import SloppyClientCore
import SwiftUI

enum MainSidebarSelection: Hashable {
    case usage
    case agents
    case pullRequests
    case scheduled
    case attention
    case artifacts
    case sites
    case project(String)
    case task(projectId: String, taskId: String)
    case chats
}

@MainActor
struct MainSidebarView: View {
    static let expandedWidth: CGFloat = 348
    static let collapsedWidth: CGFloat = 150
    static let minimumWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 800
    static let rowMinimumHeight: CGFloat = 32

    let viewModel: MainViewModel
    let isOverlay: Bool
    var composerBackdropHeight: CGFloat? = nil
    var approvalRequiredSessionIDs: Set<String> = []
    var showsApprovalRequiredChatsOnly = false
    let canvasWorkspaceViewModel: CanvasWorkspaceViewModel
    var mobileComposer: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    let navigationDestination: @MainActor (MainSidebarSelection) -> AnyView

    var body: some View {
        #if os(iOS)
        PlatformMainSidebar(
            viewModel: viewModel,
            isOverlay: isOverlay,
            canvasWorkspaceViewModel: canvasWorkspaceViewModel,
            mobileComposer: mobileComposer,
            navigationDestination: navigationDestination
        )
        #elseif os(macOS)
        PlatformMainSidebar(
            viewModel: viewModel,
            isOverlay: isOverlay,
            composerBackdropHeight: composerBackdropHeight,
            approvalRequiredSessionIDs: approvalRequiredSessionIDs,
            showsApprovalRequiredChatsOnly: showsApprovalRequiredChatsOnly
        )
        #else
        PlatformMainSidebar(viewModel: viewModel, isOverlay: isOverlay)
        #endif
    }
}
