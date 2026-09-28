import Foundation
import AgentRuntime
import Protocols
import PluginSDK
import AnyLanguageModel
import Logging
import CodexBarCore
import SloppyRuntime

// MARK: - Agents

extension CoreService {
    public func listAgents(includeSystem: Bool = true) throws -> [AgentSummary] {
        do {
            let agents = try agentCatalogStore.listAgents()
            if includeSystem {
                return agents
            }
            return agents.filter { !$0.isSystem }
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    /// Returns one persisted agent by id.
    public func getAgent(id: String) throws -> AgentSummary {
        do {
            return try agentCatalogStore.getAgent(id: id)
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    public func listAgentFiles(agentID: String, path: String) throws -> [ProjectFileEntry] {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let rootURL: URL
        do {
            rootURL = try agentCatalogStore.directoryURL(agentID: normalizedID)
        } catch {
            throw mapAgentStorageError(error)
        }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTopLevelNames = Set(agentVisibleTopLevelNames)
        let fm = FileManager.default

        if trimmedPath.isEmpty || trimmedPath == "/" {
            var entries: [ProjectFileEntry] = []
            for name in agentVisibleTopLevelNames {
                let url = rootURL.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    continue
                }
                entries.append(
                    ProjectFileEntry(
                        name: name,
                        type: isDirectory.boolValue ? .directory : .file,
                        size: isDirectory.boolValue ? nil : ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil)
                    )
                )
            }
            return sortAgentEntries(entries)
        }

        let normalizedPath = trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = normalizedPath.split(separator: "/").map(String.init)
        guard !pathComponents.isEmpty else {
            throw AgentStorageError.notFound
        }

        let firstComponent = pathComponents[0]
        guard firstComponent == "skills" || visibleTopLevelNames.contains(firstComponent) else {
            throw AgentStorageError.notFound
        }

        let targetURL = rootURL.appendingPathComponent(normalizedPath).standardizedFileURL
        guard isAgentURL(targetURL, inside: rootURL) else {
            throw AgentStorageError.invalidID
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentStorageError.notFound
        }

        let contents = try fm.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let entries = contents.compactMap { url -> ProjectFileEntry? in
            if normalizedPath == "skills" && url.lastPathComponent == "skills.json" {
                return nil
            }
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize
            return ProjectFileEntry(
                name: url.lastPathComponent,
                type: isDir ? .directory : .file,
                size: isDir ? nil : size
            )
        }
        return sortAgentEntries(entries)
    }

    public func readAgentFile(agentID: String, path: String) throws -> ProjectFileContentResponse {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let rootURL: URL
        do {
            rootURL = try agentCatalogStore.directoryURL(agentID: normalizedID)
        } catch {
            throw mapAgentStorageError(error)
        }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else {
            throw AgentStorageError.invalidID
        }

        let pathComponents = normalizedPath.split(separator: "/").map(String.init)
        guard let firstComponent = pathComponents.first else {
            throw AgentStorageError.invalidID
        }
        guard agentVisibleTopLevelNames.contains(firstComponent) else {
            throw AgentStorageError.notFound
        }
        if firstComponent == "skills" && normalizedPath == "skills/skills.json" {
            throw AgentStorageError.notFound
        }

        let targetURL = rootURL.appendingPathComponent(normalizedPath).standardizedFileURL
        guard isAgentURL(targetURL, inside: rootURL) else {
            throw AgentStorageError.invalidID
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgentStorageError.notFound
        }

        let maxBytes = 2 * 1024 * 1024
        let data = try Data(contentsOf: targetURL)
        guard data.count <= maxBytes else {
            throw AgentStorageError.invalidPayload
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentStorageError.invalidPayload
        }

        return ProjectFileContentResponse(path: normalizedPath, content: text, sizeBytes: data.count)
    }

    /// Lists project tasks currently claimed by a specific agent.
    public func listAgentTasks(agentID: String) async throws -> [AgentTaskRecord] {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let board = try? getActorBoard()
        let linkedActorIDs = Set(
            (board?.nodes ?? [])
                .filter { ($0.linkedAgentId ?? "").caseInsensitiveCompare(normalizedID) == .orderedSame }
                .map { $0.id.lowercased() }
        )

        let projects = await store.listProjects()
        var records: [AgentTaskRecord] = []
        for project in projects {
            for task in project.tasks {
                let claimedByAgent = task.claimedAgentId.map {
                    $0.caseInsensitiveCompare(normalizedID) == .orderedSame
                } ?? false
                let assignedViaActor = task.actorId.map {
                    linkedActorIDs.contains($0.lowercased())
                } ?? false
                if claimedByAgent || assignedViaActor {
                    records.append(
                        AgentTaskRecord(
                            projectId: project.id,
                            projectName: project.name,
                            task: task
                        )
                    )
                }
            }
        }

        return records.sorted { left, right in
            left.task.updatedAt > right.task.updatedAt
        }
    }

    private var agentVisibleTopLevelNames: [String] {
        ["AGENTS.md", "USER.md", "SOUL.md", "IDENTITY.md", "HEARTBEAT.md", "FRIEND_REMINDER.md", "MEMORY.md", "skills"]
    }

    private func sortAgentEntries(_ entries: [ProjectFileEntry]) -> [ProjectFileEntry] {
        entries.sorted {
            if $0.type == $1.type {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.type == .directory
        }
    }

    private func isAgentURL(_ url: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }

    public func listAgentMemories(
        agentID: String,
        search: String?,
        filter: AgentMemoryFilter,
        limit: Int,
        offset: Int
    ) async throws -> AgentMemoryListResponse {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let boundedLimit = max(1, min(limit, 100))
        let boundedOffset = max(0, offset)
        let entries = await matchingAgentMemoryEntries(agentID: normalizedID, search: search, filter: filter)
        let page = Array(entries.dropFirst(boundedOffset).prefix(boundedLimit))

        return AgentMemoryListResponse(
            agentId: normalizedID,
            items: page.map { makeAgentMemoryItem(from: $0) },
            total: entries.count,
            limit: boundedLimit,
            offset: boundedOffset
        )
    }

    public func agentMemoryGraph(
        agentID: String,
        search: String?,
        filter: AgentMemoryFilter
    ) async throws -> AgentMemoryGraphResponse {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let allEntries = await allAgentMemoryEntries(agentID: normalizedID)
        let matchingEntries = filterAgentMemoryEntries(allEntries, search: search, filter: filter)
        let seedEntries = Array(matchingEntries.prefix(Self.agentMemoryGraphSeedLimit))
        let seedIDs = seedEntries.map(\.id)
        var truncated = matchingEntries.count > Self.agentMemoryGraphSeedLimit

        guard !seedIDs.isEmpty else {
            return AgentMemoryGraphResponse(
                agentId: normalizedID,
                nodes: [],
                edges: [],
                seedIds: [],
                truncated: false
            )
        }

        let edgeRecords = await memoryStore.edges(for: seedIDs)
        let entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var neighborIDs: [String] = []
        var seenNeighborIDs = Set<String>()
        let seedIDSet = Set(seedIDs)

        for edge in edgeRecords {
            for candidateID in [edge.fromMemoryId, edge.toMemoryId] {
                guard !seedIDSet.contains(candidateID),
                      entriesByID[candidateID] != nil,
                      seenNeighborIDs.insert(candidateID).inserted
                else {
                    continue
                }
                neighborIDs.append(candidateID)
            }
        }

        if neighborIDs.count > Self.agentMemoryGraphNeighborLimit {
            neighborIDs = Array(neighborIDs.prefix(Self.agentMemoryGraphNeighborLimit))
            truncated = true
        }

        let includedNodeIDs = Set(seedIDs + neighborIDs)
        let includedNodes = seedEntries + neighborIDs.compactMap { entriesByID[$0] }
        let filteredEdges = edgeRecords
            .filter { includedNodeIDs.contains($0.fromMemoryId) && includedNodeIDs.contains($0.toMemoryId) }
            .map {
                AgentMemoryEdgeRecord(
                    fromMemoryId: $0.fromMemoryId,
                    toMemoryId: $0.toMemoryId,
                    relation: $0.relation,
                    weight: $0.weight,
                    provenance: $0.provenance,
                    createdAt: $0.createdAt
                )
            }

        return AgentMemoryGraphResponse(
            agentId: normalizedID,
            nodes: includedNodes.map { makeAgentMemoryItem(from: $0) },
            edges: filteredEdges,
            seedIds: seedIDs,
            truncated: truncated
        )
    }

    public func listProjectMemories(
        projectID: String,
        search: String?,
        filter: AgentMemoryFilter,
        limit: Int,
        offset: Int
    ) async throws -> ProjectMemoryListResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        _ = try await getProject(id: normalizedID)

        let boundedLimit = max(1, min(limit, 100))
        let boundedOffset = max(0, offset)
        let entries = await allProjectMemoryEntries(projectID: normalizedID)
        let matching = filterAgentMemoryEntries(entries, search: search, filter: filter)
        let page = Array(matching.dropFirst(boundedOffset).prefix(boundedLimit))

        return ProjectMemoryListResponse(
            projectId: normalizedID,
            items: page.map { makeAgentMemoryItem(from: $0) },
            total: matching.count,
            limit: boundedLimit,
            offset: boundedOffset
        )
    }

    public func projectMemoryGraph(
        projectID: String,
        search: String?,
        filter: AgentMemoryFilter
    ) async throws -> ProjectMemoryGraphResponse {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        _ = try await getProject(id: normalizedID)

        let allEntries = await allProjectMemoryEntries(projectID: normalizedID)
        let matchingEntries = filterAgentMemoryEntries(allEntries, search: search, filter: filter)
        let seedEntries = Array(matchingEntries.prefix(Self.agentMemoryGraphSeedLimit))
        let seedIDs = seedEntries.map(\.id)
        var truncated = matchingEntries.count > Self.agentMemoryGraphSeedLimit

        guard !seedIDs.isEmpty else {
            return ProjectMemoryGraphResponse(
                projectId: normalizedID,
                nodes: [],
                edges: [],
                seedIds: [],
                truncated: false
            )
        }

        let edgeRecords = await memoryStore.edges(for: seedIDs)
        let entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var neighborIDs: [String] = []
        var seenNeighborIDs = Set<String>()
        let seedIDSet = Set(seedIDs)

        for edge in edgeRecords {
            for candidateID in [edge.fromMemoryId, edge.toMemoryId] {
                guard !seedIDSet.contains(candidateID),
                      entriesByID[candidateID] != nil,
                      seenNeighborIDs.insert(candidateID).inserted
                else {
                    continue
                }
                neighborIDs.append(candidateID)
            }
        }

        if neighborIDs.count > Self.agentMemoryGraphNeighborLimit {
            neighborIDs = Array(neighborIDs.prefix(Self.agentMemoryGraphNeighborLimit))
            truncated = true
        }

        let includedNodeIDs = Set(seedIDs + neighborIDs)
        let includedNodes = seedEntries + neighborIDs.compactMap { entriesByID[$0] }
        let filteredEdges = edgeRecords
            .filter { includedNodeIDs.contains($0.fromMemoryId) && includedNodeIDs.contains($0.toMemoryId) }
            .map {
                AgentMemoryEdgeRecord(
                    fromMemoryId: $0.fromMemoryId,
                    toMemoryId: $0.toMemoryId,
                    relation: $0.relation,
                    weight: $0.weight,
                    provenance: $0.provenance,
                    createdAt: $0.createdAt
                )
            }

        return ProjectMemoryGraphResponse(
            projectId: normalizedID,
            nodes: includedNodes.map { makeAgentMemoryItem(from: $0) },
            edges: filteredEdges,
            seedIds: seedIDs,
            truncated: truncated
        )
    }

    public func updateAgentMemory(
        agentID: String,
        memoryID: String,
        note: String?,
        summary: String?,
        kind: MemoryKind?,
        importance: Double?,
        confidence: Double?
    ) async throws -> AgentMemoryItem {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        guard let updated = await memoryStore.updateEntry(
            id: memoryID,
            note: note,
            summary: summary,
            kind: kind,
            importance: importance,
            confidence: confidence
        ) else {
            throw AgentStorageError.notFound
        }

        guard belongsToAgentMemory(updated, agentID: normalizedID) else {
            throw AgentStorageError.notFound
        }

        return makeAgentMemoryItem(from: updated)
    }

    public func deleteAgentMemory(
        agentID: String,
        memoryID: String
    ) async throws {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let entries = await allAgentMemoryEntries(agentID: normalizedID)
        guard entries.contains(where: { $0.id == memoryID }) else {
            throw AgentStorageError.notFound
        }

        let deleted = await memoryStore.softDelete(id: memoryID)
        guard deleted else {
            throw AgentStorageError.notFound
        }
    }

    /// Creates an agent and provisions `/workspace/agents/<agent_id>` directory.
    public func createAgent(_ request: AgentCreateRequest) async throws -> AgentSummary {
        do {
            if let runtime = request.runtime, runtime.type == .acp {
                do {
                    try await acpSessionManager.validateRuntime(runtime)
                } catch {
                    throw AgentStorageError.invalidPayload
                }
            }
            let summary = try agentCatalogStore.createAgent(request, availableModels: availableAgentModels())
            // Create skills directory for the new agent
            try await ensureAgentSkillsDirectory(agentID: summary.id)
            if !currentConfig.onboarding.completed {
                logger.info(
                    "onboarding.agent.created",
                    metadata: [
                        "agent_id": .string(summary.id),
                        "agent_role": .string(summary.role)
                    ]
                )
            }
            return summary
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    func provisionBuiltInSkillsForAllAgents() {
        do {
            for agent in try agentCatalogStore.listAgents() {
                try agentSkillsStore.ensureSkillsDirectory(agentID: agent.id)
            }
        } catch {
            logger.warning(
                "Failed to provision built-in skills for existing agents",
                metadata: [
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    public func deleteAgent(agentID: String) async throws {
        do {
            try agentCatalogStore.deleteAgent(id: agentID)
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    func makePersistedModelAllowance() -> (String) -> Bool {
        let cfg = currentConfig
        let hasOAuth = openAIOAuthService.currentAccessToken() != nil
        return { id in
            CoreService.isRuntimeRoutableModelID(id, config: cfg, hasOAuthCredentials: hasOAuth)
        }
    }

    func widenAvailableModelsForAgentSave(
        request: AgentConfigUpdateRequest,
        base: [ProviderModelOption]
    ) -> [ProviderModelOption] {
        var available = base
        let cfg = currentConfig
        let hasOAuth = openAIOAuthService.currentAccessToken() != nil
        if request.runtime.type == .native {
            for raw in [request.selectedModel, request.plannerModel] {
                let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty,
                   !available.contains(where: { $0.id == trimmed }),
                   CoreService.isRuntimeRoutableModelID(trimmed, config: cfg, hasOAuthCredentials: hasOAuth) {
                    available.append(CoreService.providerModelOption(for: trimmed))
                }
            }
        }
        return available
    }

    /// Returns agent-specific config including selected model and editable markdown docs.
    public func getAgentConfig(agentID: String) throws -> AgentConfigDetail {
        let availableModels = availableAgentModels()
        do {
            return try agentCatalogStore.getAgentConfig(
                agentID: agentID,
                availableModels: availableModels,
                persistedModelAllowed: makePersistedModelAllowance()
            )
        } catch {
            throw mapAgentConfigError(error)
        }
    }

    public func getAgentConfigWithMemory(agentID: String) async throws -> AgentConfigDetail {
        return try getAgentConfig(agentID: agentID)
    }

    /// Updates agent-specific model and markdown docs.
    public func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) async throws -> AgentConfigDetail {
        let availableModels = widenAvailableModelsForAgentSave(
            request: request,
            base: availableAgentModels()
        )
        do {
            if request.runtime.type == .acp {
                do {
                    try await acpSessionManager.validateRuntime(request.runtime)
                } catch {
                    throw AgentConfigError.invalidPayload
                }
            }
            let previousConfig = try? agentCatalogStore.getAgentConfig(
                agentID: agentID,
                availableModels: availableModels,
                persistedModelAllowed: makePersistedModelAllowance()
            )
            let previousSkills = previousConfig?.skills ?? AgentSkillSettings()
            let previousDocuments = previousConfig?.documents
            let updated = try agentCatalogStore.updateAgentConfig(
                agentID: agentID,
                request: request,
                availableModels: availableModels
            )
            if previousSkills != updated.skills {
                await sessionOrchestrator.notifySkillsChanged(agentID: agentID)
            }
            if let previousDocuments, previousDocuments != updated.documents {
                await sessionOrchestrator.notifyAgentDocumentsChanged(agentID: agentID)
            }
            if !currentConfig.onboarding.completed {
                logger.info(
                    "onboarding.agent_config.updated",
                    metadata: [
                        "agent_id": .string(agentID),
                        "selected_model": .string(request.selectedModel ?? "")
                    ]
                )
            }
            return updated
        } catch {
            throw mapAgentConfigError(error)
        }
    }

    /// Tool entry point for `agent.documents.set_*` (same validation as HTTP config updates).
    func applyAgentMarkdownFromTool(
        agentID: String,
        userID: String? = nil,
        field: AgentMarkdownDocumentField,
        markdown: String
    ) async throws {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentConfigError.invalidAgentID
        }
        if isUserScopedAgentDocumentUserID(userID) {
            var documents = try agentCatalogStore.readAgentDocuments(agentID: normalizedID, userID: userID)
            switch field {
            case .user:
                documents.userMarkdown = markdown
            case .memory:
                documents.memoryMarkdown = markdown
            }
            do {
                try AgentMarkdownLimits.validateAgentDocumentBundle(documents)
                try agentCatalogStore.writeAgentScopedMarkdown(
                    agentID: normalizedID,
                    userID: userID,
                    field: field,
                    markdown: markdown
                )
                await sessionOrchestrator.notifyAgentDocumentsChanged(agentID: normalizedID)
                return
            } catch let error as AgentDocumentLengthError {
                throw error
            } catch {
                throw AgentConfigError.storageFailure
            }
        }

        let models = availableAgentModels()
        let config = try agentCatalogStore.getAgentConfig(
            agentID: normalizedID,
            availableModels: models,
            persistedModelAllowed: makePersistedModelAllowance()
        )
        var documents = config.documents
        switch field {
        case .user:
            documents.userMarkdown = markdown
        case .memory:
            documents.memoryMarkdown = markdown
        }
        do {
            try AgentMarkdownLimits.validateAgentDocumentBundle(documents)
        } catch let error as AgentDocumentLengthError {
            throw error
        } catch {
            throw AgentConfigError.invalidPayload
        }
        let updateRequest = AgentConfigUpdateRequest(
            role: config.role,
            selectedModel: config.selectedModel,
            documents: documents,
            heartbeat: config.heartbeat,
            channelSessions: config.channelSessions,
            runtime: config.runtime
        )
        let saveModels = widenAvailableModelsForAgentSave(request: updateRequest, base: models)
        do {
            _ = try agentCatalogStore.updateAgentConfig(
                agentID: normalizedID,
                request: updateRequest,
                availableModels: saveModels
            )
            await sessionOrchestrator.notifyAgentDocumentsChanged(agentID: normalizedID)
        } catch {
            throw mapAgentConfigError(error)
        }
    }

    private func isUserScopedAgentDocumentUserID(_ raw: String?) -> Bool {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalized.isEmpty else { return false }
        return normalized != "system"
            && normalized != "assistant"
            && normalized != "agent"
            && normalized != "goal"
            && normalized != "goal_loop"
            && normalized != "onboarding"
    }

    /// Fetches token usage and estimated cost for the agent's selected model provider.
    public func getAgentTokenUsage(agentID: String) async throws -> AgentTokenUsageResponse {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }

        // Collect all channel IDs that belong to this agent:
        // 1. Agent chat session channels: agent:{agentId}:session:{sessionId}
        var channelIDs: Set<String> = []
        if let sessions = try? listAgentSessions(agentID: normalizedID) {
            for session in sessions {
                channelIDs.insert("agent:\(normalizedID):session:\(session.id)")
            }
        }
        // 2. External channels linked via the actor board
        let board = try? getActorBoard()
        channelIDs.formUnion(boundChannelIDs(agentID: normalizedID, board: board))

        var totalPrompt = 0
        var totalCompletion = 0
        var totalCachedInput = 0
        var totalCacheCreationInput = 0
        var totalReasoning = 0
        for channelID in channelIDs {
            let usage = await listTokenUsage(channelId: channelID)
            totalPrompt += usage.totalPromptTokens
            totalCompletion += usage.totalCompletionTokens
            totalCachedInput += usage.totalCachedInputTokens
            totalCacheCreationInput += usage.totalCacheCreationInputTokens
            totalReasoning += usage.totalReasoningTokens
        }

        // Try to get cost from CodexBar (reads local provider logs).
        let config = try getAgentConfig(agentID: normalizedID)
        let model = (config.selectedModel ?? "").lowercased()
        let provider: UsageProvider
        if model.contains("claude") {
            provider = .claude
        } else if model.contains("gemini") {
            provider = .gemini
        } else if model.contains("vertex") {
            provider = .vertexai
        } else {
            provider = .codex
        }

        var totalCostUSD: Double = 0.0
        let fetcher = CostUsageFetcher()
        if let snapshot = try? await fetcher.loadTokenSnapshot(provider: provider) {
            totalCostUSD = snapshot.last30DaysCostUSD ?? 0.0
        }

        return AgentTokenUsageResponse(
            inputTokens: totalPrompt,
            outputTokens: totalCompletion,
            cachedTokens: totalCachedInput,
            cacheCreationTokens: totalCacheCreationInput,
            reasoningTokens: totalReasoning,
            totalCostUSD: totalCostUSD
        )
    }

    func persistTokenUsageForTest(channelId: String, usage: TokenUsage) async {
        await store.persistTokenUsage(channelId: channelId, taskId: nil, usage: usage)
    }

    func overrideModelProviderForTests(_ modelProvider: (any ModelProvider)?, defaultModel: String?) async {
        self.modelProvider = modelProvider
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
    }

    func modelProviderSupportsForTests(_ modelName: String) -> Bool {
        modelProvider?.supports(modelName: modelName) == true
    }

    func triggerHeartbeatRunnerForTests() async {
        await heartbeatRunner?.triggerImmediately()
    }

    func heartbeatRunnerRunningForTests() async -> Bool {
        await heartbeatRunner?.running() ?? false
    }

    func listHeartbeatSchedules() async -> [AgentHeartbeatSchedule] {
        do {
            let agents = try listAgents()
            var schedules: [AgentHeartbeatSchedule] = []
            schedules.reserveCapacity(agents.count)

            for agent in agents {
                let config = try getAgentConfig(agentID: agent.id)
                guard config.heartbeat.enabled else {
                    continue
                }
                schedules.append(
                    AgentHeartbeatSchedule(
                        agentId: agent.id,
                        intervalMinutes: config.heartbeat.intervalMinutes,
                        lastRunAt: config.heartbeatStatus.lastRunAt
                    )
                )
            }
            return schedules
        } catch {
            logger.warning("Failed to load heartbeat schedules: \(error)")
            return []
        }
    }

    func runAgentHeartbeat(agentID: String) async {
        await waitForStartup()

        do {
            let config = try getAgentConfig(agentID: agentID)
            guard config.heartbeat.enabled else {
                return
            }

            let now = Date()
            var status = config.heartbeatStatus
            status.lastRunAt = now
            status.lastErrorMessage = nil

            let heartbeatMarkdown = config.documents.heartbeatMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if heartbeatMarkdown.isEmpty {
                status.lastSuccessAt = now
                status.lastResult = "ok_empty"
                status.lastSessionId = nil
                try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
                return
            }

            let session = try await createAgentSession(
                agentID: agentID,
                request: AgentSessionCreateRequest(
                    title: heartbeatSessionTitle(date: now),
                    kind: .heartbeat
                )
            )
            status.lastSessionId = session.id
            try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)

            let response = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: "system_heartbeat",
                    content: heartbeatPrompt(markdown: config.documents.heartbeatMarkdown)
                )
            )

            let assistantText = latestAssistantText(from: response.appendedEvents)
            let latestRunStatus = response.appendedEvents.reversed().first(where: { $0.type == .runStatus })?.runStatus
            let trimmedAssistantText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)

            if latestRunStatus?.stage != .interrupted && trimmedAssistantText == Self.heartbeatSuccessToken {
                status.lastSuccessAt = now
                status.lastResult = "ok"
                status.lastErrorMessage = nil
                try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
                return
            }

            let failureMessage = heartbeatFailureMessage(
                assistantText: trimmedAssistantText,
                runStatus: latestRunStatus
            )
            status.lastFailureAt = now
            status.lastResult = "failed"
            status.lastErrorMessage = failureMessage
            try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
            await notifyHeartbeatFailure(agentID: agentID, message: failureMessage)
        } catch {
            let now = Date()
            let message = "Heartbeat failed: \(error)"

            do {
                var status = try agentCatalogStore.getHeartbeatStatus(agentID: agentID)
                status.lastRunAt = now
                status.lastFailureAt = now
                status.lastResult = "failed"
                status.lastErrorMessage = message
                try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
            } catch {
                logger.warning("Failed to persist heartbeat error for agent \(agentID): \(error)")
            }

            await notifyHeartbeatFailure(agentID: agentID, message: message)
        }
    }

    /// Returns available tool catalog entries.
    func heartbeatSessionTitle(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Heartbeat \(formatter.string(from: date))"
    }

    func heartbeatPrompt(markdown: String) -> String {
        """
        [heartbeat_v1]
        Review the HEARTBEAT.md checklist below.

        Rules:
        - If every requested item is already completed, verified, or there is nothing actionable, respond with exactly \(Self.heartbeatSuccessToken)
        - If anything is missing, failed, blocked, or cannot be verified, respond with one short plain-text problem description
        - Do not return markdown fences
        - Do not include any extra commentary when returning \(Self.heartbeatSuccessToken)

        [HEARTBEAT.md]
        \(markdown)
        """
    }

    func latestAssistantText(from events: [AgentSessionEvent]) -> String {
        for event in events.reversed() {
            guard event.type == .message, let message = event.message, message.role == .assistant else {
                continue
            }
            return plainText(from: message)
        }
        return ""
    }

    func plainText(from message: AgentSessionMessage) -> String {
        message.segments.compactMap { segment in
            switch segment.kind {
            case .text, .thinking:
                return segment.text
            case .attachment:
                return nil
            }
        }.joined(separator: "\n")
    }

    func heartbeatFailureMessage(
        assistantText: String,
        runStatus: AgentRunStatusEvent?
    ) -> String {
        if let runStatus, runStatus.stage == .interrupted {
            let details = normalizeWhitespace(runStatus.details ?? "")
            if !details.isEmpty {
                return details
            }
        }

        let normalizedAssistant = normalizeWhitespace(assistantText)
        if !normalizedAssistant.isEmpty {
            return normalizedAssistant
        }

        return "Heartbeat did not return \(Self.heartbeatSuccessToken)."
    }

    func notifyHeartbeatFailure(agentID: String, message: String) async {
        let notification = "HEARTBEAT failed for agent \(agentID): \(message)"
        if let channelID = heartbeatNotificationChannelID(agentID: agentID) {
            await runtime.appendSystemMessage(channelId: channelID, content: notification)
            await deliverToChannelPlugin(channelId: channelID, content: notification)
            return
        }

        logger.warning("\(notification)")
    }

    func heartbeatNotificationChannelID(agentID: String) -> String? {
        guard let board = try? getActorBoard() else {
            return nil
        }

        return board.nodes
            .filter { normalizeWhitespace($0.linkedAgentId ?? "") == agentID }
            .sorted(by: { $0.createdAt < $1.createdAt })
            .compactMap { node in
                let channelID = normalizeWhitespace(node.channelId ?? "")
                return channelID.isEmpty ? nil : channelID
            }
            .first
    }

    func allAgentMemoryEntries(agentID: String) async -> [MemoryEntry] {
        let entries = await memoryStore.entries(filter: .default)
        return entries
            .filter { belongsToAgentMemory($0, agentID: agentID) }
            .filter { $0.memoryClass != .bulletin }
            .sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.id.localizedCaseInsensitiveCompare(right.id) == .orderedAscending
                }
                return left.createdAt > right.createdAt
            }
    }

    func allProjectMemoryEntries(projectID: String) async -> [MemoryEntry] {
        let entries = await memoryStore.entries(filter: .default)
        return entries
            .filter { belongsToProjectMemory($0, projectID: projectID) }
            .sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.id.localizedCaseInsensitiveCompare(right.id) == .orderedAscending
                }
                return left.createdAt > right.createdAt
            }
    }

    func matchingAgentMemoryEntries(
        agentID: String,
        search: String?,
        filter: AgentMemoryFilter
    ) async -> [MemoryEntry] {
        filterAgentMemoryEntries(await allAgentMemoryEntries(agentID: agentID), search: search, filter: filter)
    }

    func filterAgentMemoryEntries(
        _ entries: [MemoryEntry],
        search: String?,
        filter: AgentMemoryFilter
    ) -> [MemoryEntry] {
        let normalizedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        return entries.filter { entry in
            guard matchesAgentMemoryFilter(entry, filter: filter) else {
                return false
            }

            guard !normalizedSearch.isEmpty else {
                return true
            }

            return entry.id.lowercased().contains(normalizedSearch) ||
                entry.note.lowercased().contains(normalizedSearch) ||
                (entry.summary?.lowercased().contains(normalizedSearch) ?? false)
        }
    }

    func belongsToAgentMemory(_ entry: MemoryEntry, agentID: String) -> Bool {
        if entry.scope.type == .agent, entry.scope.id.caseInsensitiveCompare(agentID) == .orderedSame {
            return true
        }

        guard entry.scope.type == .channel else {
            return false
        }

        let channelID = entry.scope.channelId ?? entry.scope.id
        return channelID.hasPrefix("agent:\(agentID):session:")
    }

    func belongsToProjectMemory(_ entry: MemoryEntry, projectID: String) -> Bool {
        if entry.scope.type == .project, entry.scope.id.caseInsensitiveCompare(projectID) == .orderedSame {
            return true
        }
        if let scopeProjectID = entry.scope.projectId, scopeProjectID.caseInsensitiveCompare(projectID) == .orderedSame {
            return true
        }
        return false
    }

    func matchesAgentMemoryFilter(_ entry: MemoryEntry, filter: AgentMemoryFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .persistent:
            return derivedCategory(for: entry) == .persistent
        case .temporary:
            return derivedCategory(for: entry) == .temporary
        case .todo:
            return derivedCategory(for: entry) == .todo
        }
    }

    func derivedCategory(for entry: MemoryEntry) -> AgentMemoryCategory {
        if entry.kind == .todo {
            return .todo
        }

        switch entry.memoryClass {
        case .semantic, .procedural:
            return .persistent
        case .episodic, .bulletin:
            return .temporary
        }
    }

    func makeAgentMemoryItem(from entry: MemoryEntry) -> AgentMemoryItem {
        AgentMemoryItem(
            id: entry.id,
            note: entry.note,
            summary: entry.summary,
            kind: entry.kind,
            memoryClass: entry.memoryClass,
            scope: entry.scope,
            source: entry.source,
            importance: entry.importance,
            confidence: entry.confidence,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            expiresAt: entry.expiresAt,
            derivedCategory: derivedCategory(for: entry)
        )
    }

    func mapSessionStoreError(_ error: Error) -> AgentSessionError {
        guard let storeError = error as? AgentSessionFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidSessionID:
            return .invalidSessionID
        case .agentNotFound:
            return .agentNotFound
        case .sessionNotFound, .sessionFileNotFound, .sessionEventsEmpty:
            return .sessionNotFound
        case .invalidPayload:
            return .invalidPayload
        }
    }

    func mapSessionOrchestratorError(_ error: Error) -> AgentSessionError {
        guard let orchestratorError = error as? AgentSessionOrchestrator.OrchestratorError else {
            return .storageFailure
        }

        switch orchestratorError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidSessionID:
            return .invalidSessionID
        case .invalidPayload:
            return .invalidPayload
        case .agentNotFound:
            return .agentNotFound
        case .sessionNotFound:
            return .sessionNotFound
        case .storageFailure:
            return .storageFailure
        }
    }

}
