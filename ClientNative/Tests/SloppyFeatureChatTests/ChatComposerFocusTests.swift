import Foundation
import SwiftUI
import SloppyClientCore
import Testing
import SloppyUITestSupport
@testable import SloppyFeatureChat
#if os(macOS)
import AppKit

@Suite("Chat composer focus", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct ChatComposerFocusTests {
    @Test("opening and switching the active composer focuses the native editor")
    func activeComposerFocusesNativeEditor() async throws {
        _ = NSApplication.shared
        let api = SloppyAPIClient(baseURL: try #require(URL(string: "http://composer-focus.invalid")))
        let settings = ClientSettings()
        func model() -> ChatScreenViewModel {
            ChatScreenViewModel(
                apiClient: api,
                cacheStore: ClientCacheStore(path: ":memory:"),
                settings: settings,
                connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
                responseNotificationScheduler: ComposerFocusNotifications(),
                onOpenSettings: { _ in }
            )
        }
        func composer(_ model: ChatScreenViewModel) -> ChatComposerOverlay {
            ChatComposerOverlay(
                viewModel: model,
                contentWidth: 720,
                composerBottomInset: 24,
                tabs: [],
                tabActions: nil
            )
        }

        let first = model()
        let hostingView = NSHostingView(rootView: composer(first))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<100 where first.composerFocusRequestToken == 0 || !(window.firstResponder is NSTextView) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.composerFocusRequestToken > 0)
        #expect(window.firstResponder is NSTextView)

        window.makeFirstResponder(nil)
        let second = model()
        hostingView.rootView = composer(second)
        for _ in 0..<100 where second.composerFocusRequestToken == 0 || !(window.firstResponder is NSTextView) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(second.composerFocusRequestToken > 0)
        #expect(window.firstResponder is NSTextView)
    }
}

@MainActor
private final class ComposerFocusNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
#endif
