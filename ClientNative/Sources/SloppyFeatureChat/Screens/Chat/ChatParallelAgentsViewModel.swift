import Foundation
import Observation
import SloppyClientCore

public struct ChatParallelAgent: Identifiable, Sendable {
    public let summary: ChatSessionSummary
    public let status: String
    public let isWorking: Bool
    public var id: String { summary.storageID }

    public init(detail: ChatSessionDetail) {
        summary = detail.summary
        if detail.pendingInputRequest != nil {
            status = "Waiting for input"
            isWorking = false
        } else if let run = detail.latestRunStatus {
            switch run.stage {
            case .done: status = "Done"
            case .interrupted: status = "Interrupted"
            case .paused: status = "Paused"
            case .thinking, .searching, .responding:
                status = run.label.isEmpty ? run.stage.rawValue.capitalized : run.label
            }
            isWorking = run.stage.isWorking
        } else {
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
                var next: [ChatParallelAgent] = []
                for link in links {
                    if let detail = try? await apiClient.fetchAgentSession(agentId: agentID, sessionId: link.childSessionId) {
                        var summary = detail.summary
                        summary.sourceInstanceID = parent.summary.sourceInstanceID
                        next.append(ChatParallelAgent(detail: ChatSessionDetail(summary: summary, events: detail.events)))
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
        return events.compactMap(\.subSession).filter {
            !$0.childSessionId.isEmpty && seen.insert($0.childSessionId).inserted
        }
    }
}
