import Foundation
import Testing

@Suite("Main sidebar refresh")
struct MainSidebarRefreshTests {
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

    @Test("main view model exposes a unified refresh entry point")
    func mainViewModelExposesUnifiedRefreshEntryPoint() throws {
        let source = try source(named: "MainViewModel.swift")

        #expect(source.contains("func refreshContent() async"))
        #expect(source.contains("await loadProjects(force: true)"))
        #expect(source.contains("if chatViewModel.selectedAgent == nil"))
        #expect(source.contains("await chatViewModel.waitForInitialData()"))
        #expect(source.contains("await chatViewModel.refreshCurrentContext()"))
        #expect(source.contains("await loadAggregatedChatCatalogIfNeeded()"))
    }

    @Test("sidebar supports pull to refresh")
    func sidebarSupportsPullToRefresh() throws {
        let source = try source(named: "MacMainSidebar.swift")

        #expect(source.contains(".refreshable"))
        #expect(source.contains("await viewModel.refreshContent()"))
    }

    @Test("sidebar remains full-height behind the transparent title bar")
    func sidebarRemainsFullHeightBehindTransparentTitleBar() throws {
        let source = try source(named: "MacMainSidebar.swift")

        #expect(!source.contains("@Environment(\\.safeAreaInsets)"))
        #expect(!source.contains("toolbarContentClearance"))
        #expect(!source.contains(".padding(.top"))
    }

    @Test("sidebar actions and recents scroll together while the footer stays fixed")
    func sidebarKeepsFooterOutsideScrollingContent() throws {
        let source = try source(named: "MacMainSidebar.swift")
        let primaryActionsIndex = try #require(source.range(of: "MacSidebarPrimaryActions(viewModel: viewModel)")?.lowerBound)
        let scrollViewIndex = try #require(source.range(of: "ScrollView {")?.lowerBound)

        #expect(scrollViewIndex < primaryActionsIndex)
        #expect(source.contains(".frame(maxHeight: .infinity)"))
        #expect(source.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
    }

    @Test("sidebar settings button opens settings")
    func sidebarSettingsButtonOpensSettings() throws {
        let source = try source(named: "MacMainSidebar.swift")

        #expect(source.contains("viewModel.onOpenSettings(.general)"))
    }

    @Test("main view wires cmd+r to the same refresh flow")
    func mainViewWiresCmdRToRefresh() throws {
        let source = try source(named: "MainView.swift")

        #expect(source.contains(".keyboardShortcut(\"r\", modifiers: [.command])"))
        #expect(source.contains("Task { await viewModel.refreshContent() }"))
    }
}
