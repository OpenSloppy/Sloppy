import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat

@MainActor
extension MainView {
    var body: some View {
        Group {
            if viewModel.hasLoadedInitialContent {
                workspacePanelContainer
            } else {
                MainLoadingView()
            }
        }
        .onAppear {
            if viewModel.tabs.isEmpty {
                viewModel.createBlankChatTab(select: true)
            }
            Task {
                await viewModel.loadProjects()
            }
            Task {
                await viewModel.chatViewModel.waitForInitialData()
                await viewModel.loadAggregatedChatCatalogIfNeeded()
            }
            Task {
                await viewModel.loadCurrentAccount()
            }
            handleMenuBarQuickAction(menuBarQuickActionRequest)
            handleDeepLink(deepLinkRequest)
            if mainContentModeRawValue == MainContentMode.workspace.rawValue {
                viewModel.selectWorkspace()
                hasActivatedWorkspaceMode = true
            }
        }
        .onChange(of: menuBarQuickActionRequest?.id) { _, _ in
            handleMenuBarQuickAction(menuBarQuickActionRequest)
        }
        .onChange(of: deepLinkRequest?.id) { _, _ in
            handleDeepLink(deepLinkRequest)
        }
        .onChange(of: approvalRequiredSessionIDs) { _, sessionIDs in
            if sessionIDs.isEmpty {
                showsApprovalRequiredChatsOnly = false
            }
            if let activeChatViewModel {
                Task {
                    await activeChatViewModel.refreshPendingToolApproval()
                }
            }
        }
        .background {
            Group {
                Button("") {
                    viewModel.selectNewChat()
                }
                .keyboardShortcut("t", modifiers: [.command])
                .opacity(0.001)
                .allowsHitTesting(false)

                Button("") {
                    viewModel.closeActivePanelTabOrMainTab()
                }
                .keyboardShortcut("w", modifiers: [.command])
                .opacity(0.001)
                .allowsHitTesting(false)

                Button("") {
                    Task { await viewModel.refreshContent() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .opacity(0.001)
                .allowsHitTesting(false)

#if os(macOS)
                Button("") {
                    viewModel.toggleTerminalForSelectedTab()
                }
                .keyboardShortcut("j", modifiers: [.command])
                .opacity(0.001)
                .allowsHitTesting(false)
#endif
            }
        }
#if os(macOS)
        .focusedSceneValue(
            \.toggleWorkspaceTerminal,
             ToggleWorkspaceTerminalAction {
                 viewModel.toggleTerminalForSelectedTab()
             }
        )
#endif
        .toolbar {
            if viewModel.hasLoadedInitialContent {
                if isCanvasWorkspaceSelected,
                   !canvasWorkspaceViewModel.isShowingLibrary {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            returnToCanvasWorkspaceLibrary()
                        } label: {
                            Label("Workspaces", systemImage: "chevron.left")
                        }
                        .help("Back to Workspaces")
                        .accessibilityIdentifier("canvas-workspace-back")
                    }
                }

#if os(macOS)
                if !isCanvasWorkspaceSelected {
                    ToolbarItem(placement: .principal) {
                        toolbarSearchField
                    }
                }
#endif

#if os(macOS)
                ToolbarItem(placement: .automatic) {
                    toolbarApprovalButton
                }
#endif
                
                ToolbarItemGroup(placement: .primaryAction) {
                    if !isCanvasWorkspaceSelected,
                       viewModel.selectedAppSection == .chats,
                       let activeChatViewModel {
                        ChatParallelAgentsToolbar(viewModel: activeChatViewModel) { session in
                            var scopedSession = session
                            scopedSession.sourceInstanceID = activeChatViewModel.sessions.first {
                                $0.id == activeChatViewModel.selectedSessionId
                            }?.sourceInstanceID ?? session.sourceInstanceID
                            viewModel.openSessionChatTab(scopedSession, endpointOverride: activeChatViewModel.sessionEndpoint)
                        }
                    }

#if os(macOS)
                    if !isCanvasWorkspaceSelected,
                       viewModel.selectedAppSection != .usage,
                       let activeChatViewModel {
                        ChatLaunchControls(viewModel: activeChatViewModel) { url in
                            let tab = viewModel.openWorkspaceDockTab(.browser)
                            tab.browser?.addressText = url.absoluteString
                            Task { _ = try? await tab.browser?.ensureBrowserRuntime().open(url: url.absoluteString) }
                        }
                    }
#endif

#if !os(macOS)
                    if !isCanvasWorkspaceSelected,
                       viewModel.selectedAppSection != .artifacts,
                       viewModel.selectedAppSection != .sites,
                       viewModel.selectedAppSection != .agents,
                       viewModel.selectedAppSection != .usage,
                       viewModel.selectedAppSection != .pullRequests,
                       let activeChatViewModel {
                        ChatContextToolbarMenu(
                            selectedAgent: activeChatViewModel.selectedAgent,
                            agents: activeChatViewModel.agents,
                            selectedModelId: activeChatViewModel.selectedModelId,
                            models: activeChatViewModel.availableModels,
                            onSelectAgent: activeChatViewModel.pickAgent,
                            onSelectModel: activeChatViewModel.pickModel
                        )
                    }
#endif

                    if idiom != .phone,
                       !isCanvasWorkspaceSelected,
                       viewModel.selectedAppSection != .artifacts,
                       viewModel.selectedAppSection != .sites,
                       viewModel.selectedAppSection != .agents,
                       viewModel.selectedAppSection != .usage,
                       viewModel.selectedAppSection != .pullRequests {
                        workspaceSidePanelButton
                    }
                }
            }
        }
#if os(macOS)
        .overlay(alignment: .top) {
            toolbarSearchResultsOverlay
        }
#endif
        .sheet(isPresented: $viewModel.isProjectEditorPresented) {
            ProjectEditorSheet(
                endpoint: viewModel.projectEditorEndpoint,
                project: viewModel.projectBeingEdited,
                onSaved: viewModel.didSaveProject
            )
        }
        .sheet(isPresented: $viewModel.isNewChatInstancePickerPresented) {
            NavigationStack {
                List(viewModel.settings.discoveredInstances) { instance in
                    Button {
                        viewModel.selectNewChat(on: instance)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: instance.isLocal ? "desktopcomputer" : "network")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instance.displayName)
                                Text(instance.isLocal ? "Local" : "Via Relay")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(instance.status == .online ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .navigationTitle("New Chat")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            viewModel.isNewChatInstancePickerPresented = false
                        }
                    }
                }
            }
            .frame(minWidth: 360, minHeight: 280)
        }
        .onChange(of: viewModel.selectedTabID) { oldValue, newValue in
            if let oldValue,
               oldValue != newValue,
               shouldCaptureLiveSnapshotForCache {
                captureMobileTabsSnapshot(for: oldValue, storeInCache: true)
            }
            viewModel.connectWorkspaceBrowserForSelectedChat()
            updateMobileTabPagingDirection(from: oldValue, to: newValue)
            if let newValue {
                viewModel.requestChatScrollToEnd(for: newValue)
            }
        }
        .onChange(of: activeChatViewModel?.workingTreeSourceControl) { _, sourceControl in
            guard let sourceControl,
                  let activeChatViewModel,
                  let projectID = activeChatViewModel.activeProjectIdForWorkspacePanel else { return }
            if viewModel.workspacePanelViewModel.context?.projectId == projectID {
                viewModel.workspacePanelViewModel.synchronizeSourceControl(sourceControl)
            }
            for tab in viewModel.workspaceDockState.tabs where tab.panel?.context?.projectId == projectID {
                tab.panel?.synchronizeSourceControl(sourceControl)
            }
        }
        .onChange(of: viewModel.selectedAppSection) { _, _ in
            mainContentModeRawValue = isCanvasWorkspaceSelected
            ? MainContentMode.workspace.rawValue
            : MainContentMode.coding.rawValue
            guard isCanvasWorkspaceSelected else {
                return
            }
            viewModel.selectedSidebarItem = nil
            hasActivatedWorkspaceMode = true
            isWorkspacePanelPresented = false
            canvasWorkspaceViewModel.showLibrary()
#if os(macOS)
            dismissToolbarSearch()
#endif
        }
        .task(id: viewModel.workspaceContext) {
            if let context = viewModel.workspaceContext { viewModel.workspaceDockState.context = context }
        }
        .task(id: viewModel.selectedChatStorageID) {
            viewModel.connectWorkspaceBrowserForSelectedChat()
        }
        .onChange(of: viewModel.browserPresentationRequest) { _, request in
            if request != nil { openWorkspacePanel(mode: .webBrowser) }
        }
        .onDisappear {
            viewModel.stopWorkspaceBrowsers()
            viewModel.workspaceDockStore.terminateAll()
            for terminal in viewModel.terminalSessions.values { terminal.terminate() }
        }
        .task(id: canvasResolutionKey) {
            guard isCanvasWorkspaceSelected else {
                return
            }
            await canvasWorkspaceViewModel.resolve(
                workspaceID: viewModel.activeCanvasWorkspaceID,
                projectID: viewModel.activeCanvasProjectID,
                projectName: viewModel.workspaceContext?.projectName,
                force: true
            )
        }
    }
}

#Preview {
    MainView(
        endpoint: .direct(baseURL: .debugURL),
        settings: ClientSettings(),
        connectionMonitor: ConnectionMonitor(baseURL: .debugURL),
        onOpenSettings: { _ in },
        onOpenWorkspace: {}
    )
#if os(macOS)
    .frame(width: 1024, height: 600)
#endif
}
