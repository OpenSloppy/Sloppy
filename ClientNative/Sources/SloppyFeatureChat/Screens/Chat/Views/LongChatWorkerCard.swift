import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct LongChatWorkerCard: View {
    let event: LongChatTaskEvent
    let viewModel: ChatScreenViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if let attempt = event.task.attempts.last {
                Button {
                    if let sessionID = attempt.sessionId { viewModel.openLongChatWorker(sessionID) }
                } label: {
                    HStack(alignment: .top, spacing: theme.spacing.m) {
                        AgentBotAvatar(
                            agentID: viewModel.selectedAgent?.id ?? "worker", size: 40,
                            emotion: attempt.status == .running ? .working : .idle)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.task.title)
                                .font(.headline)
                            Text(
                                "\(viewModel.selectedAgent?.displayName ?? "Agent") · \(attempt.status.rawValue.replacingOccurrences(of: "_", with: " ")) · attempt \(attempt.number)"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            if let summary = attempt.summary { Text(summary).font(.callout).lineLimit(5) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(attempt.sessionId == nil)
                HStack {
                    if !attempt.status.isTerminal {
                        Button("Cancel") { viewModel.updateLongChatTask(event.task.id, action: "cancel") }
                    } else if attempt.status != .completed {
                        Button("Retry") { viewModel.updateLongChatTask(event.task.id, action: "retry") }
                    }
                    if event.task.attempts.count > 1 {
                        Menu("Previous attempts") {
                            ForEach(event.task.attempts.dropLast()) { previous in
                                Button("Attempt \(previous.number): \(previous.status.rawValue)") {
                                    if let sessionID = previous.sessionId { viewModel.openLongChatWorker(sessionID) }
                                }.disabled(previous.sessionId == nil)
                            }
                        }
                    }
                }.font(.caption)
            }
        }
        .padding(theme.spacing.m)
        .background(theme.colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.colors.borderBold.opacity(0.6), lineWidth: 1))
        .accessibilityIdentifier("long-chat.task.\(event.task.id)")
    }
}
