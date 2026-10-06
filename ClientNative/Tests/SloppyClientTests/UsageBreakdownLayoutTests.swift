#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import SloppyClientCore
@testable import SloppyClient

@MainActor
@Test func usageBreakdownReflowsOnDesktopAndPhoneWidths() throws {
    let data = Data(#"{"collectionStartedAt":"2026-10-06T09:00:00Z","requestCount":7,"reportedRequestCount":6,"completeRequestCount":5,"providerUsage":{"prompt":12000,"completion":1300,"cachedInput":9000,"cacheCreationInput":0,"reasoning":400},"groups":[{"id":"mcp.docs.lookup","calls":3,"failures":1,"argumentsTokens":120,"resultTokens":1200,"replayTokens":2400,"schemaTokens":1800,"catalogTokens":0,"tokenizerMeasurements":5,"estimatedMeasurements":0,"unavailableMeasurements":0},{"id":"files.read","calls":2,"failures":0,"argumentsTokens":20,"resultTokens":300,"replayTokens":600,"schemaTokens":100,"catalogTokens":0,"tokenizerMeasurements":0,"estimatedMeasurements":4,"unavailableMeasurements":0}],"calls":[]}"#.utf8)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(UsageBreakdownResponse.self,from:data)
    let api = SloppyAPIClient(baseURL: try #require(URL(string:"http://127.0.0.1:9")))
    for width in [900.0,390.0] {
        let view = UsageBreakdownSection(apiClient:api,from:Date(),to:Date(),revision:0,
            sessions:[:],onOpenSession:{ _ in },initialResponse:response).padding(24).frame(width:width)
        // NSHostingView captures native segmented controls, which ImageRenderer cannot render.
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
        let height = hosting.fittingSize.height
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(abs(hosting.bounds.width - width) < 1)
        #expect(height > 300)
        #expect(height < 1600)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to:URL(fileURLWithPath:"/private/tmp/sloppy-usage-native-\(Int(width)).png"))
    }
}
#endif
