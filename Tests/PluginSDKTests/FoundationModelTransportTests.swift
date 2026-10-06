import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import Protocols
import Testing
@testable import PluginSDK

@Suite("Foundation model transport")
struct FoundationModelTransportTests {
    @Test func sdkSessionKeepsFoundationType() {
        let foundation = URLSession(configuration: .ephemeral)
        let sdk: HTTPSession = foundation
        #expect(sdk === foundation)
        foundation.invalidateAndCancel()
    }

    @Test func geminiPreservesCustomProtocolsHeadersAndUsageObservation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiTransportStub.self]
        configuration.httpAdditionalHeaders = ["X-Transport-Test": "preserved"]
        let base = URLSession(configuration: configuration)
        defer { base.invalidateAndCancel() }
        let records = GeminiTransportRecords()
        let provider = GeminiModelProvider(
            supportedModels: ["gemini:test-model"], apiKey: { "test-key" },
            refreshTokenIfNeeded: { await records.refreshed() },
            baseURL: try #require(URL(string: "https://gemini-transport.invalid")),
            session: base
        )
        let model = try await provider.createLanguageModel(
            for: "gemini:test-model", usageContext: .init(
                channelId: "agent:test:session:transport", provider: "gemini", model: "test-model",
                onRequest: { await records.append($0) }
            )
        )
        let response = try await LanguageModelSession(model: model).respond(to: "Hello")
        #expect(response.content == "Ready.")
        #expect(await records.refreshCount == 1)
        let usage = await records.records
        #expect(usage.count == 1)
        #expect(usage.first?.usage?.total == 13)
        #expect(usage.first?.complete == true)
    }
}

private actor GeminiTransportRecords {
    private(set) var records: [UsageRequestRecord] = []
    private(set) var refreshCount = 0
    func append(_ record: UsageRequestRecord) { records.append(record) }
    func refreshed() { refreshCount += 1 }
}

private final class GeminiTransportStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gemini-transport.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "X-Transport-Test") == "preserved",
              request.value(forHTTPHeaderField: "x-sloppy-usage-observation") == nil,
              url.path.hasSuffix("test-model:generateContent"),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let payload = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Ready."}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":3,"totalTokenCount":13}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
