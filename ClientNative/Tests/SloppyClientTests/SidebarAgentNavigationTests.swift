import Foundation
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat
import Testing
@testable import SloppyClient

@Suite("Sidebar agent navigation", .serialized)
@MainActor
struct SidebarAgentNavigationTests {
    private func makeViewModel(api: SloppyAPIClient? = nil) -> MainViewModel {
        let endpoint = api?.endpoint ?? SloppyInstanceEndpoint.direct(baseURL: URL(string: "http://localhost:9")!)
        return MainViewModel(
            endpoint: endpoint,
            settings: ClientSettings(),
            connectionMonitor: ConnectionMonitor(baseURL: endpoint.coordinatorBaseURL),
            cacheStore: ClientCacheStore(path: ":memory:"),
            apiClient: api,
            responseNotificationScheduler: SidebarNavigationNotifications(),
            onOpenSettings: { _ in },
            onOpenWorkspace: {}
        )
    }

    @Test func infoUpdatesDetailWithoutChangingTheChatTab() {
        let viewModel = makeViewModel()
        let tab = WorkspaceTab(
            key: .chatSession("existing-chat"),
            kind: .chat,
            title: "Existing chat",
            payload: .chatSession(sessionID: "existing-chat", title: "Existing chat")
        )
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let chatAgentID = viewModel.chatViewModel.selectedAgent?.id

        viewModel.showSidebarAgentInfo(APIAgentRecord(id: "first", displayName: "First"))
        #expect(viewModel.selectedSidebarAgent?.id == "first")
        #expect(viewModel.selectedAppSection == .agents)
        #expect(viewModel.selectedSidebarItem == .agents)

        viewModel.showSidebarAgentInfo(APIAgentRecord(id: "second", displayName: "Second"))
        #expect(viewModel.selectedSidebarAgent?.id == "second")
        #expect(viewModel.selectedTabID == tab.id)
        #expect(viewModel.chatViewModel.selectedAgent?.id == chatAgentID)
        #expect(viewModel.tabs.count == 1)
    }

    @Test func openingTheAgentDirectoryClearsIndividualSelection() {
        let viewModel = makeViewModel()
        viewModel.showSidebarAgentInfo(APIAgentRecord(id: "first", displayName: "First"))

        viewModel.selectAgents()

        #expect(viewModel.selectedSidebarAgent?.id == nil)
        #expect(viewModel.selectedAppSection == .agents)
        #expect(viewModel.selectedSidebarItem == .agents)
    }

    @Test func defaultActionOpensPersonalLongChatAndReusesTheOpenTab() async throws {
        let fixture = SidebarLongChatFixture()
        let viewModel = makeViewModel(api: fixture.api)
        defer { closeChats(viewModel) }
        let agent = APIAgentRecord(id: "first", displayName: "First")

        viewModel.selectSidebarAgent(agent)
        viewModel.selectSidebarAgent(agent)
        try await waitUntil { viewModel.openingSidebarAgentID == nil }

        let tab = try #require(viewModel.tabs.first)
        #expect(tab.key == .chatSession("long-first"))
        #expect(viewModel.selectedAppSection == .chats)
        #expect(viewModel.sidebarSelectedAgentID == agent.id)
        #expect(fixture.posts.count == 1)
        let request = try JSONDecoder().decode(LongChatOpenRequest.self, from: #require(fixture.posts.first?.httpBody))
        #expect(request.projectId == nil)
        let chat = try #require(viewModel.tabStates[tab.id]?.chatState?.viewModel)
        chat.composerDraft.text = "Keep this draft"
        viewModel.tabs[0] = WorkspaceTab(
            id: tab.id, key: .chatSession(InstanceScopedID(instanceID: "local", localID: "long-first").description),
            kind: .chat, title: tab.title, payload: tab.payload
        )

        viewModel.selectSidebarAgent(agent)
        #expect(fixture.posts.count == 1)
        viewModel.showSidebarAgentInfo(agent)
        viewModel.selectSidebarAgent(agent)
        try await waitUntil { viewModel.openingSidebarAgentID == nil }

        #expect(fixture.posts.count == 2)
        #expect(fixture.posts.allSatisfy { $0.url?.path.hasSuffix("/long-chat") == true })
        #expect(viewModel.tabs.count == 1)
        #expect(viewModel.selectedTabID == tab.id)
        #expect(viewModel.tabStates[tab.id]?.chatState?.viewModel === chat)
        #expect(chat.composerDraft.text == "Keep this draft")
    }

    @Test func laterAgentSelectionWinsOverAnEarlierResponse() async throws {
        let fixture = SidebarLongChatFixture(delayedAgentID: "first")
        let viewModel = makeViewModel(api: fixture.api)
        defer { closeChats(viewModel) }

        viewModel.selectSidebarAgent(APIAgentRecord(id: "first", displayName: "First"))
        try await waitUntil { fixture.posts.count == 1 }
        viewModel.selectSidebarAgent(APIAgentRecord(id: "second", displayName: "Second"))
        try await waitUntil { viewModel.openingSidebarAgentID == nil }
        try await Task.sleep(for: .milliseconds(250))

        #expect(viewModel.tabs.first?.key == .chatSession("long-second"))
        #expect(viewModel.sidebarSelectedAgentID == "second")
        #expect(viewModel.tabs.count == 1)
    }

    @Test(arguments: [false, true])
    func navigationCancelsPendingChatOpening(opensInfo: Bool) async throws {
        let fixture = SidebarLongChatFixture(delayedAgentID: "first")
        let viewModel = makeViewModel(api: fixture.api)
        defer { closeChats(viewModel) }
        let agent = APIAgentRecord(id: "first", displayName: "First")

        viewModel.selectSidebarAgent(agent)
        try await waitUntil { fixture.posts.count == 1 }
        if opensInfo { viewModel.showSidebarAgentInfo(agent) } else { viewModel.selectUsage() }
        try await Task.sleep(for: .milliseconds(250))

        #expect(viewModel.selectedAppSection == (opensInfo ? .agents : .usage))
        #expect(viewModel.openingSidebarAgentID == nil)
        #expect(viewModel.sidebarAgentChatError == nil)
        #expect(viewModel.tabs.isEmpty)
    }

    @Test func failureKeepsTheExistingChatAndReportsAnError() async throws {
        let fixture = SidebarLongChatFixture(fails: true)
        let viewModel = makeViewModel(api: fixture.api)
        let tab = WorkspaceTab(key: .chatSession("existing"), kind: .chat, title: "Existing",
                               payload: .chatSession(sessionID: "existing", title: "Existing"))
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id

        viewModel.selectSidebarAgent(APIAgentRecord(id: "first", displayName: "First"))
        try await waitUntil { viewModel.openingSidebarAgentID == nil }

        #expect(viewModel.selectedTabID == tab.id)
        #expect(viewModel.tabs.first?.key == .chatSession("existing"))
        #expect(viewModel.sidebarAgentChatError != nil)
        #expect(fixture.posts.count == 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    private func closeChats(_ viewModel: MainViewModel) {
        viewModel.chatViewModel.closeSession()
        for state in viewModel.tabStates.values { state.chatState?.viewModel.closeSession() }
    }
}

@MainActor
private final class SidebarNavigationNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
