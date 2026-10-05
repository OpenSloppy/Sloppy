#if os(macOS)
import AppKit
import SwiftUI
import Testing
import SloppyUITestSupport
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("User bubble layout", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct ChatUserBubbleLayoutTests {
    @Test("new short user messages have text height on the first layout")
    func shortMessageHasImmediateHeight() {
        _ = NSApplication.shared
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 400, height: 100)
        func height(for text: String) -> CGFloat {
            let message = ChatMessage(id: "user-test", role: .user,
                                      segments: [ChatMessageSegment(kind: .text, text: text)])
            item.configure(rootView: AnyView(ChatBubbleView(message: message)
                .frame(width: 400).fixedSize(horizontal: false, vertical: true)))
            return item.preferredLayoutAttributesFitting(attributes).size.height
        }
        let shortHeight = height(for: "Повтори")
        // A visible line plus the bubble's vertical padding and row spacing.
        #expect(shortHeight >= 48)
        let multilineHeight = height(for: String(repeating: "Повтори это сообщение ещё раз. ", count: 20))
        #expect(multilineHeight > shortHeight * 2)
        #expect(abs(height(for: "Повтори") - shortHeight) <= 1)
    }
}
#endif
