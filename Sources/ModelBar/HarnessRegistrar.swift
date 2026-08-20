import Foundation

/// Rewrites a single scalar key in a backend's own per-model config file.
///
/// This exists for context-window control on a backend ModelBar does not
/// launch. For ds4 and llama.cpp the size is a launch flag and ModelBar owns
/// the spawn, so the choice can simply be remembered until next start. LocalAI
/// is `managed: false` — nothing here ever starts it — so its `context_size:`
/// has to be written into `~/.localai/models/<name>.yaml` to have any effect.
///
/// Deliberately a one-key line rewrite rather than a YAML round-trip: these
/// files are hand-maintained and short, and re-emitting them through a
/// serialiser would reformat and reorder content the user owns. Only the
/// matching line changes; every other byte is preserved.
enum ContextFile {

    /// Replaces `<key>: <number>` in the option's file, or appends it when the
    /// key is absent. Returns nil on success, a message on failure.
    @discardableResult
    static func write(size: Int, option ctx: ContextOption) -> String? {
        guard let path = ctx.resolvedFile, let key = ctx.key else {
            return "context: no file configured"
        }
        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "context: cannot read \(path)"
        }
        let updated = replacing(key: key, with: size, in: original)
        do {
            try HarnessRegistrar.writeAtomically(data: Data(updated.utf8), to: path)
            return nil
        } catch {
            return "context: writing \(path): \(error.localizedDescription)"
        }
    }

    /// Pure transformation, so it can be exercised without touching a real
    /// config. Matches the key only at top level (no leading indentation), so a
    /// same-named key nested under some other mapping is left alone.
    static func replacing(key: String, with value: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            lines[i] = "\(key): \(value)"
            return lines.joined(separator: "\n")
        }
        // Absent: append, keeping exactly one trailing newline.
        var out = lines
        while let last = out.last, last.isEmpty { out.removeLast() }
        out.append("\(key): \(value)")
        out.append("")
        return out.joined(separator: "\n")
    }
}

/// Everything a harness needs to *define* a model, as opposed to merely
/// pointing at one it already knows.
///
/// Derived from the manifest's backend + model pair rather than being spelled
/// out per harness, so adding a model to the manifest is enough to make it
/// registrable everywhere its backend's wire formats allow. The alternative —
/// a per-harness provider block written by hand in the manifest — is the
/// six-files-to-edit problem this feature exists to remove, moved one level up.
struct HarnessRegistration: Sendable {
    /// Provider key, e.g. `ds4`. This is the identifier harnesses resolve an
    /// endpoint *from*, so it has to be stable and match across reads/writes.
    var providerId: String
    var providerLabel: String
    /// OpenAI-shaped base URL, `/v1` included.
    var openAIBaseURL: String
    /// Anthropic-shaped base URL, deliberately WITHOUT `/v1` — Claude Code
    /// appends `/v1/messages` itself, so a `/v1` suffix here yields `/v1/v1/…`.
    var anthropicBaseURL: String
    /// What the backend itself calls this model — the string that goes in the
    /// request body, which is often not the manifest's own model id.
    var modelName: String
    var contextLength: Int
    /// Local backends do not authenticate, but most clients refuse to send a
    /// request with no key at all, so a placeholder is required rather than
    /// optional.
    var apiKey: String = "none"
}

/// Writes model *definitions* into harness configs.
///
/// Separate from `HarnessControl`, which only ever moves a pointer between
/// models a harness already knows. Registration is the strictly more dangerous
/// half — it creates config structure — so it lives apart, writes through the
/// same atomic-with-backup path, and is deliberately idempotent: registering a
/// model that is already present rewrites its definition to match the manifest
/// rather than appending a duplicate.
///
/// Claude Code is absent by design. It is registered *only* through the
/// call-scoped `claude-local` wrapper, which needs no provider definition —
/// just ANTHROPIC_BASE_URL/ANTHROPIC_MODEL for one invocation. Nothing here
/// writes `~/.claude/settings.json` or changes what a bare `claude` does,
/// because Claude Code sessions orchestrating this very work are themselves
/// plain `claude` processes and a global redirect would hijack them mid-run.
enum HarnessRegistrar {

