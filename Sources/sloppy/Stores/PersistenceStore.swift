import Foundation
import Protocols

public struct PersistedChannelRecord: Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersistedTaskRecord: Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var status: String
    public var title: String
    public var objective: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        channelId: String,
        status: String,
        title: String,
        objective: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.channelId = channelId
        self.status = status
        self.title = title
        self.objective = objective
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersistedArtifactRecord: Sendable, Equatable {
    public var id: String
    public var title: String
    public var kind: String
    public var mediaType: String
    public var content: String
    public var previewText: String?
    public var widgetSize: String?
    public var widgetWidth: Int?
    public var widgetHeight: Int?
    public var widgetEntry: String?
    public var bundlePath: String?
    public var createdAt: Date

    public init(
        id: String,
        title: String? = nil,
        kind: String = "document",
        mediaType: String = "text/plain",
        content: String,
        previewText: String? = nil,
        widgetSize: String? = nil,
        widgetWidth: Int? = nil,
        widgetHeight: Int? = nil,
        widgetEntry: String? = nil,
        bundlePath: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.title = title ?? id
        self.kind = kind
        self.mediaType = mediaType
        self.content = content
        self.previewText = previewText
        self.widgetSize = widgetSize
        self.widgetWidth = widgetWidth
        self.widgetHeight = widgetHeight
        self.widgetEntry = widgetEntry
        self.bundlePath = bundlePath
        self.createdAt = createdAt
    }

    public func updatingContent(_ content: String) -> PersistedArtifactRecord {
        PersistedArtifactRecord(
            id: id,
            title: title,
            kind: kind,
            mediaType: mediaType,
            content: content,
            previewText: String(content.prefix(160)),
            widgetSize: widgetSize,
            widgetWidth: widgetWidth,
            widgetHeight: widgetHeight,
            widgetEntry: widgetEntry,
            bundlePath: bundlePath,
            createdAt: createdAt
        )
    }
}

public struct PersistedPublishedSiteRecord: Sendable, Equatable {
    public var id: String
    public var slug: String
    public var title: String
    public var visibility: PublishedSiteVisibility
    public var ownerId: String
    public var projectId: String?
    public var entryFile: String
    public var bundlePath: String
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        slug: String,
        title: String,
        visibility: PublishedSiteVisibility,
        ownerId: String,
        projectId: String? = nil,
        entryFile: String,
        bundlePath: String,
        revision: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.visibility = visibility
        self.ownerId = ownerId
        self.projectId = projectId
        self.entryFile = entryFile
        self.bundlePath = bundlePath
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersistedEventCursor: Sendable, Equatable {
    public var createdAt: Date
    public var eventId: String

    public init(createdAt: Date, eventId: String) {
        self.createdAt = createdAt
        self.eventId = eventId
    }
}

public struct PersistedToolInvocationAggregate: Sendable, Equatable {
    public var tool: String
    public var calls: Int
    public var failures: Int
    public var totalDurationMs: Int

    public init(tool: String, calls: Int, failures: Int, totalDurationMs: Int) {
        self.tool = tool
        self.calls = calls
        self.failures = failures
        self.totalDurationMs = totalDurationMs
    }
}

public struct PersistedToolInvocationRecord: Sendable, Equatable {
    public var id: String
    public var projectId: String?
    public var taskId: String?
    public var agentId: String
    public var sessionId: String
    public var tool: String
    public var ok: Bool
    public var durationMs: Int?
    public var traceId: String?
    public var createdAt: Date

