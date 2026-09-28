import Foundation
import Protocols
import SloppyRuntime
import Testing

@Test("Mobile workspace tools read and write project text")
func mobileWorkspaceToolsReadAndWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let tools = SloppyWorkspaceToolExecutor(rootURL: root)

    let written = await tools.invoke(.init(tool: "files.write", arguments: [
        "path": .string("Sources/main.ada"),
        "content": .string("func main() {}"),
    ]))
    #expect(written.ok)
    let loaded = await tools.invoke(.init(tool: "files.read", arguments: ["path": .string("Sources/main.ada")]))
    #expect(loaded.ok)
    #expect(loaded.data?.asObject?["content"]?.asString == "func main() {}")
    let listed = await tools.invoke(.init(tool: "files.list", arguments: ["path": .string("Sources")]))
    #expect(listed.ok)
    #expect(try String(contentsOf: root.appendingPathComponent("Sources/main.ada"), encoding: .utf8) == "func main() {}")

    let metadata = root.appendingPathComponent(".ada/project.json")
    try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{\"build\":{\"system\":\"adascript\"}}".write(to: metadata, atomically: true, encoding: .utf8)
    let manifest = await tools.invoke(.init(tool: "files.read", arguments: ["path": .string(".ada/project.json")]))
    #expect(manifest.ok)
    let protected = await tools.invoke(.init(tool: "files.write", arguments: [
        "path": .string(".ada/project.json"), "content": .string("{}"),
    ]))
    #expect(!protected.ok)
}

@Test("Mobile workspace tools reject traversal and symlinks")
func mobileWorkspaceToolsRejectEscapes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sources/link"), withDestinationURL: outside)
    let tools = SloppyWorkspaceToolExecutor(rootURL: root)

    let traversal = await tools.invoke(.init(tool: "files.write", arguments: [
        "path": .string("Sources/../../escape.ada"), "content": .string("escape"),
    ]))
    let symlink = await tools.invoke(.init(tool: "files.write", arguments: [
        "path": .string("Sources/link/escape.ada"), "content": .string("escape"),
    ]))
    #expect(!traversal.ok)
    #expect(!symlink.ok)
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.ada").path))
}

@Test("Mobile build tool returns editor diagnostics to the agent")
func mobileWorkspaceBuildToolReturnsDiagnostics() async {
    let root = FileManager.default.temporaryDirectory
    let tools = SloppyWorkspaceToolExecutor(rootURL: root, build: {
        SloppyBuildResult(ok: false, summary: "Sources/Game.ada: expected expression")
    })
    let result = await tools.invoke(.init(tool: "editor.build", arguments: [:]))
    #expect(!result.ok)
    #expect(result.error?.code == "build_failed")
    #expect(result.error?.message == "Sources/Game.ada: expected expression")
}

@Test("Mobile Sloppy session survives reopening its project store")
func mobileSessionSurvivesStoreReopen() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = project.appendingPathComponent(".ada/workspace/agents", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: project) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("mobile"), withIntermediateDirectories: true)
    let store = AgentSessionFileStore(agentsRootURL: root)
    let session = try store.createSession(
        agentID: "mobile",
        request: AgentSessionCreateRequest(title: "Mobile game", projectId: "project-1")
    )
    try store.appendEvents(agentID: "mobile", sessionID: session.id, events: [
        AgentSessionEvent(
            agentId: "mobile", sessionId: session.id, type: .message,
            message: AgentSessionMessage(role: .user, segments: [.init(kind: .text, text: "Make a fox game")])
        ),
        AgentSessionEvent(
            agentId: "mobile", sessionId: session.id, type: .message,
            message: AgentSessionMessage(role: .assistant, segments: [.init(kind: .text, text: "Created Game.ada")])
        ),
    ])

    let reopened = AgentSessionFileStore(agentsRootURL: root)
    let summary = try #require(reopened.listSessions(agentID: "mobile").first)
    #expect(summary.projectId == "project-1")
    let detail = try reopened.loadSession(agentID: "mobile", sessionID: summary.id)
    #expect(detail.events.count == 3)
    #expect(AgentSessionTranscriptBuilder.hasRecoverableEntries(
        AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)
    ))
}

@Test("Mobile Sloppy host exposes saved turns to the shared chat")
func mobileHostLoadsSavedChat() async throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let agentsRoot = project.appendingPathComponent(".ada/workspace/agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsRoot.appendingPathComponent("mobile"), withIntermediateDirectories: true)
    let store = AgentSessionFileStore(agentsRootURL: agentsRoot)
    let session = try store.createSession(agentID: "mobile", request: AgentSessionCreateRequest(projectId: "project-1"))
    try store.appendEvents(agentID: "mobile", sessionID: session.id, events: [
        AgentSessionEvent(
            agentId: "mobile", sessionId: session.id, type: .message,
            message: AgentSessionMessage(role: .user, segments: [.init(kind: .text, text: "Build a fox game")])
        ),
        AgentSessionEvent(
            agentId: "mobile", sessionId: session.id, type: .message,
            message: AgentSessionMessage(role: .assistant, segments: [.init(kind: .text, text: "Created a scene")])
        ),
    ])

    let messages = try await SloppyRuntimeHost().messages(workspaceURL: project)
    #expect(messages.map(\.text) == ["Build a fox game", "Created a scene"])
    #expect(messages.first?.role == .user)
    #expect(messages.last?.role == .assistant)
}
