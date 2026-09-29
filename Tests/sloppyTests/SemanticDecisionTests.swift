import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols
import Testing
@testable import sloppy

private final class JevMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FixedSemanticDecisionProvider: SemanticDecisionProvider {
    var response: SemanticChoiceResponse

    func choose(_ request: SemanticChoiceRequest) async throws -> SemanticChoiceResponse {
        response
    }
}

private func jevTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JevMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func jevRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}

@Suite("Semantic decisions", .serialized)
struct SemanticDecisionTests {
    private var layaRequest: SemanticChoiceRequest {
        .init(
            state: "Проверь ошибку конкурентного доступа",
            questionID: "executor_profile",
            instructions: "Choose a profile.",
            choices: ["fast": "Routine work", "senior": "Complex debugging"]
        )
    }

    private func layaConfig() -> CoreConfig.SemanticDecisions {
        .init(
            provider: .laya,
            apiKeyEnvironmentVariable: "SLOPPY_TEST_UNSET_LAYA_KEY",
            maxInputTokens: 8_192,
            executorModelRouting: .active,
            modelProfiles: [
                "fast": .init(model: "mock:fast", description: "Routine work"),
                "senior": .init(model: "mock:senior", description: "Complex debugging"),
            ]
        )
    }

    @Test("Laya config round trips independently of Jev and needs no key")
    func layaConfiguration() throws {
        let config = layaConfig()
        let decoded = try JSONDecoder().decode(
            CoreConfig.SemanticDecisions.self,
            from: JSONEncoder().encode(config)
        )
        #expect(decoded == config)
        #expect(decoded.inputCostPerMillionTokensUSD == 0)
        #expect(SemanticModelRouter.defaultProvider(config: decoded) is LayaSemanticDecisionProvider)
        #expect(CoreConfig.SemanticDecisions(provider: .typeSafe).inputCostPerMillionTokensUSD == 0.042)
        #expect(CoreConfig.SemanticDecisions(provider: .vercel).inputCostPerMillionTokensUSD == 0.042)

        let minimal = try JSONDecoder().decode(
            CoreConfig.SemanticDecisions.self,
            from: Data(#"{"provider":"laya"}"#.utf8)
        )
        #expect(minimal.apiKey.isEmpty)
        #expect(minimal.maxInputTokens == nil)
        #expect(minimal.inputCostPerMillionTokensUSD == 0)
        #expect(minimal.executorModelRouting == .disabled)

        for provider in [CoreConfig.SemanticDecisions.Provider.typeSafe, .vercel] {
            #expect(SemanticModelRouter.defaultProvider(config: .init(
                provider: provider,
                apiKeyEnvironmentVariable: "SLOPPY_TEST_UNSET_JEV_KEY"
            )) == nil)
        }
    }

    @Test("Laya defaults send the System One wire request without authentication")
    func layaDefaultWireRequest() async throws {
        JevMockURLProtocol.requestHandler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:8000/v1/systemone")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(jevRequestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "multilingual")
            #expect(json["max_len"] as? Int == 8_192)
            #expect(json["state"] as? String == "Проверь ошибку конкурентного доступа")
            let questions = try #require(json["questions"] as? [String: [String: Any]])
            #expect(questions["executor_profile"]?["type"] as? String == "choice")
            #expect(questions["executor_profile"]?["criteria"] as? [String: String] == [
                "fast": "Routine work", "senior": "Complex debugging",
            ])
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"answers":{"executor_profile":{"choice":"senior","confidence":0.2,"answer_confidence":0.91,"probabilities":{"fast":0.09,"senior":0.91}}},"usage":{"input_tokens":88,"output_tokens":0}}"#.utf8))
        }
        defer { JevMockURLProtocol.requestHandler = nil }
        let provider = try #require(SemanticModelRouter.defaultProvider(config: layaConfig(), session: jevTestSession()))
        let result = try await provider.choose(layaRequest)
        #expect(result.choice == "senior")
        #expect(result.confidence == 0.91)
        #expect(result.usage.inputTokens == 88)
        #expect(result.usage.costUSD == 0)
        #expect(!result.usage.costIsEstimated)
    }

    @Test("Laya custom endpoint, checkpoint and API key override defaults")
    func layaCustomWireRequest() async throws {
        JevMockURLProtocol.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://laya.example.test/v1/systemone")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer configured-laya-key")
            let body = try #require(jevRequestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "typed-decisions")
            #expect(json["max_len"] == nil)
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"answers":{"executor_profile":{"choice":"fast","confidence":0.99,"probabilities":{"fast":0.65,"senior":0.35}}}}"#.utf8))
        }
        defer { JevMockURLProtocol.requestHandler = nil }
        var config = layaConfig()
        config.baseURL = " https://laya.example.test/v1/systemone "
        config.model = " typed-decisions "
        config.apiKey = " configured-laya-key "
        config.maxInputTokens = nil
        let provider = try #require(SemanticModelRouter.defaultProvider(config: config, session: jevTestSession()))
        let result = try await provider.choose(layaRequest)
        #expect(result.confidence == 0.65)
        #expect(result.usage.inputTokens == 0)
    }

    @Test("Laya routing gates on answer probability and records zero API spend", arguments: [0.65, 0.91])
    func layaRoutingConfidence(probability: Double) async throws {
        JevMockURLProtocol.requestHandler = { request in
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data("""
                {"answers":{"executor_profile":{"choice":"senior","confidence":0.99,"answer_confidence":\(probability)}},
                 "usage":{"input_tokens":88,"output_tokens":0},"provider_metadata":{"gateway":{"cost":0.042}}}
                """.utf8))
        }
        defer { JevMockURLProtocol.requestHandler = nil }
        let session = jevTestSession()
        let meter = SemanticDecisionUsageMeter()
        let router = SemanticModelRouter(
            config: layaConfig(), usageMeter: meter,
            providerFactory: { SemanticModelRouter.defaultProvider(config: $0, session: session) }
        )
        let route = await router.route(
            channelID: "laya", userRequest: layaRequest.state, chatMode: .debug,
            attachmentTypes: [], availableModelIDs: ["mock:fast", "mock:senior"]
        )
        #expect(route?.model == (probability >= 0.75 ? "mock:senior" : nil))
        #expect(route?.shouldApply == (probability >= 0.75 ? true : nil))
        let usage = await meter.snapshot(channelID: "laya")
        #expect(usage?.requestCount == 1)
        #expect(usage?.totalCostUSD == 0)
        #expect(usage?.includesEstimatedCost == false)
    }

    @Test("Laya errors and invalid answers fall back to the configured executor", arguments: [
        "timeout", "http", "malformed", "unknown-choice", "invalid-confidence",
    ])
    func layaFailureFallback(failure: String) async throws {
        JevMockURLProtocol.requestHandler = { request in
            if failure == "timeout" { throw URLError(.timedOut) }
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: failure == "http" ? 503 : 200, httpVersion: nil, headerFields: nil
            ))
            let body: String
            switch failure {
            case "unknown-choice": body = #"{"answers":{"executor_profile":{"choice":"unknown","answer_confidence":0.99}}}"#
            case "invalid-confidence": body = #"{"answers":{"executor_profile":{"choice":"fast","answer_confidence":1.5}}}"#
            default: body = #"{"answers":{}}"#
            }
            return (response, Data(body.utf8))
        }
        defer { JevMockURLProtocol.requestHandler = nil }
        let session = jevTestSession()
        let meter = SemanticDecisionUsageMeter()
        let router = SemanticModelRouter(
            config: layaConfig(), usageMeter: meter,
            providerFactory: { SemanticModelRouter.defaultProvider(config: $0, session: session) }
        )
        let route = await router.route(
            channelID: "laya", userRequest: layaRequest.state, chatMode: nil,
            attachmentTypes: [], availableModelIDs: ["mock:fast", "mock:senior"]
        )
        #expect(route == nil)
        #expect(await meter.snapshot(channelID: "laya") == nil)
    }

    @Test("Laya refuses endpoints without an HTTP host")
    func layaInvalidEndpoint() {
        for endpoint in ["/v1/systemone", "file:///tmp/laya", "http://"] {
            var config = layaConfig()
            config.baseURL = endpoint
            #expect(SemanticModelRouter.defaultProvider(config: config) == nil)
        }
    }

    @Test("JEV spending survives metering and aggregates within a selected period")
    func spendingByPeriod() async throws {
        let store = InMemoryPersistenceStore()
        let meter = SemanticDecisionUsageMeter(store: store)
        let older = try #require(ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))
        let first = try #require(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        let second = try #require(ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z"))

        await meter.record(channelID: "old", usage: .init(inputTokens: 20, outputTokens: 2, costUSD: 0.02, costIsEstimated: false), at: older)
        await meter.record(channelID: "current", usage: .init(inputTokens: 100, outputTokens: 5, costUSD: 0.001, costIsEstimated: false), at: first)
        await meter.record(channelID: "current", usage: .init(inputTokens: 50, outputTokens: 3, costUSD: 0.0005, costIsEstimated: true), at: second)

        let records = await store.listSemanticDecisionUsage(channelId: nil, from: first, to: second)
        let current = await meter.snapshot(channelID: "current")
        #expect(records.count == 2)
        #expect(current?.requestCount == 2)
        #expect(abs((current?.totalCostUSD ?? 0) - 0.0015) < 0.000000001)
        #expect(abs((current?.estimatedCostUSD ?? 0) - 0.0005) < 0.000000001)

        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        for record in records {
            await service.store.persistSemanticDecisionUsage(record: record)
        }
        let report = await service.semanticDecisionSpending(from: first, to: second)
        #expect(report.total.requestCount == 2)
        #expect(report.total.inputTokens == 150)
        #expect(report.total.outputTokens == 8)
        #expect(report.days.map(\.day) == ["2026-09-24"])
        #expect(report.days.first?.usage.estimatedCostUSD == 0.0005)
    }

    @Test("JEV call costs remain available after reopening SQLite")
    func spendingSurvivesStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sloppy-jev-spending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.sqlite").path
        let schema = """
            CREATE TABLE IF NOT EXISTS semantic_decision_usage (
                id TEXT PRIMARY KEY, channel_id TEXT NOT NULL,
                input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                cost_usd REAL NOT NULL, cost_is_estimated INTEGER NOT NULL,
                created_at TEXT NOT NULL
            );
            """
        let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        let firstStore = SQLiteStore(path: path, schemaSQL: schema)
        await firstStore.persistSemanticDecisionUsage(record: .init(
            id: "jev-1", channelId: "agent:a:session:s", inputTokens: 88, outputTokens: 4,
            costUSD: 0.00001155, costIsEstimated: false, createdAt: timestamp
        ))

        let reopenedStore = SQLiteStore(path: path, schemaSQL: schema)
        let records = await reopenedStore.listSemanticDecisionUsage(channelId: "agent:a:session:s", from: timestamp, to: timestamp)
        #expect(records.count == 1)
        #expect(records.first?.id == "jev-1")
        #expect(records.first?.costUSD == 0.00001155)
    }

    @Test("spending endpoint filters JEV calls by date")
    func spendingEndpointFiltersDates() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        await service.store.persistSemanticDecisionUsage(record: .init(
            id: "jev-http-1", channelId: "agent:a:session:s", inputTokens: 88, outputTokens: 4,
            costUSD: 0.00001155, costIsEstimated: false, createdAt: timestamp
        ))
        let router = CoreRouter(service: service)
        let response = await router.handle(
            method: "GET",
            path: "/v1/semantic-decisions/spending?from=2026-09-24T00:00:00Z&to=2026-09-24T23:59:59Z",
            body: nil
        )
        let payload = try JSONDecoder().decode(SemanticDecisionSpendingResponse.self, from: response.body)
        #expect(response.status == 200)
        #expect(payload.total.requestCount == 1)
        #expect(payload.days.map(\.day) == ["2026-09-24"])
    }

    @Test("legacy configs keep semantic decisions disabled")
    func legacyConfigDefaults() throws {
        let encoded = try JSONEncoder().encode(CoreConfig.test)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "semanticDecisions")

        let decoded = try JSONDecoder().decode(
            CoreConfig.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.semanticDecisions.provider == nil)
        #expect(decoded.semanticDecisions.executorModelRouting == .disabled)
        #expect(decoded.semanticDecisions.modelProfiles.isEmpty)
    }

    @Test("semantic decision config accepts a Dashboard API key and older payloads without it")
    func configAPIKeyRoundTripAndCompatibility() throws {
        let configured = CoreConfig.SemanticDecisions(
            provider: .typeSafe,
            apiKey: "dashboard-key",
            executorModelRouting: .shadow,
            modelProfiles: [
                "fast": .init(model: "mock:fast", description: "Routine"),
                "senior": .init(model: "mock:senior", description: "Complex"),
            ]
        )
        let encoded = try JSONEncoder().encode(configured)
        let decoded = try JSONDecoder().decode(CoreConfig.SemanticDecisions.self, from: encoded)
        #expect(decoded.apiKey == "dashboard-key")
        #expect(SemanticModelRouter.defaultProvider(config: decoded) != nil)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "apiKey")
        let legacy = try JSONDecoder().decode(
            CoreConfig.SemanticDecisions.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.apiKey.isEmpty)
        #expect(legacy.executorModelRouting == .shadow)
    }

    @Test("JEV adapter reads a typed choice and provider-reported Vercel cost")
    func jevChoiceAndReportedCost() async throws {
        JevMockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try #require(jevRequestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "typesafe-ai/jev")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            let data = Data(
                """
                {
                  "model": "typesafe-ai/jev",
                  "answers": {
                    "executor_profile": {
                      "type": "choice",
                      "choice": "senior",
                      "confidence": 0.91,
                      "probabilities": { "fast": 0.09, "senior": 0.91 }
                    }
                  },
                  "usage": { "input_tokens": 275, "output_tokens": 20 },
                  "provider_metadata": { "gateway": { "cost": "0.00001155" } }
                }
                """.utf8
            )
            return (response, data)
        }
        defer { JevMockURLProtocol.requestHandler = nil }

        let provider = JevSemanticDecisionProvider(
            endpoint: try #require(URL(string: "https://example.test/typesafe/v1/systemone")),
            apiKey: "test-key",
            model: "typesafe-ai/jev",
            timeoutMs: 1_000,
            inputCostPerMillionTokensUSD: 0.042,
            session: jevTestSession()
        )
        let result = try await provider.choose(
            SemanticChoiceRequest(
                state: "{}",
                questionID: "executor_profile",
                instructions: "Choose a profile.",
                choices: ["fast": "Routine", "senior": "Complex"]
            )
        )

        #expect(result.choice == "senior")
        #expect(result.confidence == 0.91)
        #expect(result.usage.inputTokens == 275)
        #expect(result.usage.costUSD == 0.00001155)
        #expect(result.usage.costIsEstimated == false)
    }

    @Test("direct JEV cost is estimated from input tokens")
    func directCostEstimate() async throws {
        JevMockURLProtocol.requestHandler = { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (
                response,
                Data("""
                {
                  "answers": {
                    "executor_profile": {
                      "choice": "fast",
                      "confidence": 0.8,
                      "probabilities": { "fast": 0.8, "senior": 0.2 }
                    }
                  },
                  "usage": { "input_tokens": 1000000, "output_tokens": 10 }
                }
                """.utf8)
            )
        }
        defer { JevMockURLProtocol.requestHandler = nil }

        let provider = JevSemanticDecisionProvider(
            endpoint: try #require(URL(string: "https://example.test/v1/systemone")),
            apiKey: "test-key",
            model: "jev-latest",
            timeoutMs: 1_000,
            inputCostPerMillionTokensUSD: 0.042,
            session: jevTestSession()
        )
        let result = try await provider.choose(
            SemanticChoiceRequest(
                state: "{}",
                questionID: "executor_profile",
                instructions: "Choose a profile.",
                choices: ["fast": "Routine", "senior": "Complex"]
            )
        )

        #expect(result.usage.costUSD == 0.042)
        #expect(result.usage.costIsEstimated)
    }

    @Test("active routing applies an eligible confident profile and meters usage")
    func activeModelRouting() async throws {
        let usageMeter = SemanticDecisionUsageMeter()
        let fixed = FixedSemanticDecisionProvider(
            response: SemanticChoiceResponse(
                choice: "senior",
                confidence: 0.92,
                probabilities: ["fast": 0.08, "senior": 0.92],
                usage: .init(inputTokens: 300, outputTokens: 15, costUSD: 0.0000126, costIsEstimated: true)
            )
        )
        let config = CoreConfig.SemanticDecisions(
            provider: .typeSafe,
            executorModelRouting: .active,
            minimumConfidence: 0.75,
            modelProfiles: [
                "fast": .init(model: "mock:fast", description: "Routine work"),
                "senior": .init(model: "mock:senior", description: "Complex work"),
            ]
        )
        let router = SemanticModelRouter(
            config: config,
            usageMeter: usageMeter,
            providerFactory: { _ in fixed }
        )

        let route = await router.route(
            channelID: "agent:a:session:s",
            userRequest: "Diagnose a concurrency crash",
            chatMode: .debug,
            attachmentTypes: ["text/plain"],
            availableModelIDs: ["mock:fast", "mock:senior"]
        )
        let usage = await usageMeter.snapshot(channelID: "agent:a:session:s")

        #expect(route?.profile == "senior")
        #expect(route?.model == "mock:senior")
        #expect(route?.shouldApply == true)
        #expect(usage?.requestCount == 1)
        #expect(usage?.totalCostUSD == 0.0000126)
        #expect(usage?.includesEstimatedCost == true)
    }

    @Test("shadow routing records spend without applying the selected model")
    func shadowModelRouting() async {
        let usageMeter = SemanticDecisionUsageMeter()
        let fixed = FixedSemanticDecisionProvider(
            response: .init(
                choice: "fast",
                confidence: 0.99,
                probabilities: ["fast": 0.99, "senior": 0.01],
                usage: .init(inputTokens: 50, outputTokens: 5, costUSD: 0.0000021, costIsEstimated: true)
            )
        )
        let router = SemanticModelRouter(
            config: .init(
                provider: .typeSafe,
                executorModelRouting: .shadow,
                modelProfiles: [
                    "fast": .init(model: "mock:fast", description: "Routine work"),
                    "senior": .init(model: "mock:senior", description: "Complex work"),
                ]
            ),
            usageMeter: usageMeter,
            providerFactory: { _ in fixed }
        )

        let route = await router.route(
            channelID: "agent:a:session:shadow",
            userRequest: "Answer a simple question",
            chatMode: .ask,
            attachmentTypes: [],
            availableModelIDs: ["mock:fast", "mock:senior"]
        )

        #expect(route?.profile == "fast")
        #expect(route?.shouldApply == false)
        #expect(await usageMeter.snapshot(channelID: "agent:a:session:shadow")?.requestCount == 1)
    }

    @Test("context status shows JEV calls and estimated spend")
    func contextStatusShowsJevSpend() {
        let summary = SloppyTUIContextUsageSummary(
            modelTitle: "Test model",
            modelID: "mock:test",
            contextWindowLabel: "32K",
            promptTokens: 1_000,
            completionTokens: 100,
            totalTokens: 1_100,
            contextWindowTokens: 32_000,
            pendingContextAttached: false,
            pendingUploadCount: 0,
            semanticDecisionUsage: SemanticDecisionUsage(
                requestCount: 3,
                inputTokens: 1_200,
                outputTokens: 60,
                totalCostUSD: 0.0042,
                estimatedCostUSD: 0.0042
            )
        )

        let markdown = SloppyTUITheme.contextUsageMarkdown(summary)

        #expect(markdown.contains("Routing decisions:"))
        #expect(markdown.contains("3 calls"))
        #expect(markdown.contains("1.2K input tokens"))
        #expect(markdown.contains("~$0.0042"))
    }
}
