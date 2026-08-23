import Foundation

// MARK: - Path helpers

extension String {
    /// Expands a leading `~` and `$HOME`. Manifest paths are written by hand,
    /// so both spellings are worth tolerating.
    var expandingTilde: String {
        var s = self
        if s.hasPrefix("$HOME") {
            s = NSHomeDirectory() + String(s.dropFirst("$HOME".count))
        }
        return (s as NSString).expandingTildeInPath
    }
}

// MARK: - Errors

enum ManifestError: LocalizedError {
    case missing(path: String)
    case unreadable(path: String, underlying: String)
    case malformed(path: String, detail: String)
    case unsupportedVersion(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .missing(let path):
            return "No manifest at \(path)"
        case .unreadable(let path, let underlying):
            return "Cannot read \(path): \(underlying)"
        case .malformed(let path, let detail):
            return "Malformed manifest \(path): \(detail)"
        case .unsupportedVersion(let found, let supported):
            return "Manifest schemaVersion \(found) is newer than supported version \(supported)"
        }
    }
}

// MARK: - Schema

/// A shell-free command description. Kept as argv (never a command *string*) so
/// that arguments containing spaces or quotes cannot be re-split or injected.
struct CommandSpec: Decodable, Sendable, Equatable {
    var argv: [String]
    var cwd: String?
    var env: [String: String]
    var logPath: String?

    private enum CodingKeys: String, CodingKey { case argv, cwd, env, logPath }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = try c.decode([String].self, forKey: .argv)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath)
    }

    var resolvedCwd: String? { cwd?.expandingTilde }
    var resolvedLogPath: String? { logPath?.expandingTilde }
    /// argv[0] is expanded too, but only when it looks like a path — a bare
    /// program name is left alone so PATH lookup still works.
    var resolvedArgv: [String] {
        argv.enumerated().map { i, a in
            (i == 0 && !a.contains("/")) ? a : a.expandingTilde
        }
    }
}

struct HealthCheck: Decodable, Sendable {
    var path: String
    /// JSON key in the health response holding the served model name.
    var modelField: String?
    /// JSON key holding uptime in seconds.
    var uptimeField: String?

    private enum CodingKeys: String, CodingKey { case path, modelField, uptimeField }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/health"
        modelField = try c.decodeIfPresent(String.self, forKey: .modelField)
        uptimeField = try c.decodeIfPresent(String.self, forKey: .uptimeField)
    }
}

/// Selects which live-telemetry parser to use for a backend. The path is
/// configurable; the response *shape* is not, so the kind is an enum.
struct TelemetrySpec: Decodable, Sendable {
    var kind: String
    var path: String?
}

/// Declarative process-matching rule (see `ProcessMatcher`).
struct ProcessMatchSpec: Decodable, Sendable {
    var label: String?
    var any: [String]
    var all: [String]

    private enum CodingKeys: String, CodingKey { case label, any, all }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        any = try c.decodeIfPresent([String].self, forKey: .any) ?? []
        all = try c.decodeIfPresent([String].self, forKey: .all) ?? []
    }
}

/// A wire format a backend serves. These are protocols, not vendors: what
/// matters to a harness is the request/response shape at a path, so a backend
/// either speaks it or it does not.
///
/// Membership is established by probing the live server, not by assuming from
/// the backend family. A route that answers `405 Method Not Allowed` to a GET
/// exists; one that answers `404` does not — and that distinction was checked
/// against a known-bogus path on each server first, so a catch-all handler
/// could not read as a false positive.
enum BackendAPI: String, Decodable, Sendable, CaseIterable {
    /// POST /v1/chat/completions — OpenAI chat completions.
    case chat
    /// POST /v1/responses — OpenAI Responses API. The only `wire_api` Codex
    /// still accepts; `"chat"` was removed in Codex 0.148.
    case responses
    /// POST /v1/messages — Anthropic Messages API, what Claude Code speaks.
    case messages

