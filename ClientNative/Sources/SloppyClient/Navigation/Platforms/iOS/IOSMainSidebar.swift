#if os(iOS)
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyFeatureChat
import SloppyFeatureProjects
import SwiftUI

@MainActor
struct PlatformMainSidebar: View {
    let viewModel: MainViewModel
    let isOverlay: Bool
    let canvasWorkspaceViewModel: CanvasWorkspaceViewModel
    var mobileComposer: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    let navigationDestination: @MainActor (MainSidebarSelection) -> AnyView

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var isAgentsPresented = false
    @State private var presentedProject: IOSProjectPresentation?
    @State private var inboxNavigationPath = NavigationPath()
    @AppStorage("client_chat_sidebar_layout_mode") private var layoutMode = SidebarLayoutMode.list

    var body: some View {
        mainTabs
        .onChange(of: viewModel.sessionDeepLinkNavigationSerial) { _, _ in
            inboxNavigationPath = NavigationPath()
            inboxNavigationPath.append(MainSidebarSelection.chats)
        }
        .refreshable { await viewModel.refreshContent() }
        .fullScreenCover(item: $presentedProject) { presentation in
            IOSProjectModal(project: presentation.project, viewModel: viewModel)
        }
        .sheet(isPresented: $isAgentsPresented) {
            AgentsScreen(apiClient: viewModel.apiClient)
        }
    }

    private var mainTabs: some View {
        @Bindable var viewModel = viewModel
        return TabView(selection: $viewModel.selectedAppSection) {
            Tab("Inbox", systemImage: "tray", value: MainAppSection.chats) {
                NavigationStack(path: $inboxNavigationPath) {
                    inboxContent
                        .navigationDestination(for: MainSidebarSelection.self) { selection in
                            navigationDestination(selection)
                                .mobileScreenBackground()
                        }
                        .mobileScreenBackground()
                        .navigationTitle(viewModel.selectedInstanceTitle)
                        .navigationBarTitleDisplayMode(.large)
                        .toolbarTitleMenu {
                            instanceSelectionMenuContent
                        }
                        .searchable(
                            text: $searchText,
                            placement: .toolbar,
                            prompt: "Search chats and projects"
                        )
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                settingsButton
                            }

                            ToolbarItemGroup(placement: .topBarTrailing) {
                                sidebarViewOptionsMenu
                                newChatToolbarButton
                            }
                        }
                }
                .modifier(IOSComposerContainer(composer: mobileComposer, viewModel: composerViewModel, allowsAutomaticFocus: isChatDestination))
                .environment(\.isChatComposerInset, true)
            }

            Tab("Attention", systemImage: "bell.badge", value: MainAppSection.attention) {
                NavigationStack {
                    AttentionScreen(inbox: viewModel.attentionInbox)
                }
            }
            .badge(viewModel.attentionInbox.unreadCount)

            Tab("Pull Requests", systemImage: "arrow.triangle.branch", value: MainAppSection.pullRequests) {
                NavigationStack {
                    PullRequestsScreen(
                        apiClient: viewModel.apiClient,
                        onBeginReview: viewModel.beginPullRequestReview,
                    onLinkChat: { detail, session in try await viewModel.linkPullRequestChat(detail, session: session) },
                        onSendReview: { detail, submission in try await viewModel.sendPullRequestReview(detail, submission: submission) }
                    )
                }
            }

            Tab("Usage", systemImage: "chart.bar", value: MainAppSection.usage) {
                NavigationStack {
                    ChatUsageScreen(
                        apiClient: viewModel.apiClient,
                        instanceTitle: viewModel.apiClient.baseURL.host ?? "Connected instance",
                        onOpenSession: viewModel.openSessionChatTab
                    )
                }
                .modifier(IOSComposerContainer(composer: mobileComposer, viewModel: composerViewModel))
                .environment(\.isChatComposerInset, true)
            }

