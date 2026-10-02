import Foundation
import Protocols

struct SessionsAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/agent-sessions", metadata: RouteMetadata(summary: "List all agent session summaries", description: "Returns session summaries across agents without transcripts; used for fleet activity", tags: ["Sessions"])) { _ in
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.listAllAgentSessions())
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "agent_sessions_list_failed"])
            }
        }

        router.get("/v1/channel-sessions", metadata: RouteMetadata(summary: "List channel sessions", description: "Returns a list of all active channel sessions", tags: ["Sessions"])) { request in
            let agentId = request.queryParam("agentId")
            let parsedLimit = Int(request.queryParam("limit") ?? "")
            let limit = parsedLimit.map { max(0, min($0, 500)) }
            let offset = max(0, Int(request.queryParam("offset") ?? "") ?? 0)
            let parsedRecentMessagesLimit = Int(request.queryParam("recentMessagesLimit") ?? "")
            let recentMessagesLimit = parsedRecentMessagesLimit.map { max(0, min($0, 50)) }
            let statusValue = request.queryParam("status")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let status: ChannelSessionStatus?
            if let statusValue, !statusValue.isEmpty {
                guard let parsedStatus = ChannelSessionStatus(rawValue: statusValue) else {
                    return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
                }
                status = parsedStatus
            } else {
                status = nil
            }

            do {
                let sessions = try await service.listChannelSessions(
                    status: status,
                    agentID: agentId,
                    recentMessagesLimit: recentMessagesLimit,
                    limit: limit,
                    offset: offset
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: sessions)
            } catch CoreService.AgentStorageError.invalidID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionListFailed])
            }
        }

        router.get("/v1/channel-sessions/:sessionId", metadata: RouteMetadata(summary: "Get channel session", description: "Returns details of a specific channel session", tags: ["Sessions"])) { request in
            let sessionId = request.pathParam("sessionId") ?? ""

            do {
                let session = try await service.getChannelSession(sessionID: sessionId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: session)
            } catch ChannelSessionFileStore.StoreError.invalidSessionID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            } catch ChannelSessionFileStore.StoreError.sessionNotFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionLoadFailed])
            }
        }

        router.post("/v1/channel-sessions/:sessionId/input-requests/:requestId/answer", metadata: RouteMetadata(summary: "Answer channel input request", description: "Answers a pending plan-mode channel input request and resumes the channel turn", tags: ["Sessions"])) { request in
            let sessionId = request.pathParam("sessionId") ?? ""
            let requestId = request.pathParam("requestId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: PlanInputAnswerRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let session = try await service.answerChannelPlanInput(
                    sessionID: sessionId,
                    requestID: requestId,
                    payload: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: session)
            } catch ChannelSessionFileStore.StoreError.invalidSessionID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            } catch ChannelSessionFileStore.StoreError.sessionNotFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
            } catch let error as CoreService.AgentSessionError {
                return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        router.delete("/v1/channel-sessions/:sessionId", metadata: RouteMetadata(summary: "Delete channel session", description: "Permanently deletes a channel session and all its events", tags: ["Sessions"])) { request in
            let sessionId = request.pathParam("sessionId") ?? ""

            do {
                try await service.deleteChannelSession(sessionID: sessionId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch ChannelSessionFileStore.StoreError.invalidSessionID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            } catch ChannelSessionFileStore.StoreError.sessionNotFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionDeleteFailed])
            }
        }
    }
}
