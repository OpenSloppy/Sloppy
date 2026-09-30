import Foundation

public struct OverviewData: Sendable, Equatable {
    public var projects: [ProjectSummary]
    public var agents: [AgentOverview]
    public var activeTasks: Int
    public var completedTasks: Int

    public init(
        projects: [ProjectSummary] = [],
        agents: [AgentOverview] = [],
        activeTasks: Int = 0,
        completedTasks: Int = 0
    ) {
        self.projects = projects
        self.agents = agents
        self.activeTasks = activeTasks
        self.completedTasks = completedTasks
    }
}

public struct ProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var channelCount: Int
    public var taskCount: Int
    public var activeTaskCount: Int

    public init(
        id: String,
        name: String,
        description: String = "",
        channelCount: Int = 0,
        taskCount: Int = 0,
        activeTaskCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.channelCount = channelCount
        self.taskCount = taskCount
        self.activeTaskCount = activeTaskCount
    }
}

public struct AgentOverview: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var role: String

    public init(id: String, displayName: String, role: String = "") {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public enum APIProjectKind: String, Codable, Sendable, Equatable, CaseIterable {
    case project
    case workspace
}

public struct APIProjectRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var icon: String?
    public var kind: APIProjectKind
    public var directoryPaths: [String]
    public var repoPath: String?
    public var worktreeRootPath: String?
    public var channels: [APIProjectChannel]?
    public var tasks: [APIProjectTask]?
    public var actors: [String]?
    public var teams: [String]?
    public var isFavorite: Bool
    public var isArchived: Bool
    public var sourceInstanceID: String?

    public var storageID: String {
        guard let sourceInstanceID else { return id }
        return InstanceScopedID(instanceID: sourceInstanceID, localID: id).description
    }

    public var projectRootPath: String? {
        directoryPaths.first ?? worktreeRootPath ?? repoPath
    }

    public var semanticIconName: String {
        let customIcon = icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customIcon, let systemIcon = Self.systemIconNames[customIcon] {
            return systemIcon
        }
        return kind == .workspace ? "square.stack.3d.up" : "folder"
    }

    private static let systemIconNames: [String: String] = [
        "folder": "folder",
        "rocket_launch": "paperplane",
        "code": "chevron.left.forwardslash.chevron.right",
        "terminal": "terminal",
        "science": "flask",
        "deployed_code": "shippingbox",
        "bug_report": "ladybug",
        "psychology": "brain",
        "smart_toy": "cpu",
        "extension": "puzzlepiece.extension",
        "database": "cylinder",
        "cloud": "cloud",
        "language": "globe",
        "brush": "paintbrush",
        "analytics": "chart.xyaxis.line",
        "school": "graduationcap",
        "build": "hammer",
        "architecture": "ruler",
        "api": "network",
        "hub": "point.3.connected.trianglepath.dotted",
        "storage": "internaldrive",
        "monitoring": "waveform.path.ecg",
        "security": "shield",
        "memory": "memorychip",
        "web": "globe",
    ]

    public init(
        id: String,
        name: String,
        description: String = "",
        icon: String? = nil,
        kind: APIProjectKind = .project,
        directoryPaths: [String] = [],
        repoPath: String? = nil,
        worktreeRootPath: String? = nil,
        channels: [APIProjectChannel]? = nil,
        tasks: [APIProjectTask]? = nil,
        actors: [String]? = nil,
        teams: [String]? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        sourceInstanceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.kind = kind
        self.directoryPaths = directoryPaths
        self.repoPath = repoPath
        self.worktreeRootPath = worktreeRootPath
        self.channels = channels
        self.tasks = tasks
        self.actors = actors
        self.teams = teams
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.sourceInstanceID = sourceInstanceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, icon, kind, directoryPaths, repoPath, worktreeRootPath
        case channels, tasks, actors, teams, isFavorite, isArchived, sourceInstanceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        kind = try container.decodeIfPresent(APIProjectKind.self, forKey: .kind) ?? .project
        directoryPaths = try container.decodeIfPresent([String].self, forKey: .directoryPaths) ?? []
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath)
        worktreeRootPath = try container.decodeIfPresent(String.self, forKey: .worktreeRootPath)
        channels = try container.decodeIfPresent([APIProjectChannel].self, forKey: .channels)
        tasks = try container.decodeIfPresent([APIProjectTask].self, forKey: .tasks)
        actors = try container.decodeIfPresent([String].self, forKey: .actors)
        teams = try container.decodeIfPresent([String].self, forKey: .teams)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        sourceInstanceID = try container.decodeIfPresent(String.self, forKey: .sourceInstanceID)
    }
}

