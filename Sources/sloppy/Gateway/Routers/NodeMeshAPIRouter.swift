import Foundation
import SloppyNodeCore

struct NodeMeshAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/node/mesh", metadata: RouteMetadata(summary: "Get mesh state", description: "Returns SloppyNode mesh network, invites, nodes, shared projects, tasks, and audit state", tags: ["Node Mesh"])) { _ in
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.getMeshState())
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/network", metadata: RouteMetadata(summary: "Configure mesh network", description: "Creates or updates SloppyNode mesh network metadata", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshNetworkUpdateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.configureMeshNetwork(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/invites", metadata: RouteMetadata(summary: "Create mesh invite", description: "Creates a one-time SloppyNode mesh invite token", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshInviteCreateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.createMeshInvite(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.delete("/v1/node/mesh/invites/:token", metadata: RouteMetadata(summary: "Revoke mesh invite", description: "Removes a pending SloppyNode mesh invite token before it is consumed", tags: ["Node Mesh"])) { request in
            do {
                let token = request.pathParam("token") ?? ""
                try await service.deleteMeshInvite(token: token)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/invites/accept", metadata: RouteMetadata(summary: "Accept mesh invite", description: "Consumes a bundled SloppyNode mesh invite token and registers the invited node identity", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshInviteAcceptRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: [
                    "error": ErrorCode.invalidBody,
                    "message": #"Expected JSON body like {"token":"slp_mesh_..."}."#,
                ])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.acceptMeshInvite(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/relay/disconnect", metadata: RouteMetadata(summary: "Disconnect manual relay", description: "Clears this local node's manual relay URL and stops its connection; preserves node identity, coordinator registration, and Console binding", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshRelayDisconnectRequest.self),
                  !payload.nodeId.isEmpty, !payload.relayURL.isEmpty else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.disconnectManualMeshRelay(payload))
            } catch CoreService.MeshRelayDisconnectError.configurationChanged {
                return CoreRouter.json(status: 409, payload: ["error": "manual_relay_changed", "message": "The local node or manual relay changed. Refresh Nodes before disconnecting."])
            } catch NodeConfigError.missing {
                return CoreRouter.json(status: 404, payload: ["error": "local_node_missing"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/remote-joins", metadata: RouteMetadata(summary: "Join remote mesh", description: "Uses this local node identity to join the relay embedded in a bundled mesh invite", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshRemoteJoinRequest.self),
                  !payload.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: [
                    "error": ErrorCode.invalidBody,
                    "message": #"Expected JSON body like {"token":"slp_mesh_...","name":"work-mac","force":false}."#,
                ])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.joinRemoteMesh(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.get("/v1/node/mesh/users/snapshot", metadata: RouteMetadata(summary: "Export mesh user directory snapshot", description: "Returns registered user directory state to sync with remote nodes", tags: ["Node Mesh"])) { _ in
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.exportMeshDirectorySnapshot())
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/users/snapshot", metadata: RouteMetadata(summary: "Apply mesh user directory snapshot", description: "Replaces local mesh user directory with an authoritative snapshot", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshDirectorySnapshotPayload.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                try await service.applyMeshDirectorySnapshot(payload)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "ok"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/users/delta", metadata: RouteMetadata(summary: "Apply mesh user directory delta", description: "Upserts and revokes mesh user directory entries", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshDirectoryDeltaPayload.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                try await service.applyMeshDirectoryDelta(payload)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "ok"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/users/revocations", metadata: RouteMetadata(summary: "Apply mesh user directory revocations", description: "Removes user directory entries by identifier", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshDirectoryRevocationPayload.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                try await service.applyMeshDirectoryRevocation(payload)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "ok"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.get("/v1/node/mesh/nodes", metadata: RouteMetadata(summary: "List mesh nodes", description: "Returns known SloppyNode mesh nodes and statuses", tags: ["Node Mesh"])) { _ in
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.listMeshNodes())
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/nodes", metadata: RouteMetadata(summary: "Register mesh node", description: "Registers a SloppyNode identity public key so it can authenticate with the relay", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshNodeRegisterRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.registerMeshNode(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.delete("/v1/node/mesh/nodes/:nodeId", metadata: RouteMetadata(summary: "Delete mesh node", description: "Removes a registered SloppyNode identity from this coordinator", tags: ["Node Mesh"])) { request in
            do {
                let nodeId = request.pathParam("nodeId") ?? ""
                try await service.deleteMeshNode(id: nodeId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/nodes/:nodeId/core", metadata: RouteMetadata(summary: "Proxy Core request to mesh node", description: "Routes a Core API request to a selected mesh node through the configured relay", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshCoreProxyHTTPRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                let nodeId = request.pathParam("nodeId") ?? ""
                var forwardedHeaders = payload.headers.reduce(into: [String: String]()) { result, entry in
                    result[entry.key.lowercased()] = entry.value
                }
                // Identity-mode clients cannot impersonate another user via proxy headers.
                if let actor = await CoreRouter.identityActor(for: request, service: service) {
                    forwardedHeaders["x-sloppy-user-context"] = actor.user.id
                } else if let userContext = request.header("x-sloppy-user-context") {
                    forwardedHeaders["x-sloppy-user-context"] = userContext
                }
                let proxyResponse = try await service.proxyMeshCoreHTTPRequest(
                    nodeId: nodeId,
                    method: payload.method,
                    path: payload.path,
                    body: payload.bodyBase64.flatMap { Data(base64Encoded: $0) },
                    headers: forwardedHeaders,
                    localAuthorizationHeader: request.header("authorization")
                )
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: MeshCoreProxyHTTPResponse(
                        status: proxyResponse.status,
                        contentType: proxyResponse.contentType,
                        bodyBase64: proxyResponse.body.base64EncodedString()
                    )
                )
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.get("/v1/node/mesh/shared-projects", metadata: RouteMetadata(summary: "List shared projects", description: "Returns SloppyNode mesh shared projects and members", tags: ["Node Mesh"])) { _ in
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.listMeshSharedProjects())
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/shared-projects", metadata: RouteMetadata(summary: "Create shared project", description: "Creates a SloppyNode mesh shared project", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshSharedProjectCreateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.createMeshSharedProject(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.patch("/v1/node/mesh/shared-projects/:projectId", metadata: RouteMetadata(summary: "Update shared project", description: "Updates SloppyNode mesh shared project metadata", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshSharedProjectUpdateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let projectId = request.pathParam("projectId") ?? ""
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.updateMeshSharedProject(id: projectId, request: payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.delete("/v1/node/mesh/shared-projects/:projectId", metadata: RouteMetadata(summary: "Disable shared project", description: "Removes a SloppyNode mesh shared project and its members", tags: ["Node Mesh"])) { request in
            do {
                let projectId = request.pathParam("projectId") ?? ""
                try await service.deleteMeshSharedProject(id: projectId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/shared-projects/:projectId/members", metadata: RouteMetadata(summary: "Attach shared project member", description: "Adds or updates a mesh node member for a shared project", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshSharedProjectMemberRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let projectId = request.pathParam("projectId") ?? ""
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.attachMeshSharedProjectMember(projectId: projectId, request: payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.get("/v1/node/mesh/tasks", metadata: RouteMetadata(summary: "List mesh tasks", description: "Returns SloppyNode mesh task lifecycle records", tags: ["Node Mesh"])) { request in
            do {
                let projectId = request.queryParam("projectId")
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.listMeshTasks(projectId: projectId))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.post("/v1/node/mesh/tasks", metadata: RouteMetadata(summary: "Dispatch mesh task", description: "Creates and dispatches a task to a mesh node", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshTaskCreateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.createMeshTask(payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.patch("/v1/node/mesh/tasks/:taskId", metadata: RouteMetadata(summary: "Update mesh task", description: "Updates mesh task lifecycle state and review metadata", tags: ["Node Mesh"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: MeshTaskUpdateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let taskId = request.pathParam("taskId") ?? ""
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.updateMeshTask(id: taskId, request: payload))
            } catch {
                return meshErrorResponse(error)
            }
        }

        router.get("/v1/node/mesh/audit-log", metadata: RouteMetadata(summary: "List mesh audit log", description: "Returns mesh authorization, routing, and task audit entries", tags: ["Node Mesh"])) { _ in
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.listMeshAuditLog())
            } catch {
                return meshErrorResponse(error)
            }
        }
    }
}

private struct MeshCoreProxyHTTPRequest: Codable {
    var method: String
    var path: String
    var headers: [String: String]
    var bodyBase64: String?

    init(method: String, path: String, headers: [String: String] = [:], bodyBase64: String? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.bodyBase64 = bodyBase64
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case path
        case headers
        case bodyBase64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        path = try container.decode(String.self, forKey: .path)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        bodyBase64 = try container.decodeIfPresent(String.self, forKey: .bodyBase64)
    }
}

private struct MeshCoreProxyHTTPResponse: Codable {
    var status: Int
    var contentType: String
    var bodyBase64: String
}

private func meshErrorResponse(_ error: Error) -> CoreRouterResponse {
    let message = error.localizedDescription
    if let remoteJoinError = error as? MeshRemoteJoinError {
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: [
            "error": "mesh_invalid_request",
            "message": remoteJoinError.localizedDescription,
        ])
    }
    if let meshProxyError = error as? CoreService.MeshCoreProxyError {
        switch meshProxyError {
        case .missingMeshUserContext:
            return CoreRouter.json(status: HTTPStatus.unauthorized, payload: [
                "error": "mesh_missing_user_context",
                "message": meshProxyError.localizedDescription,
            ])
        default:
            return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "mesh_proxy_error", "message": message])
        }
    }
    if let meshError = error as? NodeMeshStoreError {
        switch meshError {
        case .nodeMissing, .projectMissing, .taskMissing:
            return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "mesh_not_found", "message": message])
        case .permissionDenied:
            return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "mesh_forbidden", "message": message])
        case .inviteMissing, .inviteWrongCoordinator, .inviteExpired, .inviteConsumed, .taskAmbiguous:
            return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "mesh_invalid_request", "message": message])
        }
    }
    return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "mesh_store_failed", "message": message])
}
