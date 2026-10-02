import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct ChatWorkerSessionCard: View {
    let child: ChatSubSessionEvent
    @Environment(ChatScreenViewModel.self) private var viewModel
    @Environment(\.theme) private var theme

    var body: some View {
        let worker = viewModel.parallelAgents.agents.first { $0.summary.id == child.childSessionId }
        Button {
            viewModel.openLongChatWorker(child.childSessionId)
        } label: {
            HStack(alignment: .top, spacing: theme.spacing.m) {
                AgentBotAvatar(
                    agentID: viewModel.selectedAgent?.id ?? "worker", size: 40,
                    emotion: worker?.isWorking == true ? .working : .idle)
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.selectedAgent?.displayName ?? "Worker").font(.caption).foregroundStyle(.secondary)
                    Text(child.title).font(.headline)
                    Text(worker?.status ?? "Status unavailable").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(theme.spacing.m)
        }
        .buttonStyle(.plain)
        .background(theme.colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.colors.borderBold.opacity(0.6), lineWidth: 1))
        .accessibilityIdentifier("chat.worker.\(child.childSessionId)")
    }
}

@MainActor
struct ChatWorkerActivityCard: View {
    @Environment(ChatScreenViewModel.self) private var viewModel
    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        let workers = viewModel.parallelAgents.agents
        let working = workers.filter(\.isWorking).count
        let waiting = workers.filter { $0.state == .waitingInput }.count
        let completed = workers.filter { $0.state == .completed }.count
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: theme.spacing.s) {
                    HStack(spacing: -8) {
                        ForEach(workers.prefix(4)) { worker in
                            AgentBotAvatar(agentID: worker.summary.agentId, size: 26)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workers · \(workers.count)").font(.callout.weight(.semibold))
                        Text("\(working) working · \(waiting) waiting · \(completed) completed")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
            }.buttonStyle(.plain)
            if expanded {
                ForEach(workers) { worker in
                    ChatWorkerSessionCard(child: .init(childSessionId: worker.summary.id, title: worker.summary.title))
                }
            }
        }
        .padding(theme.spacing.m)
        .background(theme.colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.colors.borderBold.opacity(0.6), lineWidth: 1))
        .accessibilityIdentifier("chat.worker-activity")
    }
}
