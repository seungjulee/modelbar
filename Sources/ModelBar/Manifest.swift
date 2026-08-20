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

    private enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, managed, health, modelsPath, logPath
        case telemetry, process, estimatedGB, publicPort, defaultModelId
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
    }

    var isProxied: Bool { publicPort != nil }

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
    var flag: String
    var options: [Int]
    var defaultSize: Int
    /// GB delta per 100K tokens of context, for the memory-budget guard.
    /// Backend-specific and measured, not assumed: ds4's compressed-attention
    /// KV cache measured 1.12 GiB at 100K context vs 1.89 GiB at 200K, i.e.
    /// ~0.77 GB per 100K — a generic llama.cpp KV cache grows far faster than
    /// that, so this is deliberately a per-model manifest value, not a
    /// hardcoded constant that would silently mis-price a different backend.
    var gbPer100k: Double

    private enum CodingKeys: String, CodingKey { case flag, options, defaultSize, gbPer100k }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flag = try c.decode(String.self, forKey: .flag)
        options = try c.decode([Int].self, forKey: .options)
        defaultSize = try c.decodeIfPresent(Int.self, forKey: .defaultSize) ?? (options.last ?? 0)
        gbPer100k = try c.decodeIfPresent(Double.self, forKey: .gbPer100k) ?? 0
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, displayName, backendId, estimatedGB, port, notes, shortName, drafters
        case servedName, requires, start, stop, loadedCheck, harness, sleepIdleSeconds, context
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
        if let ctx = context, let size = contextSize ?? Optional(ctx.defaultSize),
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
    var hermesBin: String?
    var piSettingsPath: String?
    /// Small env file the `codex-local` shell wrapper reads its `--profile`
    /// argument from. ModelBar owns writing this file entirely; Codex itself
    /// is never told about it directly (there is no persistent-default config
    /// key any more — verified against the installed CLI, which now rejects a
    /// top-level `profile = "..."` key outright).
    var codexLocalProfilePath: String?
    /// Small env file the `claude-local` shell wrapper reads ANTHROPIC_MODEL /
    /// ANTHROPIC_BASE_URL from. Bare `claude` never reads this file and is
    /// never touched by ModelBar — that boundary is load-bearing, not a
    /// style choice: this orchestrating session is itself a `claude` process.
    var claudeLocalModelPath: String?

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

    var resolvedCodexLocalProfilePath: String {
        codexLocalProfilePath?.expandingTilde ?? (NSHomeDirectory() + "/models/codex-local-profile.env")
    }

    var resolvedClaudeLocalModelPath: String {
        claudeLocalModelPath?.expandingTilde ?? (NSHomeDirectory() + "/models/claude-local-model.env")
    }

    /// Codex profile files live at a fixed, well-known location — this is
    /// where `~/.codex/ds4.config.toml` etc. are expected.
    func codexProfilePath(_ profile: String) -> String {
        NSHomeDirectory() + "/.codex/\(profile).config.toml"
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
            ?? HarnessConfig(hermesBin: nil, piSettingsPath: nil)
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
        for b in m.backends {
            if !seenBackends.insert(b.id).inserted {
                warnings.append("duplicate backend id \"\(b.id)\"")
            }
            if !(1...65535).contains(b.port) {
                warnings.append("backend \"\(b.id)\" has out-of-range port \(b.port)")
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
