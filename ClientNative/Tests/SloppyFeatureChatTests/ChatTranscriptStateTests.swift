import Foundation
import Testing
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("ChatTranscriptState")
@MainActor
struct ChatTranscriptStateTests {
    @Test("streamed text keeps thinking inside activity without duplicating it in the reply")
    func streamingMixedMessagePreservesActivityGroup() {
        let transcript = ChatTranscriptState()
        transcript.append(ChatMessage(id: "assistant", role: .assistant, segments: [
            .init(kind: .thinking, text: "Reasoning"),
        ]))
        transcript.appendStreamingAssistantText("Hello", messageId: "assistant")
        let activity = transcript.entries.first
        let identityRevision = transcript.identityRevision
        transcript.appendStreamingAssistantText("!", messageId: "assistant")
        #expect(transcript.entries.count == 2)
        #expect(transcript.entries.first == activity)
        #expect(transcript.identityRevision == identityRevision)
        guard case .message(let reply) = transcript.entries.last else {
            Issue.record("Expected a separate reply")
            return
        }
        #expect(reply.segments == [.init(kind: .text, text: "Hello!")])
        #expect(transcript.messages.first?.segments.count == 2)
    }

    @Test("late final events close turns in submission order")
    func lateFinalEventsKeepTurnOrder() {
        var tracker = ChatStreamingTurnTracker()
        tracker.begin(sessionId: "session", messageId: "assistant-turn-1")
        tracker.begin(sessionId: "session", messageId: "assistant-turn-2")

        #expect(tracker.currentMessageId(for: "session") == "assistant-turn-1")
        #expect(tracker.claimFinalMessageId(for: "session") == "assistant-turn-1")

        #expect(tracker.completeNextTurn(for: "session") == "assistant-turn-1")

        #expect(tracker.currentMessageId(for: "session") == "assistant-turn-2")
        #expect(tracker.claimFinalMessageId(for: "session") == "assistant-turn-2")
    }

    @Test("completion notification uses response preview and a session deep link")
    func completionNotificationContent() {
        let notification = AgentResponseCompletionNotification(
            agentName: "Builder",
            sessionTitle: "Fix notifications",
            responsePreview: "  Finished\nwith   tests.  ",
            agentId: "agent/id",
            sessionId: "session?id",
            messageId: "message-1"
        )

        #expect(notification.title == "Builder finished responding")
        #expect(notification.body == "Finished with tests.")
        #expect(notification.deepLink == "sloppy://session?agent=agent/id&id=session?id")
        #expect(notification.identifier == "agent-response.session?id.message-1")
    }

    @Test("completion notification has a fallback body")
    func completionNotificationFallbackBody() {
        let notification = AgentResponseCompletionNotification(
            agentName: "Builder",
            sessionTitle: "Chat",
            responsePreview: nil,
            agentId: "agent",
            sessionId: "session",
            messageId: "message"
        )

        #expect(notification.body == "The agent’s response is ready.")
    }

    @Test("replaceAll keeps only a recent window visible for large histories")
    func replaceAllShowsRecentWindowForLargeHistory() {
        let transcript = ChatTranscriptState()
        let messages = makeMessages(count: 150)

        transcript.replaceAll(messages)

        #expect(transcript.messages.count == 64)
        #expect(transcript.messages.first?.id == "msg-86")
        #expect(transcript.messages.last?.id == "msg-149")
        #expect(transcript.hasEarlierMessages == true)
        #expect(transcript.hiddenMessageCount == 86)
        #expect(transcript.entries.count == 64)
        #expect(transcript.renderRevision > 0)
        #expect(transcript.identityRevision > 0)
    }

    @Test("append keeps the recent window and newer messages visible")
    func appendKeepsRecentWindowVisible() {
        let transcript = ChatTranscriptState()
        transcript.replaceAll(makeMessages(count: 70))

        transcript.append(message(id: "msg-70", index: 70))

        #expect(transcript.messages.count == 65)
        #expect(transcript.messages.first?.id == "msg-6")
        #expect(transcript.messages.last?.id == "msg-70")
        #expect(transcript.hasEarlierMessages == true)
    }

    @Test("revealEarlierMessages restores earlier transcript pages")
    func revealEarlierMessagesRestoresEarlierPages() {
        let transcript = ChatTranscriptState()
        transcript.replaceAll(makeMessages(count: 150))

        transcript.revealEarlierMessages()

        #expect(transcript.messages.count == 128)
        #expect(transcript.messages.first?.id == "msg-22")
        #expect(transcript.messages.last?.id == "msg-149")
        #expect(transcript.hasEarlierMessages == true)
        #expect(transcript.hiddenMessageCount == 22)
    }

