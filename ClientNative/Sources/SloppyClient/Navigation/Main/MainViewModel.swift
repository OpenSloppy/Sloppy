//
//  MainViewModel.swift
//  SloppyClient
//
//  Created by Vladislav Prusakov on 05.07.2026.
//

import Observation
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
import SloppyRemoteProtocol
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat
import SloppyFeatureProjects

enum MainAppSection: String, CaseIterable, Hashable {
    case usage
    case pullRequests
    case scheduled
    case attention
    case artifacts
    case sites
    case projects
    case agents
    case chats
    case workspace
    case settings
}

@Observable
@MainActor
final class MainViewModel {
    let baseURL: URL
    let endpoint: SloppyInstanceEndpoint
    let settings: ClientSettings
    let connectionMonitor: ConnectionMonitor
    let onOpenSettings: @MainActor (ClientSettingsDestination) -> Void
    let onOpenWorkspace: @MainActor () -> Void
    let cacheStore: ClientCacheStore
    private let projectCacheStore: ClientCacheStore
    private let inboxSelection: SloppyInstanceSelection
    private var didLoadSidebarCatalog = false

    var projects: [APIProjectRecord] = []
    var isLoadingProjects = false
    var isProjectEditorPresented = false
    var isNewChatInstancePickerPresented = false
    var projectBeingEdited: APIProjectRecord?
    var didLoadProjects = false
    var collapsedProjectIds: Set<String> = []
    var expandedTaskLists: Set<String> = []
    var visibleProjectCount = 6
    var selectedAppSection: MainAppSection = .chats
    var selectedSidebarItem: MainSidebarSelection? = nil
    var selectedSidebarAgent: APIAgentRecord?
    var openingSidebarAgentID: String?
    @ObservationIgnored private var selectedCodeReviewSessions: [CodeReviewReference: ChatSessionSummary] = [:]
    var sidebarAgentChatError: String?
    @ObservationIgnored private var sidebarAgentChatTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarAgentChatRequestID: UUID?
    private let responseNotificationScheduler: any AgentResponseNotificationScheduling
    var sessionDeepLinkNavigationSerial = 0
    var isSidebarCollapsed = false
    var columnVisibility: NavigationSplitViewVisibility
    var isMobileTabsOverviewPresented = false
    var isVisionTabsOverviewPresented = false
    var tabs: [WorkspaceTab] = []
    var selectedTabID: WorkspaceTab.ID?
    var desktopSplitState: DesktopTabSplitState?
    var tabStates: [WorkspaceTab.ID: WorkspaceTabState] = [:]
    var projectModeStates: [String: ProjectKanbanTabState] = [:]
    var terminalSessions: [WorkspaceTab.ID: WorkspaceTerminalSession] = [:]
    var terminalHosts: [WorkspaceTab.ID: WorkspaceTerminalHosting] = [:]
    var tabEndpoints: [WorkspaceTab.ID: SloppyInstanceEndpoint] = [:]
    var chatViewModel: ChatScreenViewModel
    private var loadedSidebarSessions: [ChatSessionSummary]?
    private var isLoadingAggregatedChatCatalog = false
    var workspacePanelViewModel: WorkspacePanelViewModel
    @ObservationIgnored let workspaceDockStore = WorkspaceDockStore()
    private var sidebarSessionActivities: [String: SidebarSessionActivityRecord] = [:]
    var browserPresentationRequest: UUID?
    var browserSessions: [WorkspaceTab.ID: WorkspaceBrowserSession] = [:]
    var chatNavigationSerial = 0
    var projectActionStatus: String?
    private var pendingNewChatStarterPrompt: String?
    var currentAuthUser: AuthUserProfile?
    let apiClient: SloppyAPIClient
    let attentionInbox: AttentionInbox

    var sidebarWidth: CGFloat {
        isSidebarCollapsed ? MainSidebarView.collapsedWidth : MainSidebarView.expandedWidth
    }

    var sidebarMinimumWidth: CGFloat {
        isSidebarCollapsed ? MainSidebarView.collapsedWidth : MainSidebarView.minimumWidth
    }

    var sidebarMaximumWidth: CGFloat {
        isSidebarCollapsed ? MainSidebarView.collapsedWidth : MainSidebarView.maximumWidth
    }

    var hasLoadedInitialContent: Bool {
        inboxSelection == settings.instanceSelection
            && didLoadProjects && didLoadSidebarCatalog
    }

    var workspaceContext: WorkspacePanelContext? {
        guard let context = activeWorkspaceFilesContext() else {
            return nil
        }
        return WorkspacePanelContext(
            projectId: context.projectId,
            projectName: context.projectName
        )
    }

    var activeCanvasProjectID: String? {
        activeWorkspaceFilesContext()?.projectId
    }

    var activeCanvasWorkspaceID: String? {
        guard let selectedTabID else {
            return nil
        }
        return tabStates[selectedTabID]?.chatState?.viewModel.activeWorkspaceIdForCanvas
    }

    var selectedChatSessionID: String? {
        guard let selectedTabID,
              tabs.first(where: { $0.id == selectedTabID })?.kind == .chat else {
            return nil
        }
        return tabStates[selectedTabID]?.chatState?.viewModel.selectedSessionId
    }

    var selectedChatStorageID: String? {
        guard let selectedTabID,
              let sessionID = tabStates[selectedTabID]?.chatState?.viewModel.selectedSessionId else {
            return nil
        }
        let tabEndpoint = tabEndpoints[selectedTabID] ?? endpoint
        return chatViewModel.sessionCatalog.first {
            $0.id == sessionID
                && ($0.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint) == tabEndpoint
        }?.storageID ?? sessionID
    }

    var sidebarSelectedAgentID: String? {
        if let openingSidebarAgentID { return openingSidebarAgentID }
        if selectedAppSection == .agents { return selectedSidebarAgent?.id }
        guard selectedAppSection == .chats,
              let tabID = selectedTabID,
              let tab = tabs.first(where: { $0.id == tabID }),
              case .chatSession(let sessionID, _) = tab.payload,
              (tabEndpoints[tabID] ?? endpoint) == endpoint,
              let session = (loadedSidebarSessions ?? chatViewModel.sessionCatalog).first(where: {
                  $0.id == sessionID && ($0.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint) == endpoint
              }),
              session.kind == "long_chat", session.projectId == nil else { return nil }
        return session.agentId
    }

    var projectEditorEndpoint: SloppyInstanceEndpoint {
        projectBeingEdited?.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
    }

    var sidebarSessionCatalog: [ChatSessionSummary] {
        let visibleSessions = (loadedSidebarSessions ?? chatViewModel.sessionCatalog).filter {
            !settings.isSessionArchived($0.storageID)
        }
        guard settings.instanceSelection == .all,
              settings.discoveredInstances.count > 1,
              let activeInstanceID = settings.discoveredInstances.first(where: {
                  $0.endpoint == endpoint
              })?.id else {
            return visibleSessions
        }
        return visibleSessions.map { session in
            guard session.sourceInstanceID == nil else { return session }
            var tagged = session
            tagged.sourceInstanceID = activeInstanceID
            return tagged
        }
    }

    var sidebarDefaultSourceInstanceID: String? {
        switch settings.instanceSelection {
        case .all:
            if settings.discoveredInstances.count == 1 {
                return settings.discoveredInstances[0].id
            }
            return settings.discoveredInstances.first(where: { $0.endpoint == endpoint })?.id
        case .instance(let instanceID):
            return instanceID
        }
    }

    func projectName(for session: ChatSessionSummary) -> String? {
        session.project(
            in: projects,
            defaultSourceInstanceID: sidebarDefaultSourceInstanceID
        )?.name
    }

    func synchronizeSidebarSessionCatalog() {
        loadedSidebarSessions = chatViewModel.sessionCatalog
    }

    func sidebarSessionActivity(for session: ChatSessionSummary) -> SidebarSessionActivity? {
        if let liveActivity = liveSidebarSessionActivity(for: session),
           liveActivity == .working || liveActivity == .waitingForInput {
            return liveActivity
        }
        return sidebarSessionActivities[session.storageID]?
            .visibleActivity(readEventID: settings.viewedSessionResultEvents[session.storageID])
    }

    func liveSidebarSessionActivity(for session: ChatSessionSummary) -> SidebarSessionActivity? {
        guard let viewModel = liveChatViewModel(for: session) else { return nil }
        return SidebarSessionActivity.resolve(
            isSending: viewModel.isSending,
            isAwaitingAgentResponse: viewModel.isAwaitingAgentResponse,
            hasPendingInputRequest: viewModel.activeInputRequest != nil,
            runStage: viewModel.activeRunStatus?.stage
        )
    }

    func sidebarSessionAvatarAgents(for session: ChatSessionSummary) -> [SidebarSessionAvatarAgent] {
        let live = liveChatViewModel(for: session)
        let sessionEndpoint = session.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        let catalog = live?.agents ?? (sessionEndpoint == endpoint ? chatViewModel.agents : [])
        func paletteID(for agentID: String) -> String? {
            catalog.first { $0.id == agentID }?.pet?.visual?.paletteId
        }
        let primary = SidebarSessionAvatarAgent(
            id: session.storageID, agentID: session.agentId, paletteID: paletteID(for: session.agentId)
        )
        let children = (live?.parallelAgents.agents ?? []).prefix(2).map { child in
            SidebarSessionAvatarAgent(
                id: child.id, agentID: child.summary.agentId, paletteID: paletteID(for: child.summary.agentId),
                emotion: child.isWorking ? .working : .idle
            )
        }
        return [primary] + children
    }

