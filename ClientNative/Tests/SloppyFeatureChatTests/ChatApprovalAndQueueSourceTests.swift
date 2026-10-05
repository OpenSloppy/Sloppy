import Foundation
import Testing

@Suite("Chat approval and queue source")
struct ChatApprovalAndQueueSourceTests {
    private func source(_ path: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    @Test("tool approval is compact and lives above the composer")
    func toolApprovalLivesAboveComposer() throws {
        let screen = try source("Sources/SloppyFeatureChat/Screens/Chat/ChatScreen.swift")
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")
        let root = try source("Sources/SloppyClient/Root/RootShellViewModel.swift")

        #expect(screen.contains("ChatToolApprovalCard("))
        #expect(screen.contains("accessibilityIdentifier(\"chat.tool-approval\")"))
        #expect(screen.contains("viewModel.resolvePendingToolApproval"))
        #expect(!overlay.contains("private func approvalContent"))
        #expect(root.contains("desktopOverlay.updateToolApproval(notification)\n            return"))
    }

    @Test("messages submitted during a run enter the local queue")
    func messagesEnterQueueDuringRun() throws {
        let model = try source("Sources/SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")
        let composer = try source("Sources/SloppyFeatureChat/Screens/Chat/Views/ChatComposerView.swift")

        #expect(model.contains("if willQueueMessage"))
        #expect(model.contains("await sendNextQueuedMessageIfIdle()"))
        #expect(!model.contains("queuedMessageInterruptRequested"))
        #expect(composer.contains("let hasMessage = !trimmedDraftText.isEmpty || !viewModel.composerAttachments.isEmpty"))
    }
}
