import Foundation
import SloppyClientCore
import Testing

@testable import SloppyFeatureChat

@Suite("Chat composer keyboard layout")
struct ChatComposerKeyboardLayoutTests {
    @Test("phone composer keeps only a tight gap above the keyboard")
    func phoneComposerKeepsOnlyTightGapAboveKeyboard() {
        let inset = ChatComposerKeyboardLayout.phoneBottomInset(
            rootSafeAreaBottom: 34,
            effectiveSafeAreaBottom: 336,
            normalMinimumSpacing: 12,
            keyboardSpacing: 8
        )

        #expect(inset == 8)
    }

    @Test("phone composer preserves home indicator clearance without keyboard")
    func phoneComposerPreservesHomeIndicatorClearanceWithoutKeyboard() {
        let inset = ChatComposerKeyboardLayout.phoneBottomInset(
            rootSafeAreaBottom: 34,
            effectiveSafeAreaBottom: 34,
            normalMinimumSpacing: 12,
            keyboardSpacing: 8
        )

        #expect(inset == 42)
    }

    @Test("phone composer keeps minimum spacing on flat-bottom screens")
    func phoneComposerKeepsMinimumSpacingOnFlatBottomScreens() {
        let inset = ChatComposerKeyboardLayout.phoneBottomInset(
            rootSafeAreaBottom: 0,
            effectiveSafeAreaBottom: 0,
            normalMinimumSpacing: 12,
            keyboardSpacing: 8
        )

        #expect(inset == 12)
    }
}

@Suite("Mobile composer presentation")
@MainActor
struct MobileComposerPresentationTests {
    @Test func fullScreenExpansionRequiresFocusAndCollapsePreservesTheDraft() {
        let api = SloppyAPIClient(baseURL: URL(string: "http://localhost:9")!)
        let model = ChatScreenViewModel(
            apiClient: api,
            cacheStore: ClientCacheStore(path: ":memory:"),
            settings: ClientSettings(),
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            responseNotificationScheduler: MobileComposerNotifications(),
            onOpenSettings: { _ in }
        )
        model.composerDraft.text = "Keep this draft"
        model.expandMobileComposerFullscreen()
        #expect(!model.isMobileComposerFullscreen)

        model.updateMobileComposerExpansion(true)
        model.expandMobileComposerFullscreen()
        #expect(model.isMobileComposerExpanded)
        #expect(model.isMobileComposerFullscreen)

        let previousReset = model.composerFocusResetToken
        model.dismissComposerFocus()
        #expect(!model.isMobileComposerExpanded)
        #expect(!model.isMobileComposerFullscreen)
        #expect(model.composerFocusResetToken == previousReset + 1)
        #expect(model.composerDraft.text == "Keep this draft")

        model.updateMobileComposerExpansion(true)
        #expect(model.isMobileComposerExpanded)
        #expect(!model.isMobileComposerFullscreen)
    }
}

@MainActor
private final class MobileComposerNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
