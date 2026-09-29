import Foundation
import SloppyClientCore
import Testing

@Suite("Semantic decisions config")
struct SemanticDecisionsConfigTests {
    @Test("Native config saves preserve Laya provider settings and executor profiles")
    func nativeConfigRoundTrip() throws {
        var config = SloppyConfig()
        config.semanticDecisions = .init(
            provider: .laya, baseURL: "http://laya.test:8000/v1/systemone", model: "multilingual",
            maxInputTokens: 8_192, executorModelRouting: .shadow,
            modelProfiles: ["fast": .init(model: "mock:fast", description: "Routine")]
        )
        let reopened = try JSONDecoder().decode(SloppyConfig.self, from: JSONEncoder().encode(config))
        #expect(reopened.semanticDecisions == config.semanticDecisions)
        #expect(reopened.semanticDecisions.inputCostPerMillionTokensUSD == 0)
    }

    @Test("Native provider switching clears previous credentials and preserves routing")
    func switchingProvider() {
        var config = SloppyConfig.SemanticDecisions(
            provider: .vercel, apiKey: "jev-secret", baseURL: "https://custom.test", model: "typesafe-ai/jev",
            executorModelRouting: .active,
            modelProfiles: ["fast": .init(model: "mock:fast", description: "Routine")]
        )
        config.selectProvider(.laya)
        #expect(config.provider == .laya)
        #expect(config.apiKey.isEmpty)
        #expect(config.baseURL == nil)
        #expect(config.model.isEmpty)
        #expect(config.apiKeyEnvironmentVariable == "LAYA_API_KEY")
        #expect(config.maxInputTokens == 8_192)
        #expect(config.timeoutMs == 5_000)
        #expect(config.inputCostPerMillionTokensUSD == 0)
        #expect(config.executorModelRouting == .active)
        #expect(config.modelProfiles["fast"]?.model == "mock:fast")
        config.apiKey = "laya-key"
        config.selectProvider(.laya)
        #expect(config.apiKey == "laya-key")
        config.selectProvider(.typeSafe)
        #expect(config.apiKey.isEmpty)
        #expect(config.apiKeyEnvironmentVariable == "TYPESAFE_API_KEY")
        #expect(config.inputCostPerMillionTokensUSD == 0.042)
        #expect(config.maxInputTokens == nil)
    }

    @Test("Native legacy configs keep semantic routing disabled")
    func legacyDefaults() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SloppyConfig())) as? [String: Any])
        object.removeValue(forKey: "semanticDecisions")
        let config = try JSONDecoder().decode(SloppyConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(config.semanticDecisions.provider == nil)
        #expect(config.semanticDecisions.executorModelRouting == .disabled)
    }
}
