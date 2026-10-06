import Foundation
import Protocols

extension CoreService {
    enum ToolReconciliationError: Error {
        case invalidEvidence
        case callNotFound
        case notInterrupted
    }

    /// Owner-facing API action. This is deliberately not exposed as an agent tool.
    public func reconcileToolCall(agentID: String, sessionID: String, callEventID: String, request: ToolCallReconciliationRequest) async throws -> AgentSessionMessageResponse {
        let evidence = request.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty, evidence.utf8.count <= 16_384 else { throw ToolReconciliationError.invalidEvidence }
        let detail = try getAgentSession(agentID: agentID, sessionID: sessionID)
        guard let call = detail.events.first(where: { $0.id == callEventID })?.toolCall else { throw ToolReconciliationError.callNotFound }
        guard let prior = detail.events.reversed().compactMap(\.toolResult).first(where: { $0.callEventId == callEventID }),
              prior.executionOutcome?.requiresReconciliation == true else { throw ToolReconciliationError.notInterrupted }
        let notExecuted = request.decision == .notExecuted
        let outcome = ExecutionOutcome(state: request.decision == .completed ? .completed : .failed, category: notExecuted ? .unavailable : nil, code: notExecuted ? "tool_not_executed" : "tool_reconciled", retryable: notExecuted)
        let event = AgentSessionEvent(
            agentId: agentID, sessionId: sessionID, type: .toolResult,
            toolResult: .init(tool: call.tool, ok: request.decision == .completed,
                data: .object(["reconciliation": .string(request.decision.rawValue), "evidence": .string(evidence)]),
                error: request.decision == .completed ? nil : .init(code: outcome.code ?? "tool_reconciled", message: evidence, retryable: notExecuted),
                callEventId: callEventID, executionOutcome: outcome)
        )
        return try await appendAgentSessionEvents(agentID: agentID, sessionID: sessionID, request: .init(events: [event]))
    }
}
