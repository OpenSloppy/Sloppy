import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

public struct GeminiModelProvider: ModelProvider {
    public let id: String
    public let supportedModels: [String]
    public let systemInstructions: String?
    public let tools: [any Tool]
    private let apiKey: @Sendable () -> String
    private let refreshTokenIfNeeded: (@Sendable () async throws -> Void)?
    private let baseURL: URL
    private let session: URLSession?
    private let _tokenUsageCapture: TokenUsageCapture

    public init(
        id: String = "gemini",
        supportedModels: [String],
        apiKey: @escaping @Sendable () -> String,
        refreshTokenIfNeeded: (@Sendable () async throws -> Void)? = nil,
        baseURL: URL = GeminiLanguageModel.defaultBaseURL,
        tools: [any Tool] = [],
        systemInstructions: String? = nil,
        session: URLSession? = nil,
        tokenUsageCapture: TokenUsageCapture? = nil
    ) {
        self.id = id
        self.supportedModels = supportedModels
        self.apiKey = apiKey
        self.refreshTokenIfNeeded = refreshTokenIfNeeded
        self.baseURL = baseURL
        self.tools = tools
        self.systemInstructions = systemInstructions
        self.session = session
        self._tokenUsageCapture = tokenUsageCapture ?? TokenUsageCapture()
    }

    public func supports(modelName: String) -> Bool {
        if supportedModels.contains(modelName) {
            return true
        }
        return modelName.hasPrefix("gemini:")
    }

    public func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? {
        guard supports(modelName: modelName) else { return nil }
        return _tokenUsageCapture
    }

    public func supportsUsageObservation(for modelName: String) -> Bool { supports(modelName: modelName) }
    public func createLanguageModel(for modelName: String, usageContext: ModelUsageContext) async throws -> any LanguageModel {
        let observed = UsageObservedURLSession.make(wrapping: session, context: usageContext)
        let scoped = GeminiModelProvider(id: id, supportedModels: supportedModels, apiKey: apiKey, refreshTokenIfNeeded: refreshTokenIfNeeded, baseURL: baseURL,
            tools: tools, systemInstructions: systemInstructions, session: observed)
        return try await scoped.createLanguageModel(for: modelName)
    }

    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        try await refreshTokenIfNeeded?()
        let resolved = modelName.hasPrefix("gemini:") ? String(modelName.dropFirst(7)) : modelName
        if let session {
            return GeminiLanguageModel(
                baseURL: baseURL,
                apiKey: apiKey(),
                model: resolved,
                session: session
            )
        }
        return GeminiLanguageModel(
            baseURL: baseURL,
            apiKey: apiKey(),
            model: resolved
        )
    }
}
