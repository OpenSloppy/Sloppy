import Foundation

struct DebugAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get(
            "/v1/debug/session-context/:agentId/:sessionId",
            metadata: RouteMetadata(summary: "Debug session context", description: "Returns session bootstrap, prepared native model input, scoped memory query diagnostics, and context budget for a given agent session", tags: ["Debug"])
        ) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard !agentId.isEmpty, !sessionId.isEmpty else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            guard let result = await service.getDebugSessionContext(agentID: agentId, sessionID: sessionId) else {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
            }
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: result)
        }

        router.get(
            "/v1/debug/session-file-path/:agentId/:sessionId",
            metadata: RouteMetadata(summary: "Debug agent session file path", description: "Returns the local JSONL file path for an agent session", tags: ["Debug"])
        ) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard !agentId.isEmpty, !sessionId.isEmpty else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let filePath = try await service.getAgentSessionFilePath(agentID: agentId, sessionID: sessionId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: [
                    "agentId": agentId,
                    "sessionId": sessionId,
                    "filePath": filePath
                ])
            } catch {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
            }
        }

        router.get(
            "/v1/debug/channels",
            metadata: RouteMetadata(summary: "Debug active channels", description: "Returns all active runtime channels with context utilization and bootstrap sizes", tags: ["Debug"])
        ) { _ in
            let result = await service.getDebugChannels()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: result)
        }

        router.get(
            "/v1/debug/prompt-templates",
            metadata: RouteMetadata(summary: "Debug prompt templates", description: "Returns raw content of all registered prompt partials", tags: ["Debug"])
        ) { _ in
            let result = await service.getDebugPromptTemplates()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: result)
        }
    }
}
