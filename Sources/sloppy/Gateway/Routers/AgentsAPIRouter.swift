import Foundation
import Protocols

struct AgentsAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/pets/image-generation-status", metadata: RouteMetadata(summary: "Pet image generation status", description: "Returns raster pet generation availability", tags: ["Pets"])) { _ in
            let status = await service.petImageGenerationStatus()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: status)
        }

        router.post("/v1/pets/generate", metadata: RouteMetadata(summary: "Retired pet generation", description: "Agent avatars are assigned automatically", tags: ["Pets"])) { _ in
            CoreRouter.json(status: 410, payload: ["error": "pet_generation_removed"])
        }

        router.get("/v1/agents", metadata: RouteMetadata(summary: "List agents", description: "Returns a list of all available agents", tags: ["Agents"])) { request in
            let includeSystem = request.queryParam("system").map { $0 != "false" } ?? true
            do {
                let agents = try await service.listAgents(includeSystem: includeSystem)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: agents)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentsListFailed])
            }
        }

        router.get("/v1/agents/:agentId", metadata: RouteMetadata(summary: "Get agent", description: "Returns details of a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let agent = try await service.getAgent(id: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: agent)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }
        }

        router.get("/v1/agents/:agentId/files", metadata: RouteMetadata(summary: "List agent files", description: "Returns the visible file tree entries for an agent directory", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let path = request.queryParam("path") ?? ""
            do {
                let entries = try await service.listAgentFiles(agentID: agentId, path: path)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: entries)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }
        }

        router.get("/v1/agents/:agentId/files/content", metadata: RouteMetadata(summary: "Read agent file", description: "Returns the text content of a visible agent file", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let path = request.queryParam("path") ?? ""
            do {
                let response = try await service.readAgentFile(agentID: agentId, path: path)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.invalidPayload {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }
        }

        router.get("/v1/agents/:agentId/chat-slash-commands", metadata: RouteMetadata(summary: "Agent chat slash commands", description: "Channel plugin commands plus user-invocable skill shortcuts for this agent (Dashboard / autocomplete)", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let payload = try await service.buildAgentChatSlashCommands(agentID: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: payload)
            } catch CoreService.AgentSkillsError.invalidAgentID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentsListFailed])
            }
        }

        router.delete("/v1/agents/:agentId", metadata: RouteMetadata(summary: "Delete agent", description: "Permanently deletes a non-system agent and all its data", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                try await service.deleteAgent(agentID: agentId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.invalidPayload {
                return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "system_agents_cannot_be_deleted"])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }
        }

        router.get("/v1/agents/:agentId/tasks", metadata: RouteMetadata(summary: "List agent tasks", description: "Returns a list of tasks assigned to a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let tasks = try await service.listAgentTasks(agentID: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: tasks)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }
        }

        router.get("/v1/agents/:agentId/memories", metadata: RouteMetadata(summary: "List agent memories", description: "Returns a list of memories for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let search = request.queryParam("search")
            let rawFilter = request.queryParam("filter")?.lowercased() ?? AgentMemoryFilter.all.rawValue
            guard let filter = AgentMemoryFilter(rawValue: rawFilter) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let parsedLimit = Int(request.queryParam("limit") ?? "") ?? 20
            let limit = max(1, min(parsedLimit, 100))
            let offset = max(0, Int(request.queryParam("offset") ?? "") ?? 0)

            do {
                let response = try await service.listAgentMemories(
                    agentID: agentId,
                    search: search,
                    filter: filter,
                    limit: limit,
                    offset: offset
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentMemoryReadFailed])
            }
        }

        router.get("/v1/agents/:agentId/memories/graph", metadata: RouteMetadata(summary: "Get agent memory graph", description: "Returns a graph representation of agent memories", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let search = request.queryParam("search")
            let rawFilter = request.queryParam("filter")?.lowercased() ?? AgentMemoryFilter.all.rawValue
            guard let filter = AgentMemoryFilter(rawValue: rawFilter) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.agentMemoryGraph(
                    agentID: agentId,
                    search: search,
                    filter: filter
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentMemoryReadFailed])
            }
        }

        router.patch("/v1/agents/:agentId/memories/:memoryId", metadata: RouteMetadata(summary: "Update agent memory", description: "Updates a specific memory entry for an agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let memoryId = request.pathParam("memoryId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentMemoryUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let item = try await service.updateAgentMemory(
                    agentID: agentId,
                    memoryID: memoryId,
                    note: payload.note,
                    summary: payload.summary,
                    kind: payload.kind,
                    importance: payload.importance,
                    confidence: payload.confidence
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: item)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentMemoryNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentMemoryUpdateFailed])
            }
        }

        router.delete("/v1/agents/:agentId/memories/:memoryId", metadata: RouteMetadata(summary: "Delete agent memory", description: "Soft-deletes a specific memory entry for an agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let memoryId = request.pathParam("memoryId") ?? ""

            do {
                try await service.deleteAgentMemory(agentID: agentId, memoryID: memoryId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentMemoryNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentMemoryDeleteFailed])
            }
        }

        router.get("/v1/agents/:agentId/sessions", metadata: RouteMetadata(summary: "List agent sessions", description: "Returns a list of sessions for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let projectFilter = request.queryParam("projectId")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectID = (projectFilter?.isEmpty == false) ? projectFilter : nil
            let parsedLimit = Int(request.queryParam("limit") ?? "")
            let limit = parsedLimit.map { max(0, min($0, 500)) }
            let offset = max(0, Int(request.queryParam("offset") ?? "") ?? 0)
            do {
                let sessions = try await service.listAgentSessions(
                    agentID: agentId,
                    projectID: projectID,
                    limit: limit,
                    offset: offset
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: sessions)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionListFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionListFailed])
            }
        }

        router.post("/v1/browser/context-message", metadata: RouteMetadata(summary: "Post browser context message", description: "Posts selected Safari page context to an agent session", tags: ["Agents"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: BrowserContextMessageRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.postBrowserContextMessage(payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch CoreService.BrowserContextError.invalidPayload {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            } catch CoreService.BrowserContextError.invalidAgentID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.BrowserContextError.invalidSessionID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.get("/v1/agents/:agentId/config", metadata: RouteMetadata(summary: "Get agent config", description: "Returns the configuration for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let detail = try await service.getAgentConfigWithMemory(agentID: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: detail)
            } catch let error as CoreService.AgentConfigError {
                return CoreRouter.agentConfigErrorResponse(error, fallback: ErrorCode.agentConfigReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentConfigReadFailed])
            }
        }

        router.get("/v1/agents/:agentId/tools", metadata: RouteMetadata(summary: "Get agent tools", description: "Returns the tool policy for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let policy = try await service.getAgentToolsPolicy(agentID: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: policy)
            } catch let error as CoreService.AgentToolsError {
                return CoreRouter.agentToolsErrorResponse(error, fallback: ErrorCode.agentToolsReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentToolsReadFailed])
            }
        }

        router.get("/v1/agents/:agentId/tools/catalog", metadata: RouteMetadata(summary: "Get tool catalog", description: "Returns the catalog of available tools for an agent", tags: ["Agents"])) { _ in
            let catalog = await service.toolCatalog()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: catalog)
        }

        router.get("/v1/agents/:agentId/token-usage", metadata: RouteMetadata(summary: "Get agent token usage", description: "Returns token usage statistics for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let usage = try await service.getAgentTokenUsage(agentID: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: usage)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.tokenUsageReadFailed])
            }
        }

        router.get("/v1/agents/:agentId/sessions/:sessionId", metadata: RouteMetadata(summary: "Get agent session", description: "Returns details of a specific agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            do {
                let detail = try await service.getAgentSession(agentID: agentId, sessionID: sessionId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: detail)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionNotFound])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/context", metadata: RouteMetadata(summary: "Prepare agent session context", description: "Loads persisted session history into runtime context for a specific agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            do {
                let summary = try await service.prepareAgentSessionContext(agentID: agentId, sessionID: sessionId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: summary)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionNotFound])
            }
        }

        router.get("/v1/agents/:agentId/sessions/:sessionId/stream", metadata: RouteMetadata(summary: "Stream agent session", description: "Open a server-sent events stream for session updates", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            do {
                let stream = try await service.streamAgentSessionEvents(agentID: agentId, sessionID: sessionId)
                return CoreRouter.sse(status: HTTPStatus.ok, updates: stream)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionStreamFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionStreamFailed])
            }
        }

        router.put("/v1/agents/:agentId/config", metadata: RouteMetadata(summary: "Update agent config", description: "Updates the configuration for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentConfigUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentConfigPayload])
            }

            do {
                let detail = try await service.updateAgentConfig(agentID: agentId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: detail)
            } catch let error as CoreService.AgentConfigError {
                return CoreRouter.agentConfigErrorResponse(error, fallback: ErrorCode.agentConfigWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentConfigWriteFailed])
            }
        }

        router.put("/v1/agents/:agentId/tools", metadata: RouteMetadata(summary: "Update agent tools", description: "Updates the tool policy for a specific agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentToolsUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentToolsPayload])
            }

            do {
                let policy = try await service.updateAgentToolsPolicy(agentID: agentId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: policy)
            } catch let error as CoreService.AgentToolsError {
                return CoreRouter.agentToolsErrorResponse(error, fallback: ErrorCode.agentToolsWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentToolsWriteFailed])
            }
        }

        router.post("/v1/agents", metadata: RouteMetadata(summary: "Create agent", description: "Creates a new agent", tags: ["Agents"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let agent = try await service.createAgent(payload)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: agent)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.invalidPayload {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentPayload])
            } catch CoreService.AgentStorageError.alreadyExists {
                return CoreRouter.json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.agentAlreadyExists])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentCreateFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/checkpoint", metadata: RouteMetadata(summary: "Run agent memory checkpoint", description: "Runs a shadow memory checkpoint for a session (updates MEMORY via tools, no chat events)", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            let payload: AgentMemoryCheckpointRequest
            if let body = request.body {
                guard let decoded = CoreRouter.decode(body, as: AgentMemoryCheckpointRequest.self) else {
                    return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
                }
                payload = decoded
            } else {
                payload = AgentMemoryCheckpointRequest()
            }

            do {
                let response = try await service.requestAgentMemoryCheckpoint(
                    agentID: agentId,
                    sessionID: sessionId,
                    reason: payload.reason
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions", metadata: RouteMetadata(summary: "Create agent session", description: "Starts a new session with an agent", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let payload: AgentSessionCreateRequest

            if let body = request.body {
                guard let decoded = CoreRouter.decode(body, as: AgentSessionCreateRequest.self) else {
                    return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
                }
                payload = decoded
            } else {
                payload = AgentSessionCreateRequest()
            }

            do {
                let userID: String
                if await service.identityAuthEnabled() {
                    guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                        return CoreRouter.json(status: 403, payload: ["error": "forbidden"])
                    }
                    userID = actor.user.id
                } else { userID = "local" }
                let summary = try await service.createAgentSession(agentID: agentId, request: payload, userID: userID)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: summary)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionCreateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionCreateFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/messages", metadata: RouteMetadata(summary: "Post session message", description: "Sends a new message to an active agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  var payload = CoreRouter.decode(body, as: AgentSessionPostMessageRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let identityEnabled = await service.identityAuthEnabled()
            if identityEnabled,
               let actor = await CoreRouter.identityActor(for: request, service: service) {
                payload.userId = actor.user.id
            } else if !identityEnabled {
                payload.userId = "local"
            }

            do {
                let response = try await service.postAgentSessionMessage(
                    agentID: agentId,
                    sessionID: sessionId,
                    request: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/input-requests/:requestId/answer", metadata: RouteMetadata(summary: "Answer session input request", description: "Answers a pending plan-mode structured input request and resumes the session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            let requestId = request.pathParam("requestId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: PlanInputAnswerRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.answerAgentPlanInput(
                    agentID: agentId,
                    sessionID: sessionId,
                    requestID: requestId,
                    payload: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/directories", metadata: RouteMetadata(summary: "Add session directory", description: "Adds a working directory to an active agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentSessionDirectoryRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.addAgentSessionDirectory(
                    agentID: agentId,
                    sessionID: sessionId,
                    request: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/control", metadata: RouteMetadata(summary: "Control agent session", description: "Sends a control command (e.g., interrupt) to an agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentSessionControlRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.controlAgentSession(
                    agentID: agentId,
                    sessionID: sessionId,
                    request: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/events", metadata: RouteMetadata(summary: "Append session events", description: "Appends events to a session without triggering agent processing", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentSessionAppendEventsRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.appendAgentSessionEvents(
                    agentID: agentId,
                    sessionID: sessionId,
                    request: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.post("/v1/agents/:agentId/sessions/:sessionId/tools/invoke", metadata: RouteMetadata(summary: "Invoke tool", description: "Manually invokes a tool for an agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ToolInvocationRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidToolInvocationPayload])
            }

            do {
                let result = try await service.invokeTool(agentID: agentId, sessionID: sessionId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: result)
            } catch let error as CoreService.ToolInvocationError {
                return CoreRouter.toolInvocationErrorResponse(error, fallback: ErrorCode.toolInvokeFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.toolInvokeFailed])
            }
        }

        router.post("/v1/safari-bridge/register", metadata: RouteMetadata(summary: "Register Safari bridge", description: "Registers SloppySafari and refreshes its tab snapshot", tags: ["Browser"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: SafariBridgeRegisterRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            let response = await service.safariBridgeService.register(payload)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
        }

        router.get("/v1/safari-bridge/status", metadata: RouteMetadata(summary: "Safari bridge status", description: "Returns the current SloppySafari bridge tab snapshot", tags: ["Browser"])) { _ in
            let payload = await service.safariBridgeService.statusPayload()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: payload)
        }

        router.get("/v1/safari-bridge/commands", metadata: RouteMetadata(summary: "Poll Safari bridge commands", description: "Returns pending browser commands for SloppySafari", tags: ["Browser"])) { request in
            let bridgeId = request.queryParam("bridgeId") ?? ""
            let limit = request.queryParam("limit").flatMap(Int.init) ?? 10
            let response = await service.safariBridgeService.pollCommands(bridgeId: bridgeId, limit: limit)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
        }

        router.post("/v1/safari-bridge/commands/:commandId/result", metadata: RouteMetadata(summary: "Complete Safari bridge command", description: "Posts the result of a SloppySafari browser command", tags: ["Browser"])) { request in
            guard let body = request.body,
                  var payload = CoreRouter.decode(body, as: SafariBridgeCommandResultRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            if payload.commandId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload.commandId = request.pathParam("commandId") ?? ""
            }
            do {
                try await service.safariBridgeService.completeCommand(payload)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "completed"])
            } catch SafariBridgeError.commandNotFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "safari_command_not_found"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "safari_command_result_failed"])
            }
        }

        router.delete("/v1/agents/:agentId/sessions/:sessionId", metadata: RouteMetadata(summary: "Delete agent session", description: "Deletes a specific agent session", tags: ["Agents"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""

            do {
                try await service.deleteAgentSession(agentID: agentId, sessionID: sessionId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionDeleteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionDeleteFailed])
            }
        }
    }
}
