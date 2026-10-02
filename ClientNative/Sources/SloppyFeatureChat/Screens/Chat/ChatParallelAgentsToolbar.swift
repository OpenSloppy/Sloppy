import SwiftUI
import SloppyClientCore

@MainActor
public struct ChatParallelAgentsToolbar: View {
    private let viewModel: ChatScreenViewModel
    private let onOpenSession: @MainActor (ChatSessionSummary) -> Void

    public init(viewModel: ChatScreenViewModel, onOpenSession: @escaping @MainActor (ChatSessionSummary) -> Void) {
        self.viewModel = viewModel
        self.onOpenSession = onOpenSession
    }

    public var body: some View {
        let model = viewModel.parallelAgents
        let workingCount = model.agents.filter(\.isWorking).count
        Group {
            if !model.agents.isEmpty {
                Menu {
                    ForEach(model.agents) { agent in
                        Button {
                            onOpenSession(agent.summary)
                        } label: {
                            Label("\(agent.summary.title) — \(agent.status)",
                                  systemImage: agent.isWorking ? "gearshape.2" : "bubble.left")
                        }
                    }
                } label: {
                    Label(workingCount > 0 ? "\(workingCount) working" : "Agents · \(model.agents.count)",
                          systemImage: "person.2")
                        .lineLimit(1)
                }
                .help("Open a parallel agent's chat")
                .accessibilityLabel("Parallel agents: \(workingCount) working, \(model.agents.count) total")
                .accessibilityIdentifier("chat.parallel-agents")
            } else if model.errorMessage != nil {
                Image(systemName: "person.2.badge.key")
                    .help("Parallel agent status unavailable")
                    .accessibilityLabel("Parallel agent status unavailable")
            }
        }
    }
}
