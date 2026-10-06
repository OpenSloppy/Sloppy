import AnyLanguageModel
import Foundation
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import PluginSDK
@testable import Protocols
@testable import sloppy

private struct UsageReportingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let text: String
    let capture: TokenUsageCapture
    let promptTokens: Int
    let completionTokens: Int
    let onRequest: @Sendable () async -> Void

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else {
            fatalError("UsageReportingLanguageModel only supports String responses")
        }
        await onRequest()
        capture.store(promptTokens: promptTokens, completionTokens: completionTokens)
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
                    within: session,
                    to: prompt,
                    generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt,
                    options: options
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

private actor UsageReportingModelProvider: ModelProvider {
    let id: String = "usage-reporting"
    let supportedModels: [String]
    let capture = TokenUsageCapture()
    private(set) var requestCount = 0
    private func recordRequest() { requestCount += 1 }

    init(models: [String]) {
        self.supportedModels = models
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        UsageReportingLanguageModel(
            text: "Recorded.",
            capture: capture,
            promptTokens: 123,
            completionTokens: 45,
            onRequest: { await self.recordRequest() }
        )
    }

    nonisolated func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? {
        capture
    }
}

private actor TokenUsageObserverCapture {
    private(set) var records: [(agentID: String, sessionID: String, usage: TokenUsage)] = []

    func record(agentID: String, sessionID: String, usage: TokenUsage) {
        records.append((agentID: agentID, sessionID: sessionID, usage: usage))
    }
}

@Test
func agentSessionOrchestratorForwardsModelTokenUsage() async throws {
    let agentID = "usage-agent"
    let modelID = "openai-api:gpt-5.4-mini"
    let models = [
        ProviderModelOption(id: modelID, title: modelID, contextWindow: "1.0M", capabilities: ["tools"])
    ]
    let agentsRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-token-usage-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("agents", isDirectory: true)
    let catalogStore = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let sessionStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    _ = try catalogStore.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Usage Agent", role: "Test agent"),
        availableModels: models
    )
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: modelID,
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nTest user\n",
                agentsMarkdown: "# Agent\nTest agent\n",
                soulMarkdown: "# Soul\nTest soul\n",
                identityMarkdown: "# Identity\n\(agentID)\n"
            )
        ),
        availableModels: models
    )

    let provider = UsageReportingModelProvider(models: [modelID])
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: modelID)
    let observer = TokenUsageObserverCapture()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: models,
        tokenUsageObserver: { agentID, sessionID, usage in
            await observer.record(agentID: agentID, sessionID: sessionID, usage: usage)
        }
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Count this")
    )

    let requestCount = await provider.requestCount
    #expect(requestCount > 0)
    let expectedPrompt = 123 * requestCount
    let expectedCompletion = 45 * requestCount
    let records = await observer.records
    #expect(records.count == 1)
    #expect(records.first?.agentID == agentID)
    #expect(records.first?.sessionID == session.id)
    #expect(records.first?.usage.prompt == expectedPrompt)
    #expect(records.first?.usage.completion == expectedCompletion)

    let responseUsageStatuses = response.appendedEvents.compactMap(\.runStatus).filter { $0.tokenUsage != nil }
    #expect(responseUsageStatuses.last?.stage == .done)
    #expect(responseUsageStatuses.last?.tokenUsage?.prompt == expectedPrompt)
    #expect(responseUsageStatuses.last?.tokenUsage?.completion == expectedCompletion)

    let detail = try sessionStore.loadSession(agentID: agentID, sessionID: session.id)
    let persistedUsageStatuses = detail.events.compactMap(\.runStatus).filter { $0.tokenUsage != nil }
    #expect(persistedUsageStatuses.contains { $0.stage == .responding && $0.tokenUsage?.prompt == expectedPrompt && $0.tokenUsage?.completion == expectedCompletion })
    #expect(persistedUsageStatuses.last?.stage == .done)
    #expect(persistedUsageStatuses.last?.tokenUsage?.prompt == expectedPrompt)
    #expect(persistedUsageStatuses.last?.tokenUsage?.completion == expectedCompletion)
}
