import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

public actor SloppyAPIClient {
    public nonisolated let baseURL: URL
    public nonisolated let endpoint: SloppyInstanceEndpoint

    let http: BackendHTTPClient
    private let projects: ProjectService
    private let agents: AgentService
    private let sessions: SessionService
    private let mesh: MeshService
    private let config: ConfigService
    private let auth: AuthService
    private let voice: VoiceService
    private let sites: SiteService
    private let logger: Logger

    public init(
        baseURL: URL = URL(string: "http://localhost:25101")!,
        authToken: String = "",
        tlsFingerprint: String? = nil,
        session: URLSession? = nil,
        authSessionStore: AuthSessionStore = .shared,
        logger: Logger = Logger(label: "sloppy.api-client")
    ) {
        self.init(
            endpoint: .direct(baseURL: baseURL),
            authToken: authToken,
            tlsFingerprint: tlsFingerprint,
            session: session,
            authSessionStore: authSessionStore,
            logger: logger
        )
    }

    public init(
        endpoint: SloppyInstanceEndpoint,
        authToken: String = "",
        tlsFingerprint: String? = nil,
        session: URLSession? = nil,
        authSessionStore: AuthSessionStore = .shared,
        logger: Logger = Logger(label: "sloppy.api-client")
    ) {
        self.endpoint = endpoint
        self.baseURL = endpoint.coordinatorBaseURL
        let http = BackendHTTPClient(
            endpoint: endpoint,
            authToken: authToken,
            tlsFingerprint: tlsFingerprint,
            session: session,
            authSessionStore: authSessionStore,
            logger: logger
        )
        self.http = http
        self.projects = ProjectService(http: http)
        self.agents = AgentService(http: http)
        self.sessions = SessionService(http: http)
        self.mesh = MeshService(http: http)
        self.config = ConfigService(http: http)
        self.auth = AuthService(http: http)
        self.voice = VoiceService(http: http)
        self.sites = SiteService(http: http)
        self.logger = logger
    }

    public func fetchSessionAttachment(agentID: String, sessionID: String, attachmentID: String) async throws -> Data {
        let path = "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentID))/sessions/\(BackendHTTPClient.encodePathSegment(sessionID))/attachments/\(BackendHTTPClient.encodePathSegment(attachmentID))"
        return try await http.getData(path, timeout: 30)
    }

    public func setAuthToken(_ token: String) async {
        await http.setAuthToken(token)
    }

    public func fetchCodexAuthorizationStatus() async throws -> CodexAuthorizationStatus {
        try await http.get("/v1/providers/openai/status")
    }

    public func startCodexDeviceAuthorization() async throws -> CodexDeviceAuthorization {
        try await http.post("/v1/providers/openai/oauth/device-code/start", body: [String: String]())
    }

    public func pollCodexDeviceAuthorization(_ authorization: CodexDeviceAuthorization) async throws -> CodexDeviceAuthorizationResult {
        try await http.post("/v1/providers/openai/oauth/device-code/poll", body: [
            "deviceAuthId": authorization.deviceAuthId,
            "userCode": authorization.userCode,
        ])
    }

    public func registerWorkspaceBrowser(_ binding: WorkspaceBrowserBinding) async throws {
        try await http.post("/v1/workspace-browser/register", body: binding)
    }

    public func pollWorkspaceBrowser(_ binding: WorkspaceBrowserBinding) async throws -> WorkspaceBrowserCommands {
        try await http.post("/v1/workspace-browser/poll", body: binding)
    }

    public func completeWorkspaceBrowser(_ result: WorkspaceBrowserCompletion) async throws {
        try await http.post("/v1/workspace-browser/complete", body: result)
    }

    public func disconnectWorkspaceBrowser(_ binding: WorkspaceBrowserBinding) async throws {
        try await http.post("/v1/workspace-browser/disconnect", body: binding)
    }

    public func currentAccessToken() async -> String? {
        await http.currentAccessToken()
    }

    public func fetchAuthChallenge() async throws -> AuthChallenge {
        try await auth.fetchAuthChallenge()
    }

    /// Resolves the authentication UI required for a new connection.
    ///
    /// Dashboard-token deployments protect most API routes and some older Core
    /// versions also protect `/v1/auth/challenge` itself. The dashboard auth
    /// status endpoint remains public, so a 401 challenge response means the
    /// client must ask for the legacy dashboard access token.
    public func fetchConnectionAuthChallenge() async throws -> AuthChallenge {
        do {
            return try await auth.fetchAuthChallenge()
        } catch let error as APIError where error.statusCode == 401 {
            let status = try await auth.fetchDashboardAuthStatus()
            guard status.enabled else { throw error }
            logger.info(
                "auth.challenge.legacy-token-fallback",
                metadata: ["server": .string(Self.serverDescription(baseURL))]
            )
            return .legacyToken
        }
    }

    public func loginIdentityUser(login: String, password: String) async throws -> AuthSession {
        let session = try await auth.loginIdentityUser(login: login, password: password)
        await http.installAuthSession(session)
        return session
    }

    public func bootstrapIdentityAdmin(login: String, password: String, name: String) async throws -> AuthSession {
        let session = try await auth.bootstrapIdentityAdmin(login: login, password: password, name: name)
        await http.installAuthSession(session)
        return session
    }

    public func registerIdentityUser(
        inviteToken: String,
        login: String,
        password: String,
        name: String
    ) async throws -> AuthSession {
        let session = try await auth.registerIdentityUser(
            inviteToken: inviteToken,
            login: login,
            password: password,
            name: name
        )
        await http.installAuthSession(session)
        return session
    }

    public func redeemDevicePairing(token: String) async throws -> AuthSession {
        let session = try await auth.redeemDevicePairing(token: token)
        await http.installAuthSession(session)
        return session
    }

    public func fetchCurrentAuthUser() async throws -> AuthUserProfile {
        try await auth.fetchCurrentUser()
    }

    public func updateCurrentAuthUser(
        name: String,
        avatar: String,
        description: String
    ) async throws -> AuthUserProfile {
        let user = try await auth.updateCurrentUser(
            name: name,
            avatar: avatar,
            description: description
        )
        await http.updateAuthSessionUser(user)
        return user
    }

    public func changeIdentityPassword(currentPassword: String, newPassword: String) async throws -> AuthSession {
        let session = try await auth.changeIdentityPassword(
            currentPassword: currentPassword,
            newPassword: newPassword
        )
        await http.installAuthSession(session)
        return session
    }

    public func generateIdentityRecoveryCodes() async throws -> AuthRecoveryCodes {
        try await auth.generateIdentityRecoveryCodes()
    }

    public func fetchIdentityApplicationTokens() async throws -> [AuthApplicationToken] {
        try await auth.fetchIdentityApplicationTokens()
    }

    public func createIdentityApplicationToken(name: String) async throws -> AuthApplicationToken {
        try await auth.createIdentityApplicationToken(name: name)
    }

    public func revokeIdentityApplicationToken(id: String) async throws {
        try await auth.revokeIdentityApplicationToken(id: id)
    }

    public func fetchDashboardAuthStatus() async throws -> DashboardAuthStatus {
        try await auth.fetchDashboardAuthStatus()
    }

    public func validateCurrentAuthToken() async throws {
        try await auth.validateCurrentToken()
    }

    public func installStaticAuthToken(_ token: String) async {
        await http.installStaticAuthToken(token)
    }

    public func hasStoredAuthSession() async -> Bool {
        await http.hasStoredAuthSession()
    }

    public func logout() async {
        await http.clearAuthSession()
    }

    public func fetchPublishedSites() async throws -> [PublishedSiteRecord] {
        try await sites.list()
    }

    public func fetchCodeReviewProviders() async throws -> [CodeReviewProviderDescriptor] {
        try await http.get("/v1/code-reviews/providers")
    }

    public func fetchCodeReviews(
        state: CodeReviewState = .open,
        roles: [CodeReviewRole] = CodeReviewRole.allCases,
        providerIDs: [String] = [],
        limit: Int = 100
    ) async throws -> CodeReviewInboxResponse {
        var query = [
            "state=\(BackendHTTPClient.encodeQueryValue(state.rawValue))",
            "roles=\(BackendHTTPClient.encodeQueryValue(roles.map(\.rawValue).joined(separator: ",")))",
            "limit=\(max(1, min(limit, 200)))",
        ]
        if !providerIDs.isEmpty {
            query.append(
                "providers=\(BackendHTTPClient.encodeQueryValue(providerIDs.joined(separator: ",")))"
            )
        }
        return try await http.get("/v1/code-reviews?\(query.joined(separator: "&"))")
    }

    public func fetchCodeReviewDetail(
        providerID: String,
        reviewID: String,
        maxDiffBytes: Int = 1_048_576
    ) async throws -> CodeReviewDetail {
        let provider = BackendHTTPClient.encodePathSegment(providerID)
        let review = BackendHTTPClient.encodePathSegment(reviewID)
        return try await http.get(
            "/v1/code-reviews/\(provider)/\(review)?maxDiffBytes=\(max(1, min(maxDiffBytes, 4 * 1_048_576)))"
        )
    }

    public func replyToCodeReviewComment(
        providerID: String,
        reviewID: String,
        parentCommentID: String,
        body: String
    ) async throws -> CodeReviewComment {
        try await http.post(
            "/v1/code-reviews/\(BackendHTTPClient.encodePathSegment(providerID))/\(BackendHTTPClient.encodePathSegment(reviewID))/comments",
            body: CodeReviewCommentReplyRequest(parentCommentID: parentCommentID, body: body)
        )
    }

    public func fetchCodeReviewCredentialStatus(providerID: String) async throws -> CodeReviewCredentialStatus {
        try await http.get("/v1/code-review-credentials/\(BackendHTTPClient.encodePathSegment(providerID))")
    }

    public func saveCodeReviewCredential(providerID: String, token: String) async throws -> CodeReviewCredentialStatus {
        try await http.put(
            "/v1/code-review-credentials/\(BackendHTTPClient.encodePathSegment(providerID))",
            body: CodeReviewCredentialRequest(token: token)
        )
    }

    public func deleteCodeReviewCredential(providerID: String) async throws -> CodeReviewCredentialStatus {
        let path = "/v1/code-review-credentials/\(BackendHTTPClient.encodePathSegment(providerID))"
        try await http.delete(path)
        return try await http.get(path)
    }

    public func updatePublishedSite(
        id: String,
        request: PublishedSiteUpdateRequest
    ) async throws -> PublishedSiteRecord {
        try await sites.update(id: id, request: request)
    }

    public func deletePublishedSite(id: String) async throws {
        try await sites.delete(id: id)
    }

    public func createPublishedSiteLaunch(id: String) async throws -> URL {
        let response = try await sites.launch(id: id)
        guard let url = URL(string: response.url, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidResponse
        }
        return url
    }

    private nonisolated static func serverDescription(_ url: URL) -> String {
        guard let host = url.host else { return "unknown-server" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    public func fetchProjects() async throws -> [APIProjectRecord] {
        try await projects.fetchProjects()
    }

    public func fetchProject(id: String) async throws -> APIProjectRecord {
        try await projects.fetchProject(id: id)
    }

    public func fetchCanvasWorkspaces(projectId: String? = nil) async throws -> [CanvasWorkspaceSummary] {
        var path = "/v1/workspaces"
        if let projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectId.isEmpty {
            path += "?projectId=\(BackendHTTPClient.encodeQueryValue(projectId))"
        }
        let response: CanvasWorkspaceListResponse = try await http.get(path)
        return response.workspaces
    }

    public func createCanvasWorkspace(
        title: String,
        description: String? = nil,
        projectId: String? = nil,
        templateId: String? = nil
    ) async throws -> CanvasWorkspaceSummary {
        let request = CanvasWorkspaceCreateRequest(
            title: title,
            description: description,
            projectId: projectId,
            templateId: templateId
        )
        return try await http.post("/v1/workspaces", body: request)
    }

    public func fetchCanvasWorkspaceDocument(workspaceId: String) async throws -> CanvasWorkspaceDocument {
        let response: CanvasWorkspaceDocumentResponse = try await http.get(
            "/v1/workspaces/\(BackendHTTPClient.encodePathSegment(workspaceId))/document"
        )
        return response.document
    }

    public func applyCanvasWorkspaceTransaction(
        workspaceId: String,
        request: CanvasWorkspaceTransactionRequest
    ) async throws -> CanvasWorkspaceCommittedTransaction {
        try await http.post(
            "/v1/workspaces/\(BackendHTTPClient.encodePathSegment(workspaceId))/transactions",
            body: request
        )
    }

    public func fetchCanvasWidgetArtifact(id: String) async throws -> CanvasWidgetArtifact {
        try await http.get("/v1/artifacts/\(BackendHTTPClient.encodePathSegment(id))/widget")
    }

    public func createProject(_ request: APIProjectCreateRequest) async throws -> APIProjectRecord {
        try await projects.createProject(request)
    }

    public func updateProject(id: String, request: APIProjectUpdateRequest) async throws -> APIProjectRecord {
        try await projects.updateProject(id: id, request: request)
    }

    public func deleteProject(id: String) async throws {
        try await projects.deleteProject(id: id)
    }

    public func createPermanentWorktree(projectId: String, taskId: String) async throws -> ProjectWorktreeRecord {
        try await projects.createPermanentWorktree(projectId: projectId, taskId: taskId)
    }

    public func createProjectTask(
        projectId: String,
        request: APIProjectTaskCreateRequest
    ) async throws -> APIProjectRecord {
        try await projects.createTask(projectId: projectId, request: request)
    }

    public func updateProjectTask(
        projectId: String,
        taskId: String,
        request: APIProjectTaskUpdateRequest
    ) async throws -> APIProjectRecord {
        try await projects.updateTask(projectId: projectId, taskId: taskId, request: request)
    }

    public func fetchProjectAutomations(projectId: String) async throws -> [ProjectAutomationDefinition] {
        try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/automations"
        )
    }

    public func createProjectAutomation(
        projectId: String,
        request: ProjectAutomationDefinitionUpsertRequest
    ) async throws -> ProjectAutomationDefinition {
        try await http.post(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/automations",
            body: request
        )
    }

    public func fetchProjectAutomationWorkflows(
        projectId: String
    ) async throws -> [ProjectAutomationWorkflowSummary] {
        try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/workflows"
        )
    }

    public func fetchProjectAutomationRuns(projectId: String) async throws -> [ProjectAutomationRun] {
        try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/automation-runs"
        )
    }

    public func runProjectAutomation(
        projectId: String,
        automationId: String,
        request: ProjectAutomationManualRunRequest = ProjectAutomationManualRunRequest()
    ) async throws -> ProjectAutomationRunDetail {
        try await http.post(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/automations/"
                + "\(BackendHTTPClient.encodePathSegment(automationId))/run",
            body: request
        )
    }

    private func taskActivityPath(_ projectId: String, _ taskId: String, _ suffix: String) -> String {
        "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/tasks/\(BackendHTTPClient.encodePathSegment(taskId))/\(suffix)"
    }

    public func fetchTaskActivities(projectId: String, taskId: String) async throws -> [APITaskActivity] {
        try await http.get(taskActivityPath(projectId, taskId, "activities"))
    }

    public func fetchTaskLogs(projectId: String, taskId: String) async throws -> [APITaskLog] {
        try await http.get(taskActivityPath(projectId, taskId, "logs"))
    }

    public func fetchTaskClarifications(projectId: String, taskId: String) async throws -> [APITaskClarification] {
        try await http.get(taskActivityPath(projectId, taskId, "clarifications"))
    }

    public func fetchTaskDiff(projectId: String, taskId: String) async throws -> APITaskDiff {
        try await http.get(taskActivityPath(projectId, taskId, "diff"))
    }

    public func fetchTaskReviewComments(projectId: String, taskId: String) async throws -> [APITaskReviewComment] {
        try await http.get(taskActivityPath(projectId, taskId, "review-comments"))
    }

    public func addTaskComment(projectId: String, taskId: String, content: String) async throws -> TaskComment {
        try await http.post(taskActivityPath(projectId, taskId, "comments"), body: APITaskCommentRequest(content: content))
    }

    public func answerTaskClarification(projectId: String, taskId: String, clarificationId: String,
                                       answer: APITaskClarificationAnswer) async throws -> APITaskClarification {
        try await http.post(taskActivityPath(projectId, taskId, "clarifications/\(BackendHTTPClient.encodePathSegment(clarificationId))/answer"), body: answer)
    }

    public func decideTaskReview(projectId: String, taskId: String, approve: Bool, reason: String) async throws {
        try await http.post(taskActivityPath(projectId, taskId, approve ? "approve" : "reject"), body: ["reason": reason])
    }

    public func resolveTaskReviewComment(projectId: String, taskId: String, commentId: String, resolved: Bool) async throws -> APITaskReviewComment {
        try await http.patch(taskActivityPath(projectId, taskId, "review-comments/\(BackendHTTPClient.encodePathSegment(commentId))"), body: ["resolved": resolved])
    }

    public func fetchTaskComments(projectId: String, taskId: String) async throws -> [TaskComment] {
        try await projects.fetchTaskComments(projectId: projectId, taskId: taskId)
    }

    public func fetchProjectFiles(projectId: String, path: String = "") async throws -> [ProjectFileEntry] {
        try await projects.fetchProjectFiles(projectId: projectId, path: path)
    }

    public func searchProjectFiles(
        projectId: String,
        query: String,
        limit: Int = 50
    ) async throws -> [ProjectFileSearchEntry] {
        try await projects.searchProjectFiles(projectId: projectId, query: query, limit: limit)
    }

    public func fetchProjectFileContent(projectId: String, path: String) async throws -> ProjectFileContentResponse {
        try await projects.fetchProjectFileContent(projectId: projectId, path: path)
    }

    public func fetchProjectWorkingTreeSourceControl(
        projectId: String,
        taskId: String? = nil
    ) async throws -> ProjectWorkingTreeSourceControlResponse {
        try await projects.fetchProjectWorkingTreeSourceControl(
            projectId: projectId,
            taskId: taskId
        )
    }

    public func fetchAgents() async throws -> [APIAgentRecord] {
        try await agents.fetchAgents()
    }

    public func fetchAgent(id: String) async throws -> APIAgentRecord {
        try await agents.fetchAgent(id: id)
    }

    public func fetchAgentTasks(agentId: String) async throws -> [APIAgentTaskRecord] {
        try await agents.fetchAgentTasks(agentId: agentId)
    }

    public func fetchAgentFiles(agentId: String, path: String = "") async throws -> [ProjectFileEntry] {
        try await agents.fetchAgentFiles(agentId: agentId, path: path)
    }

    public func fetchAgentFileContent(agentId: String, path: String) async throws -> ProjectFileContentResponse {
        try await agents.fetchAgentFileContent(agentId: agentId, path: path)
    }

    public func fetchAgentTokenUsage(agentId: String) async throws -> AgentTokenUsageResponse {
        try await agents.fetchAgentTokenUsage(agentId: agentId)
    }

    public func fetchSessionTokenUsage(agentId: String, sessionId: String) async throws -> ChatTokenUsageResponse {
        let channelId = "agent:\(agentId):session:\(sessionId)"
        return try await http.get(
            "/v1/token-usage?channelId=\(BackendHTTPClient.encodeQueryValue(channelId))"
        )
    }

    public func fetchAgentSkills(agentId: String) async throws -> AgentSkillsResponse {
        try await agents.fetchAgentSkills(agentId: agentId)
    }

    public func fetchSkillsRegistry(
        search: String = "",
        sort: String = "installs",
        limit: Int = 40,
        offset: Int = 0
    ) async throws -> SkillsRegistryResponse {
        try await agents.fetchSkillsRegistry(search: search, sort: sort, limit: limit, offset: offset)
    }

    public func installAgentSkill(
        agentId: String,
        request: AgentSkillInstallRequest
    ) async throws -> InstalledAgentSkill {
        try await agents.installAgentSkill(agentId: agentId, request: request)
    }

    public func uninstallAgentSkill(agentId: String, skillId: String) async throws {
        try await agents.uninstallAgentSkill(agentId: agentId, skillId: skillId)
    }

    public func fetchChatSlashCommands(agentId: String) async throws -> AgentChatSlashCommandsResponse {
        try await agents.fetchChatSlashCommands(agentId: agentId)
    }

    public func fetchScheduledTasks(agentId: String) async throws -> [ScheduledTask] {
        let agent = BackendHTTPClient.encodePathSegment(agentId)
        return try await http.get("/v1/agents/\(agent)/cron")
    }

    public func createScheduledTask(agentId: String, request: ScheduledTaskCreateRequest) async throws -> ScheduledTask {
        let agent = BackendHTTPClient.encodePathSegment(agentId)
        return try await http.post("/v1/agents/\(agent)/cron", body: request)
    }

    public func updateScheduledTask(agentId: String, taskId: String, request: ScheduledTaskUpdateRequest) async throws -> ScheduledTask {
        let agent = BackendHTTPClient.encodePathSegment(agentId)
        let task = BackendHTTPClient.encodePathSegment(taskId)
        return try await http.put("/v1/agents/\(agent)/cron/\(task)", body: request)
    }

    public func deleteScheduledTask(agentId: String, taskId: String) async throws {
        let agent = BackendHTTPClient.encodePathSegment(agentId)
        let task = BackendHTTPClient.encodePathSegment(taskId)
        try await http.delete("/v1/agents/\(agent)/cron/\(task)")
    }

    public func fetchOverviewData() async throws -> OverviewData {
        async let projectsReq = fetchProjects()
        async let agentsReq = fetchAgents()

        let projects = (try? await projectsReq) ?? []
        let agents = (try? await agentsReq) ?? []

        let summaries = projects.map { $0.toSummary() }
        let agentOverviews = agents.map { $0.toOverview() }

        let allTasks = projects.flatMap { $0.tasks ?? [] }
        let active = allTasks.filter { ["in_progress", "ready", "needs_review"].contains($0.status) }.count
        let completed = allTasks.filter { $0.status == "done" }.count

        return OverviewData(
            projects: summaries,
            agents: agentOverviews,
            activeTasks: active,
            completedTasks: completed
        )
    }

    public func resolveToolApproval(
        id: String,
        approved: Bool,
        scope: ClientToolApprovalDecisionScope = .once
    ) async throws {
        struct DecisionPayload: Encodable {
            var decidedBy: String?
            var scope: String
        }
        struct DecisionResponse: Decodable { var id: String }

        let approvalID = BackendHTTPClient.encodePathSegment(id)
        let action = approved ? "approve" : "reject"
        let _: DecisionResponse = try await http.post(
            "/v1/tool-approvals/\(approvalID)/\(action)",
            body: DecisionPayload(decidedBy: "SloppyClient", scope: approved ? scope.rawValue : ClientToolApprovalDecisionScope.once.rawValue)
        )
    }

    public func fetchPendingToolApprovals() async throws -> [PendingToolApprovalRecord] {
        try await http.get("/v1/tool-approvals/pending")
    }

    // MARK: - Session REST API

    public func fetchAgentSessions(
        agentId: String,
        projectId: String? = nil,
        limit: Int? = nil
    ) async throws -> [ChatSessionSummary] {
        try await sessions.fetchAgentSessions(agentId: agentId, projectId: projectId, limit: limit)
    }

    public func fetchAgentSession(
        agentId: String, sessionId: String, eventLimit: Int? = nil, before: String? = nil
    ) async throws -> ChatSessionDetail {
        try await sessions.fetchAgentSession(
            agentId: agentId, sessionId: sessionId, eventLimit: eventLimit, before: before
        )
    }

    public func fetchAgentSessionData(agentId: String, sessionId: String) async throws -> Data {
        try await sessions.fetchAgentSessionData(agentId: agentId, sessionId: sessionId)
    }

    public func answerSessionInputRequest(
        agentId: String,
        sessionId: String,
        requestId: String,
        request: ChatPlanInputAnswerRequest
    ) async throws -> ChatSessionSummary {
        try await sessions.answerInputRequest(
            agentId: agentId,
            sessionId: sessionId,
            requestId: requestId,
            request: request
        )
    }

    public func renameAgentSession(agentId: String, sessionId: String, title: String) async throws -> ChatSessionSummary {
        try await sessions.renameAgentSession(agentId: agentId, sessionId: sessionId, title: title)
    }

    public func createAgentSession(
        agentId: String,
        title: String? = nil,
        parentSessionId: String? = nil,
        projectId: String? = nil,
        taskId: String? = nil,
        workspaceId: String? = nil,
        separateChat: Bool = false
    ) async throws -> ChatSessionSummary {
        try await sessions.createAgentSession(
            agentId: agentId,
            title: title,
            parentSessionId: parentSessionId,
            projectId: projectId,
            taskId: taskId,
            workspaceId: workspaceId,
            separateChat: separateChat
        )
    }

    public func fetchMeshNodes() async throws -> [MeshNodeRecord] {
        try await mesh.listNodes()
    }

    public func fetchMeshTopology() async throws -> ClientMeshTopology {
        try await http.get("/v1/node/mesh")
    }

    public func acceptMeshInvite(
        token: String,
        endpoint: String? = nil,
        allowRemote: Bool = true
    ) async throws -> MeshNodeRecord {
        try await mesh.acceptInvite(
            MeshInviteAcceptRequest(token: token, endpoint: endpoint, allowRemote: allowRemote)
        )
    }

    public func createMeshTask(
        projectId: String,
        title: String,
        assignedNodeId: String
    ) async throws -> MeshTaskRecord {
        try await mesh.createTask(
            MeshTaskCreateRequest(projectId: projectId, title: title, assignedNodeId: assignedNodeId)
        )
    }

    public func fetchMeshTasks(projectId: String? = nil) async throws -> [MeshTaskRecord] {
        try await mesh.listTasks(projectId: projectId)
    }

    public func postSessionMessage(
        agentId: String,
        sessionId: String,
        content: String,
        userId: String = "user",
        attachments: [ChatAttachmentUpload] = [],
        selectedModel: String? = nil,
        reasoningEffort: String? = nil
    ) async throws -> ChatSessionSummary {
        try await postSessionMessageWithReceipt(
            agentId: agentId, sessionId: sessionId, content: content, userId: userId,
            attachments: attachments, selectedModel: selectedModel, reasoningEffort: reasoningEffort
        ).summary
    }

    public func postSessionMessageWithReceipt(
        agentId: String,
        sessionId: String,
        content: String,
        userId: String = "user",
        attachments: [ChatAttachmentUpload] = [],
        selectedModel: String? = nil,
        reasoningEffort: String? = nil,
        clientMessageId: String? = nil
    ) async throws -> ChatSessionMessageReceipt {
        try await sessions.postSessionMessageWithReceipt(
            agentId: agentId,
            sessionId: sessionId,
            content: content,
            userId: userId,
            attachments: attachments,
            selectedModel: selectedModel,
            reasoningEffort: reasoningEffort,
            clientMessageId: clientMessageId
        )
    }

    public func deleteAgentSession(agentId: String, sessionId: String) async throws {
        try await sessions.deleteAgentSession(agentId: agentId, sessionId: sessionId)
    }

    public func interruptAgentSession(
        agentId: String,
        sessionId: String,
        includeSubsessions: Bool = true,
        requestedBy: String = "apple-client",
        reason: String? = nil
    ) async throws {
        try await sessions.controlAgentSession(
            agentId: agentId,
            sessionId: sessionId,
            action: includeSubsessions ? .interruptTree : .interrupt,
            requestedBy: requestedBy,
            reason: reason
        )
    }

    // MARK: - Config API

    public func fetchConfig() async throws -> SloppyConfig {
        try await config.fetchConfig()
    }

    public func fetchAvailableModels() async throws -> [ChatModelOption] {
        try await config.fetchAvailableModels()
    }

    public func fetchProviderModels(
        providerId: String,
        apiKey: String? = nil,
        apiUrl: String? = nil
    ) async throws -> [ChatModelOption] {
        try await config.fetchProviderModels(
            providerId: providerId,
            apiKey: apiKey,
            apiUrl: apiUrl
        )
    }

    public func updateConfig(_ config: SloppyConfig) async throws -> SloppyConfig {
        try await self.config.updateConfig(config)
    }

    // MARK: - Agent Plugins

    public func fetchAgentPlugins() async throws -> [ClientInstalledAgentPlugin] {
        try await http.get("/v1/agent-plugins")
    }

    public func uploadAgentPluginZIP(_ data: Data) async throws -> ClientAgentPluginUpload {
        try await http.postRaw("/v1/agent-plugins/uploads", data: data, contentType: "application/zip")
    }

    public func inspectAgentPlugin(source: ClientAgentPluginSource) async throws -> ClientAgentPluginInspection {
        try await http.post("/v1/agent-plugins/inspections", body: ClientAgentPluginInspectionRequest(source: source))
    }

    public func planAgentPlugin(inspectionId: String, agentIds: [String], inputs: [String: String]) async throws -> ClientAgentPluginPlan {
        try await http.post("/v1/agent-plugins/plans", body: ClientAgentPluginPlanRequest(inspectionId: inspectionId, agentIds: agentIds, inputs: inputs))
    }

    public func installAgentPlugin(plan: ClientAgentPluginPlan, trustConfirmed: Bool, commandsApproved: Bool) async throws -> ClientAgentPluginOperation {
        try await http.post("/v1/agent-plugins/install", body: ClientAgentPluginInstallRequest(planId: plan.id, approvalHash: plan.approvalHash, trustConfirmed: trustConfirmed, commandsApproved: commandsApproved))
    }

    public func uninstallAgentPlugin(id: String, forceModifiedComponents: Bool) async throws -> ClientAgentPluginOperation {
        struct Request: Codable { var forceModifiedComponents: Bool }
        return try await http.post("/v1/agent-plugins/\(BackendHTTPClient.encodePathSegment(id))/uninstall", body: Request(forceModifiedComponents: forceModifiedComponents))
    }

    public func fetchAgentPluginOperation(id: String) async throws -> ClientAgentPluginOperation {
        try await http.get("/v1/agent-plugins/operations/\(BackendHTTPClient.encodePathSegment(id))")
    }

    public func fetchAgentPluginRegistries() async throws -> [ClientAgentPluginRegistry] {
        try await http.get("/v1/agent-plugin-registries")
    }

    public func saveAgentPluginRegistry(id: String? = nil, request: ClientAgentPluginRegistryWriteRequest) async throws -> ClientAgentPluginRegistry {
        if let id { return try await http.put("/v1/agent-plugin-registries/\(BackendHTTPClient.encodePathSegment(id))", body: request) }
        return try await http.post("/v1/agent-plugin-registries", body: request)
    }

    public func deleteAgentPluginRegistry(id: String) async throws {
        try await http.delete("/v1/agent-plugin-registries/\(BackendHTTPClient.encodePathSegment(id))")
    }

    public func searchAgentPluginCatalog(query: String = "", registryId: String? = nil) async throws -> ClientAgentPluginCatalogResponse {
        var queryItems = ["search=\(BackendHTTPClient.encodeQueryValue(query))"]
        if let registryId { queryItems.append("registryId=\(BackendHTTPClient.encodeQueryValue(registryId))") }
        return try await http.get("/v1/agent-plugin-catalog?\(queryItems.joined(separator: "&"))")
    }

    public func fetchAccessUsers(platform: String? = nil) async throws -> [AccessUser] {
        try await config.fetchAccessUsers(platform: platform)
    }

    public func deleteAccessUser(_ userId: String) async throws {
        try await config.deleteAccessUser(userId)
    }

    public func transcribeVoice(_ request: VoiceTranscriptionRequest) async throws -> VoiceTranscriptionResponse {
        try await voice.transcribe(request)
    }
}
