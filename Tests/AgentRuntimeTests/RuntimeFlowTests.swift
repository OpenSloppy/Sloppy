import AnyLanguageModel
import Foundation
import Testing
@testable import AgentRuntime
@testable import PluginSDK
@testable import Protocols

@Test
func routingDoesNotUseKeywordHeuristicsForBranchingOrWorkers() async {
    let system = RuntimeSystem()

    let decision = await system.postMessage(
        channelId: "general",
        request: ChannelMessageRequest(
            userId: "u1",
            content: "please implement and run tests, oppure analizza l'architettura"
        )
    )

    #expect(decision.action == .respond)
}

@Test
func interactiveWorkerRouteRequiresStructuredCommand() async throws {
    let system = RuntimeSystem()
    let spec = WorkerTaskSpec(
        taskId: "task-route",
        channelId: "general",
        title: "Interactive",
        objective: "wait for route",
        tools: ["shell"],
        mode: .interactive
    )

    let workerId = await system.createWorker(spec: spec)
    let accepted = await system.routeMessage(channelId: "general", workerId: workerId, message: "done")
    #expect(accepted)

    let waitingSnapshots = await system.workerSnapshots()
    let waitingSnapshot = waitingSnapshots.first(where: { $0.workerId == workerId })
    #expect(waitingSnapshot?.status == .waitingInput)

    let completion = WorkerRouteCommand(command: .complete, summary: "Worker finished", error: nil, report: nil)
    let completionMessage = String(decoding: try JSONEncoder().encode(completion), as: UTF8.self)
    let completed = await system.routeMessage(channelId: "general", workerId: workerId, message: completionMessage)
    #expect(completed)

    let completedSnapshots = await system.workerSnapshots()
    let completedSnapshot = completedSnapshots.first(where: { $0.workerId == workerId })
    #expect(completedSnapshot?.status == .completed)
    #expect(completedSnapshot?.latestReport == "Worker finished")
}

@Test
func compactorThresholdsProduceEvents() async {
    let bus = EventBus()
    let compactor = Compactor(eventBus: bus)

    let job1 = await compactor.evaluate(channelId: "c1", utilization: 0.81)
    #expect(job1?.level == .soft)

    let job2 = await compactor.evaluate(channelId: "c1", utilization: 0.90)
    #expect(job2?.level == .aggressive)

    let job3 = await compactor.evaluate(channelId: "c1", utilization: 0.97)
    #expect(job3?.level == .emergency)
}

@Test
func compactorUsesCustomConfigurationAndCanBeDisabled() async {
    let bus = EventBus()
    let disabled = Compactor(
        eventBus: bus,
        configuration: CompactorConfiguration(enabled: false)
    )
    let disabledJob = await disabled.evaluate(channelId: "disabled", utilization: 0.99)
    #expect(disabledJob == nil)

    let custom = Compactor(
        eventBus: bus,
        configuration: CompactorConfiguration(
            contextWindowTokens: 64_000,
            levels: [
                CompactionLevelConfiguration(
                    level: .aggressive,
                    utilizationThreshold: 0.50,
                    targetReductionPercent: 62,
                    preserveRecentMessages: 12,
                    preserveRecentTokens: 4_000
                )
            ]
        )
    )

    let customJob = await custom.evaluate(channelId: "custom", utilization: 0.51)
    #expect(customJob?.level == .aggressive)
    #expect(customJob?.threshold == 0.50)
    #expect(customJob?.targetReductionPercent == 62)
    #expect(customJob?.preserveRecentMessages == 12)
    #expect(customJob?.preserveRecentTokens == 4_000)
    #expect(customJob?.contextWindowTokens == 64_000)
}

@Test
func compactorConfigurationClampsUnsafeValues() {
    let level = CompactionLevelConfiguration(
        level: .soft,
        utilizationThreshold: 150,
        targetReductionPercent: 150,
        preserveRecentMessages: -1,
        preserveRecentTokens: -2
    )
    #expect(level.utilizationThreshold == 1.0)
    #expect(level.targetReductionPercent == 100)
    #expect(level.preserveRecentMessages == 0)
    #expect(level.preserveRecentTokens == 0)
}

@Test
func tokenPressureEstimatorCountsAttachmentsAsBoundedPlaceholders() {
    let estimator = TokenPressureEstimator(contextWindowTokens: 2_000)
    let request = ChannelMessageRequest(
        userId: "u1",
        content: "hello",
        attachments: [
            ChannelAttachment(
                id: "img-1",
                type: .image,
                mimeType: "image/png",
                filename: "screenshot.png",
                sizeBytes: 6_000_000,
                platformMetadata: ["base64": String(repeating: "a", count: 10_000)]
            )
        ]
    )

    let estimate = estimator.estimate(request: request)

    #expect(estimate.source == .roughRequest)
    #expect(estimate.tokens > 768)
    #expect(estimate.tokens < 4_000)
}

@Test
func contextLedgerSeparatesOccupancyFromLastTurnEconomics() {
    let snapshot = ContextLedgerSnapshot(
        channelId: "ledger-channel",
        contextWindowTokens: 10_000,
        reservedOutputTokens: 1_000,
        entries: [
            ContextLedgerEntry(category: .bootstrapStatic, label: "AGENTS.md", estimatedTokens: 2_000, cachePolicy: .cacheable),
            ContextLedgerEntry(category: .toolsSchema, label: "native tools", estimatedTokens: 1_500, cachePolicy: .cacheable),
            ContextLedgerEntry(category: .currentTurn, label: "user", estimatedTokens: 100, cachePolicy: .uncacheable),
        ],
        lastTurnUsage: TokenUsage(prompt: 3_700, completion: 80, cachedInputTokens: 3_000, cacheCreationInputTokens: 400, reasoningTokens: 12)
    )

    #expect(snapshot.contextWindowUsedTokens == 3_600)
    #expect(snapshot.contextWindowFreeTokens == 5_400)
    #expect(snapshot.lastTurnInputTokens == 3_700)
    #expect(snapshot.lastTurnCachedInputTokens == 3_000)
    #expect(snapshot.lastTurnUncachedInputTokens == 700)
    #expect(snapshot.lastTurnCacheCreationInputTokens == 400)
    #expect(snapshot.lastTurnCompletionTokens == 80)
    #expect(snapshot.lastTurnReasoningTokens == 12)
}

@Test
func tokenPressurePrefersLedgerOccupancyOverLastPromptUsage() {
    let estimator = TokenPressureEstimator(contextWindowTokens: 10_000)
    let ledger = ContextLedgerSnapshot(
        channelId: "pressure-ledger",
        contextWindowTokens: 10_000,
        reservedOutputTokens: 1_000,
        entries: [
            ContextLedgerEntry(category: .bootstrapStatic, label: "bootstrap", estimatedTokens: 2_000),
            ContextLedgerEntry(category: .currentTurn, label: "turn", estimatedTokens: 500),
        ],
        lastTurnUsage: TokenUsage(prompt: 9_500, completion: 100, cachedInputTokens: 8_000)
    )

    let pressure = estimator.estimate(
        messages: [],
        latestPromptUsage: ledger.lastTurnUsage,
        ledgerSnapshot: ledger
    )

    #expect(pressure.source == .contextLedger)
    #expect(pressure.tokens == 3_500)
    #expect(pressure.utilization == 0.35)
}

@Test
func channelPressureUsesProviderPromptUsageWhenAvailable() async {
    let channel = ChannelRuntime(eventBus: EventBus(), contextWindowTokens: 1_000)

    _ = await channel.ingest(
        channelId: "c1",
        request: ChannelMessageRequest(userId: "u1", content: String(repeating: "x", count: 40))
    )
    let rough = await channel.snapshot(channelId: "c1")
    #expect(rough?.contextPressureSource == .roughMessages)
    #expect((rough?.contextUtilization ?? 0) < 0.20)

    await channel.recordTokenUsage(
        channelId: "c1",
        usage: TokenUsage(prompt: 800, completion: 2, reasoningTokens: 5)
    )
    let real = await channel.snapshot(channelId: "c1")

    #expect(real?.contextPressureSource == .realUsage)
    #expect(real?.contextUtilization == 0.802)
}

