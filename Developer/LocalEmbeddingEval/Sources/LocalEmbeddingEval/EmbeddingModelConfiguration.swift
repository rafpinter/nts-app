import Foundation
import CryptoKit

/// Dev-only vector-space contract. Production integration is a later slice.
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

    static let evaluationRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    var cacheRoot: URL { Self.evaluationRoot.appendingPathComponent("models/\(revision)") }
    var directory: URL { cacheRoot.appendingPathComponent("models/\(modelID)") }
    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
    var requiredFiles: [String] {
        ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json",
         "special_tokens_map.json", "1_Pooling/config.json", "sentence_bert_config.json", "modules.json"]
    }
}

struct EvaluationFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Options {
    var allowDownload = false
    var repeats = 2
    var directory: URL?
    var output = EmbeddingModelConfiguration.evaluationRoot.appendingPathComponent("results/evaluation.json")

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--download" { result.allowDownload = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw EvaluationFailure("Missing value for \(option)") }
            let value = arguments[index + 1]
            switch option {
            case "--model-directory": result.directory = URL(fileURLWithPath: value)
            case "--output": result.output = URL(fileURLWithPath: value)
            case "--repeats":
                guard let count = Int(value), (1...5).contains(count) else {
                    throw EvaluationFailure("Repeats must be between 1 and 5")
                }
                result.repeats = count
            default: throw EvaluationFailure("Unknown option: \(option)")
            }
            index += 2
        }
        return result
    }
}
