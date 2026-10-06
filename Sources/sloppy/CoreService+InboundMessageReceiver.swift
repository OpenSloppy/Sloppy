import Foundation
import AgentRuntime
import ChannelPluginSupport
import Protocols
import PluginSDK
import Logging

// MARK: - InboundMessageReceiver Helpers

extension CoreService {
    func handleTaskApprovalCommand(channelId: String, reference: TaskApprovalReference) async -> ChannelRouteDecision {
        let scoped = ChannelGatewayScope.parse(channelId)
        guard let project = await projectForChannel(channelId: scoped.baseChannelId, topicId: scoped.topicKey) else {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "project_not_found_for_channel"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "project_not_found_for_channel",
                confidence: 1.0,
                tokenBudget: 0
            )
        }

        guard let task = resolveTask(reference: reference, in: project) else {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "task_not_found"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_not_found",
                confidence: 1.0,
                tokenBudget: 0
            )
        }

        do {
            _ = try await updateProjectTask(
                projectID: project.id,
                taskID: task.id,
                request: ProjectTaskUpdateRequest(status: ProjectTaskStatus.ready.rawValue)
            )
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "Task \(task.id) approved and queued for execution."
            )
            logger.info(
                "visor.task.approved",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(task.id),
                    "channel_id": .string(channelId),
                    "source": .string("nl_command")
                ]
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_approved_command",
                confidence: 1.0,
                tokenBudget: 0
            )
        } catch {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "task_not_found"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_not_found",
                confidence: 1.0,
                tokenBudget: 0
            )
        }
    }

    func handleVisorTaskPlan(
        channelId: String,
        request: ChannelMessageRequest
    ) async -> ChannelRouteDecision? {
        let scoped = ChannelGatewayScope.parse(channelId)
        let topicKey = scoped.topicKey ?? request.topicId
        let project = await projectForChannel(channelId: scoped.baseChannelId, topicId: topicKey)
        let channelState = await runtime.channelState(channelId: channelId)
        let board = try? getActorBoard()
        let context = VisorTaskPlanningContext(
            channelId: channelId,
            content: request.content,
            recentMessages: channelState?.messages.suffix(20).map { $0 } ?? [],
            tasks: project?.tasks ?? [],
            actorIDs: Set(board?.nodes.map(\.id) ?? []),
            teamIDs: Set(board?.teams.map(\.id) ?? [])
        )
        let intents = VisorTaskPlanner.plan(context: context)
        guard !intents.isEmpty else {
            return nil
        }

        guard let project else {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "project_not_found_for_channel"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "project_not_found_for_channel",
                confidence: 1.0,
                tokenBudget: 0
            )
        }

        do {
            let summary = try await applyVisorTaskIntents(
                intents,
                project: project,
                channelId: channelId
            )
            guard !summary.isEmpty else {
                return nil
            }

            await runtime.appendSystemMessage(channelId: channelId, content: summary)
            return ChannelRouteDecision(
                action: .respond,
                reason: "visor_task_plan_applied",
                confidence: 1.0,
                tokenBudget: 0
            )
        } catch ProjectError.notFound {
            await runtime.appendSystemMessage(channelId: channelId, content: "task_not_found")
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_not_found",
                confidence: 1.0,
                tokenBudget: 0
            )
        } catch {
            await runtime.appendSystemMessage(channelId: channelId, content: "invalid_task_request")
            return ChannelRouteDecision(
                action: .respond,
                reason: "invalid_task_request",
                confidence: 1.0,
                tokenBudget: 0
            )
        }
    }

    func applyVisorTaskIntents(
        _ intents: [VisorTaskIntent],
        project: ProjectRecord,
        channelId: String
    ) async throws -> String {
        var project = project
        var createdTaskIDs: [String] = []
        var updatedTaskIDs: [String] = []
        var cancelledTaskIDs: [String] = []
        var skippedDuplicates: [String] = []

        for intent in intents {
            switch intent {
            case .create(let createIntent):
                let titleKey = normalizedTaskTitleKey(createIntent.title)
                let hasDuplicate = project.tasks.contains(where: { task in
                    activeProjectTaskStatuses.contains(task.status) && normalizedTaskTitleKey(task.title) == titleKey
                })
                if hasDuplicate {
                    skippedDuplicates.append(createIntent.title)
                    continue
                }

                project = try await createProjectTask(
                    projectID: project.id,
                    request: ProjectTaskCreateRequest(
                        title: createIntent.title,
                        description: createIntent.description,
                        priority: createIntent.priority ?? "medium",
                        status: ProjectTaskStatus.pendingApproval.rawValue,
                        actorId: createIntent.actorId,
                        teamId: createIntent.teamId
                    )
                )
                if let created = project.tasks.last {
                    createdTaskIDs.append(created.id)
                }

            case .update(let updateIntent):
                let task = try resolveTask(reference: updateIntent.reference, in: project)
                project = try await updateProjectTask(
                    projectID: project.id,
                    taskID: task.id,
                    request: ProjectTaskUpdateRequest(
                        title: updateIntent.title,
                        description: updateIntent.description,
                        priority: updateIntent.priority,
                        status: updateIntent.status?.rawValue,
                        actorId: updateIntent.actorId,
                        teamId: updateIntent.teamId,
                        changedBy: "visor"
                    )
                )
                updatedTaskIDs.append(task.id)

            case .cancel(let cancelIntent):
                let task = try resolveTask(reference: cancelIntent.reference, in: project)
                project = try await cancelProjectTask(
                    projectID: project.id,
                    taskID: task.id,
                    reason: cancelIntent.reason
                )
                cancelledTaskIDs.append(task.id)

            case .split(let splitIntent):
                let parent = try resolveTask(reference: splitIntent.reference, in: project)
                for item in splitIntent.items {
                    let title = summarizedTaskTitle(from: item)
                    let titleKey = normalizedTaskTitleKey(title)
                    let hasDuplicate = project.tasks.contains(where: { task in
                        activeProjectTaskStatuses.contains(task.status) && normalizedTaskTitleKey(task.title) == titleKey
                    })
                    if hasDuplicate {
                        skippedDuplicates.append(title)
                        continue
                    }

                    let description = normalizeTaskDescription(
                        """
                        Split from task \(parent.id): \(parent.title)

                        \(item)
                        """
                    )
                    project = try await createProjectTask(
                        projectID: project.id,
                        request: ProjectTaskCreateRequest(
                            title: title,
                            description: description,
                            priority: parent.priority,
                            status: ProjectTaskStatus.pendingApproval.rawValue,
                            actorId: parent.actorId,
                            teamId: parent.teamId
                        )
                    )
                    if let created = project.tasks.last {
                        createdTaskIDs.append(created.id)
                    }
                }
            }
        }

        var parts: [String] = []
        if !createdTaskIDs.isEmpty {
            parts.append("Created tasks: \(createdTaskIDs.joined(separator: ", "))")
        }
        if !updatedTaskIDs.isEmpty {
            parts.append("Updated tasks: \(updatedTaskIDs.joined(separator: ", "))")
        }
        if !cancelledTaskIDs.isEmpty {
            parts.append("Cancelled tasks: \(cancelledTaskIDs.joined(separator: ", "))")
        }
        if !skippedDuplicates.isEmpty {
            parts.append("Skipped duplicates: \(skippedDuplicates.joined(separator: ", "))")
        }
        if parts.isEmpty {
            parts.append("No task changes applied.")
        }

        logger.info(
            "visor.task.plan_applied",
            metadata: [
                "project_id": .string(project.id),
                "channel_id": .string(channelId),
                "created": .stringConvertible(createdTaskIDs.count),
                "updated": .stringConvertible(updatedTaskIDs.count),
                "cancelled": .stringConvertible(cancelledTaskIDs.count),
                "duplicates": .stringConvertible(skippedDuplicates.count)
            ]
        )

        _ = await triggerVisorBulletin()
        return parts.joined(separator: " ")
    }

    func petSourceKindForExternalChannelUser(_ userID: String) -> AgentPetSourceKind {
        let normalized = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "system" || normalized.hasPrefix("system_") {
            return .cron
        }
        return .externalChannel
    }

    func applyPetProgressForExternalChannel(
        channelID: String,
        event: AgentPetProgressionInput
    ) async {
        let board = try? getActorBoard()
        guard let agentID = linkedAgentID(forChannelID: channelID, board: board) else {
            return
        }

        do {
            _ = try agentCatalogStore.recordPetInteraction(agentID: agentID, input: event)
        } catch {
            logger.warning("Failed to update pet progress for external channel \(channelID): \(error)")
        }
    }

    func applyPetProgressForAgentSessionEvents(
        agentID: String,
        sessionID: String,
        summary: AgentSessionSummary,
        events: [AgentSessionEvent]
    ) async {
        let sourceKind: AgentPetSourceKind = summary.kind == .heartbeat ? .heartbeat : .agentSession
        let channelID = "agent:\(agentID):session:\(sessionID)"

        for event in events {
            let input: AgentPetProgressionInput?
            switch event.type {
            case .message:
                guard let message = event.message, message.role == .user else {
                    input = nil
                    break
                }
                let content = message.segments
                    .filter { $0.kind == .text || $0.kind == .thinking }
                    .compactMap(\.text)
                    .joined(separator: "\n")
                input = AgentPetProgressionInput(
                    sourceKind: sourceKind,
                    eventKind: .userMessage,
                    channelId: channelID,
                    sessionId: sessionID,
                    timestamp: event.createdAt,
                    userId: message.userId,
                    content: content
                )
            case .toolCall:
                input = AgentPetProgressionInput(
                    sourceKind: sourceKind,
                    eventKind: .toolCall,
                    channelId: channelID,
                    sessionId: sessionID,
                    timestamp: event.createdAt,
                    content: event.toolCall?.tool
                )
            case .toolResult:
                input = AgentPetProgressionInput(
                    sourceKind: sourceKind,
                    eventKind: event.toolResult?.ok == true ? .toolSuccess : .toolFailure,
                    channelId: channelID,
                    sessionId: sessionID,
                    timestamp: event.createdAt,
                    content: event.toolResult?.tool
                )
            case .runStatus:
                guard let status = event.runStatus else {
                    input = nil
                    break
                }
                let label = status.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let eventKind: AgentPetEventKind?
                switch status.stage {
                case .done:
                    eventKind = .runCompleted
                case .interrupted:
                    eventKind = label == "error" || details.hasPrefix("error") ? .runFailed : .runInterrupted
                default:
                    eventKind = nil
                }
                if let eventKind {
                    input = AgentPetProgressionInput(
                        sourceKind: sourceKind,
                        eventKind: eventKind,
                        channelId: channelID,
                        sessionId: sessionID,
                        timestamp: event.createdAt,
                        content: status.details
                    )
                } else {
                    input = nil
                }
            case .longChatTask, .sessionCreated, .memoryCheckpoint, .buildProgress, .planArtifact, .subSession, .runControl, .inputRequest, .inputResponse, .selfImprovementReview:
                input = nil
            }

            guard let input else {
                continue
            }

            do {
                _ = try agentCatalogStore.recordPetInteraction(agentID: agentID, input: input)
            } catch {
                logger.warning("Failed to update pet progress for agent session \(agentID)/\(sessionID): \(error)")
            }
        }
    }

}

