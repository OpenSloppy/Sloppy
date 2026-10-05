import Foundation
import PluginSDK
import Protocols

// MARK: - Tool Approvals

enum ToolApprovalPresentationDecision: Sendable, Equatable {
    case approve(ToolApprovalDecisionScope)
    case reject
}

extension CoreService: ToolApprovalBridge {
    func setToolApprovalPresenter(
        _ presenter: (@Sendable (ToolApprovalRecord) async -> ToolApprovalPresentationDecision?)?
    ) {
        toolApprovalPresenter = presenter
    }

    public func listPendingToolApprovals() async -> [ToolApprovalRecord] {
        await toolApprovalService.listPending()
    }

    public func approveToolApproval(id: String, decidedBy: String?) async -> ToolApprovalRecord? {
        await approveToolApproval(id: id, decidedBy: decidedBy, scope: .once)
    }

    public func approveToolApproval(
        id: String,
        decidedBy: String?,
        scope: ToolApprovalDecisionScope,
        decisionReason: String? = nil
    ) async -> ToolApprovalRecord? {
        guard let pending = await toolApprovalService.listPending(includeUnpublished: true).first(where: { $0.id == id }),
              pending.expiresAt > Date() else {
            return nil
        }
        switch scope {
        case .once:
            break
        case .session:
            rememberToolApprovalSessionAllowance(pending)
        case .always:
            do {
                try await toolsAuthorization.rememberApprovalGrants(
                    agentID: pending.agentId,
                    grants: approvalGrants(for: pending)
                )
            } catch {
                logger.error("Failed to save permanent tool approval", metadata: [
                    "approval_id": .string(id),
                    "agent_id": .string(pending.agentId),
                    "error": .string(String(describing: error)),
                ])
                return nil
            }
        }
        guard let record = await toolApprovalService.approve(
            id: id,
            decidedBy: decidedBy,
            decisionReason: decisionReason
        ) else {
            return nil
        }
        _ = await channelDelivery.updateToolApproval(record)
        return record
    }

    public func rejectToolApproval(id: String, decidedBy: String?) async -> ToolApprovalRecord? {
        await rejectToolApproval(id: id, decidedBy: decidedBy, decisionReason: nil)
    }

    func rejectToolApproval(
        id: String,
        decidedBy: String?,
        decisionReason: String?
    ) async -> ToolApprovalRecord? {
        guard let record = await toolApprovalService.reject(
            id: id,
            decidedBy: decidedBy,
            decisionReason: decisionReason
        ) else {
            return nil
        }
        _ = await channelDelivery.updateToolApproval(record)
        return record
    }

    public func resolveToolApproval(id: String, approved: Bool, decidedBy: String?) async -> ToolApprovalRecord? {
        if approved {
            return await approveToolApproval(id: id, decidedBy: decidedBy)
        }
        return await rejectToolApproval(id: id, decidedBy: decidedBy)
    }

