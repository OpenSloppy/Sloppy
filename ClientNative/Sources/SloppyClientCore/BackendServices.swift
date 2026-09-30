import Foundation

public struct HealthCheckResult: Sendable {
    public let isHealthy: Bool
    public let failureMessage: String?

    public init(isHealthy: Bool, failureMessage: String? = nil) {
        self.isHealthy = isHealthy
        self.failureMessage = failureMessage
    }
}

public struct ChatAttachmentUpload: Codable, Sendable, Equatable {
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var contentBase64: String

    public init(name: String, mimeType: String, sizeBytes: Int, contentBase64: String) {
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentBase64 = contentBase64
    }
}

public struct AccessUser: Codable, Sendable, Identifiable {
    public var id: String
    public var platform: String
    public var platformUserId: String
    public var displayName: String
    public var status: String
    public var createdAt: Date

    public init(
        id: String,
        platform: String,
        platformUserId: String,
        displayName: String,
        status: String,
        createdAt: Date
    ) {
        self.id = id
        self.platform = platform
        self.platformUserId = platformUserId
        self.displayName = displayName
        self.status = status
        self.createdAt = createdAt
    }
}

public actor HealthService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public init(baseURL: URL = URL(string: "http://localhost:25101")!) {
        self.init(http: BackendHTTPClient(baseURL: baseURL))
    }

    public nonisolated var baseURL: URL { http.baseURL }

    public func check(timeout: TimeInterval = 5) async -> HealthCheckResult {
        do {
            _ = try await http.getData("/health", timeout: timeout)
            return HealthCheckResult(isHealthy: true)
        } catch let apiError as APIError {
            switch apiError {
            case .invalidResponse:
                return HealthCheckResult(isHealthy: false, failureMessage: "Invalid HTTP response")
            case let .httpError(statusCode, _):
                return HealthCheckResult(isHealthy: false, failureMessage: "HTTP \(statusCode)")
            case let .decodingFailed(message):
                return HealthCheckResult(isHealthy: false, failureMessage: message)
            }
        } catch {
            let nsError = error as NSError
            return HealthCheckResult(
                isHealthy: false,
                failureMessage: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            )
        }
    }

    public func isHealthy(timeout: TimeInterval = 5) async -> Bool {
        await check(timeout: timeout).isHealthy
    }
}

public struct AuthChallenge: Codable, Sendable, Equatable {
    public var mode: String
    public var bootstrapRequired: Bool
    public var passkeySupported: Bool?
    public var accessTokenExpiresInSeconds: Int?
    public var refreshTokenExpiresInSeconds: Int?

    public init(
        mode: String,
        bootstrapRequired: Bool,
        passkeySupported: Bool? = nil,
        accessTokenExpiresInSeconds: Int? = nil,
        refreshTokenExpiresInSeconds: Int? = nil
    ) {
        self.mode = mode
        self.bootstrapRequired = bootstrapRequired
        self.passkeySupported = passkeySupported
        self.accessTokenExpiresInSeconds = accessTokenExpiresInSeconds
        self.refreshTokenExpiresInSeconds = refreshTokenExpiresInSeconds
    }

    public static var legacyToken: AuthChallenge {
        AuthChallenge(mode: "token", bootstrapRequired: false)
    }
}

public struct AuthUserProfile: Codable, Sendable, Equatable {
    public var id: String
    public var login: String
    public var name: String
    public var avatar: String?
    public var description: String?
    public var role: String
    public var status: String?
}

public struct AuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var user: AuthUserProfile?

    public init(
        accessToken: String,
        refreshToken: String,
        accessTokenExpiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil,
        user: AuthUserProfile? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.user = user
    }
}

public struct AuthRecoveryCodes: Codable, Sendable, Equatable {
    public var codes: [String]
}

public struct AuthApplicationToken: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var token: String?
    public var tokenPrefix: String
    public var createdAt: Date
    public var expiresAt: Date
}

public struct DashboardAuthStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
}