// MARK: - InboundMessageReceiver

private actor ResponseCollector {
    private var value = ""
    func set(_ text: String) { value = text }
    func get() -> String { value }
}

extension CoreService {
    static let inboundChannelContextBootstrapMarker = "[inbound_channel_context_bootstrap_v1]"
    static let inboundRecentHistoryMaxCharacters = 12_000

    func offerInboundChannelPluginMessage(
        channelId: String,
        userId: String,
        contentForModel: String,
        topicId: String?,
        mode: AgentChatMode? = nil,
        attachments: [ChannelAttachment] = []
    ) async {
        var slot = inboundChannelPluginQueues[channelId] ?? InboundChannelPluginQueueSlot()
        if slot.processing {
            slot.fifo.append((userId: userId, content: contentForModel, topicId: topicId, mode: mode, attachments: attachments))
            inboundChannelPluginQueues[channelId] = slot
            await deliverToChannelPlugin(
                channelId: channelId,
                userId: "system",
                content: "Message queued (\(slot.fifo.count) ahead).",
                topicId: topicId
            )
            return
        }
        slot.processing = true
        inboundChannelPluginQueues[channelId] = slot
        Task {
            await self.runInboundChannelPluginDrain(
                channelId: channelId,
                initialUserId: userId,
                initialContent: contentForModel,
                initialTopicId: topicId,
                initialMode: mode,
                initialAttachments: attachments
            )
        }
    }

