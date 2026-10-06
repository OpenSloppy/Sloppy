import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Chat session history page models")
struct ChatSessionHistoryPageTests {
    @Test func latestControlStateOverridesHistoricalRequests() {
        let oldRequest = ChatPlanInputRequest(id: "old", questions: [])
        let detail = ChatSessionDetail(
            summary: .init(id: "session", agentId: "agent", title: "Chat"),
            events: [.init(id: "request", type: "input_request", inputRequest: oldRequest)],
            stateEvents: [.init(id: "current-status", type: "run_status", runStatus: .init(stage: .done, label: "Done"))]
        )
        #expect(detail.pendingInputRequest == nil)
        #expect(detail.latestRunStatus?.stage == .done)
        #expect(detail.messages.isEmpty)
    }

    @Test func cacheKeepsCursorAndLegacyDetailsStillDecode() async throws {
        let cache = ClientCacheStore(path: ":memory:")
        let detail = ChatSessionDetail(
            summary: .init(id: "session", agentId: "agent", title: "Chat"),
            messages: [.init(id: "last", role: .user, segments: [.init(kind: .text, text: "Latest")])],
            historyPage: .init(nextBefore: "12345", hasMore: true)
        )
        await cache.cacheSessionDetail(agentId: "agent", detail: detail)
        let restored = try #require(await cache.loadSessionDetail(agentId: "agent", sessionId: "session"))
        #expect(restored.historyPage == detail.historyPage)
        #expect(restored.messages.map(\.id) == ["last"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(ChatSessionDetail.self, from: Data(#"{"summary":{"id":"old","agentId":"agent","title":"Old","messageCount":0,"kind":"chat","updatedAt":"2026-10-01T00:00:00Z"},"events":[]}"#.utf8))
        #expect(legacy.historyPage == nil)
        #expect(legacy.stateEvents == nil)
    }
}
