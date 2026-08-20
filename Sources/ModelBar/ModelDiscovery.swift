import Foundation

/// Something found on disk or in a backend's own inventory that no manifest
/// entry currently references.
///
/// This is detection, not configuration: correctly guessing serve flags for
/// an arbitrary new model is not realistic (this whole session was spent
/// hand-tuning mmproj paths, drafter flags, and context sizing per model) —
/// what is realistic and valuable is never letting something sit on disk
/// invisibly. Same principle as scanning `~/.lmstudio/models/`: list what is
/// there, do not try to launch any of it.
struct DiscoveredItem: Sendable, Identifiable, Equatable {
    var id: String
    var source: Source
    var name: String
    var sizeBytes: UInt64
    var detail: String

    enum Source: String, Sendable { case mlx, gguf, comfyui, ollama }
}

enum ModelDiscovery {

    /// Runs every scanner and filters out anything a manifest model already
    /// references. Directory walks and GGUF header reads have real I/O cost,
    /// so this is meant to be called on a slow cadence (menu-open / manual
    /// rescan), never on the 1s live-poll path.
    static func scan(manifest: Manifest?, comfyBackend: BackendSpec?) async -> [DiscoveredItem] {
        let configuredPaths = configuredPathSet(manifest)

        // MLX/GGUF do blocking filesystem I/O (directory walks, GGUF header
        // reads) — run them off the main actor so a large ~/models tree
        // cannot stall the UI. ComfyUI/Ollama are network calls, already
        // non-blocking, run concurrently alongside.
        async let fileScan = Task.detached(priority: .utility) { () -> [DiscoveredItem] in
            scanMLX(excluding: configuredPaths) + scanGGUF(excluding: configuredPaths)
        }.value
        async let comfy: [DiscoveredItem] = comfyBackend != nil
            ? await scanComfyUI(backend: comfyBackend!, excluding: configuredPaths) : []
        async let ollama = scanOllama(excluding: configuredPaths)

        return await fileScan + comfy + ollama
    }

    /// Every filesystem path a manifest model's `requires`/start argv
    /// mentions, lowercased, used as a substring test against a candidate's
    /// own path — good enough to say "something already covers this" without
    /// needing an exact match against one particular file in a directory.
    private static func configuredPathSet(_ manifest: Manifest?) -> Set<String> {
        guard let manifest else { return [] }
        var paths = Set<String>()
        for model in manifest.models {
            for p in model.resolvedRequires { paths.insert(resolvedLower(p)) }
            if let argv = model.start?.resolvedArgv {
                for a in argv where a.contains("/") { paths.insert(resolvedLower(a)) }
            }
        }
        return paths
    }

    /// Lowercased, symlink-resolved path. Several manifest entries reference
    /// weights through a symlink farm (`~/.pi/ds4/support/gguf/*.gguf` →
    /// `~/models/gguf/...`) rather than the real path directly — without
    /// resolving through that, the scanner would flag ds4's own weights as
    /// "unconfigured" purely because it walks the real tree under
    /// `~/models/gguf`, never the symlink directory.
    private static func resolvedLower(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath.lowercased()
    }

    private static func isConfigured(_ path: String, in set: Set<String>) -> Bool {
        let lower = resolvedLower(path)
        return set.contains { $0.contains(lower) || lower.contains($0) }
    }

    // MARK: - MLX

    /// A candidate is any directory containing a `config.json` under
    /// `~/models/mlx`, at up to two levels deep (matches the layout seen in
    /// practice: `<repo>/config.json` directly, or `<repo>/<variant>/config.json`
    /// for a multi-quant repo like the Qwen3.8 MLX downloads).
    private static func scanMLX(excluding configured: Set<String>) -> [DiscoveredItem] {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("models/mlx")
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var out: [DiscoveredItem] = []
        for repo in repos {
            let repoPath = (root as NSString).appendingPathComponent(repo)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else { continue }

            var candidateDirs = [repoPath]
            if let subs = try? fm.contentsOfDirectory(atPath: repoPath) {
                candidateDirs += subs.map { (repoPath as NSString).appendingPathComponent($0) }
            }

            for dir in candidateDirs {
                let configPath = (dir as NSString).appendingPathComponent("config.json")
                guard fm.fileExists(atPath: configPath) else { continue }
                guard !isConfigured(dir, in: configured) else { continue }

                let arch = readArchitectures(configPath)
                let size = directorySize(dir)
                out.append(DiscoveredItem(
                    id: "mlx:\(dir)", source: .mlx,
                    name: dir == repoPath ? repo : "\(repo)/\((dir as NSString).lastPathComponent)",
                    sizeBytes: size,
                    detail: arch ?? "MLX model"))
            }
        }
        return out
    }

    private static func readArchitectures(_ configPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let archs = json["architectures"] as? [String], let first = archs.first { return first }
        if let modelType = json["model_type"] as? String { return modelType }
        return nil
    }

