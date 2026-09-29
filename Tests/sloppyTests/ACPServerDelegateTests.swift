import ACPModel
import Foundation
import Testing
@testable import Protocols
@testable import sloppy

private actor ACPServerUpdateRecorder {
    private(set) var updates: [(SessionId, SessionUpdate)] = []

    func append(sessionId: SessionId, update: SessionUpdate) {
        updates.append((sessionId, update))
    }
}

private actor ACPServerPermissionRecorder {
    private(set) var requests: [ACPServerPermissionRequest] = []

    func append(_ request: ACPServerPermissionRequest) {
        requests.append(request)
    }
}

private func makeACPServerService() async throws -> CoreService {
    var config = CoreConfig.test
    config.acp.server = .init(enabled: true, agentId: "dev", cwd: nil)
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    _ = try await service.createAgent(
        AgentCreateRequest(id: "dev", displayName: "Dev", role: "Developer", isSystem: false)
    )
    return service
}

@Test
func sloppyACPServerInitializeAdvertisesSessionCapabilities() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: nil,
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let response = try await delegate.handleInitialize(
        InitializeRequest(
            protocolVersion: 1,
            clientCapabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                terminal: true
            )
        )
    )

    #expect(response.protocolVersion == 1)
    #expect(response.agentInfo?.name == "sloppy")
    #expect(response.agentInfo?.title == "Sloppy")
    #expect(response.agentCapabilities.loadSession == true)
    #expect(response.agentCapabilities.mcpCapabilities == nil)
    #expect(response.agentCapabilities.promptCapabilities?.image == true)
    #expect(response.agentCapabilities.promptCapabilities?.audio == nil)
    #expect(response.agentCapabilities.promptCapabilities?.embeddedContext == nil)
    #expect(response.agentCapabilities.sessionCapabilities?.close == nil)
    #expect(response.agentCapabilities.sessionCapabilities?.list != nil)
    #expect(response.agentCapabilities.sessionCapabilities?.resume != nil)
    #expect(response.authMethods?.isEmpty == true)
}

@Test
func sloppyACPServerAcceptsImagePromptBlocksAsAttachments() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    _ = try await delegate.handlePrompt(
        SessionPromptRequest(
            sessionId: created.sessionId,
            prompt: [
                .image(
                    ImageContent(
                        data: imageData.base64EncodedString(),
                        mimeType: "image/png",
                        uri: "file:///tmp/mock.png"
                    )
                )
            ]
        )
    )

    let detail = try await service.getAgentSession(agentID: "dev", sessionID: created.sessionId.value)
    let userMessage = try #require(detail.events.compactMap(\.message).last(where: { $0.role == .user }))
    let attachment = try #require(userMessage.segments.compactMap(\.attachment).first)

    #expect(userMessage.segments.compactMap(\.text).joined(separator: "\n").contains("Image attached"))
    #expect(attachment.name == "mock.png")
    #expect(attachment.mimeType == "image/png")
    #expect(attachment.sizeBytes == imageData.count)
    #expect(attachment.relativePath != nil)
}

@Test
func sloppyACPServerDoesNotDuplicateInlineImageTrailingText() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let trailingText = """
    Сейчас же у нас там были какие-то странные шары, хочется вот этого.

    1) Голубой цвет может быть Color.accentColor
    2) Основной цвет фона должен приходить из theme
    """
    let fullText = """
    для @AppAtmosphericBackground надо сделать шейдер эффект.

    \(trailingText)
    """

    _ = try await delegate.handlePrompt(
        SessionPromptRequest(
            sessionId: created.sessionId,
            prompt: [
                .text(TextContent(text: fullText)),
                .image(
                    ImageContent(
                        data: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
                        mimeType: "image/png",
                        uri: "zed:///agent/pasted-image?name=Image"
                    )
                ),
                .text(TextContent(text: trailingText))
            ]
        )
    )

    let detail = try await service.getAgentSession(agentID: "dev", sessionID: created.sessionId.value)
    let userMessage = try #require(detail.events.compactMap(\.message).last(where: { $0.role == .user }))
    let text = userMessage.segments.compactMap(\.text).joined(separator: "\n")

    #expect(text.contains("Image attached: zed:///agent/pasted-image?name=Image"))
    #expect(text.ranges(of: "Сейчас же у нас там были какие-то странные шары").count == 1)
    #expect(text.ranges(of: "Основной цвет фона должен приходить из theme").count == 1)
}

