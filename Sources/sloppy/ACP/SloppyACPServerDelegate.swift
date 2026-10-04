import ACP
import ACPModel
import Foundation
import Logging
import Protocols

final class SloppyACPServerDelegate: AgentDelegate, @unchecked Sendable {
    typealias UpdateSender = @Sendable (SessionId, SessionUpdate) async throws -> Void
    typealias PermissionRequester = @Sendable (ACPServerPermissionRequest) async throws -> RequestPermissionResponse

    enum ServerError: Error, LocalizedError {
        case disabled
        case missingAgent
        case invalidSession
        case invalidPrompt
        case invalidConfigOption

        var errorDescription: String? {
            switch self {
            case .disabled:
                return "Sloppy ACP server is disabled in config."
            case .missingAgent:
                return "A Sloppy agent ID is required for ACP server mode."
            case .invalidSession:
                return "ACP session does not map to a Sloppy agent session."
            case .invalidPrompt:
                return "ACP prompt did not contain supported text content."
            case .invalidConfigOption:
                return "ACP session configuration option is invalid."
            }
        }
    }

    private let service: CoreService
    private let agentID: String
    private let defaultCwd: String?
    private let sendUpdate: UpdateSender
    private let isoFormatter = ISO8601DateFormatter()
    private let logger: Logging.Logger
    private let sessionConfiguration = ACPServerSessionConfiguration()
    private let requestPermission: PermissionRequester?

    init(
        service: CoreService,
        agentID: String,
        defaultCwd: String?,
        logger: Logging.Logger? = nil,
        requestPermission: PermissionRequester? = nil,
        sendUpdate: @escaping UpdateSender
    ) {
        self.service = service
        self.agentID = agentID
        self.defaultCwd = defaultCwd
        self.logger = logger ?? .sloppy(label: "sloppy.acp.server.delegate")
        self.requestPermission = requestPermission
        self.sendUpdate = sendUpdate
    }

