import Foundation

struct KV: Sendable, Identifiable, Equatable {
    var key: String
    var value: String
    var id: String { key }
}

/// A model Ollama currently holds resident (from GET /api/ps).
struct OllamaResident: Sendable, Equatable, Identifiable {
    var name: String
    var sizeBytes: UInt64
    var expiresAt: String?
    var id: String { name }
}

/// Live per-backend telemetry. Every field is optional because which of these a
/// backend exposes varies, and because a server can be up but not yet serving.
struct Telemetry: Sendable, Equatable {
    var decodeTPS: Double?
    var prefillTPS: Double?
    var contextUsed: Int?
    var contextSize: Int?
    var queueDepth: Int?
    var busy: Bool?
    var promptTokens: Int?
    var generatedTokens: Int?
    var ollamaResident: [OllamaResident] = []
    /// Names a multi-model backend reports as resident, where it gives us names
    /// but no per-model size (LocalAI). Sorted, so the UI never flickers.
    var residentModels: [String] = []
    var jobsRunning: Int?
    var jobsPending: Int?
    var extra: [KV] = []

    var contextFraction: Double? {
        guard let used = contextUsed, let size = contextSize, size > 0 else { return nil }
        return min(1.0, Double(used) / Double(size))
    }

    var isEmpty: Bool {
        decodeTPS == nil && prefillTPS == nil && contextUsed == nil
            && ollamaResident.isEmpty && residentModels.isEmpty
            && jobsRunning == nil && extra.isEmpty
    }
}

struct BackendStatus: Sendable, Equatable {
    var backendId: String
    var up: Bool
    var servedModel: String?
    var uptime: TimeInterval?
    var telemetry: Telemetry
    var lastError: String?
    var checkedAt: Date

    /// The names a backend reports as *actually resident right now*, or `nil`
    /// when the backend has no way to tell us.
    ///
    /// This distinction is the whole point: for a multi-model server that stays
    /// up across loads and unloads (LocalAI, Ollama), "the port answers" and
    /// "this model is in memory" are completely different facts, and an
    /// OpenAI-style `/v1/models` listing answers neither — it lists what is
    /// *configured*. LocalAI returns all three of its YAML entries whether or
    /// not any weights are resident, which is what previously made an unloaded
    /// Muse-Glimmer report as loaded.
    ///
    /// `nil` and `[]` mean opposite things and must not be conflated:
    ///   nil — no residency signal exists; fall back to weaker heuristics.
    ///   []  — the backend affirmatively says nothing is loaded. Authoritative.
    var residentModelIDs: [String]?
}

enum TelemetryKind: String, Sendable {
    case ds4, llamacpp, ollama, comfyui, localai, none
}

