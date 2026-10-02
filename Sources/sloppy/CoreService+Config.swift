import Foundation
import AnyLanguageModel
import AgentRuntime
import Protocols
import PluginSDK

// MARK: - Config

struct WorkspaceGitSyncRunError: LocalizedError {
    var response: WorkspaceGitSyncResponse

    var errorDescription: String? {
        response.message
    }
}

extension CoreService {
    func refreshModelProviderAfterCredentialChange() async {
        let config = currentConfig
        let oauthSvc = self.openAIOAuthService
        let anthropicOAuthSvc = self.anthropicOAuthService
        let geminiOAuthSvc = self.geminiOAuthService
        let workspaceRootURL = self.workspaceRootURL
        let anthropicSettingsProvider: @Sendable () -> ClaudeSettingsEnvironment = {
            ClaudeSettingsEnvironment.load(workspaceRootURL: workspaceRootURL)
        }
        let hasOAuth = oauthSvc.currentAccessToken() != nil
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(
            config: config,
            hasOAuthCredentials: hasOAuth,
            currentDirectory: workspaceCurrentDirectory
        )
        let modelProvider = CoreModelProviderFactory.buildModelProvider(
            config: config,
            resolvedModels: resolvedModels,
            tools: ToolRegistry.makeDefault().allTools,
            oauthTokenProvider: { oauthSvc.currentAccessToken() },
            oauthAccountId: oauthSvc.currentAccountId(),
            oauthTokenRefresh: { try await oauthSvc.ensureValidToken() },
            oauthTokenForceRefresh: { try await oauthSvc.ensureValidToken(forceRefresh: true) },
            anthropicOAuthTokenProvider: { anthropicOAuthSvc.currentAccessToken() },
            anthropicOAuthTokenRefresh: { try await anthropicOAuthSvc.ensureValidToken() },
            anthropicSettingsProvider: anthropicSettingsProvider,
            geminiOAuthCredentialsProvider: { geminiOAuthSvc.currentCredentials() },
            systemInstructions: "You are Sloppy core channel assistant.",
            proxySession: ProxySessionFactory.makeSession(proxy: config.proxy),
            currentDirectory: workspaceCurrentDirectory
        )
        let defaultModel = modelProvider?.supportedModels.first ?? resolvedModels.first
        self.modelProvider = modelProvider
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
        await sessionOrchestrator.updateAvailableModels(availableAgentModels())
        await sessionOrchestrator.updatePersistedModelContext(
            config: config,
            hasOAuthCredentials: hasOAuth
        )
    }

    public func updateConfig(_ config: CoreConfig) async throws -> CoreConfig {
        let previousOnboardingCompleted = currentConfig.onboarding.completed
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded = try encoder.encode(config)
        let payload = encoded + Data("\n".utf8)
        let url = URL(fileURLWithPath: configPath)
        try CoreConfigFileStore.backupExistingConfigIfValid(path: configPath)
        try payload.write(to: url, options: .atomic)

        let previousChannels = currentConfig.channels
        let launchStorageChanged = currentConfig.resolvedSQLiteURL(currentDirectory: workspaceCurrentDirectory)
            != config.resolvedSQLiteURL(currentDirectory: workspaceCurrentDirectory)
            || workspaceRootURL != config.resolvedWorkspaceRootURL(currentDirectory: workspaceCurrentDirectory)
        currentConfig = config
        await semanticModelRouter.updateConfig(config.semanticDecisions)
        let refreshedStore = persistenceBuilder.makeStore(config: config)
        try await launches.updateStore(refreshedStore, reset: launchStorageChanged)
        store = refreshedStore
        await proactiveHeartbeatService.updateStore(refreshedStore)
        let nextWorkspaceRoot = config.resolvedWorkspaceRootURL(currentDirectory: workspaceCurrentDirectory)
        if workspaceRootURL != nextWorkspaceRoot {
            longChatStorage = nil
            longChatRecoveryCompleted = false
        }
        workspaceRootURL = nextWorkspaceRoot
        agentsRootURL = workspaceRootURL
            .appendingPathComponent("agents", isDirectory: true)
        agentCatalogStore.updateAgentsRootURL(agentsRootURL)
        sessionStore.updateAgentsRootURL(agentsRootURL)
        agentSkillsStore.updateAgentsRootURL(agentsRootURL)
        actorBoardStore.updateWorkspaceRootURL(workspaceRootURL)
        workflowDefinitionStore.updateWorkspaceRootURL(workspaceRootURL)
        automationDefinitionStore.updateWorkspaceRootURL(workspaceRootURL)
        await channelModelStore.updateWorkspaceRootURL(workspaceRootURL)
        await channelChatModeStore.updateWorkspaceRootURL(workspaceRootURL)
        await sessionOrchestrator.updateAgentsRootURL(agentsRootURL)
        await toolsAuthorization.updateAgentsRootURL(agentsRootURL)
        await mcpRegistry.updateConfig(config.mcp)
        await agentPluginManager.update(workspaceRootURL: workspaceRootURL, store: refreshedStore)
        await acpSessionManager.updateConfig(
            config.acp,
            workspaceRootURL: workspaceRootURL,
            agentsRootURL: agentsRootURL
        )
        await toolExecution.updateLSPConfig(config.lsp)
        await toolsAuthorization.invalidateCachedPolicies()
        toolExecution.updateWorkspaceRootURL(workspaceRootURL)
        await toolExecution.updateBrowserConfig(config.browser)
        toolExecution.updateStore(refreshedStore)
        systemLogStore.updateWorkspaceRootURL(workspaceRootURL)
        await channelDelivery.updateStore(refreshedStore)
        await recoveryManager.updateStore(refreshedStore)
        readyTaskStartupDispatchCompleted = false
        readyTaskStartupDispatchInProgress = false
        await searchProviderService.updateConfig(config.searchTools)
        await refreshModelProviderAfterCredentialChange()

        if previousChannels.telegram != config.channels.telegram {
            var plugin: (any GatewayPlugin)?
            if let telegramConfig = config.channels.telegram {
                let token = telegramConfig.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    plugin = builtInGatewayPluginFactory.makeTelegram(
                        telegramConfig,
                        self as any TelegramModelPickerBridge,
                        self as any ToolApprovalBridge
                    )
                }
            }
            let channelIds = config.channels.telegram.map { Array(Set($0.channelChatMap.keys).union($0.topicChannelMap.values)) } ?? []
            await reloadBuiltInPlugin(
                id: "telegram",
                type: "telegram",
                newPlugin: plugin,
                channelIds: channelIds,
                removedBecauseEmptyToken: config.channels.telegram?.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            )
        }