    func handleInitialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        logger.info(
            "handle.request.initialize",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )
        do {
            _ = try await service.getAgent(id: agentID)
            let response = InitializeResponse(
                protocolVersion: 1,
                agentCapabilities: AgentCapabilities(
                    loadSession: true,
                    mcpCapabilities: MCPCapabilities(http: true),
                    promptCapabilities: PromptCapabilities(image: true),
                    sessionCapabilities: SessionCapabilities(
                        fork: SessionForkCapabilities(),
                        list: SessionListCapabilities(),
                        resume: SessionResumeCapabilities(),
                    )
                ),
                agentInfo: AgentInfo(
                    name: "sloppy",
                    version: SloppyVersion.current,
                    title: "Sloppy"
                ),
                authMethods: []
            )

            logger.info(
                "handle.response.initialize",
                metadata: [
                    "response": .string(String(reflecting: response))
                ]
            )

            return response
        } catch {
            logger.error(
                "handle.request.initialize",
                metadata: [
                    "request": .string(String(reflecting: request)),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func handleAuthorization(_ request: AuthorizationRequest) async throws -> AuthorizationResponse {
        logger.info(
            "handle.request.authorization",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )
        try await validateReady()
        return AuthorizationResponse()
    }

    func handleNewSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        logger.info(
            "handle.request.newSession",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )

        do {
            try await validateReady()
            let title = titleForSession(cwd: request.cwd)
            let project = await projectForSession(cwd: request.cwd)
            let summary = try await service.createAgentSession(
                agentID: agentID,
                request: AgentSessionCreateRequest(title: title, projectId: project?.id)
            )
            try await applyWorkingDirectory(request.cwd, sessionID: summary.id)
            try await service.configureACPMCPServers(sessionID: summary.id, servers: request.mcpServers, cwd: request.cwd)
            await service.setSessionToolApprovalRequired(sessionID: summary.id, enabled: true)
            try await sendUpdate(
                SessionId(summary.id),
                .sessionInfoUpdate(
                    SessionInfoUpdate(
                        title: summary.title,
                        updatedAt: isoFormatter.string(from: summary.updatedAt)
                    )
                )
            )
            let response = NewSessionResponse(
                sessionId: SessionId(summary.id),
                modes: nil,
                models: try await modelsInfo(sessionID: summary.id),
                configOptions: try await configOptions(sessionID: summary.id)
            )

            logger.info(
                "handle.response.newSession",
                metadata: [
                    "response": .string(String(reflecting: response))
                ]
            )

            return response
        } catch {
            logger.error(
                "handle.request.newSession",
                metadata: [
                    "request": .string(String(reflecting: request)),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func handlePrompt(_ request: SessionPromptRequest) async throws -> SessionPromptResponse {
        logger.info(
            "handle.request.prompt",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )
        do {
            try await validateReady()
            let sessionID = request.sessionId.value
            _ = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)

            let prompt = Self.promptPayload(from: request.prompt)
            guard !prompt.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !prompt.attachments.isEmpty else {
                throw ServerError.invalidPrompt
            }

            let stream = try await service.streamAgentSessionEvents(
                agentID: agentID, sessionID: sessionID)
            let deltaTracker = ACPServerDeltaTracker()
            let thinkBlockRouter = ACPServerThinkBlockRouter()
            let toolCallTracker = ACPServerToolCallTracker()
            let streamTask = Task {
                for await update in stream {
                    if Task.isCancelled {
                        break
                    }
                    await self.forward(
                        update: update,
                        acpSessionID: request.sessionId,
                        deltaTracker: deltaTracker,
                        thinkBlockRouter: thinkBlockRouter,
                        toolCallTracker: toolCallTracker
                    )
                }
            }

            let sessionOptions = try await sessionOptions(sessionID: sessionID)
            let response = try await service.postAgentSessionMessage(
                agentID: agentID,
                sessionID: sessionID,
                request: AgentSessionPostMessageRequest(
                    userId: "acp",
                    content: prompt.content + (await service.acpMCPPromptContext(sessionID: sessionID)),
                    attachments: prompt.attachments,
                    reasoningEffort: sessionOptions.reasoningEffort,
                    selectedModel: Self.requestModelOverride(for: sessionOptions.modelID),
                    mode: sessionOptions.mode
                )
            )
            streamTask.cancel()

            if !(await deltaTracker.didSendDelta) {
                let fallback = Self.assistantText(from: response.appendedEvents)
                if !fallback.isEmpty {
                    try await forwardAssistantText(
                        fallback,
                        acpSessionID: request.sessionId,
                        thinkBlockRouter: thinkBlockRouter,
                        flush: true
                    )
                }
            }

            logger.info(
                "handle.response.prompt",
                metadata: [
                    "stopReason": .string("end turn"),
                    "sessionId": .string(sessionID),
                ]
            )

            return SessionPromptResponse(stopReason: .endTurn)
        } catch {
            logger.error(
                "handle.request.prompt",
                metadata: [
                    "request": .string(String(reflecting: request)),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func handleCancel(_ sessionId: SessionId) async throws {
        logger.info(
            "handle.request.cancel",
            metadata: [
                "sessionId": .string(sessionId.value)
            ]
        )
        do {
            _ = try await service.getAgentSession(agentID: agentID, sessionID: sessionId.value)
            _ = try await service.controlAgentSession(
                agentID: agentID,
                sessionID: sessionId.value,
                request: AgentSessionControlRequest(action: .interruptTree, requestedBy: "acp")
            )

            logger.info(
                "handle.response.cancel",
                metadata: [
                    "sessionId": .string(sessionId.value)
                ]
            )
        } catch {
            logger.error(
                "handle.request.cancel",
                metadata: [
                    "sessionId": .string(sessionId.value),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func handleSetModel(_ request: SetModelRequest) async throws -> SetModelResponse {
        logger.info(
            "handle.request.setModel",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )
        do {
            try await validateReady()
            _ = try await service.getAgentSession(agentID: agentID, sessionID: request.sessionId.value)
            let config = try await service.getAgentConfig(agentID: agentID)
            guard config.runtime.type == .native,
                  request.modelId == Self.automaticJEVModelID || Self.modelIDs(from: config.availableModels).contains(request.modelId)
            else {
                return SetModelResponse(success: false)
            }

            if request.modelId == Self.automaticJEVModelID {
                let defaults = Self.defaultSessionOptions(config: config)
                _ = await sessionConfiguration.update(sessionID: request.sessionId.value, defaults: defaults) {
                    $0.modelID = Self.automaticJEVModelID
                    $0.reasoningEffort = nil
                }
                return SetModelResponse(success: true)
            }

            _ = try await service.updateAgentConfig(
                agentID: agentID,
                request: AgentConfigUpdateRequest(
                    role: config.role,
                    selectedModel: request.modelId,
                    documents: config.documents,
                    heartbeat: config.heartbeat,
                    channelSessions: config.channelSessions,
                    runtime: config.runtime
                )
            )
            let defaults = Self.defaultSessionOptions(config: config)
            _ = await sessionConfiguration.update(sessionID: request.sessionId.value, defaults: defaults) {
                $0.modelID = request.modelId
                $0.reasoningEffort = Self.modelSupportsReasoning(request.modelId, models: config.availableModels)
                    ? (config.reasoningEffort ?? .medium) : nil
            }

            let response = SetModelResponse(success: true)
            logger.info(
                "handle.response.setModel",
                metadata: [
                    "response": .string(String(reflecting: response)),
                    "sessionId": .string(request.sessionId.value),
                    "modelId": .string(request.modelId),
                ]
            )
            return response
        } catch {
            logger.error(
                "handle.request.setModel",
                metadata: [
                    "request": .string(String(reflecting: request)),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func handleSetSessionConfigOption(
        _ request: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try await validateReady()
        let sessionID = request.sessionId.value
        _ = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        let config = try await service.getAgentConfig(agentID: agentID)
        let defaults = Self.defaultSessionOptions(config: config)

        switch request.value {
        case .boolean:
            throw ServerError.invalidConfigOption
        case .select(let selectedValue):
            let value = selectedValue.value
            if request.configId == Self.modeConfigID {
                guard let mode = AgentChatMode(rawValue: value) else {
                    throw ServerError.invalidConfigOption
                }
                _ = await sessionConfiguration.update(sessionID: sessionID, defaults: defaults) {
                    $0.mode = mode
                }
            } else if request.configId == Self.modelConfigID {
                guard value == Self.automaticJEVModelID || Self.modelIDs(from: config.availableModels).contains(value) else {
                    throw ServerError.invalidConfigOption
                }
                _ = await sessionConfiguration.update(sessionID: sessionID, defaults: defaults) {
                    $0.modelID = value
                    if !Self.modelSupportsReasoning(value, models: config.availableModels) {
                        $0.reasoningEffort = nil
                    } else if $0.reasoningEffort == nil {
                        $0.reasoningEffort = config.reasoningEffort ?? .medium
                    }
                }
            } else if request.configId == Self.reasoningEffortConfigID {
                guard let effort = ReasoningEffort(rawValue: value) else {
                    throw ServerError.invalidConfigOption
                }
                let current = await sessionConfiguration.values(sessionID: sessionID, defaults: defaults)
                guard let modelID = current.modelID,
                      Self.modelSupportsReasoning(modelID, models: config.availableModels)
                else {
                    throw ServerError.invalidConfigOption
                }
                _ = await sessionConfiguration.update(sessionID: sessionID, defaults: defaults) {
                    $0.reasoningEffort = effort
                }
            } else {
                throw ServerError.invalidConfigOption
            }
        }

        return SetSessionConfigOptionResponse(
            configOptions: try await configOptions(sessionID: sessionID)
        )
    }

    func presentToolApproval(
        _ record: ToolApprovalRecord
    ) async -> ToolApprovalPresentationDecision? {
        guard record.agentId == agentID, let requestPermission else {
            return nil
        }
        let candidates = [record.displaySessionId, record.sessionId].compactMap { $0 }
        var sessionID: String?
        for candidate in candidates where await sessionConfiguration.contains(sessionID: candidate) {
            sessionID = candidate
            break
        }
        guard let sessionID else {
            return nil
        }

        let request = ACPServerPermissionRequest(
            sessionId: SessionId(sessionID),
            toolCall: ACPServerPermissionRequest.ToolCall(
                toolCallId: record.toolCallId ?? record.id,
                title: record.tool,
                kind: Self.toolKind(for: record.tool).rawValue,
                status: ToolStatus.pending.rawValue,
                rawInput: Self.permissionRawInput(record.arguments)
            ),
            options: [
                PermissionOption(kind: "allow_once", name: "Allow Once", optionId: "allow_once"),
                PermissionOption(kind: "allow_always", name: "Allow for Session", optionId: "allow_session"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "reject"),
            ]
        )
        do {
            let response = try await requestPermission(request)
            guard response.outcome.outcome == "selected",
                  let optionID = response.outcome.optionId
            else {
                return .reject
            }
            switch optionID {
            case "allow_once":
                return .approve(.once)
            case "allow_session":
                return .approve(.session)
            default:
                return .reject
            }
        } catch {
            return .reject
        }
    }

    func handleLoadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        logger.info(
            "handle.request.loadSession",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )

        do {
            try await validateReady()
            let detail = try await service.getAgentSession(
                agentID: agentID, sessionID: request.sessionId.value)
            await service.setSessionToolApprovalRequired(
                sessionID: request.sessionId.value,
                enabled: true
            )
            if let cwd = request.cwd {
                try await applyWorkingDirectory(cwd, sessionID: detail.summary.id)
            }
            if let servers = request.mcpServers {
                try await service.configureACPMCPServers(sessionID: detail.summary.id, servers: servers, cwd: request.cwd ?? defaultCwd)
            }
            let thinkBlockRouter = ACPServerThinkBlockRouter()
            let toolCallTracker = ACPServerToolCallTracker()
            for event in detail.events {
                try await forward(
                    event: event,
                    acpSessionID: request.sessionId,
                    thinkBlockRouter: thinkBlockRouter,
                    toolCallTracker: toolCallTracker
                )
            }
            let response = LoadSessionResponse(
                sessionId: request.sessionId,
                modes: nil,
                models: try await modelsInfo(sessionID: request.sessionId.value),
                configOptions: try await configOptions(sessionID: request.sessionId.value)
            )

            logger.info(
                "handle.response.loadSession",
                metadata: [
                    "response": .string(String(reflecting: response))
                ]
            )

            return response
        } catch {
            logger.error(
                "handle.request.loadSession",
                metadata: [
                    "request": .string(String(reflecting: request)),
                    "error": .string(error.localizedDescription),
                ]
            )
            throw error
        }
    }

    func handleListSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
        logger.info(
            "handle.request.listSessions",
            metadata: [
                "request": .string(String(reflecting: request))
            ]
        )

        let cursor = Int(request.cursor ?? "0") ?? 0
        let limit = 30

        do {
            try await validateReady()
            let summaries = try await service.listAgentSessions(
                agentID: agentID,
                limit: limit,
                offset: cursor
            )
            let cwd = request.cwd ?? defaultCwd ?? FileManager.default.currentDirectoryPath
            let response = ListSessionsResponse(
                sessions: summaries.map { summary in
                    SessionInfo(
                        sessionId: SessionId(summary.id),
                        cwd: cwd,
                        title: summary.title,
                        updatedAt: isoFormatter.string(from: summary.updatedAt)
                    )
                },
                nextCursor: summaries.count == limit ? String(cursor + limit) : nil
            )

            logger.info(
                "handle.response.listSessions",
                metadata: [
                    "response": .string(String(reflecting: response))
                ]
            )

            return response
        } catch {
            logger.error(
                "handle.request.listSessions",
                metadata: [
                    "error": .string(error.localizedDescription)
                ]
            )
            throw error
        }
    }
}

extension SloppyACPServerDelegate {
    private func validateReady() async throws {
        let config = await service.getConfig()
        guard config.acp.server.enabled else {
            throw ServerError.disabled
        }
        guard !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerError.missingAgent
        }
        _ = try await service.getAgent(id: agentID)
    }

    private func applyWorkingDirectory(_ requestedCwd: String?, sessionID: String) async throws {
        let resolved = resolvedWorkingDirectory(requestedCwd)
        guard !resolved.isEmpty else {
            return
        }
        _ = try await service.addAgentSessionDirectory(
            agentID: agentID,
            sessionID: sessionID,
            request: AgentSessionDirectoryRequest(path: resolved)
        )
    }

    private func projectForSession(cwd requestedCwd: String?) async -> ProjectRecord? {
        let resolved = resolvedWorkingDirectory(requestedCwd)
        guard !resolved.isEmpty else {
            return nil
        }
        do {
            return try await service.resolveOrCreateProjectForCurrentDirectory(resolved)
        } catch {
            logger.warning(
                "ACP session project resolution failed",
                metadata: [
                    "cwd": .string(resolved),
                    "error": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    private func resolvedWorkingDirectory(_ requestedCwd: String?) -> String {
        let cwd = requestedCwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = cwd?.isEmpty == false ? cwd! : (defaultCwd ?? "")
        return resolved.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modelsInfo(sessionID: String) async throws -> ModelsInfo? {
        let config = try await service.getAgentConfig(agentID: agentID)
        guard config.runtime.type == .native else {
            return nil
        }
        let availableModels = Self.modelInfo(from: config.availableModels)
        guard !availableModels.isEmpty else {
            return nil
        }
        let models = [Self.automaticJEVModel] + availableModels
        let values = await sessionConfiguration.values(sessionID: sessionID, defaults: Self.defaultSessionOptions(config: config))
        let current = values.modelID ?? Self.automaticJEVModelID
        return ModelsInfo(currentModelId: current, availableModels: models)
    }

    private func sessionOptions(
        sessionID: String
    ) async throws -> ACPServerSessionConfiguration.Values {
        let config = try await service.getAgentConfig(agentID: agentID)
        return await sessionConfiguration.values(
            sessionID: sessionID,
            defaults: Self.defaultSessionOptions(config: config)
        )
    }

    private func configOptions(sessionID: String) async throws -> [SessionConfigOption] {
        let config = try await service.getAgentConfig(agentID: agentID)
        let values = await sessionConfiguration.values(
            sessionID: sessionID,
            defaults: Self.defaultSessionOptions(config: config)
        )
        var options = [Self.modeConfigOption(current: values.mode)]

        let models = [Self.automaticJEVModel] + Self.modelInfo(from: config.availableModels)
        if let currentModelID = values.modelID, !models.isEmpty {
            options.append(Self.modelConfigOption(current: currentModelID, models: models))
            if Self.modelSupportsReasoning(currentModelID, models: config.availableModels),
               let reasoningEffort = values.reasoningEffort
            {
                options.append(Self.reasoningEffortConfigOption(current: reasoningEffort))
            }
        }
        return options
    }

    private static func defaultSessionOptions(
        config: AgentConfigDetail
    ) -> ACPServerSessionConfiguration.Values {
        let selected = config.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = selected?.isEmpty == false ? selected : config.availableModels.first?.id
        let supportsReasoning = modelID.map {
            modelSupportsReasoning($0, models: config.availableModels)
        } ?? false
        return ACPServerSessionConfiguration.Values(
            mode: .defaultMode,
            modelID: modelID,
            reasoningEffort: supportsReasoning ? (config.reasoningEffort ?? .medium) : nil
        )
    }

    private static func modeConfigOption(current: AgentChatMode) -> SessionConfigOption {
        let descriptions: [AgentChatMode: String] = [
            .auto: "Let Sloppy choose the best workflow for the request.",
            .ask: "Answer and inspect without making implementation changes.",
            .build: "Implement requested changes.",
            .plan: "Plan the work before implementation.",
            .debug: "Investigate and diagnose runtime behavior.",
        ]
        let names: [AgentChatMode: String] = [
            .auto: "Auto",
            .ask: "Ask",
            .build: "Build",
            .plan: "Plan",
            .debug: "Debug",
        ]
        return SessionConfigOption(
            id: modeConfigID,
            name: "Mode",
            description: "How Sloppy handles subsequent turns",
            category: "collaboration_mode",
            kind: .select(
                SessionConfigSelect(
                    currentValue: SessionConfigValueId(current.rawValue),
                    options: .ungrouped(
                        AgentChatMode.allCases.map { mode in
                            SessionConfigSelectOption(
                                value: SessionConfigValueId(mode.rawValue),
                                name: names[mode] ?? mode.rawValue,
                                description: descriptions[mode]
                            )
                        }
                    )
                )
            )
        )
    }

    private static func modelConfigOption(current: String, models: [ModelInfo]) -> SessionConfigOption {
        SessionConfigOption(
            id: modelConfigID,
            name: "Model",
            description: "Model Sloppy uses for the session",
            category: "model",
            kind: .select(
                SessionConfigSelect(
                    currentValue: SessionConfigValueId(current),
                    options: .ungrouped(
                        models.map { model in
                            SessionConfigSelectOption(
                                value: SessionConfigValueId(model.modelId),
                                name: model.name,
                                description: model.description
                            )
                        }
                    )
                )
            )
        )
    }

    private static func reasoningEffortConfigOption(current: ReasoningEffort) -> SessionConfigOption {
        SessionConfigOption(
            id: reasoningEffortConfigID,
            name: "Reasoning effort",
            description: "How much reasoning effort the model should use",
            category: "thought_level",
            kind: .select(
                SessionConfigSelect(
                    currentValue: SessionConfigValueId(current.rawValue),
                    options: .ungrouped(
                        ReasoningEffort.allCases.map { effort in
                            SessionConfigSelectOption(
                                value: SessionConfigValueId(effort.rawValue),
                                name: effort.rawValue.capitalized
                            )
                        }
                    )
                )
            )
        )
    }

    private static func modelInfo(from models: [ProviderModelOption]) -> [ModelInfo] {
        models.map { model in
            ModelInfo(
                modelId: model.id,
                name: model.title.isEmpty ? model.id : model.title,
                description: modelDescription(model)
            )
        }
    }

    private static var automaticJEVModel: ModelInfo {
        ModelInfo(modelId: automaticJEVModelID, name: "Auto", description: "Choose the executor model for each request")
    }

    static func requestModelOverride(for selection: String?) -> String? {
        selection == automaticJEVModelID ? nil : selection
    }

    private static func modelIDs(from models: [ProviderModelOption]) -> Set<String> {
        Set(models.map(\.id))
    }

    private static func modelSupportsReasoning(
        _ modelID: String,
        models: [ProviderModelOption]
    ) -> Bool {
        models.first(where: { $0.id == modelID })?.capabilities.contains(where: {
            $0.caseInsensitiveCompare("reasoning") == .orderedSame
        }) == true
    }

    private static func modelDescription(_ model: ProviderModelOption) -> String? {
        var parts: [String] = []
        if let context = model.contextWindow?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            parts.append("Context: \(context)")
        }
        if !model.capabilities.isEmpty {
            parts.append("Capabilities: \(model.capabilities.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    private func forward(
        update: AgentSessionStreamUpdate,
        acpSessionID: SessionId,
        deltaTracker: ACPServerDeltaTracker,
        thinkBlockRouter: ACPServerThinkBlockRouter,
        toolCallTracker: ACPServerToolCallTracker
    ) async {
        do {
            switch update.kind {
            case .sessionDelta:
                guard let message = update.message,
                      let delta = await deltaTracker.consume(delta: message)
                else { return }
                try await forwardAssistantText(delta, acpSessionID: acpSessionID, thinkBlockRouter: thinkBlockRouter)
            case .sessionEvent:
                guard let event = update.event else { return }
                try await forward(
                    event: event,
                    acpSessionID: acpSessionID,
                    deltaTracker: deltaTracker,
                    thinkBlockRouter: thinkBlockRouter,
                    toolCallTracker: toolCallTracker
                )
            case .sessionReady, .heartbeat, .sessionClosed, .sessionError:
                return
            }
        } catch {
            return
        }
    }

    private func forward(
        event: AgentSessionEvent,
        acpSessionID: SessionId,
        deltaTracker: ACPServerDeltaTracker? = nil,
        thinkBlockRouter: ACPServerThinkBlockRouter = ACPServerThinkBlockRouter(),
        toolCallTracker: ACPServerToolCallTracker
    ) async throws {
        switch event.type {
        case .message:
            guard let message = event.message else { return }
            let text = Self.text(from: message)
            guard !text.isEmpty else { return }
            if message.role == .assistant {
                if let deltaTracker, !(await deltaTracker.shouldForwardFinalAssistantMessage()) {
                    try await forwardAssistantText(
                        "",
                        acpSessionID: acpSessionID,
                        thinkBlockRouter: thinkBlockRouter,
                        flush: true
                    )
                    return
                }
                try await forwardAssistantText(
                    text,
                    acpSessionID: acpSessionID,
                    thinkBlockRouter: thinkBlockRouter,
                    flush: true
                )
            } else if message.role == .user {
                try await sendUpdate(
                    acpSessionID, .userMessageChunk(.text(TextContent(text: text))))
            } else if message.role == .system {
                try await sendUpdate(
                    acpSessionID, .agentThoughtChunk(.text(TextContent(text: text))))
            }
        case .runStatus:
            return
        case .toolCall:
            guard let call = event.toolCall else { return }
            let toolCallId = await toolCallTracker.recordCall(tool: call.tool, eventID: event.id)
            try await sendUpdate(
                acpSessionID,
                .toolCall(
                    ToolCallUpdate(
                        toolCallId: toolCallId,
                        status: .inProgress,
                        title: call.tool,
                        kind: Self.toolKind(for: call.tool),
                        content: [
                            .content(
                                .text(TextContent(text: Self.toolArgumentsText(call.arguments))))
                        ]
                    )
                )
            )
        case .toolResult:
            guard let result = event.toolResult else { return }
            let toolCallId = await toolCallTracker.consumeResult(tool: result.tool, eventID: event.id)
            try await sendUpdate(
                acpSessionID,
                .toolCallUpdate(
                    ToolCallUpdateDetails(
                        toolCallId: toolCallId,
                        status: result.ok ? .completed : .failed,
                        content: [.content(.text(TextContent(text: Self.toolResultText(result))))]
                    )
                )
            )
        default:
            return
        }
    }

    private func forwardAssistantText(
        _ text: String,
        acpSessionID: SessionId,
        thinkBlockRouter: ACPServerThinkBlockRouter,
        flush: Bool = false
    ) async throws {
        let chunks = await thinkBlockRouter.consume(text) + (flush ? await thinkBlockRouter.flush() : [])
        for chunk in chunks {
            let content = ContentBlock.text(TextContent(text: chunk.text))
            switch chunk.kind {
            case .message:
                try await sendUpdate(acpSessionID, .agentMessageChunk(content))
            case .thought:
                try await sendUpdate(acpSessionID, .agentThoughtChunk(content))
            }
        }
    }

    private func titleForSession(cwd: String) -> String {
        let raw = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ACP Session"
        }
        return "ACP \(URL(fileURLWithPath: raw).lastPathComponent)"
    }

    private static func promptPayload(from blocks: [ContentBlock]) -> (content: String, attachments: [AgentAttachmentUpload]) {
        var attachments: [AgentAttachmentUpload] = []
        var contentParts: [String] = []
        var previousTextBlock: String?

        for block in blocks {
            switch block {
            case .text(let text):
                appendPromptText(text.text, to: &contentParts, previousTextBlock: &previousTextBlock)
            case .image(let image):
                attachments.append(
                    AgentAttachmentUpload(
                        name: imageName(from: image.uri, fallbackExtension: imageExtension(for: image.mimeType)),
                        mimeType: image.mimeType,
                        sizeBytes: Data(base64Encoded: image.data, options: [.ignoreUnknownCharacters])?.count ?? 0,
                        contentBase64: image.data
                    )
                )
                contentParts.append(image.uri.map { "Image attached: \($0)" } ?? "Image attached.")
            case .resourceLink(let link):
                appendPromptText(link.uri, to: &contentParts, previousTextBlock: &previousTextBlock)
            case .resource(let resource):
                switch resource.resource {
                case .text(let text):
                    appendPromptText(text.text, to: &contentParts, previousTextBlock: &previousTextBlock)
                case .blob(let blob):
                    if let mimeType = blob.mimeType, isImageMimeType(mimeType) {
                        attachments.append(
                            AgentAttachmentUpload(
                                name: imageName(from: blob.uri, fallbackExtension: imageExtension(for: mimeType)),
                                mimeType: mimeType,
                                sizeBytes: Data(base64Encoded: blob.blob, options: [.ignoreUnknownCharacters])?.count ?? 0,
                                contentBase64: blob.blob
                            )
                        )
                    }
                    appendPromptText(blob.uri, to: &contentParts, previousTextBlock: &previousTextBlock)
                }
            case .audio:
                break
            }
        }

        return (contentParts.joined(separator: "\n\n"), attachments)
    }

    private static func appendPromptText(
        _ text: String,
        to contentParts: inout [String],
        previousTextBlock: inout String?
    ) {
        let normalizedText = normalizedPromptTextForOverlap(text)
        guard !normalizedText.isEmpty else {
            return
        }

        if normalizedText.count >= 32,
           let previousTextBlock,
           normalizedPromptTextForOverlap(previousTextBlock).hasSuffix(normalizedText) {
            return
        }

        contentParts.append(text)
        previousTextBlock = text
    }

    private static func normalizedPromptTextForOverlap(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isImageMimeType(_ mimeType: String) -> Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    private static func imageExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        case "image/svg+xml":
            return "svg"
        default:
            return "png"
        }
    }

    private static func imageName(from uri: String?, fallbackExtension: String) -> String {
        guard let uri,
              let components = URLComponents(string: uri),
              let lastPathComponent = components.url?.lastPathComponent,
              !lastPathComponent.isEmpty
        else {
            return "acp-image.\(fallbackExtension)"
        }
        return lastPathComponent
    }

    private static func assistantText(from events: [AgentSessionEvent]) -> String {
        events
            .compactMap { event -> String? in
                guard event.type == .message,
                    event.message?.role == .assistant,
                    let message = event.message
                else { return nil }
                return text(from: message)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(from message: AgentSessionMessage) -> String {
        message.segments.compactMap(\.text).joined(separator: "\n")
    }

    private static func toolKind(for tool: String) -> ToolKind {
        let lowered = tool.lowercased()
        if lowered.contains("read") { return .read }
        if lowered.contains("write") || lowered.contains("edit") { return .edit }
        if lowered.contains("grep") || lowered.contains("search") || lowered.contains("list") {
            return .search
        }
        if lowered.contains("exec") || lowered.contains("terminal") { return .execute }
        return .other
    }

    private static func toolArgumentsText(_ arguments: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(arguments),
            let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text
    }

    private static func permissionRawInput(_ arguments: [String: JSONValue]) -> AnyCodable {
        guard let data = try? JSONEncoder().encode(arguments),
              let value = try? JSONDecoder().decode(AnyCodable.self, from: data)
        else {
            return AnyCodable([String: any Sendable]())
        }
        return value
    }

    private static func toolResultText(_ result: AgentToolResultEvent) -> String {
        if let error = result.error {
            return error.message
        }
        guard let data = result.data,
            let encoded = try? JSONEncoder().encode(data),
            let text = String(data: encoded, encoding: .utf8)
        else {
            return result.ok ? "Done." : "Failed."
        }
        return text
    }
}

actor ACPServerToolCallTracker {
    private var pendingCallIdsByTool: [String: [String]] = [:]

    func recordCall(tool: String, eventID: String) -> String {
        pendingCallIdsByTool[tool, default: []].append(eventID)
        return eventID
    }

    func consumeResult(tool: String, eventID: String) -> String {
        guard var pending = pendingCallIdsByTool[tool], !pending.isEmpty else {
            return eventID
        }
        let callID = pending.removeFirst()
        pendingCallIdsByTool[tool] = pending
        return callID
    }
}

enum ACPServerThinkBlockKind: Sendable, Equatable {
    case message
    case thought
}

struct ACPServerThinkBlockChunk: Sendable, Equatable {
    let kind: ACPServerThinkBlockKind
    let text: String
}

actor ACPServerThinkBlockRouter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var isInsideThinkBlock = false

    func consume(_ text: String) -> [ACPServerThinkBlockChunk] {
        buffer.append(text)

        var chunks: [ACPServerThinkBlockChunk] = []
        while !buffer.isEmpty {
            let tag = isInsideThinkBlock ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: tag) {
                append(
                    String(buffer[..<range.lowerBound]),
                    kind: isInsideThinkBlock ? .thought : .message,
                    to: &chunks
                )
                buffer.removeSubrange(..<range.upperBound)
                isInsideThinkBlock.toggle()
                continue
            }

            let holdCount = Self.trailingPrefixLength(in: buffer, matching: tag)
            let emitEnd = buffer.index(buffer.endIndex, offsetBy: -holdCount)
            append(
                String(buffer[..<emitEnd]),
                kind: isInsideThinkBlock ? .thought : .message,
                to: &chunks
            )
            buffer.removeSubrange(..<emitEnd)
            break
        }

        return chunks
    }

    func flush() -> [ACPServerThinkBlockChunk] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        return [
            ACPServerThinkBlockChunk(
                kind: isInsideThinkBlock ? .thought : .message,
                text: buffer
            )
        ]
    }

    private static func trailingPrefixLength(in text: String, matching tag: String) -> Int {
        let maxCount = min(text.count, tag.count - 1)
        guard maxCount > 0 else { return 0 }

        for count in stride(from: maxCount, through: 1, by: -1) {
            let suffix = text.suffix(count)
            let prefix = tag.prefix(count)
            if suffix == prefix {
                return count
            }
        }
        return 0
    }

    private func append(
        _ text: String,
        kind: ACPServerThinkBlockKind,
        to chunks: inout [ACPServerThinkBlockChunk]
    ) {
        guard !text.isEmpty else { return }
        chunks.append(ACPServerThinkBlockChunk(kind: kind, text: text))
    }
}

actor ACPServerDeltaTracker {
    private(set) var didSendDelta = false

    func consume(delta: String) -> String? {
        let normalized = delta.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty else {
            return nil
        }
        didSendDelta = true
        return normalized
    }

    func shouldForwardFinalAssistantMessage() -> Bool {
        !didSendDelta
    }
}
