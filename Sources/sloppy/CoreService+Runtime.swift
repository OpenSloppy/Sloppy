import Foundation
import AgentRuntime
import Protocols
import Logging
import Tracing

// MARK: - Runtime

extension CoreService {
    func waitForStartup(dispatchReadyTasks: Bool = true) async {
        await sessionOrchestrator.setPendingMessageIDsProvider { [weak self] agentID, sessionID in
            await self?.pendingSessionMessageIDs(agentID: agentID, sessionID: sessionID) ?? []
        }
        await recoveryManager.recoverIfNeeded()
        await startEventPersistence()
        await recoverLongChatsIfNeeded()
        await recoverSessionMessagesIfNeeded()
        await restorePlanInputAutoApprovalsIfNeeded()
        await memoryOutboxIndexer?.start()
        await startNodeMeshClientIfConfigured()
        if dispatchReadyTasks {
            await dispatchStartupReadyTasksIfNeeded()
        }
    }

    func dispatchStartupReadyTasksIfNeeded() async {
        guard !readyTaskStartupDispatchCompleted,
              !readyTaskStartupDispatchInProgress
        else {
            return
        }
        readyTaskStartupDispatchCompleted = true
        readyTaskStartupDispatchInProgress = true
        defer {
            readyTaskStartupDispatchInProgress = false
        }

        let readyTasks = await store.listProjects().flatMap { project in
            project.tasks
                .filter { project.automaticTaskPickupEnabled && $0.status == ProjectTaskStatus.ready.rawValue }
                .map { (project.id, $0.id) }
        }

        guard !readyTasks.isEmpty else {
            return
        }

        logger.info(
            "tasks.ready.startup_dispatch",
            metadata: ["count": .stringConvertible(readyTasks.count)]
        )
        for (projectID, taskID) in readyTasks {
            await handleTaskBecameReady(projectID: projectID, taskID: taskID)
        }
    }

