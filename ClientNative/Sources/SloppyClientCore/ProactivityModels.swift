import Foundation

public enum AgentHeartbeatMode: String, Codable, Sendable, Equatable {
    case checklist
    case proactive
}

public struct AgentProactiveSettings: Codable, Sendable, Equatable {
    public var projectIds: [String]
    public var reviewProviderIds: [String]
    public var analysisModel: String
    public var notificationStartHour: Int
    public var notificationEndHour: Int
    public var timeZone: String

    public init(
        projectIds: [String] = [], reviewProviderIds: [String] = [], analysisModel: String = "",
        notificationStartHour: Int = 9, notificationEndHour: Int = 21, timeZone: String = "Europe/Moscow"
    ) {
        self.projectIds = projectIds
        self.reviewProviderIds = reviewProviderIds
        self.analysisModel = analysisModel
        self.notificationStartHour = notificationStartHour
        self.notificationEndHour = notificationEndHour
        self.timeZone = timeZone
    }

    public var isValid: Bool {
        (0...23).contains(notificationStartHour) && (1...24).contains(notificationEndHour)
            && notificationStartHour != notificationEndHour && TimeZone(identifier: timeZone) != nil
    }

    public func permitsNotification(at date: Date) -> Bool {
        guard isValid, let zone = TimeZone(identifier: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        if notificationStartHour < notificationEndHour {
            return hour >= notificationStartHour && hour < notificationEndHour
        }
        return hour >= notificationStartHour || hour < notificationEndHour
    }
}

public struct ProactiveSource: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case task, pullRequest = "pull_request" }
    public var id: String
    public var kind: Kind
    public var title: String
    public var url: String?
    public var projectId: String?
    public var taskId: String?
    public var providerId: String?
    public var reviewId: String?

    public init(id: String, kind: Kind, title: String, url: String? = nil, projectId: String? = nil,
                taskId: String? = nil, providerId: String? = nil, reviewId: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.url = url
        self.projectId = projectId; self.taskId = taskId; self.providerId = providerId; self.reviewId = reviewId
    }
}

public enum ProactiveReportOutcome: String, Codable, Sendable { case quiet, notify, needsInput = "needs_input" }

public struct ProactiveFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var agentId: String
    public var source: ProactiveSource
    public var revision: String
    public var outcome: ProactiveReportOutcome
    public var reason: String
    public var evidence: String
    public var nextStep: String
    public var sessionId: String
    public var createdAt: Date
    public var readAt: Date?
    public var dismissedAt: Date?
    public var snoozedUntil: Date?
    public var deliveredAt: Date?
    public var resolvedAt: Date?

    public init(id: String = UUID().uuidString, agentId: String, source: ProactiveSource, revision: String,
                outcome: ProactiveReportOutcome, reason: String, evidence: String, nextStep: String,
                sessionId: String, createdAt: Date = Date()) {
        self.id = id; self.agentId = agentId; self.source = source; self.revision = revision; self.outcome = outcome
        self.reason = reason; self.evidence = evidence; self.nextStep = nextStep; self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

public struct ProactiveInbox: Codable, Sendable {
    public var findings: [ProactiveFinding]
    public var lastCheckedAt: Date?
    public var pendingAnalysisCount: Int
    public var sourceErrors: [String: String]
    public var lastAnalysisError: String?
    public init(findings: [ProactiveFinding] = [], lastCheckedAt: Date? = nil, pendingAnalysisCount: Int = 0,
                sourceErrors: [String: String] = [:], lastAnalysisError: String? = nil) {
        self.findings = findings; self.lastCheckedAt = lastCheckedAt; self.pendingAnalysisCount = pendingAnalysisCount
        self.sourceErrors = sourceErrors; self.lastAnalysisError = lastAnalysisError
    }
}

public struct ProactiveFindingActionRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case read, snooze, dismiss }
    public var action: Action
    public init(action: Action) { self.action = action }
}

public struct ProactiveSettingsRequest: Codable, Sendable {
    public var heartbeat: AgentHeartbeatSettings
    public var heartbeatMarkdown: String?
    public init(heartbeat: AgentHeartbeatSettings, heartbeatMarkdown: String? = nil) {
        self.heartbeat = heartbeat; self.heartbeatMarkdown = heartbeatMarkdown
    }
}

public struct ProactiveSettingsResponse: Codable, Sendable {
    public var heartbeat: AgentHeartbeatSettings
    public var heartbeatMarkdown: String
    public var availableModels: [ChatModelOption]
    public init(heartbeat: AgentHeartbeatSettings, heartbeatMarkdown: String, availableModels: [ChatModelOption]) {
        self.heartbeat = heartbeat; self.heartbeatMarkdown = heartbeatMarkdown; self.availableModels = availableModels
    }
}

public struct AgentHeartbeatSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var intervalMinutes: Int
    public var mode: AgentHeartbeatMode
    public var proactive: AgentProactiveSettings

    public init(enabled: Bool = false, intervalMinutes: Int? = nil, mode: AgentHeartbeatMode = .checklist,
                proactive: AgentProactiveSettings = .init()) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes ?? (mode == .proactive ? 30 : 5)
        self.mode = mode
        self.proactive = proactive
    }

    private enum CodingKeys: String, CodingKey { case enabled, intervalMinutes, mode, proactive }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            intervalMinutes: try container.decodeIfPresent(Int.self, forKey: .intervalMinutes),
            mode: try container.decodeIfPresent(AgentHeartbeatMode.self, forKey: .mode) ?? .checklist,
            proactive: try container.decodeIfPresent(AgentProactiveSettings.self, forKey: .proactive) ?? .init()
        )
    }
}