    /// The route, for messages that name it. `chat` is the one where the enum
    /// case and the path differ, and "does not serve /v1/chat" would send
    /// someone looking for a route that does not exist under that name.
    var path: String {
        switch self {
        case .chat: return "/v1/chat/completions"
        case .responses: return "/v1/responses"
        case .messages: return "/v1/messages"
        }
    }
}

/// How to price a backend's memory against the budget.
///
/// `nominal` charges the manifest's declared size as soon as the backend is up.
/// That is right for a server whose weights are mmapped — ds4-server holds an
/// 84 GB model at single-digit RSS, so measuring it would under-count wildly
/// and happily approve a load that cannot fit.
///
/// `measured` charges the process's real footprint instead, for a backend that
/// allocates anonymously (ComfyUI's PyTorch pipelines) *and* whose server stays
/// up with nothing loaded. ComfyUI idles at ~1 GB and only reaches its ~62 GB
/// nominal size once a pipeline is actually resident; charging the nominal
/// figure merely for the port being open is the same "up != loaded" error as
/// reading load-state off a model listing, and it was silently eating half the
/// budget. Note ComfyUI's own `/system_stats` cannot substitute here: on Metal
/// it reports whole-system RAM as `vram_total`/`vram_free`, so it moves when
/// *any* process allocates and says nothing about ComfyUI specifically —
/// checked against the live endpoint rather than assumed.
enum MemoryAccounting: String, Decodable, Sendable {
    case nominal, measured
}

struct BackendSpec: Decodable, Sendable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var host: String
    var port: Int
    /// `false` marks a service ModelBar must never stop — Ollama is a launchd
    /// job that would just respawn, and stopping it would break other clients.
    var managed: Bool
    var health: HealthCheck
    /// Optional OpenAI-style model listing, used when /health carries no name.
    var modelsPath: String?
    var logPath: String?
    var telemetry: TelemetrySpec?
    var process: ProcessMatchSpec?
    /// Rough resident cost when this backend is up but its size is not
    /// attributable to a single manifest model (ComfyUI's pipeline, say).
    var estimatedGB: Double

    /// How the memory guard should price this backend's un-attributed
    /// footprint. See `MemoryAccounting` — the choice is per-backend because
    /// the two families genuinely behave differently, not as a preference.
    var memoryAccounting: MemoryAccounting

    /// When set, this backend is on-demand: ModelBar itself binds this port
    /// (the one clients already point at) and owns the real backend process's
    /// lifecycle — spawning it on the first proxied connection and stopping it
    /// after the model's idle timeout. `port` above then means something
    /// different for these backends: it is the *internal* port the real
    /// server process listens on, never exposed to clients, used only for
    /// ModelBar's own health/telemetry probing and for `stop(port:)`.
    /// Backends without a `publicPort` (Ollama, ComfyUI) are status-only or
    /// self-managed and are never proxied.
    var publicPort: Int?

    /// For a proxied backend that can serve more than one manifest model on
    /// the same port (MLX, where only one model is resident at a time), which
    /// model a cold incoming request should start. A manual "Load" from the
    /// menu overrides this for subsequent auto-starts, persisted the same way
    /// as any manual load.
    var defaultModelId: String?

    static func == (a: BackendSpec, b: BackendSpec) -> Bool { a.id == b.id }

    /// Wire formats this backend actually serves, e.g. `["chat", "responses",
    /// "messages"]`. Declared per backend and verified against the live server
    /// rather than inferred from the family name — Ollama and LocalAI both
    /// serve `/v1/responses` and `/v1/messages` while stock llama.cpp serves
    /// neither, so guessing from "it's llama.cpp underneath" is wrong.
    ///
    /// This is what stops a harness picker from offering a model whose backend
    /// cannot speak that harness's protocol; registering such a model would
    /// write a config that parses fine and then fails at the first request.
    var apis: Set<BackendAPI>

    private enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, managed, health, modelsPath, logPath
        case telemetry, process, estimatedGB, publicPort, defaultModelId
        case memoryAccounting, apis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decode(Int.self, forKey: .port)
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed) ?? true
        health = try c.decodeIfPresent(HealthCheck.self, forKey: .health)
            ?? HealthCheck(path: "/health")
        modelsPath = try c.decodeIfPresent(String.self, forKey: .modelsPath)
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath)
        telemetry = try c.decodeIfPresent(TelemetrySpec.self, forKey: .telemetry)
        process = try c.decodeIfPresent(ProcessMatchSpec.self, forKey: .process)
        estimatedGB = try c.decodeIfPresent(Double.self, forKey: .estimatedGB) ?? 0
        publicPort = try c.decodeIfPresent(Int.self, forKey: .publicPort)
        defaultModelId = try c.decodeIfPresent(String.self, forKey: .defaultModelId)
        memoryAccounting = try c.decodeIfPresent(MemoryAccounting.self,
                                                 forKey: .memoryAccounting) ?? .nominal
        // Unknown API names are dropped rather than fatal: a manifest naming a
        // wire format this build has never heard of should cost that one
        // harness option, not the whole app.
        let apiNames = try c.decodeIfPresent([String].self, forKey: .apis) ?? []
        apis = Set(apiNames.compactMap(BackendAPI.init(rawValue:)))
    }

    var isProxied: Bool { publicPort != nil }

    /// The port clients are told to use: the proxy's public port when this
    /// backend is proxied, otherwise the real one. Harness configs must be
    /// written against this — pointing a harness at the private internal port
    /// would bypass the proxy and so never trigger an on-demand cold start.
    var clientPort: Int { publicPort ?? port }

    /// Base URL for an OpenAI-shaped client (`/v1` suffix included).
    var clientBaseURL: String { "http://\(host):\(clientPort)/v1" }

    /// Base URL for an Anthropic-shaped client, which appends `/v1/messages`
    /// itself and therefore must NOT be given a `/v1` suffix.
    var anthropicBaseURL: String { "http://\(host):\(clientPort)" }

    var telemetryKind: TelemetryKind {
        TelemetryKind(rawValue: telemetry?.kind ?? "none") ?? .none
    }
    var telemetryPath: String? { telemetry?.path }

    var matcher: ProcessMatcher? {
        guard let p = process, !p.any.isEmpty else { return nil }
        return ProcessMatcher(label: p.label ?? displayName, any: p.any, all: p.all)
    }

    var resolvedLogPath: String? { logPath?.expandingTilde }
    func url(_ path: String) -> URL? {
        URL(string: "http://\(host):\(port)\(path.hasPrefix("/") ? path : "/" + path)")
    }
}

