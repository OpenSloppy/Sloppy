import Foundation
import Testing
import SloppyRuntime
@testable import Protocols
@testable import sloppy

@Suite("Session history pages")
struct AgentSessionHistoryPageTests {
    @Test func pagesAreBoundedAndCursorsSurviveAppends() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let session = fixture.session
        let events = (0..<150).map { index in
            AgentSessionEvent(id: "event-\(index)", agentId: "agent", sessionId: session.id,
                              type: .message, createdAt: Date(timeIntervalSince1970: Double(index + 1)),
                              message: AgentSessionMessage(role: .user, segments: [
                                .init(kind: .text, text: index == 90 ? String(repeating: "Привет 🌿", count: 12_000) : "\(index)")
                              ]))
        }
        _ = try store.appendEvents(agentID: "agent", sessionID: session.id, events: events)
        let newest = try store.loadSessionPage(agentID: "agent", sessionID: session.id, limit: 64)
        #expect(newest.events.map(\.id) == events.suffix(64).map(\.id))
        #expect(newest.historyPage?.hasMore == true)
        let cursor = try #require(newest.historyPage?.nextBefore)
        let appended = AgentSessionEvent(id: "appended", agentId: "agent", sessionId: session.id,
                                         type: .runStatus, createdAt: Date(timeIntervalSince1970: 200),
                                         runStatus: .init(stage: .done, label: "Done"))
        _ = try store.appendEvents(agentID: "agent", sessionID: session.id, events: [appended])
        let middle = try store.loadSessionPage(agentID: "agent", sessionID: session.id, limit: 64, before: cursor)
        #expect(middle.events.map(\.id) == events[22..<86].map(\.id))
        let first = try store.loadSessionPage(agentID: "agent", sessionID: session.id, limit: 64,
                                            before: try #require(middle.historyPage?.nextBefore))
        #expect(first.events.filter { $0.type == .message }.map(\.id) == events.prefix(22).map(\.id))
        #expect(first.historyPage?.hasMore == false)
        #expect(first.historyPage?.nextBefore == nil)
        #expect(middle.stateEvents?.last?.runStatus?.stage == .done)
        #expect(try store.loadSession(agentID: "agent", sessionID: session.id).events.count == 152)
        for invalid in ["-1", "not-a-cursor", "1", "999999999"] {
            #expect(throws: AgentSessionFileStore.StoreError.self) {
                try store.loadSessionPage(agentID: "agent", sessionID: session.id, limit: 64, before: invalid)
            }
        }
        #expect(throws: AgentSessionFileStore.StoreError.self) {
            try store.loadSessionPage(agentID: "agent", sessionID: session.id, limit: 0)
        }
    }

    @Test func controlStateOutsidePageIsPreservedAndAnswersClearIt() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = PlanInputRequest(id: "question", questions: [])
        _ = try fixture.store.appendEvents(agentID: "agent", sessionID: fixture.session.id, events: [
            .init(agentId: "agent", sessionId: fixture.session.id, type: .runStatus,
                  runStatus: .init(stage: .paused, label: "Waiting")),
            .init(agentId: "agent", sessionId: fixture.session.id, type: .inputRequest, inputRequest: request),
            .init(agentId: "agent", sessionId: fixture.session.id, type: .message,
                  message: .init(role: .user, segments: [.init(kind: .text, text: "Latest")]))
        ])
        let detail = try fixture.store.loadSessionPage(agentID: "agent", sessionID: fixture.session.id, limit: 1)
        #expect(detail.events.count == 1)
        #expect(detail.stateEvents?.compactMap(\.inputRequest).first?.id == request.id)
        #expect(detail.stateEvents?.compactMap(\.runStatus).first?.stage == .paused)
        _ = try fixture.store.appendEvents(agentID: "agent", sessionID: fixture.session.id, events: [
            .init(agentId: "agent", sessionId: fixture.session.id, type: .inputResponse,
                  inputResponse: .init(requestId: request.id, status: .cancelled, answers: [], userId: "owner"))
        ])
        let answered = try fixture.store.loadSessionPage(agentID: "agent", sessionID: fixture.session.id, limit: 1)
        #expect(answered.stateEvents?.compactMap(\.inputRequest).isEmpty == true)
    }

    private func makeStore() throws -> (root: URL, store: AgentSessionFileStore, session: AgentSessionSummary) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-page-\(UUID())")
        let catalog = AgentCatalogFileStore(agentsRootURL: root)
        _ = try catalog.createAgent(AgentCreateRequest(id: "agent", displayName: "Agent", role: "Testing"), availableModels: [])
        let store = AgentSessionFileStore(agentsRootURL: root)
        let session = try store.createSession(agentID: "agent", request: .init(title: "History"), createdAt: Date(timeIntervalSince1970: 0))
        return (root, store, session)
    }
}
