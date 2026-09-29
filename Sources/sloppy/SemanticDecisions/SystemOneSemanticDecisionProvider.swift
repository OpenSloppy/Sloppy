import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SystemOneSemanticDecisionProviderError: Error, Equatable {
    case invalidEndpoint
    case invalidRequest
    case httpStatus(Int)
    case invalidResponse
}

struct SystemOneSemanticDecisionProvider: SemanticDecisionProvider {
    enum Backend: Sendable {
        case jev
        case laya
    }

    private struct RequestBody: Encodable {
        struct Question: Encodable {
            var type: String
            var instructions: String
            var criteria: [String: String]
        }

        var state: String
        var model: String
        var questions: [String: Question]
        var maxInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case state, model, questions
            case maxInputTokens = "max_len"
        }
    }

    private struct ResponseBody: Decodable {
        struct Answer: Decodable {
            var choice: String?
            var confidence: Double?
            var answerConfidence: Double?
            var probabilities: [String: Double]?

            enum CodingKeys: String, CodingKey {
                case choice, confidence, probabilities
                case answerConfidence = "answer_confidence"
            }
        }

        struct Usage: Decodable {
            var inputTokens: Int
            var outputTokens: Int

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        struct ProviderMetadata: Decodable {
            struct Gateway: Decodable {
                var cost: FlexibleDouble?
            }

            var gateway: Gateway?
        }

        var answers: [String: Answer]
        var usage: Usage?
        var providerMetadata: ProviderMetadata?

        enum CodingKeys: String, CodingKey {
            case answers
            case usage
            case providerMetadata = "provider_metadata"
        }
    }

    private struct FlexibleDouble: Decodable {
        var value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
                return
            }
            let string = try container.decode(String.self)
            guard let number = Double(string) else {
                throw SystemOneSemanticDecisionProviderError.invalidResponse
            }
            value = number
        }
    }

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let inputCostPerMillionTokensUSD: Double
    private let session: URLSession
    private let backend: Backend
    private let maxInputTokens: Int?

    init(
        endpoint: URL,
        apiKey: String,
        model: String,
        timeoutMs: Int,
        inputCostPerMillionTokensUSD: Double,
        backend: Backend,
        maxInputTokens: Int? = nil,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.inputCostPerMillionTokensUSD = max(0, inputCostPerMillionTokensUSD)
        self.backend = backend
        self.maxInputTokens = maxInputTokens
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = TimeInterval(max(100, timeoutMs)) / 1_000
            configuration.timeoutIntervalForResource = TimeInterval(max(100, timeoutMs)) / 1_000
            self.session = URLSession(configuration: configuration)
        }
    }

    func choose(_ request: SemanticChoiceRequest) async throws -> SemanticChoiceResponse {
        guard !request.questionID.isEmpty, !request.choices.isEmpty else {
            throw SystemOneSemanticDecisionProviderError.invalidRequest
        }
        let body = RequestBody(
            state: request.state,
            model: model,
            questions: [
                request.questionID: .init(
                    type: "choice",
                    instructions: request.instructions,
                    criteria: request.choices
                )
            ],
            maxInputTokens: maxInputTokens
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw SystemOneSemanticDecisionProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SystemOneSemanticDecisionProviderError.httpStatus(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let answer = decoded.answers[request.questionID],
              let choice = answer.choice,
              request.choices[choice] != nil
        else {
            throw SystemOneSemanticDecisionProviderError.invalidResponse
        }

        let inputTokens = max(0, decoded.usage?.inputTokens ?? 0)
        let outputTokens = max(0, decoded.usage?.outputTokens ?? 0)
        let reportedCost = decoded.providerMetadata?.gateway?.cost?.value
        let estimatedCost = Double(inputTokens) * inputCostPerMillionTokensUSD / 1_000_000
        let confidence: Double
        switch backend {
        case .jev:
            confidence = answer.confidence ?? answer.probabilities?[choice] ?? 0
        case .laya:
            // Laya's `confidence` is entropy-based. Gate on the selected answer's
            // probability instead, including responses from older Laya servers.
            confidence = answer.answerConfidence ?? answer.probabilities?[choice] ?? 0
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw SystemOneSemanticDecisionProviderError.invalidResponse
        }
        return SemanticChoiceResponse(
            choice: choice,
            confidence: confidence,
            probabilities: answer.probabilities ?? [:],
            usage: SemanticDecisionCallUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                costUSD: backend == .laya ? 0 : max(0, reportedCost ?? estimatedCost),
                costIsEstimated: backend == .jev && reportedCost == nil
            )
        )
    }
}
