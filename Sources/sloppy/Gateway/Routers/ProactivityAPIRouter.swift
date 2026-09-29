import Foundation
import Protocols

struct ProactivityAPIRouter: APIRouter {
    let service: CoreService

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/agents/:agentId/proactivity", metadata: .init(summary: "List proactive findings", description: "Durable attention inbox and queue health", tags: ["Agents"])) { request in
            do { return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.proactiveInbox(agentID: request.pathParam("agentId") ?? "")) }
            catch { return Self.failure(error) }
        }
        router.get("/v1/agents/:agentId/proactivity/settings", metadata: .init(summary: "Get proactive settings", description: "Heartbeat configuration and available analysis models", tags: ["Agents"])) { request in
            do { return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.proactiveSettings(agentID: request.pathParam("agentId") ?? "")) }
            catch { return Self.failure(error) }
        }
        router.put("/v1/agents/:agentId/proactivity/settings", metadata: .init(summary: "Update proactive settings", description: "Updates only heartbeat settings and its instructions", tags: ["Agents"])) { request in
            guard let data = request.body, let body = CoreRouter.decode(data, as: ProactiveSettingsRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_body"])
            }
            do { return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.updateProactiveSettings(agentID: request.pathParam("agentId") ?? "", request: body)) }
            catch { return Self.failure(error) }
        }
        router.post("/v1/agents/:agentId/proactivity/findings/:findingId/action", metadata: .init(summary: "Update proactive finding", description: "Mark read, snooze for 24 hours or dismiss this revision", tags: ["Agents"])) { request in
            guard let data = request.body, let body = CoreRouter.decode(data, as: ProactiveFindingActionRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_body"])
            }
            do { return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.actOnProactiveFinding(agentID: request.pathParam("agentId") ?? "", findingID: request.pathParam("findingId") ?? "", request: body)) }
            catch { return Self.failure(error) }
        }
    }

    private static func failure(_ error: Error) -> CoreRouterResponse {
        switch error {
        case CoreService.AgentStorageError.notFound, CoreService.AgentConfigError.agentNotFound, ProactiveHeartbeatError.findingNotFound:
            return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "not_found"])
        case CoreService.AgentConfigError.invalidPayload, CoreService.AgentConfigError.invalidAgentID, CoreService.AgentStorageError.invalidID:
            return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_proactive_settings"])
        default:
            return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "proactivity_failed"])
        }
    }
}
