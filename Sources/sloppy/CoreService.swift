import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AppKit)
import AppKit
#endif
import AgentRuntime
import ChannelPluginDiscord
import ChannelPluginTelegram
import Logging
import Protocols
import PluginSDK
import CodexBarCore
import SloppyNodeCore
import SloppyRuntime
import SloppyMigration
import SloppyConsoleProtocol
import SloppyRemoteProtocol

public enum AgentSessionStreamUpdateKind: String, Codable, Sendable {
    case sessionReady = "session_ready"
    case sessionEvent = "session_event"
    case sessionDelta = "session_delta"
    case heartbeat
    case sessionClosed = "session_closed"
    case sessionError = "session_error"
}

public struct AgentSessionStreamUpdate: Codable, Sendable {
    public var kind: AgentSessionStreamUpdateKind
    public var cursor: Int
    public var summary: AgentSessionSummary?
    public var event: AgentSessionEvent?
    public var message: String?
    public var createdAt: Date

    public init(
        kind: AgentSessionStreamUpdateKind,
        cursor: Int,
        summary: AgentSessionSummary? = nil,
        event: AgentSessionEvent? = nil,
        message: String? = nil,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.cursor = cursor
        self.summary = summary
        self.event = event
        self.message = message
        self.createdAt = createdAt
    }
}

struct BuiltInGatewayPluginFactory: Sendable {
    let makeTelegram: @Sendable (CoreConfig.ChannelConfig.Telegram, (any TelegramModelPickerBridge)?, (any ToolApprovalBridge)?) -> any GatewayPlugin
    let makeDiscord: @Sendable (CoreConfig.ChannelConfig.Discord) -> any GatewayPlugin

    static let live = BuiltInGatewayPluginFactory(
        makeTelegram: { config, modelPickerBridge, toolApprovalBridge in
            TelegramGatewayPlugin(
                botToken: config.botToken,
                channelChatMap: config.channelChatMap,
                topicChannelMap: config.topicChannelMap,
                allowedUserIds: config.allowedUserIds,
                allowedChatIds: config.allowedChatIds,
                logger: .sloppy(label: "sloppy.plugin.telegram"),
                modelPickerBridge: modelPickerBridge,
                toolApprovalBridge: toolApprovalBridge
            )
        },
        makeDiscord: { config in
            DiscordGatewayPlugin(
                botToken: config.botToken,
                channelDiscordChannelMap: config.channelDiscordChannelMap,
                allowedGuildIds: config.allowedGuildIds,
                allowedChannelIds: config.allowedChannelIds,
                allowedUserIds: config.allowedUserIds,
                logger: .sloppy(label: "sloppy.plugin.discord")
            )
        }
    )
}

