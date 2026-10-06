import AgentRuntime
import Foundation
import Protocols
import SloppyRuntime

extension CoreService {
    func longChats() throws -> LongChatFileStore {
        if let longChatStorage { return longChatStorage }
        let store = try LongChatFileStore(root: workspaceRootURL)
        longChatStorage = store
        return store
    }

    public func openLongChat(agentID: String, userID: String, projectID: String? = nil) async throws -> AgentSessionSummary {
        await waitForStartup()
        guard let agentID = normalizedAgentID(agentID), !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AgentSessionError.invalidPayload }
        _ = try getAgent(id: agentID)
        let config = try agentCatalogStore.getAgentRuntimeConfig(agentID: agentID)
        guard config.type == .native else { throw AgentSessionError.invalidPayload }
        let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let projectID {
            guard !projectID.isEmpty else { throw AgentSessionError.invalidPayload }
            _ = try await getProject(id: projectID)
        }
        // From here, no suspension between migration, lookup and reservation.
        let storage = try longChats()
        if let projectID {
            let separate = Set(storage.state.separateSessionIds ?? [])
            for session in try sessionStore.listSessions(agentID: agentID)
                where session.projectId == projectID && session.parentSessionId == nil
                    && session.taskId == nil && session.workspaceId == nil
                    && session.kind == .chat && !separate.contains(session.id) {
                // Reserve ownership before promotion; an interrupted migration is repaired on reopening.
                if !storage.state.conversations.contains(where: { $0.sessionId == session.id }) {
                    try storage.transaction {
                        $0.conversations.append(.init(agentId: agentID, userId: userID, sessionId: session.id,
                                                       assignments: [], projectId: projectID))
                    }
                }
                try sessionStore.promoteToLongChat(agentID: agentID, sessionID: session.id)
            }
        }
        if let existing = storage.state.conversations.first(where: {
            $0.agentId == agentID && $0.userId == userID && $0.projectId == projectID
        }) {
            return try getAgentSession(agentID: agentID, sessionID: existing.sessionId).summary
        }
        let session = try sessionStore.createSession(
            agentID: agentID, request: .init(title: "Conversation", kind: .longChat, projectId: projectID))
        do {
            try storage.transaction {
                $0.conversations.append(.init(agentId: agentID, userId: userID, sessionId: session.id,
                                               assignments: [], projectId: projectID))
            }
        } catch {
            try? sessionStore.deleteSession(agentID: agentID, sessionID: session.id)
            throw error
        }
        return session
    }

    public func getLongChat(agentID: String, sessionID: String) throws -> LongChatConversation {
        let detail = try getAgentSession(agentID: agentID, sessionID: sessionID)
        guard detail.summary.kind == .longChat else { throw AgentSessionError.invalidPayload }
        let conversation = try longChats().conversation(sessionId: sessionID)
        guard conversation.agentId == agentID else { throw AgentSessionError.invalidAgentID }
        return conversation
    }

    /// Receipts are immediate; model turns are serialized in a durable inbox.
    func enqueueLongChatMessage(agentID: String, sessionID: String, request: AgentSessionPostMessageRequest, peerOrigin: AgentSessionPeerOrigin? = nil) throws
        -> AgentSessionMessageResponse
    {
        let conversation = try getLongChat(agentID: agentID, sessionID: sessionID)
        guard conversation.userId == request.userId, !request.spawnSubSession,
            !request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.attachments.isEmpty
        else { throw AgentSessionError.invalidPayload }
        var request = request
        let id = request.clientMessageId ?? UUID().uuidString
        guard UUID(uuidString: id) != nil else { throw AgentSessionError.invalidPayload }
        request.clientMessageId = id
        let storage = try longChats()
        if let existing = storage.state.turns.first(where: { $0.id == id }) {
            guard existing.sessionId == sessionID, existing.agentId == agentID,
                existing.request.content == request.content,
                existing.peerOrigin?.agentId == peerOrigin?.agentId, existing.peerOrigin?.sessionId == peerOrigin?.sessionId
            else { throw AgentSessionError.invalidPayload }
        } else {
            try storage.transaction {
                $0.turns.append(
                    .init(id: id, agentId: agentID, sessionId: sessionID, request: request, isNotification: false, peerOrigin: peerOrigin))
            }
        }
        let event = try persistLongChatTurnIfNeeded(
            .init(id: id, agentId: agentID, sessionId: sessionID, request: request, isNotification: false, peerOrigin: peerOrigin))
        scheduleLongChatTurns(sessionID: sessionID)
        return AgentSessionMessageResponse(
            summary: try getAgentSession(agentID: agentID, sessionID: sessionID).summary,
            appendedEvents: event.map { [$0] } ?? [], routeDecision: nil)
    }

    func persistLongChatTurnIfNeeded(_ turn: LongChatFileStore.Turn) throws -> AgentSessionEvent? {
        let detail = try getAgentSession(agentID: turn.agentId, sessionID: turn.sessionId)
        if detail.events.contains(where: { $0.message?.id == turn.id }) { return nil }
        let attachments = try sessionStore.persistAttachments(
            agentID: turn.agentId, sessionID: turn.sessionId, uploads: turn.request.attachments)
        let displayContent =
            turn.isNotification
            ? "Worker update received. The coordinator will summarize the result." : turn.request.content
        var segments: [AgentMessageSegment] = [.init(kind: .text, text: displayContent)]
        segments += attachments.map { .init(kind: .attachment, attachment: $0) }
        let event = AgentSessionEvent(
            agentId: turn.agentId, sessionId: turn.sessionId, type: .message,
            message: .init(
                id: turn.id, role: turn.isNotification ? .system : .user, segments: segments,
                userId: turn.request.userId, peerOrigin: turn.peerOrigin,
                sessionReferences: SessionReferenceContext.references(for: turn.request)))
        let summary = try sessionStore.appendEvents(agentID: turn.agentId, sessionID: turn.sessionId, events: [event])
        publishLiveSessionEvents(agentID: turn.agentId, sessionID: turn.sessionId, summary: summary, events: [event])
        return event
    }

    func scheduleLongChatTurns(sessionID: String) {
        guard !longChatIsStopping, longChatTurnRunners.insert(sessionID).inserted else { return }
        longChatTurnTasks[sessionID] = Task { [weak self] in await self?.drainLongChatTurns(sessionID: sessionID) }
    }

    private func drainLongChatTurns(sessionID: String) async {
        defer {
            longChatTurnRunners.remove(sessionID)
            longChatTurnTasks.removeValue(forKey: sessionID)
            longChatCurrentTurns.removeValue(forKey: sessionID)
            activePeerSessionOrigins.removeValue(forKey: sessionID)
        }
        do {
            let storage = try longChats()
            while !longChatIsStopping, !Task.isCancelled,
                let turn = nextLongChatTurn(storage: storage, sessionID: sessionID)
            {
                let currentDetail = try getAgentSession(agentID: turn.agentId, sessionID: sessionID)
                if sessionHasPendingInput(currentDetail) { break }
                let pendingApprovals = await toolApprovalService.listPending(includeUnpublished: true)
                if pendingApprovals.contains(where: { $0.sessionId == sessionID }) { break }
                _ = try persistLongChatTurnIfNeeded(turn)
                let responseID = "long-chat-response-\(turn.id)"
                let detail = try getAgentSession(agentID: turn.agentId, sessionID: sessionID)
                if !detail.events.contains(where: { $0.message?.id == responseID }) {
                    try storage.transaction { state in
                        if let i = state.turns.firstIndex(where: { $0.id == turn.id }) {
                            state.turns[i].processing = true
                        }
                    }
                    longChatCurrentTurns[sessionID] = turn.id
                    activePeerSessionOrigins[sessionID] = turn.peerOrigin
                    let conversation = try storage.conversation(sessionId: sessionID)
                    let snapshot = longChatContext(conversation)
                    do {
                        await runtime.setChannelToolAllowList(
                            channelId: sessionChannelID(agentID: turn.agentId, sessionID: sessionID),
                            toolIDs: LongChatCoordinatorPolicy.readTools.union(
                                LongChatCoordinatorPolicy.managementTools.union(SessionCommunicationPolicy.tools)
                            ).union(["memory.save", "agent.documents.set_memory_markdown"]).union(
                                await readOnlyLongChatMCPTools()))
                        _ = try await sessionOrchestrator.postMessage(
                            agentID: turn.agentId, sessionID: sessionID, request: turn.request,
                            userMessageAlreadyPersisted: true,
                            additionalContext: SessionCommunicationPolicy.instructions + "\n" + LongChatCoordinatorPolicy.instructions
                                + "\n[Current assignments — authoritative persisted state]\n" + snapshot,
                            responseMessageID: responseID, peerOrigin: turn.peerOrigin)
                    } catch {
                        if longChatIsStopping { return }
                        let event = AgentSessionEvent(
                            agentId: turn.agentId, sessionId: sessionID, type: .message,
                            message: .init(
                                id: responseID, role: .assistant,
                                segments: [
                                    .init(
                                        kind: .text,
                                        text:
                                            "The coordinator turn was interrupted or failed. Accepted tasks remain available. \(error.localizedDescription)"
                                    )
                                ]))
                        _ = try await appendAgentSessionEvents(
                            agentID: turn.agentId, sessionID: sessionID, request: .init(events: [event]))
                    }
                }
                try storage.transaction { state in
                    if let i = state.turns.firstIndex(where: { $0.id == turn.id }) { state.turns[i].delivered = true }
                }
                longChatCurrentTurns.removeValue(forKey: sessionID)
                activePeerSessionOrigins.removeValue(forKey: sessionID)
            }
        } catch {
            logger.error("long_chat.inbox_failed", metadata: ["error": .string(String(describing: error))])
        }
    }

    private func nextLongChatTurn(storage: LongChatFileStore, sessionID: String) -> LongChatFileStore.Turn? {
        let pending = storage.state.turns.filter { $0.sessionId == sessionID && !$0.delivered }
        return pending.first { !$0.isNotification } ?? pending.first
    }

    func longChatContext(_ conversation: LongChatConversation) -> String {
        let relevant =
            conversation.assignments.filter { !$0.isTerminal }
            + conversation.assignments.filter(\.isTerminal).suffix(10)
        let assignments = relevant.map { assignment -> JSONValue in
            .object([
                "id": .string(assignment.id), "sourceMessageId": .string(assignment.sourceMessageId),
                "requestKey": .string(assignment.requestKey), "title": .string(assignment.title),
                "acceptanceCriteria": .string(String(assignment.acceptanceCriteria.prefix(1000))),
                "terminal": .bool(assignment.isTerminal),
                "tasks": .array(
                    assignment.tasks.map { task in
                        .object([
                            "id": .string(task.id), "key": .string(task.key), "title": .string(task.title),
                            "dependsOn": .array(task.dependsOn.map(JSONValue.string)),
                            "status": .string(task.status.rawValue),
                            "attempt": .number(Double(task.attempts.last?.number ?? 0)),
                            "summary": .string(String((task.attempts.last?.summary ?? "").prefix(1000))),
                            "automaticRetryAllowed": .bool(task.attempts.last?.automaticRetryAllowed != false),
                        ])
                    }),
            ])
        }
        let snapshot = JSONValue.object([
            "assignmentCount": .number(Double(conversation.assignments.count)), "assignments": .array(assignments),
        ])
        return (try? JSONEncoder().encode(snapshot)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func invokeLongChatTool(agentID: String, sessionID: String, request: ToolInvocationRequest) async
        -> ToolInvocationResult
    {
        do {
            if ["long_chat.delegate", "long_chat.retry", "long_chat.message"].contains(request.tool),
                let source = longChatCurrentTurns[sessionID],
                try longChats().state.cancelledSourceMessageIds?.contains(source) == true
            {
                throw LongChatFileStore.StoreError.conflict
            }
            let result: JSONValue
            switch request.tool {
            case "long_chat.delegate":
                guard let raw = request.arguments["assignment"]?.asString, let data = raw.data(using: .utf8),
                    let sourceID = longChatCurrentTurns[sessionID]
                else { throw AgentSessionError.invalidPayload }
                let payload = try JSONDecoder().decode(LongChatDelegationRequest.self, from: data)
                let assignment = try await delegateLongChat(
                    agentID: agentID, sessionID: sessionID, sourceID: sourceID, request: payload)
                result = try longChatJSON(assignment)
            case "long_chat.status":
                if let taskID = request.arguments["taskId"]?.asString {
                    result = try longChatJSON(currentLongChatTask(sessionID: sessionID, taskID: taskID))
                } else {
                    result = .string(longChatContext(try getLongChat(agentID: agentID, sessionID: sessionID)))
                }
            case "long_chat.cancel":
                let taskID = request.arguments["taskId"]?.asString
                try await cancelLongChatTasks(agentID: agentID, sessionID: sessionID, taskID: taskID)
                result = .object(["cancelled": .bool(true)])
            case "long_chat.retry":
                guard let taskID = request.arguments["taskId"]?.asString else { throw AgentSessionError.invalidPayload }
                try await retryLongChatTask(agentID: agentID, sessionID: sessionID, taskID: taskID, automatic: true)
                result = .object(["queued": .bool(true)])
            case "long_chat.message":
                guard let taskID = request.arguments["taskId"]?.asString,
                    let content = request.arguments["content"]?.asString
                else { throw AgentSessionError.invalidPayload }
                let conversation = try getLongChat(agentID: agentID, sessionID: sessionID)
                try await messageLongChatTask(
                    agentID: agentID, sessionID: sessionID, taskID: taskID,
                    request: .init(userId: conversation.userId, content: content))
                result = .object(["accepted": .bool(true)])
            default: throw AgentSessionError.invalidPayload
            }
            return .init(tool: request.tool, ok: true, data: result)
        } catch {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "long_chat_invalid_operation", message: String(describing: error), retryable: false))
        }
    }

    private func longChatJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func delegateLongChat(agentID: String, sessionID: String, sourceID: String, request: LongChatDelegationRequest)
        async throws -> LongChatAssignment
    {
        let conversation = try getLongChat(agentID: agentID, sessionID: sessionID)
        var request = request
        for i in request.tasks.indices {
            request.tasks[i].projectId = request.tasks[i].projectId ?? conversation.projectId
            if let projectID = request.tasks[i].projectId {
                let project = try await getProject(id: projectID)
                if let repoPath = project.repoPath {
                    let canonical = URL(fileURLWithPath: repoPath).standardizedFileURL.resolvingSymlinksInPath().path
                    request.tasks[i].resourceKeys.append("workspace:" + canonical)
                }
                let key = "project:\(projectID)"
                if !request.tasks[i].resourceKeys.contains(key) { request.tasks[i].resourceKeys.append(key) }
            }
            request.tasks[i].resourceKeys = Array(
                Set(
                    request.tasks[i].resourceKeys.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    })
            ).sorted()
            request.tasks[i].readOnly = request.tasks[i].readOnly ?? request.tasks[i].resourceKeys.isEmpty
            guard !request.tasks[i].resourceKeys.contains(""),
                request.tasks[i].readOnly != false || !request.tasks[i].resourceKeys.isEmpty
            else { throw AgentSessionError.invalidPayload }
        }
        let assignment = try longChats().delegate(sessionId: sessionID, sourceMessageId: sourceID, request: request)
        for task in assignment.tasks {
            try await publishLongChatTask(sessionID: sessionID, taskID: task.id, reason: "accepted")
        }
        Task { [weak self] in await self?.dispatchLongChatWorkers() }
        return assignment
    }

    public func cancelLongChatTasks(agentID: String, sessionID: String, taskID: String? = nil) async throws {
        let conversation = try getLongChat(agentID: agentID, sessionID: sessionID)
        if let taskID { _ = try currentLongChatTask(sessionID: sessionID, taskID: taskID) }
        if taskID == nil {
            try longChats().transaction { state in
                let pending = state.turns.filter { $0.sessionId == sessionID && !$0.delivered }.map(\.id)
                state.cancelledSourceMessageIds = Array(Set((state.cancelledSourceMessageIds ?? []) + pending))
            }
        }
        let tasks = conversation.assignments.flatMap(\.tasks).filter {
            !$0.status.isTerminal && (taskID == nil || $0.id == taskID)
        }
        for task in tasks {
            try longChats().updateTask(sessionId: sessionID, taskId: task.id) {
                $0.attempts[$0.attempts.count - 1].status = .cancelled
                $0.attempts[$0.attempts.count - 1].executionStopped = false
                $0.attempts[$0.attempts.count - 1].summary = "Cancelled by user/coordinator."
                $0.attempts[$0.attempts.count - 1].updatedAt = Date()
            }
            if let child = task.attempts.last?.sessionId {
                longChatWorkerRuns[child]?.cancel()
                _ = try? await controlAgentSession(
                    agentID: agentID, sessionID: child,
                    request: .init(action: .interrupt, requestedBy: conversation.userId, interruptPendingInput: true))
                await toolExecution.cleanupSessionProcesses(child)
            }
            if let worker = task.attempts.last?.workerId {
                _ = await runtime.cancelWorker(workerId: worker, reason: "Long chat task cancelled")
            }
            try longChats().updateTask(sessionId: sessionID, taskId: task.id) {
                $0.attempts[$0.attempts.count - 1].executionStopped = true
            }
            try await refreshLongChatDependencies(sessionID: sessionID)
            try await publishLongChatTask(sessionID: sessionID, taskID: task.id, reason: "cancelled", notify: true)
        }
        await dispatchLongChatWorkers()
    }

    public func retryLongChatTask(agentID: String, sessionID: String, taskID: String, automatic: Bool = false)
        async throws
    {
        _ = try getLongChat(agentID: agentID, sessionID: sessionID)
        try longChats().updateTask(sessionId: sessionID, taskId: taskID) {
            guard $0.status == .failed || (!automatic && $0.status == .cancelled),
                $0.attempts.last?.executionStopped != false
            else {
                throw LongChatFileStore.StoreError.conflict
            }
            guard !automatic || ($0.attempts.count < 3 && $0.attempts.last?.automaticRetryAllowed != false) else {
                throw LongChatFileStore.StoreError.retryLimit
            }
            $0.attempts.append(.init(number: $0.attempts.count + 1))
        }
        try await refreshLongChatDependencies(sessionID: sessionID)
        try await publishLongChatTask(sessionID: sessionID, taskID: taskID, reason: "retry_queued")
        await dispatchLongChatWorkers()
    }

    public func messageLongChatTask(
        agentID: String, sessionID: String, taskID: String, request: LongChatTaskMessageRequest
    ) async throws {
        let conversation = try getLongChat(agentID: agentID, sessionID: sessionID)
        let task = try currentLongChatTask(sessionID: sessionID, taskID: taskID)
        guard request.userId == conversation.userId,
            !request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !task.status.isTerminal
        else { throw AgentSessionError.invalidPayload }
        if task.status == .queued {
            try longChats().updateTask(sessionId: sessionID, taskId: taskID) {
                $0.objective += "\n[Clarification]\n" + request.content
            }
        } else {
            try longChats().updateTask(sessionId: sessionID, taskId: taskID) {
                $0.objective += "\n[Clarification]\n" + request.content
            }
            _ = try enqueueLongChatWorkerMessage(
                conversation: conversation, task: task,
                request: .init(
                    userId: request.userId, content: request.content, clientMessageId: request.clientMessageId))
        }
        try await publishLongChatTask(
            sessionID: sessionID, taskID: taskID, reason: "clarified-" + UUID().uuidString, notify: true)
    }

    func refreshLongChatDependencies(sessionID: String) async throws {
        for (taskID, status) in try longChats().resolveDependencies(sessionId: sessionID) {
            try await publishLongChatTask(sessionID: sessionID, taskID: taskID, reason: "dependency_" + status.rawValue)
        }
    }

    func recoverLongChatsIfNeeded() async {
        guard !longChatRecoveryCompleted else { return }
        longChatRecoveryCompleted = true
        do {
            let storage = try longChats()
            // A crash may have persisted migration ownership before the journal metadata write.
            for conversation in storage.state.conversations {
                if try sessionStore.loadSession(agentID: conversation.agentId, sessionID: conversation.sessionId).summary.kind == .chat {
                    try sessionStore.promoteToLongChat(agentID: conversation.agentId, sessionID: conversation.sessionId)
                }
            }
            try storage.transaction { state in
                for index in state.turns.indices where state.turns[index].processing && !state.turns[index].delivered && state.turns[index].peerOrigin != nil {
                    state.turns[index].delivered = true
                    state.turns[index].deliveryError = "Core restarted during peer delivery; inspect the session before sending again."
                }
            }
            for turn in storage.state.turns where turn.deliveryError != nil {
                let detail = try getAgentSession(agentID: turn.agentId, sessionID: turn.sessionId)
                let id = "delivery-interrupted-" + turn.id
                guard !detail.events.contains(where: { $0.id == id }) else { continue }
                let event = AgentSessionEvent(id: id, agentId: turn.agentId, sessionId: turn.sessionId, type: .runStatus,
                    runStatus: .init(stage: .interrupted, label: "Message interrupted", details: turn.deliveryError))
                let summary = try sessionStore.appendEvents(agentID: turn.agentId, sessionID: turn.sessionId, events: [event])
                publishLiveSessionEvents(agentID: turn.agentId, sessionID: turn.sessionId, summary: summary, events: [event])
            }
            var interrupted: [(String, String)] = []
            try storage.transaction { state in
                for c in state.conversations.indices {
                    for a in state.conversations[c].assignments.indices {
                        for t in state.conversations[c].assignments[a].tasks.indices {
                            var task = state.conversations[c].assignments[a].tasks[t]
                            if task.status == .running {
                                task.attempts[task.attempts.count - 1].status = .failed
                                task.attempts[task.attempts.count - 1].automaticRetryAllowed = false
                                task.attempts[task.attempts.count - 1].summary =
                                    "Core restarted; execution interrupted. Inspect evidence before retrying external changes."
                                state.conversations[c].assignments[a].tasks[t] = task
                                interrupted.append((state.conversations[c].sessionId, task.id))
                            }
                        }
                    }
                }
            }
            for (sessionID, taskID) in interrupted {
                try await refreshLongChatDependencies(sessionID: sessionID)
                try await publishLongChatTask(sessionID: sessionID, taskID: taskID, reason: "interrupted", notify: true)
            }
            for conversation in storage.state.conversations {
                scheduleLongChatTurns(sessionID: conversation.sessionId)
                for task in conversation.assignments.flatMap(\.tasks) where task.status == .waitingInput {
                    if let childID = task.attempts.last?.sessionId { scheduleLongChatWorkerTurns(childID: childID) }
                }
            }
            await dispatchLongChatWorkers()
        } catch { logger.error("long_chat.recovery_failed", metadata: ["error": .string(String(describing: error))]) }
    }
}