    /// Subscribes to runtime event stream and persists events in background.
    func startEventPersistence() async {
        guard eventTask == nil else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let runtime = self.runtime
            eventTask = Task { [weak self, runtime] in
                let stream = await runtime.eventBus.subscribe()
                continuation.resume()
                for await event in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard let self else {
                        break
                    }
                    _ = await withSpan("runtime.event.persist", ofKind: .consumer) { span in
                        span.attributes["channel_id"] = "\(event.channelId)"
                        span.attributes["message_type"] = "\(event.messageType.rawValue)"
                        let enrichedEvent = await eventByInjectingSwarmMetadata(event)
                        await store.persist(event: enrichedEvent)
                        await recordProjectAnalyticsFactIfNeeded(enrichedEvent)
                        await handleKanbanRuntimeEvent(enrichedEvent)
                        await handleVisorEvent(enrichedEvent)
                        await handleMemoryCheckpointRuntimeEvent(enrichedEvent)
                        await extractAndPersistTokenUsage(from: enrichedEvent)
                        await emitNotificationIfNeeded(from: enrichedEvent)
                    }
                }
            }
        }
    }

    func recordProjectAnalyticsFactIfNeeded(_ event: EventEnvelope) async {
        let tracked: Set<MessageType> = [
            .channelRouteDecided,
            .visorWorkerTimeout,
            .visorBranchTimeout,
            .compactorThresholdHit,
            .compactorSummaryApplied,
            .visorBulletinGenerated,
        ]
        guard tracked.contains(event.messageType) else { return }

        let projectId = await resolveProjectId(forChannelId: event.channelId)
        guard let projectId else { return }

        await store.persistProjectEventFact(
            id: UUID().uuidString,
            projectId: projectId,
            channelId: event.channelId,
            messageType: event.messageType.rawValue,
            traceId: event.traceId,
            createdAt: event.ts
        )
    }

    func resolveProjectId(forChannelId channelId: String) async -> String? {
        let normalized = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let projects = await store.listProjects()
        for project in projects {
            if project.channels.contains(where: { $0.channelId == normalized }) {
                return project.id
            }
        }
        return nil
    }

    func eventByInjectingSwarmMetadata(_ event: EventEnvelope) async -> EventEnvelope {
        guard let taskID = event.taskId else {
            return event
        }

        let projects = await store.listProjects()
        var resolvedTask: ProjectTask?
        for project in projects {
            if let task = project.tasks.first(where: { $0.id == taskID }) {
                resolvedTask = task
                break
            }
        }
        guard let task = resolvedTask, let swarmId = task.swarmId else {
            return event
        }

        var envelope = event
        var swarmPayload: [String: JSONValue] = [
            "swarmId": .string(swarmId)
        ]
        if let swarmTaskId = task.swarmTaskId {
            swarmPayload["swarmTaskId"] = .string(swarmTaskId)
        }
        if let swarmParentTaskId = task.swarmParentTaskId {
            swarmPayload["swarmParentTaskId"] = .string(swarmParentTaskId)
        }
        if let dependencyIds = task.swarmDependencyIds, !dependencyIds.isEmpty {
            swarmPayload["swarmDependencyIds"] = .array(dependencyIds.map { .string($0) })
        }
        if let actorPath = task.swarmActorPath, !actorPath.isEmpty {
            swarmPayload["swarmActorPath"] = .array(actorPath.map { .string($0) })
        }

        envelope.extensions["swarm"] = .object(swarmPayload)
        return envelope
    }

    /// Extracts token usage from branch.conclusion and worker.completed events.
    func extractAndPersistTokenUsage(from event: EventEnvelope) async {
        guard !(await runtime.isRequestUsageObserved(channelId: event.channelId)) else { return }
        let tokenUsage: TokenUsage?

        switch event.messageType {
        case .branchConclusion:
            tokenUsage = extractTokenUsageFromBranchConclusion(event)
        case .workerCompleted:
            tokenUsage = extractTokenUsageFromWorkerCompleted(event)
        default:
            tokenUsage = nil
        }

        if let usage = tokenUsage {
            await store.persistTokenUsage(
                channelId: event.channelId,
                taskId: event.taskId,
                usage: usage
            )
        }
    }

    func extractTokenUsageFromBranchConclusion(_ event: EventEnvelope) -> TokenUsage? {
        guard case .object(let obj) = event.payload else { return nil }

        // Preferred payload shape: branch conclusion itself is in event.payload.
        if let usage = tokenUsage(fromObjectField: obj["tokenUsage"]) {
            return usage
        }

        // Backward-compatible fallback for nested payloads: { "conclusion": { "tokenUsage": ... } }.
        if case .object(let conclusionObj)? = obj["conclusion"] {
            return tokenUsage(fromObjectField: conclusionObj["tokenUsage"])
        }

        return nil
    }

    func extractTokenUsageFromWorkerCompleted(_ event: EventEnvelope) -> TokenUsage? {
        guard case .object(let obj) = event.payload else { return nil }
        guard case .object(let resultObj)? = obj["result"] else { return nil }
        return tokenUsage(fromObjectField: resultObj["tokenUsage"])
    }

    func tokenUsage(fromObjectField field: JSONValue?) -> TokenUsage? {
        guard case .object(let tokenUsageObj)? = field else {
            return nil
        }

        let prompt = numericTokenUsageValue(tokenUsageObj["prompt"])
        let completion = numericTokenUsageValue(tokenUsageObj["completion"])

        guard let p = prompt, let c = completion else {
            return nil
        }

        return TokenUsage(
            prompt: Int(p),
            completion: Int(c),
            cachedInputTokens: Int(numericTokenUsageValue(tokenUsageObj["cachedInput"]) ?? 0),
            cacheCreationInputTokens: Int(numericTokenUsageValue(tokenUsageObj["cacheCreationInput"]) ?? 0),
            reasoningTokens: Int(numericTokenUsageValue(tokenUsageObj["reasoning"]) ?? 0)
        )
    }

    func numericTokenUsageValue(_ field: JSONValue?) -> Double? {
        if case .number(let val) = field {
            return val
        }
        if case .string(let str) = field {
            return Double(str)
        }
        return nil
    }
}
