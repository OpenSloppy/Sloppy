import Foundation
import AgentRuntime
import Protocols
import PluginSDK
import Logging

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let dict) = self { return dict }
        return [:]
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

func sessionToolRoots(forWorkingDirectory workingDirectory: String) -> [String] {
    let workURL = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
    var roots = [workURL.path]

    let worktreesDir = workURL.deletingLastPathComponent()
    if worktreesDir.lastPathComponent == ".sloppy-worktrees" {
        let repoRoot = worktreesDir.deletingLastPathComponent().standardizedFileURL.path
        if repoRoot != "/" && !repoRoot.isEmpty {
            roots.append(repoRoot)
        }
    }

    var seen = Set<String>()
    return roots.filter { root in
        seen.insert(root).inserted
    }
}

// MARK: - Task Lifecycle

extension CoreService {
    func handleTaskBecameReady(projectID: String, taskID: String) async {
        await waitForStartup(dispatchReadyTasks: false)

        guard var project = await store.project(id: projectID),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            return
        }

        let pickupGeneration = projectStopGenerations[projectID, default: 0]
        var task = project.tasks[taskIndex]
        guard project.automaticTaskPickupEnabled,
              task.status == ProjectTaskStatus.ready.rawValue,
              pickupRulesPermit(project: project, task: task) else {
            return
        }

