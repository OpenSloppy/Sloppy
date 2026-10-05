import Foundation
import Testing

@Suite("Main sidebar project sessions")
struct MainSidebarProjectSessionsTests {
    private var source: String {
        get throws {
            try sourceFile("Sources/SloppyClient/Navigation/Shared/SidebarRecentsList.swift")
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try mainViewAwareSourceContents(at: packageRoot.appendingPathComponent(relativePath))
    }

    @Test("project groups include sessions created in workspace chat tabs")
    func projectGroupsIncludeSessionsCreatedInWorkspaceChatTabs() throws {
        let source = try source
        let mainViewModelSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")
        let chatViewModelSource = try sourceFile("Sources/SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")

        #expect(source.contains("ChatSidebarSections.build("))
        #expect(source.contains("sessions: visibleSessions"))
        #expect(source.contains("return viewModel.sidebarSessionCatalog.filter(requiresApproval)"))
        #expect(source.contains("defaultSourceInstanceID: viewModel.sidebarDefaultSourceInstanceID"))
        #expect(mainViewModelSource.contains("!settings.isSessionArchived($0.storageID)"))
        #expect(mainViewModelSource.contains("tagged.sourceInstanceID = activeInstanceID"))
        #expect(mainViewModelSource.contains("loadedSidebarSessions ?? chatViewModel.sessionCatalog"))
        #expect(mainViewModelSource.contains("func synchronizeSidebarSessionCatalog()"))
        #expect(mainViewModelSource.contains("loadedSidebarSessions = chatViewModel.sessionCatalog"))
        #expect(mainViewModelSource.contains("loadsGlobalSessionCatalog: true"))
        #expect(mainViewModelSource.contains("onSessionSummaryChange: { [weak self] summary in"))
        #expect(mainViewModelSource.contains("self?.chatViewModel.mergeSessionSummary(tagged)"))
        #expect(mainViewModelSource.contains("self?.synchronizeSidebarSessionCatalog()"))
        #expect(chatViewModelSource.contains("public func mergeSessionSummary(_ summary: ChatSessionSummary)"))
        #expect(chatViewModelSource.contains("onSessionSummaryChange(summary)"))
        #expect(source.contains("ForEach(sections.projectGroups.prefix(viewModel.visibleProjectCount))"))
        #expect(source.contains("ForEach(sessions, id: \\.storageID)"))
        #expect(source.contains("SidebarSessionItem(\n                        viewModel: viewModel,\n                        session: $0,"))
        #expect(source.contains("showsProjectName: false"))
    }

    @Test("sidebar session rows render typed activity and monitor visible sessions")
    func sidebarSessionRowsRenderActivity() throws {
        let listSource = try source
        let rowSource = try sourceFile("Sources/SloppyClient/Navigation/Shared/SidebarSessionRow.swift")
        let avatarSource = try sourceFile("Sources/SloppyClient/Navigation/Shared/SidebarSessionAvatar.swift")
        let mainViewModelSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(rowSource.contains("SidebarSessionAvatar("))
        #expect(avatarSource.contains("sidebar.session.avatar"))
        #expect(listSource.contains("viewModel.sidebarSessionActivity(for: session)"))
        #expect(listSource.contains("viewModel.monitorSidebarSessionActivity(for: session)"))
        #expect(mainViewModelSource.contains("detail.latestRunStatus?.stage"))
        #expect(mainViewModelSource.contains("detail.pendingInputRequest != nil"))
    }

    @Test("aggregated project chats install after the primary catalog finishes loading")
    func aggregatedProjectChatsInstallAfterPrimaryCatalogLoad() throws {
        let mainViewSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let chatViewModelSource = try sourceFile("Sources/SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")
        let waitIndex = try #require(
            mainViewSource.range(of: "await viewModel.chatViewModel.waitForInitialData()")?.lowerBound
        )
        let aggregateIndex = try #require(
            mainViewSource.range(of: "await viewModel.loadAggregatedChatCatalogIfNeeded()")?.lowerBound
        )

