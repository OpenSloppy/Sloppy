import Foundation
import Testing

@Suite("Main loading screen source")
struct MainLoadingViewSourceTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try mainViewAwareSourceContents(at: packageRoot.appendingPathComponent(relativePath))
    }

    @Test("main content is gated only by the initial app bootstrap")
    func mainContentIsGatedOnlyByInitialAppBootstrap() throws {
        let mainView = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let mainViewModel = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")
        let chatViewModel = try source("Sources/SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")

        #expect(mainView.contains("if viewModel.hasLoadedInitialContent"))
        #expect(mainView.contains("MainLoadingView()"))
        #expect(mainViewModel.contains("didLoadProjects && chatViewModel.didLoadInitialData"))
        #expect(!mainViewModel.contains("return selectedChatViewModel.didLoadInitialData"))
        #expect(mainViewModel.contains("viewModel.loadInitialData()"))
        #expect(chatViewModel.contains("public private(set) var didLoadInitialData = false"))
    }

    @Test("loading screen shimmers the project logo and respects reduced motion")
    func loadingScreenShimmersProjectLogo() throws {
        let source = try source("Sources/SloppyClient/Root/MainLoadingView.swift")

        #expect(source.contains("Image(\"SloppyProjectLogo\""))
        #expect(source.contains("LinearGradient("))
        #expect(source.contains("repeatForever(autoreverses: false)"))
        #expect(source.contains("accessibilityReduceMotion"))
    }

    @Test("project bootstrap releases cached content before remote refresh")
    func projectBootstrapIsCacheFirst() throws {
        let source = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        let cachedProjects = try #require(source.range(
            of: "projects = reconcileProjectOrder(await cacheStore.loadProjects())"
        ))
        let contentReady = try #require(source.range(of: "didLoadProjects = true"))
        let remoteProjects = try #require(source.range(of: "let list = try await fetchProjectsForCurrentSelection()"))

        #expect(cachedProjects.lowerBound < contentReady.lowerBound)
        #expect(contentReady.lowerBound < remoteProjects.lowerBound)
    }
}
