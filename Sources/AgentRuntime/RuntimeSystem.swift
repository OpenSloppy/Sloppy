import AnyLanguageModel
import Foundation
import Logging
import PluginSDK
import Protocols

public struct RecoveryChannelState: Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RecoveryTaskState: Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var status: String
    public var title: String
    public var objective: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        channelId: String,
        status: String,
        title: String,
        objective: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.channelId = channelId
        self.status = status
        self.title = title
        self.objective = objective
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RecoveryArtifactState: Sendable, Equatable {
    public var id: String
    public var content: String
    public var createdAt: Date

    public init(id: String, content: String, createdAt: Date) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

public enum RuntimeResponseObservation: Sendable {
    case thinking(String)
    case toolCall(ToolInvocationRequest)
    case toolResult(ToolInvocationResult)
    case usage(TokenUsage)
}

public struct NativeAgentLoopConfig: Sendable, Equatable {
    public var maxOutputTokens: Int
    public var maxToolRounds: Int
    public var enforceToolRoundLimit: Bool
    public var finalizerToolNames: Set<String>
    public var overBudgetRecoveryBatches: Int
    public var budgetExhaustedMessage: String

    public init(
        maxToolRounds: Int = 60,
        enforceToolRoundLimit: Bool = true,
        finalizerToolNames: Set<String> = [],
        overBudgetRecoveryBatches: Int = 0,
        budgetExhaustedMessage: String = "Agent reached the tool turn limit before producing a final answer.",
        maxOutputTokens: Int = 1024
    ) {
        self.maxToolRounds = max(0, maxToolRounds)
        self.maxOutputTokens = max(128, min(16_384, maxOutputTokens))
        self.enforceToolRoundLimit = enforceToolRoundLimit
        self.finalizerToolNames = finalizerToolNames
        self.overBudgetRecoveryBatches = max(0, overBudgetRecoveryBatches)
        self.budgetExhaustedMessage = budgetExhaustedMessage
    }
}

public enum NativeAgentLoopTurnExitReason: String, Sendable, Equatable {
    case completed
    case fallbackNoModel
    case streamIdleTimeoutFallback
    case streamRetryFailed
    case contextWindowRecovered
    case contextWindowRecoveryFailed
    case toolRoundLimit
    case toolLoopDetected
    case emptyResponse
    case emptyResponseRepaired
    case emptyAfterToolTimeout
    case modelProviderError
    case modelCancelled
    case consumerCancelled
}

public struct NativeAgentLoopOutcome: Sendable, Equatable {
    public var toolRoundsUsed: Int
    public var maxToolRounds: Int
    public var finishedNaturally: Bool
    public var hitTurnLimit: Bool
    public var toolErrors: [ToolInvocationResult]
    public var lastAssistantText: String
    public var turnExitReason: NativeAgentLoopTurnExitReason

    public init(
        toolRoundsUsed: Int = 0,
        maxToolRounds: Int = 60,
        finishedNaturally: Bool = false,
        hitTurnLimit: Bool = false,
        toolErrors: [ToolInvocationResult] = [],
        lastAssistantText: String = "",
        turnExitReason: NativeAgentLoopTurnExitReason = .completed
    ) {
        self.toolRoundsUsed = toolRoundsUsed
        self.maxToolRounds = maxToolRounds
        self.finishedNaturally = finishedNaturally
        self.hitTurnLimit = hitTurnLimit
        self.toolErrors = toolErrors
        self.lastAssistantText = lastAssistantText
        self.turnExitReason = turnExitReason
    }
}

public struct BranchExecutionResult: Sendable, Equatable {
    public var branchId: String
    public var workerId: String
    public var conclusion: BranchConclusion

    public init(branchId: String, workerId: String, conclusion: BranchConclusion) {
        self.branchId = branchId
        self.workerId = workerId
        self.conclusion = conclusion
    }
}

public actor RuntimeSystem {
    public nonisolated let eventBus: EventBus
    public nonisolated let performanceTelemetry: RuntimePerformanceTelemetry
    static let toolRoundLimitMessage = "Agent reached the tool turn limit before producing a final answer."
    static let defaultModelReconnectDelays: [Duration] = [
        .seconds(5),
        .seconds(7),
        .seconds(9),
        .seconds(10),
        .seconds(12),
    ]

    let memoryStore: any MemoryStore
    let channels: ChannelRuntime
    let workers: WorkerRuntime
    let branches: BranchRuntime
    let compactor: Compactor
    let visor: Visor
    let logger: Logger
    let preResponseMemoryLimit: Int
    let modelReconnectDelays: [Duration]
    let modelReconnectSleeper: @Sendable (Duration) async -> Void
    var modelProvider: (any ModelProvider)?
    var defaultModel: String?

    struct CachedLanguageModelSession {
        var model: String
        var session: LanguageModelSession
    }

    struct ActiveResponseTask {
        var id: UUID
        var task: Task<Void, Never>
    }

    /// Persistent LLM sessions keyed by channel ID. Each session accumulates full
    /// transcript (prompts, tool calls, tool outputs, responses) so the model sees
    /// complete history without rebuilding context on every turn.
    var sessionsByChannel: [String: CachedLanguageModelSession] = [:]

    /// Active inline model responses keyed by channel ID. Interrupts cancel these
    /// tasks directly instead of waiting for the next cooperative stream chunk.
    var activeResponseTasks: [String: ActiveResponseTask] = [:]

    /// Bootstrap system prompt content per channel, kept to recreate sessions after
    /// context overflow or model hot-swap.
    var bootstrapByChannel: [String: String] = [:]
    var imagesByChannel: [String: [Transcript.ImageSegment]] = [:]

    /// Explicit project association supplied by the session owner, never inferred from prompt text.
    var memoryProjectByChannel: [String: String] = [:]

    /// Latest context accounting snapshot per channel. This is diagnostic and
    /// compaction input; it does not store full prompt text.
    var usageRequestHandler: (@Sendable (UsageRequestRecord) async -> Void)?
    var usageProvenanceProvider: (@Sendable (String) async -> UsageProvenance)?
    var usageToolOutcomeHandler: (@Sendable (String, String, Bool) async -> Void)?
    var observedUsageChannels: Set<String> = []
    var pendingRequestUsage: [String: TokenUsage] = [:]
    var contextLedgerByChannel: [String: ContextLedgerSnapshot] = [:]

    /// Durable transcript seed per channel, rebuilt from persisted session events
    /// by the owner layer when the cached in-memory LLM session is gone.
    var recoveryTranscriptByChannel: [String: Transcript] = [:]
    let contextConfiguration: CompactorConfiguration
    var contextArchiversByChannel: [String: TranscriptContextManager.Archive] = [:]
    var contextPreparationByChannel: [String: TranscriptContextReport] = [:]

    /// When set, only these tool names (matching `Tool.name`) are passed to `LanguageModelSession` for the channel.
    var channelToolAllowList: [String: Set<String>] = [:]

    public init(
        modelProvider: (any ModelProvider)? = nil,
        defaultModel: String? = nil,
        workerExecutor: (any WorkerExecutor)? = nil,
        memoryStore: (any MemoryStore)? = nil,
        visorCompletionProvider: (@Sendable (String, Int) async -> String?)? = nil,
        visorStreamingProvider: (@Sendable (String, Int) -> AsyncStream<String>)? = nil,
        visorBulletinMaxWords: Int = 300,
        compactorConfiguration: CompactorConfiguration = .default,
        compactorRetryPolicy: CompactorRetryPolicy = .default,
        preResponseMemoryLimit: Int = 8,
        modelReconnectDelays: [Duration]? = nil,
        modelReconnectSleeper: (@Sendable (Duration) async -> Void)? = nil
    ) {
        let bus = EventBus()
        let memory = memoryStore ?? InMemoryMemoryStore()
        eventBus = bus
        performanceTelemetry = RuntimePerformanceTelemetry()
        self.memoryStore = memory
        self.contextConfiguration = compactorConfiguration
        self.preResponseMemoryLimit = max(0, preResponseMemoryLimit)
        self.modelReconnectDelays = modelReconnectDelays ?? Self.defaultModelReconnectDelays
        self.modelReconnectSleeper = modelReconnectSleeper ?? { delay in
            try? await Task.sleep(for: delay)
        }
        channels = ChannelRuntime(
            eventBus: bus,
            contextWindowTokens: compactorConfiguration.contextWindowTokens
        )
        workers = WorkerRuntime(
            eventBus: bus,
            executor: workerExecutor ?? DefaultWorkerExecutor()
        )
        branches = BranchRuntime(eventBus: bus, memoryStore: memory)
        compactor = Compactor(
            eventBus: bus,
            configuration: compactorConfiguration,
            retryPolicy: compactorRetryPolicy
        )
        visor = Visor(
            eventBus: bus,
            memoryStore: memory,
            completionProvider: visorCompletionProvider,
            streamingProvider: visorStreamingProvider,
            bulletinMaxWords: visorBulletinMaxWords
        )
        logger = .runtime(label: "sloppy.runtime.model")
        self.modelProvider = modelProvider
        self.defaultModel = defaultModel ?? modelProvider?.supportedModels.first
    }

    public func performanceSnapshot(limit: Int = 60) async -> RuntimePerformanceSnapshot {
        await performanceTelemetry.snapshot(limit: limit)
    }

    /// Hot-swaps worker executor backend for subsequent worker operations.
    public func updateWorkerExecutor(_ executor: any WorkerExecutor) async {
        await workers.updateExecutor(executor)
    }

    /// Hot-swaps model provider and default model for subsequent direct responses.
    /// Invalidates all cached LLM sessions so next request creates fresh ones with
    /// the new provider.
    public func updateModelProvider(modelProvider: (any ModelProvider)?, defaultModel: String?) {
        self.modelProvider = modelProvider
        sessionsByChannel.removeAll()
        channelToolAllowList.removeAll()
        contextLedgerByChannel.removeAll()

        guard let modelProvider else {
            self.defaultModel = nil
            return
        }

        let normalizedDefault = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDefault, !normalizedDefault.isEmpty, modelProvider.supports(modelName: normalizedDefault) {
            self.defaultModel = normalizedDefault
            return
        }

        self.defaultModel = modelProvider.supportedModels.first
    }

    /// Restricts tools exposed to the model for this channel. Pass `nil` or an empty set to clear filtering.
    public func setChannelToolAllowList(channelId: String, toolIDs: Set<String>?) {
        guard let toolIDs, !toolIDs.isEmpty else {
            channelToolAllowList.removeValue(forKey: channelId)
            return
        }
        channelToolAllowList[channelId] = toolIDs
    }

    public func clearChannelToolAllowList(channelId: String) {
        channelToolAllowList.removeValue(forKey: channelId)
    }

    /// Removes a cached `LanguageModelSession` so the next turn builds a fresh session (e.g. after tool allowlist changes).
    public func invalidateChannelSession(channelId: String) {
        sessionsByChannel.removeValue(forKey: channelId)
    }

    /// Seeds the next fresh LLM session for a channel with durable transcript state.
    /// The seed is ignored while a cached session is still live.
    public func setChannelRecoveryTranscript(channelId: String, transcript: Transcript?) {
        guard let transcript, !transcript.isEmpty else {
            recoveryTranscriptByChannel.removeValue(forKey: channelId)
            return
        }
        recoveryTranscriptByChannel[channelId] = transcript
    }

    /// Returns whether the channel currently has an in-memory LLM session.
    public func hasCachedChannelSession(channelId: String) -> Bool {
        sessionsByChannel[channelId] != nil
    }

    /// Runs a one-shot text generation outside channel transcript state. Tools are never attached.
}
