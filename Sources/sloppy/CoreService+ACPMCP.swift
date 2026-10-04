import ACPModel
import Foundation

extension CoreService {
    /// Client-supplied servers live only in the ACP session and never change global MCP settings.
    func configureACPMCPServers(sessionID: String, servers: [MCPServerConfig], cwd: String?) async throws {
        var names = Set(currentConfig.mcp.servers.map(\.id))
        let supplied = try servers.map { server -> CoreConfig.MCP.Server in
            let converted: CoreConfig.MCP.Server
            switch server {
            case .stdio(let value):
                converted = .init(id: "acp." + value.name, transport: .stdio, command: value.command,
                    arguments: value.args, cwd: cwd, environment: Dictionary(value.env.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }))
            case .http(let value):
                converted = .init(id: "acp." + value.name, transport: .http, endpoint: value.url,
                    headers: Dictionary((value.headers ?? []).map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }))
            case .sse:
                throw MCPRegistryError.invalidConfiguration("Legacy SSE MCP servers are unsupported; use HTTP or stdio.")
            }
            guard converted.id != "acp.", names.insert(converted.id).inserted else {
                throw MCPRegistryError.invalidConfiguration("ACP MCP server names must be nonempty and unique.")
            }
            return converted
        }
        let previous = acpSessionMCPRegistries.removeValue(forKey: sessionID)
        if !supplied.isEmpty {
            acpSessionMCPRegistries[sessionID] = MCPClientRegistry(config: .init(servers: currentConfig.mcp.servers + supplied))
        }
        await previous?.updateConfig(.init())
    }

    func acpMCPPromptContext(sessionID: String) async -> String {
        guard let registry = acpSessionMCPRegistries[sessionID] else { return "" }
        let servers = await registry.listServers().filter { $0.id.hasPrefix("acp.") }.map(\.id)
        return """


        [ACP client MCP servers]
        The client supplied these MCP servers for this session: \(servers.joined(separator: ", ")).
        Their tools are accessible through the native mcp.list_tools and mcp.call_tool functions.
        Use mcp.list_tools(server: serverID) to read exact tool names and schemas, then
        mcp.call_tool(server: serverID, tool: toolName, arguments: JSON-encoded argument object).
        Discover the supplied tools before concluding that editor, scene, build or play capabilities are unavailable.
        """
    }

    func shutdownACPMCPServers() async {
        let registries = Array(acpSessionMCPRegistries.values)
        acpSessionMCPRegistries.removeAll()
        for registry in registries { await registry.updateConfig(.init()) }
    }
}