@Test
func sloppyACPServerCreatesAndListsSessionsForConfiguredAgent() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(
        NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path)
    )
    let listed = try await delegate.handleListSessions(ListSessionsRequest(cwd: "/tmp"))

    #expect(!created.sessionId.value.isEmpty)
    #expect(created.modes == nil)
    #expect(created.models?.currentModelId == "mock:test-model")
    #expect(created.models?.availableModels.map(\.modelId).contains("mock:test-model") == true)
    #expect(created.configOptions?.map(\.id.value) == ["mode", "model"])
    #expect(listed.sessions.map(\SessionInfo.sessionId).contains(created.sessionId))
    #expect(listed.nextCursor == nil)
    #expect(await recorder.updates.count == 1)
}

@Test
func sloppyACPServerUpdatesSessionConfigOptions() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let response = try await delegate.handleSetSessionConfigOption(
        SetSessionConfigOptionRequest(
            sessionId: created.sessionId,
            configId: SloppyACPServerDelegate.modeConfigID,
            value: SessionConfigValueId(AgentChatMode.plan.rawValue)
        )
    )
    let mode = try #require(response.configOptions.first(where: { $0.id == SloppyACPServerDelegate.modeConfigID }))
    guard case .select(let select) = mode.kind else {
        Issue.record("Expected mode to be a select config option")
        return
    }

    #expect(select.currentValue.value == AgentChatMode.plan.rawValue)
    #expect(response.configOptions.map(\.id.value) == ["mode", "model"])
}

@Test
func sloppyACPServerOffersAutomaticJEVModelSelection() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    #expect(created.models?.availableModels.first?.modelId == SloppyACPServerDelegate.automaticJEVModelID)
    #expect(created.models?.availableModels.first?.name == "Auto")
    let selected = try await delegate.handleSetSessionConfigOption(
        SetSessionConfigOptionRequest(
            sessionId: created.sessionId,
            configId: SloppyACPServerDelegate.modelConfigID,
            value: SessionConfigValueId(SloppyACPServerDelegate.automaticJEVModelID)
        )
    )
    let option = try #require(selected.configOptions.first(where: { $0.id == SloppyACPServerDelegate.modelConfigID }))
    guard case .select(let model) = option.kind else {
        Issue.record("Expected model selection")
        return
    }
    #expect(model.currentValue.value == SloppyACPServerDelegate.automaticJEVModelID)
    #expect(SloppyACPServerDelegate.requestModelOverride(for: model.currentValue.value) == nil)
    #expect(SloppyACPServerDelegate.requestModelOverride(for: "mock:test-model") == "mock:test-model")
    #expect(!selected.configOptions.contains { $0.id == SloppyACPServerDelegate.reasoningEffortConfigID })
}

