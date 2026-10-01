#if os(macOS)
import Foundation
import AppKit
import Observation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
@Observable
final class SloppyUpdateController: NSObject {
    static let shared = SloppyUpdateController()

    private(set) var availableVersion: String?

    #if canImport(Sparkle)
    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    #endif
    @ObservationIgnored private var startupError: String?

    override init() { super.init() }

    func start() {
        #if canImport(Sparkle)
        guard updaterController == nil else { return }
        guard Self.hasValidConfiguration else {
            startupError = "This build does not have a signed update channel configured."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        updaterController = controller
        do {
            try controller.updater.start()
        } catch {
            startupError = error.localizedDescription
        }
        #else
        startupError = "Updates are unavailable in this development build."
        #endif
    }

    func updatePresentationWillBegin(version: String, handledBySparkle: Bool) {
        availableVersion = handledBySparkle ? nil : version
    }

    func dismissUpdateReminder() {
        availableVersion = nil
    }

    func checkForUpdates() {
        start()
        #if canImport(Sparkle)
        if let updaterController, startupError == nil {
            updaterController.checkForUpdates(nil)
            return
        }
        #endif
        showUnavailableAlert()
    }

    #if canImport(Sparkle)
    private static var hasValidConfiguration: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme == "https",
              feedURL.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            return false
        }
        return true
    }
    #endif

    private func showUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = startupError ?? "Please try again later."
        alert.runModal()
    }
}

#if canImport(Sparkle)
// Sparkle invokes its UI delegate on the main thread; its Objective-C protocol
// does not declare that actor isolation to Swift.
extension SloppyUpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Preserve Sparkle's immediate alerts near launch or after system idle.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        updatePresentationWillBegin(
            version: update.displayVersionString,
            handledBySparkle: handleShowingUpdate
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        dismissUpdateReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        dismissUpdateReminder()
    }
}
#endif
#endif