public actor CoreService {
    static let heartbeatSuccessToken = "SLOPPY_ACTION_OK"
    static let agentMemoryGraphSeedLimit = 50
    static let agentMemoryGraphNeighborLimit = 150

    struct InboundChannelPluginQueueSlot: Sendable {
        var fifo: [(userId: String, content: String, topicId: String?, mode: AgentChatMode?, attachments: [ChannelAttachment])] = []
        var processing: Bool = false
    }

    public enum AgentStorageError: Error {
        case invalidID
        case invalidPayload
        case alreadyExists
        case notFound
    }

    public enum AgentSessionError: Error {
        case invalidAgentID
        case invalidSessionID
        case invalidPayload
        case agentNotFound
        case sessionNotFound
        case storageFailure
    }

    public enum AgentConfigError: Error {
        case invalidAgentID
        case invalidPayload
        case invalidModel
        case agentNotFound
        case storageFailure
        case documentLengthExceeded(resource: String, limit: Int)
    }

    public enum AgentToolsError: Error {
        case invalidAgentID
        case invalidPayload
        case agentNotFound
        case storageFailure
    }

    public enum ToolInvocationError: Error {
        case invalidAgentID
        case invalidSessionID
        case invalidPayload
        case agentNotFound
        case sessionNotFound
        case forbidden(ToolErrorPayload)
        case storageFailure
    }

    public enum SystemLogsError: Error {
        case storageFailure
    }

    public enum ActorBoardError: Error {
        case invalidPayload
        case actorNotFound
        case linkNotFound
        case teamNotFound
        case protectedActor
        case storageFailure
    }

    public enum ProjectError: Error {
        case invalidProjectID
        case invalidChannelID
        case invalidTaskID
        case invalidPayload
        case notFound
        case conflict
    }

    public enum WorkspaceError: Error {
        case invalidID
        case invalidPayload
        case notFound
        case forbidden
        case conflict(latestRevision: Int, elementIds: [String])
    }

    public enum ChannelPluginError: Error {
        case invalidID
        case invalidPayload
        case notFound
        case conflict
    }

    public enum AgentSkillsError: Error {
        case invalidAgentID
        case invalidPayload
        case agentNotFound
        case skillNotFound
        case skillAlreadyExists
        case storageFailure
        case networkFailure
        case downloadFailure
        case localPathFailure
    }

    public enum GenerateError: Error {
        case noModelProvider
        case noModelAvailable
        case generationFailed
    }

    public enum AgentCronTaskError: Error {
        case invalidAgentID
        case invalidPayload
        case notFound
        case storageFailure
    }

    /// Retained for checkpoint / one-off model sessions (also held inside `runtime`).
    var modelProvider: (any ModelProvider)?
    let runtime: RuntimeSystem
    let semanticDecisionUsageMeter: SemanticDecisionUsageMeter
    let semanticModelRouter: SemanticModelRouter
    let memoryStore: any MemoryStore
    lazy var memoryImports = MemoryImportService(root: workspaceRootURL.appendingPathComponent("memory-imports", isDirectory: true), memoryStore: memoryStore)
    lazy var launches = LaunchRunService(store: store, processes: toolExecution.processRegistry)
    lazy var migrations = MigrationJobService(root: workspaceRootURL.appendingPathComponent("migrations", isDirectory: true))
    let hybridMemoryStore: HybridMemoryStore?
    let persistenceBuilder: any CorePersistenceBuilding
    var store: any PersistenceStore
    let openAIProviderCatalog: OpenAIProviderCatalogService
    let openAIOAuthService: OpenAIOAuthService
    let anthropicOAuthService: AnthropicOAuthService
    let geminiOAuthService: GeminiOAuthService
    let githubAuthService: GitHubAuthService
    let providerProbeService: ProviderProbeService
    let searchProviderService: SearchProviderService
    let agentCatalogStore: AgentCatalogFileStore
    let sessionStore: AgentSessionFileStore
    let actorBoardStore: ActorBoardFileStore
    let workflowDefinitionStore: WorkflowDefinitionFileStore
    let automationDefinitionStore: AutomationDefinitionFileStore
    let sessionOrchestrator: AgentSessionOrchestrator
    let sessionGoalController: AgentSessionGoalController
    let acpSessionManager: ACPSessionManager
    let toolsAuthorization: ToolAuthorizationService
    let toolLoopGuard: ToolLoopGuard
    let toolPreHookService: ToolPreHookService
    let safariBridgeService: SafariBridgeService
    var toolExecution: ToolExecutionService
    let mcpRegistry: MCPClientRegistry
    let systemLogStore: SystemLogFileStore
    let issueReportLogUploader: (any IssueReportLogUploading)?
    var channelDelivery: ChannelDeliveryService
    let channelSessionStore: ChannelSessionFileStore
    let agentSkillsStore: AgentSkillsFileStore
    let skillsRegistryService: SkillsRegistryService
    let skillsGitHubClient: SkillsGitHubClient
    let agentPluginManager: AgentPluginManager
    let updateChecker: UpdateCheckerService
    let swarmPlanner: SwarmPlanner
    let gitWorktreeService: GitWorktreeService
    var sourceControlProviders: [String: any SourceControlProvider]
    var taskSyncProviders: [String: any TaskSyncProvider]
    var taskSyncProviderDescriptors: [String: TaskSyncProviderDescriptor]
    var taskCommentMirrorQueues: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    var codeReviewProviders: [String: any CodeReviewProvider]
    let workspaceGitSyncService: WorkspaceGitSyncService
    let logger: Logger
    let configPath: String
    let builtInGatewayPluginFactory: BuiltInGatewayPluginFactory
    let channelModelStore: ChannelModelStore
    let channelChatModeStore: ChannelChatModeStore
    var workspaceRootURL: URL
    var agentsRootURL: URL
    let workspaceCurrentDirectory: String
    var currentConfig: CoreConfig
    var eventTask: Task<Void, Never>?
    var readyTaskStartupDispatchCompleted = false
    var readyTaskStartupDispatchInProgress = false
    var activeGatewayPlugins: [any GatewayPlugin] = []
    var visorScheduler: VisorScheduler?
    var kanbanScheduler: KanbanMaintenanceScheduler?
    var autodreamRunner: AutodreamRunner?
    var cronRunner: CronRunner?
    var heartbeatRunner: HeartbeatRunner?
    lazy var proactiveHeartbeatService = makeProactiveHeartbeatService()
    var proactiveTaskEventTask: Task<Void, Never>?
    var taskSyncRunner: TaskSyncRunner?
    var selfImprovementCuratorRunner: SelfImprovementCuratorRunner?
    var memoryOutboxIndexer: MemoryOutboxIndexer?
    var recoveryManager: RecoveryManager
    var oauthModelCache: [String: ProviderModelOption] = [:]
    var liveSessionStreamContinuations: [String: [UUID: AsyncStream<AgentSessionStreamUpdate>.Continuation]] = [:]
    var liveSessionStreamCursor: [String: Int] = [:]
    var longChatStorage: LongChatFileStore?
    var longChatRecoveryCompleted = false
    var longChatTurnRunners: Set<String> = []
    var longChatTurnTasks: [String: Task<Void, Never>] = [:]
    var longChatIsStopping = false
    var longChatCurrentTurns: [String: String] = [:]
    var longChatWorkerRuns: [String: Task<Void, Never>] = [:]
    var sessionExtraRoots: [String: [String]] = [:]
    var sessionWorkingDirectories: [String: String] = [:]
    var sessionAddedRoots: [String: [String]] = [:]
    var projectExecutionSessions: [String: (projectID: String, taskID: String, agentID: String, generation: Int)] = [:]
    var projectPlanningCancellations: [String: [UUID: @Sendable () -> Void]] = [:]
    var projectStopGenerations: [String: Int] = [:]
    var sessionEnvironmentOverrides: [String: [String: String]] = [:]
    var channelExtraRoots: [String: [String]] = [:]
    var channelWorkingDirectories: [String: String] = [:]
    var channelAddedRoots: [String: [String]] = [:]
    /// When set, only these tool IDs may execute for the session (subagent isolation overlay).
    var sessionSubagentToolAllowList: [String: Set<String>] = [:]
    /// Sessions temporarily exempted from interactive TUI tool usage ceilings.
    var sessionToolUsageLimitBypass: Set<String> = []
    /// Autonomous worker sessions allowed to use already-scoped project permissions without interactive tool approval.
    var sessionToolApprovalBypass: Set<String> = []
    /// Interactive ACP sessions that require approval for Sloppy's risky tool set.
    var sessionToolApprovalRequired: Set<String> = []
    /// Tool approvals granted for the lifetime of an agent session/channel, keyed by agent and session scope.
    var toolApprovalSessionAllowances: [String: Set<ToolApprovalGrant>] = [:]
    /// Optional interactive surface for approvals created by an embedded protocol client such as ACP.
    var toolApprovalPresenter: (@Sendable (ToolApprovalRecord) async -> ToolApprovalPresentationDecision?)?
    /// Test seam for deterministic agent approval decisions; production uses the configured reviewer's model.
    var toolApprovalAgentReviewOverride: (@Sendable (ToolApprovalRecord, String) async -> ToolApprovalAgentReviewDecision?)?
    /// Prevents overlapping memory checkpoints per agent/session pair.
    var memoryCheckpointLocks: Set<String> = []
    /// Background sessions started by TUI `/bg`; owned by CoreService so screen teardown does not cancel them.
    var tuiBackgroundSessionTasks: [String: Task<Void, Never>] = [:]
    /// Prevents overlapping proposal reviews per agent/session pair.
    var selfImprovementProposalReviewLocks: Set<String> = []
    /// Prevents overlapping proposal review queue runners.
    var selfImprovementProposalReviewQueueRunning = false
    /// Tracks tool-result thresholds already reviewed for a session.
    var selfImprovementProposalReviewToolBuckets: [String: Int] = [:]
    var meshLaunchPreviewOwners: [String: String] = [:]
    var meshLaunchPreviewInputs: [String: AsyncStream<String>.Continuation] = [:]
    var consoleStreams: [UUID: ConsoleStreamRegistration] = [:]
    var consoleRelayTask: Task<Void, Never>?
    var consoleRemoteConnection: ConsoleRemoteConnection?
    var consoleDashboardController: ConsoleDashboardController?
    var nodeMeshClientTask: Task<Void, Never>?
    var nodeMeshClient: NodeMeshClient?
    var meshTerminalSessionIDs: [String: String] = [:]
    var meshTerminalForwardTasks: [String: Task<Void, Never>] = [:]
    public let notificationService: NotificationService
    public let kanbanEventService: KanbanEventService
    let workspaceRealtimeService: WorkspaceRealtimeService
    public let pendingApprovalService: PendingApprovalService
    let toolApprovalService: ToolApprovalService
    let dashboardTerminalService: DashboardTerminalService
    let consoleTrustUnavailable: Bool
    let consoleTrustStore: ConsoleInstanceTrustStore?
    let identityAuthService: CoreIdentityAuthService
    let siteBrowserSessionService: SiteBrowserSessionService
    let enterpriseModules: [any EnterpriseModule]
    let channelStreamCancelRegistry: ChannelStreamCancelRegistry
    nonisolated let nodeMeshStore: NodeMeshStore
    nonisolated let nodeConfigStore: NodeConfigStore
    var inboundChannelPluginQueues: [String: InboundChannelPluginQueueSlot] = [:]

    /// Creates core orchestration service with runtime and persistence backend.
    public init(
        config: CoreConfig,
        configPath: String = CoreConfig.defaultConfigPath,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        persistenceBuilder: any CorePersistenceBuilding = DefaultCorePersistenceBuilder(),
        searchProviderService: SearchProviderService? = nil,
        nodeConfigStore: NodeConfigStore = NodeConfigStore(),
        sharedSkillsRootURLs: [URL]? = nil,
        enterpriseModules: [any EnterpriseModule] = [],
        identityPasswordHashIterations: Int = 120_000
    ) {
        self.init(
            config: config,
            configPath: configPath,
            currentDirectory: currentDirectory,
            persistenceBuilder: persistenceBuilder,
            searchProviderService: searchProviderService,
            nodeConfigStore: nodeConfigStore,
            sharedSkillsRootURLs: sharedSkillsRootURLs,
            enterpriseModules: enterpriseModules,
            builtInGatewayPluginFactory: .live,
            issueReportLogUploader: PasteRSIssueReportLogUploader(),
            identityPasswordHashIterations: identityPasswordHashIterations
        )
    }

    init(
        config: CoreConfig,
        configPath: String = CoreConfig.defaultConfigPath,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        persistenceBuilder: any CorePersistenceBuilding = DefaultCorePersistenceBuilder(),
        searchProviderService: SearchProviderService? = nil,
        providerProbeService: ProviderProbeService? = nil,
        nodeConfigStore: NodeConfigStore = NodeConfigStore(),
        sharedSkillsRootURLs: [URL]? = nil,
        enterpriseModules: [any EnterpriseModule] = [],
        builtInGatewayPluginFactory: BuiltInGatewayPluginFactory,
        updateChecker: UpdateCheckerService? = nil,
        issueReportLogUploader: (any IssueReportLogUploading)? = PasteRSIssueReportLogUploader(),
        identityPasswordHashIterations: Int = 120_000
    ) {
        self.enterpriseModules = enterpriseModules
        self.workspaceCurrentDirectory = currentDirectory
        let workspaceRootURL = config.resolvedWorkspaceRootURL(currentDirectory: currentDirectory)
        self.openAIOAuthService = OpenAIOAuthService(workspaceRootURL: workspaceRootURL)
        self.anthropicOAuthService = AnthropicOAuthService(workspaceRootURL: workspaceRootURL)
        self.geminiOAuthService = GeminiOAuthService(workspaceRootURL: workspaceRootURL)
        self.githubAuthService = GitHubAuthService(workspaceRootURL: workspaceRootURL)
        let anthropicSettingsProvider: @Sendable () -> ClaudeSettingsEnvironment = {
            ClaudeSettingsEnvironment.load(workspaceRootURL: workspaceRootURL)
        }
        self.mcpRegistry = MCPClientRegistry(
            config: config.mcp,
            logger: Logger.sloppy(label: "sloppy.mcp")
        )
        let oauthService = self.openAIOAuthService
        let anthropicOAuthService = self.anthropicOAuthService
        let geminiOAuthService = self.geminiOAuthService
        let hasOAuth = oauthService.currentAccessToken() != nil
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(
            config: config,
            hasOAuthCredentials: hasOAuth,
            currentDirectory: currentDirectory
        )
        let modelProvider = CoreModelProviderFactory.buildModelProvider(
            config: config,
            resolvedModels: resolvedModels,
            tools: ToolRegistry.makeDefault().allTools,
            oauthTokenProvider: { oauthService.currentAccessToken() },
            oauthAccountId: oauthService.currentAccountId(),
            oauthTokenRefresh: { try await oauthService.ensureValidToken() },
            oauthTokenForceRefresh: { try await oauthService.ensureValidToken(forceRefresh: true) },
            anthropicOAuthTokenProvider: { anthropicOAuthService.currentAccessToken() },
            anthropicOAuthTokenRefresh: { try await anthropicOAuthService.ensureValidToken() },
            anthropicSettingsProvider: anthropicSettingsProvider,
            geminiOAuthCredentialsProvider: { geminiOAuthService.currentCredentials() },
            systemInstructions: "You are Sloppy core channel assistant.",
            proxySession: ProxySessionFactory.makeSession(proxy: config.proxy),
            currentDirectory: currentDirectory
        )
        let runtimeMemoryStore: any MemoryStore
        let hybridMemoryStore: HybridMemoryStore?
        if persistenceBuilder is InMemoryCorePersistenceBuilder {
            hybridMemoryStore = nil
            runtimeMemoryStore = InMemoryMemoryStore()
        } else {
            let embeddingService = EmbeddingService.make(
                config: config,
                logger: Logger.sloppy(label: "sloppy.memory.embedding")
            )
            let store = HybridMemoryStore(
                config: config,
                mcpRegistry: self.mcpRegistry,
                embeddingService: embeddingService
            )
            hybridMemoryStore = store
            runtimeMemoryStore = store
        }
        let visorCompletionProvider = Self.buildVisorCompletionProvider(
            modelProvider: modelProvider,
            visorModel: config.visor.model,
            resolvedModels: resolvedModels
        )
        let visorStreamingProvider = Self.buildVisorStreamingProvider(
            modelProvider: modelProvider,
            visorModel: config.visor.model,
            resolvedModels: resolvedModels
        )
        self.modelProvider = modelProvider
        let runtime = SloppyRuntimeBootstrap.makeSystem(
            modelProvider: modelProvider,
            memoryStore: runtimeMemoryStore,
            configuration: SloppyRuntimeConfiguration(
                defaultModel: modelProvider?.supportedModels.first ?? resolvedModels.first,
                visorBulletinMaxWords: config.visor.bulletinMaxWords,
                compactorConfiguration: config.compactor.runtimeConfiguration,
                compactorRetryPolicy: config.compactor.runtimeRetryPolicy,
                preResponseMemoryLimit: config.memory.retrieval.topK
            ),
            visorCompletionProvider: visorCompletionProvider,
            visorStreamingProvider: visorStreamingProvider
        )
        self.runtime = runtime
        self.memoryStore = runtimeMemoryStore
        self.hybridMemoryStore = hybridMemoryStore
        self.persistenceBuilder = persistenceBuilder
        self.store = persistenceBuilder.makeStore(config: config)
        self.workspaceRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: currentDirectory)
        self.agentPluginManager = AgentPluginManager(
            workspaceRootURL: self.workspaceRootURL,
            store: self.store
        )
        self.nodeMeshStore = NodeMeshStore(
            stateURL: config.resolvedNodeMeshStateURL(currentDirectory: currentDirectory)
        )
        self.nodeConfigStore = nodeConfigStore
        self.openAIProviderCatalog = OpenAIProviderCatalogService()
        let providerWorkspaceRootURL = self.workspaceRootURL
        self.providerProbeService = providerProbeService ?? ProviderProbeService(
            claudeSettingsProvider: anthropicSettingsProvider,
            geminiOAuthCredentialsProvider: {
                GeminiOAuthCredentials.load(workspaceRootURL: providerWorkspaceRootURL)
            }
        )
        self.searchProviderService = searchProviderService ?? SearchProviderService(config: config.searchTools)
        self.configPath = configPath
        self.agentsRootURL = self.workspaceRootURL
            .appendingPathComponent("agents", isDirectory: true)
        let makeAgentSkillsStore: (URL) -> AgentSkillsFileStore = { agentsRootURL in
            if let sharedSkillsRootURLs {
                return AgentSkillsFileStore(
                    agentsRootURL: agentsRootURL,
                    sharedSkillsRootURLs: sharedSkillsRootURLs
                )
            }
            return AgentSkillsFileStore(agentsRootURL: agentsRootURL)
        }
        self.agentCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        self.sessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        self.systemLogStore = SystemLogFileStore(workspaceRootURL: self.workspaceRootURL)
        self.issueReportLogUploader = issueReportLogUploader
        self.channelDelivery = ChannelDeliveryService(store: self.store)
        self.actorBoardStore = ActorBoardFileStore(workspaceRootURL: self.workspaceRootURL)
        self.workflowDefinitionStore = WorkflowDefinitionFileStore(workspaceRootURL: self.workspaceRootURL)
        self.automationDefinitionStore = AutomationDefinitionFileStore(workspaceRootURL: self.workspaceRootURL)
        self.channelSessionStore = ChannelSessionFileStore(workspaceRootURL: self.workspaceRootURL)
        self.channelModelStore = ChannelModelStore(workspaceRootURL: self.workspaceRootURL)
        self.channelChatModeStore = ChannelChatModeStore(workspaceRootURL: self.workspaceRootURL)
        self.agentSkillsStore = makeAgentSkillsStore(self.agentsRootURL)
        self.skillsRegistryService = SkillsRegistryService()
        let githubAuth = self.githubAuthService
        self.skillsGitHubClient = SkillsGitHubClient(tokenProvider: { githubAuth.currentToken() })
        self.updateChecker = updateChecker ?? UpdateCheckerService()
        self.swarmPlanner = SwarmPlanner { prompt, maxTokens in
            await runtime.complete(prompt: prompt, maxTokens: maxTokens)
        }
        self.gitWorktreeService = GitWorktreeService()
        let gitSourceControlProvider = GitCLISourceControlProvider(service: self.gitWorktreeService)
        self.sourceControlProviders = [gitSourceControlProvider.id: gitSourceControlProvider]
        let githubTaskSyncProvider = GitHubProjectTaskSyncProvider()
        self.taskSyncProviders = [githubTaskSyncProvider.id: githubTaskSyncProvider]
        self.taskSyncProviderDescriptors = [
            githubTaskSyncProvider.id: TaskSyncProviderDescriptor(
                id: githubTaskSyncProvider.id,
                displayName: "GitHub Projects",
                capabilities: ["pull_tasks", "push_task_fields", "push_comments", "webhook"]
            )
        ]
        let githubCodeReviewProvider = GitHubCodeReviewProvider(
            tokenProvider: { githubAuth.currentToken() }
        )
        self.codeReviewProviders = [githubCodeReviewProvider.id: githubCodeReviewProvider]
        self.workspaceGitSyncService = WorkspaceGitSyncService()
        self.sessionGoalController = AgentSessionGoalController()
        let orchestratorCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorSessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorSkillsStore = makeAgentSkillsStore(self.agentsRootURL)
        let initialAvailableAgentModels = Self.availableAgentModels(
            config: config,
            hasOAuthCredentials: hasOAuth,
            currentDirectory: currentDirectory
        )
        self.acpSessionManager = ACPSessionManager(
            config: config.acp,
            workspaceRootURL: self.workspaceRootURL,
            agentsRootURL: self.agentsRootURL
        )
        self.semanticDecisionUsageMeter = SemanticDecisionUsageMeter(store: self.store)
        self.semanticModelRouter = SemanticModelRouter(
            config: config.semanticDecisions,
            usageMeter: self.semanticDecisionUsageMeter
        )
        self.sessionOrchestrator = AgentSessionOrchestrator(
            runtime: self.runtime,
            sessionStore: orchestratorSessionStore,
            agentCatalogStore: orchestratorCatalogStore,
            agentSkillsStore: orchestratorSkillsStore,
            acpSessionManager: self.acpSessionManager,
            semanticModelRouter: self.semanticModelRouter,
            availableModels: initialAvailableAgentModels,
            persistedModelContext: (config, hasOAuth),
            logger: .sloppy(label: "sloppy.core.sessions")
        )
        let toolsStore = AgentToolsFileStore(agentsRootURL: self.agentsRootURL)
        self.toolsAuthorization = ToolAuthorizationService(store: toolsStore, mcpRegistry: self.mcpRegistry)
        self.toolLoopGuard = ToolLoopGuard()
        self.toolPreHookService = ToolPreHookService()
        self.safariBridgeService = SafariBridgeService()
        let processRegistry = SessionProcessRegistry()
        self.toolExecution = ToolExecutionService(
            workspaceRootURL: self.workspaceRootURL,
            runtime: self.runtime,
            memoryStore: self.memoryStore,
            sessionStore: self.sessionStore,
            agentCatalogStore: self.agentCatalogStore,
            agentSkillsStore: self.agentSkillsStore,
            processRegistry: processRegistry,
            browserConfig: config.browser,
            safariBridgeService: self.safariBridgeService,
            channelSessionStore: self.channelSessionStore,
            store: self.store,
            searchProviderService: self.searchProviderService,
            mcpRegistry: self.mcpRegistry,
            lspConfig: config.lsp
        )
        self.logger = .sloppy(label: "sloppy.core.visor")
        self.builtInGatewayPluginFactory = builtInGatewayPluginFactory
        if let hybridMemoryStore {
            self.memoryOutboxIndexer = MemoryOutboxIndexer(
                store: hybridMemoryStore,
                logger: .sloppy(label: "sloppy.memory.outbox")
            )
        } else {
            self.memoryOutboxIndexer = nil
        }
        self.recoveryManager = RecoveryManager(store: self.store, runtime: self.runtime, logger: self.logger)
        self.notificationService = NotificationService()
        self.kanbanEventService = KanbanEventService()
        self.workspaceRealtimeService = WorkspaceRealtimeService(store: self.store)
        self.toolApprovalService = ToolApprovalService(eventBus: self.runtime.eventBus, notificationService: self.notificationService)
        self.pendingApprovalService = PendingApprovalService(
            workspaceDirectory: config
                .resolvedWorkspaceRootURL(currentDirectory: currentDirectory).path
        )
        self.dashboardTerminalService = DashboardTerminalService()
        self.consoleTrustStore = try? ConsoleInstanceTrustStore(url: self.workspaceRootURL
            .appendingPathComponent(".sloppy", isDirectory: true)
            .appendingPathComponent("console-trust.json"))
        self.identityAuthService = CoreIdentityAuthService(
            passwordHashIterations: identityPasswordHashIterations,
            stateURL: self.workspaceRootURL
                .appendingPathComponent(".sloppy", isDirectory: true)
                .appendingPathComponent("auth-state.json")
        )
        let consoleTrustFileExists = FileManager.default.fileExists(atPath: self.workspaceRootURL.appendingPathComponent(".sloppy/console-trust.json").path)
        self.consoleTrustUnavailable = self.consoleTrustStore == nil && consoleTrustFileExists
        self.siteBrowserSessionService = SiteBrowserSessionService()
        self.channelStreamCancelRegistry = ChannelStreamCancelRegistry()
        self.currentConfig = config
        let toolExecution = self.toolExecution
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
        toolExecution.sessionEnvironmentOverrides = { [weak self] sessionID in
            guard let self else { return [:] }
            return await self.environmentOverridesForSession(sessionID)
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.sessionOrchestrator.updatePlanArtifactRecorder { [weak self] agentID, sessionID, sessionTitle, projectID, messageEventID, markdown, createdAt in
                guard let self else {
                    throw ProjectError.notFound
                }
                return try await self.recordPlanArtifact(
                    agentID: agentID,
                    sessionID: sessionID,
                    sessionTitle: sessionTitle,
                    projectID: projectID,
                    messageEventID: messageEventID,
                    markdown: markdown,
                    createdAt: createdAt
                )
            }
            await self.sessionOrchestrator.setProjectBootstrapProvider { [weak self] projectID, taskID, agentID in
                guard let self else { return nil }
                return await self.projectBootstrapMarkdownForAgentSession(projectID: projectID, taskID: taskID, agentID: agentID)
            }
            await self.provisionBuiltInSkillsForAllAgents()
            await self.acpSessionManager.updatePermissionNotificationSink { [weak self] agentID, sessionID, summary in
                guard let self else { return }
                await self.notificationService.pushToolApprovalRequired(
                    title: "Tool approval required",
                    message: summary,
                    agentId: agentID,
                    sessionId: sessionID
                )
            }
            await self.runtime.updateWorkerExecutor(
                ToolExecutionWorkerExecutorAdapter(
                    toolExecutionService: self.toolExecution,
                    agentRunner: { [weak self] agentID, taskID, objective, workingDirectory, selectedModel, toolIDs in
                        guard let self else { return nil }
                        let knownToolIDs = await ToolCatalog.knownToolIDs(mcpRegistry: self.mcpRegistry)
                        let explicitToolIDs = SubagentDelegation.explicitToolIDs(
                            forWorkerTools: toolIDs,
                            knownToolIDs: knownToolIDs
                        )
                        guard let result = await self.runAgentTaskResult(
                            agentID: agentID,
                            taskID: taskID,
                            objective: objective,
                            workingDirectory: workingDirectory,
                            selectedModel: selectedModel,
                            explicitToolIDs: explicitToolIDs
                        ) else {
                            return nil
                        }
                        return ToolExecutionWorkerExecutorAdapter.AgentRunnerResult(
                            summary: result.text,
                            payload: result.payload
                        )
                    }
                )
            )
            await self.sessionOrchestrator.updateToolInvoker { [weak self] agentID, sessionID, request, mode in
                guard let self else {
                    return ToolInvocationResult(
                        tool: request.tool,
                        ok: false,
                        error: ToolErrorPayload(
                            code: "tool_invoker_unavailable",
                            message: "Tool invoker is unavailable.",
                            retryable: true
                        )
                    )
                }
                return await self.invokeToolFromRuntime(
                    agentID: agentID,
                    sessionID: sessionID,
                    request: request,
                    recordSessionEvents: true,
                    chatMode: mode
                )
            }
            await self.sessionOrchestrator.updateToolInvokerRecordsEvents(true)
            await self.sessionOrchestrator.updateResponseChunkObserver { [weak self] agentID, sessionID, chunk in
                guard let self else {
                    return
                }
                await self.publishLiveSessionDelta(agentID: agentID, sessionID: sessionID, chunk: chunk)
            }
            await self.sessionOrchestrator.updateEventAppendObserver { [weak self] agentID, sessionID, summary, events in
                guard let self else {
                    return
                }
                await self.publishLiveSessionEvents(
                    agentID: agentID,
                    sessionID: sessionID,
                    summary: summary,
                    events: events
                )
                await self.applyPetProgressForAgentSessionEvents(
                    agentID: agentID,
                    sessionID: sessionID,
                    summary: summary,
                    events: events
                )
            }
            await self.sessionOrchestrator.updateTokenUsageObserver { [weak self] agentID, sessionID, usage in
                guard let self else {
                    return
                }
                await self.store.persistTokenUsage(
                    channelId: "agent:\(agentID):session:\(sessionID)",
                    taskId: nil,
                    usage: usage
                )
            }
            await self.resumePendingMemoryImports()
            await self.resumePendingMigrations()
        }
    }

    func environmentOverridesForSession(_ sessionID: String) -> [String: String] {
        sessionEnvironmentOverrides[sessionID] ?? [:]
    }

    func setEnvironmentOverrides(_ environment: [String: String], forSession sessionID: String) {
        sessionEnvironmentOverrides[sessionID] = environment
    }

    deinit {
        eventTask?.cancel()
        proactiveTaskEventTask?.cancel()
    }

    // MARK: - Review Flow

    // MARK: - Task Activity

    func projectForChannel(channelId: String, topicId: String? = nil) async -> ProjectRecord? {
        let projects = await store.listProjects()
        let scoped = ChannelGatewayScope.parse(channelId)
        let effectiveChannelId = ChannelGatewayScope.scopedChannelId(
            baseChannelId: scoped.baseChannelId,
            topicKey: scoped.topicKey ?? topicId
        )
        let ordered = projects.sorted(by: { $0.createdAt < $1.createdAt })
        if let exact = ordered.first(where: { project in
            project.channels.contains { $0.channelId == effectiveChannelId }
        }) {
            return exact
        }
        return ordered.first(where: { project in
            project.channels.contains {
                ChannelGatewayScope.sessionMatchesBinding(sessionChannelId: effectiveChannelId, bindingChannelId: $0.channelId)
            }
        })
    }

    func resolveTask(reference: TaskApprovalReference, in project: ProjectRecord) -> ProjectTask? {
        switch reference {
        case .taskID(let taskID):
            let lowercasedTaskID = taskID.lowercased()
            return project.tasks.first(where: { task in
                task.id == taskID || task.id.lowercased() == lowercasedTaskID
            })
        case .index(let oneBasedIndex):
            guard oneBasedIndex > 0 else {
                return nil
            }
            let ordered = project.tasks.sorted(by: { $0.createdAt < $1.createdAt })
            let zeroBasedIndex = oneBasedIndex - 1
            guard ordered.indices.contains(zeroBasedIndex) else {
                return nil
            }
            return ordered[zeroBasedIndex]
        }
    }

    func resolveTask(reference: String, in project: ProjectRecord) throws -> ProjectTask {
        guard let normalizedReference = normalizeTaskReference(reference) else {
            throw ProjectError.invalidTaskID
        }

        let lowercasedTaskID = normalizedReference.lowercased()
        guard let task = project.tasks.first(where: { task in
            task.id == normalizedReference || task.id.lowercased() == lowercasedTaskID
        }) else {
            throw ProjectError.notFound
        }

        return task
    }

    var activeProjectTaskStatuses: Set<String> {
        Set([
            ProjectTaskStatus.pendingApproval.rawValue,
            ProjectTaskStatus.backlog.rawValue,
            ProjectTaskStatus.ready.rawValue,
            ProjectTaskStatus.inProgress.rawValue,
            ProjectTaskStatus.needsReview.rawValue,
        ])
    }

    func normalizedTaskTitleKey(_ value: String) -> String {
        normalizeWhitespace(value).lowercased()
    }

    func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isModelProviderError(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("model provider error:")
    }

    func captureGroup(_ source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        guard let match = regex.firstMatch(in: source, options: [], range: fullRange),
              match.numberOfRanges > 1
        else {
            return nil
        }

        let range = match.range(at: 1)
        guard range.location != NSNotFound else {
            return nil
        }
        return nsSource.substring(with: range)
    }

    func extractTaskReferences(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"#([A-Za-z0-9._-]+-\d+)"#) else {
            return []
        }

        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: content, options: [], range: range)
        guard !matches.isEmpty else {
            return []
        }

        var unique: Set<String> = []
        var ordered: [String] = []
        for match in matches where match.numberOfRanges > 1 {
            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound else {
                continue
            }

            let token = nsContent.substring(with: tokenRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                continue
            }

            let normalizedToken = token.uppercased()
            if unique.insert(normalizedToken).inserted {
                ordered.append(normalizedToken)
            }
        }
        return ordered
    }

    func mapAgentStorageError(_ error: Error) -> AgentStorageError {
        guard let storeError = error as? AgentCatalogFileStore.StoreError else {
            return .invalidPayload
        }

        switch storeError {
        case .invalidID:
            return .invalidID
        case .invalidPayload, .invalidModel, .storageFailure:
            return .invalidPayload
        case .alreadyExists:
            return .alreadyExists
        case .notFound:
            return .notFound
        }
    }

    func mapAgentConfigError(_ error: Error) -> AgentConfigError {
        if let lengthError = error as? AgentDocumentLengthError,
           case .exceeded(let resource, let limit) = lengthError {
            return .documentLengthExceeded(resource: resource, limit: limit)
        }

        guard let storeError = error as? AgentCatalogFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidID:
            return .invalidAgentID
        case .invalidPayload:
            return .invalidPayload
        case .invalidModel:
            return .invalidModel
        case .notFound:
            return .agentNotFound
        case .alreadyExists, .storageFailure:
            return .storageFailure
        }
    }

    func mapAgentToolsError(_ error: Error) -> AgentToolsError {
        guard let storeError = error as? AgentToolsFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidPayload:
            return .invalidPayload
        case .agentNotFound:
            return .agentNotFound
        case .storageFailure:
            return .storageFailure
        }
    }

    func mapActorBoardError(_ error: Error) -> ActorBoardError {
        if let actorBoardError = error as? ActorBoardError {
            return actorBoardError
        }

        guard let storeError = error as? ActorBoardFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidPayload:
            return .invalidPayload
        case .actorNotFound:
            return .actorNotFound
        case .storageFailure:
            return .storageFailure
        }
    }

    func updateActorBoardSnapshot(
        nodes: [ActorNode],
        links: [ActorLink],
        teams: [ActorTeam],
        agents: [AgentSummary]
    ) throws -> ActorBoardSnapshot {
        do {
            return try actorBoardStore.saveBoard(
                ActorBoardUpdateRequest(nodes: nodes, links: links, teams: teams),
                agents: agents
            )
        } catch {
            throw mapActorBoardError(error)
        }
    }

    func isProtectedSystemActorID(_ id: String) -> Bool {
        id == "human:admin" || id.hasPrefix("agent:")
    }

    func normalizedActorEntityID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 180 else {
            return nil
        }

        return trimmed
    }

    func normalizedAgentID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 120 else {
            return nil
        }

        return trimmed
    }

    func normalizedSessionID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 160 else {
            return nil
        }

        return trimmed
    }

}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
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

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else {
            return nil
        }
        return values.compactMap { value in
            if case .string(let stringValue) = value {
                return stringValue
            }
            return nil
        }
    }
}


