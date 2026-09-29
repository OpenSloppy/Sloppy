import Foundation
import Testing
@testable import SloppyDesktopCompanion

@Suite("Companion update configuration")
@MainActor
struct CompanionUpdateTests {
    private let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func signedHTTPSFeedIsRequired() {
        let feed = "https://github.com/TeamSloppy/Sloppy/releases/latest/download/companion-appcast.xml"
        #expect(CompanionUpdateController.validConfiguration(["SUFeedURL": feed, "SUPublicEDKey": publicKey]))
        #expect(!CompanionUpdateController.validConfiguration(["SUFeedURL": "http://example.com/feed.xml", "SUPublicEDKey": publicKey]))
        #expect(!CompanionUpdateController.validConfiguration(["SUFeedURL": feed, "SUPublicEDKey": "not-a-key"]))
        #expect(!CompanionUpdateController.validConfiguration(["SUFeedURL": feed, "SUPublicEDKey": Data(repeating: 0, count: 31).base64EncodedString()]))
        #expect(!CompanionUpdateController.validConfiguration([:]))
    }

    @Test func checkingWhileAgentIsBusyDoesNotStartUpdaterOrShowDialog() {
        let updater = CompanionUpdateController(isBusy: { true })
        updater.checkForUpdates()
        #expect(!updater.isStarted)
        #expect(updater.startupError == nil)
    }

    @Test func recordingAndTranscribingDeferUpdatesUntilTheTurnIsIdle() {
        let suite = "CompanionUpdateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DesktopCompanionModel(defaults: defaults)
        let updater = CompanionUpdateController(isBusy: { model.isBusyForUpdates })

        model.isRecording = true
        #expect(model.isBusyForUpdates)
        updater.checkForUpdates()
        #expect(!updater.isStarted && updater.startupError == nil)

        model.isRecording = false
        model.isTranscribing = true
        #expect(model.isBusyForUpdates)
        updater.checkForUpdates()
        #expect(!updater.isStarted && updater.startupError == nil)

        model.isTranscribing = false
        #expect(!model.isBusyForUpdates)
    }
}
