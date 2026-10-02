import AgentRuntime
import Foundation
import Protocols
import SloppyNodeCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol SloppyTUIBackend: Sendable {
    var isRemote: Bool { get }
    var displayName: String { get }

    func waitForStartup() async
    func shutdown() async
    func shutdownChannelPlugins() async
    func listChannelPlugins() async -> [ChannelPluginRecord]
    func getConfig() async -> CoreConfig
    func updateConfig(_ config: CoreConfig) async throws -> CoreConfig
    func listProjects() async throws -> [ProjectRecord]
    func getProject(id: String) async throws -> ProjectRecord
    func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord
    func getActorBoard() async throws -> ActorBoardSnapshot
    func resolveOrCreateProjectForCurrentDirectory(_ cwd: String) async throws -> ProjectRecord
    func resolveProjectWorkspaceRoot(projectID: String) async throws -> URL
    func listAgents(includeSystem: Bool) async throws -> [AgentSummary]
    func createAgent(_ request: AgentCreateRequest) async throws -> AgentSummary
    func getAgentConfig(agentID: String) async throws -> AgentConfigDetail
    func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) async throws -> AgentConfigDetail
    func buildAgentChatSlashCommands(agentID: String) async throws -> AgentChatSlashCommandsResponse
    func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse
    func listAgentSessions(agentID: String, projectID: String?, limit: Int?, offset: Int?) async throws -> [AgentSessionSummary]
    func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary
    func prepareAgentSessionContext(agentID: String, sessionID: String) async throws -> AgentSessionSummary
    func getAgentSession(agentID: String, sessionID: String) async throws -> AgentSessionDetail
    func deleteAgentSession(agentID: String, sessionID: String) async throws
    func postAgentSessionMessage(agentID: String, sessionID: String, request: AgentSessionPostMessageRequest) async throws -> AgentSessionMessageResponse
    func startAgentSessionGoal(agentID: String, sessionID: String, request: AgentSessionGoalStartRequest) async throws -> AgentSessionGoalRecord
    func getAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord?
    func pauseAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord?
    func resumeAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord?
    func clearAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord?
    func addAgentSessionDirectory(agentID: String, sessionID: String, request: AgentSessionDirectoryRequest) async throws -> AgentSessionDirectoryResponse
    func controlAgentSession(agentID: String, sessionID: String, request: AgentSessionControlRequest) async throws -> AgentSessionMessageResponse
    func answerAgentPlanInput(agentID: String, sessionID: String, requestID: String, payload: PlanInputAnswerRequest) async throws -> AgentSessionMessageResponse
    func listPendingToolApprovals() async throws -> [ToolApprovalRecord]
    func approveToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord
    func rejectToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord
    func streamAgentSessionEvents(agentID: String, sessionID: String) async throws -> AsyncStream<AgentSessionStreamUpdate>
    func streamProjectWorkingTreeChanges(projectID: String) async throws -> AsyncStream<ProjectWorkingTreeChangeBatch>
    func projectWorkingTreeSourceControl(projectID: String) async throws -> ProjectWorkingTreeSourceControlResponse
    func createTUIBackgroundWorktree(projectID: String, taskID: String) async throws -> SourceControlWorktreeResult
    func startTUIBackgroundSession(agentID: String, projectID: String, task: String, mode: AgentChatMode?, reasoningEffort: ReasoningEffort?) async throws -> CoreService.TUIBackgroundSessionStartResult
    func searchProjectFiles(projectID: String, query: String, limit: Int) async throws -> [ProjectFileSearchEntry]
    func readProjectFile(projectID: String, path: String) async throws -> ProjectFileContentResponse
    func listMCPServerStatuses() async -> [MCPServerStatus]
    func getAgentTokenUsage(agentID: String) async throws -> AgentTokenUsageResponse
    func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> TokenUsageResponse
    func contextLedgerSnapshot(channelId: String) async -> ContextLedgerSnapshot?
    func hasLiveAgentRuntimeSession(agentID: String, sessionID: String) async -> Bool
    func requestAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String?) async throws -> AgentMemoryCheckpointResponse
    func probeProvider(request: ProviderProbeRequest) async -> ProviderProbeResponse
    func startOpenAIDeviceCode() async throws -> OpenAIDeviceCodeStartResponse
    func pollOpenAIDeviceCode(request: OpenAIDeviceCodePollRequest) async throws -> OpenAIDeviceCodePollResponse
    func startAnthropicOAuth(request: AnthropicOAuthStartRequest) async throws -> AnthropicOAuthStartResponse
    func completeAnthropicOAuth(request: AnthropicOAuthCompleteRequest) async throws -> AnthropicOAuthCompleteResponse
}

enum SloppyTUIBackendError: Error, LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let message):
            return message
        }
    }
}

extension SloppyTUIBackend {
    func listAgentSessions(agentID: String) async throws -> [AgentSessionSummary] {
        try await listAgentSessions(agentID: agentID, projectID: nil, limit: nil, offset: nil)
    }

