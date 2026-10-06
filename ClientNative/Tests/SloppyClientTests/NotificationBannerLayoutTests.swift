#if os(macOS)
import AppKit
import SloppyClientUI
import SwiftUI
import Testing

@MainActor
@Test func notificationBannerStaysCompactInTallWindow() throws {
    let renderer = ImageRenderer(content: NotificationBanner(item: .init(
        id: "worker-error", title: "Worker failed",
        message: "Worker timed out after 626s", accentColor: .red
    )).frame(width: 320))
    renderer.proposedSize = ProposedViewSize(width: 320, height: 1_000)
    let image = try #require(renderer.nsImage)
    #expect(image.size.width == 320)
    #expect(image.size.height > 40)
    #expect(image.size.height < 160)
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/private/tmp/sloppy-worker-notification-banner.png"))
}
#endif
