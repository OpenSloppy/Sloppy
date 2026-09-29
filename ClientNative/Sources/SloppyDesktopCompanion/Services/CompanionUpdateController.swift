import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class CompanionUpdateController: NSObject {
    private let isBusy: () -> Bool
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var deferredRelaunch: Task<Void, Never>?
    #endif
    private(set) var startupError: String?
    private(set) var isStarted = false

    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy; super.init() }

    static func validConfiguration(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start() {
        guard !isStarted else { return }
        #if canImport(Sparkle)
        guard Self.validConfiguration(Bundle.main.infoDictionary ?? [:]) else {
            startupError = "This build does not have a signed Companion update channel configured."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do { try controller.updater.start(); isStarted = true; startupError = nil }
        catch { startupError = error.localizedDescription }
        #else
        startupError = "Updates are unavailable in this SwiftPM development build."
        #endif
    }

    func checkForUpdates() {
        guard !isBusy() else { return }
        start()
        #if canImport(Sparkle)
        if let controller, isStarted { controller.checkForUpdates(nil); return }
        #endif
        let alert = NSAlert()
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = startupError ?? "Please try again later."
        alert.runModal()
    }

    #if DEBUG
    func saveReport(to url: URL) throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let report: [String: Any] = ["started": isStarted, "configurationValid": Self.validConfiguration(info),
                                     "feedURL": info["SUFeedURL"] as? String ?? "", "hasError": startupError != nil]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    #endif
}

#if canImport(Sparkle)
extension CompanionUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isBusy() {
            throw NSError(domain: "team.sloppy.desktop-companion.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Finish the current conversation or agent task before checking for updates."])
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { !isBusy() }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        deferredRelaunch?.cancel()
        deferredRelaunch = Task { [weak self] in
            while let self, self.isBusy() {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}
#endif