public struct APIProjectCreateRequest: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var idea: String?
    public var repoUrl: String?
    public var repoPath: String?
    public var kind: APIProjectKind
    public var directoryPaths: [String]

    public init(
        name: String,
        description: String? = nil,
        idea: String? = nil,
        repoUrl: String? = nil,
        repoPath: String? = nil,
        kind: APIProjectKind = .project,
        directoryPaths: [String] = []
    ) {
        self.name = name
        self.description = description
        self.idea = idea
        self.repoUrl = repoUrl
        self.repoPath = repoPath
        self.kind = kind
        self.directoryPaths = directoryPaths
    }
}

public struct APIProjectCreateResult: Codable, Sendable {
    public var project: APIProjectRecord
    public var repoCloneSucceeded: Bool?

    public init(project: APIProjectRecord, repoCloneSucceeded: Bool? = nil) {
        self.project = project
        self.repoCloneSucceeded = repoCloneSucceeded
    }
}

public struct APIProjectUpdateRequest: Codable, Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var kind: APIProjectKind?
    public var directoryPaths: [String]?
    public var isFavorite: Bool?
    public var isArchived: Bool?

    public init(
        name: String? = nil,
        description: String? = nil,
        kind: APIProjectKind? = nil,
        directoryPaths: [String]? = nil,
        isFavorite: Bool? = nil,
        isArchived: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.directoryPaths = directoryPaths
        self.isFavorite = isFavorite
        self.isArchived = isArchived
    }
}

public struct APIProjectTaskCreateRequest: Codable, Sendable, Equatable {
    public var title: String
    public var description: String?
    public var priority: String
    public var status: String?
    public var actorId: String?
    public var executionNodeId: String?
    public var tags: [String]?

    public init(
        title: String,
        description: String? = nil,
        priority: String = "medium",
        status: String? = nil,
        actorId: String? = nil,
        executionNodeId: String? = nil,
        tags: [String]? = nil
    ) {
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.actorId = actorId
        self.executionNodeId = executionNodeId
        self.tags = tags
    }
}

public struct APIProjectTaskUpdateRequest: Codable, Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var priority: String?
    public var status: String?
    public var actorId: String?
    public var executionNodeId: String?
    public var tags: [String]?

    public init(
        title: String? = nil,
        description: String? = nil,
        priority: String? = nil,
        status: String? = nil,
        actorId: String? = nil,
        executionNodeId: String? = nil,
        tags: [String]? = nil
    ) {
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.actorId = actorId
        self.executionNodeId = executionNodeId
        self.tags = tags
    }
}

public struct APIProjectChannel: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channelId: String

    public init(id: String, title: String, channelId: String) {
        self.id = id
        self.title = title
        self.channelId = channelId
    }
}

public struct APIProjectTaskExternalStatus: Codable, Sendable, Equatable {
    public var display: String?
}

public struct APIProjectTaskExternalMetadata: Codable, Sendable, Equatable {
    public var externalAssignee: String?
    public var providerId: String?
    public var externalIssueKey: String?
    public var externalIssueURL: String?
    public var externalStatus: APIProjectTaskExternalStatus?
    public var syncState: String?

    public init(externalAssignee: String? = nil, providerId: String? = nil,
                externalIssueKey: String? = nil, externalIssueURL: String? = nil,
                externalStatus: APIProjectTaskExternalStatus? = nil, syncState: String? = nil) {
        self.externalAssignee = externalAssignee
        self.providerId = providerId
        self.externalIssueKey = externalIssueKey
        self.externalIssueURL = externalIssueURL
        self.externalStatus = externalStatus
        self.syncState = syncState
    }
}

public struct APIProjectTask: Codable, Sendable, Identifiable {
    public var parentTaskId: String?
    public var dependsOnTaskIds: [String]?
    public var worktreeBranch: String?
    public var id: String
    public var title: String
    public var status: String
    public var priority: String?
    public var actorId: String?
    public var executionNodeId: String?
    public var description: String?
    public var claimedActorId: String?
    public var claimedAgentId: String?
    public var createdBy: String?
    public var tags: [String]?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var kanbanColumnEnteredAt: Date?
    public var externalMetadata: APIProjectTaskExternalMetadata?

    public init(
        id: String,
        title: String,
        status: String,
        priority: String? = nil,
        actorId: String? = nil,
        executionNodeId: String? = nil,
        description: String? = nil,
        claimedActorId: String? = nil,
        claimedAgentId: String? = nil,
        createdBy: String? = nil,
        tags: [String]? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        kanbanColumnEnteredAt: Date? = nil,
        externalMetadata: APIProjectTaskExternalMetadata? = nil
    ) {
        self.parentTaskId = nil
        self.dependsOnTaskIds = nil
        self.worktreeBranch = nil
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.actorId = actorId
        self.executionNodeId = executionNodeId
        self.description = description
        self.claimedActorId = claimedActorId
        self.claimedAgentId = claimedAgentId
        self.createdBy = createdBy
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kanbanColumnEnteredAt = kanbanColumnEnteredAt
        self.externalMetadata = externalMetadata
    }
}

