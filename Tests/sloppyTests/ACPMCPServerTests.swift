import ACPModel
import Foundation
import Testing
@testable import Protocols
@testable import sloppy

@Test("ACP MCP tools reach the supplied server, preserve arguments, and stay isolated to the session")
func sloppyACPServerMCPToolsAreSessionScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ACP-MCP-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("mcp.py")
    try #"""
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"editor-test","version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name":"editor.scene.get","description":"Read active scene","inputSchema":{"type":"object"}}]}
        elif method == "tools/call":
            result = {"content":[{"type":"text","text":json.dumps(request["params"]["arguments"])}]}
        else:
            result = {}
        if "id" in request:
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
    """#.write(to: script, atomically: true, encoding: .utf8)
    var config = CoreConfig.test
    config.acp.server = .init(enabled: true, agentId: "dev", cwd: nil)
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    _ = try await service.createAgent(.init(id: "dev", displayName: "Dev", role: "Developer", isSystem: false))
    let delegate = SloppyACPServerDelegate(service: service, agentID: "dev", defaultCwd: nil, sendUpdate: { _, _ in })
    let servers: [MCPServerConfig] = [.stdio(.init(name: "AdaEditor", command: "/usr/bin/python3", args: [script.path], env: []))]
    let created = try await delegate.handleNewSession(.init(cwd: root.path, mcpServers: servers))
    let other = try await delegate.handleNewSession(.init(cwd: root.path))
    await service.setSessionToolApprovalRequired(sessionID: created.sessionId.value, enabled: false)
    await service.setSessionToolApprovalRequired(sessionID: other.sessionId.value, enabled: false)
    let scoped = try #require(await service.acpSessionMCPRegistries[created.sessionId.value])
    #expect(await service.acpSessionMCPRegistries[other.sessionId.value] == nil)
    #expect(!(await service.getConfig()).mcp.servers.contains { $0.id == "acp.AdaEditor" })
    let tools = try await scoped.listTools(serverID: "acp.AdaEditor")
    #expect(tools.tools.map(\.name) == ["editor.scene.get"])
    #expect(await service.acpMCPPromptContext(sessionID: created.sessionId.value).contains("acp.AdaEditor"))
    #expect(await service.acpMCPPromptContext(sessionID: other.sessionId.value).isEmpty)
    let request = ToolInvocationRequest(tool: "mcp.call_tool", arguments: [
        "server": .string("acp.AdaEditor"), "tool": .string("editor.scene.get"),
        "arguments": .string(#"{"path":"Assets/Main.ascn"}"#)
    ])
    let result = await service.invokeToolFromRuntime(agentID: "dev", sessionID: created.sessionId.value, request: request, recordSessionEvents: false)
    #expect(result.ok, "\(String(describing: result.error))")
    #expect(result.data?.asObject?["content"]?.asArray?.first?.asObject?["text"]?.asString?.contains("Assets/Main.ascn") == true)
    let isolated = await service.invokeToolFromRuntime(agentID: "dev", sessionID: other.sessionId.value, request: request, recordSessionEvents: false)
    #expect(!isolated.ok)
    let restored = try await delegate.handleLoadSession(.init(sessionId: created.sessionId, cwd: root.path, mcpServers: servers))
    #expect(restored.sessionId == created.sessionId)
    #expect(await service.acpSessionMCPRegistries[created.sessionId.value] != nil)
    _ = try await delegate.handleLoadSession(.init(sessionId: created.sessionId, cwd: root.path, mcpServers: []))
    #expect(await service.acpSessionMCPRegistries[created.sessionId.value] == nil)
    await service.shutdownACPMCPServers()
}

@Test("ACP HTTP MCP can discover and call the running Ada Editor", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_MCP_SMOKE_ENDPOINT"] != nil))
func sloppyACPServerLiveEditorMCP() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["ADAEDITOR_MCP_SMOKE_ENDPOINT"])
    var config = CoreConfig.test
    config.acp.server = .init(enabled: true, agentId: "dev", cwd: nil)
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    _ = try await service.createAgent(.init(id: "dev", displayName: "Dev", role: "Developer", isSystem: false))
    let delegate = SloppyACPServerDelegate(service: service, agentID: "dev", defaultCwd: nil, sendUpdate: { _, _ in })
    let created = try await delegate.handleNewSession(.init(cwd: "/tmp", mcpServers: [.http(.init(name: "AdaEditor", url: endpoint))]))
    await service.setSessionToolApprovalRequired(sessionID: created.sessionId.value, enabled: false)
    let scoped = try #require(await service.acpSessionMCPRegistries[created.sessionId.value])
    let names = Set(try await scoped.listTools(serverID: "acp.AdaEditor").tools.map(\.name))
    #expect(Set(["editor.scene.get", "editor.scene.apply", "editor.build.start", "editor.play.start"]).isSubset(of: names))
    let result = await service.invokeToolFromRuntime(agentID: "dev", sessionID: created.sessionId.value,
        request: .init(tool: "mcp.call_tool", arguments: ["server": .string("acp.AdaEditor"), "tool": .string("editor.task.status"), "arguments": .string("{}")]),
        recordSessionEvents: false)
    #expect(result.ok, "\(String(describing: result.error))")
    #expect(result.data?.asObject?["isError"]?.asBool != true)
    await service.shutdownACPMCPServers()
}
