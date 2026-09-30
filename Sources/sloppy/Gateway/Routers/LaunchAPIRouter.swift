import Foundation
import Protocols

struct LaunchAPIRouter: APIRouter {
    let service: CoreService
    func configure(on router: CoreRouterRegistrar) {
        let base = "/v1/agents/:agentId/sessions/:sessionId/launch"
        router.get(base) { request in
            await self.respond {
                try await service.launchState(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "")
            }
        }
        router.post(base + "/configurations") { request in
            guard let body = request.body, let payload = CoreRouter.decode(body, as: LaunchConfigurationRequest.self) else { return CoreRouter.json(status: 400, payload: ["error": "invalid_launch_configuration"]) }
            return await self.respond {
                try await service.configureLaunch(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", request: payload)
            }
        }
        router.post(base + "/selection") { request in
            guard let body = request.body, let payload = CoreRouter.decode(body, as: LaunchSelectionRequest.self) else { return CoreRouter.json(status: 400, payload: ["error": "invalid_launch_selection"]) }
            return await self.respond {
                try await service.selectLaunch(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", request: payload)
            }
        }
        router.delete(base + "/configurations/:configurationId") { request in
            await self.respond {
                try await service.removeLaunch(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", configurationID: request.pathParam("configurationId") ?? "")
            }
        }
        router.post(base + "/configurations/:configurationId/start") { request in
            await self.respond {
                try await service.startLaunch(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", configurationID: request.pathParam("configurationId") ?? "")
            }
        }
        router.post(base + "/runs/:runId/stop") { request in
            await self.respond {
                try await service.stopLaunch(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", runID: request.pathParam("runId") ?? "")
            }
        }
        router.post(base + "/archive") { request in
            guard let body = request.body, let payload = CoreRouter.decode(body, as: LaunchArchiveRequest.self) else { return CoreRouter.json(status: 400, payload: ["error": "invalid_launch_archive"]) }
            return await self.respond {
                try await service.archiveLaunch(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "", isArchived: payload.isArchived)
            }
        }
        router.get(base + "/simulators") { request in
            await self.respond {
                try await service.launchSimulators(agentID: request.pathParam("agentId") ?? "", sessionID: request.pathParam("sessionId") ?? "")
            }
        }
    }

    private func respond<T: Encodable>(_ body: () async throws -> T) async -> CoreRouterResponse {
        do { return CoreRouter.encodable(status: 200, payload: try await body()) }
        catch let error as CoreService.AgentSessionError { return CoreRouter.agentSessionErrorResponse(error, fallback: ErrorCode.sessionNotFound) }
        catch let error as LaunchRunService.Failure {
            let code: Int
            switch error { case .notFound: code = 404; case .alreadyRunning: code = 409; default: code = 400 }
            return CoreRouter.json(status: code, payload: ["error": "launch_unavailable", "message": error.localizedDescription])
        }
        catch { return CoreRouter.json(status: 500, payload: ["error": "launch_failed", "message": error.localizedDescription]) }
    }
}