public struct TaskComment: Codable, Sendable, Identifiable, Equatable {
    public var kind: String?
    public var externalMetadata: APIProjectTaskExternalMetadata?
    public var effectiveKind: String { kind ?? (authorActorId == "system" ? "technical" : "user_comment") }
    public var isTechnical: Bool { effectiveKind == "technical" }
    public var id: String
    public var taskId: String
    public var content: String
    public var authorActorId: String
    public var mentionedActorId: String?
    public var isAgentReply: Bool
    public var sourceAuthor: String?
    public var createdAt: Date

    public init(
        id: String,
        taskId: String,
        content: String,
        authorActorId: String,
        mentionedActorId: String? = nil,
        isAgentReply: Bool = false,
        sourceAuthor: String? = nil,
        createdAt: Date,
        kind: String? = nil,
        externalMetadata: APIProjectTaskExternalMetadata? = nil
    ) {
        self.kind = kind
        self.externalMetadata = externalMetadata
        self.id = id
        self.taskId = taskId
        self.content = content
        self.authorActorId = authorActorId
        self.mentionedActorId = mentionedActorId
        self.isAgentReply = isAgentReply
        self.sourceAuthor = sourceAuthor
        self.createdAt = createdAt
    }
}

public enum ProjectKanbanColumnID: String, CaseIterable, Hashable, Sendable {
    case todo
    case inProgress
    case needsReview
    case done
    case other

    public var title: String {
        switch self {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .needsReview: "Needs Review"
        case .done: "Done"
        case .other: "Other"
        }
    }

    public var taskStatus: String {
        switch self {
        case .todo: "ready"
        case .inProgress: "in_progress"
        case .needsReview: "needs_review"
        case .done: "done"
        case .other: "blocked"
        }
    }
}

public struct APIAgentRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var role: String
    public var isSystem: Bool?
    public var pet: APIAgentBotPet?

    public init(id: String, displayName: String, role: String = "", isSystem: Bool? = nil, pet: APIAgentBotPet? = nil) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isSystem = isSystem
        self.pet = pet
    }
}

public struct AgentChatSlashCommandItem: Codable, Sendable, Equatable {
    public var source: String
    public var name: String
    public var description: String
    public var argument: String?
    public var skillId: String?
    public var displayName: String?

    public init(
        source: String,
        name: String,
        description: String,
        argument: String? = nil,
        skillId: String? = nil,
        displayName: String? = nil
    ) {
        self.source = source
        self.name = name
        self.description = description
        self.argument = argument
        self.skillId = skillId
        self.displayName = displayName
    }
}

public struct AgentChatSlashCommandsResponse: Codable, Sendable, Equatable {
    public var commands: [AgentChatSlashCommandItem]

    public init(commands: [AgentChatSlashCommandItem]) {
        self.commands = commands
    }
}

public struct APIAgentTaskRecord: Codable, Sendable, Identifiable {
    public var projectId: String
    public var projectName: String
    public var task: APIProjectTask

    public var id: String { "\(projectId)/\(task.id)" }

    public init(projectId: String, projectName: String, task: APIProjectTask) {
        self.projectId = projectId
        self.projectName = projectName
        self.task = task
    }
}

private let activeStatuses: Set<String> = ["in_progress", "ready", "needs_review"]

public extension APIProjectRecord {
    /// Only tasks in the canonical In Progress column; nil means tasks are not loaded.
    var inProgressTaskCount: Int? {
        tasks.map { $0.count { $0.normalizedKanbanColumnID == .inProgress } }
    }

    func toSummary() -> ProjectSummary {
        let allTasks = tasks ?? []
        let active = allTasks.filter { activeStatuses.contains($0.status) }
        return ProjectSummary(
            id: id,
            name: name,
            description: description,
            channelCount: channels?.count ?? 0,
            taskCount: allTasks.count,
            activeTaskCount: active.count
        )
    }
}

public extension APIProjectTask {
    /// A worker claim takes precedence over the planned assignment.
    var kanbanAssigneeID: String? {
        [claimedActorId, claimedAgentId, actorId, externalMetadata?.externalAssignee]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    var normalizedKanbanColumnID: ProjectKanbanColumnID {
        switch status {
        case "todo", "backlog", "ready":
            return .todo
        case "in_progress":
            return .inProgress
        case "needs_review":
            return .needsReview
        case "done":
            return .done
        default:
            return .other
        }
    }
}

public extension APIAgentRecord {
    func toOverview() -> AgentOverview {
        AgentOverview(id: id, displayName: displayName, role: role)
    }
}
