import AnyLanguageModel
import Foundation
import Protocols

/// Combines multiple `ModelProvider` instances into a single provider.
/// Routes `createLanguageModel(for:)` and `generationOptions(for:)` to the
/// matching sub-provider based on `supportedModels`.
public struct CompositeModelProvider: ModelProvider {
    public enum ProviderError: Error {
        case unsupportedModel(String)
    }

    private let providers: [any ModelProvider]

    public let id: String
    public let systemInstructions: String?
    public let tools: [any Tool]

    public var supportedModels: [String] {
        providers.flatMap(\.supportedModels)
    }

    public init(
        id: String = "composite",
        providers: [any ModelProvider],
        tools: [any Tool] = [],
        systemInstructions: String? = nil
    ) {
        self.id = id
        self.providers = providers
        self.tools = tools
        self.systemInstructions = systemInstructions
    }

    private func provider(matching modelName: String) -> (any ModelProvider)? {
        if let exact = providers.first(where: { $0.supportedModels.contains(modelName) }) {
            return exact
        }
        let routes: [(prefix: String, id: String)] = [
            ("sloppy:", "sloppy"),
            ("openrouter:", "openrouter"),
            ("openai-api:", "openai-api"),
            ("openai-oauth:", "openai-oauth"),
            ("ollama:", "ollama"),
            ("gemini:", "gemini"),
            ("anthropic:", "anthropic"),
        ]
        for route in routes where modelName.hasPrefix(route.prefix) {
            if let match = providers.first(where: { $0.id == route.id }) {
                return match
            }
        }
        return nil
    }

    public func supports(modelName: String) -> Bool {
        provider(matching: modelName) != nil
    }

    public func supportsUsageObservation(for modelName: String) -> Bool { provider(matching: modelName)?.supportsUsageObservation(for: modelName) ?? false }
    public func createLanguageModel(for modelName: String, usageContext: ModelUsageContext) async throws -> any LanguageModel {
        guard let provider = provider(matching: modelName) else { throw ProviderError.unsupportedModel(modelName) }
        return try await provider.createLanguageModel(for: modelName, usageContext: usageContext)
    }

    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        guard let provider = provider(matching: modelName) else {
            throw ProviderError.unsupportedModel(modelName)
        }
        return try await provider.createLanguageModel(for: modelName)
    }

    public func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        guard let provider = provider(matching: modelName) else {
            return GenerationOptions(maximumResponseTokens: maxTokens)
        }
        return provider.generationOptions(for: modelName, maxTokens: maxTokens, reasoningEffort: reasoningEffort)
    }

    public func reasoningCapture(for modelName: String) -> ReasoningContentCapture? {
        provider(matching: modelName)?.reasoningCapture(for: modelName)
    }

    public func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? {
        provider(matching: modelName)?.tokenUsageCapture(for: modelName)
    }

    public func contextLimits(for modelName: String) -> ModelContextLimits? {
        provider(matching: modelName)?.contextLimits(for: modelName)
    }
}
