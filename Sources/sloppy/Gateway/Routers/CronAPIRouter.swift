import Foundation
import Protocols

struct CronAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/agents/:agentId/cron", metadata: RouteMetadata(summary: "List agent cron tasks", description: "Returns a list of scheduled cron tasks for an agent", tags: ["Cron"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let tasks = try await service.listAgentCronTasks(agentID: agentId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: tasks)
            } catch CoreService.AgentCronTaskError.invalidAgentID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "internal_error"])
            }
        }

        router.post("/v1/agents/:agentId/cron", metadata: RouteMetadata(summary: "Create agent cron task", description: "Creates a new scheduled cron task for an agent", tags: ["Cron"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentCronTaskCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let task = try await service.createAgentCronTask(agentID: agentId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: task)
            } catch CoreService.AgentCronTaskError.invalidPayload {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_cron_task"])
            } catch CoreService.AgentCronTaskError.invalidAgentID {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "internal_error"])
            }
        }

        router.put("/v1/agents/:agentId/cron/:cronId", metadata: RouteMetadata(summary: "Update agent cron task", description: "Updates an existing scheduled cron task", tags: ["Cron"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let cronId = request.pathParam("cronId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AgentCronTaskUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let task = try await service.updateAgentCronTask(agentID: agentId, cronID: cronId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: task)
            } catch CoreService.AgentCronTaskError.invalidPayload {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_cron_task"])
            } catch CoreService.AgentCronTaskError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "internal_error"])
            }
        }

        router.delete("/v1/agents/:agentId/cron/:cronId", metadata: RouteMetadata(summary: "Delete agent cron task", description: "Deletes a scheduled cron task", tags: ["Cron"])) { request in
            let agentId = request.pathParam("agentId") ?? ""
            let cronId = request.pathParam("cronId") ?? ""
            do {
                try await service.deleteAgentCronTask(agentID: agentId, cronID: cronId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: ["success": true])
            } catch CoreService.AgentCronTaskError.notFound {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "internal_error"])
            }
        }
    }
}
