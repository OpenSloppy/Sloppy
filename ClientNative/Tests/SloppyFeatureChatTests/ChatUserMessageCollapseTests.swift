#if os(macOS)
import AppKit
import SwiftUI
import Testing
import SloppyUITestSupport
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("User message collapse", .serialized, .appKitUI)
@MainActor
struct ChatUserMessageCollapseTests {
    @Test("short messages have no expansion control")
    func shortMessage() async throws {
        let fixture = Fixture(text: "Короткое сообщение")
        defer { fixture.close() }
        await fixture.layout()
        #expect(fixture.height < 100)
        #expect(fixture.button == nil)
    }

    @Test("long user messages expand and collapse without losing content")
    func longMessage() async throws {
        let text = (1...40).map { "Строка \($0): полный текст сообщения." }.joined(separator: "\n")
        let fixture = Fixture(text: text)
        defer { fixture.close() }
        await fixture.layout()
        let collapsedHeight = fixture.height
        #expect(collapsedHeight < 400)
        try fixture.capture(to: "/tmp/sloppy-user-message-collapsed.png")
        let button = try #require(fixture.button)
        #expect((button as AnyObject).accessibilityLabel?() == "Show more")
        #expect((button as AnyObject).accessibilityPerformPress?() == true)
        await fixture.layout()
        #expect(fixture.height > collapsedHeight * 2)
        #expect(fixture.button.map { ($0 as AnyObject).accessibilityLabel?() } == "Show less")
        #expect(fixture.button.map { ($0 as AnyObject).accessibilityPerformPress?() } == true)
        await fixture.layout()
        #expect(abs(fixture.height - collapsedHeight) <= 1)
        #expect(fixture.message.textContent == text)
    }

    @Test("wrapping counts toward the preview budget")
    func wrappedMessage() async throws {
        let fixture = Fixture(text: String(repeating: "Длинное сообщение без явных переносов строк. ", count: 35))
        defer { fixture.close() }
        await fixture.layout()
        #expect(fixture.button != nil)
        #expect(fixture.height < 400)
    }

    @Test("the preview boundary is twelve lines", arguments: [12, 13])
    func lineBoundary(lines: Int) async {
        let fixture = Fixture(text: Array(repeating: "Строка сообщения", count: lines).joined(separator: "\n"))
        defer { fixture.close() }
        await fixture.layout()
        #expect((fixture.button != nil) == (lines > 12))
    }

    @Test("quoted markdown uses the same collapsed preview")
    func markdownMessage() async throws {
        let fixture = Fixture(text: (1...40).map { "> Цитата: строка \($0)." }.joined(separator: "\n\n"))
        defer { fixture.close() }
        await fixture.layout()
        #expect(fixture.height < 400)
        #expect(fixture.button != nil)
    }

    @Test("assistant text stays fully visible")
    func assistantMessage() async {
        let fixture = Fixture(text: String(repeating: "Строка ответа\n\n", count: 40), role: .assistant)
        defer { fixture.close() }
        await fixture.layout()
        #expect(fixture.button == nil)
        #expect(fixture.height > 600)
    }

    @MainActor
    private final class Fixture {
        let message: ChatMessage
        let host: NSHostingView<AnyView>
        let window: NSWindow

        init(text: String, role: ChatMessageRole = .user) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            // XCTest has no accessibility client to enable SwiftUI's tree for us.
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            message = ChatMessage(id: "collapse-test", role: role,
                                  segments: [ChatMessageSegment(kind: .text, text: text)])
            host = NSHostingView(rootView: AnyView(ChatBubbleView(message: message)
                .frame(width: 400).fixedSize(horizontal: false, vertical: true)
                .padding(20).background(Color.black).preferredColorScheme(.dark)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        var height: CGFloat { host.fittingSize.height }

        var button: NSObject? {
            // SwiftUI exposes these selectors without adopting NSAccessibilityProtocol.
            func attribute(_ name: String, of object: NSObject) -> Any? {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            func find(_ elements: [Any]) -> NSObject? {
                for element in elements {
                    guard let accessible = element as? NSObject else { continue }
                    if (attribute("accessibilityIdentifier", of: accessible) as? String) == "chat.user-message.toggle-expansion" {
                        return accessible
                    }
                    if let match = find(attribute("accessibilityChildren", of: accessible) as? [Any] ?? []) { return match }
                }
                return nil
            }
            return find(host.accessibilityChildren() ?? [])
        }

        func layout() async {
            for _ in 0..<12 {
                host.frame.size = NSSize(width: 440, height: max(height, 1))
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        func capture(to path: String) throws {
            host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
#endif
