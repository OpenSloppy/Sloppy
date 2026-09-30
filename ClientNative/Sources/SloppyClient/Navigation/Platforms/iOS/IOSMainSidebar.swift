#if os(iOS)
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SwiftUI

@MainActor
struct PlatformMainSidebar: View {
    let viewModel: MainViewModel
    let isOverlay: Bool
    let canvasWorkspaceViewModel: CanvasWorkspaceViewModel
    let navigationDestination: @MainActor (MainSidebarSelection) -> AnyView

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var isAgentsPresented = false
    @State private var inboxNavigationPath = NavigationPath()
    @AppStorage("client_chat_sidebar_layout_mode") private var layoutMode = SidebarLayoutMode.list

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                mainTabs
                    .tabViewBottomAccessory {
                        if idiom == .phone, viewModel.selectedAppSection == .chats {
                            newChatAccessory
                        }
                    }
            } else {
                mainTabs
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: viewModel.sessionDeepLinkNavigationSerial) { _, _ in
            inboxNavigationPath = NavigationPath()
            inboxNavigationPath.append(MainSidebarSelection.chats)
        }
        .refreshable { await viewModel.refreshContent() }
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
                        }
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
            }

            Tab("Pull Requests", systemImage: "arrow.triangle.branch", value: MainAppSection.pullRequests) {
                NavigationStack {
                    PullRequestsScreen(
                        apiClient: viewModel.apiClient,
                        onOpenChat: viewModel.openPullRequestChat,
                        onAddToSideChat: viewModel.addToSideChat,
                        onResolveOpenIssues: viewModel.startInSideChat
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
            }

            Tab("Workspace", systemImage: "square.grid.2x2", value: MainAppSection.workspace) {
                if idiom == .phone {
                    NavigationStack {
                        CanvasWorkspaceSurface(viewModel: canvasWorkspaceViewModel)
                    }
                } else {
                    Color.clear
                }
            }
        }
    }

    @ViewBuilder
    private var inboxContent: some View {
        if normalizedSearchQuery.isEmpty {
            IOSInboxHome(
                viewModel: viewModel,
                onOpenAgents: { isAgentsPresented = true }
            )
        } else {
            IOSInboxSearchResults(
                query: normalizedSearchQuery,
                viewModel: viewModel,
                onOpenResult: { searchText = "" }
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

    @available(iOS 26.0, *)
    private var newChatAccessory: some View {
        Button(action: openNewChatComposer) {
            HStack(spacing: theme.spacing.m) {
                accessoryIcon("plus")

                Text("Plan, ask, build…")
                    .font(.title3)
                    .foregroundStyle(theme.colors.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                accessoryIcon("microphone")
            }
            .padding(.horizontal, theme.spacing.xs)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, theme.spacing.xs)
        .padding(.vertical, theme.spacing.xs)
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("sidebar.new-chat")
    }

    private func accessoryIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title2.weight(.medium))
            .foregroundStyle(theme.colors.textMuted)
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.08), in: Circle())
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
private struct IOSInboxHome: View {
    let viewModel: MainViewModel
    let onOpenAgents: @MainActor () -> Void

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
            .padding(.bottom, 96)
        }
        .background(theme.colors.background)
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

            IOSInboxMetricCard(
                title: "Working",
                count: workingCount,
                systemImage: "circle.hexagongrid.fill",
                tint: theme.colors.statusActive
            )

            IOSInboxMetricCard(
                title: "Needs Attention",
                count: attentionCount,
                systemImage: "bell.badge",
                tint: theme.colors.statusWarning
            )

            IOSInboxMetricCard(
                title: "In Review",
                count: reviewCount,
                systemImage: "checkmark.circle",
                tint: theme.colors.statusReady
            )
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
                    NavigationLink(value: MainSidebarSelection.project(project.storageID)) {
                        IOSInboxProjectRow(
                            title: project.name,
                            subtitle: viewModel.instanceTitle(for: project.sourceInstanceID),
                            systemImage: project.semanticIconName,
                            showsDisclosure: true
                        )
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            viewModel.openProjectKanbanTab(project: project)
                        }
                    )
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
                            Label(session.title, systemImage: "bubble.left")
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
                        NavigationLink(value: MainSidebarSelection.project(project.storageID)) {
                            Label(project.name, systemImage: project.semanticIconName)
                                .foregroundStyle(theme.colors.textPrimary)
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                viewModel.openProjectKanbanTab(project: project)
                                onOpenResult()
                            }
                        )
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

#Preview("iOS Sidebar") {
    PlatformMainSidebar(
        viewModel: .preview(),
        isOverlay: false,
        canvasWorkspaceViewModel: CanvasWorkspaceViewModel(),
        navigationDestination: { _ in AnyView(EmptyView()) }
    )
}
#endif