    public init(
        id: String,
        projectId: String?,
        taskId: String?,
        agentId: String,
        sessionId: String,
        tool: String,
        ok: Bool,
        durationMs: Int?,
        traceId: String?,
        createdAt: Date
    ) {
        self.id = id
        self.projectId = projectId
        self.taskId = taskId
        self.agentId = agentId
        self.sessionId = sessionId
        self.tool = tool
        self.ok = ok
        self.durationMs = durationMs
        self.traceId = traceId
        self.createdAt = createdAt
    }
}

public struct SelfImprovementProposalReviewJob: Sendable, Equatable {
    public var id: String
    public var agentId: String
    public var sessionId: String
    public var projectId: String
    public var reason: String
    public var reviewContext: String?
    public var status: String
    public var attempts: Int
    public var nextRunAt: Date
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        agentId: String,
        sessionId: String,
        projectId: String,
        reason: String,
        reviewContext: String? = nil,
        status: String = "pending",
        attempts: Int = 0,
        nextRunAt: Date = Date(),
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.projectId = projectId
        self.reason = reason
        self.reviewContext = reviewContext
        self.status = status
        self.attempts = attempts
        self.nextRunAt = nextRunAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AutodreamSessionReviewRecord: Sendable, Equatable {
    public var agentId: String
    public var sessionId: String
    public var status: String
    public var reason: String
    public var sessionUpdatedAt: Date
    public var reviewedAt: Date
    public var lastError: String?

    public init(
        agentId: String,
        sessionId: String,
        status: String,
        reason: String,
        sessionUpdatedAt: Date,
        reviewedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.agentId = agentId
        self.sessionId = sessionId
        self.status = status
        self.reason = reason
        self.sessionUpdatedAt = sessionUpdatedAt
        self.reviewedAt = reviewedAt
        self.lastError = lastError
    }
}

public struct ChannelAccessUser: Codable, Sendable, Equatable {
    public var id: String
    public var platform: String
    public var platformUserId: String
    public var displayName: String
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        platform: String,
        platformUserId: String,
        displayName: String,
        status: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.platformUserId = platformUserId
        self.displayName = displayName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol PersistenceStore: Sendable {
    func persistUsageRequest(_ record: UsageRequestRecord) async throws
    func usageBreakdown(_ query: UsageBreakdownQuery) async throws -> UsageBreakdownResponse
    func updateUsageToolOutcome(channelId: String, callId: String, ok: Bool) async throws

    func loadLaunchSessions() async throws -> [LaunchSessionState]
    func saveLaunchSession(_ state: LaunchSessionState) async throws
    func deleteLaunchSession(agentID: String, sessionID: String) async throws

    /// Atomic per-agent snapshot, decisions, analysis queue and durable attention inbox.
    func loadProactiveState(agentId: String) async throws -> Data?
    func saveProactiveState(agentId: String, data: Data) async throws

    /// Persists protocol-level event envelopes emitted by the runtime.
    func persist(event: EventEnvelope) async

    /// Persists token accounting for a channel/task execution slice.
    func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async

    /// Lists token usage records with optional filters.
    func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> [TokenUsageRecord]

    /// Lists token usage records across a set of channels (used for project analytics).
    func listTokenUsage(channelIds: [String], from: Date?, to: Date?) async -> [TokenUsageRecord]

    /// Persists the billed usage of one semantic-decision request.
    func persistSemanticDecisionUsage(record: SemanticDecisionUsageRecord) async

    /// Lists semantic-decision calls for a channel or time range.
    func listSemanticDecisionUsage(channelId: String?, from: Date?, to: Date?) async -> [SemanticDecisionUsageRecord]

    /// Persists a tool invocation analytics row (duration, ok/error, tracing correlation).
    func persistToolInvocation(
        id: String,
        projectId: String?,
        taskId: String?,
        agentId: String,
        sessionId: String,
        tool: String,
        ok: Bool,
        durationMs: Int?,
        traceId: String?,
        createdAt: Date
    ) async

    /// Persists a runtime event fact for project-level analytics.
    func persistProjectEventFact(
        id: String,
        projectId: String,
        channelId: String,
        messageType: String,
        traceId: String?,
        createdAt: Date
    ) async

    /// Lists counts of tracked runtime events for a project within optional date range.
    func listProjectEventCounts(projectId: String, from: Date?, to: Date?) async -> [String: Int]

    /// Lists tool invocation aggregates grouped by tool id for a project within optional date range.
    func listToolInvocationAggregates(projectId: String, from: Date?, to: Date?) async -> [PersistedToolInvocationAggregate]

    /// Lists recent tool invocation rows for a project/task timeline.
    func listToolInvocations(projectId: String?, taskId: String?, limit: Int) async -> [PersistedToolInvocationRecord]

    /// Creates or replaces one workflow run record.
    func saveWorkflowRun(_ run: WorkflowRun) async

    /// Lists workflow runs for a project ordered newest first.
    func listWorkflowRuns(projectId: String) async -> [WorkflowRun]

    /// Returns one workflow run by identifier.
    func getWorkflowRun(id: String) async -> WorkflowRun?

    /// Creates or replaces one workflow run step record.
    func saveWorkflowRunStep(_ step: WorkflowRunStep) async

    /// Lists workflow run steps ordered by start time.
    func listWorkflowRunSteps(runId: String) async -> [WorkflowRunStep]

    /// Creates or replaces one workflow pending action.
    func saveWorkflowPendingAction(_ action: WorkflowPendingAction) async

    /// Lists workflow pending actions for a project.
    func listWorkflowPendingActions(projectId: String, includeResolved: Bool) async -> [WorkflowPendingAction]

    /// Lists workflow pending actions for a run.
    func listWorkflowPendingActions(runId: String) async -> [WorkflowPendingAction]

    /// Marks a workflow pending action as resolved.
    func resolveWorkflowPendingAction(actionId: String, resolvedAt: Date) async -> WorkflowPendingAction?

    /// Inserts or updates a pending self-improvement proposal review job.
    func upsertSelfImprovementProposalReviewJob(
        agentId: String,
        sessionId: String,
        projectId: String,
        reason: String,
        reviewContext: String?,
        nextRunAt: Date
    ) async -> SelfImprovementProposalReviewJob

    /// Lists self-improvement proposal review jobs, optionally filtered by status.
    func listSelfImprovementProposalReviewJobs(statuses: [String]?) async -> [SelfImprovementProposalReviewJob]

    /// Claims one due pending self-improvement proposal review job.
    func claimNextSelfImprovementProposalReviewJob(now: Date) async -> SelfImprovementProposalReviewJob?

    /// Saves a self-improvement proposal review job lifecycle update.
    func saveSelfImprovementProposalReviewJob(_ job: SelfImprovementProposalReviewJob) async

    /// Returns the latest autodream review state for one agent session.
    func autodreamSessionReview(agentId: String, sessionId: String) async -> AutodreamSessionReviewRecord?

    /// Creates or replaces the autodream review state for one agent session.
    func saveAutodreamSessionReview(_ record: AutodreamSessionReviewRecord) async

    /// Lists tool invocation durations (ms) for percentile computation.
    func listToolInvocationDurations(projectId: String, from: Date?, to: Date?, limit: Int) async -> [Int]

    /// Persists a generated memory bulletin.
    func persistBulletin(_ bulletin: MemoryBulletin) async

    /// Lists persisted events in replay-safe order (oldest first).
    func listPersistedEvents() async -> [EventEnvelope]

    /// Lists persisted events for one channel ordered by newest first.
    func listChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) async -> [EventEnvelope]

