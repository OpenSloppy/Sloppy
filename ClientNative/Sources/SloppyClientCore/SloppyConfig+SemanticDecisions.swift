import Foundation

public extension SloppyConfig {
    struct SemanticDecisions: Codable, Sendable, Equatable {
        public enum Provider: String, Codable, Sendable, Equatable {
            case typeSafe = "typesafe"
            case vercel
            case laya

            public var title: String {
                switch self {
                case .typeSafe: "TypeSafe direct (Jev)"
                case .vercel: "Vercel AI Gateway (Jev)"
                case .laya: "Laya"
                }
            }

            public var defaultEndpoint: String {
                switch self {
                case .typeSafe: "https://api.typesafe.ai/v1/systemone"
                case .vercel: "https://ai-gateway.vercel.sh/typesafe/v1/systemone"
                case .laya: "http://127.0.0.1:8000/v1/systemone"
                }
            }

            public var defaultModel: String {
                switch self {
                case .typeSafe: "jev-latest"
                case .vercel: "typesafe-ai/jev"
                case .laya: "multilingual"
                }
            }

            public var defaultAPIKeyEnvironmentVariable: String {
                switch self {
                case .typeSafe: "TYPESAFE_API_KEY"
                case .vercel: "AI_GATEWAY_API_KEY"
                case .laya: "LAYA_API_KEY"
                }
            }
        }

        public enum Mode: String, Codable, Sendable, Equatable {
            case disabled
            case shadow
            case active
        }

        public struct ModelProfile: Codable, Sendable, Equatable {
            public var model: String
            public var description: String

            public init(model: String, description: String) {
                self.model = model
                self.description = description
            }
        }

        public var provider: Provider?
        public var apiKey: String
        public var apiKeyEnvironmentVariable: String
        public var baseURL: String?
        public var model: String
        public var maxInputTokens: Int?
        public var timeoutMs: Int
        public var executorModelRouting: Mode
        public var minimumConfidence: Double
        public var inputCostPerMillionTokensUSD: Double
        public var modelProfiles: [String: ModelProfile]

        public init(
            provider: Provider? = nil,
            apiKey: String = "",
            apiKeyEnvironmentVariable: String = "",
            baseURL: String? = nil,
            model: String = "",
            maxInputTokens: Int? = nil,
            timeoutMs: Int = 2_000,
            executorModelRouting: Mode = .disabled,
            minimumConfidence: Double = 0.75,
            inputCostPerMillionTokensUSD: Double? = nil,
            modelProfiles: [String: ModelProfile] = [:]
        ) {
            self.provider = provider
            self.apiKey = apiKey
            self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
            self.baseURL = baseURL
            self.model = model
            self.maxInputTokens = maxInputTokens.map { min(8_192, max(1, $0)) }
            self.timeoutMs = max(100, timeoutMs)
            self.executorModelRouting = executorModelRouting
            self.minimumConfidence = min(1, max(0, minimumConfidence))
            self.inputCostPerMillionTokensUSD = max(0, inputCostPerMillionTokensUSD ?? (provider == .laya ? 0 : 0.042))
            self.modelProfiles = modelProfiles
        }

        private enum CodingKeys: String, CodingKey {
            case provider
            case apiKey
            case apiKeyEnvironmentVariable
            case baseURL
            case model
            case maxInputTokens
            case timeoutMs
            case executorModelRouting
            case minimumConfidence
            case inputCostPerMillionTokensUSD
            case modelProfiles
        }

        public mutating func selectProvider(_ provider: Provider?) {
            guard self.provider != provider else { return }
            self.provider = provider
            apiKey = ""
            apiKeyEnvironmentVariable = provider?.defaultAPIKeyEnvironmentVariable ?? ""
            baseURL = nil
            model = ""
            maxInputTokens = provider == .laya ? 8_192 : nil
            inputCostPerMillionTokensUSD = provider == .laya ? 0 : 0.042
            if provider == .laya, timeoutMs == 2_000 {
                timeoutMs = 5_000
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                provider: try container.decodeIfPresent(Provider.self, forKey: .provider),
                apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
                apiKeyEnvironmentVariable: try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironmentVariable) ?? "",
                baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL),
                model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
                maxInputTokens: try container.decodeIfPresent(Int.self, forKey: .maxInputTokens),
                timeoutMs: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 2_000,
                executorModelRouting: try container.decodeIfPresent(Mode.self, forKey: .executorModelRouting) ?? .disabled,
                minimumConfidence: try container.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? 0.75,
                inputCostPerMillionTokensUSD: try container.decodeIfPresent(Double.self, forKey: .inputCostPerMillionTokensUSD),
                modelProfiles: try container.decodeIfPresent([String: ModelProfile].self, forKey: .modelProfiles) ?? [:]
            )
        }
    }

}