        if let executionNodeId = task.executionNodeId,
           let localNodeId = try? nodeConfigStore.load().identity.nodeId,
           executionNodeId != localNodeId {
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "remote_instance_assigned",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: "Local execution skipped because this task is assigned to mesh node \(executionNodeId)."
            )
            return
        }

        if let waitingMessage = taskDependencyWaitingMessage(project: project, task: task) {
            await returnReadyTaskToBacklogForDependencies(
                project: project,
                taskIndex: taskIndex,
                task: task,
                message: waitingMessage
            )
            return
        }

        // Sequential / assistive capacity gate: if autopilot manages this task and the
        // mode allows only one concurrent execution, return it to backlog when another
        // autopilot task is already active.  The visor scheduler will re-release it once
        // the active task completes.
        if project.autopilotSettings.enabled,
           isAutopilotManagedTask(project: project, task: task) {
            let activeCount = project.tasks.filter { t in
                t.id != task.id &&
                isAutopilotExecutionTask(project: project, task: t) &&
                activeAutopilotStatuses.contains(t.status)
            }.count
            let capacity = autopilotCapacity(settings: project.autopilotSettings, activeCount: activeCount)
            if capacity <= 0 {
                await returnReadyTaskToBacklogForCapacity(
                    project: project,
                    taskIndex: taskIndex,
                    task: task
                )
                return
            }
        }

        _ = await triggerVisorBulletin()
        guard await currentPickupRulesPermit(projectID: projectID, taskID: taskID) else {
            return
        }
        logger.info(
            "visor.task.approved",
            metadata: [
                "project_id": .string(projectID),
                "task_id": .string(taskID),
                "source": .string("status_ready")
            ]
        )

        let workers = await runtime.workerSnapshots()
        let activeWorker = workers.first { snapshot in
            snapshot.taskId == task.id &&
            (snapshot.status == .queued || snapshot.status == .running || snapshot.status == .waitingInput)
        }
        guard activeWorker == nil else {
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "already_running",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: activeWorker?.workerId,
                message: "Skipped auto-delegation because task already has an active worker."
            )
            return
        }

        let delegation: TaskDelegation?
        if task.swarmId != nil, let swarmTaskId = task.swarmTaskId, swarmTaskId != "root" {
            delegation = await resolveSwarmTaskDelegation(project: project, task: task)
        } else {
            delegation = await resolveTaskDelegation(project: project, task: task)
        }
        let effectiveDelegation: TaskDelegation?
        if task.stageAssignments != nil {
            effectiveDelegation = delegation
        } else if let delegation {
            let agentID = normalizeWhitespace(delegation.agentID ?? "")
            if agentID.isEmpty, let fallback = autopilotDelegationFallback(project: project, task: task) {
                effectiveDelegation = fallback
            } else {
                effectiveDelegation = delegation
            }
        } else {
            effectiveDelegation = autopilotDelegationFallback(project: project, task: task)
        }

        guard let delegation = effectiveDelegation else {
            if shouldLeaveReadyForConstrainedRoute(project: project, task: task) {
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: task.id,
                    stage: "route_constrained",
                    channelID: resolveExecutionChannelID(project: project, task: task),
                    workerID: nil,
                    message: "Skipped auto-delegation because the assigned actor is not reachable by task routes.",
                    actorID: task.actorId ?? task.claimedActorId,
                    agentID: task.claimedAgentId
                )
                return
            }
            let blockedMessage = task.stageAssignments != nil && task.stageAssignments?.developer == nil
                ? "Task \(task.id) needs a developer. Assign one in Stage responsibilities, then move the task to Ready."
                : "Task \(task.id) is ready but no eligible actor route was resolved."
            await blockReadyTaskFlowProblem(
                project: project,
                taskIndex: taskIndex,
                task: task,
                previousStatus: task.status,
                stage: "route_blocked",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: blockedMessage,
                actorID: nil,
                agentID: nil
            )
            return
        }

        let delegatedAgentID = normalizeWhitespace(delegation.agentID ?? "")
        guard !delegatedAgentID.isEmpty else {
            let blockedMessage = "Task \(task.id) is ready but the resolved route has no linked agent. Assign an actor with a linked agent or choose a team member that can execute the task."
            await blockReadyTaskFlowProblem(
                project: project,
                taskIndex: taskIndex,
                task: task,
                previousStatus: task.status,
                stage: "missing_agent",
                channelID: delegation.channelID,
                workerID: nil,
                message: blockedMessage,
                actorID: delegation.actorID,
                agentID: nil
            )
            return
        }

        guard await currentPickupRulesPermit(projectID: projectID, taskID: taskID) else { return }
        if !isAutopilotManagedTask(project: project, task: task),
           await startSwarmIfHierarchical(projectID: project.id, taskID: task.id, delegation: delegation) {
            return
        }

        task.claimedActorId = delegation.actorID
        task.claimedAgentId = delegation.agentID
        if let actorID = delegation.actorID {
            task.actorId = actorID
        }
        let routeUpdate = recordAutonomousRoute(
            task: task,
            actorID: delegation.actorID,
            agentID: delegation.agentID,
            reason: "delegate",
            settings: project.reviewSettings
        )
        task = routeUpdate.task
        if let blockedMessage = routeUpdate.blockedMessage {
            await persistAutonomousRouteBlock(
                project: project,
                taskIndex: taskIndex,
                task: task,
                previousStatus: task.status,
                message: blockedMessage,
                channelID: delegation.channelID,
                workerID: nil,
                actorID: delegation.actorID,
                agentID: delegation.agentID
            )
            return
        }

        var worktreePath: String?
        if let repoPath = project.repoPath,
           project.reviewSettings.enabled,
           task.worktreeBranch == nil {
            do {
                let provider = sourceControlProvider(for: project, task: task)
                let result = try await createOrReclaimWorktree(
                    repoPath: repoPath,
                    taskId: task.id,
                    worktreeRootPath: defaultWorktreeRootPath(projectID: project.id),
                    provider: provider
                )
                task.worktreeBranch = result.branchName
                task.sourceControlProviderId = provider.id
                worktreePath = result.worktreePath
            } catch {
                guard pickupGeneration == projectStopGenerations[projectID, default: 0] else { return }
                let failureMessage = "Worktree creation failed: \(error.localizedDescription). Task blocked before worker launch to avoid modifying the repository without an isolated worktree."
                logger.warning(
                    "visor.task.worktree_failed",
                    metadata: [
                        "project_id": .string(projectID),
                        "task_id": .string(taskID),
                        "error": .string(error.localizedDescription)
                    ]
                )
                appendTaskLifecycleLog(
                    projectID: projectID,
                    taskID: taskID,
                    stage: "worktree_failed",
                    channelID: resolveExecutionChannelID(project: project, task: task),
                    workerID: nil,
                    message: failureMessage
                )
                let previousStatus = task.status
                task.status = ProjectTaskStatus.blocked.rawValue
                task.updatedAt = Date()
                project.tasks[taskIndex] = task
                project.updatedAt = Date()
                await store.saveProject(project)
                await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
                await recordSystemStatusChange(
                    projectID: project.id,
                    taskID: task.id,
                    from: previousStatus,
                    to: task.status,
                    source: "system"
                )
                await appendSystemTaskComment(
                    projectID: project.id, taskID: task.id,
                    content: "\(failureMessage)\nAction required: check the repository and source-control configuration, then return the task to ready.",
                    kind: .actionRequired
                )
                if let channelID = resolveExecutionChannelID(project: project, task: task) {
                    await runtime.appendSystemMessage(channelId: channelID, content: failureMessage)
                }
                return
            }
        } else if task.worktreeBranch != nil {
            if let repoPath = project.repoPath {
                worktreePath = sourceControlProvider(for: project, task: task).worktreePath(
                    repoPath: repoPath,
                    taskId: task.id,
                    worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
                )
            }
        }

        guard pickupGeneration == projectStopGenerations[projectID, default: 0],
              let latestPickupProject = await store.project(id: projectID),
              latestPickupProject.automaticTaskPickupEnabled,
              let latestPickupTask = latestPickupProject.tasks.first(where: { $0.id == taskID }),
              latestPickupTask.status == ProjectTaskStatus.ready.rawValue,
              pickupRulesPermit(project: latestPickupProject, task: latestPickupTask) else { return }
        // Keep settings changed while worktree preparation was awaiting I/O.
        project.autopilotSettings = latestPickupProject.autopilotSettings
        let prevStatusForLog = task.status
        task.status = ProjectTaskStatus.inProgress.rawValue
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevStatusForLog, to: task.status, source: "system")

        let effectiveWorkingDirectory = worktreePath ?? project.repoPath
        let workerMode: WorkerMode = task.kind == .planning ? .interactive : .fireAndForget
        let workerObjective = buildWorkerObjective(task: task, project: project, worktreePath: worktreePath)
        let workerTools = workerToolsForTask(task: task, project: project)
        let workerId = await runtime.createWorker(
            spec: WorkerTaskSpec(
                taskId: task.id,
                channelId: delegation.channelID,
                title: task.title,
                objective: workerObjective,
                agentID: delegation.agentID,
                tools: workerTools,
                mode: workerMode,
                workingDirectory: effectiveWorkingDirectory,
                selectedModel: {
                    let t = task.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return t.isEmpty ? nil : t
                }()
            )
        )

        await startTaskRun(
            projectID: project.id,
            taskID: task.id,
            actorID: delegation.actorID,
            agentID: delegation.agentID,
            workerID: workerId,
            channelID: delegation.channelID
        )
        await recordTaskWorkerHeartbeat(
            projectID: project.id,
            taskID: task.id,
            workerID: workerId,
            agentID: delegation.agentID,
            status: .running,
            message: "Worker started.",
            metadata: [
                "source": "worker_started",
                "channelId": delegation.channelID
            ]
        )

        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "worker_spawned",
            channelID: delegation.channelID,
            workerID: workerId,
            message: "Task delegated.",
            actorID: delegation.actorID,
            agentID: delegation.agentID
        )

        logger.info(
            "visor.task.worker_spawned",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "worker_id": .string(workerId),
                "channel_id": .string(delegation.channelID),
                "agent_id": .string(delegation.agentID ?? "none")
            ]
        )
        // Build a descriptive spawn message including agent/actor details and log path.
        let delegateMessage: String
        if let agentID = delegation.agentID {
            delegateMessage = "Task \(task.id) delegated to agent \(agentID)."
        } else if let actorID = delegation.actorID {
            delegateMessage = "Task \(task.id) delegated to actor \(actorID)."
        } else {
            delegateMessage = "Task \(task.id) started in channel \(delegation.channelID)."
        }
        let logsPath = projectTaskLogFileURL(projectID: project.id, taskID: task.id).path
        let spawnMessage = "\(delegateMessage) Logs: \(logsPath)"
        await runtime.appendSystemMessage(
            channelId: delegation.channelID,
            content: spawnMessage
        )
        await deliverToChannelPlugin(
            channelId: delegation.channelID,
            content: spawnMessage
        )
    }

    func taskDependencyWaitingMessage(project: ProjectRecord, task: ProjectTask) -> String? {
        let unmetDependencies = unmetProjectTaskDependencies(project: project, task: task)
        guard !unmetDependencies.isEmpty else {
            return nil
        }
        return dependencyWaitMessage(task: task, unmetDependencies: unmetDependencies)
    }

    func taskDependenciesSatisfied(project: ProjectRecord, task: ProjectTask) -> Bool {
        unmetProjectTaskDependencies(project: project, task: task).isEmpty
    }

    func returnReadyTaskToBacklogForDependencies(
        project: ProjectRecord,
        taskIndex: Int,
        task: ProjectTask,
        message: String
    ) async {
        var project = project
        var task = task
        let previousStatus = task.status
        task.status = ProjectTaskStatus.backlog.rawValue
        task.claimedActorId = nil
        task.claimedAgentId = nil
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(
            projectID: project.id,
            taskID: task.id,
            from: previousStatus,
            to: task.status,
            source: "system"
        )
        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "dependency_wait",
            channelID: resolveExecutionChannelID(project: project, task: task),
            workerID: nil,
            message: message,
            actorID: task.actorId,
            agentID: task.claimedAgentId
        )
        let existingComments = await listTaskComments(projectID: project.id, taskID: task.id)
        if !existingComments.contains(where: { $0.authorActorId == "system" && $0.content.contains("Task is waiting for dependencies before it can run:") }) {
            await appendSystemTaskComment(projectID: project.id, taskID: task.id, content: message)
        }
        logger.info(
            "visor.task.dependency_wait",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id)
            ]
        )
    }

    func returnReadyTaskToBacklogForCapacity(
        project: ProjectRecord,
        taskIndex: Int,
        task: ProjectTask
    ) async {
        var project = project
        var task = task
        let previousStatus = task.status
        task.status = ProjectTaskStatus.backlog.rawValue
        task.claimedActorId = nil
        task.claimedAgentId = nil
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(
            projectID: project.id,
            taskID: task.id,
            from: previousStatus,
            to: task.status,
            source: "system"
        )
        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "autopilot_capacity_wait",
            channelID: resolveExecutionChannelID(project: project, task: task),
            workerID: nil,
            message: "Task returned to backlog: autopilot sequential capacity is at limit. Will be re-released when active task completes.",
            actorID: task.actorId,
            agentID: task.claimedAgentId
        )
        logger.info(
            "visor.task.autopilot_capacity_wait",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "mode": .string(project.autopilotSettings.mode.rawValue)
            ]
        )
    }

    @discardableResult
    public func reclaimStaleProjectTaskClaims(
        staleAfter timeout: TimeInterval,
        now: Date = Date()
    ) async -> [ProjectTask] {
        let activeWorkers = await runtime.workerSnapshots().filter { snapshot in
            snapshot.status == .queued || snapshot.status == .running || snapshot.status == .waitingInput
        }
        let workersByTaskID = Dictionary(grouping: activeWorkers, by: \.taskId)
        var reclaimed: [ProjectTask] = []

        for var project in await store.listProjects() {
            var changed = false
            var projectReclaimedTasks: [ProjectTask] = []
            for index in project.tasks.indices {
                var task = project.tasks[index]
                guard task.status == ProjectTaskStatus.inProgress.rawValue else {
                    continue
                }

                let workers = workersByTaskID[task.id] ?? []
                let heartbeats = await listTaskWorkerHeartbeats(projectID: project.id, taskID: task.id)
                var hasFreshWorker = false
                for worker in workers {
                    if let heartbeat = latestHeartbeat(for: worker, in: heartbeats) {
                        if now.timeIntervalSince(heartbeat.updatedAt) < timeout {
                            hasFreshWorker = true
                            break
                        }
                        continue
                    }
                    guard let startedAt = worker.startedAt else {
                        hasFreshWorker = true
                        break
                    }
                    if now.timeIntervalSince(startedAt) < timeout {
                        hasFreshWorker = true
                        break
                    }
                }
                guard !hasFreshWorker else {
                    continue
                }

                let previousStatus = task.status
                task.status = ProjectTaskStatus.ready.rawValue
                task.claimedActorId = nil
                task.claimedAgentId = nil
                task.updatedAt = now
                project.tasks[index] = task
                changed = true
                reclaimed.append(task)
                projectReclaimedTasks.append(task)

                await finishLatestTaskRun(
                    projectID: project.id,
                    taskID: task.id,
                    outcome: .reclaimed,
                    summary: "Task claim reclaimed after worker became stale or disappeared.",
                    metadata: [
                        "source": "system",
                        "reason": "stale_claim"
                    ],
                    failureReason: "Worker became stale or disappeared.",
                    actorID: task.actorId,
                    agentID: nil,
                    workerID: workers.first?.workerId,
                    channelID: resolveExecutionChannelID(project: project, task: task)
                )
                await recordSystemStatusChange(
                    projectID: project.id,
                    taskID: task.id,
                    from: previousStatus,
                    to: task.status,
                    source: "system"
                )
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: task.id,
                    stage: "stale_claim_reclaimed",
                    channelID: resolveExecutionChannelID(project: project, task: task),
                    workerID: workers.first?.workerId,
                    message: "Task claim reclaimed after worker became stale or disappeared.",
                    actorID: task.actorId,
                    agentID: nil
                )
            }

            if changed {
                project.updatedAt = now
                await store.saveProject(project)
                for task in projectReclaimedTasks {
                    await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
                }
            }
        }

        return reclaimed
    }

    func latestHeartbeat(
        for worker: WorkerSnapshot,
        in heartbeats: [ProjectTaskWorkerHeartbeat]
    ) -> ProjectTaskWorkerHeartbeat? {
        heartbeats.reversed().first { heartbeat in
            heartbeat.workerId == worker.workerId
        }
    }

    public struct KanbanMaintenanceResult: Sendable, Equatable {
        public var reclaimedTaskIds: [String]
        public var dispatchAttemptedTaskIds: [String]

        public init(
            reclaimedTaskIds: [String] = [],
            dispatchAttemptedTaskIds: [String] = []
        ) {
            self.reclaimedTaskIds = reclaimedTaskIds
            self.dispatchAttemptedTaskIds = dispatchAttemptedTaskIds
        }
    }

    @discardableResult
    public func runKanbanMaintenanceNow(now: Date = Date()) async -> KanbanMaintenanceResult {
        await waitForStartup(dispatchReadyTasks: false)
        let reclaimed = await reclaimStaleProjectTaskClaims(
            staleAfter: TimeInterval(max(0, currentConfig.kanban.staleClaimTimeoutSeconds)),
            now: now
        )
        let reclaimedIDs = Set(reclaimed.map(\.id))
        let readyTasks = await store.listProjects().flatMap { project in
            project.tasks
                .filter { task in
                    project.automaticTaskPickupEnabled &&
                        task.status == ProjectTaskStatus.ready.rawValue &&
                        !reclaimedIDs.contains(task.id)
                }
                .map { (project.id, $0.id) }
        }

        var dispatched: [String] = []
        var seen = Set<String>()
        for (projectID, taskID) in readyTasks where seen.insert("\(projectID):\(taskID)").inserted {
            await handleTaskBecameReady(projectID: projectID, taskID: taskID)
            dispatched.append(taskID)
        }

        return KanbanMaintenanceResult(
            reclaimedTaskIds: reclaimed.map(\.id),
            dispatchAttemptedTaskIds: dispatched
        )
    }

    func handleKanbanRuntimeEvent(_ event: EventEnvelope) async {
        guard event.messageType == .workerFailed,
              let taskID = event.taskId,
              let projectID = await projectID(containingTaskID: taskID)
        else {
            return
        }
        let error = event.payload.objectValue["error"]?.stringValue ?? "Worker failed."
        _ = try? await recordProjectTaskSpawnFailure(
            projectID: projectID,
            taskID: taskID,
            error: error,
            failureLimit: currentConfig.kanban.spawnFailureLimit
        )
    }

    func projectID(containingTaskID taskID: String) async -> String? {
        let lowercasedTaskID = taskID.lowercased()
        return await store.listProjects().first { project in
            project.tasks.contains { $0.id.lowercased() == lowercasedTaskID }
        }?.id
    }

    func recordProjectTaskWorkerLaunchFailure(
        taskID: String,
        error: String
    ) async {
        guard let projectID = await projectID(containingTaskID: taskID) else {
            return
        }
        _ = try? await recordProjectTaskSpawnFailure(
            projectID: projectID,
            taskID: taskID,
            error: error,
            failureLimit: currentConfig.kanban.spawnFailureLimit
        )
    }

    @discardableResult
    public func recordProjectTaskSpawnFailure(
        projectID: String,
        taskID: String,
        error: String,
        failureLimit: Int = 2
    ) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        guard var project = await store.project(id: normalizedProject),
              let taskIndex = project.tasks.firstIndex(where: { $0.id.lowercased() == normalizedTask.lowercased() })
        else {
            throw ProjectError.notFound
        }

        var task = project.tasks[taskIndex]
        guard task.status != ProjectTaskStatus.cancelled.rawValue else { return project }
        let previousStatus = task.status
        let failureMessage = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedFailure = String((failureMessage.isEmpty ? "Worker spawn failed." : failureMessage).prefix(1_000))
        let run = await finishLatestTaskRun(
            projectID: project.id,
            taskID: task.id,
            outcome: .failed,
            summary: boundedFailure,
            metadata: [
                "source": "system",
                "reason": "spawn_failed"
            ],
            failureReason: boundedFailure,
            actorID: task.claimedActorId ?? task.actorId,
            agentID: task.claimedAgentId,
            workerID: nil,
            channelID: resolveExecutionChannelID(project: project, task: task)
        )
        let consecutiveFailures = await consecutiveTaskRunFailures(projectID: project.id, taskID: task.id)
        let effectiveLimit = max(1, failureLimit)
        let shouldBlock = consecutiveFailures >= effectiveLimit

        task.status = shouldBlock ? ProjectTaskStatus.blocked.rawValue : ProjectTaskStatus.ready.rawValue
        if shouldBlock {
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = task.updatedAt
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: previousStatus, to: task.status, source: "system")

        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: shouldBlock ? "circuit_breaker" : "spawn_failed",
            channelID: resolveExecutionChannelID(project: project, task: task),
            workerID: run.workerId,
            message: shouldBlock
                ? "Task blocked after \(consecutiveFailures) consecutive spawn failures. Last error: \(boundedFailure)"
                : "Worker spawn failed; task remains ready for retry. Error: \(boundedFailure)",
            actorID: task.claimedActorId ?? task.actorId,
            agentID: task.claimedAgentId
        )
        if shouldBlock {
            await appendSystemTaskComment(
                projectID: project.id,
                taskID: task.id,
                content: "Automatic worker launch attempts exhausted (limit: \(effectiveLimit)). Task is blocked.\nLast error: \(boundedFailure)\nAction required: resolve the launch error, then return the task to ready.",
                kind: .actionRequired
            )
        }

        return project
    }

    func consecutiveTaskRunFailures(projectID: String, taskID: String) async -> Int {
        let runs = await listTaskRuns(projectID: projectID, taskID: taskID)
        var count = 0
        for run in runs.reversed() {
            guard run.endedAt != nil else {
                continue
            }
            if run.outcome == .failed {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    func autopilotDelegationFallback(project: ProjectRecord, task: ProjectTask) -> TaskDelegation? {
        guard project.autopilotSettings.enabled,
              isAutopilotManagedTask(project: project, task: task),
              let channelID = resolveExecutionChannelID(project: project, task: task)
        else {
            return nil
        }
        let agentID = normalizeWhitespace(project.autopilotSettings.defaultAgentId ?? "")
        guard !agentID.isEmpty else {
            return nil
        }
        return TaskDelegation(actorID: nil, agentID: agentID, channelID: channelID)
    }

    func workerToolsForTask(task: ProjectTask, project: ProjectRecord) -> [String] {
        var tools: [String] = ["project_tasks"]
        guard isAutopilotManagedTask(project: project, task: task) else {
            tools.append(contentsOf: ["shell", "file", "exec", "browser"])
            return Array(Set(tools)).sorted()
        }
        let settings = project.autopilotSettings
        if settings.canRunCommands {
            tools.append(contentsOf: ["shell", "exec"])
        }
        if settings.canEditFiles {
            tools.append("file")
        }
        if settings.canStartLocalhost {
            tools.append("browser")
        }
        if settings.canUseWeb {
            tools.append(contentsOf: ["web.search", "web.fetch"])
        }
        return tools.isEmpty ? ["project"] : Array(Set(tools)).sorted()
    }

    func shouldLeaveReadyForConstrainedRoute(project: ProjectRecord, task: ProjectTask) -> Bool {
        guard let board = try? getActorBoard() else {
            return false
        }
        let preferredActors = preferredActorIDs(for: task, board: board)
        guard !preferredActors.isEmpty,
              let allowedActors = routableActorIDs(project: project, task: task, board: board)
        else {
            return false
        }
        return preferredActors.allSatisfy { !allowedActors.contains($0) }
    }

    func resolveExecutionChannelID(project: ProjectRecord, task: ProjectTask) -> String? {
        if let markedChannelID = extractOriginChannelID(from: task.description),
           project.channels.contains(where: { $0.channelId == markedChannelID }) {
            return markedChannelID
        }
        return project.channels.sorted(by: { $0.createdAt < $1.createdAt }).first?.channelId
    }

    struct AutonomousRouteUpdate {
        var task: ProjectTask
        var blockedMessage: String?
    }

    func recordAutonomousRoute(
        task: ProjectTask,
        actorID: String?,
        agentID: String?,
        reason: String,
        settings: ProjectReviewSettings
    ) -> AutonomousRouteUpdate {
        let normalizedActorID = normalizeWhitespace(actorID ?? "")
        let normalizedAgentID = normalizeWhitespace(agentID ?? "")
        let routeIdentity: String?
        if !normalizedActorID.isEmpty {
            routeIdentity = "actor:\(normalizedActorID)"
        } else if !normalizedAgentID.isEmpty {
            routeIdentity = "agent:\(normalizedAgentID)"
        } else {
            routeIdentity = nil
        }

        guard let routeIdentity else {
            return AutonomousRouteUpdate(task: task, blockedMessage: nil)
        }

        var task = task
        if let last = task.routeHistory.last,
           autonomousRouteIdentity(actorID: last.actorId, agentID: last.agentId) == routeIdentity {
            return AutonomousRouteUpdate(task: task, blockedMessage: nil)
        }

        let step = ProjectTaskRouteStep(
            actorId: normalizedActorID.isEmpty ? nil : normalizedActorID,
            agentId: normalizedAgentID.isEmpty ? nil : normalizedAgentID,
            reason: normalizeWhitespace(reason).isEmpty ? "delegate" : normalizeWhitespace(reason)
        )
        let previousHistory = task.routeHistory
        task.routeHistory.append(step)

        let path = autonomousRoutePath(task.routeHistory)
        if previousHistory.contains(where: {
            autonomousRouteIdentity(actorID: $0.actorId, agentID: $0.agentId) == routeIdentity
        }) {
            return AutonomousRouteUpdate(
                task: task,
                blockedMessage: "Autonomous routing loop detected: \(path). Human intervention required."
            )
        }

        let maxRouteSteps = max(1, settings.maxAutonomousRouteSteps)
        if previousHistory.count >= maxRouteSteps {
            return AutonomousRouteUpdate(
                task: task,
                blockedMessage: "Autonomous route limit reached (\(maxRouteSteps) steps): \(path). Human intervention required."
            )
        }

        return AutonomousRouteUpdate(task: task, blockedMessage: nil)
    }

    func autonomousRouteIdentity(actorID: String?, agentID: String?) -> String? {
        let normalizedActorID = normalizeWhitespace(actorID ?? "")
        if !normalizedActorID.isEmpty {
            return "actor:\(normalizedActorID)"
        }
        let normalizedAgentID = normalizeWhitespace(agentID ?? "")
        if !normalizedAgentID.isEmpty {
            return "agent:\(normalizedAgentID)"
        }
        return nil
    }

    func autonomousRoutePath(_ history: [ProjectTaskRouteStep]) -> String {
        let labels = history.map { step in
            if let actorID = step.actorId, !actorID.isEmpty {
                return actorID
            }
            if let agentID = step.agentId, !agentID.isEmpty {
                return "agent:\(agentID)"
            }
            return "unknown"
        }
        return labels.isEmpty ? "(empty)" : labels.joined(separator: " -> ")
    }

    func persistAutonomousRouteBlock(
        project: ProjectRecord,
        taskIndex: Int,
        task: ProjectTask,
        previousStatus: String,
        message: String,
        channelID: String?,
        workerID: String?,
        actorID: String?,
        agentID: String?,
        artifactPath: String? = nil
    ) async {
        var project = project
        var task = task
        task.status = ProjectTaskStatus.blocked.rawValue
        task.updatedAt = Date()
        let note = "Autonomous route blocked: \(message)"
        if task.description.isEmpty {
            task.description = note
        } else if !task.description.contains(note) {
            task.description += "\n\n\(note)"
        }
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(
            projectID: project.id,
            taskID: task.id,
            from: previousStatus,
            to: task.status,
            source: "system"
        )
        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "loop_guard_blocked",
            channelID: channelID,
            workerID: workerID,
            message: message,
            actorID: actorID,
            agentID: agentID,
            artifactPath: artifactPath
        )
        await appendSystemTaskComment(
            projectID: project.id, taskID: task.id,
            content: "Task blocked by system flow: \(message)\nAction required: review the routing blocker, then return the task to ready.",
            kind: .actionRequired
        )
        _ = await ensureInitiativeDecisionPacket(
            projectID: project.id,
            task: task,
            kind: .blocked,
            summary: "Task \(task.id) is blocked by autonomous routing",
            rationale: message,
            requestedAction: "Review the routing blocker for task \(task.id)",
            resumePoint: "Resume task \(task.id) after routing blocker is resolved"
        )
        if let channelID {
            let statusMessage = "Task \(task.id) blocked: \(message)"
            await runtime.appendSystemMessage(channelId: channelID, content: statusMessage)
            await deliverToChannelPlugin(channelId: channelID, content: statusMessage)
        }
        logger.warning(
            "visor.task.loop_guard_blocked",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "message": .string(message)
            ]
        )
    }

    func blockReadyTaskFlowProblem(
        project: ProjectRecord,
        taskIndex: Int,
        task: ProjectTask,
        previousStatus: String,
        stage: String,
        channelID: String?,
        workerID: String?,
        message: String,
        actorID: String?,
        agentID: String?
    ) async {
        var project = project
        var task = task
        task.status = ProjectTaskStatus.blocked.rawValue
        task.updatedAt = Date()
        let note = "Task flow problem: \(message)"
        if task.description.isEmpty {
            task.description = note
        } else if !task.description.contains(note) {
            task.description += "\n\n\(note)"
        }
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(
            projectID: project.id,
            taskID: task.id,
            from: previousStatus,
            to: task.status,
            source: "system"
        )
        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: stage,
            channelID: channelID,
            workerID: workerID,
            message: message,
            actorID: actorID,
            agentID: agentID
        )
        await appendSystemTaskComment(
            projectID: project.id, taskID: task.id,
            content: "\(note)\nAction required: resolve this flow blocker, then return the task to ready.",
            kind: .actionRequired
        )
        _ = await ensureInitiativeDecisionPacket(
            projectID: project.id,
            task: task,
            kind: .blocked,
            summary: "Task \(task.id) is blocked by system flow",
            rationale: message,
            requestedAction: "Resolve the system flow blocker for task \(task.id)",
            resumePoint: "Resume task \(task.id) after the flow blocker is resolved"
        )
        if let channelID {
            let statusMessage = "Task \(task.id) blocked by system flow: \(message)"
            await runtime.appendSystemMessage(channelId: channelID, content: statusMessage)
            await deliverToChannelPlugin(channelId: channelID, content: statusMessage)
        }
        logger.warning(
            "visor.task.flow_blocked",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "stage": .string(stage),
                "message": .string(message)
            ]
        )
    }

    /// Stops background tasks and waits for pending work.
    func handleReviewHandoff(
        project: ProjectRecord,
        task: ProjectTask,
        taskIndex: Int,
        handoffDelegate: TeamRetryDelegate,
        event: EventEnvelope,
        completionArtifactPath: String?
    ) async {
        var project = project
        var task = task
        let prevReviewStatus = task.status

        let approvalMode = project.reviewSettings.approvalMode
        let reviewerChannelID = handoffDelegate.agentID.map { "agent:\($0)" }
            ?? event.channelId

        switch approvalMode {
        case .auto:
            task.status = ProjectTaskStatus.needsReview.rawValue
            task.claimedActorId = handoffDelegate.actorID
            task.claimedAgentId = handoffDelegate.agentID
            task.updatedAt = Date()
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevReviewStatus, to: task.status, source: "system")
            await finishLatestTaskRun(
                projectID: project.id,
                taskID: task.id,
                outcome: .needsReview,
                summary: "Task completed and sent to auto-review.",
                metadata: ["reviewMode": approvalMode.rawValue],
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                workerID: event.workerId,
                channelID: event.channelId
            )
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "review_auto",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Auto-approving task.",
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID
            )
            scheduleProjectMemoryCheckpointFromWorkerEvent(
                projectID: project.id,
                taskID: task.id,
                status: task.status,
                event: event
            )
            await appendAutoReviewTaskComment(
                projectID: project.id,
                taskID: task.id,
                artifactPath: completionArtifactPath
            )
            try? await approveTask(projectID: project.id, taskID: task.id)

        case .human:
            task.status = ProjectTaskStatus.needsReview.rawValue
            task.claimedActorId = handoffDelegate.actorID
            task.claimedAgentId = handoffDelegate.agentID
            task.updatedAt = Date()
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevReviewStatus, to: task.status, source: "system")
            await finishLatestTaskRun(
                projectID: project.id,
                taskID: task.id,
                outcome: .needsReview,
                summary: "Task completed and is awaiting human review.",
                metadata: ["reviewMode": approvalMode.rawValue],
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                workerID: event.workerId,
                channelID: event.channelId
            )
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "review_human",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Awaiting human review.",
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                artifactPath: completionArtifactPath
            )
            scheduleProjectMemoryCheckpointFromWorkerEvent(
                projectID: project.id,
                taskID: task.id,
                status: task.status,
                event: event
            )
            let reviewMessage = "Task \(task.id) is ready for review. Approve or reject via the dashboard."
            await runtime.appendSystemMessage(channelId: event.channelId, content: reviewMessage)
            await deliverToChannelPlugin(channelId: event.channelId, content: reviewMessage)

        case .agent:
            let diff: String
            if let repoPath = project.repoPath, let branchName = task.worktreeBranch {
                let provider = sourceControlProvider(for: project, task: task)
                let baseBranch = (try? await provider.defaultBranch(at: repoPath)) ?? "main"
                diff = (try? await provider.branchDiff(at: repoPath, branchName: branchName, baseBranch: baseBranch, maxBytes: 512 * 1024))?.text ?? "Diff unavailable."
            } else {
                diff = "No worktree branch available."
            }
            let reviewObjective = buildReviewObjective(task: task, projectID: project.id, diff: diff)
            task.status = ProjectTaskStatus.needsReview.rawValue
            task.claimedActorId = handoffDelegate.actorID
            task.claimedAgentId = handoffDelegate.agentID
            task.updatedAt = Date()
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevReviewStatus, to: task.status, source: handoffDelegate.agentID ?? "system")
            await finishLatestTaskRun(
                projectID: project.id,
                taskID: task.id,
                outcome: .needsReview,
                summary: "Task completed and was delegated to reviewer agent.",
                metadata: ["reviewMode": approvalMode.rawValue],
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                workerID: event.workerId,
                channelID: event.channelId
            )
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "review_agent",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Delegated to reviewer agent.",
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                artifactPath: completionArtifactPath
            )
            scheduleProjectMemoryCheckpointFromWorkerEvent(
                projectID: project.id,
                taskID: task.id,
                status: task.status,
                event: event
            )
            _ = await runtime.createWorker(
                spec: WorkerTaskSpec(
                    taskId: task.id,
                    channelId: reviewerChannelID,
                    title: "Review: \(task.title)",
                    objective: reviewObjective,
                    tools: ["project_tasks", "shell", "file"],
                    mode: .fireAndForget
                )
            )
        }
    }

    func buildReviewObjective(task: ProjectTask, projectID: String, diff: String) -> String {
        return normalizeTaskDescription([
            "Review task: \(task.title)",
            "",
            "Original task description:",
            task.description.isEmpty ? "(none)" : task.description,
            "",
            "Changes to review (source-control diff):",
            diff,
            "",
            "Review instructions:",
            "- Evaluate whether the changes correctly and completely implement the task.",
            "- Before approving or rejecting, leave a task-level review summary comment by calling project.task_update with completionConfidence and completionNote.",
            "- If the changes are acceptable, call the approve command/tool after leaving the review summary.",
            "- If the changes need work, call the reject command/tool with specific reasons after leaving the review summary."
        ].joined(separator: "\n"))
    }

    public func approveTask(projectID: String, taskID: String) async throws {
        let projects = await store.listProjects()
        guard var project = projects.first(where: { $0.id == projectID }),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            throw ProjectError.notFound
        }
        var task = project.tasks[taskIndex]
        let prevApproveStatus = task.status

        guard await hasReviewCompletionComment(
            projectID: projectID,
            taskID: taskID,
            reviewerActorID: task.claimedActorId,
            reviewerAgentID: task.claimedAgentId
        ) else {
            throw ProjectError.invalidPayload
        }

        if let repoPath = project.repoPath, let branchName = task.worktreeBranch {
            let provider = sourceControlProvider(for: project, task: task)
            let targetBranch = (try? await provider.defaultBranch(at: repoPath)) ?? "main"
            try await provider.mergeBranch(repoPath: repoPath, branchName: branchName, targetBranch: targetBranch)
            let worktreePath = provider.worktreePath(
                repoPath: repoPath,
                taskId: taskID,
                worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
            )
            if try await !launches.retainsCheckout(worktreePath) {
                try? await provider.removeWorktree(repoPath: repoPath, worktreePath: worktreePath)
            }
        }

        task.status = ProjectTaskStatus.done.rawValue
        task.routeHistory = []
        task.worktreeBranch = nil
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: projectID, task: task))
        await recordSystemStatusChange(projectID: projectID, taskID: taskID, from: prevApproveStatus, to: task.status, source: "user")
        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: taskID,
            stage: "approved",
            channelID: nil,
            workerID: nil,
            message: "Task approved and merged."
        )
        logger.info("visor.task.approved", metadata: ["project_id": .string(projectID), "task_id": .string(taskID)])
    }

    public func getTaskDiff(projectID: String, taskID: String) async throws -> TaskDiffResponse {
        let projects = await store.listProjects()
        guard let project = projects.first(where: { $0.id == projectID }),
              let task = project.tasks.first(where: { $0.id == taskID })
        else {
            throw ProjectError.notFound
        }

        guard let repoPath = project.repoPath else {
            return TaskDiffResponse(diff: "", branchName: "", baseBranch: "", hasChanges: false)
        }

        if let branchName = task.worktreeBranch {
            let provider = sourceControlProvider(for: project, task: task)
            let baseBranch = (try? await provider.defaultBranch(at: repoPath)) ?? "main"
            let diff = (try? await provider.branchDiff(at: repoPath, branchName: branchName, baseBranch: baseBranch, maxBytes: 512 * 1024))?.text ?? ""
            return TaskDiffResponse(diff: diff, branchName: branchName, baseBranch: baseBranch, hasChanges: !diff.isEmpty)
        }

        // Fallback: when a task is in review but no dedicated worktree exists, surface the project's working-tree diff.
        // This is less precise than a task-scoped worktree diff, but it prevents "no diff" when changes were made directly on the repo.
        let provider = sourceControlProvider(for: project, task: task)
        if task.status == ProjectTaskStatus.needsReview.rawValue,
           (await provider.inspectRepository(at: repoPath)).isRepository {
            let worktreePath = provider.worktreePath(
                repoPath: repoPath,
                taskId: taskID,
                worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
            )
            if (await provider.inspectRepository(at: worktreePath)).isRepository {
                let label = (try? await provider.currentBranch(at: worktreePath)) ?? ""
                let patch = (try? await provider.workingTreeDiff(at: worktreePath, maxBytes: 512 * 1024)) ?? SourceControlDiffResult(providerId: provider.id)
                let branchName = label.isEmpty ? "worktree (working-tree)" : "\(label) (working-tree)"
                return TaskDiffResponse(diff: patch.text, branchName: branchName, baseBranch: "HEAD", hasChanges: patch.hasChanges)
            }

            let label = (try? await provider.currentBranch(at: repoPath)) ?? ""
            let patch = (try? await provider.workingTreeDiff(at: repoPath, maxBytes: 512 * 1024)) ?? SourceControlDiffResult(providerId: provider.id)
            let branchName = label.isEmpty ? "working-tree" : "\(label) (working-tree)"
            return TaskDiffResponse(diff: patch.text, branchName: branchName, baseBranch: "HEAD", hasChanges: patch.hasChanges)
        }

        return TaskDiffResponse(diff: "", branchName: "", baseBranch: "", hasChanges: false)
    }

    public func listReviewComments(projectID: String, taskID: String) async -> [ReviewComment] {
        let url = reviewCommentsFileURL(projectID: projectID, taskID: taskID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ReviewComment].self, from: data)) ?? []
    }

    public func addReviewComment(projectID: String, taskID: String, request: ReviewCommentCreateRequest) async -> ReviewComment {
        var comments = await listReviewComments(projectID: projectID, taskID: taskID)
        let comment = ReviewComment(
            id: UUID().uuidString,
            taskId: taskID,
            filePath: request.filePath,
            lineNumber: request.lineNumber,
            side: request.side,
            content: request.content,
            author: request.author
        )
        comments.append(comment)
        saveReviewComments(comments, projectID: projectID, taskID: taskID)
        return comment
    }

    public func updateReviewComment(projectID: String, taskID: String, commentID: String, request: ReviewCommentUpdateRequest) async -> ReviewComment? {
        var comments = await listReviewComments(projectID: projectID, taskID: taskID)
        guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return nil }
        if let resolved = request.resolved { comments[index].resolved = resolved }
        if let content = request.content { comments[index].content = content }
        saveReviewComments(comments, projectID: projectID, taskID: taskID)
        return comments[index]
    }

    public func deleteReviewComment(projectID: String, taskID: String, commentID: String) async -> Bool {
        var comments = await listReviewComments(projectID: projectID, taskID: taskID)
        let before = comments.count
        comments.removeAll { $0.id == commentID }
        if comments.count == before { return false }
        saveReviewComments(comments, projectID: projectID, taskID: taskID)
        return true
    }

    func reviewCommentsFileURL(projectID: String, taskID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID)
            .appendingPathComponent("review-comments-\(taskID).json")
    }

    func saveReviewComments(_ comments: [ReviewComment], projectID: String, taskID: String) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(comments) else { return }
        let url = reviewCommentsFileURL(projectID: projectID, taskID: taskID)
        try? data.write(to: url, options: .atomic)
    }

    public func rejectTask(projectID: String, taskID: String, reason: String?) async throws {
        let projects = await store.listProjects()
        guard var project = projects.first(where: { $0.id == projectID }),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            throw ProjectError.notFound
        }
        var task = project.tasks[taskIndex]
        let prevRejectStatus = task.status

        if let reason, !reason.isEmpty {
            let rejectionNote = "Review rejected: \(reason)"
            if task.description.isEmpty {
                task.description = rejectionNote
            } else {
                task.description += "\n\n\(rejectionNote)"
            }
        }

        let board = try? getActorBoard()
        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        var developerActorID = task.stageAssignments?.developer
        var developerAgentID = developerActorID.flatMap { nodesByID[$0]?.linkedAgentId }
        if developerActorID == nil, let teamID = task.teamId,
           let team = board?.teams.first(where: { $0.id == teamID }) {
            for memberID in team.memberActorIds {
                if let node = nodesByID[memberID], team.roles(for: node).contains(.developer) {
                    developerActorID = memberID
                    developerAgentID = node.linkedAgentId
                    break
                }
            }
        }

        task.status = ProjectTaskStatus.ready.rawValue
        task.activeStage = .development
        task.claimedActorId = developerActorID ?? task.claimedActorId
        task.claimedAgentId = developerAgentID ?? task.claimedAgentId
        if let developerActorID {
            task.actorId = developerActorID
        }
        let routeUpdate = recordAutonomousRoute(
            task: task,
            actorID: task.claimedActorId,
            agentID: task.claimedAgentId,
            reason: "review_reject",
            settings: project.reviewSettings
        )
        task = routeUpdate.task
        if let blockedMessage = routeUpdate.blockedMessage {
            await persistAutonomousRouteBlock(
                project: project,
                taskIndex: taskIndex,
                task: task,
                previousStatus: prevRejectStatus,
                message: blockedMessage,
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId
            )
            return
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: projectID, task: task))
        await recordSystemStatusChange(projectID: projectID, taskID: taskID, from: prevRejectStatus, to: task.status, source: "user")
        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: taskID,
            stage: "rejected",
            channelID: nil,
            workerID: nil,
            message: "Task rejected. Returning to developer."
        )
        logger.info("visor.task.rejected", metadata: ["project_id": .string(projectID), "task_id": .string(taskID)])
        await handleTaskBecameReady(projectID: projectID, taskID: taskID)
    }

    func syncTaskProgressFromWorkerEvent(event: EventEnvelope) async {
        guard let taskID = event.taskId else {
            return
        }
        let progress = event.payload.objectValue["progress"]?.stringValue ?? "progress"

        let projects = await store.listProjects()
        for project in projects {
            guard project.tasks.contains(where: { $0.id == taskID }) else {
                continue
            }
            let agentID = event.payload.objectValue["agentId"]?.stringValue
            await recordTaskWorkerHeartbeat(
                projectID: project.id,
                taskID: taskID,
                workerID: event.workerId,
                agentID: agentID,
                status: progress == "waiting_for_route" ? .waitingInput : .running,
                message: progress,
                metadata: [
                    "source": MessageType.workerProgress.rawValue,
                    "channelId": event.channelId
                ],
                updatedAt: event.ts
            )

            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: taskID,
                stage: "worker_progress",
                channelID: event.channelId,
                workerID: event.workerId,
                message: progress
            )
            logger.info(
                "visor.task.progress",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(taskID),
                    "progress": .string(progress)
                ]
            )
            return
        }
    }


    func summarizedTaskTitle(from value: String) -> String {
        let normalized = normalizeWhitespace(value)
        if normalized.isEmpty {
            return "Visor task"
        }

        let separators = CharacterSet(charactersIn: "\n.;:")
        if let splitRange = normalized.rangeOfCharacter(from: separators) {
            let prefix = normalizeWhitespace(String(normalized[..<splitRange.lowerBound]))
            if prefix.count >= 6 {
                return String(prefix.prefix(120))
            }
        }

        return String(normalized.prefix(120))
    }

    func cancelProjectTask(projectID: String, taskID: String, reason: String?) async throws -> ProjectRecord {
        let note = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2_000)
        let normalizedNote = note.map(String.init)
        let update = ProjectTaskUpdateRequest(status: ProjectTaskStatus.cancelled.rawValue)
        _ = try await updateProjectTask(projectID: projectID, taskID: taskID, request: update)

        guard let normalizedProject = normalizedProjectID(projectID),
              var storedProject = await store.project(id: normalizedProject)
        else {
            throw ProjectError.notFound
        }
        guard let index = storedProject.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw ProjectError.notFound
        }

        var task = storedProject.tasks[index]
        if let normalizedNote, !normalizedNote.isEmpty {
            let line = "Cancelled: \(normalizedNote)"
            if task.description.isEmpty {
                task.description = line
            } else {
                task.description += "\n\n\(line)"
            }
        }
        task.updatedAt = Date()
        storedProject.tasks[index] = task
        storedProject.updatedAt = Date()
        await store.saveProject(storedProject)
        return storedProject
    }

    func runAgentTask(
        agentID: String,
        taskID: String,
        objective: String,
        workingDirectory: String?,
        selectedModel: String? = nil,
        explicitToolIDs: [String]? = nil
    ) async -> String? {
        await runAgentTaskResult(
            agentID: agentID,
            taskID: taskID,
            objective: objective,
            workingDirectory: workingDirectory,
            selectedModel: selectedModel,
            explicitToolIDs: explicitToolIDs
        )?.text
    }

    func runAgentTaskResult(
        agentID: String,
        taskID: String,
        objective: String,
        workingDirectory: String?,
        selectedModel: String? = nil,
        explicitToolIDs: [String]? = nil
    ) async -> AgentTaskRunResult? {
        let autopilotContext = await autopilotWorkerContext(taskID: taskID)
        return await runSubagentTaskResult(
            agentID: agentID,
            taskID: taskID,
            objective: objective,
            workingDirectory: workingDirectory,
            toolsetNames: autopilotContext?.toolsets,
            selectedModel: selectedModel,
            bypassToolApproval: autopilotContext?.bypassToolApproval == true,
            explicitToolIDs: explicitToolIDs
        )
    }

    /// Runs a one-shot agent session with optional toolset restriction and subagent deny rules.
    func runSubagentTask(
        agentID: String,
        taskID: String,
        objective: String,
        workingDirectory: String?,
        toolsetNames: [String]?,
        selectedModel: String? = nil,
        parentSessionID: String? = nil,
        bypassToolApproval: Bool = false,
        explicitToolIDs: [String]? = nil
    ) async -> String? {
        await runSubagentTaskResult(
            agentID: agentID,
            taskID: taskID,
            objective: objective,
            workingDirectory: workingDirectory,
            toolsetNames: toolsetNames,
            selectedModel: selectedModel,
            parentSessionID: parentSessionID,
            bypassToolApproval: bypassToolApproval,
            explicitToolIDs: explicitToolIDs
        )?.text
    }

    /// Runs a one-shot agent session and preserves typed completion metadata for worker events.
    func runSubagentTaskResult(
        agentID: String,
        taskID: String,
        objective: String,
        workingDirectory: String?,
        toolsetNames: [String]?,
        selectedModel: String? = nil,
        parentSessionID: String? = nil,
        bypassToolApproval: Bool = false,
        explicitToolIDs: [String]? = nil
    ) async -> AgentTaskRunResult? {
        let directProjectID = await projectID(containingTaskID: taskID)
        let executionProjectID = directProjectID ?? parentSessionID.flatMap { projectExecutionSessions[$0]?.projectID }
        let executionGeneration = executionProjectID.map { projectStopGenerations[$0, default: 0] }
        if let executionProjectID,
           await store.project(id: executionProjectID)?.automaticTaskPickupEnabled != true { return nil }
        let knownIDs = await ToolCatalog.knownToolIDs(mcpRegistry: mcpRegistry)
        guard let policy = try? await toolsAuthorization.policy(agentID: agentID) else {
            await recordProjectTaskWorkerLaunchFailure(
                taskID: taskID,
                error: "Could not load tool policy for agent \(agentID)."
            )
            await appendSystemTaskComment(
                taskID: taskID,
                content: "Task flow problem: could not load tool policy for agent \(agentID)."
            )
            logger.warning(
                "task.subagent.policy_failed",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID)]
            )
            return AgentTaskRunResult(text: "[failed] Could not load tool policy for agent \(agentID).\nError: tool policy unavailable", executionOutcome: .init(state: .failed, category: .unavailable, code: "worker_launch_failed"))
        }
        let effectiveTools = SubagentDelegation.effectiveToolIDs(
            policy: policy,
            knownToolIDs: knownIDs,
            toolsetNames: toolsetNames,
            explicitToolIDs: explicitToolIDs
        )
        guard !effectiveTools.isEmpty else {
            await recordProjectTaskWorkerLaunchFailure(
                taskID: taskID,
                error: "Agent \(agentID) has no effective tools available."
            )
            await appendSystemTaskComment(
                taskID: taskID,
                content: "Task flow problem: agent \(agentID) has no effective tools available for this task."
            )
            logger.warning(
                "task.subagent.no_tools",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID)]
            )
            return AgentTaskRunResult(text: "[failed] Agent \(agentID) has no effective tools available.\nError: no tools available", executionOutcome: .init(state: .failed, category: .unavailable, code: "worker_launch_failed"))
        }

        let sessionBaseTitle = "task-\(taskID)"
        let existingSessions = (try? listAgentSessions(agentID: agentID)) ?? []
        let attemptNumber = nextSubagentTaskAttemptNumber(baseTitle: sessionBaseTitle, existingSessions: existingSessions)
        let sessionTitle = "\(sessionBaseTitle)-attempt-\(attemptNumber)"

        let session: AgentSessionSummary
        do {
            session = try await createAgentSession(
                agentID: agentID,
                request: AgentSessionCreateRequest(title: sessionTitle, parentSessionId: parentSessionID)
            )
            await appendSubagentSessionTaskCommentIfNeeded(
                agentID: agentID,
                taskID: taskID,
                session: session,
                attemptNumber: attemptNumber
            )
        } catch {
            await appendSystemTaskComment(
                taskID: taskID,
                content: "Task flow problem: failed to create worker session for agent \(agentID): \(error.localizedDescription)"
            )
            await recordProjectTaskWorkerLaunchFailure(
                taskID: taskID,
                error: "Failed to create worker session for agent \(agentID): \(error.localizedDescription)"
            )
            logger.warning(
                "task.worker.session_create_failed",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID), "error": .string(error.localizedDescription)]
            )
            return AgentTaskRunResult(text: "[failed] Failed to create worker session for agent \(agentID).\nError: \(error.localizedDescription)", executionOutcome: .init(state: .failed, category: .unavailable, code: "worker_launch_failed"))
        }

        if let parentSessionID = parentSessionID.flatMap(normalizedSessionID) {
            let event = AgentSessionEvent(
                agentId: agentID,
                sessionId: parentSessionID,
                type: .subSession,
                subSession: AgentSubSessionEvent(
                    childSessionId: session.id,
                    title: session.title
                )
            )
            _ = try? await appendAgentSessionEvents(
                agentID: agentID,
                sessionID: parentSessionID,
                request: AgentSessionAppendEventsRequest(events: [event])
            )
        }

        let inheritedContext = await subagentToolContext(
            agentID: agentID,
            parentSessionID: parentSessionID,
            fallbackWorkingDirectory: workingDirectory
        )
        if let workingDirectory = inheritedContext.workingDirectory,
           !workingDirectory.isEmpty {
            sessionWorkingDirectories[session.id] = workingDirectory
        }
        if !inheritedContext.extraRoots.isEmpty {
            sessionExtraRoots[session.id] = inheritedContext.extraRoots
        }
        var workerEnvironment = [
            "SLOPPY_KANBAN_TASK": taskID
        ]
        if let projectID = await projectID(containingTaskID: taskID) {
            workerEnvironment["SLOPPY_KANBAN_PROJECT"] = projectID
        }
        sessionEnvironmentOverrides[session.id] = workerEnvironment

        if let executionProjectID {
            registerProjectExecutionSession(sessionID: session.id, projectID: executionProjectID, taskID: taskID, agentID: agentID, generation: executionGeneration)
        }
        defer { projectExecutionSessions.removeValue(forKey: session.id) }
        let channelId = sessionChannelID(agentID: agentID, sessionID: session.id)
        sessionSubagentToolAllowList[session.id] = effectiveTools
        do {
            try sessionMessageInbox().rememberScope(sessionID: session.id, toolIDs: effectiveTools)
        } catch {
            logger.warning("session_messages.worker_scope_unavailable", metadata: ["error": .string(String(describing: error))])
        }
        if bypassToolApproval {
            sessionToolApprovalBypass.insert(session.id)
        }
        await sessionOrchestrator.markDelegatedSubagentSession(sessionID: session.id)
        await runtime.setChannelToolAllowList(channelId: channelId, toolIDs: effectiveTools)

        let response: AgentSessionMessageResponse
        do {
            response = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: "system_task_worker",
                    content: delegatedTaskObjective(objective),
                    selectedModel: {
                        let t = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return t.isEmpty ? nil : t
                    }()
                )
            )
        } catch {
            await appendSystemTaskComment(
                taskID: taskID,
                content: "Task flow problem: failed to start worker session for agent \(agentID): \(error.localizedDescription)"
            )
            await recordProjectTaskWorkerLaunchFailure(
                taskID: taskID,
                error: "Failed to start worker session for agent \(agentID): \(error.localizedDescription)"
            )
            logger.warning(
                "task.worker.session_post_failed",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID), "error": .string(error.localizedDescription)]
            )
            sessionSubagentToolAllowList.removeValue(forKey: session.id)
            sessionEnvironmentOverrides.removeValue(forKey: session.id)
            sessionToolApprovalBypass.remove(session.id)
            await sessionOrchestrator.unmarkDelegatedSubagentSession(sessionID: session.id)
            await runtime.clearChannelToolAllowList(channelId: channelId)
            await runtime.invalidateChannelSession(channelId: channelId)
            return AgentTaskRunResult(text: "[failed] Failed to start worker session for agent \(agentID).\nError: \(error.localizedDescription)", executionOutcome: .init(state: .failed, category: .unavailable, code: "worker_launch_failed"))
        }

        let detail = try? getAgentSession(agentID: agentID, sessionID: session.id)
        var resultEvents = detail?.events ?? response.appendedEvents
        if latestDelegateFinishOutcome(from: resultEvents) == nil {
            resultEvents = await attemptDelegatedTaskFinishRescueIfNeeded(
                agentID: agentID,
                session: session,
                taskID: taskID,
                currentEvents: resultEvents,
                selectedModel: selectedModel
            ) ?? resultEvents
        }
        if latestDelegateFinishOutcome(from: resultEvents) == nil,
           let syntheticFinish = syntheticDelegateFinishEvent(
               agentID: agentID,
               sessionID: session.id,
               from: resultEvents
           ) {
            _ = try? await appendAgentSessionEvents(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionAppendEventsRequest(events: [syntheticFinish])
            )
            resultEvents.append(syntheticFinish)
        }
        let outcome = delegatedTaskFinishOutcome(from: resultEvents) ?? fallbackDelegatedTaskFinishOutcome()
        let text = delegatedTaskResultText(from: outcome)
        await blockAutopilotTaskForSyntheticDelegatedFailureIfNeeded(
            taskID: taskID,
            resultText: text,
            outcome: outcome
        )
        sessionSubagentToolAllowList.removeValue(forKey: session.id)
        sessionEnvironmentOverrides.removeValue(forKey: session.id)
        sessionToolApprovalBypass.remove(session.id)
        await sessionOrchestrator.unmarkDelegatedSubagentSession(sessionID: session.id)
        await runtime.clearChannelToolAllowList(channelId: channelId)
        await runtime.invalidateChannelSession(channelId: channelId)
        return AgentTaskRunResult(
            text: text,
            payload: delegatedTaskWorkerPayload(from: outcome),
            executionOutcome: {
                if let latest = resultEvents.reversed().compactMap({ $0.runStatus }).first {
                    if let terminal = latest.executionOutcome, terminal.state != .completed { return terminal }
                    if latest.stage == .paused { return .init(state: .waitingInput) }
                }
                return Self.delegateExecutionOutcome(status: outcome.status)
            }()
        )
    }

    private func attemptDelegatedTaskFinishRescueIfNeeded(
        agentID: String,
        session: AgentSessionSummary,
        taskID: String,
        currentEvents: [AgentSessionEvent],
        selectedModel: String?
    ) async -> [AgentSessionEvent]? {
        guard latestDelegateFinishOutcome(from: currentEvents) == nil else {
            return currentEvents
        }
        let latestRunStatus = currentEvents.reversed().compactMap(\.runStatus).first
        if latestRunStatus?.stage == .paused {
            return nil
        }

        let rescuePrompt = """
        [Delegated task finalization required]
        Your previous turn produced a response but did not close the delegated worker protocol.

        Do not continue implementation or analysis. Close the worker now:
        1. If task `\(taskID)` is complete and not already marked done, call `project.task_update` with status=`done`, completionConfidence=`done`, and concrete completionNote evidence.
        2. Then call `agent_delegate.finish` as your final tool call.
        3. If the task is not complete or you cannot provide evidence, call `agent_delegate.finish` with status=`blocked` or `failed` and explain why.

        Do not answer in plain text only. The worker flow is incomplete until `agent_delegate.finish` is called.
        """

        do {
            _ = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: "system_task_worker",
                    content: rescuePrompt,
                    selectedModel: {
                        let t = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return t.isEmpty ? nil : t
                    }()
                )
            )
            let detail = try? getAgentSession(agentID: agentID, sessionID: session.id)
            return detail?.events
        } catch {
            logger.warning(
                "task.worker.finalizer_rescue_failed",
                metadata: [
                    "agent_id": .string(agentID),
                    "task_id": .string(taskID),
                    "session_id": .string(session.id),
                    "error": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    static func delegateExecutionOutcome(status: String) -> ExecutionOutcome {
        switch status {
        case "completed": return .completed
        case "waiting_input": return .init(state: .waitingInput)
        case "cancelled": return .init(state: .cancelled)
        default: return .init(state: .failed, category: .tool, code: "delegate_" + status)
        }
    }

    struct AgentTaskRunResult: Sendable {
        var text: String
        var payload: [String: JSONValue]
        var executionOutcome: ExecutionOutcome

        init(text: String, payload: [String: JSONValue] = [:], executionOutcome: ExecutionOutcome = .completed) {
            self.text = text
            self.payload = payload
            self.executionOutcome = executionOutcome
        }
    }

    private struct AutopilotWorkerContext {
        var toolsets: [String]
        var bypassToolApproval: Bool
    }

    private func autopilotWorkerContext(taskID: String) async -> AutopilotWorkerContext? {
        let projects = await store.listProjects()
        for project in projects {
            guard let task = project.tasks.first(where: { $0.id == taskID }),
                  project.autopilotSettings.enabled,
                  isAutopilotManagedTask(project: project, task: task)
            else {
                continue
            }
            return AutopilotWorkerContext(
                toolsets: subagentToolsets(forWorkerTools: workerToolsForTask(task: task, project: project)),
                bypassToolApproval: true
            )
        }
        return nil
    }

    private func blockAutopilotTaskForSyntheticDelegatedFailureIfNeeded(
        taskID: String,
        resultText: String,
        outcome: DelegatedTaskFinishOutcome
    ) async {
        guard outcome.synthetic,
              outcome.status == "failed"
        else {
            return
        }

        for project in await store.listProjects() {
            guard let task = project.tasks.first(where: { $0.id == taskID }),
                  project.autopilotSettings.enabled,
                  isAutopilotManagedTask(project: project, task: task),
                  task.status != ProjectTaskStatus.done.rawValue,
                  task.status != ProjectTaskStatus.cancelled.rawValue
            else {
                continue
            }

            await blockAutopilotTask(
                project: project,
                taskID: task.id,
                message: "Delegated subagent failed to finish task \(task.id).\n\n\(resultText)"
            )
            return
        }
    }

    private func subagentToolsets(forWorkerTools workerTools: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for rawTool in workerTools {
            let tool = rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let mapped: String?
            switch tool {
            case "shell", "exec", "terminal":
                mapped = "terminal"
            case "file", "files.list", "files.read", "files.write", "files.edit":
                mapped = "file"
            case "web", "web.search", "web.fetch":
                mapped = "web"
            case "browser",
                 "browser.open",
                 "browser.navigate",
                 "browser.click",
                 "browser.type",
                 "browser.screenshot",
                 "browser.status",
                 "browser.read",
                 "browser.scroll",
                 "browser.close":
                mapped = "browser"
            case "project_tasks", "project-tasks", "tasks", "task":
                mapped = "project_tasks"
            case "project":
                mapped = "project"
            default:
                mapped = nil
            }
            guard let mapped, seen.insert(mapped).inserted else {
                continue
            }
            result.append(mapped)
        }
        return result
    }

    func appendSubagentSessionTaskCommentIfNeeded(
        agentID: String,
        taskID: String,
        session: AgentSessionSummary,
        attemptNumber: Int? = nil
    ) async {
        let projects = await store.listProjects()
        guard let project = projects.first(where: { project in
            project.tasks.contains(where: { $0.id == taskID })
        }) else {
            return
        }

        let sessionURL = "/agents/\(dashboardPathComponent(agentID))/chat/\(dashboardPathComponent(session.id))"
        let sessionName = session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? session.id
            : session.title
        _ = await addTaskComment(
            projectID: project.id,
            taskID: taskID,
            request: TaskCommentCreateRequest(
                content: "Task delegated to subagent \(attemptNumber.map { "attempt \($0) " } ?? "")session [\(sessionName)](\(sessionURL)).",
                authorActorId: "system",
                kind: .technical
            )
        )
    }

    func nextSubagentTaskAttemptNumber(baseTitle: String, existingSessions: [AgentSessionSummary]) -> Int {
        var maxAttempt = 0
        for session in existingSessions {
            if session.title == baseTitle {
                maxAttempt = max(maxAttempt, 1)
                continue
            }

            let prefix = "\(baseTitle)-attempt-"
            guard session.title.hasPrefix(prefix),
                  let attempt = Int(session.title.dropFirst(prefix.count))
            else {
                continue
            }
            maxAttempt = max(maxAttempt, attempt)
        }
        return maxAttempt + 1
    }

    func subagentToolContext(
        agentID: String,
        parentSessionID: String?,
        fallbackWorkingDirectory: String?
    ) async -> (workingDirectory: String?, extraRoots: [String]) {
        var workingDirectory: String?
        var roots: [String] = []

        if let parentSessionID = parentSessionID.flatMap(normalizedSessionID) {
            if let parentRoots = sessionExtraRoots[parentSessionID] {
                workingDirectory = sessionWorkingDirectories[parentSessionID]
                roots = parentRoots
            } else if let detail = try? getAgentSession(agentID: agentID, sessionID: parentSessionID) {
                let parentContext = await toolContextForSession(
                    sessionID: parentSessionID,
                    sessionTitle: detail.summary.title,
                    projectID: detail.summary.projectId
                )
                workingDirectory = parentContext.workingDirectory
                roots = parentContext.extraRoots
            }
        }

        if let fallback = fallbackWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            let normalizedFallback = URL(fileURLWithPath: fallback, isDirectory: true).standardizedFileURL.path
            if workingDirectory == nil {
                workingDirectory = normalizedFallback
            }
            roots = appendingUniqueRoots(
                sessionToolRoots(forWorkingDirectory: normalizedFallback),
                to: roots
            )
        }

        return (workingDirectory, roots)
    }

    private func delegatedTaskObjective(_ objective: String) -> String {
        """
        [Delegated task protocol]
        You are running as an isolated delegated subagent. When the assigned goal is complete, blocked, or failed, call `agent_delegate.finish` as your final step.
        - Use `status: "completed"` only when you have completed the task and can summarize evidence.
        - Use `status: "failed"` when an error prevents completion.
        - Use `status: "blocked"` when required information, permissions, or tools are missing.
        - Include a concise `summary`; include `error` for failed or blocked outcomes.
        - If any tool returns `tool_budget_exhausted`, stop calling non-finalizer tools and immediately call `agent_delegate.finish` with completed, blocked, or failed based on the evidence already collected.
        Do not delegate again and do not finish with only a plain text promise.

        \(objective)
        """
    }

    private struct DelegatedTaskFinishOutcome: Sendable {
        var status: String
        var summary: String
        var error: String?
        var synthetic: Bool
    }

    func delegatedTaskResultText(from events: [AgentSessionEvent]) -> String {
        delegatedTaskFinishOutcome(from: events)
            .map(delegatedTaskResultText(from:))
            ?? delegatedTaskResultText(from: fallbackDelegatedTaskFinishOutcome())
    }

    private func delegatedTaskResultText(from outcome: DelegatedTaskFinishOutcome) -> String {
        if let error = outcome.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return "[\(outcome.status)] \(outcome.summary)\nError: \(error)"
        }
        return "[\(outcome.status)] \(outcome.summary)"
    }

    private func delegatedTaskWorkerPayload(from outcome: DelegatedTaskFinishOutcome) -> [String: JSONValue] {
        guard outcome.status == "completed",
              !outcome.synthetic
        else {
            return [:]
        }

        return [
            "delegateFinish": .object([
                "finished": .bool(true),
                "status": .string(outcome.status),
                "summary": .string(outcome.summary),
                "error": outcome.error.map(JSONValue.string) ?? .null,
                "synthetic": .bool(outcome.synthetic),
            ]),
        ]
    }

    private func delegatedTaskFinishOutcome(from events: [AgentSessionEvent]) -> DelegatedTaskFinishOutcome? {
        latestDelegateFinishOutcome(from: events) ?? syntheticDelegateFinishOutcome(from: events)
    }

    private func fallbackDelegatedTaskFinishOutcome() -> DelegatedTaskFinishOutcome {
        DelegatedTaskFinishOutcome(
            status: "failed",
            summary: "Delegated subagent ended before calling `agent_delegate.finish`.",
            error: "The subagent ended without a structured delegated-task result.",
            synthetic: true
        )
    }

    private func latestDelegateFinishOutcome(from events: [AgentSessionEvent]) -> DelegatedTaskFinishOutcome? {
        for event in events.reversed() {
            guard event.type == .toolResult,
                  let result = event.toolResult,
                  result.ok,
                  result.tool == "agent_delegate.finish" || result.tool == "agents.delegate_finish",
                  let data = result.data?.asObject,
                  data["finished"]?.asBool == true,
                  let status = data["status"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let summary = data["summary"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty,
                  !summary.isEmpty
            else {
                continue
            }

            let error = data["error"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DelegatedTaskFinishOutcome(
                status: status,
                summary: summary,
                error: error,
                synthetic: data["synthetic"]?.asBool == true
            )
        }
        return nil
    }

    private func syntheticDelegateFinishEvent(
        agentID: String,
        sessionID: String,
        from events: [AgentSessionEvent]
    ) -> AgentSessionEvent? {
        guard let outcome = syntheticDelegateFinishOutcome(from: events) else {
            return nil
        }
        return AgentSessionEvent(
            agentId: agentID,
            sessionId: sessionID,
            type: .toolResult,
            toolResult: AgentToolResultEvent(
                tool: "agent_delegate.finish",
                ok: true,
                data: .object([
                    "finished": .bool(true),
                    "status": .string("failed"),
                    "summary": .string(outcome.summary),
                    "error": .string(outcome.error ?? "The subagent ended without a structured delegated-task result."),
                    "synthetic": .bool(true),
                ])
            )
        )
    }

    private func syntheticDelegateFinishOutcome(from events: [AgentSessionEvent]) -> DelegatedTaskFinishOutcome? {
        guard let status = events.reversed().compactMap(\.runStatus).first(where: {
            $0.stage == .done || $0.stage == .interrupted
        }) else {
            return nil
        }

        switch status.stage {
        case .interrupted:
            return DelegatedTaskFinishOutcome(
                status: "failed",
                summary: "Delegated subagent ended before calling `agent_delegate.finish`.",
                error: syntheticDelegateFinishError(from: events, status: status),
                synthetic: true
            )
        case .done:
            return DelegatedTaskFinishOutcome(
                status: "failed",
                summary: "Delegated subagent completed without calling `agent_delegate.finish`.",
                error: syntheticDelegateFinishError(from: events, status: status),
                synthetic: true
            )
        default:
            return nil
        }
    }

    private func syntheticDelegateFinishError(
        from events: [AgentSessionEvent],
        status: AgentRunStatusEvent
    ) -> String {
        if events.contains(where: { event in
            event.toolResult?.error?.code == "tool_budget_exhausted"
        }) {
            return "The delegated subagent hit `tool_budget_exhausted` before calling `agent_delegate.finish`."
        }

        let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let details,
           !details.isEmpty,
           details != "Response is ready." {
            return details
        }

        if status.stage == .interrupted {
            return "The delegated subagent run was interrupted before calling `agent_delegate.finish`."
        }

        return "The subagent ended without a structured delegated-task result."
    }

    private func appendingUniqueRoots(_ additions: [String], to existing: [String]) -> [String] {
        var result = existing
        for root in additions {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
            if !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    func createOrReclaimWorktree(
        repoPath: String,
        taskId: String,
        worktreeRootPath: String,
        provider: any SourceControlProvider
    ) async throws -> SourceControlWorktreeResult {
        do {
            return try await provider.createWorktree(
                repoPath: repoPath,
                taskId: taskId,
                baseBranch: "HEAD",
                worktreeRootPath: worktreeRootPath
            )
        } catch GitWorktreeError.worktreeAlreadyExists(let existingPath) {
            guard try await !launches.retainsCheckout(existingPath) else {
                throw LaunchRunService.Failure.unavailable("This worktree is retained by a chat launch configuration. Remove the configuration before recreating it.")
            }
            try? await provider.removeWorktree(repoPath: repoPath, worktreePath: existingPath)
            return try await provider.createWorktree(
                repoPath: repoPath,
                taskId: taskId,
                baseBranch: "HEAD",
                worktreeRootPath: worktreeRootPath
            )
        }
    }

    func buildWorkerObjective(task: ProjectTask, project: ProjectRecord, worktreePath: String? = nil) -> String {
        var sections: [String] = []

        // --- Task ---
        var taskLines: [String] = [
            "[Task]",
            "ID: \(task.id)",
            "Title: \(task.title)",
            "Priority: \(task.priority)",
            "Kind: \(task.kind?.rawValue ?? "execution")"
        ]
        if !task.description.isEmpty {
            taskLines.append("")
            taskLines.append(task.description)
        }
        sections.append(taskLines.joined(separator: "\n"))

        if isAutopilotManagedTask(project: project, task: task) {
            var autopilotLines: [String] = ["[Autopilot]"]
            if let parentTaskId = task.parentTaskId,
               let parent = project.tasks.first(where: { $0.id == parentTaskId }) {
                autopilotLines.append("Parent objective: \(parent.title)")
                if !parent.description.isEmpty {
                    autopilotLines.append("Parent details: \(parent.description)")
                }
            }
            if !task.dependsOnTaskIds.isEmpty {
                autopilotLines.append("Dependency context:")
                for dependencyID in task.dependsOnTaskIds {
                    if let dependency = project.tasks.first(where: { $0.id == dependencyID }) {
                        autopilotLines.append("- \(dependency.id): \(dependency.title) [\(dependency.status)]")
                    } else {
                        autopilotLines.append("- \(dependencyID): missing")
                    }
                }
            }
            let settings = project.autopilotSettings
            autopilotLines.append("Allowed permissions: web=\(settings.canUseWeb), editFiles=\(settings.canEditFiles), runCommands=\(settings.canRunCommands), localhost=\(settings.canStartLocalhost), commit=\(settings.canCommit), push=\(settings.canPush)")
            autopilotLines.append("Before marking done, provide explicit completion evidence in completionNote.")
            if settings.canStartLocalhost {
                autopilotLines.append("If a localhost server is started, include its URL in your report.")
            }
            sections.append(autopilotLines.joined(separator: "\n"))
        }

        // --- Project context ---
        var projectLines: [String] = [
            "[Project]",
            "ID: \(project.id)",
            "Name: \(project.name)"
        ]
        if let repoPath = project.repoPath, !repoPath.isEmpty {
            projectLines.append("Repository: \(repoPath)")
        }
        if !project.description.isEmpty {
            projectLines.append("Description: \(project.description)")
        }
        sections.append(projectLines.joined(separator: "\n"))

        // --- Workspace ---
        var workspaceLines: [String] = ["[Workspace]"]
        if let worktreePath {
            let repoRoot = URL(fileURLWithPath: worktreePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            workspaceLines.append("Working directory: \(worktreePath)")
            workspaceLines.append("Repository root: \(repoRoot)")
            workspaceLines.append("All code changes MUST be made inside this worktree.")
            workspaceLines.append("Commit changes to the worktree branch before completing the task.")
        } else if let repoPath = project.repoPath, !repoPath.isEmpty {
            workspaceLines.append("Working directory: \(repoPath)")
        }
        sections.append(workspaceLines.joined(separator: "\n"))

        // --- Task lifecycle ---
        sections.append("""
        [Task lifecycle]
        Tasks move through these statuses:
        backlog → ready → in_progress → done
        At any point a task can transition to: waiting_input, blocked, needs_review, cancelled.
        - Your task is now in_progress. The system will NOT mark it done automatically.
        - When the task is truly complete, call `project.task_update` with status=`done`, completionConfidence=`done`, and a brief completionNote.
        - If you are missing user input, use the clarification flow below so the task becomes waiting_input.
        - If you are blocked by missing access, dependencies, or an external issue you cannot resolve, call `project.task_update` with status=`blocked`.
        - To update the task status or metadata, use tool `project.task_update`.
        - To create sub-tasks, use tool `project.task_create` with the same project ID.
        - Task reports are shared with the user. In completionNote and final artifacts, state the concrete outcome, evidence links (PR/files/artifacts), checks actually run and their results, and any remaining work. Do not claim checks you did not run.
        - For blocked tasks, include a completionNote explaining the blocker and the specific action needed from the user. Keep heartbeat, retry, delegation, and session status updates in the execution log.
        """)

        // --- Clarification flow ---
        sections.append("""
        [Clarification flow]
        When you need information from the user before proceeding:
        1. Call tool `project.task_clarification_create` with taskId="\(task.id)" and your question.
           You may include structured options (id + label) and/or allow freeform notes.
        2. After calling the tool, STOP and wait. Do NOT continue working on the task.
           The system will set the task to waiting_input and notify the user.
        3. When the user answers, the system resumes your session with their response.
           You will receive the answer as a follow-up message. Then continue working.
        Ask all related questions in a single clarification call when possible.
        """)

        // --- Mode-specific instructions ---
        if task.kind == .planning {
            sections.append("""
            [Planning mode]
            You are in PLANNING mode. Your goal is to produce a plan, not code.
            1. Read and analyze the task requirements and the project codebase.
            2. If anything is unclear, use the clarification flow above to ask the user.
            3. Produce a structured implementation plan: break the work into concrete sub-tasks.
            4. Create each sub-task via `project.task_create` with kind=execution and status=backlog.
            5. When the plan is complete, summarize what you created and finish.
            Do NOT write implementation code in planning mode.
            """)
        } else if task.kind == .execution || task.kind == nil {
            sections.append("""
            [Execution mode]
            You are in EXECUTION mode. Your goal is to implement the requested changes.
            1. Analyze the task description and explore the relevant parts of the codebase.
            2. If the requirements are ambiguous, use the clarification flow above to ask the user.
            3. Implement the changes: write code, create files, run commands as needed.
            4. Verify your work compiles/passes and meets the task requirements.
            5. If the task is large, break it into logical commits with clear messages.
            Produce working, tested code. Prefer minimal, focused changes over broad rewrites.
            """)
        } else if task.kind == .bugfix {
            sections.append("""
            [Bugfix mode]
            Focus on identifying and fixing the reported issue.
            1. Reproduce or locate the bug in the codebase.
            2. If the bug description is ambiguous, use the clarification flow to ask the user.
            3. Implement the minimal fix and verify it does not introduce regressions.
            """)
        }

        return normalizeTaskDescription(sections.joined(separator: "\n\n"))
    }


    func appendTaskLifecycleLog(
        projectID: String,
        taskID: String,
        stage: String,
        channelID: String?,
        workerID: String?,
        message: String,
        actorID: String? = nil,
        agentID: String? = nil,
        artifactPath: String? = nil
    ) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let logURL = projectTaskLogFileURL(projectID: projectID, taskID: taskID)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeStage = normalizeWhitespace(stage)
        let safeMessage = normalizeWhitespace(message)

        var line = "[\(timestamp)] stage=\(safeStage)"
        line += " task=\(taskID)"
        if let channelID, !channelID.isEmpty {
            line += " channel=\(channelID)"
        }
        if let workerID, !workerID.isEmpty {
            line += " worker=\(workerID)"
        }
        if let actorID, !actorID.isEmpty {
            line += " actor=\(actorID)"
        }
        if let agentID, !agentID.isEmpty {
            line += " agent=\(agentID)"
        }
        if let artifactPath, !artifactPath.isEmpty {
            line += " artifact=\(artifactPath)"
        }
        line += " message=\(safeMessage)\n"

        let payload = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                try handle.close()
                return
            } catch {
                logger.warning(
                    "visor.task.log_append_failed",
                    metadata: [
                        "project_id": .string(projectID),
                        "task_id": .string(taskID),
                        "path": .string(logURL.path)
                    ]
                )
            }
        }

        do {
            try payload.write(to: logURL, options: .atomic)
        } catch {
            logger.warning(
                "visor.task.log_write_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "task_id": .string(taskID),
                    "path": .string(logURL.path)
                ]
            )
        }
    }

    func persistWorkerArtifactForProjectTask(
        projectID: String,
        taskID: String,
        event: EventEnvelope
    ) async -> String? {
        guard let artifactID = event.payload.objectValue["artifactId"]?.stringValue,
              !artifactID.isEmpty
        else {
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_missing_id",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Worker completed without artifactId."
            )
            return nil
        }

        let artifactContent: String?
        if let runtimeArtifact = await runtime.artifactContent(id: artifactID) {
            artifactContent = runtimeArtifact
            await store.persistArtifact(id: artifactID, content: runtimeArtifact)
        } else {
            artifactContent = await store.artifactContent(id: artifactID)
        }

        guard let artifactContent, !artifactContent.isEmpty else {
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_missing_content",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Artifact payload not found for id \(artifactID)."
            )
            return nil
        }

        let referencedPath: String? = extractCreatedFilePath(from: artifactContent).flatMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return relativePathFromWorkspace(url)
        }

        _ = await addTaskComment(
            projectID: projectID,
            taskID: taskID,
            request: TaskCommentCreateRequest(content: artifactContent, authorActorId: "system", kind: .result)
        )

        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: taskID,
            stage: "artifact_persisted",
            channelID: event.channelId,
            workerID: event.workerId,
            message: "Worker artifact stored as task comment.",
            artifactPath: referencedPath
        )
        return referencedPath ?? artifactID
    }

    func extractCreatedFilePath(from content: String) -> String? {
        if let value = captureGroup(
            content,
            pattern: #"(?im)^Created file at\s+(.+?)\s*$"#
        ) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func ensureProjectWorkspaceDirectory(projectID: String) {
        let directories = [
            projectDirectoryURL(projectID: projectID),
            projectMetaDirectoryURL(projectID: projectID)
        ]
        do {
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            logger.warning(
                "visor.project.directory_create_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "path": .string(projectDirectoryURL(projectID: projectID).path)
                ]
            )
        }
    }

    func legacyProjectSourceSymlinkURL(projectID: String) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("source", isDirectory: true)
    }

    func normalizedExternalProjectPath(_ rawPath: String?) throws -> String? {
        guard let rawPath else {
            return nil
        }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidateURL: URL
        if trimmed.hasPrefix("file://") {
            guard let parsed = URL(string: trimmed),
                  parsed.isFileURL,
                  parsed.host == nil || parsed.host == "" || parsed.host == "localhost",
                  !parsed.path.isEmpty
            else {
                throw ProjectError.invalidPayload
            }
            candidateURL = parsed
        } else {
            guard trimmed.hasPrefix("/") else {
                throw ProjectError.invalidPayload
            }
            let directURL = URL(fileURLWithPath: trimmed, isDirectory: true)
            if trimmed.hasPrefix("/projects/"), !FileManager.default.fileExists(atPath: directURL.path) {
                let projectsRoot = workspaceRootURL.appendingPathComponent("projects", isDirectory: true)
                let relative = String(trimmed.dropFirst("/projects/".count))
                let workspaceURL = projectsRoot.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
                guard isProjectURL(workspaceURL, inside: projectsRoot) else { throw ProjectError.invalidPayload }
                candidateURL = workspaceURL
            } else {
                candidateURL = directURL
            }
        }

        let normalizedURL = candidateURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        guard normalizedPath.hasPrefix("/") else {
            throw ProjectError.invalidPayload
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectError.invalidPayload
        }

        return normalizedPath
    }

    func prepareExternalProjectWorkspace(projectID: String) throws {
        ensureProjectWorkspaceDirectory(projectID: projectID)

        let fileManager = FileManager.default
        let sourceLinkURL = legacyProjectSourceSymlinkURL(projectID: projectID)
        if (try? fileManager.destinationOfSymbolicLink(atPath: sourceLinkURL.path)) != nil {
            try fileManager.removeItem(at: sourceLinkURL)
        }
    }

    /// Clones `repoUrl` into the project workspace directory. Returns `true` only when `git clone` exits successfully.
    func cloneProjectRepository(repoUrl: String, projectID: String, projectDisplayName: String) async -> Bool {
        let trimmedUrl = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrLogMax = 12_000

        func clipStderr(_ raw: String) -> String {
            if raw.count <= stderrLogMax { return raw }
            return String(raw.prefix(stderrLogMax)) + "…(truncated)"
        }

        guard trimmedUrl.hasPrefix("https://") || trimmedUrl.hasPrefix("git@") || trimmedUrl.hasPrefix("http://") else {
            logger.error(
                "project.clone.invalid_url",
                metadata: ["project_id": .string(projectID), "repo_url": .string(trimmedUrl)]
            )
            ensureProjectWorkspaceDirectory(projectID: projectID)
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but the URL is not supported for cloning (use https://, http://, or git@)."
            )
            return false
        }

        let cloneUrl = authorizedCloneURL(for: trimmedUrl)

        let projectDir = projectDirectoryURL(projectID: projectID)
        let parentDir = projectDir.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "project.clone.parent_dir_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "path": .string(parentDir.path),
                    "error": .string(error.localizedDescription)
                ]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "clone", "--recurse-submodules", cloneUrl, projectDir.path]
        process.currentDirectoryURL = parentDir
        process.environment = childProcessEnvironment(overrides: ["GIT_TERMINAL_PROMPT": "0"])

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            logger.error(
                "project.clone.launch_failed",
                metadata: ["project_id": .string(projectID), "error": .string(error.localizedDescription)]
            )
            ensureProjectWorkspaceDirectory(projectID: projectID)
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but git could not be started: \(error.localizedDescription)"
            )
            return false
        }

        let didTimeout = await waitForProcessExitOrTimeout(process: process, timeoutMs: 120_000)

        if didTimeout, process.isRunning {
            await terminateProcess(process)
            let stderrOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            logger.error(
                "project.clone.timeout",
                metadata: [
                    "project_id": .string(projectID),
                    "repo_url": .string(trimmedUrl),
                    "stderr": .string(clipStderr(stderrOutput))
                ]
            )
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but git clone timed out after 120s. See server logs (project.clone.timeout)."
            )
            return false
        }

        if process.terminationStatus != 0 {
            let stderrOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            logger.error(
                "project.clone.failed",
                metadata: [
                    "project_id": .string(projectID),
                    "repo_url": .string(trimmedUrl),
                    "exit_code": .string(String(process.terminationStatus)),
                    "stderr": .string(clipStderr(stderrOutput))
                ]
            )
            let hint = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
            let suffix = hint.isEmpty ? "" : " Output: \(hint)"
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but git clone failed (exit \(process.terminationStatus)).\(suffix)"
            )
            return false
        }

        logger.info(
            "project.clone.success",
            metadata: ["project_id": .string(projectID), "repo_url": .string(trimmedUrl)]
        )
        return true
    }

    func authorizedCloneURL(for url: String) -> String {
        guard url.hasPrefix("https://") || url.hasPrefix("http://"),
              let token = githubAuthService.currentToken(),
              var components = URLComponents(string: url)
        else {
            return url
        }
        components.user = "x-access-token"
        components.password = token
        return components.string ?? url
    }

}