    // MARK: - Codex

    /// Provider ids Codex reserves for its own built-ins.
    ///
    /// Redefining one is not a soft failure — Codex rejects the config outright
    /// and every subsequent invocation dies, including ones unrelated to local
    /// models. `ollama` is the one that bit this project for real. The list is
    /// deliberately generous: colliding with a built-in is unrecoverable from
    /// inside the app, whereas an unnecessary alias costs nothing but a
    /// slightly uglier provider key.
    static let codexReservedProviderIDs: Set<String> = [
        "openai", "oss", "ollama", "azure", "anthropic", "claude", "gemini",
        "google", "mistral", "deepseek", "xai", "grok", "groq", "openrouter",
        "arceeai", "baseten", "cohere", "together", "fireworks", "perplexity",
    ]

    /// A provider key safe to define in `~/.codex/config.toml`. Reserved names
    /// get a `-local` suffix rather than an error: the user asked to register a
    /// model, and refusing over a name collision when a trivially safe
    /// alternative exists would be a worse answer than renaming.
    static func safeCodexProviderID(_ id: String) -> String {
        let lowered = id.lowercased()
        guard codexReservedProviderIDs.contains(lowered) else { return id }
        return "\(lowered)-local"
    }

    /// Creates `~/.codex/<profile>.config.toml` and ensures a matching
    /// `[model_providers.<id>]` block exists in `~/.codex/config.toml`.
    ///
    /// `wire_api` is always `"responses"`. Codex 0.148 removed `"chat"`, so
    /// there is no second option to choose between — which is exactly why a
    /// model whose backend does not serve `/v1/responses` must never reach this
    /// function. Eligibility is enforced by the caller against the backend's
    /// declared `apis`.
    @discardableResult
    static func registerCodex(config: HarnessConfig,
                              profile: String,
                              registration reg: HarnessRegistration) -> String? {
        let providerId = safeCodexProviderID(reg.providerId)

        // 1. The profile file: which model, via which provider.
        let profilePath = config.codexProfilePath(profile)
        let profileBody = """
        # Written by ModelBar. Registers \(reg.modelName) via the \
        \(providerId) provider.
        # Use with:  codex --profile \(profile)
        model = "\(tomlEscape(reg.modelName))"
        model_provider = "\(tomlEscape(providerId))"

        """
        do {
            try writeAtomically(data: Data(profileBody.utf8), to: profilePath)
        } catch {
            return "codex profile: \(error.localizedDescription)"
        }

        // 2. The provider block in the main config, added only when absent.
        //    An existing block is left exactly as it is: config.toml holds a
        //    great deal the user owns (plugins, MCP servers, notify hooks), and
        //    rewriting a provider the user may have hand-tuned is not worth the
        //    convenience of keeping it in sync with the manifest.
        let mainPath = config.resolvedCodexConfigPath
        var text = (try? String(contentsOfFile: mainPath, encoding: .utf8)) ?? ""
        if tomlHasTable(text, "model_providers.\(providerId)") {
            return nil
        }
        let block = """

        [model_providers.\(providerId)]
        name = "\(tomlEscape(reg.providerLabel))"
        base_url = "\(tomlEscape(reg.openAIBaseURL))"
        wire_api = "responses"

        """
        if !text.hasSuffix("\n") && !text.isEmpty { text += "\n" }
        text += block
        do {
            try writeAtomically(data: Data(text.utf8), to: mainPath)
        } catch {
            return "codex config.toml: \(error.localizedDescription)"
        }
        return nil
    }

