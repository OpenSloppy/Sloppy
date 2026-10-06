import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AgentRuntime
import Protocols
import Logging

// MARK: - Swarm

extension CoreService {
    func startSwarmIfHierarchical(
        projectID: String,
        taskID: String,
        delegation: TaskDelegation
    ) async -> Bool {
        guard var project = await store.project(id: projectID),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            return false
        }

        var rootTask = project.tasks[taskIndex]
        guard rootTask.status == ProjectTaskStatus.ready.rawValue,
              pickupRulesPermit(project: project, task: rootTask) else {
            return false
        }
        guard rootTask.swarmTaskId == nil else {
            return false
        }
        let hasExplicitAssignee = (rootTask.actorId != nil || rootTask.teamId != nil || rootTask.claimedActorId != nil)
        guard hasExplicitAssignee else {
            return false
        }

        guard let board = try? getActorBoard() else {
            return false
        }
        let rootActorID = delegation.actorID ?? rootTask.claimedActorId ?? rootTask.actorId ?? ""
        guard !rootActorID.isEmpty else {
            return false
        }

        switch SwarmCoordinator.buildHierarchy(rootActorId: rootActorID, links: board.links, logger: logger) {
        case .noHierarchy:
            return false
        case .cycle:
            await failSwarmRootWithEscalation(
                projectID: projectID,
                rootTaskID: rootTask.id,
                failedTaskID: nil,
                reason: "Swarm hierarchy cycle detected; execution was blocked.",
                executionChannelID: delegation.channelID,
                board: board
            )
            return true
        case .hierarchy(let hierarchy):
            do {
                let plannedSubtasks = try await swarmPlanner.plan(rootTask: rootTask, actorLevels: hierarchy.levels)
                if plannedSubtasks.isEmpty {
                    await failSwarmRootWithEscalation(
                        projectID: projectID,
                        rootTaskID: rootTask.id,
                        failedTaskID: nil,
                        reason: "Swarm planner returned empty subtask plan.",
                        executionChannelID: delegation.channelID,
                        board: board
                    )
                    return true
                }

                let swarmID = UUID().uuidString
                rootTask.claimedActorId = delegation.actorID
                rootTask.claimedAgentId = delegation.agentID
                if let actorID = delegation.actorID {
                    rootTask.actorId = actorID
                }
                rootTask.swarmId = swarmID
                rootTask.swarmTaskId = "root"
                rootTask.swarmParentTaskId = nil
                rootTask.swarmDependencyIds = nil
                rootTask.swarmDepth = 0
                rootTask.swarmActorPath = [rootActorID]
                rootTask.status = ProjectTaskStatus.inProgress.rawValue
                rootTask.updatedAt = Date()
                project.tasks[taskIndex] = rootTask

                var roundRobinByDepth: [Int: Int] = [:]
                let sortedPlanned = plannedSubtasks.sorted { lhs, rhs in
                    if lhs.depth == rhs.depth {
                        return lhs.swarmTaskId < rhs.swarmTaskId
                    }
                    return lhs.depth < rhs.depth
                }

                for planned in sortedPlanned {
                    guard !hierarchy.levels.isEmpty else { continue }
                    let levelIndex = min(max(planned.depth, 1) - 1, hierarchy.levels.count - 1)
                    let levelActors = hierarchy.levels[levelIndex]
                    guard !levelActors.isEmpty else { continue }

                    let nextIndex = roundRobinByDepth[levelIndex, default: 0]
                    let assignedActorID = levelActors[nextIndex % levelActors.count]
                    roundRobinByDepth[levelIndex] = nextIndex + 1
                    let actorPath = swarmActorPath(
                        rootActorID: hierarchy.rootActorId,
                        targetActorID: assignedActorID,
                        parentByActor: hierarchy.parentByActor
                    )

                    let now = Date()
                    project.tasks.append(
                        ProjectTask(
                            id: UUID().uuidString,
                            title: planned.title,
                            description: normalizeTaskDescription(
                                """
                                Source: swarm-planner
                                Swarm objective: \(planned.objective)
                                """
                            ),
                            priority: rootTask.priority,
                            status: ProjectTaskStatus.ready.rawValue,
                            actorId: assignedActorID,
                            teamId: nil,
                            claimedActorId: nil,
                            claimedAgentId: nil,
                            swarmId: swarmID,
                            swarmTaskId: planned.swarmTaskId,
                            swarmParentTaskId: planned.dependencyIds.first,
                            swarmDependencyIds: planned.dependencyIds,
                            swarmDepth: planned.depth,
                            swarmActorPath: actorPath,
                            createdAt: now,
                            updatedAt: now
                        )
                    )
                }

                project.updatedAt = Date()
                await store.saveProject(project)
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: rootTask.id,
                    stage: "swarm_started",
                    channelID: delegation.channelID,
                    workerID: nil,
                    message: "Swarm started with \(project.tasks.filter { $0.swarmId == swarmID && $0.id != rootTask.id }.count) subtasks.",
                    actorID: delegation.actorID,
                    agentID: delegation.agentID
                )
                await runtime.appendSystemMessage(
                    channelId: delegation.channelID,
                    content: "Swarm \(swarmID) started for task \(rootTask.id)."
                )

                Task {
                    await self.executeSwarm(
                        projectID: projectID,
                        rootTaskID: rootTask.id,
                        swarmID: swarmID,
                        executionChannelID: delegation.channelID,
                        board: board
                    )
                }
                return true
            } catch {
                await failSwarmRootWithEscalation(
                    projectID: projectID,
                    rootTaskID: rootTask.id,
                    failedTaskID: nil,
                    reason: "Swarm planner failed: \(error)",
                    executionChannelID: delegation.channelID,
                    board: board
                )
                return true
            }
        }
    }

    func executeSwarm(
        projectID: String,
        rootTaskID: String,
        swarmID: String,
        executionChannelID: String,
        board: ActorBoardSnapshot
    ) async {
        guard let project = await store.project(id: projectID) else {
            return
        }
        let swarmTasks = project.tasks
            .filter { $0.swarmId == swarmID && $0.id != rootTaskID }
            .sorted { lhs, rhs in
                if lhs.swarmDepth == rhs.swarmDepth {
                    return lhs.createdAt < rhs.createdAt
                }
                return (lhs.swarmDepth ?? .max) < (rhs.swarmDepth ?? .max)
            }

        if swarmTasks.isEmpty {
            await failSwarmRootWithEscalation(
                projectID: projectID,
                rootTaskID: rootTaskID,
                failedTaskID: nil,
                reason: "Swarm has no executable child tasks.",
                executionChannelID: executionChannelID,
                board: board
            )
            return
        }

        var completedSwarmTaskIDs: Set<String> = []
        let byDepth = Dictionary(grouping: swarmTasks, by: { $0.swarmDepth ?? 1 })
        let orderedDepths = byDepth.keys.sorted()

        for depth in orderedDepths {
            let levelTasks = (byDepth[depth] ?? []).sorted { $0.createdAt < $1.createdAt }
            var pendingTasks = levelTasks.filter { task in
                let dependencies = Set(task.swarmDependencyIds ?? [])
                return dependencies.isSubset(of: completedSwarmTaskIDs)
            }
            if pendingTasks.count != levelTasks.count {
                await failSwarmRootWithEscalation(
                    projectID: projectID,
                    rootTaskID: rootTaskID,
                    failedTaskID: nil,
                    reason: "Swarm dependencies are unresolved at level \(depth).",
                    executionChannelID: executionChannelID,
                    board: board
                )
                return
            }

            while !pendingTasks.isEmpty {
                let batch = Array(pendingTasks.prefix(3))
                pendingTasks.removeFirst(min(3, pendingTasks.count))

                for task in batch {
                    await handleTaskBecameReady(projectID: projectID, taskID: task.id)
                }

                let settled = await waitForTasksToSettle(
                    projectID: projectID,
                    taskIDs: batch.map(\.id)
                )
                guard !Task.isCancelled else { return }
                guard settled else {
                    await failSwarmRootWithEscalation(
                        projectID: projectID,
                        rootTaskID: rootTaskID,
                        failedTaskID: batch.first?.id,
                        reason: "Swarm batch stopped before worker completion.",
                        executionChannelID: executionChannelID,
                        board: board
                    )
                    return
                }

                guard let refreshedProject = await store.project(id: projectID) else {
                    return
                }
                for task in batch {
                    guard let refreshed = refreshedProject.tasks.first(where: { $0.id == task.id }) else {
                        continue
                    }
                    if refreshed.status != ProjectTaskStatus.done.rawValue {
                        await failSwarmRootWithEscalation(
                            projectID: projectID,
                            rootTaskID: rootTaskID,
                            failedTaskID: refreshed.id,
                            reason: "Child task \(refreshed.id) finished with status \(refreshed.status).",
                            executionChannelID: executionChannelID,
                            board: board
                        )
                        return
                    }
                    if let swarmTaskId = refreshed.swarmTaskId {
                        completedSwarmTaskIDs.insert(swarmTaskId)
                    }
                }
            }
        }

        await completeSwarmRoot(
            projectID: projectID,
            rootTaskID: rootTaskID,
            swarmID: swarmID,
            executionChannelID: executionChannelID
        )
    }

    func waitForTasksToSettle(
        projectID: String,
        taskIDs: [String]
    ) async -> Bool {
        let runningStatuses = Set([
            ProjectTaskStatus.ready.rawValue,
            ProjectTaskStatus.inProgress.rawValue,
            ProjectTaskStatus.needsReview.rawValue
        ])
        while !Task.isCancelled {
            guard let project = await store.project(id: projectID) else {
                return false
            }

            let statuses: [String] = taskIDs.compactMap { taskID in
                project.tasks.first(where: { $0.id == taskID })?.status
            }
            guard statuses.count == taskIDs.count else {
                return false
            }
            if statuses.allSatisfy({ !runningStatuses.contains($0) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return false
    }

    func completeSwarmRoot(
        projectID: String,
        rootTaskID: String,
        swarmID: String,
        executionChannelID: String
    ) async {
        guard var project = await store.project(id: projectID),
              let rootIndex = project.tasks.firstIndex(where: { $0.id == rootTaskID })
        else {
            return
        }

        let childTasks = project.tasks.filter { $0.swarmId == swarmID && $0.id != rootTaskID }
        let artifactRefs = childTasks.flatMap { task in
            extractArtifactRefs(from: task.description)
        }
        let summaryLine = "Swarm completed \(childTasks.count) subtasks."
        let artifactLine = artifactRefs.isEmpty ? "" : "\nArtifacts: \(artifactRefs.joined(separator: ", "))"

        var rootTask = project.tasks[rootIndex]
        rootTask.status = ProjectTaskStatus.done.rawValue
        rootTask.updatedAt = Date()
        if !summaryLine.isEmpty {
            if rootTask.description.isEmpty {
                rootTask.description = summaryLine + artifactLine
            } else if !rootTask.description.contains(summaryLine) {
                rootTask.description += "\n\n" + summaryLine + artifactLine
            }
        }
        project.tasks[rootIndex] = rootTask
        project.updatedAt = Date()
        await store.saveProject(project)

        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: rootTaskID,
            stage: "swarm_completed",
            channelID: executionChannelID,
            workerID: nil,
            message: summaryLine
        )
        await runtime.appendSystemMessage(
            channelId: executionChannelID,
            content: "\(summaryLine)\(artifactLine)"
        )
        await deliverToChannelPlugin(
            channelId: executionChannelID,
            content: "\(summaryLine)\(artifactLine)"
        )
    }

    func failSwarmRootWithEscalation(
        projectID: String,
        rootTaskID: String,
        failedTaskID: String?,
        reason: String,
        executionChannelID: String,
        board: ActorBoardSnapshot
    ) async {
        guard var project = await store.project(id: projectID),
              let rootIndex = project.tasks.firstIndex(where: { $0.id == rootTaskID })
        else {
            return
        }

        var rootTask = project.tasks[rootIndex]
        rootTask.status = ProjectTaskStatus.blocked.rawValue
        rootTask.updatedAt = Date()
        if rootTask.description.isEmpty {
            rootTask.description = reason
        } else if !rootTask.description.contains(reason) {
            rootTask.description += "\n\n\(reason)"
        }
        project.tasks[rootIndex] = rootTask

        var blockedDownstreamTaskIDs: [String] = []
        if let swarmID = rootTask.swarmId,
           let failedTaskID,
           let failedIndex = project.tasks.firstIndex(where: { $0.id == failedTaskID }),
           let failedSwarmTaskID = project.tasks[failedIndex].swarmTaskId {
            project.tasks[failedIndex] = markSwarmTaskBlocked(
                project.tasks[failedIndex],
                reasonLine: "Swarm failed: \(reason)"
            )

            let swarmChildren = project.tasks.filter { $0.swarmId == swarmID && $0.id != rootTaskID }
            let downstreamSwarmTaskIDs = downstreamSwarmTaskIDs(
                from: failedSwarmTaskID,
                children: swarmChildren
            )
            for downstreamSwarmTaskID in downstreamSwarmTaskIDs {
                guard let index = project.tasks.firstIndex(where: {
                    $0.swarmId == swarmID && $0.swarmTaskId == downstreamSwarmTaskID
                }) else {
                    continue
                }
                var task = project.tasks[index]
                guard task.status != ProjectTaskStatus.done.rawValue,
                      task.status != ProjectTaskStatus.blocked.rawValue,
                      task.status != ProjectTaskStatus.cancelled.rawValue
                else {
                    continue
                }
                task = markSwarmTaskBlocked(
                    task,
                    reasonLine: "Blocked by failed dependency \(failedSwarmTaskID)."
                )
                blockedDownstreamTaskIDs.append(task.id)
                project.tasks[index] = task
            }
        }

        project.updatedAt = Date()
        await store.saveProject(project)
        if let failedTaskID, let fIdx = project.tasks.firstIndex(where: { $0.id == failedTaskID }) {
            await recordSystemStatusChange(projectID: projectID, taskID: failedTaskID, from: project.tasks[fIdx].status, to: ProjectTaskStatus.blocked.rawValue, source: "system")
        }
        for blockedID in blockedDownstreamTaskIDs {
            await recordSystemStatusChange(projectID: projectID, taskID: blockedID, from: "ready", to: ProjectTaskStatus.blocked.rawValue, source: "system")
        }

        let failedTask = failedTaskID.flatMap { id in
            project.tasks.first(where: { $0.id == id })
        }
        let escalationChannelID = resolveSwarmEscalationChannelID(
            failedTask: failedTask,
            board: board,
            fallbackChannelID: executionChannelID
        )
        let artifactRefs = failedTask.map { extractArtifactRefs(from: $0.description) } ?? []
        let message =
            """
            Swarm escalation required.
            Root task: \(rootTaskID)
            Failed child: \(failedTaskID ?? "n/a")
            Reason: \(reason)
            Blocked downstream: \(blockedDownstreamTaskIDs.isEmpty ? "none" : blockedDownstreamTaskIDs.joined(separator: ", "))
            Artifacts: \(artifactRefs.isEmpty ? "none" : artifactRefs.joined(separator: ", "))
            Action: Please review and unblock the task.
            """

        let logMessage: String
        if blockedDownstreamTaskIDs.isEmpty {
            logMessage = reason
        } else {
            logMessage = "\(reason) Downstream blocked: \(blockedDownstreamTaskIDs.count)."
        }

        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: rootTaskID,
            stage: "swarm_blocked",
            channelID: escalationChannelID,
            workerID: nil,
            message: logMessage,
            artifactPath: artifactRefs.first
        )
        await runtime.appendSystemMessage(channelId: escalationChannelID, content: message)
        await deliverToChannelPlugin(channelId: escalationChannelID, content: message)
    }

    func markSwarmTaskBlocked(_ task: ProjectTask, reasonLine: String) -> ProjectTask {
        var task = task
        task.status = ProjectTaskStatus.blocked.rawValue
        task.updatedAt = Date()
        if task.description.isEmpty {
            task.description = reasonLine
        } else if !task.description.contains(reasonLine) {
            task.description += "\n\n\(reasonLine)"
        }
        return task
    }

    func downstreamSwarmTaskIDs(
        from failedSwarmTaskID: String,
        children: [ProjectTask]
    ) -> Set<String> {
        var dependentsByDependency: [String: Set<String>] = [:]
        for task in children {
            guard let swarmTaskID = task.swarmTaskId else {
                continue
            }
            for dependency in task.swarmDependencyIds ?? [] {
                dependentsByDependency[dependency, default: []].insert(swarmTaskID)
            }
        }

        var queue = Array(dependentsByDependency[failedSwarmTaskID] ?? [])
        var visited: Set<String> = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current).inserted else {
                continue
            }
            queue.append(contentsOf: dependentsByDependency[current] ?? [])
        }
        return visited
    }

    func resolveSwarmEscalationChannelID(
        failedTask: ProjectTask?,
        board: ActorBoardSnapshot,
        fallbackChannelID: String
    ) -> String {
        let nodesByID = Dictionary(uniqueKeysWithValues: board.nodes.map { ($0.id, $0) })
        if let actorPath = failedTask?.swarmActorPath {
            for actorID in actorPath.reversed() {
                guard let actor = nodesByID[actorID], actor.kind == .human else {
                    continue
                }
                let channelID = normalizeWhitespace(actor.channelId ?? "")
                if !channelID.isEmpty {
                    return channelID
                }
            }
        }

        if let admin = nodesByID["human:admin"] {
            let channelID = normalizeWhitespace(admin.channelId ?? "")
            if !channelID.isEmpty {
                return channelID
            }
        }

        return fallbackChannelID
    }

    func swarmActorPath(
        rootActorID: String,
        targetActorID: String,
        parentByActor: [String: String]
    ) -> [String] {
        if targetActorID == rootActorID {
            return [rootActorID]
        }

        var path: [String] = [targetActorID]
        var current = targetActorID
        while let parent = parentByActor[current] {
            path.append(parent)
            if parent == rootActorID {
                break
            }
            current = parent
        }
        return path.reversed()
    }

    func extractArtifactRefs(from description: String) -> [String] {
        description
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.lowercased().hasPrefix("artifact: ") else {
                    return nil
                }
                return String(trimmed.dropFirst("Artifact: ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    func resolveTaskDelegation(project: ProjectRecord, task: ProjectTask) async -> TaskDelegation? {
        if let assignments = task.stageAssignments {
            let assigned = task.activeStage == .review ? assignments.reviewer : assignments.developer
            guard assigned != nil else { return nil }
        }
        let board = try? getActorBoard()
        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let routeAllowedActorIDs = routableActorIDs(project: project, task: task, board: board)

        let preferredActors = preferredActorIDs(for: task, board: board)
        for actorID in preferredActors {
            if let routeAllowedActorIDs, !routeAllowedActorIDs.contains(actorID) {
                continue
            }
            guard let node = nodesByID[actorID] else {
                continue
            }

            let channelID = normalizeWhitespace(node.channelId ?? "")
            let resolvedChannelID: String?
            if !channelID.isEmpty {
                resolvedChannelID = channelID
            } else {
                resolvedChannelID = resolveExecutionChannelID(project: project, task: task)
            }

            guard let channel = resolvedChannelID else {
                continue
            }

            return TaskDelegation(
                actorID: actorID,
                agentID: node.linkedAgentId,
                channelID: channel
            )
        }

        if !preferredActors.isEmpty {
            return nil
        }

        if preferredActors.isEmpty,
           let routeAllowedActorIDs,
           !routeAllowedActorIDs.isEmpty {
            for actorID in routeAllowedActorIDs.sorted() {
                guard let node = nodesByID[actorID] else {
                    continue
                }
                let channelID = normalizeWhitespace(node.channelId ?? "")
                let resolvedChannelID: String?
                if !channelID.isEmpty {
                    resolvedChannelID = channelID
                } else {
                    resolvedChannelID = resolveExecutionChannelID(project: project, task: task)
                }

                guard let channel = resolvedChannelID else {
                    continue
                }

                return TaskDelegation(
                    actorID: actorID,
                    agentID: node.linkedAgentId,
                    channelID: channel
                )
            }
        }

        if let firstExecutor = resolveFirstExecutor(project: project, task: task, nodesByID: nodesByID, board: board) {
            return firstExecutor
        }

        if let fallbackChannelID = resolveExecutionChannelID(project: project, task: task) {
            let fallbackChannelActor = nodesByID.values
                .filter { normalizeWhitespace($0.channelId ?? "") == fallbackChannelID }
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first
            return TaskDelegation(
                actorID: fallbackChannelActor?.id,
                agentID: fallbackChannelActor?.linkedAgentId,
                channelID: fallbackChannelID
            )
        }
        return nil
    }

    func resolveFirstExecutor(
        project: ProjectRecord,
        task: ProjectTask,
        nodesByID: [String: ActorNode],
        board: ActorBoardSnapshot?
    ) -> TaskDelegation? {
        guard !nodesByID.isEmpty else { return nil }

        func tryNode(_ node: ActorNode) -> TaskDelegation? {
            guard node.kind == .agent, node.linkedAgentId != nil else { return nil }
            let channelID = normalizeWhitespace(node.channelId ?? "")
            let resolvedChannelID = !channelID.isEmpty
                ? channelID
                : resolveExecutionChannelID(project: project, task: task)
            guard let channel = resolvedChannelID else { return nil }
            return TaskDelegation(actorID: node.id, agentID: node.linkedAgentId, channelID: channel)
        }

        for actorID in project.actors {
            if let node = nodesByID[actorID], let delegation = tryNode(node) {
                return delegation
            }
        }

        for teamID in project.teams {
            guard let team = resolveTeam(teamID, board: board) else { continue }
            for memberID in team.memberActorIds {
                if let node = nodesByID[memberID], let delegation = tryNode(node) {
                    return delegation
                }
            }
        }

        let agentNodes = nodesByID.values
            .filter { $0.kind == .agent && $0.linkedAgentId != nil }
            .sorted(by: { $0.createdAt < $1.createdAt })
        for node in agentNodes {
            if let delegation = tryNode(node) {
                return delegation
            }
        }

        return nil
    }

    func resolveSwarmTaskDelegation(project: ProjectRecord, task: ProjectTask) async -> TaskDelegation? {
        let board = try? getActorBoard()
        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let actorID = normalizeWhitespace(task.claimedActorId ?? task.actorId ?? "")
        guard !actorID.isEmpty else {
            return nil
        }

        let resolvedNode = nodesByID[actorID]
        let directChannelID = normalizeWhitespace(resolvedNode?.channelId ?? "")
        let channelID = directChannelID.isEmpty
            ? resolveExecutionChannelID(project: project, task: task)
            : directChannelID
        guard let channelID else {
            return nil
        }

        return TaskDelegation(
            actorID: actorID,
            agentID: resolvedNode?.linkedAgentId,
            channelID: channelID
        )
    }

    func preferredActorIDs(for task: ProjectTask, board: ActorBoardSnapshot?) -> [String] {
        var actorIDs: [String] = []
        var seen: Set<String> = []

        func add(_ actorID: String?) {
            guard let actorID = actorID else {
                return
            }
            let normalized = normalizeWhitespace(actorID)
            guard !normalized.isEmpty else {
                return
            }
            let resolved = resolveActorNodeID(normalized, board: board) ?? normalized
            if seen.insert(resolved).inserted {
                actorIDs.append(resolved)
            }
        }

        if task.activeStage == .review, let reviewer = task.stageAssignments?.reviewer {
            add(reviewer)
            return actorIDs
        }
        if let developer = task.stageAssignments?.developer {
            add(developer)
            return actorIDs
        }
        add(task.actorId)

        let resolvedTeam = task.teamId.flatMap { resolveTeam($0, board: board) }
        if let team = resolvedTeam {
            add(task.claimedActorId)
            for memberActorID in team.memberActorIds {
                add(memberActorID)
            }
        }

        add(task.claimedActorId)
        return actorIDs
    }

    func resolveActorNodeID(_ raw: String, board: ActorBoardSnapshot?) -> String? {
        guard let nodes = board?.nodes, !nodes.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        return nodes.first { node in
            node.id == raw ||
            node.id.lowercased() == lower ||
            (node.linkedAgentId ?? "").lowercased() == lower ||
            node.displayName.lowercased() == lower
        }?.id
    }

    func resolveTeam(_ raw: String, board: ActorBoardSnapshot?) -> ActorTeam? {
        guard let teams = board?.teams, !teams.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        return teams.first { team in
            team.id == raw ||
            team.id.lowercased() == lower ||
            team.name.lowercased() == lower
        }
    }

    func routableActorIDs(
        project: ProjectRecord,
        task: ProjectTask,
        board: ActorBoardSnapshot?
    ) -> Set<String>? {
        guard let board else {
            return nil
        }

        guard let sourceChannelID = resolveExecutionChannelID(project: project, task: task) else {
            return nil
        }

        let sourceActorIDs = board.nodes.compactMap { node -> String? in
            let nodeChannelID = normalizeWhitespace(node.channelId ?? "")
            guard nodeChannelID == sourceChannelID else {
                return nil
            }
            return node.id
        }
        guard !sourceActorIDs.isEmpty else {
            return nil
        }

        var hasTaskRoutes = false
        var allowed = Set(sourceActorIDs)
        for sourceActorID in sourceActorIDs {
            let recipients = routeRecipients(
                fromActorID: sourceActorID,
                links: board.links,
                communicationType: .task
            )
            if !recipients.isEmpty {
                hasTaskRoutes = true
            }
            allowed.formUnion(recipients)
        }

        // If we have a board and detected task-specific routes, we must respect them.
        // Returning an empty set instead of nil ensures that we don't fall back to 'allow all'
        // when a board is present but the specific actor is not in the allowed set.
        guard hasTaskRoutes else {
            return nil
        }
        return allowed
    }

    func routeRecipients(
        fromActorID: String,
        links: [ActorLink],
        communicationType: ActorCommunicationType
    ) -> Set<String> {
        var recipients: Set<String> = []

        for link in links {
            guard link.communicationType == communicationType else {
                continue
            }
            if link.sourceActorId == fromActorID {
                recipients.insert(link.targetActorId)
                continue
            }
            if link.direction == .twoWay, link.targetActorId == fromActorID {
                recipients.insert(link.sourceActorId)
            }
        }

        recipients.remove(fromActorID)
        return recipients
    }

    struct TeamRetryDelegate {
        let actorID: String
        let agentID: String?
    }

    func nextTeamRetryDelegate(project: ProjectRecord, task: ProjectTask) async -> TeamRetryDelegate? {
        guard let teamID = task.teamId else {
            return nil
        }
        let board = try? getActorBoard()
        guard let team = board?.teams.first(where: { $0.id == teamID }),
              !team.memberActorIds.isEmpty
        else {
            return nil
        }

        guard let currentActorID = task.claimedActorId,
              let currentIndex = team.memberActorIds.firstIndex(of: currentActorID)
        else {
            return nil
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let routeAllowedActorIDs = routableActorIDs(project: project, task: task, board: board)
        for nextIndex in (currentIndex + 1)..<team.memberActorIds.count {
            let nextActorID = team.memberActorIds[nextIndex]
            if let routeAllowedActorIDs, !routeAllowedActorIDs.contains(nextActorID) {
                continue
            }
            guard let node = nodesByID[nextActorID],
                  node.linkedAgentId != nil else {
                continue
            }
            return TeamRetryDelegate(actorID: nextActorID, agentID: node.linkedAgentId)
        }

        return nil
    }

    func nextTeamHandoffDelegate(project: ProjectRecord, task: ProjectTask) async -> TeamRetryDelegate? {
        if let assignments = task.stageAssignments {
            guard task.activeStage != .review,
                  let reviewer = assignments.reviewer,
                  let board = try? getActorBoard(),
                  let node = board.nodes.first(where: { $0.id == reviewer }) else { return nil }
            return TeamRetryDelegate(actorID: reviewer, agentID: node.linkedAgentId)
        }
        guard let teamID = task.teamId else {
            return nil
        }
        let board = try? getActorBoard()
        guard let team = board?.teams.first(where: { $0.id == teamID }),
              !team.memberActorIds.isEmpty
        else {
            return nil
        }

        guard let currentActorID = task.claimedActorId,
              let currentIndex = team.memberActorIds.firstIndex(of: currentActorID)
        else {
            return nil
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let links = board?.links ?? []
        
        var nextActorID: String?
        
        for link in links {
            guard link.communicationType == .task else { continue }
            if link.sourceActorId == currentActorID, team.memberActorIds.contains(link.targetActorId) {
                nextActorID = link.targetActorId
                break
            }
            if link.direction == .twoWay, link.targetActorId == currentActorID, team.memberActorIds.contains(link.sourceActorId) {
                nextActorID = link.sourceActorId
                break
            }
        }
        
        if nextActorID == nil {
            let nextIndex = currentIndex + 1
            guard nextIndex < team.memberActorIds.count else {
                return nil
            }
            nextActorID = team.memberActorIds[nextIndex]
        }

        guard let targetActorID = nextActorID,
              let node = nodesByID[targetActorID],
              node.linkedAgentId != nil else {
            return nil
        }
        return TeamRetryDelegate(actorID: targetActorID, agentID: node.linkedAgentId)
    }

    func autopilotReviewerDelegate(project: ProjectRecord, task: ProjectTask) -> TeamRetryDelegate? {
        guard project.autopilotSettings.enabled,
              isAutopilotManagedTask(project: project, task: task)
        else {
            return nil
        }
        let reviewerAgentID = normalizeWhitespace(project.autopilotSettings.reviewerAgentId ?? "")
        guard !reviewerAgentID.isEmpty else {
            return nil
        }
        return TeamRetryDelegate(actorID: "agent:\(reviewerAgentID)", agentID: reviewerAgentID)
    }

    func extractOriginChannelID(from description: String) -> String? {
        let pattern = #"(?im)^Origin channel:\s*(\S+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsDescription = description as NSString
        let range = NSRange(location: 0, length: nsDescription.length)
        guard let match = regex.firstMatch(in: description, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound else {
            return nil
        }
        return nsDescription.substring(with: capture)
    }

    func handleVisorEvent(_ event: EventEnvelope) async {
        switch event.messageType {
        case .workerProgress:
            await syncTaskProgressFromWorkerEvent(event: event)
        case .workerCompleted:
            await syncTaskStatusFromWorkerEvent(event: event, nextStatus: ProjectTaskStatus.done.rawValue, failureNote: nil)
        case .workerFailed:
            let errorText = event.payload.objectValue["error"]?.stringValue
            await syncTaskStatusFromWorkerEvent(event: event, nextStatus: ProjectTaskStatus.backlog.rawValue, failureNote: errorText)
        case .visorWorkerTimeout:
            // Ignore legacy timeout events: worker age is not a cancellation signal.
            break
        case .visorSignalChannelDegraded:
            let failureCount = event.payload.asObject?["failure_count"]?.asNumber ?? 0
            logger.warning(
                "visor.signal.channel_degraded",
                metadata: [
                    "channel_id": .string(event.channelId),
                    "failure_count": .stringConvertible(Int(failureCount))
                ]
            )
            await deliverWebhook(event: event)
        case .visorSignalIdle:
            logger.warning("visor.signal.idle", metadata: ["channel_id": .string(event.channelId)])
            await deliverWebhook(event: event)
        default:
            break
        }
    }

    func deliverWebhook(event: EventEnvelope) async {
        let urls = currentConfig.visor.webhookURLs
        guard !urls.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let body = try? encoder.encode(event) else { return }

        for urlString in urls {
            guard let url = URL(string: urlString) else {
                logger.warning("visor.webhook.invalid_url", metadata: ["url": .string(urlString)])
                continue
            }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                let (_, response) = try await SloppyURLSessionFactory.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status < 200 || status >= 300 {
                    logger.warning(
                        "visor.webhook.failed",
                        metadata: ["url": .string(urlString), "status": .stringConvertible(status)]
                    )
                }
            } catch {
                logger.warning(
                    "visor.webhook.error",
                    metadata: ["url": .string(urlString), "error": .string(error.localizedDescription)]
                )
            }
        }
    }

    func syncTaskStatusFromWorkerEvent(
        event: EventEnvelope,
        nextStatus: String,
        failureNote: String?
    ) async {
        guard let taskID = event.taskId else {
            return
        }

        let projects = await store.listProjects()
        for var project in projects {
            guard let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID }) else {
                continue
            }

            var task = project.tasks[taskIndex]
            guard task.status != ProjectTaskStatus.cancelled.rawValue else { continue }
            var effectiveFailureNote = failureNote
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: event.messageType.rawValue,
                channelID: event.channelId,
                workerID: event.workerId,
                message: effectiveFailureNote ?? "Worker event received.",
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId
            )
            let isModelError = effectiveFailureNote.map { isModelProviderError($0) } ?? false
            let maxModelRetries = 3
            let modelRetryCount = isModelError
                ? task.description.components(separatedBy: "Model provider error").count - 1
                : 0

            if event.messageType == .workerFailed, isModelError, modelRetryCount < maxModelRetries {
                let prevRetryStatus = task.status
                task.status = ProjectTaskStatus.ready.rawValue
                task.updatedAt = Date()
                if let effectiveFailureNote {
                    let timestamp = ISO8601DateFormatter().string(from: event.ts)
                    let notePrefix = event.messageType == .workerCompleted ? "Worker completed at \(timestamp) without confirmation" : "Worker failed at \(timestamp)"
                    let note = "\(notePrefix): \(effectiveFailureNote)"
                    if task.description.isEmpty {
                        task.description = note
                    } else {
                        task.description += "\n\n\(note)"
                    }
                }
                project.tasks[taskIndex] = task
                project.updatedAt = Date()
                await store.saveProject(project)
                await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevRetryStatus, to: task.status, source: "system")
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: task.id,
                    stage: "retry_same_actor",
                    channelID: event.channelId,
                    workerID: event.workerId,
                    message: "Model error; retrying with same actor (\(modelRetryCount + 1)/\(maxModelRetries)).",
                    actorID: task.claimedActorId,
                    agentID: task.claimedAgentId
                )
                let actor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "Model error on task \(task.id); retrying with \(actor) (\(modelRetryCount + 1)/\(maxModelRetries))."
                )
                await handleTaskBecameReady(projectID: project.id, taskID: task.id)
                return
            }

            if event.messageType == .workerFailed,
               let retryDelegate = await nextTeamRetryDelegate(project: project, task: task) {
                let prevRetryStatus = task.status
                task.status = ProjectTaskStatus.ready.rawValue
                task.claimedActorId = retryDelegate.actorID
                task.claimedAgentId = retryDelegate.agentID
                task.actorId = retryDelegate.actorID
                let routeUpdate = recordAutonomousRoute(
                    task: task,
                    actorID: retryDelegate.actorID,
                    agentID: retryDelegate.agentID,
                    reason: "retry",
                    settings: project.reviewSettings
                )
                task = routeUpdate.task
                if let blockedMessage = routeUpdate.blockedMessage {
                    await persistAutonomousRouteBlock(
                        project: project,
                        taskIndex: taskIndex,
                        task: task,
                        previousStatus: prevRetryStatus,
                        message: blockedMessage,
                        channelID: event.channelId,
                        workerID: event.workerId,
                        actorID: retryDelegate.actorID,
                        agentID: retryDelegate.agentID
                    )
                    return
                }
                task.updatedAt = Date()
                if let effectiveFailureNote {
                    let timestamp = ISO8601DateFormatter().string(from: event.ts)
                    let note = "Worker failed at \(timestamp): \(effectiveFailureNote)"
                    if task.description.isEmpty {
                        task.description = note
                    } else {
                        task.description += "\n\n\(note)"
                    }
                }

                project.tasks[taskIndex] = task
                project.updatedAt = Date()
                await store.saveProject(project)
                await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevRetryStatus, to: task.status, source: "system")
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: task.id,
                    stage: "retry_ready",
                    channelID: event.channelId,
                    workerID: event.workerId,
                    message: "Retry scheduled with next team member.",
                    actorID: retryDelegate.actorID,
                    agentID: retryDelegate.agentID
                )

                let retryActor = retryDelegate.agentID ?? retryDelegate.actorID
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "Retrying task \(task.id) with \(retryActor)."
                )
                await handleTaskBecameReady(projectID: project.id, taskID: task.id)
                return
            }

            var resolvedStatus = nextStatus
            var completionArtifactPath: String?
            if event.messageType == .workerCompleted {
                if let claimedActorID = task.claimedActorId {
                    task.actorId = claimedActorID
                }
                completionArtifactPath = await persistWorkerArtifactForProjectTask(
                    projectID: project.id,
                    taskID: task.id,
                    event: event
                )
                let delegatedFinishSummary = delegatedFinishCompletionSummary(from: event)

                if task.status == ProjectTaskStatus.done.rawValue {
                    resolvedStatus = ProjectTaskStatus.done.rawValue
                } else if let currentStatus = task.statusValue,
                          currentStatus == .waitingInput || currentStatus == .blocked || currentStatus == .needsReview || currentStatus == .cancelled {
                    resolvedStatus = currentStatus.rawValue
                } else if let delegatedFinishSummary {
                    resolvedStatus = ProjectTaskStatus.needsReview.rawValue
                    await appendSystemTaskComment(
                        projectID: project.id,
                        taskID: task.id,
                        content: "Completion reported; verification is needed before closing this task.\nEvidence: \(delegatedFinishSummary)\nAction required: review the completion evidence and confirm the outcome in Sloppy.",
                        kind: .actionRequired
                    )
                } else {
                    resolvedStatus = ProjectTaskStatus.blocked.rawValue
                    effectiveFailureNote = "Worker exited without explicit completion confirmation. Mark the task done only after calling project.task_update with completion evidence."
                    await appendSystemTaskComment(
                        projectID: project.id,
                        taskID: task.id,
                        content: "Task blocked: the worker exited without confirming completion.\nAction required: inspect the execution log and any artifacts in Sloppy, then resume the task or confirm its result.",
                        kind: .actionRequired
                    )
                }

                let completionHandoffDelegate: TeamRetryDelegate?
                let board = try? getActorBoard()
                let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
                let currentNode = task.claimedActorId.flatMap { nodesByID[$0] }
                let currentActorIsReviewer = task.stageAssignments != nil
                    ? task.activeStage == .review
                    : currentNode?.systemRole == .reviewer
                if resolvedStatus == ProjectTaskStatus.done.rawValue, !currentActorIsReviewer {
                    let teamDelegate = await nextTeamHandoffDelegate(project: project, task: task)
                    completionHandoffDelegate = task.stageAssignments != nil ? teamDelegate
                        : teamDelegate ?? autopilotReviewerDelegate(project: project, task: task)
                } else {
                    completionHandoffDelegate = nil
                }
                if let handoffDelegate = completionHandoffDelegate {
                    let previousHandoffActor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                    let prevRouteStatus = task.status
                    task.claimedActorId = handoffDelegate.actorID
                    task.claimedAgentId = handoffDelegate.agentID
                    task.actorId = handoffDelegate.actorID
                    let routeUpdate = recordAutonomousRoute(
                        task: task,
                        actorID: handoffDelegate.actorID,
                        agentID: handoffDelegate.agentID,
                        reason: "handoff",
                        settings: project.reviewSettings
                    )
                    task = routeUpdate.task
                    if let blockedMessage = routeUpdate.blockedMessage {
                        await persistAutonomousRouteBlock(
                            project: project,
                            taskIndex: taskIndex,
                            task: task,
                            previousStatus: prevRouteStatus,
                            message: blockedMessage,
                            channelID: event.channelId,
                            workerID: event.workerId,
                            actorID: handoffDelegate.actorID,
                            agentID: handoffDelegate.agentID,
                            artifactPath: completionArtifactPath
                        )
                        return
                    }
                    let nextNode = nodesByID[handoffDelegate.actorID]
                    let isReviewer = task.stageAssignments?.reviewer == handoffDelegate.actorID
                        || nextNode?.systemRole == .reviewer
                    let isAutopilotReviewer = normalizeWhitespace(handoffDelegate.agentID ?? "") == normalizeWhitespace(project.autopilotSettings.reviewerAgentId ?? "")

                    if isReviewer || isAutopilotReviewer {
                        task.activeStage = .review
                        project.tasks[taskIndex] = task
                        project.updatedAt = Date()
                        await store.saveProject(project)
                        await handleReviewHandoff(
                            project: project,
                            task: task,
                            taskIndex: taskIndex,
                            handoffDelegate: handoffDelegate,
                            event: event,
                            completionArtifactPath: completionArtifactPath
                        )
                        return
                    }

                    let handoffActor = previousHandoffActor
                    let handoffNote = "Handoff from \(handoffActor)"
                    if task.description.isEmpty {
                        task.description = handoffNote
                    } else {
                        task.description += "\n\n\(handoffNote)"
                    }

                    let prevHandoffStatus = task.status
                    task.status = ProjectTaskStatus.ready.rawValue
                    task.updatedAt = Date()
                    project.tasks[taskIndex] = task
                    project.updatedAt = Date()
                    await store.saveProject(project)
                    await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevHandoffStatus, to: task.status, source: "system")
                    appendTaskLifecycleLog(
                        projectID: project.id,
                        taskID: task.id,
                        stage: "handoff_ready",
                        channelID: event.channelId,
                        workerID: event.workerId,
                        message: "Handoff to next team member.",
                        actorID: handoffDelegate.actorID,
                        agentID: handoffDelegate.agentID,
                        artifactPath: completionArtifactPath
                    )

                    let nextActor = handoffDelegate.agentID ?? handoffDelegate.actorID
                    let handoffMessage = "Task \(task.id) handed off to \(nextActor)."
                    await runtime.appendSystemMessage(channelId: event.channelId, content: handoffMessage)
                    await deliverToChannelPlugin(channelId: event.channelId, content: handoffMessage)
                    await handleTaskBecameReady(projectID: project.id, taskID: task.id)
                    return
                }
            }

            let prevSyncStatus = task.status
            task.status = resolvedStatus
            task.updatedAt = Date()
            if let effectiveFailureNote {
                let timestamp = ISO8601DateFormatter().string(from: event.ts)
                let note = "Worker failed at \(timestamp): \(effectiveFailureNote)"
                if task.description.isEmpty {
                    task.description = note
                } else {
                    task.description += "\n\n\(note)"
                }
            }
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevSyncStatus, to: resolvedStatus, source: task.claimedAgentId ?? "system")
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "status_synced",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Task status set to \(resolvedStatus).",
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId,
                artifactPath: completionArtifactPath
            )
            if event.messageType == .workerCompleted,
               resolvedStatus == ProjectTaskStatus.done.rawValue || resolvedStatus == ProjectTaskStatus.needsReview.rawValue {
                scheduleProjectMemoryCheckpointFromWorkerEvent(
                    projectID: project.id,
                    taskID: task.id,
                    status: resolvedStatus,
                    event: event
                )
            }

            if event.messageType == .workerCompleted {
                let completionActor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                let completionSuffix: String
                if let completionArtifactPath {
                    completionSuffix = " Artifact: \(completionArtifactPath)"
                } else {
                    completionSuffix = " Artifact missing; task returned to backlog."
                }
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "\(completionActor) completed task \(task.id).\(completionSuffix)"
                )
            } else if event.messageType == .workerFailed {
                let failedActor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                if let effectiveFailureNote {
                    await appendSystemTaskComment(
                        projectID: project.id,
                        taskID: task.id,
                        content: "Task execution stopped; no automatic retry was selected.\nLast error: \(effectiveFailureNote)\nAction required: inspect the execution log and any saved results in Sloppy, resolve the error, then return the task to ready.",
                        kind: .actionRequired
                    )
                }
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "\(failedActor) failed task \(task.id); moved back to backlog."
                )
            }

            let statusMessage: String
            if resolvedStatus == ProjectTaskStatus.done.rawValue {
                statusMessage = "Task \(task.id) completed."
            } else if resolvedStatus == ProjectTaskStatus.blocked.rawValue,
                      event.messageType == .workerCompleted,
                      effectiveFailureNote != nil {
                statusMessage = "Task \(task.id) blocked: worker exited without explicit completion confirmation."
            } else if effectiveFailureNote != nil {
                statusMessage = "Task \(task.id) failed; moved back to backlog."
            } else {
                statusMessage = "Task \(task.id) status changed to \(resolvedStatus)."
            }
            await runtime.appendSystemMessage(channelId: event.channelId, content: statusMessage)
            await deliverToChannelPlugin(channelId: event.channelId, content: statusMessage)

            logger.info(
                "visor.task.synced_from_worker_event",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(task.id),
                    "event_type": .string(event.messageType.rawValue),
                    "status": .string(resolvedStatus)
                ]
            )
            return
        }
    }

    func delegatedFinishCompletionSummary(from event: EventEnvelope) -> String? {
        guard event.messageType == .workerCompleted,
              let finish = event.payload.objectValue["delegateFinish"]?.objectValue,
              finish["finished"]?.boolValue == true,
              finish["synthetic"]?.boolValue != true,
              finish["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "completed"
        else {
            return nil
        }

        let summary = finish["summary"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? nil : summary
    }

}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self { return object }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
