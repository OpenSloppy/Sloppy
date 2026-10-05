import Foundation
import SloppyClientCore
import SloppyFeatureChat
import Testing
@testable import SloppyClient

@Suite("Attention navigation")
@MainActor
struct AttentionNavigationTests {
    @Test func attentionKeepsExistingChatAndCanReturnToIt() throws {
        let endpoint = SloppyInstanceEndpoint.direct(baseURL: try #require(URL(string: "http://localhost:9")))
        let model = MainViewModel(
            endpoint: endpoint, settings: ClientSettings(),
            connectionMonitor: ConnectionMonitor(baseURL: endpoint.coordinatorBaseURL),
            cacheStore: ClientCacheStore(path: ":memory:"),
            responseNotificationScheduler: AttentionNavigationNotifications(),
            onOpenSettings: { _ in }, onOpenWorkspace: {}
        )
        defer {
            model.chatViewModel.closeSession()
            for state in model.tabStates.values { state.chatState?.viewModel.closeSession() }
        }
        model.createBlankChatTab()
        let tabID = try #require(model.selectedTabID)
        let chat = try #require(model.tabStates[tabID]?.chatState?.viewModel)
        chat.composerDraft.text = "Keep my draft"

        model.selectAttention()

        #expect(model.selectedAppSection == .attention)
        #expect(model.selectedSidebarItem == .attention)
        #expect(model.selectedTabID == tabID)
        #expect(model.tabStates[tabID]?.chatState?.viewModel === chat)
        model.selectAppSection(.chats)
        model.selectTab(tabID)
        #expect(model.selectedAppSection == .chats)
        #expect(chat.composerDraft.text == "Keep my draft")
    }
}

@MainActor
private final class AttentionNavigationNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
