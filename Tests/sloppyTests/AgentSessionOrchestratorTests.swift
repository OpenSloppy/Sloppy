import AnyLanguageModel
import Foundation
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import PluginSDK
@testable import Protocols

private final class MockCallStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _models: [String] = []
    private var _reasoningEfforts: [ReasoningEffort?] = []
    private var _prompts: [String] = []
    private var _transcripts: [[String]] = []

    func recordModel(_ model: String) { lock.withLock { _models.append(model) } }
    func recordEffort(_ effort: ReasoningEffort?) { lock.withLock { _reasoningEfforts.append(effort) } }
    func recordPrompt(_ prompt: Prompt) { lock.withLock { _prompts.append(prompt.description) } }
    func recordTranscript(_ transcript: Transcript) { lock.withLock { _transcripts.append(transcript.map(debugTranscriptEntry)) } }
    var models: [String] { lock.withLock { _models } }
    var reasoningEfforts: [ReasoningEffort?] { lock.withLock { _reasoningEfforts } }
    var prompts: [String] { lock.withLock { _prompts } }
    var transcripts: [[String]] { lock.withLock { _transcripts } }
}

private struct FixedTextLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let text: String
    var callStore: MockCallStore? = nil

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("FixedTextLanguageModel: only String supported") }
        callStore?.recordPrompt(prompt)
        callStore?.recordTranscript(session.transcript)
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                guard let response = try? await respond(
                    within: session, to: prompt, generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt, options: options
                ) else {
                    continuation.finish()
                    return
                }
                continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor SessionCapturingModelProvider: ModelProvider {
    let id: String = "session-capturing"
    let supportedModels: [String]
    nonisolated let callStore = MockCallStore()

    init(models: [String]) {
        self.supportedModels = models
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return FixedTextLanguageModel(text: "Captured.", callStore: callStore)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func requestedModelsSnapshot() -> [String] { callStore.models }
    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] { callStore.reasoningEfforts }
    func requestedPromptsSnapshot() -> [String] { callStore.prompts }
    func requestedTranscriptsSnapshot() -> [[String]] { callStore.transcripts }
}

private struct OrchestratorSemanticDecisionProvider: SemanticDecisionProvider {
    func choose(_ request: SemanticChoiceRequest) async throws -> SemanticChoiceResponse {
        SemanticChoiceResponse(
            choice: "senior",
            confidence: 0.99,
            probabilities: ["fast": 0.01, "senior": 0.99],
            usage: .init(inputTokens: 100, outputTokens: 10, costUSD: 0.0000042, costIsEstimated: true)
        )
    }
}

@Test
func nativeLoopConfigUsesConfiguredToolBudget() {
    var config = CoreConfig.test
    config.experimentalFlags.toolBudgetEnabled = true
    config.experimentalFlags.disableToolBudgetAndLoopGuard = false
    config.toolBudgetExhausted = 7

    let nativeLoopConfig = AgentSessionOrchestrator.nativeLoopConfig(
        coreConfig: config,
        userID: "operator",
        isDelegatedSubagent: false
    )

    #expect(nativeLoopConfig.maxToolRounds == 7)
    #expect(nativeLoopConfig.enforceToolRoundLimit)
}

@Test
func experimentalFlagDisablesConfiguredToolBudget() {
    var config = CoreConfig.test
    config.experimentalFlags.toolBudgetEnabled = true
    config.toolBudgetExhausted = 7
    config.experimentalFlags.disableToolBudgetAndLoopGuard = true

    let nativeLoopConfig = AgentSessionOrchestrator.nativeLoopConfig(
        coreConfig: config,
        userID: "operator",
        isDelegatedSubagent: true
    )

    #expect(nativeLoopConfig.maxToolRounds == 0)
    #expect(!nativeLoopConfig.enforceToolRoundLimit)
}

@Test
func nativeLoopConfigTreatsZeroToolBudgetAsUnlimited() {
    var config = CoreConfig.test
    config.experimentalFlags.toolBudgetEnabled = true
    config.experimentalFlags.disableToolBudgetAndLoopGuard = false
    config.toolBudgetExhausted = 0

    let nativeLoopConfig = AgentSessionOrchestrator.nativeLoopConfig(
        coreConfig: config,
        userID: "operator",
        isDelegatedSubagent: false
    )

    #expect(nativeLoopConfig.maxToolRounds == 0)
    #expect(nativeLoopConfig.enforceToolRoundLimit == false)
}

@Test
func nativeLoopConfigDisablesToolBudgetByDefault() {
    var config = CoreConfig.test
    config.toolBudgetExhausted = 7

    let nativeLoopConfig = AgentSessionOrchestrator.nativeLoopConfig(
        coreConfig: config,
        userID: "operator",
        isDelegatedSubagent: true
    )

    #expect(nativeLoopConfig.maxToolRounds == 0)
    #expect(!nativeLoopConfig.enforceToolRoundLimit)
}

private actor FixedOutputModelProvider: ModelProvider {
    let id: String = "fixed-output"
    let supportedModels: [String]
    private let output: String

    init(models: [String], output: String) {
        self.supportedModels = models
        self.output = output
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        FixedTextLanguageModel(text: output)
    }
}

private actor SequentialTextStore {
    private let outputs: [String]
    private var index = 0

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func next() -> String {
        defer { index += 1 }
        guard outputs.indices.contains(index) else {
            return outputs.last ?? ""
        }
        return outputs[index]
    }

    func requestCount() -> Int {
        index
    }
}

private actor PlanArtifactRecorderCapture {
    private(set) var records: [(sessionTitle: String, projectID: String?, messageEventID: String, markdown: String)] = []

    func record(sessionTitle: String, projectID: String?, messageEventID: String, markdown: String) {
        records.append((sessionTitle, projectID, messageEventID, markdown))
    }
}

private struct SequentialTextLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let store: SequentialTextStore

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("SequentialTextLanguageModel: only String supported") }
        let text = await store.next()
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                guard let response = try? await respond(
                    within: session, to: prompt, generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt, options: options
                ) else {
                    continuation.finish()
                    return
                }
                continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor SequentialOutputModelProvider: ModelProvider {
    let id: String = "sequential-output"
    let supportedModels: [String]
    nonisolated let store: SequentialTextStore

    init(models: [String], outputs: [String]) {
        self.supportedModels = models
        self.store = SequentialTextStore(outputs: outputs)
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        SequentialTextLanguageModel(store: store)
    }

    func requestCount() async -> Int {
        await store.requestCount()
    }
}

private struct ToolCallingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let toolNames: [String]
    var toolArguments: [String: GeneratedContent] = [:]
    let finalText: String
    var callStore: MockCallStore? = nil

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("ToolCallingLanguageModel: only String supported") }
        callStore?.recordTranscript(session.transcript)

        var entries: [Transcript.Entry] = []
        if let delegate = session.toolExecutionDelegate {
            for toolName in toolNames {
                let toolCall = Transcript.ToolCall(
                    id: UUID().uuidString,
                    toolName: toolName,
                    arguments: toolArguments[toolName] ?? (toolName == "session.complete"
                        ? GeneratedContent(properties: [
                            "status": "completed",
                            "summary": "Completion summary from tool",
                            "verification": ["Focused tests passed"],
                            "verificationEvidenceIds": ["verification-1"],
                        ])
                        : (toolName == "agent_delegate.finish"
                            ? GeneratedContent(properties: [
                                "status": "completed",
                                "summary": "Delegated finish summary from tool",
                            ])
                            : GeneratedContent("")))
                )
                await delegate.didGenerateToolCalls([toolCall], in: session)
                let decision = await delegate.toolCallDecision(for: toolCall, in: session)
                if case .stop = decision {
                    entries.append(.toolCalls(Transcript.ToolCalls([toolCall])))
                    return LanguageModelSession.Response(
                        content: "" as! Content,
                        rawContent: GeneratedContent(""),
                        transcriptEntries: ArraySlice(entries)
                    )
                }
                if case .provideOutput(let segments) = decision {
                    let output = Transcript.ToolOutput(id: toolCall.id, toolName: toolCall.toolName, segments: segments)
                    await delegate.didExecuteToolCall(toolCall, output: output, in: session)
                    entries.append(.toolCalls(Transcript.ToolCalls([toolCall])))
                    entries.append(.toolOutput(output))
                }
            }
        }

        return LanguageModelSession.Response(
            content: finalText as! Content,
            rawContent: GeneratedContent(finalText),
            transcriptEntries: ArraySlice(entries)
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                do {
                    let response = try await respond(
                        within: session,
                        to: prompt,
                        generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt,
                        options: options
                    )
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor ToolCallingModelProvider: ModelProvider {
    let id: String = "tool-calling"
    let supportedModels: [String]
    private let toolNames: [String]
    private let toolArguments: [String: GeneratedContent]
    private let finalText: String
    nonisolated let callStore = MockCallStore()

    init(models: [String], toolName: String, finalText: String = "Tool result inspected.") {
        self.supportedModels = models
        self.toolNames = [toolName]
        self.toolArguments = [:]
        self.finalText = finalText
    }

    init(models: [String], toolNames: [String], finalText: String = "Tool result inspected.") {
        self.supportedModels = models
        self.toolNames = toolNames
        self.toolArguments = [:]
        self.finalText = finalText
    }

    init(models: [String], toolNames: [String], toolArguments: [String: GeneratedContent], finalText: String = "Tool result inspected.") {
        self.supportedModels = models
        self.toolNames = toolNames
        self.toolArguments = toolArguments
        self.finalText = finalText
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        ToolCallingLanguageModel(toolNames: toolNames, toolArguments: toolArguments, finalText: finalText, callStore: callStore)
    }

    func requestedTranscriptsSnapshot() -> [[String]] { callStore.transcripts }
}

private actor BlockingToolInvocationGate {
    private var startedCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func recordStartAndBlockFirst() async {
        startedCount += 1
        guard startedCount == 1, !released else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func starts() -> Int {
        startedCount
    }
}

private func waitForAgentSessionCondition(
    timeoutNanoseconds: UInt64,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

private func makeAgentSessionFixture(
    agentID: String,
    selectedModel: String,
    plannerModel: String? = nil,
    documents: AgentDocumentBundle? = nil,
    availableModels: [ProviderModelOption]
) throws -> (AgentCatalogFileStore, AgentSessionFileStore, URL) {
    let agentsRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-orchestrator-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("agents", isDirectory: true)
    let catalogStore = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let sessionStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)

    _ = try catalogStore.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Agent \(agentID)",
            role: "Test agent"
        ),
        availableModels: availableModels
    )
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: selectedModel,
            plannerModel: plannerModel,
            documents: documents ?? AgentDocumentBundle(
                userMarkdown: "# User\nTest user\n",
                agentsMarkdown: "# Agent\nTest agent\n",
                soulMarkdown: "# Soul\nTest soul\n",
                identityMarkdown: "# Identity\n\(agentID)\n"
            )
        ),
        availableModels: availableModels
    )

    return (catalogStore, sessionStore, agentsRootURL)
}