@Test
func sloppyACPServerRequestsRiskyToolPermissionFromClient() async throws {
    let service = try await makeACPServerService()
    let updates = ACPServerUpdateRecorder()
    let permissions = ACPServerPermissionRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        requestPermission: { request in
            await permissions.append(request)
            return RequestPermissionResponse(outcome: PermissionOutcome(optionId: "allow_once"))
        },
        sendUpdate: { sessionId, update in await updates.append(sessionId: sessionId, update: update) }
    )
    await service.setToolApprovalPresenter { [weak delegate] record in
        guard let delegate else { return nil }
        return await delegate.presentToolApproval(record)
    }
    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))

    let result = await service.invokeToolFromRuntime(
        agentID: "dev",
        sessionID: created.sessionId.value,
        request: ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("/bin/echo"),
                "arguments": .array([.string("approved")]),
            ]
        ),
        recordSessionEvents: true
    )
    let request = try #require(await permissions.requests.first)

    #expect(result.error?.code != "tool_approval_rejected")
    #expect(result.error?.code != "tool_approval_timeout")
    #expect(request.sessionId == created.sessionId)
    #expect(request.toolCall.title == "runtime.exec")
    #expect(request.toolCall.kind == ToolKind.execute.rawValue)
    #expect(request.toolCall.status == ToolStatus.pending.rawValue)
    #expect(request.options.map(\.kind) == ["allow_once", "allow_always", "reject_once"])
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func sloppyACPServerNewSessionScopesProjectFromCwd() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: nil,
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-acp-project-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: cwd.path))
    let detail = try await service.getAgentSession(agentID: "dev", sessionID: created.sessionId.value)
    let projectID = try #require(detail.summary.projectId)
    let project = try await service.getProject(id: projectID)

    let result = await service.invokeToolFromRuntime(
        agentID: "dev",
        sessionID: created.sessionId.value,
        request: ToolInvocationRequest(tool: "project.current", arguments: [:]),
        recordSessionEvents: false
    )

    #expect(project.repoPath == cwd.path)
    #expect(result.ok == true)
    #expect(result.data?.asObject?["projectId"]?.asString == projectID)
}

@Test
func sloppyACPServerLoadSessionDoesNotAdvertiseUnsupportedModes() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let loaded = try await delegate.handleLoadSession(
        LoadSessionRequest(sessionId: created.sessionId, cwd: "/tmp")
    )

    #expect(loaded.sessionId == created.sessionId)
    #expect(loaded.modes == nil)
    #expect(loaded.models?.currentModelId == "mock:test-model")
}

@Test
func sloppyACPServerSetModelPersistsAgentSelection() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let response = try await delegate.handleSetModel(
        SetModelRequest(sessionId: created.sessionId, modelId: "mock:test-model")
    )
    let config = try await service.getAgentConfig(agentID: "dev")

    #expect(response.success == true)
    #expect(config.selectedModel == "mock:test-model")
}

@Test
func sloppyACPServerLoadSessionReplaysStoredTranscript() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let events = [
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .message,
            message: AgentSessionMessage(
                role: .user,
                segments: [AgentMessageSegment(kind: .text, text: "Hello from VS Code")],
                userId: "acp"
            )
        ),
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .message,
            message: AgentSessionMessage(
                role: .assistant,
                segments: [AgentMessageSegment(kind: .text, text: "Hello from Sloppy")]
            )
        ),
    ]
    _ = try await service.appendAgentSessionEvents(
        agentID: "dev",
        sessionID: created.sessionId.value,
        request: AgentSessionAppendEventsRequest(events: events)
    )

    _ = try await delegate.handleLoadSession(
        LoadSessionRequest(sessionId: created.sessionId, cwd: "/tmp")
    )

    let updates = await recorder.updates.map(\.1)
    #expect(ACPServerTestHelpers.acpText(updates[safe: 1], expectedCase: "user_message_chunk") == "Hello from VS Code")
    #expect(ACPServerTestHelpers.acpText(updates[safe: 2], expectedCase: "agent_message_chunk") == "Hello from Sloppy")
}

