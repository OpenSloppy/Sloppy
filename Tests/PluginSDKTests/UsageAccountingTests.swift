import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Protocols
@testable import PluginSDK

@Suite struct UsageAccountingTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }
    private func context(model: String = "openai-api:gpt-4o") -> ModelUsageContext {
        var provenance = UsageProvenance()
        provenance.toolNameMap = ["files_read":"files.read","mcp_lookup":"mcp.search"]
        provenance.toolServers = ["mcp.search":"research"]
        provenance.skills = [.init(id:"research",directory:"/private/tmp/usage-skill",catalogEntry:"- research | entrypoint")]
        return .init(channelId:"agent:a:session:s",provider:"openai-api",model:model,provenance:provenance,onRequest:{ _ in })
    }
    @Test func tokenizerMatchesReferenceCounts() async {
        for model in ["openai-api:gpt-4o","openai-api:gpt-4"] {
            let hello = await UsageTokenCounter.shared.count("Hello, world!", model:model)
            #expect(hello.tokens == 4)
            #expect(hello.method == .tokenizer)
            #expect(hello.encoding != nil)
            #expect(await UsageTokenCounter.shared.count("",model:model).tokens == 0)
        }
        #expect(await UsageTokenCounter.shared.count("Привет, мир!",model:"gpt-4o").tokens == 5)
        #expect(await UsageTokenCounter.shared.count("Привет, мир!",model:"gpt-4").tokens == 7)
    }
    // Fixtures generated with the reference Python tiktoken 0.12.0, using the same vocabulary hashes.
    @Test func codeJSONAndUnicodeMatchReferenceTokenizer() async {
        let fixtures: [(String, Int, Int)] = [
            ("let value = [1, 2, 3]\nprint(value)", 15, 15),
            (#"{"query":"Swift actor","limit":10}"#, 10, 10),
            ("日本語 👩🏽‍💻 é\nمرحبا", 21, 14),
            ("1234567890\n\n   ", 6, 6)
        ]
        for (text, cl, o) in fixtures {
            #expect(await UsageTokenCounter.shared.count(text, model: "gpt-4").tokens == cl)
            #expect(await UsageTokenCounter.shared.count(text, model: "gpt-4o").tokens == o)
        }
    }
    @Test func unknownModelNeverInheritsTokenizer() async {
        let count = await UsageTokenCounter.shared.count("Привет, мир!",model:"openai-api:future-model")
        #expect(count.method == .estimate)
        #expect(count.encoding == nil)
        #expect(UsageTokenCounter.encoding(for:"ollama:gpt-4o-custom") == nil)
    }
    @Test func responsesRoundTripUsesSentResultsAndActualCallIds() async {
        let decoder = UsageWireDecoder(context:context())
        let first = await decoder.record(requestId:"r1",body:data(#"{"model":"gpt-4o","instructions":"- research | entrypoint","tools":[{"type":"function","name":"files_read","parameters":{"type":"object"}}],"input":[]}"#),
            response:data(#"{"usage":{"input_tokens":100,"output_tokens":20},"output":[{"type":"function_call","call_id":"c1","name":"files_read","arguments":"{\"path\":\"/private/tmp/usage-skill/SKILL.md\"}"}]}"#),createdAt:Date(),failed:false)
        #expect(first.usage?.prompt == 100)
        #expect(first.calls.count == 1)
        #expect(first.calls.first?.skillId == "research")
        #expect(first.components.contains { $0.kind == .toolSchema })
        #expect(first.components.contains { $0.kind == .skillCatalog })
        let followUp = await decoder.record(requestId:"r2",body:data(#"{"input":[{"type":"function_call","call_id":"c1","name":"files_read","arguments":"{\"path\":\"/private/tmp/usage-skill/SKILL.md\"}"},{"type":"function_call_output","call_id":"c1","output":"{\"ok\":true,\"data\":{\"content\":\"Only the bounded output\"}}"}]}"#),
            response:data(#"{"usage":{"input_tokens":130,"output_tokens":10}}"#),createdAt:Date(),failed:false)
        #expect(followUp.components.filter { $0.kind == .resultInput }.count == 1)
        #expect(followUp.components.first { $0.kind == .resultInput }?.skillId == "research")
        #expect(followUp.calls.first?.generated == false)
        #expect(followUp.calls.first?.ok == true)
        let compacted = await decoder.record(requestId:"r3",body:data(#"{"input":[{"role":"user","content":"Historical summary"}]}"#),
            response:data(#"{"usage":{"input_tokens":20,"output_tokens":10}}"#),createdAt:Date(),failed:false)
        #expect(compacted.components.isEmpty)
    }
    @Test func anthropicStreamingUsageIncludesCacheWithoutDoubleCounting() async {
        let stream = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}}}
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a1","name":"mcp_lookup","input":{}}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"query\\\":\\\"swift\\\"}"}}
        data: {"type":"message_delta","usage":{"output_tokens":12}}
        """
        let result = await UsageWireDecoder(context:context(model:"anthropic:claude-test")).record(requestId:"a",body:data(#"{"model":"claude-test","system":"instructions","max_tokens":100,"messages":[]}"#),response:data(stream),createdAt:Date(),failed:false)
        #expect(result.usage?.prompt == 35)
        #expect(result.usage?.completion == 12)
        #expect(result.usage?.cachedInput == 20)
        #expect(result.calls.first?.serverId == "research")
        #expect(result.components.first?.method == .estimate)
    }
    @Test func failuresAndMediaPreserveUsageWithIncompleteCoverage() async {
        let decoder = UsageWireDecoder(context:context())
        let result = await decoder.record(requestId:"failed",body:data(#"{"input":[{"role":"user","content":[{"type":"input_image","image_url":"redacted"}]}]}"#),
            response:data(#"{"usage":{"input_tokens":22,"output_tokens":3}}"#),createdAt:Date(),failed:true)
        #expect(result.failed)
        #expect(!result.complete)
        #expect(result.usage?.total == 25)
        let unknown = await decoder.record(requestId:"missing",body:nil,response:Data(),createdAt:Date(),failed:true)
        #expect(unknown.usage == nil)
        #expect(!unknown.complete)
    }
    @Test func unlinkedOllamaCallsAndProviderErrorsNeverClaimFullCoverage() async {
        let decoder = UsageWireDecoder(context: context(model: "ollama:local"))
        let result = await decoder.record(requestId: "local", body: data(#"{"messages":[{"role":"assistant","tool_calls":[{"function":{"name":"files_read","arguments":{}}}]}]}"#),
            response: data(#"{"prompt_eval_count":10,"eval_count":5,"message":{"tool_calls":[{"function":{"name":"files_read","arguments":{}}}]}}"#), createdAt: Date(), failed: false)
        #expect(result.usage?.total == 15)
        #expect(!result.complete)
        let failed = await decoder.record(requestId: "failed", body: data(#"{"input":[]}"#),
            response: data(#"{"type":"response.failed","response":{"usage":{"input_tokens":10,"output_tokens":3},"error":{"code":"test"}}}"#), createdAt: Date(), failed: false)
        #expect(failed.failed)
        #expect(failed.usage?.total == 13)
    }
    @Test func multimediaToolResultHasExplicitUnavailableMeasurement() async {
        let decoder = UsageWireDecoder(context: context())
        let result = await decoder.record(requestId: "media", body: data(#"{"messages":[{"role":"assistant","tool_calls":[{"id":"c","function":{"name":"mcp_lookup","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c","content":[{"type":"image_url","image_url":{"url":"redacted"}},{"type":"text","text":"caption"}]}]}"#),
            response: data(#"{"usage":{"prompt_tokens":20,"completion_tokens":5}}"#), createdAt: Date(), failed: false)
        #expect(!result.complete)
        #expect(result.components.contains { $0.toolCallId == "c" && $0.method == .unavailable && $0.tokens == nil })
    }
    @Test func restoredHistoryIsReplayWithoutInventingAnObservedGeneration() async {
        let result = await UsageWireDecoder(context: context()).record(requestId: "restored", body: data(#"{"input":[{"type":"function_call","call_id":"old","name":"mcp_lookup","arguments":"{}"},{"type":"function_call_output","call_id":"old","output":"old result"}]}"#),
            response: data(#"{"usage":{"input_tokens":20,"output_tokens":5}}"#), createdAt: Date(), failed: false)
        #expect(!result.complete)
        #expect(result.calls.allSatisfy { !$0.generated })
        #expect(result.components.first { $0.kind == .resultInput }?.repeated == true)
    }
    @Test func skillReadCannotEscapeThroughSymlinkOrRelativePath() async {
        let decoder = UsageWireDecoder(context:context())
        let result = await decoder.record(requestId:"r",body:data(#"{"input":[]}"#),response:data(#"{"output":[{"type":"function_call","call_id":"c","name":"files_read","arguments":"{\"path\":\"/private/tmp/usage-skill-other/SKILL.md\"}"}]}"#),createdAt:Date(),failed:false)
        #expect(result.calls.first?.skillId == nil)
    }
}