@Test
func nativeAgentRunPlansWithPlannerModelThenExecutesWithExecutorModel() async throws {
    let availableModels = [
        ProviderModelOption(id: "mock:planner", title: "Planner", capabilities: ["reasoning"]),
        ProviderModelOption(id: "mock:executor", title: "Executor", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "planner-executor-agent",
        selectedModel: "mock:executor",
        plannerModel: "mock:planner",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "mock:executor")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "planner-executor-agent", request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: "planner-executor-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Build a small feature"
        )
    )

    #expect(await provider.requestedModelsSnapshot() == ["mock:planner", "mock:executor"])
    let runStatuses = response.appendedEvents.compactMap(\.runStatus)
    #expect(runStatuses.first(where: { $0.label == "Planning" })?.selectedModel == "mock:planner")
    #expect(runStatuses.first(where: { $0.label == "Responding" })?.selectedModel == "mock:executor")
    let prompts = await provider.requestedPromptsSnapshot()
    #expect(prompts.count == 2)
    #expect(prompts.last?.contains("[Planner output]") == true)
    #expect(prompts.last?.contains("Captured.") == true)
}

@Test
func explicitTurnModelOverrideWinsOverSemanticRouting() async throws {
    let availableModels = [
        ProviderModelOption(id: "mock:fast", title: "Fast"),
        ProviderModelOption(id: "mock:senior", title: "Senior"),
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "semantic-override-agent",
        selectedModel: "mock:senior",
        availableModels: availableModels
    )
    let modelProvider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: modelProvider, defaultModel: "mock:senior")
    let usageMeter = SemanticDecisionUsageMeter()
    let semanticRouter = SemanticModelRouter(
        config: .init(
            provider: .typeSafe,
            executorModelRouting: .active,
            modelProfiles: [
                "fast": .init(model: "mock:fast", description: "Routine"),
                "senior": .init(model: "mock:senior", description: "Complex"),
            ]
        ),
        usageMeter: usageMeter,
        providerFactory: { _ in OrchestratorSemanticDecisionProvider() }
    )
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        semanticModelRouter: semanticRouter,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(
        agentID: "semantic-override-agent",
        request: AgentSessionCreateRequest()
    )
    _ = try await orchestrator.postMessage(
        agentID: "semantic-override-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Use the explicitly selected model",
            selectedModel: "mock:fast"
        )
    )

    #expect(await modelProvider.requestedModelsSnapshot() == ["mock:fast", "mock:fast"])
    #expect(await usageMeter.snapshot(channelID: "agent:semantic-override-agent:session:\(session.id)") == nil)
}

@Test
func semanticRoutingSelectsExecutorModelForTurn() async throws {
    let availableModels = [
        ProviderModelOption(id: "mock:fast", title: "Fast"),
        ProviderModelOption(id: "mock:senior", title: "Senior"),
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "semantic-route-agent",
        selectedModel: "mock:fast",
        availableModels: availableModels
    )
    let modelProvider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: modelProvider, defaultModel: "mock:fast")
    let usageMeter = SemanticDecisionUsageMeter()
    let semanticRouter = SemanticModelRouter(
        config: .init(
            provider: .typeSafe,
            executorModelRouting: .active,
            modelProfiles: [
                "fast": .init(model: "mock:fast", description: "Routine"),
                "senior": .init(model: "mock:senior", description: "Complex"),
            ]
        ),
        usageMeter: usageMeter,
        providerFactory: { _ in OrchestratorSemanticDecisionProvider() }
    )
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        semanticModelRouter: semanticRouter,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(
        agentID: "semantic-route-agent",
        request: AgentSessionCreateRequest()
    )
    let response = try await orchestrator.postMessage(
        agentID: "semantic-route-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Diagnose a difficult concurrency failure"
        )
    )

    #expect(await modelProvider.requestedModelsSnapshot() == ["mock:senior", "mock:senior"])
    #expect(response.appendedEvents.compactMap(\.runStatus).first?.selectedModel == "mock:senior")
    #expect(response.appendedEvents.compactMap(\.runStatus).last?.selectedModel == "mock:senior")
    let usage = await usageMeter.snapshot(channelID: "agent:semantic-route-agent:session:\(session.id)")
    #expect(usage?.requestCount == 1)
    #expect(usage?.totalCostUSD == 0.0000042)
}

@Test
func fixedAgentModelSkipsJEVRouting() async throws {
    let availableModels = [
        ProviderModelOption(id: "mock:fast", title: "Fast"),
        ProviderModelOption(id: "mock:senior", title: "Senior"),
    ]
    let agentID = "fixed-model-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "mock:fast",
        availableModels: availableModels
    )
    let original = try catalogStore.getAgentConfig(agentID: agentID, availableModels: availableModels)
    let updated = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: original.role,
            selectedModel: original.selectedModel,
            documents: original.documents,
            heartbeat: original.heartbeat,
            channelSessions: original.channelSessions,
            automaticModelRouting: false,
            runtime: original.runtime,
            skills: original.skills
        ),
        availableModels: availableModels
    )
    #expect(updated.automaticModelRouting == false)
    #expect(try catalogStore.getAgentConfig(agentID: agentID, availableModels: availableModels).automaticModelRouting == false)

    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "mock:fast")
    let usageMeter = SemanticDecisionUsageMeter()
    let router = SemanticModelRouter(
        config: .init(
            provider: .typeSafe,
            executorModelRouting: .active,
            modelProfiles: [
                "fast": .init(model: "mock:fast", description: "Routine"),
                "senior": .init(model: "mock:senior", description: "Complex"),
            ]
        ),
        usageMeter: usageMeter,
        providerFactory: { _ in OrchestratorSemanticDecisionProvider() }
    )
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        semanticModelRouter: router,
        availableModels: availableModels
    )
    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Diagnose a difficult concurrency failure")
    )
    #expect(await provider.requestedModelsSnapshot() == ["mock:fast", "mock:fast"])
    #expect(await usageMeter.snapshot(channelID: "agent:\(agentID):session:\(session.id)") == nil)
}

@Test
func agentSessionOneShotBuildCommandOverridesAskMode() async throws {
    let modelID = "mock:default"
    let availableModels = [
        ProviderModelOption(id: modelID, title: "Mock")
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "one-shot-build-agent",
        selectedModel: modelID,
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: [modelID])
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: modelID)
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "one-shot-build-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "one-shot-build-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "/build Fix the router",
            mode: .ask
        )
    )

    let prompts = await provider.requestedPromptsSnapshot()
    let executionPrompt = prompts.first(where: { $0.contains("[User request]\nFix the router") }) ?? ""
    #expect(executionPrompt.contains("[Sloppy runtime mode]\nmode: build"))
    #expect(executionPrompt.contains("[User request]\nFix the router"))
    #expect(!executionPrompt.contains("[User request]\n/build"))
}

