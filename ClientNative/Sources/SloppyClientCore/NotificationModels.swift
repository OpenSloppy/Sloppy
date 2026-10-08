import Foundation

public enum AppNotificationType: String, Codable, Sendable {
    case confirmation
    case agentError = "agent_error"
    case systemError = "system_error"
    case pendingApproval = "pending_approval"
    case toolApproval = "tool_approval"
    case proactiveAttention = "proactive_attention"
}

public struct AppNotification: Codable, Sendable, Identifiable {
    public var id: String
    public var type: AppNotificationType
    public var title: String
    public var message: String
    public var timestamp: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        type: AppNotificationType,
        title: String,
        message: String,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

public enum ClientToolApprovalDecisionScope: String, Codable, Sendable, CaseIterable {
    case once
    case session
    case always
}

public struct PendingToolApprovalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: String
    public var agentId: String?
    public var sessionId: String?
    public var displaySessionId: String?
    public var tool: String?
    public var reason: String?
    public var expiresAt: Date?
    public var updatedAt: Date

    public init(
        id: String,
        status: String,
        agentId: String? = nil,
        sessionId: String? = nil,
        displaySessionId: String? = nil,
        tool: String? = nil,
        reason: String? = nil,
        updatedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.agentId = agentId
        self.sessionId = sessionId
        self.displaySessionId = displaySessionId
        self.tool = tool
        self.reason = reason
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

public struct PendingChatApprovalTracker: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        var sessionID: String?
        var isPending: Bool
        var updatedAt: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var sessionIDs: Set<String> {
        Set(entries.values.compactMap { entry in
            entry.isPending ? entry.sessionID : nil
        })
    }

    public mutating func apply(_ record: PendingToolApprovalRecord) {
        apply(
            approvalID: record.id,
            status: record.status,
            sessionID: record.displaySessionId ?? record.sessionId,
            updatedAt: record.updatedAt
        )
    }

    public mutating func apply(_ notification: AppNotification) {
        guard notification.type == .toolApproval else { return }
        apply(
            approvalID: notification.metadata["approvalId"] ?? notification.id,
            status: notification.metadata["status"] ?? "pending",
            sessionID: notification.metadata["displaySessionId"] ?? notification.metadata["sessionId"],
            updatedAt: notification.timestamp
        )
    }

    private mutating func apply(
        approvalID: String,
        status: String,
        sessionID: String?,
        updatedAt: Date
    ) {
        if let current = entries[approvalID], current.updatedAt > updatedAt {
            return
        }
        entries[approvalID] = Entry(
            sessionID: sessionID,
            isPending: status == "pending",
            updatedAt: updatedAt
        )
    }
}
