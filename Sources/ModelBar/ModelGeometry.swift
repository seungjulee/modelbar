import Foundation

/// A model's trained context ceiling and KV-cache cost, read from the model's
/// own metadata rather than hardcoded per model in the manifest.
///
/// Reading it means a newly-added model gets correct bounds automatically, and
/// — more importantly — correct ones. Hand-picked numbers were how this ended
/// up offering a 32K ceiling to models trained for 128K and 256K.
struct ModelGeometry: Sendable, Equatable {
    /// Largest context the model was trained for. Exceeding it does not error,
    /// it silently degrades output, so nothing above this is ever offered.
    var contextCeiling: Int
    /// KV cache bytes per token at f16, counting only layers that actually
    /// keep a growing cache. Zero when the geometry could not be determined.
    var kvBytesPerTokenF16: Double
    /// Where these numbers came from, for the tooltip.
    var source: String
    /// Anything about the attention layout worth surfacing — chiefly the
    /// hybrid-attention split, which is the difference between a correct KV
    /// estimate and one that is wrong by 4x.
    var note: String?

    /// KV cache size in GB at a given context length.
    func kvGB(at tokens: Int) -> Double {
        guard kvBytesPerTokenF16 > 0 else { return 0 }
        return kvBytesPerTokenF16 * Double(tokens) / 1_073_741_824
    }
}

enum ModelGeometryReader {

    /// Reads geometry for a model, preferring an explicit `metadataPath` and
    /// otherwise auto-detecting from the model's `requires` list — an MLX
    /// `config.json` or a `.gguf` is enough, and every current entry names one.
    static func read(for model: ModelSpec) -> ModelGeometry? {
        let candidates: [String]
        if let explicit = model.metadataPath?.expandingTilde {
            candidates = [explicit]
        } else {
            candidates = model.resolvedRequires
        }
        if let cfg = candidates.first(where: { $0.hasSuffix("config.json") }),
           let g = fromMLXConfig(path: cfg) {
            return g
        }
        if let gguf = candidates.first(where: { $0.hasSuffix(".gguf") }),
           let g = fromGGUF(path: gguf) {
            return g
        }
        return nil
    }

    // MARK: - MLX (config.json)

    /// Transformers-style `config.json`, as MLX ships alongside its weights.
    ///
    /// Handles hybrid attention, which matters a great deal here. Qwen3.8-27B
    /// declares `layer_types` with only 16 of its 64 layers as
    /// `full_attention`; the other 48 are linear-attention layers whose state
    /// is constant-size and does not grow with context. Charging all 64 layers
    /// overestimates its KV cache by 4x — the difference between "256K needs
    /// 69 GB and is out of reach without quantised KV" and the truth, which is
    /// 16 GB and fits comfortably at f16.
    static func fromMLXConfig(path: String) -> ModelGeometry? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // Multimodal configs nest the language model's geometry.
        let cfg = (root["text_config"] as? [String: Any]) ?? root

        guard let ceiling = int(cfg["max_position_embeddings"]), ceiling > 0 else { return nil }

        var note: String?
        let totalLayers = int(cfg["num_hidden_layers"]) ?? 0
        var cacheLayers = totalLayers
        if let types = cfg["layer_types"] as? [String] {
            let full = types.filter { $0.contains("full") }.count
            if full > 0 {
                cacheLayers = full
                note = "\(full) of \(types.count) layers full-attention; "
                     + "the rest are linear-attention with constant-size state"
            }
        }

        let kvHeads = int(cfg["num_key_value_heads"]) ?? int(cfg["num_attention_heads"]) ?? 0
        var headDim = int(cfg["head_dim"]) ?? 0
        if headDim == 0, let hidden = int(cfg["hidden_size"]),
           let heads = int(cfg["num_attention_heads"]), heads > 0 {
            headDim = hidden / heads
        }

        // K and V, two bytes each at f16.
        let bytesPerToken = Double(cacheLayers * kvHeads * headDim * 2 * 2)
        return ModelGeometry(contextCeiling: ceiling,
                             kvBytesPerTokenF16: max(0, bytesPerToken),
                             source: "config.json", note: note)
    }

    // MARK: - GGUF

    /// `<arch>.context_length` plus the attention dimensions, from the GGUF
    /// header. Only the header is read, never the tensor data.
    static func fromGGUF(path: String) -> ModelGeometry? {
        // Two passes: the architecture prefixes every other key we need.
        let archMeta = GGUFHeader.readMetadata(path: path, wanted: ["general.architecture"])
        guard let arch = archMeta["general.architecture"] else { return nil }

        let keys: Set<String> = [
            "\(arch).context_length",
            "\(arch).block_count",
            "\(arch).attention.head_count",
            "\(arch).attention.head_count_kv",
            "\(arch).attention.key_length",
            "\(arch).attention.value_length",
            "\(arch).embedding_length",
        ]
        let m = GGUFHeader.readMetadata(path: path, wanted: keys)
        func v(_ suffix: String) -> Int? { m["\(arch).\(suffix)"].flatMap { Int($0) } }

        guard let ceiling = v("context_length"), ceiling > 0 else { return nil }
        let blocks = v("block_count") ?? 0
        let kvHeads = v("attention.head_count_kv") ?? v("attention.head_count") ?? 0
        var keyLen = v("attention.key_length") ?? 0
        var valLen = v("attention.value_length") ?? 0
        if keyLen == 0, let embed = v("embedding_length"), let heads = v("attention.head_count"),
           heads > 0 {
            keyLen = embed / heads
            valLen = keyLen
        }
        if valLen == 0 { valLen = keyLen }

        let bytesPerToken = Double(blocks * kvHeads * (keyLen + valLen) * 2)
        return ModelGeometry(contextCeiling: ceiling,
                             kvBytesPerTokenF16: max(0, bytesPerToken),
                             source: "GGUF header", note: nil)
    }

    private static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

/// One selectable context size, priced.
struct ContextChoice: Sendable, Identifiable, Equatable {
    var size: Int
    /// Estimated KV cache at this size, GB. Zero when unknown or when the
    /// backend does not allocate KV up front.
    var kvGB: Double
    /// Total estimated resident cost — weights plus KV.
    var totalGB: Double
    /// Whether this choice fits the memory budget alongside what else is
    /// loaded right now.
    var fits: Bool
    var id: Int { size }

    /// "256K" / "128K" / "200K" — rounded, since the exact token count is
    /// noise at a glance.
    ///
    /// Binary and decimal both appear in practice and neither reads correctly
    /// under the other's divisor: a derived ladder is powers of two (262144 is
    /// "256K"), while a hand-written one tends to be round decimals (ds4's
    /// 200000 is "200K", and dividing it by 1024 would render it "195K").
    var label: String {
        if size % 1_048_576 == 0 { return "\(size / 1_048_576)M" }
        if size % 1_000_000 == 0 { return "\(size / 1_000_000)M" }
        if size % 1024 == 0 { return "\(size / 1024)K" }
        if size % 1000 == 0 { return "\(size / 1000)K" }
        return size.formatted()
    }
}