@Test
func channelPressureFallsBackToRealUsageWhenLedgerBecomesStaleAfterSystemAppend() async throws {
    let channel = ChannelRuntime(eventBus: EventBus(), contextWindowTokens: 1_000)
    let ledger = ContextLedgerSnapshot(
        channelId: "c1",
        contextWindowTokens: 1_000,
        reservedOutputTokens: 100,
        entries: [
            ContextLedgerEntry(category: .bootstrapStatic, label: "bootstrap", estimatedTokens: 200),
        ]
    )

    _ = await channel.ingest(
        channelId: "c1",
        request: ChannelMessageRequest(userId: "u1", content: "hello")
    )
    await channel.recordTokenUsage(
        channelId: "c1",
        usage: TokenUsage(prompt: 800, completion: 2)
    )
    await channel.recordContextLedger(channelId: "c1", snapshot: ledger)

    let ledgerBacked = try #require(await channel.snapshot(channelId: "c1"))
    #expect(ledgerBacked.contextPressureSource == .contextLedger)
    #expect(ledgerBacked.contextUtilization == 0.3)

    await channel.appendSystemMessage(channelId: "c1", content: "Assistant reply not represented in ledger.")
    let invalidated = try #require(await channel.snapshot(channelId: "c1"))

    #expect(invalidated.contextPressureSource == .realUsage)
    #expect(invalidated.contextUtilization == 0.802)
}

@Test
func channelPressureFallsBackToRoughMessagesWhenNewUserMessageInvalidatesLedger() async throws {
    let channel = ChannelRuntime(eventBus: EventBus(), contextWindowTokens: 1_000)
    let ledger = ContextLedgerSnapshot(
        channelId: "c1",
        contextWindowTokens: 1_000,
        reservedOutputTokens: 100,
        entries: [
            ContextLedgerEntry(category: .bootstrapStatic, label: "bootstrap", estimatedTokens: 200),
        ]
    )

    _ = await channel.ingest(
        channelId: "c1",
        request: ChannelMessageRequest(userId: "u1", content: "hello")
    )
    await channel.recordTokenUsage(
        channelId: "c1",
        usage: TokenUsage(prompt: 800, completion: 2)
    )
    await channel.recordContextLedger(channelId: "c1", snapshot: ledger)

    _ = await channel.ingest(
        channelId: "c1",
        request: ChannelMessageRequest(userId: "u2", content: "follow up")
    )
    let invalidated = try #require(await channel.snapshot(channelId: "c1"))

    #expect(invalidated.contextPressureSource == .roughMessages)
    #expect(invalidated.contextUtilization < 0.1)
}

@Test
func restoreMessageInvalidatesLiveLedgerAndRecomputesFallbackPressure() async throws {
    let channel = ChannelRuntime(eventBus: EventBus(), contextWindowTokens: 1_000)
    let ledger = ContextLedgerSnapshot(
        channelId: "restore-live-ledger",
        contextWindowTokens: 1_000,
        reservedOutputTokens: 100,
        entries: [
            ContextLedgerEntry(category: .bootstrapStatic, label: "bootstrap", estimatedTokens: 200),
        ]
    )

    _ = await channel.ingest(
        channelId: "restore-live-ledger",
        request: ChannelMessageRequest(userId: "u1", content: "hello")
    )
    await channel.recordTokenUsage(
        channelId: "restore-live-ledger",
        usage: TokenUsage(prompt: 800, completion: 40)
    )
    await channel.recordContextLedger(channelId: "restore-live-ledger", snapshot: ledger)

    let ledgerBacked = try #require(await channel.snapshot(channelId: "restore-live-ledger"))
    #expect(ledgerBacked.contextPressureSource == .contextLedger)
    #expect(ledgerBacked.contextUtilization == 0.3)

    await channel.restoreMessage(
        channelId: "restore-live-ledger",
        message: ChannelMessageEntry(
            id: "restored-assistant",
            userId: "system",
            content: "Recovered assistant reply.",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    )
    let invalidated = try #require(await channel.snapshot(channelId: "restore-live-ledger"))

    #expect(invalidated.contextPressureSource == .realUsage)
    #expect(invalidated.contextUtilization == 0.84)

    let roughOnlyChannel = ChannelRuntime(eventBus: EventBus(), contextWindowTokens: 1_000)
    await roughOnlyChannel.recordContextLedger(channelId: "restore-rough", snapshot: ledger)
    await roughOnlyChannel.restoreMessage(
        channelId: "restore-rough",
        message: ChannelMessageEntry(
            id: "restored-user",
            userId: "u2",
            content: "Recovered history entry.",
            createdAt: Date(timeIntervalSince1970: 2)
        )
    )
    let roughFallback = try #require(await roughOnlyChannel.snapshot(channelId: "restore-rough"))

    #expect(roughFallback.contextPressureSource == .roughMessages)
    #expect(roughFallback.contextUtilization > 0)
    #expect(roughFallback.contextUtilization < 0.1)
}

@Test
func compactorDeduplicatesInFlightJobsByChannelAndLevel() async {
    let bus = EventBus()
    let workers = WorkerRuntime(eventBus: bus)
    let applier = BlockingCompactionApplier()
    let compactor = Compactor(
        eventBus: bus,
        applier: { job, _ in
            await applier.execute(job: job)
        },
        sleepOperation: { _ in }
    )

    let job = CompactionJob(channelId: "c1", level: .aggressive, threshold: 0.85)
    await compactor.apply(job: job, workers: workers)
    await applier.waitUntilFirstAttemptIsBlocked()

    await compactor.apply(job: job, workers: workers)
    await applier.releaseFirstAttempt()

    let summaryEvent = await firstEvent(
        matching: .compactorSummaryApplied,
        in: await bus.subscribe()
    )

    #expect(summaryEvent != nil)
    #expect(await applier.attempts(for: .aggressive) == 1)
}

@Test
func compactorRetriesWithBackoffUntilSuccess() async {
    let bus = EventBus()
    let workers = WorkerRuntime(eventBus: bus)
    let applier = FlakyCompactionApplier(failuresBeforeSuccess: 2)
    let sleepRecorder = SleepRecorder()
    let retryPolicy = CompactorRetryPolicy(
        maxAttempts: 3,
        initialBackoffNanoseconds: 10_000,
        multiplier: 2.0,
        maxBackoffNanoseconds: 20_000
    )
    let compactor = Compactor(
        eventBus: bus,
        retryPolicy: retryPolicy,
        applier: { job, _ in
            await applier.execute(job: job)
        },
        sleepOperation: { duration in
            await sleepRecorder.record(duration)
        }
    )

    await compactor.apply(
        job: CompactionJob(channelId: "c1", level: .emergency, threshold: 0.95),
        workers: workers
    )

    let summaryEvent = await firstEvent(
        matching: .compactorSummaryApplied,
        in: await bus.subscribe()
    )

    #expect(summaryEvent != nil)
    #expect(await applier.attemptCount() == 3)
    #expect(await sleepRecorder.values() == [10_000, 20_000])
}

@Test
func branchIsEphemeralAfterConclusion() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let countBefore = await branchRuntime.activeBranchesCount()
    #expect(countBefore == 1)

    _ = await branchRuntime.conclude(
        branchId: branchId,
        summary: "final summary",
        artifactRefs: [],
        tokenUsage: TokenUsage(prompt: 20, completion: 10)
    )

    let countAfter = await branchRuntime.activeBranchesCount()
    #expect(countAfter == 0)
}

@Test
func validBranchConclusionPublishesConclusionEvent() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)
    let stream = await bus.subscribe()

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let expectedSummary = "final summary"
    let expectedUsage = TokenUsage(prompt: 20, completion: 10)
    let conclusion = await branchRuntime.conclude(
        branchId: branchId,
        summary: expectedSummary,
        artifactRefs: [ArtifactRef(id: "art-1", kind: "text", preview: "artifact preview")],
        tokenUsage: expectedUsage
    )

    #expect(conclusion != nil)
    let event = await firstEvent(matching: .branchConclusion, in: stream)
    #expect(event?.branchId == branchId)
    let decoded = event.flatMap { try? JSONValueCoder.decode(BranchConclusion.self, from: $0.payload) }
    #expect(decoded?.summary == expectedSummary)
    #expect(decoded?.tokenUsage == expectedUsage)
}

@Test
func invalidBranchConclusionEmitsFailureEvent() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)
    let stream = await bus.subscribe()

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let conclusion = await branchRuntime.conclude(
        branchId: branchId,
        summary: "   ",
        artifactRefs: [ArtifactRef(id: "art-dup", kind: "text", preview: "a"), ArtifactRef(id: "art-dup", kind: "text", preview: "b")],
        tokenUsage: TokenUsage(prompt: -1, completion: 10)
    )

    #expect(conclusion == nil)

    let events = await collectEvents(in: stream)
    let failure = events.first(where: { $0.messageType == .workerFailed && $0.branchId == branchId })
    #expect(failure != nil)
    #expect(failure?.payload.objectValue["code"]?.stringValue == "empty_summary")
    #expect(!events.contains(where: { $0.messageType == .branchConclusion && $0.branchId == branchId }))
}

