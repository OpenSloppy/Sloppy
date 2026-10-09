import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginSDK
import Protocols

struct ModelProviderBuildConfig: @unchecked Sendable {
    var coreConfig: CoreConfig
    var modelConfigs: [CoreConfig.ModelConfig]
    var resolvedModels: [String]
    var tools: [any Tool]
    var oauthTokenProvider: (@Sendable () -> String?)?
    var oauthAccountId: String?
    var oauthTokenRefresh: (@Sendable () async throws -> Void)?
    var oauthTokenForceRefresh: (@Sendable () async throws -> Void)?
    var anthropicOAuthTokenProvider: (@Sendable () -> String?)?
    var anthropicOAuthTokenRefresh: (@Sendable () async throws -> Void)?
    var anthropicSettingsProvider: (@Sendable () -> ClaudeSettingsEnvironment)?
    var geminiOAuthCredentialsProvider: (@Sendable () -> GeminiOAuthCredentials?)?
    var systemInstructions: String?
    var proxySession: URLSession?
    var meshModelBridge: MeshModelBridge? = nil
}

protocol ModelProviderFactory: Sendable {
    func buildProvider(from config: ModelProviderBuildConfig) -> (any ModelProvider)?
}

enum CoreModelProviderFactory {
    private static let factories: [any ModelProviderFactory] = [
        MockModelProviderFactory(),
        OpenCodeModelProviderFactory(),
        OpenAIModelProviderFactory(),
        SloppyModelProviderFactory(),
        OpenRouterModelProviderFactory(),
        OllamaModelProviderFactory(),
        GeminiModelProviderFactory(),
        AnthropicModelProviderFactory(),
        ClaudeCodeModelProviderFactory(),
    ]

