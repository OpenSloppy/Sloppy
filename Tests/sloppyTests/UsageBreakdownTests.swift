import Foundation
import Testing
import Protocols
@testable import sloppy

@Suite struct UsageBreakdownTests {
    private func store() throws -> SQLiteStore {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try String(contentsOf:root.appendingPathComponent("Sources/sloppy/Storage/schema.sql"),encoding:.utf8)
        return SQLiteStore(path:":memory:",schemaSQL:schema)
    }
    private func record(_ id: String, channel: String = "agent:a:session:s", call: String = "call", result: Bool = false) -> UsageRequestRecord {
        .init(id:id,channelId:channel,sessionId:"s",agentId:"a",provider:"openai-api",model:"gpt-4o",
            usage:.init(prompt:100,completion:20,cachedInputTokens:10),
            components:[.init(id:"component-"+id,requestId:id,toolCallId:call,tool:"mcp.search",serverId:"research",skillId:"skill",
                kind:result ? .resultInput : .argumentsOutput,tokens:result ? 30 : 5,method:.tokenizer,encoding:"fixture")],
            calls:[.init(id:call,requestId:id,channelId:channel,sessionId:"s",agentId:"a",tool:"mcp.search",serverId:"research",skillId:"skill",
                         ok:result ? true : nil,generated:!result)])
    }
    @Test func deduplicationReplayAndOverlap() async throws {
        let store = try store()
        try await store.persistUsageRequest(record("r1"))
        try await store.persistUsageRequest(record("r1"))
        try await store.persistUsageRequest(record("r2",result:true))
        try await store.persistUsageRequest(record("r3",result:true))
        let result = try await store.usageBreakdown(.init())
        #expect(result.requestCount == 3)
        #expect(result.providerUsage.total == 360)
        #expect(result.groups.first?.calls == 1)
        #expect(result.groups.first?.argumentsTokens == 5)
        #expect(result.groups.first?.resultTokens == 30)
        #expect(result.groups.first?.replayTokens == 30)
        #expect(result.calls.first?.ok == true)
        #expect(result.groups.first?.averagePerCall == 35)
        let skills = try await store.usageBreakdown(.init(groupBy:"skill"))
        #expect(skills.groups.first?.resultTokens == 30)
        let legacy = await store.listTokenUsage(channelId:nil,taskId:nil,from:nil,to:nil)
        #expect(legacy.count == 3)
    }
    @Test func fullPeriodAggregationAndCursorPagination() async throws {
        let store = try store()
        for index in 0..<1205 { try await store.persistUsageRequest(record(String(index),call:"call-\(index)")) }
        let page = try await store.usageBreakdown(.init(limit:200))
        #expect(page.requestCount == 1205)
        #expect(page.groups.first?.calls == 1205)
        #expect(page.providerUsage.total == 1205*120)
        #expect(page.calls.count == 200)
        var seen = Set(page.calls.map(\.id)), cursor = page.nextCursor
        while let next = cursor {
            let result = try await store.usageBreakdown(.init(cursor:next,limit:200))
            #expect(result.requestCount == 1205)
            for call in result.calls { #expect(seen.insert(call.id).inserted) }
            cursor = result.nextCursor
        }
        #expect(seen.count == 1205)
    }
    @Test func sameCallIdInConcurrentSessionsIsIndependent() async throws {
        let store = try store()
        async let a: Void = store.persistUsageRequest(record("a",channel:"agent:a:session:a"))
        async let b: Void = store.persistUsageRequest(record("b",channel:"agent:a:session:b"))
        _ = try await (a,b)
        try await store.updateUsageToolOutcome(channelId:"agent:a:session:a",callId:"call",ok:false)
        let result = try await store.usageBreakdown(.init())
        #expect(result.requestCount == 2)
        #expect(result.groups.first?.calls == 2)
        #expect(result.groups.first?.failures == 1)
        #expect(try await store.usageBreakdown(.init(channelId:"agent:a:session:b")).groups.first?.failures == 0)
    }
    @Test func paginationKeepsPrefixChannelsAndOpaqueSeparators() async throws {
        let store = try store()
        let identities = [("a", "b|c"), ("a|b", "c"), ("agent:a:session:s", "one"), ("agent:a:session:s2", "two")]
        for (index, identity) in identities.enumerated() {
            try await store.persistUsageRequest(record("opaque-\(index)", channel: identity.0, call: identity.1))
        }
        var result = try await store.usageBreakdown(.init(limit:1))
        var found = result.calls
        while let cursor = result.nextCursor {
            result = try await store.usageBreakdown(.init(cursor:cursor,limit:1))
            found += result.calls
        }
        #expect(found.count == 4)
        #expect(Set(found.map { UsageCallCursor.encode($0) }).count == 4)
        #expect(found.allSatisfy { $0.argumentsTokens == 5 })
    }
    @Test func unavailableMarkerDoesNotTurnFirstResultIntoReplay() async throws {
        let store = try store()
        var request = record("media-first", result:true)
        request.components.insert(.init(id:"unknown",requestId:request.id,toolCallId:"call",tool:"mcp.search",kind:.resultInput,tokens:nil,method:.unavailable),at:0)
        try await store.persistUsageRequest(request)
        let result = try await store.usageBreakdown(.init())
        #expect(result.groups.first?.resultTokens == 30)
        #expect(result.groups.first?.replayTokens == 0)
        #expect(result.groups.first?.unavailableMeasurements == 1)
    }
    @Test func recoveredHistoryDoesNotInventNewCalls() async throws {
        let store = try store()
        try await store.persistUsageRequest(record("recovered",result:true))
        let result = try await store.usageBreakdown(.init())
        #expect(result.calls.isEmpty)
        #expect(result.groups.first?.calls == 0)
        #expect(result.groups.first?.averagePerCall == nil)
        #expect(result.groups.first?.resultTokens == 30)
    }
    @Test func upgradesLegacyDatabaseAndKeepsUsageAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-restart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("usage.sqlite").path
        let legacySchema = """
            CREATE TABLE token_usage (id TEXT PRIMARY KEY,channel_id TEXT NOT NULL,task_id TEXT,
                prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,created_at TEXT NOT NULL);
            INSERT INTO token_usage VALUES ('legacy','legacy-channel',NULL,100,20,120,'2026-10-01T00:00:00Z');
            """
        var legacy: SQLiteStore? = SQLiteStore(path:path,schemaSQL:legacySchema)
        #expect(await legacy?.listTokenUsage(channelId:nil,taskId:nil,from:nil,to:nil).count == 1)
        legacy = nil
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try String(contentsOf:root.appendingPathComponent("Sources/sloppy/Storage/schema.sql"),encoding:.utf8)
        var upgraded: SQLiteStore? = SQLiteStore(path:path,schemaSQL:schema)
        try await upgraded?.persistUsageRequest(record("after-upgrade"))
        upgraded = nil
        let reopened = SQLiteStore(path:path,schemaSQL:schema)
        let result = try await reopened.usageBreakdown(.init())
        #expect(result.requestCount == 1)
        #expect(result.groups.first?.calls == 1)
        #expect(result.collectionStartedAt != nil)
        let usage = await reopened.listTokenUsage(channelId:nil,taskId:nil,from:nil,to:nil)
        #expect(usage.count == 2)
        #expect(usage.contains { $0.id == "legacy" && $0.totalTokens == 120 })
    }
    @Test func memoryStoreHasSameAttribution() async throws {
        let store = InMemoryPersistenceStore()
        for record in [record("a"),record("b",result:true),record("c",result:true)] { try await store.persistUsageRequest(record) }
        let result = try await store.usageBreakdown(.init(groupBy:"server"))
        #expect(result.groups.first?.id == "research")
        #expect(result.groups.first?.calls == 1)
        #expect(result.groups.first?.replayTokens == 30)
    }
}