@Test
func visorCreatesBulletin() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let bulletin = await visor.generateBulletin(channels: [], workers: [])
    #expect(!bulletin.digest.isEmpty)

    let entries = await memory.entries()
    #expect(entries.isEmpty)
}

private actor ToolInvocationCounter {
    private var count = 0
    private var tools: [String] = []

    func increment(tool: String? = nil) {
        count += 1
        if let tool {
            tools.append(tool)
        }
    }

    func value() -> Int {
        count
    }

    func toolNames() -> [String] {
        tools
    }
}

private actor NativeLoopOutcomeCapture {
    private var outcome: NativeAgentLoopOutcome?

    func store(_ outcome: NativeAgentLoopOutcome) {
        self.outcome = outcome
    }

    func value() -> NativeAgentLoopOutcome? {
        outcome
    }
}

private struct NativeToolSequenceLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let toolNames: [String]
    let finalText: String
    var failStreaming = false

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("NativeToolSequenceLanguageModel: only String supported") }

        var entries: [Transcript.Entry] = []
        if let delegate = session.toolExecutionDelegate {
            for toolName in toolNames {
                let toolCall = Transcript.ToolCall(
                    id: UUID().uuidString,
                    toolName: toolName,
                    arguments: GeneratedContent("")
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
            if failStreaming {
                continuation.finish(throwing: StreamIdleTimeoutError())
                return
            }
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

private actor NativeToolSequenceModelProvider: ModelProvider {
    let id: String = "native-tool-sequence"
    nonisolated var supportedModels: [String] { ["mock-model"] }
    let toolNames: [String]
    let finalText: String

    let failStreaming: Bool

    init(toolNames: [String], finalText: String = "Finished after native tools.", failStreaming: Bool = false) {
        self.toolNames = toolNames
        self.finalText = finalText
        self.failStreaming = failStreaming
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        NativeToolSequenceLanguageModel(toolNames: toolNames, finalText: finalText, failStreaming: failStreaming)
    }
}

// MARK: - Shared mock infrastructure

private final class MockCallStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _models: [String] = []
    private var _reasoningEfforts: [ReasoningEffort?] = []
    private var _prompts: [String] = []
    private var _instructions: [String] = []

    func recordModel(_ model: String) { lock.withLock { _models.append(model) } }
    func recordEffort(_ effort: ReasoningEffort?) { lock.withLock { _reasoningEfforts.append(effort) } }
    func recordPrompt(_ prompt: String) { lock.withLock { _prompts.append(prompt) } }
    func recordInstructions(_ instructions: String?) { lock.withLock { _instructions.append(instructions ?? "") } }

    var models: [String] { lock.withLock { _models } }
    var reasoningEfforts: [ReasoningEffort?] { lock.withLock { _reasoningEfforts } }
    var lastPrompt: String? { lock.withLock { _prompts.last } }
    var allPrompts: [String] { lock.withLock { _prompts } }
    var allInstructions: [String] { lock.withLock { _instructions } }
}

private func extractPromptText(from prompt: Prompt) -> String {
    prompt.description
}

private func extractToolName(from text: String) -> String? {
    func tryParse(_ candidate: String) -> String? {
        guard let data = candidate.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = json["tool"] as? String
        else { return nil }
        return tool
    }

    if let tool = tryParse(text) { return tool }

    var depth = 0
    var start: String.Index?
    for i in text.indices {
        switch text[i] {
        case "{":
            if depth == 0 { start = i }
            depth += 1
        case "}":
            depth -= 1
            if depth == 0, let s = start {
                if let tool = tryParse(String(text[s...i])) { return tool }
                start = nil
            }
        default: break
        }
    }
    return nil
}

// MARK: - SequencedModelProvider

private struct SequencedMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let provider: SequencedModelProvider

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("SequencedMockLanguageModel: only String supported") }

        let firstOutput = await provider.dequeue()
        var entries: [Transcript.Entry] = []

        if let toolName = extractToolName(from: firstOutput), let delegate = session.toolExecutionDelegate {
            let toolCall = Transcript.ToolCall(id: UUID().uuidString, toolName: toolName, arguments: GeneratedContent(""))
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
            let finalOutput = await provider.dequeue()
            return LanguageModelSession.Response(
                content: finalOutput as! Content,
                rawContent: GeneratedContent(finalOutput),
                transcriptEntries: ArraySlice(entries)
            )
        }

        return LanguageModelSession.Response(
            content: firstOutput as! Content,
            rawContent: GeneratedContent(firstOutput),
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
                do {
                    let response = try await respond(
                        within: session, to: prompt, generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt, options: options
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

private actor SequencedModelProvider: ModelProvider {
    let id: String = "sequenced"
    nonisolated var supportedModels: [String] { ["mock-model"] }
    nonisolated let callStore = MockCallStore()
    private var queue: [String]

    init(outputs: [String]) {
        self.queue = outputs
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return SequencedMockLanguageModel(provider: self)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func dequeue() -> String {
        queue.isEmpty ? "No output." : queue.removeFirst()
    }

    func requestedModelsSnapshot() -> [String] { callStore.models }
    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] { callStore.reasoningEfforts }
}

// MARK: - FailingModelProvider

private enum FailingModelError: Error, CustomStringConvertible {
    case providerUnavailable

    var description: String {
        "provider unavailable"
    }
}

private struct FailingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        throw FailingModelError.providerUnavailable
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        LanguageModelSession.ResponseStream(stream: AsyncThrowingStream { continuation in
            continuation.finish(throwing: FailingModelError.providerUnavailable)
        })
    }
}

private actor FailingModelProvider: ModelProvider {
    let id: String = "failing"
    nonisolated var supportedModels: [String] { ["mock-model"] }
    nonisolated let callStore = MockCallStore()

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return FailingMockLanguageModel()
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func requestedModelsSnapshot() -> [String] { callStore.models }
}

// MARK: - ReconnectingModelProvider

private actor ReconnectDelayCapture {
    private var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }

    func snapshot() -> [Duration] {
        delays
    }
}

private actor ReconnectingModelProvider: ModelProvider {
    let id: String = "reconnecting"
    nonisolated var supportedModels: [String] { ["mock-model"] }
    private var failuresBeforeSuccess: Int
    private let successText: String
    private let errorCode: URLError.Code
    private var requests = 0

    init(failuresBeforeSuccess: Int, successText: String, errorCode: URLError.Code = .networkConnectionLost) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.successText = successText
        self.errorCode = errorCode
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        ReconnectingMockLanguageModel(provider: self)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func nextResponseText() throws -> String {
        requests += 1
        guard failuresBeforeSuccess <= 0 else {
            failuresBeforeSuccess -= 1
            throw URLError(errorCode)
        }
        return successText
    }

    func requestCount() -> Int {
        requests
    }
}

private struct ReconnectingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let provider: ReconnectingModelProvider

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("ReconnectingMockLanguageModel: only String supported") }
        let text = try await provider.nextResponseText()
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
        guard type == String.self else { fatalError("ReconnectingMockLanguageModel: only String supported") }
        let provider = provider
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                do {
                    let text = try await provider.nextResponseText()
                    continuation.yield(.init(
                        content: text as! Content.PartiallyGenerated,
                        rawContent: GeneratedContent(text)
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

// MARK: - PromptCapturingModelProvider

private struct PromptCapturingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let callStore: MockCallStore
    let streamOutput: String?
    let respondOutput: String
    let usageCapture: TokenUsageCapture?
    let streamUsage: TokenUsage?
    let respondUsage: TokenUsage?

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("PromptCapturingMockLanguageModel: only String supported") }
        callStore.recordInstructions(session.instructions?.description)
        callStore.recordPrompt(extractPromptText(from: prompt))
        if let respondUsage {
            usageCapture?.store(
                promptTokens: respondUsage.prompt,
                completionTokens: respondUsage.completion,
                cachedInputTokens: respondUsage.cachedInput,
                cacheCreationInputTokens: respondUsage.cacheCreationInput,
                reasoningTokens: respondUsage.reasoning
            )
        }
        return LanguageModelSession.Response(
            content: respondOutput as! Content,
            rawContent: GeneratedContent(respondOutput),
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
        guard type == String.self else { fatalError("PromptCapturingMockLanguageModel: only String supported") }
        guard let output = streamOutput else {
            return LanguageModelSession.ResponseStream(stream: AsyncThrowingStream { $0.finish() })
        }
        let store = callStore
        let instructions = session.instructions?.description
        let text = extractPromptText(from: prompt)
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                store.recordInstructions(instructions)
                store.recordPrompt(text)
                if let streamUsage {
                    usageCapture?.store(
                        promptTokens: streamUsage.prompt,
                        completionTokens: streamUsage.completion,
                        cachedInputTokens: streamUsage.cachedInput,
                        cacheCreationInputTokens: streamUsage.cacheCreationInput,
                        reasoningTokens: streamUsage.reasoning
                    )
                }
                continuation.yield(.init(content: output as! Content.PartiallyGenerated, rawContent: GeneratedContent(output)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private final class PromptCapturingModelProvider: ModelProvider, @unchecked Sendable {
    let id: String = "prompt-capturing"
    let supportedModels: [String]
    private let streamOutput: String?
    private let respondOutput: String
    private let usageCapture: TokenUsageCapture?
    private let streamUsage: TokenUsage?
    private let respondUsage: TokenUsage?
    let callStore = MockCallStore()

    init(
        models: [String] = ["mock-model"],
        streamOutput: String? = nil,
        respondOutput: String = "Captured.",
        tokenUsageCapture: TokenUsageCapture? = nil,
        streamUsage: TokenUsage? = nil,
        respondUsage: TokenUsage? = nil
    ) {
        self.supportedModels = models
        self.streamOutput = streamOutput
        self.respondOutput = respondOutput
        self.usageCapture = tokenUsageCapture
        self.streamUsage = streamUsage
        self.respondUsage = respondUsage
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return PromptCapturingMockLanguageModel(
            callStore: callStore,
            streamOutput: streamOutput,
            respondOutput: respondOutput,
            usageCapture: usageCapture,
            streamUsage: streamUsage,
            respondUsage: respondUsage
        )
    }

    func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? {
        usageCapture
    }

    func lastPrompt() async -> String? { callStore.lastPrompt }
    func allPrompts() async -> [String] { callStore.allPrompts }
    func allInstructions() async -> [String] { callStore.allInstructions }
    func requestedModelsSnapshot() async -> [String] { callStore.models }
    func requestedReasoningEffortsSnapshot() async -> [ReasoningEffort?] { callStore.reasoningEfforts }
}

@Test
func respondInlineAutoToolCallingLoop() async {
    let provider = SequencedModelProvider(
        outputs: [
            "{\"tool\":\"agents.list\",\"arguments\":{},\"reason\":\"need agents\"}",
            "Final answer after tool execution."
        ]
    )
    let invocationCounter = ToolInvocationCounter()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    let decision = await system.postMessage(
        channelId: "tool-loop",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment()
            #expect(request.tool == "agents.list")
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .array([])
            )
        }
    )

    #expect(decision.action == .respond)
    let snapshot = await system.channelState(channelId: "tool-loop")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Final answer after tool execution.")
    #expect(await invocationCounter.value() == 1)
    #expect(await provider.requestedModelsSnapshot() == ["mock-model"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [nil])
}

@Test
func respondInlineStopsBeforeExecutingToolsWhenToolRoundLimitIsReached() async throws {
    let provider = SequencedModelProvider(
        outputs: [
            "{\"tool\":\"agents.list\",\"arguments\":{},\"reason\":\"loop\"}",
            "This final answer should not be used."
        ]
    )
    let invocationCounter = ToolInvocationCounter()
    let outcomeCapture = NativeLoopOutcomeCapture()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "tool-loop-limit",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment()
            return ToolInvocationResult(tool: request.tool, ok: true)
        },
        nativeLoopConfig: NativeAgentLoopConfig(maxToolRounds: 0),
        nativeLoopOutcomeHandler: { outcome in
            await outcomeCapture.store(outcome)
        }
    )

    let snapshot = await system.channelState(channelId: "tool-loop-limit")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    let outcome = try #require(await outcomeCapture.value())

    #expect(finalMessage == "Agent reached the tool turn limit before producing a final answer.")
    #expect(await invocationCounter.value() == 0)
    #expect(outcome.toolRoundsUsed == 1)
    #expect(outcome.maxToolRounds == 0)
    #expect(outcome.hitTurnLimit)
    #expect(!outcome.finishedNaturally)
}

@Test(arguments: [false, true])
func respondInlineStopsToolLoopWithoutEmptyResponseRetry(failStreaming: Bool) async throws {
    let provider = NativeToolSequenceModelProvider(
        toolNames: ["memory.save", "memory.save", "memory.save"],
        finalText: "This success message must never be generated.",
        failStreaming: failStreaming
    )
    let counter = ToolInvocationCounter()
    let capture = NativeLoopOutcomeCapture()
    let system = RuntimeSystem(modelProvider: provider)
    _ = await system.postMessage(
        channelId: "memory-loop", request: .init(userId: "test", content: "Import memory"),
        toolInvoker: { request in
            await counter.increment(tool: request.tool)
            let code = await counter.value() == 1 ? "memory_not_found" : "tool_loop_detected"
            return .init(tool: request.tool, ok: false, error: .init(code: code, message: "Correct memory_id.", retryable: false))
        },
        nativeLoopOutcomeHandler: { await capture.store($0) }
    )
    #expect(await counter.value() == 2)
    let outcome = try #require(await capture.value())
    #expect(outcome.turnExitReason == .toolLoopDetected)
    #expect(!outcome.finishedNaturally)
    #expect(outcome.toolErrors.count == 2)
    #expect(outcome.lastAssistantText.contains("Correct memory_id"))
    let state = await system.channelState(channelId: "memory-loop")
    #expect(state?.messages.last(where: { $0.userId == "system" })?.content == outcome.lastAssistantText)
}

@Test
func respondInlineAllowsFinalizerAfterToolBudgetRecovery() async throws {
    let provider = NativeToolSequenceModelProvider(
        toolNames: ["files.list", "agent_delegate.finish"],
        finalText: "Delegated task finished."
    )
    let invocationCounter = ToolInvocationCounter()
    let outcomeCapture = NativeLoopOutcomeCapture()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "tool-budget-finalizer",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment(tool: request.tool)
            return ToolInvocationResult(tool: request.tool, ok: true)
        },
        nativeLoopConfig: NativeAgentLoopConfig(
            maxToolRounds: 0,
            finalizerToolNames: ["agent_delegate.finish"],
            overBudgetRecoveryBatches: 1
        ),
        nativeLoopOutcomeHandler: { outcome in
            await outcomeCapture.store(outcome)
        }
    )

    let snapshot = await system.channelState(channelId: "tool-budget-finalizer")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    let outcome = try #require(await outcomeCapture.value())

    #expect(finalMessage == "Delegated task finished.")
    #expect(await invocationCounter.toolNames() == ["agent_delegate.finish"])
    #expect(outcome.toolRoundsUsed == 1)
    #expect(!outcome.hitTurnLimit)
    #expect(outcome.toolErrors.contains { $0.error?.code == "tool_budget_exhausted" })
}

