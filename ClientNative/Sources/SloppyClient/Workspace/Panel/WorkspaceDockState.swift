import Foundation
import Observation
import SloppyClientCore
import SloppyFeatureChat

/// UI state belongs to a project (and server), not to the panel's visibility.
@Observable
@MainActor
final class WorkspaceDockState {
    var isPresented = false
    var preferredWidth: CGFloat = 480
    private(set) var tabs: [WorkspaceDockTab] = []
    var selectedID: UUID?
    var context: WorkspacePanelContext?

    init(context: WorkspacePanelContext? = nil) {
        self.context = context
    }

    var selectedTab: WorkspaceDockTab? { tabs.first { $0.id == selectedID } }

    @discardableResult
    func open(_ kind: WorkspaceSidePanelItem, browser: WorkspaceWebViewModel? = nil) -> WorkspaceDockTab {
        if let browser, let tab = tabs.first(where: { $0.browser === browser }) {
            select(tab)
            return tab
        }
        if kind == .files || kind == .review, let tab = tabs.first(where: { $0.kind == kind && $0.sourceFile == nil }) {
            select(tab)
            return tab
        }
        let number = (tabs.filter { $0.kind == kind }.map(\.number).max() ?? 0) + 1
        let tab = WorkspaceDockTab(kind: kind, number: number, browser: browser)
        tabs.append(tab)
        select(tab)
        return tab
    }

    @discardableResult
    func openSourceFile(_ reference: SourceFileReference, apiClient: SloppyAPIClient,
                        scope: WorkspaceSourceFileViewModel.Scope) -> WorkspaceDockTab {
        if let tab = tabs.first(where: {
            $0.sourceFile?.reference.path == reference.path && $0.sourceFile?.scope == scope
                && $0.sourceFile?.apiClient.endpoint == apiClient.endpoint
        }) {
            tab.sourceFile?.navigate(to: reference)
            select(tab)
            return tab
        }
        let number = (tabs.filter { $0.kind == .files }.map(\.number).max() ?? 0) + 1
        let tab = WorkspaceDockTab(kind: .files, number: number)
        tab.sourceFile = WorkspaceSourceFileViewModel(reference: reference, apiClient: apiClient, scope: scope)
        tabs.append(tab)
        select(tab)
        return tab
    }

    func select(_ tab: WorkspaceDockTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedID = tab.id
        isPresented = true
    }

    func toggleVisibility() { isPresented.toggle() }
    func hide() { isPresented = false }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index).terminal?.terminate()
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelectedTabOrHide() {
        if let selectedID {
            close(selectedID)
        } else {
            hide()
        }
    }

    static func visibleWidth(preferred: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = max(0, available - min(320, available * 0.45))
        return min(max(preferred, min(240, maximum)), maximum)
    }
}

@Observable
@MainActor
final class WorkspaceDockTab: Identifiable {
    let id = UUID()
    let kind: WorkspaceSidePanelItem
    let number: Int
    let browser: WorkspaceWebViewModel?
    var chat: ChatScreenViewModel?
    var terminal: WorkspaceTerminalSession?
    var panel: WorkspacePanelViewModel?
    var sourceFile: WorkspaceSourceFileViewModel?

    var systemImage: String { sourceFile == nil ? kind.systemImage : "chevron.left.forwardslash.chevron.right" }

    init(kind: WorkspaceSidePanelItem, number: Int, browser: WorkspaceWebViewModel? = nil) {
        self.kind = kind
        self.number = number
        self.browser = kind == .browser ? (browser ?? WorkspaceWebViewModel()) : nil
    }

    var title: String {
        if let sourceFile { return sourceFile.title }
        if let browser {
            if let title = browser.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return title
            }
            if let url = browser.currentURL, url.absoluteString != "about:blank" {
                return url.host ?? url.absoluteString
            }
            return "New tab"
        }
        return number == 1 ? kind.title : "\(kind.title) \(number)"
    }
}

@MainActor
final class WorkspaceDockStore {
    private var states: [String: WorkspaceDockState] = [:]

    func state(server: String, projectID: String?, fallbackID: String, context: WorkspacePanelContext?) -> WorkspaceDockState {
        let key = "\(server)|\(projectID.map { "project:\($0)" } ?? "tab:\(fallbackID)")"
        if let state = states[key] { return state }
        let state = WorkspaceDockState(context: context)
        states[key] = state
        return state
    }

    func terminateAll() {
        for state in states.values {
            for tab in state.tabs { tab.terminal?.terminate() }
        }
    }
}
