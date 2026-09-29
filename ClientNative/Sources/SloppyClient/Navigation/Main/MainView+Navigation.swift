import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyFeatureChat
import SloppyFeatureProjects
import SloppyFeatureSettings
import SloppyFeatureSites

@MainActor
extension MainView {
    @ViewBuilder
    var contentView: some View {
#if os(visionOS)
        if viewModel.isVisionTabsOverviewPresented {
            VisionWorkspaceTabsOverview(
                tabs: viewModel.tabs,
                selectedTabID: viewModel.selectedTabID,
                onSelect: { tabID in
                    viewModel.selectTab(tabID)
                    viewModel.dismissVisionTabsOverview()
                },
                onClose: { tabID in
                    viewModel.closeTab(tabID)
                },
                onCreate: {
                    viewModel.selectNewChat()
                },
                onDismiss: {
                    viewModel.dismissVisionTabsOverview()
                },
                previewContent: { tab in
                    desktopTabPreviewContent(for: tab)
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            navigationView
        }
#else
        navigationView
#endif
    }

    func handleMenuBarQuickAction(_ request: MenuBarQuickActionRequest?) {
        guard let request else { return }
        switch request.action {
        case .newChat:
            viewModel.selectNewChat()
        case .scheduledTasks:
            viewModel.selectScheduled()
        }
        onConsumeMenuBarQuickAction(request)
    }

    func handleDeepLink(_ request: AppDeepLinkRequest?) {
        guard let request else { return }

        switch request.deepLink {
        case .connect, .open:
            onConsumeDeepLink(request)
        case .proactivity:
            onConsumeDeepLink(request)
        case .project(let id):
            Task { @MainActor in
                await viewModel.loadProjects(force: true)
                if let project = viewModel.projects.first(where: { $0.id == id }) {
                    viewModel.selectProject(project)
                }
                onConsumeDeepLink(request)
            }
        case .task(let projectId, let taskId):
            Task { @MainActor in
                await viewModel.loadProjects(force: true)
                if let project = viewModel.projects.first(where: { $0.id == projectId }),
                   let task = project.tasks?.first(where: { $0.id == taskId }) {
                    viewModel.openTaskDetailTab(
                        project: project,
                        task: task,
                        fallbackAgentId: task.actorId
                    )
                }
                onConsumeDeepLink(request)
            }
        case .session(let agentId, let sessionId):
            Task { @MainActor in
                if let detail = try? await viewModel.apiClient.fetchAgentSession(
                    agentId: agentId,
                    sessionId: sessionId
                ) {
                    viewModel.openSessionChatTab(detail.summary)
                    viewModel.sessionDeepLinkNavigationSerial += 1
                }
                onConsumeDeepLink(request)
            }
        case .dictationToggle(let agentId, let sessionId):
            Task { @MainActor in
                if let detail = try? await viewModel.apiClient.fetchAgentSession(
                    agentId: agentId,
                    sessionId: sessionId
                ) {
                    viewModel.openSessionChatTab(detail.summary)
                    await Task.yield()
                    if let chatViewModel = activeChatViewModel {
                        switch chatViewModel.dictationPhase {
                        case .idle:
                            chatViewModel.startDictation()
                        case .recording:
                            chatViewModel.stopDictation()
                        case .transcribing:
                            break
                        }
                    }
                }
                onConsumeDeepLink(request)
            }
        }
    }

    var navigationView: some View {
        Group {
#if os(iOS)
        // `PlatformMainSidebar` owns the phone TabView and its NavigationStack.
        // Wrapping it in a second NavigationSplitView makes UIKit suppress the
        // inner stack's navigation bar on a real device (but not in Preview).
        sidebarView(isOverlay: false)
#else
        NavigationSplitView(columnVisibility: $viewModel.columnVisibility) {
            sidebarView(isOverlay: false)
                .navigationSplitViewColumnWidth(
                    min: viewModel.sidebarMinimumWidth,
                    ideal: viewModel.sidebarWidth,
                    max: viewModel.sidebarMaximumWidth
                )
                .navigationDestination(for: MainSidebarSelection.self) { _ in
                    contentArea()
                        .onAppear {
                            viewModel.dismissMobileSidebar()
                        }
                }
        } detail: {
            contentArea()
        }
        .navigationSplitViewStyle(.balanced)
#endif
        }
        .overlay {
            if idiom == .phone,
               viewModel.isMobileTabsOverviewPresented || mobileTabsHeroOverlay != nil || isMobileTabsOverviewGestureActive {
                GeometryReader { proxy in
                    let rootFrame = proxy.frame(in: .global)

                    ZStack {
                        if viewModel.isMobileTabsOverviewPresented || isMobileTabsOverviewGestureActive {
                            MobileWorkspaceTabsOverview(
                                tabs: viewModel.tabs,
                                selectedTabID: viewModel.selectedTabID,
                                snapshotCache: mobileTabsSnapshotCache,
                                hiddenThumbnailTabID: hiddenThumbnailTabIDForOverview,
                                appearanceProgress: mobileTabsOverviewAppearanceProgress,
                                onSelect: { tabID in
                                    Task {
                                        await handleMobileTabsOverviewSelection(tabID)
                                    }
                                },
                                onClose: { tabID in
                                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                        viewModel.closeTab(tabID)
                                    }
                                },
                                onCreate: {
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                        viewModel.selectNewChat()
                                        viewModel.dismissMobileTabsOverview()
                                    }
                                    clearMobileTabsHeroState()
                                },
                                onDismiss: {
                                    Task {
                                        await dismissMobileTabsOverviewAnimated()
                                    }
                                },
                                onThumbnailFramesChange: { frames in
                                    mobileTabsThumbnailFrames = frames
                                    if isMobileTabsOverviewGestureActive || mobileTabsOverviewProgress > 0 {
                                        syncMobileTabsOverviewHero()
                                    }
                                }
                            )
                            .allowsHitTesting(viewModel.isMobileTabsOverviewPresented && !isMobileTabsOverviewGestureActive)
                        }

                        mobileTabsHeroOverlayView(rootFrame: rootFrame)
                    }
                }
            }
        }
#if os(visionOS)
        .ornament(
            attachmentAnchor: .scene(.top),
            contentAlignment: .bottom,
            ornament: {
                VisionFloatingTabBarView(
                    viewModel: viewModel,
                    onOpenOverview: { viewModel.presentVisionTabsOverview() }
                )
                .padding(.bottom, 12)
            }
        )
#endif
    }

