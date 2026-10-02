import Foundation

public enum LongChatTaskStatus: String, Codable, Sendable, Equatable {
    case queued, running, completed, failed, cancelled
    case waitingInput = "waiting_input"

    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public struct LongChatTaskRequest: Codable, Sendable, Equatable {
    public var key: String
    public var title: String
    public var objective: String
    public var resourceKeys: [String]
    public var dependsOn: [String]
    public var projectId: String?
    public var readOnly: Bool?

    public init(
        key: String, title: String, objective: String, resourceKeys: [String] = [], dependsOn: [String] = [],
        projectId: String? = nil, readOnly: Bool? = nil
    ) {
        self.readOnly = readOnly
        self.key = key
        self.title = title
        self.objective = objective
        self.resourceKeys = resourceKeys
        self.dependsOn = dependsOn
        self.projectId = projectId
    }
}

public struct LongChatDelegationRequest: Codable, Sendable {
    public var requestKey: String
    public var title: String
    public var acceptanceCriteria: String
    public var tasks: [LongChatTaskRequest]
    public init(requestKey: String, title: String, acceptanceCriteria: String, tasks: [LongChatTaskRequest]) {
        self.requestKey = requestKey
        self.title = title
        self.acceptanceCriteria = acceptanceCriteria
        self.tasks = tasks
    }
}

public struct LongChatAttempt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var number: Int
    public var workerId: String?
    public var sessionId: String?
    public var status: LongChatTaskStatus
    public var summary: String?
    public var evidence: [String]
    public var artifacts: [String]
    public var selectedModel: String?
    public var automaticRetryAllowed: Bool?
    public var executionStopped: Bool?
    public var blockedByTaskId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(number: Int) {
        id = UUID().uuidString
        self.number = number
        status = .queued
        evidence = []
        artifacts = []
        createdAt = Date()
        updatedAt = createdAt
    }
}

public struct LongChatTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var key: String
    public var title: String
    public var objective: String
    public var projectId: String?
    public var resourceKeys: [String]
    public var dependsOn: [String]
    public var attempts: [LongChatAttempt]
    public var readOnly: Bool?
    public var status: LongChatTaskStatus { attempts.last?.status ?? .queued }
    public init(
        id: String, key: String, title: String, objective: String, projectId: String?, resourceKeys: [String],
        dependsOn: [String], attempts: [LongChatAttempt], readOnly: Bool? = nil
    ) {
        self.readOnly = readOnly
        self.id = id
        self.key = key
        self.title = title
        self.objective = objective
        self.projectId = projectId
        self.resourceKeys = resourceKeys
        self.dependsOn = dependsOn
        self.attempts = attempts
    }
}

public struct LongChatAssignment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sourceMessageId: String
    public var requestKey: String
    public var title: String
    public var acceptanceCriteria: String
    public var tasks: [LongChatTask]
    public var createdAt: Date
    public var isTerminal: Bool { tasks.allSatisfy { $0.status.isTerminal } }
    public init(
        id: String, sourceMessageId: String, requestKey: String, title: String, acceptanceCriteria: String,
        tasks: [LongChatTask], createdAt: Date
    ) {
        self.id = id
        self.sourceMessageId = sourceMessageId
        self.requestKey = requestKey
        self.title = title
        self.acceptanceCriteria = acceptanceCriteria
        self.tasks = tasks
        self.createdAt = createdAt
    }
}

public struct LongChatConversation: Codable, Sendable, Equatable {
    public var agentId: String
    public var userId: String
    public var sessionId: String
    public var assignments: [LongChatAssignment]
    public var projectId: String?
    public init(agentId: String, userId: String, sessionId: String, assignments: [LongChatAssignment], projectId: String? = nil) {
        self.agentId = agentId
        self.userId = userId
        self.sessionId = sessionId
        self.assignments = assignments
        self.projectId = projectId
    }
}

public struct LongChatOpenRequest: Codable, Sendable {
    public var userId: String
    public var projectId: String?
    public init(userId: String, projectId: String? = nil) {
        self.userId = userId
        self.projectId = projectId
    }
}

public struct LongChatTaskMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String
    public var clientMessageId: String?
    public init(userId: String, content: String, clientMessageId: String? = nil) {
        self.userId = userId
        self.content = content
        self.clientMessageId = clientMessageId
    }
}

public struct LongChatTaskEvent: Codable, Sendable, Equatable {
    public var assignmentId: String
    public var task: LongChatTask
    public var reason: String
    public var inputRequest: PlanInputRequest?
    public init(assignmentId: String, task: LongChatTask, reason: String, inputRequest: PlanInputRequest? = nil) {
        self.assignmentId = assignmentId
        self.task = task
        self.reason = reason
        self.inputRequest = inputRequest
    }
}
