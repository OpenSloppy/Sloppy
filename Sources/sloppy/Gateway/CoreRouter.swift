import Foundation
import Tracing
import Metrics
import SloppyConsoleProtocol
import Logging
import AgentRuntime
import Protocols
import PluginSDK
import SloppyNodeCore

private struct TraceHeaderExtractor: Extractor {
    func extract(key: String, from carrier: [String: String]) -> String? {
        carrier.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

/// Minimal transport-agnostic response type used by sloppy router handlers.
public struct CoreRouterResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var headers: [String: String]
    public var sseStream: AsyncStream<CoreRouterServerSentEvent>?

    public init(
        status: Int,
        body: Data,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        sseStream: AsyncStream<CoreRouterServerSentEvent>? = nil
    ) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.headers = headers
        self.sseStream = sseStream
    }
}

public struct CoreRouterServerSentEvent: Sendable {
    public var event: String
    public var data: Data
    public var id: String?

    public init(event: String, data: Data, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

public enum HTTPRouteMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct RouteMetadata: Sendable {
    public var summary: String?
    public var description: String?
    public var tags: [String]?

    public init(summary: String? = nil, description: String? = nil, tags: [String]? = nil) {
        self.summary = summary
        self.description = description
        self.tags = tags
    }
}

/// Typed request object passed into router callbacks.
public struct HTTPRequest: Sendable {
    public var method: HTTPRouteMethod
    public var path: String
    public var segments: [String]
    public var params: [String: String]
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data?
    public var remoteAddress: String?
    public var consoleContext: ConsoleAuthorizationContext?

    public init(
        method: HTTPRouteMethod,
        path: String,
        segments: [String],
        params: [String: String] = [:],
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        remoteAddress: String? = nil,
        consoleContext: ConsoleAuthorizationContext? = nil
    ) {
        self.method = method
        self.path = path
        self.segments = segments
        self.params = params
        self.query = query
        self.headers = headers.reduce(into: [:]) { partialResult, item in
            partialResult[item.key.lowercased()] = item.value
        }
        self.body = body
        self.remoteAddress = remoteAddress
        self.consoleContext = consoleContext
    }

    public func pathParam(_ key: String) -> String? {
        params[key]
    }

    public func queryParam(_ key: String) -> String? {
        query[key]
    }

    public func header(_ key: String) -> String? {
        headers[key.lowercased()]
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let body else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: body)
    }
}

/// WebSocket-style placeholder callback context for future transport integration.
public struct WebSocketConnectionContext: Sendable {
    private let sendTextBody: @Sendable (String) async -> Bool
    private let closeBody: @Sendable () async -> Void
    private let incomingMessagesBody: @Sendable () -> AsyncStream<String>

    public init(
        sendText: @escaping @Sendable (String) async -> Bool,
        close: @escaping @Sendable () async -> Void,
        incomingMessages: @escaping @Sendable () -> AsyncStream<String>
    ) {
        self.sendTextBody = sendText
        self.closeBody = close
        self.incomingMessagesBody = incomingMessages
    }

    public func sendText(_ text: String) async -> Bool {
        await sendTextBody(text)
    }

    public func close() async {
        await closeBody()
    }

    public func incomingMessages() -> AsyncStream<String> {
        incomingMessagesBody()
    }
}

enum CoreRouterConstants {
    static let emptyJSONData = Data("{}".utf8)
}

enum HTTPStatus {
    static let ok = 200
    static let created = 201
    static let seeOther = 303
    static let temporaryRedirect = 307
    static let badRequest = 400
    static let unauthorized = 401
    static let forbidden = 403
    static let conflict = 409
    static let notFound = 404
    static let internalServerError = 500
}

enum ErrorCode {
    static let invalidBody = "invalid_body"
    static let unauthorized = "unauthorized"
    static let notFound = "not_found"
    static let artifactNotFound = "artifact_not_found"
    static let artifactCreateFailed = "artifact_create_failed"
    static let artifactReadFailed = "artifact_read_failed"
    static let configWriteFailed = "config_write_failed"
    static let invalidAgentId = "invalid_agent_id"
    static let invalidAgentPayload = "invalid_agent_payload"
    static let agentAlreadyExists = "agent_already_exists"
    static let agentNotFound = "agent_not_found"
    static let agentCreateFailed = "agent_create_failed"
    static let agentsListFailed = "agents_list_failed"
    static let agentMemoryReadFailed = "agent_memory_read_failed"
    static let agentMemoryUpdateFailed = "agent_memory_update_failed"
    static let agentMemoryDeleteFailed = "agent_memory_delete_failed"
    static let agentMemoryNotFound = "agent_memory_not_found"
    static let invalidSessionId = "invalid_session_id"
    static let invalidSessionPayload = "invalid_session_payload"
    static let sessionNotFound = "session_not_found"
    static let sessionCreateFailed = "session_create_failed"
    static let sessionListFailed = "session_list_failed"
    static let sessionLoadFailed = "session_load_failed"
    static let sessionDeleteFailed = "session_delete_failed"
    static let sessionWriteFailed = "session_write_failed"
    static let sessionStreamFailed = "session_stream_failed"
    static let invalidAgentConfigPayload = "invalid_agent_config_payload"
    static let invalidAgentModel = "invalid_agent_model"
    static let agentConfigReadFailed = "agent_config_read_failed"
    static let agentConfigWriteFailed = "agent_config_write_failed"
    static let invalidAgentToolsPayload = "invalid_agent_tools_payload"
    static let invalidToolInvocationPayload = "invalid_tool_invocation_payload"
    static let agentToolsReadFailed = "agent_tools_read_failed"
    static let agentToolsWriteFailed = "agent_tools_write_failed"
    static let toolForbidden = "tool_forbidden"
    static let toolInvokeFailed = "tool_invoke_failed"
    static let systemLogsReadFailed = "system_logs_read_failed"
    static let issueReportFailed = "issue_report_failed"
    static let invalidActorPayload = "invalid_actor_payload"
    static let actorNotFound = "actor_not_found"
    static let linkNotFound = "link_not_found"
    static let teamNotFound = "team_not_found"
    static let actorProtected = "actor_protected"
    static let actorBoardReadFailed = "actor_board_read_failed"
    static let actorBoardWriteFailed = "actor_board_write_failed"
    static let actorRouteFailed = "actor_route_failed"
    static let invalidProjectId = "invalid_project_id"
    static let invalidProjectPayload = "invalid_project_payload"
    static let invalidProjectTaskId = "invalid_project_task_id"
    static let invalidProjectChannelId = "invalid_project_channel_id"
    static let projectNotFound = "project_not_found"
    static let projectConflict = "project_conflict"
    static let projectCreateFailed = "project_create_failed"
    static let projectUpdateFailed = "project_update_failed"
    static let projectDeleteFailed = "project_delete_failed"
    static let projectListFailed = "project_list_failed"
    static let projectReadFailed = "project_read_failed"
    static let projectMemoryReadFailed = "project_memory_read_failed"
    static let projectContextRefreshFailed = "project_context_refresh_failed"
    static let invalidPluginId = "invalid_plugin_id"
    static let invalidPluginPayload = "invalid_plugin_payload"
    static let pluginNotFound = "plugin_not_found"
    static let pluginConflict = "plugin_conflict"
    static let pluginInstallFailed = "plugin_install_failed"
    static let skillsRegistryFailed = "skills_registry_failed"
    static let skillsListFailed = "skills_list_failed"
    static let skillsInstallFailed = "skills_install_failed"
    static let skillsUninstallFailed = "skills_uninstall_failed"
    static let skillNotFound = "skill_not_found"
    static let skillAlreadyExists = "skill_already_exists"
    static let tokenUsageReadFailed = "token_usage_read_failed"
}

struct AcceptResponse: Encodable {
    let accepted: Bool
}

struct WorkerCreateResponse: Encodable {
    let workerId: String
}

struct WorkerCancelRequest: Decodable {
    var reason: String?

