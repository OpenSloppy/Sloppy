import Foundation
import Protocols

public struct DashboardNotification: Codable, Sendable {
    public enum NotificationType: String, Codable, Sendable {
        case confirmation
        case agentError = "agent_error"
        case systemError = "system_error"
        case pendingApproval = "pending_approval"
        case toolApproval = "tool_approval"
        case taskCompleted = "task_completed"
        case inputRequired = "input_required"
        case cronAttention = "cron_attention"
        case proactiveAttention = "proactive_attention"
    }

    public var id: String
    public var type: NotificationType
    public var title: String
    public var message: String
    public var timestamp: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        type: NotificationType,
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

public actor NotificationService {
    private var subscribers: [UUID: AsyncStream<DashboardNotification>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<DashboardNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [id] _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    public func push(_ notification: DashboardNotification) {
        for continuation in subscribers.values {
            continuation.yield(notification)
        }
    }

    public func pushAgentError(title: String, message: String, agentId: String? = nil, taskId: String? = nil) {
        var metadata: [String: String] = [:]
        if let agentId { metadata["agentId"] = agentId }
        if let taskId { metadata["taskId"] = taskId }
        push(DashboardNotification(type: .agentError, title: title, message: message, metadata: metadata))
    }

    public func pushSystemError(title: String, message: String) {
        push(DashboardNotification(type: .systemError, title: title, message: message))
    }

    public func pushPendingApproval(
        title: String,
        message: String,
        approvalId: String,
        platform: String,
        userId: String,
        channelId: String?
    ) {
        var metadata: [String: String] = [
            "approvalId": approvalId,
            "platform": platform,
            "userId": userId,
            "source": "system"
        ]
        if let channelId { metadata["channelId"] = channelId }
        push(DashboardNotification(type: .pendingApproval, title: title, message: message, metadata: metadata))
    }

    public func pushConfirmation(title: String, message: String, taskId: String? = nil) {
        var metadata: [String: String] = [:]
        if let taskId { metadata["taskId"] = taskId }
        push(DashboardNotification(type: .confirmation, title: title, message: message, metadata: metadata))
    }

    public func pushToolApproval(_ approval: ToolApprovalRecord) {
        var metadata: [String: String] = [
            "approvalId": approval.id,
            "status": approval.status.rawValue,
            "agentId": approval.agentId,
            "tool": approval.tool,
            "expiresAt": ISO8601DateFormatter().string(from: approval.expiresAt),
            "source": "agent"
        ]
        if let sessionId = approval.displaySessionId ?? approval.sessionId { metadata["sessionId"] = sessionId }
        if let sourceSessionId = approval.sessionId { metadata["sourceSessionId"] = sourceSessionId }
        if let displaySessionId = approval.displaySessionId { metadata["displaySessionId"] = displaySessionId }
        if let channelId = approval.channelId { metadata["channelId"] = channelId }
        if let topicId = approval.topicId { metadata["topicId"] = topicId }
        if let reason = approval.reason { metadata["reason"] = reason }
        push(DashboardNotification(
            type: .toolApproval,
            title: approval.status == .pending ? "Tool approval required" : "Tool approval \(approval.status.rawValue)",
            message: approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? approval.reason!
                : approval.tool,
            metadata: metadata
        ))
    }

    public func pushToolApprovalRequired(
        title: String,
        message: String,
        agentId: String,
        sessionId: String
    ) {
        push(
            DashboardNotification(
                type: .toolApproval,
                title: title,
                message: message,
                metadata: [
                    "agentId": agentId,
                    "sessionId": sessionId,
                    "channelId": "agent:\(agentId):session:\(sessionId)",
                    "source": "agent"
                ]
            )
        )
    }

    public func pushInputRequired(
        title: String,
        message: String,
        agentId: String? = nil,
        sessionId: String? = nil,
        taskId: String? = nil,
        projectId: String? = nil,
        requestId: String? = nil,
        source: String = "agent"
    ) {
        var metadata: [String: String] = ["source": source]
        if let agentId { metadata["agentId"] = agentId }
        if let sessionId { metadata["sessionId"] = sessionId }
        if let taskId { metadata["taskId"] = taskId }
        if let projectId { metadata["projectId"] = projectId }
        if let requestId { metadata["requestId"] = requestId }
        push(DashboardNotification(type: .inputRequired, title: title, message: message, metadata: metadata))
    }

    public func pushTaskCompleted(
        title: String,
        message: String,
        taskId: String,
        projectId: String,
        source: String
    ) {
        push(DashboardNotification(
            type: .taskCompleted,
            title: title,
            message: message,
            metadata: [
                "taskId": taskId,
                "projectId": projectId,
                "source": source
            ]
        ))
    }

    public func pushCronAttention(
        title: String,
        message: String,
        cronTaskId: String,
        agentId: String,
        channelId: String
    ) {
        push(DashboardNotification(
            type: .cronAttention,
            title: title,
            message: message,
            metadata: [
                "cronTaskId": cronTaskId,
                "agentId": agentId,
                "channelId": channelId,
                "source": "cron"
            ]
        ))
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
