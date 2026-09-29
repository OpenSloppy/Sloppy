import Foundation
import Testing
@testable import SloppyDesktopCompanion

@Suite("Desktop companion composer")
@MainActor
struct DesktopComposerTests {
    private func makeModel() -> DesktopCompanionModel {
        DesktopCompanionModel(defaults: UserDefaults(suiteName: "DesktopComposerTests.\(UUID().uuidString)")!)
    }

    @Test func emptyDraftOffersVoiceAndTextOffersSend() {
        let model = makeModel()
        model.draft = " \n\t"
        #expect(model.composerAction == .record)
        #expect(model.canPerformComposerAction)
        model.draft = "Explain this window"
        #expect(model.composerAction == .send)
        #expect(!model.canPerformComposerAction)
        model.isConnected = true
        #expect(model.canPerformComposerAction)
        model.draft = ""
        #expect(model.composerAction == .record)
    }

    @Test func recordingAndTranscriptionTakePriorityOverExistingText() {
        let model = makeModel()
        model.draft = "Existing text"
        model.isRecording = true
        #expect(model.composerAction == .finishRecording)
        #expect(model.canPerformComposerAction)
        model.isRecording = false
        model.isTranscribing = true
        #expect(model.composerAction == .transcribing)
        #expect(!model.canPerformComposerAction)
        model.isTranscribing = false
        model.isConnected = true
        #expect(model.composerAction == .send)
        #expect(model.canPerformComposerAction)
    }

    @Test func activeRunDisablesNewRecordingAndSending() {
        let model = makeModel()
        model.isConnected = true
        for draft in ["", "New request"] {
            model.draft = draft
            model.isWorking = true
            #expect(!model.canPerformComposerAction)
            model.isWorking = false
            model.isSending = true
            #expect(!model.canPerformComposerAction)
            model.isSending = false
            model.isStopping = true
            #expect(!model.canPerformComposerAction)
            model.isStopping = false
            #expect(model.canPerformComposerAction)
        }
    }

    @Test func disabledActionDoesNotChangeDraftOrStartRecording() async {
        let model = makeModel()
        model.draft = "Keep this draft"
        await model.performComposerAction()
        #expect(model.draft == "Keep this draft")
        #expect(!model.isRecording)
        #expect(model.error == nil)
    }

    @Test func successfulDesktopHandoffNotifiesPanelWithoutDiscardingWork() {
        let model = makeModel()
        model.draft = "Keep this draft"
        model.isWorking = true
        var openedURL: URL?
        var didOpen = false
        model.onDesktopOpened = { didOpen = true }
        let result = model.openDesktop(preferSession: true, openURL: { openedURL = $0; return true })
        #expect(result && didOpen)
        #expect(openedURL?.scheme == "sloppy")
        #expect(model.isWorking)
        #expect(model.draft == "Keep this draft")
    }

    @Test func failedDesktopHandoffKeepsPanelAvailable() {
        let model = makeModel()
        var didOpen = false
        model.onDesktopOpened = { didOpen = true }
        let result = model.openDesktop(openURL: { _ in false })
        #expect(!result && !didOpen)
        #expect(model.error != nil)
    }
}