@Test
func agentSessionLeanBootstrapUsesManifestInsteadOfLargeDocuments() async throws {
    let agentID = "lean-bootstrap-agent"
    let modelID = "mock:default"
    let largeAgents = String(repeating: "Large AGENTS body.\n", count: 500)
    let availableModels = [
        ProviderModelOption(id: modelID, title: "Mock")
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: modelID,
        documents: AgentDocumentBundle(
            userMarkdown: "User preferences",
            agentsMarkdown: largeAgents,
            soulMarkdown: "Soul",
            identityMarkdown: "Identity"
        ),
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: [modelID])
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: modelID)
    var config = CoreConfig.default
    config.agentRuntimeContext.bootstrapMode = .lean
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        availableModels: availableModels,
        persistedModelContext: (config, false)
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let channelID = "agent:\(agentID):session:\(session.id)"
    let bootstrap = try #require(await runtime.channelBootstrapContent(channelId: channelID))

    #expect(bootstrap.contains("[Agent context manifest]"))
    #expect(bootstrap.contains("AGENTS.md"))
    #expect(bootstrap.contains("available in agent directory"))
    #expect(!bootstrap.contains(String(repeating: "Large AGENTS body.\n", count: 20)))
}

private func expectedFallbackBootstrapMessage(
    agentID: String,
    sessionID: String,
    documents: AgentDocumentBundle,
    agentDirectoryPath: String? = nil
) throws -> String {
    let loader = PromptTemplateLoader()
    let renderer = PromptTemplateRenderer()
    let identity = BaseSloppyPrompts.generalPrompt.trimmingCharacters(in: .newlines)
    let skillsRules = [BaseSloppyPrompts.sessionSearchPrompt, BaseSloppyPrompts.skillsPrompt]
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .newlines)
    let capabilities = try renderer.render(template: try loader.loadPartial(named: "session_capabilities"), values: [:])
    let runtimeRules = try renderer.render(template: try loader.loadPartial(named: "runtime_rules"), values: [:])
    let branchingRules = try renderer.render(template: try loader.loadPartial(named: "branching_rules"), values: [:])
    let workerRules = try renderer.render(template: try loader.loadPartial(named: "worker_rules"), values: [:])
    let toolsInstruction = try renderer.render(template: try loader.loadPartial(named: "tools_instruction"), values: [:])
    let taskPlanningRules = try renderer.render(template: try loader.loadPartial(named: "task_planning_rules"), values: [:])
    let taskSpecRules = try renderer.render(template: try loader.loadPartial(named: "task_spec_rules"), values: [:])
    let completionReflection = try renderer.render(template: try loader.loadPartial(named: "completion_reflection"), values: [:])
    let memorySection = documents.memoryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "" : "\n\n[MEMORY.md]\n\(documents.memoryMarkdown)"
    let agentDirectoryLine = agentDirectoryPath.map { "Agent directory: \($0)\n" } ?? ""

    return """
    [agent_session_context_bootstrap_v1]
    Session context initialized.
    Agent: \(agentID)
    \(agentDirectoryLine)Session: \(sessionID)

    \(identity)

    [AGENTS.md]
    \(documents.agentsMarkdown)

    [USER.md]
    \(documents.userMarkdown)

    [IDENTITY.md]
    \(documents.identityMarkdown)

    [SOUL.md]
    \(documents.soulMarkdown)\(memorySection)

    \(identity)

    \(skillsRules)

    \(capabilities)

    \(runtimeRules)

    \(branchingRules)

    \(workerRules)

    \(toolsInstruction)

    \(AgentPromptComposer().sharedMemoryPromptSection())

    \(taskPlanningRules)

    \(taskSpecRules)

    \(completionReflection)
    """
}

private func debugTranscriptEntry(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions(let instructions):
        return "instructions:\(debugTranscriptSegments(instructions.segments))"
    case .prompt(let prompt):
        return "prompt:\(debugTranscriptSegments(prompt.segments))"
    case .response(let response):
        return "response:\(debugTranscriptSegments(response.segments))"
    case .toolCalls(let calls):
        return "toolCalls:\(calls.map { "\($0.toolName):\($0.arguments.jsonString)" }.joined(separator: "\n"))"
    case .toolOutput(let output):
        return "toolOutput:\(output.toolName):\(debugTranscriptSegments(output.segments))"
    }
}

private func debugTranscriptSegments(_ segments: [Transcript.Segment]) -> String {
    segments.map { segment -> String in
        switch segment {
        case .text(let text):
            return text.content
        case .structure(let structured):
            return structured.content.jsonString
        case .image:
            return "<image>"
        }
    }.joined(separator: "\n")
}

@Test
func agentSessionOrchestratorUsesSelectedReasoningModelAndEffort() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:o4-mini", title: "openai-api:o4-mini", capabilities: ["reasoning", "tools"]),
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "reasoning-agent",
        selectedModel: "openai-api:o4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "reasoning-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "reasoning-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Please think",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedModelsSnapshot().last == "openai-api:o4-mini")
    #expect(await provider.requestedReasoningEffortsSnapshot().last == .high)
}

@Test
func agentSessionOrchestratorUsesAgentDefaultReasoningEffortWhenRequestOmitsIt() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:o4-mini", title: "openai-api:o4-mini", capabilities: ["reasoning", "tools"])
    ]
    let agentID = "default-reasoning-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:o4-mini",
        availableModels: availableModels
    )
    let initial = try catalogStore.getAgentConfig(agentID: agentID, availableModels: availableModels)
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: initial.role,
            selectedModel: "openai-api:o4-mini",
            documents: initial.documents,
            heartbeat: initial.heartbeat,
            channelSessions: initial.channelSessions,
            reasoningEffort: .medium,
            runtime: initial.runtime,
            skills: initial.skills
        ),
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:o4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Please think"
        )
    )

    #expect(await provider.requestedReasoningEffortsSnapshot().last == .medium)
}

@Test
func agentSessionOrchestratorRequestReasoningEffortOverridesAgentDefault() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:o4-mini", title: "openai-api:o4-mini", capabilities: ["reasoning", "tools"])
    ]
    let agentID = "override-reasoning-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:o4-mini",
        availableModels: availableModels
    )
    let initial = try catalogStore.getAgentConfig(agentID: agentID, availableModels: availableModels)
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: initial.role,
            selectedModel: "openai-api:o4-mini",
            documents: initial.documents,
            heartbeat: initial.heartbeat,
            channelSessions: initial.channelSessions,
            reasoningEffort: .low,
            runtime: initial.runtime,
            skills: initial.skills
        ),
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:o4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Please think",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedReasoningEffortsSnapshot().last == .high)
}

@Test
func agentSessionOrchestratorDropsReasoningEffortForNonReasoningModels() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:o4-mini", title: "openai-api:o4-mini", capabilities: ["reasoning", "tools"]),
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "non-reasoning-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:o4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "non-reasoning-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "non-reasoning-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Please think",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedModelsSnapshot() == ["openai-api:gpt-5.4-mini", "openai-api:gpt-5.4-mini"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [nil, nil])
}

@Test
func agentSessionOrchestratorAppendsPlanArtifactEventForCompletedPlanTurn() async throws {
    let agentID = "plan-artifact-agent"
    let availableModels = [ProviderModelOption(id: "mock:plan", title: "mock:plan", capabilities: ["tools"])]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "mock:plan",
        availableModels: availableModels
    )
    let runtime = RuntimeSystem(
        modelProvider: FixedOutputModelProvider(models: ["mock:plan"], output: "# Durable Plan\n\nBuild the thing."),
        defaultModel: "mock:plan"
    )
    let capture = PlanArtifactRecorderCapture()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        planArtifactRecorder: { agentID, sessionID, sessionTitle, projectID, messageEventID, markdown, createdAt in
            await capture.record(sessionTitle: sessionTitle, projectID: projectID, messageEventID: messageEventID, markdown: markdown)
            return AgentPlanArtifactEvent(artifact: PlanArtifactRecord(
                projectId: projectID ?? "",
                projectName: "Project",
                agentId: agentID,
                sessionId: sessionID,
                messageEventId: messageEventID,
                planName: "durable-plan",
                createdAt: createdAt,
                storageKind: PlanArtifactStorageKind.workspace,
                markdownPath: "/tmp/durable-plan.md",
                webUrl: "/v1/projects/project/plans/durable-plan/web"
            ))
        }
    )

    let session = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Plan Session", projectId: "project")
    )
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Plan it", mode: .plan)
    )

    let assistantEvent = try #require(response.appendedEvents.first(where: { $0.type == .message && $0.message?.role == .assistant }))
    let artifactEvent = try #require(response.appendedEvents.first(where: { $0.type == .planArtifact })?.planArtifact)
    #expect(artifactEvent.artifact.messageEventId == assistantEvent.id)
    #expect(artifactEvent.artifact.planName == "durable-plan")
    let records = await capture.records
    #expect(records.count == 1)
    #expect(records.first?.sessionTitle == "Plan Session")
    #expect(records.first?.projectID == "project")
    #expect(records.first?.markdown.contains("# Durable Plan") == true)
}

