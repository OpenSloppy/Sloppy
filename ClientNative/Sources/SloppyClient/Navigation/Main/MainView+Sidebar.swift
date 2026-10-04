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
    func chatScreen(showsSidebarControl: Bool) -> some View {
        let openSidebar: (@MainActor @Sendable () -> Void)? = showsSidebarControl
        ? { @MainActor @Sendable in viewModel.openMobileSidebar() }
        : nil
        return ChatScreen(
            viewModel: viewModel.chatViewModel,
            rootSafeAreaInsets: rootSafeAreaInsets,
            onOpenSidebar: openSidebar,
            showsContextToolbar: false,
            onAskInSideChat: askInSideChat
        )
    }

    var sidebarComposerBackdropHeight: CGFloat? {
#if os(macOS)
        guard viewModel.selectedAppSection == .chats || viewModel.selectedAppSection == .projects,
              let activeChatViewModel else {
            return nil
        }
        return (activeChatViewModel.composerPanelHeight ?? ChatComposerView.panelHeight) + 24 + 40
#else
        return nil
#endif
    }

    func sidebarView(isOverlay: Bool) -> some View {
        MainSidebarView(
            viewModel: viewModel,
            isOverlay: isOverlay,
            composerBackdropHeight: sidebarComposerBackdropHeight,
            approvalRequiredSessionIDs: approvalRequiredSessionIDs,
            showsApprovalRequiredChatsOnly: showsApprovalRequiredChatsOnly,
            canvasWorkspaceViewModel: canvasWorkspaceViewModel,
            navigationDestination: { _ in
                AnyView(
                    contentArea()
                        .onAppear {
                            viewModel.dismissMobileSidebar()
                        }
                )
            }
        )
    }

    var workspaceSidePanel: some View {
        WorkspaceDockView(state: viewModel.workspaceDockState, onOpen: { selectWorkspaceSidePanelItem($0) }) { tab in
            workspaceScreen(tab)
        }
    }

    @ViewBuilder
    func workspaceScreen(_ tab: WorkspaceDockTab) -> some View {
        switch tab.kind {
        case .browser:
            if let browser = tab.browser {
                WorkspaceBrowserPanelView(
                    viewModel: browser,
                    onOpenTool: { selectWorkspaceSidePanelItem($0) },
                    allowsProjectTools: viewModel.workspaceDockState.context != nil
                )
            }
        case .terminal:
            if let session = tab.terminal {
#if os(macOS)
                if session.remoteConfiguration != nil {
                    WorkspaceRemoteTerminalMacHostView(session: session) { $0.focus() }
                } else {
                    WorkspaceTerminalMacHostView(session: session) { $0.focus() }
                }
#else
                Text("Terminal is available on macOS.")
#endif
            }
        case .review, .files:
            if let context = viewModel.workspaceDockState.context, let panel = tab.panel {
                WorkspacePanelView(viewModel: panel, context: context,
                                   onOpenTerminal: { viewModel.openWorkspaceDockTab(.terminal) })
            } else { WorkspaceUnavailableView() }
        case .sideChat:
            if let chat = tab.chat {
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        ChatScreen(viewModel: chat, showsContextToolbar: false, showsNavigationToolbar: false)
                        ChatComposerOverlay(viewModel: chat, contentWidth: geometry.size.width,
                                            composerBottomInset: theme.spacing.m, tabs: [], tabActions: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func mobileTabPreviewContent(for tab: WorkspaceTab) -> some View {
        desktopTabContent(for: tab)
            .allowsHitTesting(false)
            .clipped()
    }

#if os(visionOS)
    @ViewBuilder
    func desktopTabPreviewContent(for tab: WorkspaceTab) -> some View {
        mobileTabPreviewContent(for: tab)
    }
#endif
}
