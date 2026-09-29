import Foundation
#if canImport(AppKit)
import AppKit
#endif
import AgentRuntime
import Protocols
import PluginSDK
import Logging

private struct ProjectWorktreeInput {
    var id: String
    var repoPath: String?
    var worktreeRootPath: String?
}

private struct ProjectGitWorktreeMetadata {
    var gitDirectory: String
    var commonDirectory: String
    var branch: String?

    var isWorktree: Bool {
        gitDirectory != commonDirectory
    }
}

private struct ProjectComputedWorktreeMetadata {
    var parentProjectId: String?
    var worktreeBranch: String?
    var isWorktree: Bool
}

// MARK: - Projects

extension CoreService {
    public struct ProjectChannelLinkConflict: Error {
        public let ownerProjectId: String
        public let ownerProjectName: String
        public let channelId: String
    }

    /// Synthetic `projectId` for `/v1/projects/:id/files/...` when the UI should search the workspace `projects/` directory (all project folders) rather than one project root.
    static let sloppyProjectsDirectoryScopeID = "_sloppyProjectsRoot"

    private static let projectContextBootstrapMarker = "[project_context_bootstrap_v1]"

    private func requiresCompletionConfirmation(changedBy: String) -> Bool {
        let normalized = changedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        return normalized != "user"
    }

    private func normalizedCompletionNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    public func listProjects() async -> [ProjectRecord] {
        computedWorktreeMetadataProjects(await store.listProjects().map(projectWithRuntimePaths))
    }

    public func listProjectSummaries() async -> [ProjectListRecord] {
        computedWorktreeMetadataSummaries(await store.listProjectSummaries().map(projectSummaryWithRuntimePaths))
    }

    /// Lists token usage records with optional filters and aggregates.
    public func listTokenUsage(
        channelId: String? = nil,
        taskId: String? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) async -> TokenUsageResponse {
        let records = await store.listTokenUsage(channelId: channelId, taskId: taskId, from: from, to: to)
        let totalPrompt = records.reduce(0) { $0 + $1.promptTokens }
        let totalCompletion = records.reduce(0) { $0 + $1.completionTokens }
        let total = records.reduce(0) { $0 + $1.totalTokens }
        let totalCachedInput = records.reduce(0) { $0 + $1.cachedInputTokens }
        let totalCacheCreationInput = records.reduce(0) { $0 + $1.cacheCreationInputTokens }
        let totalReasoning = records.reduce(0) { $0 + $1.reasoningTokens }
        let measuredSemanticDecisionUsage = await semanticDecisionUsageMeter.snapshot(channelID: channelId)
        let semanticDecisionUsage = measuredSemanticDecisionUsage
            ?? (currentConfig.semanticDecisions.provider == nil ? nil : SemanticDecisionUsage())
        return TokenUsageResponse(
            items: records,
            totalPromptTokens: totalPrompt,
            totalCompletionTokens: totalCompletion,
            totalTokens: total,
            totalCachedInputTokens: totalCachedInput,
            totalCacheCreationInputTokens: totalCacheCreationInput,
            totalReasoningTokens: totalReasoning,
            semanticDecisionUsage: semanticDecisionUsage
        )
    }

    /// Returns the recorded JEV spend grouped by UTC day for the selected period.
    public func semanticDecisionSpending(from: Date?, to: Date?) async -> SemanticDecisionSpendingResponse {
        let records = await store.listSemanticDecisionUsage(channelId: nil, from: from, to: to)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var total = SemanticDecisionUsage()
        var usageByDay: [String: SemanticDecisionUsage] = [:]

        for record in records {
            let day = String(formatter.string(from: record.createdAt).prefix(10))
            var daily = usageByDay[day] ?? SemanticDecisionUsage()
            daily.requestCount += 1
            daily.inputTokens += record.inputTokens
            daily.outputTokens += record.outputTokens
            daily.totalCostUSD += record.costUSD
            if record.costIsEstimated {
                daily.estimatedCostUSD += record.costUSD
            }
            usageByDay[day] = daily

            total.requestCount += 1
            total.inputTokens += record.inputTokens
            total.outputTokens += record.outputTokens
            total.totalCostUSD += record.costUSD
            if record.costIsEstimated {
                total.estimatedCostUSD += record.costUSD
            }
        }

        return SemanticDecisionSpendingResponse(
            total: total,
            days: usageByDay.keys.sorted().map { SemanticDecisionSpendingDay(day: $0, usage: usageByDay[$0] ?? SemanticDecisionUsage()) }
        )
    }

    public func projectAnalytics(projectID: String, query: ProjectAnalyticsQuery) async throws -> ProjectAnalyticsResponse {
        let project = try await getProject(id: projectID)

        let now = Date()
        let rangeFrom: Date?
        let rangeTo: Date?

        switch query.window {
        case .last24h:
            rangeFrom = query.from ?? Calendar.current.date(byAdding: .hour, value: -24, to: now)
            rangeTo = query.to ?? now
        case .last7d:
            rangeFrom = query.from ?? Calendar.current.date(byAdding: .day, value: -7, to: now)
            rangeTo = query.to ?? now
        case .all:
            rangeFrom = query.from
            rangeTo = query.to
        }

        let runtimeCounts = await store.listProjectEventCounts(projectId: project.id, from: rangeFrom, to: rangeTo)

        let outcome = ProjectTaskOutcomeCounts(
            total: project.tasks.count,
            success: project.tasks.filter { $0.status == ProjectTaskStatus.done.rawValue }.count,
            failed: project.tasks.filter { $0.status == ProjectTaskStatus.blocked.rawValue }.count,
            interrupted: project.tasks.filter { $0.status == ProjectTaskStatus.cancelled.rawValue }.count
        )

        let aggregates = await store.listToolInvocationAggregates(projectId: project.id, from: rangeFrom, to: rangeTo)
        let totalCalls = aggregates.reduce(0) { $0 + $1.calls }
        let totalFailures = aggregates.reduce(0) { $0 + $1.failures }
        let totalDuration = aggregates.reduce(0) { $0 + $1.totalDurationMs }
        let avgDurationMs: Int? = totalCalls > 0 ? Int(Double(totalDuration) / Double(totalCalls)) : nil
        let failureRate = totalCalls > 0 ? Double(totalFailures) / Double(totalCalls) : 0

        let durations = await store.listToolInvocationDurations(projectId: project.id, from: rangeFrom, to: rangeTo, limit: 5000).sorted()
        let p50 = percentile(sorted: durations, p: 0.50)
        let p95 = percentile(sorted: durations, p: 0.95)

        let toolAggs: [ProjectToolStats.ToolAggregate] = aggregates.map { agg in
            let avg = agg.calls > 0 ? Int(Double(agg.totalDurationMs) / Double(agg.calls)) : nil
            return .init(tool: agg.tool, calls: agg.calls, failures: agg.failures, avgDurationMs: avg)
        }

        let topByTime = toolAggs
            .sorted { (lhs, rhs) in
                let lhsTotal = (lhs.avgDurationMs ?? 0) * lhs.calls
                let rhsTotal = (rhs.avgDurationMs ?? 0) * rhs.calls
                if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
                return lhs.tool < rhs.tool
            }
            .prefix(8)

        let topFailing = toolAggs
            .sorted { (lhs, rhs) in
                if lhs.failures != rhs.failures { return lhs.failures > rhs.failures }
                return lhs.tool < rhs.tool
            }
            .prefix(8)

        let toolStats = ProjectToolStats(
            totalCalls: totalCalls,
            totalFailures: totalFailures,
            failureRate: failureRate,
            avgDurationMs: avgDurationMs,
            p50DurationMs: p50,
            p95DurationMs: p95,
            topToolsByTime: Array(topByTime),
            topFailingTools: Array(topFailing)
        )

        let channelIds = project.channels.map { $0.channelId }
        let tokenRecords = await store.listTokenUsage(channelIds: channelIds, from: rangeFrom, to: rangeTo)
        let tokenTotals = ProjectTokenUsageTotals(
            totalPromptTokens: tokenRecords.reduce(0) { $0 + $1.promptTokens },
            totalCompletionTokens: tokenRecords.reduce(0) { $0 + $1.completionTokens },
            totalTokens: tokenRecords.reduce(0) { $0 + $1.totalTokens },
            totalCachedInputTokens: tokenRecords.reduce(0) { $0 + $1.cachedInputTokens },
            totalCacheCreationInputTokens: tokenRecords.reduce(0) { $0 + $1.cacheCreationInputTokens },
            totalReasoningTokens: tokenRecords.reduce(0) { $0 + $1.reasoningTokens }
        )

        return ProjectAnalyticsResponse(
            projectId: project.id,
            window: query.window,
            from: rangeFrom,
            to: rangeTo,
            runtimeEventCounts: runtimeCounts,
            taskOutcomes: outcome,
            tools: toolStats,
            tokenUsage: tokenTotals,
            isPartial: false,
            notes: []
        )
    }