    func requestToolApprovalIfNeeded(
        agentID: String,
        sessionID: String?,
        channelID: String?,
        topicID: String?,
        request: ToolInvocationRequest,
        toolCallID: String? = nil,
        requireApproval: Bool,
        approvalSettings: AgentToolApprovalSettings? = nil,
        forcePerInvocation: Bool = false
    ) async -> ToolApprovalWaitResult? {
        guard requireApproval, requiresHumanApproval(toolID: request.tool, arguments: request.arguments) else {
            return nil
        }
        if !forcePerInvocation, await isToolApprovalAllowedForSession(
            agentID: agentID,
            sessionID: sessionID,
            channelID: channelID,
            toolID: request.tool
        ) {
            return nil
        }

        let displaySessionID = toolApprovalDisplaySessionID(agentID: agentID, sessionID: sessionID)
        let record = await toolApprovalService.createPending(
            agentId: agentID,
            sessionId: sessionID,
            displaySessionId: displaySessionID,
            channelId: channelID,
            topicId: topicID,
            toolCallId: toolCallID,
            request: request,
            approvalKind: .riskyTool,
            publishRequest: displaySessionID == nil
        )
        let semanticResolved = await resolveSubagentToolApprovalIfPossible(record)
        if !semanticResolved, displaySessionID != nil {
            await toolApprovalService.publishPendingRequest(id: record.id)
        }
        if !semanticResolved, approvalSettings?.policy != .approveForMe {
            await appendToolApprovalPausedStatusIfNeeded(
                agentID: agentID,
                sessionID: sessionID,
                displaySessionID: displaySessionID,
                record: record
            )
            if let waitingSessionID = displaySessionID ?? sessionID {
                await markTaskWaitingInputForAgentSession(
                    agentID: agentID,
                    sessionID: waitingSessionID,
                    reason: "Tool approval required for \(request.tool).",
                    source: "agent"
                )
            }
        }
        if !semanticResolved {
            _ = await channelDelivery.presentToolApproval(record)
            await resolveToolApproval(record, approvalSettings: approvalSettings)
        }
        let result = await toolApprovalService.waitForDecision(id: record.id)
        if case .timedOut(let timedOut) = result {
            _ = await channelDelivery.updateToolApproval(timedOut)
        }
        return result
    }

    func toolApprovalDeniedResult(tool: String, approval: ToolApprovalWaitResult) -> ToolInvocationResult? {
        switch approval {
        case .approved:
            return nil
        case .rejected(let record):
            var data: [String: JSONValue] = [
                "approvalId": .string(record.id),
                "status": .string(record.status.rawValue),
            ]
            if let decidedBy = record.decidedBy {
                data["decidedBy"] = .string(decidedBy)
            }
            if let decisionReason = record.decisionReason {
                data["decisionReason"] = .string(decisionReason)
            }
            return ToolInvocationResult(
                tool: tool,
                ok: false,
                data: .object(data),
                error: ToolErrorPayload(
                    code: "tool_approval_rejected",
                    message: "Tool call was rejected by the approval reviewer.",
                    retryable: false
                )
            )
        case .timedOut(let record):
            return ToolInvocationResult(
                tool: tool,
                ok: false,
                data: .object([
                    "approvalId": .string(record.id),
                    "status": .string(ToolApprovalStatus.timedOut.rawValue)
                ]),
                error: ToolErrorPayload(
                    code: "tool_approval_timeout",
                    message: "Tool approval timed out before a human approved it.",
                    retryable: false
                )
            )
        }
    }

