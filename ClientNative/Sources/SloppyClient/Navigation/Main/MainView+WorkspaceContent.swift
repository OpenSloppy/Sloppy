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
    var workspaceArea: some View {
        ZStack(alignment: .top) {
#if os(visionOS)
            workspaceContentHost(showsFloatingTabChrome: true)
#elseif os(macOS)
            VStack(spacing: 0) {
                if viewModel.tabs.count > 1 {
                    DesktopWorkspaceTabStrip(viewModel: viewModel)
                }
                workspaceContentHost(showsFloatingTabChrome: false)
            }
#else
            if idiom == .phone {
                phoneWorkspaceContentHost(showsFloatingTabChrome: false)
            } else {
                workspaceContentHost(showsFloatingTabChrome: false)
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(anchor: .bottom) {
#if !os(iOS)
            if let activeChatViewModel {
                ChatComposerOverlay(
                    viewModel: activeChatViewModel,
                    contentWidth: {
#if os(macOS)
                        ChatComposerView.desktopPanelWidth
#else
                        ChatComposerView.panelWidth
#endif
                    }(),
                    composerBottomInset: {
#if os(macOS)
                        24
#else
                        theme.spacing.s
#endif
                    }(),
                    tabs: viewModel.tabs,
                    tabActions: idiom == .phone
                    ? ChatComposerTabActions(
                        tabProgress: { progress in updatePagerPosition(progress) },
                        showOverview: { presentMobileTabsOverviewAnimated() },
                        beginOverviewGesture: { beginMobileTabsOverviewGesture() },
                        updateOverviewGesture: { progress in
                            updateMobileTabsOverviewGesture(progress: progress)
                        },
                        endOverviewGesture: { progress, velocity in
                            endMobileTabsOverviewGesture(progress: progress, upwardVelocity: velocity)
                        },
                        createTab: { createMobileTabAnimated() }
                    )
                    : nil
                )
                .opacity(shouldHidePhoneComposer ? 0.0 : 1.0)
                .allowsHitTesting(!viewModel.isMobileTabsOverviewPresented)
            }
#endif
        }
    }

    @ViewBuilder
    func phoneWorkspaceContentHost(showsFloatingTabChrome: Bool) -> some View {
        if let activeDesktopTab {
            desktopTabContent(for: activeDesktopTab)
                .id(activeDesktopTab.id)
                .opacity(shouldHidePhoneContent(for: activeDesktopTab.id) ? 0.0 : 1.0)
                .allowsHitTesting(!shouldHidePhoneContent(for: activeDesktopTab.id))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            mobileTabsContentFrame = proxy.frame(in: .global)
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, newValue in
                            mobileTabsContentFrame = newValue
                        }
                }
            }
            .background(phoneWorkspaceBackground.opacity(shouldHidePhoneBackground ? 0.0 : 1.0))
        } else {
            DesktopTabsEmptyState()
        }
    }

    @ViewBuilder
    func workspaceContentHost(showsFloatingTabChrome: Bool) -> some View {
        if let desktopSplitState = viewModel.desktopSplitState,
           let primaryTab = viewModel.tabs.first(where: { $0.id == desktopSplitState.primaryTabID }),
           let secondaryTab = viewModel.tabs.first(where: { $0.id == desktopSplitState.secondaryTabID }) {
            DesktopSplitContentView(
                fraction: desktopSplitState.fraction,
                onFractionChange: viewModel.updateDesktopSplitFraction(_:),
                onClearSplit: viewModel.clearDesktopSplit,
                primary: { desktopTabContent(for: primaryTab) },
                secondary: { desktopTabContent(for: secondaryTab) }
            )
        } else if let activeDesktopTab {
            mountedDesktopTabContent(activeTabID: activeDesktopTab.id)
        } else {
            DesktopTabsEmptyState()
        }
    }

    func mountedDesktopTabContent(activeTabID: WorkspaceTab.ID) -> some View {
        ZStack {
            ForEach(viewModel.tabs) { tab in
                desktopTabContent(for: tab)
                    .opacity(tab.id == activeTabID ? 1.0 : 0.0)
                    .allowsHitTesting(tab.id == activeTabID)
                    .accessibilityHidden(tab.id != activeTabID)
            }
        }
    }

    @ViewBuilder
    func desktopTabContent(for tab: WorkspaceTab) -> some View {
        if let content = cachedContent(for: tab) {
            content
                .environment(\.canvasWorkspaceToolbarEnabled, tab.id == viewModel.selectedTabID && !isCanvasWorkspaceSelected)
        } else {
            DesktopTabPlaceholderView(
                title: tab.title,
                detail: "Tab state is unavailable."
            )
        }
    }

    func cachedContent(for tab: WorkspaceTab) -> AnyView? {
        guard let tabState = viewModel.tabStates[tab.id] else {
            return nil
        }

        if let content = tabState.content {
            return content
        }

        let content = makeDesktopTabContent(for: tab, tabState: tabState)
        tabState.content = content
        return content
    }

    func uncachedContent(for tab: WorkspaceTab) -> AnyView? {
        guard let tabState = viewModel.tabStates[tab.id] else {
            return nil
        }
        return makeDesktopTabContent(for: tab, tabState: tabState)
    }

    func makeDesktopTabContent(for tab: WorkspaceTab, tabState: WorkspaceTabState) -> AnyView {
        switch tab.kind {
        case .chat:
            guard let chatState = tabState.chatState else {
                return placeholderContent(
                    title: tab.title,
                    detail: "Chat tab state is unavailable."
                )
            }
            let openSidebar: (@MainActor @Sendable () -> Void)? = idiom == .phone
            ? { @MainActor @Sendable in viewModel.openMobileSidebar() }
            : nil
            return AnyView(
                ChatScreen(
                    viewModel: chatState.viewModel,
                    rootSafeAreaInsets: rootSafeAreaInsets,
                    onOpenSidebar: openSidebar,
                    showsContextToolbar: false,
                    showsNavigationToolbar: idiom == .phone,
                    onAskInSideChat: askInSideChat
                )
                .id(ObjectIdentifier(chatState.viewModel))
                .onChange(of: chatState.viewModel.selectedSessionId) { _, _ in
                    viewModel.synchronizeChatTab(tab.id)
                }
            )
        case .projectKanban:
            guard let kanbanState = tabState.projectKanbanState,
                  case .projectKanban(let context) = tab.payload else {
                return placeholderContent(
                    title: tab.title,
                    detail: "Kanban tab state is unavailable."
                )
            }
            let project = viewModel.project(for: tab.id, localProjectID: context.projectId)
            ?? APIProjectRecord(
                id: context.projectId,
                name: context.projectName,
                directoryPaths: context.projectRootPath.map { [$0] } ?? []
            )
            return AnyView(
                ProjectModeView(
                    project: project,
                    state: kanbanState,
                    rootSafeAreaInsets: rootSafeAreaInsets,
                    onSelectSection: { section in
                        viewModel.selectProjectModeSection(section, project: project)
                    },
                    onOpenTask: { card in
                        let task = APIProjectTask(
                            id: card.id,
                            title: card.title,
                            status: card.status,
                            priority: card.priority,
                            actorId: card.actorID
                        )
                        viewModel.openTaskDetailTab(
                            project: project,
                            task: task,
                            fallbackAgentId: card.actorID
                        )
                    },
                    onOpenTaskChat: { task in
                        viewModel.openTaskChatTab(project: project, task: task, fallbackAgentId: task.actorId)
                    }
                )
            )
        case .taskDetail:
            guard let detailState = tabState.taskDetailState,
                  case .taskDetail(let context) = tab.payload else {
                return placeholderContent(
                    title: tab.title,
                    detail: "Task detail state is unavailable."
                )
            }
            return AnyView(
                TaskDetailView(
                    viewModel: detailState.viewModel,
                    projectId: context.projectId,
                    taskId: context.taskId,
                    onClose: {
                        let project = viewModel.project(for: tab.id, localProjectID: context.projectId)
                        ?? APIProjectRecord(
                            id: context.projectId,
                            name: context.projectName,
                            directoryPaths: context.projectRootPath.map { [$0] } ?? []
                        )
                        viewModel.openProjectKanbanTab(project: project)
                    },
                    onOpenChat: { task in
                        var project = viewModel.project(for: tab.id, localProjectID: context.projectId)
                        ?? APIProjectRecord(
                            id: context.projectId,
                            name: context.projectName,
                            tasks: [task]
                        )
                        project.tasks = [task]
                        viewModel.openTaskChatTab(
                            project: project,
                            task: task,
                            fallbackAgentId: context.fallbackAgentId
                        )
                    },
                    onOpenRelatedTask: { task in
                        let project = viewModel.project(for: tab.id, localProjectID: context.projectId)
                            ?? APIProjectRecord(id: context.projectId, name: context.projectName)
                        viewModel.openTaskDetailTab(project: project, task: task, fallbackAgentId: task.actorId)
                    },
                    onTaskChanged: {
                        await viewModel.loadProjects(force: true)
                        if let project = viewModel.project(for: tab.id, localProjectID: context.projectId),
                           let board = viewModel.projectModeStates[project.storageID] {
                            await board.viewModel.load(projectId: context.projectId)
                        }
                    }
                )
            )
        case .workspaceFiles:
            guard let workspaceState = tabState.workspaceFilesState,
                  case .workspaceFiles(let context) = tab.payload else {
                return placeholderContent(
                    title: tab.title,
                    detail: "Workspace tab state is unavailable."
                )
            }
            return AnyView(
                WorkspacePanelView(
                    viewModel: workspaceState.viewModel,
                    context: WorkspacePanelContext(projectId: context.projectId, projectName: context.projectName),
                    onOpenTerminal: { viewModel.toggleTerminalForSelectedTab() }
                )
            )
        }
    }

    func placeholderContent(title: String, detail: String) -> AnyView {
        AnyView(
            DesktopTabPlaceholderView(
                title: title,
                detail: detail
            )
        )
    }
}