    static func buildModelProvider(
        config: CoreConfig,
        resolvedModels: [String],
        tools: [any Tool] = [],
        oauthTokenProvider: (@Sendable () -> String?)? = nil,
        oauthAccountId: String? = nil,
        oauthTokenRefresh: (@Sendable () async throws -> Void)? = nil,
        oauthTokenForceRefresh: (@Sendable () async throws -> Void)? = nil,
        anthropicOAuthTokenProvider: (@Sendable () -> String?)? = nil,
        anthropicOAuthTokenRefresh: (@Sendable () async throws -> Void)? = nil,
        anthropicSettingsProvider: (@Sendable () -> ClaudeSettingsEnvironment)? = nil,
        geminiOAuthCredentialsProvider: (@Sendable () -> GeminiOAuthCredentials?)? = nil,
        systemInstructions: String? = nil,
        proxySession: URLSession? = nil,
        meshModelBridge: MeshModelBridge? = nil,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> (any ModelProvider)? {
        let modelConfigs = config.effectiveModels(currentDirectory: currentDirectory)
        let buildConfig = ModelProviderBuildConfig(
            coreConfig: config,
            modelConfigs: modelConfigs,
            resolvedModels: resolvedModels,
            tools: tools,
            oauthTokenProvider: oauthTokenProvider,
            oauthAccountId: oauthAccountId,
            oauthTokenRefresh: oauthTokenRefresh,
            oauthTokenForceRefresh: oauthTokenForceRefresh,
            anthropicOAuthTokenProvider: anthropicOAuthTokenProvider,
            anthropicOAuthTokenRefresh: anthropicOAuthTokenRefresh,
            anthropicSettingsProvider: anthropicSettingsProvider,
            geminiOAuthCredentialsProvider: geminiOAuthCredentialsProvider ?? {
                GeminiOAuthCredentials.load(
                    workspaceRootURL: config.resolvedWorkspaceRootURL(currentDirectory: currentDirectory)
                )
            },
            systemInstructions: systemInstructions,
            proxySession: proxySession,
            meshModelBridge: meshModelBridge
        )

        let providers = factories.compactMap { $0.buildProvider(from: buildConfig) }
        guard !providers.isEmpty else { return nil }
        let provider: any ModelProvider = providers.count == 1 ? providers[0] : CompositeModelProvider(
            providers: providers, tools: tools, systemInstructions: systemInstructions
        )
        var limits: [String: ModelContextLimits] = [:]
        for model in modelConfigs {
            guard let identifier = resolvedIdentifier(for: model),
                  let window = model.contextWindowTokens, window > 0 else { continue }
            limits[identifier] = ModelContextLimits(contextWindowTokens: window, maxInputTokens: model.maxInputTokens, maxOutputTokens: model.maxOutputTokens)
        }
        return limits.isEmpty ? provider : ContextLimitedModelProvider(wrapping: provider, limits: limits)
    }

    /// Resolves model identifiers from config, adding fallback OpenAI defaults when needed.
    /// Only models with a recognized provider prefix are included (no unprefixed models).
    static func resolveModelIdentifiers(
        config: CoreConfig,
        hasOAuthCredentials: Bool = false,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> [String] {
        let modelConfigs = config.effectiveModels(currentDirectory: currentDirectory)
        var identifiers = modelConfigs.compactMap { resolvedIdentifier(for: $0) }
        let hasOpenAIAPI = identifiers.contains { $0.hasPrefix("openai-api:") }
        let hasOpenAIOAuth = identifiers.contains { $0.hasPrefix("openai-oauth:") }
        let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasOpenRouter = identifiers.contains { $0.hasPrefix("openrouter:") }
        let openRouterEnvKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !config.disableModelInference {
            if !hasOpenAIAPI, !environmentKey.isEmpty {
                identifiers.append("openai-api:gpt-5.4-mini")
            }
            if !hasOpenAIOAuth, environmentKey.isEmpty, hasOAuthCredentials {
                identifiers.append("openai-oauth:gpt-5-codex-mini")
            }
            if !hasOpenRouter, !openRouterEnvKey.isEmpty {
                identifiers.append("openrouter:openai/gpt-4o-mini")
            }
        }

        return identifiers
    }

    /// Returns the prefixed model identifier (e.g. "openai-api:gpt-4o") or `nil` if the
    /// provider cannot be inferred, rejecting unprefixed models.
    static func resolvedIdentifier(for model: CoreConfig.ModelConfig) -> String? {
        if model.disabled {
            return nil
        }
        let modelValue = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelValue.isEmpty else { return nil }
        if model.providerCatalogId == "sloppy" {
            return modelValue.hasPrefix("sloppy:") ? modelValue : "sloppy:\(modelValue)"
        }
        if model.providerCatalogId == "claude-code" {
            if modelValue.hasPrefix("claude-code:") { return modelValue }
            return modelValue.contains(":") ? nil : "claude-code:\(modelValue)"
        }
        if modelValue.hasPrefix("openai:") {
            return nil
        }

        if modelValue.hasPrefix("sloppy:") || modelValue.hasPrefix("openai-api:") || modelValue.hasPrefix("openai-oauth:")
            || modelValue.hasPrefix("openrouter:")
            || modelValue.hasPrefix("ollama:")
            || modelValue.hasPrefix("gemini:") || modelValue.hasPrefix("anthropic:")
            || modelValue.hasPrefix("mock:") || modelValue.hasPrefix("opencode:") || modelValue.hasPrefix("claude-code:") {
            return modelValue
        }

        guard let provider = inferredProvider(model: model) else { return nil }
        return "\(provider):\(modelValue)"
    }

    static func resolveRequestedModel(_ requestedModel: String, from resolvedModels: [String]) -> String {
        let model = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return resolvedModels.first ?? ""
        }
        if resolvedModels.contains(model) || model.contains(":") {
            return model
        }

        let matches = resolvedModels.filter { resolved in
            guard let separatorIndex = resolved.firstIndex(of: ":") else {
                return resolved == model
            }
            let unprefixed = resolved[resolved.index(after: separatorIndex)...]
            return unprefixed == model
        }
        return matches.count == 1 ? matches[0] : model
    }

    private static func inferredProvider(model: CoreConfig.ModelConfig) -> String? {
        if let catalog = model.providerCatalogId?.trimmingCharacters(in: .whitespacesAndNewlines), !catalog.isEmpty {
            switch catalog {
            case "openai-api":
                return "openai-api"
            case "openai-oauth":
                return "openai-oauth"
            case "openrouter":
                return "openrouter"
            case "ollama":
                return "ollama"
            case "gemini":
                return "gemini"
            case "anthropic":
                return "anthropic"
            case "anthropic-oauth":
                return "anthropic"
            default:
                break
            }
        }

        let title = model.title.lowercased()
        let apiURL = model.apiUrl.lowercased()

        if (title.contains("oauth") || title.contains("deeplink")) && !title.contains("anthropic") {
            return "openai-oauth"
        }
        if apiURL.contains("chatgpt.com") {
            return "openai-oauth"
        }

        if title.contains("openai") || apiURL.contains("openai") {
            return "openai-api"
        }

        if title.contains("openrouter") || apiURL.contains("openrouter") {
            return "openrouter"
        }

        // LM Studio and many local OpenAI-compatible servers default to port 1234 (not Ollama /api/tags).
        if apiURL.contains(":1234") {
            return "openai-api"
        }

        if title.contains("ollama") || apiURL.contains("ollama") || apiURL.contains("11434") {
            return "ollama"
        }

        if title.contains("gemini") || apiURL.contains("generativelanguage.googleapis.com") {
            return "gemini"
        }

        if title.contains("anthropic") || apiURL.contains("anthropic") {
            return "anthropic"
        }

        return nil
    }

    static func parseURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }
}

// MARK: - Mock Provider

struct MockModelProviderFactory: ModelProviderFactory {
    func buildProvider(from config: ModelProviderBuildConfig) -> (any ModelProvider)? {
        let mockModels = config.resolvedModels.filter { $0.hasPrefix("mock:") }
        guard !mockModels.isEmpty else { return nil }
        return MockModelProvider(supportedModels: mockModels)
    }
}

private actor MockModelProvider: ModelProvider {
    nonisolated let id: String = "mock"
    nonisolated let supportedModels: [String]

    init(supportedModels: [String]) {
        self.supportedModels = supportedModels
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        MockLanguageModel()
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }
}

private struct MockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        let text = "Mock response for prompt: \(prompt.description)"
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let text = "Mock response for prompt: \(prompt.description)"
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                continuation.yield(.init(content: text as! Content.PartiallyGenerated, rawContent: GeneratedContent(text)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}
