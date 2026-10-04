import Foundation
import Testing
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("Chat message rendering support")
struct ChatMessageRenderingSupportTests {
    @Test("tools and assistant thinking share one activity group before the reply")
    func assistantThinkingJoinsToolActivity() throws {
        let user = ChatMessage(id: "user", role: .user, segments: [.init(kind: .text, text: "Hello")])
        let tool = ChatMessage(id: "tool", role: .system, segments: [.init(kind: .toolCall, title: "files.read")])
        let thinking = ChatMessage(id: "thinking", role: .assistant, segments: [.init(kind: .thinking, text: "Reasoning")])
        let assistant = ChatMessage(id: "reply", role: .assistant, segments: [
            .init(kind: .thinking, text: "More reasoning"),
            .init(kind: .toolResult, text: "Details", title: "files.read"),
            .init(kind: .text, text: "Hello!"),
        ])
        let entries = ChatTranscriptGrouping.entries(from: [user, tool, thinking, assistant])
        #expect(entries.count == 3)
        #expect(entries[0] == .message(user))
        guard case .systemGroup(let activity) = entries[1], case .message(let reply) = entries[2] else {
            Issue.record("Expected one activity group followed by the reply")
            return
        }
        #expect(activity.map(\.id) == ["tool", "thinking", "reply"])
        #expect(activity.flatMap(\.segments).map(\.kind) == [.toolCall, .thinking, .thinking, .toolResult])
        #expect(reply.id == assistant.id)
        #expect(reply.segments == [.init(kind: .text, text: "Hello!")])
        #expect(assistant.segments.count == 3)
    }