@Test
func agentSessionOrchestratorAppendsPlanArtifactEventForAutoModePlanRoute() async throws {
    let agentID = "auto-plan-artifact-agent"
    let availableModels = [ProviderModelOption(id: "mock:auto-plan", title: "mock:auto-plan", capabilities: ["tools"])]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "mock:auto-plan",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: ["mock:auto-plan"],
        toolNames: ["planning.select_route"],
        toolArguments: [
            "planning.select_route": GeneratedContent(properties: [
                "route": "mode-plan",
                "reason": "User asked for a plan.",
            ])
        ],
        finalText: "# Auto Durable Plan\n\nBuild the thing after approval."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "mock:auto-plan")
    let capture = PlanArtifactRecorderCapture()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        planArtifactRecorder: { agentID, sessionID, sessionTitle, projectID, messageEventID, markdown, createdAt in
            await capture.record(sessionTitle: sessionTitle, projectID: projectID, messageEventID: messageEventID, markdown: markdown)
            return AgentPlanArtifactEvent(artifact: PlanArtifactRecord(
                projectId: projectID ?? "",
                projectName: "Project",
                agentId: agentID,
                sessionId: sessionID,
                messageEventId: messageEventID,
                planName: "auto-durable-plan",
                createdAt: createdAt,
                storageKind: PlanArtifactStorageKind.workspace,
                markdownPath: "/tmp/auto-durable-plan.md",
                webUrl: "/v1/projects/project/plans/auto-durable-plan/web"
            ))
        }
    )

    let session = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Auto Plan Session", projectId: "project")
    )
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Plan it", mode: .auto)
    )

    let assistantEvent = try #require(response.appendedEvents.first(where: { $0.type == .message && $0.message?.role == .assistant }))
    let artifactEvent = try #require(response.appendedEvents.first(where: { $0.type == .planArtifact })?.planArtifact)
    let detail = try sessionStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.contains { $0.toolCall?.tool == "planning.select_route" })
    #expect(artifactEvent.artifact.messageEventId == assistantEvent.id)
    #expect(artifactEvent.artifact.planName == "auto-durable-plan")
    let records = await capture.records
    #expect(records.count == 1)
    #expect(records.first?.sessionTitle == "Auto Plan Session")
    #expect(records.first?.projectID == "project")
    #expect(records.first?.markdown.contains("# Auto Durable Plan") == true)
}

@Test
func agentSessionTreatsPlainAssistantAnswerWithoutToolsAsDone() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "plain-answer-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SequentialOutputModelProvider(
        models: availableModels.map(\.id),
        outputs: ["Recovered without tools."]
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "plain-answer-agent", request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: "plain-answer-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Continue the failed restore",
            mode: .ask
        )
    )

    let assistantTexts = response.appendedEvents.compactMap { event -> String? in
        guard event.type == .message, event.message?.role == .assistant else {
            return nil
        }
        return event.message?.segments.compactMap(\.text).joined(separator: "\n")
    }

    #expect(await provider.requestCount() == 2)
    #expect(assistantTexts.last == "Recovered without tools.")
    #expect(response.appendedEvents.last?.runStatus?.stage == .done)
}

@Test
func agentSessionRetriesAndMarksToollessDebugTurnIncompleteWithoutCompletionEvidence() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "toolless-progress-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SequentialOutputModelProvider(
        models: availableModels.map(\.id),
        outputs: ["Изучаю контекст создания резолвера во всех точках."]
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(tool: request.tool, ok: true, data: .object(["ok": .bool(true)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "интересно, как там с теориями?",
            mode: .debug
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Incomplete")
    #expect(finalStatus.details?.contains("session.complete") == true)
    #expect(await provider.requestCount() == 3)
}

@Test
func agentSessionRetriesAndMarksToolDrivenDebugTurnIncompleteWithoutExplicitCompletion() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "tool-promise-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolName: "files.list",
        finalText: "Need more context before this can be handed back."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(tool: request.tool, ok: true, data: .object(["count": .number(1)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "debug why strings do not arrive",
            mode: .debug
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Incomplete")

    let assistantTexts = response.appendedEvents.compactMap { event -> String? in
        guard event.type == .message, event.message?.role == .assistant else {
            return nil
        }
        return event.message?.segments.compactMap(\.text).joined(separator: "\n")
    }
    #expect(assistantTexts.last == "Need more context before this can be handed back.")

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.filter { $0.toolCall?.tool == "files.list" }.count == 2)
}

@Test
func agentSessionTreatsToolDrivenTurnWithExplicitCompletionAsDone() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "tool-complete-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: ["runtime.exec", "session.complete"],
        toolArguments: [
            "runtime.exec": GeneratedContent(properties: [
                "command": "swift",
                "arguments": ["test", "--filter", "ParserTests"],
                "cwd": "/workspace",
            ])
        ],
        finalText: "Ran the focused tests and finished the handoff."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .object([
                    "command": .string("swift"),
                    "arguments": .array([.string("test"), .string("--filter"), .string("ParserTests")]),
                    "exitCode": .number(0),
                    "timedOut": .bool(false),
                    "stdout": .string("Test run passed"),
                    "stderr": .string(""),
                ])
            )
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "debug why strings do not arrive",
            mode: .debug
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .done)
    #expect(finalStatus.label == "Done")

    let assistantTexts = response.appendedEvents.compactMap { event -> String? in
        guard event.type == .message, event.message?.role == .assistant else {
            return nil
        }
        return event.message?.segments.compactMap(\.text).joined(separator: "\n")
    }
    #expect(assistantTexts.last == "Ran the focused tests and finished the handoff.")

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.contains { $0.toolCall?.tool == "runtime.exec" })
    #expect(detail.events.contains { $0.toolCall?.tool == "session.complete" })
    #expect(detail.events.contains { $0.toolResult?.tool == "session.complete" && $0.toolResult?.ok == true })
    #expect(detail.events.contains {
        $0.toolResult?.tool == "session.complete" &&
            $0.toolResult?.data?.asObject?["summary"]?.asString == "Completion summary from tool"
    })
    #expect(detail.events.contains {
        $0.toolResult?.tool == "session.complete" &&
            $0.toolResult?.data?.asObject?["status"]?.asString == "completed" &&
            $0.toolResult?.data?.asObject?["verification"]?.asArray?.compactMap(\.asString) == ["Focused tests passed"] &&
            $0.toolResult?.data?.asObject?["verificationEvidenceIds"]?.asArray?.compactMap(\.asString) == ["verification-1"]
    })
    let evidence = try #require(detail.events.compactMap(\.toolResult).first(where: {
        $0.tool == "runtime.exec"
    })?.data?.asObject?["verificationEvidence"]?.asObject)
    #expect(evidence["id"]?.asString == "verification-1")
    #expect(evidence["kind"]?.asString == "test")
    #expect(evidence["command"]?.asString == "swift")
    #expect(evidence["exitCode"]?.asInt == 0)
}

@Test
func agentSessionRejectsCompletedDebugOutcomeWithoutVerificationEvidence() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "completion-without-evidence-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: ["session.complete"],
        toolArguments: [
            "session.complete": GeneratedContent(properties: [
                "status": "completed",
                "summary": "Claimed completion without checks",
                "verification": ["Focused tests passed"],
            ])
        ]
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Fix and verify the parser",
            mode: .debug
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Incomplete")

    let detail = try AgentSessionFileStore(agentsRootURL: agentsRootURL)
        .loadSession(agentID: agentID, sessionID: session.id)
    let completionResults = detail.events.compactMap(\.toolResult).filter { $0.tool == "session.complete" }
    #expect(completionResults.count == 2)
    #expect(completionResults.allSatisfy { result in
        result.ok == false && result.error?.code == "completion_verification_required"
    })
}

@Test
func agentSessionRejectsEvidenceIdFromNonVerificationCommand() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "unverified-command-evidence-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: ["runtime.exec", "session.complete"],
        toolArguments: [
            "runtime.exec": GeneratedContent(properties: [
                "command": "git",
                "arguments": ["status", "--short"],
            ])
        ]
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .object([
                    "command": .string("git"),
                    "arguments": .array([.string("status"), .string("--short")]),
                    "exitCode": .number(0),
                    "timedOut": .bool(false),
                    "stdout": .string(""),
                    "stderr": .string(""),
                ])
            )
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Inspect and verify the parser",
            mode: .debug
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Incomplete")

    let detail = try AgentSessionFileStore(agentsRootURL: agentsRootURL)
        .loadSession(agentID: agentID, sessionID: session.id)
    let completionResults = detail.events.compactMap(\.toolResult).filter { $0.tool == "session.complete" }
    #expect(completionResults.count == 2)
    #expect(completionResults.allSatisfy { result in
        result.ok == false && result.error?.code == "completion_verification_not_found"
    })
    #expect(detail.events.allSatisfy {
        $0.toolResult?.data?.asObject?["verificationEvidence"] == nil
    })
}

