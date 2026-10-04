import Foundation
import Testing

@Suite("Project context menu source")
struct ProjectContextMenuSourceTests {
    private func source(_ path: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("project menu matches the desktop project actions")
    func projectMenuActions() throws {
        let menu = try source("Sources/SloppyClient/Navigation/Shared/ProjectContextMenu.swift")

        #expect(menu.contains("project.isFavorite ? \"Unpin\" : \"Pin\""))
        #expect(menu.contains("Label(\"Edit\", systemImage: \"pencil\")"))
        #expect(menu.contains("Label(\"Reveal in Finder\", systemImage: \"folder\")"))
        #expect(menu.contains("Label(\"Create permanent worktree\""))
        #expect(menu.contains("hasVisibleChats ? \"Archive chats\" : \"Unarchive chats\""))
        #expect(menu.contains("Label(\"Remove project\", systemImage: \"xmark\")"))
        #expect(menu.contains("Button(role: .destructive)"))
        #expect(menu.contains(".confirmationDialog("))
    }

    @Test("both sidebar layouts reuse the same project menu")
    func bothSidebarLayoutsReuseMenu() throws {
        let cards = try source("Sources/SloppyClient/Navigation/Shared/SidebarCards.swift")
        let list = try source("Sources/SloppyClient/Navigation/Shared/SidebarRecentsList.swift")

        #expect(cards.contains(".projectContextMenu(viewModel: viewModel, project: group.project)"))
        #expect(list.contains(".projectContextMenu(viewModel: viewModel, project: group.project)"))
        #expect(list.contains("sessions: visibleSessions"))
    }
}
