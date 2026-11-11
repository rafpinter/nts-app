import Foundation
#if arch(arm64)
import Hub
import MLX
import MLXEmbedders
#endif

enum NoteEmbeddingFailure: LocalizedError {
    case unavailable
    case malformedArtifact(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .unavailable: "Local note embeddings require an Apple Silicon Mac."
        case .malformedArtifact(let detail): "The embedding model artifact is invalid: \(detail)"
        case .invalidOutput: "The embedding model returned an invalid vector."
        }
    }
}

actor MLXNoteEmbedder: NoteEmbeddingBackend {
    private let configuration: EmbeddingModelConfiguration
    #if arch(arm64)
    private var container: MLXEmbedders.ModelContainer?
    #endif

    init(configuration: EmbeddingModelConfiguration = .current) {
        self.configuration = configuration
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if arch(arm64)
        let hub = HubApi(downloadBase: try configuration.cacheRoot)
        let directory = try await hub.snapshot(
            from: Hub.Repo(id: configuration.modelID),
            revision: configuration.revision,
            matching: configuration.requiredFiles,
            progressHandler: { progress($0.fractionCompleted) })
        guard directory.standardizedFileURL == (try configuration.modelDirectory).standardizedFileURL else {
            throw NoteEmbeddingFailure.malformedArtifact("The downloaded model path did not match the pinned revision.")
        }
        let marker = directory.appendingPathComponent("embedding-artifact.json")
        let provenance = ["model": configuration.modelID, "revision": configuration.revision]
        try JSONEncoder().encode(provenance).write(to: marker, options: .atomic)
        progress(1)
        #else
        throw NoteEmbeddingFailure.unavailable
        #endif
    }

    func isAvailable() -> Bool {
        #if arch(arm64)
        guard let directory = try? configuration.modelDirectory else { return false }
        return configuration.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        } && FileManager.default.fileExists(atPath: directory.appendingPathComponent("embedding-artifact.json").path)
        #else
        false
        #endif
    }

    func embed(_ text: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Float] {
        #if arch(arm64)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteEmbeddingFailure.malformedArtifact("Empty saved notes are skipped.")
        }
        try await load()
        guard let container else { throw NoteEmbeddingFailure.malformedArtifact("The model did not load.") }
        let config = configuration
        let (content, prefix) = try await container.perform { _, tokenizer, _ in
            guard tokenizer.convertTokenToId("<s>") == config.bosTokenID,
                  tokenizer.convertTokenToId("</s>") == config.eosTokenID else {
                throw NoteEmbeddingFailure.malformedArtifact("Special-token IDs do not match the pinned model.")
            }
            let prefix = tokenizer.encode(text: config.prefix.trimmingCharacters(in: .whitespaces),
                                          addSpecialTokens: false)
            let complete = tokenizer.encode(text: config.prefix + text, addSpecialTokens: false)
            guard complete.starts(with: prefix) else {
                throw NoteEmbeddingFailure.malformedArtifact("Prefix tokenization did not match the pinned contract.")
            }
            return (Array(complete.dropFirst(prefix.count)), prefix)
        }
        guard !content.isEmpty else {
            throw NoteEmbeddingFailure.malformedArtifact("The saved note has no content tokens.")
        }

        var aggregate = Array(repeating: 0.0, count: config.dimensions)
        let chunkCount = (content.count + config.contentTokensPerChunk - 1) / config.contentTokensPerChunk
        for (chunkIndex, offset) in stride(from: 0, to: content.count,
                                           by: config.contentTokensPerChunk).enumerated() {
            try Task.checkCancellation()
            let part = Array(content[offset..<min(content.count, offset + config.contentTokensPerChunk)])
            let ids = [config.bosTokenID] + prefix + part + [config.eosTokenID]
            guard ids.count <= config.maximumSequenceTokens else {
                throw NoteEmbeddingFailure.malformedArtifact("Token window exceeds the model context limit.")
            }
            let vector: [Float] = try await container.perform { model, _, _ in
                try Task.checkCancellation()
                let input = MLXArray(ids).reshaped(1, -1)
                let positions = MLXArray(Array(0..<ids.count)).reshaped(1, -1)
                let output = model(input, positionIds: positions, tokenTypeIds: MLXArray.zeros(like: input),
                                  attentionMask: MLXArray.ones(input.shape))
                let pooled = Pooling(strategy: .mean, dimension: config.dimensions)(
                    output, mask: MLXArray.ones(input.shape), normalize: true, applyLayerNorm: false)
                eval(pooled)
                Stream().synchronize()
                return pooled.asArray(Float.self)
            }
            try Self.validate(vector, dimensions: config.dimensions)
            for index in vector.indices { aggregate[index] += Double(vector[index]) * Double(part.count) }
            progress(Double(chunkIndex + 1) / Double(chunkCount))
        }
        let norm = sqrt(aggregate.reduce(0.0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw NoteEmbeddingFailure.invalidOutput }
        let result = aggregate.map { Float($0 / norm) }
        try Self.validate(result, dimensions: config.dimensions)
        return result
        #else
        throw NoteEmbeddingFailure.unavailable
        #endif
    }

    private func load() async throws {
        #if arch(arm64)
        guard container == nil else { return }
        let directory = try configuration.modelDirectory
        guard isAvailable() else { throw NoteEmbeddingFailure.malformedArtifact("Download the embedding model first.") }
        let markerURL = directory.appendingPathComponent("embedding-artifact.json")
        let marker = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: markerURL))
        guard marker["model"] == configuration.modelID, marker["revision"] == configuration.revision else {
            throw NoteEmbeddingFailure.malformedArtifact("Model provenance does not match the pinned revision.")
        }
        let pooling = try Self.json(directory.appendingPathComponent("1_Pooling/config.json"))
        guard pooling["pooling_mode_mean_tokens"] as? Bool == true,
              pooling["word_embedding_dimension"] as? Int == configuration.dimensions else {
            throw NoteEmbeddingFailure.malformedArtifact("Pooling configuration is incompatible.")
        }
        let model = try Self.json(directory.appendingPathComponent("config.json"))
        guard model["model_type"] as? String == "bert",
              model["max_position_embeddings"] as? Int == configuration.maximumSequenceTokens else {
            throw NoteEmbeddingFailure.malformedArtifact("Model architecture or context length is incompatible.")
        }
        GPU.set(cacheLimit: 64 * 1024 * 1024)
        container = try await MLXEmbedders.loadModelContainer(configuration: .init(directory: directory))
        #endif
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw NoteEmbeddingFailure.malformedArtifact("Could not parse \(url.lastPathComponent).")
        }
        return object
    }

    private static func validate(_ vector: [Float], dimensions: Int) throws {
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard vector.count == dimensions, vector.allSatisfy(\.isFinite), norm.isFinite,
              abs(norm - 1) < 0.001 else { throw NoteEmbeddingFailure.invalidOutput }
    }

    func unload() async {
        #if arch(arm64)
        container = nil
        GPU.clearCache()
        #endif
    }
}