    @Test("streaming assistant text accumulates across separate UI flushes")
    func streamingAssistantTextAccumulatesAcrossFlushes() {
        let transcript = ChatTranscriptState()

        transcript.appendStreamingAssistantText("Hello", messageId: "streaming-assistant-session")
        let identityRevision = transcript.identityRevision
        let renderRevision = transcript.renderRevision
        transcript.appendStreamingAssistantText(", world", messageId: "streaming-assistant-session")

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages.first?.role == .assistant)
        #expect(transcript.messages.first?.textContent == "Hello, world")
        #expect(transcript.identityRevision == identityRevision)
        #expect(transcript.renderRevision > renderRevision)
        #expect(transcript.entries.first?.id == "message:streaming-assistant-session")
    }

    @Test("history reconciliation preserves optimistic and streamed messages")
    func reconciliationPreservesLocalMessages() {
        let transcript = ChatTranscriptState()
        let optimistic = ChatMessage(
            id: "optimistic-user-1",
            role: .user,
            segments: [ChatMessageSegment(kind: .text, text: "Now")],
            createdAt: Date(timeIntervalSince1970: 2)
        )
        transcript.replaceAll([message(id: "server-1", index: 0)])
        transcript.append(optimistic)

        transcript.reconcile(with: [message(id: "server-1", index: 0, text: "Updated")])

        #expect(transcript.messages.map(\.id) == ["server-1", "optimistic-user-1"])
        #expect(transcript.messages.first?.textContent == "Updated")
    }

    @Test("final assistant atomically replaces the streaming placeholder")
    func finalAssistantReplacesStreamingPlaceholder() {
        let transcript = ChatTranscriptState()
        transcript.appendStreamingAssistantText("Draft", messageId: "streaming-assistant-session")
        let final = ChatMessage(
            id: "assistant-final",
            role: .assistant,
            segments: [ChatMessageSegment(kind: .text, text: "Final")]
        )

        transcript.replaceStreamingAssistant(
            messageId: "streaming-assistant-session",
            with: final
        )

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages.first?.id == "assistant-final")
        #expect(transcript.messages.first?.textContent == "Final")
    }

    @Test("a later turn cannot overwrite an earlier streaming assistant")
    func laterTurnPreservesEarlierStreamingAssistant() {
        let transcript = ChatTranscriptState()
        transcript.append(
            ChatMessage(
                id: "user-1",
                role: .user,
                segments: [ChatMessageSegment(kind: .text, text: "First question")]
            )
        )
        transcript.appendStreamingAssistantText("First answer", messageId: "streaming-assistant-session-turn-1")
        transcript.append(
            ChatMessage(
                id: "user-2",
                role: .user,
                segments: [ChatMessageSegment(kind: .text, text: "Second question")]
            )
        )
        transcript.appendStreamingAssistantText("Second answer", messageId: "streaming-assistant-session-turn-2")

        #expect(transcript.messages.map(\.id) == [
            "user-1",
            "streaming-assistant-session-turn-1",
            "user-2",
            "streaming-assistant-session-turn-2",
        ])
        #expect(transcript.messages.filter { $0.role == .assistant }.map(\.textContent) == [
            "First answer",
            "Second answer",
        ])
    }

    @Test("late activity is inserted before the streaming assistant")
    func lateActivityStaysBeforeStreamingAssistant() {
        let transcript = ChatTranscriptState()
        transcript.appendStreamingAssistantText("Draft", messageId: "streaming-assistant-session")
        let thinking = ChatMessage(
            id: "thinking-1",
            role: .assistant,
            segments: [ChatMessageSegment(kind: .thinking, text: "Planning")]
        )

        transcript.upsert(thinking, before: "streaming-assistant-session")

        #expect(transcript.messages.map(\.id) == ["thinking-1", "streaming-assistant-session"])
    }

    @Test("streaming updates an earlier visible turn without changing neighboring entries")
    func streamingPreservesNeighboringEntries() {
        let transcript = ChatTranscriptState()
        transcript.replaceAll(makeMessages(count: 150))
        let originalEntries = transcript.entries
        let identityRevision = transcript.identityRevision
        for _ in 0..<100 {
            transcript.appendStreamingAssistantText(" delta", messageId: "msg-147")
        }
        #expect(transcript.messages.count == 64)
        #expect(transcript.messages[61].textContent == "message 147" + String(repeating: " delta", count: 100))
        #expect(transcript.entries[61] == .message(transcript.messages[61]))
        #expect(transcript.entries[60] == originalEntries[60])
        #expect(transcript.entries[62] == originalEntries[62])
        #expect(transcript.identityRevision == identityRevision)
    }

    private func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { message(id: "msg-\($0)", index: $0) }
    }

    private func message(id: String, index: Int, text: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id,
            role: index.isMultiple(of: 2) ? .user : .assistant,
            segments: [ChatMessageSegment(kind: .text, text: text ?? "message \(index)")],
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}