@Test
func agentSessionSurfacesTypedBlockedDebugOutcome() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "blocked-completion-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: ["session.complete"],
        toolArguments: [
            "session.complete": GeneratedContent(properties: [
                "status": "blocked",
                "summary": "The reproduction environment is unavailable.",
                "limitations": ["Required simulator is not installed"],
            ])
        ]
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Reproduce the UI crash",
            mode: .debug
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Blocked")
    #expect(finalStatus.details == "The reproduction environment is unavailable.")
}

@Test
func agentSessionMarksTurnIncompleteWhenNativeToolRoundLimitIsReached() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "tool-limit-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: Array(repeating: "files.list", count: 61),
        finalText: "This should not become the handoff."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    var config = CoreConfig.default
    config.experimentalFlags.toolBudgetEnabled = true
    config.experimentalFlags.disableToolBudgetAndLoopGuard = false
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        persistedModelContext: (config, false),
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(tool: request.tool, ok: true, data: .object(["count": .number(1)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "keep using tools forever",
            mode: .build
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Incomplete")
    #expect(finalStatus.details == "Agent reached the tool turn limit before producing a final answer.")

    let assistantText = response.appendedEvents.last(where: { $0.type == .message && $0.message?.role == .assistant })?
        .message?.segments.compactMap(\.text).joined(separator: "\n")
    #expect(assistantText == "Agent reached the tool turn limit before producing a final answer.")

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.filter { $0.toolCall?.tool == "files.list" }.count == 60)
}

@Test
func tuiAgentSessionDoesNotEnforceNativeToolRoundLimit() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "tui-unlimited-tools-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: Array(repeating: "files.list", count: 61),
        finalText: "TUI finished after extended tool use."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    var config = CoreConfig.default
    config.experimentalFlags.toolBudgetEnabled = true
    config.experimentalFlags.disableToolBudgetAndLoopGuard = false
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        persistedModelContext: (config, false),
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(tool: request.tool, ok: true, data: .object(["count": .number(1)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "tui",
            content: "keep using tools until done",
            mode: .build
        )
    )

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .interrupted)
    #expect(finalStatus.label == "Incomplete")

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.filter { $0.toolCall?.tool == "files.list" }.count == 61)
}

@Test
func delegatedSubagentCanFinishAfterToolBudgetRecovery() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "delegated-tool-budget-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: Array(repeating: "files.list", count: 61) + ["agent_delegate.finish"],
        finalText: "Delegated subagent finished after budget recovery."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    var config = CoreConfig.default
    config.experimentalFlags.toolBudgetEnabled = true
    config.experimentalFlags.disableToolBudgetAndLoopGuard = false
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        persistedModelContext: (config, false),
        toolInvoker: { _, _, request, _ in
            if request.tool == "agent_delegate.finish" {
                return ToolInvocationResult(
                    tool: request.tool,
                    ok: true,
                    data: .object([
                        "finished": .bool(true),
                        "status": .string("completed"),
                        "summary": .string("Delegated finish summary from tool"),
                        "error": .null,
                    ])
                )
            }
            return ToolInvocationResult(tool: request.tool, ok: true, data: .object(["count": .number(1)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    await orchestrator.markDelegatedSubagentSession(sessionID: session.id)
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "keep inspecting until ready",
            mode: .build
        )
    )
    await orchestrator.unmarkDelegatedSubagentSession(sessionID: session.id)

    let finalStatus = try #require(response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus)
    #expect(finalStatus.stage == .done)

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.filter { $0.toolCall?.tool == "files.list" }.count == 60)
    #expect(detail.events.contains {
        $0.toolResult?.tool == "agent_delegate.finish" &&
            $0.toolResult?.ok == true &&
            $0.toolResult?.data?.asObject?["summary"]?.asString == "Delegated finish summary from tool"
    })
    #expect(!detail.events.contains {
        $0.runStatus?.stage == .interrupted &&
            $0.runStatus?.details == "Agent reached the tool turn limit before producing a final answer."
    })
}

@Test
func agentSessionInterruptPreventsLateNativeToolCallbacksFromAppendingEvents() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "late-tool-interrupt-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolNames: ["runtime.exec", "runtime.exec"],
        finalText: "This should not append after interruption."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let gate = BlockingToolInvocationGate()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            await gate.recordStartAndBlockFirst()
            return ToolInvocationResult(tool: request.tool, ok: true, data: .object(["ok": .bool(true)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let postTask = Task {
        try await orchestrator.postMessage(
            agentID: agentID,
            sessionID: session.id,
            request: AgentSessionPostMessageRequest(
                userId: "dashboard",
                content: "run tools, then stop",
                mode: .build
            )
        )
    }

    let firstToolStarted = await waitForAgentSessionCondition(timeoutNanoseconds: 10_000_000_000) {
        await gate.starts() == 1
    }
    guard firstToolStarted else {
        #expect(firstToolStarted)
        _ = try? await orchestrator.controlSession(
            agentID: agentID,
            sessionID: session.id,
            request: AgentSessionControlRequest(action: .interruptTree, requestedBy: "dashboard", reason: "Stopped by test")
        )
        await gate.release()
        _ = try? await postTask.value
        return
    }

    _ = try await orchestrator.controlSession(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionControlRequest(action: .interruptTree, requestedBy: "dashboard", reason: "Stopped by user")
    )
    await gate.release()
    _ = try await postTask.value

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    let firstInterruptedIndex = try #require(detail.events.firstIndex { $0.runStatus?.stage == .interrupted })
    let eventsAfterInterrupt = detail.events.dropFirst(firstInterruptedIndex + 1)

    #expect(await gate.starts() == 1)
    #expect(detail.events.filter { $0.toolCall?.tool == "runtime.exec" }.count == 1)
    #expect(detail.events.contains {
        $0.message?.role == .assistant &&
            $0.message?.segments.compactMap(\.text).joined(separator: "\n") == "Done."
    } == false)
    #expect(eventsAfterInterrupt.contains { $0.toolCall != nil } == false)
    #expect(eventsAfterInterrupt.contains { $0.toolResult != nil } == false)
    #expect(eventsAfterInterrupt.contains { $0.runStatus?.stage == .searching } == false)
}

@Test
func agentSessionPlanningRequestInputStillPausesAfterToolUse() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "planning-pause-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolName: "planning.request_input",
        finalText: "This should wait for the user first."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { invokedAgentID, invokedSessionID, request, _ in
            let inputRequest = PlanInputRequest(
                id: "input-123",
                mode: AgentChatMode.plan.rawValue,
                title: "Choose direction",
                questions: [
                    PlanInputQuestion(
                        id: "direction",
                        question: "Which plan direction should I use?",
                        options: [
                            PlanInputOption(id: "small", label: "Small"),
                            PlanInputOption(id: "large", label: "Large"),
                        ]
                    )
                ]
            )
            _ = try? sessionStore.appendEvents(
                agentID: invokedAgentID,
                sessionID: invokedSessionID,
                events: [
                    AgentSessionEvent(
                        agentId: invokedAgentID,
                        sessionId: invokedSessionID,
                        type: .inputRequest,
                        inputRequest: inputRequest
                    ),
                    AgentSessionEvent(
                        agentId: invokedAgentID,
                        sessionId: invokedSessionID,
                        type: .runStatus,
                        runStatus: AgentRunStatusEvent(
                            stage: .paused,
                            label: "Waiting for input",
                            details: "Choose direction"
                        )
                    )
                ]
            )
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .object([
                    "paused": .bool(true),
                    "requestId": .string("input-123")
                ])
            )
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "ask me before changing files",
            mode: .plan
        )
    )

    #expect(response.appendedEvents.contains(where: { $0.runStatus?.stage == .responding }))
    #expect(response.appendedEvents.contains(where: { $0.runStatus?.stage == .paused }) == false)
    #expect(response.appendedEvents.contains(where: { $0.message?.role == .assistant }) == false)

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(detail.events.contains(where: { $0.toolCall?.tool == "planning.request_input" }))
    #expect(detail.events.contains(where: { $0.inputRequest?.id == "input-123" }))
    #expect(detail.events.contains(where: { $0.runStatus?.stage == .paused }))
    #expect(detail.events.contains(where: { $0.runStatus?.stage == .done }) == false)
    #expect(detail.events.contains(where: { $0.runStatus?.stage == .interrupted }) == false)

    let interrupt = try await orchestrator.controlSession(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionControlRequest(action: .interruptTree, requestedBy: "test", reason: "should not cancel input")
    )
    #expect(interrupt.appendedEvents.isEmpty)

    let interruptedDetail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    #expect(interruptedDetail.events.contains(where: { $0.inputRequest?.id == "input-123" }))
    #expect(interruptedDetail.events.contains(where: { $0.runStatus?.stage == .interrupted }) == false)
}

