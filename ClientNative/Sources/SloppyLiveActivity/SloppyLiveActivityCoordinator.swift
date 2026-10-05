#if os(iOS)
@preconcurrency import ActivityKit
import Foundation
import SloppyClientCore

@MainActor
public final class SloppyLiveActivityCoordinator {
    private var apiClient = SloppyAPIClient()
    private var baseURL: URL?
    private var refreshTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?
    private var activity: Activity<SloppyActivityAttributes>?
    private var approval: SloppyActivityApproval?
    private var displayedError: SloppyActivityError?
    private var agentRuns: [SloppyActivityAgentRun] = []
    private var tasks: [SloppyActivityTask] = []
    private var agentRunCache: [String: AgentRunCacheEntry] = [:]

    public init() {
        activity = Activity<SloppyActivityAttributes>.activities.first
    }

    deinit {
        refreshTask?.cancel()
        errorDismissTask?.cancel()
    }

    public func start(baseURL: URL) {
        if self.baseURL != baseURL {
            self.baseURL = baseURL
            apiClient = SloppyAPIClient(baseURL: baseURL)
            agentRunCache.removeAll()
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func applicationDidBecomeActive() {
        guard baseURL != nil else { return }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    public func apply(_ notification: AppNotification) {
        switch notification.type {
        case .toolApproval:
            applyToolApproval(notification)
        case .agentError, .systemError:
            showError(title: notification.title, message: notification.message)
        case .confirmation, .pendingApproval, .proactiveAttention:
            break
        }
    }

    private func refresh() async {
        async let projectsRequest = apiClient.fetchProjects()
        async let agentsRequest = apiClient.fetchAgents()

        let projects = try? await projectsRequest
        let agents = try? await agentsRequest

        if let projects {
            tasks = projects.flatMap { project in
                (project.tasks ?? []).compactMap { task -> SloppyActivityTask? in
                    let status: SloppyActivityTask.Status
                    switch task.normalizedKanbanColumnID {
                    case .inProgress:
                        status = .inProgress
                    case .needsReview:
                        status = .needsReview
                    case .todo, .done, .other:
                        return nil
                    }
                    return SloppyActivityTask(
                        id: "\(project.id)/\(task.id)",
                        title: task.title,
                        projectName: project.name,
                        status: status
                    )
                }
            }
        }
        if let agents {
            agentRuns = await fetchActiveAgentRuns(for: agents)
        }

        reconcileApprovalIntentResult()
        await publish()
    }

    private func fetchActiveAgentRuns(for agents: [APIAgentRecord]) async -> [SloppyActivityAgentRun] {
        let sessionsByAgent = await withTaskGroup(
            of: (APIAgentRecord, [ChatSessionSummary]).self,
            returning: [(APIAgentRecord, [ChatSessionSummary])].self
        ) { group in
            for agent in agents {
                group.addTask { [apiClient] in
                    let sessions = (try? await apiClient.fetchAgentSessions(
                        agentId: agent.id,
                        limit: 8
                    )) ?? []
                    return (agent, sessions)
                }
            }

            var result: [(APIAgentRecord, [ChatSessionSummary])] = []
            for await item in group {
                result.append(item)
            }
            return result
        }

        let cachedRuns = agentRunCache
        let lookups = await withTaskGroup(
            of: AgentRunLookup.self,
            returning: [AgentRunLookup].self
        ) { group in
            for (agent, sessions) in sessionsByAgent {
                for session in sessions {
                    let cacheID = "\(agent.id)/\(session.id)"
                    group.addTask { [apiClient] in
                        if let cached = cachedRuns[cacheID], cached.updatedAt == session.updatedAt {
                            return AgentRunLookup(
                                id: cacheID,
                                updatedAt: session.updatedAt,
                                run: cached.run
                            )
                        }
                        guard let detail = try? await apiClient.fetchAgentSession(
                            agentId: agent.id,
                            sessionId: session.id
                        ),
                        let status = detail.latestRunStatus,
                        status.stage.isWorking else {
                            return AgentRunLookup(
                                id: cacheID,
                                updatedAt: session.updatedAt,
                                run: nil
                            )
                        }
                        let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let statusText = details?.isEmpty == false ? details! : status.label
                        return AgentRunLookup(
                            id: cacheID,
                            updatedAt: session.updatedAt,
                            run: SloppyActivityAgentRun(
                                id: cacheID,
                                sessionTitle: session.displayTitle,
                                agentName: agent.displayName,
                                status: statusText
                            )
                        )
                    }
                }
            }

            var result: [AgentRunLookup] = []
            for await lookup in group {
                result.append(lookup)
            }
            return result
        }

        agentRunCache = Dictionary(uniqueKeysWithValues: lookups.map {
            ($0.id, AgentRunCacheEntry(updatedAt: $0.updatedAt, run: $0.run))
        })
        return lookups
            .filter { $0.run != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap(\.run)
    }

    private func applyToolApproval(_ notification: AppNotification) {
        guard let approvalID = notification.metadata["approvalId"] else { return }
        let status = notification.metadata["status"] ?? "pending"
        if status == "pending" {
            approval = SloppyActivityApproval(
                id: approvalID,
                title: notification.title,
                message: notification.message,
                toolName: notification.metadata["tool"]
            )
            displayedError = nil
        } else if approval?.id == approvalID {
            approval = nil
            displayedError = nil
        }
        Task { [weak self] in
            await self?.publish()
        }
    }

    private func showError(title: String, message: String) {
        displayedError = SloppyActivityError(title: title, message: message)
        errorDismissTask?.cancel()
        errorDismissTask = Task { [weak self] in
            await self?.publish()
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.displayedError = nil
            await self?.publish()
        }
    }

    private func reconcileApprovalIntentResult() {
        guard let approval, let activity else { return }
        let activityState = activity.content.state
        if activityState.approval?.id != approval.id {
            self.approval = nil
            displayedError = nil
        } else if let error = activityState.error {
            displayedError = error
        }
    }

    private func publish() async {
        guard let baseURL else { return }
        let state = SloppyActivityContentState(
            agentRuns: agentRuns,
            tasks: tasks,
            agentRunCount: agentRuns.count,
            taskCount: tasks.count,
            approval: approval,
            error: displayedError
        )

        if state.isEmpty {
            guard let activity else { return }
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
            self.activity = nil
            return
        }

        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(30)
        )
        if let activity {
            await activity.update(content)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: SloppyActivityAttributes(serverURL: baseURL.absoluteString),
                content: content,
                pushType: nil
            )
        } catch {
            // ActivityKit can reject a start request while the app isn't foreground-active.
            // The next foreground refresh retries with the latest snapshot.
        }
    }
}

private struct AgentRunCacheEntry: Sendable {
    var updatedAt: Date
    var run: SloppyActivityAgentRun?
}

private struct AgentRunLookup: Sendable {
    var id: String
    var updatedAt: Date
    var run: SloppyActivityAgentRun?
}
#endif
