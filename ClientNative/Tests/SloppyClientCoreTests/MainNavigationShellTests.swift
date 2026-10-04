import Foundation
import Testing

@Suite("Main navigation shell")
struct MainNavigationShellTests {
    private func source(named fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SloppyClient")
        let sourceURL = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )?
            .compactMap { $0 as? URL }
            .first(where: { $0.lastPathComponent == fileName })
        return try mainViewAwareSourceContents(at: #require(sourceURL))
    }

    private func featureSource(named fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SloppyFeatureChat")
        let sourceURL = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )?
            .compactMap { $0 as? URL }
            .first(where: { $0.lastPathComponent == fileName })
        return try mainViewAwareSourceContents(at: #require(sourceURL))
    }

    @Test("main view defines section tabs for shell navigation")
    func mainViewDefinesSectionTabsForShellNavigation() throws {
        let source = try source(named: "MainViewModel.swift")

        #expect(source.contains("enum MainAppSection: String, CaseIterable, Hashable"))
        #expect(source.contains("var selectedAppSection: MainAppSection = .chats"))
        #expect(source.contains("func selectAppSection(_ section: MainAppSection)"))
    }

    @Test("main view uses split detail workspace container on phones")
    func mainViewUsesSplitDetailWorkspaceContainerOnPhones() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains("NavigationSplitView"))
        #expect(source.contains("contentArea()"))
        #expect(source.contains("if idiom == .phone,\n               viewModel.isMobileTabsOverviewPresented"))
        #expect(source.contains("MobileWorkspaceTabsOverview("))
    }

    @Test("vision overview is presented above workspace content and uses live tab previews")
    func visionOverviewIsPresentedAboveWorkspaceContent() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains("if viewModel.isVisionTabsOverviewPresented"))
        #expect(source.contains("VisionWorkspaceTabsOverview("))
        #expect(source.contains("previewContent: { tab in"))
        #expect(source.contains("desktopTabPreviewContent(for: tab)"))
    }

    @Test("regular layout uses extracted workspace host and desktop strip")
    func regularLayoutUsesExtractedWorkspaceHostAndDesktopStrip() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains("var activeDesktopTab: WorkspaceTab?"))
        #expect(source.contains("func workspaceContentHost(showsFloatingTabChrome: Bool) -> some View"))
        #expect(source.contains("var workspaceArea: some View"))
        #expect(source.contains("desktopTabContent(for tab: WorkspaceTab)"))
        #expect(!source.contains("private func phoneTabLayout() -> some View"))
    }

    @Test("main view hosts vision floating tab chrome separately from desktop strip")
    func mainViewHostsVisionFloatingTabChromeSeparatelyFromDesktopStrip() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains("#if os(visionOS)"))
        #expect(source.contains("VisionFloatingTabBarView("))
        #expect(source.contains("DesktopWorkspaceTabStrip(viewModel: viewModel)"))
        #expect(source.contains("workspaceContentHost(showsFloatingTabChrome: true)"))
        #expect(source.contains("workspaceContentHost(showsFloatingTabChrome: false)"))
    }

    @Test("vision floating tab chrome is attached as a scene-level ornament")
    func visionFloatingTabChromeUsesSceneLevelOrnament() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains(".ornament("))
        #expect(source.contains("attachmentAnchor: .scene(.top)"))
        #expect(source.contains("contentAlignment: .bottom"))
        #expect(!source.contains("attachmentAnchor: .parent(.top)"))
        #expect(!source.contains(".background(.red)"))
    }

    @Test("sidebar exposes workspace navigation on every platform")
    func sidebarExposesWorkspaceNavigationOnEveryPlatform() throws {
        let iosSource = try source(named: "IOSMainSidebar.swift")
        let visionSource = try source(named: "VisionMainSidebar.swift")
        let macSource = try source(named: "MacMainSidebar.swift")
        let mainViewSource = try source(named: "MainView.swift")
        let source = iosSource + visionSource + macSource

        #expect(source.contains("TabView(selection: $viewModel.selectedAppSection)"))
        #expect(source.contains("Tab(\"Chats\""))
        #expect(source.contains("Tab(\"Agents\""))
        #expect(iosSource.contains("Tab(\"Workspace\""))
        #expect(visionSource.contains("Tab(\"Workspace\""))
        #expect(macSource.contains("title: \"Workspace\""))
        #expect(macSource.contains("action: viewModel.selectWorkspace"))
        #expect(macSource.contains("SidebarAgentsSection("))
        #expect(macSource.contains("onSelect: viewModel.selectSidebarAgent"))
        #expect(mainViewSource.contains("AgentsScreen(apiClient: viewModel.apiClient)"))
    }

    @Test("phone workspace tab renders the canvas surface")
    func phoneWorkspaceTabRendersCanvasSurface() throws {
        let iosSource = try source(named: "IOSMainSidebar.swift")
        let mainView = try source(named: "MainView.swift")

        #expect(iosSource.contains("if idiom == .phone"))
        #expect(iosSource.contains("CanvasWorkspaceSurface(viewModel: canvasWorkspaceViewModel)"))
        #expect(mainView.contains(".task(id: canvasResolutionKey)"))
    }

    @Test("phone new chat action uses the native accessory and toolbar")
    func phoneNewChatActionUsesNativePlacements() throws {
        let iosSource = try source(named: "IOSMainSidebar.swift")

        #expect(iosSource.contains(".tabViewBottomAccessory"))
        #expect(iosSource.contains("if #available(iOS 26.0, *)"))
        #expect(iosSource.contains("ToolbarItemGroup(placement: .topBarTrailing)"))
        #expect(!iosSource.contains(".safeAreaInset(edge: .bottom"))
    }

    @Test("phone tabs use native navigation titles")
    func phoneTabsUseNativeNavigationTitles() throws {
        let iosSource = try source(named: "IOSMainSidebar.swift")
        let workspaceSource = try source(named: "CanvasWorkspaceLibraryView.swift")

        #expect(iosSource.contains(".navigationTitle(viewModel.selectedInstanceTitle)"))
        #expect(workspaceSource.contains(".navigationTitle(viewModel.libraryTitle)"))
        #expect(workspaceSource.contains("Label(\"New Workspace\", systemImage: \"plus\")"))
        #expect(workspaceSource.contains(".labelStyle(.iconOnly)"))
    }

    @Test("project editor only applies desktop minimum dimensions on macOS")
    func projectEditorOnlyAppliesDesktopMinimumDimensionsOnMacOS() throws {
        let source = try source(named: "ProjectEditorSheet.swift")

        #expect(source.contains("#if os(iOS)\n        .presentationDetents([.large])"))
        #expect(source.contains(".presentationDetents([.large])"))
    }

    @Test("workspace mode is absent from the main toolbar")
    func workspaceModeIsAbsentFromMainToolbar() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains("ToolbarItem(placement: .primaryAction)"))
        #expect(!source.contains("mainContentModePicker"))
        #expect(source.contains("viewModel.selectedAppSection == .workspace"))
    }

    @Test("macOS moves model selection from the toolbar into the composer")
    func macOSMovesModelSelectionIntoComposer() throws {
        let mainView = try source(named: "MainView.swift")
        let composer = try featureSource(named: "ChatComposerView.swift")

        #expect(mainView.contains("#if !os(macOS)"))
        #expect(mainView.contains("ChatContextToolbarMenu("))
        #expect(!mainView.contains("ChatAgentToolbarMenu("))
        #expect(!mainView.contains("ChatModelToolbarMenu("))
        #expect(mainView.contains("var activeChatViewModel: ChatScreenViewModel?"))
        #expect(composer.contains("ComposerOptionsMenuView("))
        #expect(composer.contains("chat.composer.model-picker"))
        #expect(composer.contains("TextField(\"Search models\", text: $searchText)"))
    }

    @Test("main view loads sidebar chat data on appear")
    func mainViewLoadsSidebarChatDataOnAppear() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains(".onAppear"))
        #expect(source.contains("await viewModel.chatViewModel.waitForInitialData()"))
        #expect(source.contains("await viewModel.loadAggregatedChatCatalogIfNeeded()"))
        #expect(source.contains("await viewModel.loadProjects()"))
    }

    @Test("macOS sidebar enforces its intended layout width")
    func macOSSidebarEnforcesItsIntendedLayoutWidth() throws {
        let mainViewSource = try source(named: "MainView.swift")
        let sidebarSource = try source(named: "MainSidebarView.swift")

        #expect(sidebarSource.contains("static let expandedWidth: CGFloat = 348"))
        #expect(sidebarSource.contains("static let minimumWidth: CGFloat = 220"))
        #expect(sidebarSource.contains("static let maximumWidth: CGFloat = 800"))
        #expect(mainViewSource.contains(".navigationSplitViewColumnWidth("))
        #expect(mainViewSource.contains("min: viewModel.sidebarMinimumWidth"))
        #expect(mainViewSource.contains("ideal: viewModel.sidebarWidth"))
        #expect(mainViewSource.contains("max: viewModel.sidebarMaximumWidth"))
    }
}
