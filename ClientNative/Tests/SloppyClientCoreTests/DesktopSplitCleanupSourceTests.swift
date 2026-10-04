import Foundation
import Testing

@Suite("Desktop split cleanup source")
struct DesktopSplitCleanupSourceTests {
    private func source(_ path: String...) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = path.reduce(packageRoot) { $0.appendingPathComponent($1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("main view model clears temporary split when replacing selected tab content")
    func mainViewModelClearsTemporarySplitWhenReplacingSelectedTabContent() throws {
        let source = try source("Sources", "SloppyClient", "Navigation", "Main", "MainViewModel.swift")

        #expect(source.contains("private func showInSelectedTab("))
        #expect(source.contains("clearDesktopSplit()"))
    }
}