public actor AuthService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func fetchAuthChallenge() async throws -> AuthChallenge {
        try await http.get("/v1/auth/challenge")
    }

    public func loginIdentityUser(login: String, password: String) async throws -> AuthSession {
        struct Payload: Encodable {
            var login: String
            var password: String
        }
        return try await http.post(
            "/v1/auth/login",
            body: Payload(
                login: login.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        )
    }

    public func bootstrapIdentityAdmin(login: String, password: String, name: String) async throws -> AuthSession {
        struct Payload: Encodable {
            var login: String
            var password: String
            var name: String
        }
        return try await http.post(
            "/v1/auth/bootstrap",
            body: Payload(
                login: login.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    public func registerIdentityUser(
        inviteToken: String,
        login: String,
        password: String,
        name: String
    ) async throws -> AuthSession {
        struct Payload: Encodable {
            var inviteToken: String
            var login: String
            var password: String
            var name: String
        }
        return try await http.post(
            "/v1/auth/register",
            body: Payload(
                inviteToken: inviteToken.trimmingCharacters(in: .whitespacesAndNewlines),
                login: login.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    public func redeemDevicePairing(token: String) async throws -> AuthSession {
        struct Payload: Encodable {
            var token: String
        }
        return try await http.post(
            "/v1/auth/device-pairing/redeem",
            body: Payload(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    public func fetchCurrentUser() async throws -> AuthUserProfile {
        try await http.get("/v1/auth/me")
    }

    public func updateCurrentUser(
        name: String,
        avatar: String,
        description: String
    ) async throws -> AuthUserProfile {
        struct Payload: Encodable {
            var name: String
            var avatar: String
            var description: String
        }
        return try await http.patch(
            "/v1/auth/me",
            body: Payload(name: name, avatar: avatar, description: description)
        )
    }

    public func changeIdentityPassword(currentPassword: String, newPassword: String) async throws -> AuthSession {
        struct Payload: Encodable {
            var currentPassword: String
            var newPassword: String
        }
        return try await http.post(
            "/v1/auth/password",
            body: Payload(currentPassword: currentPassword, newPassword: newPassword)
        )
    }

    public func generateIdentityRecoveryCodes() async throws -> AuthRecoveryCodes {
        struct EmptyPayload: Encodable {}
        return try await http.post("/v1/auth/recovery-codes", body: EmptyPayload())
    }

    public func fetchIdentityApplicationTokens() async throws -> [AuthApplicationToken] {
        try await http.get("/v1/auth/application-tokens")
    }

    public func createIdentityApplicationToken(name: String) async throws -> AuthApplicationToken {
        struct Payload: Encodable { var name: String }
        return try await http.post(
            "/v1/auth/application-tokens",
            body: Payload(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    public func revokeIdentityApplicationToken(id: String) async throws {
        try await http.delete(
            "/v1/auth/application-tokens/\(BackendHTTPClient.encodePathSegment(id))"
        )
    }

    public func fetchDashboardAuthStatus() async throws -> DashboardAuthStatus {
        try await http.get("/v1/dashboard/auth/status")
    }

    public func validateCurrentToken() async throws {
        struct EmptyPayload: Encodable {}
        struct ValidationResponse: Decodable { var ok: Bool }

        let response: ValidationResponse = try await http.post(
            "/v1/dashboard/auth/validate",
            body: EmptyPayload()
        )
        guard response.ok else {
            throw APIError.invalidResponse
        }
    }
}

public actor ProjectService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func fetchProjects() async throws -> [APIProjectRecord] {
        try await http.get("/v1/projects")
    }

    public func fetchProject(id: String) async throws -> APIProjectRecord {
        try await http.get("/v1/projects/\(BackendHTTPClient.encodePathSegment(id))")
    }

    public func createProject(_ request: APIProjectCreateRequest) async throws -> APIProjectRecord {
        let result: APIProjectCreateResult = try await http.post("/v1/projects", body: request)
        return result.project
    }

    public func updateProject(id: String, request: APIProjectUpdateRequest) async throws -> APIProjectRecord {
        try await http.patch(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(id))",
            body: request
        )
    }

    public func deleteProject(id: String) async throws {
        try await http.delete("/v1/projects/\(BackendHTTPClient.encodePathSegment(id))")
    }

    public func createPermanentWorktree(projectId: String, taskId: String) async throws -> ProjectWorktreeRecord {
        let response: ProjectWorktreeCreateResponse = try await http.post(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/source-control/worktrees",
            body: ProjectWorktreeCreateRequest(taskId: taskId)
        )
        return response.worktree
    }

    public func createTask(
        projectId: String,
        request: APIProjectTaskCreateRequest
    ) async throws -> APIProjectRecord {
        try await http.post(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/tasks",
            body: request
        )
    }

    public func updateTask(
        projectId: String,
        taskId: String,
        request: APIProjectTaskUpdateRequest
    ) async throws -> APIProjectRecord {
        try await http.patch(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/tasks/\(BackendHTTPClient.encodePathSegment(taskId))",
            body: request
        )
    }

    public func fetchTaskComments(projectId: String, taskId: String) async throws -> [TaskComment] {
        return try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/tasks/\(BackendHTTPClient.encodePathSegment(taskId))/comments"
        )
    }

    public func fetchProjectFiles(projectId: String, path: String = "") async throws -> [ProjectFileEntry] {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedPath.isEmpty ? "" : "?path=\(BackendHTTPClient.encodeQueryValue(trimmedPath))"
        return try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/files\(query)"
        )
    }

    public func searchProjectFiles(
        projectId: String,
        query: String,
        limit: Int = 50
    ) async throws -> [ProjectFileSearchEntry] {
        let resolvedLimit = max(1, min(limit, 100))
        return try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/files/search"
                + "?q=\(BackendHTTPClient.encodeQueryValue(query))&limit=\(resolvedLimit)"
        )
    }

    public func fetchProjectFileContent(projectId: String, path: String) async throws -> ProjectFileContentResponse {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/files/content?path=\(BackendHTTPClient.encodeQueryValue(trimmedPath))"
        )
    }

    public func fetchProjectWorkingTreeSourceControl(
        projectId: String,
        taskId: String? = nil
    ) async throws -> ProjectWorkingTreeSourceControlResponse {
        let taskQuery = taskId.map {
            "?taskId=\(BackendHTTPClient.encodeQueryValue($0))"
        } ?? ""
        return try await http.get(
            "/v1/projects/\(BackendHTTPClient.encodePathSegment(projectId))/source-control/working-tree\(taskQuery)"
        )
    }
}

public actor AgentService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func fetchAgents() async throws -> [APIAgentRecord] {
        try await http.get("/v1/agents")
    }

    public func fetchAgent(id: String) async throws -> APIAgentRecord {
        try await http.get("/v1/agents/\(BackendHTTPClient.encodePathSegment(id))")
    }

    public func fetchAgentTasks(agentId: String) async throws -> [APIAgentTaskRecord] {
        try await http.get("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/tasks")
    }

    public func fetchAgentFiles(agentId: String, path: String = "") async throws -> [ProjectFileEntry] {
        let encodedAgent = BackendHTTPClient.encodePathSegment(agentId)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedPath.isEmpty
            ? ""
            : "?path=\(BackendHTTPClient.encodeQueryValue(trimmedPath))"
        return try await http.get("/v1/agents/\(encodedAgent)/files\(query)")
    }

    public func fetchAgentFileContent(agentId: String, path: String) async throws -> ProjectFileContentResponse {
        let encodedAgent = BackendHTTPClient.encodePathSegment(agentId)
        let encodedPath = BackendHTTPClient.encodeQueryValue(path.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await http.get("/v1/agents/\(encodedAgent)/files/content?path=\(encodedPath)")
    }

    public func fetchAgentTokenUsage(agentId: String) async throws -> AgentTokenUsageResponse {
        try await http.get("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/token-usage")
    }

    public func fetchAgentSkills(agentId: String) async throws -> AgentSkillsResponse {
        try await http.get("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/skills")
    }

    public func fetchSkillsRegistry(
        search: String = "",
        sort: String = "installs",
        limit: Int = 40,
        offset: Int = 0
    ) async throws -> SkillsRegistryResponse {
        var query = [
            "sort=\(BackendHTTPClient.encodeQueryValue(sort))",
            "limit=\(max(1, limit))",
            "offset=\(max(0, offset))",
        ]
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            query.insert("search=\(BackendHTTPClient.encodeQueryValue(trimmedSearch))", at: 0)
        }
        return try await http.get("/v1/skills/registry?\(query.joined(separator: "&"))")
    }

    public func installAgentSkill(
        agentId: String,
        request: AgentSkillInstallRequest
    ) async throws -> InstalledAgentSkill {
        try await http.post(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/skills",
            body: request
        )
    }

    public func uninstallAgentSkill(agentId: String, skillId: String) async throws {
        try await http.delete(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/skills/\(BackendHTTPClient.encodePathSegment(skillId))"
        )
    }

    public func fetchChatSlashCommands(agentId: String) async throws -> AgentChatSlashCommandsResponse {
        try await http.get("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/chat-slash-commands")
    }
}

public actor SessionService {
    private let http: BackendHTTPClient

    public enum SessionControlAction: String, Encodable, Sendable {
        case interrupt
        case interruptTree = "interruptTree"
    }

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func fetchAgentSessions(
        agentId: String,
        projectId: String? = nil,
        limit: Int? = nil
    ) async throws -> [ChatSessionSummary] {
        var path = "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions"
        var queryItems: [String] = []
        if let projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !projectId.isEmpty {
            queryItems.append("projectId=\(BackendHTTPClient.encodeQueryValue(projectId))")
        }
        if let limit {
            queryItems.append("limit=\(max(0, limit))")
        }
        if !queryItems.isEmpty {
            path += "?\(queryItems.joined(separator: "&"))"
        }
        return try await http.get(path)
    }

    public func fetchAgentSession(agentId: String, sessionId: String) async throws -> ChatSessionDetail {
        try await http.get("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))")
    }

    public func fetchAgentSessionData(agentId: String, sessionId: String) async throws -> Data {
        try await http.getData("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))")
    }

    public func createAgentSession(
        agentId: String,
        title: String? = nil,
        parentSessionId: String? = nil,
        projectId: String? = nil,
        taskId: String? = nil,
        workspaceId: String? = nil
    ) async throws -> ChatSessionSummary {
        struct Payload: Encodable {
            var title: String?
            var parentSessionId: String?
            var kind: String = "chat"
            var projectId: String?
            var taskId: String?
            var workspaceId: String?
        }
        let normalizedProjectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTaskId = taskId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkspaceId = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await http.post(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions",
            body: Payload(
                title: title,
                parentSessionId: parentSessionId,
                projectId: normalizedProjectId?.isEmpty == false ? normalizedProjectId : nil,
                taskId: normalizedTaskId?.isEmpty == false ? normalizedTaskId : nil,
                workspaceId: normalizedWorkspaceId?.isEmpty == false ? normalizedWorkspaceId : nil
            )
        )
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
        struct Payload: Encodable {
            var userId: String
            var content: String
            var attachments: [ChatAttachmentUpload]
            var spawnSubSession: Bool = false
            var selectedModel: String?
            var reasoningEffort: String?
            var clientMessageId: String?
        }
        let normalizedSelectedModel = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: ChatSessionMessageReceipt = try await http.post(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))/messages",
            body: Payload(
                userId: userId,
                content: content,
                attachments: attachments,
                selectedModel: normalizedSelectedModel?.isEmpty == false ? normalizedSelectedModel : nil,
                reasoningEffort: normalizedReasoningEffort?.isEmpty == false ? normalizedReasoningEffort : nil,
                clientMessageId: clientMessageId
            )
        )
        return response
    }

    public func answerInputRequest(
        agentId: String,
        sessionId: String,
        requestId: String,
        request: ChatPlanInputAnswerRequest
    ) async throws -> ChatSessionSummary {
        struct Response: Decodable {
            var summary: ChatSessionSummary
        }

        let response: Response = try await http.post(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))/input-requests/\(BackendHTTPClient.encodePathSegment(requestId))/answer",
            body: request
        )
        return response.summary
    }

    public func deleteAgentSession(agentId: String, sessionId: String) async throws {
        try await http.delete("/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))")
    }

    public func controlAgentSession(
        agentId: String,
        sessionId: String,
        action: SessionControlAction,
        requestedBy: String = "apple-client",
        reason: String? = nil
    ) async throws {
        struct Payload: Encodable {
            var action: SessionControlAction
            var requestedBy: String
            var reason: String?
        }

        try await http.post(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))/control",
            body: Payload(action: action, requestedBy: requestedBy, reason: reason)
        )
    }
}