    fileprivate func runInboundChannelPluginDrain(
        channelId: String,
        initialUserId: String,
        initialContent: String,
        initialTopicId: String?,
        initialMode: AgentChatMode?,
        initialAttachments: [ChannelAttachment]
    ) async {
        var userId = initialUserId
        var content = initialContent
        var topicId = initialTopicId
        var mode = initialMode
        var attachments = initialAttachments
        while true {
            await executeSingleInboundChannelPluginTurn(
                channelId: channelId,
                userId: userId,
                contentForModel: content,
                topicId: topicId,
                mode: mode,
                attachments: attachments
            )
            guard var slot = inboundChannelPluginQueues[channelId] else {
                return
            }
            if slot.fifo.isEmpty {
                slot.processing = false
                inboundChannelPluginQueues[channelId] = slot
                return
            }
            let next = slot.fifo.removeFirst()
            inboundChannelPluginQueues[channelId] = slot
            userId = next.userId
            content = next.content
            topicId = next.topicId
            mode = next.mode
            attachments = next.attachments
        }
    }

    fileprivate func executeSingleInboundChannelPluginTurn(
        channelId: String,
        userId: String,
        contentForModel: String,
        topicId: String?,
        mode forcedMode: AgentChatMode?,
        attachments: [ChannelAttachment]
    ) async {
        await channelStreamCancelRegistry.clearCancel(channelId: channelId)

        let bindingChannelId = ChannelGatewayScope.parse(channelId).baseChannelId
        let board = try? getActorBoard()
        let linkedAgentID = linkedAgentID(forChannelID: bindingChannelId, board: board)
        await ensureInboundChannelContextBootstrap(
            channelId: channelId,
            linkedAgentID: linkedAgentID,
            topicId: topicId
        )
        let mode = forcedMode ?? .defaultMode
        let autoRouteCatalog: String?
        if mode == .auto, let linkedAgentID {
            let skills = (try? await getAgentSkillsForRuntime(agentID: linkedAgentID)) ?? []
            autoRouteCatalog = AutoRouteCatalog.markdown(installedSkills: skills)
        } else if mode == .auto {
            autoRouteCatalog = AutoRouteCatalog.defaultMarkdown()
        } else {
            autoRouteCatalog = nil
        }
        let modeContent = AgentSessionOrchestrator.runtimeContent(
            contentForModel,
            mode: mode,
            autoRouteCatalog: autoRouteCatalog
        )
        let contentForRuntime = contentWithFriendReminderIfNeeded(
            modeContent,
            linkedAgentID: linkedAgentID
        )
        let modelOverride = await channelModelStore.get(channelId: bindingChannelId)
        let request = ChannelMessageRequest(
            userId: userId,
            content: contentForRuntime,
            topicId: topicId,
            model: modelOverride,
            attachments: attachments
        )
        let collector = ResponseCollector()
        let outboundStreamID = await channelDelivery.beginStream(
            channelId: channelId,
            userId: "assistant",
            topicId: topicId
        )
        let cancelRegistry = channelStreamCancelRegistry

        let onChunk: @Sendable (String) async -> Bool = { chunk in
            if await cancelRegistry.isCancelling(channelId: channelId) {
                return false
            }
            await collector.set(chunk)
            if let outboundStreamID {
                _ = await self.channelDelivery.updateStream(id: outboundStreamID, content: chunk)
            }
            return true
        }
        let toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?
        if let agentID = linkedAgentID {
            toolInvoker = { [weak self] toolRequest in
                guard let self else {
                    return ToolInvocationResult(
                        tool: toolRequest.tool,
                        ok: false,
                        error: ToolErrorPayload(
                            code: "tool_invoker_unavailable",
                            message: "Tool invoker is unavailable.",
                            retryable: true
                        )
                    )
                }
                return await self.invokeToolFromChannelRuntime(
                    agentID: agentID,
                    channelID: channelId,
                    request: toolRequest,
                    topicID: topicId,
                    chatMode: mode
                )
            }
        } else {
            toolInvoker = nil
        }

        await toolLoopGuard.beginTurn(sessionID: channelId)
        _ = await runtime.postMessage(
            channelId: channelId,
            request: request,
            onResponseChunk: onChunk,
            toolInvoker: toolInvoker,
            observationHandler: { [weak self] observation in
                guard let self else {
                    return
                }

                do {
                    switch observation {
                    case .thinking(let text):
                        try await self.channelSessionStore.recordThinking(
                            channelId: channelId,
                            content: text
                        )
                    case .toolCall(let toolRequest):
                        try await self.channelSessionStore.recordToolCall(
                            channelId: channelId,
                            tool: toolRequest.tool,
                            arguments: .object(toolRequest.arguments),
                            reason: toolRequest.reason
                        )
                        await self.applyPetProgressForExternalChannel(
                            channelID: channelId,
                            event: AgentPetProgressionInput(
                                sourceKind: self.petSourceKindForExternalChannelUser(userId),
                                eventKind: .toolCall,
                                channelId: channelId,
                                timestamp: Date(),
                                userId: userId,
                                content: toolRequest.tool
                            )
                        )
                    case .toolResult(let toolResult):
                        try await self.channelSessionStore.recordToolResult(
                            channelId: channelId,
                            tool: toolResult.tool,
                            ok: toolResult.ok,
                            data: toolResult.data,
                            error: toolResult.error,
                            durationMs: toolResult.durationMs
                        )
                        await self.applyPetProgressForExternalChannel(
                            channelID: channelId,
                            event: AgentPetProgressionInput(
                                sourceKind: self.petSourceKindForExternalChannelUser(userId),
                                eventKind: toolResult.ok ? .toolSuccess : .toolFailure,
                                channelId: channelId,
                                timestamp: Date(),
                                userId: userId,
                                content: toolResult.tool
                            )
                        )
                    case .usage(let tokenUsage):
                        guard !(await self.runtime.isRequestUsageObserved(channelId: channelId)) else { return }
                        await self.store.persistTokenUsage(
                            channelId: channelId,
                            taskId: nil,
                            usage: tokenUsage
                        )
                    }
                } catch {
                    self.logger.warning("Failed to persist channel technical event: \(error)")
                }
            }
        )

        let reply = await collector.get().trimmingCharacters(in: .whitespacesAndNewlines)
        let waitingForPlanInput = (try? await channelSessionStore.hasPendingInputRequest(channelId: channelId)) == true
        if !reply.isEmpty {
            do {
                try await channelSessionStore.recordAssistantMessage(
                    channelId: channelId,
                    content: reply
                )
                await applyPetProgressForExternalChannel(
                    channelID: channelId,
                    event: AgentPetProgressionInput(
                        sourceKind: petSourceKindForExternalChannelUser(userId),
                        eventKind: .runCompleted,
                        channelId: channelId,
                        timestamp: Date(),
                        userId: userId,
                        content: reply
                    )
                )
            } catch {
                logger.warning("Failed to persist assistant message to channel session: \(error)")
            }
        } else if !waitingForPlanInput {
            await applyPetProgressForExternalChannel(
                channelID: channelId,
                event: AgentPetProgressionInput(
                    sourceKind: petSourceKindForExternalChannelUser(userId),
                    eventKind: .runFailed,
                    channelId: channelId,
                    timestamp: Date(),
                    userId: userId,
                    content: nil
                )
            )
        }
        if let outboundStreamID {
            _ = await channelDelivery.endStream(
                id: outboundStreamID,
                finalContent: reply.isEmpty ? nil : reply
            )
        } else if !reply.isEmpty {
            await channelDelivery.deliver(
                channelId: channelId,
                userId: "assistant",
                content: reply,
                topicId: topicId
            )
        }
    }