        if previousChannels.discord != config.channels.discord {
            var plugin: (any GatewayPlugin)?
            if let discordConfig = config.channels.discord {
                let token = discordConfig.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    plugin = builtInGatewayPluginFactory.makeDiscord(discordConfig)
                }
            }
            let channelIds = config.channels.discord.map { Array($0.channelDiscordChannelMap.keys) } ?? []
            await reloadBuiltInPlugin(
                id: "discord",
                type: "discord",
                newPlugin: plugin,
                channelIds: channelIds,
                removedBecauseEmptyToken: config.channels.discord?.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            )
        }

        if previousOnboardingCompleted != config.onboarding.completed {
            logger.info(
                "onboarding.config.updated",
                metadata: [
                    "completed": .stringConvertible(config.onboarding.completed),
                    "models_count": .stringConvertible(config.models.count),
                    "primary_model": .string(config.models.first?.model ?? "")
                ]
            )
        } else if !config.onboarding.completed {
            logger.info(
                "onboarding.config.saved_draft",
                metadata: [
                    "models_count": .stringConvertible(config.models.count),
                    "primary_model": .string(config.models.first?.model ?? "")
                ]
            )
        }

        return currentConfig
    }
    public func getConfig() -> CoreConfig {
        currentConfig
    }

    public func runWorkspaceGitSyncNow() async throws -> WorkspaceGitSyncResponse {
        let syncConfig = currentConfig.gitSync
        let syncWorkspaceRootURL = workspaceRootURL
        let attemptedAt = workspaceGitSyncTimestamp()
        let branch = syncConfig.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "main"
            : syncConfig.branch.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var response = try await workspaceGitSyncService.syncNow(
                config: syncConfig,
                workspaceRootURL: syncWorkspaceRootURL
            )
            let status = WorkspaceGitSyncStatus(
                lastAttemptAt: attemptedAt,
                lastSuccessAt: attemptedAt,
                lastFailureAt: syncConfig.status.lastFailureAt,
                lastError: nil,
                lastCommit: response.commit ?? syncConfig.status.lastCommit,
                lastFilesChanged: response.filesChanged,
                failedAttempts: 0
            )
            recordWorkspaceGitSyncStatus(status)
            response.status = status
            return response
        } catch {
            let message = error.localizedDescription
            let status = WorkspaceGitSyncStatus(
                lastAttemptAt: attemptedAt,
                lastSuccessAt: syncConfig.status.lastSuccessAt,
                lastFailureAt: attemptedAt,
                lastError: message,
                lastCommit: syncConfig.status.lastCommit,
                lastFilesChanged: syncConfig.status.lastFilesChanged,
                failedAttempts: syncConfig.status.failedAttempts + 1
            )
            recordWorkspaceGitSyncStatus(status)
            throw WorkspaceGitSyncRunError(
                response: WorkspaceGitSyncResponse(
                    ok: false,
                    message: message,
                    branch: branch,
                    status: status
                )
            )
        }
    }

    private func recordWorkspaceGitSyncStatus(_ status: WorkspaceGitSyncStatus) {
        currentConfig.gitSync.status = status
        do {
            try writeRuntimeConfigSnapshot(currentConfig)
        } catch {
            logger.warning(
                "workspace_git_sync.status_persist_failed",
                metadata: ["error": .string(error.localizedDescription)]
            )
        }
    }

    private func writeRuntimeConfigSnapshot(_ config: CoreConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(config) + Data("\n".utf8)
        let url = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: url, options: .atomic)
    }

    private func workspaceGitSyncTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Lists all persisted agents from workspace `/agents`.
}