public actor MeshService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func listNodes() async throws -> [MeshNodeRecord] {
        try await http.get("/v1/node/mesh/nodes")
    }

    public func acceptInvite(_ request: MeshInviteAcceptRequest) async throws -> MeshNodeRecord {
        struct Response: Decodable {
            var id: String
            var name: String
            var publicKey: String
            var roles: [String]
            var endpoint: String?
            var status: MeshNodeStatus
            var lastSeenAt: Date
            var capabilities: [String]
        }

        let response: Response = try await http.post("/v1/node/mesh/invites/accept", body: request)
        return MeshNodeRecord(
            id: response.id,
            name: response.name,
            publicKey: response.publicKey,
            roles: response.roles,
            endpoint: response.endpoint,
            status: response.status,
            lastSeenAt: response.lastSeenAt,
            capabilities: response.capabilities
        )
    }

    public func listTasks(projectId: String?) async throws -> [MeshTaskRecord] {
        let encodedProjectId = projectId.flatMap(BackendHTTPClient.encodeQueryValue) ?? ""
        let path = encodedProjectId.isEmpty ? "/v1/node/mesh/tasks" : "/v1/node/mesh/tasks?projectId=\(encodedProjectId)"
        return try await http.get(path)
    }

    public func createTask(_ request: MeshTaskCreateRequest) async throws -> MeshTaskRecord {
        try await http.post("/v1/node/mesh/tasks", body: request)
    }
}

