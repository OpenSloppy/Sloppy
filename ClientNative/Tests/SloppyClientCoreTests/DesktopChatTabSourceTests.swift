import Foundation
import Testing

@Suite("Desktop chat tab source")
struct DesktopChatTabSourceTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try mainViewAwareSourceContents(at: packageRoot.appendingPathComponent(relativePath))
    }

    @Test("chat tabs own local chat screen state")
    func chatTabsOwnLocalChatScreenState() throws {
        let tabs = try source("Sources/SloppyClient/Navigation/Main/MainTabs.swift")
        let mainView = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let mainViewModel = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")
        let chatScreen = try source("Sources/SloppyFeatureChat/Screens/Chat/ChatScreen.swift")

        #expect(tabs.contains("final class WorkspaceTabState"))
        #expect(tabs.contains("var content: AnyView?"))
        #expect(tabs.contains("final class ChatTabState"))
        #expect(tabs.contains("let viewModel: ChatScreenViewModel"))
        #expect(mainViewModel.contains("var tabStates: [WorkspaceTab.ID: WorkspaceTabState] = [:]"))
        #expect(mainViewModel.contains("makeChatTabState(endpoint: SloppyInstanceEndpoint? = nil) -> ChatTabState"))
        #expect(mainViewModel.contains("restoresLastSession: false"))
        #expect(mainView.contains("cachedContent(for: tab)"))
        #expect(mainView.contains("mountedDesktopTabContent(activeTabID: activeDesktopTab.id)"))
        #expect(mainView.contains(".allowsHitTesting(tab.id == activeTabID)"))
        #expect(mainView.contains("ChatScreen("))
        #expect(mainView.contains("viewModel: chatState.viewModel"))
        #expect(mainView.contains(".id(ObjectIdentifier(chatState.viewModel))"))
        #expect(chatScreen.contains("@State private var viewModel: ChatScreenViewModel"))
    }

    @Test("desktop task and recent session actions use tab-local chats instead of the global chat view model")
    func desktopTaskAndRecentSessionActionsUseTabLocalChats() throws {
        let mainViewModel = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(mainViewModel.contains("openTaskChatTab("))
        #expect(mainViewModel.contains("openSessionChatTab("))
        #expect(mainViewModel.contains("private func showInSelectedTab("))
        #expect(mainViewModel.contains("tabStates[selectedTabID] = state"))
        #expect(!mainViewModel.contains("chatViewModel.pickSession(session)"))
        #expect(!mainViewModel.contains("navigateChat("))
    }

    @Test("reactivating a mounted chat tab requests its transcript end")
    func reactivatingMountedChatTabRequestsTranscriptEnd() throws {
        let mainView = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let mainViewModel = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(mainView.contains(".onChange(of: viewModel.selectedTabID)"))
        #expect(mainView.contains("viewModel.requestChatScrollToEnd(for: newValue)"))
        #expect(mainViewModel.contains("requestTranscriptScrollToEnd()"))
    }

    @Test("blank tab-local chats do not restore the previous global session")
    func blankTabLocalChatsDoNotRestoreThePreviousGlobalSession() throws {
        let chatViewModel = try source("Sources/SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")

        #expect(chatViewModel.contains("restoresLastSession: Bool = true"))
        #expect(chatViewModel.contains("restoresLastSession,"))
        #expect(chatViewModel.contains("let lastSessionId = settings.lastSessionId,"))
        #expect(chatViewModel.contains("sessions.contains(where: { $0.id == lastSessionId })"))
    }
}