    private func percentile(sorted: [Int], p: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let clamped = max(0, min(p, 1))
        let idx = Int(round(clamped * Double(sorted.count - 1)))
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    /// Lists runtime event timeline for a channel (newest first) with cursor pagination.
    public func getProject(id: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(id) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        return projectWithRuntimePaths(project)
    }

    public func listProjectFiles(projectID: String, path: String) async throws -> [ProjectFileEntry] {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.notFound
        }
        let project = await store.project(id: normalizedID)
        let rootURLs = try await resolveProjectWorkspaceRoots(projectID: normalizedID)
        guard let rootURL = rootURLs.first else { throw ProjectError.notFound }

        let targetURL: URL
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if project?.kind == .workspace, trimmedPath.isEmpty || trimmedPath == "/" {
            return rootURLs.map { root in
                ProjectFileEntry(
                    name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent,
                    path: root.path,
                    type: .directory
                )
            }
        }
        if trimmedPath.isEmpty || trimmedPath == "/" {
            targetURL = rootURL
        } else if trimmedPath.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: trimmedPath, isDirectory: true).standardizedFileURL
        } else {
            targetURL = rootURL.appendingPathComponent(trimmedPath).standardized
        }

        guard rootURLs.contains(where: { isProjectURL(targetURL, inside: $0) }) else {
            throw ProjectError.invalidProjectID
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.notFound
        }

        let contents = try fm.contentsOfDirectory(at: targetURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var entries: [ProjectFileEntry] = []
        for url in contents {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize
            entries.append(ProjectFileEntry(
                name: url.lastPathComponent,
                path: project?.kind == .workspace || trimmedPath.hasPrefix("/") ? url.standardizedFileURL.path : nil,
                type: isDirectory ? .directory : .file,
                size: isDirectory ? nil : size
            ))
        }
        entries.sort {
            if $0.type == $1.type { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.type == .directory
        }
        return entries
    }

    /// Returns project-relative paths whose full path matches the search string (substring, case-insensitive), ranked for autocomplete.
    public func searchProjectFiles(projectID: String, query: String, limit: Int) async throws -> [ProjectFileSearchEntry] {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        let rootURLs = try await resolveProjectWorkspaceRoots(projectID: normalizedID)
        guard let rootURL = rootURLs.first else { throw ProjectError.notFound }

        let fm = FileManager.default
        var isRootDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isRootDir), isRootDir.boolValue else {
            throw ProjectError.notFound
        }

        let maxResults = max(1, min(limit, 100))
        let index = ProjectFileIndex.build(
            projectId: projectID,
            rootURL: rootURL,
            additionalRootURLs: Array(rootURLs.dropFirst()) + fallbackPlanArtifactIndexRoots(projectID: normalizedID, rootURL: rootURL),
            limit: ProjectFileIndex.defaultLimit
        )
        return index.search(query, limit: maxResults).map { entry in
            ProjectFileSearchEntry(path: entry.path, type: entry.type)
        }
    }

    public func readProjectFile(projectID: String, path: String) async throws -> ProjectFileContentResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.notFound
        }
        let project = await store.project(id: normalizedID)
        let rootURLs = try await resolveProjectWorkspaceRoots(projectID: normalizedID)
        guard let rootURL = rootURLs.first else { throw ProjectError.notFound }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ProjectError.invalidProjectID
        }

        let targetURL = trimmedPath.hasPrefix("/")
            ? URL(fileURLWithPath: trimmedPath).standardizedFileURL
            : rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
        guard rootURLs.contains(where: { isProjectURL(targetURL, inside: $0) }) else {
            throw ProjectError.invalidProjectID
        }

        let maxBytes = 2 * 1024 * 1024
        let data = try Data(contentsOf: targetURL)
        guard data.count <= maxBytes else {
            throw ProjectError.invalidProjectID
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProjectError.invalidProjectID
        }

        let responsePath: String
        if project?.kind == .workspace || trimmedPath.hasPrefix("/") {
            responsePath = targetURL.path
        } else {
            responsePath = String(targetURL.path.dropFirst(rootURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ProjectFileContentResponse(path: responsePath, content: text, sizeBytes: data.count)
    }

    /// Line stats and unified diff for the project workspace from its configured source-control provider.
    public func projectWorkingTreeSourceControl(
        projectID: String,
        taskID: String? = nil
    ) async throws -> ProjectWorkingTreeSourceControlResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        let task = taskID.flatMap { requestedID in
            project.tasks.first { $0.id == requestedID }
        }
        if taskID != nil, task == nil {
            throw ProjectError.invalidTaskID
        }
        let rootPath: String
        if let task,
           task.worktreeBranch != nil,
           let repoPath = project.repoPath {
            rootPath = sourceControlProvider(for: project, task: task).worktreePath(
                repoPath: repoPath,
                taskId: task.id,
                worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
            )
        } else {
            rootPath = try await resolveProjectWorkspaceRoot(projectID: normalizedID).path
        }
        let selection = await inspectSourceControlProvider(for: project, task: task, at: rootPath)
        let provider = selection.provider
        let repository = selection.repository

        guard repository.isRepository else {
            return ProjectWorkingTreeSourceControlResponse(
                providerId: provider.id,
                isRepository: false,
                branch: nil,
                linesAdded: 0,
                linesDeleted: 0,
                diff: "",
                diffTruncated: false,
                message: repository.message ?? "This project folder is not a source-control repository."
            )
        }

        do {
            let status = try await provider.workingTreeStatus(at: rootPath)
            let patch = try await provider.workingTreeDiff(at: rootPath, maxBytes: 512 * 1024)
            return ProjectWorkingTreeSourceControlResponse(
                providerId: provider.id,
                isRepository: true,
                branch: status.repository.branch,
                linesAdded: status.linesAdded,
                linesDeleted: status.linesDeleted,
                diff: patch.text,
                diffTruncated: patch.truncated,
                message: nil
            )
        } catch {
            return ProjectWorkingTreeSourceControlResponse(
                providerId: provider.id,
                isRepository: true,
                branch: nil,
                linesAdded: 0,
                linesDeleted: 0,
                diff: "",
                diffTruncated: false,
                message: error.localizedDescription
            )
        }
    }

    public func createTUIBackgroundWorktree(projectID: String, taskID: String) async throws -> SourceControlWorktreeResult {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        let normalizedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskID.isEmpty else {
            throw ProjectError.invalidTaskID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let rootPath = try await resolveProjectWorkspaceRoot(projectID: normalizedID).path
        let provider = sourceControlProvider(for: project)
        let worktreeRootPath = defaultWorktreeRootPath(projectID: normalizedID)
        logger.info(
            "source_control.worktree.create.started",
            metadata: [
                "project_id": .string(normalizedID),
                "task_id": .string(normalizedTaskID),
                "provider_id": .string(provider.id),
                "repo_path": .string(rootPath),
                "worktree_root_path": .string(worktreeRootPath)
            ]
        )
        do {
            let result = try await provider.createWorktree(
                repoPath: rootPath,
                taskId: normalizedTaskID,
                baseBranch: "HEAD",
                worktreeRootPath: worktreeRootPath
            )
            logger.info(
                "source_control.worktree.create.succeeded",
                metadata: [
                    "project_id": .string(normalizedID),
                    "task_id": .string(normalizedTaskID),
                    "provider_id": .string(provider.id),
                    "branch_name": .string(result.branchName),
                    "worktree_path": .string(result.worktreePath)
                ]
            )
            return result
        } catch {
            logger.error(
                "source_control.worktree.create.failed",
                metadata: [
                    "project_id": .string(normalizedID),
                    "task_id": .string(normalizedTaskID),
                    "provider_id": .string(provider.id),
                    "error": .string(error.localizedDescription)
                ]
            )
            throw error
        }
    }

    public struct TUIBackgroundSessionStartResult: Sendable {
        public var session: AgentSessionSummary
        public var worktree: SourceControlWorktreeResult
    }

    public func startTUIBackgroundSession(
        agentID: String,
        projectID: String,
        task: String,
        mode: AgentChatMode?,
        reasoningEffort: ReasoningEffort?
    ) async throws -> TUIBackgroundSessionStartResult {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else {
            throw AgentSessionError.invalidPayload
        }

        let session = try await createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(
                title: "Background: \(String(trimmedTask.prefix(48)))",
                projectId: projectID
            )
        )
        let sessionIDPrefix = "session-"
        let taskIDSeed = if session.id.hasPrefix(sessionIDPrefix) {
            String(session.id.dropFirst(sessionIDPrefix.count))
        } else {
            session.id
        }
        let taskID = "tui-\(String(taskIDSeed.prefix(8)))"
        let worktree = try await createTUIBackgroundWorktree(projectID: projectID, taskID: taskID)
        _ = try await addAgentSessionDirectory(
            agentID: agentID,
            sessionID: session.id,
            request: AgentSessionDirectoryRequest(path: worktree.worktreePath)
        )

        tuiBackgroundSessionTasks[session.id]?.cancel()
        tuiBackgroundSessionTasks[session.id] = Task { [weak self] in
            await self?.runTUIBackgroundSession(
                agentID: agentID,
                sessionID: session.id,
                task: trimmedTask,
                worktreePath: worktree.worktreePath,
                mode: mode,
                reasoningEffort: reasoningEffort
            )
        }

        return TUIBackgroundSessionStartResult(session: session, worktree: worktree)
    }

    private func runTUIBackgroundSession(
        agentID: String,
        sessionID: String,
        task: String,
        worktreePath: String,
        mode: AgentChatMode?,
        reasoningEffort: ReasoningEffort?
    ) async {
        defer {
            Task { [weak self] in
                await self?.clearTUIBackgroundSessionTask(sessionID: sessionID)
            }
        }

        do {
            _ = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: sessionID,
                request: AgentSessionPostMessageRequest(
                    userId: "tui",
                    content: """
                    \(task)

                    Work in this dedicated worktree:
                    \(worktreePath)
                    """,
                    reasoningEffort: reasoningEffort,
                    mode: mode
                )
            )
        } catch {
            logger.warning(
                "tui.background_session.failed",
                metadata: [
                    "agent_id": .string(agentID),
                    "session_id": .string(sessionID),
                    "error": .string(error.localizedDescription)
                ]
            )
            let event = AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .interrupted,
                    label: "Background session failed",
                    details: error.localizedDescription
                )
            )
            _ = try? await appendAgentSessionEvents(
                agentID: agentID,
                sessionID: sessionID,
                request: AgentSessionAppendEventsRequest(events: [event])
            )
        }
    }

    private func clearTUIBackgroundSessionTask(sessionID: String) {
        tuiBackgroundSessionTasks.removeValue(forKey: sessionID)
    }

    /// Reverts a tracked file under the project workspace through the configured source-control provider.
    public func restoreProjectWorkingTreeFile(projectID: String, path: String) async throws {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        let rootURL = try await resolveProjectWorkspaceRoot(projectID: normalizedID)
        let rootPath = rootURL.path
        let provider = sourceControlProvider(for: project)
        let repository = await provider.inspectRepository(at: rootPath)
        guard repository.isRepository else {
            throw ProjectError.invalidPayload
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.invalidPayload
        }

        let segments = trimmed.split(separator: "/").map(String.init)
        guard !segments.contains("..") else {
            throw ProjectError.invalidProjectID
        }

        let targetURL = rootURL.appendingPathComponent(trimmed).standardized
        guard isProjectURL(targetURL, inside: rootURL) else {
            throw ProjectError.invalidProjectID
        }

        do {
            try await provider.restorePathFromHead(repoPath: rootPath, relativePath: trimmed)
        } catch {
            throw ProjectError.invalidPayload
        }
    }

    public func refreshProjectContext(projectID: String) async throws -> ProjectContextRefreshResponse {
        await waitForStartup()
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        let rootPaths = effectiveProjectDirectoryURLs(project).map(\.path)
        guard !rootPaths.isEmpty else { throw ProjectError.invalidPayload }
        let loader = ProjectContextLoader()
        let loaded = loader.load(repoPaths: rootPaths, projectMemoryURL: projectMetaMemoryFileURL(projectID: normalizedID))
        let content = renderProjectContextBootstrap(projectID: normalizedID, projectName: project.name, loaded: loaded)

        let channelIDs = project.channels.map(\.channelId)
        for channelID in channelIDs {
            await runtime.appendSystemMessage(channelId: channelID, content: content)
            await runtime.setChannelBootstrap(channelId: channelID, content: content)
        }

        var loadedDocPaths = loaded.loadedDocs.map(\.relativePath)
        if let loadedProjectMemory = loaded.loadedProjectMemory {
            loadedDocPaths.append(loadedProjectMemory.relativePath)
        }

        return ProjectContextRefreshResponse(
            projectId: normalizedID,
            repoPath: loaded.repoPath,
            appliedChannelIds: channelIDs,
            loadedDocPaths: loadedDocPaths,
            loadedSkillPaths: loaded.loadedSkills.map(\.relativePath),
            totalChars: loaded.totalChars,
            truncated: loaded.truncated
        )
    }

    /// Same markdown as channel `refreshProjectContext`, for merging into agent session bootstrap (no channel writes).
    func projectBootstrapMarkdownForAgentSession(projectID: String, taskID: String? = nil, agentID: String? = nil) async -> String? {
        await waitForStartup()
        guard let normalizedID = normalizedProjectID(projectID) else {
            return nil
        }
        guard let project = await store.project(id: normalizedID) else {
            return nil
        }
        let rootPaths = effectiveProjectDirectoryURLs(project).map(\.path)
        let loader = ProjectContextLoader()
        let loaded = loader.load(repoPaths: rootPaths, projectMemoryURL: projectMetaMemoryFileURL(projectID: normalizedID))
        var context = renderProjectContextBootstrap(projectID: normalizedID, projectName: project.name, loaded: loaded)
        if let agentID {
            context += importedProjectInstructions(projectID: normalizedID, agentID: agentID)
        }

        if let taskID = taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !taskID.isEmpty,
           let task = project.tasks.first(where: { $0.id == taskID }) {
            var taskLines = [
                "[Project task context]",
                "Task: \(task.title) (\(task.id))",
                "Status: \(task.status)",
                "Priority: \(task.priority)",
            ]
            if !task.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                taskLines.append("Description:\n\(task.description)")
            }
            if let parentTaskID = task.parentTaskId, !parentTaskID.isEmpty {
                taskLines.append("Parent task: \(parentTaskID)")
            }
            if !task.dependsOnTaskIds.isEmpty {
                taskLines.append("Dependencies: \(task.dependsOnTaskIds.joined(separator: ", "))")
            }
            if let branch = task.worktreeBranch, !branch.isEmpty {
                taskLines.append("Worktree branch: \(branch)")
                if let repoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !repoPath.isEmpty {
                    let worktreePath = sourceControlProvider(for: project, task: task).worktreePath(
                        repoPath: repoPath,
                        taskId: task.id,
                        worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
                    )
                    taskLines.append("Task working directory: \(worktreePath)")
                }
            }
            context += "\n\n" + taskLines.joined(separator: "\n")
        }

        return context
    }

    private func renderProjectContextBootstrap(
        projectID: String,
        projectName: String,
        loaded: ProjectContextLoader.Result
    ) -> String {
        var lines: [String] = []
        lines.append(Self.projectContextBootstrapMarker)
        lines.append("Project context initialized.")
        lines.append("Project: \(projectName) (\(projectID))")
        if loaded.repoPaths.count > 1 {
            lines.append("Workspace paths:")
            for (index, path) in loaded.repoPaths.enumerated() {
                lines.append("- \(index == 0 ? "primary: " : "")\(path)")
            }
        } else {
            lines.append("Repo path: \(loaded.repoPath)")
        }

        if !loaded.loadedDocs.isEmpty {
            lines.append("")
            lines.append("[Project files]")
            for file in loaded.loadedDocs {
                lines.append("")
                lines.append("[\(file.relativePath)]")
                lines.append(file.content)
                if file.truncated {
                    lines.append("")
                    lines.append("(truncated)")
                }
            }
            if let file = loaded.loadedProjectMemory {
                lines.append("")
                lines.append("[\(file.relativePath)]")
                lines.append(file.content)
                if file.truncated {
                    lines.append("")
                    lines.append("(truncated)")
                }
            }
        } else if let file = loaded.loadedProjectMemory {
            lines.append("")
            lines.append("[Project files]")
            lines.append("")
            lines.append("[\(file.relativePath)]")
            lines.append(file.content)
            if file.truncated {
                lines.append("")
                lines.append("(truncated)")
            }
        }

        if !loaded.loadedSkills.isEmpty {
            lines.append("")
            lines.append("[.skills]")
            lines.append("Loaded \(loaded.loadedSkills.count) skill file(s).")
            for file in loaded.loadedSkills {
                lines.append("")
                lines.append("[\(file.relativePath)]")
                lines.append(file.content)
                if file.truncated {
                    lines.append("")
                    lines.append("(truncated)")
                }
            }
        }

        if loaded.truncated {
            lines.append("")
            lines.append("[Note]")
            lines.append("Project context was truncated due to size limits.")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Creates a new dashboard project.
    public func createProject(_ request: ProjectCreateRequest) async throws -> ProjectCreateResult {
        let now = Date()
        let normalizedName = try normalizeProjectName(request.name)
        let normalizedDescription = normalizeProjectDescription(request.description)
        let normalizedIdea = normalizeProjectIdea(request.idea)
        let trimmedRepoUrl = request.repoUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasRepoUrl = !trimmedRepoUrl.isEmpty
        let requestedDirectoryPaths = try normalizedProjectDirectoryPaths(request.directoryPaths)
        if request.repoPath != nil, !requestedDirectoryPaths.isEmpty {
            throw ProjectError.invalidPayload
        }
        let normalizedRepoPath = try normalizedExternalProjectPath(request.repoPath)
        let directoryPaths = requestedDirectoryPaths.isEmpty
            ? normalizedRepoPath.map { [$0] } ?? []
            : requestedDirectoryPaths
        let sourceControlProviderId = normalizedSourceControlProviderID(request.sourceControlProviderId)

        if hasRepoUrl, normalizedRepoPath != nil || !directoryPaths.isEmpty {
            throw ProjectError.invalidPayload
        }
        try validateProjectDirectories(kind: request.kind, directoryPaths: directoryPaths)
        let normalizedID: String
        if let requestedID = request.id, !requestedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let validID = normalizedProjectID(requestedID) else {
                throw ProjectError.invalidProjectID
            }
            guard await store.project(id: validID) == nil else {
                throw ProjectError.conflict
            }
            normalizedID = validID
        } else {
            normalizedID = UUID().uuidString
        }
        let channels = try normalizeInitialProjectChannels(request.channels, fallbackName: normalizedName)
        let project = ProjectRecord(
            id: normalizedID,
            name: normalizedName,
            description: normalizedDescription,
            kind: request.kind,
            directoryPaths: directoryPaths,
            channels: channels,
            tasks: [],
            actors: request.actors ?? [],
            teams: request.teams ?? [],
            repoPath: directoryPaths.first ?? normalizedRepoPath,
            sourceControlProviderId: sourceControlProviderId,
            createdAt: now,
            updatedAt: now
        )

        if !directoryPaths.isEmpty {
            try prepareExternalProjectWorkspace(projectID: normalizedID)
        }

        await store.saveProject(project)
        let repoCloneSucceeded: Bool?
        if hasRepoUrl {
            repoCloneSucceeded = await cloneProjectRepository(
                repoUrl: trimmedRepoUrl,
                projectID: normalizedID,
                projectDisplayName: normalizedName
            )
        } else {
            ensureProjectWorkspaceDirectory(projectID: normalizedID)
            repoCloneSucceeded = nil
        }
        if let normalizedIdea {
            try writeProjectIdea(normalizedIdea, for: project)
        }
        if !currentConfig.onboarding.completed {
            logger.info(
                "onboarding.project.created",
                metadata: [
                    "project_id": .string(normalizedID),
                    "project_name": .string(normalizedName)
                ]
            )
        }
        return ProjectCreateResult(project: projectWithRuntimePaths(project), repoCloneSucceeded: repoCloneSucceeded)
    }

    public func selectDirectory() async -> String? {
        await selectDirectories().first
    }

    public func selectDirectories() async -> [String] {
#if canImport(AppKit)
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSApplication.shared.activate(ignoringOtherApps: true)

                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.canCreateDirectories = false
                panel.title = "Choose Project Directory"
                panel.prompt = "Open Project"
                panel.level = .floating

                @MainActor func finish(_ response: NSApplication.ModalResponse) {
                    guard response == .OK else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: panel.urls.map(\.standardizedFileURL.path))
                }

                if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
                    panel.beginSheetModal(for: window, completionHandler: finish)
                } else {
                    finish(panel.runModal())
                }
            }
        }
