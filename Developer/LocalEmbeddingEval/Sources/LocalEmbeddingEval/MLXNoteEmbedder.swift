import Foundation
import Hub
import MLX
import MLXEmbedders

protocol TextEmbedding: Sendable {
    func load() async throws
    func embed(_ text: String) async throws -> NoteEmbedding
    func unload() async
}

struct ChunkEmbedding: Codable, Sendable {
    let contentTokens: Int
    let inputIDs: [Int]
    let vector: [Float]
}
struct NoteEmbedding: Codable, Sendable {
    let contentIDs: [Int]
    let prefixIDs: [Int]
    let chunks: [ChunkEmbedding]
    let vector: [Float]
}

actor MLXNoteEmbedder: TextEmbedding {
    let configuration: EmbeddingModelConfiguration
    let directory: URL
    private var container: MLXEmbedders.ModelContainer?

    init(configuration: EmbeddingModelConfiguration, directory: URL) {
        self.configuration = configuration
        self.directory = directory
    }

    func load() async throws {
        guard container == nil else { return }
        for name in configuration.requiredFiles {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw EvaluationFailure("Missing local model file: \(name). Run with --download first.")
            }
        }
        let marker = directory.appendingPathComponent("embedding-artifact.json")
        let recorded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: marker))
        guard recorded["model"] == configuration.modelID, recorded["revision"] == configuration.revision else {
            throw EvaluationFailure("Model provenance does not match the configured immutable revision")
        }
        let poolingData = try Data(contentsOf: directory.appendingPathComponent("1_Pooling/config.json"))
        let pooling = try JSONSerialization.jsonObject(with: poolingData) as? [String: Any]
        guard pooling?["pooling_mode_mean_tokens"] as? Bool == true,
              pooling?["word_embedding_dimension"] as? Int == configuration.dimensions else {
            throw EvaluationFailure("The artifact does not declare the expected mean pooling/dimension")
        }
        let modelData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let modelConfig = try JSONSerialization.jsonObject(with: modelData) as? [String: Any]
        guard modelConfig?["model_type"] as? String == "bert",
              modelConfig?["max_position_embeddings"] as? Int == configuration.maximumSequenceTokens else {
            throw EvaluationFailure("This backend contract expects the pinned BERT encoder configuration")
        }
        GPU.set(cacheLimit: 64 * 1024 * 1024)
        container = try await MLXEmbedders.loadModelContainer(configuration: .init(directory: directory))
    }

    func embed(_ text: String) async throws -> NoteEmbedding {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvaluationFailure("Empty notes are skipped, not embedded as zero vectors")
        }
        guard let container else { throw EvaluationFailure("Load the model first") }
        let config = configuration
        let (content, prefix, bos, eos) = try await container.perform { _, tokenizer, _ in
            // This version's Unigram bosTokenId is an internal space token,
            // not XLM-R's <s>. Resolve/validate the artifact's special tokens.
            guard tokenizer.convertTokenToId("<s>") == config.bosTokenID,
                  tokenizer.convertTokenToId("</s>") == config.eosTokenID else {
                throw EvaluationFailure("Special-token IDs do not match the pinned artifact")
            }
            let bos = config.bosTokenID, eos = config.eosTokenID
            let prefix = tokenizer.encode(text: config.prefix.trimmingCharacters(in: .whitespaces), addSpecialTokens: false)
            let complete = tokenizer.encode(text: config.prefix + text, addSpecialTokens: false)
            guard complete.starts(with: prefix) else { throw EvaluationFailure("Prefix token boundary changed") }
            return (Array(complete.dropFirst(prefix.count)), prefix, bos, eos)
        }
        guard !content.isEmpty else { throw EvaluationFailure("Tokenization produced no content tokens") }
        var chunks: [ChunkEmbedding] = []
        var accumulated = Array(repeating: 0.0, count: config.dimensions)
        for offset in stride(from: 0, to: content.count, by: config.contentTokensPerChunk) {
            try Task.checkCancellation()
            let part = Array(content[offset..<min(content.count, offset + config.contentTokensPerChunk)])
            let inputIDs = [bos] + prefix + part + [eos]
            guard inputIDs.count <= config.maximumSequenceTokens else {
                throw EvaluationFailure("Prefix/special tokens exceeded the configured sequence budget")
            }
            let vector: [Float] = try await container.perform { model, _, _ in
                try Task.checkCancellation()
                let input = MLXArray(inputIDs).reshaped(1, -1)
                // E5-small has a BERT encoder despite its XLM-R tokenizer:
                // use absolute positions starting at zero, not RoBERTa offsets.
                let positions = Array(0..<inputIDs.count)
                let output = model(input, positionIds: MLXArray(positions).reshaped(1, -1),
                                   tokenTypeIds: MLXArray.zeros(like: input),
                                   attentionMask: MLXArray.ones(input.shape))
                // Explicit mean pooling: the pinned loader silently falls back
                // if a sentence-transformers pooling config omits lasttoken.
                let vector = Pooling(strategy: .mean, dimension: config.dimensions)(
                    output, mask: MLXArray.ones(input.shape), normalize: true, applyLayerNorm: false)
                eval(vector)
                Stream().synchronize()
                return vector.asArray(Float.self)
            }
            try Self.validate(vector, dimensions: config.dimensions)
            for i in vector.indices { accumulated[i] += Double(vector[i]) * Double(part.count) }
            chunks.append(ChunkEmbedding(contentTokens: part.count, inputIDs: inputIDs, vector: vector))
        }
        let norm = sqrt(accumulated.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw EvaluationFailure("Invalid aggregate norm") }
        let vector = accumulated.map { Float($0 / norm) }
        try Self.validate(vector, dimensions: config.dimensions)
        return NoteEmbedding(contentIDs: content, prefixIDs: prefix, chunks: chunks, vector: vector)
    }

    static func validate(_ vector: [Float], dimensions: Int) throws {
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard vector.count == dimensions, vector.allSatisfy({ $0.isFinite }), abs(norm - 1) < 0.001 else {
            throw EvaluationFailure("Embedding must have \(dimensions) finite unit-normalized values")
        }
    }

    func unload() {
        container = nil
        GPU.clearCache()
    }
}

func prepareArtifact(_ config: EmbeddingModelConfiguration, download: Bool, directory: URL?) async throws -> URL {
    let target = directory ?? config.directory
    if download {
        guard directory == nil else { throw EvaluationFailure("--download cannot modify a supplied --model-directory") }
        let hub = HubApi(downloadBase: config.cacheRoot)
        let loaded = try await hub.snapshot(from: Hub.Repo(id: config.modelID), revision: config.revision,
                                            matching: config.requiredFiles)
        guard loaded.standardizedFileURL.path == target.standardizedFileURL.path else {
            throw EvaluationFailure("Unexpected download cache location")
        }
        let provenance = ["model": config.modelID, "revision": config.revision]
        try JSONEncoder().encode(provenance).write(to: target.appendingPathComponent("embedding-artifact.json"), options: .atomic)
    }
    return target
}
