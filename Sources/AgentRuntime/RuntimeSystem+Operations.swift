import AnyLanguageModel
import Foundation
import Logging
import PluginSDK
import Protocols

public extension RuntimeSystem {
    /// Images for the next turn; the model transcript owns their subsequent conversational lifetime.
    func setChannelImages(channelId: String, images: [Transcript.ImageSegment]) {
        imagesByChannel[channelId] = images
    }

    func setChannelBootstrap(channelId: String, content: String) async {
        if bootstrapByChannel[channelId] != content {
            sessionsByChannel.removeValue(forKey: channelId)
        }
        bootstrapByChannel[channelId] = content
    }

    /// Clears cached LLM session and bootstrap for an ephemeral channel (memory checkpoints).
    func discardEphemeralCheckpointChannel(channelId: String) async {
        sessionsByChannel.removeValue(forKey: channelId)
        bootstrapByChannel.removeValue(forKey: channelId)
        imagesByChannel.removeValue(forKey: channelId)
        memoryProjectByChannel.removeValue(forKey: channelId)
        channelToolAllowList.removeValue(forKey: channelId)
        contextLedgerByChannel.removeValue(forKey: channelId)
        recoveryTranscriptByChannel.removeValue(forKey: channelId)
        contextArchiversByChannel.removeValue(forKey: channelId)
        contextPreparationByChannel.removeValue(forKey: channelId)
        await channels.removeChannel(channelId: channelId)
    }

    func contextLedgerSnapshot(channelId: String) async -> ContextLedgerSnapshot? {
        contextLedgerByChannel[channelId]
    }

    /// Routes interactive payload to worker bound to the channel.
    func routeMessage(channelId: String, workerId: String, message: String) async -> Bool {
        let result = await workers.route(workerId: workerId, message: message)
        guard result.accepted else {
            return false
        }

        if result.completed {
            await channels.detachWorker(channelId: channelId, workerId: workerId)
            if let artifact = result.artifactRef {
                await channels.appendSystemMessage(
                    channelId: channelId,
                    content: "Worker \(workerId) completed with artifact \(artifact.id)"
                )
            }
        }

        return true
    }

    /// Performs one-shot completion with currently configured model provider.
    /// Returns nil when no provider/model is configured or completion fails.
    func complete(prompt: some PromptRepresentable, maxTokens: Int = 1024) async -> String? {
        guard let modelProvider, let defaultModel else {
            return nil
        }
        guard let languageModel = try? await modelProvider.createLanguageModel(for: defaultModel) else {
            return nil
        }
        let session: LanguageModelSession
        let tools = ModelToolNameSanitizer.sanitizeTools(modelProvider.tools).tools
        if let instructions = modelProvider.systemInstructions {
            session = LanguageModelSession(model: languageModel, tools: tools, instructions: instructions)
        } else {
            session = LanguageModelSession(model: languageModel, tools: tools)
        }
        let options = modelProvider.generationOptions(for: defaultModel, maxTokens: maxTokens, reasoningEffort: nil)
        return try? await session.respond(to: prompt.promptRepresentation, options: options).content
    }

    /// Creates worker and attaches it to channel tracking.
    func createWorker(spec: WorkerTaskSpec, autoStart: Bool = true) async -> String {
        let workerId = await workers.spawn(spec: spec, autoStart: autoStart)
        await channels.attachWorker(channelId: spec.channelId, workerId: workerId)
        return workerId
    }

    /// Lifecycle bridge for persistently scheduled, session-backed workers.
    func reportManagedWorker(workerId: String, waitingInput: Bool = false, report: String? = nil) async {
        await workers.reportManagedProgress(workerId: workerId, waitingInput: waitingInput, report: report)
    }

    func completeManagedWorker(workerId: String, summary: String) async {
        _ = await workers.completeNow(workerId: workerId, summary: summary)
    }

    func failManagedWorker(workerId: String, error: String) async {
        await workers.fail(workerId: workerId, error: error)
    }

