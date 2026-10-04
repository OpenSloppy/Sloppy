import Foundation
import Protocols

// MARK: - Cron Tasks

extension CoreService {
    func makeCronRunner() -> CronRunner {
        CronRunner(
            store: store,
            taskExecutor: { [weak self] task, request in
                guard let self else { return }
                try await self.executeAgentCronTask(task, request: request)
            },
            notificationService: notificationService,
            logger: logger
        )
    }

    func executeAgentCronTask(_ task: AgentCronTask, request: ChannelMessageRequest) async throws {
        let target = task.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID: String
        if let parsed = Self.parseAgentSessionChannelId(target) {
            guard parsed.agentID == task.agentId,
                  target == sessionChannelID(agentID: parsed.agentID, sessionID: parsed.sessionID) else {
                throw AgentCronTaskError.invalidPayload
            }
            sessionID = parsed.sessionID
        } else if target.hasPrefix("session-") {
            // The scheduled-task editor and older jobs also store bare session IDs.
            sessionID = target
        } else if target.isEmpty || target == "main" || target == "agent:\(task.agentId)" {
            sessionID = try await createAgentSession(
                agentID: task.agentId,
                request: AgentSessionCreateRequest(title: "Cron: \(task.command.prefix(80))")
            ).id
        } else {
            guard !target.hasPrefix("agent:") else { throw AgentCronTaskError.invalidPayload }
            _ = await postChannelMessage(channelId: target, request: request)
            return
        }

        let detail = try getAgentSession(agentID: task.agentId, sessionID: sessionID)
        var userID = request.userId
        if detail.summary.kind == .longChat {
            userID = try getLongChat(agentID: task.agentId, sessionID: sessionID).userId
        } else if let (conversation, _) = longChatParent(of: sessionID) {
            userID = conversation.userId
        }
        _ = try await postAgentSessionMessage(
            agentID: task.agentId,
            sessionID: sessionID,
            request: AgentSessionPostMessageRequest(
                userId: userID,
                content: request.content,
                reasoningEffort: request.reasoningEffort,
                selectedModel: request.model
            )
        )
    }

    public func listAgentCronTasks(agentID: String) async throws -> [AgentCronTask] {
        guard !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCronTaskError.invalidAgentID
        }
        return await store.listCronTasks(agentId: agentID)
    }

    public func createAgentCronTask(agentID: String, request: AgentCronTaskCreateRequest) async throws -> AgentCronTask {
        guard !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCronTaskError.invalidAgentID
        }
        guard CronEvaluator.isValid(cronExpression: request.schedule),
              !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCronTaskError.invalidPayload
        }
        let task = AgentCronTask(
            id: UUID().uuidString,
            agentId: agentID,
            channelId: request.channelId,
            schedule: request.schedule,
            command: request.command,
            enabled: request.enabled ?? true
        )
        await store.saveCronTask(task)
        return task
    }

    public func updateAgentCronTask(agentID: String, cronID: String, request: AgentCronTaskUpdateRequest) async throws -> AgentCronTask {
        guard let existing = await store.cronTask(id: cronID), existing.agentId == agentID else {
            throw AgentCronTaskError.notFound
        }
        var updated = existing
        if let schedule = request.schedule { updated.schedule = schedule }
        if let command = request.command { updated.command = command }
        if let channelId = request.channelId { updated.channelId = channelId }
        if let enabled = request.enabled { updated.enabled = enabled }
        guard CronEvaluator.isValid(cronExpression: updated.schedule),
              !updated.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCronTaskError.invalidPayload
        }
        updated.updatedAt = Date()
        await store.saveCronTask(updated)
        return updated
    }

    public func deleteAgentCronTask(agentID: String, cronID: String) async throws {
        guard let existing = await store.cronTask(id: cronID), existing.agentId == agentID else {
            throw AgentCronTaskError.notFound
        }
        await store.deleteCronTask(id: cronID)
    }
}
