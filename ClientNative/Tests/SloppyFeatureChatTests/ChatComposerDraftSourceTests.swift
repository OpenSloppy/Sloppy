import Foundation
import Testing

@Suite("Chat composer draft source")
struct ChatComposerDraftSourceTests {
    private var viewModelSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    @Test("view model stores composer drafts per active session or draft context")
    func viewModelStoresComposerDraftsPerActiveSessionOrDraftContext() throws {
        let source = try viewModelSource

        #expect(source.contains("private var composerDraftsByKey: [String: StoredComposerDraft] = [:]"))
        #expect(source.contains("composerAttachments = storedDraft?.attachments ?? []"))
        #expect(source.contains("private var activeComposerDraftKey: String?"))
        #expect(source.contains("private func syncComposerDraft("))
        #expect(source.contains("private func composerDraftKey("))
        #expect(source.contains("return \"session:\\(sessionId)\""))
        #expect(source.contains("return \"draft:\\(resolvedAgentId):\\(projectId ?? \"-\"):\\(taskId ?? \"-\")\""))
    }

    @Test("send message clears the active composer draft and requests focus")
    func sendMessageClearsActiveComposerDraftAndRequestsFocus() throws {
        let source = try viewModelSource
        let sendStart = try #require(source.range(of: "public func sendMessage(content: String)"))
        let sendEnd = try #require(source.range(of: "public func submitInputResponse("))
        let sendMethods = source[sendStart.lowerBound..<sendEnd.lowerBound]

        #expect(sendMethods.contains("clearActiveComposerDraft()"))
        #expect(sendMethods.contains("requestComposerFocus()"))
        #expect(!sendMethods.contains("dismissComposerFocus()"))
        #expect(source.contains("private func clearActiveComposerDraft()"))
        #expect(source.contains("composerDraft.text = \"\""))
        #expect(source.contains("composerAttachments = []"))
    }

    @Test("send failures restore the draft and expose the error")
    func sendFailuresRestoreTheDraftAndExposeTheError() throws {
        let source = try viewModelSource

        #expect(source.contains("public private(set) var sendErrorMessage: String?"))
        #expect(source.contains("Could not create session:"))
        #expect(source.contains("Message was not sent:"))
        #expect(source.contains("composerDraft.text = content"))
        #expect(source.contains("composerAttachments = attachments"))
        #expect(source.contains("let summary = try await apiClient.createAgentSession"))
    }
}
