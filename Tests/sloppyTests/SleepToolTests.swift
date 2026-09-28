import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("tools.sleep")
struct SleepToolTests {

    private func makeContext() -> ToolContext {
        let guardrails = AgentToolsGuardrails()
        let policy = AgentToolsPolicy(guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
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
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }

    @Test("zero seconds succeeds without sleeping")
    func zeroSeconds() async throws {
        let tool = SleepTool()
        let result = await tool.invoke(arguments: ["seconds": .number(0)], context: makeContext())
        #expect(result.ok == true)
        #expect(result.data?.asObject?["slept_seconds"]?.asNumber == 0)
    }

    @Test("missing seconds fails")
    func missingSeconds() async throws {
        let tool = SleepTool()
        let result = await tool.invoke(arguments: [:], context: makeContext())
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }

    @Test("negative seconds fails")
    func negativeSeconds() async throws {
        let tool = SleepTool()
        let result = await tool.invoke(arguments: ["seconds": .number(-1)], context: makeContext())
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }

    @Test("above max seconds fails")
    func aboveMax() async throws {
        let tool = SleepTool()
        let result = await tool.invoke(arguments: ["seconds": .number(Double(SleepTool.maxSeconds + 1))], context: makeContext())
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }
}