@Test
func agentSessionOrchestratorAppendsFriendReminderToRuntimeUserMessage() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "friend-reminder-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: "openai-api:gpt-5.4-mini",
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nTest user\n",
                agentsMarkdown: "# Agent\nTest agent\n",
                soulMarkdown: "# Soul\nTest soul\n",
                identityMarkdown: "# Identity\n\(agentID)\n",
                friendReminderMarkdown: "- Do not use mcps\n- always run git pull\n"
            )
        ),
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Да, исправь это как можно скорее",
            mode: .build
        )
    )

    let prompt = await provider.requestedPromptsSnapshot().first(where: {
        $0.contains("[User request]\nДа, исправь это как можно скорее")
    }) ?? ""
    #expect(prompt.contains("[User request]\nДа, исправь это как можно скорее"))
    #expect(prompt.contains("#[FRIEND_REMINDER.md]\n- Do not use mcps\n- always run git pull"))
}

@Test
func nativeAgentSessionPromptIncludesAttachmentPaths() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "attachment-native-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let content = Data("hello attachment".utf8).base64EncodedString()
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Inspect the attached file",
            attachments: [
                AgentAttachmentUpload(
                    name: "notes.txt",
                    mimeType: "text/plain",
                    sizeBytes: 16,
                    contentBase64: content
                )
            ]
        )
    )

    let prompt = await provider.requestedPromptsSnapshot().last ?? ""
    let detail = try sessionStore.loadSession(agentID: agentID, sessionID: session.id)
    let attachments = detail.events.flatMap { event in
        event.message?.segments.compactMap(\.attachment) ?? []
    }
    guard let attachment = attachments.first else {
        Issue.record("Expected persisted attachment in session events")
        return
    }
    guard let attachmentURL = try sessionStore.resolveAttachmentFileURL(agentID: agentID, attachment: attachment) else {
        Issue.record("Expected attachment file URL")
        return
    }
    let expectedAssetDirectory = attachmentURL.deletingLastPathComponent().path
    #expect(prompt.contains("[Attachment context]"))
    #expect(prompt.contains("notes.txt"))
    #expect(prompt.contains("Path: \(expectedAssetDirectory)/"))
    #expect(prompt.contains("files.read"))
    #expect(prompt.contains("runtime.exec"))
}

@Test
func attachmentsDoNotCreateInitialSearchingStatus() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "attachment-no-search-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "search this attachment",
            attachments: [
                AgentAttachmentUpload(
                    name: "payload.json",
                    mimeType: "application/json",
                    sizeBytes: 2,
                    contentBase64: Data("{}".utf8).base64EncodedString()
                )
            ]
        )
    )

    let searchingStatuses = response.appendedEvents.compactMap(\.runStatus).filter { $0.stage == .searching }
    #expect(searchingStatuses.isEmpty)
}

@Test
func toolCallsStillCreateExecutingToolSearchingStatus() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "tool-search-status-agent"
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(models: availableModels.map(\.id), toolName: "files.read")
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(tool: request.tool, ok: true, data: .object(["content": .string("ok")]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Read the file with a tool")
    )

    let verificationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let detail = try verificationStore.loadSession(agentID: agentID, sessionID: session.id)
    let searchingStatuses = detail.events.compactMap(\.runStatus).filter { $0.stage == .searching }
    #expect(searchingStatuses.contains { $0.label == "Executing tool" && $0.details == "Tool: files.read" })
    #expect(detail.events.contains { $0.toolCall?.tool == "files.read" })
}

@Test
func agentSessionBootstrapIncludesInstalledSkillsSummary() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skills-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let skillsStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)
    _ = try skillsStore.installSkill(
        agentID: "skills-agent",
        owner: "acme",
        repo: "release-skills",
        name: "release-helper",
        description: "Guides release execution"
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: skillsStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skills-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skills-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Skills]"))
    #expect(bootstrapMessage.contains("Before replying, scan the skills below."))
    #expect(bootstrapMessage.contains("If a skill matches or is even partially relevant to your task, you MUST read it before answering and follow its instructions."))
    #expect(bootstrapMessage.contains("Use `files.read` on `entrypoint` when provided, otherwise on the skill path plus `/SKILL.md`; do not proceed without loading a genuinely relevant skill."))
    #expect(bootstrapMessage.contains("Only proceed without loading a skill if genuinely none are relevant to the task."))
    #expect(bootstrapMessage.contains("<available_skills>"))
    #expect(bootstrapMessage.contains("</available_skills>"))
    #expect(bootstrapMessage.contains("`acme/release-skills`"))
    #expect(bootstrapMessage.contains("release-helper"))
    #expect(bootstrapMessage.contains("Guides release execution"))
    #expect(bootstrapMessage.contains("`sloppy/task-spec-writer`"))
    #expect(bootstrapMessage.contains("user-invocable: false"))
    let releaseSkillPath = agentsRootURL.appendingPathComponent("skills-agent", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("acme/release-skills", isDirectory: true)
    #expect(bootstrapMessage.contains("path: `\(releaseSkillPath.path)`"))
}

@Test
func agentDocumentUpdatesRefreshExistingSessionBootstrap() async throws {
    let agentID = "doc-refresh-agent"
    let modelID = "openai-api:gpt-5.4-mini"
    let availableModels = [
        ProviderModelOption(id: modelID, title: modelID, contextWindow: "1.0M", capabilities: ["tools"])
    ]
    let agentsRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-doc-refresh-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("agents", isDirectory: true)
    let catalogStore = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let sessionStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    _ = try catalogStore.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Doc Refresh Agent", role: "Test agent"),
        availableModels: availableModels
    )
    let initialConfig = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: modelID,
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nInitial preference\n",
                agentsMarkdown: "# Agent\nFollow project rules\n",
                soulMarkdown: "# Soul\nInitial soul\n",
                identityMarkdown: "# Identity\nDoc Refresh Agent\n"
            )
        ),
        availableModels: availableModels
    )

    let provider = SessionCapturingModelProvider(models: [modelID])
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: modelID)
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )
    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Main"))

    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "first")
    )

    var updatedDocuments = initialConfig.documents
    updatedDocuments.userMarkdown = "# User\nUpdated preference\n"
    updatedDocuments.soulMarkdown = "# Soul\nUpdated soul\n"
    let updateStore = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    _ = try updateStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: initialConfig.role,
            selectedModel: initialConfig.selectedModel,
            documents: updatedDocuments,
            heartbeat: initialConfig.heartbeat,
            channelSessions: initialConfig.channelSessions,
            runtime: initialConfig.runtime
        ),
        availableModels: availableModels
    )
    await orchestrator.notifyAgentDocumentsChanged(agentID: agentID)

    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "second")
    )

    let transcripts = await provider.requestedTranscriptsSnapshot()
    #expect(transcripts.count >= 2)
    #expect(transcripts.last?.joined(separator: "\n").contains("Updated preference") == true)
    #expect(transcripts.last?.joined(separator: "\n").contains("Updated soul") == true)
}

