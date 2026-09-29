import Foundation
import AgentRuntime
import Protocols

// MARK: - Agent Sessions

extension CoreService {
    public func listAgentSessions(
        agentID: String,
        projectID: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [AgentSessionSummary] {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            _ = deleteExpiredAgentSessionsIfNeeded()
            var sessions = try sessionStore.listSessions(agentID: normalizedAgentID)
            if let filter = projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
                sessions = sessions.filter { ($0.projectId ?? "").caseInsensitiveCompare(filter) == .orderedSame }
            }
            return Self.paginatedAgentSessions(sessions, limit: limit, offset: offset)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    /// Creates a session for a given agent.
    public func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        await waitForStartup()
        await deleteExpiredSessionsIfNeeded()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        _ = try getAgent(id: normalizedAgentID)

        let checkpointSessionID = request.checkpointSessionId
            .flatMap { normalizedSessionID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        do {
            let session = try await sessionOrchestrator.createSession(agentID: normalizedAgentID, request: request)
            if let parentSessionID = session.parentSessionId {
                try await toolExecution.desktopComputerBridge.inheritAssignment(
                    parentSessionID: parentSessionID, agentID: normalizedAgentID, sessionID: session.id
                )
            }
            if let checkpointSessionID {
                scheduleAgentMemoryCheckpoint(
                    agentID: normalizedAgentID,
                    sessionID: checkpointSessionID,
                    reason: "new_session_command"
                )
            }
            if !currentConfig.onboarding.completed,
               request.title?.localizedCaseInsensitiveContains("onboarding") == true {
                logger.info(
                    "onboarding.session.created",
                    metadata: [
                        "agent_id": .string(normalizedAgentID),
                        "session_id": .string(session.id),
                        "title": .string(request.title ?? "")
                    ]
                )
            }
            return session
        } catch {
            throw mapSessionOrchestratorError(error)
        }
    }

    /// Loads one session with its full event history.
    public func getAgentSession(agentID: String, sessionID: String) throws -> AgentSessionDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    public func getAgentSessionFilePath(agentID: String, sessionID: String) throws -> String {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try sessionStore.sessionFilePath(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    public func prepareAgentSessionContext(agentID: String, sessionID: String) async throws -> AgentSessionSummary {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)
        let detail = try getAgentSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)

        do {
            try await sessionOrchestrator.prepareSessionContext(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID
            )
            return detail.summary
        } catch {
            throw mapSessionOrchestratorError(error)
        }
    }

    public func hasLiveAgentRuntimeSession(agentID: String, sessionID: String) async throws -> Bool {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)
        _ = try getAgentSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)

