import Foundation

struct EmbeddingModelConfiguration: Encodable, Sendable {
    let modelID = "intfloat/multilingual-e5-small"
    let revision = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
    let tokenizerRevision = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
    let dimensions = 384
    let precision = "float32"
    let prefix = "query: "
    let prefixTokenization = "tokenize-prefix-plus-text-then-split-payload-v1"
    let contentTokensPerChunk = 384
    let maximumSequenceTokens = 512
    let overlapTokens = 0
    let pooling = "attention-mask-mean-no-extra-layernorm"
    let normalization = "chunk-l2-then-token-weighted-file-mean-l2"
    let preparation = "raw-markdown-v1-no-filename-no-text-normalization"
    let positionPolicy = "bert-absolute-zero-based"
    let bosTokenID = 0
    let eosTokenID = 2
    let runtime = "mlx-swift-lm-2.29.3/mlx-0.29.1/transformers-1.1.9"
    let pipelineVersion = "note-embedding-eval-v1"

    static let current = Self()

    var json: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    var space: EmbeddingSpace {
        get throws {
            EmbeddingSpace(configurationJSON: try json, modelID: modelID, modelRevision: revision,
                           tokenizerRevision: tokenizerRevision, dimensions: dimensions,
                           pipelineVersion: pipelineVersion)
        }
    }

    var cacheRoot: URL {
        get throws {
            try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier?
                    .split(separator: ".").last.map(String.init) ?? "Nts", isDirectory: true)
                .appendingPathComponent("EmbeddingModels", isDirectory: true)
                .appendingPathComponent(revision, isDirectory: true)
        }
    }

    var modelDirectory: URL {
        get throws {
            try cacheRoot.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(modelID, isDirectory: true)
        }
    }

    var requiredFiles: [String] {
        ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json",
         "special_tokens_map.json", "1_Pooling/config.json", "sentence_bert_config.json", "modules.json"]
    }
}
