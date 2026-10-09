import Foundation
import AnyLanguageModel
import PluginSDK
import Protocols

struct ClaudeCodeModelProviderFactory: ModelProviderFactory {
    func buildProvider(from config: ModelProviderBuildConfig) -> (any ModelProvider)? {
        let models = config.resolvedModels.filter { $0.hasPrefix("claude-code:") }
        guard !models.isEmpty else { return nil }
        let rows = config.modelConfigs.filter { CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("claude-code:") == true }
        return ClaudeCodeModelProvider(supportedModels: models, systemInstructions: config.systemInstructions, tools: config.tools,
            transport: ClaudeCodeTransport(proxy: config.coreConfig.proxy),
            invalidConfiguration: rows.contains { !$0.apiKey.isEmpty || !$0.apiUrl.isEmpty })
    }
}

struct ClaudeCodeModelProvider: ModelProvider {
    let id = "claude-code"
    let supportedModels: [String]
    let systemInstructions: String?
    let tools: [any Tool]
    let transport: ClaudeCodeTransport
    var invalidConfiguration = false
    private let reasoning = ReasoningContentCapture()
    private let usage = TokenUsageCapture()

    func supports(modelName: String) -> Bool { modelName.hasPrefix("claude-code:") }
    func supportsUsageObservation(for modelName: String) -> Bool { supports(modelName: modelName) }
    func reasoningCapture(for modelName: String) -> ReasoningContentCapture? { supports(modelName: modelName) ? reasoning : nil }
    func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? { supports(modelName: modelName) ? usage : nil }
    func contextLimits(for modelName: String) -> ModelContextLimits? {
        guard supports(modelName: modelName) else { return nil }
        return .init(contextWindowTokens: modelName.hasSuffix("[1m]") ? 1_000_000 : 200_000, maxOutputTokens: 32_000)
    }
    func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        var options = GenerationOptions(maximumResponseTokens: min(maxTokens, 32_000))
        let effort: String? = switch reasoningEffort {
        case nil: nil
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
        options[custom: ClaudeCodeLanguageModel.self] = .init(effort: effort)
        return options
    }
    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        try await makeModel(modelName: modelName, usageContext: nil)
    }
    func createLanguageModel(for modelName: String, usageContext: ModelUsageContext) async throws -> any LanguageModel {
        try await makeModel(modelName: modelName, usageContext: usageContext)
    }
    private func makeModel(modelName: String, usageContext: ModelUsageContext?) async throws -> ClaudeCodeLanguageModel {
        guard !invalidConfiguration else { throw ClaudeCodeError.invalidConfiguration }
        guard supports(modelName: modelName) else { throw ClaudeCodeError.invalidConfiguration }
        try await transport.status()
        let model = String(modelName.dropFirst("claude-code:".count))
        return ClaudeCodeLanguageModel(generate: { history, body, effort, onText in
            try await transport.generate(model: model, history: history, extraBody: body, effort: effort, onText: onText, usageContext: usageContext)
        }, reasoningCapture: reasoning, tokenUsageCapture: usage, captureFallbackUsage: usageContext == nil)
    }
}
