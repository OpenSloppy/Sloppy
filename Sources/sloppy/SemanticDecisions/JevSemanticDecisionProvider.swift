import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct JevSemanticDecisionProvider: SemanticDecisionProvider {
    private let transport: SystemOneSemanticDecisionProvider

    init(
        endpoint: URL,
        apiKey: String,
        model: String,
        timeoutMs: Int,
        inputCostPerMillionTokensUSD: Double,
        session: URLSession? = nil
    ) {
        transport = SystemOneSemanticDecisionProvider(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            timeoutMs: timeoutMs,
            inputCostPerMillionTokensUSD: inputCostPerMillionTokensUSD,
            backend: .jev,
            session: session
        )
    }

    func choose(_ request: SemanticChoiceRequest) async throws -> SemanticChoiceResponse {
        try await transport.choose(request)
    }
}