    func listAgentSessions(agentID: String, projectID: String) async throws -> [AgentSessionSummary] {
        try await listAgentSessions(agentID: agentID, projectID: projectID, limit: nil, offset: nil)
    }

    func listAgentSessions(agentID: String, limit: Int) async throws -> [AgentSessionSummary] {
        try await listAgentSessions(agentID: agentID, projectID: nil, limit: limit, offset: nil)
    }

    func listAgentSessions(agentID: String, projectID: String, limit: Int) async throws -> [AgentSessionSummary] {
        try await listAgentSessions(agentID: agentID, projectID: projectID, limit: limit, offset: nil)
    }

    func listTokenUsage(channelId: String?) async -> TokenUsageResponse {
        await listTokenUsage(channelId: channelId, taskId: nil, from: nil, to: nil)
    }
}

struct LocalSloppyTUIBackend: SloppyTUIBackend {
    let service: CoreService

    var isRemote: Bool { false }
    var displayName: String { "Local" }

    func waitForStartup() async { await service.waitForStartup() }
    func shutdown() async { await service.shutdownChannelPlugins() }
    func shutdownChannelPlugins() async { await service.shutdownChannelPlugins() }
    func listChannelPlugins() async -> [ChannelPluginRecord] { await service.listChannelPlugins() }
    func getConfig() async -> CoreConfig { await service.getConfig() }
    func updateConfig(_ config: CoreConfig) async throws -> CoreConfig { try await service.updateConfig(config) }
    func listProjects() async throws -> [ProjectRecord] { await service.listProjects() }
    func getProject(id: String) async throws -> ProjectRecord { try await service.getProject(id: id) }
    func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        try await service.createProjectTask(projectID: projectID, request: request)
    }
    func getActorBoard() async throws -> ActorBoardSnapshot { try await service.getActorBoard() }
    func resolveOrCreateProjectForCurrentDirectory(_ cwd: String) async throws -> ProjectRecord {
        try await service.resolveOrCreateProjectForCurrentDirectory(cwd)
    }
    func resolveProjectWorkspaceRoot(projectID: String) async throws -> URL {
        try await service.resolveProjectWorkspaceRoot(projectID: projectID)
    }
    func listAgents(includeSystem: Bool) async throws -> [AgentSummary] {
        try await service.listAgents(includeSystem: includeSystem)
    }
    func createAgent(_ request: AgentCreateRequest) async throws -> AgentSummary {
        try await service.createAgent(request)
    }
    func getAgentConfig(agentID: String) async throws -> AgentConfigDetail {
        try await service.getAgentConfig(agentID: agentID)
    }
    func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) async throws -> AgentConfigDetail {
        try await service.updateAgentConfig(agentID: agentID, request: request)
    }
    func buildAgentChatSlashCommands(agentID: String) async throws -> AgentChatSlashCommandsResponse {
        try await service.buildAgentChatSlashCommands(agentID: agentID)
    }
    func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse {
        try await service.listAgentSkills(agentID: agentID)
    }
    func listAgentSessions(agentID: String, projectID: String?, limit: Int?, offset: Int?) async throws -> [AgentSessionSummary] {
        try await service.listAgentSessions(agentID: agentID, projectID: projectID, limit: limit, offset: offset ?? 0)
    }
    func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        try await service.createAgentSession(agentID: agentID, request: request)
    }
    func prepareAgentSessionContext(agentID: String, sessionID: String) async throws -> AgentSessionSummary {
        try await service.prepareAgentSessionContext(agentID: agentID, sessionID: sessionID)
    }
    func getAgentSession(agentID: String, sessionID: String) async throws -> AgentSessionDetail {
        try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
    }
    func deleteAgentSession(agentID: String, sessionID: String) async throws {
        try await service.deleteAgentSession(agentID: agentID, sessionID: sessionID)
    }
    func postAgentSessionMessage(agentID: String, sessionID: String, request: AgentSessionPostMessageRequest) async throws -> AgentSessionMessageResponse {
        try await service.postAgentSessionMessage(agentID: agentID, sessionID: sessionID, request: request)
    }
    func startAgentSessionGoal(agentID: String, sessionID: String, request: AgentSessionGoalStartRequest) async throws -> AgentSessionGoalRecord {
        try await service.startAgentSessionGoal(agentID: agentID, sessionID: sessionID, request: request)
    }
    func getAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await service.getAgentSessionGoal(agentID: agentID, sessionID: sessionID)
    }
    func pauseAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await service.pauseAgentSessionGoal(agentID: agentID, sessionID: sessionID)
    }
    func resumeAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await service.resumeAgentSessionGoal(agentID: agentID, sessionID: sessionID)
    }
    func clearAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await service.clearAgentSessionGoal(agentID: agentID, sessionID: sessionID)
    }
    func addAgentSessionDirectory(agentID: String, sessionID: String, request: AgentSessionDirectoryRequest) async throws -> AgentSessionDirectoryResponse {
        try await service.addAgentSessionDirectory(agentID: agentID, sessionID: sessionID, request: request)
    }
    func controlAgentSession(agentID: String, sessionID: String, request: AgentSessionControlRequest) async throws -> AgentSessionMessageResponse {
        try await service.controlAgentSession(agentID: agentID, sessionID: sessionID, request: request)
    }
    func answerAgentPlanInput(agentID: String, sessionID: String, requestID: String, payload: PlanInputAnswerRequest) async throws -> AgentSessionMessageResponse {
        try await service.answerAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: requestID, payload: payload)
    }
    func listPendingToolApprovals() async throws -> [ToolApprovalRecord] {
        await service.listPendingToolApprovals()
    }
    func approveToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord {
        guard let record = await service.approveToolApproval(
            id: id,
            decidedBy: request.decidedBy,
            scope: request.scope
        ) else {
            throw SloppyTUIBackendError.notFound("Tool approval not found.")
        }
        return record
    }
    func rejectToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord {
        guard let record = await service.rejectToolApproval(id: id, decidedBy: request.decidedBy) else {
            throw SloppyTUIBackendError.notFound("Tool approval not found.")
        }
        return record
    }
    func streamAgentSessionEvents(agentID: String, sessionID: String) async throws -> AsyncStream<AgentSessionStreamUpdate> {
        try await service.streamAgentSessionEvents(agentID: agentID, sessionID: sessionID)
    }
    func streamProjectWorkingTreeChanges(projectID: String) async throws -> AsyncStream<ProjectWorkingTreeChangeBatch> {
        try await service.streamProjectWorkingTreeChanges(projectID: projectID)
    }
    func projectWorkingTreeSourceControl(projectID: String) async throws -> ProjectWorkingTreeSourceControlResponse {
        try await service.projectWorkingTreeSourceControl(projectID: projectID)
    }
    func createTUIBackgroundWorktree(projectID: String, taskID: String) async throws -> SourceControlWorktreeResult {
        try await service.createTUIBackgroundWorktree(projectID: projectID, taskID: taskID)
    }
    func startTUIBackgroundSession(agentID: String, projectID: String, task: String, mode: AgentChatMode?, reasoningEffort: ReasoningEffort?) async throws -> CoreService.TUIBackgroundSessionStartResult {
        try await service.startTUIBackgroundSession(
            agentID: agentID,
            projectID: projectID,
            task: task,
            mode: mode,
            reasoningEffort: reasoningEffort
        )
    }
    func searchProjectFiles(projectID: String, query: String, limit: Int) async throws -> [ProjectFileSearchEntry] {
        try await service.searchProjectFiles(projectID: projectID, query: query, limit: limit)
    }
    func readProjectFile(projectID: String, path: String) async throws -> ProjectFileContentResponse {
        try await service.readProjectFile(projectID: projectID, path: path)
    }
    func listMCPServerStatuses() async -> [MCPServerStatus] { await service.listMCPServerStatuses() }
    func getAgentTokenUsage(agentID: String) async throws -> AgentTokenUsageResponse {
        try await service.getAgentTokenUsage(agentID: agentID)
    }
    func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> TokenUsageResponse {
        await service.listTokenUsage(channelId: channelId, taskId: taskId, from: from, to: to)
    }
    func contextLedgerSnapshot(channelId: String) async -> ContextLedgerSnapshot? {
        await service.runtime.contextLedgerSnapshot(channelId: channelId)
    }
    func hasLiveAgentRuntimeSession(agentID: String, sessionID: String) async -> Bool {
        (try? await service.hasLiveAgentRuntimeSession(agentID: agentID, sessionID: sessionID)) ?? false
    }
    func requestAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String?) async throws -> AgentMemoryCheckpointResponse {
        try await service.requestAgentMemoryCheckpoint(agentID: agentID, sessionID: sessionID, reason: reason)
    }
    func probeProvider(request: ProviderProbeRequest) async -> ProviderProbeResponse {
        await service.probeProvider(request: request)
    }
    func startOpenAIDeviceCode() async throws -> OpenAIDeviceCodeStartResponse {
        try await service.startOpenAIDeviceCode()
    }
    func pollOpenAIDeviceCode(request: OpenAIDeviceCodePollRequest) async throws -> OpenAIDeviceCodePollResponse {
        try await service.pollOpenAIDeviceCode(request: request)
    }
    func startAnthropicOAuth(request: AnthropicOAuthStartRequest) async throws -> AnthropicOAuthStartResponse {
        try await service.startAnthropicOAuth(request: request)
    }
    func completeAnthropicOAuth(request: AnthropicOAuthCompleteRequest) async throws -> AnthropicOAuthCompleteResponse {
        try await service.completeAnthropicOAuth(request: request)
    }
}

