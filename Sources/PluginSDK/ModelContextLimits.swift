import AnyLanguageModel
import Foundation
import Protocols

public struct ModelContextLimits: Codable, Sendable, Equatable {
    public var contextWindowTokens: Int
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?

    public init(contextWindowTokens: Int, maxInputTokens: Int? = nil, maxOutputTokens: Int? = nil) {
        let window = max(1, contextWindowTokens)
        self.contextWindowTokens = window
        self.maxInputTokens = maxInputTokens.map { min(max(1, $0), window) }
        self.maxOutputTokens = maxOutputTokens.map { min(max(1, $0), window) }
    }

    public func inputBudget(reserving outputTokens: Int) -> Int {
        max(0, min(contextWindowTokens, maxInputTokens ?? contextWindowTokens) - outputReserve(outputTokens))
    }

    public func outputReserve(_ requested: Int) -> Int {
        min(max(0, requested), maxOutputTokens ?? contextWindowTokens)
    }
}

public struct ContextLimitedModelProvider: ModelProvider {
    private let wrapped: any ModelProvider
    private let limits: [String: ModelContextLimits]

    public init(wrapping provider: any ModelProvider, limits: [String: ModelContextLimits]) {
        wrapped = provider
        self.limits = limits
    }

    public var id: String { wrapped.id }
    public var supportedModels: [String] { wrapped.supportedModels }
    public var systemInstructions: String? { wrapped.systemInstructions }
    public var tools: [any Tool] { wrapped.tools }
    public func supports(modelName: String) -> Bool { wrapped.supports(modelName: modelName) }
    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel { try await wrapped.createLanguageModel(for: modelName) }
    public func supportsUsageObservation(for modelName: String) -> Bool { wrapped.supportsUsageObservation(for: modelName) }
    public func createLanguageModel(for modelName: String, usageContext: ModelUsageContext) async throws -> any LanguageModel { try await wrapped.createLanguageModel(for: modelName, usageContext: usageContext) }
    public func contextLimits(for modelName: String) -> ModelContextLimits? { limits[modelName] ?? wrapped.contextLimits(for: modelName) }
    public func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        wrapped.generationOptions(for: modelName, maxTokens: contextLimits(for: modelName)?.outputReserve(maxTokens) ?? maxTokens, reasoningEffort: reasoningEffort)
    }
    public func reasoningCapture(for modelName: String) -> ReasoningContentCapture? { wrapped.reasoningCapture(for: modelName) }
    public func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? { wrapped.tokenUsageCapture(for: modelName) }
}