    func ensureInboundChannelContextBootstrap(
        channelId: String,
        linkedAgentID: String?,
        topicId: String?,
        maxHistoryCharacters: Int = CoreService.inboundRecentHistoryMaxCharacters
    ) async {
        if let existing = await runtime.channelBootstrapContent(channelId: channelId),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let bootstrap = await buildInboundChannelContextBootstrap(
            channelId: channelId,
            linkedAgentID: linkedAgentID,
            topicId: topicId,
            maxHistoryCharacters: maxHistoryCharacters
        )
        let trimmed = bootstrap.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        await runtime.setChannelBootstrap(channelId: channelId, content: bootstrap)
        logger.info(
            "Inbound channel context bootstrap restored",
            metadata: [
                "channel_id": .string(channelId),
                "linked_agent_id": .string(linkedAgentID ?? ""),
                "bootstrap_chars": .stringConvertible(bootstrap.count)
            ]
        )
    }

    func buildInboundChannelContextBootstrap(
        channelId: String,
        linkedAgentID: String?,
        topicId: String?,
        maxHistoryCharacters: Int = CoreService.inboundRecentHistoryMaxCharacters
    ) async -> String {
        var parts: [String] = [
            Self.inboundChannelContextBootstrapMarker,
            "Channel context restored.",
            "Channel: \(channelId)"
        ]

        if let linkedAgentID,
           let config = try? getAgentConfig(agentID: linkedAgentID) {
            parts.append("Agent: \(linkedAgentID)")
            if !config.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("\n[Agent role]\n\(config.role)")
            }
            appendAgentDocuments(config.documents, to: &parts)
        }