extension HealthCheck {
    init(path: String) {
        self.path = path
        self.modelField = nil
        self.uptimeField = nil
    }
}

/// An explicit "is this specific model loaded?" probe, for backends that stay
/// up across model changes (Ollama) where port liveness proves nothing.
struct LoadedCheck: Decodable, Sendable {
    var path: String
    var contains: String
}

struct HarnessTarget: Decodable, Sendable {
    /// What this model is called *on the wire* — the string a client puts in
    /// the request body's `model` field. Often not the manifest id and not the
    /// display name: ds4's entry is served as `deepseek-v4-flash` while its
    /// `servedName` (what /health reports, used for load detection) is
    /// "DeepSeek V4 Flash". The per-harness fields below override this when a
    /// harness genuinely needs a different string; otherwise every harness uses
    /// it, so a new model needs one line rather than four.
    var apiName: String?
    var hermesProvider: String?
    var hermesModel: String?
    var piProvider: String?
    var piModel: String?
    /// Name of a `~/.codex/<name>.config.toml` profile. Only set for models
    /// whose backend was actually confirmed to serve the OpenAI Responses API
    /// — Codex's `wire_api` accepts nothing else, so a plain chat-completions
    /// backend (MLX, Ollama, stock llama.cpp) cannot be a Codex target at all
    /// right now, verified rather than assumed.
    var codexProfile: String?
    /// Provider key for Codex, when it must differ from the backend id —
    /// chiefly because Codex reserves some ids for built-ins and rejects the
    /// whole config if one is redefined (`ollama` is a real example).
    /// `HarnessRegistrar.safeCodexProviderID` applies the same protection
    /// automatically, so this is only for deliberate naming.
    var codexProvider: String?
    /// Model string for Codex, when it differs from `apiName`.
    var codexModel: String?
    /// ANTHROPIC_MODEL for the `claude-local` shell wrapper. Only set for
    /// models whose backend was confirmed to serve /v1/messages — same
    /// reasoning as codexProfile, different wire format.
    var claudeLocalModel: String?
    var claudeLocalBaseURL: String?
}

