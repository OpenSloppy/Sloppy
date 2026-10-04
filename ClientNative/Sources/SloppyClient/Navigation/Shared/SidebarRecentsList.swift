import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct SidebarRecentsList: View {
    let viewModel: MainViewModel
    var showsHeaderControls = true
    var sectionTitle: String? = nil
    var approvalRequiredSessionIDs: Set<String> = []
    var showsApprovalRequiredOnly = false

    @Environment(\.theme) private var theme
    @AppStorage("client_chat_sidebar_layout_mode") private var layoutMode = SidebarLayoutMode.list
    @State private var isShowMoreHovered = false

    private var sections: ChatSidebarSections {
        ChatSidebarSections.build(
            sessions: visibleSessions,
            projects: visibleProjects,
            pinnedSessionIds: viewModel.chatViewModel.pinnedSessionIds,
            mode: viewModel.chatSidebarMode,
            projectPreviewLimit: 5,
            defaultSourceInstanceID: viewModel.sidebarDefaultSourceInstanceID
        )
    }

    private var visibleSessions: [ChatSessionSummary] {
        guard showsApprovalRequiredOnly else { return viewModel.sidebarSessionCatalog }
        return viewModel.sidebarSessionCatalog.filter(requiresApproval)
    }

    private var visibleProjects: [APIProjectRecord] {
        guard showsApprovalRequiredOnly else { return viewModel.projects }
        let projectIDs = Set(visibleSessions.compactMap(\.projectId))
        return viewModel.projects.filter { projectIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            #if os(macOS)
            if viewModel.chatSidebarMode == .projects {
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    sectionsContent
                }
            } else {
                LazyVStack(alignment: .leading, spacing: theme.spacing.s) {
                    sectionsContent
                }
            }
            #else
            LazyVStack(alignment: .leading, spacing: theme.spacing.s) {
                sectionsContent
            }
            #endif
        }
        .padding(.horizontal, theme.spacing.xs)
    }

    @ViewBuilder
    private var sectionsContent: some View {
        if !sections.pinned.isEmpty {
            SidebarSectionTitle(title: "Priority")
            if layoutMode == .cards {
                sessionCardGrid(sections.pinned)
            } else {
                ForEach(sections.pinned) {
                    SidebarSessionItem(
                        viewModel: viewModel,
                        session: $0,
                        requiresApproval: requiresApproval($0)
                    )
                }
            }
        }

        HStack {
            SidebarSectionTitle(title: sectionTitle ?? viewModel.chatSidebarMode.title)
            Spacer()
            if showsHeaderControls, viewModel.chatSidebarMode == .projects {
                Button {
                    viewModel.presentProjectCreator()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New project")
                .help("New project")
            }
            if showsHeaderControls, !viewModel.chatViewModel.sessionCatalog.isEmpty {
                SidebarListModeMenu(viewModel: viewModel)
            }
            if showsHeaderControls {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutMode = layoutMode == .list ? .cards : .list
                    }
                } label: {
                    Image(systemName: layoutMode == .list ? "rectangle.grid.2x2" : "list.bullet")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layoutMode == .list ? "Show as cards" : "Show as list")
                .help(layoutMode == .list ? "Card view" : "List view")
            }
        }
        .padding(.trailing, theme.spacing.m)
        .padding(.top, theme.spacing.s)

        content

        if let status = viewModel.chatViewModel.sessionActionStatus {
            Text(status)
                .font(.system(size: theme.typography.micro))
                .foregroundColor(theme.colors.textMuted)
                .padding(.horizontal, theme.spacing.m)
        }
        if let status = viewModel.projectActionStatus {
            Text(status)
                .font(.system(size: theme.typography.micro))
                .foregroundColor(theme.colors.textMuted)
                .padding(.horizontal, theme.spacing.m)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.chatViewModel.isLoadingSessions && viewModel.chatViewModel.sessionCatalog.isEmpty {
            SidebarStatusText(text: "Loading chats…")
        } else if sections.pinned.isEmpty && sections.sessions.isEmpty && sections.projectGroups.isEmpty {
            SidebarStatusText(text: showsApprovalRequiredOnly ? "No chats require approval" : "No chats yet")
        } else if viewModel.chatSidebarMode == .allChats {
            if layoutMode == .cards {
                sessionCardGrid(sections.sessions)
            } else {
                ForEach(sections.dayGroups) { group in
                    SidebarSectionTitle(title: daySectionTitle(for: group.day))
                        .padding(.top, theme.spacing.s)
                    ForEach(group.sessions, id: \.storageID) { session in
                        SidebarSessionItem(
                            viewModel: viewModel,
                            session: session,
                            requiresApproval: requiresApproval(session)
                        )
                    }
                }
            }
        } else {
            if layoutMode == .cards {
                LazyVGrid(columns: cardColumns, alignment: .leading, spacing: theme.spacing.s) {
                    ForEach(sections.projectGroups.prefix(viewModel.visibleProjectCount)) {
                        SidebarProjectCard(viewModel: viewModel, group: $0)
                    }
                }
                .padding(.horizontal, theme.spacing.xs)
            } else {
                ForEach(sections.projectGroups.prefix(viewModel.visibleProjectCount)) {
                    SidebarProjectGroupView(
                        viewModel: viewModel,
                        group: $0,
                        approvalRequiredSessionIDs: approvalRequiredSessionIDs
                    )
                }
            }

            if sections.projectGroups.count > viewModel.visibleProjectCount {
                Button {
                    viewModel.showMoreProjects()
                } label: {
                    HStack(spacing: theme.spacing.s) {
                        Text("Show more projects")
                        Image(systemName: "arrow.right")
                    }
                    .padding(theme.spacing.s)
                }
                .buttonStyle(SidebarHoverButtonStyle(isHovered: isShowMoreHovered))
                .onHover { isShowMoreHovered = $0 }
                .foregroundColor(theme.colors.textMuted)
                .padding(.leading, theme.spacing.m)
                .padding(.vertical, theme.spacing.s)
            }
        }
    }

    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 148, maximum: 280), spacing: theme.spacing.s, alignment: .top)]
    }

    private func sessionCardGrid(_ sessions: [ChatSessionSummary]) -> some View {
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: theme.spacing.s) {
            ForEach(sessions, id: \.storageID) { session in
                SidebarSessionCard(
                    viewModel: viewModel,
                    session: session,
                    requiresApproval: requiresApproval(session)
                )
            }
        }
        .padding(.horizontal, theme.spacing.xs)
    }

    private func requiresApproval(_ session: ChatSessionSummary) -> Bool {
        approvalRequiredSessionIDs.contains(session.id)
            || approvalRequiredSessionIDs.contains(session.storageID)
    }

    private func daySectionTitle(for day: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(day) {
            return "Today"
        }

        let today = calendar.startOfDay(for: Date())
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if (1...6).contains(daysAgo) {
            return day.formatted(.dateTime.weekday(.wide))
        }

        if calendar.component(.year, from: day) == calendar.component(.year, from: today) {
            return day.formatted(.dateTime.month(.wide).day())
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

enum SidebarLayoutMode: String {
    case list
    case cards
}

@MainActor
private struct SidebarSessionItem: View {
    let viewModel: MainViewModel
    let session: ChatSessionSummary
    var requiresApproval = false
    var showsProjectName = true

    private var activityTaskID: String {
        "\(session.storageID):\(session.updatedAt.timeIntervalSince1970)"
    }

    var body: some View {
        SidebarSessionRow(
            session: session,
            projectName: viewModel.projectName(for: session),
            instanceName: viewModel.instanceTitle(for: session.sourceInstanceID),
            showsProjectName: showsProjectName,
            isPinned: viewModel.settings.isSessionPinned(session.storageID),
            isSelected: viewModel.selectedChatStorageID == session.storageID,
            requiresApproval: requiresApproval,
            activity: viewModel.sidebarSessionActivity(for: session),
            chatColor: viewModel.settings.sidebarChatColor(for: session),
            avatarAgents: viewModel.sidebarSessionAvatarAgents(for: session),
            onOpen: { viewModel.openSessionChatTab(session) },
            onTogglePin: { viewModel.togglePinChatSession(session) },
            onCopyDebugLink: { viewModel.copyDebugSessionFileLink(session) },
            onDelete: { viewModel.deleteChatSession(session) },
            onSetChatColor: { color in
                if let color {
                    viewModel.settings.chatColors[session.storageID] = color
                } else {
                    viewModel.settings.chatColors.removeValue(forKey: session.storageID)
                }
            }
        )
        .task(id: activityTaskID) {
            await viewModel.monitorSidebarSessionActivity(for: session)
        }
    }
}

@MainActor
private struct SidebarProjectGroupView: View {
    let viewModel: MainViewModel
    let group: ChatSidebarProjectGroup
    var approvalRequiredSessionIDs: Set<String> = []

    @Environment(\.theme) private var theme

    private var isCollapsed: Bool { viewModel.collapsedProjectIds.contains(group.id) }
    private var isExpanded: Bool { viewModel.expandedTaskLists.contains(group.id) }
    private var sessions: [ChatSessionSummary] { isExpanded ? group.totalSessions : group.visibleSessions }

    private var isSelected: Bool {
        viewModel.selectedSidebarItem == .project(group.id)
    }

    @State private var isHovered = false
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.spacing.xs) {
                NavigationLink(value: MainSidebarSelection.project(group.id)) {
                    HStack(spacing: theme.spacing.s) {
                        Image(systemName: group.project.semanticIconName)
                            .font(.system(size: theme.typography.body))
                            .foregroundColor(viewModel.settings.sidebarColor(for: group.project) ?? (isSelected ? theme.colors.accentCyan : theme.colors.textMuted))
                            .frame(width: 22)
                        Text(group.project.name)
                            .font(.system(size: theme.typography.body))
                            .foregroundColor(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                            .lineLimit(1)
                        if let instanceName = viewModel.instanceTitle(for: group.project.sourceInstanceID) {
                            Text(instanceName)
                                .font(.system(size: theme.typography.micro, weight: .semibold))
                                .foregroundColor(theme.colors.textMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.colors.surfaceRaised, in: Capsule())
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        viewModel.openProjectKanbanTab(project: group.project)
                    }
                )
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

                Button {
                    viewModel.showNewProjectChat(project: group.project)
                } label: {
                    Icons.symbol(.chatAddOn, size: theme.typography.body)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.colors.textMuted)
                .opacity(Double(isHovered ? 1 : 0))
                .allowsHitTesting(isHovered)
                .accessibilityLabel("Open main chat in \(group.project.name)")
                .help("Open main long chat")

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: theme.typography.caption, weight: .semibold))
                    .foregroundColor(theme.colors.textMuted)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
                    .draggable(group.id)
                    .opacity(isHovered ? 1.0 : 0.0)
                    .allowsHitTesting(isHovered)
                    .accessibilityLabel("Reorder \(group.project.name)")
                    .help("Drag to reorder")

                Button {
                    viewModel.toggleProjectCollapse(projectId: group.id)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: theme.typography.caption, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.colors.textMuted)
                .opacity(isHovered ? 1.0 : 0.0)
                .allowsHitTesting(isHovered)
                .accessibilityLabel(isCollapsed ? "Expand \(group.project.name)" : "Collapse \(group.project.name)")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: MainSidebarView.rowMinimumHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered || isSelected || isDropTarget ? theme.colors.surfaceRaised : .clear)
            }
            .dropDestination(for: String.self) { projectIDs, _ in
                guard let projectID = projectIDs.first else { return false }
                return viewModel.moveProject(projectID, relativeTo: group.id)
            } isTargeted: {
                isDropTarget = $0
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .projectContextMenu(viewModel: viewModel, project: group.project)

            if !isCollapsed {
                ForEach(sessions, id: \.storageID) {
                    SidebarSessionItem(
                        viewModel: viewModel,
                        session: $0,
                        requiresApproval: approvalRequiredSessionIDs.contains($0.id)
                            || approvalRequiredSessionIDs.contains($0.storageID),
                        showsProjectName: false
                    )
                }

                if group.hiddenCount > 0 {
                    Button(isExpanded ? "Show less" : "Show more") {
                        viewModel.toggleTaskListExpansion(projectId: group.id)
                    }
                    .clipShape(Rectangle())
                    .buttonStyle(.plain)
                    .foregroundColor(theme.colors.textMuted)
                    .padding(.leading, 42)
                    .padding(.vertical, theme.spacing.s)
                }
            }
        }
        .animation(.linear(duration: 0.2), value: isCollapsed)
    }
}

private struct SidebarSectionTitle: View {
    let title: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(title)
            .font(.system(size: theme.typography.body))
            .foregroundColor(theme.colors.textMuted)
            .padding(.horizontal, theme.spacing.s)
    }
}

private struct SidebarStatusText: View {
    let text: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(text)
            .font(.system(size: theme.typography.caption))
            .foregroundColor(theme.colors.textMuted)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
    }
}

@MainActor
private struct SidebarListModeMenu: View {
    let viewModel: MainViewModel
    var body: some View {
        Menu {
            ForEach(ChatSidebarListMode.allCases, id: \.self) { mode in
                Button(mode.title) { viewModel.chatSidebarMode = mode }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
    }
}

#Preview("Recents List") {
    let viewModel = MainViewModel.preview()
    SidebarRecentsList(viewModel: viewModel)
        .frame(width: 348, height: 520, alignment: .top)
        .task {
            await viewModel.loadProjects()
        }
}