    func recordSidebarSessionActivity(
        _ activity: SidebarSessionActivity?,
        for session: ChatSessionSummary,
        eventID: String? = nil
    ) {
        let record = activity.map { SidebarSessionActivityRecord(activity: $0, eventID: eventID) }
        guard sidebarSessionActivities[session.storageID] != record else { return }
        if let record {
            sidebarSessionActivities[session.storageID] = record
        } else {
            sidebarSessionActivities.removeValue(forKey: session.storageID)
        }
        if selectedChatStorageID == session.storageID || selectedSessionTabKey == .chatSession(session.storageID) {
            markSidebarSessionResultViewed(session)
        }
    }

    private var selectedSessionTabKey: WorkspaceTabKey? {
        tabs.first(where: { $0.id == selectedTabID })?.key
    }

    private func markSidebarSessionResultViewed(_ session: ChatSessionSummary) {
        guard let record = sidebarSessionActivities[session.storageID],
              record.activity == .completed || record.activity == .failed,
              let eventID = record.eventID,
              settings.viewedSessionResultEvents[session.storageID] != eventID else { return }
        settings.viewedSessionResultEvents[session.storageID] = eventID
    }

    func monitorSidebarSessionActivity(for session: ChatSessionSummary) async {
        let client = apiClient(for: session)
        while !Task.isCancelled {
            guard let detail = try? await client.fetchAgentSession(
                agentId: session.agentId,
                sessionId: session.id,
                eventLimit: 1
            ) else {
                return
            }
            let latestStatusEvent = (detail.stateEvents ?? detail.events).last { $0.runStatus != nil }
            let fetched = SidebarSessionActivity.resolve(
                hasPendingInputRequest: detail.pendingInputRequest != nil,
                runStage: detail.latestRunStatus?.stage
            )
            let live = liveSidebarSessionActivity(for: session)
            let resolved = live == .working || live == .waitingForInput ? live : fetched
            recordSidebarSessionActivity(resolved, for: session, eventID: latestStatusEvent?.id)
            guard resolved == .working else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func liveChatViewModel(for session: ChatSessionSummary) -> ChatScreenViewModel? {
        let sessionEndpoint = session.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        for (tabID, state) in tabStates {
            let candidate = state.chatState?.viewModel ?? state.projectKanbanState?.chatViewModel
            guard let candidate,
                  candidate.selectedSessionId == session.id,
                  (tabEndpoints[tabID] ?? endpoint) == sessionEndpoint else {
                continue
            }
            return candidate
        }
        if sessionEndpoint == endpoint, chatViewModel.selectedSessionId == session.id {
            return chatViewModel
        }
        return nil
    }

    var chatSidebarMode: ChatSidebarListMode {
        get { settings.chatSidebarMode }
        set { settings.chatSidebarMode = newValue }
    }

    init(
        endpoint: SloppyInstanceEndpoint,
        settings: ClientSettings,
        connectionMonitor: ConnectionMonitor,
        cacheStore: ClientCacheStore? = nil,
        apiClient: SloppyAPIClient? = nil,
        responseNotificationScheduler: (any AgentResponseNotificationScheduling)? = nil,
        onOpenSettings: @Sendable @escaping @MainActor (ClientSettingsDestination) -> Void,
        onOpenWorkspace: @escaping @MainActor () -> Void
    ) {
        let apiClient = apiClient ?? SloppyAPIClient(endpoint: endpoint)
        let projectCacheStore = cacheStore ?? ClientCacheStore(
            namespace: endpoint.cacheNamespace + ":inbox-projects:" + settings.instanceDirectoryKey
        )
        let cacheStore = cacheStore ?? ClientCacheStore(namespace: endpoint.cacheNamespace)
        let notificationScheduler = responseNotificationScheduler ?? LocalAgentResponseNotificationScheduler.shared
        self.endpoint = endpoint
        self.baseURL = endpoint.coordinatorBaseURL
        self.settings = settings
        self.connectionMonitor = connectionMonitor
        self.cacheStore = cacheStore
        self.projectCacheStore = projectCacheStore
        self.inboxSelection = settings.instanceSelection
        self.responseNotificationScheduler = notificationScheduler
        self.onOpenSettings = onOpenSettings
        self.onOpenWorkspace = onOpenWorkspace
        self.chatViewModel = ChatScreenViewModel(
            apiClient: apiClient,
            cacheStore: cacheStore,
            settings: settings,
            connectionMonitor: connectionMonitor,
            loadsGlobalSessionCatalog: true,
            responseNotificationScheduler: notificationScheduler,
            onOpenSettings: onOpenSettings
        )
        self.workspacePanelViewModel = WorkspacePanelViewModel(apiClient: apiClient)
        self.apiClient = apiClient
        self.attentionInbox = AttentionInbox(apiClient: apiClient)
        self.columnVisibility = {
            #if os(macOS)
            .automatic
            #else
            .detailOnly
            #endif
        }()
    }

    var workspaceDockState: WorkspaceDockState {
        let source = selectedTabID.flatMap { tabEndpoints[$0] } ?? endpoint
        return workspaceDockStore.state(
            server: source.cacheNamespace,
            projectID: selectedTabID.flatMap { projectID(for: $0) },
            fallbackID: selectedChatStorageID ?? selectedTabID.map { String(describing: $0) } ?? "main",
            context: workspaceContext
        )
    }

    @discardableResult
    func openWorkspaceDockTab(_ kind: WorkspaceSidePanelItem, browser: WorkspaceWebViewModel? = nil) -> WorkspaceDockTab {
        let dock = workspaceDockState
        let tab = dock.open(kind, browser: browser)
        let source = selectedTabID.flatMap { tabEndpoints[$0] } ?? endpoint
        switch kind {
        case .browser: break
        case .sideChat:
            if tab.chat == nil {
                tab.chat = makeChatTabState(endpoint: source).viewModel
                if let context = dock.context {
                    tab.chat?.applyNavigationRequest(.init(id: 1,
                        context: .project(projectId: context.projectId, projectName: context.projectName, agentId: nil)))
                }
            }
        case .terminal:
            if tab.terminal == nil {
                #if os(macOS)
                let fallbackDirectory = FileManager.default.homeDirectoryForCurrentUser
                #else
                let fallbackDirectory = URL.applicationDirectory
                #endif
                let directory = selectedTabID.map { terminalWorkingDirectory(for: $0) }
                    ?? fallbackDirectory
                let remote: WorkspaceTerminalSession.RemoteConfiguration?
                if case .relay(let coordinatorBaseURL, let targetNodeID) = source {
                    remote = .init(apiClient: SloppyAPIClient(endpoint: source), coordinatorBaseURL: coordinatorBaseURL,
                                   targetNodeID: targetNodeID, managedDeviceID: nil, projectID: dock.context?.projectId)
                } else if case .managed(let relayURL, let targetDeviceID) = source {
                    remote = .init(apiClient: SloppyAPIClient(endpoint: source), coordinatorBaseURL: relayURL,
                                   targetNodeID: "", managedDeviceID: targetDeviceID, projectID: dock.context?.projectId)
                } else { remote = nil }
                tab.terminal = WorkspaceTerminalSession(id: tab.id, workingDirectory: directory, remoteConfiguration: remote)
                tab.terminal?.startIfNeeded()
            }
        case .review, .files:
            if tab.panel == nil { tab.panel = WorkspacePanelViewModel(apiClient: SloppyAPIClient(endpoint: source)) }
            tab.panel?.switchMode(kind == .files ? .files : .environment)
        }
        return tab
    }

    func connectWorkspaceBrowserForSelectedChat() {
#if os(macOS)
        let closedTabs = browserSessions.keys.filter { tabStates[$0] == nil }
        for id in closedTabs { browserSessions.removeValue(forKey: id)?.stop() }
        guard let tabID = selectedTabID,
              let chat = tabStates[tabID]?.chatState?.viewModel,
              let sessionID = chat.selectedSessionId,
              let agentID = chat.selectedAgent?.id else { return }
        if let existing = browserSessions[tabID], existing.binding.sessionId == sessionID {
            workspacePanelViewModel.webViewModel = existing.viewModel
            existing.start()
            return
        }
        browserSessions.removeValue(forKey: tabID)?.stop()
        let browserDock = workspaceDockState
        let browser = WorkspaceBrowserSession(
            apiClient: SloppyAPIClient(endpoint: tabEndpoints[tabID] ?? endpoint),
            agentID: agentID,
            sessionID: sessionID
        ) { [weak self] in
            guard let self, let browser = self.browserSessions[tabID], browser.binding.sessionId == sessionID else { return }
            guard self.tabStates[tabID]?.chatState?.viewModel.selectedSessionId == sessionID else {
                browserDock.open(.browser, browser: browser.viewModel)
                return
            }
            self.selectTab(tabID)
            self.workspacePanelViewModel.webViewModel = browser.viewModel
            self.browserPresentationRequest = UUID()
        }
        browserSessions[tabID] = browser
        workspacePanelViewModel.webViewModel = browser.viewModel
        browser.start()
#endif
    }

    func stopWorkspaceBrowsers() {
        for browser in browserSessions.values { browser.stop() }
        browserSessions.removeAll()
    }

    var selectedInstanceTitle: String {
        switch settings.instanceSelection {
        case .all:
            return "All"
        case .instance(let id):
            return settings.discoveredInstances.first(where: { $0.id == id })?.displayName ?? id
        }
    }

    var selectedInstance: SloppyInstance? {
        settings.selectedInstance
    }

    func instanceTitle(for sourceInstanceID: String?) -> String? {
        guard settings.instanceSelection == .all,
              let sourceInstanceID else { return nil }
        return settings.discoveredInstances.first { $0.id == sourceInstanceID }?.displayName
            ?? sourceInstanceID
    }

    func selectInstance(_ selection: SloppyInstanceSelection) {
        if let instance = settings.discoveredInstances.first(where: { $0.id == selection.instanceID }),
           settings.requiresConsoleVerification(instance) {
            onOpenWorkspace()
            return
        }
        guard selection != settings.instanceSelection else { return }
        didLoadSidebarCatalog = false
        settings.instanceSelection = selection
    }

    func openMobileSidebar() {
        isSidebarCollapsed = false
        columnVisibility = .all
    }

    func dismissMobileSidebar() {
//        #if os(iOS)
//        columnVisibility = .detailOnly
//        #endif
    }

    func selectNewChat() {
        selectAppSection(.chats)
        updateSelectedSidebarItem(.chats)
        dismissMobileSidebar()
        if settings.instanceSelection == .all,
           settings.discoveredInstances.count > 1 {
            isNewChatInstancePickerPresented = true
        } else {
            showBlankChatInSelectedTab(endpoint: endpoint)
            applyPendingNewChatStarterPrompt()
        }
    }

    func selectNewChat(on instance: SloppyInstance) {
        isNewChatInstancePickerPresented = false
        guard !settings.requiresConsoleVerification(instance) else {
            onOpenWorkspace()
            return
        }
        showBlankChatInSelectedTab(endpoint: instance.endpoint)
        applyPendingNewChatStarterPrompt()
        requestSelectedComposerFocus()
    }

    func selectChatSession(_ session: ChatSessionSummary) {
        selectAppSection(.chats)
        updateSelectedSidebarItem(.chats)
        dismissMobileSidebar()
        openSessionChatTab(session)
    }

    func renameChatSession(_ session: ChatSessionSummary, title: String) async throws {
        let sourceEndpoint: SloppyInstanceEndpoint
        if let instanceID = session.sourceInstanceID {
            guard let resolved = endpoint(for: instanceID) else { throw APIError.invalidResponse }
            sourceEndpoint = resolved
        } else {
            sourceEndpoint = endpoint
        }
        var summary = try await SloppyAPIClient(endpoint: sourceEndpoint).renameAgentSession(
            agentId: session.agentId, sessionId: session.id, title: title
        )
        summary.sourceInstanceID = session.sourceInstanceID
        chatViewModel.mergeSessionSummary(summary)
        for tab in tabs {
            if let chat = tabStates[tab.id]?.chatState?.viewModel,
               chat.sessionEndpoint == sourceEndpoint,
               chat.selectedAgent?.id == session.agentId,
               chat.selectedSessionId == session.id {
                var localSummary = summary
                localSummary.sourceInstanceID = nil
                chat.mergeSessionSummary(localSummary)
                synchronizeChatTab(tab.id)
            }
        }
        synchronizeSidebarSessionCatalog()
    }

    func deleteChatSession(_ session: ChatSessionSummary) {
        guard let instanceID = session.sourceInstanceID,
              let sourceEndpoint = endpoint(for: instanceID),
              sourceEndpoint != endpoint else {
            chatViewModel.deleteSession(session)
            return
        }
        Task {
            do {
                try await SloppyAPIClient(endpoint: sourceEndpoint).deleteAgentSession(
                    agentId: session.agentId,
                    sessionId: session.id
                )
                chatViewModel.removeSessionFromCatalog(session)
            } catch {
                projectActionStatus = "Could not delete remote chat: \(error.localizedDescription)"
            }
        }
    }

    func togglePinChatSession(_ session: ChatSessionSummary) {
        let nextPinned = !settings.isSessionPinned(session.storageID)
        settings.setSessionPinned(session.storageID, isPinned: nextPinned)
    }

    func copyDebugSessionFileLink(_ session: ChatSessionSummary) {
        chatViewModel.copyDebugSessionFileLink(session)
    }

    func hasVisibleChats(in project: APIProjectRecord) -> Bool {
        chatViewModel.sessionCatalog.contains {
            $0.projectId == project.id
                && $0.sourceInstanceID == project.sourceInstanceID
                && !settings.isSessionArchived($0.storageID)
        }
    }

    func hasArchivedChats(in project: APIProjectRecord) -> Bool {
        chatViewModel.sessionCatalog.contains {
            $0.projectId == project.id
                && $0.sourceInstanceID == project.sourceInstanceID
                && settings.isSessionArchived($0.storageID)
        }
    }

    func toggleProjectChatsArchived(_ project: APIProjectRecord) {
        let projectSessions = chatViewModel.sessionCatalog.filter {
            $0.projectId == project.id && $0.sourceInstanceID == project.sourceInstanceID
        }
        guard !projectSessions.isEmpty else {
            projectActionStatus = "No chats to archive in \(project.name)"
            return
        }

        let shouldArchive = projectSessions.contains { !settings.isSessionArchived($0.storageID) }
        for session in projectSessions {
            let source = session.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
            let client = SloppyAPIClient(endpoint: source)
            Task {
                do {
                    _ = try await client.archiveLaunch(agentID: session.agentId, sessionID: session.id, isArchived: shouldArchive)
                    settings.setSessionArchived(session.storageID, isArchived: shouldArchive)
                } catch let error as APIError where error.statusCode == 404 {
                    // Older Core versions have no managed launch state to release.
                    settings.setSessionArchived(session.storageID, isArchived: shouldArchive)
                } catch { projectActionStatus = "Could not archive chat: \(error.localizedDescription)" }
            }
        }
        projectActionStatus = shouldArchive
            ? "Archived chats in \(project.name)"
            : "Restored chats in \(project.name)"
    }

    func openSessionChatTab(_ session: ChatSessionSummary) {
        openSessionChatTab(session, endpointOverride: nil)
    }

    func openSessionChatTab(_ session: ChatSessionSummary, endpointOverride: SloppyInstanceEndpoint?) {
        selectAppSection(.chats)
        updateSelectedSidebarItem(.chats)
        dismissMobileSidebar()

        let sourceEndpoint = endpointOverride ?? session.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        let chatState = makeChatTabState(endpoint: sourceEndpoint)
        chatState.viewModel.openSessionFromSummary(session)
        let tab = WorkspaceTab(
            key: .chatSession(session.storageID),
            kind: .chat,
            title: session.displayTitle,
            payload: .chatSession(sessionID: session.id, title: session.displayTitle)
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .chat(chatState)),
            endpoint: sourceEndpoint
        )
        markSidebarSessionResultViewed(session)
    }

    func selectProject(_ project: APIProjectRecord) {
        openProjectKanbanTab(project: project)
    }

    func openProjectKanbanTab(project: APIProjectRecord) {
        selectAppSection(.projects)
        updateSelectedSidebarItem(.project(scopedProjectID(project)))
        dismissMobileSidebar()
        let key = WorkspaceTabKey.projectKanban(scopedProjectID(project))

        let kanbanState = projectModeState(for: project)
        activateProjectModeSection(kanbanState.selectedSection, project: project, state: kanbanState)
        let tab = WorkspaceTab(
            key: key,
            kind: .projectKanban,
            title: project.name,
            payload: .projectKanban(
                ProjectKanbanTabContext(
                    projectId: project.id,
                    projectName: project.name,
                    projectRootPath: project.projectRootPath
                )
            )
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .projectKanban(kanbanState)),
            endpoint: project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        )
    }

