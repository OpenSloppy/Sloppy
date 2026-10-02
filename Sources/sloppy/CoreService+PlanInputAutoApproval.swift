import Foundation
import Protocols

extension CoreService {
    static let planInputAutoApprovalTimeoutSeconds: TimeInterval = 120

    func schedulePlanInputAutoApproval(
        agentID: String, sessionID: String, request: PlanInputRequest, channel: Bool = false
    ) {
        guard !planInputAutoApprovalStopping, let deadline = request.autoApproveAt else { return }
        cancelPlanInputAutoApproval(requestID: request.id)
        let delay = max(0, deadline.timeIntervalSinceNow)
        planInputAutoApprovalTasks[request.id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runPlanInputAutoApproval(agentID: agentID, sessionID: sessionID, requestID: request.id, channel: channel)
        }
    }

    private func runPlanInputAutoApproval(agentID: String, sessionID: String, requestID: String, channel: Bool) async {
        // Remove before resolving so persisting the response does not cancel its own continuation.
        planInputAutoApprovalTasks.removeValue(forKey: requestID)
        do {
            if channel {
                _ = try await resolveChannelPlanInput(sessionID: sessionID, requestID: requestID, payload: nil, automaticAgentID: agentID)
            } else {
                _ = try await resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: requestID, payload: nil, automatically: true)
            }
        } catch {
            logger.debug("Plan input auto-approval skipped or failed for \(requestID): \(error)")
        }
    }

    func cancelPlanInputAutoApproval(requestID: String) {
        planInputAutoApprovalTasks.removeValue(forKey: requestID)?.cancel()
    }

    func stopPlanInputAutoApprovals() {
        planInputAutoApprovalStopping = true
        for task in planInputAutoApprovalTasks.values { task.cancel() }
        planInputAutoApprovalTasks.removeAll()
    }

    func restorePlanInputAutoApprovalsIfNeeded() async {
        guard !planInputAutoApprovalRecovered, !planInputAutoApprovalStopping else { return }
        planInputAutoApprovalRecovered = true
        for agent in (try? listAgents()) ?? [] {
            guard (try? getAgentConfig(agentID: agent.id).autoApproveInput) == true else { continue }
            // Include worker sessions, which the public session listing hides for long chats.
            for session in (try? sessionStore.listSessions(agentID: agent.id)) ?? [] {
                guard let detail = try? getAgentSession(agentID: agent.id, sessionID: session.id),
                      let request = detail.events.last(where: { $0.inputRequest != nil })?.inputRequest,
                      Self.autoApprovalCanResume(requestID: request.id, events: detail.events)
                else {
                continue
            }
                schedulePlanInputAutoApproval(agentID: agent.id, sessionID: session.id, request: request)
            }
        }
        let board = try? getActorBoard()
        for session in (try? await channelSessionStore.listSessions(status: .open)) ?? [] {
            guard let agentID = linkedAgentID(forChannelID: session.channelId, board: board),
                  let pending = try? await channelSessionStore.pendingInputRequest(channelId: session.channelId)
            else {
                continue
            }
            schedulePlanInputAutoApproval(agentID: agentID, sessionID: pending.sessionId, request: pending.request, channel: true)
        }
    }

    static func autoApprovalCanResume(requestID: String, events: [AgentSessionEvent]) -> Bool {
        guard let index = events.lastIndex(where: { $0.inputRequest != nil && $0.importOrigin == nil }),
              events[index].inputRequest?.id == requestID else { return false }
        return !events.dropFirst(index + 1).contains { event in
            event.inputResponse?.requestId == requestID
                || event.runStatus?.stage == .interrupted
                || event.runControl?.action == .pause
                || event.runControl?.action == .interrupt
                || event.runControl?.action == .interruptTree
                || event.message?.role == .user
        }
    }

    static func automaticPlanInputResponse(_ request: PlanInputRequest) -> PlanInputResponse {
        PlanInputResponse(
            requestId: request.id,
            status: .answered,
            answers: [],
            userId: "sloppy:auto-approve",
            autoApproved: true
        )
    }
}
