import Foundation
import Protocols
@testable import SloppyRuntime
import Testing

@Test("Explicit portable sessions create a clean conversation and resume the selected history")
func mobileExplicitSessionSelection() async throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: project) }
    let agentsRoot = project.appendingPathComponent(".ada/workspace/agents")
    try FileManager.default.createDirectory(at: agentsRoot.appendingPathComponent("mobile"), withIntermediateDirectories: true)
    let store = AgentSessionFileStore(agentsRootURL: agentsRoot)
    let previous = try store.createSession(agentID: "mobile", request: .init(title: "Forest adventure"))
    try store.appendEvents(agentID: "mobile", sessionID: previous.id, events: [
        .init(agentId: "mobile", sessionId: previous.id, type: .message,
              message: .init(role: .user, segments: [.init(kind: .text, text: "Create a forest game")]))
    ])
    let freshID = "session-\(UUID().uuidString.lowercased())"
    let host = SloppyRuntimeHost()
    let (freshStore, selected) = try await host.prepareSession(channelID: freshID, workspaceURL: project, persistedSessionID: freshID)
    #expect(selected == freshID)
    #expect(try freshStore.loadSession(agentID: "mobile", sessionID: selected).summary.messageCount == 0)
    try freshStore.appendEvents(agentID: "mobile", sessionID: selected, events: [
        .init(agentId: "mobile", sessionId: selected, type: .message,
              message: .init(role: .user, segments: [.init(kind: .text, text: "A separate game request")]))
    ])
    #expect(try store.listSessions(agentID: "mobile").first?.id == freshID)
    let (resumedStore, resumedID) = try await SloppyRuntimeHost().prepareSession(
        channelID: previous.id, workspaceURL: project, persistedSessionID: previous.id
    )
    #expect(resumedID == previous.id)
    let resumed = try resumedStore.loadSession(agentID: "mobile", sessionID: resumedID)
    #expect(resumed.summary.messageCount == 1)
    #expect(resumed.events.compactMap(\.message).first?.segments.first?.text == "Create a forest game")
    #expect(try store.listSessions(agentID: "mobile").count == 2)
    let (_, reopenedFreshID) = try await SloppyRuntimeHost().prepareSession(
        channelID: freshID, workspaceURL: project, persistedSessionID: freshID
    )
    #expect(reopenedFreshID == freshID)
}

@Test("Portable callers without an explicit selection retain latest-session behavior")
func mobileLegacySessionSelection() async throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: project) }
    let host = SloppyRuntimeHost()
    let (_, createdID) = try await host.prepareSession(channelID: "project", workspaceURL: project)
    let (_, loadedID) = try await SloppyRuntimeHost().prepareSession(channelID: "project", workspaceURL: project)
    #expect(loadedID == createdID)
}