        #expect(waitIndex < aggregateIndex)
        #expect(chatViewModelSource.contains("private var initialDataTask: Task<Void, Never>?"))
        #expect(chatViewModelSource.contains("public func waitForInitialData() async"))
        #expect(chatViewModelSource.contains("await task?.value"))
        #expect(chatViewModelSource.contains("ChatSessionCatalog.mergeAggregated(existing: sessionCatalog, incoming: sessions)"))
    }

    @Test("project list reveals additional projects in pages")
    func projectListRevealsAdditionalProjectsInPages() throws {
        let source = try source
        let mainViewModelSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(source.contains("sections.projectGroups.prefix(viewModel.visibleProjectCount)"))
        #expect(source.contains("Text(\"Show more projects\")"))
        #expect(source.contains("viewModel.showMoreProjects()"))
        #expect(mainViewModelSource.contains("var visibleProjectCount = 6"))
        #expect(mainViewModelSource.contains("visibleProjectCount += 6"))
    }

    @Test("sidebar can display chats and projects as cards")
    func sidebarSupportsCardLayout() throws {
        let source = try source
        let cardsSource = try sourceFile("Sources/SloppyClient/Navigation/Shared/SidebarCards.swift")

        #expect(source.contains("client_chat_sidebar_layout_mode"))
        #expect(source.contains("layoutMode == .cards"))
        #expect(source.contains("LazyVGrid(columns: cardColumns"))
        #expect(source.contains("SidebarSessionCard("))
        #expect(source.contains("requiresApproval: requiresApproval(session)"))
        #expect(source.contains("SidebarProjectCard(viewModel: viewModel, group: $0)"))
        #expect(source.contains("Show as cards"))
        #expect(source.contains("Show as list"))
        #expect(source.contains(".padding(.leading, theme.spacing.m)"))
        #expect(cardsSource.contains("if group.project.isFavorite"))
        #expect(cardsSource.contains(".accessibilityLabel(\"Pinned project\")"))
        #expect(cardsSource.contains("Text(\"\\(group.allSessionsCount) chats\")"))
    }

    @Test("project and recents session rows open session-backed tabs")
    func projectAndRecentsSessionRowsOpenSessionBackedTabs() throws {
        let source = try source

        #expect(source.contains("viewModel.openSessionChatTab(session)"))
        #expect(!source.contains("viewModel.selectChatSession(session)"))
    }

    @Test("project row reveals a project-scoped new chat action on hover")
    func projectRowRevealsProjectScopedNewChatActionOnHover() throws {
        let sidebarSource = try source
        let mainViewModelSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(sidebarSource.contains("viewModel.showNewProjectChat(project: group.project)"))
        #expect(sidebarSource.contains("Icons.symbol(.chatAddOn"))
        #expect(sidebarSource.contains(".opacity(Double(isHovered ? 1 : 0))"))
        #expect(sidebarSource.contains(".help(\"Open conversation\")"))

        let methodStart = try #require(mainViewModelSource.range(of: "func showNewProjectChat(project: APIProjectRecord)"))
        let nextMethod = try #require(
            mainViewModelSource.range(
                of: "func selectTask(",
                range: methodStart.upperBound..<mainViewModelSource.endIndex
            )
        )
        let methodSource = mainViewModelSource[methodStart.lowerBound..<nextMethod.lowerBound]

        #expect(methodSource.contains("context: .project("))
        #expect(methodSource.contains("to: chatState.viewModel"))
        #expect(methodSource.contains("loadInitialData: true"))
        #expect(methodSource.contains("showInSelectedTab("))
        #expect(!methodSource.contains("tabs.append(tab)"))
    }

    @Test("project navigation reuses the current tab while explicit tab creation appends")
    func projectNavigationReusesCurrentTabWhileExplicitCreationAppends() throws {
        let mainViewModelSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        let projectStart = try #require(mainViewModelSource.range(of: "func openProjectKanbanTab(project: APIProjectRecord)"))
        let projectEnd = try #require(
            mainViewModelSource.range(
                of: "func showNewProjectChat(",
                range: projectStart.upperBound..<mainViewModelSource.endIndex
            )
        )
        let projectMethod = mainViewModelSource[projectStart.lowerBound..<projectEnd.lowerBound]

        #expect(projectMethod.contains("showInSelectedTab("))
        #expect(!projectMethod.contains("tabs.append(tab)"))

        let createStart = try #require(mainViewModelSource.range(of: "func createBlankChatTab(select: Bool = true)"))
        let createEnd = try #require(
            mainViewModelSource.range(
                of: "func showBlankChatInSelectedTab(endpoint:",
                range: createStart.upperBound..<mainViewModelSource.endIndex
            )
        )
        let createMethod = mainViewModelSource[createStart.lowerBound..<createEnd.lowerBound]

        #expect(createMethod.contains("tabs.append(tab)"))
        #expect(createMethod.contains("selectedTabID = tab.id"))

        #expect(mainViewModelSource.contains("private func showInSelectedTab("))
        #expect(mainViewModelSource.contains("state: WorkspaceTabState,"))
        #expect(mainViewModelSource.contains("id: selectedTabID"))
        #expect(mainViewModelSource.contains("tabStates[selectedTabID] = state"))
    }

    @Test("new projects open a scoped chat and project rows support drag reordering")
    func newProjectsOpenAScopedChatAndProjectRowsSupportDragReordering() throws {
        let sidebarSource = try source
        let mainViewModelSource = try sourceFile("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(sidebarSource.contains(".draggable(group.id)"))
        #expect(sidebarSource.contains(".dropDestination(for: String.self)"))
        #expect(sidebarSource.contains("viewModel.moveProject(projectID, relativeTo: group.id)"))

        let saveStart = try #require(mainViewModelSource.range(of: "func didSaveProject(_ project: APIProjectRecord)"))
        let saveEnd = try #require(
            mainViewModelSource.range(
                of: "func showNewProjectChat(",
                range: saveStart.upperBound..<mainViewModelSource.endIndex
            )
        )
        let saveMethod = mainViewModelSource[saveStart.lowerBound..<saveEnd.lowerBound]

        #expect(saveMethod.contains("projects.insert(project, at: 0)"))
        #expect(saveMethod.contains("showNewProjectChat(project: project)"))
        #expect(saveMethod.contains("persistProjectOrder()"))
    }
}
