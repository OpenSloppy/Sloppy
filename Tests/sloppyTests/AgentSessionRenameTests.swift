import Foundation
import Testing
import SloppyRuntime
import Protocols
@testable import sloppy

@Test
func agentSessionRenamePreservesHistoryAndSurvivesReload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = AgentCatalogFileStore(agentsRootURL: root)
    _ = try catalog.createAgent(.init(id: "agent", displayName: "Agent", role: "Testing"), availableModels: [])
    let store = AgentSessionFileStore(agentsRootURL: root)
    let session = try store.createSession(agentID: "agent", request: .init(projectId: "project"))
    let event = AgentSessionEvent(agentId: "agent", sessionId: session.id, type: .message,
        message: .init(role: .user, segments: [.init(kind: .text, text: "Original message")]))
    _ = try store.appendEvents(agentID: "agent", sessionID: session.id, events: [event])
    let before = try store.loadSession(agentID: "agent", sessionID: session.id)
    let renamed = try store.renameSession(agentID: "agent", sessionID: session.id, title: "  Morning report  \n")
    #expect(renamed.title == "Morning report")
    #expect(renamed.projectId == "project")
    #expect(renamed.updatedAt == before.summary.updatedAt)
    let reloaded = AgentSessionFileStore(agentsRootURL: root)
    #expect(try reloaded.listSessions(agentID: "agent").first?.title == "Morning report")
    let after = try reloaded.loadSession(agentID: "agent", sessionID: session.id)
    #expect(after.events.dropFirst() == before.events.dropFirst())
    #expect(after.events.first?.metadata?.titleIsAutomatic == false)
    _ = try reloaded.appendEvents(agentID: "agent", sessionID: session.id, events: [
        .init(agentId: "agent", sessionId: session.id, type: .message,
              message: .init(role: .user, segments: [.init(kind: .text, text: "New content")]))
    ])
    #expect(try reloaded.loadSession(agentID: "agent", sessionID: session.id).summary.title == "Morning report")
}

@Test
func agentSessionRenameEndpointValidatesTitle() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    _ = try await service.createAgent(.init(id: "rename-agent", displayName: "Agent", role: "Testing"))
    let session = try await service.createAgentSession(agentID: "rename-agent", request: .init(title: "Before"))
    let path = "/v1/agents/rename-agent/sessions/\(session.id)/title"
    for title in ["", " \n", String(repeating: "a", count: 201)] {
        let body = try JSONEncoder().encode(AgentSessionRenameRequest(title: title))
        let response = await router.handle(method: "POST", path: path, body: body)
        #expect(response.status == 400)
    }
    let response = await router.handle(method: "POST", path: path, body: Data(#"{"title":"After"}"#.utf8))
    #expect(response.status == 200)
    #expect(try await service.getAgentSession(agentID: "rename-agent", sessionID: session.id).summary.title == "After")
    let missing = await router.handle(method: "POST", path: "/v1/agents/rename-agent/sessions/missing/title", body: Data(#"{"title":"After"}"#.utf8))
    #expect(missing.status == 404)
    let missingAgent = await router.handle(method: "POST", path: "/v1/agents/missing-agent/sessions/missing/title", body: Data(#"{"title":"After"}"#.utf8))
    #expect(missingAgent.status == 404)
}