            Tab("Workspace", systemImage: "square.grid.2x2", value: MainAppSection.workspace) {
                if idiom == .phone {
                    NavigationStack {
                        CanvasWorkspaceSurface(viewModel: canvasWorkspaceViewModel)
                    }
                    .modifier(IOSComposerContainer(composer: mobileComposer, viewModel: composerViewModel))
                } else {
                    Color.clear
                }
            }
        }
        .background(theme.colors.background.ignoresSafeArea())
    }

    private var composerViewModel: ChatScreenViewModel {
        guard let tabID = viewModel.selectedTabID, let state = viewModel.tabStates[tabID] else {
            return viewModel.chatViewModel
        }
        if let chat = state.chatState { return chat.viewModel }
        if let project = state.projectKanbanState, project.selectedSection == .chats {
            return project.chatViewModel
        }
        return viewModel.chatViewModel
    }

    private var isChatDestination: Bool {
        guard !inboxNavigationPath.isEmpty, let tabID = viewModel.selectedTabID,
              let tabState = viewModel.tabStates[tabID] else { return false }
        return tabState.chatState != nil || tabState.projectKanbanState?.selectedSection == .chats
    }

    @ViewBuilder
    private var inboxContent: some View {
        if normalizedSearchQuery.isEmpty {
            IOSInboxHome(
                viewModel: viewModel,
                onOpenAgents: { isAgentsPresented = true },
                onOpenProject: { presentedProject = IOSProjectPresentation(project: $0) }
            )
        } else {
            IOSInboxSearchResults(
                query: normalizedSearchQuery,
                viewModel: viewModel,
                onOpenResult: { searchText = "" },
                onOpenProject: {
                    searchText = ""
                    presentedProject = IOSProjectPresentation(project: $0)
                }
            )
        }
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var settingsButton: some View {
        Button {
            viewModel.onOpenSettings(.general)
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Open settings")
        .accessibilityIdentifier("inbox.settings")
    }

    @ViewBuilder
    private var instanceSelectionMenuContent: some View {
        Button {
            viewModel.selectInstance(.all)
        } label: {
            if viewModel.settings.instanceSelection == .all {
                Label("All", systemImage: "checkmark")
            } else {
                Label("All", systemImage: "square.stack.3d.up")
            }
        }

        Divider()

        ForEach(viewModel.settings.discoveredInstances) { instance in
            Button {
                viewModel.selectInstance(.instance(instance.id))
            } label: {
                let isSelected = viewModel.settings.instanceSelection == .instance(instance.id)
                Label(
                    instance.displayName,
                    systemImage: isSelected ? "checkmark" : instance.isLocal ? "desktopcomputer" : "network"
                )
            }
        }
    }

    private var sidebarViewOptionsMenu: some View {
        Menu {
            Section("Filter") {
                ForEach(ChatSidebarListMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.chatSidebarMode = mode
                    } label: {
                        if viewModel.chatSidebarMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }

            Section("View") {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutMode = .list
                    }
                } label: {
                    Label("List", systemImage: layoutMode == .list ? "checkmark" : "list.bullet")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutMode = .cards
                    }
                } label: {
                    Label("Cards", systemImage: layoutMode == .cards ? "checkmark" : "rectangle.grid.2x2")
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Chat filters and view")
        .accessibilityIdentifier("inbox.view-options")
    }

    private var newChatToolbarButton: some View {
        Button(action: openNewChatComposer) {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("inbox.new-chat")
    }

    private func openNewChatComposer() {
        viewModel.selectNewChat()
        inboxNavigationPath.append(MainSidebarSelection.chats)
        guard !viewModel.isNewChatInstancePickerPresented else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            viewModel.requestSelectedComposerFocus()
        }
    }
}

@MainActor
struct IOSComposerContainer: ViewModifier {
    let composer: @MainActor () -> AnyView
    let viewModel: ChatScreenViewModel
    var allowsAutomaticFocus = false
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentMargins(.bottom, (viewModel.composerPanelHeight ?? (idiom == .phone ? ChatComposerView.phonePanelHeight : ChatComposerView.panelHeight)) + (idiom == .phone ? theme.spacing.s : 24), for: .scrollContent)
                    .overlay {
                        if viewModel.isMobileComposerExpanded {
                            Color.black.opacity(0.35)
                                .ignoresSafeArea(edges: .top)
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.dismissComposerFocus() }
                                .accessibilityLabel("Dismiss composer")
                                .accessibilityIdentifier("chat.composer.dimming")
                        }
                    }
                if idiom == .phone {
                    composer()
                        .environment(\.allowsAutomaticComposerFocus, allowsAutomaticFocus)
                        .environment(\.mobileComposerAvailableHeight, max(196, geometry.size.height - theme.spacing.s))
                } else {
                    ChatComposerOverlay(viewModel: viewModel, contentWidth: ChatComposerView.desktopPanelWidth,
                        composerBottomInset: 24, tabs: [], tabActions: nil)
                        .environment(\.allowsAutomaticComposerFocus, allowsAutomaticFocus)
                        .accessibilityIdentifier("chat.composer.desktop-container")
                }
            }
        }
        .background(theme.colors.background.ignoresSafeArea())
        .toolbar(viewModel.isMobileComposerExpanded ? .hidden : .automatic, for: .tabBar)
    }
}

@MainActor
private struct IOSInboxHome: View {
    let viewModel: MainViewModel
    let onOpenAgents: @MainActor () -> Void
    let onOpenProject: @MainActor (APIProjectRecord) -> Void
    @State private var selectedStatus: IOSInboxTaskStatus?

    @Environment(\.theme) private var theme

    private var allTasks: [APIProjectTask] {
        viewModel.projects.flatMap { $0.tasks ?? [] }
    }