    /// Rebuilds in-memory runtime state from persisted channels/tasks/events/artifacts.
    func recover(
        channels channelStates: [RecoveryChannelState],
        tasks taskStates: [RecoveryTaskState],
        events: [EventEnvelope],
        artifacts: [RecoveryArtifactState]
    ) async {
        await channels.resetForRecovery()
        await workers.resetForRecovery()

        for channel in channelStates.sorted(by: { $0.createdAt < $1.createdAt }) {
            await channels.ensureChannel(channelId: channel.id)
        }

        for artifact in artifacts.sorted(by: { $0.createdAt < $1.createdAt }) {
            await workers.restoreArtifact(id: artifact.id, content: artifact.content)
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: taskStates.map { ($0.id, $0) })
        let orderedEvents = events.sorted { left, right in
            if left.ts == right.ts {
                return left.messageId < right.messageId
            }
            return left.ts < right.ts
        }

        for event in orderedEvents {
            await replayRecoveredEvent(event, tasksByID: tasksByID)
        }

        let eventCountsByChannel = Dictionary(grouping: orderedEvents, by: { $0.channelId })
        for (channelID, eventsForChannel) in eventCountsByChannel where !eventsForChannel.isEmpty {
            if let snapshot = await channels.snapshot(channelId: channelID), snapshot.messages.isEmpty {
                await channels.appendSystemMessage(
                    channelId: channelID,
                    content: "Recovered \(eventsForChannel.count) persisted events."
                )
            }
        }

        for task in taskStates {
            let hasTask = await workers.hasTask(taskId: task.id)
            if hasTask {
                continue
            }
            let spec = WorkerTaskSpec(
                taskId: task.id,
                channelId: task.channelId,
                title: task.title,
                objective: task.objective,
                tools: [],
                mode: .interactive
            )
            let workerID = "recovered-\(task.id)"
            await workers.restoreWorker(
                workerId: workerID,
                spec: spec,
                status: workerStatus(from: task.status),
                latestReport: nil,
                artifactId: nil
            )
            if workerStatus(from: task.status) == .queued ||
                workerStatus(from: task.status) == .running ||
                workerStatus(from: task.status) == .waitingInput
            {
                await channels.attachWorker(channelId: task.channelId, workerId: workerID)
            }
        }
    }

    internal func replayRecoveredEvent(
        _ event: EventEnvelope,
        tasksByID: [String: RecoveryTaskState]
    ) async {
        await channels.ensureChannel(channelId: event.channelId)

        switch event.messageType {
        case .channelMessageReceived:
            guard let userId = event.payload.runtimeObjectValue["userId"]?.runtimeStringValue,
                  let message = event.payload.runtimeObjectValue["message"]?.runtimeStringValue
            else {
                return
            }
            await channels.restoreMessage(
                channelId: event.channelId,
                message: ChannelMessageEntry(
                    id: event.messageId,
                    userId: userId,
                    content: message,
                    createdAt: event.ts
                )
            )

        case .channelRouteDecided:
            guard let decision = try? JSONValueCoder.decode(ChannelRouteDecision.self, from: event.payload) else {
                return
            }
            await channels.restoreDecision(channelId: event.channelId, decision: decision)

        case .branchConclusion:
            guard let conclusion = try? JSONValueCoder.decode(BranchConclusion.self, from: event.payload) else {
                return
            }
            await channels.applyBranchConclusion(channelId: event.channelId, conclusion: conclusion)

        case .workerSpawned:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let spec = recoveredWorkerSpec(
                event: event,
                workerId: workerID,
                taskId: taskID,
                tasksByID: tasksByID
            )
            await workers.restoreWorker(
                workerId: workerID,
                spec: spec,
                status: .queued,
                latestReport: nil,
                artifactId: nil,
                createdAt: event.ts,
                updatedAt: event.ts
            )
            await channels.attachWorker(channelId: event.channelId, workerId: workerID)

        case .workerProgress:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let progress = event.payload.runtimeObjectValue["progress"]?.runtimeStringValue
            let status: WorkerStatus = (progress == "waiting_for_route") ? .waitingInput : .running
            let updated = await workers.updateRecoveredWorker(
                workerId: workerID,
                status: status,
                latestReport: progress,
                artifactId: nil,
                observedAt: event.ts
            )
            if !updated {
                let spec = recoveredWorkerSpec(
                    event: event,
                    workerId: workerID,
                    taskId: taskID,
                    tasksByID: tasksByID
                )
                await workers.restoreWorker(
                    workerId: workerID,
                    spec: spec,
                    status: status,
                    latestReport: progress,
                    artifactId: nil,
                    startedAt: status == .running ? event.ts : nil,
                    createdAt: event.ts,
                    updatedAt: event.ts
                )
            }
            await channels.attachWorker(channelId: event.channelId, workerId: workerID)

        case .workerCompleted:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let summary = event.payload.runtimeObjectValue["summary"]?.runtimeStringValue
            let artifactID = event.payload.runtimeObjectValue["artifactId"]?.runtimeStringValue
            let updated = await workers.updateRecoveredWorker(
                workerId: workerID,
                status: .completed,
                latestReport: summary,
                artifactId: artifactID,
                observedAt: event.ts
            )
            if !updated {
                let spec = recoveredWorkerSpec(
                    event: event,
                    workerId: workerID,
                    taskId: taskID,
                    tasksByID: tasksByID
                )
                await workers.restoreWorker(
                    workerId: workerID,
                    spec: spec,
                    status: .completed,
                    latestReport: summary,
                    artifactId: artifactID,
                    createdAt: event.ts,
                    updatedAt: event.ts
                )
            }
            await channels.detachWorker(channelId: event.channelId, workerId: workerID)

        case .workerFailed:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let error = event.payload.runtimeObjectValue["error"]?.runtimeStringValue
            let updated = await workers.updateRecoveredWorker(
                workerId: workerID,
                status: .failed,
                latestReport: error,
                artifactId: nil,
                observedAt: event.ts
            )
            if !updated {
                let spec = recoveredWorkerSpec(
                    event: event,
                    workerId: workerID,
                    taskId: taskID,
                    tasksByID: tasksByID
                )
                await workers.restoreWorker(
                    workerId: workerID,
                    spec: spec,
                    status: .failed,
                    latestReport: error,
                    artifactId: nil,
                    createdAt: event.ts,
                    updatedAt: event.ts
                )
            }
            await channels.detachWorker(channelId: event.channelId, workerId: workerID)

        default:
            break
        }
    }