    /// Lists persisted channels in creation order.
    func listPersistedChannels() async -> [PersistedChannelRecord]

    /// Lists persisted worker/task records in creation order.
    func listPersistedTasks() async -> [PersistedTaskRecord]

    /// Lists persisted artifacts in creation order.
    func listPersistedArtifacts() async -> [PersistedArtifactRecord]

    /// Persists a complete artifact record by identifier.
    func persistArtifact(record: PersistedArtifactRecord) async

    /// Persists an artifact payload by artifact identifier.
    func persistArtifact(id: String, content: String) async

    /// Removes a persisted artifact by identifier.
    func deleteArtifact(id: String) async -> Bool

    /// Returns artifact metadata by identifier when available.
    func persistedArtifact(id: String) async -> PersistedArtifactRecord?

    /// Returns artifact content by identifier when available.
    func artifactContent(id: String) async -> String?

    /// Lists published site metadata ordered by update time.
    func listPublishedSites() async -> [PersistedPublishedSiteRecord]

    /// Returns published site metadata by identifier.
    func publishedSite(id: String) async -> PersistedPublishedSiteRecord?

    /// Returns published site metadata by public slug.
    func publishedSite(slug: String) async -> PersistedPublishedSiteRecord?

    /// Creates or replaces published site metadata.
    func savePublishedSite(_ site: PersistedPublishedSiteRecord) async

    /// Removes published site metadata by identifier.
    func deletePublishedSite(id: String) async -> Bool

    /// Lists recent memory bulletins from persistence.
    func listBulletins() async -> [MemoryBulletin]

    /// Lists dashboard projects with embedded channels and tasks.
    func listProjects() async -> [ProjectRecord]

    /// Lists dashboard projects with metadata and task counts only.
    func listProjectSummaries() async -> [ProjectListRecord]

    /// Returns one dashboard project by identifier.
    func project(id: String) async -> ProjectRecord?

    /// Creates or replaces one dashboard project.
    func saveProject(_ project: ProjectRecord) async

    /// Deletes one dashboard project and all nested records.
    func deleteProject(id: String) async

    /// Lists canvas workspaces ordered by most recently updated.
    func listWorkspaces() async -> [WorkspaceRecord]

    /// Returns one canvas workspace by identifier.
    func workspace(id: String) async -> WorkspaceRecord?

    /// Creates or replaces canvas workspace metadata.
    func saveWorkspace(_ workspace: WorkspaceRecord) async

    /// Returns the latest durable workspace document snapshot.
    func workspaceDocument(id: String) async -> WorkspaceDocument?

    /// Creates or replaces the latest workspace document snapshot.
    func saveWorkspaceDocument(_ document: WorkspaceDocument) async

    /// Lists committed workspace transactions after a revision.
    func listWorkspaceTransactions(workspaceId: String, afterRevision: Int) async -> [WorkspaceCommittedTransaction]

    /// Returns a committed transaction by client-provided id for idempotency.
    func workspaceTransaction(workspaceId: String, transactionId: String) async -> WorkspaceCommittedTransaction?