/// All backend HTTP probing. Every call has a short timeout so a wedged server
/// delays a refresh rather than hanging the app.
enum Probe {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.5
        cfg.timeoutIntervalForResource = 4
        cfg.waitsForConnectivity = false
        // Localhost only; no caching or cookies wanted.
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    static func get(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func getJSON(_ url: URL) async -> [String: Any]? {
        guard let data = await get(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func getText(_ url: URL) async -> String? {
        guard let data = await get(url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Backend status

    static func status(for backend: BackendSpec, kind: TelemetryKind,
                       telemetryPath: String?) async -> BackendStatus {
        guard let healthURL = backend.url(backend.health.path) else {
            return BackendStatus(backendId: backend.id, up: false, servedModel: nil,
                                 uptime: nil, telemetry: Telemetry(),
                                 lastError: "bad health URL", checkedAt: Date())
        }

        let health = await getJSON(healthURL)
        let plainUp = health != nil ? true : (await get(healthURL)) != nil
        guard plainUp else {
            return BackendStatus(backendId: backend.id, up: false, servedModel: nil,
                                 uptime: nil, telemetry: Telemetry(),
                                 lastError: nil, checkedAt: Date(), residentModelIDs: nil)
        }

        var servedModel: String?
        var uptime: TimeInterval?
        if let health {
            if let key = backend.health.modelField { servedModel = stringValue(health[key]) }
            if let key = backend.health.uptimeField { uptime = doubleValue(health[key]) }
        }

        var telemetry = Telemetry()
        /// Authoritative residency, when the backend can report it. See
        /// `BackendStatus.residentModelIDs` for why nil != [].
        var residentModelIDs: [String]?
        switch kind {
        case .ds4:
            if let path = telemetryPath, let url = backend.url(path),
               let stats = await getJSON(url) {
                telemetry = ds4Telemetry(stats)
                if uptime == nil { uptime = doubleValue(stats["uptime_s"]) }
            }
        case .llamacpp:
            let (t, model) = await llamacppTelemetry(backend: backend, metricsPath: telemetryPath)
            telemetry = t
            if servedModel == nil { servedModel = model }
        case .ollama:
            // /api/ps is the *loaded* set. Ollama's /api/tags — the listing it
            // is easy to reach for — is the *installed* set and would be the
            // same category error as LocalAI's /v1/models. Deliberately not used.
            if let path = telemetryPath, let url = backend.url(path),
               let ps = await getJSON(url) {
                telemetry = ollamaTelemetry(ps)
                residentModelIDs = telemetry.ollamaResident.map(\.name).sorted()
                if servedModel == nil { servedModel = residentModelIDs?.first }
            }
        case .comfyui:
            telemetry = await comfyTelemetry(backend: backend, statsPath: telemetryPath)
        case .localai:
            // LocalAI's own /metrics is HTTP request-latency histograms, not
            // per-model decode tok/s — genuinely thinner than ds4/llama.cpp,
            // verified rather than assumed (checked the real output).
            //
            // /system is the load-state source. Its `loaded_models[]` is the
            // set actually resident; the sibling `backends[]` key is the list
            // of *installed* backend runtimes and has nothing to do with load
            // state — conflating the two is an easy and wrong shortcut.
            //
            // /backend/monitor?model=<name> was evaluated for richer per-model
            // telemetry and rejected: against a genuinely loaded model it
            // returns 500 "rpc error: code = Unimplemented", so there is no
            // per-model detail to be had. Observed live, not assumed.
            let system = await localaiSystem(backend: backend)
            residentModelIDs = system.loaded
            telemetry.residentModels = system.loaded
            if !system.loaded.isEmpty {
                telemetry.extra.append(KV(key: "loaded",
                                          value: system.loaded.joined(separator: ", ")))
            }
            // Deterministic: the first *loaded* model, not the first configured
            // one. LocalAI serialises /v1/models from a Go map, so its order is
            // randomised per request — taking `data[0]` there made the menu
            // alternate between model names on consecutive polls even though
            // nothing had changed.
            servedModel = system.loaded.first
        case .none:
            break
        }

        // Fall back to an OpenAI-style model listing when /health carries no
        // name — but only for a backend with no residency signal of its own.
        // For LocalAI/Ollama this listing is "configured", not "loaded", and
        // letting it populate servedModel is precisely the bug being fixed.
        if servedModel == nil, residentModelIDs == nil,
           let path = backend.modelsPath, let url = backend.url(path),
           let json = await getJSON(url) {
            servedModel = openAIModelName(json)
        }

        return BackendStatus(backendId: backend.id, up: true, servedModel: servedModel,
                             uptime: uptime, telemetry: telemetry,
                             lastError: nil, checkedAt: Date(),
                             residentModelIDs: residentModelIDs)
    }

    /// LocalAI `GET /system`. Verified shape, observed live with a model
    /// genuinely resident:
    ///
    ///     {"backends":["llama-cpp","metal-mlx", …],
    ///      "loaded_models":[{"id":"muse-glimmer","backend":"llama-cpp"}]}
    ///
    /// `id` is the model name from `~/.localai/models/<name>.yaml`. Entries are
    /// tolerated as bare strings too, so a future LocalAI that flattens the
    /// array does not silently read as "nothing loaded".
    static func localaiSystem(backend: BackendSpec) async -> (loaded: [String],
                                                              backends: [String]) {
        guard let url = backend.url("/system"), let json = await getJSON(url) else {
            // Unreachable /system is genuinely unknown, not "nothing loaded" —
            // reported as an empty pair only because the caller has already
            // established the port answers; see the call site.
            return ([], [])
        }
        var loaded: [String] = []
        if let entries = json["loaded_models"] as? [Any] {
            for entry in entries {
                if let s = entry as? String { loaded.append(s) }
                else if let d = entry as? [String: Any], let id = stringValue(d["id"]) {
                    loaded.append(id)
                }
            }
        }
        let backends = (json["backends"] as? [Any])?.compactMap { $0 as? String } ?? []
        return (loaded.sorted(), backends)
    }

    // MARK: - Per-backend parsers

    /// ds4 GET /stats — verified shape: uptime_s, busy, queue_depth, live_tokens,
    /// ctx_size, prompt_tokens, generated_tokens, last_prefill_tps, last_decode_tps.
    static func ds4Telemetry(_ s: [String: Any]) -> Telemetry {
        var t = Telemetry()
        t.decodeTPS = doubleValue(s["last_decode_tps"])
        t.prefillTPS = doubleValue(s["last_prefill_tps"])
        t.contextUsed = intValue(s["live_tokens"])
        t.contextSize = intValue(s["ctx_size"])
        t.queueDepth = intValue(s["queue_depth"])
        t.busy = s["busy"] as? Bool
        t.promptTokens = intValue(s["prompt_tokens"])
        t.generatedTokens = intValue(s["generated_tokens"])
        if let cached = intValue(s["cached_tokens"]), let prompt = t.promptTokens, prompt > 0 {
            let pct = Double(cached) / Double(prompt) * 100
            t.extra.append(KV(key: "cache hit", value: String(format: "%.0f%%", pct)))
        }
        if let clients = intValue(s["clients"]) {
            t.extra.append(KV(key: "clients", value: "\(clients)"))
        }
        return t
    }

    /// llama.cpp: throughput from the Prometheus /metrics endpoint (which only
    /// exists when the server was started with --metrics), context size from
    /// /props, model name from /v1/models.
    static func llamacppTelemetry(backend: BackendSpec,
                                  metricsPath: String?) async -> (Telemetry, String?) {
        var t = Telemetry()
        var model: String?

        async let metricsText: String? = {
            guard let path = metricsPath, let url = backend.url(path) else { return nil }
            return await getText(url)
        }()
        async let propsJSON: [String: Any]? = {
            guard let url = backend.url("/props") else { return nil }
            return await getJSON(url)
        }()
        async let slotsJSON: Data? = {
            guard let url = backend.url("/slots") else { return nil }
            return await get(url)
        }()

        if let text = await metricsText {
            let m = parsePrometheus(text)
            t.decodeTPS = m["llamacpp:predicted_tokens_seconds"]
            t.prefillTPS = m["llamacpp:prompt_tokens_seconds"]
            if let v = m["llamacpp:requests_processing"] { t.queueDepth = Int(v); t.busy = v > 0 }
            if let v = m["llamacpp:tokens_predicted_total"] { t.generatedTokens = Int(v) }
            if let v = m["llamacpp:prompt_tokens_total"] { t.promptTokens = Int(v) }
            if let v = m["llamacpp:n_tokens_max"] { t.contextUsed = Int(v) }
        } else if metricsPath != nil {
            t.extra.append(KV(key: "metrics", value: "off (needs --metrics)"))
        }

        if let props = await propsJSON {
            if let gen = props["default_generation_settings"] as? [String: Any],
               let n = intValue(gen["n_ctx"]) {
                t.contextSize = n
            }
            if t.contextSize == nil { t.contextSize = intValue(props["n_ctx"]) }
            if let path = stringValue(props["model_path"]) {
                model = (path as NSString).lastPathComponent
            }
        }

        // Live per-slot context use is more accurate than the n_tokens_max
        // high-water mark, so prefer it when a slot reports it.
        if let data = await slotsJSON,
           let slots = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            var maxUsed = 0
            var processing = 0
            for slot in slots {
                if let n = intValue(slot["n_ctx"]), t.contextSize == nil { t.contextSize = n }
                for key in ["n_past", "tokens_evaluated", "n_tokens"] {
                    if let v = intValue(slot[key]) { maxUsed = max(maxUsed, v) }
                }
                if slot["is_processing"] as? Bool == true { processing += 1 }
            }
            if maxUsed > 0 { t.contextUsed = maxUsed }
            if processing > 0 { t.busy = true; t.queueDepth = processing }
        }

        if let url = backend.url(backend.modelsPath ?? "/v1/models"),
           let json = await getJSON(url), let name = openAIModelName(json) {
            model = name
        }
        return (t, model)
    }

    /// Ollama GET /api/ps — the only way to know what it holds, since it loads
    /// and evicts on its own schedule while the port stays up regardless.
    static func ollamaTelemetry(_ ps: [String: Any]) -> Telemetry {
        var t = Telemetry()
        guard let models = ps["models"] as? [[String: Any]] else { return t }
        t.ollamaResident = models.compactMap { m in
            guard let name = stringValue(m["name"]) ?? stringValue(m["model"]) else { return nil }
            let size = UInt64(intValue(m["size_vram"]) ?? intValue(m["size"]) ?? 0)
            return OllamaResident(name: name, sizeBytes: size,
                                  expiresAt: stringValue(m["expires_at"]))
        }
        return t
    }

    /// ComfyUI: /system_stats for VRAM as torch sees it, /queue for job state.
    /// The job indicator matters because a diffusers pipeline with sequential
    /// offload swings RSS by tens of GB mid-generation, which otherwise reads
    /// as a bug rather than as normal behaviour.
    static func comfyTelemetry(backend: BackendSpec, statsPath: String?) async -> Telemetry {
        var t = Telemetry()

        if let path = statsPath, let url = backend.url(path), let stats = await getJSON(url) {
            if let devices = stats["devices"] as? [[String: Any]], let d = devices.first {
                let total = UInt64(intValue(d["vram_total"]) ?? 0)
                let free = UInt64(intValue(d["vram_free"]) ?? 0)
                if total > 0 {
                    t.extra.append(KV(key: "torch vram free", value: Fmt.gb(free)))
                }
            }
            if let system = stats["system"] as? [String: Any],
               let version = stringValue(system["comfyui_version"]) {
                t.extra.append(KV(key: "version", value: version))
            }
        }

        if let url = backend.url("/queue"), let q = await getJSON(url) {
            let running = (q["queue_running"] as? [Any])?.count ?? 0
            let pending = (q["queue_pending"] as? [Any])?.count ?? 0
            t.jobsRunning = running
            t.jobsPending = pending
            t.busy = running > 0
        }
        return t
    }

    // MARK: - Small parsers

    /// Prometheus text format: `name value`, with `#` comment lines.
    static func parsePrometheus(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            out[String(parts[0])] = value
        }
        return out
    }

    /// Accepts both OpenAI (`data[].id`) and Ollama-flavoured (`models[].name`)
    /// listings — llama.cpp build 10470 returns both keys in one response.
    ///
    /// Only ever called for single-model servers now (llama.cpp, MLX), where
    /// the listing has exactly one entry and "listed" really does mean
    /// "loaded". It sorts before picking anyway: a server that serialises this
    /// array from a hash map returns a different order per request, and taking
    /// an arbitrary element made the UI alternate between names on consecutive
    /// polls with nothing actually changing.
    static func openAIModelName(_ json: [String: Any]) -> String? {
        if let data = json["data"] as? [[String: Any]] {
            let ids = data.compactMap { stringValue($0["id"]) }.sorted()
            if let first = ids.first { return first }
        }
        if let models = json["models"] as? [[String: Any]] {
            let names = models.compactMap {
                stringValue($0["name"]) ?? stringValue($0["model"])
            }.sorted()
            if let first = names.first { return first }
        }
        return nil
    }

    static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