/// A selectable context-window size, only meaningful for a backend that takes
/// context as a launch-time flag (restart required to change it). MLX has no
/// such flag at all (verified against `mlx_lm.server`'s own argument parser —
/// there is nothing beyond `--max-tokens`, which is generation length, not
/// context); Ollama takes it per-request with no restart, which is a live
/// request-rewriting feature ModelBar does not implement (it proxies bytes,
/// it does not parse and mutate JSON request bodies). This models the one
/// case actually built: a launch flag whose value can be swapped before start.
struct ContextOption: Decodable, Sendable {
    /// Launch flag carrying the size, for a backend ModelBar spawns itself
    /// (ds4's `-c`, llama.cpp's `--ctx-size`). Empty when the size lives in a
    /// config file instead — see `file`.
    var flag: String
    /// Config file holding the size, for a backend ModelBar does not launch.
    /// LocalAI is the case: it is `managed: false`, so there is no argv to
    /// rewrite, and its per-model `~/.localai/models/<name>.yaml` carries
    /// `context_size:`. Mutually exclusive with `flag` in practice.
    var file: String?
    /// Key to rewrite inside `file` (e.g. `context_size`).
    var key: String?
    /// Explicit ladder. `nil` means "derive from the model's trained ceiling",
    /// which is the preferred form: a hardcoded ladder is how every model here
    /// ended up capped at 32K regardless of what it was actually trained for.
    /// Set it only where the usable range is narrower than the ceiling for a
    /// reason the metadata cannot express.
    var options: [Int]?
    var defaultSize: Int
    /// GB delta per 100K tokens of context, for the memory-budget guard.
    /// Backend-specific and measured, not assumed: ds4's compressed-attention
    /// KV cache measured 1.12 GiB at 100K context vs 1.89 GiB at 200K, i.e.
    /// ~0.77 GB per 100K — a generic llama.cpp KV cache grows far faster than
    /// that, so this is deliberately a per-model manifest value, not a
    /// hardcoded constant that would silently mis-price a different backend.
    var gbPer100k: Double
    /// Whether the backend allocates the whole KV cache at load time.
    ///
    /// True for the llama.cpp family, which reserves the full context up front
    /// and so really does cost it the moment the model loads. MLX grows its
    /// cache lazily as a conversation extends, so charging a full-context KV
    /// against the budget at load time would refuse loads that are fine.
    var reservesKVUpFront: Bool

    private enum CodingKeys: String, CodingKey {
        case flag, file, key, options, defaultSize, gbPer100k, reservesKVUpFront
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flag = try c.decodeIfPresent(String.self, forKey: .flag) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        options = try c.decodeIfPresent([Int].self, forKey: .options)
        defaultSize = try c.decodeIfPresent(Int.self, forKey: .defaultSize) ?? (options?.last ?? 0)
        gbPer100k = try c.decodeIfPresent(Double.self, forKey: .gbPer100k) ?? 0
        reservesKVUpFront = try c.decodeIfPresent(Bool.self, forKey: .reservesKVUpFront) ?? true
    }

    var resolvedFile: String? { file?.expandingTilde }
    /// Where the chosen size actually goes. A file-backed size has to be
    /// written the moment it is picked, since nothing re-reads it from
    /// ModelBar's memory at launch — there is no launch under ModelBar's
    /// control at all for these backends.
    var isFileBacked: Bool { file != nil && key != nil }
}