    @Test("activity grouping keeps user turns and visible progress separate")
    func activityGroupingPreservesTurnBoundaries() {
        let thinking = ChatMessage(id: "thinking", role: .assistant, segments: [.init(kind: .thinking, text: "Reasoning")])
        let user = ChatMessage(id: "user", role: .user, segments: [.init(kind: .text, text: "Continue")])
        let progress = ChatMessage(id: "progress", role: .system, segments: [
            .init(kind: .buildProgress, buildProgress: .init(title: "Build", items: [])),
        ])
        let nextThinking = ChatMessage(id: "next", role: .assistant, segments: [.init(kind: .thinking, text: "Next")])
        #expect(ChatTranscriptGrouping.entries(from: [thinking, user, progress, nextThinking]) == [
            .systemGroup([thinking]), .message(user), .message(progress), .systemGroup([nextThinking]),
        ])
    }

    @Test("compact duration formatter renders seconds and minutes")
    func compactDurationFormatterRendersDurations() {
        #expect(ChatCompactDurationFormatter.string(for: 12) == "12s")
        #expect(ChatCompactDurationFormatter.string(for: 84) == "1m 24s")
        #expect(ChatCompactDurationFormatter.string(for: 7384) == "2h 03m")
    }

    @Test("date separators appear after a long pause or on a new day")
    func dateSeparatorsTrackConversationBreaks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(!ChatTranscriptDateSeparators.shouldInsert(
            between: start,
            and: start.addingTimeInterval(44 * 60),
            calendar: calendar
        ))
        #expect(ChatTranscriptDateSeparators.shouldInsert(
            between: start,
            and: start.addingTimeInterval(45 * 60),
            calendar: calendar
        ))

        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)!
        #expect(ChatTranscriptDateSeparators.shouldInsert(
            between: start,
            and: nextDay,
            calendar: calendar
        ))
    }

    @Test("consecutive system messages are merged into transcript groups")
    func consecutiveSystemMessagesAreMerged() {
        let firstSystem = ChatMessage(id: "system-1", role: .system, segments: [
            .init(kind: .toolCall, title: "Read file")
        ])
        let secondSystem = ChatMessage(id: "system-2", role: .system, segments: [
            .init(kind: .toolResult, title: "Read result")
        ])
        let user = ChatMessage(id: "user", role: .user, segments: [
            .init(kind: .text, text: "Continue")
        ])
        let thirdSystem = ChatMessage(id: "system-3", role: .system, segments: [
            .init(kind: .status, title: "Running tests")
        ])

        let entries = ChatTranscriptGrouping.entries(from: [
            firstSystem,
            secondSystem,
            user,
            thirdSystem,
        ])

        #expect(entries == [
            .systemGroup([firstSystem, secondSystem]),
            .message(user),
            .systemGroup([thirdSystem]),
        ])
    }

    @Test("adjacent system activity uses compact transcript spacing")
    func adjacentSystemActivityUsesCompactSpacing() {
        let thinking = ChatTranscriptEntry.systemGroup([
            ChatMessage(id: "thinking", role: .system, segments: [
                .init(kind: .thinking, title: "Thinking")
            ])
        ])
        let progress = ChatTranscriptEntry.message(
            ChatMessage(id: "progress", role: .system, segments: [
                .init(kind: .buildProgress)
            ])
        )
        let assistant = ChatTranscriptEntry.message(
            ChatMessage(id: "assistant", role: .assistant, segments: [
                .init(kind: .text, text: "Done")
            ])
        )

        #expect(ChatTranscriptGrouping.usesCompactSpacing(between: thinking, and: progress))
        #expect(!ChatTranscriptGrouping.usesCompactSpacing(between: progress, and: assistant))
    }

    @Test("inactive runs never animate stale execution states")
    func inactiveRunsHaveNoActiveMessages() {
        let messages = [
            ChatMessage(id: "user", role: .user, segments: [.init(kind: .text, text: "Go")]),
            ChatMessage(id: "stale", role: .system, segments: [
                .init(kind: .toolCall, title: "Tests", status: "running")
            ]),
        ]

        #expect(ChatActiveRunMessages.messageIDs(in: messages, isRunActive: false).isEmpty)
    }

    @Test("active runs only animate execution after the latest user message")
    func activeRunsOnlyIncludeCurrentTurnMessages() {
        let messages = [
            ChatMessage(id: "old-user", role: .user, segments: [.init(kind: .text, text: "Old")]),
            ChatMessage(id: "old-running", role: .system, segments: [
                .init(kind: .toolCall, title: "Old tool", status: "running")
            ]),
            ChatMessage(id: "current-user", role: .user, segments: [.init(kind: .text, text: "New")]),
            ChatMessage(id: "current-tool", role: .system, segments: [
                .init(kind: .toolCall, title: "Current tool", status: "in_progress")
            ]),
            ChatMessage(id: "current-thinking", role: .assistant, segments: [
                .init(kind: .thinking, text: "Working")
            ]),
            ChatMessage(id: "completed", role: .system, segments: [
                .init(kind: .toolResult, title: "Done", status: "completed")
            ]),
        ]

        let activeIDs = ChatActiveRunMessages.messageIDs(in: messages, isRunActive: true)

        #expect(activeIDs == ["current-tool", "current-thinking"])
    }

    @Test("collapsed system activity shows only currently executing tools")
    func collapsedSystemActivityShowsOnlyCurrentTools() {
        let message = ChatMessage(id: "system", role: .system, segments: [])
        let items = [
            ChatSystemSegmentItem(
                id: "first-call",
                message: message,
                segment: .init(kind: .toolCall, title: "runtime.exec", status: "started")
            ),
            ChatSystemSegmentItem(
                id: "first-result",
                message: message,
                segment: .init(kind: .toolResult, title: "runtime.exec", status: "done")
            ),
            ChatSystemSegmentItem(
                id: "current-call",
                message: message,
                segment: .init(kind: .toolCall, title: "runtime.exec", status: "started")
            ),
            ChatSystemSegmentItem(
                id: "running-thinking",
                message: message,
                segment: .init(kind: .thinking, title: "Thinking", status: "running")
            ),
        ]

        let collapsed = ChatSystemActivityVisibility.visibleItems(from: items, isExpanded: false)
        let expanded = ChatSystemActivityVisibility.visibleItems(from: items, isExpanded: true)

        #expect(collapsed.map(\.id) == ["current-call"])
        #expect(expanded.map(\.id) == items.map(\.id))
    }
}