        return await sessionOrchestrator.hasLiveRuntimeSession(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID
        )
    }

    /// Adds a directory as a session-scoped tool root. The first added directory also becomes
    /// the default current directory for sessions that do not already have one.
    public func addAgentSessionDirectory(
        agentID: String,
        sessionID: String,
        request: AgentSessionDirectoryRequest
    ) async throws -> AgentSessionDirectoryResponse {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)
        let detail: AgentSessionDetail
        do {
            detail = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            throw mapSessionStoreError(error)
        }

        let existingContext = await toolContextForSession(
            sessionID: normalizedSessionID,
            sessionTitle: detail.summary.title,
            projectID: detail.summary.projectId,
            taskID: detail.summary.taskId
        )
        let resolvedPath = try resolvedSessionDirectoryPath(
            request.path,
            baseDirectory: existingContext.workingDirectory
        )
        let workingDirectory = existingContext.workingDirectory ?? resolvedPath
        let roots = appendingUniqueRoot(resolvedPath, to: existingContext.extraRoots)
        sessionAddedRoots[normalizedSessionID] = appendingUniqueRoot(
            resolvedPath,
            to: sessionAddedRoots[normalizedSessionID] ?? []
        )

        sessionExtraRoots[normalizedSessionID] = roots
        sessionWorkingDirectories[normalizedSessionID] = workingDirectory

        return AgentSessionDirectoryResponse(
            path: resolvedPath,
            workingDirectory: workingDirectory,
            directories: roots
        )
    }

    public func canStreamAgentSessionEvents(agentID: String, sessionID: String) -> Bool {
        do {
            let identifiers = try validatedStreamIdentifiers(agentID: agentID, sessionID: sessionID)
            _ = try getAgentSession(agentID: identifiers.agentID, sessionID: identifiers.sessionID)
            return true
        } catch {
            return false
        }
    }

    /// Streams incremental session updates over a long-lived connection.
    public func streamAgentSessionEvents(agentID: String, sessionID: String) throws -> AsyncStream<AgentSessionStreamUpdate> {
        let identifiers = try validatedStreamIdentifiers(agentID: agentID, sessionID: sessionID)
        let detail = try getAgentSession(agentID: identifiers.agentID, sessionID: identifiers.sessionID)
        let streamKey = sessionStreamKey(agentID: identifiers.agentID, sessionID: identifiers.sessionID)

        return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let listenerID = UUID()
            let readyCursor = max(detail.events.count, currentLiveSessionStreamCursor(for: streamKey))
            setLiveSessionStreamCursor(readyCursor, for: streamKey)
            registerLiveSessionStreamContinuation(
                key: streamKey,
                listenerID: listenerID,
                continuation: continuation
            )

            continuation.yield(
                AgentSessionStreamUpdate(
                    kind: .sessionReady,
                    cursor: readyCursor,
                    summary: detail.summary
                )
            )

            let heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    if Task.isCancelled {
                        break
                    }
                    guard isLiveSessionStreamContinuationRegistered(key: streamKey, listenerID: listenerID) else {
                        break
                    }

                    continuation.yield(
                        AgentSessionStreamUpdate(
                            kind: .heartbeat,
                            cursor: nextLiveSessionStreamCursor(for: streamKey),
                            summary: detail.summary
                        )
                    )
                }
            }

            continuation.onTermination = { _ in
                heartbeatTask.cancel()
                Task {
                    await self.unregisterLiveSessionStreamContinuation(key: streamKey, listenerID: listenerID)
                }
            }
        }
    }

    func publishLiveSessionDelta(agentID: String, sessionID: String, chunk: String) {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty else {
            return
        }

        publishLiveSessionUpdate(
            agentID: agentID,
            sessionID: sessionID,
            update: AgentSessionStreamUpdate(
            kind: .sessionDelta,
            cursor: 0,
            message: normalized
            )
        )
    }

    func publishLiveSessionEvents(
        agentID: String,
        sessionID: String,
        summary: AgentSessionSummary,
        events: [AgentSessionEvent]
    ) {
        for event in events {
            publishLiveSessionUpdate(
                agentID: agentID,
                sessionID: sessionID,
                update: AgentSessionStreamUpdate(
                    kind: .sessionEvent,
                    cursor: 0,
                    summary: summary,
                    event: event
                )
            )
        }
    }

    func publishLiveSessionClosed(agentID: String, sessionID: String, message: String) {
        publishLiveSessionUpdate(
            agentID: agentID,
            sessionID: sessionID,
            update: AgentSessionStreamUpdate(
                kind: .sessionClosed,
                cursor: 0,
                message: message
            )
        )
    }

    func publishLiveSessionUpdate(
        agentID: String,
        sessionID: String,
        update: AgentSessionStreamUpdate
    ) {
        let key = sessionStreamKey(agentID: agentID, sessionID: sessionID)
        guard let listeners = liveSessionStreamContinuations[key], !listeners.isEmpty else {
            return
        }

        var published = update
        published.cursor = nextLiveSessionStreamCursor(for: key)
        for continuation in listeners.values {
            continuation.yield(published)
        }
    }

    func registerLiveSessionStreamContinuation(
        key: String,
        listenerID: UUID,
        continuation: AsyncStream<AgentSessionStreamUpdate>.Continuation
    ) {
        var listeners = liveSessionStreamContinuations[key] ?? [:]
        listeners[listenerID] = continuation
        liveSessionStreamContinuations[key] = listeners
    }

    func unregisterLiveSessionStreamContinuation(key: String, listenerID: UUID) {
        guard var listeners = liveSessionStreamContinuations[key] else {
            return
        }

        listeners.removeValue(forKey: listenerID)
        if listeners.isEmpty {
            liveSessionStreamContinuations.removeValue(forKey: key)
            liveSessionStreamCursor.removeValue(forKey: key)
        } else {
            liveSessionStreamContinuations[key] = listeners
        }
    }

    func isLiveSessionStreamContinuationRegistered(key: String, listenerID: UUID) -> Bool {
        liveSessionStreamContinuations[key]?[listenerID] != nil
    }

    func currentLiveSessionStreamCursor(for key: String) -> Int {
        liveSessionStreamCursor[key] ?? 0
    }

    func setLiveSessionStreamCursor(_ value: Int, for key: String) {
        liveSessionStreamCursor[key] = value
    }

    func nextLiveSessionStreamCursor(for key: String) -> Int {
        let baseline = max(1_000_000, liveSessionStreamCursor[key] ?? 1_000_000)
        let next = baseline + 1
        liveSessionStreamCursor[key] = next
        return next
    }

    func sessionStreamKey(agentID: String, sessionID: String) -> String {
        "\(agentID)::\(sessionID)"
    }

    func validatedStreamIdentifiers(
        agentID: String,
        sessionID: String
    ) throws -> (agentID: String, sessionID: String) {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)
        return (normalizedAgentID, normalizedSessionID)
    }

    /// Deletes one session and its attachment directory.
    public func deleteAgentSession(agentID: String, sessionID: String) async throws {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            try sessionStore.deleteSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
            publishLiveSessionClosed(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                message: "Session was deleted."
            )
            await acpSessionManager.removeSession(agentID: normalizedAgentID, sloppySessionID: normalizedSessionID)
            await toolExecution.cleanupSessionProcesses(normalizedSessionID)
            await toolLoopGuard.cleanup(sessionID: normalizedSessionID)
            sessionExtraRoots.removeValue(forKey: normalizedSessionID)
            sessionWorkingDirectories.removeValue(forKey: normalizedSessionID)
            sessionAddedRoots.removeValue(forKey: normalizedSessionID)
            sessionSubagentToolAllowList.removeValue(forKey: normalizedSessionID)
            sessionToolApprovalBypass.remove(normalizedSessionID)
            sessionToolApprovalRequired.remove(normalizedSessionID)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    /// Appends user message, run-status events and assistant reply into session JSONL.
    public func postAgentSessionMessage(
        agentID: String,
        sessionID: String,
        request: AgentSessionPostMessageRequest
    ) async throws -> AgentSessionMessageResponse {
        let effectiveRequest = AgentSessionOrchestrator.requestByApplyingOneShotModeCommand(request)
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)
        if effectiveRequest.userId == "onboarding" {
            logger.info(
                "onboarding.message.posted",
                metadata: [
                    "agent_id": .string(normalizedAgentID),
                    "session_id": .string(normalizedSessionID),
                    "content_chars": .stringConvertible(effectiveRequest.content.count)
                ]
            )
        }

        if effectiveRequest.mode == .debug {
            do {
                let detail = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
                await ensureDebugDirectoryForSessionIfNeeded(
                    chatMode: effectiveRequest.mode,
                    sessionID: normalizedSessionID,
                    sessionTitle: detail.summary.title,
                    projectID: detail.summary.projectId
                )
            } catch {
                throw mapSessionStoreError(error)
            }
        }

        let bypassToolUsageLimits = Self.shouldBypassToolUsageLimits(userID: effectiveRequest.userId)
        if bypassToolUsageLimits {
            sessionToolUsageLimitBypass.insert(normalizedSessionID)
        }
        defer {
            if bypassToolUsageLimits {
                sessionToolUsageLimitBypass.remove(normalizedSessionID)
            }
        }

        do {
            if !["system_task_worker", "memory_checkpoint", "onboarding", "goal", "goal_loop"].contains(effectiveRequest.userId.lowercased()) {
                await toolLoopGuard.beginTurn(sessionID: normalizedSessionID)
            }
            if let execution = projectExecutionSessions[normalizedSessionID] {
                let pickupEnabled = await store.project(id: execution.projectID)?.automaticTaskPickupEnabled == true
                guard pickupEnabled, execution.generation == projectStopGenerations[execution.projectID, default: 0] else {
                    throw CancellationError()
                }
            }
            let response = try await sessionOrchestrator.postMessage(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: effectiveRequest
            )
            let uid = effectiveRequest.userId.lowercased()
            let skipUserTurnCount = uid == "system_task_worker" || uid == "memory_checkpoint" || uid == "onboarding" || uid == "goal" || uid == "goal_loop"
            if !skipUserTurnCount {
                do {
                    let count = try sessionStore.incrementUserTurnCount(
                        agentID: normalizedAgentID,
                        sessionID: normalizedSessionID
                    )
                    if count >= CoreService.agentMemoryCheckpointUserTurnThreshold {
                        scheduleAgentMemoryCheckpoint(
                            agentID: normalizedAgentID,
                            sessionID: normalizedSessionID,
                            reason: "user_turn_threshold"
                        )
                    }
                } catch {
                    logger.warning(
                        "memory.checkpoint.user_turn_count_failed",
                        metadata: ["error": .string(error.localizedDescription)]
                    )
                }
            }
            maybeScheduleSelfImprovementProposalReviewAfterTurn(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                response: response,
                userID: effectiveRequest.userId
            )
            await scheduleGoalContinuationIfNeeded(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: effectiveRequest,
                response: response
            )
            return response
        } catch {
            throw mapSessionOrchestratorError(error)
        }
    }

    public func startAgentSessionGoal(
        agentID: String,
        sessionID: String,
        request: AgentSessionGoalStartRequest
    ) async throws -> AgentSessionGoalRecord {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        _ = try getAgent(id: normalizedAgentID)
        _ = try getAgentSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)

        let objective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw AgentSessionError.invalidPayload
        }

        let goal = await sessionGoalController.start(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            objective: objective,
            maxAttempts: request.maxAttempts ?? 8
        )
        let userID = request.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await postAgentSessionMessage(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            request: AgentSessionPostMessageRequest(
                userId: userID.isEmpty ? "goal" : userID,
                content: SloppyTUIGoalPromptFormatter.initialPrompt(objective: objective),
                reasoningEffort: request.reasoningEffort,
                mode: request.mode
            )
        )
        return (await sessionGoalController.goal(agentID: normalizedAgentID, sessionID: normalizedSessionID)) ?? goal
    }

    public func getAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        return await sessionGoalController.goal(agentID: normalizedAgentID, sessionID: normalizedSessionID)
    }

    public func pauseAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        return await sessionGoalController.pause(agentID: normalizedAgentID, sessionID: normalizedSessionID)
    }

    public func resumeAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        guard let goal = await sessionGoalController.resume(agentID: normalizedAgentID, sessionID: normalizedSessionID) else {
            return nil
        }
        if goal.status == .active {
            _ = try await postAgentSessionMessage(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: AgentSessionPostMessageRequest(
                    userId: "goal_loop",
                    content: SloppyTUIGoalPromptFormatter.continuationPrompt(goal: goal)
                )
            )
        }
        return await sessionGoalController.goal(agentID: normalizedAgentID, sessionID: normalizedSessionID)
    }

    public func clearAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        return await sessionGoalController.clear(agentID: normalizedAgentID, sessionID: normalizedSessionID)
    }

    private func scheduleGoalContinuationIfNeeded(
        agentID: String,
        sessionID: String,
        request: AgentSessionPostMessageRequest,
        response: AgentSessionMessageResponse
    ) async {
        let userID = request.userId.lowercased()
        guard userID == "goal" || userID == "goal_loop" else {
            return
        }
        guard let evaluation = await sessionGoalController.evaluateTurn(
            agentID: agentID,
            sessionID: sessionID,
            events: response.appendedEvents
        ),
              evaluation.shouldContinue,
              let prompt = evaluation.continuationPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else {
            return
        }

        Task { [weak self] in
            do {
                _ = try await self?.postAgentSessionMessage(
                    agentID: agentID,
                    sessionID: sessionID,
                    request: AgentSessionPostMessageRequest(
                        userId: "goal_loop",
                        content: prompt,
                        reasoningEffort: request.reasoningEffort,
                        mode: request.mode
                    )
                )
            } catch {
                self?.logger.warning(
                    "session.goal.continuation_failed",
                    metadata: [
                        "agent_id": .string(agentID),
                        "session_id": .string(sessionID),
                        "error": .string(error.localizedDescription)
                    ]
                )
            }
        }
    }

    /// Appends control signal (pause/resume/interrupt) and corresponding status.
    public func controlAgentSession(
        agentID: String,
        sessionID: String,
        request: AgentSessionControlRequest
    ) async throws -> AgentSessionMessageResponse {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            let response = try await sessionOrchestrator.controlSession(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request
            )
            if request.action == .interrupt || request.action == .interruptTree {
                let interruptedSessionIDs = Set(response.appendedEvents.map(\.sessionId))
                for interruptedSessionID in interruptedSessionIDs {
                    await toolExecution.cleanupSessionProcesses(interruptedSessionID)
                }
            }
            return response
        } catch {
            throw mapSessionOrchestratorError(error)
        }
    }

    public func appendAgentSessionEvents(
        agentID: String,
        sessionID: String,
        request: AgentSessionAppendEventsRequest
    ) async throws -> AgentSessionMessageResponse {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try await sessionOrchestrator.appendSessionEvents(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                events: request.events
            )
        } catch {
            throw mapSessionOrchestratorError(error)
        }
    }

    func addChannelSessionDirectory(
        channelID: String,
        request: AgentSessionDirectoryRequest
    ) async throws -> AgentSessionDirectoryResponse {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else {
            throw AgentSessionError.invalidSessionID
        }

        let existingContext = await toolContextForChannel(channelID: normalizedChannelID)
        let resolvedPath = try resolvedSessionDirectoryPath(
            request.path,
            baseDirectory: existingContext.workingDirectory
        )
        let workingDirectory = existingContext.workingDirectory ?? resolvedPath
        let roots = appendingUniqueRoot(resolvedPath, to: existingContext.extraRoots)
        channelAddedRoots[normalizedChannelID] = appendingUniqueRoot(
            resolvedPath,
            to: channelAddedRoots[normalizedChannelID] ?? []
        )

        channelExtraRoots[normalizedChannelID] = roots
        channelWorkingDirectories[normalizedChannelID] = workingDirectory

        return AgentSessionDirectoryResponse(
            path: resolvedPath,
            workingDirectory: workingDirectory,
            directories: roots
        )
    }

    func resolvedSessionDirectoryPath(_ rawPath: String, baseDirectory: String?) throws -> String {
        var trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentSessionError.invalidPayload
        }

        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else {
            throw AgentSessionError.invalidPayload
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            let base = baseDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            let basePath = base?.isEmpty == false ? base! : workspaceRootURL.path
            let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
            candidate = baseURL.appendingPathComponent(expanded, isDirectory: true)
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AgentSessionError.invalidPayload
        }
        return resolved.path
    }

    func appendingUniqueRoot(_ root: String, to roots: [String]) -> [String] {
        var result = roots
        if !result.contains(root) {
            result.append(root)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func paginatedAgentSessions(
        _ sessions: [AgentSessionSummary],
        limit: Int?,
        offset: Int
    ) -> [AgentSessionSummary] {
        let start = min(max(0, offset), sessions.count)
        let tail = sessions[start...]
        guard let limit else {
            return Array(tail)
        }
        return Array(tail.prefix(max(0, limit)))
    }

    private static func shouldBypassToolUsageLimits(userID: String) -> Bool {
        let normalized = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "tui" || normalized == "onboarding"
    }

}
