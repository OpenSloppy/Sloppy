import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

// MARK: - Helpers

private func makeContext(lspManager: LSPServerManager? = nil) -> ToolContext {
    let tmpURL = FileManager.default.temporaryDirectory
    return ToolContext(
        agentID: "test-agent",
        sessionID: "test-session",
        policy: AgentToolsPolicy(),
        workspaceRootURL: tmpURL,
        runtime: RuntimeSystem(),
        memoryStore: InMemoryMemoryStore(),
        sessionStore: AgentSessionFileStore(agentsRootURL: tmpURL),
        agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmpURL),
        agentSkillsStore: nil,
        processRegistry: SessionProcessRegistry(),
        channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmpURL),
        store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
        searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
        mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
        logger: .sloppy(label: "test"),
        projectService: nil,
        configService: nil,
        skillsService: nil,
        lspManager: lspManager,
        applyAgentMarkdown: nil,
        delegateSubagent: nil
    )
}

// MARK: - LSPOperationTests

@Suite("LSPOperation")
struct LSPOperationTests {
    @Test("all 9 operations parse from raw value")
    func allOperationsParse() {
        let expected: [String] = [
            "goToDefinition", "findReferences", "hover", "documentSymbol",
            "workspaceSymbol", "goToImplementation", "prepareCallHierarchy",
            "incomingCalls", "outgoingCalls"
        ]
        for raw in expected {
            #expect(LSPOperation(rawValue: raw) != nil, "Expected '\(raw)' to parse")
        }
        #expect(LSPOperation.allCases.count == 9)
    }

    @Test("unknown operation string returns nil")
    func unknownOperationReturnsNil() {
        #expect(LSPOperation(rawValue: "unknownOp") == nil)
        #expect(LSPOperation(rawValue: "") == nil)
    }
}

// MARK: - LSPToolValidationTests

@Suite("LSPTool argument validation")
struct LSPToolValidationTests {
    private let tool = LSPTool()

    @Test("missing operation returns error")
    func missingOperationFails() async {
        let result = await tool.invoke(arguments: [:], context: makeContext())
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_operation")
    }

    @Test("invalid operation string returns error")
    func invalidOperationFails() async {
        let result = await tool.invoke(
            arguments: ["operation": .string("teleport")],
            context: makeContext()
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_operation")
    }

    @Test("valid operation without lspManager returns lsp_not_configured")
    func noLSPManagerFails() async {
        let result = await tool.invoke(
            arguments: [
                "operation": .string("hover"),
                "filePath": .string("/tmp/test.swift"),
                "line": .number(1),
                "character": .number(1)
            ],
            context: makeContext(lspManager: nil)
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "lsp_not_configured")
    }

    @Test("operation without filePath returns invalid_arguments")
    func missingFilePathFails() async {
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: []),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        let result = await tool.invoke(
            arguments: ["operation": .string("hover")],
            context: makeContext(lspManager: manager)
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }

    @Test("workspaceSymbol without filePath returns invalid_arguments")
    func workspaceSymbolWithoutFilePath() async {
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: []),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        let result = await tool.invoke(
            arguments: ["operation": .string("workspaceSymbol")],
            context: makeContext(lspManager: manager)
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }
}

// MARK: - LSPToolNoServerTests

@Suite("LSPTool with no matching server")
struct LSPToolNoServerTests {
    private let tool = LSPTool()

    @Test("server not found for extension returns lsp_error")
    func serverNotFoundFails() async {
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: []),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        let result = await tool.invoke(
            arguments: [
                "operation": .string("hover"),
                "filePath": .string("/tmp/test.swift"),
                "line": .number(5),
                "character": .number(10)
            ],
            context: makeContext(lspManager: manager)
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "lsp_error")
        // Message should mention the extension
        let msg = result.error?.message ?? ""
        #expect(msg.contains(".swift"))
    }

    @Test("workspaceSymbol server not found returns lsp_error")
    func workspaceSymbolServerNotFound() async {
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: []),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        let result = await tool.invoke(
            arguments: [
                "operation": .string("workspaceSymbol"),
                "filePath": .string("/tmp/file.ts"),
                "query": .string("myFunc")
            ],
            context: makeContext(lspManager: manager)
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "lsp_error")
    }
}

// MARK: - LSPConfigTests

@Suite("CoreConfig.LSP")
struct LSPConfigTests {
    @Test("default LSP config has no servers")
    func defaultEmpty() {
        let lsp = CoreConfig.LSP()
        #expect(lsp.servers.isEmpty)
    }

    @Test("LSP server config decodes correctly from JSON")
    func serverDecoding() throws {
        let json = """
        {
          "servers": [
            {
              "id": "sourcekit",
              "command": "sourcekit-lsp",
              "arguments": ["--log-level", "warning"],
              "extensions": [".swift"],
              "enabled": true,
              "timeoutMs": 20000
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let lsp = try JSONDecoder().decode(CoreConfig.LSP.self, from: data)
        #expect(lsp.servers.count == 1)
        let server = lsp.servers[0]
        #expect(server.id == "sourcekit")
        #expect(server.command == "sourcekit-lsp")
        #expect(server.arguments == ["--log-level", "warning"])
        #expect(server.extensions == [".swift"])
        #expect(server.enabled == true)
        #expect(server.timeoutMs == 20000)
    }

    @Test("LSP server uses defaults for omitted fields")
    func serverDefaultDecoding() throws {
        let json = """
        { "servers": [{ "id": "ts", "command": "typescript-language-server" }] }
        """
        let data = json.data(using: .utf8)!
        let lsp = try JSONDecoder().decode(CoreConfig.LSP.self, from: data)
        let server = lsp.servers[0]
        #expect(server.arguments.isEmpty)
        #expect(server.extensions.isEmpty)
        #expect(server.enabled == true)
        #expect(server.timeoutMs == 15_000)
        #expect(server.cwd == nil)
    }

    @Test("CoreConfig.default includes empty LSP")
    func coreConfigDefaultHasLSP() {
        let config = CoreConfig.default
        #expect(config.lsp.servers.isEmpty)
    }
}

// MARK: - LSPServerManagerRoutingTests

@Suite("LSPServerManager routing")
struct LSPServerManagerRoutingTests {
    @Test("instance returns server matching extension")
    func routesToMatchingServer() async throws {
        let serverConfig = CoreConfig.LSP.Server(
            id: "swift-lsp",
            command: "/usr/bin/sourcekit-lsp",
            extensions: [".swift"]
        )
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: [serverConfig]),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        let instance = try await manager.instance(for: "/path/to/MyFile.swift")
        #expect(instance != nil)
    }

    @Test("instance throws for unregistered extension")
    func throwsForUnknownExtension() async {
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: []),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        do {
            _ = try await manager.instance(for: "/path/to/file.py")
            Issue.record("Expected throw for .py extension")
        } catch let error as LSPServerError {
            if case .serverNotFound = error {
                // Expected
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("disabled server is not routed to")
    func disabledServerIsSkipped() async {
        let serverConfig = CoreConfig.LSP.Server(
            id: "disabled-lsp",
            command: "/usr/bin/sourcekit-lsp",
            extensions: [".swift"],
            enabled: false
        )
        let manager = LSPServerManager(
            config: CoreConfig.LSP(servers: [serverConfig]),
            workspaceRootURL: FileManager.default.temporaryDirectory
        )
        do {
            _ = try await manager.instance(for: "/path/to/file.swift")
            Issue.record("Expected throw for disabled server")
        } catch let error as LSPServerError {
            if case .serverNotFound = error {
                // Expected
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
