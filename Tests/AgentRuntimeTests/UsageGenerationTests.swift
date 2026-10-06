import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import PluginSDK
import Protocols
@testable import AgentRuntime

private actor GenerationUsageRecords {
    var records: [UsageRequestRecord] = []
    func append(_ record: UsageRequestRecord) { records.append(record) }
}
private final class GenerationUsageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chatgpt.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/event-stream"]) else { return }
        let stream = """
        data: {"type":"response.output_text.delta","delta":"Plan."}
        data: {"type":"response.completed","response":{"id":"fixture","status":"completed","usage":{"input_tokens":40,"output_tokens":15},"output":[]}}
        data: [DONE]

        """
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct UsageGenerationTests {
    @Test func plannerGenerationPersistsItsOwnRequestOnTheSessionChannel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GenerationUsageProtocol.self]
        let base = URLSession(configuration:config)
        defer { base.invalidateAndCancel() }
        let provider = OpenAIModelProvider(supportedModels:["openai-oauth:gpt-4o"],
            settings:.init(apiKey:{ "fixture-bearer" },session:base,modelIdentifierPrefix:"openai-oauth:",useOpenAICodexOAuthPath:true))
        let runtime = RuntimeSystem(modelProvider:provider,defaultModel:"openai-oauth:gpt-4o")
        let records = GenerationUsageRecords()
        await runtime.configureUsageAccounting(onRequest:{ await records.append($0) },
            provenance:{ _ in UsageProvenance() },onToolOutcome:{ _,_,_ in })
        let plan = await runtime.generateText(prompt:"Plan a task",model:"openai-oauth:gpt-4o",channelId:"agent:a:session:s")
        #expect(plan == "Plan.")
        let observed = await records.records
        #expect(observed.count == 1)
        #expect(observed.first?.channelId == "agent:a:session:s")
        #expect(observed.first?.sessionId == "s")
        #expect(observed.first?.usage?.total == 55)
    }
}
