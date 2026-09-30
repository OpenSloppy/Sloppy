import Foundation
import AgentRuntime
import Protocols
import PluginSDK
import Logging

// MARK: - Gateway Plugin Lifecycle

extension CoreService {
    public func bootstrapSourceControlPlugins() async {
        let pluginsDir = pluginsRootURL
        let loader = PluginLoader(logger: logger)
        let sourceControlPlugins = await loader.loadSourceControlPluginBundles(
            from: pluginsDir,
            cacheRootURL: pluginCacheRootURL
        )
        for loaded in sourceControlPlugins {
            registerSourceControlProvider(loaded.provider)
            logger.info("External source-control provider \(loaded.provider.id) registered.")
        }
    }

    public func bootstrapChannelPlugins() async {
        await refreshOAuthModelCacheIfNeeded()

        if let telegramConfig = currentConfig.channels.telegram {
            let plugin = builtInGatewayPluginFactory.makeTelegram(
                telegramConfig,
                self as any TelegramModelPickerBridge,
                self as any ToolApprovalBridge
            )
            await startBuiltInPlugin(
                plugin,
                id: "telegram",
                type: "telegram",
                channelIds: Array(Set(telegramConfig.channelChatMap.keys).union(telegramConfig.topicChannelMap.values))
            )
        }

        if let discordConfig = currentConfig.channels.discord {
            let plugin = builtInGatewayPluginFactory.makeDiscord(discordConfig)
            await startBuiltInPlugin(
                plugin,
                id: "discord",
                type: "discord",
                channelIds: Array(discordConfig.channelDiscordChannelMap.keys)
            )
        }

        await bootstrapSourceControlPlugins()

        let pluginsDir = pluginsRootURL
        let loader = PluginLoader(logger: logger)
        let taskSyncPlugins = await loader.loadTaskSyncPluginBundles(
            from: pluginsDir,
            cacheRootURL: pluginCacheRootURL
        )
        for loaded in taskSyncPlugins {
            registerTaskSyncProvider(loaded.provider, manifest: loaded.manifest)
            logger.info("External task-sync provider \(loaded.provider.id) registered.")
        }

        let disabledCodeReviewPluginIDs = Set(
            await store.listChannelPlugins()
                .filter { !$0.enabled }
                .map(\.id)
        )
        let codeReviewPlugins = await loader.loadCodeReviewPluginBundles(
            from: pluginsDir,
            cacheRootURL: pluginCacheRootURL,
            disabledPluginIDs: disabledCodeReviewPluginIDs
        )
        for loaded in codeReviewPlugins {
            registerCodeReviewProvider(loaded.provider)
            logger.info("External code-review provider \(loaded.provider.id) registered.")
        }

        let disabledPluginIDs = Set(
            await store.listChannelPlugins()
                .filter { !$0.enabled && $0.deliveryMode == ChannelPluginRecord.DeliveryMode.inProcess }
                .map(\.id)
        )
        let externalPlugins = await loader.loadGatewayPluginBundles(
            from: pluginsDir,
            cacheRootURL: pluginCacheRootURL,
            inboundReceiver: self,
            disabledPluginIDs: disabledPluginIDs
        )
        for loaded in externalPlugins {
            let plugin = loaded.plugin
            await channelDelivery.registerPlugin(plugin)
            activeGatewayPlugins.append(plugin)
            do {
                try await plugin.start(inboundReceiver: self)
                await seedExternalPluginRecord(
                    id: loaded.manifest.name,
                    type: loaded.manifest.name,
                    channelIds: plugin.channelIds,
                    enabled: true
                )
                logger.info("External gateway plugin \(plugin.id) started.")
            } catch {
                logger.error("Failed to start external gateway plugin \(plugin.id): \(error)")
                await channelDelivery.unregisterPlugin(plugin)
                activeGatewayPlugins.removeAll { $0.id == plugin.id }
            }
        }

        // Initialize periodic visor scheduler from config.
        if visorScheduler == nil {
            visorScheduler = VisorScheduler(
                config: buildVisorSchedulerConfig(),
                logger: logger
            ) { [weak self] in
                guard let self else { return }
                _ = await self.triggerVisorBulletin()
            }
        }
        if currentConfig.visor.scheduler.enabled {
            await visorScheduler?.start()
        }

        if kanbanScheduler == nil {
            kanbanScheduler = KanbanMaintenanceScheduler(
                config: buildKanbanSchedulerConfig(),
                logger: Logger.sloppy(label: "sloppy.kanban.scheduler")
            ) { [weak self] in
                guard let self else { return }
                _ = await self.runKanbanMaintenanceNow()
            }
        }
        if currentConfig.kanban.scheduler.enabled {
            await kanbanScheduler?.start()
        }

        if autodreamRunner == nil {
            autodreamRunner = AutodreamRunner(
                config: buildAutodreamRunnerConfig(),
                logger: Logger.sloppy(label: "sloppy.autodream")
            ) { [weak self] in
                guard let self else { return }
                await self.runAutodreamPass(reason: "scheduled")
            }
        }
        if currentConfig.visor.autodream.enabled {
            await autodreamRunner?.start()
        }

        if selfImprovementCuratorRunner == nil {
            selfImprovementCuratorRunner = SelfImprovementCuratorRunner(
                config: .weekly,
                logger: Logger.sloppy(label: "sloppy.self-improvement.curator")
            ) { [weak self] in
                guard let self else { return }
                _ = await self.runScheduledSelfImprovementCurator(reason: "weekly")
            }
        }
        await selfImprovementCuratorRunner?.start()
        
        if cronRunner == nil {
            cronRunner = CronRunner(
                store: self.store,
                messagePoster: { [weak self] channelId, request in
                    guard let self else {
                        return
                    }
                    _ = await self.postChannelMessage(channelId: channelId, request: request)
                },
                notificationService: self.notificationService,
                logger: self.logger
            )
        }
        await cronRunner?.start()

        if heartbeatRunner == nil {
            heartbeatRunner = HeartbeatRunner(
                logger: Logger.sloppy(label: "sloppy.core.heartbeat")
            ) { [weak self] in
                guard let self else {
                    return []
                }
                return await self.listHeartbeatSchedules()
            } executor: { [weak self] agentID in
                guard let self else {
                    return
                }
                await self.runAgentHeartbeat(agentID: agentID)
            }
        }
        await heartbeatRunner?.start()

        if proactiveTaskEventTask == nil {
            let events = await kanbanEventService.subscribeAll()
            proactiveTaskEventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.markProactiveProjectDirty(projectID: event.projectId)
                }
            }
        }

        if taskSyncRunner == nil {
            taskSyncRunner = TaskSyncRunner(
                logger: Logger.sloppy(label: "sloppy.core.task-sync")
            ) { [weak self] in
                guard let self else {
                    return []
                }
                return await self.listTaskSyncSchedules()
            } executor: { [weak self] projectID in
                guard let self else {
                    return
                }
                await self.runScheduledTaskSync(projectID: projectID)
            }
        }
        await taskSyncRunner?.start()

        await runtime.startVisorSupervision(
            tickIntervalSeconds: currentConfig.visor.tickIntervalSeconds,
            workerTimeoutSeconds: currentConfig.visor.workerTimeoutSeconds,
            branchTimeoutSeconds: currentConfig.visor.branchTimeoutSeconds,
            maintenanceIntervalSeconds: currentConfig.visor.maintenanceIntervalSeconds,
            decayRatePerDay: currentConfig.visor.decayRatePerDay,
            pruneImportanceThreshold: currentConfig.visor.pruneImportanceThreshold,
            pruneMinAgeDays: currentConfig.visor.pruneMinAgeDays,
            channelDegradedFailureCount: currentConfig.visor.channelDegradedFailureCount,
            channelDegradedWindowSeconds: currentConfig.visor.channelDegradedWindowSeconds,
            idleThresholdSeconds: currentConfig.visor.idleThresholdSeconds,
            mergeEnabled: currentConfig.visor.mergeEnabled,
            mergeSimilarityThreshold: currentConfig.visor.mergeSimilarityThreshold,
            mergeMaxPerRun: currentConfig.visor.mergeMaxPerRun
        )
    }

    /// Stops all active in-process gateway plugins and visor scheduler. Called on shutdown.
    public func shutdownChannelPlugins() async {
        proactiveTaskEventTask?.cancel()
        proactiveTaskEventTask = nil
        for plugin in activeGatewayPlugins {
            await plugin.stop()
            await channelDelivery.unregisterPlugin(plugin)
        }
        activeGatewayPlugins.removeAll()

        await visorScheduler?.stop()
        await kanbanScheduler?.stop()
        await autodreamRunner?.stop()
        await selfImprovementCuratorRunner?.stop()
        await runtime.stopVisorSupervision()
        await memoryOutboxIndexer?.stop()
        await cronRunner?.stop()
        await heartbeatRunner?.stop()
        await taskSyncRunner?.stop()
        nodeMeshClientTask?.cancel()
        nodeMeshClientTask = nil
        nodeMeshClient = nil
        for task in meshTerminalForwardTasks.values {
            task.cancel()
        }
        meshTerminalForwardTasks.removeAll()
        for input in meshLaunchPreviewInputs.values { input.finish() }
        meshLaunchPreviewInputs.removeAll()
        meshLaunchPreviewOwners.removeAll()
        meshTerminalSessionIDs.removeAll()
        await launches.shutdown()
        await acpSessionManager.shutdown()
    }

    func seedBuiltInPluginRecord(
        id pluginId: String,
        type: String,
        channelIds: [String]
    ) async {
        let existing = await store.channelPlugin(id: pluginId)
        let now = Date()
        let record = ChannelPluginRecord(
            id: pluginId,
            type: type,
            baseUrl: "",
            channelIds: channelIds,
            config: [:],
            enabled: true,
            deliveryMode: ChannelPluginRecord.DeliveryMode.inProcess,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        await store.saveChannelPlugin(record)
    }

    func seedExternalPluginRecord(
        id pluginId: String,
        type: String,
        channelIds: [String],
        enabled: Bool
    ) async {
        let existing = await store.channelPlugin(id: pluginId)
        let now = Date()
        let record = ChannelPluginRecord(
            id: pluginId,
            type: existing?.type ?? type,
            baseUrl: "",
            channelIds: channelIds,
            config: existing?.config ?? [:],
            enabled: enabled,
            deliveryMode: ChannelPluginRecord.DeliveryMode.inProcess,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        await store.saveChannelPlugin(record)
    }

    var pluginsRootURL: URL {
        workspaceRootURL.appendingPathComponent("plugins", isDirectory: true)
    }

    var pluginCacheRootURL: URL {
        workspaceRootURL.appendingPathComponent("plugin-cache", isDirectory: true)
    }

    func stopActiveGatewayPlugin(id: String) async {
        let matches = activeGatewayPlugins.filter { $0.id == id }
        for plugin in matches {
            await plugin.stop()
            await channelDelivery.unregisterPlugin(plugin)
        }
        if !matches.isEmpty {
            activeGatewayPlugins.removeAll { $0.id == id }
        }
    }

    /// Accepts a user channel message and returns routing decision.
    func startBuiltInPlugin(
        _ plugin: any GatewayPlugin,
        id: String,
        type: String,
        channelIds: [String]
    ) async {
        await channelDelivery.registerPlugin(plugin)
        activeGatewayPlugins.append(plugin)
        await seedBuiltInPluginRecord(id: id, type: type, channelIds: channelIds)

        do {
            try await plugin.start(inboundReceiver: self)
            logger.info("\(type.capitalized) gateway plugin started.")
        } catch {
            logger.error("Failed to start \(type) gateway plugin: \(error)")
        }
    }

    func reloadBuiltInPlugin(
        id: String,
        type: String,
        newPlugin: (any GatewayPlugin)?,
        channelIds: [String],
        removedBecauseEmptyToken: Bool
    ) async {
        if let existing = activeGatewayPlugins.first(where: { $0.id == id }) {
            logger.info("\(type.capitalized) config changed — stopping existing plugin.")
            await existing.stop()
            await channelDelivery.unregisterPlugin(existing)
            activeGatewayPlugins.removeAll { $0.id == id }
        }

        guard let newPlugin else {
            let reason = removedBecauseEmptyToken ? "empty token" : "no config"
            await store.deleteChannelPlugin(id: id)
            logger.info("\(type.capitalized) plugin removed (\(reason)).")
            return
        }

        logger.info("\(type.capitalized) config changed — starting new plugin.")
        await startBuiltInPlugin(newPlugin, id: id, type: type, channelIds: channelIds)
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await memoryOutboxIndexer?.stop()
    }



    struct TaskDelegation {
        let actorID: String?
        let agentID: String?
        let channelID: String
    }

}