public actor ConfigService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func fetchConfig() async throws -> SloppyConfig {
        try await http.get("/v1/config")
    }

    public func fetchAvailableModels() async throws -> [ChatModelOption] {
        try await http.get("/v1/providers/models")
    }

    public func fetchProviderModels(
        providerId: String,
        apiKey: String? = nil,
        apiUrl: String? = nil
    ) async throws -> [ChatModelOption] {
        switch providerId {
        case "openai-api", "openai-oauth":
            let response: ProviderModelsResponse = try await http.post(
                "/v1/providers/openai/models",
                body: OpenAIProviderModelsPayload(
                    authMethod: providerId == "openai-oauth" ? "deeplink" : "api_key",
                    apiKey: apiKey,
                    apiUrl: apiUrl
                )
            )
            return response.models
        default:
            let response: ProviderModelsResponse = try await http.post(
                "/v1/providers/probe",
                body: ProviderProbePayload(
                    providerId: providerId,
                    apiKey: apiKey,
                    apiUrl: apiUrl
                )
            )
            if response.ok == false {
                throw ProviderCatalogError(message: response.message ?? "Could not load the provider catalog.")
            }
            return response.models
        }
    }

    public func updateConfig(_ config: SloppyConfig) async throws -> SloppyConfig {
        try await http.put("/v1/config", body: config)
    }

    public func fetchAccessUsers(platform: String? = nil) async throws -> [AccessUser] {
        let trimmed = platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (trimmed?.isEmpty == false) ? "?platform=\(BackendHTTPClient.encodeQueryValue(trimmed!))" : ""
        return try await http.get("/v1/channel-approvals/users\(query)")
    }

    public func deleteAccessUser(_ userId: String) async throws {
        try await http.delete("/v1/channel-approvals/users/\(BackendHTTPClient.encodePathSegment(userId))")
    }
}

private struct OpenAIProviderModelsPayload: Encodable {
    var authMethod: String
    var apiKey: String?
    var apiUrl: String?
}

private struct ProviderProbePayload: Encodable {
    var providerId: String
    var apiKey: String?
    var apiUrl: String?
}

private struct ProviderModelsResponse: Decodable {
    var models: [ChatModelOption]
    var ok: Bool?
    var message: String?
}

private struct ProviderCatalogError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
