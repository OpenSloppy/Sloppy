import AgentRuntime
import Foundation
import Protocols

struct AgentRunnerModelError: Error, LocalizedError {
    let detail: String
    var outcome: ExecutionOutcome = .init(state: .failed, category: .provider, code: "model_provider_error")
    var errorDescription: String? { detail }
}

/// Bridge executor that plugs worker execution into the agent session orchestrator.
/// When the worker spec carries an agentID, execution is delegated to the agent runner closure
/// which creates a dedicated session, posts the task objective, and returns the assistant response.
/// Workers without an agentID fall back to DefaultWorkerExecutor.
final class ToolExecutionWorkerExecutorAdapter: @unchecked Sendable, WorkerExecutor {
    struct AgentRunnerResult: Sendable {
        var summary: String
        var payload: [String: JSONValue]
        var executionOutcome: ExecutionOutcome = .completed
    }

    typealias AgentRunner = @Sendable (
        _ agentID: String,
        _ taskID: String,
        _ objective: String,
        _ workingDirectory: String?,
        _ selectedModel: String?,
        _ toolIDs: [String]
    ) async -> AgentRunnerResult?

    private let fallback: any WorkerExecutor
    private let agentRunner: AgentRunner?

    init(
        fallback: any WorkerExecutor = DefaultWorkerExecutor(),
        agentRunner: AgentRunner? = nil
    ) {
        self.fallback = fallback
        self.agentRunner = agentRunner
    }

    convenience init(
        toolExecutionService: ToolExecutionService,
        fallback: any WorkerExecutor = DefaultWorkerExecutor(),
        agentRunner: AgentRunner? = nil
    ) {
        self.init(fallback: fallback, agentRunner: agentRunner)
    }

    func execute(workerId: String, spec: WorkerTaskSpec) async throws -> WorkerExecutionResult {
        if let agentID = spec.agentID, let runner = agentRunner {
            let result = await runner(agentID, spec.taskId, spec.objective, spec.workingDirectory, spec.selectedModel, spec.tools)
            guard let result else {
                throw AgentRunnerModelError(detail: "Worker runner unavailable.", outcome: .init(state: .failed, category: .unavailable, code: "worker_runner_unavailable"))
            }
            switch result.executionOutcome.state {
            case .completed: return .completed(summary: result.summary, payload: result.payload)
            case .waitingInput, .waitingApproval: return .waitingForRoute(report: result.summary)
            case .cancelled: throw CancellationError()
            case .failed, .interrupted: throw AgentRunnerModelError(detail: result.summary, outcome: result.executionOutcome)
            }
        }
        return try await fallback.execute(workerId: workerId, spec: spec)
    }

    func route(workerId: String, spec: WorkerTaskSpec, message: String) async throws -> WorkerRouteExecutionResult {
        return try await fallback.route(workerId: workerId, spec: spec, message: message)
    }

    func cancel(workerId: String, spec: WorkerTaskSpec) async {
        await fallback.cancel(workerId: workerId, spec: spec)
    }
}
