import Foundation
import Protocols

public protocol CorePersistenceBuilding: Sendable {
    func makeStore(config: CoreConfig) -> any PersistenceStore
}

public struct DefaultCorePersistenceBuilder: CorePersistenceBuilding {
    public init() {}

    public func makeStore(config: CoreConfig) -> any PersistenceStore {
        CorePersistenceFactory.makeStore(config: config)
    }
}

public struct InMemoryCorePersistenceBuilder: CorePersistenceBuilding {
    public init() {}

    public func makeStore(config: CoreConfig) -> any PersistenceStore {
        InMemoryPersistenceStore()
    }
}

public actor InMemoryPersistenceStore: PersistenceStore {
    let usageMemoryLedger = UsageMemoryLedger()
    private var proactiveStates: [String: Data] = [:]

    public func loadProactiveState(agentId: String) async throws -> Data? { proactiveStates[agentId] }
    public func saveProactiveState(agentId: String, data: Data) async throws { proactiveStates[agentId] = data }

    private var events: [EventEnvelope] = []
    private var tokenUsages: [(channelId: String, taskId: String?, usage: TokenUsage)] = []
    private var semanticDecisionUsages: [SemanticDecisionUsageRecord] = []
    private var toolInvocations: [PersistedToolInvocationRecord] = []
    private var bulletins: [MemoryBulletin] = []
    private var artifacts: [String: String] = [:]
    private var artifactRecords: [String: PersistedArtifactRecord] = [:]
    private var publishedSites: [String: PersistedPublishedSiteRecord] = [:]
    private var channels: [String: PersistedChannelRecord] = [:]
    private var tasks: [String: PersistedTaskRecord] = [:]
    private var projects: [String: ProjectRecord] = [:]
    private var launchSessions: [String: LaunchSessionState] = [:]

    public func loadLaunchSessions() async throws -> [LaunchSessionState] { Array(launchSessions.values) }
    public func saveLaunchSession(_ state: LaunchSessionState) async throws {
        launchSessions[state.agentID + ":" + state.sessionID] = state
    }
    public func deleteLaunchSession(agentID: String, sessionID: String) async throws {
        launchSessions.removeValue(forKey: agentID + ":" + sessionID)
    }

    private var workspaces: [String: WorkspaceRecord] = [:]
    private var workspaceDocuments: [String: WorkspaceDocument] = [:]
    private var workspaceTransactions: [String: [WorkspaceCommittedTransaction]] = [:]
    private var workspaceMembers: [String: [WorkspaceMember]] = [:]
    private var workspaceTemplates: [String: WorkspaceTemplate] = [:]
    private var initiatives: [String: InitiativeRecord] = [:]
    private var decisionPackets: [String: DecisionPacketRecord] = [:]
    private var selfImprovementProposalReviewJobs: [String: SelfImprovementProposalReviewJob] = [:]
    private var autodreamSessionReviews: [String: AutodreamSessionReviewRecord] = [:]
    private var workflowRuns: [String: WorkflowRun] = [:]
    private var workflowRunSteps: [String: WorkflowRunStep] = [:]
    private var workflowPendingActions: [String: WorkflowPendingAction] = [:]

    public init() {}

    public func persist(event: EventEnvelope) async {
        events.append(event)
        upsertChannel(from: event)
        upsertTask(from: event)
    }

    public func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async {
        tokenUsages.append((channelId: channelId, taskId: taskId, usage: usage))
    }

    public func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> [TokenUsageRecord] {
        var result: [TokenUsageRecord] = []

        for (index, entry) in tokenUsages.enumerated() {
            // Apply filters
            if let channelId, entry.channelId != channelId { continue }
            if let taskId, entry.taskId != taskId { continue }

            // For in-memory store, we don't have exact timestamps per record, use index-based approximation
            // In real implementation, records would have actual timestamps
            let record = TokenUsageRecord(
                id: "mem-\(index)",
                channelId: entry.channelId,
                taskId: entry.taskId,
                promptTokens: entry.usage.prompt,
                completionTokens: entry.usage.completion,
                totalTokens: entry.usage.total,
                cachedInputTokens: entry.usage.cachedInput,
                cacheCreationInputTokens: entry.usage.cacheCreationInput,
                reasoningTokens: entry.usage.reasoning,
                createdAt: Date()
            )
            result.append(record)
        }

        return result
    }

    public func listTokenUsage(channelIds: [String], from: Date?, to: Date?) async -> [TokenUsageRecord] {
        // In-memory store: keep it simple by delegating to per-channel filtering (no timestamps tracked).
        var result: [TokenUsageRecord] = []
        for channelId in channelIds {
            let records = await listTokenUsage(channelId: channelId, taskId: nil, from: from, to: to)
            result.append(contentsOf: records)
        }
        return result
    }

    public func persistSemanticDecisionUsage(record: SemanticDecisionUsageRecord) async {
        semanticDecisionUsages.append(record)
    }

    public func listSemanticDecisionUsage(channelId: String?, from: Date?, to: Date?) async -> [SemanticDecisionUsageRecord] {
        semanticDecisionUsages.filter { record in
            if let channelId, record.channelId != channelId { return false }
            if let from, record.createdAt < from { return false }
            if let to, record.createdAt > to { return false }
            return true
        }
    }

    public func persistToolInvocation(
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
    ) async {
        toolInvocations.append(PersistedToolInvocationRecord(
            id: id,
            projectId: projectId,
            taskId: taskId,
            agentId: agentId,
            sessionId: sessionId,
            tool: tool,
            ok: ok,
            durationMs: durationMs,
            traceId: traceId,
            createdAt: createdAt
        ))
    }

    public func persistProjectEventFact(
        id: String,
        projectId: String,
        channelId: String,
        messageType: String,
        traceId: String?,
        createdAt: Date
    ) async {
        // Intentionally ignored for in-memory store (used for lightweight dev/testing only).
    }

    public func listProjectEventCounts(projectId: String, from: Date?, to: Date?) async -> [String: Int] {
        [:]
    }

    public func listToolInvocationAggregates(projectId: String, from: Date?, to: Date?) async -> [PersistedToolInvocationAggregate] {
        var buckets: [String: (calls: Int, failures: Int, totalDurationMs: Int)] = [:]
        for record in toolInvocations {
            guard record.projectId == projectId else { continue }
            if let from, record.createdAt < from { continue }
            if let to, record.createdAt > to { continue }
            var bucket = buckets[record.tool] ?? (calls: 0, failures: 0, totalDurationMs: 0)
            bucket.calls += 1
            if !record.ok {
                bucket.failures += 1
            }
            bucket.totalDurationMs += record.durationMs ?? 0
            buckets[record.tool] = bucket
        }
        return buckets.map { tool, bucket in
            PersistedToolInvocationAggregate(
                tool: tool,
                calls: bucket.calls,
                failures: bucket.failures,
                totalDurationMs: bucket.totalDurationMs
            )
        }
    }

    public func listToolInvocations(projectId: String?, taskId: String?, limit: Int) async -> [PersistedToolInvocationRecord] {
        let clampedLimit = max(1, min(limit, 500))
        return toolInvocations
            .filter { record in
                if let projectId, record.projectId != projectId { return false }
                if let taskId, record.taskId != taskId { return false }
                return true
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(clampedLimit)
            .map { $0 }
    }

    public func listToolInvocationDurations(projectId: String, from: Date?, to: Date?, limit: Int) async -> [Int] {
        toolInvocations
            .filter { record in
                guard record.projectId == projectId, record.durationMs != nil else { return false }
                if let from, record.createdAt < from { return false }
                if let to, record.createdAt > to { return false }
                return true
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(1, min(limit, 20_000)))
            .compactMap(\.durationMs)
    }

    public func saveWorkflowRun(_ run: WorkflowRun) async {
        workflowRuns[run.id] = run
    }

    public func listWorkflowRuns(projectId: String) async -> [WorkflowRun] {
        workflowRuns.values
            .filter { $0.projectId == projectId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func getWorkflowRun(id: String) async -> WorkflowRun? {
        workflowRuns[id]
    }

    public func saveWorkflowRunStep(_ step: WorkflowRunStep) async {
        workflowRunSteps[step.id] = step
    }

    public func listWorkflowRunSteps(runId: String) async -> [WorkflowRunStep] {
        workflowRunSteps.values
            .filter { $0.runId == runId }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func saveWorkflowPendingAction(_ action: WorkflowPendingAction) async {
        workflowPendingActions[action.id] = action
    }

    public func listWorkflowPendingActions(projectId: String, includeResolved: Bool) async -> [WorkflowPendingAction] {
        workflowPendingActions.values
            .filter { action in
                action.projectId == projectId && (includeResolved || action.resolvedAt == nil)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func listWorkflowPendingActions(runId: String) async -> [WorkflowPendingAction] {
        workflowPendingActions.values
            .filter { $0.workflowRunId == runId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func resolveWorkflowPendingAction(actionId: String, resolvedAt: Date) async -> WorkflowPendingAction? {
        guard var action = workflowPendingActions[actionId] else {
            return nil
        }
        action.resolvedAt = resolvedAt
        workflowPendingActions[actionId] = action
        return action
    }

    public func upsertSelfImprovementProposalReviewJob(
        agentId: String,
        sessionId: String,
        projectId: String,
        reason: String,
        reviewContext: String?,
        nextRunAt: Date
    ) async -> SelfImprovementProposalReviewJob {
        let now = Date()
        if var existing = selfImprovementProposalReviewJobs.values.first(where: {
            $0.agentId == agentId && $0.sessionId == sessionId && $0.reason == reason
        }) {
            existing.projectId = projectId
            existing.reviewContext = reviewContext
            existing.status = "pending"
            existing.nextRunAt = nextRunAt
            existing.updatedAt = now
            existing.lastError = nil
            selfImprovementProposalReviewJobs[existing.id] = existing
            return existing
        }

        let job = SelfImprovementProposalReviewJob(
            id: UUID().uuidString.lowercased(),
            agentId: agentId,
            sessionId: sessionId,
            projectId: projectId,
            reason: reason,
            reviewContext: reviewContext,
            nextRunAt: nextRunAt,
            createdAt: now,
            updatedAt: now
        )
        selfImprovementProposalReviewJobs[job.id] = job
        return job
    }

    public func listSelfImprovementProposalReviewJobs(statuses: [String]?) async -> [SelfImprovementProposalReviewJob] {
        let allowed = statuses.map(Set.init)
        return selfImprovementProposalReviewJobs.values
            .filter { job in allowed?.contains(job.status) ?? true }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func claimNextSelfImprovementProposalReviewJob(now: Date) async -> SelfImprovementProposalReviewJob? {
        guard var job = selfImprovementProposalReviewJobs.values
            .filter({ $0.status == "pending" && $0.nextRunAt <= now })
            .sorted(by: { $0.nextRunAt < $1.nextRunAt })
            .first
        else { return nil }
        job.status = "running"
        job.updatedAt = now
        selfImprovementProposalReviewJobs[job.id] = job
        return job
    }

    public func saveSelfImprovementProposalReviewJob(_ job: SelfImprovementProposalReviewJob) async {
        selfImprovementProposalReviewJobs[job.id] = job
    }

    public func autodreamSessionReview(agentId: String, sessionId: String) async -> AutodreamSessionReviewRecord? {
        autodreamSessionReviews[autodreamSessionReviewKey(agentId: agentId, sessionId: sessionId)]
    }

    public func saveAutodreamSessionReview(_ record: AutodreamSessionReviewRecord) async {
        autodreamSessionReviews[autodreamSessionReviewKey(agentId: record.agentId, sessionId: record.sessionId)] = record
    }

    private func autodreamSessionReviewKey(agentId: String, sessionId: String) -> String {
        "\(agentId)::\(sessionId)"
    }

    public func persistBulletin(_ bulletin: MemoryBulletin) async {
        bulletins.append(bulletin)
    }

    public func listPersistedEvents() async -> [EventEnvelope] {
        events.sorted { left, right in
            if left.ts == right.ts {
                return left.messageId < right.messageId
            }
            return left.ts < right.ts
        }
    }

    public func listChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) async -> [EventEnvelope] {
        guard limit > 0 else {
            return []
        }

        let sorted = events
            .filter { $0.channelId == channelId }
            .sorted { left, right in
                if left.ts == right.ts {
                    return left.messageId > right.messageId
                }
                return left.ts > right.ts
            }

        var result: [EventEnvelope] = []
        result.reserveCapacity(max(limit, 0))

        for event in sorted {
            if let before, !(event.ts < before) {
                continue
            }
            if let after, !(event.ts > after) {
                continue
            }
            if let cursor {
                if event.ts > cursor.createdAt {
                    continue
                }
                if event.ts == cursor.createdAt, event.messageId >= cursor.eventId {
                    continue
                }
            }

            result.append(event)
            if result.count >= limit {
                break
            }
        }

        return result
    }

    public func listPersistedChannels() async -> [PersistedChannelRecord] {
        channels.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func listPersistedTasks() async -> [PersistedTaskRecord] {
        tasks.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func listPersistedArtifacts() async -> [PersistedArtifactRecord] {
        artifactRecords.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func persistArtifact(record: PersistedArtifactRecord) async {
        artifacts[record.id] = record.content
        artifactRecords[record.id] = record
    }

    public func persistArtifact(id: String, content: String) async {
        let record = artifactRecords[id]?.updatingContent(content) ?? PersistedArtifactRecord(
            id: id,
            content: content,
            previewText: String(content.prefix(160)),
            createdAt: Date()
        )
        await persistArtifact(
            record: record
        )
    }

    public func deleteArtifact(id: String) async -> Bool {
        let removedRecord = artifactRecords.removeValue(forKey: id) != nil
        let removedContent = artifacts.removeValue(forKey: id) != nil
        return removedRecord || removedContent
    }

    public func persistedArtifact(id: String) async -> PersistedArtifactRecord? {
        artifactRecords[id]
    }

    public func artifactContent(id: String) async -> String? {
        artifactRecords[id]?.content ?? artifacts[id]
    }

    public func listPublishedSites() async -> [PersistedPublishedSiteRecord] {
        publishedSites.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func publishedSite(id: String) async -> PersistedPublishedSiteRecord? {
        publishedSites[id]
    }

    public func publishedSite(slug: String) async -> PersistedPublishedSiteRecord? {
        publishedSites.values.first { $0.slug == slug }
    }

    public func savePublishedSite(_ site: PersistedPublishedSiteRecord) async {
        publishedSites[site.id] = site
    }

    public func deletePublishedSite(id: String) async -> Bool {
        publishedSites.removeValue(forKey: id) != nil
    }

    public func listBulletins() async -> [MemoryBulletin] {
        bulletins
    }

    public func listProjects() async -> [ProjectRecord] {
        projects.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func listProjectSummaries() async -> [ProjectListRecord] {
        projects.values
            .map(Self.projectListRecord)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func project(id: String) async -> ProjectRecord? {
        projects[id]
    }

    public func saveProject(_ project: ProjectRecord) async {
        projects[project.id] = project
    }

    public func deleteProject(id: String) async {
        projects[id] = nil
    }

    public func listWorkspaces() async -> [WorkspaceRecord] {
        workspaces.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func workspace(id: String) async -> WorkspaceRecord? {
        workspaces[id]
    }

    public func saveWorkspace(_ workspace: WorkspaceRecord) async {
        workspaces[workspace.id] = workspace
    }

    public func workspaceDocument(id: String) async -> WorkspaceDocument? {
        workspaceDocuments[id]
    }

    public func saveWorkspaceDocument(_ document: WorkspaceDocument) async {
        workspaceDocuments[document.workspaceId] = document
    }

    public func listWorkspaceTransactions(workspaceId: String, afterRevision: Int) async -> [WorkspaceCommittedTransaction] {
        (workspaceTransactions[workspaceId] ?? [])
            .filter { $0.revision > afterRevision }
            .sorted { $0.revision < $1.revision }
    }

    public func workspaceTransaction(workspaceId: String, transactionId: String) async -> WorkspaceCommittedTransaction? {
        workspaceTransactions[workspaceId]?.first { $0.id == transactionId }
    }

    public func saveWorkspaceTransaction(_ transaction: WorkspaceCommittedTransaction) async {
        var transactions = workspaceTransactions[transaction.workspaceId] ?? []
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[index] = transaction
        } else {
            transactions.append(transaction)
        }
        workspaceTransactions[transaction.workspaceId] = transactions
    }

    public func listWorkspaceMembers(workspaceId: String) async -> [WorkspaceMember] {
        workspaceMembers[workspaceId] ?? []
    }

    public func saveWorkspaceMember(_ member: WorkspaceMember) async {
        var members = workspaceMembers[member.workspaceId] ?? []
        if let index = members.firstIndex(where: {
            $0.principalKind == member.principalKind && $0.principalId == member.principalId
        }) {
            members[index] = member
        } else {
            members.append(member)
        }
        workspaceMembers[member.workspaceId] = members
    }

    public func deleteWorkspaceMember(
        workspaceId: String,
        principalKind: WorkspacePrincipalKind,
        principalId: String
    ) async {
        workspaceMembers[workspaceId]?.removeAll {
            $0.principalKind == principalKind && $0.principalId == principalId
        }
    }

    public func listWorkspaceTemplates() async -> [WorkspaceTemplate] {
        workspaceTemplates.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveWorkspaceTemplate(_ template: WorkspaceTemplate) async {
        workspaceTemplates[template.id] = template
    }

    public func listInitiatives(projectID: String) async -> [InitiativeRecord] {
        initiatives.values
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func getInitiative(projectID: String, initiativeID: String) async -> InitiativeRecord? {
        guard let record = initiatives[initiativeID], record.projectID == projectID else {
            return nil
        }
        return record
    }

    public func saveInitiative(_ record: InitiativeRecord) async {
        initiatives[record.id] = record
    }

    public func deleteInitiative(projectID: String, initiativeID: String) async -> Bool {
        guard let record = initiatives[initiativeID], record.projectID == projectID else {
            return false
        }
        initiatives[initiativeID] = nil
        decisionPackets = decisionPackets.filter { _, packet in
            !(packet.projectID == projectID && packet.initiativeID == record.id)
        }
        return true
    }

    public func listDecisionPackets(projectID: String, initiativeID: String) async -> [DecisionPacketRecord] {
        decisionPackets.values
            .filter { $0.projectID == projectID && $0.initiativeID == initiativeID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func saveDecisionPacket(_ record: DecisionPacketRecord) async {
        decisionPackets[record.id] = record
    }

    private var cronTasks: [String: AgentCronTask] = [:]
    private var automationRuns: [String: AutomationRun] = [:]

    private static func projectListRecord(_ project: ProjectRecord) -> ProjectListRecord {
        var counts = ProjectTaskCountSummary(total: project.tasks.count)
        for task in project.tasks {
            switch ProjectTaskStatus(rawValue: task.status) {
            case .backlog: counts.backlog += 1
            case .ready: counts.ready += 1
            case .inProgress: counts.inProgress += 1
            case .waitingInput: counts.waitingInput += 1
            case .blocked: counts.blocked += 1
            case .needsReview: counts.needsReview += 1
            case .done: counts.done += 1
            default: break
            }
        }
        return ProjectListRecord(
            id: project.id,
            name: project.name,
            description: project.description,
            icon: project.icon,
            kind: project.kind,
            directoryPaths: project.directoryPaths,
            channels: project.channels,
            actors: project.actors,
            teams: project.teams,
            repoPath: project.repoPath,
            worktreeRootPath: project.worktreeRootPath,
            sourceControlProviderId: project.sourceControlProviderId,
            taskCounts: counts,
            isFavorite: project.isFavorite,
            isArchived: project.isArchived,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    public func listCronTasks(agentId: String) async -> [AgentCronTask] {
        cronTasks.values.filter { $0.agentId == agentId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func listAllCronTasks() async -> [AgentCronTask] {
        cronTasks.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func cronTask(id: String) async -> AgentCronTask? {
        cronTasks[id]
    }

    public func saveCronTask(_ task: AgentCronTask) async {
        cronTasks[task.id] = task
    }

    public func deleteCronTask(id: String) async {
        cronTasks[id] = nil
    }

    public func listAutomationRuns(projectId: String) async -> [AutomationRun] {
        automationRuns.values
            .filter { $0.projectId == projectId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func listAutomationRuns(automationId: String) async -> [AutomationRun] {
        automationRuns.values
            .filter { $0.automationId == automationId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func getAutomationRun(id: String) async -> AutomationRun? {
        automationRuns[id]
    }

    public func saveAutomationRun(_ run: AutomationRun) async {
        automationRuns[run.id] = run
    }

    private var channelPlugins: [String: ChannelPluginRecord] = [:]
    private var agentPlugins: [String: InstalledAgentPlugin] = [:]
    private var agentPluginRegistries: [String: AgentPluginRegistry] = [:]

    public func listChannelPlugins() async -> [ChannelPluginRecord] {
        channelPlugins.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func channelPlugin(id: String) async -> ChannelPluginRecord? {
        channelPlugins[id]
    }

    public func saveChannelPlugin(_ plugin: ChannelPluginRecord) async {
        channelPlugins[plugin.id] = plugin
    }

    public func deleteChannelPlugin(id: String) async {
        channelPlugins[id] = nil
    }

    public func listAgentPlugins() async -> [InstalledAgentPlugin] {
        agentPlugins.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func agentPlugin(id: String) async -> InstalledAgentPlugin? { agentPlugins[id] }

    public func saveAgentPlugin(_ plugin: InstalledAgentPlugin) async { agentPlugins[plugin.id] = plugin }

    public func deleteAgentPlugin(id: String) async { agentPlugins[id] = nil }

    public func listAgentPluginRegistries() async -> [AgentPluginRegistry] {
        agentPluginRegistries.values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func saveAgentPluginRegistry(_ registry: AgentPluginRegistry) async {
        if registry.isDefault {
            for key in agentPluginRegistries.keys {
                agentPluginRegistries[key]?.isDefault = false
            }
        }
        agentPluginRegistries[registry.id] = registry
    }

    public func deleteAgentPluginRegistry(id: String) async { agentPluginRegistries[id] = nil }

    private var clarifications: [String: TaskClarificationRecord] = [:]

    public func listClarifications(projectId: String, taskId: String) async -> [TaskClarificationRecord] {
        clarifications.values
            .filter { $0.projectId == projectId && $0.taskId == taskId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func clarification(id: String) async -> TaskClarificationRecord? {
        clarifications[id]
    }

    public func saveClarification(_ record: TaskClarificationRecord) async {
        clarifications[record.id] = record
    }

    public func deleteClarification(id: String) async {
        clarifications[id] = nil
    }

    private var accessUsers: [String: ChannelAccessUser] = [:]

    public func listChannelAccessUsers(platform: String?) async -> [ChannelAccessUser] {
        let all = accessUsers.values.sorted { $0.createdAt < $1.createdAt }
        guard let platform else { return all }
        return all.filter { $0.platform == platform }
    }

    public func channelAccessUser(platform: String, platformUserId: String) async -> ChannelAccessUser? {
        accessUsers.values.first { $0.platform == platform && $0.platformUserId == platformUserId }
    }

    public func saveChannelAccessUser(_ user: ChannelAccessUser) async {
        if let existing = accessUsers.values.first(where: { $0.platform == user.platform && $0.platformUserId == user.platformUserId }) {
            accessUsers[existing.id] = nil
        }
        accessUsers[user.id] = user
    }

    public func deleteChannelAccessUser(id: String) async {
        accessUsers[id] = nil
    }

    private func upsertChannel(from event: EventEnvelope) {
        if var existing = channels[event.channelId] {
            existing.updatedAt = max(existing.updatedAt, event.ts)
            channels[event.channelId] = existing
            return
        }

        channels[event.channelId] = PersistedChannelRecord(
            id: event.channelId,
            createdAt: event.ts,
            updatedAt: event.ts
        )
    }

    private func upsertTask(from event: EventEnvelope) {
        guard let taskId = event.taskId, !taskId.isEmpty else {
            return
        }

        let now = event.ts
        let payload = event.payload.objectValue
        let inferredStatus = inferredTaskStatus(from: event.messageType)
        let incomingTitle = payload["title"]?.stringValue ?? payload["progress"]?.stringValue
        let incomingObjective = payload["objective"]?.stringValue

        if var existing = tasks[taskId] {
            existing.channelId = event.channelId
            existing.status = inferredStatus ?? existing.status
            if let incomingTitle, !incomingTitle.isEmpty {
                existing.title = incomingTitle
            }
            if let incomingObjective, !incomingObjective.isEmpty {
                existing.objective = incomingObjective
            }
            existing.updatedAt = max(existing.updatedAt, now)
            tasks[taskId] = existing
            return
        }

        tasks[taskId] = PersistedTaskRecord(
            id: taskId,
            channelId: event.channelId,
            status: inferredStatus ?? "unknown",
            title: incomingTitle ?? "Task \(taskId)",
            objective: incomingObjective ?? "",
            createdAt: now,
            updatedAt: now
        )
    }

    private func inferredTaskStatus(from messageType: MessageType) -> String? {
        switch messageType {
        case .workerSpawned:
            "queued"
        case .workerProgress:
            "running"
        case .workerCompleted:
            "completed"
        case .workerFailed:
            "failed"
        default:
            nil
        }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

enum CorePersistenceFactory {
    static func makeStore(config: CoreConfig) -> any PersistenceStore {
        SQLiteStore(path: config.sqlitePath, schemaSQL: loadSchemaSQL())
    }

    @discardableResult
    static func prepareSQLiteDatabaseIfNeeded(config: CoreConfig) -> String? {
        guard !FileManager.default.fileExists(atPath: config.sqlitePath) else {
            return nil
        }
        return SQLiteStore.prepareDatabase(path: config.sqlitePath, schemaSQL: loadSchemaSQL())
    }

    private static func loadSchemaSQL() -> String {
        let fileManager = FileManager.default
        let executablePath = CommandLine.arguments.first ?? ""
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        let candidatePaths = [
            cwd.appendingPathComponent("Sources/sloppy/Storage/schema.sql").path,
            executableDirectory.appendingPathComponent("Sources/sloppy/Storage/schema.sql").path,
            cwd.appendingPathComponent("Sloppy_sloppy.resources/schema.sql").path,
            cwd.appendingPathComponent("Sloppy_sloppy.bundle/schema.sql").path,
            executableDirectory.appendingPathComponent("Sloppy_sloppy.resources/schema.sql").path,
            executableDirectory.appendingPathComponent("Sloppy_sloppy.bundle/schema.sql").path
        ]

        for candidatePath in candidatePaths where fileManager.fileExists(atPath: candidatePath) {
            if let schema = try? String(contentsOfFile: candidatePath, encoding: .utf8), !schema.isEmpty {
                return schema
            }
        }

        return embeddedSchemaSQL
    }

    private static let embeddedSchemaSQL =
        """
        CREATE TABLE IF NOT EXISTS session_launch_state (
            agent_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY (agent_id, session_id)
        );

        CREATE TABLE IF NOT EXISTS channels (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            status TEXT NOT NULL,
            title TEXT NOT NULL,
            objective TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY,
            message_type TEXT NOT NULL,
            channel_id TEXT NOT NULL,
            task_id TEXT,
            branch_id TEXT,
            worker_id TEXT,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_events_channel_created ON events(channel_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_events_task_created ON events(task_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS artifacts (
            id TEXT PRIMARY KEY,
            title TEXT,
            kind TEXT,
            media_type TEXT,
            content TEXT NOT NULL,
            preview_text TEXT,
            widget_size TEXT,
            widget_width INTEGER,
            widget_height INTEGER,
            widget_entry TEXT,
            bundle_path TEXT,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_bulletins (
            id TEXT PRIMARY KEY,
            headline TEXT NOT NULL,
            digest TEXT NOT NULL,
            items_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_entries (
            id TEXT PRIMARY KEY,
            class TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            summary TEXT,
            scope_type TEXT NOT NULL,
            scope_id TEXT NOT NULL,
            channel_id TEXT,
            project_id TEXT,
            agent_id TEXT,
            importance REAL NOT NULL DEFAULT 0.5,
            confidence REAL NOT NULL DEFAULT 0.7,
            source_type TEXT,
            source_id TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            expires_at TEXT,
            deleted_at TEXT
        );

        CREATE TABLE IF NOT EXISTS memory_edges (
            id TEXT PRIMARY KEY,
            from_memory_id TEXT NOT NULL,
            to_memory_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            provenance TEXT,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_provider_outbox (
            id TEXT PRIMARY KEY,
            memory_id TEXT NOT NULL,
            op TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            attempt INTEGER NOT NULL DEFAULT 0,
            next_retry_at TEXT NOT NULL,
            last_error TEXT,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_recall_log (
            id TEXT PRIMARY KEY,
            query TEXT NOT NULL,
            scope_type TEXT,
            scope_id TEXT,
            top_k INTEGER NOT NULL,
            result_ids_json TEXT NOT NULL,
            latency_ms INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(
            id UNINDEXED,
            text,
            summary
        );

        CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_time ON memory_entries(scope_type, scope_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memory_entries_kind ON memory_entries(kind);
        CREATE INDEX IF NOT EXISTS idx_memory_entries_class ON memory_entries(class);
        CREATE INDEX IF NOT EXISTS idx_memory_entries_expires ON memory_entries(expires_at);
        CREATE INDEX IF NOT EXISTS idx_memory_edges_from ON memory_edges(from_memory_id);
        CREATE INDEX IF NOT EXISTS idx_memory_edges_to ON memory_edges(to_memory_id);
        CREATE INDEX IF NOT EXISTS idx_memory_outbox_retry ON memory_provider_outbox(next_retry_at, attempt);

        CREATE TABLE IF NOT EXISTS autodream_session_reviews (
            agent_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            status TEXT NOT NULL,
            reason TEXT NOT NULL,
            session_updated_at TEXT NOT NULL,
            reviewed_at TEXT NOT NULL,
            last_error TEXT,
            PRIMARY KEY(agent_id, session_id)
        );

        CREATE INDEX IF NOT EXISTS idx_autodream_session_reviews_status_reviewed
        ON autodream_session_reviews(status, reviewed_at DESC);

        CREATE TABLE IF NOT EXISTS token_usage (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            task_id TEXT,
            prompt_tokens INTEGER NOT NULL,
            completion_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS semantic_decision_usage (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cost_usd REAL NOT NULL,
            cost_is_estimated INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_semantic_decision_usage_created_at
        ON semantic_decision_usage(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_semantic_decision_usage_channel_created_at
        ON semantic_decision_usage(channel_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS tool_invocations (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            task_id TEXT,
            agent_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            tool TEXT NOT NULL,
            ok INTEGER NOT NULL,
            duration_ms INTEGER,
            trace_id TEXT,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_tool_invocations_project_created ON tool_invocations(project_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_tool_invocations_task_created ON tool_invocations(task_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_tool_invocations_tool_created ON tool_invocations(tool, created_at DESC);

        CREATE TABLE IF NOT EXISTS workflow_runs (
            id TEXT PRIMARY KEY,
            workflow_id TEXT NOT NULL,
            workflow_version INTEGER NOT NULL,
            project_id TEXT NOT NULL,
            task_id TEXT,
            status TEXT NOT NULL,
            current_node_ids_json TEXT NOT NULL,
            started_by TEXT NOT NULL,
            started_at TEXT NOT NULL,
            finished_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_workflow_runs_project ON workflow_runs(project_id, started_at DESC);

        CREATE TABLE IF NOT EXISTS workflow_run_steps (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            status TEXT NOT NULL,
            input_json TEXT NOT NULL,
            output_json TEXT NOT NULL,
            error TEXT,
            started_at TEXT NOT NULL,
            finished_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_workflow_run_steps_run ON workflow_run_steps(run_id, started_at ASC);

        CREATE TABLE IF NOT EXISTS workflow_pending_actions (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            workflow_run_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            task_id TEXT,
            assignee TEXT NOT NULL,
            prompt TEXT NOT NULL,
            decisions_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            resolved_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_workflow_pending_actions_project ON workflow_pending_actions(project_id, resolved_at, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_workflow_pending_actions_run ON workflow_pending_actions(workflow_run_id);

        CREATE TABLE IF NOT EXISTS project_event_facts (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            channel_id TEXT NOT NULL,
            message_type TEXT NOT NULL,
            trace_id TEXT,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_project_event_facts_project_created ON project_event_facts(project_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_project_event_facts_project_type_created ON project_event_facts(project_id, message_type, created_at DESC);

        CREATE TABLE IF NOT EXISTS dashboard_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            actors_json TEXT NOT NULL DEFAULT '[]',
            teams_json TEXT NOT NULL DEFAULT '[]',
            project_kind TEXT NOT NULL DEFAULT 'project',
            directory_paths_json TEXT NOT NULL DEFAULT '[]',
            task_sync_settings_json TEXT NOT NULL DEFAULT '{}',
            is_favorite INTEGER NOT NULL DEFAULT 0,
            source_control_provider_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS dashboard_project_channels (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            title TEXT NOT NULL,
            channel_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE(project_id, channel_id)
        );

        CREATE INDEX IF NOT EXISTS idx_dashboard_project_channels_project ON dashboard_project_channels(project_id);

        CREATE TABLE IF NOT EXISTS dashboard_project_tasks (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            priority TEXT NOT NULL,
            status TEXT NOT NULL,
            actor_id TEXT,
            team_id TEXT,
            claimed_actor_id TEXT,
            claimed_agent_id TEXT,
            parent_task_id TEXT,
            swarm_id TEXT,
            swarm_task_id TEXT,
            swarm_parent_task_id TEXT,
            swarm_dependency_ids_json TEXT NOT NULL DEFAULT '[]',
            swarm_depth INTEGER,
            swarm_actor_path_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            worktree_branch TEXT,
            source_control_provider_id TEXT,
            kind TEXT,
            loop_mode_override TEXT,
            origin_type TEXT,
            origin_channel_id TEXT,
            is_archived INTEGER NOT NULL DEFAULT 0,
            selected_model TEXT,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            external_metadata_json TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]',
            kanban_column_entered_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_dashboard_project_tasks_project ON dashboard_project_tasks(project_id);

        CREATE TABLE IF NOT EXISTS project_initiatives (
            id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            title TEXT NOT NULL,
            goal TEXT NOT NULL,
            phase TEXT NOT NULL,
            execution_mode TEXT NOT NULL,
            success_metrics_json TEXT NOT NULL DEFAULT '[]',
            constraints_json TEXT NOT NULL DEFAULT '[]',
            resume_point TEXT,
            blocker TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (project_id, id)
        );

        CREATE INDEX IF NOT EXISTS idx_project_initiatives_project ON project_initiatives(project_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS initiative_decision_packets (
            id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            initiative_id TEXT NOT NULL,
            summary TEXT NOT NULL,
            rationale TEXT NOT NULL,
            tradeoffs_json TEXT NOT NULL DEFAULT '[]',
            requested_action TEXT NOT NULL,
            resume_point TEXT,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (project_id, id)
        );

        CREATE INDEX IF NOT EXISTS idx_initiative_decision_packets_initiative
            ON initiative_decision_packets(project_id, initiative_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS channel_plugins (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            base_url TEXT NOT NULL,
            channel_ids_json TEXT NOT NULL DEFAULT '[]',
            config_json TEXT NOT NULL DEFAULT '{}',
            enabled INTEGER NOT NULL DEFAULT 1,
            delivery_mode TEXT NOT NULL DEFAULT 'http',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS agent_plugins (
            id TEXT PRIMARY KEY,
            record_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS agent_plugin_registries (
            id TEXT PRIMARY KEY,
            record_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS task_clarifications (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            target_type TEXT NOT NULL DEFAULT 'human',
            target_actor_id TEXT,
            target_channel_id TEXT,
            question_text TEXT NOT NULL,
            options_json TEXT NOT NULL DEFAULT '[]',
            allow_note INTEGER NOT NULL DEFAULT 1,
            created_by_agent_id TEXT,
            selected_option_ids_json TEXT NOT NULL DEFAULT '[]',
            note TEXT,
            created_at TEXT NOT NULL,
            answered_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_task_clarifications_task ON task_clarifications(project_id, task_id);

        CREATE TABLE IF NOT EXISTS channel_access_users (
            id TEXT PRIMARY KEY,
            platform TEXT NOT NULL,
            platform_user_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(platform, platform_user_id)
        );

        CREATE INDEX IF NOT EXISTS idx_channel_access_users_platform ON channel_access_users(platform, status);
        """
}
