import Foundation
import Logging
import Protocols
import Tracing

// MARK: - Tool Invocation

extension CoreService {
    public func invokeTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest
    ) async throws -> ToolInvocationResult {
        let result = await invokeToolFromRuntime(agentID: agentID, sessionID: sessionID, request: request)
        if result.ok || result.error?.code != "tool_forbidden" {
            return result
        }
        throw ToolInvocationError.forbidden(result.error ?? .init(code: "tool_forbidden", message: "Forbidden", retryable: false))
    }

    /// Internal runtime path used by auto tool-calling loop.
    public func invokeToolFromRuntime(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest,
        recordSessionEvents: Bool = true,
        requireApproval: Bool = false,
        chatMode: AgentChatMode? = nil
    ) async -> ToolInvocationResult {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_session_id", message: "Invalid session id.", retryable: false)
            )
        }
        guard !request.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_tool", message: "Tool id is required.", retryable: false)
            )
        }

        let sessionDetail: AgentSessionDetail
        do {
            _ = try getAgent(id: normalizedAgentID)
            sessionDetail = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch let error as AgentStorageError {
            if case .notFound = error {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
                )
            }
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "session_not_found", message: "Session not found.", retryable: false)
            )
        }

        var authorization: ToolAuthorizationDecision
        do {
            authorization = try await toolsAuthorization.authorize(
                agentID: normalizedAgentID,
                toolID: request.tool,
                enforceRateLimit: !sessionToolUsageLimitBypass.contains(normalizedSessionID)
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "authorization_failed", message: "Failed to authorize tool call.", retryable: true)
            )
        }

        let trimmedToolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToolID == "planning.request_input" {
            return await handleAgentPlanInputTool(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request,
                chatMode: chatMode
            )
        }
        if trimmedToolID == "planning.progress_update" {
            return await handleAgentBuildProgressTool(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request,
                chatMode: chatMode
            )
        }

        var missingAccessApprovalGranted = false
        if !authorization.allowed,
           await isToolApprovalAllowedForSession(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            channelID: nil,
            toolID: trimmedToolID
           ) {
            authorization = ToolAuthorizationDecision(
                allowed: true,
                policy: applyApprovalGrants(
                    [ToolApprovalGrant(kind: .tool, tool: trimmedToolID)],
                    to: authorization.policy,
                    matchingToolID: trimmedToolID
                ),
                error: nil
            )
        }
        if !authorization.allowed,
           authorization.error?.code == "tool_forbidden",
           let accessState = await requestMissingAccessApprovalIfNeeded(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            channelID: nil,
            topicID: nil,
            request: request,
            grants: [ToolApprovalGrant(kind: .tool, tool: trimmedToolID)] + missingDirectoryApprovalGrants(
                for: request,
                policy: authorization.policy,
                currentDirectoryURL: nil
            )
           ) {
            if let deniedResult = toolApprovalDeniedResult(tool: request.tool, approval: accessState.result) {
                return deniedResult
            }
            authorization = ToolAuthorizationDecision(
                allowed: true,
                policy: applyApprovalGrants(accessState.grants, to: authorization.policy, matchingToolID: trimmedToolID),
                error: nil
            )
            missingAccessApprovalGranted = true
        }

        if authorization.allowed,
           let allowOverlay = sessionSubagentToolAllowList[normalizedSessionID],
           !allowOverlay.isEmpty,
           !allowOverlay.contains(trimmedToolID) {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(
                    code: "tool_forbidden",
                    message: "Tool '\(trimmedToolID)' is not available in this subagent session.",
                    retryable: false
                )
            )
        }

        let sessionToolContext = await toolContextForSession(
            sessionID: normalizedSessionID,
            sessionTitle: sessionDetail.summary.title,
            projectID: sessionDetail.summary.projectId,
            taskID: sessionDetail.summary.taskId
        )
        await ensureDebugDirectoryForSessionIfNeeded(
            chatMode: chatMode,
            sessionID: normalizedSessionID,
            sessionTitle: sessionDetail.summary.title,
            projectID: sessionDetail.summary.projectId,
            fallbackWorkingDirectory: sessionToolContext.workingDirectory
        )

        var effectivePolicy = authorization.policy
        let approvalSessionGrants = await sessionApprovalGrants(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            channelID: nil
        )
        effectivePolicy = applyApprovalGrants(
            approvalSessionGrants,
            to: effectivePolicy,
            matchingToolID: trimmedToolID
        )
        if authorization.allowed,
           !sessionToolContext.extraRoots.isEmpty {
            effectivePolicy.guardrails.allowedExecRoots += sessionToolContext.extraRoots
            effectivePolicy.guardrails.allowedWriteRoots += sessionToolContext.extraRoots
        } else if authorization.allowed,
           let extraRoots = sessionExtraRoots[normalizedSessionID],
           !extraRoots.isEmpty {
            effectivePolicy.guardrails.allowedExecRoots += extraRoots
            effectivePolicy.guardrails.allowedWriteRoots += extraRoots
        }
        let currentDirectoryURL = sessionToolContext.workingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        var effectiveRequest = request
        if authorization.allowed {
            let missingGrants = missingDirectoryApprovalGrants(
                for: request,
                policy: effectivePolicy,
                currentDirectoryURL: currentDirectoryURL
            )
            if !missingGrants.isEmpty,
               let accessState = await requestMissingAccessApprovalIfNeeded(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                channelID: nil,
                topicID: nil,
                request: request,
                grants: missingGrants
               ) {
                if let deniedResult = toolApprovalDeniedResult(tool: request.tool, approval: accessState.result) {
                    return deniedResult
                }
                effectivePolicy = applyApprovalGrants(accessState.grants, to: effectivePolicy, matchingToolID: trimmedToolID)
                missingAccessApprovalGranted = true
            } else if matchingSessionDirectoryApprovalGrant(
                in: approvalSessionGrants,
                for: request,
                currentDirectoryURL: currentDirectoryURL
            ) {
                missingAccessApprovalGranted = true
            }
        }
        var preHookBlockedResult: ToolInvocationResult?
        if authorization.allowed {
            switch await toolPreHookService.evaluate(
                globalConfig: currentConfig.toolHooks.preTools,
                agentOverride: effectivePolicy.preToolsHook,
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                channelID: nil,
                source: .agentSession,
                request: request,
                workingDirectory: sessionToolContext.workingDirectory,
                workspaceRootURL: workspaceRootURL
            ) {
            case .allow(let rewritten):
                effectiveRequest = rewritten
            case .block(let blocked):
                preHookBlockedResult = blocked
            }
        }

        let loopGuardEnabled = !currentConfig.experimentalFlags.disableToolBudgetAndLoopGuard
        let loopDecision: ToolLoopGuard.Decision
        if loopGuardEnabled, authorization.allowed, preHookBlockedResult == nil {
            loopDecision = await toolLoopGuard.evaluate(
                sessionID: normalizedSessionID,
                request: effectiveRequest,
                policy: effectivePolicy,
                workspaceRootURL: workspaceRootURL,
                currentDirectoryURL: currentDirectoryURL
            )
        } else {
            loopDecision = .allow(signature: "")
        }

        let toolCallEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            type: .toolCall,
            toolCall: AgentToolCallEvent(
                tool: effectiveRequest.tool,
                arguments: effectiveRequest.arguments,
                reason: effectiveRequest.reason,
                argumentDiagnostics: effectiveRequest.argumentDiagnostics
            )
        )

        if recordSessionEvents, preHookBlockedResult == nil {
            do {
                let summary = try sessionStore.appendEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    events: [toolCallEvent]
                )
                publishLiveSessionEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    summary: summary,
                    events: [toolCallEvent]
                )
                await applyPetProgressForAgentSessionEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    summary: summary,
                    events: [toolCallEvent]
                )
            } catch {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "session_write_failed", message: "Failed to persist tool call event.", retryable: true)
                )
            }
        }

        var result: ToolInvocationResult
        if authorization.allowed {
            if let preHookBlockedResult {
                result = preHookBlockedResult
            } else {
                switch loopDecision {
                case .block(let message):
                    result = .init(
                        tool: effectiveRequest.tool,
                        ok: false,
                        error: .init(
                            code: "tool_loop_detected",
                            message: message,
                            retryable: false,
                            hint: "Change the command or arguments, or summarize the blocker instead of retrying the same tool call."
                        )
                    )

                case .allow:
                    if let approval = await requestToolApprovalIfNeeded(
                        agentID: normalizedAgentID,
                        sessionID: normalizedSessionID,
                        channelID: nil,
                        topicID: nil,
                        request: effectiveRequest,
                        toolCallID: toolCallEvent.id,
                        requireApproval: !missingAccessApprovalGranted &&
                            !sessionToolApprovalBypass.contains(normalizedSessionID) &&
                            (requireApproval || effectivePolicy.approval.enabled ||
                                sessionToolApprovalRequired.contains(normalizedSessionID)),
                        approvalSettings: effectivePolicy.approval
                    ), let deniedResult = toolApprovalDeniedResult(tool: effectiveRequest.tool, approval: approval) {
                        result = deniedResult
                        break
                    }
                    if loopGuardEnabled {
                        await toolLoopGuard.recordStarted(
                            sessionID: normalizedSessionID,
                            request: effectiveRequest,
                            policy: effectivePolicy,
                            workspaceRootURL: workspaceRootURL,
                            currentDirectoryURL: currentDirectoryURL
                        )
                    }
                    let toolExecution = self.toolExecution
                    let invocationPolicy = effectivePolicy
                    let invocationRequest = effectiveRequest
                    let timeoutMs = toolInvocationHardTimeoutMs(request: invocationRequest, policy: invocationPolicy)
                    result = await runToolInvocationWithHardTimeout(
                        toolID: invocationRequest.tool,
                        timeoutMs: timeoutMs
                    ) {
                        await withSpan("tool.invoke", ofKind: .internal) { span in
                            span.attributes["agent_id"] = "\(normalizedAgentID)"
                            span.attributes["session_id"] = "\(normalizedSessionID)"
                            span.attributes["tool_id"] = "\(invocationRequest.tool)"
                            return await toolExecution.invoke(
                                agentID: normalizedAgentID,
                                sessionID: normalizedSessionID,
                                request: invocationRequest,
                                policy: invocationPolicy,
                                currentProjectID: sessionDetail.summary.projectId,
                                currentDirectoryURL: currentDirectoryURL
                            )
                        }
                    }
                    if loopGuardEnabled {
                        let correctionExhausted = await toolLoopGuard.recordResult(
                            sessionID: normalizedSessionID,
                            request: effectiveRequest,
                            result: result,
                            policy: effectivePolicy,
                            workspaceRootURL: workspaceRootURL,
                            currentDirectoryURL: currentDirectoryURL
                        )
                        if correctionExhausted { result = toolArgumentCorrectionExhausted(result) }
                    }
                }
            }
        } else {
            result = .init(
                tool: request.tool,
                ok: false,
                error: authorization.error ?? .init(code: "tool_forbidden", message: "Tool is forbidden.", retryable: false)
            )
        }

        let toolResultEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            type: .toolResult,
            toolResult: AgentToolResultEvent(
                tool: result.tool,
                ok: result.ok,
                data: result.data,
                error: result.error,
                durationMs: result.durationMs
            )
        )

        if recordSessionEvents {
            do {
                var eventsToAppend: [AgentSessionEvent] = []
                if result.error?.code == "tool_loop_detected" {
                    eventsToAppend.append(
                        AgentSessionEvent(
                            agentId: normalizedAgentID,
                            sessionId: normalizedSessionID,
                            type: .runStatus,
                            runStatus: AgentRunStatusEvent(
                                stage: .paused,
                                label: "Loop blocked",
                                details: result.error?.message ?? "Loop blocked: repeated identical tool call."
                            )
                        )
                    )
                } else if result.error?.code == "tool_timeout" {
                    eventsToAppend.append(
                        AgentSessionEvent(
                            agentId: normalizedAgentID,
                            sessionId: normalizedSessionID,
                            type: .runStatus,
                            runStatus: AgentRunStatusEvent(
                                stage: .paused,
                                label: "Tool timed out",
                                details: result.error?.message ?? "Tool timed out."
                            )
                        )
                    )
                }
                eventsToAppend.append(toolResultEvent)
                let summary = try sessionStore.appendEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    events: eventsToAppend
                )
                publishLiveSessionEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    summary: summary,
                    events: eventsToAppend
                )
                await applyPetProgressForAgentSessionEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    summary: summary,
                    events: eventsToAppend
                )
            } catch {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "session_write_failed", message: "Failed to persist tool result event.", retryable: true)
                )
            }
        }

        await persistToolInvocationAnalytics(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            sessionTitle: sessionDetail.summary.title,
            toolId: result.tool,
            ok: result.ok,
            durationMs: result.durationMs
        )

        return result
    }

    /// Internal runtime path used by gateway/channel sessions linked to an agent.
    public func invokeToolFromChannelRuntime(
        agentID: String,
        channelID: String,
        request: ToolInvocationRequest,
        topicID: String? = nil,
        requireApproval: Bool = false,
        chatMode: AgentChatMode? = nil
    ) async -> ToolInvocationResult {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        }
        guard !request.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_tool", message: "Tool id is required.", retryable: false)
            )
        }

        do {
            _ = try getAgent(id: normalizedAgentID)
        } catch let error as AgentStorageError {
            if case .notFound = error {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
                )
            }
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
            )
        }

        var authorization: ToolAuthorizationDecision
        do {
            authorization = try await toolsAuthorization.authorize(agentID: normalizedAgentID, toolID: request.tool)
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "authorization_failed", message: "Failed to authorize tool call.", retryable: true)
            )
        }

        let trimmedToolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToolID == "planning.request_input" {
            return await handleChannelPlanInputTool(
                agentID: normalizedAgentID,
                channelID: channelID,
                request: request,
                topicID: topicID,
                chatMode: chatMode
            )
        }
        if trimmedToolID == "planning.progress_update" {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(
                    code: "agent_session_required",
                    message: "`planning.progress_update` is only available in agent sessions.",
                    retryable: false
                )
            )
        }

        var missingAccessApprovalGranted = false
        if !authorization.allowed,
           await isToolApprovalAllowedForSession(
            agentID: normalizedAgentID,
            sessionID: nil,
            channelID: channelID,
            toolID: trimmedToolID
           ) {
            authorization = ToolAuthorizationDecision(
                allowed: true,
                policy: applyApprovalGrants(
                    [ToolApprovalGrant(kind: .tool, tool: trimmedToolID)],
                    to: authorization.policy,
                    matchingToolID: trimmedToolID
                ),
                error: nil
            )
        }
        if !authorization.allowed,
           authorization.error?.code == "tool_forbidden",
           let accessState = await requestMissingAccessApprovalIfNeeded(
            agentID: normalizedAgentID,
            sessionID: nil,
            channelID: channelID,
            topicID: topicID,
            request: request,
            grants: [ToolApprovalGrant(kind: .tool, tool: trimmedToolID)] + missingDirectoryApprovalGrants(
                for: request,
                policy: authorization.policy,
                currentDirectoryURL: nil
            )
           ) {
            if let deniedResult = toolApprovalDeniedResult(tool: request.tool, approval: accessState.result) {
                return deniedResult
            }
            authorization = ToolAuthorizationDecision(
                allowed: true,
                policy: applyApprovalGrants(accessState.grants, to: authorization.policy, matchingToolID: trimmedToolID),
                error: nil
            )
            missingAccessApprovalGranted = true
        }

        var effectivePolicy = authorization.policy
        let approvalSessionGrants = await sessionApprovalGrants(
            agentID: normalizedAgentID,
            sessionID: nil,
            channelID: channelID
        )
        effectivePolicy = applyApprovalGrants(
            approvalSessionGrants,
            to: effectivePolicy,
            matchingToolID: trimmedToolID
        )
        let channelToolContext = await toolContextForChannel(channelID: channelID)
        if authorization.allowed, !channelToolContext.extraRoots.isEmpty {
            effectivePolicy.guardrails.allowedExecRoots += channelToolContext.extraRoots
            effectivePolicy.guardrails.allowedWriteRoots += channelToolContext.extraRoots
        }
        let currentDirectoryURL = channelToolContext.workingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        var effectiveRequest = request
        if authorization.allowed {
            let missingGrants = missingDirectoryApprovalGrants(
                for: request,
                policy: effectivePolicy,
                currentDirectoryURL: currentDirectoryURL
            )
            if !missingGrants.isEmpty,
               let accessState = await requestMissingAccessApprovalIfNeeded(
                agentID: normalizedAgentID,
                sessionID: nil,
                channelID: channelID,
                topicID: topicID,
                request: request,
                grants: missingGrants
               ) {
                if let deniedResult = toolApprovalDeniedResult(tool: request.tool, approval: accessState.result) {
                    return deniedResult
                }
                effectivePolicy = applyApprovalGrants(accessState.grants, to: effectivePolicy, matchingToolID: trimmedToolID)
                missingAccessApprovalGranted = true
            } else if matchingSessionDirectoryApprovalGrant(
                in: approvalSessionGrants,
                for: request,
                currentDirectoryURL: currentDirectoryURL
            ) {
                missingAccessApprovalGranted = true
            }
        }
        var preHookBlockedResult: ToolInvocationResult?
        if authorization.allowed {
            switch await toolPreHookService.evaluate(
                globalConfig: currentConfig.toolHooks.preTools,
                agentOverride: effectivePolicy.preToolsHook,
                agentID: normalizedAgentID,
                sessionID: nil,
                channelID: channelID,
                source: .channelRuntime,
                request: request,
                workingDirectory: channelToolContext.workingDirectory,
                workspaceRootURL: workspaceRootURL
            ) {
            case .allow(let rewritten):
                effectiveRequest = rewritten
            case .block(let blocked):
                preHookBlockedResult = blocked
            }
        }

        let loopGuardEnabled = !currentConfig.experimentalFlags.disableToolBudgetAndLoopGuard
        let loopDecision: ToolLoopGuard.Decision
        if loopGuardEnabled, authorization.allowed, preHookBlockedResult == nil {
            loopDecision = await toolLoopGuard.evaluate(
                sessionID: channelID,
                request: effectiveRequest,
                policy: effectivePolicy,
                workspaceRootURL: workspaceRootURL,
                currentDirectoryURL: currentDirectoryURL
            )
        } else {
            loopDecision = .allow(signature: "")
        }

        var result: ToolInvocationResult
        if authorization.allowed {
            if let preHookBlockedResult {
                result = preHookBlockedResult
            } else {
                switch loopDecision {
                case .block(let message):
                    result = .init(
                        tool: effectiveRequest.tool,
                        ok: false,
                        error: .init(
                            code: "tool_loop_detected",
                            message: message,
                            retryable: false,
                            hint: "Change the command or arguments, or summarize the blocker instead of retrying the same tool call."
                        )
                    )

                case .allow:
                    if let approval = await requestToolApprovalIfNeeded(
                        agentID: normalizedAgentID,
                        sessionID: nil,
                        channelID: channelID,
                        topicID: topicID,
                        request: effectiveRequest,
                        requireApproval: !missingAccessApprovalGranted && (requireApproval || effectivePolicy.approval.enabled),
                        approvalSettings: effectivePolicy.approval
                    ), let deniedResult = toolApprovalDeniedResult(tool: effectiveRequest.tool, approval: approval) {
                        result = deniedResult
                        break
                    }
                    if loopGuardEnabled {
                        await toolLoopGuard.recordStarted(
                            sessionID: channelID,
                            request: effectiveRequest,
                            policy: effectivePolicy,
                            workspaceRootURL: workspaceRootURL,
                            currentDirectoryURL: currentDirectoryURL
                        )
                    }
                    let toolExecution = self.toolExecution
                    let invocationPolicy = effectivePolicy
                    let invocationRequest = effectiveRequest
                    let timeoutMs = toolInvocationHardTimeoutMs(request: invocationRequest, policy: invocationPolicy)
                    result = await runToolInvocationWithHardTimeout(
                        toolID: invocationRequest.tool,
                        timeoutMs: timeoutMs
                    ) {
                        await withSpan("tool.invoke.channel", ofKind: .internal) { span in
                            span.attributes["agent_id"] = "\(normalizedAgentID)"
                            span.attributes["channel_id"] = "\(channelID)"
                            span.attributes["tool_id"] = "\(invocationRequest.tool)"
                            return await toolExecution.invoke(
                                agentID: normalizedAgentID,
                                sessionID: channelID,
                                currentChannelID: channelID,
                                request: invocationRequest,
                                policy: invocationPolicy,
                                currentDirectoryURL: currentDirectoryURL
                            )
                        }
                    }
                    if loopGuardEnabled {
                        let correctionExhausted = await toolLoopGuard.recordResult(
                            sessionID: channelID,
                            request: effectiveRequest,
                            result: result,
                            policy: effectivePolicy,
                            workspaceRootURL: workspaceRootURL,
                            currentDirectoryURL: currentDirectoryURL
                        )
                        if correctionExhausted { result = toolArgumentCorrectionExhausted(result) }
                    }
                }
            }
        } else {
            result = .init(
                tool: request.tool,
                ok: false,
                error: authorization.error ?? .init(code: "tool_forbidden", message: "Tool is forbidden.", retryable: false)
            )
        }

        return result
    }

    private struct MissingAccessApprovalState {
        var result: ToolApprovalWaitResult
        var grants: [ToolApprovalGrant]
    }

    private func requestMissingAccessApprovalIfNeeded(
        agentID: String,
        sessionID: String?,
        channelID: String?,
        topicID: String?,
        request: ToolInvocationRequest,
        grants: [ToolApprovalGrant]
    ) async -> MissingAccessApprovalState? {
        let normalizedGrants = normalizedMissingAccessGrants(grants)
        guard !normalizedGrants.isEmpty else {
            return nil
        }
        if let bypassDecisionBy = await missingAccessApprovalBypassDecisionBy(
            agentID: agentID,
            sessionID: sessionID,
            grants: normalizedGrants
        ) {
            let now = Date()
            let record = ToolApprovalRecord(
                status: .approved,
                approvalKind: .missingAccess,
                agentId: agentID,
                sessionId: sessionID.flatMap(normalizedSessionID),
                channelId: channelID,
                topicId: topicID,
                tool: request.tool,
                arguments: request.arguments,
                grants: normalizedGrants,
                reason: request.reason,
                decidedBy: bypassDecisionBy,
                createdAt: now,
                updatedAt: now,
                expiresAt: now
            )
            return MissingAccessApprovalState(result: .approved(record), grants: normalizedGrants)
        }
        let result = await requestMissingAccessApproval(
            agentID: agentID,
            sessionID: sessionID,
            channelID: channelID,
            topicID: topicID,
            request: request,
            grants: normalizedGrants
        )
        return MissingAccessApprovalState(result: result, grants: normalizedGrants)
    }

    private func missingAccessApprovalBypassDecisionBy(
        agentID: String,
        sessionID: String?,
        grants: [ToolApprovalGrant]
    ) async -> String? {
        guard !grants.isEmpty,
              let normalizedSessionID = sessionID.flatMap(normalizedSessionID)
        else {
            return nil
        }
        if sessionToolApprovalBypass.contains(normalizedSessionID) {
            return "session_tool_approval_bypass"
        }
        if await isAutopilotManagedTaskSession(agentID: agentID, sessionID: normalizedSessionID) {
            return "autopilot_task_session"
        }
        return nil
    }

    private func isAutopilotManagedTaskSession(agentID: String, sessionID: String) async -> Bool {
        guard let detail = try? getAgentSession(agentID: agentID, sessionID: sessionID),
              let taskID = taskIDFromWorkerSessionTitle(detail.summary.title)
        else {
            return false
        }
        for project in await store.listProjects() {
            guard let task = project.tasks.first(where: { $0.id == taskID }),
                  project.autopilotSettings.enabled,
                  isAutopilotManagedTask(project: project, task: task)
            else {
                continue
            }
            return true
        }
        return false
    }

    private func taskIDFromWorkerSessionTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("task-") else {
            return nil
        }
        let rawTaskID = String(trimmed.dropFirst("task-".count))
        guard !rawTaskID.isEmpty else {
            return nil
        }
        if let range = rawTaskID.range(of: "-attempt-", options: .backwards) {
            let suffix = rawTaskID[range.upperBound...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                let taskID = String(rawTaskID[..<range.lowerBound])
                return taskID.isEmpty ? nil : taskID
            }
        }
        return rawTaskID
    }

    private func missingDirectoryApprovalGrants(
        for request: ToolInvocationRequest,
        policy: AgentToolsPolicy,
        currentDirectoryURL: URL?
    ) -> [ToolApprovalGrant] {
        guard policy.sandbox.mode != .fullAccess else {
            return []
        }
        let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let requirement = directoryAccessRequirement(for: toolID, arguments: request.arguments) else {
            return []
        }
        let rawPath = request.arguments[requirement.argumentName]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawPath.isEmpty else {
            return []
        }
        let extraRoots = requirement.operation == "exec"
            ? policy.guardrails.allowedExecRoots
            : policy.guardrails.allowedWriteRoots
        if resolveToolPath(
            rawPath,
            workspaceRootURL: workspaceRootURL,
            currentDirectoryURL: currentDirectoryURL,
            extraRoots: extraRoots + defaultTemporaryToolRoots()
        ) != nil {
            return []
        }
        let requestedURL = unrestrictedToolPath(rawPath, currentDirectoryURL: currentDirectoryURL)
        let resource = approvalDirectoryResource(for: requestedURL, operation: requirement.operation)
        return [
            ToolApprovalGrant(
                kind: .directory,
                tool: toolID,
                operation: requirement.operation,
                resource: resource
            )
        ]
    }

    private func matchingSessionDirectoryApprovalGrant(
        in grants: [ToolApprovalGrant],
        for request: ToolInvocationRequest,
        currentDirectoryURL: URL?
    ) -> Bool {
        let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let requirement = directoryAccessRequirement(for: toolID, arguments: request.arguments) else {
            return false
        }
        let rawPath = request.arguments[requirement.argumentName]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawPath.isEmpty else {
            return false
        }
        let requestedURL = unrestrictedToolPath(rawPath, currentDirectoryURL: currentDirectoryURL)
        return normalizedMissingAccessGrants(grants).contains { grant in
            guard grant.kind == .directory,
                  grant.tool == toolID,
                  grant.operation == requirement.operation,
                  let resource = grant.resource else {
                return false
            }
            return isToolPath(requestedURL.path, withinRoot: resource)
        }
    }

    private func directoryAccessRequirement(
        for toolID: String,
        arguments: [String: JSONValue]
    ) -> (argumentName: String, operation: String)? {
        switch toolID {
        case "files.read", "files.list":
            return ("path", "read")
        case "files.grep":
            let path = arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "."
            guard !path.isEmpty, path != "." else {
                return nil
            }
            return ("path", "read")
        case "files.write", "files.edit":
            return ("path", "write")
        case "runtime.exec":
            let cwd = arguments["cwd"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cwd.isEmpty else {
                return nil
            }
            return ("cwd", "exec")
        case "runtime.process":
            let action = arguments["action"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "list"
            let cwd = arguments["cwd"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard action == "start", !cwd.isEmpty else {
                return nil
            }
            return ("cwd", "exec")
        default:
            return nil
        }
    }

    private func unrestrictedToolPath(_ rawPath: String, currentDirectoryURL: URL?) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL
        }
        let baseURL = currentDirectoryURL ?? workspaceRootURL
        return baseURL.appendingPathComponent(trimmed).resolvingSymlinksInPath().standardizedFileURL
    }

    private func approvalDirectoryResource(for url: URL, operation: String) -> String {
        let standardized = url.standardizedFileURL
        if operation == "exec" {
            return standardized.path
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? standardized.path : standardized.deletingLastPathComponent().path
        }
        return standardized.deletingLastPathComponent().path
    }

    private func isToolPath(_ path: String, withinRoot root: String) -> Bool {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(rootPrefix)
    }

    private func normalizedMissingAccessGrants(_ grants: [ToolApprovalGrant]) -> [ToolApprovalGrant] {
        var seen = Set<ToolApprovalGrant>()
        var result: [ToolApprovalGrant] = []
        for grant in grants {
            let normalized = ToolApprovalGrant(
                kind: grant.kind,
                tool: grant.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                operation: grant.operation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                resource: grant.resource.map {
                    URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
                }
            )
            guard !normalized.tool.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    func persistToolInvocationAnalytics(
        agentId: String,
        sessionId: String,
        sessionTitle: String,
        toolId: String,
        ok: Bool,
        durationMs: Int
    ) async {
        let trimmedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskId: String?
        if trimmedTitle.hasPrefix("task-") {
            let raw = String(trimmedTitle.dropFirst("task-".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            taskId = raw.isEmpty ? nil : raw
        } else {
            taskId = nil
        }

        let projectId: String?
        if let taskId {
            let projects = await store.listProjects()
            projectId = projects.first(where: { $0.tasks.contains(where: { $0.id == taskId }) })?.id
        } else {
            projectId = nil
        }

        await store.persistToolInvocation(
            id: UUID().uuidString,
            projectId: projectId,
            taskId: taskId,
            agentId: agentId,
            sessionId: sessionId,
            tool: toolId,
            ok: ok,
            durationMs: durationMs,
            traceId: nil,
            createdAt: Date()
        )
    }

    /// Persists config to file and updates in-memory snapshot.
    public func toolCatalog() async -> [AgentToolCatalogEntry] {
        await ToolCatalog.entries(mcpRegistry: mcpRegistry)
    }

    /// Returns agent tools policy from `/agents/<agentID>/tools/tools.json`.
    public func getAgentToolsPolicy(agentID: String) async throws -> AgentToolsPolicy {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentToolsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)
        do {
            return try await toolsAuthorization.policy(agentID: normalizedAgentID)
        } catch {
            throw mapAgentToolsError(error)
        }
    }

    /// Updates agent tools policy.
    public func updateAgentToolsPolicy(agentID: String, request: AgentToolsUpdateRequest) async throws -> AgentToolsPolicy {
        guard let targetAgentID = normalizedAgentID(agentID) else {
            throw AgentToolsError.invalidAgentID
        }
        _ = try getAgent(id: targetAgentID)
        if request.approval.policy == .approveForMe {
            guard let reviewerAgentID = normalizedAgentID(request.approval.reviewerAgentId ?? ""),
                  reviewerAgentID != targetAgentID,
                  let reviewer = try? getAgent(id: reviewerAgentID),
                  reviewer.runtime.type == .native
            else {
                throw AgentToolsError.invalidPayload
            }
        }
        do {
            return try await toolsAuthorization.updatePolicy(agentID: targetAgentID, request: request)
        } catch {
            throw mapAgentToolsError(error)
        }
    }

    func configureToolExecutionServices() {
        toolExecution.projectService = self
        toolExecution.configService = self
        toolExecution.skillsService = self
        toolExecution.memoryImportService = self
        toolExecution.siteService = self
        toolExecution.applyAgentMarkdown = { [weak self] agentID, userID, field, markdown in
            guard let self else {
                throw AgentConfigError.storageFailure
            }
            try await self.applyAgentMarkdownFromTool(agentID: agentID, userID: userID, field: field, markdown: markdown)
        }
        toolExecution.delegateSubagent = { [weak self] agentID, taskID, objective, workingDirectory, toolsetNames, selectedModel, parentSessionID in
            guard let self else { return nil }
            return await self.runSubagentTask(
                agentID: agentID,
                taskID: taskID,
                objective: objective,
                workingDirectory: workingDirectory,
                toolsetNames: toolsetNames,
                selectedModel: selectedModel,
                parentSessionID: parentSessionID
            )
        }
    }

    func toolContextForSession(
        sessionID: String,
        sessionTitle: String,
        projectID: String?,
        taskID: String? = nil
    ) async -> (workingDirectory: String?, extraRoots: [String]) {
        if let taskContext = await toolContextForTask(projectID: projectID, taskID: taskID) {
            var roots = taskContext.extraRoots
            for addedRoot in sessionAddedRoots[sessionID] ?? [] where !roots.contains(addedRoot) {
                roots.append(addedRoot)
            }
            sessionExtraRoots[sessionID] = roots
            sessionWorkingDirectories[sessionID] = taskContext.workingDirectory
            return (taskContext.workingDirectory, roots)
        }

        if let projectContext = await toolContextForProject(projectID: projectID) {
            var roots = projectContext.extraRoots
            for addedRoot in sessionAddedRoots[sessionID] ?? [] where !roots.contains(addedRoot) {
                roots.append(addedRoot)
            }
            sessionExtraRoots[sessionID] = roots
            sessionWorkingDirectories[sessionID] = projectContext.workingDirectory
            return (projectContext.workingDirectory, roots)
        }

        if let roots = sessionExtraRoots[sessionID] {
            return (sessionWorkingDirectories[sessionID], roots)
        }

        let trimmedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.hasPrefix("task-") else {
            return (nil, [])
        }

        let taskID = String(trimmedTitle.dropFirst("task-".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            return (nil, [])
        }

        let projects = await store.listProjects()
        for project in projects {
            guard let task = project.tasks.first(where: { $0.id == taskID }),
                  let repoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !repoPath.isEmpty
            else {
                continue
            }

            let workingDirectory: String
            if task.worktreeBranch != nil {
                workingDirectory = sourceControlProvider(for: project, task: task).worktreePath(
                    repoPath: repoPath,
                    taskId: task.id,
                    worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
                )
            } else {
                workingDirectory = repoPath
            }

            var roots = sessionToolRoots(forWorkingDirectory: workingDirectory)
            for projectRoot in effectiveProjectDirectoryURLs(project).map(\.path) where !roots.contains(projectRoot) {
                roots.append(projectRoot)
            }
            for addedRoot in sessionAddedRoots[sessionID] ?? [] where !roots.contains(addedRoot) {
                roots.append(addedRoot)
            }
            sessionExtraRoots[sessionID] = roots
            sessionWorkingDirectories[sessionID] = workingDirectory
            return (workingDirectory, roots)
        }

        return (nil, [])
    }

    private func toolContextForTask(
        projectID: String?,
        taskID: String?
    ) async -> (workingDirectory: String?, extraRoots: [String])? {
        guard let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectID.isEmpty,
              let taskID = taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskID.isEmpty,
              let normalizedID = normalizedProjectID(projectID),
              let project = await store.project(id: normalizedID),
              let task = project.tasks.first(where: { $0.id == taskID }),
              let repoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoPath.isEmpty
        else {
            return nil
        }

        let workingDirectory: String
        if task.worktreeBranch != nil {
            workingDirectory = sourceControlProvider(for: project, task: task).worktreePath(
                repoPath: repoPath,
                taskId: task.id,
                worktreeRootPath: defaultWorktreeRootPath(projectID: project.id)
            )
        } else {
            workingDirectory = repoPath
        }
        var roots = sessionToolRoots(forWorkingDirectory: workingDirectory)
        for root in effectiveProjectDirectoryURLs(project).map(\.path) where !roots.contains(root) {
            roots.append(root)
        }
        return (workingDirectory, roots)
    }

    private func toolContextForProject(projectID: String?) async -> (workingDirectory: String?, extraRoots: [String])? {
        guard let trimmedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedProjectID.isEmpty,
              let normalizedID = normalizedProjectID(trimmedProjectID),
              let project = await store.project(id: normalizedID)
        else {
            return nil
        }

        let rootPaths = effectiveProjectDirectoryURLs(project).map(\.path)
        guard let workingDirectory = rootPaths.first else { return nil }
        var roots = sessionToolRoots(forWorkingDirectory: workingDirectory)
        for root in rootPaths where !roots.contains(root) {
            roots.append(root)
        }
        return (workingDirectory, roots)
    }

    func ensureDebugDirectoryForSessionIfNeeded(
        chatMode: AgentChatMode?,
        sessionID: String,
        sessionTitle: String,
        projectID: String?,
        fallbackWorkingDirectory: String? = nil
    ) async {
        guard chatMode == .debug || chatMode == .auto,
              let rootPath = await debugDirectoryRootForSession(
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                projectID: projectID,
                fallbackWorkingDirectory: fallbackWorkingDirectory
              )
        else {
            return
        }

        let debugURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(".sloppy", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: debugURL, withIntermediateDirectories: true)
        } catch {
            logger.warning(
                "debug.directory_create_failed",
                metadata: [
                    "session_id": .string(sessionID),
                    "path": .string(debugURL.path),
                    "error": .string(error.localizedDescription)
                ]
            )
        }
    }

    private func debugDirectoryRootForSession(
        sessionID: String,
        sessionTitle: String,
        projectID: String?,
        fallbackWorkingDirectory: String?
    ) async -> String? {
        if let projectIDRoot = await debugDirectoryRootForProject(projectID: projectID) {
            return projectIDRoot
        }

        let trimmedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.hasPrefix("task-") {
            let taskID = String(trimmedTitle.dropFirst("task-".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !taskID.isEmpty {
                let projects = await store.listProjects()
                for project in projects {
                    guard project.tasks.contains(where: { $0.id == taskID }),
                          let repoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !repoPath.isEmpty
                    else {
                        continue
                    }
                    return URL(fileURLWithPath: repoPath, isDirectory: true).standardizedFileURL.path
                }
            }
        }

        if let fallback = fallbackWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return URL(fileURLWithPath: fallback, isDirectory: true).standardizedFileURL.path
        }

        if let roots = sessionExtraRoots[sessionID],
           let firstRoot = roots.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstRoot.isEmpty {
            return URL(fileURLWithPath: firstRoot, isDirectory: true).standardizedFileURL.path
        }

        return nil
    }

    private func debugDirectoryRootForProject(projectID: String?) async -> String? {
        guard let trimmedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedProjectID.isEmpty
        else {
            return nil
        }

        if let normalizedID = normalizedProjectID(trimmedProjectID),
           let project = await store.project(id: normalizedID),
           let repoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !repoPath.isEmpty {
            return URL(fileURLWithPath: repoPath, isDirectory: true).standardizedFileURL.path
        }

        guard let workingDirectoryURL = try? await resolveProjectWorkspaceRoot(projectID: trimmedProjectID) else {
            return nil
        }
        return workingDirectoryURL.standardizedFileURL.path
    }

    func toolContextForChannel(
        channelID: String
    ) async -> (workingDirectory: String?, extraRoots: [String]) {
        let savedRoots = channelExtraRoots[channelID] ?? []
        let savedWorkingDirectory = channelWorkingDirectories[channelID]
        guard let project = await projectForChannel(channelId: channelID) else {
            return (savedWorkingDirectory, savedRoots)
        }
        let rootPaths = effectiveProjectDirectoryURLs(project).map(\.path)
        guard let workingDirectory = rootPaths.first else {
            return (savedWorkingDirectory, savedRoots)
        }

        var roots = sessionToolRoots(forWorkingDirectory: workingDirectory)
        for root in rootPaths where !roots.contains(root) {
            roots.append(root)
        }
        for root in channelAddedRoots[channelID] ?? [] where !roots.contains(root) {
            roots.append(root)
        }
        channelExtraRoots[channelID] = roots
        channelWorkingDirectories[channelID] = workingDirectory
        return (workingDirectory, roots)
    }

}

private actor ToolInvocationResultBox {
    private var stored: ToolInvocationResult?

    func complete(_ result: ToolInvocationResult) {
        guard stored == nil else { return }
        stored = result
    }

    var value: ToolInvocationResult? {
        stored
    }
}

private func runToolInvocationWithHardTimeout(
    toolID: String,
    timeoutMs: Int,
    operation: @escaping @Sendable () async -> ToolInvocationResult
) async -> ToolInvocationResult {
    let box = ToolInvocationResultBox()
    let startedAt = Date()
    let timeoutMs = max(1, timeoutMs)
    let task = Task {
        let result = await operation()
        await box.complete(result)
    }
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

    while Date() < deadline {
        if let result = await box.value {
            return result
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    if let result = await box.value {
        return result
    }

    task.cancel()
    let durationMs = max(timeoutMs, Int(Date().timeIntervalSince(startedAt) * 1000))
    return ToolInvocationResult(
        tool: toolID,
        ok: false,
        data: .object([
            "timedOut": .bool(true),
            "timeoutMs": .number(Double(timeoutMs))
        ]),
        error: ToolErrorPayload(
            code: "tool_timeout",
            message: "Tool execution timed out after \(timeoutMs) ms.",
            retryable: true,
            hint: "Stop retrying the same tool call. Summarize the blocker or use runtime.process for long-running commands."
        ),
        durationMs: durationMs
    )
}

private func toolInvocationHardTimeoutMs(request: ToolInvocationRequest, policy: AgentToolsPolicy) -> Int {
    let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
    switch toolID {
    case "runtime.exec":
        return resolvedExecTimeoutMs(arguments: request.arguments, guardrails: policy.guardrails) + 3_000

    case "agents.delegate_task":
        return Int(ToolApprovalService.defaultTimeoutSeconds * 1_000) + 5_000

    case "tools.sleep":
        let rawSeconds = request.arguments["seconds"]?.asInt ?? 0
        let seconds = min(max(0, rawSeconds), SleepTool.maxSeconds)
        return seconds * 1_000 + 1_000

    default:
        return max(30_000, policy.guardrails.execTimeoutMs + 5_000)
    }
}