@Test
func agentSessionBootstrapIncludesReadableEntrypointsForInstalledSkills() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skill-entrypoint-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let skillsStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)

    let uiSkillDirectory = agentsRootURL.appendingPathComponent("skill-entrypoint-agent", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("nextlevelbuilder/ui-ux-pro-max-skill", isDirectory: true)
    try FileManager.default.createDirectory(at: uiSkillDirectory, withIntermediateDirectories: true)
    try "# UI UX Pro Max\n".write(to: uiSkillDirectory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = try skillsStore.installSkill(
        agentID: "skill-entrypoint-agent",
        owner: "nextlevelbuilder",
        repo: "ui-ux-pro-max-skill",
        name: "ui-ux-pro-max",
        description: "Design intelligence",
        localPath: uiSkillDirectory.path
    )

    let codeRabbitDirectory = agentsRootURL.appendingPathComponent("skill-entrypoint-agent", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("coderabbitai/skills", isDirectory: true)
    let codeReviewSkill = codeRabbitDirectory
        .appendingPathComponent("skills/code-review", isDirectory: true)
        .appendingPathComponent("SKILL.md")
    try FileManager.default.createDirectory(at: codeReviewSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "---\nname: code-review\n---\n# Code review\n".write(to: codeReviewSkill, atomically: true, encoding: .utf8)
    _ = try skillsStore.installSkill(
        agentID: "skill-entrypoint-agent",
        owner: "coderabbitai",
        repo: "skills",
        name: "skills",
        description: "CodeRabbit skills collection",
        localPath: codeRabbitDirectory.path
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: skillsStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skill-entrypoint-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skill-entrypoint-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("`nextlevelbuilder/ui-ux-pro-max-skill`"))
    #expect(bootstrapMessage.contains("path: `\(uiSkillDirectory.path)`"))
    #expect(bootstrapMessage.contains("entrypoint: `\(uiSkillDirectory.appendingPathComponent("README.md").path)`"))
    #expect(bootstrapMessage.contains("`coderabbitai/skills`"))
    #expect(bootstrapMessage.contains("path: `\(codeRabbitDirectory.path)`"))
    #expect(bootstrapMessage.contains("entrypoint: `\(codeReviewSkill.path)`"))
}

@Test
func agentSessionBootstrapBackfillsBuiltInTaskSpecSkillWhenAgentHasNoSkills() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skills-empty-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let skillsStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: skillsStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skills-empty-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skills-empty-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Skills]"))
    #expect(bootstrapMessage.contains("Before replying, scan the skills below."))
    #expect(bootstrapMessage.contains("<available_skills>"))
    #expect(bootstrapMessage.contains("</available_skills>"))
    #expect(bootstrapMessage.contains("`sloppy/task-spec-writer`"))
    #expect(bootstrapMessage.contains("task-spec-writer"))
    #expect(bootstrapMessage.contains("user-invocable: false"))
    #expect(bootstrapMessage.contains("path: `\(agentsRootURL.appendingPathComponent("skills-empty-agent", isDirectory: true).appendingPathComponent("skills", isDirectory: true).appendingPathComponent("sloppy/task-spec-writer", isDirectory: true).path)`"))

    let verificationSkillsStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)
    let installed = try verificationSkillsStore.listSkills(agentID: "skills-empty-agent")
    #expect(installed.filter { $0.id == BuiltInSkillCatalog.taskSpecWriterID }.count == 1)
    #expect(FileManager.default.fileExists(atPath: agentsRootURL
        .appendingPathComponent("skills-empty-agent", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("sloppy/task-spec-writer", isDirectory: true)
        .appendingPathComponent("SKILL.md")
        .path))
}

@Test
func agentSessionBootstrapIncludesToolCallProtocol() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "tool-protocol-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "tool-protocol-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:tool-protocol-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("`branches.spawn`"))
    #expect(bootstrapMessage.contains("`workers.spawn`"))
    #expect(bootstrapMessage.contains("`workers.route`"))
    #expect(bootstrapMessage.contains("[Branching rules]"))
    #expect(bootstrapMessage.contains("[Worker rules]"))
    #expect(bootstrapMessage.contains("[Tools usage rules]"))
    #expect(bootstrapMessage.contains("native function calls"))
    #expect(bootstrapMessage.contains("`cron`"))
}

@Test
func agentSessionTextContainingFailedDoesNotForceInterruptedStatus() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "non-error-failed-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Initial inspection hit a tool failure, so I need one more recovery pass before I can claim the workspace has been reviewed."
    )

    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "non-error-failed-agent", request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: "non-error-failed-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "inspect the workspace"
        )
    )

    let finalStatus = response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus?.stage
    #expect(finalStatus == .done)
}

@Test
func agentSessionReusesPersistentSessionAcrossMessages() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "session-reuse-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "session-reuse-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "session-reuse-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "first message")
    )
    _ = try await orchestrator.postMessage(
        agentID: "session-reuse-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "second message")
    )

    #expect(await provider.requestedModelsSnapshot().count == 3)
}

@Test
func agentSessionReportsLiveRuntimeSessionOnlyWhileCached() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "live-runtime-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    #expect(await orchestrator.hasLiveRuntimeSession(agentID: agentID, sessionID: session.id) == false)

    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "first message")
    )
    #expect(await orchestrator.hasLiveRuntimeSession(agentID: agentID, sessionID: session.id) == true)

    await runtime.invalidateChannelSession(channelId: "agent:\(agentID):session:\(session.id)")
    #expect(await orchestrator.hasLiveRuntimeSession(agentID: agentID, sessionID: session.id) == false)
}

@Test
func agentSessionRestoresPersistedTranscriptAfterRuntimeSessionInvalidation() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "session-restore-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = ToolCallingModelProvider(
        models: availableModels.map(\.id),
        toolName: "files.list",
        finalText: "Tool-backed answer."
    )
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels,
        toolInvoker: { _, _, request, _ in
            ToolInvocationResult(tool: request.tool, ok: true, data: .object(["count": .number(1)]))
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "inspect files")
    )

    await runtime.invalidateChannelSession(channelId: "agent:\(agentID):session:\(session.id)")

    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "continue")
    )

    let transcripts = await provider.requestedTranscriptsSnapshot()
    let restoredTranscript = transcripts.last?.joined(separator: "\n") ?? ""
    #expect(restoredTranscript.contains("inspect files"))
    #expect(restoredTranscript.contains("Tool-backed answer."))
    #expect(restoredTranscript.contains("toolCalls"))
    #expect(restoredTranscript.contains("toolOutput"))
    #expect(restoredTranscript.contains("continue"))
}

@Test
func linkedChildSessionStartsWithParentTranscriptContext() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "linked-child-restore-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let parent = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Parent"))
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: parent.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "parent task context")
    )

    let child = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Child", parentSessionId: parent.id)
    )
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: child.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "child continuation")
    )

    let transcript = await provider.requestedTranscriptsSnapshot().last?.joined(separator: "\n") ?? ""
    #expect(transcript.contains("prompt:parent task context"))
    #expect(transcript.contains("response:Captured."))
    #expect(transcript.contains("child continuation"))
}

@Test
func checkpointSessionStartsWithCheckpointTranscriptContext() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "checkpoint-restore-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let checkpoint = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Checkpoint"))
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: checkpoint.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "checkpoint task context")
    )

    let next = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Next", checkpointSessionId: checkpoint.id)
    )
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: next.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "after checkpoint")
    )

    let transcript = await provider.requestedTranscriptsSnapshot().last?.joined(separator: "\n") ?? ""
    #expect(next.parentSessionId == nil)
    #expect(transcript.contains("prompt:checkpoint task context"))
    #expect(transcript.contains("response:Captured."))
    #expect(transcript.contains("after checkpoint"))
}

@Test
func unlinkedFreshSessionDoesNotInheritRecentInterruptedSessionTranscript() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "unlinked-no-restore-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let interrupted = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Interrupted"))
    _ = try sessionStore.appendEvents(
        agentID: agentID,
        sessionID: interrupted.id,
        events: [
            AgentSessionEvent(
                agentId: agentID,
                sessionId: interrupted.id,
                type: .message,
                message: AgentSessionMessage(role: .user, segments: [.init(kind: .text, text: "do not leak this context")])
            ),
            AgentSessionEvent(
                agentId: agentID,
                sessionId: interrupted.id,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(stage: .interrupted, label: "Interrupted")
            )
        ]
    )

    let fresh = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Fresh"))
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: fresh.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "fresh task")
    )

    let transcript = await provider.requestedTranscriptsSnapshot().last?.joined(separator: "\n") ?? ""
    #expect(!transcript.contains("do not leak this context"))
    #expect(transcript.contains("fresh task"))
}

@Test
func agentSessionBootstrapFallsBackWhenPromptComposerFails() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "fallback-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let documents = try catalogStore.readAgentDocuments(agentID: "fallback-agent")
    let failingLoader = PromptTemplateLoader(resolver: { _ in
        throw PromptTemplateLoader.LoaderError.templateNotFound("forced-failure")
    })
    let composer = AgentPromptComposer(templateLoader: failingLoader)

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        promptComposer: composer,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "fallback-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:fallback-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    let expected = try expectedFallbackBootstrapMessage(
        agentID: "fallback-agent",
        sessionID: session.id,
        documents: documents,
        agentDirectoryPath: agentsRootURL.appendingPathComponent("fallback-agent", isDirectory: true).path
    )
    func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
    }
    #expect(normalized(bootstrapMessage) == normalized(expected))
}

@Test
func agentSessionBootstrapIncludesSkillsRulesPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "skills-rules-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skills-rules-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skills-rules-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Skills rules]"))
    #expect(bootstrapMessage.contains("files.read"))
    #expect(bootstrapMessage.contains("SKILL.md"))
}

@Test
func agentSessionBootstrapIncludesCompletionReflectionPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "completion-reflection-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "completion-reflection-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:completion-reflection-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Completion reflection]"))
    #expect(bootstrapMessage.contains("decide yourself whether the work produced anything durable"))
    #expect(bootstrapMessage.contains("without asking the user to triage it"))
}

@Test
func agentSessionBootstrapIncludesTaskPlanningRulesPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "task-planning-rules-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "task-planning-rules-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:task-planning-rules-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Task planning rules]"))
    #expect(bootstrapMessage.contains("project.task_list"))
    #expect(bootstrapMessage.contains("project.task_update"))
    #expect(bootstrapMessage.contains("not only by exact title text"))
}