    /// Persists one committed workspace transaction.
    func saveWorkspaceTransaction(_ transaction: WorkspaceCommittedTransaction) async

    /// Lists workspace access members.
    func listWorkspaceMembers(workspaceId: String) async -> [WorkspaceMember]

    /// Creates or replaces one workspace member.
    func saveWorkspaceMember(_ member: WorkspaceMember) async

    /// Removes one workspace member.
    func deleteWorkspaceMember(workspaceId: String, principalKind: WorkspacePrincipalKind, principalId: String) async

    /// Lists user-created workspace templates.
    func listWorkspaceTemplates() async -> [WorkspaceTemplate]

    /// Creates or replaces one workspace template.
    func saveWorkspaceTemplate(_ template: WorkspaceTemplate) async

    /// Lists durable initiative records for one project.
    func listInitiatives(projectID: String) async -> [InitiativeRecord]

    /// Returns one initiative record when present.
    func getInitiative(projectID: String, initiativeID: String) async -> InitiativeRecord?

    /// Creates or replaces one initiative record.
    func saveInitiative(_ record: InitiativeRecord) async

    /// Deletes one initiative and its nested decision packets.
    func deleteInitiative(projectID: String, initiativeID: String) async -> Bool

    /// Lists decision packets for one initiative ordered by creation time.
    func listDecisionPackets(projectID: String, initiativeID: String) async -> [DecisionPacketRecord]

    /// Creates or replaces one decision packet.
    func saveDecisionPacket(_ record: DecisionPacketRecord) async

    /// Lists all channel plugin records.
    func listChannelPlugins() async -> [ChannelPluginRecord]

    /// Returns one channel plugin by identifier.
    func channelPlugin(id: String) async -> ChannelPluginRecord?

    /// Creates or replaces one channel plugin record.
    func saveChannelPlugin(_ plugin: ChannelPluginRecord) async

    /// Deletes one channel plugin record.
    func deleteChannelPlugin(id: String) async

    /// Lists installed Agent Plugin bundles.
    func listAgentPlugins() async -> [InstalledAgentPlugin]

    /// Returns one installed Agent Plugin bundle.
    func agentPlugin(id: String) async -> InstalledAgentPlugin?

    /// Creates or replaces one installed Agent Plugin bundle.
    func saveAgentPlugin(_ plugin: InstalledAgentPlugin) async

    /// Deletes one installed Agent Plugin bundle.
    func deleteAgentPlugin(id: String) async

    /// Lists configured read-only Agent Plugin registries.
    func listAgentPluginRegistries() async -> [AgentPluginRegistry]

    /// Creates or replaces one Agent Plugin registry.
    func saveAgentPluginRegistry(_ registry: AgentPluginRegistry) async

    /// Deletes one Agent Plugin registry.
    func deleteAgentPluginRegistry(id: String) async

    /// Lists cron tasks for an agent.
    func listCronTasks(agentId: String) async -> [AgentCronTask]

    /// Lists all cron tasks across all agents.
    func listAllCronTasks() async -> [AgentCronTask]

    /// Returns one cron task by identifier.
    func cronTask(id: String) async -> AgentCronTask?

    /// Creates or replaces one cron task record.
    func saveCronTask(_ task: AgentCronTask) async

    /// Deletes one cron task record.
    func deleteCronTask(id: String) async

    /// Lists automation runs for a project ordered by newest first.
    func listAutomationRuns(projectId: String) async -> [AutomationRun]

    /// Lists automation runs for one automation ordered by newest first.
    func listAutomationRuns(automationId: String) async -> [AutomationRun]

    /// Returns one automation run by identifier.
    func getAutomationRun(id: String) async -> AutomationRun?

    /// Creates or replaces one automation run record.
    func saveAutomationRun(_ run: AutomationRun) async

    /// Lists all channel access user records, optionally filtered by platform.
    func listChannelAccessUsers(platform: String?) async -> [ChannelAccessUser]

    /// Returns one channel access user record by platform + platformUserId.
    func channelAccessUser(platform: String, platformUserId: String) async -> ChannelAccessUser?

    /// Creates or replaces one channel access user record.
    func saveChannelAccessUser(_ user: ChannelAccessUser) async

    /// Deletes one channel access user record.
    func deleteChannelAccessUser(id: String) async

    /// Lists clarification requests for a task.
    func listClarifications(projectId: String, taskId: String) async -> [TaskClarificationRecord]

    /// Returns one clarification request by identifier.
    func clarification(id: String) async -> TaskClarificationRecord?

    /// Creates or replaces one clarification request record.
    func saveClarification(_ record: TaskClarificationRecord) async

    /// Deletes one clarification request record.
    func deleteClarification(id: String) async
}