        let scoped = ChannelGatewayScope.parse(channelId)
        if let project = await projectForChannel(channelId: scoped.baseChannelId, topicId: scoped.topicKey ?? topicId),
           let projectContext = await projectBootstrapMarkdownForAgentSession(projectID: project.id),
           !projectContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(projectContext)
        }

        if let historyContext = await recentChannelHistoryContext(
            channelId: channelId,
            maxCharacters: maxHistoryCharacters
        ) {
            parts.append(historyContext)
        }

        return parts.joined(separator: "\n\n")
    }

    private func appendAgentDocuments(_ documents: AgentDocumentBundle, to parts: inout [String]) {
        let sections: [(String, String)] = [
            ("[AGENTS.md]", documents.agentsMarkdown),
            ("[USER.md]", documents.userMarkdown),
            ("[IDENTITY.md]", documents.identityMarkdown),
            ("[SOUL.md]", documents.soulMarkdown),
            ("[MEMORY.md]", documents.memoryMarkdown)
        ]

        for (title, content) in sections {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            parts.append("\(title)\n\(content)")
        }
    }

    func recentChannelHistoryContext(
        channelId: String,
        maxCharacters: Int = CoreService.inboundRecentHistoryMaxCharacters
    ) async -> String? {
        guard maxCharacters > 0 else {
            return nil
        }

        let history: [ChannelMessageEntry]
        do {
            history = try await channelSessionStore.getMessageHistory(channelId: channelId, limit: 200)
        } catch {
            logger.warning("Failed to restore recent channel history for \(channelId): \(error)")
            return nil
        }
        guard !history.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        let header = """
        [Recent channel history]
        The following messages are from the current open channel session. Use them to preserve continuity after process restart.
        """
        let footer = "[End of recent channel history]"
        var selected: [String] = []
        var total = header.count + footer.count + 2

        for entry in history.reversed() {
            let speaker = entry.userId == "assistant" ? "Assistant" : "User \(entry.userId)"
            let content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                continue
            }
            let line = "\(formatter.string(from: entry.createdAt)) \(speaker): \(content)"
            let lineCost = line.count + 1
            if total + lineCost > maxCharacters {
                if selected.isEmpty {
                    let available = max(0, maxCharacters - total - "\(formatter.string(from: entry.createdAt)) \(speaker): ".count - 14)
                    guard available > 0 else {
                        break
                    }
                    let suffix = String(content.suffix(available))
                    selected.insert("\(formatter.string(from: entry.createdAt)) \(speaker): ...\(suffix)", at: 0)
                }
                break
            }
            selected.insert(line, at: 0)
            total += lineCost
        }

        guard !selected.isEmpty else {
            return nil
        }

        return ([header] + selected + [footer]).joined(separator: "\n")
    }

    fileprivate func contentWithFriendReminderIfNeeded(_ content: String, linkedAgentID: String?) -> String {
        guard let linkedAgentID,
              let config = try? getAgentConfig(agentID: linkedAgentID)
        else {
            return content
        }
        return AgentSessionOrchestrator.contentWithFriendReminder(content, documents: config.documents)
    }
}

extension CoreService {
    /// Applies per-agent ``ChannelInboundActivation`` for gateway-originated messages (mention/reply-only).
    fileprivate func shouldDeliverChannelInbound(
        baseChannelId: String,
        sessionChannelId: String,
        content: String,
        inboundContext: ChannelInboundContext
    ) async -> Bool {
        let board = try? getActorBoard()
        guard let agentID = linkedAgentID(forChannelID: baseChannelId, board: board) else {
            return true
        }
        guard let config = try? getAgentConfig(agentID: agentID) else {
            return true
        }
        switch config.channelSessions.inboundActivation {
        case .allMessages:
            return true
        case .mentionOrReply:
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") {
                return true
            }
            return inboundContext.mentionsThisBot || inboundContext.isReplyToThisBot
        }
    }
}

extension CoreService: InboundMessageReceiver {
    /// Checks whether a platform user is allowed to interact.
    /// Priority: config allowlist (fast path) -> DB blocked -> DB approved -> pending approval flow.
    public func checkAccess(
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String
    ) async -> ChannelAccessResult {
        // Check DB for existing blocked entry
        if let existing = await store.channelAccessUser(platform: platform, platformUserId: platformUserId) {
            if existing.status == "blocked" {
                return .blocked
            }
            if existing.status == "approved" {
                return .allowed
            }
        }

        // Already pending — return existing code
        if let pending = await pendingApprovalService.findByUser(platform: platform, platformUserId: platformUserId) {
            let msg = "Your access request is pending.\n\nVerification code: \(pending.code)\n\nShare this code with an admin to get approved."
            return .pendingApproval(code: pending.code, message: msg)
        }

        // New user — create pending entry and notify Dashboard
        let entry = await pendingApprovalService.addPending(
            platform: platform,
            platformUserId: platformUserId,
            displayName: displayName,
            chatId: chatId
        )
        await notificationService.pushPendingApproval(
            title: "Access Request",
            message: "\(displayName) (@\(platformUserId)) wants access via \(platform)",
            approvalId: entry.id,
            platform: platform,
            userId: platformUserId,
            channelId: entry.channelId
        )
        let msg = "Access requested.\n\nVerification code: \(entry.code)\n\nShare this code with an admin to get approved."
        return .pendingApproval(code: entry.code, message: msg)
    }

