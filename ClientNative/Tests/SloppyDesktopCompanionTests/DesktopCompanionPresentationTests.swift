import Foundation
import Testing
import SloppyClientCore
@testable import SloppyDesktopCompanion

@Suite("Desktop companion presentation")
@MainActor
struct DesktopCompanionPresentationTests {
    private func makeModel() throws -> DesktopCompanionModel {
        let defaults = try #require(UserDefaults(suiteName: "DesktopCompanionPresentationTests.\(UUID().uuidString)"))
        return DesktopCompanionModel(defaults: defaults)
    }

    @Test func emptyComposerDoesNotInventResponseOrShowHistory() throws {
        let model = try makeModel()
        model.expanded = true
        #expect(model.responseText == nil)
        #expect(!model.showsResponsePanel)
        #expect(!model.showHistory)
    }

    @Test func restoredHistoryDoesNotPresentYesterdayAnswer() throws {
        let model = try makeModel()
        let history: [ChatMessage] = [
            .init(role: .user, segments: [.init(kind: .text, text: "Yesterday's question")]),
            .init(role: .assistant, segments: [.init(kind: .text, text: "Yesterday's answer")]),
        ]
        model.messages = history
        model.resetResponsePresentation()
        // A subsequent refresh of the restored chat must keep the old answer hidden.
        model.messages = history
        #expect(model.responseText == nil && !model.showsResponsePanel)
        #expect(model.messages.count == 2)
        model.showHistory = true
        #expect(model.showsResponsePanel)
    }

    @Test func freshAnswerAppearsAfterRestoringHistory() throws {
        let model = try makeModel()
        model.messages = [.init(role: .assistant, segments: [.init(kind: .text, text: "Old answer")])]
        model.resetResponsePresentation()
        model.didSubmitPrompt("New question")
        model.isWorking = false
        #expect(model.responseText == "New question")
        model.messages.append(.init(role: .assistant, segments: [.init(kind: .text, text: "New answer")]))
        #expect(model.responseText == "New answer" && model.showsResponsePanel)
    }

    @Test func closingResponseHidesPanelAndPreservesHistory() throws {
        let model = try makeModel()
        let answer = ChatMessage(role: .assistant, segments: [.init(kind: .text, text: "Answer")])
        model.messages = [answer]
        var layoutChanged = false
        model.onLayoutChanged = { layoutChanged = true }
        model.dismissResponse()
        // A refresh with the same history must not reopen the dismissed panel.
        model.messages = [answer]
        #expect(!model.showsResponsePanel && !model.panelLayout.showsResponse)
        #expect(model.messages.count == 1 && model.responseText == "Answer")
        #expect(layoutChanged)
        #expect(model.panelVisible)
    }

    @Test func nextSubmissionReopensDismissedResponse() throws {
        let model = try makeModel()
        model.didSubmitPrompt("First request")
        model.dismissResponse()
        #expect(!model.showsResponsePanel)
        #expect(model.isWorking && model.canStop)
        model.didSubmitPrompt("Next request")
        #expect(model.showsResponsePanel)
        #expect(model.responseText == "Next request")
    }

    @Test func historyCanBeReopenedAndClosedAfterDismissingResponse() throws {
        let model = try makeModel()
        model.messages = [.init(role: .assistant, segments: [.init(kind: .text, text: "Answer")])]
        model.dismissResponse()
        model.showHistory = true
        #expect(model.showsResponseContent && model.showsResponsePanel)
        model.dismissResponse()
        #expect(!model.showHistory && !model.showsResponsePanel)
    }

    @Test func closingResponseKeepsErrorsVisible() throws {
        let model = try makeModel()
        model.didSubmitPrompt("Request")
        model.error = "Connection lost"
        model.dismissResponse()
        #expect(!model.showsResponseContent && model.showsResponsePanel)
        #expect(model.error == "Connection lost" && model.isWorking)
    }

    @Test func acknowledgedSubmissionShowsCurrentPromptBeforeHistoryRefresh() throws {
        let model = try makeModel()
        model.messages = [.init(role: .assistant, segments: [.init(kind: .text, text: "Previous answer")])]
        model.draft = "New request"
        model.expanded = true
        var notified = false
        model.onMessageSubmitted = { notified = true; model.expanded = false }
        model.didSubmitPrompt("New request")
        #expect(notified && !model.expanded)
        #expect(model.draft.isEmpty)
        #expect(model.responseText == "New request")
        #expect(model.showsResponsePanel && model.canStop)
    }

    @Test func completionShowsLatestAnswerAndIgnoresSystemText() throws {
        let model = try makeModel()
        model.didSubmitPrompt("Question")
        model.messages = [
            .init(role: .user, segments: [.init(kind: .text, text: "Question")]),
            .init(role: .assistant, segments: [.init(kind: .text, text: "Answer")]),
            .init(role: .system, segments: [.init(kind: .text, text: "Internal details")]),
        ]
        model.isWorking = false
        #expect(model.responseText == "Answer")
        #expect(!model.canStop)
    }

    @Test func draftAndAssistantWordingDoNotClassifyRunState() throws {
        let model = try makeModel()
        model.messages = [.init(role: .assistant, segments: [.init(kind: .text, text: "Thinking…")])]
        model.draft = "Unsent draft"
        #expect(model.responseText == "Thinking…")
        #expect(!model.canStop)
        model.isSending = true
        #expect(model.responseText == "Unsent draft")
    }

    @Test func failedSubmissionKeepsComposerAndDraft() async throws {
        let model = try makeModel()
        model.expanded = true
        model.draft = "Keep this"
        var notified = false
        model.onMessageSubmitted = { notified = true }
        await model.send()
        #expect(!notified)
        #expect(model.expanded && model.draft == "Keep this")
    }

    @Test func successfulSubmissionClearsTheDraftAfterTheFieldEditorCommitsOnCollapse() throws {
        let model = try makeModel()
        model.draft = "Hello"
        model.onMessageSubmitted = { model.draft = "Hello" }
        model.didSubmitPrompt("Hello")
        #expect(model.draft.isEmpty)
        #expect(model.lastSubmittedPrompt == "Hello")
    }

    @Test func voiceSubmissionAlsoClearsAnExistingComposerDraft() throws {
        let model = try makeModel()
        model.draft = "Previous draft"
        model.didSubmitPrompt("Spoken request")
        #expect(model.draft.isEmpty)
        #expect(model.responseText == "Spoken request")
    }

    @Test func orbStaysAnchoredWhenComposerWrapsAndResponseGrows() {
        let anchor = CGPoint(x: -850, y: 150)
        let screen = CGRect(x: -1920, y: -500, width: 1920, height: 1600)
        let layouts = [
            DesktopCompanionLayout(expanded: false, showsResponse: false, composerHeight: 44, responseHeight: 56),
            .init(expanded: true, showsResponse: false, composerHeight: 44, responseHeight: 56),
            .init(expanded: true, showsResponse: false, composerHeight: 100, responseHeight: 56),
            .init(expanded: false, showsResponse: true, composerHeight: 100, responseHeight: 240),
            .init(expanded: true, showsResponse: true, composerHeight: 100, responseHeight: 240),
        ]
        for layout in layouts {
            let frame = DesktopPointerGeometry.panelFrame(anchor: anchor, size: layout.size,
                                                         visibleFrame: screen, orbOffset: layout.orbOffset)
            #expect(DesktopPointerGeometry.anchor(for: frame, orbOffset: layout.orbOffset) == anchor)
            #expect(screen.contains(frame))
        }
    }
}
