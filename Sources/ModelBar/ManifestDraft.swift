import Foundation

/// Turns a discovered model into a manifest entry.
///
/// `ModelDiscovery` deliberately stops at detection, and its reasoning holds:
/// serve flags cannot be guessed. Every model in this manifest needed something
/// that no scanner could have known — an `--image-min-tokens` the loader only
/// warns about, a measured `gbPer100k` that keeps a valid load from being
/// refused, a drafter that turned out to be a regression.
///
/// So this does not pretend to produce a finished entry. It fills in what is
/// genuinely derivable — path, size, backend, served name, context ceiling read
/// from the model's own metadata — and marks the entry `draft` with a note
/// naming what a human still has to decide. A draft is skipped by auto-start and
/// carries its provenance, so an unreviewed guess can never quietly become the
/// thing that launches an 80 GB process.
enum ManifestDraft {

    /// Everything the caller needs to report what happened, without this type
    /// needing to know how the CLI or the menu wants to phrase it.
    struct Result: Sendable {
        var added: [String] = []
        var skipped: [(name: String, reason: String)] = []
        var backupPath: String?
    }

    /// Adds a draft entry for each discovered item whose name matches `filter`.
    ///
    /// Writes through a temp file in the same directory and renames into place,
    /// keeping one dotfile backup — the same discipline as every other config
    /// write here, and for the same reason: a half-written manifest is worse
    /// than no change at all.
    static func add(_ items: [DiscoveredItem],
                    matching filter: String?,
                    manifestPath: String,
                    manifest: Manifest?) throws -> Result {
        var result = Result()

        let wanted = items.filter { item in
            guard let filter, !filter.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(filter)
                || item.id.localizedCaseInsensitiveContains(filter)
        }
        guard !wanted.isEmpty else { return result }

        let url = URL(fileURLWithPath: (manifestPath as NSString).expandingTildeInPath)
        let raw = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw Err.unreadable
        }
        let existingIds = Set(models.compactMap { $0["id"] as? String })

        var entries: [[String: Any]] = []
        for item in wanted {
            guard let path = item.path else {
                result.skipped.append((item.name,
                    "\(item.source.rawValue) inventory has no local path to reference"))
                continue
            }
            // Speculation support files sit in the same directory as real
            // weights and look identical to a size-and-path scan, but they are
            // drafters — they are named by another model's `drafters` entry and
            // cannot be served alone. Their own GGUF architecture says so.
            if isSupportFile(item) {
                result.skipped.append((item.name,
                    "\(item.detail) is a speculation support file, not a servable "
                    + "model — attach it to a model's drafters instead"))
                continue
            }
            guard let backendId = backend(for: item, in: manifest) else {
                result.skipped.append((item.name,
                    "no \(item.source.rawValue) backend in the manifest to attach it to"))
                continue
            }
            var id = slug(item.name)
            if existingIds.contains(id) || entries.contains(where: { $0["id"] as? String == id }) {
                result.skipped.append((item.name, "manifest already has a model with id \(id)"))
                continue
            }
            if id.isEmpty { id = "model-\(abs(path.hashValue))" }
            entries.append(entry(for: item, id: id, path: path, backendId: backendId,
                                 manifest: manifest))
            result.added.append(id)
        }
        guard !entries.isEmpty else { return result }

