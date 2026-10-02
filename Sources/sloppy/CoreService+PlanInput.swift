import Foundation
import PluginSDK
import Protocols

// MARK: - Plan Input

extension CoreService {
    func handleAgentPlanInputTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest,
        chatMode: AgentChatMode?
    ) async -> ToolInvocationResult {
        let longChatWorker = longChatParent(of: sessionID) != nil
        guard let requestMode = inputRequestMode(from: chatMode) ?? (longChatWorker ? .plan : nil) else {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(
                    code: "input_mode_required",
                    message: "`planning.request_input` is only available in plan or debug mode.",
                    retryable: false
                )
            )
        }

        var inputRequest: PlanInputRequest
        do {
            inputRequest = try makePlanInputRequest(arguments: request.arguments, mode: requestMode.rawValue)
            if (try? getAgentConfig(agentID: agentID).autoApproveInput) == true {
                inputRequest.autoApproveAt = inputRequest.createdAt.addingTimeInterval(Self.planInputAutoApprovalTimeoutSeconds)
            }
        } catch {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(code: "invalid_arguments", message: String(describing: error), retryable: false)
            )
        }

        let events = [
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .inputRequest,
                inputRequest: inputRequest
            ),
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .paused,
                    label: "Waiting for input",
                    details: inputRequest.title ?? "Plan input requested."
                )
            )
        ]

        do {
            let summary = try sessionStore.appendEvents(agentID: agentID, sessionID: sessionID, events: events)
            publishLiveSessionEvents(agentID: agentID, sessionID: sessionID, summary: summary, events: events)
            schedulePlanInputAutoApproval(agentID: agentID, sessionID: sessionID, request: inputRequest)
            let title = inputRequest.title ?? "Plan input requested"
            await notificationService.pushInputRequired(
                title: "Input required",
                message: title,
                agentId: agentID,
                sessionId: sessionID,
                requestId: inputRequest.id,
                source: "agent"
            )
            await markTaskWaitingInputForAgentSession(
                agentID: agentID,
                sessionID: sessionID,
                reason: title,
                source: "agent"
            )
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .object([
                    "requestId": .string(inputRequest.id),
                    "paused": .bool(true),
                    "message": .string("Input request recorded. Stop this turn and wait for the user's answer.")
                ])
            )
        } catch {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(code: "session_write_failed", message: "Failed to persist input request.", retryable: true)
            )
        }
    }

    func handleChannelPlanInputTool(
        agentID: String,
        channelID: String,
        request: ToolInvocationRequest,
        topicID: String?,
        chatMode: AgentChatMode?
    ) async -> ToolInvocationResult {
        guard let requestMode = inputRequestMode(from: chatMode) else {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(
                    code: "input_mode_required",
                    message: "`planning.request_input` is only available in plan or debug mode.",
                    retryable: false
                )
            )
        }

        var inputRequest: PlanInputRequest
        do {
            inputRequest = try makePlanInputRequest(arguments: request.arguments, mode: requestMode.rawValue)
            if (try? getAgentConfig(agentID: agentID).autoApproveInput) == true {
                inputRequest.autoApproveAt = inputRequest.createdAt.addingTimeInterval(Self.planInputAutoApprovalTimeoutSeconds)
            }
            try await channelSessionStore.recordInputRequest(channelId: channelID, request: inputRequest)
            let session = try await channelSessionStore.ensureOpenSession(channelId: channelID)
            schedulePlanInputAutoApproval(agentID: agentID, sessionID: session.sessionId, request: inputRequest, channel: true)
            _ = await channelDelivery.presentPlanInputRequest(
                channelId: channelID,
                userId: "assistant",
                request: inputRequest,
                topicId: topicID
            )
        } catch {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(code: "invalid_arguments", message: String(describing: error), retryable: false)
            )
        }

        await notificationService.pushInputRequired(
            title: "Input required",
            message: inputRequest.title ?? "Plan input requested.",
            agentId: agentID,
            requestId: inputRequest.id,
            source: "agent"
        )
        return ToolInvocationResult(
            tool: request.tool,
            ok: true,
            data: .object([
                "requestId": .string(inputRequest.id),
                "paused": .bool(true),
                "message": .string("Input request recorded. Stop this turn and wait for the user's answer.")
            ])
        )
    }

    public func answerAgentPlanInput(
        agentID: String,
        sessionID: String,
        requestID: String,
        payload: PlanInputAnswerRequest
    ) async throws -> AgentSessionMessageResponse {
        try await resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: requestID, payload: payload)
    }

    func resolveAgentPlanInput(
        agentID: String, sessionID: String, requestID: String,
        payload: PlanInputAnswerRequest?, automatically: Bool = false, now: Date = Date()
    ) async throws -> AgentSessionMessageResponse {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequestID.isEmpty else {
            throw AgentSessionError.invalidPayload
        }

        let detail = try getAgentSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        let inputRequest = try pendingPlanInputRequest(
            requestID: normalizedRequestID,
            events: detail.events.compactMap { event in
                event.type == .inputRequest ? event.inputRequest : nil
            },
            responses: detail.events.compactMap { event in
                event.type == .inputResponse ? event.inputResponse : nil
            }
        )
        let response: PlanInputResponse
        if automatically {
            guard !planInputAutoApprovalStopping,
                  (try? getAgentConfig(agentID: normalizedAgentID).autoApproveInput) == true,
                  let deadline = inputRequest.autoApproveAt, deadline <= now,
                  Self.autoApprovalCanResume(requestID: requestID, events: detail.events)
            else { throw AgentSessionError.invalidPayload }
            response = Self.automaticPlanInputResponse(inputRequest)
        } else {
            guard let payload else { throw AgentSessionError.invalidPayload }
            response = try validatedPlanInputResponse(payload: payload, request: inputRequest)
        }
        let summaryText = answerSummaryText(request: inputRequest, response: response)
        let responseEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            type: .inputResponse,
            inputResponse: response
        )
        let summaryEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            type: .message,
            message: AgentSessionMessage(
                role: .user,
                segments: [.init(kind: .text, text: summaryText)],
                userId: response.userId
            )
        )
        let appendedSummary = try sessionStore.appendEvents(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            events: [responseEvent, summaryEvent]
        )
        cancelPlanInputAutoApproval(requestID: inputRequest.id)
        publishLiveSessionEvents(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            summary: appendedSummary,
            events: [responseEvent, summaryEvent]
        )

        guard response.status == .answered else {
            let pausedEvent = AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(stage: .interrupted, label: "Cancelled", details: "Plan input was cancelled.")
            )
            let cancelledSummary = try sessionStore.appendEvents(agentID: normalizedAgentID, sessionID: normalizedSessionID, events: [pausedEvent])
            publishLiveSessionEvents(agentID: normalizedAgentID, sessionID: normalizedSessionID, summary: cancelledSummary, events: [pausedEvent])
            return AgentSessionMessageResponse(summary: cancelledSummary, appendedEvents: [responseEvent, summaryEvent, pausedEvent], routeDecision: nil)
        }

        return try await postAgentSessionMessage(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            request: AgentSessionPostMessageRequest(
                userId: longChatParent(of: normalizedSessionID)?.0.userId ?? response.userId,
                content: resumePromptText(request: inputRequest, response: response),
                mode: inputRequestChatMode(inputRequest)
            )
        )
    }

    public func answerChannelPlanInput(
        sessionID: String,
        requestID: String,
        payload: PlanInputAnswerRequest
    ) async throws -> ChannelSessionDetail {
        try await resolveChannelPlanInput(sessionID: sessionID, requestID: requestID, payload: payload)
    }

    func resolveChannelPlanInput(
        sessionID: String, requestID: String, payload: PlanInputAnswerRequest?,
        automaticAgentID: String? = nil, now: Date = Date()
    ) async throws -> ChannelSessionDetail {
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequestID.isEmpty else {
            throw AgentSessionError.invalidPayload
        }
        guard resolvingChannelPlanInputs.insert(normalizedRequestID).inserted else { throw AgentSessionError.invalidPayload }
        defer { resolvingChannelPlanInputs.remove(normalizedRequestID) }
        let detail = try await channelSessionStore.loadSessionDetail(sessionID: sessionID)
        let inputRequest = try pendingPlanInputRequest(
            requestID: normalizedRequestID,
            events: detail.events.compactMap { $0.inputRequest },
            responses: detail.events.compactMap { $0.inputResponse }
        )
        let response: PlanInputResponse
        if let agentID = automaticAgentID {
            guard !planInputAutoApprovalStopping, detail.summary.status == .open,
                  (try? getAgentConfig(agentID: agentID).autoApproveInput) == true,
                  let deadline = inputRequest.autoApproveAt, deadline <= now,
                  detail.events.last(where: { $0.inputRequest != nil })?.inputRequest?.id == requestID
            else { throw AgentSessionError.invalidPayload }
            response = Self.automaticPlanInputResponse(inputRequest)
        } else {
            guard let payload else { throw AgentSessionError.invalidPayload }
            response = try validatedPlanInputResponse(payload: payload, request: inputRequest)
        }
        let summaryText = answerSummaryText(request: inputRequest, response: response)
        try await channelSessionStore.recordInputResponse(
            channelId: detail.summary.channelId,
            response: response,
            summary: summaryText
        )
        cancelPlanInputAutoApproval(requestID: inputRequest.id)
        try await channelSessionStore.recordUserMessage(
            channelId: detail.summary.channelId,
            userId: response.userId,
            content: summaryText
        )
        if response.status == .answered {
            await offerInboundChannelPluginMessage(
                channelId: detail.summary.channelId,
                userId: response.userId,
                contentForModel: resumePromptText(request: inputRequest, response: response),
                topicId: nil,
                mode: inputRequestChatMode(inputRequest)
            )
        }
        return try await channelSessionStore.loadSessionDetail(sessionID: sessionID)
    }

    public func answerChannelPlanInputOption(
        channelId: String,
        userId: String,
        requestId: String,
        questionId: String,
        optionId: String,
        topicId: String?
    ) async -> Bool {
        let sessionChannelId = ChannelGatewayScope.scopedChannelId(
            baseChannelId: channelId,
            topicKey: topicId
        )
        do {
            guard let pending = try await channelSessionStore.pendingInputRequest(channelId: sessionChannelId),
                  pending.request.id == requestId,
                  pending.request.questions.count == 1,
                  pending.request.questions.first?.id == questionId
            else {
                return false
            }
            _ = try await answerChannelPlanInput(
                sessionID: pending.sessionId,
                requestID: requestId,
                payload: PlanInputAnswerRequest(
                    answers: [PlanInputAnswer(questionId: questionId, selectedOptionId: optionId)],
                    userId: userId
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func inputRequestMode(from chatMode: AgentChatMode?) -> AgentChatMode? {
        switch chatMode {
        case .plan, .debug, .auto:
            return chatMode
        case .ask, .build, nil:
            return nil
        }
    }

    private func inputRequestChatMode(_ request: PlanInputRequest) -> AgentChatMode {
        AgentChatMode(rawValue: request.mode) ?? .plan
    }

    private func makePlanInputRequest(arguments: [String: JSONValue], mode: String) throws -> PlanInputRequest {
        let title = arguments["title"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let questionValues = arguments["questions"]?.asArray else {
            throw PlanInputValidationError.invalid("`questions` must be an array.")
        }
        guard (1...3).contains(questionValues.count) else {
            throw PlanInputValidationError.invalid("Ask between 1 and 3 questions.")
        }
        var seenQuestionIDs = Set<String>()
        let questions = try questionValues.map { value -> PlanInputQuestion in
            guard let object = value.asObject else {
                throw PlanInputValidationError.invalid("Each question must be an object.")
            }
            let id = try stableID(object["id"]?.asString, field: "question.id")
            guard seenQuestionIDs.insert(id).inserted else {
                throw PlanInputValidationError.invalid("Duplicate question id `\(id)`.")
            }
            let text = object["question"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw PlanInputValidationError.invalid("Question `\(id)` is missing text.")
            }
            guard let optionValues = object["options"]?.asArray, (2...4).contains(optionValues.count) else {
                throw PlanInputValidationError.invalid("Question `\(id)` must have 2-4 options.")
            }
            var seenOptionIDs = Set<String>()
            let options = try optionValues.map { optionValue -> PlanInputOption in
                guard let optionObject = optionValue.asObject else {
                    throw PlanInputValidationError.invalid("Each option must be an object.")
                }
                let optionID = try stableID(optionObject["id"]?.asString, field: "option.id")
                guard seenOptionIDs.insert(optionID).inserted else {
                    throw PlanInputValidationError.invalid("Duplicate option id `\(optionID)` in question `\(id)`.")
                }
                let label = optionObject["label"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !label.isEmpty else {
                    throw PlanInputValidationError.invalid("Option `\(optionID)` is missing a label.")
                }
                let description = optionObject["description"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PlanInputOption(id: optionID, label: label, description: description?.isEmpty == false ? description : nil)
            }
            let header = object["header"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlanInputQuestion(
                id: id,
                header: header?.isEmpty == false ? header : nil,
                question: text,
                options: options,
                allowCustomAnswer: object["allowCustomAnswer"]?.asBool ?? true
            )
        }
        return PlanInputRequest(mode: mode, title: title?.isEmpty == false ? title : nil, questions: questions)
    }

    private func pendingPlanInputRequest(
        requestID: String,
        events: [PlanInputRequest],
        responses: [PlanInputResponse]
    ) throws -> PlanInputRequest {
        guard let inputRequest = events.last(where: { $0.id == requestID }) else {
            throw AgentSessionError.invalidPayload
        }
        if responses.contains(where: { $0.requestId == requestID }) {
            throw AgentSessionError.invalidPayload
        }
        return inputRequest
    }

    private func validatedPlanInputResponse(
        payload: PlanInputAnswerRequest,
        request: PlanInputRequest
    ) throws -> PlanInputResponse {
        let userID = payload.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else {
            throw AgentSessionError.invalidPayload
        }
        if payload.status == .cancelled {
            return PlanInputResponse(requestId: request.id, status: .cancelled, answers: [], userId: userID)
        }
        guard payload.answers.count == request.questions.count else {
            throw AgentSessionError.invalidPayload
        }
        var answerByQuestionID: [String: PlanInputAnswer] = [:]
        for answer in payload.answers {
            let qid = answer.questionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !qid.isEmpty, answerByQuestionID[qid] == nil else {
                throw AgentSessionError.invalidPayload
            }
            answerByQuestionID[qid] = answer
        }
        let normalizedAnswers = try request.questions.map { question -> PlanInputAnswer in
            guard let answer = answerByQuestionID[question.id] else {
                throw AgentSessionError.invalidPayload
            }
            let selected = answer.selectedOptionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let custom = answer.customAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSelected = selected?.isEmpty == false
            let hasCustom = custom?.isEmpty == false
            guard hasSelected != hasCustom else {
                throw AgentSessionError.invalidPayload
            }
            if let selected, !selected.isEmpty {
                guard question.options.contains(where: { $0.id == selected }) else {
                    throw AgentSessionError.invalidPayload
                }
                return PlanInputAnswer(questionId: question.id, selectedOptionId: selected)
            }
            guard question.allowCustomAnswer, let custom, !custom.isEmpty else {
                throw AgentSessionError.invalidPayload
            }
            return PlanInputAnswer(questionId: question.id, customAnswer: custom)
        }
        return PlanInputResponse(requestId: request.id, status: .answered, answers: normalizedAnswers, userId: userID)
    }

    private func answerSummaryText(request: PlanInputRequest, response: PlanInputResponse) -> String {
        if response.autoApproved == true {
            return "Auto-approved after 2 minutes without a user answer. The agent will decide from the task context."
        }
        if response.status == .cancelled {
            return "\(inputRequestModeLabel(request)) input cancelled."
        }
        let lines = request.questions.map { question -> String in
            guard let answer = response.answers.first(where: { $0.questionId == question.id }) else {
                return "- \(question.question): (missing)"
            }
            let text: String
            if let selected = answer.selectedOptionId,
               let option = question.options.first(where: { $0.id == selected }) {
                text = option.label
            } else {
                text = answer.customAnswer ?? ""
            }
            return "- \(question.question): \(text)"
        }
        return (["\(inputRequestModeLabel(request)) input answered:"] + lines).joined(separator: "\n")
    }

    private func resumePromptText(request: PlanInputRequest, response: PlanInputResponse) -> String {
        if response.autoApproved == true {
            let questions = request.questions.map { question in
                let options = question.options.map { option in
                    "- \(option.id): \(option.label)\(option.description.map { " — " + $0 } ?? "")"
                }.joined(separator: "\n")
                return "\(question.question)\n\(options)"
            }.joined(separator: "\n\n")
            return """
            Auto-approve is enabled for this agent. The user did not answer request `\(request.id)` within 2 minutes.
            Decide how to proceed using the original task, conversation, and available evidence. Explain your choice and continue.
            Do not claim the user answered or repeat this same question. Do not invent facts that require user observation.

            Pending questions:
            \(questions)
            """
        }
        return """
        The user answered the pending \(inputRequestModeLabel(request).lowercased()) input request `\(request.id)`.

        \(answerSummaryText(request: request, response: response))

        Continue the \(inputRequestChatMode(request).rawValue)-mode turn using these answers.
        """
    }

    private func inputRequestModeLabel(_ request: PlanInputRequest) -> String {
        inputRequestChatMode(request) == .debug ? "Debug" : "Plan"
    }

    private func stableID(_ raw: String?, field: String) throws -> String {
        let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty,
              id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else {
            throw PlanInputValidationError.invalid("`\(field)` must be a non-empty stable id.")
        }
        return id
    }
}

private enum PlanInputValidationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