    func presentProjectCreator() {
        projectBeingEdited = nil
        isProjectEditorPresented = true
    }

    func presentProjectEditor(_ project: APIProjectRecord) {
        projectBeingEdited = project
        isProjectEditorPresented = true
    }

    func toggleProjectPinned(_ project: APIProjectRecord) {
        Task {
            do {
                let client = apiClient(for: project)
                var updated = try await client.updateProject(
                    id: project.id,
                    request: APIProjectUpdateRequest(isFavorite: !project.isFavorite)
                )
                updated.sourceInstanceID = project.sourceInstanceID
                replaceProject(updated)
                prioritizeFavoriteProjects()
                projectActionStatus = updated.isFavorite
                    ? "Pinned \(updated.name)"
                    : "Unpinned \(updated.name)"
            } catch {
                projectActionStatus = "Could not update \(project.name): \(error.localizedDescription)"
            }
        }
    }

    func revealProjectInFinder(_ project: APIProjectRecord) {
        #if os(macOS)
        guard let path = project.projectRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            projectActionStatus = "No local folder configured for \(project.name)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path, isDirectory: true)
        ])
        #else
        projectActionStatus = "Reveal in Finder is only available on macOS"
        #endif
    }

    func createPermanentWorktree(for project: APIProjectRecord) {
        let worktreeID = "permanent-\(UUID().uuidString.lowercased())"
        Task {
            do {
                let worktree = try await apiClient(for: project).createPermanentWorktree(
                    projectId: project.id,
                    taskId: worktreeID
                )
                projectActionStatus = "Created worktree \(worktree.branchName)"
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
                ])
                #endif
            } catch {
                projectActionStatus = "Could not create worktree: \(error.localizedDescription)"
            }
        }
    }

    func removeProject(_ project: APIProjectRecord) {
        Task {
            do {
                try await apiClient(for: project).deleteProject(id: project.id)
                let scopedID = scopedProjectID(project)
                let projectEndpoint = project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
                let tabIDs = tabs.filter {
                    $0.key == .projectKanban(scopedID)
                        || (tabEndpoints[$0.id] == projectEndpoint && tabBelongsToProject($0, projectID: project.id))
                }.map(\.id)
                for tabID in tabIDs {
                    closeTab(tabID)
                }
                projects.removeAll { scopedProjectID($0) == scopedID }
                collapsedProjectIds.remove(scopedID)
                expandedTaskLists.remove(scopedID)
                projectModeStates.removeValue(forKey: scopedID)
                settings.projectModeSections.removeValue(forKey: scopedID)
                persistProjectOrder()
                await projectCacheStore.cacheProjects(projects)
                if selectedSidebarItem == .project(scopedID) {
                    selectedSidebarItem = .chats
                    selectedAppSection = .chats
                }
                projectActionStatus = "Removed \(project.name)"
            } catch {
                projectActionStatus = "Could not remove \(project.name): \(error.localizedDescription)"
            }
        }
    }

    func didSaveProject(_ project: APIProjectRecord) {
        if let index = projects.firstIndex(where: { scopedProjectID($0) == scopedProjectID(project) }) {
            projects[index] = project
            persistProjectOrder()
            openProjectKanbanTab(project: project)
        } else {
            projects.insert(project, at: 0)
            persistProjectOrder()
            showNewProjectChat(project: project)
        }
        Task { await projectCacheStore.cacheProjects(projects) }
        Task { await loadProjects(force: true) }
    }

    func showNewProjectChat(project: APIProjectRecord) {
        selectAppSection(.projects)
        updateSelectedSidebarItem(.project(project.id))
        dismissMobileSidebar()

        let projectEndpoint = project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        let chatState = makeChatTabState(endpoint: projectEndpoint)
        chatNavigationSerial += 1
        applyNavigationRequestOnNextTurn(
            ChatNavigationRequest(
                id: chatNavigationSerial,
                context: .project(
                    projectId: project.id,
                    projectName: project.name,
                    agentId: project.actors?.first
                )
            ),
            to: chatState.viewModel,
            loadInitialData: true
        )

        let draftID = "draft-\(UUID().uuidString)"
        let tab = WorkspaceTab(
            key: .chatSession(draftID),
            kind: .chat,
            title: "Main Chat",
            payload: .chatSession(sessionID: draftID, title: "Main Chat")
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .chat(chatState)),
            endpoint: projectEndpoint
        )
    }

    func selectTask(
        projectId: String,
        projectName: String,
        task: APIProjectTask,
        fallbackAgentId: String?
    ) {
        selectAppSection(.projects)
        updateSelectedSidebarItem(.task(projectId: projectId, taskId: task.id))
        dismissMobileSidebar()
        routePrimaryChat(
            .task(
                projectId: projectId,
                projectName: projectName,
                taskId: task.id,
                taskTitle: task.title,
                agentId: task.actorId ?? fallbackAgentId
            )
        )
    }

    func openTaskChatTab(project: APIProjectRecord, task: APIProjectTask, fallbackAgentId: String?) {
        selectAppSection(.projects)
        updateSelectedSidebarItem(.task(projectId: project.id, taskId: task.id))
        dismissMobileSidebar()
        let projectEndpoint = project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        let key = WorkspaceTabKey.chatTask(projectId: project.storageID, taskId: task.id)

        let chatState = makeChatTabState(endpoint: projectEndpoint)
        applyNavigationRequestOnNextTurn(
            ChatNavigationRequest(
                id: Int.random(in: Int.min ... Int.max),
                context: .task(
                    projectId: project.id,
                    projectName: project.name,
                    taskId: task.id,
                    taskTitle: task.title,
                    agentId: task.actorId ?? fallbackAgentId
                )
            ),
            to: chatState.viewModel,
            loadInitialData: true
        )
        let tab = WorkspaceTab(
            key: key,
            kind: .chat,
            title: task.title,
            payload: .chatTask(
                projectId: project.id,
                projectName: project.name,
                projectRootPath: project.projectRootPath,
                taskId: task.id,
                taskTitle: task.title,
                fallbackAgentId: task.actorId ?? fallbackAgentId
            )
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .chat(chatState)),
            endpoint: projectEndpoint
        )
    }

    func openTaskDetailTab(project: APIProjectRecord, task: APIProjectTask, fallbackAgentId: String?) {
        selectAppSection(.projects)
        updateSelectedSidebarItem(.task(projectId: project.id, taskId: task.id))
        dismissMobileSidebar()
        let projectEndpoint = project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        let key = WorkspaceTabKey.taskDetail(projectId: project.storageID, taskId: task.id)

        let detailState = makeTaskDetailTabState(endpoint: projectEndpoint)
        let tab = WorkspaceTab(
            key: key,
            kind: .taskDetail,
            title: task.title,
            payload: .taskDetail(
                TaskDetailTabContext(
                    projectId: project.id,
                    projectName: project.name,
                    projectRootPath: project.projectRootPath,
                    taskId: task.id,
                    taskTitle: task.title,
                    fallbackAgentId: task.actorId ?? fallbackAgentId
                )
            )
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .taskDetail(detailState)),
            endpoint: projectEndpoint
        )
    }

    func toggleProjectCollapse(projectId: String) {
        if collapsedProjectIds.contains(projectId) {
            collapsedProjectIds.remove(projectId)
        } else {
            collapsedProjectIds.insert(projectId)
        }
    }

    func toggleTaskListExpansion(projectId: String) {
        if expandedTaskLists.contains(projectId) {
            expandedTaskLists.remove(projectId)
        } else {
            expandedTaskLists.insert(projectId)
        }
    }

    func showMoreProjects() {
        visibleProjectCount += 6
    }

    @discardableResult
    func moveProject(_ projectID: String, relativeTo targetProjectID: String) -> Bool {
        guard projectID != targetProjectID,
              let sourceIndex = projects.firstIndex(where: { scopedProjectID($0) == projectID }),
              let targetIndex = projects.firstIndex(where: { scopedProjectID($0) == targetProjectID }) else {
            return false
        }

        let project = projects.remove(at: sourceIndex)
        guard let remainingTargetIndex = projects.firstIndex(where: { scopedProjectID($0) == targetProjectID }) else {
            projects.insert(project, at: sourceIndex)
            return false
        }
        let destinationIndex = sourceIndex < targetIndex
            ? remainingTargetIndex + 1
            : remainingTargetIndex
        projects.insert(project, at: destinationIndex)
        persistProjectOrder()
        Task { await projectCacheStore.cacheProjects(projects) }
        return true
    }

    func refreshContent() async {
        if await ConsoleAccountClient.shared.isSignedIn(),
           let snapshot = try? await ConsoleAccountClient.shared.snapshot() {
            let unverified = await ConsoleRemoteClientRegistry.shared.installDirectory(snapshot)
            settings.installConsoleInstances(snapshot.instances, unverifiedHostIDs: unverified,
                                             relayURL: ManagedRemoteClient.productionURL)
        }
        await loadProjects(force: true)
        await loadCurrentAccount()
        if chatViewModel.selectedAgent == nil {
            await chatViewModel.waitForInitialData()
        } else {
            await chatViewModel.refreshCurrentContext()
        }
        await loadAggregatedChatCatalogIfNeeded()
    }

    func loadCurrentAccount() async {
        currentAuthUser = await AuthSessionStore.shared.session(for: baseURL)?.user
    }

    func requestChatScrollToEnd(for tabID: WorkspaceTab.ID) {
        tabStates[tabID]?.chatState?.viewModel.requestTranscriptScrollToEnd()
    }

    func openSubmittedChat(_ chat: ChatScreenViewModel) {
        if selectedTabID.flatMap({ tabStates[$0]?.chatState?.viewModel }) !== chat {
            let id = chat.selectedSessionId ?? "draft-\(UUID().uuidString)"
            let tab = WorkspaceTab(key: .chatSession(id), kind: .chat, title: chat.activeSessionTitle,
                                   payload: .chatSession(sessionID: id, title: chat.activeSessionTitle))
            showInSelectedTab(tab, state: WorkspaceTabState(contentState: .chat(ChatTabState(viewModel: chat))),
                              endpoint: chat.sessionEndpoint)
        }
        selectAppSection(.chats)
        sessionDeepLinkNavigationSerial += 1
    }

    func requestSelectedComposerFocus() {
        guard let selectedTabID,
              let chatViewModel = tabStates[selectedTabID]?.chatState?.viewModel else {
            return
        }
        chatViewModel.requestComposerFocus()
    }

    func loadProjects(force: Bool = false) async {
        guard inboxSelection == settings.instanceSelection else { return }
        guard force || !didLoadProjects else { return }
        guard !isLoadingProjects else { return }

        isLoadingProjects = true
        defer {
            didLoadProjects = true
            isLoadingProjects = false
        }
        if !force {
            let cached = await projectCacheStore.loadProjects()
            guard inboxSelection == settings.instanceSelection else { return }
            projects = reconcileProjectOrder(cached)
            visibleProjectCount = 6
        }

        do {
            let list = try await fetchProjectsForCurrentSelection()
            guard inboxSelection == settings.instanceSelection, !Task.isCancelled else { return }
            projects = reconcileProjectOrder(list)
            await projectCacheStore.cacheProjects(projects)
        } catch {
            // The cached project snapshot remains available while offline.
        }
        visibleProjectCount = 6
    }

    func loadAggregatedChatCatalogIfNeeded() async {
        guard inboxSelection == settings.instanceSelection, !Task.isCancelled else { return }
        let catalogInstances: [SloppyInstance]
        switch inboxSelection {
        case .all:
            catalogInstances = settings.discoveredInstances
        case .instance(let instanceID):
            catalogInstances = settings.discoveredInstances.filter { $0.id == instanceID }
        }
        guard !catalogInstances.isEmpty else {
            synchronizeSidebarSessionCatalog()
            didLoadSidebarCatalog = true
            return
        }

        guard !isLoadingAggregatedChatCatalog else { return }
        isLoadingAggregatedChatCatalog = true
        defer {
            isLoadingAggregatedChatCatalog = false
            if inboxSelection == settings.instanceSelection, !Task.isCancelled {
                didLoadSidebarCatalog = true
            }
        }
        if let primaryID = settings.discoveredInstances.first(where: { $0.endpoint == endpoint })?.id {
            let primaryCatalog = chatViewModel.sessionCatalog.map { session in
                var tagged = session
                if tagged.sourceInstanceID == nil { tagged.sourceInstanceID = primaryID }
                return tagged
            }
            chatViewModel.installAggregatedSessionCatalog(primaryCatalog)
        }
        synchronizeSidebarSessionCatalog()
        await withTaskGroup(of: [ChatSessionSummary].self) { group in
            for instance in catalogInstances where instance.endpoint != endpoint && !settings.requiresConsoleVerification(instance) {
                group.addTask {
                    let client = SloppyAPIClient(endpoint: instance.endpoint)
                    guard let agents = try? await client.fetchAgents() else { return [] }
                    return await withTaskGroup(of: [ChatSessionSummary].self) { sessionsGroup in
                        for agent in agents {
                            sessionsGroup.addTask {
                                let cache = ClientCacheStore(namespace: instance.endpoint.cacheNamespace)
                                let sessions: [ChatSessionSummary]
                                if let fetched = try? await client.fetchAgentSessions(agentId: agent.id) {
                                    sessions = fetched
                                    await cache.cacheSessions(agentId: agent.id, projectId: nil, sessions: fetched)
                                } else {
                                    sessions = await cache.loadSessions(agentId: agent.id)
                                }
                                return sessions.map { session in
                                    var tagged = session
                                    tagged.sourceInstanceID = instance.id
                                    return tagged
                                }
                            }
                        }
                        var summaries: [ChatSessionSummary] = []
                        for await sessions in sessionsGroup { summaries += sessions }
                        return summaries
                    }
                }
            }

            for await batch in group {
                guard inboxSelection == settings.instanceSelection, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if !batch.isEmpty { chatViewModel.installAggregatedSessionCatalog(batch) }
                synchronizeSidebarSessionCatalog()
            }
        }
    }

    private func fetchProjectsForCurrentSelection() async throws -> [APIProjectRecord] {
        switch inboxSelection {
        case .all:
            guard settings.discoveredInstances.count > 1 else {
                let projects = try await apiClient.fetchProjects()
                guard let instanceID = settings.discoveredInstances.first(where: { $0.endpoint == endpoint })?.id else {
                    return projects
                }
                return projects.map { project in
                    var tagged = project
                    tagged.sourceInstanceID = instanceID
                    return tagged
                }
            }

            return await withTaskGroup(of: [APIProjectRecord].self) { group in
                for instance in settings.discoveredInstances where !settings.requiresConsoleVerification(instance) {
                    group.addTask {
                        let client = SloppyAPIClient(endpoint: instance.endpoint)
                        let cache = ClientCacheStore(namespace: instance.endpoint.cacheNamespace)
                        let projects: [APIProjectRecord]
                        if let fetched = try? await client.fetchProjects() {
                            projects = fetched
                            await cache.cacheProjects(fetched)
                        } else {
                            projects = await cache.loadProjects().filter {
                                $0.sourceInstanceID == nil || $0.sourceInstanceID == instance.id
                            }
                        }
                        return projects.map { project in
                            var tagged = project
                            tagged.sourceInstanceID = instance.id
                            return tagged
                        }
                    }
                }
                var result: [APIProjectRecord] = []
                for await batch in group {
                    result += batch
                    if !batch.isEmpty, inboxSelection == settings.instanceSelection, !Task.isCancelled {
                        let updatedIDs = Set(batch.map(\.storageID))
                        projects = reconcileProjectOrder(projects.filter { !updatedIDs.contains($0.storageID) } + batch)
                    }
                }
                return result
            }
        case .instance(let instanceID):
            guard let instance = settings.discoveredInstances.first(where: { $0.id == instanceID }) else {
                return try await apiClient.fetchProjects()
            }
            let client = instance.endpoint == endpoint ? apiClient : SloppyAPIClient(endpoint: instance.endpoint)
            return try await client.fetchProjects().map { project in
                var tagged = project
                tagged.sourceInstanceID = instance.id
                return tagged
            }
        }
    }

    func endpoint(for instanceID: String) -> SloppyInstanceEndpoint? {
        settings.discoveredInstances.first(where: { $0.id == instanceID })?.endpoint
    }

    private func apiClient(for project: APIProjectRecord) -> SloppyAPIClient {
        guard let instanceID = project.sourceInstanceID,
              let sourceEndpoint = endpoint(for: instanceID) else {
            return apiClient
        }
        return SloppyAPIClient(endpoint: sourceEndpoint)
    }

    private func apiClient(for session: ChatSessionSummary) -> SloppyAPIClient {
        guard let instanceID = session.sourceInstanceID,
              let sourceEndpoint = endpoint(for: instanceID) else {
            return apiClient
        }
        return SloppyAPIClient(endpoint: sourceEndpoint)
    }

    func project(for tabID: WorkspaceTab.ID, localProjectID: String) -> APIProjectRecord? {
        let sourceEndpoint = tabEndpoints[tabID] ?? endpoint
        return projects.first { project in
            guard project.id == localProjectID else { return false }
            let projectEndpoint = project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
            return projectEndpoint == sourceEndpoint
        }
    }

    private func scopedProjectID(_ project: APIProjectRecord) -> String {
        project.storageID
    }

    private func reconcileProjectOrder(_ availableProjects: [APIProjectRecord]) -> [APIProjectRecord] {
        let projectsByID = Dictionary(uniqueKeysWithValues: availableProjects.map { (scopedProjectID($0), $0) })
        let savedIDs = settings.projectOrderIDs.filter { projectsByID[$0] != nil }
        let savedIDSet = Set(savedIDs)
        let newProjects = availableProjects.filter { !savedIDSet.contains(scopedProjectID($0)) }
        let orderedProjects = newProjects + savedIDs.compactMap { projectsByID[$0] }
        let prioritizedProjects = orderedProjects.filter(\.isFavorite) + orderedProjects.filter { !$0.isFavorite }
        settings.projectOrderIDs = prioritizedProjects.map(scopedProjectID)
        return prioritizedProjects
    }

    private func persistProjectOrder() {
        settings.projectOrderIDs = projects.map(scopedProjectID)
    }

    private func replaceProject(_ project: APIProjectRecord) {
        guard let index = projects.firstIndex(where: { scopedProjectID($0) == scopedProjectID(project) }) else {
            projects.append(project)
            return
        }
        projects[index] = project
    }

    private func prioritizeFavoriteProjects() {
        projects = projects.filter(\.isFavorite) + projects.filter { !$0.isFavorite }
        persistProjectOrder()
        Task { await projectCacheStore.cacheProjects(projects) }
    }

    private func tabBelongsToProject(_ tab: WorkspaceTab, projectID: String) -> Bool {
        switch tab.payload {
        case .projectKanban(let context):
            return context.projectId == projectID
        case .workspaceFiles(let context):
            return context.projectId == projectID
        case .chatTask(let tabProjectID, _, _, _, _, _):
            return tabProjectID == projectID
        case .taskDetail(let context):
            return context.projectId == projectID
        case .chatSession:
            return tabStates[tab.id]?.chatState?.viewModel.activeProjectIdForWorkspacePanel == projectID
        }
    }

    func selectAppSection(_ section: MainAppSection) {
        cancelSidebarAgentChatRequest()
        guard selectedAppSection != section else {
            return
        }
        selectedAppSection = section
        dismissMobileSidebar()
    }

    func selectAttention() {
        selectedSidebarItem = .attention
        selectAppSection(.attention)
    }

    func selectScheduled() {
        selectedSidebarItem = .scheduled
        selectAppSection(.scheduled)
    }

    func selectAgents() {
        selectedSidebarAgent = nil
        selectedSidebarItem = .agents
        selectAppSection(.agents)
    }

    func selectSidebarAgent(_ agent: APIAgentRecord) {
        guard openingSidebarAgentID != agent.id else { return }
        if selectedAppSection == .chats, sidebarSelectedAgentID == agent.id {
            requestSelectedComposerFocus()
            return
        }

        cancelSidebarAgentChatRequest()
        let requestID = UUID()
        sidebarAgentChatRequestID = requestID
        openingSidebarAgentID = agent.id
        sidebarAgentChatError = nil
        sidebarAgentChatTask = Task { @MainActor [weak self, apiClient] in
            do {
                let session = try await apiClient.openLongChat(agentId: agent.id)
                guard let self, !Task.isCancelled, self.sidebarAgentChatRequestID == requestID else { return }
                self.cancelSidebarAgentChatRequest()
                self.chatViewModel.mergeSessionSummary(session)
                self.synchronizeSidebarSessionCatalog()
                if let tab = self.tabs.first(where: {
                    guard case .chatSession(let sessionID, _) = $0.payload else { return false }
                    return sessionID == session.id && (self.tabEndpoints[$0.id] ?? self.endpoint) == self.endpoint
                }) {
                    self.selectAppSection(.chats)
                    self.updateSelectedSidebarItem(.chats)
                    self.selectTab(tab.id)
                } else {
                    self.openSessionChatTab(session)
                }
                self.requestSelectedComposerFocus()
            } catch {
                guard let self, !Task.isCancelled, self.sidebarAgentChatRequestID == requestID else { return }
                self.cancelSidebarAgentChatRequest()
                self.sidebarAgentChatError = "Could not open chat: \(error.localizedDescription)"
            }
        }
    }

    func showSidebarAgentInfo(_ agent: APIAgentRecord) {
        selectedSidebarAgent = agent
        selectedSidebarItem = .agents
        selectAppSection(.agents)
    }

    private func cancelSidebarAgentChatRequest() {
        sidebarAgentChatTask?.cancel()
        sidebarAgentChatTask = nil
        sidebarAgentChatRequestID = nil
        openingSidebarAgentID = nil
        sidebarAgentChatError = nil
    }

    func selectUsage() {
        selectedSidebarItem = .usage
        selectAppSection(.usage)
    }

    func selectPullRequests() {
        selectedSidebarItem = .pullRequests
        selectAppSection(.pullRequests)
    }

    func selectArtifacts() {
        selectedSidebarItem = .artifacts
        selectAppSection(.artifacts)
    }

    func selectSites() {
        selectedSidebarItem = .sites
        selectAppSection(.sites)
    }

    func createSiteFromChat() {
        pendingNewChatStarterPrompt = "Help me build this project as a static website and publish it with Sloppy Sites. Keep it private unless I explicitly choose public access."
        selectNewChat()
    }

    func beginPullRequestReview() {
        let dock = workspaceDockState
        if dock.selectedTab?.reviewReference != nil { dock.hide() }
    }

    func linkPullRequestChat(_ detail: CodeReviewDetail, session: ChatSessionSummary) async throws {
        let linked = try await apiClient.openCodeReviewSession(detail.item, agentId: session.agentId, sessionId: session.id)
        selectedCodeReviewSessions[detail.item.reviewReference] = linked
    }

    func sendPullRequestReview(_ detail: CodeReviewDetail, submission: CodeReviewSubmission) async throws {
        let reference = detail.item.reviewReference
        let selected = selectedCodeReviewSessions[reference]
        await chatViewModel.waitForInitialData()
        guard let agentID = selected?.agentId ?? chatViewModel.selectedAgent?.id else {
            throw APIError.decodingFailed("Choose an agent before sending the review.")
        }
        let accepted: ChatSessionSummary
        do {
            accepted = try await apiClient.sendCodeReview(detail.item, agentId: agentID,
                sessionId: selected?.id, submission: submission)
        } catch {
            if let selected, let known = try? await apiClient.fetchCodeReviewSessions(detail.item),
               !known.contains(where: { $0.id == selected.id && $0.agentId == selected.agentId }) {
                selectedCodeReviewSessions.removeValue(forKey: reference)
                accepted = try await apiClient.sendCodeReview(detail.item, agentId: agentID, submission: submission)
            } else { throw error }
        }
        selectedCodeReviewSessions[reference] = accepted
        chatViewModel.mergeSessionSummary(accepted)
        await presentPullRequestChat(detail, session: accepted)
    }

    private func presentPullRequestChat(_ detail: CodeReviewDetail, session: ChatSessionSummary) async {
        guard !Task.isCancelled else { return }
        let source = apiClient.endpoint
        let dock = workspaceDockState
        let reference = detail.item.reviewReference
        let tab: WorkspaceDockTab
        if let existing = dock.tabs.first(where: { $0.reviewReference == reference && $0.reviewSessionID == session.id }) {
            tab = existing
        } else {
            tab = dock.open(.sideChat, present: false)
            tab.reviewReference = reference
            tab.reviewSessionID = session.id
            tab.reviewDisplayTitle = detail.item.number.map { "PR #\($0)" } ?? "PR \(detail.item.id)"
            tab.chat = makeChatTabState(endpoint: source).viewModel
        }
        guard let chat = tab.chat else { return }
        await chat.waitForInitialData()
        guard !Task.isCancelled else { return }
        if chat.selectedSessionId != session.id { chat.openSessionFromSummary(session) }
        dock.select(tab)
    }

    func addToSideChat(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        sideChatViewModel()?.addTextSelectionToComposer(text)
    }

    func startInSideChat(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chat = sideChatViewModel() else { return }

        Task { @MainActor in
            await chat.waitForInitialData()
            chat.useStarterPrompt(text)
            chat.sendMessage(content: text)
        }
    }

    private func sideChatViewModel() -> ChatScreenViewModel? {
        let dock = workspaceDockState
        let tab: WorkspaceDockTab
        if let existing = dock.tabs.first(where: { $0.kind == .sideChat }) {
            dock.select(existing)
            tab = existing
        } else {
            tab = openWorkspaceDockTab(.sideChat)
        }
        return tab.chat
    }

    private func applyPendingNewChatStarterPrompt() {
        guard let prompt = pendingNewChatStarterPrompt,
              let selectedTabID,
              let chatViewModel = tabStates[selectedTabID]?.chatState?.viewModel else {
            return
        }
        pendingNewChatStarterPrompt = nil
        chatViewModel.useStarterPrompt(prompt)
    }

    func selectWorkspace() {
        selectedSidebarItem = nil
        selectAppSection(.workspace)
    }

    func selectTab(_ tabID: WorkspaceTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        cancelSidebarAgentChatRequest()

        if let desktopSplitState,
           tabID != desktopSplitState.primaryTabID,
           tabID != desktopSplitState.secondaryTabID {
            clearDesktopSplit()
        }

        selectedTabID = tabID
    }

    func beginDesktopSplit(source sourceTabID: WorkspaceTab.ID, target targetTabID: WorkspaceTab.ID) {
        guard sourceTabID != targetTabID,
              tabs.contains(where: { $0.id == sourceTabID }),
              tabs.contains(where: { $0.id == targetTabID }) else {
            return
        }

        desktopSplitState = DesktopTabSplitState(
            primaryTabID: targetTabID,
            secondaryTabID: sourceTabID,
            fraction: 0.5
        )
        selectedTabID = targetTabID
    }

    func updateDesktopSplitFraction(_ fraction: CGFloat) {
        guard var desktopSplitState else {
            return
        }
        desktopSplitState.fraction = min(0.88, max(0.12, fraction))
        self.desktopSplitState = desktopSplitState
    }

    func clearDesktopSplit() {
        desktopSplitState = nil
    }

    func createBlankChatTab(select: Bool = true) {
        appendBlankChatTab(endpoint: endpoint, select: select)
    }

    func createBlankChatTab(on instance: SloppyInstance) {
        appendBlankChatTab(endpoint: instance.endpoint, select: true)
    }

    private func appendBlankChatTab(endpoint: SloppyInstanceEndpoint, select: Bool) {
        let chatState = makeChatTabState(endpoint: endpoint)
        let draftID = "draft-\(UUID().uuidString)"
        let tab = WorkspaceTab(
            key: .chatSession(draftID),
            kind: .chat,
            title: "New Chat",
            payload: .chatSession(sessionID: draftID, title: "New Chat")
        )
        tabs.append(tab)
        tabStates[tab.id] = WorkspaceTabState(contentState: .chat(chatState))
        tabEndpoints[tab.id] = endpoint
        if select {
            selectedTabID = tab.id
        }
    }

    func showBlankChatInSelectedTab(endpoint: SloppyInstanceEndpoint? = nil) {
        let sourceEndpoint = endpoint ?? self.endpoint
        let chatState = makeChatTabState(endpoint: sourceEndpoint)
        let draftID = "draft-\(UUID().uuidString)"
        let tab = WorkspaceTab(
            key: .chatSession(draftID),
            kind: .chat,
            title: "New Chat",
            payload: .chatSession(sessionID: draftID, title: "New Chat")
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .chat(chatState)),
            endpoint: sourceEndpoint
        )
    }

    func synchronizeChatTab(_ tabID: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].kind == .chat,
              let chatViewModel = tabStates[tabID]?.chatState?.viewModel else {
            return
        }

        guard let sessionID = chatViewModel.selectedSessionId else {
            tabs[index] = WorkspaceTab(
                id: tabs[index].id,
                key: tabs[index].key,
                kind: .chat,
                title: "New Chat",
                payload: tabs[index].payload
            )
            return
        }

        let title = chatViewModel.activeSessionTitle
        let sourceInstanceID = (tabEndpoints[tabID] ?? endpoint).targetNodeID
            ?? settings.discoveredInstances.first(where: { $0.endpoint == (tabEndpoints[tabID] ?? endpoint) })?.id
        let storageSessionID = sourceInstanceID.map {
            InstanceScopedID(instanceID: $0, localID: sessionID).description
        } ?? sessionID
        tabs[index] = WorkspaceTab(
            id: tabs[index].id,
            key: .chatSession(storageSessionID),
            kind: .chat,
            title: title,
            payload: .chatSession(sessionID: sessionID, title: title)
        )
    }

    func nextTabID(from tabID: WorkspaceTab.ID, offset: Int) -> WorkspaceTab.ID? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return nil
        }
        let nextIndex = index + offset
        guard tabs.indices.contains(nextIndex) else {
            return nil
        }
        return tabs[nextIndex].id
    }

    func selectAdjacentTab(offset: Int) {
        guard let selectedTabID,
              let nextID = nextTabID(from: selectedTabID, offset: offset) else {
            return
        }
        self.selectedTabID = nextID
    }

    func presentMobileTabsOverview() {
        isMobileTabsOverviewPresented = true
    }

    func dismissMobileTabsOverview() {
        isMobileTabsOverviewPresented = false
    }

    func presentVisionTabsOverview() {
        isVisionTabsOverviewPresented = true
    }

    func dismissVisionTabsOverview() {
        isVisionTabsOverviewPresented = false
    }

    func closeActiveTab() {
        guard let selectedTabID else {
            return
        }
        closeTab(selectedTabID)
    }

    func closeActivePanelTabOrMainTab() {
        let dock = workspaceDockState
        if dock.isPresented {
            dock.closeSelectedTabOrHide()
            return
        }
        closeActiveTab()
    }

    func toggleTerminalForSelectedTab() {
        guard let selectedTabID,
              let terminalState = tabStates[selectedTabID]?.terminalState else {
            return
        }

        if terminalState.isPresented,
           terminalState.selectedPanel == .terminal {
            closeTerminalForSelectedTab()
        } else {
            openTerminalForSelectedTab()
        }
    }

    func openTerminalForSelectedTab() {
        openBottomPanel(.terminal)
    }

    func openBottomPanel(_ panel: WorkspaceBottomPanelKind) {
        guard let selectedTabID,
              let terminalState = tabStates[selectedTabID]?.terminalState else {
            return
        }

        terminalState.selectedPanel = panel
        terminalState.isPresented = true
        if panel == .terminal {
            ensureTerminalSessionStarted(for: selectedTabID)
        }
    }

    func closeTerminalForSelectedTab() {
        guard let selectedTabID,
              let terminalState = tabStates[selectedTabID]?.terminalState else {
            return
        }

        terminalState.isPresented = false
    }

    func ensureTerminalSessionStarted(for tabID: WorkspaceTab.ID) {
        guard terminalSessions[tabID] == nil,
              let terminalState = tabStates[tabID]?.terminalState else {
            return
        }

        let workingDirectory = terminalWorkingDirectory(for: tabID)
        terminalState.workingDirectory = workingDirectory
        let remoteConfiguration: WorkspaceTerminalSession.RemoteConfiguration?
        let tabEndpoint = tabEndpoints[tabID] ?? endpoint
        if case .relay(let coordinatorBaseURL, let targetNodeID) = tabEndpoint {
            remoteConfiguration = WorkspaceTerminalSession.RemoteConfiguration(
                apiClient: apiClient,
                coordinatorBaseURL: coordinatorBaseURL,
                targetNodeID: targetNodeID,
                managedDeviceID: nil,
                projectID: projectID(for: tabID)
            )
        } else if case .managed(let relayURL, let targetDeviceID) = tabEndpoint {
            remoteConfiguration = WorkspaceTerminalSession.RemoteConfiguration(
                apiClient: apiClient,
                coordinatorBaseURL: relayURL,
                targetNodeID: "",
                managedDeviceID: targetDeviceID,
                projectID: projectID(for: tabID)
            )
        } else {
            remoteConfiguration = nil
        }
        let session = WorkspaceTerminalSession(
            id: terminalState.sessionID,
            workingDirectory: workingDirectory,
            remoteConfiguration: remoteConfiguration
        )
        session.startIfNeeded()
        terminalSessions[tabID] = session
    }

    func registerTerminalHost(_ host: WorkspaceTerminalHosting, for tabID: WorkspaceTab.ID) {
        terminalHosts[tabID] = host
    }

    func makeTerminalHostView(for tabID: WorkspaceTab.ID) -> AnyView {
        guard let session = terminalSessions[tabID] else {
            return AnyView(
                Text("Project directory unavailable")
            )
        }

        #if os(macOS)
        if session.remoteConfiguration != nil {
            return AnyView(
                WorkspaceRemoteTerminalMacHostView(session: session) { host in
                    self.registerTerminalHost(host, for: tabID)
                    host.focus()
                }
            )
        }
        return AnyView(
            WorkspaceTerminalMacHostView(session: session) { host in
                self.registerTerminalHost(host, for: tabID)
                host.focus()
            }
        )
        #else
        return AnyView(
            Text("Terminal host is not available on this platform yet.")
        )
        #endif
    }

    func closeTab(_ tabID: WorkspaceTab.ID) {
        browserSessions.removeValue(forKey: tabID)?.stop()
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        terminalSessions[tabID]?.terminate()
        terminalSessions.removeValue(forKey: tabID)
        terminalHosts.removeValue(forKey: tabID)
        tabEndpoints.removeValue(forKey: tabID)

        let splitStateBeforeClose = desktopSplitState
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: index)
        tabStates.removeValue(forKey: tabID)

        if let splitStateBeforeClose {
            if tabID == splitStateBeforeClose.primaryTabID {
                selectedTabID = splitStateBeforeClose.secondaryTabID
                clearDesktopSplit()
            } else if tabID == splitStateBeforeClose.secondaryTabID {
                selectedTabID = splitStateBeforeClose.primaryTabID
                clearDesktopSplit()
            } else if !tabs.contains(where: { $0.id == splitStateBeforeClose.primaryTabID }) ||
                        !tabs.contains(where: { $0.id == splitStateBeforeClose.secondaryTabID }) {
                clearDesktopSplit()
            }
        }

        if tabs.isEmpty {
            selectedTabID = nil
            createBlankChatTab(select: true)
            if isMobileTabsOverviewPresented {
                dismissMobileTabsOverview()
            }
            return
        }

        guard wasSelected else {
            return
        }

        let nextIndex = min(index, tabs.count - 1)
        selectedTabID = tabs[nextIndex].id
    }

    func makeChatTabState(endpoint: SloppyInstanceEndpoint? = nil) -> ChatTabState {
        let resolvedEndpoint = endpoint ?? self.endpoint
        let sourceInstanceID = settings.discoveredInstances.first(where: { $0.endpoint == resolvedEndpoint })?.id
        let apiClient = resolvedEndpoint == self.endpoint ? self.apiClient : SloppyAPIClient(endpoint: resolvedEndpoint)
        let viewModel = ChatScreenViewModel(
            apiClient: apiClient,
            cacheStore: resolvedEndpoint == self.endpoint
                ? cacheStore
                : ClientCacheStore(namespace: resolvedEndpoint.cacheNamespace),
            settings: settings,
            connectionMonitor: connectionMonitor,
            restoresLastSession: false,
            onSessionSummaryChange: { [weak self] summary in
                var tagged = summary
                tagged.sourceInstanceID = sourceInstanceID
                self?.chatViewModel.mergeSessionSummary(tagged)
                self?.synchronizeSidebarSessionCatalog()
            },
            responseNotificationScheduler: responseNotificationScheduler,
            onOpenSettings: { destination in self.onOpenSettings(destination) }
        )
        viewModel.loadInitialData()
        return ChatTabState(viewModel: viewModel)
    }

    func selectProjectModeSection(_ section: ProjectModeSection, project: APIProjectRecord) {
        let state = projectModeState(for: project)
        guard state.selectedSection != section else { return }

        state.selectedSection = section
        settings.projectModeSections[scopedProjectID(project)] = section.rawValue
        activateProjectModeSection(section, project: project, state: state)
    }

    func projectModeState(for project: APIProjectRecord) -> ProjectKanbanTabState {
        let projectStateID = scopedProjectID(project)
        if let state = projectModeStates[projectStateID] {
            return state
        }

        let projectEndpoint = project.sourceInstanceID.flatMap(endpoint(for:)) ?? endpoint
        let chatState = makeChatTabState(endpoint: projectEndpoint)
        chatNavigationSerial += 1
        applyNavigationRequestOnNextTurn(
            ChatNavigationRequest(
                id: chatNavigationSerial,
                context: .project(
                    projectId: project.id,
                    projectName: project.name,
                    agentId: project.actors?.first
                )
            ),
            to: chatState.viewModel,
            loadInitialData: false
        )

        let selectedSection = settings.projectModeSections[projectStateID]
            .flatMap(ProjectModeSection.init(rawValue:)) ?? .kanban
        let state = ProjectKanbanTabState(
            viewModel: ProjectKanbanViewModel(
                apiClient: SloppyAPIClient(endpoint: projectEndpoint),
                availableInstances: settings.discoveredInstances,
                preferredExecutionNodeID: project.sourceInstanceID ?? settings.instanceSelection.instanceID
            ),
            workspaceViewModel: CanvasWorkspaceViewModel(
                baseURL: baseURL,
                apiClient: SloppyAPIClient(endpoint: projectEndpoint)
            ),
            automationViewModel: ProjectAutomationViewModel(
                apiClient: SloppyAPIClient(endpoint: projectEndpoint)
            ),
            chatViewModel: chatState.viewModel,
            selectedSection: selectedSection
        )
        projectModeStates[projectStateID] = state
        return state
    }

    func activateProjectModeSection(
        _ section: ProjectModeSection,
        project: APIProjectRecord,
        state: ProjectKanbanTabState
    ) {
        switch section {
        case .kanban:
            break // The visible board owns its cancellable loading task.
        case .workspaces:
            Task {
                await state.workspaceViewModel.resolve(
                    workspaceID: nil,
                    projectID: project.id,
                    projectName: project.name
                )
            }
        case .automation:
            Task { await state.automationViewModel.load(projectId: project.id) }
        case .chats:
            chatNavigationSerial += 1
            applyNavigationRequestOnNextTurn(
                ChatNavigationRequest(
                    id: chatNavigationSerial,
                    context: .project(
                        projectId: project.id,
                        projectName: project.name,
                        agentId: project.actors?.first
                    )
                ),
                to: state.chatViewModel,
                loadInitialData: true
            )
        }
    }

    func makeWorkspaceFilesTabState(endpoint: SloppyInstanceEndpoint? = nil) -> WorkspaceFilesTabState {
        let apiClient = SloppyAPIClient(endpoint: endpoint ?? self.endpoint)
        return WorkspaceFilesTabState(viewModel: WorkspacePanelViewModel(apiClient: apiClient))
    }

    func makeTaskDetailTabState(endpoint: SloppyInstanceEndpoint? = nil) -> TaskDetailTabState {
        let apiClient = SloppyAPIClient(endpoint: endpoint ?? self.endpoint)
        return TaskDetailTabState(viewModel: TaskDetailViewModel(apiClient: apiClient))
    }

    func openWorkspaceTabForSelectedContext() {
        guard let context = activeWorkspaceFilesContext() else {
            return
        }

        let sourceEndpoint = selectedTabID.flatMap { tabEndpoints[$0] } ?? endpoint
        let sourceInstanceID = settings.discoveredInstances.first(where: { $0.endpoint == sourceEndpoint })?.id
        let scopedProjectID = sourceInstanceID.map {
            InstanceScopedID(instanceID: $0, localID: context.projectId).description
        } ?? context.projectId
        let key = WorkspaceTabKey.workspaceFiles(scopedProjectID)
        let workspaceState = makeWorkspaceFilesTabState(endpoint: sourceEndpoint)
        let tab = WorkspaceTab(
            key: key,
            kind: .workspaceFiles,
            title: "\(context.projectName) Files",
            payload: .workspaceFiles(context)
        )
        showInSelectedTab(
            tab,
            state: WorkspaceTabState(contentState: .workspaceFiles(workspaceState)),
            endpoint: sourceEndpoint
        )
    }

    func resolveWorkingDirectory(for tabID: WorkspaceTab.ID) -> URL? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return nil
        }

        let projectRootPath: String?
        switch tab.payload {
        case .workspaceFiles(let context):
            projectRootPath = context.projectRootPath
        case .projectKanban(let context):
            projectRootPath = context.projectRootPath
        case .chatTask(_, _, let payloadProjectRootPath, _, _, _):
            projectRootPath = payloadProjectRootPath
        case .taskDetail(let context):
            projectRootPath = context.projectRootPath
        case .chatSession:
            guard let chatState = tabStates[tab.id]?.chatState,
                  let projectId = chatState.viewModel.activeProjectIdForWorkspacePanel else {
                return nil
            }
            projectRootPath = projects.first(where: { $0.id == projectId })?.projectRootPath
        }

        guard let projectRootPath, !projectRootPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: projectRootPath, isDirectory: true)
    }

    func terminalWorkingDirectory(for tabID: WorkspaceTab.ID) -> URL {
        let fallback = {
            #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser
            #else
            return URL.applicationDirectory 
            #endif
        }()
        return resolveWorkingDirectory(for: tabID) ?? fallback
    }

    private func projectID(for tabID: WorkspaceTab.ID) -> String? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        switch tab.payload {
        case .projectKanban(let context):
            return context.projectId
        case .workspaceFiles(let context):
            return context.projectId
        case .chatTask(let projectId, _, _, _, _, _):
            return projectId
        case .taskDetail(let context):
            return context.projectId
        case .chatSession:
            return tabStates[tabID]?.chatState?.viewModel.activeProjectIdForWorkspacePanel
        }
    }

    private func updateSelectedSidebarItem(_ selection: MainSidebarSelection) {
        guard selectedSidebarItem != selection else {
            return
        }
        selectedSidebarItem = selection
    }

    private func routePrimaryChat(_ context: ChatNavigationRequest.Context) {
        chatNavigationSerial += 1
        applyNavigationRequestOnNextTurn(
            ChatNavigationRequest(id: chatNavigationSerial, context: context),
            to: chatViewModel,
            loadInitialData: false
        )
    }

    private func applyNavigationRequestOnNextTurn(
        _ request: ChatNavigationRequest,
        to viewModel: ChatScreenViewModel,
        loadInitialData: Bool
    ) {
        Task { @MainActor in
            viewModel.applyNavigationRequest(request)
            if loadInitialData {
                viewModel.loadInitialData()
            }
        }
    }

    private func showInSelectedTab(
        _ tab: WorkspaceTab,
        state: WorkspaceTabState,
        endpoint sourceEndpoint: SloppyInstanceEndpoint? = nil
    ) {
        guard let selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            tabs.append(tab)
            tabStates[tab.id] = state
            if let sourceEndpoint {
                tabEndpoints[tab.id] = sourceEndpoint
            }
            self.selectedTabID = tab.id
            return
        }

        clearDesktopSplit()
        terminalSessions[selectedTabID]?.terminate()
        terminalSessions.removeValue(forKey: selectedTabID)
        terminalHosts.removeValue(forKey: selectedTabID)
        if let sourceEndpoint {
            tabEndpoints[selectedTabID] = sourceEndpoint
        } else {
            tabEndpoints.removeValue(forKey: selectedTabID)
        }

        tabs[index] = WorkspaceTab(
            id: selectedTabID,
            key: tab.key,
            kind: tab.kind,
            title: tab.title,
            payload: tab.payload
        )
        tabStates[selectedTabID] = state
    }

    private func activeWorkspaceFilesContext() -> WorkspaceFilesTabContext? {
        guard let selectedTabID,
              let tab = tabs.first(where: { $0.id == selectedTabID }) else {
            return nil
        }

        switch tab.payload {
        case .projectKanban(let context):
            return WorkspaceFilesTabContext(
                projectId: context.projectId,
                projectName: context.projectName,
                projectRootPath: context.projectRootPath
            )
        case .workspaceFiles(let context):
            return context
        case .chatTask(let projectId, let projectName, let projectRootPath, _, _, _):
            return WorkspaceFilesTabContext(
                projectId: projectId,
                projectName: projectName,
                projectRootPath: projectRootPath
            )
        case .taskDetail(let context):
            return WorkspaceFilesTabContext(
                projectId: context.projectId,
                projectName: context.projectName,
                projectRootPath: context.projectRootPath
            )
        case .chatSession:
            guard let chatState = tabStates[tab.id]?.chatState,
                  let projectId = chatState.viewModel.activeProjectIdForWorkspacePanel,
                  let projectName = chatState.viewModel.activeProjectNameForWorkspacePanel else {
                return nil
            }
            return WorkspaceFilesTabContext(
                projectId: projectId,
                projectName: projectName,
                projectRootPath: projects.first(where: { $0.id == projectId })?.projectRootPath
            )
        }
    }
}