/// An optional speculative-decoding drafter for a model.
///
/// Kept as an appendable list of `extraArgs` rather than as named fields so a
/// new drafter family can be switched on by editing JSON alone. DFlash2 entries
/// ship with `enabled: false` because they need a llama.cpp built from an
/// unmerged PR; the Homebrew build advertises draft-dflash/draft-dspark only.
struct DrafterSpec: Decodable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var enabled: Bool
    /// Appended verbatim to the model's start argv when enabled.
    var extraArgs: [String]
    /// Files that must exist before this drafter can be used.
    var requires: [String]
    var notes: String?

    private enum CodingKeys: String, CodingKey {
        case id, displayName, enabled, extraArgs, requires, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    var resolvedExtraArgs: [String] { extraArgs.map(\.expandingTilde) }
    var missingRequirements: [String] {
        requires.map(\.expandingTilde).filter { !FileManager.default.fileExists(atPath: $0) }
    }
    var isUsable: Bool { enabled && missingRequirements.isEmpty }
}

struct ModelSpec: Decodable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var backendId: String
    var estimatedGB: Double
    var port: Int
    var notes: String?
    /// Optional compact label for the menubar, where space is tight.
    var shortName: String?
    var drafters: [DrafterSpec]
    /// Substring matched (case-insensitively) against the model name the
    /// backend reports, to decide whether *this* entry is what is loaded.
    var servedName: String?
    /// Files that must exist for this entry to be startable. Entries whose
    /// weights are still downloading fail this check and are shown greyed out.
    var requires: [String]
    var start: CommandSpec?
    var stop: CommandSpec?
    var loadedCheck: LoadedCheck?
    var harness: HarnessTarget?
    /// How long a proxied backend may sit idle (no open client connections)
    /// before ModelBar stops it to reclaim memory. Named to mirror Llama.app's
    /// own `sleep-idle-seconds`, since it's the same concept. `nil` means "use
    /// `settings.defaultSleepIdleSeconds`"; only meaningful for models on a
    /// backend with `publicPort` set.
    var sleepIdleSeconds: Double?
    /// Selectable context-window sizes, only present for a backend that takes
    /// context as a restart-time launch flag. `nil` means not adjustable —
    /// hidden in the UI rather than shown disabled, since for MLX that is not
    /// a temporary limitation but a real absence of the capability.
    var context: ContextOption?
    /// Fixed context window, for a model whose size is not adjustable from
    /// here but is still worth telling a harness about. Ignored when `context`
    /// is present, which carries the live selection instead.
    var contextLength: Int?
    /// Explicit path to the file carrying this model's geometry — an MLX
    /// `config.json` or a `.gguf`. Only needed when it cannot be picked out of
    /// `requires`, which is the case for a model whose manifest entry names a
    /// backend config file instead of the weights (LocalAI).
    var metadataPath: String?

    private enum CodingKeys: String, CodingKey {
        case id, displayName, backendId, estimatedGB, port, notes, shortName, drafters
        case servedName, requires, start, stop, loadedCheck, harness, sleepIdleSeconds, context
        case contextLength, metadataPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        backendId = try c.decode(String.self, forKey: .backendId)
        estimatedGB = try c.decodeIfPresent(Double.self, forKey: .estimatedGB) ?? 0
        port = try c.decode(Int.self, forKey: .port)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName)
        drafters = try c.decodeIfPresent([DrafterSpec].self, forKey: .drafters) ?? []
        servedName = try c.decodeIfPresent(String.self, forKey: .servedName)
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        start = try c.decodeIfPresent(CommandSpec.self, forKey: .start)
        stop = try c.decodeIfPresent(CommandSpec.self, forKey: .stop)
        loadedCheck = try c.decodeIfPresent(LoadedCheck.self, forKey: .loadedCheck)
        harness = try c.decodeIfPresent(HarnessTarget.self, forKey: .harness)
        sleepIdleSeconds = try c.decodeIfPresent(Double.self, forKey: .sleepIdleSeconds)
        context = try c.decodeIfPresent(ContextOption.self, forKey: .context)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        metadataPath = try c.decodeIfPresent(String.self, forKey: .metadataPath)
    }

    /// Compact menubar label: the manifest's `shortName` if given, else the
    /// first word of the display name with any trailing punctuation removed.
    var shortLabel: String {
        if let shortName, !shortName.isEmpty { return shortName }
        let first = displayName.split(separator: " ").first.map(String.init) ?? displayName
        return String(first.prefix(14)).trimmingCharacters(in: CharacterSet(charactersIn: "·-—,"))
    }

    var resolvedRequires: [String] { requires.map(\.expandingTilde) }

    /// Paths from `requires` that are not present on disk right now.
    var missingRequirements: [String] {
        resolvedRequires.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    /// The drafter that will actually be applied: enabled and fully present.
    var activeDrafter: DrafterSpec? { drafters.first(where: \.isUsable) }

    /// Start command with the active drafter's arguments appended and, if this
    /// model has a `context` option, its context flag's value substituted for
    /// the currently-selected size (falling back to the manifest default).
    /// The manifest's own literal argv value is never trusted as "current" —
    /// only ever as the fallback — since the user's last picked size lives in
    /// `AppState`'s persisted selection, not in this static spec.
    func effectiveStart(contextSize: Int? = nil) -> CommandSpec? {
        guard var cmd = start else { return nil }
        if let drafter = activeDrafter {
            cmd.argv = cmd.argv + drafter.resolvedExtraArgs
        }
        if let ctx = context, !ctx.flag.isEmpty,
           let size = contextSize ?? Optional(ctx.defaultSize),
           let flagIndex = cmd.argv.firstIndex(of: ctx.flag), flagIndex + 1 < cmd.argv.count {
            cmd.argv[flagIndex + 1] = String(size)
        }
        return cmd
    }

    /// Convenience for call sites that do not care about context selection
    /// (drafter application only).
    var effectiveStart: CommandSpec? { effectiveStart(contextSize: nil) }

    /// Estimated resident size at a given context selection. Uses the
    /// manifest's measured per-100K delta rather than a generic proportional
    /// heuristic — see `ContextOption.gbPer100k` for why that matters.
    func estimatedGB(atContextSize size: Int) -> Double {
        guard let ctx = context, ctx.gbPer100k > 0 else { return estimatedGB }
        let deltaTokens = Double(size - ctx.defaultSize)
        return max(0, estimatedGB + (deltaTokens / 100_000) * ctx.gbPer100k)
    }
}