    /// Called by in-process channel plugins when a message arrives from an external platform.
    /// Routes through the runtime, collects the response, persists to channel session,
    /// and delivers it back to the channel plugin.
    public func postMessage(
        channelId: String,
        userId: String,
        content: String,
        topicId: String?,
        inboundContext: ChannelInboundContext?,
        attachments: [ChannelAttachment]
    ) async -> Bool {
        let bindingChannelId = channelId
        let sessionChannelId = ChannelGatewayScope.scopedChannelId(
            baseChannelId: bindingChannelId,
            topicKey: topicId
        )

        if let inboundContext,
           !(await shouldDeliverChannelInbound(
               baseChannelId: bindingChannelId,
               sessionChannelId: sessionChannelId,
               content: content,
               inboundContext: inboundContext
           )) {
            return true
        }

        if let statusReply = await handleStatusCommand(channelId: sessionChannelId, content: content) {
            await deliverToChannelPlugin(channelId: sessionChannelId, content: statusReply, topicId: topicId)
            return true
        }

        if let modelCommandReply = await handleModelCommand(channelId: sessionChannelId, content: content) {
            await deliverToChannelPlugin(channelId: sessionChannelId, content: modelCommandReply, topicId: topicId)
            return true
        }

        if let modeCommandReply = await handleModeCommand(channelId: sessionChannelId, content: content) {
            await deliverToChannelPlugin(channelId: sessionChannelId, content: modeCommandReply, topicId: topicId)
            return true
        }

        if let contextReply = await handleContextCommand(channelId: sessionChannelId, content: content) {
            await deliverToChannelPlugin(channelId: sessionChannelId, content: contextReply, topicId: topicId)
            return true
        }

        if let addDirReply = await handleAddDirCommand(channelId: sessionChannelId, content: content) {
            await deliverToChannelPlugin(channelId: sessionChannelId, content: addDirReply, topicId: topicId)
            return true
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact" {
            let reason = "channel_compact_command"
            do {
                try await channelSessionStore.recordUserMessage(
                    channelId: sessionChannelId,
                    userId: userId,
                    content: content
                )
                try await channelSessionStore.recordCompactLifecycle(
                    channelId: sessionChannelId,
                    status: .started,
                    reason: reason,
                    content: "Compacting context..."
                )
            } catch {
                logger.warning("Failed to persist channel compact start for \(sessionChannelId): \(error)")
            }

            await deliverToChannelPlugin(channelId: sessionChannelId, content: "Compacting context...", topicId: topicId)
            await runtime.invalidateChannelSession(channelId: sessionChannelId)

            do {
                try await channelSessionStore.recordCompactLifecycle(
                    channelId: sessionChannelId,
                    status: .succeeded,
                    reason: reason,
                    content: "Compact success."
                )
            } catch {
                logger.warning("Failed to persist channel compact success for \(sessionChannelId): \(error)")
            }

            await deliverToChannelPlugin(channelId: sessionChannelId, content: "Compact success.", topicId: topicId)
            return true
        }

        if let diffReply = await handleDiffCommand(channelId: sessionChannelId, content: content) {
            await deliverToChannelPlugin(channelId: sessionChannelId, content: diffReply, topicId: topicId)
            return true
        }

        do {
            try await prepareChannelSession(channelId: bindingChannelId)
        } catch {
            logger.warning("Failed to prepare channel session for \(bindingChannelId): \(error)")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let oneShotModeCommand = inboundOneShotChatModeCommand(content)
        if let oneShotModeCommand, oneShotModeCommand.message.isEmpty {
            let usage: String
            switch oneShotModeCommand.mode {
            case .ask:
                usage = "Usage: /ask <question>"
            case .plan:
                usage = "Usage: /plan <request>"
            case .auto:
                usage = "Usage: /auto <request>"
            case .build, .debug:
                usage = "Usage: /\(oneShotModeCommand.mode.rawValue) <request>"
            }
            await deliverToChannelPlugin(channelId: sessionChannelId, content: usage, topicId: topicId)
            return true
        }

        if lower == "/abort" {
            await channelStreamCancelRegistry.requestCancel(channelId: sessionChannelId)
            let cancelled = await runtime.abortChannel(channelId: sessionChannelId, reason: "Aborted by user")
            await channelStreamCancelRegistry.clearCancel(channelId: sessionChannelId)
            let reason = cancelled > 0
                ? "Aborted \(cancelled) active worker(s)."
                : "No active workers to abort."
            await deliverToChannelPlugin(channelId: sessionChannelId, content: reason, topicId: topicId)
            return true
        }

        if let btwTail = ChannelInboundBtwParsing.btwModelTailIfCommand(content) {
            await channelStreamCancelRegistry.requestCancel(channelId: sessionChannelId)
            _ = await runtime.abortChannel(channelId: sessionChannelId, reason: "Interrupted by /btw")
            await runtime.invalidateChannelSession(channelId: sessionChannelId)

            do {
                try await channelSessionStore.recordUserMessage(
                    channelId: sessionChannelId,
                    userId: userId,
                    content: content
                )
                await applyPetProgressForExternalChannel(
                    channelID: sessionChannelId,
                    event: AgentPetProgressionInput(
                        sourceKind: petSourceKindForExternalChannelUser(userId),
                        eventKind: .userMessage,
                        channelId: sessionChannelId,
                        timestamp: Date(),
                        userId: userId,
                        content: content
                    )
                )
            } catch {
                logger.warning("Failed to persist user message to channel session: \(error)")
            }

            if btwTail.isEmpty {
                await deliverToChannelPlugin(
                    channelId: sessionChannelId,
                    content: "Model context cleared for this channel. Send your next message when ready.",
                    topicId: topicId
                )
                return true
            }

            if var slot = inboundChannelPluginQueues[sessionChannelId], slot.processing {
                slot.fifo.insert((userId: userId, content: btwTail, topicId: topicId, mode: nil, attachments: []), at: 0)
                inboundChannelPluginQueues[sessionChannelId] = slot
                return true
            }

            await offerInboundChannelPluginMessage(
                channelId: sessionChannelId,
                userId: userId,
                contentForModel: btwTail,
                topicId: topicId
            )
            return true
        }

        if !trimmed.hasPrefix("/"),
           let pending = try? await channelSessionStore.pendingInputRequest(channelId: sessionChannelId),
           let customAnswers = customPlanInputAnswers(from: trimmed, request: pending.request) {
            do {
                _ = try await answerChannelPlanInput(
                    sessionID: pending.sessionId,
                    requestID: pending.request.id,
                    payload: PlanInputAnswerRequest(
                        answers: customAnswers,
                        userId: userId
                    )
                )
                return true
            } catch {
                logger.warning("Failed to answer pending plan input for channel \(sessionChannelId): \(error)")
                await deliverToChannelPlugin(
                    channelId: sessionChannelId,
                    content: "Could not record that answer. Please try again.",
                    topicId: topicId
                )
                return true
            }
        }

        do {
            try await channelSessionStore.recordUserMessage(
                channelId: sessionChannelId,
                userId: userId,
                content: content
            )
            await applyPetProgressForExternalChannel(
                channelID: sessionChannelId,
                event: AgentPetProgressionInput(
                    sourceKind: petSourceKindForExternalChannelUser(userId),
                    eventKind: .userMessage,
                    channelId: sessionChannelId,
                    timestamp: Date(),
                    userId: userId,
                    content: content
                )
            )
        } catch {
            logger.warning("Failed to persist user message to channel session: \(error)")
        }

        await offerInboundChannelPluginMessage(
            channelId: sessionChannelId,
            userId: userId,
            contentForModel: oneShotModeCommand?.message ?? trimmed,
            topicId: topicId,
            mode: oneShotModeCommand?.mode,
            attachments: attachments
        )
        return true
    }

    func inboundOneShotChatModeCommand(_ content: String) -> (mode: AgentChatMode, message: String)? {
        AgentSessionOrchestrator.oneShotModeCommand(content)
    }

    private func customPlanInputAnswers(
        from content: String,
        request: PlanInputRequest
    ) -> [PlanInputAnswer]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if request.questions.count == 1, let question = request.questions.first {
            guard question.allowCustomAnswer else { return nil }
            return [PlanInputAnswer(questionId: question.id, customAnswer: trimmed)]
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == request.questions.count else {
            return nil
        }
        var answers: [PlanInputAnswer] = []
        for (index, question) in request.questions.enumerated() {
            guard question.allowCustomAnswer else { return nil }
            answers.append(PlanInputAnswer(questionId: question.id, customAnswer: lines[index]))
        }
        return answers
    }

    func handleAddDirCommand(channelId: String, content: String) async -> String? {
        guard let rawPath = ChannelAddDirCommandParsing.pathTailIfCommand(content) else {
            return nil
        }
        guard !rawPath.isEmpty else {
            return "Usage: /add_dir <path>"
        }

        do {
            let response = try await addChannelSessionDirectory(
                channelID: channelId,
                request: AgentSessionDirectoryRequest(path: rawPath)
            )
            return "Added working directory:\n\(response.path)"
        } catch AgentSessionError.invalidPayload {
            return "Directory not found: \(rawPath)"
        } catch {
            return "Failed to add directory: \(String(describing: error))"
        }
    }

    public func skillSlashCommandTokens(forChannelID: String) async -> [String] {
        let board = try? getActorBoard()
        let base = ChannelGatewayScope.parse(forChannelID).baseChannelId
        guard let agentID = linkedAgentID(forChannelID: base, board: board) else {
            return []
        }
        guard let skills = try? await getAgentSkillsForRuntime(agentID: agentID) else {
            return []
        }
        let builtin = Set(ChannelCommandHandler.allCommands.map { $0.name.lowercased() })
        let invocableSkillIds = skills.filter(\.userInvocable).map(\.id)
        let resolved = SkillSlashCommandNaming.resolvedSlashTokens(forSkillIds: invocableSkillIds, reservedTokens: builtin)
        return invocableSkillIds.compactMap { resolved[$0] }
    }

    public func skillSlashMenuEntriesUnion(forChannelIDs: [String]) async -> [ChannelSlashCommandItem] {
        var seen = Set<String>()
        var items: [ChannelSlashCommandItem] = []
        let builtin = Set(ChannelCommandHandler.allCommands.map { $0.name.lowercased() })
        for cid in forChannelIDs {
            let board = try? getActorBoard()
            let base = ChannelGatewayScope.parse(cid).baseChannelId
            guard let agentID = linkedAgentID(forChannelID: base, board: board) else {
                continue
            }
            guard let skills = try? await getAgentSkillsForRuntime(agentID: agentID) else {
                continue
            }
            let invocableSkills = skills.filter(\.userInvocable)
            let resolved = SkillSlashCommandNaming.resolvedSlashTokens(
                forSkillIds: invocableSkills.map(\.id),
                reservedTokens: builtin
            )
            for skill in invocableSkills {
                let token = resolved[skill.id] ?? SkillSlashCommandNaming.slashToken(fromSkillId: skill.repo)
                guard !token.isEmpty, !seen.contains(token) else {
                    continue
                }
                seen.insert(token)
                let desc = Self.skillSlashDescription(for: skill)
                let clipped = desc.count > 240 ? String(desc.prefix(240)) + "…" : desc
                items.append(ChannelSlashCommandItem(name: token, description: clipped, argument: nil))
            }
        }
        return items.sorted { $0.name < $1.name }
    }

    public func projectLinkOptions() async -> [ChannelProjectLinkOption] {
        await store.listProjects()
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ChannelProjectLinkOption(projectId: $0.id, name: $0.name) }
    }

