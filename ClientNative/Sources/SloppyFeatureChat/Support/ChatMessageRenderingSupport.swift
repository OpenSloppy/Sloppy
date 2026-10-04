import Foundation
import SloppyClientCore

enum ChatTranscriptEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case systemGroup([ChatMessage])

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id)"
        case .systemGroup(let messages):
            return "system-group:\(messages.first?.id ?? "empty")"
        }
    }

    var createdAt: Date {
        switch self {
        case .message(let message):
            return message.createdAt
        case .systemGroup(let messages):
            return messages.first?.createdAt ?? .distantPast
        }
    }
}

enum ChatTranscriptDateSeparators {
    static let minimumInterval: TimeInterval = 45 * 60

    static func shouldInsert(
        between previous: Date,
        and current: Date,
        calendar: Calendar = .current
    ) -> Bool {
        !calendar.isDate(previous, inSameDayAs: current)
            || current.timeIntervalSince(previous) >= minimumInterval
    }

    static func title(for date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum ChatTranscriptGrouping {
    static func entries(from messages: [ChatMessage]) -> [ChatTranscriptEntry] {
        var entries: [ChatTranscriptEntry] = []
        var pendingSystemMessages: [ChatMessage] = []

        func flushSystemMessages() {
            guard !pendingSystemMessages.isEmpty else { return }
            entries.append(.systemGroup(pendingSystemMessages))
            pendingSystemMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if isGroupableSystemMessage(message) {
                pendingSystemMessages.append(message)
            } else if message.role == .assistant {
                let activitySegments = message.segments.filter(\.isAssistantActivity)
                guard !activitySegments.isEmpty else {
                    flushSystemMessages()
                    entries.append(.message(message))
                    continue
                }
                var activity = message
                activity.segments = activitySegments
                pendingSystemMessages.append(activity)

                var response = message
                response.segments.removeAll(where: \.isAssistantActivity)
                if !response.segments.isEmpty {
                    flushSystemMessages()
                    entries.append(.message(response))
                }
            } else {
                flushSystemMessages()
                entries.append(.message(message))
            }
        }

        flushSystemMessages()
        return entries
    }

    private static func isGroupableSystemMessage(_ message: ChatMessage) -> Bool {
        message.role == .system
            && message.segments.allSatisfy { $0.buildProgress == nil }
    }

    static func usesCompactSpacing(
        between current: ChatTranscriptEntry,
        and next: ChatTranscriptEntry
    ) -> Bool {
        current.isSystemActivity && next.isSystemActivity
    }
}

enum ChatActiveRunMessages {
    static func messageIDs(
        in messages: [ChatMessage],
        isRunActive: Bool
    ) -> Set<ChatMessage.ID> {
        guard isRunActive,
              let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return []
        }

        let firstActiveIndex = messages.index(after: lastUserIndex)
        guard firstActiveIndex < messages.endIndex else { return [] }

        let activeMessages = messages[firstActiveIndex...]
        var messageIDs = Set(activeMessages.compactMap { message -> ChatMessage.ID? in
            message.segments.contains(where: \.isExecutionRunning) ? message.id : nil
        })

        if let thinkingMessage = activeMessages.reversed().first(where: { message in
            message.role == .assistant
                && message.segments.contains(where: { $0.kind == .thinking })
        }) {
            messageIDs.insert(thinkingMessage.id)
        }

        return messageIDs
    }
}

extension ChatMessageSegment {
    var isAssistantActivity: Bool {
        switch kind {
        case .thinking, .toolCall, .toolResult:
            return true
        case .text, .attachment, .status, .buildProgress:
            return false
        }
    }

    var isExecutionRunning: Bool {
        if let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return status == "started" || status == "running" || status == "in_progress"
        }
        return startedAt != nil && finishedAt == nil
    }
}

private extension ChatTranscriptEntry {
    var isSystemActivity: Bool {
        switch self {
        case .message(let message):
            return message.role == .system
        case .systemGroup:
            return true
        }
    }
}

enum ChatCompactDurationFormatter {
    static func string(for seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
}