@Test
func respondInlineHardStopsAfterBudgetRecoveryIsIgnored() async throws {
    let provider = NativeToolSequenceModelProvider(
        toolNames: ["files.list", "files.read"],
        finalText: "This should not be used."
    )
    let invocationCounter = ToolInvocationCounter()
    let outcomeCapture = NativeLoopOutcomeCapture()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "tool-budget-hard-stop",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment(tool: request.tool)
            return ToolInvocationResult(tool: request.tool, ok: true)
        },
        nativeLoopConfig: NativeAgentLoopConfig(
            maxToolRounds: 0,
            finalizerToolNames: ["agent_delegate.finish"],
            overBudgetRecoveryBatches: 1
        ),
        nativeLoopOutcomeHandler: { outcome in
            await outcomeCapture.store(outcome)
        }
    )

    let snapshot = await system.channelState(channelId: "tool-budget-hard-stop")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    let outcome = try #require(await outcomeCapture.value())

    #expect(finalMessage == "Agent reached the tool turn limit before producing a final answer.")
    #expect(await invocationCounter.value() == 0)
    #expect(outcome.toolRoundsUsed == 2)
    #expect(outcome.hitTurnLimit)
    #expect(!outcome.finishedNaturally)
}

@Test
func respondInlineParsesToolCallEmbeddedInAssistantText() async {
    let provider = SequencedModelProvider(
        outputs: [
            """
            Initial inspection hit a tool failure, so I need a recovery step.

            {"tool":"agents.list","arguments":{},"reason":"recover after previous tool failure"}
            """,
            "Final answer after recovery tool execution."
        ]
    )
    let invocationCounter = ToolInvocationCounter()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    let decision = await system.postMessage(
        channelId: "tool-loop-inline-json",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment()
            #expect(request.tool == "agents.list")
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .array([])
            )
        }
    )

    #expect(decision.action == .respond)
    let snapshot = await system.channelState(channelId: "tool-loop-inline-json")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Final answer after recovery tool execution.")
    #expect(await invocationCounter.value() == 1)
}

