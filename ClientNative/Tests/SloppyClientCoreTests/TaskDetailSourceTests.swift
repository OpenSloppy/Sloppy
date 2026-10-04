import Foundation
import Testing

@Suite("Task detail source")
struct TaskDetailSourceTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try mainViewAwareSourceContents(at: packageRoot.appendingPathComponent(relativePath))
    }

    @Test("task detail tab is modeled in main tabs and main view")
    func taskDetailTabIsModeledInMainTabsAndMainView() throws {
        let tabs = try source("Sources/SloppyClient/Navigation/Main/MainTabs.swift")
            + source("Sources/SloppyClientUI/Tabs.swift")
        let mainView = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")
        let mainViewModel = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")

        #expect(tabs.contains("struct TaskDetailTabContext: Hashable, Sendable"))
        #expect(tabs.contains("case taskDetail(TaskDetailTabContext)"))
        #expect(tabs.contains("final class TaskDetailTabState"))
        #expect(mainViewModel.contains("var tabStates: [WorkspaceTab.ID: WorkspaceTabState] = [:]"))
        #expect(mainViewModel.contains("WorkspaceTabState(contentState: .taskDetail(detailState))"))
        #expect(mainViewModel.contains("func makeTaskDetailTabState(endpoint: SloppyInstanceEndpoint? = nil) -> TaskDetailTabState"))
        #expect(mainView.contains("case .taskDetail:"))
        #expect(mainView.contains("TaskDetailView("))
    }

    @Test("task detail provides a visible close action that returns to the project")
    func taskDetailProvidesCloseAction() throws {
        let detailSource = try source("Sources/SloppyFeatureProjects/Screens/Projects/Views/TaskDetailView.swift")
        let mainViewSource = try source("Sources/SloppyClient/Navigation/Main/MainView.swift")

        #expect(detailSource.contains("let onClose: @MainActor () -> Void"))
        #expect(detailSource.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
        #expect(detailSource.contains(".keyboardShortcut(.cancelAction)"))
        #expect(detailSource.contains(".accessibilityLabel(\"Close task details\")"))
        #expect(mainViewSource.contains("onClose: {"))
        #expect(mainViewSource.contains("viewModel.openProjectKanbanTab(project: project)"))
    }
}
