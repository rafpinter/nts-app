import Foundation
#if arch(arm64)
import MLX
import MLXLLM
import MLXLMCommon
import Hub
#endif

/// MLX is confined to this backend. Notes, persistence and UI use plain Swift types.
actor MLXFilenameGenerator: FilenameGenerating {
    #if arch(arm64)
    private var container: ModelContainer?
    private var loadedFingerprint: String?

    private func cacheRoot() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FilenameModels", isDirectory: true)
    }

    private func directory(_ configuration: FilenameModelConfiguration) throws -> URL {
        // Separate revisions/configurations so changing models never silently reuses old weights.
        try cacheRoot().appendingPathComponent(configuration.modelCacheKey, isDirectory: true)
            .appendingPathComponent("models").appendingPathComponent(configuration.modelID)
    }
    #endif

    func download(configuration: FilenameModelConfiguration, progress: @escaping @Sendable (Double) -> Void) async throws {
        #if arch(arm64)
        let hub = HubApi(downloadBase: try cacheRoot().appendingPathComponent(configuration.modelCacheKey))
        _ = try await downloadModel(hub: hub,
                                   configuration: MLXLMCommon.ModelConfiguration(id: configuration.modelID, revision: configuration.revision),
                                   progressHandler: { progress($0.fractionCompleted) })
        #else
        throw FilenameSuggestionFailure(message: "Local filename generation requires an Apple Silicon Mac.")
        #endif
    }

    func isAvailable(configuration: FilenameModelConfiguration) async -> Bool {
        #if arch(arm64)
        guard let local = try? directory(configuration) else { return false }
        return FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path)
        #else
        return false
        #endif
    }

    func generate(text: String, configuration: FilenameModelConfiguration) async throws -> String {
        try await LocalMLXResourceGate.shared.withResource(.filenames) {
            try await self.generateWithModel(text: text, configuration: configuration)
        }
    }

    private func generateWithModel(text: String, configuration: FilenameModelConfiguration) async throws -> String {
        try configuration.validateGenerationSettings()
        #if arch(arm64)
        if loadedFingerprint != configuration.modelCacheKey {
            container = nil
            let local = try directory(configuration)
            guard FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path) else {
                throw FilenameSuggestionFailure(message: "Download the configured model using Local AI → Download Model and Enable Suggestions…")
            }
            GPU.set(cacheLimit: configuration.cacheLimitBytes)
            container = try await LLMModelFactory.shared.loadContainer(configuration: MLXLMCommon.ModelConfiguration(directory: local))
            loadedFingerprint = configuration.modelCacheKey
        }
        guard let container else { throw FilenameSuggestionFailure(message: "The local model could not be loaded.") }
        #if DEBUG
        print("[Filename Model] model=\(configuration.modelID) revision=\(configuration.revision)")
        print("[Filename Model] configuration=\(configuration.fingerprint) temperature=\(configuration.temperature) topP=\(configuration.topP) maxTokens=\(configuration.maxOutputTokens) thinking=\(configuration.enableThinking) systemRole=\(configuration.useSystemRole)")
        if configuration.useSystemRole {
            print("[Filename Model] System prompt BEGIN\n\(configuration.systemPrompt)\n[Filename Model] System prompt END")
            print("[Filename Model] User prompt BEGIN\n\(configuration.userPrompt(for: text))\n[Filename Model] User prompt END")
        } else {
            print("[Filename Model] Effective prompt BEGIN\n\(configuration.combinedPrompt(for: text))\n[Filename Model] Effective prompt END")
        }
        #endif
        return try await container.perform { context in
            defer { Stream().synchronize() }
            let userInput: UserInput
            if configuration.useSystemRole {
                userInput = UserInput(chat: [.system(configuration.systemPrompt), .user(configuration.userPrompt(for: text))],
                                      additionalContext: ["enable_thinking": configuration.enableThinking])
            } else {
                userInput = UserInput(prompt: configuration.combinedPrompt(for: text),
                                      additionalContext: ["enable_thinking": configuration.enableThinking])
            }
            let input = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(input: input,
                parameters: GenerateParameters(maxTokens: configuration.maxOutputTokens, temperature: configuration.temperature,
                                               topP: configuration.topP), context: context)
            var output = ""
            for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .chunk(let chunk): output += chunk
                case .info: break
                case .toolCall: throw FilenameSuggestionFailure(message: "The model returned a tool call instead of a filename.")
                }
            }
            return output
        }
        #else
        throw FilenameSuggestionFailure(message: "Local filename generation requires an Apple Silicon Mac.")
        #endif
    }

    func unload() async {
        _ = try? await LocalMLXResourceGate.shared.withResource(.filenames) {
            await self.unloadForSwitch()
            return true
        }
    }

    func unloadForSwitch() {
        #if arch(arm64)
        container = nil
        loadedFingerprint = nil
        GPU.clearCache()
        #endif
    }
}
