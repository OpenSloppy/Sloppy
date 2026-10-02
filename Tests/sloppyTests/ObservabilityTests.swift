import Foundation
import Testing
import SloppyRuntime
@testable import Protocols
@testable import sloppy

@Test
func observabilityReportsRouteTemplatesAndTimingForSuccessAndErrors() async {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)
    for path in ["/health", "/v1/agents/private-agent?secret=hidden", "/unknown/private-id"] {
        let response = await router.handle(method: "GET", path: path, body: nil)
        let expected = path == "/health" ? "/health" : path.hasPrefix("/v1/agents/") ? "/v1/agents/:agentId" : "unmatched"
        #expect(response.headers["x-sloppy-route"] == expected)
        #expect(response.headers["server-timing"]?.hasPrefix("core;dur=") == true)
        #expect(response.headers["x-sloppy-route"]?.contains("private") == false)
    }
}

@Test
func allAgentSessionsReturnsTheSameVisibleSummariesWithoutTranscripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("all-sessions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var config = CoreConfig.test
    config.workspace = .init(name: "workspace", basePath: root.path)
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentsRoot = config.resolvedWorkspaceRootURL().appendingPathComponent("agents")
    let catalog = AgentCatalogFileStore(agentsRootURL: agentsRoot)
    let sessions = AgentSessionFileStore(agentsRootURL: agentsRoot)
    for agentID in ["alpha", "beta"] {
        _ = try catalog.createAgent(AgentCreateRequest(id: agentID, displayName: agentID, role: "Test"), availableModels: [])
        _ = try sessions.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: agentID))
        _ = try sessions.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Hidden heartbeat", kind: .heartbeat))
    }
    let alpha = try await service.listAgentSessions(agentID: "alpha")
    let beta = try await service.listAgentSessions(agentID: "beta")
    let expected = alpha + beta
    let router = CoreRouter(service: service)
    let response = await router.handle(method: "GET", path: "/v1/agent-sessions", body: nil)
    #expect(response.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode([AgentSessionSummary].self, from: response.body)
    #expect(Set(result.filter { ["alpha", "beta"].contains($0.agentId) }.map(\.id)) == Set(expected.map(\.id)))
    #expect(!String(decoding: response.body, as: UTF8.self).contains("\"events\""))
}