    internal func recoveredWorkerSpec(
        event: EventEnvelope,
        workerId: String,
        taskId: String,
        tasksByID: [String: RecoveryTaskState]
    ) -> WorkerTaskSpec {
        let taskState = tasksByID[taskId]
        let modeText = event.payload.runtimeObjectValue["mode"]?.runtimeStringValue
        let mode = modeText.flatMap(WorkerMode.init(rawValue:)) ?? .interactive
        let title = event.payload.runtimeObjectValue["title"]?.runtimeStringValue ?? taskState?.title ?? "Recovered worker \(workerId)"
        let objective = taskState?.objective ?? event.payload.runtimeObjectValue["objective"]?.runtimeStringValue ?? ""

        return WorkerTaskSpec(
            taskId: taskId,
            channelId: event.channelId,
            title: title,
            objective: objective,
            tools: [],
            mode: mode
        )
    }

    internal func workerStatus(from raw: String) -> WorkerStatus {
        switch raw.lowercased() {
        case "queued", "ready", "pending_approval", "backlog":
            .queued
        case "running", "in_progress":
            .running
        case "waiting_input", "waitinginput":
            .waitingInput
        case "completed", "done":
            .completed
        case "failed":
            .failed
        default:
            .queued
        }
    }

    /// Returns channel snapshot by identifier.
    func channelState(channelId: String) async -> ChannelSnapshot? {
        await channels.snapshot(channelId: channelId)
    }

    /// Appends one synthetic system message into channel context.
    func appendSystemMessage(channelId: String, content: String) async {
        await channels.appendSystemMessage(channelId: channelId, content: content)
    }

    /// Returns artifact content by identifier.
    func artifactContent(id: String) async -> String? {
        await workers.artifactContent(id: id)
    }

    /// Generates visor bulletin for runtime health monitoring.
    func generateVisorBulletin(taskSummary: String? = nil) async -> MemoryBulletin {
        let channelSnapshots = await channels.snapshots()
        let workerSnapshots = await workers.snapshots()
        return await visor.generateBulletin(
            channels: channelSnapshots,
            workers: workerSnapshots,
            taskSummary: taskSummary
        )
    }

    /// Returns collected bulletins.
    func bulletins() async -> [MemoryBulletin] {
        await visor.listBulletins()
    }

    /// Returns current worker snapshots.
    func workerSnapshots() async -> [WorkerSnapshot] {
        await workers.snapshots()
    }

    /// Returns active branch snapshots.
    func activeBranchSnapshots() async -> [BranchSnapshot] {
        await branches.activeBranches()
    }