// MARK: - ProjectToolService conformance

extension CoreService: ProjectToolService {
    func findProjectForChannel(channelId: String, topicId: String?) async -> ProjectRecord? {
        await projectForChannel(channelId: channelId, topicId: topicId)
    }

    func createTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        try await createProjectTask(projectID: projectID, request: request)
    }

    func updateTask(projectID: String, taskID: String, request: ProjectTaskUpdateRequest) async throws -> ProjectRecord {
        try await updateProjectTask(projectID: projectID, taskID: taskID, request: request)
    }

    func cancelTaskWithReason(projectID: String, taskID: String, reason: String?) async throws -> ProjectRecord {
        try await cancelProjectTask(projectID: projectID, taskID: taskID, reason: reason)
    }

    func deleteTask(projectID: String, taskID: String) async throws -> ProjectRecord {
        try await deleteProjectTask(projectID: projectID, taskID: taskID)
    }

    func getTask(reference: String) async throws -> AgentTaskRecord {
        try await getProjectTask(taskReference: reference)
    }

    func deliverMessage(channelId: String, content: String) async {
        await deliverToChannelPlugin(channelId: channelId, content: content)
    }

    func actorBoard() async throws -> ActorBoardSnapshot {
        try getActorBoard()
    }

    func requestProjectMemoryCheckpoint(agentID: String, sessionID: String, projectID: String, taskID: String, status: String) async {
        scheduleAgentMemoryCheckpoint(
            agentID: agentID,
            sessionID: sessionID,
            reason: "project_task_\(status):\(projectID):\(taskID)"
        )
    }

    func listAllProjects() async -> [ProjectRecord] {
        await listProjects()
    }
}

extension CoreService: RuntimeConfigToolService {
    func runtimeConfig() async -> CoreConfig {
        currentConfig
    }

    func updateRuntimeConfig(_ config: CoreConfig) async throws -> CoreConfig {
        try await updateConfig(config)
    }
}

extension CoreService: SkillsToolService {}