struct ManifestSettings: Decodable, Sendable {
    var memoryBudgetGB: Double
    var pollSeconds: Double
    var startTimeoutSeconds: Double
    var stopGraceSeconds: Double
    /// Fallback idle timeout for a proxied model that does not set its own
    /// `sleepIdleSeconds`.
    var defaultSleepIdleSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case memoryBudgetGB, pollSeconds, startTimeoutSeconds, stopGraceSeconds
        case defaultSleepIdleSeconds
    }

    init() {
        memoryBudgetGB = 124
        pollSeconds = 4
        startTimeoutSeconds = 180
        stopGraceSeconds = 12
        defaultSleepIdleSeconds = 300
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(Double.self, forKey: .memoryBudgetGB) { memoryBudgetGB = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) { pollSeconds = max(1, v) }
        if let v = try c.decodeIfPresent(Double.self, forKey: .startTimeoutSeconds) { startTimeoutSeconds = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .stopGraceSeconds) { stopGraceSeconds = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .defaultSleepIdleSeconds) {
            defaultSleepIdleSeconds = max(10, v)
        }
    }
}

struct HarnessConfig: Decodable, Sendable {
    var hermesBin: String? = nil
    var piSettingsPath: String? = nil
    /// Pi's provider/model *definitions*, separate from settings.json.
    var piModelsPath: String? = nil
    /// Hermes' config, edited directly for provider registration — its CLI
    /// cannot write a real YAML list (see `HarnessRegistrar.registerHermes`).
    var hermesConfigPath: String? = nil
    /// Codex's main config, where `[model_providers.*]` blocks live.
    var codexConfigPath: String? = nil
    /// Small env file the `codex-local` shell wrapper reads its `--profile`
    /// argument from. ModelBar owns writing this file entirely; Codex itself
    /// is never told about it directly (there is no persistent-default config
    /// key any more — verified against the installed CLI, which now rejects a
    /// top-level `profile = "..."` key outright).
    var codexLocalProfilePath: String? = nil
    /// Small env file the `claude-local` shell wrapper reads ANTHROPIC_MODEL /
    /// ANTHROPIC_BASE_URL from. Bare `claude` never reads this file and is
    /// never touched by ModelBar — that boundary is load-bearing, not a
    /// style choice: this orchestrating session is itself a `claude` process.
    var claudeLocalModelPath: String? = nil