@Test
func respondInlineRecreatesSessionWhenRequestedModelChanges() async {
    let provider = SequencedModelProvider(outputs: ["First", "Second"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-a")
    let channelId = "model-switch"

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "u1", content: "hello", model: "mock-a")
    )
    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "u1", content: "hello again", model: "mock-b")
    )

    #expect(await provider.requestedModelsSnapshot() == ["mock-a", "mock-b"])
}

@Test
func respondInlineIncludesBootstrapContextInPrompt() async {
    let provider = PromptCapturingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let channelId = "session-bootstrap"

    let bootstrapContent = """
    [agent_session_context_bootstrap_v1]
    [IDENTITY.md]
    Тебя зовут Серега
    """
    await system.setChannelBootstrap(channelId: channelId, content: bootstrapContent)

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "привет, как тебя зовут?")
    )

    let instructions = await provider.allInstructions()
    let prompts = await provider.allPrompts()
    let bootstrapInstructions = instructions.last ?? ""
    let userPrompt = prompts.last ?? ""

    #expect(bootstrapInstructions.contains("[agent_session_context_bootstrap_v1]"))
    #expect(bootstrapInstructions.contains("Тебя зовут Серега"))
    #expect(userPrompt.contains("привет, как тебя зовут?"))
}

@Test
func updatingBootstrapContextInvalidatesPersistentSession() async {
    let provider = PromptCapturingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let channelId = "session-bootstrap-refresh"

    await system.setChannelBootstrap(channelId: channelId, content: "Initial bootstrap")
    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "first")
    )

    await system.setChannelBootstrap(channelId: channelId, content: "Updated bootstrap")
    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "second")
    )

    let instructions = await provider.allInstructions()
    #expect(await provider.requestedModelsSnapshot().count == 2)
    #expect(instructions.first?.contains("Initial bootstrap") == true)
    #expect(instructions.last?.contains("Updated bootstrap") == true)
}

@Test
func respondInlineInjectsScopedMemoryForAgentSession() async {
    let provider = PromptCapturingModelProvider()
    let memory = InMemoryMemoryStore()
    let channelId = "agent:test-agent:session:test-session"
    let otherChannelId = "agent:test-agent:session:other-session"
    _ = await memory.save(
        entry: MemoryWriteRequest(
            note: "The project codename is Aurora.",
            summary: "Project codename Aurora",
            kind: .fact,
            memoryClass: .semantic,
            scope: .channel(channelId)
        )
    )
    _ = await memory.save(
        entry: MemoryWriteRequest(
            note: "The project codename is Borealis.",
            summary: "Unrelated session codename Borealis",
            kind: .fact,
            memoryClass: .semantic,
            scope: .channel(otherChannelId)
        )
    )
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "mock-model",
        memoryStore: memory
    )

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "What is the project codename?")
    )

    let prompt = await provider.lastPrompt() ?? ""
    #expect(prompt.contains("[Recalled scoped memory]"))
    #expect(prompt.contains("Project codename Aurora"))
    #expect(prompt.contains("[Current user message]"))
    #expect(prompt.contains("What is the project codename?"))
    #expect(!prompt.contains("Borealis"))
}

@Test
func respondInlineUsesRequestModelInsteadOfDefaultModel() async {
    let provider = PromptCapturingModelProvider(models: ["default-model", "reasoning-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "default-model")

    _ = await system.postMessage(
        channelId: "request-model",
        request: ChannelMessageRequest(
            userId: "dashboard",
            content: "use the request model",
            model: "reasoning-model"
        )
    )

    #expect(await provider.requestedModelsSnapshot().last == "reasoning-model")
}

@Test
func respondInlineForwardsReasoningEffortToStreamingRequests() async {
    let provider = PromptCapturingModelProvider(models: ["reasoning-model"], streamOutput: "Streamed.")
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "reasoning-model")

    _ = await system.postMessage(
        channelId: "stream-reasoning",
        request: ChannelMessageRequest(
            userId: "dashboard",
            content: "stream with effort",
            model: "reasoning-model",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedReasoningEffortsSnapshot().last == .high)
}

@Test
func respondInlineForwardsReasoningEffortToFallbackCompletion() async {
    let provider = PromptCapturingModelProvider(models: ["reasoning-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "reasoning-model")

    _ = await system.postMessage(
        channelId: "fallback-reasoning",
        request: ChannelMessageRequest(
            userId: "dashboard",
            content: "fallback with effort",
            model: "reasoning-model",
            reasoningEffort: .low
        )
    )

    #expect(await provider.requestedReasoningEffortsSnapshot().last == .low)
}

@Test
func runtimeRecordsContextLedgerForNativeModelCall() async throws {
    let expectedUsage = TokenUsage(
        prompt: 240,
        completion: 32,
        cachedInputTokens: 144,
        cacheCreationInputTokens: 24,
        reasoningTokens: 5
    )
    let usageCapture = TokenUsageCapture()
    let provider = PromptCapturingModelProvider(
        models: ["prompt-capturing"],
        streamOutput: "Streamed.",
        tokenUsageCapture: usageCapture,
        streamUsage: expectedUsage
    )
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "prompt-capturing",
        compactorConfiguration: CompactorConfiguration(contextWindowTokens: 8_000)
    )
    let usageCollector = UsageCollector()
    let ledgerSnapshotCollector = ChannelSnapshotCollector()
    await system.setChannelBootstrap(
        channelId: "ledger-runtime",
        content: "Stable bootstrap instructions."
    )

    _ = await system.postMessage(
        channelId: "ledger-runtime",
        request: ChannelMessageRequest(userId: "user", content: "Hello"),
        observationHandler: { observation in
            if case .usage(let usage) = observation {
                await usageCollector.append(usage)
                await ledgerSnapshotCollector.append(await system.channelState(channelId: "ledger-runtime"))
            }
        }
    )

    let snapshot = try #require(await system.contextLedgerSnapshot(channelId: "ledger-runtime"))
    let observedLedgerSnapshot = try #require(await ledgerSnapshotCollector.all().last)
    #expect(snapshot.channelId == "ledger-runtime")
    #expect(snapshot.entries.contains { $0.category == .bootstrapStatic })
    #expect(snapshot.entries.contains { $0.category == .currentTurn })
    #expect(snapshot.contextWindowTokens == 8_000)
    #expect(snapshot.lastTurnUsage == expectedUsage)
    #expect(snapshot.lastTurnCachedInputTokens == 144)
    #expect(snapshot.lastTurnUncachedInputTokens == 96)
    #expect(snapshot.lastTurnCacheCreationInputTokens == 24)
    #expect(snapshot.lastTurnReasoningTokens == 5)
    #expect(observedLedgerSnapshot.contextPressureSource == .contextLedger)
    #expect(await usageCollector.all() == [expectedUsage])
}

@Test
func runtimeRecordsContextLedgerForFallbackCompletionUsage() async throws {
    let expectedUsage = TokenUsage(
        prompt: 180,
        completion: 28,
        cachedInputTokens: 120,
        cacheCreationInputTokens: 18,
        reasoningTokens: 4
    )
    let usageCapture = TokenUsageCapture()
    let provider = PromptCapturingModelProvider(
        models: ["prompt-capturing"],
        streamOutput: nil,
        respondOutput: "Captured from fallback.",
        tokenUsageCapture: usageCapture,
        respondUsage: expectedUsage
    )
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "prompt-capturing",
        compactorConfiguration: CompactorConfiguration(contextWindowTokens: 8_000)
    )
    let usageCollector = UsageCollector()
    let ledgerSnapshotCollector = ChannelSnapshotCollector()

    _ = await system.postMessage(
        channelId: "ledger-runtime-fallback",
        request: ChannelMessageRequest(userId: "user", content: "Hello"),
        observationHandler: { observation in
            if case .usage(let usage) = observation {
                await usageCollector.append(usage)
                await ledgerSnapshotCollector.append(await system.channelState(channelId: "ledger-runtime-fallback"))
            }
        }
    )

    let snapshot = try #require(await system.contextLedgerSnapshot(channelId: "ledger-runtime-fallback"))
    let channelSnapshot = try #require(await system.channelState(channelId: "ledger-runtime-fallback"))
    let observedLedgerSnapshot = try #require(await ledgerSnapshotCollector.all().last)
    let finalMessage = channelSnapshot.messages.last(where: { $0.userId == "system" })?.content

    #expect(finalMessage == "Captured from fallback.")
    #expect(snapshot.lastTurnUsage == expectedUsage)
    #expect(snapshot.lastTurnCachedInputTokens == 120)
    #expect(snapshot.lastTurnUncachedInputTokens == 60)
    #expect(snapshot.lastTurnCacheCreationInputTokens == 18)
    #expect(snapshot.lastTurnReasoningTokens == 4)
    #expect(observedLedgerSnapshot.contextPressureSource == .contextLedger)
    #expect(await usageCollector.all() == [expectedUsage])
}

@Test
func compactionUsesLedgerBackedUtilizationAfterResponse() async throws {
    let provider = PromptCapturingModelProvider(
        models: ["prompt-capturing"],
        streamOutput: "Streamed.",
        tokenUsageCapture: TokenUsageCapture(),
        streamUsage: TokenUsage(prompt: 1_500, completion: 1_000)
    )
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "prompt-capturing",
        compactorConfiguration: CompactorConfiguration(
            contextWindowTokens: 6_000,
            levels: [
                CompactionLevelConfiguration(
                    level: .soft,
                    utilizationThreshold: 0.40,
                    targetReductionPercent: 30
                )
            ]
        )
    )

    _ = await system.postMessage(
        channelId: "ledger-compaction",
        request: ChannelMessageRequest(userId: "user", content: "hi")
    )

    let ledgerSnapshot = try #require(await system.contextLedgerSnapshot(channelId: "ledger-compaction"))
    let snapshot = try #require(await system.channelState(channelId: "ledger-compaction"))
    let finalMessages = snapshot.messages.suffix(2).map(\.content)

    #expect(ledgerSnapshot.utilization < 0.40)
    #expect(snapshot.contextPressureSource == .realUsage)
    #expect(snapshot.contextUtilization > 0.40)
    #expect(finalMessages.contains("Streamed."))
    #expect(finalMessages.contains("Compactor scheduled soft policy"))
}

@Test
func respondInlineRepairsEmptyStreamAndCompletion() async {
    let provider = SequencedModelProvider(outputs: ["   ", "\n", "Recovered final answer."])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "empty-repair",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let snapshot = await system.channelState(channelId: "empty-repair")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Recovered final answer.")
    #expect(await provider.requestedModelsSnapshot() == ["mock-model", "mock-model"])
}

@Test
func respondInlineFallsBackWhenEmptyRepairAlsoReturnsEmpty() async {
    let provider = SequencedModelProvider(outputs: ["   ", "\n", "\t "])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "empty-repair-fallback",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let snapshot = await system.channelState(channelId: "empty-repair-fallback")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Model returned an empty response. Please try rephrasing or try again.")
    #expect(await provider.requestedModelsSnapshot() == ["mock-model", "mock-model"])
}

@Test
func respondInlineProviderErrorsBypassEmptyRepair() async {
    let provider = FailingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "provider-error-no-repair",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let snapshot = await system.channelState(channelId: "provider-error-no-repair")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage.contains("Model provider error:"))
    #expect(finalMessage.contains("providerUnavailable") || finalMessage.contains("provider unavailable"))
    #expect(await provider.requestedModelsSnapshot() == ["mock-model"])
}

