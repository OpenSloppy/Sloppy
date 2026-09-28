import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("HTML artifact tools")
struct WidgetArtifactGenerateToolTests {
    private func makeContext(workspaceRootURL: URL) -> ToolContext {
        let guardrails = AgentToolsGuardrails()
        let policy = AgentToolsPolicy(guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
            workspaceRootURL: workspaceRootURL,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: tmp),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmp),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmp),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
            logger: .sloppy(label: "test"),
            projectService: nil,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }

    @Test("tool creates widget artifact under sloppy artifacts")
    func createsWidgetArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await WidgetArtifactGenerateTool().invoke(arguments: [
            "prompt": .string("Clock widget"),
            "size": .string("medium"),
            "html": .string("<!doctype html><html><body><main>Clock</main></body></html>")
        ], context: makeContext(workspaceRootURL: root))

        #expect(result.ok == true)
        let artifact = try #require(result.data?.asObject?["artifact"]?.asObject)
        let id = try #require(artifact["id"]?.asString)
        #expect(artifact["kind"]?.asString == "widget")
        #expect(artifact["widget"]?.asObject?["size"]?.asString == "medium")

        let htmlURL = root
            .appendingPathComponent(CoreConfig.defaultWorkspaceName, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("widgets", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: htmlURL.path))
    }

    @Test("chat web visuals keep prior versions available")
    func webVisualsAreImmutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-artifact-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(workspaceRootURL: root)
        let tool = WebArtifactCreateTool()

        let first = await tool.invoke(arguments: [
            "title": .string("Comparison"),
            "summary": .string("Original values"),
            "html": .string("<!doctype html><html><body>First</body></html>")
        ], context: context)
        let second = await tool.invoke(arguments: [
            "title": .string("Comparison"),
            "summary": .string("Updated values"),
            "html": .string("<!doctype html><html><body>Second</body></html>")
        ], context: context)

        let firstID = try #require(first.data?.asObject?["artifact"]?.asObject?["id"]?.asString)
        let secondID = try #require(second.data?.asObject?["artifact"]?.asObject?["id"]?.asString)
        #expect(first.ok && second.ok)
        #expect(firstID != secondID)
        #expect(await context.store.persistedArtifact(id: firstID)?.content.contains("First") == true)
        #expect(await context.store.persistedArtifact(id: secondID)?.content.contains("Second") == true)
    }

    @Test("chat web visuals reject external resources")
    func webVisualRejectsExternalResources() async {
        let context = makeContext(workspaceRootURL: FileManager.default.temporaryDirectory)
        let result = await WebArtifactCreateTool().invoke(arguments: [
            "title": .string("External chart"),
            "summary": .string("Loads remote code"),
            "html": .string("<!doctype html><html><body><script src='https://example.com/chart.js'></script></body></html>")
        ], context: context)

        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
        #expect(await context.store.listPersistedArtifacts().isEmpty)
    }

    @Test("widget editor session blocks files.write and allows widget artifact tool")
    func widgetSessionAllowListBlocksFileWrites() async throws {
        let service = CoreService(config: .test)
        _ = try await service.createAgent(
            AgentCreateRequest(id: "widget-agent", displayName: "Widget Agent", role: "Testing")
        )
        let session = try await service.createAgentSession(
            agentID: "widget-agent",
            request: AgentSessionCreateRequest(title: "Safari: widget")
        )
        await service.configureWidgetEditorToolAllowList(sessionID: session.id)

        let forbidden = await service.invokeToolFromRuntime(
            agentID: "widget-agent",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "files.write",
                arguments: [
                    "path": .string("new-widget.html"),
                    "content": .string("bad")
                ]
            ),
            recordSessionEvents: false
        )
        #expect(forbidden.ok == false)
        #expect(forbidden.error?.code == "tool_forbidden")

        let allowed = await service.invokeToolFromRuntime(
            agentID: "widget-agent",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "artifacts.widget.generate",
                arguments: [
                    "prompt": .string("Clock widget"),
                    "size": .string("medium"),
                    "html": .string("<!doctype html><html><body>Clock</body></html>")
                ]
            ),
            recordSessionEvents: false
        )
        #expect(allowed.ok == true)
    }
}