enum RemoteSloppyTUIBackendError: Error, LocalizedError {
    case missingProject
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingProject:
            return "Select a remote project before using this action."
        case .unsupported(let action):
            return "\(action) is not available for remote Sloppy instances yet."
        }
    }
}

struct RemoteSloppyTUIBackend: SloppyTUIBackend {
    let client: SloppyCLIClient
    let node: CoreConfig.Node
    let projectID: String?
    let environment: [String: String]

    var isRemote: Bool { true }
    var displayName: String { node.displayTitle }

    init(node: CoreConfig.Node, projectID: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.node = node
        self.projectID = projectID
        self.environment = environment
        let token = node.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? environment[node.tokenEnv]?.trimmingCharacters(in: .whitespacesAndNewlines)
            : node.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = node.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let localAuth = token?.isEmpty == false ? nil : SloppyCLILocalAuthStore.load(baseURL: baseURL)
        self.client = SloppyCLIClient(
            baseURL: baseURL,
            token: token?.isEmpty == false ? token! : localAuth?.accessToken ?? "dev-token",
            verbose: false,
            localAuthSession: localAuth
        )
    }

    func waitForStartup() async {}
    func shutdown() async {}
    func shutdownChannelPlugins() async {}
    func listChannelPlugins() async -> [ChannelPluginRecord] { [] }
    func getConfig() async -> CoreConfig { (try? await get("/v1/config", as: CoreConfig.self)) ?? .default }
    func updateConfig(_ config: CoreConfig) async throws -> CoreConfig {
        try await put("/v1/config", body: config, as: CoreConfig.self)
    }
    func listProjects() async throws -> [ProjectRecord] { try await get("/v1/projects", as: [ProjectRecord].self) }
    func getProject(id: String) async throws -> ProjectRecord { try await get("/v1/projects/\(Self.escape(id))", as: ProjectRecord.self) }
    func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        try await post("/v1/projects/\(Self.escape(projectID))/tasks", body: request, as: ProjectRecord.self)
    }
    func getActorBoard() async throws -> ActorBoardSnapshot { try await get("/v1/actors/board", as: ActorBoardSnapshot.self) }
    func resolveOrCreateProjectForCurrentDirectory(_ cwd: String) async throws -> ProjectRecord {
        guard let projectID else { throw RemoteSloppyTUIBackendError.missingProject }
        return try await getProject(id: projectID)
    }
    func resolveProjectWorkspaceRoot(projectID: String) async throws -> URL {
        URL(fileURLWithPath: "/remote/\(projectID)", isDirectory: true)
    }
    func listAgents(includeSystem: Bool) async throws -> [AgentSummary] {
        try await get("/v1/agents", query: ["includeSystem": includeSystem ? "true" : "false"], as: [AgentSummary].self)
    }
    func createAgent(_ request: AgentCreateRequest) async throws -> AgentSummary {
        try await post("/v1/agents", body: request, as: AgentSummary.self)
    }
    func getAgentConfig(agentID: String) async throws -> AgentConfigDetail {
        try await get("/v1/agents/\(Self.escape(agentID))/config", as: AgentConfigDetail.self)
    }
    func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) async throws -> AgentConfigDetail {
        try await put("/v1/agents/\(Self.escape(agentID))/config", body: request, as: AgentConfigDetail.self)
    }
    func buildAgentChatSlashCommands(agentID: String) async throws -> AgentChatSlashCommandsResponse {
        try await get("/v1/agents/\(Self.escape(agentID))/chat-slash-commands", as: AgentChatSlashCommandsResponse.self)
    }
    func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse {
        try await get("/v1/agents/\(Self.escape(agentID))/skills", as: AgentSkillsResponse.self)
    }
    func listAgentSessions(agentID: String, projectID: String?, limit: Int?, offset: Int?) async throws -> [AgentSessionSummary] {
        var query: [String: String] = [:]
        if let projectID { query["projectId"] = projectID }
        if let limit { query["limit"] = String(limit) }
        if let offset { query["offset"] = String(offset) }
        return try await get("/v1/agents/\(Self.escape(agentID))/sessions", query: query, as: [AgentSessionSummary].self)
    }
    func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        var request = request
        request.separateChat = true
        return try await post("/v1/agents/\(Self.escape(agentID))/sessions", body: request, as: AgentSessionSummary.self)
    }
    func prepareAgentSessionContext(agentID: String, sessionID: String) async throws -> AgentSessionSummary {
        try await postEmpty("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/context", as: AgentSessionSummary.self)
    }
    func getAgentSession(agentID: String, sessionID: String) async throws -> AgentSessionDetail {
        try await get("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))", as: AgentSessionDetail.self)
    }
    func deleteAgentSession(agentID: String, sessionID: String) async throws {
        _ = try await client.delete("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))")
    }
    func postAgentSessionMessage(agentID: String, sessionID: String, request: AgentSessionPostMessageRequest) async throws -> AgentSessionMessageResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/messages", body: request, as: AgentSessionMessageResponse.self)
    }
    func startAgentSessionGoal(agentID: String, sessionID: String, request: AgentSessionGoalStartRequest) async throws -> AgentSessionGoalRecord {
        throw RemoteSloppyTUIBackendError.unsupported("/goal")
    }
    func getAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        throw RemoteSloppyTUIBackendError.unsupported("/goal")
    }
    func pauseAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        throw RemoteSloppyTUIBackendError.unsupported("/goal")
    }
    func resumeAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        throw RemoteSloppyTUIBackendError.unsupported("/goal")
    }
    func clearAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        throw RemoteSloppyTUIBackendError.unsupported("/goal")
    }
    func addAgentSessionDirectory(agentID: String, sessionID: String, request: AgentSessionDirectoryRequest) async throws -> AgentSessionDirectoryResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/directories", body: request, as: AgentSessionDirectoryResponse.self)
    }
    func controlAgentSession(agentID: String, sessionID: String, request: AgentSessionControlRequest) async throws -> AgentSessionMessageResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/control", body: request, as: AgentSessionMessageResponse.self)
    }
    func answerAgentPlanInput(agentID: String, sessionID: String, requestID: String, payload: PlanInputAnswerRequest) async throws -> AgentSessionMessageResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/input-requests/\(Self.escape(requestID))/answer", body: payload, as: AgentSessionMessageResponse.self)
    }
    func listPendingToolApprovals() async throws -> [ToolApprovalRecord] {
        try await get("/v1/tool-approvals/pending", as: [ToolApprovalRecord].self)
    }
    func approveToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord {
        try await post("/v1/tool-approvals/\(Self.escape(id))/approve", body: request, as: ToolApprovalRecord.self)
    }
    func rejectToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord {
        try await post("/v1/tool-approvals/\(Self.escape(id))/reject", body: request, as: ToolApprovalRecord.self)
    }
    func streamAgentSessionEvents(agentID: String, sessionID: String) async throws -> AsyncStream<AgentSessionStreamUpdate> {
        stream(path: "/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/stream", as: AgentSessionStreamUpdate.self)
    }
    func streamProjectWorkingTreeChanges(projectID: String) async throws -> AsyncStream<ProjectWorkingTreeChangeBatch> {
        stream(path: "/v1/projects/\(Self.escape(projectID))/changes/stream", as: ProjectWorkingTreeChangeBatch.self)
    }
    func projectWorkingTreeSourceControl(projectID: String) async throws -> ProjectWorkingTreeSourceControlResponse {
        try await get("/v1/projects/\(Self.escape(projectID))/source-control/working-tree", as: ProjectWorkingTreeSourceControlResponse.self)
    }
    func createTUIBackgroundWorktree(projectID: String, taskID: String) async throws -> SourceControlWorktreeResult {
        throw RemoteSloppyTUIBackendError.unsupported("/bg worktree sessions")
    }
    func startTUIBackgroundSession(agentID: String, projectID: String, task: String, mode: AgentChatMode?, reasoningEffort: ReasoningEffort?) async throws -> CoreService.TUIBackgroundSessionStartResult {
        throw RemoteSloppyTUIBackendError.unsupported("/bg sessions")
    }
    func searchProjectFiles(projectID: String, query: String, limit: Int) async throws -> [ProjectFileSearchEntry] {
        try await get("/v1/projects/\(Self.escape(projectID))/files/search", query: ["q": query, "limit": String(limit)], as: [ProjectFileSearchEntry].self)
    }
    func readProjectFile(projectID: String, path: String) async throws -> ProjectFileContentResponse {
        try await get("/v1/projects/\(Self.escape(projectID))/files/content", query: ["path": path], as: ProjectFileContentResponse.self)
    }
    func listMCPServerStatuses() async -> [MCPServerStatus] { [] }
    func getAgentTokenUsage(agentID: String) async throws -> AgentTokenUsageResponse {
        try await get("/v1/agents/\(Self.escape(agentID))/token-usage", as: AgentTokenUsageResponse.self)
    }
    func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> TokenUsageResponse {
        var query: [String: String] = [:]
        if let channelId { query["channelId"] = channelId }
        if let taskId { query["taskId"] = taskId }
        return (try? await get("/v1/token-usage", query: query, as: TokenUsageResponse.self)) ?? TokenUsageResponse(items: [])
    }
    func contextLedgerSnapshot(channelId: String) async -> ContextLedgerSnapshot? {
        nil
    }
    func hasLiveAgentRuntimeSession(agentID: String, sessionID: String) async -> Bool { false }
    func requestAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String?) async throws -> AgentMemoryCheckpointResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/checkpoint", body: AgentMemoryCheckpointRequest(reason: reason), as: AgentMemoryCheckpointResponse.self)
    }
    func probeProvider(request: ProviderProbeRequest) async -> ProviderProbeResponse {
        (try? await post("/v1/providers/probe", body: request, as: ProviderProbeResponse.self))
            ?? ProviderProbeResponse(providerId: request.providerId, ok: false, usedEnvironmentKey: false, message: "Remote probe failed", models: [])
    }
    func startOpenAIDeviceCode() async throws -> OpenAIDeviceCodeStartResponse {
        try await postEmpty("/v1/providers/openai/oauth/device-code/start", as: OpenAIDeviceCodeStartResponse.self)
    }
    func pollOpenAIDeviceCode(request: OpenAIDeviceCodePollRequest) async throws -> OpenAIDeviceCodePollResponse {
        try await post("/v1/providers/openai/oauth/device-code/poll", body: request, as: OpenAIDeviceCodePollResponse.self)
    }
    func startAnthropicOAuth(request: AnthropicOAuthStartRequest) async throws -> AnthropicOAuthStartResponse {
        try await post("/v1/providers/anthropic/oauth/start", body: request, as: AnthropicOAuthStartResponse.self)
    }
    func completeAnthropicOAuth(request: AnthropicOAuthCompleteRequest) async throws -> AnthropicOAuthCompleteResponse {
        try await post("/v1/providers/anthropic/oauth/complete", body: request, as: AnthropicOAuthCompleteResponse.self)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T {
        try decode(try await client.get(path, query: query), as: type)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        try decode(try await client.post(path, body: try client.encode(body)), as: type)
    }

    private func postEmpty<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try decode(try await client.post(path), as: type)
    }

    private func put<T: Decodable, Body: Encodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        try decode(try await client.put(path, body: try client.encode(body)), as: type)
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func stream<T: Decodable & Sendable>(path: String, as type: T.Type) -> AsyncStream<T> {
        AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let task = Task {
                guard let url = URL(string: client.baseURL + path) else {
                    continuation.finish()
                    return
                }
                var request = URLRequest(url: url, timeoutInterval: 60 * 60)
                request.setValue("Bearer \(client.token)", forHTTPHeaderField: "Authorization")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    let (lines, response) = try await SloppyTUILineStream.open(request: request)
                    guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else {
                        continuation.finish()
                        return
                    }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    for try await line in lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        guard let data = payload.data(using: .utf8),
                              let value = try? decoder.decode(type, from: data)
                        else { continue }
                        continuation.yield(value)
                    }
                } catch {
                    continuation.finish()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func escape(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }
}

