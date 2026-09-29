import Foundation
import Protocols

struct DesktopComputerAPIRouter: APIRouter {
    let service: CoreService

    func configure(on router: CoreRouterRegistrar) {
        for action in ["register", "poll", "disconnect"] {
            router.post("/v1/desktop-computer/" + action, metadata: RouteMetadata(
                summary: "Desktop companion " + action, description: "Bind this agent session to the original desktop companion", tags: ["Computer"]
            )) { request in
                guard let body = request.body, let binding = CoreRouter.decode(body, as: DesktopComputerBinding.self) else {
                    return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_body"])
                }
                do {
                    _ = try await service.getAgentSession(agentID: binding.agentId, sessionID: binding.sessionId)
                    let bridge = await service.toolExecution.desktopComputerBridge
                    switch action {
                    case "register": try await bridge.register(binding)
                    case "poll": return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await bridge.poll(binding))
                    default: await bridge.disconnect(binding)
                    }
                    return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "ok"])
                } catch DesktopComputerBridgeError.conflict {
                    return CoreRouter.json(status: HTTPStatus.conflict, payload: ["error": "computer_already_bound"])
                } catch {
                    return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "computer_binding_unavailable"])
                }
            }
        }
        router.post("/v1/desktop-computer/complete", metadata: RouteMetadata(
            summary: "Complete desktop command", description: "Deliver a result from the bound desktop companion", tags: ["Computer"]
        )) { request in
            guard let body = request.body, let result = CoreRouter.decode(body, as: DesktopComputerCompletion.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_body"])
            }
            do {
                _ = try await service.getAgentSession(agentID: result.binding.agentId, sessionID: result.binding.sessionId)
                try await service.toolExecution.desktopComputerBridge.complete(result)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "completed"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "computer_command_unavailable"])
            }
        }
    }
}