    init(reason: String? = nil) {
        self.reason = reason
    }
}

struct WorkerCancelResponse: Encodable {
    let workerId: String
    let cancelled: Bool
}

public enum RoutePathSegment: Equatable {
    case literal(String)
    case parameter(String)
    case catchAll(String)
}

public struct RouteDefinition {
    public typealias Callback = (HTTPRequest) async -> CoreRouterResponse

    public let method: HTTPRouteMethod
    public let path: String
    public let segments: [RoutePathSegment]
    public let callback: Callback
    public let metadata: RouteMetadata?

    public init(method: HTTPRouteMethod, path: String, metadata: RouteMetadata? = nil, callback: @escaping Callback) {
        self.method = method
        self.path = path
        self.segments = parseRoutePath(path)
        self.callback = callback
        self.metadata = metadata
    }

    public func match(pathSegments: [String]) -> [String: String]? {
        var params: [String: String] = [:]
        var pathIndex = 0
        for pattern in segments {
            if case .catchAll(let key) = pattern {
                params[key] = pathSegments.dropFirst(pathIndex).joined(separator: "/")
                return params
            }
            guard pathIndex < pathSegments.count else { return nil }
            let value = pathSegments[pathIndex]
            switch pattern {
            case .literal(let literal):
                guard literal == value else {
                    return nil
                }
            case .parameter(let key):
                params[key] = value
            case .catchAll:
                break
            }
            pathIndex += 1
        }
        return pathIndex == pathSegments.count ? params : nil
    }
}

private struct WebSocketRouteDefinition {
    typealias Validator = (HTTPRequest) async -> Bool
    typealias Callback = (HTTPRequest, WebSocketConnectionContext) async -> Void

    let segments: [RoutePathSegment]
    let validator: Validator
    let callback: Callback

    init(path: String, validator: @escaping Validator, callback: @escaping Callback) {
        self.segments = parseRoutePath(path)
        self.validator = validator
        self.callback = callback
    }

    func match(pathSegments: [String]) -> [String: String]? {
        guard segments.count == pathSegments.count else {
            return nil
        }

        var params: [String: String] = [:]
        for (pattern, value) in zip(segments, pathSegments) {
            switch pattern {
            case .literal(let literal):
                guard literal == value else {
                    return nil
                }
            case .parameter(let key):
                params[key] = value
            case .catchAll:
                return nil
            }
        }
        return params
    }
}

public actor CoreRouter {
    static let logger = Logger.sloppy(label: "sloppy.core.router")
    let service: CoreService
    private var routes: [RouteDefinition]
    private var webSocketRoutes: [WebSocketRouteDefinition]

    public init(service: CoreService) {
        self.service = service
        self.routes = Self.defaultRoutes(service: service)
        self.webSocketRoutes = Self.defaultWebSocketRoutes(service: service)
    }

    /// Registers generic HTTP route callback.
    public func register(
        path: String,
        method: HTTPRouteMethod,
        metadata: RouteMetadata? = nil,
        callback: @escaping (HTTPRequest) async -> CoreRouterResponse
    ) {
        routes.append(.init(method: method, path: path, metadata: metadata, callback: callback))
    }

    public func get(_ path: String, metadata: RouteMetadata? = nil, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .get, metadata: metadata, callback: callback)
    }

