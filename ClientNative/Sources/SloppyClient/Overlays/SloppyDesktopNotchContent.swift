#if os(macOS)
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat
import SwiftUI

enum SloppyDesktopNotchSection: String, CaseIterable, Identifiable {
    case home, chats, tasks

    var id: Self { self }
    var title: String {
        switch self {
        case .home: "Home"
        case .chats: "Chats"
        case .tasks: "Tasks"
        }
    }
    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .chats: "bubble.left.fill"
        case .tasks: "checklist"
        }
    }
}

@MainActor
struct SloppyDesktopNotchContent<TaskComposer: View>: View {
    let state: SloppyDesktopOverlayState
    @ViewBuilder var taskComposer: () -> TaskComposer

    var body: some View {
        Group {
            if let chat = state.selectedChat {
                chatContent(chat)
                    .padding(8)
                    .background(Color.fromHex(0x151518), in: RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(spacing: 10) {
                    ScrollView(.vertical) {
                        sections.padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: .infinity)
                    if state.selectedSection != .chats {
                        Divider().opacity(0.25)
                        taskComposer().layoutPriority(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.theme, .sloppyDark)
        .preferredColorScheme(.dark)
    }

    private func chatContent(_ chat: SloppyDesktopRecentChat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: state.backToChats) {
                    Image(systemName: "chevron.left").frame(width: 22, height: 28)
                }
                .buttonStyle(.plain)
                .help("Back to chats")
                .accessibilityLabel("Back to chats")
                .accessibilityIdentifier("notch.chat.back")
                avatar(agentID: chat.agentID, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text([chat.agentName, chat.projectName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            if let model = state.chatViewModel {
                NotchChatView(
                    viewModel: model,
                    agentID: chat.agentID,
                    agentName: chat.agentName,
                    paletteID: state.agentPalettes[chat.agentID],
                    isPresented: state.isExpanded
                )
                .id(chat.id)
            } else {
                Text("Chat is unavailable. Reconnect to Sloppy.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.selectedSection {
            case .home:
                team
                if let approval = state.toolApproval {
                    Button { _ = state.openMascotDestination() } label: {
                        Label(approval.message, systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                if !state.activeAgentRuns.isEmpty {
                    sectionHeader("Agents working", count: state.activeAgentRuns.count)
                    ForEach(state.activeAgentRuns.prefix(3)) { run in
                        Button { state.openAgentRun(run) } label: {
                            row(agentID: run.agentID, title: run.sessionTitle, subtitle: run.subtitle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !state.activeTasks.isEmpty {
                    sectionHeader("Tasks", count: state.activeTasks.count)
                    ForEach(state.activeTasks.prefix(3)) { task in taskRow(task) }
                }
                if !state.recentChats.isEmpty {
                    sectionHeader("Recent chats", count: state.recentChats.count)
                    ForEach(state.recentChats.prefix(3)) { chat in chatRow(chat) }
                }
            case .chats:
                sectionHeader("Recent chats", count: state.recentChats.count)
                if state.recentChats.isEmpty {
                    emptyState("No chats yet. Start one with +.")
                }
                ForEach(state.recentChats) { chat in chatRow(chat) }
            case .tasks:
                sectionHeader("Tasks", count: state.activeTasks.count)
                if state.activeTasks.isEmpty {
                    emptyState("No active tasks. Create one below.")
                }
                ForEach(state.activeTasks) { task in taskRow(task) }
            }
        }
    }

    private var team: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(state.teamAgents.prefix(3)) { agent in
                    Button { state.openAgent(agent) } label: {
                        VStack(spacing: 4) {
                            avatar(agentID: agent.id, size: 64)
                            Text(agent.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(state.agentStatusLabel(for: agent.id))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Chat with \(agent.displayName)")
                    .accessibilityIdentifier("notch.agent.\(agent.id)")
                }
            }
            if state.teamAgents.count > 3 {
                Menu("\(state.teamAgents.count - 3) more agents") {
                    ForEach(state.teamAgents.dropFirst(3)) { agent in
                        Button(agent.displayName) { state.openAgent(agent) }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 10))
            }
            if state.teamAgents.isEmpty {
                emptyState("Your agents will appear here when Sloppy connects.")
            }
        }
        .accessibilityIdentifier("notch.team")
    }

    private func avatar(agentID: String, size: CGFloat) -> some View {
        AgentBotAvatar(
            agentID: agentID, size: size, paletteID: state.agentPalettes[agentID],
            emotion: state.agentEmotion(for: agentID), isAnimated: state.isExpanded
        )
    }

    private func row(agentID: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 9) {
            avatar(agentID: agentID, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func chatRow(_ chat: SloppyDesktopRecentChat) -> some View {
        Button { state.openRecentChat(chat) } label: {
            row(
                agentID: chat.agentID, title: chat.title,
                subtitle: [chat.agentName, chat.projectName].compactMap { $0 }.joined(separator: " · ")
            )
        }
        .buttonStyle(.plain)
        .help("Open chat with \(chat.agentName)")
        .accessibilityIdentifier("notch.session.\(chat.id)")
    }

    private func taskRow(_ task: SloppyDesktopTask) -> some View {
        Button { state.openTask(task) } label: {
            row(
                agentID: task.agentID ?? "sloppy", title: task.title,
                subtitle: "\(task.projectName) · \(task.statusTitle)"
            )
        }
        .buttonStyle(.plain)
        .help("Open task in \(task.projectName)")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func emptyState(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
}

extension SloppyDesktopOverlayState {
    func agentEmotion(for agentID: String) -> AgentBotEmotion {
        let runs = activeAgentRuns.filter { $0.agentID == agentID }
        let tasks = activeTasks.filter { $0.agentID == agentID }
        if runs.contains(where: { $0.stage == .interrupted }) || tasks.contains(where: \.isError) { return .error }
        if toolApproval?.metadata["agentId"] == agentID
            || runs.contains(where: \.needsInput) || tasks.contains(where: \.requiresInput) { return .needsInput }
        if runs.contains(where: { $0.stage == .thinking }) { return .thinking }
        return runs.isEmpty && tasks.isEmpty ? .idle : .working
    }

    func agentStatusLabel(for agentID: String) -> String {
        switch agentEmotion(for: agentID) {
        case .error: "Needs attention"
        case .needsInput: "Waiting for you"
        case .thinking: "Thinking"
        case .working: "Working"
        case .idle, .happy, .surprised, .angry: "Ready"
        }
    }
}
#endif
