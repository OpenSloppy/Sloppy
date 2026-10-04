#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Testing
import SloppyUITestSupport
@testable import SloppyClient

@Suite("Sloppy update reminders", .serialized, .appKitUI)
@MainActor
struct SloppyUpdateReminderTests {
    @Test func scheduledUpdateRemainsDiscoverableUntilUserAttention() {
        let controller = SloppyUpdateController()
        #expect(controller.availableVersion == nil)

        controller.updatePresentationWillBegin(version: "2.2.0", handledBySparkle: false)
        #expect(controller.availableVersion == "2.2.0")

        // A manual check uses Sparkle's update window instead of a second reminder.
        controller.updatePresentationWillBegin(version: "2.2.0", handledBySparkle: true)
        #expect(controller.availableVersion == nil)

        controller.updatePresentationWillBegin(version: "2.3.0", handledBySparkle: false)
        #expect(controller.availableVersion == "2.3.0")
        controller.dismissUpdateReminder()
        #expect(controller.availableVersion == nil)
    }

    @Test func reminderAppearsAndDisappearsInAnAlreadyMountedView() async throws {
        let controller = SloppyUpdateController()
        let host = NSHostingView(rootView: SloppyUpdateReminderView(controller: controller)
            .padding(8)
            .frame(width: 220, height: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 220, height: 44),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(100))
        let hidden = try snapshot(host)
        controller.updatePresentationWillBegin(version: "2.2.0", handledBySparkle: false)
        try await Task.sleep(for: .milliseconds(100))
        let visible = try snapshot(host)
        #expect(hidden != visible)
        #expect(host.bounds.width == 220)

        if let directory = ProcessInfo.processInfo.environment["SLOPPY_UPDATE_SCREENSHOTS"] {
            try visible.write(to: URL(fileURLWithPath: directory).appendingPathComponent("update-reminder.png"))
        }

        controller.dismissUpdateReminder()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try snapshot(host) == hidden)
    }

    private func snapshot(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
#endif