    var resolvedHermesBin: String? {
        // GUI apps inherit a minimal PATH from launchd, so a bare "hermes"
        // would not resolve. Prefer the manifest value, then known locations.
        let candidates = [hermesBin?.expandingTilde,
                          NSHomeDirectory() + "/.local/bin/hermes",
                          "/opt/homebrew/bin/hermes",
                          "/usr/local/bin/hermes"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var resolvedPiSettingsPath: String {
        piSettingsPath?.expandingTilde ?? (NSHomeDirectory() + "/.pi/agent/settings.json")
    }

    /// Pi splits provider *definitions* (models.json) from the active pointer
    /// and enabled list (settings.json); registering a model requires both.
    var resolvedPiModelsPath: String {
        piModelsPath?.expandingTilde ?? (NSHomeDirectory() + "/.pi/agent/models.json")
    }

    var resolvedHermesConfigPath: String {
        hermesConfigPath?.expandingTilde ?? (NSHomeDirectory() + "/.hermes/config.yaml")
    }

    var resolvedCodexConfigPath: String {
        codexConfigPath?.expandingTilde ?? (NSHomeDirectory() + "/.codex/config.toml")
    }

    var resolvedCodexLocalProfilePath: String {
        codexLocalProfilePath?.expandingTilde ?? (NSHomeDirectory() + "/models/scripts/codex-local-profile.env")
    }

    var resolvedClaudeLocalModelPath: String {
        claudeLocalModelPath?.expandingTilde ?? (NSHomeDirectory() + "/models/scripts/claude-local-model.env")
    }

    /// Codex profile files sit beside the main config, as
    /// `<codex dir>/<profile>.config.toml`.
    ///
    /// Derived from `resolvedCodexConfigPath` rather than hardcoded to
    /// `~/.codex`, so pointing ModelBar at a scratch manifest really does
    /// redirect *every* Codex write. When it was hardcoded, a test run against
    /// a throwaway manifest still dropped a profile file into the user's real
    /// `~/.codex` — a config-writing feature whose test mode is not fully
    /// isolated is one that cannot be exercised safely.
    func codexProfilePath(_ profile: String) -> String {
        let dir = (resolvedCodexConfigPath as NSString).deletingLastPathComponent
        return dir + "/\(profile).config.toml"
    }
}

struct Manifest: Decodable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var settings: ManifestSettings
    var backends: [BackendSpec]
    var models: [ModelSpec]
    var harness: HarnessConfig

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settings, backends, models, harness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        settings = try c.decodeIfPresent(ManifestSettings.self, forKey: .settings) ?? ManifestSettings()
        backends = try c.decodeIfPresent([BackendSpec].self, forKey: .backends) ?? []
        models = try c.decodeIfPresent([ModelSpec].self, forKey: .models) ?? []
        harness = try c.decodeIfPresent(HarnessConfig.self, forKey: .harness)
            ?? HarnessConfig()
    }

    func backend(id: String) -> BackendSpec? { backends.first { $0.id == id } }
    func model(id: String) -> ModelSpec? { models.first { $0.id == id } }
    func models(backendId: String) -> [ModelSpec] { models.filter { $0.backendId == backendId } }

    func effectiveSleepIdleSeconds(_ model: ModelSpec) -> Double {
        model.sleepIdleSeconds ?? settings.defaultSleepIdleSeconds
    }
}

