import Foundation
import Protocols

extension CoreService {
    func subagentToolApprovalContext(_ record: ToolApprovalRecord) -> SubagentToolApprovalContext? {
        guard let sessionID = record.sessionId,
              let child = try? getAgentSession(agentID: record.agentId, sessionID: sessionID),
              let parentID = child.summary.parentSessionId,
              let parent = try? getAgentSession(agentID: record.agentId, sessionID: parentID)
        else { return nil }

        let worker = longChatParent(of: sessionID)
        let assignment = worker?.0.assignments.first { assignment in
            assignment.tasks.contains { $0.id == worker?.1.id }
        }
        let sourceRequest = assignment.flatMap { assignment in
            if let turn = (try? longChats())?.state.turns.first(where: { $0.id == assignment.sourceMessageId }) {
                // A worker notification may start a coordinator turn, but cannot supply user authorization.
                guard !turn.isNotification, turn.agentId == record.agentId, turn.sessionId == parentID,
                      turn.request.userId == worker?.0.userId else { return nil as String? }
                return turn.request.content
            }
            return parent.events.first {
                $0.message?.id == assignment.sourceMessageId && $0.message?.role == .user
            }?.message.map { plainText(from: $0) }
        }
        let userRequest = assignment != nil ? sourceRequest ?? "" :
            parent.events.last { $0.message?.role == .user }?.message.map { plainText(from: $0) } ?? ""
        let objective = worker?.1.objective ?? child.events.first { $0.message?.role == .user }?.message.map { plainText(from: $0) } ?? ""
        return SubagentToolApprovalContext(
            userRequest: userRequest,
            objective: objective,
            acceptanceCriteria: assignment?.acceptanceCriteria,
            readOnly: worker.map { $0.1.readOnly ?? $0.1.resourceKeys.isEmpty } ?? false,
            resourceKeys: worker?.1.resourceKeys ?? [],
            workingDirectory: sessionWorkingDirectories[sessionID],
            tool: record.tool,
            arguments: record.arguments,
            requestedAccess: record.grants,
            reason: record.reason
        )
    }

    /// Unavailable, ambiguous, or low-confidence reviews leave the request with the user.
    func resolveSubagentToolApprovalIfPossible(_ record: ToolApprovalRecord) async -> Bool {
        guard let context = subagentToolApprovalContext(record),
              let decision = await semanticModelRouter.reviewSubagentToolApproval(
                channelID: sessionChannelID(agentID: record.agentId, sessionID: record.sessionId ?? record.agentId),
                context: context)
        else { return false }

        switch decision {
        case .approve:
            _ = await approveToolApproval(
                id: record.id, decidedBy: "semantic:subagent_tool_approval", scope: .once,
                decisionReason: "Semantic reviewer approved this tool call within the delegated scope.")
        case .reject:
            _ = await rejectToolApproval(
                id: record.id, decidedBy: "semantic:subagent_tool_approval",
                decisionReason: "Semantic reviewer rejected this tool call as outside the authorized scope or unsafe.")
        case .askUser:
            return false
        }
        return true
    }
}