struct MeshSloppyTUIBackend: SloppyTUIBackend {
    let service: CoreService
    let node: MeshNodeRecord
    let projectID: String?

    var isRemote: Bool { true }
    var displayName: String { node.name.isEmpty ? node.id : node.name }

    init(service: CoreService, node: MeshNodeRecord, projectID: String? = nil) {
        self.service = service
        self.node = node
        self.projectID = projectID
    }

    func waitForStartup() async {}
    func shutdown() async {}
    func shutdownChannelPlugins() async {}
    func listChannelPlugins() async -> [ChannelPluginRecord] { [] }
    func getConfig() async -> CoreConfig { (try? await get("/v1/config", as: CoreConfig.self)) ?? .default }
    func updateConfig(_ config: CoreConfig) async throws -> CoreConfig { try await put("/v1/config", body: config, as: CoreConfig.self) }
    func listProjects() async throws -> [ProjectRecord] { try await get("/v1/projects", as: [ProjectRecord].self) }
    func getProject(id: String) async throws -> ProjectRecord { try await get("/v1/projects/\(Self.escape(id))", as: ProjectRecord.self) }
    func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        try await post("/v1/projects/\(Self.escape(projectID))/tasks", body: request, as: ProjectRecord.self)
    }
    func getActorBoard() async throws -> ActorBoardSnapshot { try await get("/v1/actors/board", as: ActorBoardSnapshot.self) }
    func resolveOrCreateProjectForCurrentDirectory(_ cwd: String) async throws -> ProjectRecord {
        guard let projectID else { throw RemoteSloppyTUIBackendError.missingProject }
        return try await getProject(id: projectID)
    }
    func resolveProjectWorkspaceRoot(projectID: String) async throws -> URL {
        URL(fileURLWithPath: "/mesh/\(node.id)/\(projectID)", isDirectory: true)
    }
    func listAgents(includeSystem: Bool) async throws -> [AgentSummary] {
        try await get("/v1/agents", query: ["includeSystem": includeSystem ? "true" : "false"], as: [AgentSummary].self)
    }
    func createAgent(_ request: AgentCreateRequest) async throws -> AgentSummary {
        try await post("/v1/agents", body: request, as: AgentSummary.self)
    }
    func getAgentConfig(agentID: String) async throws -> AgentConfigDetail {
        try await get("/v1/agents/\(Self.escape(agentID))/config", as: AgentConfigDetail.self)
    }
    func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) async throws -> AgentConfigDetail {
        try await put("/v1/agents/\(Self.escape(agentID))/config", body: request, as: AgentConfigDetail.self)
    }
    func buildAgentChatSlashCommands(agentID: String) async throws -> AgentChatSlashCommandsResponse {
        try await get("/v1/agents/\(Self.escape(agentID))/chat-slash-commands", as: AgentChatSlashCommandsResponse.self)
    }
    func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse {
        try await get("/v1/agents/\(Self.escape(agentID))/skills", as: AgentSkillsResponse.self)
    }
    func listAgentSessions(agentID: String, projectID: String?, limit: Int?, offset: Int?) async throws -> [AgentSessionSummary] {
        var query: [String: String] = [:]
        if let projectID { query["projectId"] = projectID }
        if let limit { query["limit"] = String(limit) }
        if let offset { query["offset"] = String(offset) }
        return try await get("/v1/agents/\(Self.escape(agentID))/sessions", query: query, as: [AgentSessionSummary].self)
    }
    func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions", body: request, as: AgentSessionSummary.self)
    }
    func prepareAgentSessionContext(agentID: String, sessionID: String) async throws -> AgentSessionSummary {
        try await postEmpty("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/context", as: AgentSessionSummary.self)
    }
    func getAgentSession(agentID: String, sessionID: String) async throws -> AgentSessionDetail {
        try await get("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))", as: AgentSessionDetail.self)
    }
    func deleteAgentSession(agentID: String, sessionID: String) async throws {
        _ = try await request(method: "DELETE", path: "/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))")
    }
    func postAgentSessionMessage(agentID: String, sessionID: String, request: AgentSessionPostMessageRequest) async throws -> AgentSessionMessageResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/messages", body: request, as: AgentSessionMessageResponse.self)
    }
    func startAgentSessionGoal(agentID: String, sessionID: String, request: AgentSessionGoalStartRequest) async throws -> AgentSessionGoalRecord {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/goal", body: request, as: AgentSessionGoalRecord.self)
    }
    func getAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await get("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/goal", as: AgentSessionGoalRecord?.self)
    }
    func pauseAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await postEmpty("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/goal/pause", as: AgentSessionGoalRecord?.self)
    }
    func resumeAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await postEmpty("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/goal/resume", as: AgentSessionGoalRecord?.self)
    }
    func clearAgentSessionGoal(agentID: String, sessionID: String) async throws -> AgentSessionGoalRecord? {
        try await postEmpty("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/goal/clear", as: AgentSessionGoalRecord?.self)
    }
    func addAgentSessionDirectory(agentID: String, sessionID: String, request: AgentSessionDirectoryRequest) async throws -> AgentSessionDirectoryResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/directories", body: request, as: AgentSessionDirectoryResponse.self)
    }
    func controlAgentSession(agentID: String, sessionID: String, request: AgentSessionControlRequest) async throws -> AgentSessionMessageResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/control", body: request, as: AgentSessionMessageResponse.self)
    }
    func answerAgentPlanInput(agentID: String, sessionID: String, requestID: String, payload: PlanInputAnswerRequest) async throws -> AgentSessionMessageResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/input-requests/\(Self.escape(requestID))/answer", body: payload, as: AgentSessionMessageResponse.self)
    }
    func listPendingToolApprovals() async throws -> [ToolApprovalRecord] {
        try await get("/v1/tool-approvals/pending", as: [ToolApprovalRecord].self)
    }
    func approveToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord {
        try await post("/v1/tool-approvals/\(Self.escape(id))/approve", body: request, as: ToolApprovalRecord.self)
    }
    func rejectToolApproval(id: String, request: ToolApprovalDecisionRequest) async throws -> ToolApprovalRecord {
        try await post("/v1/tool-approvals/\(Self.escape(id))/reject", body: request, as: ToolApprovalRecord.self)
    }
    func streamAgentSessionEvents(agentID: String, sessionID: String) async throws -> AsyncStream<AgentSessionStreamUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let task = Task {
                var seen = Set<String>()
                var cursor = 0
                while !Task.isCancelled {
                    do {
                        let detail = try await getAgentSession(agentID: agentID, sessionID: sessionID)
                        if cursor == 0 {
                            continuation.yield(AgentSessionStreamUpdate(kind: .sessionReady, cursor: cursor, summary: detail.summary))
                            cursor += 1
                        }
                        for event in detail.events where !seen.contains(event.id) {
                            seen.insert(event.id)
                            continuation.yield(AgentSessionStreamUpdate(kind: .sessionEvent, cursor: cursor, event: event))
                            cursor += 1
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        continuation.yield(AgentSessionStreamUpdate(kind: .sessionError, cursor: cursor, message: String(describing: error)))
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func streamProjectWorkingTreeChanges(projectID: String) async throws -> AsyncStream<ProjectWorkingTreeChangeBatch> {
        AsyncStream { continuation in continuation.finish() }
    }
    func projectWorkingTreeSourceControl(projectID: String) async throws -> ProjectWorkingTreeSourceControlResponse {
        try await get("/v1/projects/\(Self.escape(projectID))/source-control/working-tree", as: ProjectWorkingTreeSourceControlResponse.self)
    }
    func createTUIBackgroundWorktree(projectID: String, taskID: String) async throws -> SourceControlWorktreeResult {
        throw RemoteSloppyTUIBackendError.unsupported("/bg worktree sessions")
    }
    func startTUIBackgroundSession(agentID: String, projectID: String, task: String, mode: AgentChatMode?, reasoningEffort: ReasoningEffort?) async throws -> CoreService.TUIBackgroundSessionStartResult {
        throw RemoteSloppyTUIBackendError.unsupported("/bg sessions")
    }
    func searchProjectFiles(projectID: String, query: String, limit: Int) async throws -> [ProjectFileSearchEntry] {
        try await get("/v1/projects/\(Self.escape(projectID))/files/search", query: ["q": query, "limit": String(limit)], as: [ProjectFileSearchEntry].self)
    }
    func readProjectFile(projectID: String, path: String) async throws -> ProjectFileContentResponse {
        try await get("/v1/projects/\(Self.escape(projectID))/files/content", query: ["path": path], as: ProjectFileContentResponse.self)
    }
    func listMCPServerStatuses() async -> [MCPServerStatus] { [] }
    func getAgentTokenUsage(agentID: String) async throws -> AgentTokenUsageResponse {
        try await get("/v1/agents/\(Self.escape(agentID))/token-usage", as: AgentTokenUsageResponse.self)
    }
    func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> TokenUsageResponse {
        var query: [String: String] = [:]
        if let channelId { query["channelId"] = channelId }
        if let taskId { query["taskId"] = taskId }
        return (try? await get("/v1/token-usage", query: query, as: TokenUsageResponse.self)) ?? TokenUsageResponse(items: [])
    }
    func contextLedgerSnapshot(channelId: String) async -> ContextLedgerSnapshot? { nil }
    func hasLiveAgentRuntimeSession(agentID: String, sessionID: String) async -> Bool { false }
    func requestAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String?) async throws -> AgentMemoryCheckpointResponse {
        try await post("/v1/agents/\(Self.escape(agentID))/sessions/\(Self.escape(sessionID))/checkpoint", body: AgentMemoryCheckpointRequest(reason: reason), as: AgentMemoryCheckpointResponse.self)
    }
    func probeProvider(request: ProviderProbeRequest) async -> ProviderProbeResponse {
        (try? await post("/v1/providers/probe", body: request, as: ProviderProbeResponse.self))
            ?? ProviderProbeResponse(providerId: request.providerId, ok: false, usedEnvironmentKey: false, message: "Mesh remote probe failed", models: [])
    }
    func startOpenAIDeviceCode() async throws -> OpenAIDeviceCodeStartResponse {
        try await postEmpty("/v1/providers/openai/oauth/device-code/start", as: OpenAIDeviceCodeStartResponse.self)
    }
    func pollOpenAIDeviceCode(request: OpenAIDeviceCodePollRequest) async throws -> OpenAIDeviceCodePollResponse {
        try await post("/v1/providers/openai/oauth/device-code/poll", body: request, as: OpenAIDeviceCodePollResponse.self)
    }
    func startAnthropicOAuth(request: AnthropicOAuthStartRequest) async throws -> AnthropicOAuthStartResponse {
        try await post("/v1/providers/anthropic/oauth/start", body: request, as: AnthropicOAuthStartResponse.self)
    }
    func completeAnthropicOAuth(request: AnthropicOAuthCompleteRequest) async throws -> AnthropicOAuthCompleteResponse {
        try await post("/v1/providers/anthropic/oauth/complete", body: request, as: AnthropicOAuthCompleteResponse.self)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T {
        try decode(try await request(method: "GET", path: pathWithQuery(path, query)), as: type)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        try decode(try await request(method: "POST", path: path, body: try encode(body)), as: type)
    }

    private func put<T: Decodable, Body: Encodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        try decode(try await request(method: "PUT", path: path, body: try encode(body)), as: type)
    }

    private func postEmpty<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try decode(try await request(method: "POST", path: path), as: type)
    }

    private func request(method: String, path: String, body: Data? = nil) async throws -> Data {
        let response = try await service.proxyMeshCoreHTTPRequest(
            nodeId: node.id,
            method: method,
            path: path,
            body: body,
            headers: body == nil ? [:] : ["content-type": "application/json"]
        )
        guard response.status < 400 else {
            throw RemoteSloppyTUIBackendError.unsupported("mesh remote HTTP \(response.status)")
        }
        return response.body
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func pathWithQuery(_ path: String, _ query: [String: String]) -> String {
        guard !query.isEmpty else { return path }
        var components = URLComponents()
        components.path = path
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.string ?? path
    }

    private static func escape(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }
}

private enum SloppyTUILineStream {
    static func open(request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let delegate = SloppyTUILineStreamDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        delegate.attach(session: session, task: task)
        let response = try await delegate.start()
        return (delegate.lines(), response)
    }
}

private final class SloppyTUILineStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    nonisolated(unsafe) private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    nonisolated(unsafe) private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var task: URLSessionDataTask?
    private let chunks: AsyncThrowingStream<Data, Error>

    override init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.chunks = AsyncThrowingStream { continuation = $0 }
        self.streamContinuation = continuation
        super.init()
    }

    func attach(session: URLSession, task: URLSessionDataTask) {
        self.session = session
        self.task = task
    }

    func start() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            task?.resume()
        }
    }

    func lines() -> AsyncThrowingStream<String, Error> {
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            let lineTask = Task {
                var buffer = Data()
                do {
                    for try await chunk in chunks {
                        for byte in chunk {
                            if byte == UInt8(ascii: "\n") {
                                continuation.yield(String(data: buffer, encoding: .utf8) ?? "")
                                buffer.removeAll(keepingCapacity: true)
                            } else if byte != UInt8(ascii: "\r") {
                                buffer.append(byte)
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(data: buffer, encoding: .utf8) ?? "")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [self] _ in
                lineTask.cancel()
                task?.cancel()
                session?.invalidateAndCancel()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        streamContinuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            responseContinuation?.resume(throwing: error)
            responseContinuation = nil
            streamContinuation?.finish(throwing: error)
        } else {
            streamContinuation?.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