@Test
func sloppyACPServerRoutesThinkBlocksToThoughtChunksWhenLoadingSession() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let events = [
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .message,
            message: AgentSessionMessage(
                role: .assistant,
                segments: [
                    AgentMessageSegment(
                        kind: .text,
                        text: "Visible <think>hidden reasoning</think> answer"
                    )
                ]
            )
        ),
    ]
    _ = try await service.appendAgentSessionEvents(
        agentID: "dev",
        sessionID: created.sessionId.value,
        request: AgentSessionAppendEventsRequest(events: events)
    )

    _ = try await delegate.handleLoadSession(
        LoadSessionRequest(sessionId: created.sessionId, cwd: "/tmp")
    )

    let updates = await recorder.updates.map(\.1)
    #expect(ACPServerTestHelpers.acpText(updates[safe: 1], expectedCase: "agent_message_chunk") == "Visible ")
    #expect(ACPServerTestHelpers.acpText(updates[safe: 2], expectedCase: "agent_thought_chunk") == "hidden reasoning")
    #expect(ACPServerTestHelpers.acpText(updates[safe: 3], expectedCase: "agent_message_chunk") == " answer")
}

@Test
func sloppyACPServerDoesNotForwardRunStatusesAsThoughtChunks() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let events = [
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .runStatus,
            runStatus: AgentRunStatusEvent(
                stage: .responding,
                label: "Responding",
                details: "Generating response..."
            )
        ),
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .runStatus,
            runStatus: AgentRunStatusEvent(
                stage: .searching,
                label: "Executing tool",
                details: "Tool: files.read"
            )
        ),
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .toolCall,
            toolCall: AgentToolCallEvent(tool: "files.read", arguments: ["path": .string("Package.swift")])
        ),
        AgentSessionEvent(
            agentId: "dev",
            sessionId: created.sessionId.value,
            type: .toolResult,
            toolResult: AgentToolResultEvent(tool: "files.read", ok: true, data: .object(["summary": .string("Read Package.swift")]))
        ),
    ]
    _ = try await service.appendAgentSessionEvents(
        agentID: "dev",
        sessionID: created.sessionId.value,
        request: AgentSessionAppendEventsRequest(events: events)
    )

    _ = try await delegate.handleLoadSession(
        LoadSessionRequest(sessionId: created.sessionId, cwd: "/tmp")
    )

    let updates = await recorder.updates.map(\.1)
    #expect(updates.contains { update in
        if case .agentThoughtChunk = update { return true }
        return false
    } == false)
    #expect(updates.contains { update in
        if case .toolCall = update { return true }
        return false
    })
    #expect(updates.contains { update in
        if case .toolCallUpdate = update { return true }
        return false
    })
}

@Test
func sloppyACPServerUsesUniqueToolCallIdsForRepeatedToolInvocations() async throws {
    let service = try await makeACPServerService()
    let recorder = ACPServerUpdateRecorder()
    let delegate = SloppyACPServerDelegate(
        service: service,
        agentID: "dev",
        defaultCwd: "/tmp",
        sendUpdate: { sessionId, update in await recorder.append(sessionId: sessionId, update: update) }
    )

    let created = try await delegate.handleNewSession(NewSessionRequest(cwd: "/tmp"))
    let firstCall = AgentSessionEvent(
        id: "event-call-1",
        agentId: "dev",
        sessionId: created.sessionId.value,
        type: .toolCall,
        toolCall: AgentToolCallEvent(tool: "files.read", arguments: ["path": .string("Package.swift")])
    )
    let firstResult = AgentSessionEvent(
        id: "event-result-1",
        agentId: "dev",
        sessionId: created.sessionId.value,
        type: .toolResult,
        toolResult: AgentToolResultEvent(tool: "files.read", ok: true)
    )
    let secondCall = AgentSessionEvent(
        id: "event-call-2",
        agentId: "dev",
        sessionId: created.sessionId.value,
        type: .toolCall,
        toolCall: AgentToolCallEvent(tool: "files.read", arguments: ["path": .string("README.md")])
    )
    let secondResult = AgentSessionEvent(
        id: "event-result-2",
        agentId: "dev",
        sessionId: created.sessionId.value,
        type: .toolResult,
        toolResult: AgentToolResultEvent(tool: "files.read", ok: true)
    )
    _ = try await service.appendAgentSessionEvents(
        agentID: "dev",
        sessionID: created.sessionId.value,
        request: AgentSessionAppendEventsRequest(events: [firstCall, firstResult, secondCall, secondResult])
    )

    _ = try await delegate.handleLoadSession(
        LoadSessionRequest(sessionId: created.sessionId, cwd: "/tmp")
    )

    let updates = await recorder.updates.map(\.1)
    let callIds = updates.compactMap { update -> String? in
        if case .toolCall(let call) = update { return call.toolCallId }
        return nil
    }
    let resultIds = updates.compactMap { update -> String? in
        if case .toolCallUpdate(let result) = update { return result.toolCallId }
        return nil
    }

    #expect(callIds == ["event-call-1", "event-call-2"])
    #expect(resultIds == callIds)
}