@Test
func respondInlineReconnectsInterruptedModelSession() async {
    let provider = ReconnectingModelProvider(failuresBeforeSuccess: 2, successText: "Recovered after reconnect.")
    let delayCapture = ReconnectDelayCapture()
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "mock-model",
        modelReconnectSleeper: { delay in
            await delayCapture.record(delay)
        }
    )

    _ = await system.postMessage(
        channelId: "provider-reconnect-success",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let messages = await system.channelState(channelId: "provider-reconnect-success")?.messages ?? []
    let systemMessages = messages.filter { $0.userId == "system" }.map(\.content)
    #expect(systemMessages.contains("Reconnecting 1/5"))
    #expect(systemMessages.contains("Reconnecting 2/5"))
    #expect(systemMessages.last == "Recovered after reconnect.")
    #expect(await delayCapture.snapshot() == [.seconds(5), .seconds(7)])
    #expect(await provider.requestCount() == 3)
}

@Test
func respondInlineReconnectsTimedOutModelSession() async {
    let provider = ReconnectingModelProvider(
        failuresBeforeSuccess: 1,
        successText: "Recovered after timeout.",
        errorCode: .timedOut
    )
    let delayCapture = ReconnectDelayCapture()
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "mock-model",
        modelReconnectSleeper: { delay in
            await delayCapture.record(delay)
        }
    )

    _ = await system.postMessage(
        channelId: "provider-reconnect-timeout",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let messages = await system.channelState(channelId: "provider-reconnect-timeout")?.messages ?? []
    let systemMessages = messages.filter { $0.userId == "system" }.map(\.content)
    #expect(systemMessages.contains("Reconnecting 1/5"))
    #expect(systemMessages.last == "Recovered after timeout.")
    #expect(await delayCapture.snapshot() == [.seconds(5)])
    #expect(await provider.requestCount() == 2)
}

@Test
func respondInlineWritesProviderErrorAfterReconnectAttemptsExhausted() async {
    let provider = ReconnectingModelProvider(failuresBeforeSuccess: 6, successText: "Should not reach this.")
    let delayCapture = ReconnectDelayCapture()
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "mock-model",
        modelReconnectSleeper: { delay in
            await delayCapture.record(delay)
        }
    )

    _ = await system.postMessage(
        channelId: "provider-reconnect-exhausted",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let messages = await system.channelState(channelId: "provider-reconnect-exhausted")?.messages ?? []
    let systemMessages = messages.filter { $0.userId == "system" }.map(\.content)
    #expect(systemMessages.filter { $0.hasPrefix("Reconnecting ") } == [
        "Reconnecting 1/5",
        "Reconnecting 2/5",
        "Reconnecting 3/5",
        "Reconnecting 4/5",
        "Reconnecting 5/5",
    ])
    #expect(systemMessages.last?.contains("Model provider error:") == true)
    #expect(systemMessages.last?.contains("-1005") == true)
    #expect(await delayCapture.snapshot() == [.seconds(5), .seconds(7), .seconds(9), .seconds(10), .seconds(12)])
    #expect(await provider.requestCount() == 6)
}

@Test
func respondInlineReusesRequestModelAndReasoningEffortAcrossToolLoop() async {
    let provider = SequencedModelProvider(
        outputs: [
            "{\"tool\":\"agents.list\",\"arguments\":{},\"reason\":\"need agents\"}",
            "Final answer after tool execution."
        ]
    )
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "fallback-model")

    _ = await system.postMessage(
        channelId: "tool-loop-request-model",
        request: ChannelMessageRequest(
            userId: "u1",
            content: "hello",
            model: "mock-model",
            reasoningEffort: .medium
        ),
        toolInvoker: { request in
            ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .array([])
            )
        }
    )

    #expect(await provider.requestedModelsSnapshot() == ["mock-model"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [.medium])
}

@Test
func appendSystemMessagePublishesChannelMessageEvent() async {
    let system = RuntimeSystem()
    let stream = await system.eventBus.subscribe()

    await system.appendSystemMessage(
        channelId: "recovery-channel",
        content: "Recovered bootstrap context"
    )

    let event = await firstEvent(matching: .channelMessageReceived, in: stream)
    #expect(event?.channelId == "recovery-channel")
    #expect(event?.payload.objectValue["userId"]?.stringValue == "system")
    #expect(event?.payload.objectValue["message"]?.stringValue == "Recovered bootstrap context")
}

private actor BlockingCompactionApplier {
    private var attemptsByLevel: [String: Int] = [:]
    private var isFirstAttemptBlocked = false
    private var firstAttemptReadyContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func execute(job: CompactionJob) async -> CompactionJobExecutionResult {
        attemptsByLevel[job.level.rawValue, default: 0] += 1

        if !isFirstAttemptBlocked {
            isFirstAttemptBlocked = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                firstAttemptReadyContinuation?.resume()
                firstAttemptReadyContinuation = nil
            }
        }

        return CompactionJobExecutionResult(success: true, workerId: "compaction-worker-blocking")
    }

    func waitUntilFirstAttemptIsBlocked() async {
        if isFirstAttemptBlocked, releaseContinuation != nil {
            return
        }

        await withCheckedContinuation { continuation in
            firstAttemptReadyContinuation = continuation
        }
    }

    func releaseFirstAttempt() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func attempts(for level: CompactionLevel) -> Int {
        attemptsByLevel[level.rawValue, default: 0]
    }
}

