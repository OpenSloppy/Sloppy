import Foundation
import Testing

@Suite("Main sidebar project disclosure")
struct MainSidebarProjectDisclosureTests {
    private func source(named fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SloppyClient")
        let sourceURL = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )?
            .compactMap { $0 as? URL }
            .first(where: { $0.lastPathComponent == fileName })
        return try mainViewAwareSourceContents(at: #require(sourceURL))
    }

    @Test("project collapse state is separate from show more state")
    func projectCollapseStateIsSeparateFromShowMoreState() throws {
        let mainViewModelSource = try source(named: "MainViewModel.swift")
        let sidebarSource = try source(named: "SidebarRecentsList.swift")

        #expect(mainViewModelSource.contains("var collapsedProjectIds: Set<String> = []"))
        #expect(mainViewModelSource.contains("var expandedTaskLists: Set<String> = []"))
        #expect(mainViewModelSource.contains("func toggleProjectCollapse(projectId: String)"))
        #expect(mainViewModelSource.contains("func toggleTaskListExpansion(projectId: String)"))

        #expect(sidebarSource.contains("viewModel.collapsedProjectIds.contains(group.id)"))
        #expect(sidebarSource.contains("if !isCollapsed {"))
        #expect(sidebarSource.contains("viewModel.toggleTaskListExpansion(projectId: group.id)"))
        #expect(sidebarSource.contains("if !isCollapsed {"))
    }

    @Test("project rows open kanban tabs and task rows open task chats")
    func projectRowsOpenKanbanTabsAndTaskRowsOpenTaskChats() throws {
        let sidebarSource = try source(named: "SidebarRecentsList.swift")

        #expect(sidebarSource.contains("viewModel.openProjectKanbanTab(project: group.project)"))
    }

    @Test("main view renders a native project kanban tab")
    func mainViewRendersNativeProjectKanbanTab() throws {
        let mainViewSource = try source(named: "MainView.swift")
        let mainTabsSource = try source(named: "MainTabs.swift")
        let projectModeSource = try source(named: "ProjectModeView.swift")

        #expect(projectModeSource.contains("ProjectKanbanView("))
        #expect(mainViewSource.contains("case .projectKanban"))
        #expect(mainTabsSource.contains("ProjectKanbanTabState"))
    }

    @Test("kanban cards open task detail from the content area")
    func kanbanCardsOpenTaskDetailFromTheContentArea() throws {
        let mainViewSource = try source(named: "MainView.swift")
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let kanbanSource = try mainViewAwareSourceContents(at: packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureProjects")
                .appendingPathComponent("Screens")
                .appendingPathComponent("Projects")
                .appendingPathComponent("Kanban")
                .appendingPathComponent("ProjectKanbanView.swift"))

        #expect(kanbanSource.contains("let onOpenTask: @MainActor (ProjectKanbanCard) -> Void"))
        #expect(kanbanSource.contains("Button {"))
        #expect(kanbanSource.contains("onOpenTask(card)"))
        #expect(kanbanSource.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(kanbanSource.contains("ScrollView(.vertical)"))
        #expect(mainViewSource.contains("onOpenTask: { card in"))
        #expect(mainViewSource.contains("viewModel.openTaskDetailTab("))
    }
}
