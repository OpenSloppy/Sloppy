#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Testing
import SloppyClientCore
import SloppyFeatureSettings
import SloppyUITestSupport

@Suite("Backend updates UI", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct BackendUpdatesRenderingTests {
    @Test("Managed backend offers installation in a native screen", arguments: [false, true])
    func rendersUpdate(isDark: Bool) async throws {
        let status = try JSONDecoder().decode(BackendUpdateStatus.self, from: Data(#"{"currentVersion":"2.2.0","latestVersion":"v2.3.0","updateAvailable":true,"isReleaseBuild":true,"deploymentKind":"local","releaseUrl":"https://github.com/TeamSloppy/Sloppy/releases/tag/v2.3.0"}"#.utf8))
        let model = BackendUpdateModel(fetch: { _ in status }, eligibility: { _ in true }, install: { _, _ in })
        await model.check()
        AppKitTestAccessibility.enable()
        let host = NSHostingView(rootView: BackendUpdatesSection(model: model)
            .padding(24)
            .frame(width: 520, height: 520, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(isDark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(AppKitTestAccessibility.element(in: host, identifier: "backend.update.install") != nil)
        #expect(AppKitTestAccessibility.element(in: host, identifier: "backend.update.check") != nil)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/sloppy-backend-update-\(isDark ? "dark" : "light").png"))
    }
}
#endif
