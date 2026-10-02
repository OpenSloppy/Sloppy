import Foundation
import Observation
import SloppyClientCore

public enum ChatParallelAgentState: Sendable { case running, waitingInput, completed, paused, interrupted, unknown }

public struct ChatParallelAgent: Identifiable, Sendable {
    public let state: ChatParallelAgentState
    public let summary: ChatSessionSummary
    public let status: String
    public let isWorking: Bool
    public var id: String { summary.storageID }

    public init(detail: ChatSessionDetail, taskStatus: LongChatTaskStatus? = nil) {
        summary = detail.summary
        if let taskStatus {
            switch taskStatus {
            case .queued:
                state = .paused
                status = "Queued"
                isWorking = false
            case .running:
                state = .running
                status = "Working"
                isWorking = true
            case .waitingInput:
                state = .waitingInput
                status = "Waiting for input"
                isWorking = false
            case .completed:
                state = .completed
                status = "Done"
                isWorking = false
            case .failed:
                state = .interrupted
                status = "Failed"
                isWorking = false
            case .cancelled:
                state = .interrupted
                status = "Cancelled"
                isWorking = false
            }
            return
        }
        if detail.pendingInputRequest != nil {
            state = .waitingInput
            status = "Waiting for input"
            isWorking = false
        } else if let run = detail.latestRunStatus {
            switch run.stage {
            case .done:
                state = .completed
                status = "Done"
            case .interrupted:
                state = .interrupted
                status = "Interrupted"
            case .paused:
                state = .paused
                status = "Paused"
            case .thinking, .searching, .responding:
                state = .running
                status = run.label.isEmpty ? run.stage.rawValue.capitalized : run.label
            }
            isWorking = run.stage.isWorking
        } else {
            state = .unknown
            status = "Status unavailable"
            isWorking = false
        }
    }
}

@Observable
@MainActor
public final class ChatParallelAgentsViewModel {
    public private(set) var agents: [ChatParallelAgent] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let apiClient: SloppyAPIClient

    public init(apiClient: SloppyAPIClient) {
        self.apiClient = apiClient
    }

    // The toolbar owns one cancellable task. Each chat uses its own instance endpoint.
    public func observe(agentID: String?, sessionID: String?) async {
        agents = []
        errorMessage = nil
        guard let agentID, let sessionID else { return }
        while !Task.isCancelled {
            do {
                let parent = try await apiClient.fetchAgentSession(agentId: agentID, sessionId: sessionID)
                let links = Self.links(in: parent.events)
                var taskStatuses: [String: LongChatTaskStatus] = [:]
                for event in parent.events {
                    if let attempt = event.longChatTask?.task.attempts.last, let childID = attempt.sessionId {
                        taskStatuses[childID] = attempt.status
                    }
                }
                var next: [ChatParallelAgent] = []
                for link in links {
                    if let detail = try? await apiClient.fetchAgentSession(
                        agentId: agentID, sessionId: link.childSessionId)
                    {
                        var summary = detail.summary
                        summary.sourceInstanceID = parent.summary.sourceInstanceID
                        next.append(
                            ChatParallelAgent(
                                detail: ChatSessionDetail(summary: summary, events: detail.events),
                                taskStatus: taskStatuses[link.childSessionId]))
                    } else {
                        // A starting/unavailable child must not hide the other agents or claim active work.
                        let summary = ChatSessionSummary(
                            id: link.childSessionId, agentId: agentID, title: link.title,
                            sourceInstanceID: parent.summary.sourceInstanceID
                        )
                        next.append(ChatParallelAgent(detail: ChatSessionDetail(summary: summary)))
                    }
                }
                guard !Task.isCancelled else { return }
                agents = next
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                // Never retain a stale working indicator after losing the connection.
                agents = []
                errorMessage = error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    static func links(in events: [ChatEventEnvelope]) -> [ChatSubSessionEvent] {
        var seen: Set<String> = []
        var latestTasks: [String: ChatSubSessionEvent] = [:]
        var taskOrder: [String] = []
        for event in events {
            if let task = event.longChatTask?.task, let childID = task.attempts.last?.sessionId {
                if latestTasks[task.id] == nil { taskOrder.append(task.id) }
                latestTasks[task.id] = .init(childSessionId: childID, title: task.title)
            }
        }
        let links = events.compactMap(\.subSession) + taskOrder.compactMap { latestTasks[$0] }
        return links.filter {
            !$0.childSessionId.isEmpty && seen.insert($0.childSessionId).inserted
        }
    }
}