    public func projectLinkAgentOptions(projectId: String) async -> [ChannelProjectLinkAgentOption] {
        guard let normalizedID = normalizedProjectID(projectId),
              let project = await store.project(id: normalizedID)
        else {
            return []
        }
        let board = (try? getActorBoard()) ?? ActorBoardSnapshot(nodes: [], links: [], teams: [])
        let projectActorIDs = projectLinkSelectedActorIDs(project: project, board: board)
        let options = board.nodes.compactMap { node -> (score: Int, option: ChannelProjectLinkAgentOption)? in
            guard node.kind == .agent else {
                return nil
            }
            let linkedAgentId = normalizeWhitespace(node.linkedAgentId ?? "")
            guard !linkedAgentId.isEmpty else {
                return nil
            }
            guard let score = projectLinkSelectionScore(
                node: node,
                linkedAgentId: linkedAgentId,
                selectedActorIDs: projectActorIDs
            ) else {
                return nil
            }
            let channelId = projectLinkChannelId(node: node, linkedAgentId: linkedAgentId)
            return (
                score,
                ChannelProjectLinkAgentOption(
                    actorId: node.id,
                    agentId: linkedAgentId,
                    name: node.displayName,
                    channelId: channelId
                )
            )
        }
        .sorted { left, right in
            if left.score != right.score {
                return left.score < right.score
            }
            return left.option.name.localizedCaseInsensitiveCompare(right.option.name) == .orderedAscending
        }

        var seenRoutes = Set<String>()
        return options.compactMap { entry in
            let key = "\(entry.option.agentId.lowercased())\u{001E}\(entry.option.channelId.lowercased())"
            guard seenRoutes.insert(key).inserted else {
                return nil
            }
            return entry.option
        }
    }