    func requiresHumanApproval(toolID rawToolID: String, arguments: [String: JSONValue]) -> Bool {
        let toolID = rawToolID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !toolID.isEmpty else { return false }

        let exactRisky: Set<String> = [
            "files.write",
            "files.edit",
            "runtime.exec",
            "project.create",
            "project.update",
            "project.delete",
            "project.task_create",
            "project.task_update",
            "project.task_cancel",
            "project.task_clarification_create",
            "project.escalate_to_user",
            "project.meta_memory_set",
            "memory.save",
            "messages.send",
            "sessions.spawn",
            "agents.delegate_task",
            "agent.documents.set_user_markdown",
            "agent.documents.set_memory_markdown",
            "branches.spawn",
            "workers.spawn",
            "workers.route",
            "actor.discuss_with_actor",
            "actor.conclude_discussion",
            "skills.install",
            "skills.uninstall",
            "cron",
            "mcp.call_tool",
            "mcp.save_server",
            "mcp.remove_server",
            "mcp.install_server",
            "mcp.uninstall_server"
        ]
        if exactRisky.contains(toolID) {
            return true
        }

        if toolID == "runtime.process" {
            let action = arguments["action"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return action == nil || action == "start" || action == "stop"
        }

        if toolID == "workspace.transaction.apply" {
            let deleteCount = arguments["operations"]?.asArray?.reduce(into: 0) { count, operation in
                guard operation.asObject?["type"]?.asString == WorkspaceOperationKind.deleteElement.rawValue else {
                    return
                }
                count += 1
            } ?? 0
            return deleteCount >= 10
        }

        if toolID.hasPrefix("mcp.") {
            let safeTools: Set<String> = [
                "mcp.list_servers",
                "mcp.list_tools",
                "mcp.list_resources",
                "mcp.read_resource",
                "mcp.list_prompts",
                "mcp.get_prompt"
            ]
            return !safeTools.contains(toolID)
        }

        return false
    }

    func requestMissingAccessApproval(
        agentID: String,
        sessionID: String?,
        channelID: String?,
        topicID: String?,
        request: ToolInvocationRequest,
        grants: [ToolApprovalGrant]
    ) async -> ToolApprovalWaitResult {
        let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.reason
            : missingAccessApprovalReason(tool: request.tool, grants: grants)
        let approvalRequest = ToolInvocationRequest(
            tool: request.tool,
            arguments: request.arguments,
            reason: reason,
            argumentDiagnostics: request.argumentDiagnostics
        )
        let displaySessionID = toolApprovalDisplaySessionID(agentID: agentID, sessionID: sessionID)
        let record = await toolApprovalService.createPending(
            agentId: agentID,
            sessionId: sessionID,
            displaySessionId: displaySessionID,
            channelId: channelID,
            topicId: topicID,
            request: approvalRequest,
            approvalKind: .missingAccess,
            grants: grants,
            publishRequest: displaySessionID == nil
        )
        let approvalSettings = try? await toolsAuthorization.policy(agentID: agentID).approval
        let semanticResolved = await resolveSubagentToolApprovalIfPossible(record)
        if !semanticResolved, displaySessionID != nil {
            await toolApprovalService.publishPendingRequest(id: record.id)
        }
        if !semanticResolved, approvalSettings?.policy != .approveForMe {
            await appendToolApprovalPausedStatusIfNeeded(
                agentID: agentID,
                sessionID: sessionID,
                displaySessionID: displaySessionID,
                record: record
            )
            if let waitingSessionID = displaySessionID ?? sessionID {
                await markTaskWaitingInputForAgentSession(
                    agentID: agentID,
                    sessionID: waitingSessionID,
                    reason: "Access approval required for \(request.tool).",
                    source: "agent"
                )
            }
        }
        if !semanticResolved {
            _ = await channelDelivery.presentToolApproval(record)
            await resolveToolApproval(record, approvalSettings: approvalSettings)
        }
        let result = await toolApprovalService.waitForDecision(id: record.id)
        if case .timedOut(let timedOut) = result {
            _ = await channelDelivery.updateToolApproval(timedOut)
        }
        return result
    }

    private func resolveToolApprovalThroughPresenter(_ record: ToolApprovalRecord) async {
        guard let toolApprovalPresenter,
              let decision = await toolApprovalPresenter(record)
        else {
            return
        }
        switch decision {
        case .approve(let scope):
            _ = await approveToolApproval(id: record.id, decidedBy: "acp", scope: scope)
        case .reject:
            _ = await rejectToolApproval(id: record.id, decidedBy: "acp")
        }
    }

    private func resolveToolApproval(
        _ record: ToolApprovalRecord,
        approvalSettings: AgentToolApprovalSettings?
    ) async {
        guard approvalSettings?.policy == .approveForMe,
              let reviewerAgentID = approvalSettings?.reviewerAgentId
        else {
            await resolveToolApprovalThroughPresenter(record)
            return
        }

        let decision = await reviewToolApproval(record, reviewerAgentID: reviewerAgentID)
        switch decision {
        case .approve(let reason):
            _ = await approveToolApproval(
                id: record.id,
                decidedBy: "agent:\(reviewerAgentID)",
                scope: .once,
                decisionReason: reason
            )
        case .reject(let reason):
            _ = await rejectToolApproval(
                id: record.id,
                decidedBy: "agent:\(reviewerAgentID)",
                decisionReason: reason
            )
        case nil:
            _ = await rejectToolApproval(
                id: record.id,
                decidedBy: "agent:\(reviewerAgentID)",
                decisionReason: "Reviewer failed to return a valid decision."
            )
        }
    }

    private func reviewToolApproval(
        _ record: ToolApprovalRecord,
        reviewerAgentID: String
    ) async -> ToolApprovalAgentReviewDecision? {
        if let toolApprovalAgentReviewOverride {
            return await toolApprovalAgentReviewOverride(record, reviewerAgentID)
        }
        guard let provider = modelProvider,
              let reviewer = try? getAgentConfig(agentID: reviewerAgentID),
              reviewer.runtime.type == .native,
              let model = reviewer.selectedModel ?? provider.supportedModels.first
        else {
            logger.warning("Tool approval agent reviewer is unavailable", metadata: [
                "reviewer_agent_id": .string(reviewerAgentID),
                "approval_id": .string(record.id),
            ])
            return nil
        }
        do {
            return try await ToolApprovalAgentReviewer(
                provider: provider,
                model: model,
                reviewer: reviewer,
                delegationContext: subagentToolApprovalContext(record)
            ).review(record)
        } catch {
            logger.warning("Tool approval agent review failed", metadata: [
                "reviewer_agent_id": .string(reviewerAgentID),
                "approval_id": .string(record.id),
                "error": .string(error.localizedDescription),
            ])
            return nil
        }
    }

    func setToolApprovalAgentReviewOverride(
        _ reviewer: (@Sendable (ToolApprovalRecord, String) async -> ToolApprovalAgentReviewDecision?)?
    ) {
        toolApprovalAgentReviewOverride = reviewer
    }

    func applyApprovalGrants(
        _ grants: [ToolApprovalGrant],
        to policy: AgentToolsPolicy,
        matchingToolID: String? = nil
    ) -> AgentToolsPolicy {
        var updated = policy
        let requestedToolID = matchingToolID.map(normalizedToolApprovalToolID)
        for grant in grants {
            let toolID = normalizedToolApprovalToolID(grant.tool)
            if let requestedToolID, !requestedToolID.isEmpty, toolID != requestedToolID {
                continue
            }
            switch grant.kind {
            case .tool:
                if !toolID.isEmpty {
                    updated.tools[toolID] = true
                }
            case .directory:
                guard let resource = normalizedApprovalResource(grant.resource), !resource.isEmpty else {
                    continue
                }
                if grant.operation == "exec" {
                    appendUniqueRoot(resource, to: &updated.guardrails.allowedExecRoots)
                } else {
                    appendUniqueRoot(resource, to: &updated.guardrails.allowedWriteRoots)
                }
            }
        }
        return updated
    }

    private func approvalGrants(for record: ToolApprovalRecord) -> [ToolApprovalGrant] {
        record.grants.isEmpty
            ? [ToolApprovalGrant(kind: .tool, tool: normalizedToolApprovalToolID(record.tool))]
            : record.grants.map(normalizedApprovalGrant)
    }

    private func rememberToolApprovalSessionAllowance(_ record: ToolApprovalRecord) {
        guard let scopeID = toolApprovalSessionScopeID(sessionID: record.sessionId, channelID: record.channelId) else {
            return
        }
        let key = toolApprovalSessionAllowanceKey(agentID: record.agentId, scopeID: scopeID)
        var allowedGrants = toolApprovalSessionAllowances[key] ?? []
        let grants = approvalGrants(for: record)
        for grant in grants {
            allowedGrants.insert(grant)
        }
        toolApprovalSessionAllowances[key] = allowedGrants
    }

    func isToolApprovalAllowedForSession(
        agentID: String,
        sessionID: String?,
        channelID: String?,
        toolID: String
    ) async -> Bool {
        let allowedGrants = await sessionApprovalGrants(
            agentID: agentID, sessionID: sessionID, channelID: channelID
        )
        let normalizedTool = normalizedToolApprovalToolID(toolID)
        return allowedGrants.contains { grant in
            grant.kind == .tool && normalizedToolApprovalToolID(grant.tool) == normalizedTool
        }
    }

    func setSessionToolApprovalBypass(sessionID: String, enabled: Bool) {
        guard let sessionID = normalizedSessionID(sessionID) else {
            return
        }
        if enabled {
            sessionToolApprovalBypass.insert(sessionID)
        } else {
            sessionToolApprovalBypass.remove(sessionID)
        }
    }

    func setSessionToolApprovalRequired(sessionID: String, enabled: Bool) {
        guard let sessionID = normalizedSessionID(sessionID) else {
            return
        }
        if enabled {
            sessionToolApprovalRequired.insert(sessionID)
        } else {
            sessionToolApprovalRequired.remove(sessionID)
        }
    }

    func sessionApprovalGrants(
        agentID: String,
        sessionID: String?,
        channelID: String?
    ) async -> [ToolApprovalGrant] {
        let persistent = (try? await toolsAuthorization.policy(agentID: agentID).approvalGrants) ?? []
        guard let scopeID = toolApprovalSessionScopeID(sessionID: sessionID, channelID: channelID) else {
            return persistent
        }
        let key = toolApprovalSessionAllowanceKey(agentID: agentID, scopeID: scopeID)
        return persistent + Array(toolApprovalSessionAllowances[key] ?? [])
    }

    private func toolApprovalSessionScopeID(sessionID: String?, channelID: String?) -> String? {
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            return "session:\(sessionID)"
        }
        if let channelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines), !channelID.isEmpty {
            return "channel:\(channelID)"
        }
        return nil
    }

    private func toolApprovalSessionAllowanceKey(agentID: String, scopeID: String) -> String {
        "\(agentID)\n\(scopeID)"
    }

    private func normalizedToolApprovalToolID(_ toolID: String) -> String {
        toolID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedApprovalGrant(_ grant: ToolApprovalGrant) -> ToolApprovalGrant {
        ToolApprovalGrant(
            kind: grant.kind,
            tool: normalizedToolApprovalToolID(grant.tool),
            operation: grant.operation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            resource: normalizedApprovalResource(grant.resource)
        )
    }

    private func normalizedApprovalResource(_ resource: String?) -> String? {
        guard let trimmed = resource?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func appendUniqueRoot(_ root: String, to roots: inout [String]) {
        guard !roots.contains(root) else {
            return
        }
        roots.append(root)
    }

    private func missingAccessApprovalReason(tool: String, grants: [ToolApprovalGrant]) -> String {
        let resources = grants.compactMap(\.resource)
        if let first = resources.first {
            return "Allow \(tool) to access \(first)."
        }
        return "Allow access to \(tool)."
    }

    private func toolApprovalDisplaySessionID(agentID: String, sessionID: String?) -> String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let detail = try? getAgentSession(agentID: agentID, sessionID: sessionID),
              let parentSessionID = detail.summary.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentSessionID.isEmpty
        else {
            return nil
        }
        return parentSessionID
    }

    private func appendToolApprovalPausedStatusIfNeeded(
        agentID: String,
        sessionID: String?,
        displaySessionID: String?,
        record: ToolApprovalRecord
    ) async {
        await appendToolApprovalPausedStatus(agentID: agentID, sessionID: sessionID, record: record)
        let sourceSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displaySessionID,
              displaySessionID != sourceSessionID
        else {
            return
        }
        await appendToolApprovalPausedStatus(agentID: agentID, sessionID: displaySessionID, record: record)
    }

    private func appendToolApprovalPausedStatus(
        agentID: String,
        sessionID: String?,
        record: ToolApprovalRecord
    ) async {
        guard let sessionID else {
            return
        }
        let details = record.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.reason!
            : "Tool: \(record.tool)"
        let event = AgentSessionEvent(
            agentId: agentID,
            sessionId: sessionID,
            type: .runStatus,
            runStatus: AgentRunStatusEvent(
                stage: .paused,
                label: "Tool approval required",
                details: details
            )
        )
        guard let summary = try? sessionStore.appendEvents(agentID: agentID, sessionID: sessionID, events: [event]) else {
            return
        }
        publishLiveSessionEvents(agentID: agentID, sessionID: sessionID, summary: summary, events: [event])
    }
}
