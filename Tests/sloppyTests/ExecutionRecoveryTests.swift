import AgentRuntime
import AnyLanguageModel
import Foundation
import PluginSDK
import SloppyRuntime
import Protocols
import Testing
@testable import sloppy

@Suite("Typed execution and interrupted call recovery")
struct ExecutionRecoveryTests {
    @Test("Core rejects replay of an interrupted mutation and owner reconciliation unlocks it")
    func ownerReconciliationAPI() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        var config = CoreConfig.test
        config.workspace = .init(name: "harness", basePath: fixture.root.path)
        config.sqlitePath = fixture.root.appendingPathComponent("core.sqlite").path
        let service = CoreService(config: config)
        let agent = try await service.createAgent(.init(id: "recovery-agent", displayName: "Recovery", role: "Test"))
        let session = try await service.createAgentSession(agentID: agent.id, request: .init(title: "Recovery"))
        let invocation = AgentSessionEvent(id: "persisted-call", agentId: agent.id, sessionId: session.id, type: .toolCall,
            toolCall: .init(tool: "files.write", arguments: ["path": .string("file.swift"), "content": .string("new bytes")]))
        _ = try await service.appendAgentSessionEvents(agentID: agent.id, sessionID: session.id, request: .init(events: [invocation]))
        let detail = try await service.getAgentSession(agentID: agent.id, sessionID: session.id)
        let interruptions = SessionToolRecovery.interruptionEvents(for: detail)
        _ = try await service.appendAgentSessionEvents(agentID: agent.id, sessionID: session.id, request: .init(events: interruptions))
        let blocked = await service.invokeToolFromRuntime(agentID: agent.id, sessionID: session.id, request: .init(tool: "files.write", arguments: invocation.toolCall!.arguments))
        #expect(blocked.error?.code == "tool_reconciliation_required")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("file.swift").path))
        _ = try await service.reconcileToolCall(agentID: agent.id, sessionID: session.id, callEventID: "persisted-call", request: .init(decision: .notExecuted, evidence: "Inspected target: file does not exist; the write never executed."))
        let reconciled = try await service.getAgentSession(agentID: agent.id, sessionID: session.id)
        #expect(!SessionToolRecovery.requiresReconciliation(tool: "files.write", arguments: invocation.toolCall!.arguments, events: reconciled.events))
    }
    private func detail(_ events: [AgentSessionEvent]) -> AgentSessionDetail {
        .init(summary: .init(id: "session", agentId: "agent", title: "Recovery"), events: events)
    }
    private func call(_ id: String, path: String = "file.swift") -> AgentSessionEvent {
        .init(id: id, agentId: "agent", sessionId: "session", type: .toolCall, toolCall: .init(tool: "files.write", arguments: ["path": .string(path), "content": .string("new bytes")]))
    }

    @Test("Interrupted calls are paired with a typed unknown result, not discarded or replayed")
    func interruptedCall() throws {
        let original = detail([call("call-1")])
        let interruption = try #require(SessionToolRecovery.interruptionEvents(for: original).first)
        #expect(interruption.toolResult?.executionOutcome?.state == .interrupted)
        #expect(interruption.toolResult?.executionOutcome?.requiresReconciliation == true)
        #expect(interruption.toolResult?.error?.retryable == false)
        let recovered = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: original)
        #expect(recovered.count == 2)
        #expect(TranscriptContextManager.render(recovered[1]).contains("tool_execution_interrupted"))
        let events = original.events + [interruption]
        #expect(SessionToolRecovery.interruptionEvents(for: detail(events)).isEmpty)
        #expect(SessionToolRecovery.requiresReconciliation(tool: "files.write", arguments: call("x").toolCall!.arguments, events: events))
        #expect(!SessionToolRecovery.requiresReconciliation(tool: "files.write", arguments: call("x", path: "other.swift").toolCall!.arguments, events: events))
    }

    @Test("Result correlation handles parallel calls completing out of order")
    func outOfOrderResults() {
        let result = AgentSessionEvent(agentId: "agent", sessionId: "session", type: .toolResult,
            toolResult: .init(tool: "files.write", ok: true, callEventId: "second", executionOutcome: .completed))
        let unresolved = SessionToolRecovery.unresolvedCalls(in: [call("first"), call("second"), result])
        #expect(unresolved.map(\.id) == ["first"])
    }

    @Test("Owner reconciliation releases the block and recovery uses the latest result only")
    func reconciledCall() {
        let original = detail([call("call-1")])
        let interrupted = SessionToolRecovery.interruptionEvents(for: original)
        let resolved = AgentSessionEvent(agentId: "agent", sessionId: "session", type: .toolResult,
            toolResult: .init(tool: "files.write", ok: false, data: .object(["reconciliation": .string("not_executed")]),
                callEventId: "call-1", executionOutcome: .init(state: .failed, code: "tool_not_executed", retryable: true)))
        let events = original.events + interrupted + [resolved]
        #expect(!SessionToolRecovery.requiresReconciliation(tool: "files.write", arguments: call("x").toolCall!.arguments, events: events))
        #expect(AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail(events)).count == 2)
        var completed = resolved
        completed.toolResult = .init(tool: "files.write", ok: true, data: .object(["reconciliation": .string("completed")]), callEventId: "call-1", executionOutcome: .completed)
        #expect(SessionToolRecovery.requiresReconciliation(tool: "files.write", arguments: call("x").toolCall!.arguments, events: original.events + interrupted + [completed]))
    }

    @Test("Normal prose that resembles an error cannot change worker execution state")
    func textIsNotControlFlow() async throws {
        let adapter = ToolExecutionWorkerExecutorAdapter(agentRunner: { _, _, _, _, _, _ in
            .init(summary: "Model provider error: this is a quotation in the solution.", payload: [:], executionOutcome: .completed)
        })
        let result = try await adapter.execute(workerId: "worker", spec: .init(taskId: "task", channelId: "channel", title: "Task", objective: "Implement", agentID: "agent", tools: [], mode: .fireAndForget))
        guard case .completed = result else { Issue.record("Display text incorrectly became control flow"); return }
    }

    @Test("A structured failure blocks completion even when its summary looks successful")
    func structuredFailure() async throws {
        let adapter = ToolExecutionWorkerExecutorAdapter(agentRunner: { _, _, _, _, _, _ in
            .init(summary: "Everything is ready", payload: [:], executionOutcome: .init(state: .failed, category: .provider, code: "provider_unavailable", retryable: true))
        })
        do {
            _ = try await adapter.execute(workerId: "worker", spec: .init(taskId: "task", channelId: "channel", title: "Task", objective: "Implement", agentID: "agent", tools: [], mode: .fireAndForget))
            Issue.record("Failed execution must not be marked completed")
        } catch let error as AgentRunnerModelError { #expect(error.outcome.code == "provider_unavailable") }
        #expect(ExecutionOutcomeClassifier.classify(reason: .modelProviderError).category == .provider)
        #expect(CoreService.delegateExecutionOutcome(status: "failed").state == .failed)
    }

    @Test("Legacy status JSON decodes without an outcome, and model config retains numeric limits")
    func legacyCoding() throws {
        let old = AgentRunStatusEvent(stage: .done, label: "Done")
        let decoded = try JSONDecoder().decode(AgentRunStatusEvent.self, from: JSONEncoder().encode(old))
        #expect(decoded.executionOutcome == nil)
        let model = CoreConfig.ModelConfig(title: "local", apiKey: "", apiUrl: "", model: "mock:small", contextWindowTokens: 8_000, maxInputTokens: 6_000, maxOutputTokens: 1_000)
        #expect(try JSONDecoder().decode(CoreConfig.ModelConfig.self, from: JSONEncoder().encode(model)).contextWindowTokens == 8_000)
    }
}
