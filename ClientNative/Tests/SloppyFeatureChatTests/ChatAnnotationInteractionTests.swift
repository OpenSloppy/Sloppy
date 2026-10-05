#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI
import SloppyUITestSupport
import Testing
@testable import SloppyFeatureChat

@Suite("Chat annotation interaction", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct ChatAnnotationInteractionTests {
    @Test("Add to chat focuses the comment belonging to the new selection")
    func newSelectionFocusesComment() async throws {
        let api = SloppyAPIClient()
        let model = ChatScreenViewModel(apiClient: api, cacheStore: ClientCacheStore(path: ":memory:"),
            settings: ClientSettings(), connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false, responseNotificationScheduler: AnnotationInteractionNotifications(),
            onOpenSettings: { _ in })
        let host = NSHostingView(rootView: ChatComposerView(draft: model.composerDraft, tabs: [], viewModel: model)
            .environment(\.theme, .sloppyDark).environment(\.userInterfaceIdiom, .desktop))
        let window = makeWindow(host: host, size: CGSize(width: 900, height: 350))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        model.composerDraft.text = "General request"
        model.addQuoteToComposer("First selection")
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Comment for first", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.composerQuotes.first?.comment == "Comment for first")
        model.addQuoteToComposer("Second selection")
        try await Task.sleep(for: .milliseconds(200))
        let secondEditor = try #require(window.firstResponder as? NSTextView)
        secondEditor.insertText("Comment for second", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.composerQuotes.map(\.comment) == ["Comment for first", "Comment for second"])
        #expect(model.composerDraft.text == "General request")
        try capture(host, name: "quote-comments")
    }

    @Test("image points and dragged areas focus and save their own comments", arguments: [ColorScheme.light, .dark])
    func imagePointAndAreaComments(scheme: ColorScheme) async throws {
        let image = NSImage(size: NSSize(width: 800, height: 400))
        image.lockFocus()
        NSColor.gray.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 400)).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var data = try #require(bitmap.representation(using: .png, properties: [:]))
        if let source = ProcessInfo.processInfo.environment["SLOPPY_ANNOTATION_SOURCE_IMAGE"] {
            data = try Data(contentsOf: URL(fileURLWithPath: source))
        }
        let attachment = ChatComposerAttachment(name: "screenshot.png", mimeType: "image/png", data: data)
        AppKitTestAccessibility.enable()
        var saved: [ChatImageAnnotation] = []
        let host = NSHostingView(rootView: ChatImageAnnotationEditor(attachment: attachment, save: { saved = $0 })
            .preferredColorScheme(scheme))
        let window = makeWindow(host: host, size: CGSize(width: 1000, height: 820))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        try capture(host, name: "image-before-click")
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.height * 0.4), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 where !(window.firstResponder is NSTextView) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try capture(host, name: "image-after-click")
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Pay attention to this section", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string == "Pay attention to this section")
        let dragStart = host.convert(NSPoint(x: host.bounds.width * 0.4, y: host.bounds.height * 0.3), to: nil)
        let dragEnd = host.convert(NSPoint(x: host.bounds.width * 0.6, y: host.bounds.height * 0.4), to: nil)
        for (type, location) in [(NSEvent.EventType.leftMouseDown, dragStart), (.leftMouseDragged, dragEnd), (.leftMouseUp, dragEnd)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(150))
        try capture(host, name: "image-after-drag")
        let areaEditor = try #require(window.firstResponder as? NSTextView)
        areaEditor.insertText("Widen this area", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        try capture(host, name: scheme == .dark ? "image-dark" : "image-light")
        let save = try #require(AppKitTestAccessibility.element(in: host, identifier: "chat.image.annotations.save"))
        #expect(AppKitTestAccessibility.press(save))
        #expect(saved.count == 2)
        #expect(saved.map(\.comment) == ["Pay attention to this section", "Widen this area"])
        #expect(saved.last?.region.width ?? 0 > 0)
        #expect(saved.last?.region.height ?? 0 > 0)
    }

    private func makeWindow<V: View>(host: NSHostingView<V>, size: CGSize) -> NSWindow {
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func capture<V: View>(_ host: NSHostingView<V>, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SLOPPY_ANNOTATION_SCREENSHOTS"] else { return }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
@MainActor
private final class AnnotationInteractionNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
#endif
