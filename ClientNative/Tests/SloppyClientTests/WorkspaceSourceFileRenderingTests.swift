#if os(macOS)
import AppKit
import SwiftUI
import Testing
import SloppyClientCore
import SloppyClientUI
import SloppyUITestSupport
@testable import SloppyFeatureChat
@testable import SloppyClient
@testable import Textual

@Suite("Source file link interaction", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct WorkspaceSourceFileRenderingTests {
    @Test func clicksNativeTranscriptLinkAndScrollsFileToRequestedLine() async throws {
        let content = (1...180).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let fixture = SourceFileFixture(content: content)
        let chat = ChatScreenViewModel(apiClient: fixture.api, cacheStore: ClientCacheStore(path: ":memory:"), settings: ClientSettings(),
            connectionMonitor: ConnectionMonitor(baseURL: fixture.api.baseURL),
            responseNotificationScheduler: SourceFileTestNotifications(),
            onOpenSettings: { _ in })
        defer { chat.closeSession() }
        await chat.waitForInitialData()
        chat.transcript.replaceAll([ChatMessage(id: "source-reference", role: .assistant,
            segments: [.init(kind: .text, text: "[Open File.swift (line 120)](/remote/File.swift:120)")])])
        let dock = WorkspaceDockState()
        let host = NSHostingView(rootView:
            SourceFileInteractionFixtureView(chat: chat, dock: dock, apiClient: fixture.api)
            .environment(\.theme, .sloppyDark)
            .preferredColorScheme(.dark)
        )
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1080, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let overlay = try #require(descendants(host).compactMap { $0 as? NSTextInteractionView }.first { $0.bounds.width > 0 })
        // Find the link's glyph hit region, then send pointer events to its native interaction view.
        // Textual can place selection overlays around more than the first text line.
        var linkPoint: NSPoint?
        for y in stride(from: overlay.visibleRect.minY + 2, to: overlay.visibleRect.maxY, by: 2) {
            for x in stride(from: overlay.visibleRect.minX + 2, to: overlay.visibleRect.maxX, by: 4) {
                let point = NSPoint(x: x, y: y)
                if overlay.model.url(for: point) != nil { linkPoint = point; break }
            }
            if linkPoint != nil { break }
        }
        let localPoint = try #require(linkPoint)
        #expect(overlay.model.url(for: localPoint)?.absoluteString == "/remote/File.swift:120")
        let point = overlay.convert(localPoint, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { overlay.mouseDown(with: event) }
            else { overlay.mouseUp(with: event) }
        }
        for _ in 0..<100 {
            if dock.selectedTab?.sourceFile?.content != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let model = try #require(dock.selectedTab?.sourceFile)
        #expect(model.reference.line == 120)
        #expect(model.content?.content == content)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let sourceScroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0.documentView?.bounds.height ?? 0 > 1000
        })
        #expect(sourceScroll.contentView.bounds.origin.y > 1000)
        #expect(sourceScroll.contentView.bounds.origin.y < 3000)
        // A second link to the same file must move the existing view back up.
        dock.openSourceFile(.init(path: "/remote/File.swift", line: 2), apiClient: fixture.api, scope: .project("project"))
        try await Task.sleep(for: .milliseconds(250))
        #expect(dock.tabs.count == 1)
        #expect(sourceScroll.contentView.bounds.origin.y < 100)
        dock.openSourceFile(.init(path: "/remote/File.swift", line: 120), apiClient: fixture.api, scope: .project("project"))
        try await Task.sleep(for: .milliseconds(250))
        if let directory = ProcessInfo.processInfo.environment["SLOPPY_SOURCE_FILE_SCREENSHOTS"] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("source-file-link.png"))
        }
    }
}

@MainActor
private struct SourceFileInteractionFixtureView: View {
    let chat: ChatScreenViewModel
    let dock: WorkspaceDockState
    let apiClient: SloppyAPIClient

    var body: some View {
        HStack(spacing: 0) {
            ChatScreen(viewModel: chat, showsContextToolbar: false, showsNavigationToolbar: false)
                .frame(width: 600)
            if dock.isPresented {
                WorkspaceDockView(state: dock, onOpen: { dock.open($0) }) { tab in
                    if let file = tab.sourceFile { WorkspaceSourceFileView(viewModel: file) }
                }
                .frame(width: 480)
            }
        }
        .environment(\.chatFileOpenHandler, { reference, origin in
            #expect(origin === chat)
            dock.openSourceFile(reference, apiClient: apiClient, scope: .project("project"))
        })
    }
}

@MainActor
private final class SourceFileTestNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
#endif