    @ViewBuilder
    func contentArea() -> some View {
        Group {
            if viewModel.selectedAppSection == .scheduled {
                ScheduledTasksScreen(apiClient: viewModel.apiClient)
            } else if viewModel.selectedAppSection == .agents {
                AgentsScreen(apiClient: viewModel.apiClient)
            } else if viewModel.selectedAppSection == .pullRequests {
                PullRequestsScreen(
                    apiClient: viewModel.apiClient,
                    onOpenChat: viewModel.openPullRequestChat,
                    onAddToSideChat: viewModel.addToSideChat,
                    onResolveOpenIssues: viewModel.startInSideChat
                )
            } else if viewModel.selectedAppSection == .sites {
                SitesScreen(
                    apiClient: viewModel.apiClient,
                    onCreate: viewModel.createSiteFromChat
                )
            } else if viewModel.selectedAppSection == .artifacts {
                ArtifactsScreen(
                    apiClient: viewModel.apiClient,
                    cacheStore: viewModel.cacheStore,
                    sessions: viewModel.chatViewModel.sessionCatalog,
                    onOpenSession: viewModel.openSessionChatTab
                )
            } else {
                mainModeContent
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 940)
#if os(macOS)
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                workspaceBottomPanelOverlay(
                    maximumHeight: max(120, proxy.size.height - 120)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
#endif
    }

    var mainModeContent: some View {
        ZStack {
            workspaceArea
                .opacity(isCanvasWorkspaceSelected ? 0.0 : 1.0)
                .allowsHitTesting(!isCanvasWorkspaceSelected)
                .accessibilityHidden(isCanvasWorkspaceSelected)

            if hasActivatedWorkspaceMode {
                CanvasWorkspaceSurface(viewModel: canvasWorkspaceViewModel)
                    .environment(\.canvasWorkspaceToolbarEnabled, isCanvasWorkspaceSelected)
                    .opacity(isCanvasWorkspaceSelected ? 1.0 : 0.0)
                    .allowsHitTesting(isCanvasWorkspaceSelected)
                    .accessibilityHidden(!isCanvasWorkspaceSelected)
            }
        }
    }

    var canvasResolutionKey: String {
        [
            viewModel.selectedAppSection.rawValue,
            viewModel.activeCanvasWorkspaceID ?? "-",
            viewModel.activeCanvasProjectID ?? "-"
        ].joined(separator: "|")
    }

    var isCanvasWorkspaceSelected: Bool {
        viewModel.selectedAppSection == .workspace
    }

    func returnToCanvasWorkspaceLibrary() {
        canvasWorkspaceViewModel.showLibrary()
        Task {
            await canvasWorkspaceViewModel.refreshLibrary()
        }
    }
}
