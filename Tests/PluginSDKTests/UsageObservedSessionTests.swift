import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import AnyLanguageModel
import Protocols
@testable import PluginSDK

private actor UsageRecordBox {
    var records: [UsageRequestRecord] = []
    func append(_ record: UsageRequestRecord) { records.append(record) }
    func snapshot() -> [UsageRequestRecord] { records }
}
private final class UsageStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { ["usage.invalid", "chatgpt.com"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]) else { return }
        if request.url?.path.hasSuffix("/responses") == true {
            let stream = """
            data: {"type":"response.reasoning_summary_text.delta","delta":"Thinking."}
            data: {"type":"response.output_text.delta","delta":"Done."}
            data: {"type":"response.completed","response":{"id":"r-oauth","status":"completed","usage":{"input_tokens":40,"output_tokens":15},"output":[]}}
            data: [DONE]

            """
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stream.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let content = request.url?.path == "/first" ? #"{"usage":{"input_tokens":10,"output_tokens":5},"output":[{"type":"function_call","call_id":"one","name":"lookup","arguments":"{}"}]}"# : #"{"usage":{"input_tokens":25,"output_tokens":6}}"#
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(content.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite struct UsageObservedSessionTests {
    @Test func actualRequestsCompleteOnlyAfterAccountingAndRemainSessionScoped() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageStubProtocol.self]
        let base = URLSession(configuration:config)
        let box = UsageRecordBox()
        let observed = UsageObservedURLSession.make(wrapping:base,context:.init(channelId:"agent:a:session:one",provider:"openai-api",model:"gpt-4o",onRequest:{ await box.append($0) }))
        let other = UsageObservedURLSession.make(wrapping:base,context:.init(channelId:"agent:a:session:two",provider:"openai-api",model:"gpt-4o",onRequest:{ await box.append($0) }))
        defer { observed.invalidateAndCancel(); other.invalidateAndCancel(); base.invalidateAndCancel() }
        func request(_ path: String) throws -> URLRequest {
            var request = URLRequest(url:try #require(URL(string:"https://usage.invalid/"+path)))
            request.httpMethod="POST"; request.httpBody=Data(#"{"input":[],"model":"gpt-4o"}"#.utf8)
            return request
        }
        _ = try await observed.data(for:request("first"))
        #expect(await box.snapshot().count == 1)
        async let second = observed.data(for:request("second"))
        async let concurrent = other.data(for:request("second"))
        _ = try await (second,concurrent)
        let records = await box.snapshot()
        #expect(records.count == 3)
        #expect(Set(records.map(\.id)).count == 3)
        #expect(records.filter { $0.channelId == "agent:a:session:one" }.count == 2)
        #expect(records.reduce(0) { $0 + ($1.usage?.total ?? 0) } == 77)
        #expect(records.allSatisfy { $0.complete })
    }
    @Test func oauthUsesObservedSessionAndKeepsOriginalReasoningCapture() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageStubProtocol.self]
        let base = URLSession(configuration: config)
        let records = UsageRecordBox()
        let provider = OpenAIModelProvider(supportedModels: ["openai-oauth:gpt-4o"],
            settings: .init(apiKey: { "fixture-oauth-bearer" }, session: base,
                modelIdentifierPrefix: "openai-oauth:", useOpenAICodexOAuthPath: true))
        let context = ModelUsageContext(channelId: "agent:a:session:oauth", provider: "openai-oauth", model: "gpt-4o", onRequest: { await records.append($0) })
        let model = try await provider.createLanguageModel(for: "openai-oauth:gpt-4o", usageContext: context)
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: "Hi")
        #expect(response.content == "Done.")
        #expect(provider.reasoningCapture(for: "openai-oauth:gpt-4o")?.consume() == "Thinking.")
        #expect(provider.tokenUsageCapture(for: "openai-oauth:gpt-4o")?.consume() == nil)
        let recorded = await records.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.first?.usage?.total == 55)
        #expect(recorded.first?.complete == true)
        base.invalidateAndCancel()
    }
    @Test func legacyCaptureRetainsEveryRequestAndDeduplicatesStreamUpdates() {
        let capture = TokenUsageCapture()
        capture.store(promptTokens:10,completionTokens:2,requestId:"one")
        capture.store(promptTokens:10,completionTokens:5,requestId:"one")
        capture.store(promptTokens:20,completionTokens:7,requestId:"two")
        let records = capture.consumeRecords()
        #expect(records.count == 2)
        #expect(records.reduce(0) { $0 + $1.usage.total } == 42)
        #expect(capture.consumeRecords().isEmpty)
    }
}
