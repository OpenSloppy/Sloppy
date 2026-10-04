import Foundation
import Testing

@Suite("Workspace terminal drawer source")
struct WorkspaceTerminalDrawerSourceTests {
    private func source(_ path: String...) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = path.reduce(packageRoot) { $0.appendingPathComponent($1) }
        return try mainViewAwareSourceContents(at: url)
    }

    @Test("main view registers cmd j and mounts the bottom panel in the detail column")
    func mainViewRegistersCmdJAndMountsDetailBottomPanel() throws {
        let app = try source("Sources", "SloppyClient", "App", "SloppyClientApp.swift")
        let mainView = try source("Sources", "SloppyClient", "Navigation", "Main", "MainView.swift")

        #expect(app.contains("@FocusedValue(\\.toggleWorkspaceTerminal)"))
        #expect(!app.contains(".keyboardShortcut(\"j\", modifiers: [.command])"))
        #expect(mainView.contains(".keyboardShortcut(\"j\", modifiers: [.command])"))
        #expect(mainView.contains(".focusedSceneValue("))
        #expect(mainView.contains("viewModel.toggleTerminalForSelectedTab()"))
        #expect(mainView.contains("func workspaceBottomPanelOverlay(maximumHeight: CGFloat)"))
        #expect(mainView.contains(".overlay(alignment: .bottom)"))
        #expect(mainView.contains("WorkspaceBottomPanelDrawerView"))
        #expect(mainView.contains("workspaceBottomPanelOverlay("))
        #expect(mainView.contains("func contentArea()"))
    }

    @Test("bottom panel has an observable drag resize handle and panel picker")
    func bottomPanelHasObservableResizeHandleAndPicker() throws {
        let drawer = try source("Sources", "SloppyClient", "Workspace", "Terminal", "WorkspaceTerminalDrawerView.swift")
        let state = try source("Sources", "SloppyClient", "Navigation", "Main", "MainTabs.swift")

        #expect(drawer.contains("struct WorkspaceBottomPanelDrawerView"))
        #expect(drawer.contains("DragGesture"))
        #expect(drawer.contains("let startHeight = dragStartHeight ?? height"))
        #expect(drawer.contains("startHeight - value.translation.height"))
        #expect(drawer.contains("dragStartHeight = nil"))
        #expect(drawer.contains("ForEach(WorkspaceBottomPanelKind.allCases)"))
        #expect(drawer.contains("NSCursor.resizeUpDown"))
        #expect(state.contains("@Observable\n@MainActor\nfinal class WorkspaceTerminalState"))
        #expect(state.contains("var selectedPanel: WorkspaceBottomPanelKind"))
    }
}
