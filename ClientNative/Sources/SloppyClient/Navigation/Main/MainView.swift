import Foundation
import SwiftUI
import Observation
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

#if canImport(UIKit)
typealias MobileTabsSnapshotImage = UIImage
#elseif canImport(AppKit)
typealias MobileTabsSnapshotImage = NSImage

struct ToggleWorkspaceTerminalAction {
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        perform()
    }
}

extension FocusedValues {
    @Entry var toggleWorkspaceTerminal: ToggleWorkspaceTerminalAction?
}
#endif

@MainActor
struct MainView: View {
    struct MobileTabsHeroOverlayState {
        var tabID: WorkspaceTab.ID
        var frame: CGRect
        var opacity: Double
        var cornerRadius: CGFloat
    }


#if os(macOS)
    enum ToolbarSearchResult: Identifiable {
        case chat(ChatSessionSummary)
        case project(APIProjectRecord)

        var id: String {
            switch self {
            case .chat(let session):
                "chat:\(session.storageID)"
            case .project(let project):
                "project:\(project.storageID)"
            }
        }
    }

    struct ToolbarSearchResultRow: View {
        let title: String
        let subtitle: String
        let systemImage: String
        let isSelected: Bool
        let onHover: @MainActor () -> Void
        let action: @MainActor () -> Void

        @State var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(title)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isSelected
                            ? Color.accentColor.opacity(0.18)
                            : isHovered ? Color.primary.opacity(0.08) : .clear
                        )
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .onHover {
                isHovered = $0
                if $0 {
                    onHover()
                }
            }
        }
    }
#endif

    let rootSafeAreaInsets: EdgeInsets
    let menuBarQuickActionRequest: MenuBarQuickActionRequest?
    let onConsumeMenuBarQuickAction: @MainActor (MenuBarQuickActionRequest) -> Void
    let deepLinkRequest: AppDeepLinkRequest?
    let onConsumeDeepLink: @MainActor (AppDeepLinkRequest) -> Void
    let approvalRequiredSessionIDs: Set<String>

    @State var viewModel: MainViewModel
    @State var mobileTabPagingDirection = 1
    @State var mobileTabsHeroOverlay: MobileTabsHeroOverlayState?
    @State var mobileTabsSnapshotImage: MobileTabsSnapshotImage?
    @State var mobileTabsSnapshotCache: [WorkspaceTab.ID: MobileTabsSnapshotImage] = [:]
    @State var mobileTabsHiddenSourceTabID: WorkspaceTab.ID?
    @State var mobileTabsHiddenThumbnailTabID: WorkspaceTab.ID?
    @State var mobileTabsContentFrame: CGRect = .zero
    @State var mobileTabsThumbnailFrames: [WorkspaceTab.ID: CGRect] = [:]
    @State var mobileTabsOverviewProgress: CGFloat = 0
    @State var isMobileTabsOverviewGestureActive = false
    var isWorkspacePanelPresented: Bool {
        get { viewModel.workspaceDockState.isPresented }
        nonmutating set { viewModel.workspaceDockState.isPresented = newValue }
    }
    @State var toolbarSearchText = ""
    @State var isToolbarSearchResultsPresented = false
    @State var showsApprovalRequiredChatsOnly = false
    @State var canvasWorkspaceViewModel: CanvasWorkspaceViewModel
    @State var hasActivatedWorkspaceMode = false
    @SceneStorage("sloppy.main-content-mode") var mainContentModeRawValue = MainContentMode.coding.rawValue
#if os(macOS)
    @State var toolbarSearchSelectionID: ToolbarSearchResult.ID?
    @FocusState var isToolbarSearchFocused: Bool
#endif

    let mobileTabsHeroThumbnailCornerRadius: CGFloat = 20
    let mobileTabsHeroDuration: Double = 0.42
    let mobileTabsHeroFadeDuration: Double = 0.14
    let mobileTabsOverviewCommitThreshold: CGFloat = 0.35
    let mobileTabsOverviewVelocityThreshold: CGFloat = 120

    @Environment(\.userInterfaceIdiom) var idiom
    @Environment(\.scenePhase) var attentionScenePhase
    @Environment(\.theme) var theme
    @Environment(\.displayScale) var displayScale

    var activeDesktopTab: WorkspaceTab? {
        guard let selectedTabID = viewModel.selectedTabID else {
            return nil
        }
        return viewModel.tabs.first(where: { $0.id == selectedTabID })
    }

    var activeChatViewModel: ChatScreenViewModel? {
        guard let selectedTabID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedTabID }),
              let tabState = viewModel.tabStates[selectedTabID] else {
            return nil
        }

        if tab.kind == .chat {
            return tabState.chatState?.viewModel
        }
        if tab.kind == .projectKanban,
           let projectState = tabState.projectKanbanState,
           projectState.selectedSection == .chats {
            return projectState.chatViewModel
        }
        return nil
    }

    init(
        endpoint: SloppyInstanceEndpoint,
        settings: ClientSettings,
        connectionMonitor: ConnectionMonitor,
        rootSafeAreaInsets: EdgeInsets = EdgeInsets(),
        onOpenSettings: @Sendable @escaping @MainActor (ClientSettingsDestination) -> Void,
        onOpenWorkspace: @escaping @MainActor () -> Void,
        menuBarQuickActionRequest: MenuBarQuickActionRequest? = nil,
        onConsumeMenuBarQuickAction: @escaping @MainActor (MenuBarQuickActionRequest) -> Void = { _ in },
        deepLinkRequest: AppDeepLinkRequest? = nil,
        onConsumeDeepLink: @escaping @MainActor (AppDeepLinkRequest) -> Void = { _ in },
        approvalRequiredSessionIDs: Set<String> = []
    ) {
        self.rootSafeAreaInsets = rootSafeAreaInsets
        self.menuBarQuickActionRequest = menuBarQuickActionRequest
        self.onConsumeMenuBarQuickAction = onConsumeMenuBarQuickAction
        self.deepLinkRequest = deepLinkRequest
        self.onConsumeDeepLink = onConsumeDeepLink
        self.approvalRequiredSessionIDs = approvalRequiredSessionIDs
        _canvasWorkspaceViewModel = State(
            initialValue: CanvasWorkspaceViewModel(
                baseURL: endpoint.coordinatorBaseURL,
                apiClient: SloppyAPIClient(endpoint: endpoint)
            )
        )
        _viewModel = State(
            initialValue: MainViewModel(
                endpoint: endpoint,
                settings: settings,
                connectionMonitor: connectionMonitor,
                onOpenSettings: onOpenSettings,
                onOpenWorkspace: onOpenWorkspace
            )
        )
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
