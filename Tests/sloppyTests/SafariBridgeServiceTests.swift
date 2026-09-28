import Foundation
import Logging
import Protocols
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy

@Suite("SafariBridgeService")
struct SafariBridgeServiceTests {
    @Test("register stores all Safari tabs for agent tools")
    func registerStoresAllTabs() async throws {
        let service = SafariBridgeService(commandTimeoutMs: 1_000)

        let response = await service.register(
            SafariBridgeRegisterRequest(
                bridgeId: "safari-test",
                tabs: [
                    SafariBridgeTab(id: 1, url: "https://example.com/one", title: "One", active: true, currentWindow: true),
                    SafariBridgeTab(id: 2, url: "https://example.com/two", title: "Two", active: false, currentWindow: true),
                ],
                capabilities: ["tabs"]
            )
        )

        #expect(response.bridgeId == "safari-test")
        let status = await service.statusPayload()
        let tabs = status.asObject?["tabs"]?.asArray ?? []
        #expect(tabs.count == 2)
        #expect(tabs[0].asObject?["url"]?.asString == "https://example.com/one")
        #expect(tabs[1].asObject?["url"]?.asString == "https://example.com/two")
    }

    @Test("command queue resolves when extension posts result")
    func commandQueueResolvesFromResult() async throws {
        let service = SafariBridgeService(commandTimeoutMs: 1_000)
        _ = await service.register(SafariBridgeRegisterRequest(bridgeId: "safari-test"))

        async let result = service.runCommand(
            name: "safari.scroll",
            input: .object(["y": .number(500)])
        )

        let polled = await pollUntilCommandAvailable(service: service, bridgeId: "safari-test")
        #expect(polled.commands.count == 1)
        #expect(polled.commands[0].name == "safari.scroll")

        try await service.completeCommand(
            SafariBridgeCommandResultRequest(
                commandId: polled.commands[0].id,
                ok: true,
                data: .object(["scrolled": .bool(true)])
            )
        )

        let payload = try await result
        #expect(payload.asObject?["scrolled"]?.asBool == true)
    }

    @Test("safari.tabs tool asks extension for a live tab list")
    func safariTabsToolUsesLiveCommand() async throws {
        let bridge = SafariBridgeService(commandTimeoutMs: 1_000)
        _ = await bridge.register(SafariBridgeRegisterRequest(bridgeId: "safari-test", tabs: []))
        let context = makeToolContext(safariBridgeService: bridge)

        async let result = SafariTabsTool().invoke(arguments: [:], context: context)

        let polled = await pollUntilCommandAvailable(service: bridge, bridgeId: "safari-test")
        #expect(polled.commands.count == 1)
        let command = try #require(polled.commands.first)
        #expect(command.name == "safari.tabs")

        try await bridge.completeCommand(
            SafariBridgeCommandResultRequest(
                commandId: command.id,
                ok: true,
                data: .object([
                    "tabs": .array([
                        .object([
                            "id": .number(10),
                            "url": .string("https://live.example"),
                            "title": .string("Live"),
                            "active": .bool(true),
                            "currentWindow": .bool(true),
                        ])
                    ])
                ])
            )
        )

        let payload = await result
        #expect(payload.ok == true)
        #expect(payload.data?.asObject?["tabs"]?.asArray?.count == 1)
        #expect(payload.data?.asObject?["tabs"]?.asArray?.first?.asObject?["url"]?.asString == "https://live.example")
    }

    private func pollUntilCommandAvailable(
        service: SafariBridgeService,
        bridgeId: String
    ) async -> SafariBridgeCommandListResponse {
        for _ in 0..<20 {
            let response = await service.pollCommands(bridgeId: bridgeId, limit: 5)
            if !response.commands.isEmpty {
                return response
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return SafariBridgeCommandListResponse()
    }

    private func makeToolContext(safariBridgeService: SafariBridgeService) -> ToolContext {
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "test-session",
            policy: AgentToolsPolicy(),
            workspaceRootURL: tmp,
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
            safariBridgeService: safariBridgeService,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }
}
