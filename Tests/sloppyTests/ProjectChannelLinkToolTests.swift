import Foundation
import Logging
import Testing
@testable import AgentRuntime
import PluginSDK
import SloppyRuntime
@testable import sloppy
@testable import Protocols

@Suite("project.channel_link tool")
struct ProjectChannelLinkToolTests {
    private func makeContext(service: CoreService, sessionID: String) -> ToolContext {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sloppy-channel-link-tool-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return ToolContext(
            agentID: "test-agent",
            sessionID: sessionID,
            policy: AgentToolsPolicy(guardrails: AgentToolsGuardrails()),
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
            logger: .sloppy(label: "test.project.channel_link"),
            projectService: service,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }

    @Test
    func linksCurrentChannelByProjectName() async throws {
        let service = CoreService(config: .test)
        _ = try await service.createProject(
            ProjectCreateRequest(id: "avito", name: "AVITO", channels: [.init(title: "Main", channelId: "main")])
        )
        let tool = ProjectChannelLinkTool()
        let result = await tool.invoke(
            arguments: ["projectName": .string("AVITO"), "title": .string("Telegram topic")],
            context: makeContext(service: service, sessionID: "telegram-main\u{001E}tgthread:42")
        )
        #expect(result.ok == true)
        #expect(result.data?.asObject?["status"]?.asString == "linked")
        #expect(result.data?.asObject?["projectId"]?.asString == "avito")
    }

    @Test
    func rejectsChannelAlreadyLinkedToAnotherProject() async throws {
        let service = CoreService(config: .test)
        _ = try await service.createProject(
            ProjectCreateRequest(id: "one", name: "One", channels: [.init(title: "Main", channelId: "main")])
        )
        _ = try await service.createProject(
            ProjectCreateRequest(id: "two", name: "Two", channels: [.init(title: "Other", channelId: "other")])
        )
        _ = try await service.linkProjectChannel(
            projectID: "one",
            request: ProjectChannelLinkRequest(channelId: "discord-room", title: "Discord", ensureSession: false)
        )

        let tool = ProjectChannelLinkTool()
        let result = await tool.invoke(
            arguments: ["projectId": .string("two"), "channelId": .string("discord-room")],
            context: makeContext(service: service, sessionID: "discord-room")
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "channel_already_linked")
    }

    @Test
    func projectLinkAgentOptionsResolveCustomActorWithoutChannel() async throws {
        let config = CoreConfig.test
        defer {
            try? FileManager.default.removeItem(at: config.resolvedWorkspaceRootURL())
            try? FileManager.default.removeItem(atPath: config.sqlitePath)
        }

        let service = CoreService(config: config)
        _ = try await service.createAgent(
            AgentCreateRequest(id: "builder", displayName: "Builder", role: "Developer")
        )
        _ = try await service.createActorNode(
            node: ActorNode(
                id: "actor:builder",
                displayName: "Builder Actor",
                kind: .agent,
                linkedAgentId: "builder"
            )
        )
        _ = try await service.createProject(
            ProjectCreateRequest(
                id: "sloppy",
                name: "Sloppy",
                channels: [.init(title: "Main", channelId: "main")],
                actors: ["actor:builder"]
            )
        )

        let restartedService = CoreService(config: config)
        let options = await restartedService.projectLinkAgentOptions(projectId: "sloppy")

        #expect(options == [
            ChannelProjectLinkAgentOption(
                actorId: "actor:builder",
                agentId: "builder",
                name: "Builder Actor",
                channelId: "agent:builder"
            )
        ])
    }
}
