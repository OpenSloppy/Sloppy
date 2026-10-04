import Foundation
import Testing

@Suite("Main sidebar selection")
struct MainSidebarSelectionTests {
    private var mainViewModelSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")
            return try mainViewAwareSourceContents(at: sourceURL)
        }
    }

    private var mainSidebarSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyClient")
                .appendingPathComponent("Navigation")
                .appendingPathComponent("Main")
                .appendingPathComponent("MainView.swift")
            return try mainViewAwareSourceContents(at: sourceURL)
        }
    }

    @Test("recent sessions derive selection from the active tab-local chat")
    func recentSessionsDeriveSelectionFromTheActiveTabLocalChat() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarURL = packageRoot
            .appendingPathComponent("Sources/SloppyClient/Navigation/Shared/SidebarRecentsList.swift")
        let source = try mainViewAwareSourceContents(at: sidebarURL)

        #expect(source.contains("viewModel.selectedChatStorageID == session.storageID"))
        #expect(!source.contains("viewModel.chatViewModel.selectedSessionId == session.id"))
    }

    @Test("selected sidebar rows keep a visible background")
    func selectedSidebarRowsKeepAVisibleBackground() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rowURL = packageRoot
            .appendingPathComponent("Sources/SloppyClient/Navigation/Shared/SidebarNavigationRow.swift")
        let source = try mainViewAwareSourceContents(at: rowURL)

        #expect(source.contains("var isSelected = false"))
        #expect(source.contains("isSelected ? theme.colors.surfaceRaised : .clear"))
    }

    @Test("chat rows use their full visual width for hover and selection")
    func chatRowsUseTheirFullVisualWidthForHoverAndSelection() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rowURL = packageRoot
            .appendingPathComponent("Sources/SloppyClient/Navigation/Shared/SidebarSessionRow.swift")
        let source = try mainViewAwareSourceContents(at: rowURL)

        #expect(source.contains("#if os(macOS)"))
        #expect(source.contains("Button(action: onOpen)"))
        #expect(source.contains(".frame(minHeight: MainSidebarView.rowMinimumHeight)"))
        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(!source.contains(".frame(maxWidth: .infinity"))
        #expect(!source.contains(".clipShape(Rectangle())"))
    }

    @Test("loading projects does not select a project implicitly")
    func loadingProjectsDoesNotSelectAProjectImplicitly() throws {
        let source = try mainViewModelSource
        let loadProjectsStart = try #require(source.range(of: "func loadProjects(force: Bool = false) async"))
        let selectAppSectionStart = try #require(
            source.range(of: "func selectAppSection", range: loadProjectsStart.upperBound..<source.endIndex)
        )
        let loadProjects = source[loadProjectsStart.lowerBound..<selectAppSectionStart.lowerBound]

        #expect(!loadProjects.contains("selectedSidebarItem = .project"))
        #expect(!loadProjects.contains("firstProject"))
    }

    @Test("main view uses split detail tabs on phones")
    func mainViewUsesSplitDetailTabsOnPhones() throws {
        let source = try mainSidebarSource

        #expect(source.contains("if idiom == .phone,\n               viewModel.isMobileTabsOverviewPresented"))
        #expect(source.contains("workspaceContentHost(showsFloatingTabChrome: false)"))
        #expect(source.contains("MobileWorkspaceTabsOverview("))
    }

    @Test("phone owns its navigation stack without an outer split view")
    func phoneOwnsNavigationStackWithoutOuterSplitView() throws {
        let source = try mainSidebarSource

        #expect(source.contains("#if os(iOS)\n        // `PlatformMainSidebar` owns the phone TabView"))
        #expect(source.contains("sidebarView(isOverlay: false)"))
        #expect(source.contains("NavigationSplitView(columnVisibility: $viewModel.columnVisibility)"))
        #expect(source.contains("viewModel.dismissMobileSidebar()"))

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosSidebarURL = packageRoot
            .appendingPathComponent("Sources/SloppyClient/Navigation/Platforms/iOS/IOSMainSidebar.swift")
        let iosSidebarSource = try mainViewAwareSourceContents(at: iosSidebarURL)
        #expect(iosSidebarSource.contains(".navigationDestination(for: MainSidebarSelection.self)"))
        #expect(iosSidebarSource.contains("NavigationStack(path: $inboxNavigationPath)"))
        #expect(iosSidebarSource.contains("settingsButton"))
        #expect(iosSidebarSource.contains("Button(action: openNewChatComposer)"))
        #expect(iosSidebarSource.contains("inboxNavigationPath.append(MainSidebarSelection.chats)"))
        #expect(iosSidebarSource.contains("viewModel.requestSelectedComposerFocus()"))
        #expect(iosSidebarSource.contains(".buttonStyle(.plain)"))
        #expect(iosSidebarSource.contains("accessoryIcon(\"microphone\")"))
    }

    @Test("split sidebar uses a single width constraint contract")
    func splitSidebarUsesASingleWidthConstraintContract() throws {
        let source = try mainSidebarSource
        let navigationViewStart = try #require(source.range(of: "var navigationView: some View"))
        let contentAreaStart = try #require(
            source.range(
                of: "func contentArea()",
                range: navigationViewStart.upperBound..<source.endIndex
            )
        )
        let navigationView = source[navigationViewStart.lowerBound..<contentAreaStart.lowerBound]

        #expect(navigationView.contains(".navigationSplitViewColumnWidth("))
        #expect(!navigationView.contains(".frame(\n                    minWidth: viewModel.sidebarMinimumWidth"))
    }

    @Test("overlay sidebar uses dedicated close button styling")
    func overlaySidebarUsesDedicatedCloseButtonStyling() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarURL = packageRoot
            .appendingPathComponent("Sources/SloppyClient/Navigation/Platforms/iOS/IOSMainSidebar.swift")
        let source = try mainViewAwareSourceContents(at: sidebarURL)

        #expect(source.contains("private var settingsButton: some View"))
    }
}