    public func head(_ path: String, metadata: RouteMetadata? = nil, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .head, metadata: metadata, callback: callback)
    }

    public func post(_ path: String, metadata: RouteMetadata? = nil, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .post, metadata: metadata, callback: callback)
    }

    public func put(_ path: String, metadata: RouteMetadata? = nil, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .put, metadata: metadata, callback: callback)
    }

    public func patch(_ path: String, metadata: RouteMetadata? = nil, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .patch, metadata: metadata, callback: callback)
    }

    public func delete(_ path: String, metadata: RouteMetadata? = nil, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .delete, metadata: metadata, callback: callback)
    }

    /// WebSocket-like registration API (transport integration to be wired in CoreHTTPServer later).
    public func webSocket(
        _ path: String,
        validator: @escaping (HTTPRequest) async -> Bool = { _ in true },
        callback: @escaping (HTTPRequest, WebSocketConnectionContext) async -> Void
    ) {
        webSocketRoutes.append(.init(path: path, validator: validator, callback: callback))
    }

    public func canHandleWebSocket(path: String, headers: [String: String] = [:], remoteAddress: String? = nil) async -> Bool {
        if let route = matchedWebSocketRoute(for: path, headers: headers, remoteAddress: remoteAddress) {
            return await route.definition.validator(route.request)
        }
        return false
    }

    public func handleWebSocket(
        path: String,
        headers: [String: String] = [:],
        connection: WebSocketConnectionContext,
        remoteAddress: String? = nil,
        consoleContext: ConsoleAuthorizationContext? = nil
    ) async -> Bool {
        guard let route = matchedWebSocketRoute(for: path, headers: headers, remoteAddress: remoteAddress) else {
            return false
        }
        var request = route.request
        request.consoleContext = consoleContext
        if let context = consoleContext {
            guard !path.hasPrefix("/v1/node/mesh/") else { return false }
            do { try context.require(path == "/v1/dashboard/terminal/ws" ? .terminal : .read) } catch { return false }
            let authorization = AuthorizationRequest(subject: AuthorizationSubject(userID: context.accountID.uuidString, role: .admin, groups: context.organizationID.map { [$0.uuidString] } ?? [], identityProviderID: "sloppy_console"), action: "websocket:" + path, resource: AuthorizationResource(kind: "websocket", id: path))
            guard await service.evaluateEnterpriseAuthorization(authorization).allowed else { return false }
        } else if !(await route.definition.validator(request)) { return false }
        await route.definition.callback(request, connection)
        return true
    }

    public func generateOpenAPISpec() async throws -> Data {
        let spec = OpenAPIGenerator.generate(routes: routes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(spec)
    }

    /// Routes incoming HTTP-like request into registered sloppy handlers.
    public func handle(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String] = [:],
        remoteAddress: String? = nil,
        consoleContext: ConsoleAuthorizationContext? = nil
    ) async -> CoreRouterResponse {
        let started = ContinuousClock.now
        let httpMethod = HTTPRouteMethod(rawValue: method.uppercased())
        let metricMethod = httpMethod?.rawValue ?? "OTHER"
        let segments = splitPath(path)
        let routeName = routes.first { $0.method == httpMethod && $0.match(pathSegments: segments) != nil }?.path ?? "unmatched"
        var traceContext = ServiceContext.topLevel
        InstrumentationSystem.instrument.extract(headers, into: &traceContext, using: TraceHeaderExtractor())
        return await withSpan("\(metricMethod) \(routeName)", context: traceContext, ofKind: .server) { span in
            span.attributes["http.request.method"] = metricMethod
            span.attributes["http.route"] = routeName
            var response = await handleRequest(method: method, path: path, body: body, headers: headers, remoteAddress: remoteAddress, consoleContext: consoleContext)
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            span.attributes["http.response.status_code"] = response.status
            if response.status >= 500 { span.setStatus(.init(code: .error)) }
            let dimensions = [("http.request.method", metricMethod), ("http.route", routeName), ("http.response.status_code", String(response.status))]
            Metrics.Timer(label: "http.server.request.duration", dimensions: dimensions + [("unit", "s")]).recordNanoseconds(Int64(seconds * 1e9))
            Counter(label: "sloppy.http.requests", dimensions: dimensions).increment()
            response.headers["x-sloppy-route"] = routeName
            response.headers["server-timing"] = String(format: "core;dur=%.2f", seconds * 1000)
            return response
        }
    }

    private func handleRequest(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String],
        remoteAddress: String?,
        consoleContext: ConsoleAuthorizationContext?
    ) async -> CoreRouterResponse {
        if await service.consoleTrustUnavailable { return Self.json(status: 503, payload: ["error": "console_trust_unavailable"]) }
        guard let httpMethod = HTTPRouteMethod(rawValue: method.uppercased()) else {
            return Self.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }

        let queryParams = parseQueryString(from: path)
        let pathSegments = splitPath(path)
        for route in routes where route.method == httpMethod {
            guard let params = route.match(pathSegments: pathSegments) else {
                continue
            }

            let request = HTTPRequest(
                method: httpMethod,
                path: path,
                segments: pathSegments,
                params: params,
                query: queryParams,
                headers: headers,
                body: body,
                remoteAddress: remoteAddress,
                consoleContext: consoleContext
            )
            let allowsUnauthenticatedLocalPluginInstall = Self.allowsUnauthenticatedLocalPluginInstall(request)
            // Transport labels and user-context headers never establish identity.
            let isTrustedMeshRequest = false
            if let consoleContext {
                do {
                    let permission: InstancePermission
                    if httpMethod == .get || httpMethod == .head { permission = .read }
                    else if route.path == "/v1/projects/:projectId/emergency-stop" { permission = .runAgents }
                    else { permission = .write }
                    try consoleContext.require(permission, projectID: request.pathParam("projectId"))
                    guard let actor = await Self.identityActor(for: request, service: service), !Self.requiresAdminIdentity(request) || actor.user.role == .admin else { return Self.json(status: 403, payload: ["error": "console_access_denied"]) }
                    let authorization = AuthorizationRequest(subject: AuthorizationSubject(userID: actor.user.id, role: actor.user.role, groups: actor.groups, identityProviderID: actor.identityProviderID), action: "\(request.method.rawValue.lowercased()):\(route.path)", resource: AuthorizationResource(kind: "http_route", id: route.path, projectID: request.pathParam("projectId")))
                    let decision = await service.evaluateEnterpriseAuthorization(authorization)
                    guard decision.allowed else { return Self.json(status: 403, payload: ["error": "console_access_denied"]) }
                    return await route.callback(request)
                } catch { return Self.json(status: HTTPStatus.forbidden, payload: ["error": "console_access_denied"]) }
            }
            if await service.identityAuthEnabled(), !isTrustedMeshRequest {
                let isEnterprisePublicRoute = await service.isEnterprisePublicIdentityRoute(
                    method: request.method.rawValue,
                    path: "/" + request.segments.joined(separator: "/")
                )
                if !Self.isPublicIdentityRoute(request)
                    && !isEnterprisePublicRoute
                    && !allowsUnauthenticatedLocalPluginInstall {
                    guard let actor = await Self.identityActor(for: request, service: service) else {
                        return Self.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
                    }
                    if Self.requiresAdminIdentity(request), actor.user.role != .admin {
                        return Self.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
                    }
                    let authorizationRequest = AuthorizationRequest(
                        subject: AuthorizationSubject(
                            userID: actor.user.id,
                            role: actor.user.role,
                            groups: actor.groups,
                            identityProviderID: actor.identityProviderID
                        ),
                        action: "\(request.method.rawValue.lowercased()):\(route.path)",
                        resource: AuthorizationResource(
                            kind: "http_route",
                            id: route.path,
                            projectID: request.pathParam("projectId")
                        )
                    )
                    let decision = await service.evaluateEnterpriseAuthorization(authorizationRequest)
                    if !decision.allowed {
                        await service.recordEnterpriseAudit(
                            AuditEvent(
                                actorID: actor.user.id,
                                action: authorizationRequest.action,
                                resourceKind: authorizationRequest.resource.kind,
                                resourceID: authorizationRequest.resource.id,
                                outcome: .denied,
                                metadata: [
                                    "reason": .string(decision.reason ?? "policy_denied"),
                                ]
                            )
                        )
                        return Self.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
                    }
                }
            } else if !isTrustedMeshRequest {
                let requiresDashboardAuthorization = await shouldRequireDashboardAuthorization(for: request)
                let hasValidDashboardAuthorization = await service
                    .validateDashboardAuthorizationHeader(request.header("authorization"))
                if requiresDashboardAuthorization
                    && !hasValidDashboardAuthorization
                    && !allowsUnauthenticatedLocalPluginInstall {
                    return Self.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
                }
            }
            let isOnboardingFlow = Self.shouldLogOnboardingFlow(httpMethod: httpMethod, pathSegments: pathSegments, body: body)
            if isOnboardingFlow {
                Self.logger.debug(
                    "onboarding.flow.request",
                    metadata: [
                        "method": .string(httpMethod.rawValue),
                        "path": .string(path),
                        "query": .string(queryParams.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&"))
                    ]
                )
            }

            let response = await route.callback(request)
            if isOnboardingFlow {
                Self.logger.debug(
                    "onboarding.flow.response",
                    metadata: [
                        "method": .string(httpMethod.rawValue),
                        "path": .string(path),
                        "status": .stringConvertible(response.status),
                        "content_type": .string(response.contentType),
                        "body_preview": .string(Self.responseBodyPreview(response.body))
                    ]
                )
            }
            return response
        }

        return Self.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
    }

    private static func shouldLogOnboardingFlow(httpMethod: HTTPRouteMethod, pathSegments: [String], body: Data?) -> Bool {
        guard pathSegments.first == "v1" else {
            return false
        }

        let path = "/" + pathSegments.joined(separator: "/")
        let exactOnboardingPaths = Set([
            "/v1/config",
            "/v1/projects",
            "/v1/providers/probe",
            "/v1/providers/openai/status",
            "/v1/providers/openai/models",
            "/v1/providers/openai/oauth/start",
            "/v1/providers/openai/oauth/complete",
            "/v1/providers/openai/oauth/device-code/start",
            "/v1/providers/openai/oauth/device-code/poll",
            "/v1/providers/anthropic/status",
            "/v1/providers/anthropic/oauth/start",
            "/v1/providers/anthropic/oauth/complete",
            "/v1/providers/anthropic/oauth/import-claude",
            "/v1/providers/gemini/status",
            "/v1/providers/gemini/oauth/start",
            "/v1/providers/gemini/oauth/complete",
            "/v1/providers/gemini/oauth/disconnect",
            "/v1/agents",
            "/v1/generate"
        ])
        if exactOnboardingPaths.contains(path) {
            return true
        }

        if pathSegments.count == 3, pathSegments[1] == "projects", httpMethod == .get {
            return true
        }
        if pathSegments.count == 3, pathSegments[1] == "agents", httpMethod == .get {
            return true
        }
        if pathSegments.count == 4, pathSegments[1] == "agents", pathSegments[3] == "config" {
            return true
        }
        if pathSegments.count == 4, pathSegments[1] == "agents", pathSegments[3] == "sessions", httpMethod == .post {
            return true
        }
        if pathSegments.count == 6,
           pathSegments[1] == "agents",
           pathSegments[3] == "sessions",
           pathSegments[5] == "messages",
           httpMethod == .post {
            return bodyContainsOnboardingUser(body)
        }

        return false
    }

    private static func bodyContainsOnboardingUser(_ body: Data?) -> Bool {
        guard let body,
              let text = String(data: body, encoding: .utf8)
        else {
            return false
        }
        return text.localizedCaseInsensitiveContains("\"userId\":\"onboarding\"")
            || text.localizedCaseInsensitiveContains("\"userId\": \"onboarding\"")
    }

    private static func responseBodyPreview(_ body: Data, maxLength: Int = 240) -> String {
        guard var text = String(data: body, encoding: .utf8) else {
            return "<non-utf8 body>"
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + "..."
        }
        return text
    }

    static func identityActor(for request: HTTPRequest, service: CoreService) async -> AuthenticatedUserContext? {
        if let context = request.consoleContext, context.expiresAt > Date() {
            let localID = await service.consoleTrustStore?.localUserID(accountID: context.accountID)
            if let localID, let profile = await service.identityAuthService.profile(id: localID), profile.status != .active { return nil }
            return AuthenticatedUserContext(user: AuthUserProfile(id: localID ?? context.accountID.uuidString, login: context.accountID.uuidString, name: "Sloppy Console", role: context.permissions.contains(.administer) ? .admin : .user), groups: context.organizationID.map { [$0.uuidString] } ?? [], identityProviderID: "sloppy_console")
        }
        return await service.authenticateIdentityAccessToken(Self.bearerToken(from: request.header("authorization")))
    }

    private static func bearerToken(from headerValue: String?) -> String? {
        let trimmed = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }
        let parts = trimmed
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        return parts[1]
    }

    private static func isPublicIdentityRoute(_ request: HTTPRequest) -> Bool {
        guard request.segments.first == "v1" else {
            return true
        }
        if request.method == .get,
           request.segments == ["v1", "auth", "challenge"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "auth", "bootstrap"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "auth", "login"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "auth", "refresh"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "auth", "device-pairing", "redeem"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "auth", "register"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "auth", "password-reset"] {
            return true
        }
        if request.method == .post,
           request.segments == ["v1", "node", "mesh", "invites", "accept"] {
            return true
        }
        return false
    }

    private static func requiresAdminIdentity(_ request: HTTPRequest) -> Bool {
        guard request.segments.first == "v1" else {
            return false
        }
        if request.segments.dropFirst().first == "migrations" {
            return true
        }
        if request.segments.dropFirst().first == "config" {
            return true
        }
        if request.segments.dropFirst().first == "agent-plugins", request.method != .get {
            return true
        }
        if request.segments.dropFirst().first == "agent-plugin-registries", request.method != .get {
            return true
        }
        if request.segments.starts(with: ["v1", "auth", "invites"]) {
            return true
        }
        if request.segments == ["v1", "auth", "mode"] {
            return true
        }
        if request.segments.starts(with: ["v1", "node", "mesh"]),
           request.method != .get {
            return request.segments != ["v1", "node", "mesh", "invites", "accept"]
        }
        return false
    }

    private static func allowsUnauthenticatedLocalPluginInstall(_ request: HTTPRequest) -> Bool {
        guard request.method == .post,
              request.segments == ["v1", "plugins", "install"]
        else {
            return false
        }

        let rawAddress = request.remoteAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedAddress = rawAddress
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "::ffff:", with: "")
        return normalizedAddress == "127.0.0.1" || normalizedAddress == "::1"
    }

    private static func defaultWebSocketRoutes(service: CoreService) -> [WebSocketRouteDefinition] {
        var routes: [WebSocketRouteDefinition] = []
        let nodeMeshRelay = NodeMeshRelay(store: service.nodeMeshStore)
        routes.append(.init(
            path: "/v1/agents/:agentId/sessions/:sessionId/launch/runs/:runId/preview/ws",
            validator: { request in
                await service.validateClientAuthorizationHeader(request.header("authorization"))
            },
            callback: { request, connection in
                await service.handleLaunchPreview(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", runID: request.pathParam("runId") ?? "", connection: connection)
            }
        ))
        routes.append(.init(
            path: "/v1/node/mesh/nodes/:nodeId/agents/:agentId/sessions/:sessionId/launch/runs/:runId/preview/ws",
            validator: { request in
                await service.validateClientAuthorizationHeader(request.header("authorization"))
            },
            callback: { request, connection in
                await service.forwardMeshLaunchPreview(nodeID: request.pathParam("nodeId") ?? "", agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", runID: request.pathParam("runId") ?? "", connection: connection)
            }
        ))

        routes.append(
            .init(
                path: "/v1/node/mesh/ws",
                validator: { _ in true },
                callback: { request, connection in
                    await nodeMeshRelay.attach(
                        connection: connection,
                        remoteAddress: request.remoteAddress
                    )
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/agents/:agentId/sessions/:sessionId/ws",
                validator: { request in
                    let agentId = request.pathParam("agentId") ?? ""
                    let sessionId = request.pathParam("sessionId") ?? ""
                    return await service.canStreamAgentSessionEvents(agentID: agentId, sessionID: sessionId)
                },
                callback: { request, connection in
                    let agentId = request.pathParam("agentId") ?? ""
                    let sessionId = request.pathParam("sessionId") ?? ""

                    do {
                        let stream = try await service.streamAgentSessionEvents(agentID: agentId, sessionID: sessionId)
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601

                        for await update in stream {
                            guard let payloadData = try? encoder.encode(update),
                                  let payload = String(data: payloadData, encoding: .utf8)
                            else {
                                continue
                            }

                            let sent = await connection.sendText(payload)
                            if !sent {
                                break
                            }
                        }
                    } catch {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        if let payloadData = try? encoder.encode(
                            AgentSessionStreamUpdate(
                                kind: .sessionError,
                                cursor: 0,
                                message: "Failed to stream session updates."
                            )
                        ), let payload = String(data: payloadData, encoding: .utf8) {
                            _ = await connection.sendText(payload)
                        }
                    }

                    await connection.close()
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/node/mesh/nodes/:nodeId/agents/:agentId/sessions/:sessionId/ws",
                validator: { request in
                    guard !(request.pathParam("nodeId") ?? "").isEmpty
                        && !(request.pathParam("agentId") ?? "").isEmpty
                        && !(request.pathParam("sessionId") ?? "").isEmpty else {
                        return false
                    }
                    return await service.validateClientAuthorizationHeader(
                        request.header("authorization")
                    )
                },
                callback: { request, connection in
                    let nodeID = request.pathParam("nodeId") ?? ""
                    let agentID = request.pathParam("agentId") ?? ""
                    let sessionID = request.pathParam("sessionId") ?? ""
                    do {
                        let stream = try await service.openMeshAgentSessionStream(
                            nodeID: nodeID,
                            agentID: agentID,
                            sessionID: sessionID
                        )
                        defer {
                            Task {
                                await service.closeMeshAgentSessionStream(streamID: stream.id, nodeID: nodeID)
                            }
                        }
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        for try await value in stream.messages {
                            guard let data = try? encoder.encode(value),
                                  let text = String(data: data, encoding: .utf8),
                                  await connection.sendText(text) else {
                                break
                            }
                        }
                    } catch {
                        Self.logger.warning(
                            "node.mesh.session-stream.failed",
                            metadata: [
                                "node_id": .string(nodeID),
                                "agent_id": .string(agentID),
                                "session_id": .string(sessionID),
                                "error": .string(String(describing: error)),
                            ]
                        )
                    }
                    await connection.close()
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/notifications/ws",
                validator: { _ in true },
                callback: { _, connection in
                    let stream = await service.notificationService.subscribe()
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601

                    for await notification in stream {
                        guard let data = try? encoder.encode(notification),
                              let text = String(data: data, encoding: .utf8)
                        else {
                            continue
                        }

                        let sent = await connection.sendText(text)
                        if !sent {
                            break
                        }
                    }

                    await connection.close()
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/dashboard/terminal/ws",
                validator: { _ in true },
                callback: { request, connection in
                    let encoder = JSONEncoder()
                    let decoder = JSONDecoder()
                    var isAuthenticated = request.consoleContext != nil
                    var authFailureCount = 0
                    var activeSessionID: String?
                    var forwardTask: Task<Void, Never>?

                    func send(_ payload: DashboardTerminalServerMessage) async -> Bool {
                        guard let data = try? encoder.encode(payload),
                              let text = String(data: data, encoding: .utf8)
                        else {
                            return false
                        }
                        return await connection.sendText(text)
                    }

                    func sendError(code: String, message: String) async {
                        Self.logger.warning(
                            "dashboard.terminal.error",
                            metadata: [
                                "code": .string(code),
                                "message": .string(message),
                                "session_id": .string(activeSessionID ?? "(none)"),
                                "remote_address": .string(request.remoteAddress ?? "(unknown)")
                            ]
                        )
                        _ = await send(
                            DashboardTerminalServerMessage(
                                type: "error",
                                sessionId: activeSessionID,
                                code: code,
                                message: message
                            )
                        )
                    }

                    func sendAuthError(message: String) async {
                        await sendError(code: ErrorCode.unauthorized, message: message)
                    }

                    defer {
                        forwardTask?.cancel()
                        if let activeSessionID {
                            Task {
                                await service.closeDashboardTerminalSession(sessionID: activeSessionID)
                            }
                        }
                    }

                    messageLoop: for await rawMessage in connection.incomingMessages() {
                        guard let payload = rawMessage.data(using: .utf8),
                              let message = try? decoder.decode(DashboardTerminalClientMessage.self, from: payload)
                        else {
                            Self.logger.warning(
                                "dashboard.terminal.message.malformed",
                                metadata: [
                                    "raw_prefix": .string(String(rawMessage.prefix(180))),
                                    "remote_address": .string(request.remoteAddress ?? "(unknown)")
                                ]
                            )
                            await sendError(code: "invalid_message", message: "Malformed terminal message.")
                            continue
                        }
                        Self.logger.debug(
                            "dashboard.terminal.message.received",
                            metadata: [
                                "type": .string(message.type.lowercased()),
                                "session_id": .string(activeSessionID ?? "(none)"),
                                "project_id": .string(message.projectId ?? ""),
                                "cols": .stringConvertible(message.cols ?? -1),
                                "rows": .stringConvertible(message.rows ?? -1),
                                "input_bytes": .stringConvertible(message.data?.utf8.count ?? 0)
                            ]
                        )

                        if !isAuthenticated {
                            if message.type.lowercased() == "auth" {
                                if await service.validateClientAuthToken(message.token) {
                                    isAuthenticated = true
                                    authFailureCount = 0
                                    _ = await send(DashboardTerminalServerMessage(type: "authenticated"))
                                } else {
                                    authFailureCount += 1
                                    await sendAuthError(message: "Invalid dashboard token.")
                                    if authFailureCount >= 2 {
                                        break messageLoop
                                    }
                                }
                                continue
                            }

                            authFailureCount += 1
                            await sendAuthError(message: "Authenticate with a dashboard token before using the terminal.")
                            if authFailureCount >= 2 {
                                break messageLoop
                            }
                            continue
                        }

                        switch message.type.lowercased() {
                        case "auth":
                            _ = await send(DashboardTerminalServerMessage(type: "authenticated", sessionId: activeSessionID))

                        case "start":
                            guard activeSessionID == nil else {
                                await sendError(code: "session_already_started", message: "Terminal session already started.")
                                continue
                            }
                            guard let cols = message.cols, let rows = message.rows else {
                                await sendError(code: "invalid_message", message: "Missing terminal dimensions.")
                                continue
                            }

                            do {
                                let started = try await service.startDashboardTerminalSession(
                                    projectID: message.projectId,
                                    cwd: message.cwd,
                                    cols: cols,
                                    rows: rows,
                                    remoteAddress: request.remoteAddress
                                )
                                activeSessionID = started.sessionID
                                Self.logger.info(
                                    "dashboard.terminal.started",
                                    metadata: [
                                        "session_id": .string(started.sessionID),
                                        "pid": .stringConvertible(started.pid),
                                        "cwd": .string(started.cwd),
                                        "remote_address": .string(request.remoteAddress ?? "(unknown)")
                                    ]
                                )
                                let readySent = await send(
                                    DashboardTerminalServerMessage(
                                        type: "ready",
                                        sessionId: started.sessionID,
                                        cwd: started.cwd,
                                        shell: started.shell,
                                        pid: started.pid
                                    )
                                )
                                guard readySent else {
                                    break
                                }

                                forwardTask = Task {
                                    for await event in started.events {
                                        let outbound: DashboardTerminalServerMessage
                                        switch event {
                                        case .output(let data):
                                            outbound = DashboardTerminalServerMessage(type: "output", sessionId: started.sessionID, data: data)
                                        case .exit(let exitCode):
                                            outbound = DashboardTerminalServerMessage(type: "exit", sessionId: started.sessionID, exitCode: exitCode)
                                        case .error(let code, let message):
                                            outbound = DashboardTerminalServerMessage(type: "error", sessionId: started.sessionID, code: code, message: message)
                                        case .closed:
                                            outbound = DashboardTerminalServerMessage(type: "closed", sessionId: started.sessionID)
                                        }

                                        guard await send(outbound) else {
                                            break
                                        }
                                    }
                                }
                            } catch CoreService.DashboardTerminalError.disabled {
                                await sendError(code: "disabled", message: "Dashboard terminal is disabled.")
                            } catch CoreService.DashboardTerminalError.remoteAccessDenied {
                                await sendError(code: "remote_access_denied", message: "Dashboard terminal is only available locally.")
                            } catch CoreService.DashboardTerminalError.invalidProjectID {
                                await sendError(code: "invalid_project_id", message: "Invalid project id.")
                            } catch CoreService.DashboardTerminalError.projectNotFound {
                                await sendError(code: "project_not_found", message: "Project workspace not found.")
                            } catch CoreService.DashboardTerminalError.invalidCwd {
                                await sendError(code: "invalid_cwd", message: "Terminal cwd must stay inside the workspace or project root.")
                            } catch CoreService.DashboardTerminalError.invalidPayload {
                                await sendError(code: "invalid_message", message: "Invalid terminal payload.")
                            } catch {
                                await sendError(code: "launch_failed", message: "Failed to start terminal session.")
                            }

                        case "input":
                            guard let activeSessionID else {
                                await sendError(code: "session_not_started", message: "Start a terminal session first.")
                                continue
                            }
                            do {
                                try await service.writeDashboardTerminalInput(sessionID: activeSessionID, data: message.data ?? "")
                            } catch {
                                await sendError(code: "write_failed", message: "Failed to write to terminal session.")
                            }

                        case "resize":
                            guard let activeSessionID else {
                                await sendError(code: "session_not_started", message: "Start a terminal session first.")
                                continue
                            }
                            guard let cols = message.cols, let rows = message.rows else {
                                await sendError(code: "invalid_message", message: "Missing terminal dimensions.")
                                continue
                            }
                            do {
                                try await service.resizeDashboardTerminalSession(sessionID: activeSessionID, cols: cols, rows: rows)
                            } catch {
                                await sendError(code: "resize_failed", message: "Failed to resize terminal session.")
                            }

                        case "close":
                            guard let sessionID = activeSessionID else {
                                break
                            }
                            Self.logger.info(
                                "dashboard.terminal.closed",
                                metadata: [
                                    "session_id": .string(sessionID),
                                    "remote_address": .string(request.remoteAddress ?? "(unknown)")
                                ]
                            )
                            await service.closeDashboardTerminalSession(sessionID: sessionID)
                            forwardTask?.cancel()
                            forwardTask = nil
                            activeSessionID = nil

                        case "ping":
                            _ = await send(DashboardTerminalServerMessage(type: "pong", sessionId: activeSessionID))

                        default:
                            await sendError(code: "invalid_message", message: "Unsupported terminal message type.")
                        }
                    }

                    await connection.close()
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/node/mesh/nodes/:nodeId/terminal/ws",
                validator: { request in
                    !(request.pathParam("nodeId") ?? "").isEmpty
                },
                callback: { request, connection in
                    let encoder = JSONEncoder()
                    let decoder = JSONDecoder()
                    var isAuthenticated = false
                    let targetNodeID = request.pathParam("nodeId") ?? ""
                    var activeStream: NodeMeshStream?
                    var forwardTask: Task<Void, Never>?

                    func send(_ message: DashboardTerminalServerMessage) async -> Bool {
                        guard let data = try? encoder.encode(message),
                              let text = String(data: data, encoding: .utf8) else {
                            return false
                        }
                        return await connection.sendText(text)
                    }

                    defer {
                        forwardTask?.cancel()
                        if let activeStream {
                            Task {
                                await service.closeMeshTerminalStream(
                                    streamID: activeStream.id,
                                    nodeID: targetNodeID
                                )
                            }
                        }
                    }

                    messageLoop: for await rawMessage in connection.incomingMessages() {
                        guard let data = rawMessage.data(using: .utf8),
                              let message = try? decoder.decode(DashboardTerminalClientMessage.self, from: data) else {
                            _ = await send(DashboardTerminalServerMessage(type: "error", code: "invalid_message", message: "Malformed terminal message."))
                            continue
                        }

                        if !isAuthenticated {
                            guard message.type.lowercased() == "auth",
                                  await service.validateClientAuthToken(message.token) else {
                                _ = await send(DashboardTerminalServerMessage(type: "error", code: ErrorCode.unauthorized, message: "Invalid dashboard token."))
                                break
                            }
                            isAuthenticated = true
                            _ = await send(DashboardTerminalServerMessage(type: "authenticated"))
                            continue
                        }

                        switch message.type.lowercased() {
                        case "start":
                            guard activeStream == nil else {
                                _ = await send(DashboardTerminalServerMessage(type: "error", code: "session_already_started", message: "Terminal session already started."))
                                continue
                            }
                            do {
                                let stream = try await service.openMeshTerminalStream(
                                    nodeID: targetNodeID,
                                    startMessage: message
                                )
                                activeStream = stream
                                forwardTask = Task {
                                    do {
                                        for try await value in stream.messages {
                                            guard let data = try? encoder.encode(value),
                                                  let text = String(data: data, encoding: .utf8),
                                                  await connection.sendText(text) else {
                                                break
                                            }
                                        }
                                    } catch {
                                        _ = await send(
                                            DashboardTerminalServerMessage(
                                                type: "error",
                                                code: "mesh_stream_closed",
                                                message: error.localizedDescription
                                            )
                                        )
                                    }
                                }
                            } catch {
                                _ = await send(DashboardTerminalServerMessage(type: "error", code: "mesh_stream_open_failed", message: error.localizedDescription))
                            }

                        case "input", "resize", "ping":
                            guard let activeStream else {
                                _ = await send(DashboardTerminalServerMessage(type: "error", code: "session_not_started", message: "Start a terminal session first."))
                                continue
                            }
                            do {
                                try await service.sendMeshTerminalFrame(
                                    streamID: activeStream.id,
                                    nodeID: targetNodeID,
                                    message: message
                                )
                            } catch {
                                _ = await send(DashboardTerminalServerMessage(type: "error", code: "mesh_stream_write_failed", message: error.localizedDescription))
                            }

                        case "close":
                            if let activeStream {
                                await service.closeMeshTerminalStream(
                                    streamID: activeStream.id,
                                    nodeID: targetNodeID
                                )
                            }
                            break messageLoop

                        default:
                            _ = await send(DashboardTerminalServerMessage(type: "error", code: "invalid_message", message: "Unsupported terminal message type."))
                        }
                    }

                    await connection.close()
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/workspaces/:workspaceId/ws",
                validator: { request in
                    let workspaceId = request.pathParam("workspaceId") ?? ""
                    let ticket = request.queryParam("ticket") ?? ""
                    return !workspaceId.isEmpty && !ticket.isEmpty
                },
                callback: { request, connection in
                    let workspaceId = request.pathParam("workspaceId") ?? ""
                    let ticket = request.queryParam("ticket") ?? ""
                    let afterRevision = max(0, Int(request.queryParam("revision") ?? "") ?? 0)
                    guard let ticketContext = await service.workspaceRealtimeService.consumeTicket(
                        ticket,
                        workspaceId: workspaceId
                    ) else {
                        await connection.close()
                        return
                    }

                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601

                    func send(_ message: WorkspaceRealtimeMessage) async -> Bool {
                        guard let data = try? encoder.encode(message),
                              let text = String(data: data, encoding: .utf8)
                        else {
                            return false
                        }
                        return await connection.sendText(text)
                    }

                    do {
                        let stream = try await service.workspaceRealtimeService.subscribe(
                            workspaceId: workspaceId,
                            afterRevision: afterRevision
                        )
                        let forwardTask = Task {
                            for await message in stream {
                                if !(await send(message)) {
                                    break
                                }
                            }
                        }

                        for await rawMessage in connection.incomingMessages() {
                            guard let data = rawMessage.data(using: .utf8),
                                  let message = try? decoder.decode(WorkspaceRealtimeMessage.self, from: data)
                            else {
                                _ = await send(WorkspaceRealtimeMessage(
                                    kind: .transactionRejected,
                                    message: "Malformed workspace message."
                                ))
                                continue
                            }
                            switch message.kind {
                            case .transaction:
                                guard let transactionRequest = message.transactionRequest else {
                                    _ = await send(WorkspaceRealtimeMessage(
                                        kind: .transactionRejected,
                                        message: "Missing transaction request."
                                    ))
                                    continue
                                }
                                do {
                                    _ = try await service.workspaceRealtimeService.commit(
                                        workspaceId: workspaceId,
                                        request: transactionRequest,
                                        actor: ticketContext.actor,
                                        canEdit: ticketContext.role.canEdit
                                    )
                                } catch WorkspaceRealtimeService.WorkspaceRealtimeError.conflict(let revision, let ids) {
                                    _ = await send(WorkspaceRealtimeMessage(
                                        kind: .transactionRejected,
                                        latestRevision: revision,
                                        conflictElementIds: ids,
                                        message: "workspace_conflict"
                                    ))
                                } catch {
                                    _ = await send(WorkspaceRealtimeMessage(
                                        kind: .transactionRejected,
                                        message: "Workspace transaction was rejected."
                                    ))
                                }
                            case .presence:
                                guard var presence = message.presence else { continue }
                                presence.actor = ticketContext.actor
                                await service.workspaceRealtimeService.publishPresence(
                                    presence,
                                    workspaceId: workspaceId
                                )
                            case .ping:
                                _ = await send(WorkspaceRealtimeMessage(kind: .pong))
                            default:
                                continue
                            }
                        }
                        forwardTask.cancel()
                    } catch {
                        _ = await send(WorkspaceRealtimeMessage(
                            kind: .transactionRejected,
                            message: "Workspace realtime stream is unavailable."
                        ))
                    }

                    await service.workspaceRealtimeService.publishPresence(
                        WorkspacePresence(actor: ticketContext.actor, status: "offline"),
                        workspaceId: workspaceId
                    )
                    await connection.close()
                }
            )
        )

        routes.append(
            .init(
                path: "/v1/projects/:projectId/kanban/ws",
                validator: { request in
                    let projectId = request.pathParam("projectId") ?? ""
                    return !projectId.isEmpty
                },
                callback: { request, connection in
                    let projectId = request.pathParam("projectId") ?? ""
                    let stream = await service.kanbanEventService.subscribe(projectId: projectId)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601

                    for await event in stream {
                        guard let data = try? encoder.encode(event),
                              let text = String(data: data, encoding: .utf8)
                        else {
                            continue
                        }

                        let sent = await connection.sendText(text)
                        if !sent {
                            break
                        }
                    }

                    await connection.close()
                }
            )
        )

        return routes
    }

    static func channelPluginErrorResponse(_ error: CoreService.ChannelPluginError) -> CoreRouterResponse {
        switch error {
        case .invalidID:
            return json(status: HTTPStatus.badRequest, payload: [
                "error": ErrorCode.invalidPluginId,
                "message": "Plugin id is required and must be 128 characters or fewer.",
            ])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: [
                "error": ErrorCode.invalidPluginPayload,
                "message": "Plugin payload is invalid. For plugin create/update, `type` and `baseUrl` must be non-empty when provided.",
            ])
        case .notFound:
            return json(status: HTTPStatus.notFound, payload: [
                "error": ErrorCode.pluginNotFound,
                "message": "Plugin was not found.",
            ])
        case .conflict:
            return json(status: HTTPStatus.conflict, payload: [
                "error": ErrorCode.pluginConflict,
                "message": "Plugin already exists.",
            ])
        }
    }

    static func agentSessionErrorResponse(_ error: CoreService.AgentSessionError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidSessionID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionPayload])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .sessionNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func agentConfigErrorResponse(_ error: CoreService.AgentConfigError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentConfigPayload])
        case .invalidModel:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentModel])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .documentLengthExceeded(let resource, let limit):
            return json(
                status: HTTPStatus.badRequest,
                payload: [
                    "error": "agent_document_too_long",
                    "resource": resource,
                    "limit": String(limit)
                ]
            )
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func agentToolsErrorResponse(_ error: CoreService.AgentToolsError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentToolsPayload])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func toolInvocationErrorResponse(_ error: CoreService.ToolInvocationError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidSessionID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidToolInvocationPayload])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .sessionNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
        case .forbidden(_):
            return json(status: HTTPStatus.forbidden, payload: ["error": ErrorCode.toolForbidden])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func systemLogsErrorResponse(_ error: CoreService.SystemLogsError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func actorBoardErrorResponse(_ error: CoreService.ActorBoardError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
        case .actorNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.actorNotFound])
        case .linkNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.linkNotFound])
        case .teamNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.teamNotFound])
        case .protectedActor:
            return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.actorProtected])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func projectErrorResponse(_ error: CoreService.ProjectError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidProjectID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectId])
        case .invalidChannelID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectChannelId])
        case .invalidTaskID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectTaskId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectPayload])
        case .notFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.projectNotFound])
        case .conflict:
            return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.projectConflict])
        }
    }

    static func agentSkillsErrorResponse(_ error: CoreService.AgentSkillsError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .skillNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.skillNotFound])
        case .skillAlreadyExists:
            return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.skillAlreadyExists])
        case .localPathFailure:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
        case .storageFailure, .networkFailure, .downloadFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    static func json(status: Int, payload: [String: String]) -> CoreRouterResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? CoreRouterConstants.emptyJSONData
        return CoreRouterResponse(status: status, body: data)
    }

    static func encodable<T: Encodable>(status: Int, payload: T) -> CoreRouterResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(payload)) ?? CoreRouterConstants.emptyJSONData
        return CoreRouterResponse(status: status, body: data)
    }

    static func sse(status: Int, updates: AsyncStream<AgentSessionStreamUpdate>) -> CoreRouterResponse {
        let stream = AsyncStream<CoreRouterServerSentEvent>(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .sortedKeys

                for await update in updates {
                    let payload = (try? encoder.encode(update)) ?? CoreRouterConstants.emptyJSONData
                    continuation.yield(
                        CoreRouterServerSentEvent(
                            event: update.kind.rawValue,
                            data: payload,
                            id: String(update.cursor)
                        )
                    )
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return CoreRouterResponse(
            status: status,
            body: Data(),
            contentType: "text/event-stream",
            sseStream: stream
        )
    }

    static func sseProjectChanges(status: Int, stream: AsyncStream<ProjectWorkingTreeChangeBatch>) -> CoreRouterResponse {
        let sseStream = AsyncStream<CoreRouterServerSentEvent>(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .sortedKeys

                for await batch in stream {
                    let payload = (try? encoder.encode(batch)) ?? CoreRouterConstants.emptyJSONData
                    continuation.yield(
                        CoreRouterServerSentEvent(
                            event: "change_batch",
                            data: payload,
                            id: String(Int(batch.createdAt.timeIntervalSince1970 * 1000))
                        )
                    )
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return CoreRouterResponse(
            status: status,
            body: Data(),
            contentType: "text/event-stream",
            sseStream: sseStream
        )
    }

    static func sseText(status: Int, stream: AsyncStream<String>) -> CoreRouterResponse {
        let sseStream = AsyncStream<CoreRouterServerSentEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                for await chunk in stream {
                    guard !chunk.isEmpty else { continue }
                    let data = Data(chunk.utf8)
                    continuation.yield(CoreRouterServerSentEvent(event: "delta", data: data, id: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return CoreRouterResponse(
            status: status,
            body: Data(),
            contentType: "text/event-stream",
            sseStream: sseStream
        )
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func isoDate(from string: String) -> Date? {
        let formatterWithFractions = ISO8601DateFormatter()
        formatterWithFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatterWithFractions.date(from: string) {
            return parsed
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    private func matchedWebSocketRoute(
        for path: String,
        headers: [String: String],
        remoteAddress: String?
    ) -> (definition: WebSocketRouteDefinition, request: HTTPRequest)? {
        let queryParams = parseQueryString(from: path)
        let pathSegments = splitPath(path)

        for route in webSocketRoutes {
            guard let params = route.match(pathSegments: pathSegments) else {
                continue
            }

            let request = HTTPRequest(
                method: .get,
                path: path,
                segments: pathSegments,
                params: params,
                query: queryParams,
                headers: headers,
                body: nil,
                remoteAddress: remoteAddress
            )
            return (route, request)
        }

        return nil
    }

    private func shouldRequireDashboardAuthorization(for request: HTTPRequest) async -> Bool {
        guard request.segments.first == "v1" else {
            return false
        }
        if request.method == .get,
           request.segments == ["v1", "dashboard", "auth", "status"] {
            return false
        }
        if request.method == .post,
           request.segments == ["v1", "node", "mesh", "invites", "accept"] {
            return false
        }
        let status = await service.dashboardAuthStatus()
        return status.protectsMutatingRoutes
    }
}

private func parseRoutePath(_ path: String) -> [RoutePathSegment] {
    splitPath(path).map { segment in
        if segment.hasPrefix("*"), segment.count > 1 {
            return .catchAll(String(segment.dropFirst()))
        }
        if segment.hasPrefix(":"), segment.count > 1 {
            return .parameter(String(segment.dropFirst()))
        }
        return .literal(segment)
    }
}

private func splitPath(_ rawPath: String) -> [String] {
    let withoutHash = rawPath.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
    let withoutQuery = withoutHash.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutHash
    return withoutQuery
        .split(separator: "/")
        .map { segment in
            let rawSegment = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            return rawSegment.removingPercentEncoding ?? rawSegment
        }
        .filter { !$0.isEmpty }
}

private func parseQueryString(from rawPath: String) -> [String: String] {
    let withoutHash = rawPath.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
    guard let queryStart = withoutHash.firstIndex(of: "?") else { return [:] }
    let queryString = String(withoutHash[withoutHash.index(after: queryStart)...])
    var result: [String: String] = [:]
    for pair in queryString.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])
            result[key] = value
        } else if parts.count == 1 {
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            result[key] = ""
        }
    }
    return result
}
