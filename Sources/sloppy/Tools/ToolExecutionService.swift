import Foundation
import AgentRuntime
import Logging
import Protocols
import SloppyRuntime

final class ToolExecutionService: @unchecked Sendable {
    private let runtime: RuntimeSystem
    private let memoryStore: any MemoryStore
    private let sessionStore: AgentSessionFileStore
    private let agentCatalogStore: AgentCatalogFileStore
    private let agentSkillsStore: AgentSkillsFileStore?
    let processRegistry: SessionProcessRegistry
    let browserService: BrowserCDPService
    let desktopComputerBridge: DesktopComputerBridgeService
    private let safariBridgeService: SafariBridgeService
    private let channelSessionStore: ChannelSessionFileStore
    private var store: any PersistenceStore
    private let searchProviderService: SearchProviderService
    private let mcpRegistry: MCPClientRegistry
    private let logger: Logger
    private var workspaceRootURL: URL
    private let registry: ToolRegistry
    private var lspManager: LSPServerManager
    private let fileMutations = FileMutationCoordinator()
    private let artifactRetention = ToolOutputArtifactRetention()
    var projectService: (any ProjectToolService)?
    var configService: (any RuntimeConfigToolService)?
    var skillsService: (any SkillsToolService)?
    var memoryImportService: (any MemoryImportToolService)?
    var siteService: (any SiteToolService)?
    var sessionService: (any SessionToolService)?
    /// `(agentID, userID, field, markdown)` — used to build per-invocation `ToolContext.applyAgentMarkdown`.
    var applyAgentMarkdown: ((String, String?, AgentMarkdownDocumentField, String) async throws -> Void)?
    var delegateSubagent: (@Sendable (String, String, String, String?, [String]?, String?, String?) async -> String?)?
    var sessionEnvironmentOverrides: @Sendable (String) async -> [String: String]

    init(
        workspaceRootURL: URL,
        runtime: RuntimeSystem,
        memoryStore: any MemoryStore,
        sessionStore: AgentSessionFileStore,
        agentCatalogStore: AgentCatalogFileStore,
        agentSkillsStore: AgentSkillsFileStore? = nil,
        processRegistry: SessionProcessRegistry,
        browserConfig: CoreConfig.Browser = CoreConfig.Browser(),
        safariBridgeService: SafariBridgeService = SafariBridgeService(),
        channelSessionStore: ChannelSessionFileStore,
        store: any PersistenceStore,
        searchProviderService: SearchProviderService,
        mcpRegistry: MCPClientRegistry,
        lspConfig: CoreConfig.LSP = CoreConfig.LSP(),
        logger: Logger = Logger.sloppy(label: "sloppy.core.tools")
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.runtime = runtime
        self.memoryStore = memoryStore
        self.sessionStore = sessionStore
        self.agentCatalogStore = agentCatalogStore
        self.agentSkillsStore = agentSkillsStore
        self.processRegistry = processRegistry
        self.browserService = BrowserCDPService(config: browserConfig, workspaceRootURL: workspaceRootURL)
        self.safariBridgeService = safariBridgeService
        self.desktopComputerBridge = DesktopComputerBridgeService(
            assignmentsURL: workspaceRootURL.appendingPathComponent("desktop-computer-assignments.json")
        )
        self.channelSessionStore = channelSessionStore
        self.store = store
        self.searchProviderService = searchProviderService
        self.mcpRegistry = mcpRegistry
        self.lspManager = LSPServerManager(config: lspConfig, workspaceRootURL: workspaceRootURL)
        self.logger = logger
        self.registry = ToolRegistry.makeDefault()
        self.applyAgentMarkdown = nil
        self.delegateSubagent = nil
        self.sessionEnvironmentOverrides = { _ in [:] }
    }

    func updateWorkspaceRootURL(_ url: URL) {
        self.workspaceRootURL = url
    }

    func updateBrowserConfig(_ config: CoreConfig.Browser) async {
        await browserService.updateConfig(config, workspaceRootURL: workspaceRootURL)
    }

    func updateLSPConfig(_ config: CoreConfig.LSP) async {
        await lspManager.updateConfig(config, workspaceRootURL: workspaceRootURL)
    }

    func updateStore(_ store: any PersistenceStore) {
        self.store = store
    }

    func cleanupSessionProcesses(_ sessionID: String) async {
        await processRegistry.cleanup(sessionID: sessionID)
        await browserService.cleanup(sessionID: sessionID)
        await desktopComputerBridge.cleanup(sessionID: sessionID)
    }

