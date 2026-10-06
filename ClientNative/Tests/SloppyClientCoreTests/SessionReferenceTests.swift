import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Session mentions")
struct SessionReferenceTests {
    @Test func preservesStableAddressWithEscapedTitles() {
        let reference = ChatSessionReference(agentId: "agent-a", sessionId: "session-123")
        let markdown = reference.markdown(title: "Review [UI] 日本語")
        #expect(markdown.contains("@Review \\[UI\\] 日本語"))
        #expect(ChatSessionReference.parseLinks(in: markdown + " " + markdown) == [reference])
        #expect(ChatSessionReference.parseLinks(in: "@README.md @skill mail@example.org").isEmpty)
    }

    @Test func legacyMessagesDecodeWithoutReferences() throws {
        let message = ChatMessage(role: .user, segments: [.init(kind: .text, text: "Legacy")])
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.peerOrigin == nil)
        #expect(decoded.sessionReferences == nil)
    }
}