    /// Starts the Visor supervision tick loop with config-driven parameters.
    func startVisorSupervision(
        tickIntervalSeconds: Int,
        workerTimeoutSeconds: Int,
        branchTimeoutSeconds: Int,
        maintenanceIntervalSeconds: Int,
        decayRatePerDay: Double,
        pruneImportanceThreshold: Double,
        pruneMinAgeDays: Int,
        channelDegradedFailureCount: Int = 3,
        channelDegradedWindowSeconds: Int = 600,
        idleThresholdSeconds: Int = 1800,
        mergeEnabled: Bool = false,
        mergeSimilarityThreshold: Double = 0.80,
        mergeMaxPerRun: Int = 10
    ) async {
        await visor.startSupervision(
            tickInterval: .seconds(max(1, tickIntervalSeconds)),
            workerTimeoutSeconds: workerTimeoutSeconds,
            branchTimeoutSeconds: branchTimeoutSeconds,
            maintenanceIntervalSeconds: maintenanceIntervalSeconds,
            decayRatePerDay: decayRatePerDay,
            pruneImportanceThreshold: pruneImportanceThreshold,
            pruneMinAgeDays: pruneMinAgeDays,
            channelDegradedFailureCount: channelDegradedFailureCount,
            channelDegradedWindowSeconds: channelDegradedWindowSeconds,
            idleThresholdSeconds: idleThresholdSeconds,
            mergeEnabled: mergeEnabled,
            mergeSimilarityThreshold: mergeSimilarityThreshold,
            mergeMaxPerRun: mergeMaxPerRun,
            snapshotProvider: { [weak self] in
                guard let self else { return ([], []) }
                return await (self.channels.snapshots(), self.workers.snapshots())
            },
            branchProvider: { [weak self] in
                guard let self else { return [] }
                return await self.branches.activeBranches()
            },
            branchForceTimeout: { [weak self] branchId in
                await self?.branches.forceTimeout(branchId: branchId)
            }
        )
    }

    /// Stops the Visor supervision tick loop.
    func stopVisorSupervision() async {
        await visor.stopSupervision()
    }

    /// Returns true after Visor has completed its first supervision tick.
    func isVisorReady() async -> Bool {
        await visor.isReady
    }

    /// Asks Visor a question and returns an LLM-synthesized answer from current context.
    func askVisor(question: String) async -> String {
        let channels = await channels.snapshots()
        let workers = await workers.snapshots()
        return await visor.answer(question: question, channels: channels, workers: workers)
    }

    /// Asks Visor a question and streams the answer as text delta chunks.
    func streamVisorAnswer(question: String) async -> AsyncStream<String> {
        let channels = await channels.snapshots()
        let workers = await workers.snapshots()
        return await visor.streamAnswer(question: question, channels: channels, workers: workers)
    }

    /// Cancels all active workers on a channel and emits abort event.
    func abortChannel(channelId: String, reason: String? = nil) async -> Int {
        guard let snapshot = await channels.snapshot(channelId: channelId) else {
            return 0
        }
        var cancelledResponses = 0
        if let activeResponse = activeResponseTasks.removeValue(forKey: channelId) {
            activeResponse.task.cancel()
            sessionsByChannel.removeValue(forKey: channelId)
            cancelledResponses = 1
        }

        var cancelledWorkers = 0
        for workerId in snapshot.activeWorkerIds {
            let ok = await workers.cancel(workerId: workerId, reason: reason)
            if ok {
                await channels.detachWorker(channelId: channelId, workerId: workerId)
                cancelledWorkers += 1
            }
        }
        if cancelledWorkers > 0 {
            await channels.appendSystemMessage(
                channelId: channelId,
                content: "Channel processing aborted. \(cancelledWorkers) worker(s) cancelled."
            )
        }
        return cancelledResponses + cancelledWorkers
    }

    /// Cancels a specific worker and detaches it from channel active tracking.
    func cancelWorker(workerId: String, reason: String? = nil) async -> Bool {
        guard let snapshot = await workers.snapshot(workerId: workerId) else {
            return false
        }
        let ok = await workers.cancel(workerId: workerId, reason: reason)
        if ok {
            await channels.detachWorker(channelId: snapshot.channelId, workerId: workerId)
        }
        return ok
    }

    /// Returns memory entries tracked by runtime memory store.
    func memoryEntries() async -> [MemoryEntry] {
        await memoryStore.entries()
    }

    /// Returns bootstrap prompt content for the given channel, if available.
    func channelBootstrapContent(channelId: String) async -> String? {
        bootstrapByChannel[channelId]
    }

    /// Returns snapshots for all channels currently tracked by the runtime.
    func activeChannelSnapshots() async -> [ChannelSnapshot] {
        await channels.snapshots()
    }
}

private extension JSONValue {
    var runtimeObjectValue: [String: JSONValue] {
        if case let .object(object) = self {
            return object
        }
        return [:]
    }

    var runtimeStringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}
