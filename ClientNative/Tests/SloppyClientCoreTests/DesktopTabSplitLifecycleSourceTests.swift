import Foundation
import Testing

@Suite("Desktop tab split lifecycle source")
struct DesktopTabSplitLifecycleSourceTests {
    private func source(_ path: String...) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = path.reduce(packageRoot) { $0.appendingPathComponent($1) }
        return try mainViewAwareSourceContents(at: url)
    }

    @Test("main view model exposes temporary desktop split lifecycle")
    func mainViewModelExposesTemporaryDesktopSplitLifecycle() throws {
        let source = try source("Sources", "SloppyClient", "Navigation", "Main", "MainViewModel.swift")

        #expect(source.contains("var desktopSplitState: DesktopTabSplitState?"))
        #expect(source.contains("func beginDesktopSplit(source sourceTabID: WorkspaceTab.ID, target targetTabID: WorkspaceTab.ID)"))
        #expect(source.contains("func updateDesktopSplitFraction(_ fraction: CGFloat)"))
        #expect(source.contains("func clearDesktopSplit()"))
    }
}
