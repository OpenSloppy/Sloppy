import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct SidebarSessionCard: View {
    let viewModel: MainViewModel
    let session: ChatSessionSummary
    var requiresApproval = false

    @Environment(\.theme) private var theme

    private var title: String { session.title.isEmpty ? "Chat" : session.title }
    private var projectName: String {
        viewModel.projectName(for: session) ?? "No project"
    }
    private var isPinned: Bool { viewModel.settings.isSessionPinned(session.storageID) }
    private var isSelected: Bool { viewModel.selectedChatStorageID == session.storageID }
    private var chatColor: Color? { viewModel.settings.sidebarColor(for: session) }
    private var activityTaskID: String { "\(session.storageID):\(session.updatedAt.timeIntervalSince1970)" }

    var body: some View {
        primaryAction
            .buttonStyle(.plain)
            .contextMenu {
                Button(isPinned ? "Unpin Chat" : "Pin Chat") {
                    viewModel.togglePinChatSession(session)
                }
                Menu {
                    Button { setChatColor(nil) } label: {
                        SidebarColorMenuOption(
                            title: "Default",
                            color: nil,
                            isSelected: viewModel.settings.chatColors[session.storageID] == nil
                        )
                    }
                    Divider()
                    ForEach(SidebarProjectColor.allCases, id: \.self) { tint in
                        Button {
                            setChatColor(tint.rawValue)
                        } label: {
                            SidebarColorMenuOption(
                                title: tint.rawValue.capitalized,
                                color: tint,
                                isSelected: viewModel.settings.chatColors[session.storageID] == tint.rawValue
                            )
                        }
                    }
                } label: {
                    Label("Chat Color", systemImage: "paintpalette")
                }
                Button("Copy Session File Debug Link") {
                    viewModel.copyDebugSessionFileLink(session)
                }
                Button("Delete Chat", role: .destructive) {
                    viewModel.deleteChatSession(session)
                }
            }
            .accessibilityHint("Project \(projectName)")
            .task(id: activityTaskID) {
                await viewModel.monitorSidebarSessionActivity(for: session)
            }
    }

    @ViewBuilder
    private var primaryAction: some View {
        #if os(macOS)
        Button { viewModel.openSessionChatTab(session) } label: { content }
        #else
        NavigationLink(value: MainSidebarSelection.chats) { content }
            .simultaneousGesture(TapGesture().onEnded { viewModel.openSessionChatTab(session) })
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            HStack(spacing: theme.spacing.xs) {
                SidebarSessionAvatar(agentID: session.agentId,
                                     agents: viewModel.sidebarSessionAvatarAgents(for: session),
                                     activity: viewModel.sidebarSessionActivity(for: session),
                                     requiresApproval: requiresApproval, size: 30)
                Text(cardDate(session.updatedAt))
                    .font(.system(size: theme.typography.caption, weight: .semibold))
                    .foregroundColor(theme.colors.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPinned {
                    Icons.symbol(.pushPin, size: theme.typography.caption)
                        .foregroundColor(theme.colors.textMuted)
                }
            }

            Text(title)
                .font(.system(size: theme.typography.body, weight: .bold))
                .foregroundColor(theme.colors.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            Spacer(minLength: theme.spacing.xs)

            VStack(alignment: .leading, spacing: 3) {
                Label(projectName, systemImage: "folder")
                    .lineLimit(1)
                Text("\(session.messageCount) messages")
                if let instanceName = viewModel.instanceTitle(for: session.sourceInstanceID) {
                    Label(instanceName, systemImage: "desktopcomputer")
                        .lineLimit(1)
                }
            }
            .font(.system(size: theme.typography.caption))
            .foregroundColor(theme.colors.textSecondary)
        }
        .padding(theme.spacing.m)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(theme.colors.surfaceRaised)
            if let chatColor {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(chatColor.opacity(0.18))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isSelected ? theme.colors.accent : theme.colors.border, lineWidth: theme.borders.thin)
            }
    }

    private func setChatColor(_ value: String?) {
        if let value {
            viewModel.settings.chatColors[session.storageID] = value
        } else {
            viewModel.settings.chatColors.removeValue(forKey: session.storageID)
        }
    }
}

@MainActor
struct SidebarProjectCard: View {
    let viewModel: MainViewModel
    let group: ChatSidebarProjectGroup

    @Environment(\.theme) private var theme
    @State private var isDropTarget = false
    @State private var isHovered = false

    private var projectColor: Color? { viewModel.settings.sidebarColor(for: group.project) }

    private var isSelected: Bool { viewModel.selectedSidebarItem == .project(group.id) }
    private var projectDescription: String {
        let description = group.project.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "No description" : description
    }

    var body: some View {
        NavigationLink(value: MainSidebarSelection.project(group.id)) {
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                HStack {
                    Image(systemName: group.project.semanticIconName)
                        .font(.system(size: theme.typography.body, weight: .semibold))
                        .foregroundColor(projectColor ?? theme.colors.accentCyan)
                    Spacer(minLength: 0)
                    if group.project.isFavorite {
                        Icons.symbol(.pushPin, size: theme.typography.caption)
                            .foregroundColor(theme.colors.textMuted)
                            .accessibilityLabel("Pinned project")
                    }
                    Text("\(group.allSessionsCount) chats")
                        .font(.system(size: theme.typography.caption, weight: .semibold))
                        .foregroundColor(theme.colors.textMuted)
                }

                Text(group.project.name)
                    .font(.system(size: theme.typography.body, weight: .bold))
                    .foregroundColor(theme.colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if let instanceName = viewModel.instanceTitle(for: group.project.sourceInstanceID) {
                    Label(instanceName, systemImage: "desktopcomputer")
                        .font(.system(size: theme.typography.caption))
                        .foregroundColor(theme.colors.textMuted)
                        .lineLimit(1)
                }

                Text(projectDescription)
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(theme.colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)

                Spacer(minLength: theme.spacing.xs)

                SidebarProjectTaskCounts(project: group.project)
            }
            .padding(theme.spacing.m)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isDropTarget ? theme.colors.surfaceGlow : theme.colors.surfaceRaised)
                if let projectColor {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(projectColor.opacity(0.20 as Double))
                }
                if isHovered {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.primary.opacity(0.06))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? theme.colors.accent : theme.colors.border, lineWidth: theme.borders.thin)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.openProjectKanbanTab(project: group.project)
        })
        .buttonStyle(.plain)
        .draggable(group.id)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .dropDestination(for: String.self) { projectIDs, _ in
            guard let projectID = projectIDs.first else { return false }
            return viewModel.moveProject(projectID, relativeTo: group.id)
        } isTargeted: {
            isDropTarget = $0
        }
        .projectContextMenu(viewModel: viewModel, project: group.project)
    }
}

private func cardDate(_ date: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInYesterday(date) {
        return "Yesterday"
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.day().month().year())
}
