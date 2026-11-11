import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Model-neutral boundary: no Hugging Face or MLX types escape the backend.
protocol LocalTextGenerator: Sendable {
    func load() async throws
    func generate(prompt: String, maxTokens: Int) async throws -> TextGeneration
    func unload() async
}

struct TextGeneration: Sendable {
    let text: String
    let promptTokens: Int
    let generatedTokens: Int
    let promptSeconds: Double
    let generationSeconds: Double
}

actor MLXTextGenerator: LocalTextGenerator {
    private let configuration: EvaluationConfiguration
    private var container: ModelContainer?

    init(configuration: EvaluationConfiguration) {
        self.configuration = configuration
    }

    func load() async throws {
        guard container == nil else { return }
        let model: ModelConfiguration
        if let directory = configuration.modelDirectory {
            model = ModelConfiguration(directory: directory)
        } else {
            guard configuration.allowDownload else {
                throw EvaluationError("Model download was not enabled.")
            }
            model = ModelConfiguration(id: configuration.modelID, revision: configuration.revision)
        }
        GPU.set(cacheLimit: 64 * 1024 * 1024)
        container = try await LLMModelFactory.shared.loadContainer(configuration: model)
    }

    func generate(prompt: String, maxTokens: Int) async throws -> TextGeneration {
        guard let container else { throw EvaluationError("Load the model before generating.") }
        // Template options are backend configuration, not part of the caller's prompt.
        let thinking = configuration.thinking
        return try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(
                prompt: prompt, additionalContext: ["enable_thinking": thinking]))
            let stream = try MLXLMCommon.generate(
                input: input, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0), context: context)
            var output = ""
            var completion: GenerateCompletionInfo?
            for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .chunk(let text): output += text
                case .info(let info): completion = info
                case .toolCall: throw EvaluationError("Unexpected tool call from filename prompt.")
                }
            }
            Stream().synchronize()
            guard let completion else { throw EvaluationError("Generation ended without completion information.") }
            return TextGeneration(text: output, promptTokens: completion.promptTokenCount,
                                  generatedTokens: completion.generationTokenCount,
                                  promptSeconds: completion.promptTime, generationSeconds: completion.generateTime)
        }
    }

    func unload() {
        container = nil
        GPU.clearCache()
    }
}