// MARK: - Loading

struct ManifestLoad: Sendable {
    var manifest: Manifest
    /// Non-fatal problems worth surfacing in the menu (bad refs, dead paths).
    var warnings: [String]
}

enum ManifestLoader {
    static var defaultPath: String { NSHomeDirectory() + "/models/modelbar.json" }

    static func load(path: String = defaultPath) throws -> ManifestLoad {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ManifestError.missing(path: path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ManifestError.unreadable(path: path, underlying: error.localizedDescription)
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw ManifestError.malformed(
                path: path,
                detail: "missing key \"\(key.stringValue)\" at \(Self.describe(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ManifestError.malformed(
                path: path,
                detail: "wrong type at \(Self.describe(ctx.codingPath)) — \(ctx.debugDescription)")
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ManifestError.malformed(
                path: path,
                detail: ctx.debugDescription)
        } catch {
            throw ManifestError.malformed(path: path, detail: error.localizedDescription)
        }

        guard manifest.schemaVersion <= Manifest.supportedSchemaVersion else {
            throw ManifestError.unsupportedVersion(
                found: manifest.schemaVersion,
                supported: Manifest.supportedSchemaVersion)
        }

        return ManifestLoad(manifest: manifest, warnings: validate(manifest))
    }

    private static func describe(_ path: [CodingKey]) -> String {
        path.isEmpty ? "top level" : path.map(\.stringValue).joined(separator: ".")
    }

    /// Structural problems that do not justify refusing to run: the app shows
    /// these in the menu and skips the offending entries.
    private static func validate(_ m: Manifest) -> [String] {
        var warnings: [String] = []

        var seenBackends = Set<String>()
        // Every port a backend claims, and what claims it. Collisions here are
        // not cosmetic: ModelBar binds each `publicPort` itself and spawns the
        // real server on the matching `port`, so two backends sharing either
        // number means one silently fails to bind, or a stop-by-port kills the
        // wrong server. Neither surfaces as anything but "it stopped working".
        var claimedPorts: [Int: String] = [:]
        func claim(_ port: Int, _ owner: String) {
            if let existing = claimedPorts[port], existing != owner {
                warnings.append("port \(port) is claimed by both \(existing) and \(owner)")
            } else {
                claimedPorts[port] = owner
            }
        }

        for b in m.backends {
            if !seenBackends.insert(b.id).inserted {
                warnings.append("duplicate backend id \"\(b.id)\"")
            }
            if !(1...65535).contains(b.port) {
                warnings.append("backend \"\(b.id)\" has out-of-range port \(b.port)")
            }
            claim(b.port, "backend \"\(b.id)\"")
            if let publicPort = b.publicPort {
                if !(1...65535).contains(publicPort) {
                    warnings.append(
                        "backend \"\(b.id)\" has out-of-range publicPort \(publicPort)")
                }
                if publicPort == b.port {
                    // The proxy would be forwarding to itself.
                    warnings.append("backend \"\(b.id)\" has publicPort equal to its port "
                                    + "(\(publicPort)) — the proxy would forward to itself")
                } else {
                    claim(publicPort, "backend \"\(b.id)\" publicPort")
                }
            }
        }

        var seenModels = Set<String>()
        for mo in m.models {
            if !seenModels.insert(mo.id).inserted {
                warnings.append("duplicate model id \"\(mo.id)\"")
            }
            if m.backend(id: mo.backendId) == nil {
                warnings.append("model \"\(mo.id)\" references unknown backend \"\(mo.backendId)\"")
            }
            if let s = mo.start, s.argv.isEmpty {
                warnings.append("model \"\(mo.id)\" has an empty start.argv")
            }
            if !(1...65535).contains(mo.port) {
                warnings.append("model \"\(mo.id)\" has out-of-range port \(mo.port)")
            }
        }

        if m.backends.isEmpty { warnings.append("manifest declares no backends") }
        if m.models.isEmpty { warnings.append("manifest declares no models") }
        return warnings
    }
}