    private var workingCount: Int {
        allTasks.count { $0.status == "in_progress" }
    }

    private var attentionCount: Int {
        allTasks.count { $0.status == "blocked" }
    }

    private var reviewCount: Int {
        allTasks.count { $0.status == "needs_review" }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.spacing.xl) {
                inboxGrid
                projectsSection
                chatsSection
            }
            .padding(.horizontal, theme.spacing.m)
            .padding(.bottom, theme.spacing.m)
        }
        .background(theme.colors.background)
        .navigationDestination(item: $selectedStatus) { status in
            IOSInboxTaskList(status: status, viewModel: viewModel)
        }
    }

    private var inboxGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: theme.spacing.s),
                GridItem(.flexible(), spacing: theme.spacing.s),
            ],
            spacing: theme.spacing.s
        ) {
            Button(action: onOpenAgents) {
                IOSInboxMetricCard(
                    title: "All Agents",
                    count: viewModel.chatViewModel.agents.count,
                    systemImage: "paperplane.fill",
                    tint: theme.colors.statusBlocked
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.all-agents")

            Button { selectedStatus = .working } label: {
                IOSInboxMetricCard(
                    title: "Working",
                    count: workingCount,
                    systemImage: "circle.hexagongrid.fill",
                    tint: theme.colors.statusActive
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.working")

            Button { selectedStatus = .attention } label: {
                IOSInboxMetricCard(
                    title: "Needs Attention",
                    count: attentionCount,
                    systemImage: "bell.badge",
                    tint: theme.colors.statusWarning
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.attention")

            Button { selectedStatus = .review } label: {
                IOSInboxMetricCard(
                    title: "In Review",
                    count: reviewCount,
                    systemImage: "checkmark.circle",
                    tint: theme.colors.statusReady
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.review")
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects")
                .font(.title3)
                .foregroundStyle(theme.colors.textMuted)
                .padding(.bottom, theme.spacing.s)

            if viewModel.projects.isEmpty {
                Text("No projects yet")
                    .foregroundStyle(theme.colors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                ForEach(viewModel.projects, id: \.storageID) { project in
                    Button { onOpenProject(project) } label: {
                        IOSInboxProjectRow(
                            title: project.name,
                            subtitle: viewModel.instanceTitle(for: project.sourceInstanceID),
                            systemImage: project.semanticIconName,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }

            Button(action: viewModel.presentProjectCreator) {
                IOSInboxProjectRow(
                    title: "Add Project",
                    systemImage: "plus",
                    showsDisclosure: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.add-project-row")
        }
    }

    private var chatsSection: some View {
        SidebarRecentsList(
            viewModel: viewModel,
            showsHeaderControls: false,
            sectionTitle: "Chats"
        )
            .padding(.horizontal, -theme.spacing.xs)
    }
}

private struct IOSInboxMetricCard: View {
    let title: String
    let count: Int
    let systemImage: String
    let tint: Color

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(count.formatted())
                    .foregroundStyle(theme.colors.textMuted)
            }
            .font(.headline)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        }
        .padding(theme.spacing.m)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.colors.border, lineWidth: theme.borders.thin)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct IOSInboxProjectRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let showsDisclosure: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.spacing.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(theme.colors.textMuted)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: theme.spacing.s)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
    }
}

@MainActor
private struct IOSInboxSearchResults: View {
    let query: String
    let viewModel: MainViewModel
    let onOpenResult: @MainActor () -> Void
    let onOpenProject: @MainActor (APIProjectRecord) -> Void

    @Environment(\.theme) private var theme

    private var chatResults: [ChatSessionSummary] {
        viewModel.sidebarSessionCatalog.filter {
            $0.title.localizedStandardContains(query)
        }
    }

    private var projectResults: [APIProjectRecord] {
        viewModel.projects.filter {
            $0.name.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            if !chatResults.isEmpty {
                Section("Chats") {
                    ForEach(chatResults, id: \.storageID) { session in
                        NavigationLink(value: MainSidebarSelection.chats) {
                            Label(session.displayTitle, systemImage: "bubble.left")
                                .foregroundStyle(theme.colors.textPrimary)
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                viewModel.openSessionChatTab(session)
                                onOpenResult()
                            }
                        )
                    }
                }
            }

            if !projectResults.isEmpty {
                Section("Projects") {
                    ForEach(projectResults, id: \.storageID) { project in
                        Button { onOpenProject(project) } label: {
                            Label(project.name, systemImage: project.semanticIconName)
                                .foregroundStyle(theme.colors.textPrimary)
                        }
                    }
                }
            }

            if chatResults.isEmpty, projectResults.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .listStyle(.insetGrouped)
    }
}


private struct IOSProjectPresentation: Identifiable {
    let project: APIProjectRecord
    var id: String { project.storageID }
}

@MainActor
private struct IOSProjectModal: View {
    let project: APIProjectRecord
    let viewModel: MainViewModel
    @State private var state: ProjectKanbanTabState
    @Environment(\.dismiss) private var dismiss

    init(project: APIProjectRecord, viewModel: MainViewModel) {
        self.project = project
        self.viewModel = viewModel
        _state = State(initialValue: viewModel.projectModeState(for: project))
    }

    var body: some View {
        ProjectModeView(
            project: project,
            state: state,
            rootSafeAreaInsets: EdgeInsets(),
            onSelectSection: { viewModel.selectProjectModeSection($0, project: project) },
            onOpenTask: { _ in },
            onOpenTaskChat: { task in
                viewModel.openTaskChatTab(project: project, task: task, fallbackAgentId: nil)
                viewModel.selectAppSection(.chats)
                viewModel.sessionDeepLinkNavigationSerial += 1
                dismiss()
            }
        )
        .environment(\.isChatComposerInset, true)
        .task { viewModel.activateProjectModeSection(state.selectedSection, project: project, state: state) }
    }
}

private enum IOSInboxTaskStatus: String, Identifiable {
    case working = "in_progress"
    case attention = "blocked"
    case review = "needs_review"
    var id: Self { self }
    var title: String {
        switch self {
        case .working: "Working"
        case .attention: "Needs Attention"
        case .review: "In Review"
        }
    }
}

@MainActor
private struct IOSInboxTaskList: View {
    let status: IOSInboxTaskStatus
    let viewModel: MainViewModel
    @Environment(\.theme) private var theme

    private var projects: [APIProjectRecord] {
        viewModel.projects.filter { ($0.tasks ?? []).contains { $0.status == status.rawValue } }
    }

    var body: some View {
        List {
            ForEach(projects, id: \.storageID) { project in
                Section {
                    ForEach((project.tasks ?? []).filter { $0.status == status.rawValue }, id: \.id) { task in
                        NavigationLink {
                            IOSInboxTaskDetail(project: project, taskID: task.id, viewModel: viewModel)
                        } label: {
                            ProjectTaskInboxRow(
                                task: task,
                                actorName: actorName(for: task, in: project),
                                attention: attention(for: task, in: project)
                            )
                        }
                        .listRowBackground(theme.colors.background)
                        .accessibilityIdentifier("inbox.open-task.\(task.id)")
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.headline).textCase(nil)
                        if let instance = viewModel.instanceTitle(for: project.sourceInstanceID) {
                            Text(instance).font(.caption)
                        }
                    }
                    .foregroundStyle(theme.colors.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .tint(theme.colors.textPrimary)
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView("No tasks", systemImage: "checklist", description: Text("There are no tasks in this status."))
            }
        }
        .mobileScreenBackground()
        .navigationTitle(status.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func attention(for task: APIProjectTask, in project: APIProjectRecord) -> ProactiveFinding? {
        let endpoint = project.sourceInstanceID.flatMap(viewModel.endpoint(for:)) ?? viewModel.endpoint
        guard endpoint == viewModel.endpoint else { return nil }
        return viewModel.attentionInbox.findings.first {
            $0.source.projectId == project.id && $0.source.taskId == task.id && $0.isActiveAttention(at: Date())
        }
    }

    private func actorName(for task: APIProjectTask, in project: APIProjectRecord) -> String? {
        let endpoint = project.sourceInstanceID.flatMap(viewModel.endpoint(for:)) ?? viewModel.endpoint
        guard endpoint == viewModel.endpoint else { return nil }
        let id = task.claimedActorId ?? task.claimedAgentId ?? task.actorId
        return viewModel.chatViewModel.agents.first { $0.id == id }?.displayName
    }
}

@MainActor
private struct IOSInboxTaskDetail: View {
    let project: APIProjectRecord
    let taskID: String
    let viewModel: MainViewModel
    @State private var detail: TaskDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(project: APIProjectRecord, taskID: String, viewModel: MainViewModel) {
        self.project = project
        self.taskID = taskID
        self.viewModel = viewModel
        let endpoint = project.sourceInstanceID.flatMap(viewModel.endpoint(for:)) ?? viewModel.endpoint
        _detail = State(initialValue: TaskDetailViewModel(apiClient: SloppyAPIClient(endpoint: endpoint)))
    }

    var body: some View {
        TaskDetailView(
            viewModel: detail,
            projectId: project.id,
            taskId: taskID,
            onClose: { dismiss() },
            onTaskChanged: { await viewModel.loadProjects(force: true) }
        )
        .mobileScreenBackground()
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("iOS Sidebar") {
    PlatformMainSidebar(
        viewModel: .preview(),
        isOverlay: false,
        canvasWorkspaceViewModel: CanvasWorkspaceViewModel(),
        navigationDestination: { _ in AnyView(EmptyView()) }
    )
}
#endif