    private static func directorySize(_ path: String) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        for case let file as String in enumerator {
            let full = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? NSNumber {
                total += size.uint64Value
            }
        }
        return total
    }

    // MARK: - GGUF

    private static func scanGGUF(excluding configured: Set<String>) -> [DiscoveredItem] {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("models/gguf")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }

        var out: [DiscoveredItem] = []
        for case let relPath as String in enumerator {
            guard relPath.hasSuffix(".gguf") else { continue }
            let full = (root as NSString).appendingPathComponent(relPath)
            guard !isConfigured(full, in: configured) else { continue }

            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.uint64Value ?? 0
            let meta = GGUFHeader.readMetadata(path: full)
            let arch = meta["general.architecture"] ?? "gguf"
            let name = meta["general.name"] ?? (full as NSString).lastPathComponent
            out.append(DiscoveredItem(
                id: "gguf:\(full)", source: .gguf, name: name, sizeBytes: size,
                detail: arch))
        }
        return out
    }

    // MARK: - ComfyUI

    /// Queries the specific loader nodes that name model files, rather than
    /// the full `/object_info` (which dumps every installed node's schema —
    /// megabytes of unrelated data for a handful of file lists).
    private static func scanComfyUI(backend: BackendSpec,
                                    excluding configured: Set<String>) async -> [DiscoveredItem] {
        guard let base = backend.url("") else { return [] }
        let nodesAndFields: [(node: String, field: String, kind: String)] = [
            ("CheckpointLoaderSimple", "ckpt_name", "checkpoint"),
            ("UNETLoader", "unet_name", "diffusion model"),
            ("CLIPLoader", "clip_name", "text encoder"),
            ("VAELoader", "vae_name", "VAE"),
        ]

        var seen = Set<String>()
        var out: [DiscoveredItem] = []
        for (node, field, kind) in nodesAndFields {
            guard let url = URL(string: base.absoluteString + "object_info/\(node)"),
                  let json = await Probe.getJSON(url),
                  let nodeInfo = json[node] as? [String: Any],
                  let input = nodeInfo["input"] as? [String: Any],
                  let required = input["required"] as? [String: Any],
                  let fieldSpec = required[field] as? [Any],
                  let files = fieldSpec.first as? [String] else { continue }

            for file in files {
                guard seen.insert(file).inserted else { continue }
                guard !isConfigured(file, in: configured) else { continue }
                out.append(DiscoveredItem(
                    id: "comfyui:\(file)", source: .comfyui, name: file, sizeBytes: 0,
                    detail: kind))
            }
        }
        return out
    }

    // MARK: - Ollama

    /// `/api/tags` lists every locally-installed model, unlike `/api/ps`
    /// (currently-resident only, what the live telemetry already uses).
    private static func scanOllama(excluding configured: Set<String>) async -> [DiscoveredItem] {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags"),
              let json = await Probe.getJSON(url),
              let models = json["models"] as? [[String: Any]] else { return [] }

        var out: [DiscoveredItem] = []
        for m in models {
            guard let name = m["name"] as? String else { continue }
            guard !isConfigured(name, in: configured) else { continue }
            let size = (m["size"] as? NSNumber)?.uint64Value ?? 0
            let family = (m["details"] as? [String: Any])?["family"] as? String
            out.append(DiscoveredItem(
                id: "ollama:\(name)", source: .ollama, name: name, sizeBytes: size,
                detail: family ?? "ollama model"))
        }
        return out
    }
}

/// Minimal GGUF header reader: enough to pull `general.architecture` and
/// `general.name` without touching the (often tens-of-GB) tensor data that
/// follows the metadata section.
enum GGUFHeader {
    private enum ValueType: UInt32 {
        case uint8 = 0, int8, uint16, int16, uint32, int32, float32, bool
        case string, array, uint64, int64, float64
    }

    static func readMetadata(path: String) -> [String: String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }

        var out: [String: String] = [:]
        let reader = ByteReader(handle: handle)

        guard reader.readData(4).map({ String(decoding: $0, as: UTF8.self) }) == "GGUF" else {
            return [:]
        }
        guard reader.readUInt32() != nil else { return [:] }          // version
        guard reader.readUInt64() != nil else { return [:] }          // tensor_count
        guard let kvCount = reader.readUInt64() else { return [:] }

        // Only these two keys are worth the read; bail once both are found
        // rather than parsing the full (sometimes hundred-plus-entry) table.
        let wanted: Set<String> = ["general.architecture", "general.name"]
        var remaining = wanted

        for _ in 0..<kvCount {
            guard !remaining.isEmpty else { break }
            guard let key = reader.readGGUFString() else { break }
            guard let rawType = reader.readUInt32(), let type = ValueType(rawValue: rawType) else {
                break
            }
            if remaining.contains(key), type == .string {
                guard let value = reader.readGGUFString() else { break }
                out[key] = value
                remaining.remove(key)
            } else {
                guard reader.skip(type: type) else { break }
            }
        }
        return out
    }

    /// Sequential little-endian reader over a `FileHandle`, reading in small
    /// chunks so this never pulls a multi-gigabyte tensor section into memory
    /// — only the metadata header, which is at most a few hundred KB.
    private struct ByteReader {
        let handle: FileHandle

        func readData(_ count: Int) -> Data? {
            guard let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        func readUInt32() -> UInt32? {
            readData(4)?.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func readUInt64() -> UInt64? {
            readData(8)?.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        }
        func readGGUFString() -> String? {
            guard let len = readUInt64(), len < 1_000_000 else { return nil }
            guard let bytes = readData(Int(len)) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        /// Advances past one value of the given type without materialising it.
        func skip(type: ValueType) -> Bool {
            switch type {
            case .uint8, .int8, .bool: return readData(1) != nil
            case .uint16, .int16: return readData(2) != nil
            case .uint32, .int32, .float32: return readData(4) != nil
            case .uint64, .int64, .float64: return readData(8) != nil
            case .string: return readGGUFString() != nil
            case .array:
                guard let rawElem = readUInt32(), let elem = ValueType(rawValue: rawElem),
                      let count = readUInt64() else { return false }
                for _ in 0..<count { guard skip(type: elem) else { return false } }
                return true
            }
        }
    }
}