private actor FlakyCompactionApplier {
    private var failuresBeforeSuccess: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func execute(job _: CompactionJob) -> CompactionJobExecutionResult {
        attempts += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            return CompactionJobExecutionResult(success: false, workerId: "compaction-worker-flaky")
        }

        return CompactionJobExecutionResult(success: true, workerId: "compaction-worker-flaky")
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor SleepRecorder {
    private var recorded: [UInt64] = []

    func record(_ nanoseconds: UInt64) {
        recorded.append(nanoseconds)
    }

    func values() -> [UInt64] {
        recorded
    }
}

private actor EventCollector {
    private var events: [EventEnvelope] = []

    func append(_ event: EventEnvelope) {
        events.append(event)
    }

    func all() -> [EventEnvelope] {
        events
    }
}

private actor FirstEventProbe {
    private var event: EventEnvelope?

    func record(_ event: EventEnvelope) {
        guard self.event == nil else { return }
        self.event = event
    }

    func value() -> EventEnvelope? {
        event
    }
}

private func firstEvent(
    matching type: MessageType,
    in stream: AsyncStream<EventEnvelope>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> EventEnvelope? {
    let probe = FirstEventProbe()
    let task = Task {
        for await event in stream {
            if Task.isCancelled {
                break
            }
            if event.messageType == type {
                await probe.record(event)
                break
            }
        }
    }

    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000.0)
    while Date() < deadline {
        if let event = await probe.value() {
            task.cancel()
            return event
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    task.cancel()
    return await probe.value()
}

private func collectEvents(
    in stream: AsyncStream<EventEnvelope>,
    timeoutNanoseconds: UInt64 = 250_000_000
) async -> [EventEnvelope] {
    let collector = EventCollector()
    let task = Task {
        for await event in stream {
            await collector.append(event)
        }
    }

    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
    task.cancel()
    return await collector.all()
}

private func waitUntil(
    timeoutNanoseconds: UInt64,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000.0)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

// MARK: - Persistent session tests

@Test
func memoryDebugCapturesTheInputOfAnActualRuntimeTurn() async throws {
    let provider = PromptCapturingModelProvider(models: ["mock-model"])
    let memory = InMemoryMemoryStore()
    _ = await memory.save(entry: MemoryWriteRequest(note: "Aurora uses Swift", scope: .agent("debug")))
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model", memoryStore: memory)
    let channel = "agent:debug:session:live"
    await system.setChannelBootstrap(channelId: channel, content: "Curated bootstrap")
    _ = await system.postMessage(channelId: channel, request: ChannelMessageRequest(userId: "u1", content: "Aurora"))
    let snapshot = await system.memoryDiagnostics.snapshot(channelId: channel)
    let context = try #require(snapshot.modelContext)
    #expect(snapshot.queries.count == 2)
    #expect(context.entries.first?.kind == "instructions")
    #expect(context.entries.first?.content.contains("Curated bootstrap") == true)
    #expect(context.entries.last?.content.contains("Aurora uses Swift") == true)
    #expect(context.entries.last?.content.hasSuffix("Aurora") == true)
    #expect(context.memoryInjection?.hitIds.count == 1)
}

@Test
func persistentSessionReusesLanguageModelAcrossMessages() async {
    let provider = PromptCapturingModelProvider(models: ["mock-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "reuse-channel",
        request: ChannelMessageRequest(userId: "u1", content: "first message")
    )
    _ = await system.postMessage(
        channelId: "reuse-channel",
        request: ChannelMessageRequest(userId: "u1", content: "second message")
    )

    #expect(await provider.requestedModelsSnapshot().count == 1)
}

@Test
func persistentSessionInvalidatedOnModelProviderUpdate() async {
    let provider = PromptCapturingModelProvider(models: ["mock-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "invalidation-channel",
        request: ChannelMessageRequest(userId: "u1", content: "first message")
    )

    await system.updateModelProvider(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "invalidation-channel",
        request: ChannelMessageRequest(userId: "u1", content: "second message")
    )

    #expect(await provider.requestedModelsSnapshot().count == 2)
}

@Test
func abortChannelCancelsActiveInlineResponseTask() async {
    let provider = CancellableStreamModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let outcomeCapture = NativeLoopOutcomeCapture()
    let postTask = Task {
        await system.postMessage(
            channelId: "cancel-inline-channel",
            request: ChannelMessageRequest(userId: "u1", content: "please wait"),
            nativeLoopOutcomeHandler: { outcome in
                await outcomeCapture.store(outcome)
            }
        )
    }

    let streamStarted = await waitUntil(timeoutNanoseconds: 10_000_000_000) {
        await provider.hasStarted()
    }
    #expect(streamStarted)
    let cancelled = await system.abortChannel(channelId: "cancel-inline-channel", reason: "test interrupt")
    _ = await postTask.value

    #expect(cancelled == 1)
    let outcome = await outcomeCapture.value()
    #expect(outcome?.finishedNaturally == false)
    #expect(outcome?.hitTurnLimit == false)
    let snapshot = await system.channelState(channelId: "cancel-inline-channel")
    #expect(snapshot?.messages.contains(where: { $0.userId == "system" && $0.content == "late response" }) == false)
}

@Test
func persistentSessionContextOverflowCreatesNewSession() async {
    let provider = ContextOverflowModelProvider(recoveryResponse: "Recovered response.")
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "overflow-channel",
        request: ChannelMessageRequest(userId: "u1", content: "hello")
    )

    let snapshot = await system.channelState(channelId: "overflow-channel")
    let lastSystemMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(lastSystemMessage == "Recovered response.")
    #expect(await provider.currentCallCount() == 2)
}

@Test
func recoveryTranscriptSeedsOnlyFreshLanguageModelSession() async {
    let provider = TranscriptCapturingModelProvider(models: ["mock-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let channelID = "recovery-seed-channel"

    await system.setChannelRecoveryTranscript(
        channelId: channelID,
        transcript: Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "seeded before first turn"))]))
        ])
    )

    _ = await system.postMessage(
        channelId: channelID,
        request: ChannelMessageRequest(userId: "u1", content: "first live turn")
    )

    await system.setChannelRecoveryTranscript(
        channelId: channelID,
        transcript: Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "seeded while cached"))]))
        ])
    )

    _ = await system.postMessage(
        channelId: channelID,
        request: ChannelMessageRequest(userId: "u1", content: "second live turn")
    )

    let transcripts = await provider.transcriptsSnapshot()
    #expect(transcripts.count == 2)
    #expect(transcripts[0].contains("seeded before first turn"))
    #expect(transcripts[0].contains("first live turn"))
    #expect(!transcripts[1].contains("seeded while cached"))
    #expect(transcripts[1].contains("seeded before first turn"))
    #expect(transcripts[1].contains("second live turn"))
}

@Test
func recoveryTranscriptToolNamesAreRemappedToSanitizedSessionTools() async {
    let system = RuntimeSystem()
    let tools = ModelToolNameSanitizer.sanitizeTools([
        NamedTool(name: "planning.select_route")
    ]).tools
    let transcript = Transcript(entries: [
        .toolCalls(Transcript.ToolCalls([
            Transcript.ToolCall(
                id: "call_123",
                toolName: "planning.select_route",
                arguments: GeneratedContent(properties: [:])
            )
        ])),
        .toolOutput(Transcript.ToolOutput(
            id: "call_123",
            toolName: "planning.select_route",
            segments: [.text(.init(content: "{\"ok\":true}"))]
        ))
    ])

    let remapped = await system.transcriptWithProviderSafeToolNames(transcript, tools: tools)

    guard case .toolCalls(let calls) = remapped[0] else {
        Issue.record("Expected tool calls entry")
        return
    }
    guard case .toolOutput(let output) = remapped[1] else {
        Issue.record("Expected tool output entry")
        return
    }

    #expect(calls.first?.toolName == "planning_select_route")
    #expect(output.toolName == "planning_select_route")
}

private actor TranscriptCaptureStore {
    private var transcripts: [String] = []

    func record(_ transcript: Transcript) {
        transcripts.append(transcript.map(debugRuntimeTranscriptEntry).joined(separator: "\n"))
    }

    func snapshot() -> [String] {
        transcripts
    }
}

private struct NamedTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description = "Test tool"
    let parameters: GenerationSchema = String.generationSchema

    func call(arguments: GeneratedContent) async throws -> String {
        ""
    }
}

private func debugRuntimeTranscriptEntry(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions(let instructions):
        return "instructions:\(debugRuntimeTranscriptSegments(instructions.segments))"
    case .prompt(let prompt):
        return "prompt:\(debugRuntimeTranscriptSegments(prompt.segments))"
    case .response(let response):
        return "response:\(debugRuntimeTranscriptSegments(response.segments))"
    case .toolCalls(let calls):
        return "toolCalls:\(calls.map { "\($0.toolName):\($0.arguments.jsonString)" }.joined(separator: "\n"))"
    case .toolOutput(let output):
        return "toolOutput:\(output.toolName):\(debugRuntimeTranscriptSegments(output.segments))"
    }
}