#else
        return []
#endif
    }

    /// Updates dashboard project metadata.
    public func updateProject(projectID: String, request: ProjectUpdateRequest) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        if let nextName = request.name {
            project.name = try normalizeProjectName(nextName)
        }
        if let nextDescription = request.description {
            project.description = normalizeProjectDescription(nextDescription)
        }
        if request.icon != nil {
            project.icon = request.icon
        }
        if let nextActors = request.actors {
            project.actors = nextActors
        }
        if let nextTeams = request.teams {
            project.teams = nextTeams
        }
        if let nextModels = request.models {
            project.models = nextModels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let nextAgentFiles = request.agentFiles {
            project.agentFiles = nextAgentFiles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let nextHeartbeat = request.heartbeat {
            project.heartbeat = nextHeartbeat
        }
        let nextKind = request.kind ?? project.kind
        if request.repoPath != nil, request.directoryPaths != nil {
            throw ProjectError.invalidPayload
        }
        if let requestedPaths = request.directoryPaths {
            let normalizedPaths = try normalizedProjectDirectoryPaths(requestedPaths)
            try validateProjectDirectories(kind: nextKind, directoryPaths: normalizedPaths)
            project.directoryPaths = normalizedPaths
            project.repoPath = normalizedPaths.first
            if !normalizedPaths.isEmpty {
                try prepareExternalProjectWorkspace(projectID: normalizedID)
            }
        } else if request.repoPath != nil {
            let normalizedPath = try normalizedExternalProjectPath(request.repoPath)
            let normalizedPaths = normalizedPath.map { [$0] } ?? []
            try validateProjectDirectories(kind: nextKind, directoryPaths: normalizedPaths)
            project.directoryPaths = normalizedPaths
            project.repoPath = normalizedPath
        } else {
            let existingPaths = effectiveProjectDirectoryURLs(project).map(\.path)
            try validateProjectDirectories(kind: nextKind, directoryPaths: existingPaths)
        }
        project.kind = nextKind
        if request.sourceControlProviderId != nil {
            let previousProviderId = project.sourceControlProviderId ?? Self.defaultSourceControlProviderID
            for index in project.tasks.indices where project.tasks[index].worktreeBranch != nil && project.tasks[index].sourceControlProviderId == nil {
                project.tasks[index].sourceControlProviderId = previousProviderId
            }
            project.sourceControlProviderId = normalizedSourceControlProviderID(request.sourceControlProviderId)
        }
        if let nextReviewSettings = request.reviewSettings {
            project.reviewSettings = nextReviewSettings
        }
        if let enabled = request.automaticTaskPickupEnabled {
            project.automaticTaskPickupEnabled = enabled
        }
        if let nextAutopilotSettings = request.autopilotSettings {
            guard nextAutopilotSettings.pickupRules.isValid else { throw ProjectError.invalidPayload }
            project.autopilotSettings = nextAutopilotSettings
        }
        if let nextLoopMode = request.taskLoopMode {
            project.taskLoopMode = nextLoopMode
        }
        if let nextFavorite = request.isFavorite {
            project.isFavorite = nextFavorite
        }
        if let nextArchived = request.isArchived {
            project.isArchived = nextArchived
        }

        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: normalizedID))
        return projectWithRuntimePaths(project)
    }

    /// Deletes one dashboard project and nested board entities.
    /// Cancels all non-terminal tasks before deletion.
    public func deleteProject(projectID: String) async throws {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        for i in project.tasks.indices {
            let status = ProjectTaskStatus(rawValue: project.tasks[i].status)
            if status == nil || !status!.isTerminal {
                project.tasks[i].status = ProjectTaskStatus.cancelled.rawValue
                project.tasks[i].updatedAt = Date()
            }
        }
        project.updatedAt = Date()
        await store.saveProject(project)
        await store.deleteProject(id: normalizedID)
    }

    /// Adds a channel to a dashboard project.
    public func createProjectChannel(
        projectID: String,
        request: ProjectChannelCreateRequest
    ) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let title = normalizeChannelTitle(request.title)
        let channelID = try normalizedChannelID(request.channelId)
        if project.channels.contains(where: { $0.channelId == channelID }) {
            throw ProjectError.conflict
        }

        project.channels.append(
            ProjectChannel(
                id: UUID().uuidString,
                title: title,
                channelId: channelID,
                createdAt: Date()
            )
        )
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    public func linkProjectChannel(
        projectID: String,
        request: ProjectChannelLinkRequest
    ) async throws -> ProjectChannelLinkResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let channelID = try normalizedChannelID(request.channelId)
        let title = normalizeChannelTitle(request.title ?? channelID)
        let projects = await store.listProjects()
        for candidate in projects where candidate.id != normalizedID {
            if candidate.channels.contains(where: { channelBindingsConflict($0.channelId, channelID) }) {
                throw ProjectChannelLinkConflict(
                    ownerProjectId: candidate.id,
                    ownerProjectName: candidate.name,
                    channelId: channelID
                )
            }
        }

        let status: String
        let channel: ProjectChannel
        if let existing = project.channels.first(where: { channelBindingsConflict($0.channelId, channelID) }) {
            channel = existing
            status = "existing"
        } else {
            channel = ProjectChannel(
                id: UUID().uuidString,
                title: title,
                channelId: channelID,
                createdAt: Date()
            )
            project.channels.append(channel)
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: normalizedID))
            status = "linked"
        }

        let session: ProjectChannelLinkSession?
        if request.ensureSession == true {
            let summary = try await channelSessionStore.ensureOpenSession(channelId: channelID)
            session = ProjectChannelLinkSession(
                channelId: summary.channelId,
                sessionId: summary.sessionId,
                status: summary.status.rawValue
            )
        } else {
            session = nil
        }

        return ProjectChannelLinkResponse(
            project: project,
            channel: channel,
            session: session,
            status: status
        )
    }

    /// Removes a channel from a dashboard project.
    public func deleteProjectChannel(projectID: String, channelID: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedChannel = normalizedEntityID(channelID) else {
            throw ProjectError.invalidChannelID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        guard project.channels.contains(where: { $0.id == normalizedChannel }) else {
            throw ProjectError.notFound
        }
        if project.channels.count <= 1 {
            throw ProjectError.invalidPayload
        }

        project.channels.removeAll(where: { $0.id == normalizedChannel })
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Creates a new task inside project board.
    public func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let now = Date()
        let rawStatus = request.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let resolvedStatus = ProjectTaskStatus(rawValue: rawStatus) != nil ? rawStatus : ProjectTaskStatus.backlog.rawValue
        let normalizedStatus = try normalizeTaskStatus(resolvedStatus)
        let teamID = try normalizeOptionalTaskTeamID(request.teamId ?? (request.actorId == nil && project.teams.count == 1 ? project.teams.first : nil))
        var assignments = try taskStageAssignments(requested: request.stageAssignments, teamID: teamID)
        if assignments != nil, request.stageAssignments == nil, let actor = try normalizeOptionalTaskActorID(request.actorId) {
            assignments?.developer = actor
            assignments = try taskStageAssignments(requested: assignments, teamID: teamID)
        }
        let task = ProjectTask(
            id: nextProjectTaskID(for: project),
            title: try normalizeTaskTitle(request.title),
            description: normalizeTaskDescription(request.description),
            priority: try normalizeTaskPriority(request.priority),
            status: normalizedStatus,
            initiativeID: request.initiativeID.flatMap(normalizedEntityID),
            kind: request.kind,
            loopModeOverride: request.loopModeOverride,
            originType: request.originType,
            originChannelId: request.originChannelId,
            actorId: try normalizeOptionalTaskActorID(request.actorId),
            executionNodeId: request.executionNodeId.flatMap(normalizedEntityID),
            teamId: teamID,
            stageAssignments: assignments,
            parentTaskId: normalizeOptionalTaskID(request.parentTaskId),
            createdBy: normalizeOptionalTaskAuthor(request.changedBy),
            dependsOnTaskIds: normalizeTaskDependencyIds(request.dependsOnTaskIds ?? []),
            selectedModel: normalizeOptionalTaskSelectedModel(request.selectedModel),
            attachments: normalizeTaskAttachments(request.attachments ?? []),
            tags: normalizeTaskTags(request.tags ?? []),
            createdAt: now,
            updatedAt: now
        )
        project.tasks.append(task)
        try validateProjectTaskDependencies(project: project)
        project.updatedAt = now
        await store.saveProject(project)
        if let initiativeID = task.initiativeID {
            await reconcileInitiativeCompletion(projectID: normalizedID, initiativeID: initiativeID)
        }
        if let changedBy = request.changedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
           !changedBy.isEmpty,
           changedBy != "user" {
            appendTaskLifecycleLog(
                projectID: normalizedID,
                taskID: task.id,
                stage: "created",
                channelID: task.originChannelId,
                workerID: nil,
                message: "Task created.",
                actorID: changedBy
            )
        }
        await kanbanEventService.push(KanbanEvent(type: .taskCreated, projectId: normalizedID, task: task))
        await syncOutboundTaskIfNeeded(projectID: normalizedID, taskID: task.id)
        if normalizedStatus == ProjectTaskStatus.ready.rawValue {
            await handleTaskBecameReady(projectID: normalizedID, taskID: task.id)
            if let updated = await store.project(id: normalizedID) {
                return updated
            }
        }
        if let updated = await store.project(id: normalizedID) {
            return updated
        }
        return project
    }

    /// Updates one task inside project board.
    public func updateProjectTask(
        projectID: String,
        taskID: String,
        request: ProjectTaskUpdateRequest
    ) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedTaskLowercased = normalizedTask.lowercased()
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.id.lowercased() == normalizedTaskLowercased }) else {
            throw ProjectError.notFound
        }

        let changedBy = request.changedBy ?? "user"
        let previousStatus = project.tasks[taskIndex].status
        let oldTask = project.tasks[taskIndex]
        var task = oldTask
        let requestedCompletionNote = normalizedCompletionNote(request.completionNote)
        if let status = request.status,
           try normalizeTaskStatus(status) == ProjectTaskStatus.done.rawValue,
           requiresCompletionConfirmation(changedBy: changedBy) {
            guard request.completionConfidence == .done,
                  requestedCompletionNote != nil
            else {
                throw ProjectError.invalidPayload
            }
        }
        if let title = request.title {
            task.title = try normalizeTaskTitle(title)
        }
        if let description = request.description {
            task.description = normalizeTaskDescription(description)
        }
        if let priority = request.priority {
            task.priority = try normalizeTaskPriority(priority)
        }
        if request.actorId != nil {
            task.actorId = try normalizeOptionalTaskActorID(request.actorId)
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        if request.executionNodeId != nil {
            task.executionNodeId = request.executionNodeId.flatMap(normalizedEntityID)
        }
        if request.teamId != nil {
            task.teamId = try normalizeOptionalTaskTeamID(request.teamId)
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        if request.stageAssignments != nil || (request.teamId != nil && task.teamId != oldTask.teamId) {
            task.stageAssignments = try taskStageAssignments(requested: request.stageAssignments, teamID: task.teamId)
        }
        if request.actorId != nil, request.stageAssignments == nil, task.stageAssignments != nil,
           request.teamId == nil || task.actorId != nil {
            task.stageAssignments?.developer = task.actorId
            task.stageAssignments = try taskStageAssignments(requested: task.stageAssignments, teamID: task.teamId)
        }
        if let kind = request.kind {
            task.kind = kind
        }
        if request.loopModeOverride != nil {
            task.loopModeOverride = request.loopModeOverride
        }
        if request.parentTaskId != nil {
            task.parentTaskId = normalizeOptionalTaskID(request.parentTaskId)
        }
        if request.initiativeID != nil {
            task.initiativeID = request.initiativeID.flatMap(normalizedEntityID)
        }
        if let dependsOnTaskIds = request.dependsOnTaskIds {
            task.dependsOnTaskIds = normalizeTaskDependencyIds(dependsOnTaskIds)
        }
        if request.selectedModel != nil {
            task.selectedModel = normalizeOptionalTaskSelectedModel(request.selectedModel)
        }
        if let tags = request.tags {
            task.tags = normalizeTaskTags(tags)
        }
        if let attachments = request.attachments {
            task.attachments = normalizeTaskAttachments(attachments)
        }
        if let isArchived = request.isArchived {
            task.isArchived = isArchived
        }
        if let status = request.status {
            task.status = try normalizeTaskStatus(status)
            if task.status == ProjectTaskStatus.backlog.rawValue || task.status == ProjectTaskStatus.cancelled.rawValue {
                task.claimedActorId = nil
                task.claimedAgentId = nil
            }
        }
        if task.externalMetadata?.providerId != nil {
            task.externalMetadata?.origin = "sloppy"
            task.externalMetadata?.syncState = "pending"
        }
        let actorChanged = request.actorId != nil && oldTask.actorId != task.actorId
        let teamChanged = request.teamId != nil && oldTask.teamId != task.teamId
        let statusChangedToReady = request.status != nil && task.status == ProjectTaskStatus.ready.rawValue
        let statusChangedToCancelled = request.status != nil && task.status == ProjectTaskStatus.cancelled.rawValue
        if task.stageAssignments != nil, !requiresCompletionConfirmation(changedBy: changedBy), statusChangedToReady {
            task.activeStage = .development
        }
        if !requiresCompletionConfirmation(changedBy: changedBy),
           actorChanged || teamChanged || statusChangedToReady || statusChangedToCancelled {
            task.routeHistory = []
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        try validateProjectTaskDependencies(project: project)
        project.updatedAt = Date()
        await store.saveProject(project)
        await syncInitiativePhaseForTaskStatusChange(
            projectID: normalizedProject,
            previousTask: oldTask,
            currentTask: task
        )
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: normalizedProject, task: task))
        await syncOutboundTaskIfNeeded(projectID: normalizedProject, taskID: task.id)

        await recordTaskFieldChanges(
            projectID: normalizedProject,
            taskID: task.id,
            oldTask: oldTask,
            newTask: task,
            changedBy: changedBy
        )
        if task.status == ProjectTaskStatus.blocked.rawValue || task.status == ProjectTaskStatus.waitingInput.rawValue,
           let completionNote = requestedCompletionNote {
            await appendSystemTaskComment(
                projectID: normalizedProject,
                taskID: task.id,
                content: completionNote,
                kind: .actionRequired
            )
        }
        if task.status == ProjectTaskStatus.done.rawValue,
           previousStatus != ProjectTaskStatus.done.rawValue,
           let completionNote = requestedCompletionNote {
            await appendExecutorCompletionComment(
                projectID: normalizedProject,
                taskID: task.id,
                completionNote: completionNote,
                authorActorId: changedBy
            )
            appendTaskLifecycleLog(
                projectID: normalizedProject,
                taskID: task.id,
                stage: "completion_confirmed",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: completionNote,
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId
            )
        }

        if previousStatus != task.status,
           let runOutcome = taskRunOutcome(forStatus: task.status) {
            var metadata: [String: String] = [
                "source": changedBy,
                "status": task.status
            ]
            if let confidence = request.completionConfidence {
                metadata["completionConfidence"] = confidence.rawValue
            }
            await finishLatestTaskRun(
                projectID: normalizedProject,
                taskID: task.id,
                outcome: runOutcome,
                summary: requestedCompletionNote,
                metadata: metadata,
                failureReason: runOutcome == .blocked ? requestedCompletionNote : nil,
                actorID: task.claimedActorId ?? task.actorId,
                agentID: task.claimedAgentId,
                workerID: nil,
                channelID: resolveExecutionChannelID(project: project, task: task)
            )
        }

        if previousStatus != task.status {
            switch task.status {
            case ProjectTaskStatus.waitingInput.rawValue:
                _ = await ensureInitiativeDecisionPacket(
                    projectID: normalizedProject,
                    task: task,
                    kind: .waitingInput,
                    summary: "Task \(task.id) needs user input",
                    rationale: requestedCompletionNote ?? "Task \(task.id) was moved to waiting_input.",
                    requestedAction: "Provide the missing input for task \(task.id)",
                    resumePoint: "Resume task \(task.id) after user input"
                )
            case ProjectTaskStatus.blocked.rawValue:
                _ = await ensureInitiativeDecisionPacket(
                    projectID: normalizedProject,
                    task: task,
                    kind: .blocked,
                    summary: "Task \(task.id) is blocked",
                    rationale: requestedCompletionNote ?? "Task \(task.id) was marked blocked.",
                    requestedAction: "Unblock task \(task.id) or decide how to proceed",
                    resumePoint: "Resume task \(task.id) after blocker resolution"
                )
            default:
                break
            }

            if (previousStatus == ProjectTaskStatus.waitingInput.rawValue || previousStatus == ProjectTaskStatus.blocked.rawValue)
                && task.status != ProjectTaskStatus.waitingInput.rawValue
                && task.status != ProjectTaskStatus.blocked.rawValue
            {
                _ = await resolveOpenDecisionPacketsForTask(
                    projectID: normalizedProject,
                    task: task,
                    resumePoint: "Resume task \(task.id) after status changed to \(task.status)"
                )
            }
        }

        if previousStatus != ProjectTaskStatus.done.rawValue,
           task.status == ProjectTaskStatus.done.rawValue,
           let promotedProject = await promoteTasksUnblockedByCompletedDependency(
                projectID: normalizedProject,
                completedTaskID: task.id
           ) {
            project = promotedProject
        }
        if let initiativeID = task.initiativeID {
            await reconcileInitiativeCompletion(projectID: normalizedProject, initiativeID: initiativeID)
        }

        let assigneeChangedWhileReady = (actorChanged || teamChanged)
            && task.status == ProjectTaskStatus.ready.rawValue

        if previousStatus != ProjectTaskStatus.ready.rawValue, task.status == ProjectTaskStatus.ready.rawValue {
            await handleTaskBecameReady(projectID: normalizedProject, taskID: task.id)
            if let updated = await store.project(id: normalizedProject) {
                return updated
            }
        } else if assigneeChangedWhileReady {
            await handleTaskBecameReady(projectID: normalizedProject, taskID: task.id)
            if let updated = await store.project(id: normalizedProject) {
                return updated
            }
        }
        return project
    }

    /// Removes one task from project board.
    public func deleteProjectTask(projectID: String, taskID: String) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedTaskLowercased = normalizedTask.lowercased()
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard project.tasks.contains(where: { $0.id.lowercased() == normalizedTaskLowercased }) else {
            throw ProjectError.notFound
        }

        project.tasks.removeAll(where: { $0.id.lowercased() == normalizedTaskLowercased })
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskDeleted, projectId: normalizedProject, taskId: normalizedTask))
        return project
    }

    private static let taskArchiveThreshold: TimeInterval = 2 * 24 * 60 * 60

    private static let archivableStatuses: Set<String> = [
        ProjectTaskStatus.done.rawValue,
        ProjectTaskStatus.cancelled.rawValue
    ]

    @discardableResult
    public func archiveOldTasks(projectID: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let cutoff = Date().addingTimeInterval(-Self.taskArchiveThreshold)
        var changed = false
        for index in project.tasks.indices {
            let task = project.tasks[index]
            if !task.isArchived,
               Self.archivableStatuses.contains(task.status),
               task.updatedAt < cutoff {
                project.tasks[index].isArchived = true
                changed = true
            }
        }

        if changed {
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: normalizedID))
        }
        return project
    }

    public func listArchivedTasks(projectID: String) async throws -> [ProjectTask] {
        let project = try await archiveOldTasks(projectID: projectID)
        return project.tasks.filter(\.isArchived)
    }

    /// Returns one task by readable id (for example, `MOBILE-1`).
    public func getProjectTask(taskReference: String) async throws -> AgentTaskRecord {
        guard let normalizedReference = normalizeTaskReference(taskReference) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedReferenceLowercased = normalizedReference.lowercased()

        let projects = await store.listProjects().sorted(by: { $0.createdAt < $1.createdAt })
        for project in projects {
            guard let task = project.tasks.first(where: { $0.id.lowercased() == normalizedReferenceLowercased }) else {
                continue
            }

            return AgentTaskRecord(
                projectId: project.id,
                projectName: project.name,
                task: task
            )
        }

        throw ProjectError.notFound
    }

    func normalizeProjectName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else {
            throw ProjectError.invalidPayload
        }
        return trimmed
    }

    func normalizeProjectDescription(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(2_000))
    }

    func normalizeProjectIdea(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(100_000))
    }

    func writeProjectIdea(_ idea: String, for project: ProjectRecord) throws {
        guard let rootURL = effectiveProjectDirectoryURLs(project).first else {
            throw ProjectError.notFound
        }
        let fileURL = rootURL.appendingPathComponent("IDEA.md", isDirectory: false)
        try Data("\(idea)\n".utf8).write(to: fileURL, options: .atomic)
    }

    func normalizeInitialProjectChannels(
        _ channels: [ProjectChannelCreateRequest],
        fallbackName: String
    ) throws -> [ProjectChannel] {
        if channels.isEmpty {
            let slug = slugify(fallbackName)
            return [
                ProjectChannel(
                    id: UUID().uuidString,
                    title: "Main channel",
                    channelId: slug.isEmpty ? "project-main" : "\(slug)-main",
                    createdAt: Date()
                )
            ]
        }

        var normalized: [ProjectChannel] = []
        var uniqueChannelIDs: Set<String> = []
        for channel in channels {
            let title = normalizeChannelTitle(channel.title)
            let channelID = try normalizedChannelID(channel.channelId)
            guard uniqueChannelIDs.insert(channelID).inserted else {
                throw ProjectError.conflict
            }
            normalized.append(
                ProjectChannel(
                    id: UUID().uuidString,
                    title: title,
                    channelId: channelID,
                    createdAt: Date()
                )
            )
        }
        return normalized
    }

    func normalizeTaskTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.invalidPayload
        }
        return String(trimmed.prefix(240))
    }

    func normalizeTaskDescription(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(8_000))
    }

    func normalizeTaskPriority(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(["low", "medium", "high"])
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    func normalizeTaskStatus(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(ProjectTaskStatus.allCases.map(\.rawValue))
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    func normalizeOptionalTaskActorID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = normalizedActorEntityID(trimmed) else {
            throw ProjectError.invalidPayload
        }
        return normalized
    }

    func normalizeOptionalTaskTeamID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = normalizedActorEntityID(trimmed) else {
            throw ProjectError.invalidPayload
        }
        return normalized
    }

    func normalizeOptionalTaskSelectedModel(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizeOptionalTaskID(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    func normalizeOptionalTaskAuthor(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    func normalizeTaskReference(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let token = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return normalizedEntityID(token)
    }

    func nextProjectTaskID(for project: ProjectRecord) -> String {
        let prefix = projectTaskIDPrefix(for: project)
        let taskPrefix = "\(prefix)-"
        let maxSequence = project.tasks.reduce(0) { partial, task in
            max(partial, taskSequenceNumber(taskID: task.id, prefix: taskPrefix) ?? 0)
        }
        return "\(prefix)-\(maxSequence + 1)"
    }

    func projectTaskIDPrefix(for project: ProjectRecord) -> String {
        var candidates: [String] = []
        if !isLikelyUUID(project.id) {
            candidates.append(project.id)
        }
        candidates.append(project.name)
        if isLikelyUUID(project.id) {
            candidates.append(project.id)
        }

        for candidate in candidates {
            let normalized = normalizeTaskPrefix(candidate)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return "PROJECT"
    }

    func taskSequenceNumber(taskID: String, prefix: String) -> Int? {
        let uppercased = taskID.uppercased()
        guard uppercased.hasPrefix(prefix) else {
            return nil
        }

        let suffix = String(uppercased.dropFirst(prefix.count))
        guard !suffix.isEmpty,
              suffix.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil
        else {
            return nil
        }
        return Int(suffix)
    }

    func normalizeTaskPrefix(_ raw: String) -> String {
        let uppercased = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !uppercased.isEmpty else {
            return ""
        }

        let compacted = uppercased.replacingOccurrences(
            of: #"[^A-Z0-9]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = compacted.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(80))
    }

    func isLikelyUUID(_ raw: String) -> Bool {
        raw.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    func jsonValue(for task: ProjectTask) -> JSONValue {
        .object([
            "id": .string(task.id),
            "title": .string(task.title),
            "description": .string(task.description),
            "priority": .string(task.priority),
            "status": .string(task.status),
            "actorId": task.actorId.map { .string($0) } ?? .null,
            "teamId": task.teamId.map { .string($0) } ?? .null,
            "claimedActorId": task.claimedActorId.map { .string($0) } ?? .null,
            "claimedAgentId": task.claimedAgentId.map { .string($0) } ?? .null,
            "swarmId": task.swarmId.map { .string($0) } ?? .null,
            "swarmTaskId": task.swarmTaskId.map { .string($0) } ?? .null,
            "swarmParentTaskId": task.swarmParentTaskId.map { .string($0) } ?? .null,
            "swarmDependencyIds": task.swarmDependencyIds.map { .array($0.map { .string($0) }) } ?? .null,
            "swarmDepth": task.swarmDepth.map { .number(Double($0)) } ?? .null,
            "swarmActorPath": task.swarmActorPath.map { .array($0.map { .string($0) }) } ?? .null,
            "selectedModel": task.selectedModel.map { .string($0) } ?? .null,
            "attachments": .array(task.attachments.map { attachment in
                .object([
                    "name": .string(attachment.name),
                    "mimeType": .string(attachment.mimeType),
                    "sizeBytes": .number(Double(attachment.sizeBytes)),
                    "contentBase64": attachment.contentBase64.map { .string($0) } ?? .null
                ])
            }),
            "createdAt": .string(ISO8601DateFormatter().string(from: task.createdAt)),
            "updatedAt": .string(ISO8601DateFormatter().string(from: task.updatedAt))
        ])
    }

    func normalizeChannelTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Channel"
        }
        return String(trimmed.prefix(160))
    }

    func normalizeTaskTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for value in raw {
            let tag = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !tag.isEmpty else {
                continue
            }
            let key = tag.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            tags.append(tag)
            if tags.count >= 24 {
                break
            }
        }
        return tags
    }

    func normalizeTaskAttachments(_ raw: [AgentAttachmentUpload]) -> [AgentAttachmentUpload] {
        var seen = Set<String>()
        var attachments: [AgentAttachmentUpload] = []
        for attachment in raw {
            let name = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                continue
            }
            let mimeType = attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(name.lowercased())|\(attachment.sizeBytes)|\(mimeType.lowercased())"
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            attachments.append(
                AgentAttachmentUpload(
                    name: String(name.prefix(240)),
                    mimeType: String((mimeType.isEmpty ? "application/octet-stream" : mimeType).prefix(120)),
                    sizeBytes: max(0, attachment.sizeBytes),
                    contentBase64: attachment.contentBase64
                )
            )
            if attachments.count >= 12 {
                break
            }
        }
        return attachments
    }

    func normalizeTaskDependencyIds(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for value in raw {
            let id = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard !id.isEmpty, !seen.contains(id) else {
                continue
            }
            seen.insert(id)
            ids.append(id)
            if ids.count >= 64 {
                break
            }
        }
        return ids
    }

    func validateProjectTaskDependencies(project: ProjectRecord) throws {
        let tasksByID = Dictionary(uniqueKeysWithValues: project.tasks.map { ($0.id, $0) })
        let taskIDs = Set(tasksByID.keys)

        for task in project.tasks {
            for dependencyID in task.dependsOnTaskIds {
                guard taskIDs.contains(dependencyID) else {
                    throw ProjectError.invalidPayload
                }
                guard dependencyID != task.id else {
                    throw ProjectError.invalidPayload
                }
            }
        }

        var visiting = Set<String>()
        var visited = Set<String>()

        func visit(_ taskID: String) throws {
            if visited.contains(taskID) {
                return
            }
            guard !visiting.contains(taskID) else {
                throw ProjectError.invalidPayload
            }
            visiting.insert(taskID)
            for dependencyID in tasksByID[taskID]?.dependsOnTaskIds ?? [] {
                try visit(dependencyID)
            }
            visiting.remove(taskID)
            visited.insert(taskID)
        }

        for taskID in taskIDs {
            try visit(taskID)
        }
    }

    func promoteTasksUnblockedByCompletedDependency(projectID: String, completedTaskID: String) async -> ProjectRecord? {
        guard var project = await store.project(id: projectID) else {
            return nil
        }

        var promotedTasks: [ProjectTask] = []
        let now = Date()

        // Pre-compute the autopilot active count before any promotion mutations.
        // This is used to enforce sequential/assistive capacity so we do not
        // over-promote when multiple tasks become unblocked simultaneously.
        let autopilotActiveCountBaseline = project.tasks.filter { t in
            t.id != completedTaskID &&
            isAutopilotExecutionTask(project: project, task: t) &&
            activeAutopilotStatuses.contains(t.status)
        }.count
        var autopilotPromotedInThisPass = 0

        for index in project.tasks.indices {
            var task = project.tasks[index]
            guard task.status == ProjectTaskStatus.backlog.rawValue,
                  task.dependsOnTaskIds.contains(completedTaskID),
                  pickupRulesPermit(project: project, task: task),
                  taskDependenciesSatisfied(project: project, task: task)
            else {
                continue
            }

            // Enforce autopilot sequential/assistive capacity for managed tasks.
            if project.autopilotSettings.enabled,
               isAutopilotManagedTask(project: project, task: task) {
                let effectiveActive = autopilotActiveCountBaseline + autopilotPromotedInThisPass
                let capacity = autopilotCapacity(settings: project.autopilotSettings, activeCount: effectiveActive)
                guard capacity > 0 else {
                    // Leave task in backlog; visor scheduler will release it later.
                    appendTaskLifecycleLog(
                        projectID: project.id,
                        taskID: task.id,
                        stage: "autopilot_capacity_wait",
                        channelID: resolveExecutionChannelID(project: project, task: task),
                        workerID: nil,
                        message: "Task kept in backlog after dependency completed: autopilot sequential capacity is at limit.",
                        actorID: task.actorId,
                        agentID: task.claimedAgentId
                    )
                    continue
                }
                autopilotPromotedInThisPass += 1
            }

            let previousStatus = task.status
            task.status = ProjectTaskStatus.ready.rawValue
            task.updatedAt = now
            project.tasks[index] = task
            promotedTasks.append(task)
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "dependency_promoted",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: "Task promoted to ready after dependencies completed.",
                actorID: task.actorId,
                agentID: task.claimedAgentId
            )
            await recordSystemStatusChange(
                projectID: project.id,
                taskID: task.id,
                from: previousStatus,
                to: task.status,
                source: "system"
            )
        }

        guard !promotedTasks.isEmpty else {
            return project
        }

        project.updatedAt = now
        await store.saveProject(project)
        for task in promotedTasks {
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        }
        return project
    }

    func normalizedProjectID(_ raw: String) -> String? {
        normalizedEntityID(raw)
    }

    func normalizedSourceControlProviderID(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        return normalizedEntityID(raw)
    }

    func normalizedEntityID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil, trimmed.count <= 180 else {
            return nil
        }

        return trimmed
    }

    func normalizedChannelID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
            .union(CharacterSet(charactersIn: "\u{001E}"))
        guard !trimmed.isEmpty, trimmed.count <= 200, trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw ProjectError.invalidChannelID
        }
        return trimmed
    }

    func channelBindingsConflict(_ left: String, _ right: String) -> Bool {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }
        return lhs == rhs
    }

    func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let separated = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return separated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func projectDirectoryURL(projectID: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
    }

    func defaultWorktreeRootPath(projectID: String) -> String {
        workspaceRootURL
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private func projectWithRuntimePaths(_ project: ProjectRecord) -> ProjectRecord {
        var result = project
        result.directoryPaths = effectiveProjectDirectoryURLs(project).map(\.path)
        result.worktreeRootPath = defaultWorktreeRootPath(projectID: project.id)
        return result
    }

    private func projectSummaryWithRuntimePaths(_ project: ProjectListRecord) -> ProjectListRecord {
        var result = project
        if result.directoryPaths.isEmpty {
            result.directoryPaths = [
                resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: project.id).path
            ]
        }
        result.worktreeRootPath = defaultWorktreeRootPath(projectID: project.id)
        return result
    }

    func effectiveProjectDirectoryURLs(_ project: ProjectRecord) -> [URL] {
        let stored = project.directoryPaths.compactMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        let candidates = stored.isEmpty
            ? [resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: project.id)]
            : stored
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
    }

    func resolveProjectWorkspaceRoots(projectID: String) async throws -> [URL] {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            return [try await resolveProjectWorkspaceRoot(projectID: normalizedID)]
        }
        return effectiveProjectDirectoryURLs(project)
    }

    func normalizedProjectDirectoryPaths(_ rawPaths: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawPath in rawPaths {
            guard let normalized = try normalizedExternalProjectPath(rawPath) else { continue }
            let identity = URL(fileURLWithPath: normalized, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            if seen.insert(identity).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    func validateProjectDirectories(kind: ProjectKind, directoryPaths: [String]) throws {
        switch kind {
        case .project:
            guard directoryPaths.count <= 1 else { throw ProjectError.invalidPayload }
        case .workspace:
            guard directoryPaths.count >= 2 else { throw ProjectError.invalidPayload }
        }
    }

    private func computedWorktreeMetadataProjects(_ projects: [ProjectRecord]) -> [ProjectRecord] {
        let metadata = computedWorktreeMetadata(
            projects.map {
                ProjectWorktreeInput(
                    id: $0.id,
                    repoPath: $0.repoPath,
                    worktreeRootPath: $0.worktreeRootPath
                )
            }
        )
        return projects.map { project in
            var result = project
            if let item = metadata[project.id] {
                result.parentProjectId = item.parentProjectId
                result.worktreeBranch = item.worktreeBranch
                result.isWorktree = item.isWorktree
            } else {
                result.parentProjectId = nil
                result.worktreeBranch = nil
                result.isWorktree = false
            }
            return result
        }
    }

    private func computedWorktreeMetadataSummaries(_ projects: [ProjectListRecord]) -> [ProjectListRecord] {
        let metadata = computedWorktreeMetadata(
            projects.map {
                ProjectWorktreeInput(
                    id: $0.id,
                    repoPath: $0.repoPath,
                    worktreeRootPath: $0.worktreeRootPath
                )
            }
        )
        return projects.map { project in
            var result = project
            if let item = metadata[project.id] {
                result.parentProjectId = item.parentProjectId
                result.worktreeBranch = item.worktreeBranch
                result.isWorktree = item.isWorktree
            } else {
                result.parentProjectId = nil
                result.worktreeBranch = nil
                result.isWorktree = false
            }
            return result
        }
    }

    private func computedWorktreeMetadata(
        _ projects: [ProjectWorktreeInput]
    ) -> [String: ProjectComputedWorktreeMetadata] {
        let projectRoots = Dictionary(
            uniqueKeysWithValues: projects.map { project in
                (
                    project.id,
                    resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: project.id)
                        .standardizedFileURL
                        .path
                )
            }
        )
        let gitMetadata = Dictionary(
            uniqueKeysWithValues: projects.compactMap { project -> (String, ProjectGitWorktreeMetadata)? in
                guard let root = projectRoots[project.id],
                      let metadata = gitWorktreeMetadata(at: root)
                else {
                    return nil
                }
                return (project.id, metadata)
            }
        )
        var result: [String: ProjectComputedWorktreeMetadata] = [:]

        for child in projects {
            guard let childRoot = projectRoots[child.id] else {
                continue
            }

            let gitBranch = gitMetadata[child.id]?.branch
            if let parent = fallbackWorktreeParent(for: child, childRoot: childRoot, projects: projects, projectRoots: projectRoots) {
                result[child.id] = ProjectComputedWorktreeMetadata(
                    parentProjectId: parent.id,
                    worktreeBranch: gitBranch ?? lastPathComponent(childRoot),
                    isWorktree: true
                )
                continue
            }

            guard let childGit = gitMetadata[child.id], childGit.isWorktree else {
                continue
            }

            let parent = projects.first { candidate in
                guard candidate.id != child.id,
                      let candidateGit = gitMetadata[candidate.id],
                      candidateGit.commonDirectory == childGit.commonDirectory
                else {
                    return false
                }
                return !candidateGit.isWorktree
            }

            if let parent {
                result[child.id] = ProjectComputedWorktreeMetadata(
                    parentProjectId: parent.id,
                    worktreeBranch: childGit.branch ?? lastPathComponent(childRoot),
                    isWorktree: true
                )
            }
        }

        return result
    }

    private func fallbackWorktreeParent(
        for child: ProjectWorktreeInput,
        childRoot: String,
        projects: [ProjectWorktreeInput],
        projectRoots: [String: String]
    ) -> ProjectWorktreeInput? {
        projects.first { parent in
            guard parent.id != child.id, let parentRoot = projectRoots[parent.id] else {
                return false
            }
            let repoWorktreeRoot = URL(fileURLWithPath: parentRoot, isDirectory: true)
                .appendingPathComponent(".sloppy-worktrees", isDirectory: true)
                .standardizedFileURL
                .path
            if path(childRoot, isInsideDirectory: repoWorktreeRoot) {
                return true
            }
            guard let configuredRoot = parent.worktreeRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !configuredRoot.isEmpty
            else {
                return false
            }
            let standardizedConfiguredRoot = URL(fileURLWithPath: configuredRoot, isDirectory: true)
                .standardizedFileURL
                .path
            return path(childRoot, isInsideDirectory: standardizedConfiguredRoot)
        }
    }

    private func gitWorktreeMetadata(at repoPath: String) -> ProjectGitWorktreeMetadata? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git",
            "-C",
            repoPath,
            "rev-parse",
            "--git-dir",
            "--git-common-dir",
            "--abbrev-ref",
            "HEAD"
        ]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard lines.count >= 2 else {
            return nil
        }

        let gitDirectory = standardizedGitPath(lines[0], relativeTo: repoPath)
        let commonDirectory = standardizedGitPath(lines[1], relativeTo: repoPath)
        let branch = lines.count >= 3 && lines[2] != "HEAD" ? lines[2] : nil
        return ProjectGitWorktreeMetadata(
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            branch: branch
        )
    }

    private func standardizedGitPath(_ value: String, relativeTo repoPath: String) -> String {
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        return URL(fileURLWithPath: repoPath, isDirectory: true)
            .appendingPathComponent(value)
            .standardizedFileURL
            .path
    }

    private func path(_ childPath: String, isInsideDirectory parentPath: String) -> Bool {
        let child = URL(fileURLWithPath: childPath, isDirectory: true).standardizedFileURL.path
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL.path
        return child != parent && child.hasPrefix(parent + "/")
    }

    private func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    /// Resolves persisted `repoPath` to a workspace directory URL.
    /// Paths like `/projects/<id>` are stored as if absolute but are intended relative to the Sloppy workspace root.
    private func resolvedProjectRootFromStored(repoPath: String?, normalizedProjectID: String) -> URL {
        guard let raw = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return projectDirectoryURL(projectID: normalizedProjectID).standardized
        }
        let direct = URL(fileURLWithPath: raw, isDirectory: true).standardized
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return direct
        }
        if raw.hasPrefix("/projects/") || raw.hasPrefix("projects/") {
            let relative = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            let segments = relative.split(separator: "/").map(String.init)
            if !segments.isEmpty {
                let candidate = segments.reduce(workspaceRootURL) { base, segment in
                    base.appendingPathComponent(segment, isDirectory: true)
                }.standardized
                isDirectory = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return candidate
                }
            }
            return projectDirectoryURL(projectID: normalizedProjectID).standardized
        }
        return direct
    }

    func resolveProjectWorkspaceRoot(projectID: String) async throws -> URL {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }

        if normalizedID == Self.sloppyProjectsDirectoryScopeID {
            let projectsRootURL = workspaceRootURL.appendingPathComponent("projects", isDirectory: true).standardized
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectsRootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProjectError.notFound
            }
            return projectsRootURL
        }

        if let project = await store.project(id: normalizedID) {
            return resolvedProjectRootFromStored(repoPath: project.repoPath, normalizedProjectID: normalizedID)
        }

        let diskProjectURL = projectDirectoryURL(projectID: normalizedID).standardized
        let projectsRoot = workspaceRootURL.appendingPathComponent("projects", isDirectory: true)
        guard isProjectURL(diskProjectURL, inside: projectsRoot),
              diskProjectURL.resolvingSymlinksInPath().standardizedFileURL != projectsRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProjectError.invalidProjectID
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: diskProjectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ProjectError.notFound
        }
        return diskProjectURL
    }

    func isProjectURL(_ url: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }

    func projectMetaDirectoryURL(projectID: String) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent(".meta", isDirectory: true)
    }

    func projectMetaStore() -> ProjectMetaStore {
        ProjectMetaStore(workspaceRootURL: workspaceRootURL)
    }

    func projectMetaMemoryFileURL(projectID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID).appendingPathComponent("MEMORY.md", isDirectory: false)
    }

    func projectTaskLogFileURL(projectID: String, taskID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID).appendingPathComponent("task-\(taskID).log")
    }

    func relativePathFromWorkspace(_ url: URL) -> String {
        let workspacePath = workspaceRootURL.path
        let targetPath = url.path
        if targetPath.hasPrefix(workspacePath) {
            let suffix = targetPath.dropFirst(workspacePath.count)
            return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        }
        return targetPath
    }

}