@Test
func agentSessionBootstrapIncludesTaskSpecRulesPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "task-spec-rules-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "task-spec-rules-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:task-spec-rules-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Task spec rules]"))
    #expect(bootstrapMessage.contains("Definition of Done"))
    #expect(bootstrapMessage.contains("RFC/ADR"))
    #expect(bootstrapMessage.contains("memory.save"))
}

@Test
func notifySkillsChangedAppendsSystemMessageToActiveSessions() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "notify-skills-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "notify-skills-agent", request: AgentSessionCreateRequest())
    let channelID = "agent:notify-skills-agent:session:\(session.id)"
    let messageCountBefore = await runtime.channelState(channelId: channelID)?.messages.count ?? 0

    // Install the skill via a separate store instance (same filesystem root) to simulate mid-session install
    let installStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)
    _ = try installStore.installSkill(
        agentID: "notify-skills-agent",
        owner: "acme",
        repo: "test-skill",
        name: "test-skill",
        description: "A test skill"
    )

    await orchestrator.notifySkillsChanged(agentID: "notify-skills-agent")

    let messages = await runtime.channelState(channelId: channelID)?.messages ?? []
    #expect(messages.count > messageCountBefore)

    let skillsUpdateMessage = messages.last(where: {
        $0.userId == "system" && $0.content.contains("[Skills updated]")
    })
    #expect(skillsUpdateMessage != nil)
    #expect(skillsUpdateMessage?.content.contains("`acme/test-skill`") == true)
    #expect(skillsUpdateMessage?.content.contains("test-skill") == true)
}

@Test
func notifySkillsChangedDoesNothingForNonBootstrappedSessions() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "notify-no-bootstrap-agent",
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        availableModels: availableModels
    )

    // No session created — notifySkillsChanged should be a no-op (no bootstrapped channels)
    await orchestrator.notifySkillsChanged(agentID: "notify-no-bootstrap-agent")

    let channelID = "agent:notify-no-bootstrap-agent:session:nonexistent-session"
    let snapshot = await runtime.channelState(channelId: channelID)
    #expect(snapshot == nil)
}

@Test
func agentSessionBootstrapIncludesConversationHistoryAfterRestart() async throws {
    let agentID = "restart-history-agent"
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentsRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-restart-history-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("agents", isDirectory: true)

    let catalogStore1 = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let sessionStore1 = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    _ = try catalogStore1.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Agent", role: "Test agent"),
        availableModels: availableModels
    )
    _ = try catalogStore1.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: "openai-api:gpt-5.4-mini",
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nTest\n",
                agentsMarkdown: "# Agent\nTest\n",
                soulMarkdown: "",
                identityMarkdown: ""
            )
        ),
        availableModels: availableModels
    )

    let provider1 = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Hello! I can help with that."
    )
    let runtime1 = RuntimeSystem(modelProvider: provider1, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator1 = AgentSessionOrchestrator(
        runtime: runtime1,
        sessionStore: sessionStore1,
        agentCatalogStore: catalogStore1,
        availableModels: availableModels
    )

    let session = try await orchestrator1.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Restart test")
    )
    _ = try await orchestrator1.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Tell me about Swift concurrency")
    )
    _ = try await orchestrator1.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "How do actors work?")
    )

    let provider2 = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Continuing the discussion."
    )
    let runtime2 = RuntimeSystem(modelProvider: provider2, defaultModel: "openai-api:gpt-5.4-mini")
    let sessionStore2 = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let catalogStore2 = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let orchestrator2 = AgentSessionOrchestrator(
        runtime: runtime2,
        sessionStore: sessionStore2,
        agentCatalogStore: catalogStore2,
        availableModels: availableModels
    )

    _ = try await orchestrator2.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Continue please")
    )

    let channelID = "agent:\(agentID):session:\(session.id)"
    let snapshot = await runtime2.channelState(channelId: channelID)
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Previous conversation history]"))
    #expect(bootstrapMessage.contains("Tell me about Swift concurrency"))
    #expect(bootstrapMessage.contains("How do actors work?"))
    #expect(bootstrapMessage.contains("[End of previous conversation]"))
}

@Test
func agentSessionRefreshesStaleBootstrapWithPersistedHistory() async throws {
    let agentID = "stale-bootstrap-history-agent"
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Stale bootstrap test")
    )
    let channelID = "agent:\(agentID):session:\(session.id)"
    let initialBootstrap = await runtime.channelBootstrapContent(channelId: channelID) ?? ""
    #expect(!initialBootstrap.contains("[Previous conversation history]"))

    let mutationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    _ = try mutationStore.appendEvents(
        agentID: agentID,
        sessionID: session.id,
        events: [
            AgentSessionEvent(
                agentId: agentID,
                sessionId: session.id,
                type: .message,
                message: AgentSessionMessage(
                    role: .user,
                    segments: [.init(kind: .text, text: "Original task: explain the failing session restore")]
                )
            ),
            AgentSessionEvent(
                agentId: agentID,
                sessionId: session.id,
                type: .message,
                message: AgentSessionMessage(
                    role: .assistant,
                    segments: [.init(kind: .text, text: "I found that the restored session needs its JSONL history.")]
                )
            )
        ]
    )

    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Continue from there")
    )

    let refreshedBootstrap = await runtime.channelBootstrapContent(channelId: channelID) ?? ""
    #expect(refreshedBootstrap.contains("[Previous conversation history]"))
    #expect(refreshedBootstrap.contains("Original task: explain the failing session restore"))
    #expect(refreshedBootstrap.contains("I found that the restored session needs its JSONL history."))
}

@Test
func agentSessionInvalidatesCachedModelSessionWhenStaleBootstrapGainsHistory() async throws {
    let agentID = "stale-cached-history-agent"
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai-api:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Stale cached bootstrap test")
    )
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "first live turn")
    )
    #expect(await provider.requestedModelsSnapshot().count == 2)

    let mutationStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    _ = try mutationStore.appendEvents(
        agentID: agentID,
        sessionID: session.id,
        events: [
            AgentSessionEvent(
                agentId: agentID,
                sessionId: session.id,
                type: .message,
                message: AgentSessionMessage(
                    role: .user,
                    segments: [.init(kind: .text, text: "persisted context that was not in the cached model session")]
                )
            )
        ]
    )

    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "continue with restored context")
    )

    #expect(await provider.requestedModelsSnapshot().count == 4)
    let restoredTranscript = await provider.requestedTranscriptsSnapshot().last?.joined(separator: "\n") ?? ""
    #expect(restoredTranscript.contains("first live turn"))
    #expect(restoredTranscript.contains("persisted context that was not in the cached model session"))
    #expect(restoredTranscript.contains("continue with restored context"))
}

@Test
func agentSessionBootstrapOmitsHistoryForFreshSession() async throws {
    let agentID = "fresh-no-history-agent"
    let availableModels = [
        ProviderModelOption(id: "openai-api:gpt-5.4-mini", title: "openai-api:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai-api:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest()
    )

    let channelID = "agent:\(agentID):session:\(session.id)"
    let snapshot = await runtime.channelState(channelId: channelID)
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(!bootstrapMessage.contains("[Previous conversation history]"))
}

@Test
func sessionRefreshesChangedScopedDocumentsWithoutLosingConversation() async throws {
    let modelID = "mock:scoped-documents"
    let models = [ProviderModelOption(id: modelID, title: "Mock", capabilities: ["tools"])]
    let agentID = "scoped-doc-refresh"
    let (catalog, store, root) = try makeAgentSessionFixture(agentID: agentID, selectedModel: modelID, availableModels: models)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try catalog.writeAgentScopedMarkdown(agentID: agentID, userID: "alice", field: .user, markdown: "SCOPED_BEFORE_MARKER")
    let provider = SessionCapturingModelProvider(models: [modelID])
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: modelID)
    let orchestrator = AgentSessionOrchestrator(runtime: runtime, sessionStore: store, agentCatalogStore: catalog, availableModels: models)
    let session = try await orchestrator.createSession(agentID: agentID, request: .init())
    _ = try await orchestrator.postMessage(agentID: agentID, sessionID: session.id, request: .init(userId: "alice", content: "Remember this conversation"))
    #expect(await provider.requestedTranscriptsSnapshot().last?.joined(separator: "\n").contains("SCOPED_BEFORE_MARKER") == true)
    let documentWriter = AgentCatalogFileStore(agentsRootURL: root)
    try documentWriter.writeAgentScopedMarkdown(agentID: agentID, userID: "alice", field: .user, markdown: "SCOPED_AFTER_MARKER")
    _ = try await orchestrator.postMessage(agentID: agentID, sessionID: session.id, request: .init(userId: "alice", content: "Continue our conversation"))
    let transcript = await provider.requestedTranscriptsSnapshot().last?.joined(separator: "\n") ?? ""
    #expect(transcript.contains("SCOPED_AFTER_MARKER"))
    #expect(!transcript.contains("SCOPED_BEFORE_MARKER"))
    #expect(transcript.contains("Remember this conversation"))
}