private func debugRuntimeTranscriptSegments(_ segments: [Transcript.Segment]) -> String {
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

private struct TranscriptCapturingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let store: TranscriptCaptureStore

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("TranscriptCapturingLanguageModel: only String supported") }
        await store.record(session.transcript)
        return LanguageModelSession.Response(
            content: "Captured." as! Content,
            rawContent: GeneratedContent("Captured."),
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

private actor TranscriptCapturingModelProvider: ModelProvider {
    let id: String = "transcript-capturing"
    let supportedModels: [String]
    private let store = TranscriptCaptureStore()

    init(models: [String]) {
        self.supportedModels = models
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        TranscriptCapturingLanguageModel(store: store)
    }

    func transcriptsSnapshot() async -> [String] {
        await store.snapshot()
    }
}

// MARK: - CancellableStreamModelProvider

private actor CancellableStreamState {
    private var started = false

    func markStarted() {
        started = true
    }

    func hasStarted() -> Bool {
        started
    }
}

private actor CancellableStreamModelProvider: ModelProvider {
    let id: String = "cancellable-stream"
    nonisolated let supportedModels: [String] = ["mock-model"]
    private let state = CancellableStreamState()

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        CancellableStreamLanguageModel(state: state)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func hasStarted() async -> Bool {
        await state.hasStarted()
    }
}

private struct CancellableStreamLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let state: CancellableStreamState

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return LanguageModelSession.Response(
            content: "late response" as! Content,
            rawContent: GeneratedContent("late response"),
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
        guard type == String.self else { fatalError("only String supported") }
        let state = state
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task {
                await state.markStarted()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    let text = "late response"
                    continuation.yield(.init(content: text as! Content.PartiallyGenerated, rawContent: GeneratedContent(text)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

// MARK: - ContextOverflowModelProvider

private actor ContextOverflowModelProvider: ModelProvider {
    let id: String = "context-overflow"
    nonisolated let supportedModels: [String] = ["mock-model"]
    private var callCount = 0
    private let recoveryResponse: String

    init(recoveryResponse: String) {
        self.recoveryResponse = recoveryResponse
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callCount += 1
        if callCount == 1 {
            return ContextOverflowLanguageModel()
        }
        return FixedResponseLanguageModel(text: recoveryResponse)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func currentCallCount() -> Int { callCount }
}

private struct ContextOverflowLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
        return LanguageModelSession.Response(
            content: "" as! Content,
            rawContent: GeneratedContent(""),
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
            continuation.finish(throwing: LanguageModelSession.GenerationError.exceededContextWindowSize(
                LanguageModelSession.GenerationError.Context(debugDescription: "test context overflow")
            ))
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private struct FixedResponseLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let text: String

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
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
        let output = text
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                continuation.yield(.init(content: output as! Content.PartiallyGenerated, rawContent: GeneratedContent(output)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

// MARK: - ReasoningContentCapture tests

@Test
func reasoningContentCaptureAppendAndConsume() {
    let capture = ReasoningContentCapture()
    capture.append("Hello")
    capture.append(", world")
    let result = capture.consume()
    #expect(result == "Hello, world")
    let afterConsume = capture.consume()
    #expect(afterConsume.isEmpty)
}

@Test
func reasoningContentCaptureConsumeResetsAccumulator() {
    let capture = ReasoningContentCapture()
    capture.append("first")
    _ = capture.consume()
    capture.append("second")
    #expect(capture.consume() == "second")
}

// MARK: - Reasoning observation emission tests

private final class ReasoningCapturingModelProvider: ModelProvider, @unchecked Sendable {
    let id: String = "reasoning-capturing"
    let supportedModels: [String] = ["mock-reasoning-model"]
    let _capture = ReasoningContentCapture()
    let responseText: String

    init(responseText: String = "Response.", reasoning: String = "") {
        self.responseText = responseText
        if !reasoning.isEmpty {
            _capture.append(reasoning)
        }
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        ReasoningCapturingMockLanguageModel(responseText: responseText)
    }

    func reasoningCapture(for modelName: String) -> ReasoningContentCapture? {
        _capture
    }
}

private struct ReasoningCapturingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let responseText: String

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        LanguageModelSession.Response(
            content: responseText as! Content,
            rawContent: GeneratedContent(responseText),
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
        let text = responseText
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                continuation.yield(.init(content: text as! Content.PartiallyGenerated, rawContent: GeneratedContent(text)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor ThinkingCollector {
    var items: [String] = []
    func append(_ text: String) { items.append(text) }
    func all() -> [String] { items }
}

private actor UsageCollector {
    var items: [TokenUsage] = []
    func append(_ usage: TokenUsage) { items.append(usage) }
    func all() -> [TokenUsage] { items }
}

private actor ChannelSnapshotCollector {
    private var snapshots: [ChannelSnapshot] = []

    func append(_ snapshot: ChannelSnapshot?) {
        guard let snapshot else { return }
        snapshots.append(snapshot)
    }

    func all() -> [ChannelSnapshot] { snapshots }
}

@Test
func reasoningObservationIsEmittedAfterStream() async {
    let provider = ReasoningCapturingModelProvider(
        responseText: "Here is my answer.",
        reasoning: "I think step by step..."
    )
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-reasoning-model")
    let collector = ThinkingCollector()

    _ = await system.postMessage(
        channelId: "reasoning-channel",
        request: ChannelMessageRequest(userId: "u1", content: "solve this"),
        observationHandler: { observation in
            if case .thinking(let text) = observation {
                await collector.append(text)
            }
        }
    )

    let observed = await collector.all()
    #expect(observed.count == 1)
    #expect(observed.first == "I think step by step...")
}

@Test
func noReasoningObservationWhenCaptureIsEmpty() async {
    let provider = ReasoningCapturingModelProvider(responseText: "Answer.", reasoning: "")
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-reasoning-model")
    let collector = ThinkingCollector()

    _ = await system.postMessage(
        channelId: "no-reasoning-channel",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        observationHandler: { observation in
            if case .thinking(let text) = observation {
                await collector.append(text)
            }
        }
    )

    let observed = await collector.all()
    #expect(observed.isEmpty)
}

// MARK: - OpenAIOAuthModel SSE parsing tests

@Test
func openAIOAuthModelParsesOutputTextDelta() {
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5")
    let line = #"data: {"type":"response.output_text.delta","delta":"Hello"}"#
    let result = model.parseSSEOutputDelta(line)
    #expect(result == "Hello")
}

@Test
func openAIOAuthModelParsesReasoningDelta() {
    let capture = ReasoningContentCapture()
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5", reasoningCapture: capture)
    let line = #"data: {"type":"response.reasoning_summary_text.delta","delta":"Let me think"}"#
    let result = model.parseSSEReasoningDelta(line)
    #expect(result == "Let me think")
}

@Test
func openAIOAuthModelIgnoresUnknownSSEEvents() {
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5")
    let line = #"data: {"type":"response.created","response":{}}"#
    #expect(model.parseSSEOutputDelta(line) == nil)
    #expect(model.parseSSEReasoningDelta(line) == nil)
}

@Test
func openAIOAuthModelParsesResponseCompletedWithUsage() {
    let usageCapture = TokenUsageCapture()
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5", tokenUsageCapture: usageCapture)
    let line = #"data: {"type":"response.completed","response":{"id":"resp_123","usage":{"input_tokens":150,"output_tokens":42,"input_tokens_details":{"cached_tokens":96},"output_tokens_details":{"reasoning_tokens":12}}}}"#
    let result = model.parseSSEResponseCompleted(line)
    #expect(result != nil)
    #expect(result?.responseId == "resp_123")
    #expect(result?.inputTokens == 150)
    #expect(result?.outputTokens == 42)
    #expect(result?.cachedInputTokens == 96)
    #expect(result?.reasoningTokens == 12)
}

@Test
func tokenUsageCaptureStoresAndConsumes() {
    let capture = TokenUsageCapture()
    #expect(capture.consume() == nil)
    capture.store(promptTokens: 100, completionTokens: 50, cachedInputTokens: 80, reasoningTokens: 5)
    let result = capture.consume()
    #expect(result?.prompt == 100)
    #expect(result?.completion == 50)
    #expect(result?.cachedInputTokens == 80)
    #expect(result?.reasoningTokens == 5)
    #expect(capture.consume() == nil)
}

private extension Protocols.JSONValue {
    var objectValue: [String: Protocols.JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