        // Splice the new entries into the existing text rather than
        // re-serializing the document. Re-serializing round-trips correctly but
        // reformats everything — Foundation sorts keys and uses its own spacing,
        // which turned a six-entry append into a 761-line diff and threw away
        // the hand-maintained ordering. A manifest people edit and review has to
        // stay byte-identical everywhere the change did not touch.
        guard let text = String(data: raw, encoding: .utf8),
              let insertAt = endOfModelsArray(in: text) else {
            throw Err.unreadable
        }
        let indent = detectIndent(text)
        // The prefix ends with the newline and padding that precede the closing
        // bracket; trimming it puts the comma on the last entry's line, where a
        // hand-written file would have it, rather than on a line of its own.
        var head = String(text.prefix(upTo: insertAt))
        let closingPad = String(head.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        while let last = head.last, last == "\n" || last == " " || last == "\t" {
            head.removeLast()
        }
        var addition = ""
        for e in entries {
            addition += ",\n" + render(e, indent: indent, level: 2)
        }
        let out = Data((head + addition + "\n" + closingPad
                        + text.suffix(from: insertAt)).utf8)

        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
        result.backupPath = backup.path

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).new")
        try out.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return result
    }

    // MARK: - Entry construction

    private static func entry(for item: DiscoveredItem, id: String, path: String,
                              backendId: String, manifest: Manifest?) -> [String: Any] {
        let home = NSHomeDirectory()
        let tildePath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let gb = Int((Double(item.sizeBytes) / 1_073_741_824).rounded())
        let port = manifest?.backends.first { $0.id == backendId }?.port ?? 0

        var e: [String: Any] = [
            "id": id,
            "shortName": shortName(from: id),
            "displayName": item.name,
            "backendId": backendId,
            "estimatedGB": gb,
            "port": port,
            "draft": true,
            "notes": draftNote(for: item),
            "requires": [tildePath],
            "metadataPath": tildePath,
        ]

        // The one thing that *is* safely derivable: the trained context ceiling,
        // read from the model's own metadata by the same reader the rest of the
        // app uses. Guessing this is what once offered 32K to a 256K model.
        if let g = ModelGeometryReader.read(candidates: [path]), g.contextCeiling > 0 {
            e["contextLength"] = min(g.contextCeiling, 32768)
            e["context"] = [
                "options": contextOptions(ceiling: g.contextCeiling),
                "defaultSize": min(g.contextCeiling, 32768),
            ] as [String: Any]
        }
        return e
    }

    /// Offers the usual power-of-two rungs, never above what the model was
    /// trained for.
    private static func contextOptions(ceiling: Int) -> [Int] {
        [32768, 65536, 131072, 262144].filter { $0 <= ceiling }
    }

    private static func draftNote(for item: DiscoveredItem) -> String {
        var parts = ["DRAFT — added by `discover --add` from \(item.detail); "
                     + "review before use"]
        switch item.source {
        case .gguf:
            parts.append("needs a start.argv (llama-server/ds4-server flags), and a "
                         + "--mmproj/--vision encoder if this model has one")
        case .mlx:
            parts.append("needs a start.argv; MLX serves lazily, so leave "
                         + "context.reservesKVUpFront unset")
        default:
            parts.append("needs a start.argv")
        }
        parts.append("estimatedGB is file size on disk, not measured residency; "
                     + "a model with compressed-attention KV also needs a measured "
                     + "gbPer100k or the budget guard will refuse valid loads")
        return parts.joined(separator: " · ")
    }

    /// A drafter/MTP sidecar rather than a model that can be served on its own.
    private static func isSupportFile(_ item: DiscoveredItem) -> Bool {
        let d = item.detail.lowercased()
        return d.hasSuffix("-dspark") || d.hasSuffix("-mtp") || d.hasSuffix("-draft")
    }

    private static func backend(for item: DiscoveredItem, in manifest: Manifest?) -> String? {
        guard let manifest else { return nil }
        let preferred: [String]
        switch item.source {
        case .gguf:   preferred = ["llamacpp", "ds4", "localai"]
        case .mlx:    preferred = ["mlx"]
        case .ollama: preferred = ["ollama"]
        case .comfyui: preferred = ["comfyui"]
        }
        let have = Set(manifest.backends.map(\.id))
        return preferred.first { have.contains($0) }
    }

    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-"); lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }

    private static func shortName(from id: String) -> String {
        let parts = id.split(separator: "-").prefix(2)
        return parts.map { $0.prefix(4).uppercased() }.joined()
    }

    // MARK: - Text splicing

    /// Index of the `]` that closes the top-level `models` array.
    ///
    /// Scans with depth and string awareness rather than searching for a
    /// literal, because paths and notes in this file contain brackets and
    /// escaped quotes.
    private static func endOfModelsArray(in text: String) -> String.Index? {
        guard let keyRange = text.range(of: "\"models\"") else { return nil }
        guard let open = text[keyRange.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < text.endIndex {
            let ch = text[i]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "[" { depth += 1 }
                else if ch == "]" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// The file's own indent unit, so appended entries match what is already
    /// there instead of imposing a different style.
    private static func detectIndent(_ text: String) -> String {
        for line in text.split(separator: "\n").dropFirst() {
            let spaces = line.prefix { $0 == " " }
            if !spaces.isEmpty { return String(spaces) }
        }
        return " "
    }

    /// Renders one entry as JSON in a fixed, readable field order.
    ///
    /// Hand-rolled rather than `JSONSerialization` because that sorts keys, and
    /// an entry whose `id` sits between `estimatedGB` and `metadataPath` reads
    /// nothing like the entries around it.
    private static func render(_ e: [String: Any], indent: String, level: Int) -> String {
        let pad = String(repeating: indent, count: level)
        let inner = String(repeating: indent, count: level + 1)
        let order = ["id", "shortName", "displayName", "backendId", "estimatedGB",
                     "port", "draft", "notes", "requires", "metadataPath",
                     "contextLength", "context"]
        var lines: [String] = []
        for key in order {
            guard let v = e[key] else { continue }
            lines.append("\(inner)\(quote(key)): \(literal(v, indent: indent, level: level + 1))")
        }
        return pad + "{\n" + lines.joined(separator: ",\n") + "\n" + pad + "}"
    }

    private static func literal(_ v: Any, indent: String, level: Int) -> String {
        let inner = String(repeating: indent, count: level + 1)
        let pad = String(repeating: indent, count: level)
        switch v {
        case let b as Bool:   return b ? "true" : "false"
        case let i as Int:    return String(i)
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        case let s as String: return quote(s)
        case let a as [Any]:
            guard !a.isEmpty else { return "[]" }
            let items = a.map { inner + literal($0, indent: indent, level: level + 1) }
            return "[\n" + items.joined(separator: ",\n") + "\n" + pad + "]"
        case let d as [String: Any]:
            guard !d.isEmpty else { return "{}" }
            let items = d.keys.sorted().map {
                inner + quote($0) + ": " + literal(d[$0]!, indent: indent, level: level + 1)
            }
            return "{\n" + items.joined(separator: ",\n") + "\n" + pad + "}"
        default: return "null"
        }
    }

    /// JSON string escaping. Non-ASCII is left as UTF-8 on purpose: the notes in
    /// this file use "·" and escaping it to \\u00b7 makes every touched line
    /// show up as a change.
    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\t":  out += "\\t"
            case "\r":  out += "\\r"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }

    enum Err: Error, CustomStringConvertible {
        case unreadable
        var description: String {
            switch self {
            case .unreadable: return "manifest is not an object with a models array"
            }
        }
    }
}
