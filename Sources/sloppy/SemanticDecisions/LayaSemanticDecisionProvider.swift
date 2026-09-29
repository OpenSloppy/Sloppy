import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LayaSemanticDecisionProvider: SemanticDecisionProvider {
    static let defaultEndpoint = "http://127.0.0.1:8000/v1/systemone"
    static let defaultModel = "multilingual"

    private let transport: SystemOneSemanticDecisionProvider

    init(
        endpoint: URL,
        apiKey: String = "",
        model: String = defaultModel,
        timeoutMs: Int,
        maxInputTokens: Int? = nil,
        session: URLSession? = nil
    ) {
        transport = SystemOneSemanticDecisionProvider(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            timeoutMs: timeoutMs,
            inputCostPerMillionTokensUSD: 0,
            backend: .laya,
            maxInputTokens: maxInputTokens,
            session: session
        )
    }

    func choose(_ request: SemanticChoiceRequest) async throws -> SemanticChoiceResponse {
        try await transport.choose(request)
    }
}
