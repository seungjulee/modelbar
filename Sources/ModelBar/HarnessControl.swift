import Foundation

/// What every harness is currently pointed at. Codex and Claude Code are
/// explicit two-state toggles — `nil` for their active-model fields means
/// "API" (Codex: native ChatGPT auth; Claude Code: `claude-local` disarmed,
/// bare `claude` was never touched either way).
struct HarnessState: Sendable, Equatable {
    var hermesProvider: String?
    var hermesModel: String?
    var piProvider: String?
    var piModel: String?
    var codexActiveProfile: String?
    var claudeLocalActiveModel: String?
    var hermesAvailable: Bool = false
    var errors: [String] = []
}

/// Reads and rewrites the two harness configs.
///
/// Hermes is driven through its own CLI (`hermes config set`) rather than by
/// editing config.yaml, so Hermes owns the file format and any migrations.
/// Pi has no such CLI, so its settings.json is edited directly — key by key,
/// preserving everything else, and written atomically.
enum HarnessControl {

    // MARK: - Reading

    static func read(config: HarnessConfig) async -> HarnessState {
        var state = HarnessState()

        if let bin = config.resolvedHermesBin {
            state.hermesAvailable = true
            let provider = await ProcessControl.run([bin, "config", "get", "model.provider"],
                                                    timeout: 10)
            let model = await ProcessControl.run([bin, "config", "get", "model.default"],
                                                 timeout: 10)
            state.hermesProvider = provider.succeeded ? provider.trimmed : nil
            state.hermesModel = model.succeeded ? model.trimmed : nil
            if !provider.succeeded && !provider.trimmed.isEmpty {
                state.errors.append("hermes: \(provider.trimmed.prefix(120))")
            }
        } else {
            state.errors.append("hermes binary not found")
        }

        let piPath = config.resolvedPiSettingsPath
        if let json = readJSONObject(atPath: piPath) {
            state.piProvider = json["defaultProvider"] as? String
            state.piModel = json["defaultModel"] as? String
        } else if FileManager.default.fileExists(atPath: piPath) {
            state.errors.append("pi settings.json is not valid JSON")
        }

        let codexEnv = readEnvFile(atPath: config.resolvedCodexLocalProfilePath)
        state.codexActiveProfile = codexEnv["CODEX_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }

        let claudeEnv = readEnvFile(atPath: config.resolvedClaudeLocalModelPath)
        state.claudeLocalActiveModel = claudeEnv["ANTHROPIC_MODEL"].flatMap { $0.isEmpty ? nil : $0 }

        return state
    }

    // MARK: - Writing

    @discardableResult
    static func setHermes(config: HarnessConfig, provider: String, model: String) async -> String? {
        guard let bin = config.resolvedHermesBin else { return "hermes binary not found" }
        let p = await ProcessControl.run([bin, "config", "set", "model.provider", provider],
                                         timeout: 20)
        guard p.succeeded else { return "hermes provider: \(p.trimmed.prefix(160))" }
        let m = await ProcessControl.run([bin, "config", "set", "model.default", model],
                                         timeout: 20)
        guard m.succeeded else { return "hermes model: \(m.trimmed.prefix(160))" }
        return nil
    }

    /// Rewrites only `defaultProvider` and `defaultModel`, leaving every other
    /// key (packages, theme, enabledModels, ...) exactly as it was.
    @discardableResult
    static func setPi(config: HarnessConfig, provider: String, model: String) -> String? {
        let path = config.resolvedPiSettingsPath
        guard var json = readJSONObject(atPath: path) else {
            return "cannot read \(path) as JSON"
        }
        json["defaultProvider"] = provider
        json["defaultModel"] = model

        do {
            let data = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try writeAtomically(data: HarnessRegistrar.newlineTerminated(data), to: path)
            return nil
        } catch {
            return "pi settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Codex ("Local" picks a profile, "API" clears it)

    /// Points `codex-local` at a profile — a name matching an existing
    /// `~/.codex/<profile>.config.toml`. Verifies the file exists first: a
    /// pointer at a profile that is not there would silently produce
    /// "Local (nothing)" the next time someone runs `codex-local`.
    @discardableResult
    static func setCodexProfile(config: HarnessConfig, profile: String) -> String? {
        let profilePath = config.codexProfilePath(profile)
        guard FileManager.default.fileExists(atPath: profilePath) else {
            return "no such Codex profile file: \(profilePath)"
        }
        return writeEnvFile(atPath: config.resolvedCodexLocalProfilePath,
                            values: ["CODEX_PROFILE": profile])
    }

    /// "API": disarm `codex-local`. Bare `codex` was never touched by either
    /// state — there is no config-level default to restore, since the only
    /// mechanism Codex still supports for a non-default provider is the
    /// `--profile` flag, which `codex-local` supplies and plain `codex` never
    /// sees.
    @discardableResult
    static func clearCodexProfile(config: HarnessConfig) -> String? {
        writeEnvFile(atPath: config.resolvedCodexLocalProfilePath, values: ["CODEX_PROFILE": ""])
    }

    // MARK: - Claude Code ("Local" arms claude-local, "API" disarms it)

    @discardableResult
    static func setClaudeLocal(config: HarnessConfig, model: String, baseURL: String) -> String? {
        writeEnvFile(atPath: config.resolvedClaudeLocalModelPath,
                    values: ["ANTHROPIC_MODEL": model, "ANTHROPIC_BASE_URL": baseURL])
    }

    /// "API": disarm `claude-local` (it will refuse to run rather than guess).
    /// Bare `claude` — this orchestrating session's own process family — is
    /// untouched by construction: nothing here ever writes to `claude`'s own
    /// config or environment.
    @discardableResult
    static func clearClaudeLocal(config: HarnessConfig) -> String? {
        writeEnvFile(atPath: config.resolvedClaudeLocalModelPath,
                    values: ["ANTHROPIC_MODEL": "", "ANTHROPIC_BASE_URL": ""])
    }

    // MARK: - File helpers

    private static func readJSONObject(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Trivial `KEY=value` line format — no quoting/escaping needed since
    /// every value written here is a model id or a fixed local URL.
    private static func readEnvFile(atPath path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    @discardableResult
    private static func writeEnvFile(atPath path: String, values: [String: String]) -> String? {
        var lines = ["# Written by ModelBar — do not edit by hand, it will be overwritten."]
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)=\(value)")
        }
        do {
            try writeAtomically(data: Data((lines.joined(separator: "\n") + "\n").utf8), to: path)
            return nil
        } catch {
            return "writing \(path): \(error.localizedDescription)"
        }
    }

    /// Writes via a temp file in the same directory plus a rename, so a crash
    /// mid-write cannot leave the harness with a truncated config. Keeps one
    /// `.modelbar.bak` copy of the previous contents.
    private static func writeAtomically(data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Backup as a DOTFILE beside the original, not `<name>.modelbar.bak`.
        // Some of these files live in directories a backend scans for its own
        // configs (~/models is LocalAI's --models-path), and a visible sibling
        // there can be picked up as a bogus model entry. A leading dot keeps
        // the safety net without polluting the scan.
        if let existing = FileManager.default.contents(atPath: path) {
            let name = "." + url.lastPathComponent + ".modelbar.bak"
            try? existing.write(to: dir.appendingPathComponent(name))
        }
        let tmp = dir.appendingPathComponent(".modelbar-\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
