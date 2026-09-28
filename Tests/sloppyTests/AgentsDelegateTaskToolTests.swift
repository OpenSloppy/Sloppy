import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("agents.delegate_task argument validation")
struct AgentsDelegateTaskToolTests {

    private func makeContext(delegateSubagent: (@Sendable (String, String, String, String?, [String]?, String?, String?) async -> String?)?) -> ToolContext {
        let guardrails = AgentToolsGuardrails()
        let policy = AgentToolsPolicy(guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-delegate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
            workspaceRootURL: workspace,
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
            delegateSubagent: delegateSubagent
        )
    }

    @Test("Rejects goal and non-empty tasks together with hint")
    func rejectsGoalAndTasksTogether() async {
        let tool = AgentsDelegateTaskTool()
        let context = makeContext(delegateSubagent: { _, _, _, _, _, _, _ in "ok" })
        let result = await tool.invoke(
            arguments: [
                "goal": .string("do a"),
                "tasks": .array([.string("do b")]),
            ],
            context: context
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
        #expect(result.error?.hint?.contains("goal") == true)
    }

    @Test("Accepts goal with empty tasks array")
    func acceptsGoalWithEmptyTasks() async {
        let tool = AgentsDelegateTaskTool()
        let context = makeContext(delegateSubagent: { _, _, _, _, _, _, _ in "done" })
        let result = await tool.invoke(
            arguments: [
                "goal": .string("single task"),
                "tasks": .array([]),
            ],
            context: context
        )
        #expect(result.ok == true)
    }

    @Test("Passes current session id to delegated subagent runner")
    func passesParentSessionIDToRunner() async throws {
        let tool = AgentsDelegateTaskTool()
        let context = makeContext(delegateSubagent: { _, _, _, _, _, _, parentSessionID in
            parentSessionID ?? "missing"
        })
        let result = await tool.invoke(
            arguments: [
                "goal": .string("single task"),
            ],
            context: context
        )

        let data = try #require(result.data?.asObject)
        let results = try #require(data["results"]?.asArray)
        let first = try #require(results.first?.asObject)
        #expect(first["summary"]?.asString == "session-test")
    }

    @Test("Finish tool accepts completed outcomes")
    func finishToolAcceptsCompletedOutcomes() async throws {
        let tool = AgentDelegateFinishTool()
        let context = makeContext(delegateSubagent: nil)
        let result = await tool.invoke(
            arguments: [
                "status": .string("done"),
                "summary": .string("Found the source file and returned snippets."),
            ],
            context: context
        )

        let data = try #require(result.data?.asObject)
        #expect(result.ok)
        #expect(data["finished"]?.asBool == true)
        #expect(data["status"]?.asString == "completed")
    }

    @Test("Finish tool requires error for failed outcomes")
    func finishToolRequiresErrorForFailedOutcomes() async {
        let tool = AgentDelegateFinishTool()
        let context = makeContext(delegateSubagent: nil)
        let result = await tool.invoke(
            arguments: [
                "status": .string("failed"),
                "summary": .string("Could not inspect the tree."),
            ],
            context: context
        )

        #expect(!result.ok)
        #expect(result.error?.code == "invalid_arguments")
    }

    @Test("Finish tool rejects completed outcomes with an error")
    func finishToolRejectsCompletedOutcomesWithError() async {
        let tool = AgentDelegateFinishTool()
        let context = makeContext(delegateSubagent: nil)
        let result = await tool.invoke(
            arguments: [
                "status": .string("completed"),
                "summary": .string("Inspected files but could not update the task."),
                "error": .string("project.task_update is unavailable."),
            ],
            context: context
        )

        #expect(!result.ok)
        #expect(result.error?.code == "invalid_arguments")
        #expect(result.error?.message.contains("blocked") == true)
    }

    @Test("Delegated task result synthesizes failure when finish tool is missing")
    func delegatedTaskResultSynthesizesFailureWhenFinishToolIsMissing() async {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let events = [
            AgentSessionEvent(
                agentId: "test-agent",
                sessionId: "session-child",
                type: .message,
                message: AgentSessionMessage(
                    role: .assistant,
                    segments: [.init(kind: .text, text: "I'll search for that now.")]
                )
            )
        ]

        let text = await service.delegatedTaskResultText(from: events)
        #expect(text.contains("[failed]"))
        #expect(text.contains("agent_delegate.finish"))
    }

    @Test("Delegated task result uses interrupted run status as synthetic finish error")
    func delegatedTaskResultUsesInterruptedRunStatusAsSyntheticFinishError() async {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let events = [
            AgentSessionEvent(
                agentId: "test-agent",
                sessionId: "session-child",
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .interrupted,
                    label: "Incomplete",
                    details: "Agent reached the tool turn limit before producing a final answer."
                )
            )
        ]

        let text = await service.delegatedTaskResultText(from: events)
        #expect(text == "[failed] Delegated subagent ended before calling `agent_delegate.finish`.\nError: Agent reached the tool turn limit before producing a final answer.")
    }

    @Test("Delegated task result names tool budget exhaustion in synthetic failure")
    func delegatedTaskResultUsesToolBudgetExhaustionAsSyntheticFinishError() async {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let events = [
            AgentSessionEvent(
                agentId: "test-agent",
                sessionId: "session-child",
                type: .toolResult,
                toolResult: AgentToolResultEvent(
                    tool: "files.list",
                    ok: false,
                    error: ToolErrorPayload(
                        code: "tool_budget_exhausted",
                        message: "Tool budget exhausted.",
                        retryable: false
                    )
                )
            ),
            AgentSessionEvent(
                agentId: "test-agent",
                sessionId: "session-child",
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .done,
                    label: "Done",
                    details: "Response is ready."
                )
            )
        ]

        let text = await service.delegatedTaskResultText(from: events)
        #expect(text.contains("tool_budget_exhausted"))
    }

    @Test("Delegated task result uses finish tool summary")
    func delegatedTaskResultUsesFinishToolSummary() async {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let events = [
            AgentSessionEvent(
                agentId: "test-agent",
                sessionId: "session-child",
                type: .toolResult,
                toolResult: AgentToolResultEvent(
                    tool: "agent_delegate.finish",
                    ok: true,
                    data: .object([
                        "finished": .bool(true),
                        "status": .string("completed"),
                        "summary": .string("Found all usages."),
                    ])
                )
            )
        ]

        let text = await service.delegatedTaskResultText(from: events)
        #expect(text == "[completed] Found all usages.")
    }
}
