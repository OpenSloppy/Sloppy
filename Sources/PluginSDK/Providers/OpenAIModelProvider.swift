import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import Protocols

/// Model provider for OpenAI-compatible APIs.
/// Supports both API-key auth and OAuth bearer tokens.
/// Automatically retries with the Responses API variant when the Chat Completions API rejects a model.
public struct OpenAIModelProvider: ModelProvider {
    public struct Settings: Sendable {
        public var apiKey: @Sendable () -> String
        public var baseURL: URL
        public var apiVariant: OpenAILanguageModel.APIVariant
        public var accountId: String?
        public var refreshTokenIfNeeded: (@Sendable () async throws -> Void)?
        public var refreshTokenAfterInvalidToken: (@Sendable () async throws -> Void)?
        public var session: URLSession?
        /// Strips this prefix from configured model ids (e.g. `openai-api:` or `openrouter:`).
        public var modelIdentifierPrefix: String
        /// When `true`, bearer tokens that are not OpenAI-style `sk-…` keys are sent to ``OpenAIOAuthModel`` (ChatGPT Codex).
        public var useOpenAICodexOAuthPath: Bool
        /// When `true`, failed Chat Completions requests may retry against OpenAI’s Responses API. Disable for OpenAI-compatible hosts such as OpenRouter.
        public var allowResponsesAPIFallback: Bool
        /// When `true`, use OpenAI Responses API semantics instead of Chat Completions. Suitable for OpenRouter and other Open Responses–compatible endpoints.
        public var useOpenResponsesLanguageModel: Bool

        public init(
            apiKey: @escaping @Sendable () -> String,
            baseURL: URL = OpenAILanguageModel.defaultBaseURL,
            apiVariant: OpenAILanguageModel.APIVariant = .chatCompletions,
            accountId: String? = nil,
            refreshTokenIfNeeded: (@Sendable () async throws -> Void)? = nil,
            refreshTokenAfterInvalidToken: (@Sendable () async throws -> Void)? = nil,
            session: URLSession? = nil,
            modelIdentifierPrefix: String = "openai-api:",
            useOpenAICodexOAuthPath: Bool = false,
            allowResponsesAPIFallback: Bool = true,
            useOpenResponsesLanguageModel: Bool = false
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.apiVariant = apiVariant
            self.accountId = accountId
            self.refreshTokenIfNeeded = refreshTokenIfNeeded
            self.refreshTokenAfterInvalidToken = refreshTokenAfterInvalidToken
            self.session = session
            self.modelIdentifierPrefix = modelIdentifierPrefix
            self.useOpenAICodexOAuthPath = useOpenAICodexOAuthPath
            self.allowResponsesAPIFallback = allowResponsesAPIFallback
            self.useOpenResponsesLanguageModel = useOpenResponsesLanguageModel
        }
    }

    public let id: String
    public let supportedModels: [String]
    public let systemInstructions: String?
    public let tools: [any Tool]
    private let _reasoningCapture: ReasoningContentCapture
    private let _tokenUsageCapture: TokenUsageCapture
    private let settings: Settings
    private static let logger = Logger(label: "sloppy.provider.openai")

    public init(
        id: String = "openai",
        supportedModels: [String],
        settings: Settings,
        tools: [any Tool] = [],
        systemInstructions: String? = nil
    ) {
        self.id = id
        self.supportedModels = supportedModels
        self.settings = settings
        self.tools = tools
        self.systemInstructions = systemInstructions
        self._reasoningCapture = ReasoningContentCapture()
        self._tokenUsageCapture = TokenUsageCapture()
    }

    public func reasoningCapture(for modelName: String) -> ReasoningContentCapture? {
        _reasoningCapture
    }

    public func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? {
        _tokenUsageCapture
    }

    public func supports(modelName: String) -> Bool {
        if supportedModels.contains(modelName) {
            return true
        }
        return modelName.hasPrefix(settings.modelIdentifierPrefix)
    }

    public func supportsUsageObservation(for modelName: String) -> Bool { supports(modelName: modelName) }

