import AnyLanguageModel
import Foundation
import Testing
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

@Suite
struct MemoryDebugAPITests {
    @Test
    func debugAPIReportsToolQueriesActualContextAndReadsPassively() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        _ = try await service.createAgent(.init(id: "memory-debug", displayName: "Memory Debug", role: "Test"))
        let session = try await service.createAgentSession(agentID: "memory-debug", request: .init(title: "Debug"))
        let channel = "agent:memory-debug:session:\(session.id)"
        let curated = "# Memory\nCurated fact"
        try await service.applyAgentMarkdownFromTool(agentID: "memory-debug", field: .memory, markdown: curated)
        let savedConfig = try await service.getAgentConfigWithMemory(agentID: "memory-debug")
        let savedMemory = savedConfig.documents.memoryMarkdown
        _ = await service.memoryStore.save(entry: MemoryWriteRequest(note: "Aurora uses Swift", scope: .agent("memory-debug")))
        for tool in ["memory.search", "memory.recall"] {
            let result = await service.invokeToolFromRuntime(agentID: "memory-debug", sessionID: session.id,
                request: .init(tool: tool, arguments: [
                    "query": .string("Aurora"), "scope_type": .string("agent"), "scope_id": .string("memory-debug")
                ]))
            #expect(result.ok)
        }
        await service.runtime.captureModelContext(channelId: channel, model: "mock", transcript: Transcript(),
            userMessage: "Actual prepared request", images: [], tools: [], options: GenerationOptions())
        let queryCount = await service.runtime.memoryDiagnostics.snapshot(channelId: channel).queries.count
        let router = CoreRouter(service: service)
        for _ in 0..<2 {
            let response = await router.handle(method: "GET", path: "/v1/debug/session-context/memory-debug/\(session.id)", body: nil)
            #expect(response.status == 200)
            let payload = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let sizes = try #require(payload["documentSizes"] as? [String: Int])
            #expect(sizes["memoryMarkdown"] == savedMemory.count)
            let debug = try #require(payload["memoryDiagnostics"] as? [String: Any])
            let queries = try #require(debug["queries"] as? [[String: Any]])
            #expect(queries.count == queryCount)
            let toolQueries = queries.filter { ["memory.search", "memory.recall"].contains($0["source"] as? String ?? "") }
            #expect(toolQueries.count == 2)
            #expect(Set(toolQueries.compactMap { $0["source"] as? String }) == ["memory.search", "memory.recall"])
            #expect(toolQueries.allSatisfy { ($0["resultCount"] as? Int) == 1 })
            let context = try #require(debug["modelContext"] as? [String: Any])
            let entries = try #require(context["entries"] as? [[String: Any]])
            #expect(entries.last?["content"] as? String == "Actual prepared request")
        }
        #expect(await service.runtime.memoryDiagnostics.snapshot(channelId: "agent:other:session:other").queries.isEmpty)
    }

    @Test
    func hybridRetrievalReportsMeasuredStagesAndPreservesResults() async {
        let store = HybridMemoryStore(config: .test)
        let ref = await store.save(entry: .init(note: "diagnostic unique aurora fact", scope: .agent("helper")))
        let request = MemoryRecallRequest(query: "aurora", scope: .agent("helper"))
        let diagnosed = await store.recallWithDiagnostics(request: request)
        let normal = await store.recall(request: request)
        #expect(diagnosed.hits.map(\.ref.id) == normal.map(\.ref.id))
        #expect(diagnosed.hits.contains { $0.ref.id == ref.id })
        #expect(diagnosed.durationMs > 0)
        #expect(diagnosed.stages.contains { $0.name == "keyword" && $0.candidateCount > 0 })
        #expect(diagnosed.stages.contains { $0.name == "graph" })
        #expect(diagnosed.stages.allSatisfy { $0.durationMs >= 0 && $0.error == nil })
    }
}