@Test
func acpServerDeltaTrackerForwardsIncrementalChunks() async {
    let tracker = ACPServerDeltaTracker()

    #expect(await tracker.consume(delta: "Пр") == "Пр")
    #expect(await tracker.consume(delta: "ивет") == "ивет")
    #expect(await tracker.consume(delta: "! Чем") == "! Чем")
    #expect(await tracker.consume(delta: "") == nil)
    #expect(await tracker.didSendDelta)
}

@Test
func acpServerDeltaTrackerSuppressesFinalAssistantReplayAfterLiveDeltas() async {
    let tracker = ACPServerDeltaTracker()

    _ = await tracker.consume(delta: "Hello")

    #expect(await tracker.shouldForwardFinalAssistantMessage() == false)
}

@Test
func acpServerDeltaTrackerAllowsFinalAssistantMessageWhenNoLiveDeltasWereSent() async {
    let tracker = ACPServerDeltaTracker()

    #expect(await tracker.shouldForwardFinalAssistantMessage() == true)
}

@Test
func acpServerThinkBlockRouterSendsThinkBlocksAsThoughtChunks() async {
    let router = ACPServerThinkBlockRouter()

    let first = await router.consume("Visible <think>hidden")
    let second = await router.consume(" thought</think> answer")

    #expect(first.map(\.kind) == [.message, .thought])
    #expect(first.map(\.text) == ["Visible ", "hidden"])
    #expect(second.map(\.kind) == [.thought, .message])
    #expect(second.map(\.text) == [" thought", " answer"])
}

@Test
func acpServerThinkBlockRouterHandlesSplitTagsAcrossChunks() async {
    let router = ACPServerThinkBlockRouter()

    let first = await router.consume("Visible <thi")
    let second = await router.consume("nk>hidden</thi")
    let third = await router.consume("nk> answer")

    #expect(first.map(\.kind) == [.message])
    #expect(first.map(\.text) == ["Visible "])
    #expect(second.map(\.kind) == [.thought])
    #expect(second.map(\.text) == ["hidden"])
    #expect(third.map(\.kind) == [.message])
    #expect(third.map(\.text) == [" answer"])
}

@Test
func acpServerThinkBlockRouterFlushesBufferedTagPrefixesAtMessageEnd() async {
    let router = ACPServerThinkBlockRouter()

    let chunks = await router.consume("Visible <")
    let flushed = await router.flush()

    #expect(chunks.map(\.text) == ["Visible "])
    #expect(flushed.map(\.kind) == [.message])
    #expect(flushed.map(\.text) == ["<"])
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private enum ACPServerTestHelpers {
    static func acpText(_ update: SessionUpdate?, expectedCase: String) -> String? {
        switch (expectedCase, update) {
        case ("user_message_chunk", .userMessageChunk(.text(let text))):
            return text.text
        case ("agent_message_chunk", .agentMessageChunk(.text(let text))):
            return text.text
        case ("agent_thought_chunk", .agentThoughtChunk(.text(let text))):
            return text.text
        default:
            return nil
        }
    }
}