    public func createLanguageModel(for modelName: String, usageContext: ModelUsageContext) async throws -> any LanguageModel {
        let observed = UsageObservedURLSession.make(wrapping: settings.session, context: usageContext)
        return try await makeLanguageModel(for: modelName, sessionOverride: observed, captureLegacyUsage: false)
    }

    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        try await makeLanguageModel(for: modelName)
    }

    private func makeLanguageModel(for modelName: String, sessionOverride: URLSession? = nil,
                                   captureLegacyUsage: Bool = true) async throws -> any LanguageModel {
        let resolved = normalizeModelName(modelName)
        let token = settings.apiKey()
        if settings.useOpenAICodexOAuthPath, isOAuthToken(token) {
            return OpenAIOAuthModel(
                bearerTokenProvider: settings.apiKey,
                bearerTokenRefresh: settings.refreshTokenIfNeeded,
                bearerTokenForceRefresh: settings.refreshTokenAfterInvalidToken,
                model: resolved,
                accountId: settings.accountId,
                instructions: systemInstructions ?? "You are an execution-focused assistant.",
                reasoningCapture: _reasoningCapture,
                tokenUsageCapture: captureLegacyUsage ? _tokenUsageCapture : nil,
                session: sessionOverride ?? settings.session ?? .shared
            )
        }
        if settings.useOpenResponsesLanguageModel {
            let httpSession = sessionOverride ?? settings.session ?? makeDefaultSession()
            return OpenAILanguageModel(
                baseURL: settings.baseURL,
                apiKey: settings.apiKey(),
                model: resolved,
                apiVariant: .responses,
                session: httpSession
            )
        }
        return OpenAIRetryingLanguageModel(
            apiKey: settings.apiKey,
            baseURL: settings.baseURL,
            apiVariant: settings.apiVariant,
            model: resolved,
            session: sessionOverride ?? settings.session,
            allowResponsesAPIFallback: settings.allowResponsesAPIFallback
        )
    }

    public func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        var options = GenerationOptions(maximumResponseTokens: maxTokens)
        let mapped = mapReasoningEffort(reasoningEffort)
        options[custom: OpenAILanguageModel.self] = .init(
            reasoningEffort: mapped,
            reasoning: mapped.map { .init(effort: $0) },
            promptCacheKey: supportsPromptCacheHints ? promptCacheKey(for: modelName) : nil,
            promptCacheRetention: nil
        )
        return options
    }

    private var supportsPromptCacheHints: Bool {
        settings.useOpenAICodexOAuthPath || settings.baseURL.host?.contains("openai.com") == true
    }

    private func promptCacheKey(for modelName: String) -> String {
        let resolved = normalizeModelName(modelName)
        let safeProvider = id.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let safeModel = resolved.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return "sloppy-\(String(safeProvider).prefix(32))-\(String(safeModel).prefix(80))"
    }

    private func normalizeModelName(_ model: String) -> String {
        let prefix = settings.modelIdentifierPrefix
        if model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        return model
    }

    private func isOAuthToken(_ token: String) -> Bool {
        !token.hasPrefix("sk-") && !token.isEmpty
    }

    private func mapReasoningEffort(
        _ effort: ReasoningEffort?
    ) -> OpenAILanguageModel.CustomGenerationOptions.ReasoningEffort? {
        switch effort {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case nil: return nil
        }
    }

}

/// Wraps `OpenAILanguageModel` and automatically retries with the Responses API variant
/// when a Chat Completions request fails because the model is not a chat model.
struct OpenAIRetryingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let apiKey: @Sendable () -> String
    let baseURL: URL
    let apiVariant: OpenAILanguageModel.APIVariant
    let model: String
    let session: URLSession?
    let allowResponsesAPIFallback: Bool

    init(
        apiKey: @escaping @Sendable () -> String,
        baseURL: URL,
        apiVariant: OpenAILanguageModel.APIVariant,
        model: String,
        session: URLSession? = nil,
        allowResponsesAPIFallback: Bool = true
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiVariant = apiVariant
        self.model = model
        self.session = session
        self.allowResponsesAPIFallback = allowResponsesAPIFallback
    }

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        let primary = makeModel(variant: apiVariant)
        do {
            return try await primary.respond(
                within: session, to: prompt, generating: type,
                includeSchemaInPrompt: includeSchemaInPrompt, options: options
            )
        } catch {
            guard allowResponsesAPIFallback,
                  shouldRetryWithResponses(error: error, currentVariant: apiVariant)
            else { throw error }
            let fallback = makeModel(variant: .responses)
            return try await fallback.respond(
                within: session, to: prompt, generating: type,
                includeSchemaInPrompt: includeSchemaInPrompt, options: options
            )
        }
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let apiKey = self.apiKey()
        let baseURL = self.baseURL
        let apiVariant = self.apiVariant
        let model = self.model
        let urlSession = self.session
        let allowResponsesAPIFallback = self.allowResponsesAPIFallback

        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                let primary = urlSession.map {
                    OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: model, apiVariant: apiVariant, session: $0)
                } ?? OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: model, apiVariant: apiVariant)
                let primaryStream = primary.streamResponse(
                    within: session, to: prompt, generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt, options: options
                )

                var retryNeeded = false
                do {
                    for try await snapshot in primaryStream {
                        continuation.yield(snapshot)
                    }
                } catch {
                    if allowResponsesAPIFallback,
                       shouldRetryWithResponses(error: error, currentVariant: apiVariant) {
                        retryNeeded = true
                    } else {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                guard retryNeeded else {
                    continuation.finish()
                    return
                }

                let fallback = urlSession.map {
                    OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: model, apiVariant: .responses, session: $0)
                } ?? OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: model, apiVariant: .responses)
                let fallbackStream = fallback.streamResponse(
                    within: session, to: prompt, generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt, options: options
                )
                do {
                    for try await snapshot in fallbackStream {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }

    private func makeModel(variant: OpenAILanguageModel.APIVariant) -> OpenAILanguageModel {
        if let session {
            return OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey(), model: model, apiVariant: variant, session: session)
        }
        return OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey(), model: model, apiVariant: variant)
    }

    private func shouldRetryWithResponses(error: any Error, currentVariant: OpenAILanguageModel.APIVariant) -> Bool {
        guard currentVariant == .chatCompletions else { return false }
        let text = String(describing: error).lowercased()
        return text.contains("not a chat model") ||
            (text.contains("v1/chat/completions") && text.contains("did you mean to use v1/completions"))
    }
}