    private func projectLinkSelectedActorIDs(project: ProjectRecord, board: ActorBoardSnapshot) -> Set<String> {
        var selected = Set(
            project.actors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let selectedTeamIDs = Set(
            project.teams
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !selectedTeamIDs.isEmpty else {
            return selected
        }
        for team in board.teams where selectedTeamIDs.contains(team.id.lowercased()) {
            for memberID in team.memberActorIds {
                let normalized = memberID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty {
                    selected.insert(normalized)
                }
            }
        }
        return selected
    }

    private func projectLinkSelectionScore(
        node: ActorNode,
        linkedAgentId: String,
        selectedActorIDs: Set<String>
    ) -> Int? {
        guard !selectedActorIDs.isEmpty else {
            return 2
        }
        let nodeID = node.id.lowercased()
        if selectedActorIDs.contains(nodeID) {
            return 0
        }
        let agentID = linkedAgentId.lowercased()
        let compatibleIDs = [
            agentID,
            "agent:\(agentID)",
            "actor:\(agentID)"
        ]
        return compatibleIDs.contains(where: selectedActorIDs.contains) ? 1 : nil
    }

    private func projectLinkChannelId(node: ActorNode, linkedAgentId: String) -> String {
        let channelId = normalizeWhitespace(node.channelId ?? "")
        if !channelId.isEmpty {
            return channelId
        }
        return "agent:\(linkedAgentId)"
    }

    public func linkProjectChannel(
        projectId: String,
        channelId: String,
        topicId: String?,
        title: String?,
        routeChannelId: String?,
        platform: String?,
        platformChannelId: String?
    ) async -> ChannelProjectLinkResult {
        let baseChannelId = normalizeWhitespace(routeChannelId ?? channelId)
        let scopedChannelId = ChannelGatewayScope.scopedChannelId(baseChannelId: baseChannelId, topicKey: topicId)
        do {
            let result = try await linkProjectChannel(
                projectID: projectId,
                request: ProjectChannelLinkRequest(
                    channelId: scopedChannelId,
                    title: title,
                    ensureSession: true
                )
            )
            try await updateGatewayRouteIfNeeded(
                platform: platform,
                platformChannelId: platformChannelId,
                topicId: topicId,
                routeChannelId: baseChannelId
            )
            return .linked(
                projectId: result.project.id,
                projectName: result.project.name,
                channelId: result.channel.channelId,
                status: result.status
            )
        } catch let conflict as CoreService.ProjectChannelLinkConflict {
            return .conflict(ownerProjectId: conflict.ownerProjectId, ownerProjectName: conflict.ownerProjectName)
        } catch let error as ProjectError {
            if case .notFound = error {
                return .notFound
            }
            return .failed(message: "\(error)")
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func updateGatewayRouteIfNeeded(
        platform: String?,
        platformChannelId: String?,
        topicId: String?,
        routeChannelId: String
    ) async throws {
        let routeChannelId = normalizeWhitespace(routeChannelId)
        guard !routeChannelId.isEmpty,
              let platform = platform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let platformChannelId = platformChannelId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !platformChannelId.isEmpty
        else {
            return
        }

        var config = currentConfig
        switch platform {
        case "telegram":
            guard let chatId = Int64(platformChannelId), var telegram = config.channels.telegram else {
                return
            }
            telegram.channelChatMap[routeChannelId] = chatId
            if let key = telegramTopicRouteKey(chatId: chatId, topicId: topicId) {
                telegram.topicChannelMap[key] = routeChannelId
            }
            config.channels.telegram = telegram
        case "discord":
            guard var discord = config.channels.discord else {
                return
            }
            discord.channelDiscordChannelMap[routeChannelId] = platformChannelId
            config.channels.discord = discord
        default:
            return
        }
        _ = try await updateConfig(config)
    }

    private func telegramTopicRouteKey(chatId: Int64, topicId: String?) -> String? {
        guard let topicId = topicId?.trimmingCharacters(in: .whitespacesAndNewlines), !topicId.isEmpty else {
            return nil
        }
        return "\(chatId):\(topicId)"
    }

    func emitNotificationIfNeeded(from event: EventEnvelope) async {
        switch event.messageType {
        case .workerFailed:
            let reason = extractPayloadString(event.payload, key: "error") ?? "Unknown error"
            let workerId = event.workerId ?? "unknown"
            var metadata: [String: String] = [:]
            if let taskId = event.taskId { metadata["taskId"] = taskId }
            metadata["channelId"] = event.channelId
            if let workerId = event.workerId { metadata["workerId"] = workerId }
            let agentId = parseAgentIdFromChannelId(event.channelId)
            if let agentId { metadata["agentId"] = agentId }
            await notificationService.push(DashboardNotification(
                type: .agentError,
                title: "Worker failed",
                message: reason,
                metadata: metadata
            ))
            logger.warning("Notification emitted: worker \(workerId) failed — \(reason)")

        case .branchConclusion:
            let outcome = extractPayloadString(event.payload, key: "outcome")
            if outcome == "needs_confirmation" || outcome == "escalated" {
                let summary = extractPayloadString(event.payload, key: "summary") ?? "Action requires your approval"
                await notificationService.pushConfirmation(
                    title: "Approval required",
                    message: summary,
                    taskId: event.taskId
                )
            }

        default:
            break
        }
    }

    func extractPayloadString(_ payload: JSONValue, key: String) -> String? {
        if case .object(let dict) = payload, case .string(let value) = dict[key] {
            return value
        }
        return nil
    }

    func parseAgentIdFromChannelId(_ channelId: String) -> String? {
        let prefix = "agent:"
        let sessionMarker = ":session:"
        guard channelId.hasPrefix(prefix) else { return nil }
        let rest = String(channelId.dropFirst(prefix.count))
        if let range = rest.range(of: sessionMarker) {
            let agentId = String(rest[rest.startIndex..<range.lowerBound])
            return agentId.isEmpty ? nil : agentId
        }
        return rest.isEmpty ? nil : rest
    }
}
