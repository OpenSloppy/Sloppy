import Foundation
import Protocols

struct LongChatAPIRouter: APIRouter {
    let service: CoreService

    func configure(on router: CoreRouterRegistrar) {
        router.post(
            "/v1/agents/:agentId/long-chat", metadata: .init(summary: "Open persistent long chat", tags: ["Sessions"])
        ) { request in
            guard let body = request.body, let payload = CoreRouter.decode(body, as: LongChatOpenRequest.self) else {
                return CoreRouter.json(status: 400, payload: ["error": "invalid_body"])
            }
            do {
                _ = payload
                let userID = try await Self.userID(request, service: service)
                let session = try await service.openLongChat(
                    agentID: request.pathParam("agentId") ?? "", userID: userID)
                return CoreRouter.encodable(status: 200, payload: session)
            } catch { return Self.errorResponse(error) }
        }
        let base = "/v1/agents/:agentId/sessions/:sessionId/long-chat"
        router.get(base, metadata: .init(summary: "Get long chat assignments", tags: ["Sessions"])) { request in
            do {
                try await Self.checkOwner(request, service: service)
                let result = try await service.getLongChat(
                    agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "")
                return CoreRouter.encodable(status: 200, payload: result)
            } catch { return Self.errorResponse(error) }
        }
        router.post(base + "/cancel", metadata: .init(summary: "Cancel all long chat tasks", tags: ["Sessions"])) {
            request in
            do {
                try await Self.checkOwner(request, service: service)
                try await service.cancelLongChatTasks(
                    agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "")
                return CoreRouter.json(status: 200, payload: ["status": "cancelled"])
            } catch { return Self.errorResponse(error) }
        }
        for action in ["cancel", "retry", "messages"] {
            router.post(
                base + "/tasks/:taskId/" + action,
                metadata: .init(summary: "Long chat task \(action)", tags: ["Sessions"])
            ) { request in
                let agentID = request.pathParam("agentId") ?? ""
                let sessionID = request.pathParam("sessionId") ?? ""
                let taskID = request.pathParam("taskId") ?? ""
                do {
                    try await Self.checkOwner(request, service: service)
                    switch action {
                    case "cancel":
                        try await service.cancelLongChatTasks(agentID: agentID, sessionID: sessionID, taskID: taskID)
                    case "retry":
                        try await service.retryLongChatTask(agentID: agentID, sessionID: sessionID, taskID: taskID)
                    default:
                        guard let body = request.body,
                            var payload = CoreRouter.decode(body, as: LongChatTaskMessageRequest.self)
                        else { return CoreRouter.json(status: 400, payload: ["error": "invalid_body"]) }
                        payload.userId = try await Self.userID(request, service: service)
                        try await service.messageLongChatTask(
                            agentID: agentID, sessionID: sessionID, taskID: taskID, request: payload)
                    }
                    let result = try await service.getLongChat(agentID: agentID, sessionID: sessionID)
                    return CoreRouter.encodable(status: 200, payload: result)
                } catch { return Self.errorResponse(error) }
            }
        }
    }

    private enum AccessError: Error { case forbidden }
    private static func userID(_ request: HTTPRequest, service: CoreService) async throws -> String {
        if await service.identityAuthEnabled() {
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                throw AccessError.forbidden
            }
            return actor.user.id
        }
        return "local"
    }
    private static func checkOwner(_ request: HTTPRequest, service: CoreService) async throws {
        let conversation = try await service.getLongChat(
            agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "")
        guard conversation.userId == (try await userID(request, service: service)) else { throw AccessError.forbidden }
    }

    private static func errorResponse(_ error: Error) -> CoreRouterResponse {
        if error is AccessError { return CoreRouter.json(status: 403, payload: ["error": "forbidden"]) }
        if let sessionError = error as? CoreService.AgentSessionError {
            return CoreRouter.agentSessionErrorResponse(sessionError, fallback: "long_chat_failed")
        }
        if let storageError = error as? LongChatFileStore.StoreError {
            switch storageError {
            case .notFound: return CoreRouter.json(status: 404, payload: ["error": "task_not_found"])
            case .conflict, .retryLimit: return CoreRouter.json(status: 409, payload: ["error": "task_conflict"])
            case .invalidPayload: return CoreRouter.json(status: 400, payload: ["error": "invalid_body"])
            }
        }
        return CoreRouter.json(status: 500, payload: ["error": "long_chat_failed"])
    }
}