    /// True when `[<table>]` is already declared. Matches the header line only,
    /// so a key elsewhere that merely mentions the name cannot read as a table.
    static func tomlHasTable(_ text: String, _ table: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { continue }
            let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            // Tolerate the quoted spelling Codex also accepts.
            if inner == table { return true }
            let unquoted = inner.replacingOccurrences(of: "\"", with: "")
            if unquoted == table { return true }
        }
        return false
    }

    private static func tomlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Pi

    /// Adds a provider + model to `~/.pi/agent/models.json` and enables the
    /// model in `~/.pi/agent/settings.json`.
    ///
    /// Pi needs both halves: models.json is the definition (where to send the
    /// request), enabledModels is what the Ctrl+P picker will actually offer.
    /// Writing only the first produces a model that exists and can never be
    /// selected, which is the sort of half-registration this feature is meant
    /// to eliminate.
    @discardableResult
    static func registerPi(config: HarnessConfig,
                           registration reg: HarnessRegistration) -> String? {
        // --- models.json -------------------------------------------------
        let modelsPath = config.resolvedPiModelsPath
        var root = readJSONObject(atPath: modelsPath) ?? [:]
        var providers = root["providers"] as? [String: Any] ?? [:]
        var provider = providers[reg.providerId] as? [String: Any] ?? [:]

        provider["baseUrl"] = reg.openAIBaseURL
        provider["api"] = "openai-completions"
        provider["apiKey"] = reg.apiKey

        // Preserve sibling models already registered under this provider;
        // replace only the entry for this model id.
        var entries = provider["models"] as? [[String: Any]] ?? []
        entries.removeAll { ($0["id"] as? String) == reg.modelName }
        entries.append(["id": reg.modelName])
        provider["models"] = entries

        providers[reg.providerId] = provider
        root["providers"] = providers

        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try writeAtomically(data: newlineTerminated(data), to: modelsPath)
        } catch {
            return "pi models.json: \(error.localizedDescription)"
        }

        // --- settings.json ------------------------------------------------
        let settingsPath = config.resolvedPiSettingsPath
        guard var settings = readJSONObject(atPath: settingsPath) else {
            return "cannot read \(settingsPath) as JSON"
        }
        var enabled = settings["enabledModels"] as? [String] ?? []
        if !enabled.contains(reg.modelName) {
            enabled.append(reg.modelName)
            settings["enabledModels"] = enabled
            do {
                let data = try JSONSerialization.data(withJSONObject: settings,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try writeAtomically(data: newlineTerminated(data), to: settingsPath)
            } catch {
                return "pi settings.json: \(error.localizedDescription)"
            }
        }
        return nil
    }

    // MARK: - Hermes

    /// Adds or replaces a provider block under `providers:` in
    /// `~/.hermes/config.yaml`.
    ///
    /// Written as a targeted text edit rather than through `hermes config set`,
    /// which looked like the right tool and is not: it stores a list value as a
    /// *quoted string*, so `hermes config set providers.x.models '["a"]'`
    /// yields `models: '["a"]'` and Hermes then has a provider with no usable
    /// model list. Verified against the real binary on a backed-up copy of the
    /// config rather than assumed. Scalars would have been fine; the `models:`
    /// sequence is the one key that must be a real list, so the whole block is
    /// written here instead of splitting the write across two mechanisms.
    ///
    /// Hermes resolves the endpoint from the provider KEY via `model.provider`,
    /// so there is deliberately no top-level `model.base_url` written anywhere.
    @discardableResult
    static func registerHermes(config: HarnessConfig,
                               registration reg: HarnessRegistration) -> String? {
        let path = config.resolvedHermesConfigPath
        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "cannot read \(path)"
        }
        let updated = upsertHermesProvider(in: original, registration: reg)
        do {
            try writeAtomically(data: Data(updated.utf8), to: path)
            return nil
        } catch {
            return "hermes config.yaml: \(error.localizedDescription)"
        }
    }

    /// The provider block as Hermes writes them: 2-space provider key,
    /// 4-space keys, sequence items at 4 spaces with `- `.
    static func hermesProviderBlock(_ reg: HarnessRegistration) -> [String] {
        [
            "  \(reg.providerId):",
            "    name: \(yamlScalar(reg.providerId))",
            "    base_url: \(yamlScalar(reg.openAIBaseURL))",
            "    api_key: \(yamlScalar(reg.apiKey))",
            "    models:",
            "    - \(yamlScalar(reg.modelName))",
            "    default_model: \(yamlScalar(reg.modelName))",
            "    context_length: \(reg.contextLength)",
        ]
    }

    /// Inserts or replaces one provider under a top-level `providers:` mapping,
    /// leaving every other line of the file byte-identical.
    ///
    /// Exposed rather than private so the transformation can be exercised
    /// directly on sample text — rewriting a 200-line config the user depends
    /// on is not something to verify only by running it against the real file.
    static func upsertHermesProvider(in text: String,
                                     registration reg: HarnessRegistration) -> String {
        var lines = text.components(separatedBy: "\n")
        let block = hermesProviderBlock(reg)

        guard let providersIndex = lines.firstIndex(where: {
            $0 == "providers:" || $0.hasPrefix("providers:")
                && !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == "providers:"
        }) else {
            // No providers mapping at all — create one at the end.
            var out = lines
            if let last = out.last, last.isEmpty { out.removeLast() }
            out.append("providers:")
            out.append(contentsOf: block)
            out.append("")
            return out.joined(separator: "\n")
        }

        // Extent of the providers mapping: every following line that is
        // indented or blank. A blank line inside the block is tolerated; a
        // non-indented, non-blank line ends it.
        var end = providersIndex + 1
        while end < lines.count {
            let line = lines[end]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { end += 1; continue }
            if line.hasPrefix(" ") || line.hasPrefix("\t") { end += 1; continue }
            break
        }

        // Is this provider already declared? Provider keys sit at exactly two
        // spaces of indent.
        let key = "  \(reg.providerId):"
        if let start = (providersIndex + 1..<end).first(where: { lines[$0] == key }) {
            // Replace through to the next 2-space key or the end of the block.
            var stop = start + 1
            while stop < end {
                let line = lines[stop]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { stop += 1; continue }
                let indent = line.prefix { $0 == " " }.count
                if indent <= 2 { break }
                stop += 1
            }
            lines.replaceSubrange(start..<stop, with: block)
        } else {
            lines.insert(contentsOf: block, at: end)
        }
        return lines.joined(separator: "\n")
    }

    /// Quotes a YAML scalar when leaving it bare would change its meaning.
    /// Provider labels carry parentheses and colons ("ds4 (DeepSeek-V4-Flash,
    /// local)"), and a bare `a: b` inside a value silently becomes a nested
    /// mapping.
    static func yamlScalar(_ s: String) -> String {
        let needsQuoting = s.isEmpty
            || s.contains(": ") || s.hasSuffix(":")
            || s.contains(" #")
            || s.first.map { "-?:,[]{}#&*!|>'\"%@`".contains($0) } ?? false
            || s.first?.isWhitespace == true || s.last?.isWhitespace == true
            || ["true", "false", "null", "yes", "no", "on", "off", "~"]
                .contains(s.lowercased())
            || Double(s) != nil
        guard needsQuoting else { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Shared file helpers

    /// Config files are line-oriented as far as diffs, editors and version
    /// control are concerned; JSONSerialization does not terminate its output.
    static func newlineTerminated(_ data: Data) -> Data {
        guard data.last != 0x0A else { return data }
        return data + Data([0x0A])
    }

    static func readJSONObject(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Same contract as `HarnessControl`'s writer: temp file in the same
    /// directory plus a rename, keeping one `.modelbar.bak` of the previous
    /// contents. Duplicated deliberately — both are small, and a shared
    /// dependency between the pointer path and the definition path would make
    /// the more dangerous one easier to change by accident.
    static func writeAtomically(data: Data, to path: String) throws {
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