    func shutdown() async {
        await processRegistry.shutdown()
        await browserService.shutdown()
        await desktopComputerBridge.shutdown()
        await lspManager.shutdown()
    }

    func activeProcessCount(sessionID: String) async -> Int {
        await processRegistry.activeCount(sessionID: sessionID)
    }

    func invoke(
        agentID: String,
        sessionID: String,
        currentChannelID: String? = nil,
        request: ToolInvocationRequest,
        policy: AgentToolsPolicy,
        currentProjectID: String? = nil,
        currentDirectoryURL: URL? = nil,
        sessionMCPRegistry: MCPClientRegistry? = nil
    ) async -> ToolInvocationResult {
        await artifactRetention.sweepIfNeeded(workspaceRootURL: workspaceRootURL)
        let context = makeContext(
            agentID: agentID,
            sessionID: sessionID,
            channelID: currentChannelID,
            policy: policy,
            currentProjectID: currentProjectID,
            currentDirectoryURL: currentDirectoryURL,
            environmentOverrides: await sessionEnvironmentOverrides(sessionID),
            userID: latestUserID(agentID: agentID, sessionID: sessionID),
            sessionMCPRegistry: sessionMCPRegistry
        )
        if let result = await registry.invoke(request: request, context: context) {
            return context.outputArtifacts.bound(result, maxBytes: min(50 * 1024, max(1, policy.guardrails.maxExecOutputBytes)))
        }
        if let result = try? await context.mcpRegistry.invokeDynamicTool(
            toolID: request.tool.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: request.arguments
        ) {
            return context.outputArtifacts.bound(result, maxBytes: min(50 * 1024, max(1, policy.guardrails.maxExecOutputBytes)))
        }
        let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolInvocationResult(
            tool: toolID,
            ok: false,
            error: ToolErrorPayload(code: "unknown_tool", message: "Unknown tool '\(toolID)'", retryable: false)
        )
    }

    func makeContext(
        agentID: String,
        sessionID: String,
        channelID: String? = nil,
        policy: AgentToolsPolicy,
        currentProjectID: String? = nil,
        currentDirectoryURL: URL? = nil,
        environmentOverrides: [String: String] = [:],
        userID: String? = nil,
        sessionMCPRegistry: MCPClientRegistry? = nil
    ) -> ToolContext {
        let boundApply = applyAgentMarkdown.map { handler in
            { (field: AgentMarkdownDocumentField, markdown: String) async throws in
                try await handler(agentID, userID, field, markdown)
            }
        }
        let sharedMemoryEnabled = (try? agentCatalogStore.getAgentRuntimeConfig(agentID: agentID).sharedMemoryEnabled) ?? true
        return ToolContext(
            agentID: agentID,
            sessionID: sessionID,
            userID: userID,
            sharedMemoryEnabled: sharedMemoryEnabled,
            channelID: channelID,
            policy: policy,
            workspaceRootURL: workspaceRootURL,
            readOnlyRoots: agentSkillsStore?.sharedSkillsRootPaths() ?? [],
            currentDirectoryURL: currentDirectoryURL,
            currentProjectID: currentProjectID,
            environmentOverrides: environmentOverrides,
            runtime: runtime,
            memoryStore: memoryStore,
            sessionStore: sessionStore,
            agentCatalogStore: agentCatalogStore,
            agentSkillsStore: agentSkillsStore,
            processRegistry: processRegistry,
            channelSessionStore: channelSessionStore,
            store: store,
            searchProviderService: searchProviderService,
            mcpRegistry: sessionMCPRegistry ?? mcpRegistry,
            logger: logger,
            projectService: projectService,
            configService: configService,
            skillsService: skillsService,
            memoryImportService: memoryImportService,
            siteService: siteService,
            sessionService: sessionService,
            lspManager: lspManager,
            fileMutations: fileMutations,
            browserService: browserService,
            desktopComputerBridge: desktopComputerBridge,
            safariBridgeService: safariBridgeService,
            applyAgentMarkdown: boundApply,
            delegateSubagent: delegateSubagent
        )
    }

    private func latestUserID(agentID: String, sessionID: String) -> String? {
        guard let detail = try? sessionStore.loadSession(agentID: agentID, sessionID: sessionID) else {
            return nil
        }
        return detail.events.reversed().compactMap { event -> String? in
            guard let message = event.message, message.role == .user, message.peerOrigin == nil else {
                return nil
            }
            let userID = message.userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return userID.isEmpty ? nil : userID
        }.first
    }
}
