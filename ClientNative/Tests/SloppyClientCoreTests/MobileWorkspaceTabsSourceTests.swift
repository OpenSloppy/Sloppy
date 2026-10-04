import Foundation
import Testing

@Suite("Mobile workspace tabs source")
struct MobileWorkspaceTabsSourceTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try mainViewAwareSourceContents(at: packageRoot.appendingPathComponent(relativePath))
    }

    @Test("main view presents mobile overview from detail container")
    func mainViewPresentsMobileOverviewFromDetailContainer() throws {
        let mainView = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let overview = try source("Sources/SloppyClient/Navigation/Tabs/MobileWorkspaceTabsOverview.swift")

        #expect(mainView.contains("MobileWorkspaceTabsOverview("))
        #expect(mainView.contains("viewModel.isMobileTabsOverviewPresented"))
        #expect(overview.contains("struct MobileWorkspaceTabsOverview: View"))
        #expect(overview.contains("ForEach(tabs)"))
    }

    @Test("mobile tabs overview uses stable thumbnails and paging motion")
    func mobileTabsOverviewUsesStableThumbnailsAndPagingMotion() throws {
        let mainView = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let overview = try source("Sources/SloppyClient/Navigation/Tabs/MobileWorkspaceTabsOverview.swift")

        #expect(mainView.contains("phoneWorkspaceContentHost(showsFloatingTabChrome:"))
        #expect(mainView.contains("mobileTabPagingTransition(for tab: WorkspaceTab)"))
        #expect(!mainView.contains("matchedGeometryEffect(id: mobileTabHeroID(for: activeDesktopTab)"))
        #expect(!mainView.contains("private func mobileTabHeroID"))
        #expect(mainView.contains("withAnimation(.spring(response: 0.42, dampingFraction: 0.86))"))
        #expect(!overview.contains("@ViewBuilder let previewContent"))
        #expect(!overview.contains("matchedGeometryEffect"))
        #expect(overview.contains("MobileWorkspaceTabThumbnail(tab: tab, snapshotImage: snapshotImage)"))
        #expect(overview.contains("private struct MobileWorkspaceTabThumbnail: View"))
        #expect(overview.contains(".transition(.opacity.combined(with: .scale"))
    }
}
