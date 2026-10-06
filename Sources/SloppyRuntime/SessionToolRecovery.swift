import Foundation
import Protocols

public enum SessionToolRecovery {
    public static func unresolvedCalls(in events: [AgentSessionEvent]) -> [AgentSessionEvent] {
        var pending: [AgentSessionEvent] = []
        for event in events where event.importOrigin == nil {
            if event.type == .toolCall, event.toolCall != nil { pending.append(event) }
            guard event.type == .toolResult, let result = event.toolResult else { continue }
            if let id = result.callEventId {
                pending.removeAll { $0.id == id && $0.toolCall?.tool == result.tool }
            } else if let index = pending.firstIndex(where: { $0.toolCall?.tool == result.tool }) {
                pending.remove(at: index)
            }
        }
        return pending
    }

    public static func interruptionEvents(for detail: AgentSessionDetail) -> [AgentSessionEvent] {
        unresolvedCalls(in: detail.events).compactMap { event in
            guard let call = event.toolCall else { return nil }
            return AgentSessionEvent(
                agentId: detail.summary.agentId, sessionId: detail.summary.id, type: .toolResult,
                toolResult: AgentToolResultEvent(
                    tool: call.tool, ok: false,
                    data: .object(["requiresReconciliation": .bool(true), "callEventId": .string(event.id)]),
                    error: .init(code: "tool_execution_interrupted", message: "Execution ended without a durable result. Side effects may already have occurred. Inspect the target before proceeding; do not replay this call.", retryable: false),
                    callEventId: event.id,
                    executionOutcome: .init(state: .interrupted, category: .unknown, code: "tool_execution_interrupted", requiresReconciliation: true)
                )
            )
        }
    }

    public static func requiresReconciliation(tool: String, arguments: [String: Protocols.JSONValue], events: [AgentSessionEvent]) -> Bool {
        if unresolvedCalls(in: events).contains(where: { $0.toolCall?.tool == tool && $0.toolCall?.arguments == arguments }) { return true }
        let calls = Dictionary(events.compactMap { event -> (String, AgentToolCallEvent)? in
            guard event.importOrigin == nil, let call = event.toolCall else { return nil }
            return (event.id, call)
        }, uniquingKeysWith: { _, latest in latest })
        var lastByCall: [String: AgentToolResultEvent] = [:]
        for event in events {
            guard let result = event.toolResult, let id = result.callEventId else { continue }
            lastByCall[id] = result
        }
        return lastByCall.contains { id, result in
            let reconciliation = result.data?.asObject?["reconciliation"]?.asString
            guard result.executionOutcome?.requiresReconciliation == true || reconciliation == "completed" || reconciliation == "failed", let call = calls[id] else { return false }
            return call.tool == tool && call.arguments == arguments
        }
    }
}
