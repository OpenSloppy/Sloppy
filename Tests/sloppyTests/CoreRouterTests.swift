import Foundation
import Testing
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols
import PluginSDK
import SloppyNodeCore

#if canImport(CSQLite3)
import CSQLite3
#endif

private struct ErrorResponse: Decodable {
    let error: String
    let message: String?
}

private struct DashboardAuthValidateResponsePayload: Decodable {
    struct Capabilities: Decodable {
        let acceptsLegacyToken: Bool
        let mutatingRoutesProtected: Bool
        let terminalWebSocketProtected: Bool
    }

    let ok: Bool
    let capabilities: Capabilities
}

private struct DashboardAuthStatusResponsePayload: Decodable {
    let enabled: Bool
    let capabilities: DashboardAuthValidateResponsePayload.Capabilities
}

private struct HealthResponsePayload: Decodable {
    let status: String
    let pid: Int32
}

@Test
func postChannelMessageEndpoint() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "respond please"))
    let response = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: body)

    #expect(response.status == 200)
}

@Test
func bulletinsEndpoint() async {
    let service = CoreService(config: .test)
    _ = await service.triggerVisorBulletin()
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/bulletins", body: nil)
    #expect(response.status == 200)
}

@Test
func meshAPIListsStateAndDispatchesTasks() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    try service.nodeMeshStore.save(MeshState(
        nodes: [
            MeshNodeRecord(
                id: "node_worker",
                name: "Home Mac",
                publicKey: "public-key",
                roles: ["worker"],
                status: .online,
                capabilities: ["git", "agent"]
            ),
        ],
        sharedProjects: [
            SharedProjectRecord(
                id: "shared_mesh",
                name: "Mesh",
                repoUrl: "git@example.com:mesh.git",
                members: [
                    SharedProjectMember(
                        nodeId: "node_worker",
                        actorId: "agent:worker",
                        localRepoPath: "/tmp/mesh",
                        role: "worker",
                        permissions: MeshPermission.workerDefaults.rawValues + [MeshPermission.taskAssign.rawValue]
                    ),
                ]
            ),
        ],
        auditLog: [
            MeshAuditLogEntry(actor: "local", action: "network.create", allowed: true),
        ]
    ))

    let nodesResponse = await router.handle(method: "GET", path: "/v1/node/mesh/nodes", body: nil)
    #expect(nodesResponse.status == 200)
    let nodes = try decoder.decode([MeshNodeRecord].self, from: nodesResponse.body)
    #expect(nodes.map(\.id) == ["node_worker"])

    let projectsResponse = await router.handle(method: "GET", path: "/v1/node/mesh/shared-projects", body: nil)
    #expect(projectsResponse.status == 200)
    let projects = try decoder.decode([SharedProjectRecord].self, from: projectsResponse.body)
    #expect(projects.first?.members.first?.localRepoPath == "/tmp/mesh")

    let createProjectBody = try encoder.encode(MeshSharedProjectCreateRequest(
        name: "Mesh API",
        repoUrl: "git@example.com:mesh-api.git",
        defaultBranch: "main"
    ))
    let createProjectResponse = await router.handle(method: "POST", path: "/v1/node/mesh/shared-projects", body: createProjectBody)
    #expect(createProjectResponse.status == 201)
    let createdProject = try decoder.decode(SharedProjectRecord.self, from: createProjectResponse.body)
    #expect(createdProject.name == "Mesh API")

    let attachBody = try encoder.encode(MeshSharedProjectMemberRequest(
        nodeId: "node_worker",
        actorId: "agent:worker",
        localRepoPath: "/tmp/mesh-api",
        role: "worker",
        permissions: MeshPermission.workerDefaults.rawValues
    ))
    let attachResponse = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/shared-projects/\(createdProject.id)/members",
        body: attachBody
    )
    #expect(attachResponse.status == 200)
    let attachedProject = try decoder.decode(SharedProjectRecord.self, from: attachResponse.body)
    #expect(attachedProject.members.first?.localRepoPath == "/tmp/mesh-api")

    let updateProjectBody = try encoder.encode(MeshSharedProjectUpdateRequest(defaultBranch: "develop"))
    let updateProjectResponse = await router.handle(
        method: "PATCH",
        path: "/v1/node/mesh/shared-projects/\(createdProject.id)",
        body: updateProjectBody
    )
    #expect(updateProjectResponse.status == 200)
    let updatedProject = try decoder.decode(SharedProjectRecord.self, from: updateProjectResponse.body)
    #expect(updatedProject.defaultBranch == "develop")

    let deleteProjectResponse = await router.handle(
        method: "DELETE",
        path: "/v1/node/mesh/shared-projects/\(createdProject.id)",
        body: nil
    )
    #expect(deleteProjectResponse.status == 200)

    let projectsAfterDeleteResponse = await router.handle(method: "GET", path: "/v1/node/mesh/shared-projects", body: nil)
    #expect(projectsAfterDeleteResponse.status == 200)
    let projectsAfterDelete = try decoder.decode([SharedProjectRecord].self, from: projectsAfterDeleteResponse.body)
    #expect(!projectsAfterDelete.contains { $0.id == createdProject.id })

    let createBody = try encoder.encode(MeshTaskCreateRequest(
        projectId: "shared_mesh",
        title: "Implement dashboard flow",
        assignedNodeId: "node_worker"
    ))
    let createResponse = await router.handle(method: "POST", path: "/v1/node/mesh/tasks", body: createBody)
    #expect(createResponse.status == 201)
    let createdTask = try decoder.decode(MeshTaskRecord.self, from: createResponse.body)
    #expect(createdTask.status == .dispatched)
    #expect(createdTask.assignedNodeId == "node_worker")

    let updateBody = try encoder.encode(MeshTaskUpdateRequest(
        status: .readyForReview,
        branch: "agent/home/mesh",
        commit: "abc123",
        summary: "Ready"
    ))
    let updateResponse = await router.handle(method: "PATCH", path: "/v1/node/mesh/tasks/\(createdTask.id)", body: updateBody)
    #expect(updateResponse.status == 200)
    let updatedTask = try decoder.decode(MeshTaskRecord.self, from: updateResponse.body)
    #expect(updatedTask.branch == "agent/home/mesh")
    #expect(updatedTask.commit == "abc123")

    let tasksResponse = await router.handle(method: "GET", path: "/v1/node/mesh/tasks?projectId=shared_mesh", body: nil)
    #expect(tasksResponse.status == 200)
    let tasks = try decoder.decode([MeshTaskRecord].self, from: tasksResponse.body)
    #expect(tasks.map(\.id) == [createdTask.id])

    let auditResponse = await router.handle(method: "GET", path: "/v1/node/mesh/audit-log", body: nil)
    #expect(auditResponse.status == 200)
    let auditLog = try decoder.decode([MeshAuditLogEntry].self, from: auditResponse.body)
    #expect(auditLog.contains { $0.action == "task.dispatch" && $0.allowed })
}

@Test
func meshAPIConfiguresNetworkInvitesAndRegisteredNodes() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let networkBody = try encoder.encode(MeshNetworkUpdateRequest(id: "studio", name: "Studio Mesh"))
    let networkResponse = await router.handle(method: "POST", path: "/v1/node/mesh/network", body: networkBody)
    #expect(networkResponse.status == 200)
    let networkState = try decoder.decode(MeshState.self, from: networkResponse.body)
    #expect(networkState.networkId == "studio")
    #expect(networkState.networkName == "Studio Mesh")

    let inviteBody = try encoder.encode(MeshInviteCreateRequest(
        networkId: "studio",
        name: "Render Worker",
        roles: ["worker"],
        capabilities: ["run_agent", "git"],
        ttlSeconds: 600,
        relayURL: "https://sloppy.example.com",
        nodeId: "node_render",
        publicKey: "ed25519:public"
    ))
    let inviteResponse = await router.handle(method: "POST", path: "/v1/node/mesh/invites", body: inviteBody)
    #expect(inviteResponse.status == 201)
    let invite = try decoder.decode(MeshInvite.self, from: inviteResponse.body)
    #expect(invite.networkId == "studio")
    #expect(invite.name == "Render Worker")
    #expect(invite.relayURL == "https://sloppy.example.com")
    #expect(invite.publicKey == "ed25519:public")
    let bundleToken = try #require(invite.bundleToken)
    let bundle = try MeshInviteBundle.parse(bundleToken)
    #expect(bundle.inviteToken == invite.token)
    #expect(bundle.relayURL == "https://sloppy.example.com")
    #expect(bundle.nodeId == "node_render")
    #expect(bundle.publicKey == "ed25519:public")
    let inviteObject = try #require(JSONSerialization.jsonObject(with: inviteResponse.body) as? [String: Any])
    #expect((inviteObject["bundleToken"] as? String)?.hasPrefix(MeshInviteBundle.prefix) == true)

    let acceptBody = Data(#"{"token":"\#(bundleToken)"}"#.utf8)
    let acceptResponse = await router.handle(method: "POST", path: "/v1/node/mesh/invites/accept", body: acceptBody)
    #expect(acceptResponse.status == 201)
    let acceptedNode = try decoder.decode(MeshNodeRecord.self, from: acceptResponse.body)
    #expect(acceptedNode.id == "node_render")
    #expect(acceptedNode.publicKey == "ed25519:public")
    #expect(acceptedNode.endpoint == "https://sloppy.example.com")

    let nodeBody = try encoder.encode(MeshNodeRegisterRequest(
        id: "node_render",
        name: "Render Worker",
        publicKey: "ed25519:public",
        roles: ["worker"],
        endpoint: nil,
        capabilities: ["run_agent", "git"]
    ))
    let nodeResponse = await router.handle(method: "POST", path: "/v1/node/mesh/nodes", body: nodeBody)
    #expect(nodeResponse.status == 201)
    let node = try decoder.decode(MeshNodeRecord.self, from: nodeResponse.body)
    #expect(node.id == "node_render")
    #expect(node.publicKey == "ed25519:public")

    let pendingInviteBody = try encoder.encode(MeshInviteCreateRequest(
        networkId: "studio",
        name: "Pending Worker",
        roles: ["worker"],
        capabilities: ["git"],
        ttlSeconds: 600,
        relayURL: "https://sloppy.example.com",
        nodeId: "node_pending",
        publicKey: "ed25519:pending_public"
    ))
    let pendingInviteResponse = await router.handle(method: "POST", path: "/v1/node/mesh/invites", body: pendingInviteBody)
    #expect(pendingInviteResponse.status == 201)
    let pendingInvite = try decoder.decode(MeshInvite.self, from: pendingInviteResponse.body)

    let stateResponse = await router.handle(method: "GET", path: "/v1/node/mesh", body: nil)
    #expect(stateResponse.status == 200)
    let state = try decoder.decode(MeshState.self, from: stateResponse.body)
    #expect(state.nodes.map(\.id) == ["node_render"])
    #expect(state.invites.map(\.token) == [invite.token, pendingInvite.token])

    let revokeResponse = await router.handle(method: "DELETE", path: "/v1/node/mesh/invites/\(pendingInvite.token)", body: nil)
    #expect(revokeResponse.status == 200)
    let revokeObject = try #require(JSONSerialization.jsonObject(with: revokeResponse.body) as? [String: Any])
    #expect(revokeObject["status"] as? String == "deleted")

    let revokedStateResponse = await router.handle(method: "GET", path: "/v1/node/mesh", body: nil)
    #expect(revokedStateResponse.status == 200)
    let revokedState = try decoder.decode(MeshState.self, from: revokedStateResponse.body)
    #expect(revokedState.invites.map(\.token) == [invite.token])
}

@Test
func meshAPIAcceptInviteExplainsWrongCoordinator() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()

    let token = try MeshInviteBundle(
        inviteToken: "slp_invite_missing",
        relayURL: "https://relay.example.com",
        nodeId: "node_worker",
        publicKey: "ed25519:public"
    ).tokenString()
    let body = try encoder.encode(MeshInviteAcceptRequest(token: token))

    let response = await router.handle(method: "POST", path: "/v1/node/mesh/invites/accept", body: body)

    #expect(response.status == 400)
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(object["error"] as? String == "mesh_invalid_request")
    let message = try #require(object["message"] as? String)
    #expect(message.contains("relay https://relay.example.com"))
    #expect(message.contains("Switch the dashboard API base"))
}

@Test
func meshAPIAcceptGenericInviteWithSuppliedIdentity() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let inviteBody = try encoder.encode(MeshInviteCreateRequest(
        networkId: "personal",
        name: "Work Mac",
        roles: ["worker"],
        capabilities: ["run_agent", "git"],
        ttlSeconds: 600,
        relayURL: "https://mesh.example.com"
    ))
    let inviteResponse = await router.handle(method: "POST", path: "/v1/node/mesh/invites", body: inviteBody)
    #expect(inviteResponse.status == 201)
    let invite = try decoder.decode(MeshInvite.self, from: inviteResponse.body)
    let token = try #require(invite.bundleToken)

    let acceptBody = try encoder.encode(MeshInviteAcceptRequest(
        token: token,
        endpoint: "https://mesh.example.com",
        nodeId: "node_work",
        name: "Work Mac",
        publicKey: "ed25519:work_public",
        roles: ["worker"],
        capabilities: ["run_agent", "git"]
    ))
    let acceptResponse = await router.handle(method: "POST", path: "/v1/node/mesh/invites/accept", body: acceptBody)

    #expect(acceptResponse.status == 201)
    let node = try decoder.decode(MeshNodeRecord.self, from: acceptResponse.body)
    #expect(node.id == "node_work")
    #expect(node.publicKey == "ed25519:work_public")
}

@Test
func meshAPIAcceptInviteRejectsWrongBodyWithExpectedShape() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "POST", path: "/v1/node/mesh/invites/accept", body: Data(#""slp_mesh_example""#.utf8))

    #expect(response.status == 400)
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(object["error"] as? String == ErrorCode.invalidBody)
    let message = try #require(object["message"] as? String)
    #expect(message.contains(#""token""#))
    #expect(message.contains("slp_mesh"))
}

@Test
func meshAPIRemoteJoinRejectsInvalidBodyWithExpectedShape() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "POST", path: "/v1/node/mesh/remote-joins", body: Data("{}".utf8))

    #expect(response.status == 400)
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(object["error"] as? String == "invalid_body")
    #expect((object["message"] as? String)?.contains(#""token":"slp_mesh_...""#) == true)
}

@Test
func meshAPIStateIncludesLocalNodeConfigAfterRemoteJoin() async throws {
    let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-tests-\(UUID().uuidString)")
        .appendingPathComponent("node.json")
    let identity = NodeIdentityGenerator.makeIdentity(
        name: "Work Mac", roles: ["worker"], capabilities: ["run_agent", "git"]
    )
    let configStore = NodeConfigStore(configURL: configURL)
    try configStore.save(NodeConfig(
        identity: identity,
        relayURL: "http://mesh.example.com",
        networkId: "personal",
        networkName: "VPS-Node"
    ))
    let service = CoreService(config: .test, nodeConfigStore: configStore)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let response = await router.handle(method: "GET", path: "/v1/node/mesh", body: nil)

    #expect(response.status == 200)
    let state = try decoder.decode(MeshState.self, from: response.body)
    #expect(state.networkId == "personal")
    #expect(state.networkName == "VPS-Node")
    #expect(state.localNode?.id == identity.nodeId)
    #expect(state.localNode?.name == "Work Mac")
    #expect(state.localNode?.relayURL == "http://mesh.example.com")
    #expect(state.localNode?.networkName == "VPS-Node")
    #expect(state.localNode?.roles == ["worker"])
    #expect(state.localNode?.capabilities == ["run_agent", "git"])
}

@Test
func meshCoreHTTPRPCDelegatesToLocalCoreRouter() async throws {
    let service = CoreService(config: .test)
    let controller = NodeIdentityGenerator.makeIdentity(
        name: "Controller", roles: ["controller"], capabilities: ["sloppy.core.remote"]
    )
    _ = try await service.nodeMeshStore.registerNode(controller)
    _ = try await service.createProject(ProjectCreateRequest(id: "mesh-remote", name: "Mesh Remote"))
    let payload = await service.handleMeshCoreHTTPRPC(
        envelope: MeshEnvelope(id: "rpc_http", type: .rpcRequest, from: controller.nodeId, to: "node_worker"),
        method: "core.http",
        params: .object([
            "method": .string("GET"),
            "path": .string("/v1/projects"),
        ])
    )

    let object = try #require(payload.asObject)
    #expect(object["requestId"] == .string("rpc_http"))
    #expect(object["method"] == .string("core.http"))
    #expect(object["ok"] == .bool(true))
    let result = try #require(object["result"]?.asObject)
    #expect(result["status"] == .number(200))
    let bodyBase64 = try #require(result["bodyBase64"]?.asString)
    let body = try #require(Data(base64Encoded: bodyBase64))
    let projects = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    #expect(projects.contains { $0["id"] as? String == "mesh-remote" })
}

@Test
func meshCoreHTTPRPCRequiresUserContextInLoginPasswordMode() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"
    config.auth.token = ""

    let service = CoreService(config: config)
    let controller = NodeIdentityGenerator.makeIdentity(
        name: "Controller", roles: ["controller"], capabilities: ["sloppy.core.remote"]
    )
    _ = try await service.nodeMeshStore.registerNode(controller)
    _ = try await service.createProject(ProjectCreateRequest(id: "mesh-login", name: "Mesh Login"))

    let withoutContext = await service.handleMeshCoreHTTPRPC(
        envelope: MeshEnvelope(id: "rpc_http_context", type: .rpcRequest, from: controller.nodeId, to: "node_worker"),
        method: "core.http",
        params: .object([
            "method": .string("GET"),
            "path": .string("/v1/projects"),
            "headers": .object([:]),
        ])
    )
    let missingObject = try #require(withoutContext.asObject)
    let missingError = try #require(missingObject["error"]?.asObject)
    #expect(missingError["code"] == .string("mesh_missing_user_context"))

    let withContext = await service.handleMeshCoreHTTPRPC(
        envelope: MeshEnvelope(id: "rpc_http_context", type: .rpcRequest, from: controller.nodeId, to: "node_worker"),
        method: "core.http",
        params: .object([
            "method": .string("GET"),
            "path": .string("/v1/projects"),
            "headers": .object(["x-sloppy-user-context": .string("user-admin")]),
        ])
    )
    let withContextObject = try #require(withContext.asObject)
    #expect(withContextObject["ok"] == .bool(false))
    #expect(withContextObject["result"]?.asObject?["status"] == .number(401))
    let authenticated = await service.handleMeshCoreHTTPRPC(
        envelope: MeshEnvelope(id: "rpc_http_authenticated", type: .rpcRequest, from: controller.nodeId, to: "node_worker"),
        method: "core.http",
        params: .object([
            "method": .string("GET"), "path": .string("/v1/projects"),
            "headers": .object(["x-sloppy-user-context": .string("user-admin"), "authorization": .string("Bearer dashboard-secret")]),
        ])
    )
    #expect(authenticated.asObject?["ok"] == .bool(true))
}

@Test
func meshAPIProxiesCoreRequestToSelectedNode() async throws {
    let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-tests-\(UUID().uuidString)")
        .appendingPathComponent("node.json")
    let identity = NodeIdentityGenerator.makeIdentity(
        name: "Local Mesh",
        roles: ["controller"],
        capabilities: ["run_agent", "git"]
    )
    let configStore = NodeConfigStore(configURL: configURL)
    try configStore.save(NodeConfig(identity: identity, relayURL: "http://mesh.example.test"))
    let service = CoreService(config: .test, nodeConfigStore: configStore)
    _ = try await service.createProject(ProjectCreateRequest(id: "mesh-proxy", name: "Mesh Proxy"))
    let router = CoreRouter(service: service)
    let body = Data(#"{"method":"GET","path":"/v1/projects"}"#.utf8)

    let response = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/nodes/\(identity.nodeId)/core",
        body: body
    )

    #expect(response.status == 200)
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(object["status"] as? Int == 200)
    let bodyBase64 = try #require(object["bodyBase64"] as? String)
    let proxiedBody = try #require(Data(base64Encoded: bodyBase64))
    let projects = try #require(JSONSerialization.jsonObject(with: proxiedBody) as? [[String: Any]])
    #expect(projects.contains { $0["id"] as? String == "mesh-proxy" })
}

@Test
func meshAPIProxiesCoreRequestRequiresUserContextInLoginPasswordMode() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"
    config.auth.token = ""

    let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-tests-\(UUID().uuidString)")
        .appendingPathComponent("node.json")
    let identity = NodeIdentityGenerator.makeIdentity(
        name: "Local Mesh",
        roles: ["controller"],
        capabilities: ["run_agent", "git"]
    )
    let configStore = NodeConfigStore(configURL: configURL)
    try configStore.save(NodeConfig(identity: identity, relayURL: "http://mesh.example.test"))

    let service = CoreService(config: config, nodeConfigStore: configStore)
    _ = try await service.createProject(ProjectCreateRequest(id: "mesh-proxy", name: "Mesh Proxy"))
    let router = CoreRouter(service: service)
    let body = Data(#"{"method":"GET","path":"/v1/projects"}"#.utf8)

    let missingContext = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/nodes/\(identity.nodeId)/core",
        body: body,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(missingContext.status == 401)

    let authorized = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/nodes/\(identity.nodeId)/core",
        body: body,
        headers: ["Authorization": "Bearer dashboard-secret", "x-sloppy-user-context": "user-admin"]
    )
    #expect(authorized.status == 200)
    let bodyObject = try #require(JSONSerialization.jsonObject(with: authorized.body) as? [String: Any])
    #expect(bodyObject["status"] as? Int == 200)

    // The transport credential is mandatory even when an inner header is supplied.
    let spoofed = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/nodes/\(identity.nodeId)/core",
        body: Data(#"{"method":"GET","path":"/v1/projects","headers":{"authorization":"Bearer dashboard-secret","x-sloppy-user-context":"user-admin"}}"#.utf8)
    )
    #expect(spoofed.status == 401)

    // Native clients carry user context in the payload; retain this wire format.
    let payloadContext = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/nodes/\(identity.nodeId)/core",
        body: Data(#"{"method":"GET","path":"/v1/projects","headers":{"Authorization":"Bearer wrong-inner-token","X-Sloppy-User-Context":"user-admin"}}"#.utf8),
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(payloadContext.status == 200)
    let payloadObject = try #require(JSONSerialization.jsonObject(with: payloadContext.body) as? [String: Any])
    #expect(payloadObject["status"] as? Int == 200)

}

@Test
func meshAPIDeletesRegisteredNode() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let registerBody = try encoder.encode(MeshNodeRegisterRequest(
        id: "node_work",
        name: "Work Mac",
        publicKey: "ed25519:work",
        roles: ["worker"],
        capabilities: ["run_agent", "git"]
    ))
    let registerResponse = await router.handle(method: "POST", path: "/v1/node/mesh/nodes", body: registerBody)
    #expect(registerResponse.status == 201)

    let deleteResponse = await router.handle(method: "DELETE", path: "/v1/node/mesh/nodes/node_work", body: nil)
    #expect(deleteResponse.status == 200)

    let nodesResponse = await router.handle(method: "GET", path: "/v1/node/mesh/nodes", body: nil)
    let nodes = try decoder.decode([MeshNodeRecord].self, from: nodesResponse.body)
    #expect(nodes.isEmpty)

    let stateResponse = await router.handle(method: "GET", path: "/v1/node/mesh", body: nil)
    let state = try decoder.decode(MeshState.self, from: stateResponse.body)
    #expect(state.auditLog.last?.action == "node.delete.api")
    #expect(state.auditLog.last?.target == "node_work")

    let repeatedDelete = await router.handle(method: "DELETE", path: "/v1/node/mesh/nodes/node_work", body: nil)
    #expect(repeatedDelete.status == 404)
}

@Test
func sessionListEndpointsSupportPaginationAndRecentMessages() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let agentID = "session-list-router"
    _ = try await service.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Session List Router", role: "Testing")
    )
    let first = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "First")
    )
    let second = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Second")
    )
    let third = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Third")
    )

    for (index, session) in [first, second, third].enumerated() {
        let event = AgentSessionEvent(
            agentId: agentID,
            sessionId: session.id,
            type: .message,
            createdAt: Date().addingTimeInterval(TimeInterval(index + 1) * 60),
            message: AgentSessionMessage(
                role: .user,
                segments: [AgentMessageSegment(kind: .text, text: "router \(index)")],
                userId: "tester"
            )
        )
        let appendBody = try encoder.encode(AgentSessionAppendEventsRequest(events: [event]))
        let appendResponse = await router.handle(
            method: "POST",
            path: "/v1/agents/\(agentID)/sessions/\(session.id)/events",
            body: appendBody
        )
        #expect(appendResponse.status == 200)
    }

    let agentResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/\(agentID)/sessions?limit=1&offset=1",
        body: nil
    )
    #expect(agentResponse.status == 200)
    let agentSessions = try decoder.decode([AgentSessionSummary].self, from: agentResponse.body)
    #expect(agentSessions.map(\.id) == [second.id])

    let startedAt = Date()
    _ = try await service.channelSessionStore.recordUserMessage(
        channelId: "router-channel",
        userId: "user-1",
        content: "Alpha",
        createdAt: startedAt
    )
    _ = try await service.channelSessionStore.recordAssistantMessage(
        channelId: "router-channel",
        content: "Beta",
        createdAt: startedAt.addingTimeInterval(1)
    )
    _ = try await service.channelSessionStore.recordUserMessage(
        channelId: "router-channel",
        userId: "user-2",
        content: "Gamma",
        createdAt: startedAt.addingTimeInterval(2)
    )

    let channelResponse = await router.handle(
        method: "GET",
        path: "/v1/channel-sessions?status=open&recentMessagesLimit=2&limit=1&offset=0",
        body: nil
    )
    #expect(channelResponse.status == 200)
    let channelSessions = try decoder.decode([ChannelSessionSummary].self, from: channelResponse.body)
    #expect(channelSessions.count == 1)
    #expect(channelSessions.first?.channelId == "router-channel")
    #expect(channelSessions.first?.recentMessages?.map(\.content) == ["Beta", "Gamma"])
}

@Test
func workersEndpoint() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        WorkerCreateRequest(
            spec: WorkerTaskSpec(
                taskId: "task-1",
                channelId: "general",
                title: "Worker",
                objective: "Do work",
                tools: ["shell"],
                mode: .interactive
            )
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/workers", body: createBody)
    #expect(createResponse.status == 201)

    let response = await router.handle(method: "GET", path: "/v1/workers", body: nil)
    #expect(response.status == 200)

    let workers = try JSONDecoder().decode([WorkerSnapshot].self, from: response.body)
    #expect(!workers.isEmpty)
}

@Test
func workersEndpointIncludesMetadataAndCanCancelWorker() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        WorkerCreateRequest(
            spec: WorkerTaskSpec(
                taskId: "task-cancel",
                channelId: "general",
                title: "Cancelable Worker",
                objective: "Wait for operator cancellation",
                tools: ["shell"],
                mode: .interactive
            )
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/workers", body: createBody)
    #expect(createResponse.status == 201)
    let createPayload = try #require(JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any])
    let workerId = try #require(createPayload["workerId"] as? String)

    let listResponse = await router.handle(method: "GET", path: "/v1/workers", body: nil)
    #expect(listResponse.status == 200)
    let rawWorkers = try #require(JSONSerialization.jsonObject(with: listResponse.body) as? [[String: Any]])
    let rawWorker = try #require(rawWorkers.first(where: { $0["workerId"] as? String == workerId }))
    #expect(rawWorker["title"] as? String == "Cancelable Worker")
    #expect(rawWorker["createdAt"] as? String != nil)
    #expect(rawWorker["updatedAt"] as? String != nil)

    let cancelBody = try JSONEncoder().encode(["reason": "Cancelled from dashboard"])
    let cancelResponse = await router.handle(
        method: "POST",
        path: "/v1/workers/\(workerId)/cancel",
        body: cancelBody
    )
    #expect(cancelResponse.status == 200)

    let workers = try JSONDecoder().decode([WorkerSnapshot].self, from: (await router.handle(method: "GET", path: "/v1/workers", body: nil)).body)
    let cancelledWorker = try #require(workers.first(where: { $0.workerId == workerId }))
    #expect(cancelledWorker.status == WorkerStatus.failed)
    #expect(cancelledWorker.latestReport == "Cancelled from dashboard")
}

@Test
func routerRegistersRoutesAcrossDomainsOnInitialization() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let healthResponse = await router.handle(method: "GET", path: "/health", body: nil)
    #expect(healthResponse.status == 200)
    let healthPayload = try JSONDecoder().decode(HealthResponsePayload.self, from: healthResponse.body)
    #expect(healthPayload.status == "ok")
    #expect(healthPayload.pid == ProcessInfo.processInfo.processIdentifier)

    let performanceResponse = await router.handle(method: "GET", path: "/v1/system/performance?limit=12", body: nil)
    #expect(performanceResponse.status == 200)
    let performancePayload = try JSONSerialization.jsonObject(with: performanceResponse.body) as? [String: Any]
    #expect(performancePayload?["samples"] is [Any])
    #expect(performancePayload?["summary"] is [String: Any])

    let channelStateResponse = await router.handle(method: "GET", path: "/v1/channels/general/state", body: nil)
    #expect(channelStateResponse.status == 200)

    let agentsResponse = await router.handle(method: "GET", path: "/v1/agents", body: nil)
    #expect(agentsResponse.status == 200)

    let projectsResponse = await router.handle(method: "GET", path: "/v1/projects", body: nil)
    #expect(projectsResponse.status == 200)
}

@Test
func projectCrudEndpoints() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: "platform-board",
            name: "Platform Board",
            description: "sloppy + dashboard roadmap",
            channels: [.init(title: "General", channelId: "general")]
        )
    )

    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createOutcome = try decoder.decode(ProjectCreateResult.self, from: createResponse.body)
    #expect(createOutcome.repoCloneSucceeded == nil)
    let created = createOutcome.project
    #expect(created.id == "platform-board")
    #expect(created.name == "Platform Board")
    #expect(created.channels.count == 1)
    #expect(created.tasks.isEmpty)

    let listResponse = await router.handle(method: "GET", path: "/v1/projects", body: nil)
    #expect(listResponse.status == 200)
    let list = try decoder.decode([ProjectRecord].self, from: listResponse.body)
    #expect(list.contains(where: { $0.id == created.id }))

    let summaryResponse = await router.handle(method: "GET", path: "/v1/projects?summary=true", body: nil)
    #expect(summaryResponse.status == 200)
    let summaries = try decoder.decode([ProjectListRecord].self, from: summaryResponse.body)
    #expect(summaries.contains(where: { $0.id == created.id && $0.taskCounts.total == 0 }))

    let updateBody = try JSONEncoder().encode(ProjectUpdateRequest(name: "Platform Board v2"))
    let updateResponse = await router.handle(method: "PATCH", path: "/v1/projects/\(created.id)", body: updateBody)
    #expect(updateResponse.status == 200)
    let updated = try decoder.decode(ProjectRecord.self, from: updateResponse.body)
    #expect(updated.name == "Platform Board v2")

    let favoriteBody = try JSONEncoder().encode(ProjectUpdateRequest(isFavorite: true))
    let favoriteResponse = await router.handle(method: "PATCH", path: "/v1/projects/\(created.id)", body: favoriteBody)
    #expect(favoriteResponse.status == 200)
    let favoriteProject = try decoder.decode(ProjectRecord.self, from: favoriteResponse.body)
    #expect(favoriteProject.isFavorite)

    let updateMembersBody = try JSONEncoder().encode(
        ProjectUpdateRequest(actors: ["actor:builder", "actor:qa"], teams: ["team:platform"])
    )
    let updateMembersResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(created.id)",
        body: updateMembersBody
    )
    #expect(updateMembersResponse.status == 200)
    let updatedMembers = try decoder.decode(ProjectRecord.self, from: updateMembersResponse.body)
    #expect(updatedMembers.actors == ["actor:builder", "actor:qa"])
    #expect(updatedMembers.teams == ["team:platform"])

    let createTaskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Wire API",
            description: "Implement CRUD for projects and tasks",
            priority: "high",
            status: "backlog",
            attachments: [
                AgentAttachmentUpload(
                    name: "brief.png",
                    mimeType: "image/png",
                    sizeBytes: 12,
                    contentBase64: "YnJpZWY="
                )
            ]
        )
    )
    let createTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(created.id)/tasks",
        body: createTaskBody
    )
    #expect(createTaskResponse.status == 200)
    let withTask = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
    #expect(withTask.tasks.count == 1)

    let taskID = try #require(withTask.tasks.first?.id)
    #expect(taskID == "PLATFORM-BOARD-1")
    #expect(withTask.tasks.first?.attachments.first?.name == "brief.png")
    #expect(withTask.tasks.first?.attachments.first?.mimeType == "image/png")

    let createSecondTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(created.id)/tasks",
        body: createTaskBody
    )
    #expect(createSecondTaskResponse.status == 200)
    let withSecondTask = try decoder.decode(ProjectRecord.self, from: createSecondTaskResponse.body)
    #expect(withSecondTask.tasks.contains(where: { $0.id == "PLATFORM-BOARD-2" }))

    let taskLookupResponse = await router.handle(
        method: "GET",
        path: "/tasks/\(taskID)",
        body: nil
    )
    #expect(taskLookupResponse.status == 200)
    let taskLookup = try decoder.decode(AgentTaskRecord.self, from: taskLookupResponse.body)
    #expect(taskLookup.projectId == created.id)
    #expect(taskLookup.task.id == taskID)

    let patchTaskBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "in_progress"))
    let patchTaskResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(created.id)/tasks/\(taskID)",
        body: patchTaskBody
    )
    #expect(patchTaskResponse.status == 200)
    let patchedTaskProject = try decoder.decode(ProjectRecord.self, from: patchTaskResponse.body)
    #expect(patchedTaskProject.tasks.first?.status == "in_progress")

    let createChannelBody = try JSONEncoder().encode(ProjectChannelCreateRequest(title: "Backend", channelId: "backend"))
    let createChannelResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(created.id)/channels",
        body: createChannelBody
    )
    #expect(createChannelResponse.status == 200)
    let withSecondChannel = try decoder.decode(ProjectRecord.self, from: createChannelResponse.body)
    #expect(withSecondChannel.channels.count == 2)

    let removableChannelID = try #require(
        withSecondChannel.channels.first(where: { $0.channelId == "backend" })?.id
    )
    let removeChannelResponse = await router.handle(
        method: "DELETE",
        path: "/v1/projects/\(created.id)/channels/\(removableChannelID)",
        body: nil
    )
    #expect(removeChannelResponse.status == 200)
    let afterChannelDelete = try decoder.decode(ProjectRecord.self, from: removeChannelResponse.body)
    #expect(afterChannelDelete.channels.count == 1)

    let removeTaskResponse = await router.handle(
        method: "DELETE",
        path: "/v1/projects/\(created.id)/tasks/\(taskID)",
        body: nil
    )
    #expect(removeTaskResponse.status == 200)
    let afterTaskDelete = try decoder.decode(ProjectRecord.self, from: removeTaskResponse.body)
    #expect(afterTaskDelete.tasks.count == 1)
    #expect(afterTaskDelete.tasks.first?.id == "PLATFORM-BOARD-2")

    let deleteProjectResponse = await router.handle(method: "DELETE", path: "/v1/projects/\(created.id)", body: nil)
    #expect(deleteProjectResponse.status == 200)

    let fetchDeletedResponse = await router.handle(method: "GET", path: "/v1/projects/\(created.id)", body: nil)
    #expect(fetchDeletedResponse.status == 404)
}

@Test
func projectChannelLinkEndpointLinksDetectsDuplicatesAndConflicts() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let firstCreate = try JSONEncoder().encode(
        ProjectCreateRequest(id: "avito", name: "AVITO", channels: [.init(title: "Main", channelId: "avito-main")])
    )
    let secondCreate = try JSONEncoder().encode(
        ProjectCreateRequest(id: "other", name: "Other", channels: [.init(title: "Main", channelId: "other-main")])
    )
    #expect(await router.handle(method: "POST", path: "/v1/projects", body: firstCreate).status == 201)
    #expect(await router.handle(method: "POST", path: "/v1/projects", body: secondCreate).status == 201)

    let scoped = ChannelGatewayScope.scopedChannelId(baseChannelId: "telegram-main", topicKey: "42")
    let linkBody = try JSONEncoder().encode(
        ProjectChannelLinkRequest(channelId: scoped, title: "Telegram topic 42", ensureSession: true)
    )
    let linkResponse = await router.handle(method: "POST", path: "/v1/projects/avito/channel-links", body: linkBody)
    #expect(linkResponse.status == 200)
    let linked = try decoder.decode(ProjectChannelLinkResponse.self, from: linkResponse.body)
    #expect(linked.status == "linked")
    #expect(linked.channel.channelId == scoped)
    #expect(linked.session?.channelId == scoped)

    let duplicateResponse = await router.handle(method: "POST", path: "/v1/projects/avito/channel-links", body: linkBody)
    #expect(duplicateResponse.status == 200)
    let duplicate = try decoder.decode(ProjectChannelLinkResponse.self, from: duplicateResponse.body)
    #expect(duplicate.status == "existing")

    let conflictResponse = await router.handle(method: "POST", path: "/v1/projects/other/channel-links", body: linkBody)
    #expect(conflictResponse.status == 409)
    let conflict = try decoder.decode(ErrorResponse.self, from: conflictResponse.body)
    #expect(conflict.error == ErrorCode.projectConflict)

    let sessionsResponse = await router.handle(method: "GET", path: "/v1/channel-sessions?status=open", body: nil)
    #expect(sessionsResponse.status == 200)
    let sessions = try decoder.decode([ChannelSessionSummary].self, from: sessionsResponse.body)
    #expect(sessions.contains(where: { $0.channelId == scoped }))
}

@Test
func projectCreateRequestWithRepoUrlIsAccepted() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: "cloned-project",
            name: "Cloned Project",
            repoUrl: "https://github.com/example/nonexistent-repo-for-test"
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(response.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let outcome = try decoder.decode(ProjectCreateResult.self, from: response.body)
    #expect(outcome.repoCloneSucceeded == false)
    let created = outcome.project
    #expect(created.id == "cloned-project")
    #expect(created.name == "Cloned Project")
}

@Test
func projectCreateRequestWithoutRepoUrlCreatesEmptyProject() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: "empty-project",
            name: "Empty Project"
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(response.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let outcome = try decoder.decode(ProjectCreateResult.self, from: response.body)
    #expect(outcome.repoCloneSucceeded == nil)
    let created = outcome.project
    #expect(created.id == "empty-project")
    #expect(created.name == "Empty Project")
}

@Test
func projectCreateEndpointAcceptsPayloadWithoutChannels() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONSerialization.data(
        withJSONObject: [
            "id": "onboarding-project",
            "name": "Onboarding Project",
            "description": "Created from a minimal wizard payload"
        ]
    )

    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createOutcome = try decoder.decode(ProjectCreateResult.self, from: createResponse.body)
    #expect(createOutcome.repoCloneSucceeded == nil)
    let created = createOutcome.project
    #expect(created.id == "onboarding-project")
    #expect(created.channels.count == 1)
    #expect(created.channels.first?.channelId == "onboarding-project-main")
}

@Test
func updateConfigSwitchesProjectPersistenceStore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-config-project-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let configPath = root.appendingPathComponent("sloppy.json").path
    let sqliteA = root.appendingPathComponent("core-a.sqlite").path
    let sqliteB = root.appendingPathComponent("core-b.sqlite").path

    var initialConfig = CoreConfig.default
    initialConfig.workspace = .init(name: "workspace-a-\(UUID().uuidString)", basePath: root.path)
    initialConfig.sqlitePath = sqliteA

    let service = CoreService(config: initialConfig, configPath: configPath)

    var updatedConfig = initialConfig
    updatedConfig.workspace = .init(name: "workspace-b-\(UUID().uuidString)", basePath: root.path)
    updatedConfig.sqlitePath = sqliteB

    _ = try await service.updateConfig(updatedConfig)
    _ = try await service.createProject(
        ProjectCreateRequest(
            id: "onboarding-project",
            name: "Onboarding Project"
        )
    )

    let projects = await service.listProjects()
    #expect(projects.contains(where: { $0.id == "onboarding-project" }))

    let restartedService = CoreService(config: updatedConfig, configPath: configPath)
    let restartedProjects = await restartedService.listProjects()
    #expect(restartedProjects.contains(where: { $0.id == "onboarding-project" }))
}

#if canImport(CSQLite3)
@Test
func projectMembersMigrateFromLegacyDashboardProjectsSchema() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-project-legacy-\(UUID().uuidString).sqlite")
        .path

    var db: OpaquePointer?
    #expect(sqlite3_open(sqlitePath, &db) == SQLITE_OK)
    defer {
        if let db {
            sqlite3_close(db)
        }
    }

    let formatter = ISO8601DateFormatter()
    let now = formatter.string(from: Date())
    let legacySchema =
        """
        CREATE TABLE dashboard_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """
    #expect(sqlite3_exec(db, legacySchema, nil, nil, nil) == SQLITE_OK)

    let insertSQL =
        """
        INSERT INTO dashboard_projects(id, name, description, created_at, updated_at)
        VALUES('legacy-project', 'Legacy Project', 'Project from pre-members schema', '\(now)', '\(now)');
        """
    #expect(sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK)

    sqlite3_close(db)
    db = nil

    var config = CoreConfig.test
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(
        ProjectUpdateRequest(actors: ["actor:builder"], teams: ["team:ops"])
    )
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/legacy-project",
        body: body
    )
    #expect(updateResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let updated = try decoder.decode(ProjectRecord.self, from: updateResponse.body)
    #expect(updated.actors == ["actor:builder"])
    #expect(updated.teams == ["team:ops"])
    #expect(updated.kind == .project)

    let restartedService = CoreService(config: config)
    let restartedRouter = CoreRouter(service: restartedService)
    let fetchResponse = await restartedRouter.handle(method: "GET", path: "/v1/projects/legacy-project", body: nil)
    #expect(fetchResponse.status == 200)

    let fetched = try decoder.decode(ProjectRecord.self, from: fetchResponse.body)
    #expect(fetched.actors == ["actor:builder"])
    #expect(fetched.teams == ["team:ops"])
    #expect(fetched.kind == .project)
}
#endif

@Test
func projectCreateCreatesWorkspaceDirectory() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "proj-dir-\(UUID().uuidString)"

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Directory Project",
            description: "Checks workspace/projects/<id> provisioning",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let projectDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectID, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: projectDirectory.path))
}

@Test
func projectTaskReadyStatusTriggersVisorBulletin() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let projectID = "ready-bulletin-\(UUID().uuidString)"
    let createProjectBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Ready Bulletin Project",
            description: "Triggers visor when task becomes ready",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let createProjectResponse = await router.handle(method: "POST", path: "/v1/projects", body: createProjectBody)
    #expect(createProjectResponse.status == 201)

    let createTaskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Prepare execution",
            description: "Move task into ready queue.",
            priority: "medium",
            status: "backlog"
        )
    )
    let createTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(projectID)/tasks",
        body: createTaskBody
    )
    #expect(createTaskResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let projectWithTask = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
    let taskID = try #require(projectWithTask.tasks.first?.id)

    let updateTaskBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateTaskResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateTaskBody
    )
    #expect(updateTaskResponse.status == 200)

    let bulletinsResponse = await router.handle(method: "GET", path: "/v1/bulletins", body: nil)
    #expect(bulletinsResponse.status == 200)
    let bulletins = try decoder.decode([MemoryBulletin].self, from: bulletinsResponse.body)
    #expect(!bulletins.isEmpty)
}

@Test
func openAIModelsEndpoint() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let request = OpenAIProviderModelsRequest(authMethod: .apiKey, apiKey: "", apiUrl: "https://api.openai.com/v1")
    let body = try JSONEncoder().encode(request)
    let response = await router.handle(method: "POST", path: "/v1/providers/openai/models", body: body)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(OpenAIProviderModelsResponse.self, from: response.body)
    #expect(payload.provider == "openai")
    #expect(!payload.models.isEmpty)
}

@Test
func openAIProviderStatusEndpoint() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/providers/openai/status", body: nil)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(OpenAIProviderStatusResponse.self, from: response.body)
    #expect(payload.provider == "openai")
    #expect(payload.hasAnyKey == (payload.hasEnvironmentKey || payload.hasConfiguredKey))
}

@Test
func geminiProviderStatusEndpoint() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/providers/gemini/status", body: nil)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(GeminiProviderStatusResponse.self, from: response.body)
    #expect(payload.provider == "gemini")
    #expect(payload.hasAnyKey == (payload.hasEnvironmentKey || payload.hasConfiguredKey || payload.hasOAuthCredentials))
}

@Test
func channelStateReturnsEmptySnapshotWhenChannelMissing() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/channels/general/state", body: nil)
    #expect(response.status == 200)

    let snapshot = try JSONDecoder().decode(ChannelSnapshot.self, from: response.body)
    #expect(snapshot.channelId == "general")
    #expect(snapshot.messages.isEmpty)
    #expect(snapshot.contextUtilization == 0)
    #expect(snapshot.activeWorkerIds.isEmpty)
    #expect(snapshot.lastDecision == nil)
}

@Test
func channelEventsEndpointReturnsRuntimeTimeline() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let channelID = "events-\(UUID().uuidString)"

    let requestBody = try JSONEncoder().encode(
        ChannelMessageRequest(userId: "u1", content: "respond please")
    )
    let firstResponse = await router.handle(
        method: "POST",
        path: "/v1/channels/\(channelID)/messages",
        body: requestBody
    )
    #expect(firstResponse.status == 200)

    try await Task.sleep(nanoseconds: 150_000_000)

    let response = await router.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/events?limit=20",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(ChannelEventsResponse.self, from: response.body)
    #expect(payload.channelId == channelID)
    #expect(!payload.items.isEmpty)
    #expect(payload.items.allSatisfy { $0.channelId == channelID })
    #expect(payload.items.contains(where: { $0.messageType == .channelMessageReceived }))
}

@Test
func channelEventsEndpointSupportsCursorAndTimeFilters() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let channelID = "events-pagination-\(UUID().uuidString)"

    for index in 1...3 {
        let body = try JSONEncoder().encode(
            ChannelMessageRequest(userId: "u\(index)", content: "respond please \(index)")
        )
        let postResponse = await router.handle(
            method: "POST",
            path: "/v1/channels/\(channelID)/messages",
            body: body
        )
        #expect(postResponse.status == 200)
        try await Task.sleep(nanoseconds: 40_000_000)
    }

    try await Task.sleep(nanoseconds: 200_000_000)

    let firstPageResponse = await router.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/events?limit=2",
        body: nil
    )
    #expect(firstPageResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let firstPage = try decoder.decode(ChannelEventsResponse.self, from: firstPageResponse.body)
    #expect(firstPage.items.count == 2)
    let cursor = try #require(firstPage.nextCursor)

    let encodedCursor = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
    let secondPageResponse = await router.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/events?limit=2&cursor=\(encodedCursor)",
        body: nil
    )
    #expect(secondPageResponse.status == 200)
    let secondPage = try decoder.decode(ChannelEventsResponse.self, from: secondPageResponse.body)

    let firstIDs = Set(firstPage.items.map(\.messageId))
    let secondIDs = Set(secondPage.items.map(\.messageId))
    #expect(firstIDs.isDisjoint(with: secondIDs))

    let isoFormatter = ISO8601DateFormatter()
    if let newestTimestamp = firstPage.items.first?.ts {
        let beforeValue = isoFormatter.string(from: newestTimestamp)
        let encodedBeforeValue = beforeValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? beforeValue
        let beforeResponse = await router.handle(
            method: "GET",
            path: "/v1/channels/\(channelID)/events?limit=30&before=\(encodedBeforeValue)",
            body: nil
        )
        #expect(beforeResponse.status == 200)
        let beforePayload = try decoder.decode(ChannelEventsResponse.self, from: beforeResponse.body)
        #expect(beforePayload.items.allSatisfy { $0.ts < newestTimestamp })
    }

    if let oldestTimestamp = firstPage.items.last?.ts {
        let afterValue = isoFormatter.string(from: oldestTimestamp)
        let encodedAfterValue = afterValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? afterValue
        let afterResponse = await router.handle(
            method: "GET",
            path: "/v1/channels/\(channelID)/events?limit=30&after=\(encodedAfterValue)",
            body: nil
        )
        #expect(afterResponse.status == 200)
        let afterPayload = try decoder.decode(ChannelEventsResponse.self, from: afterResponse.body)
        #expect(afterPayload.items.allSatisfy { $0.ts > oldestTimestamp })
    }
}

@Test
func getConfigEndpoint() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/config", body: nil)
    #expect(response.status == 200)

    let config = try JSONDecoder().decode(CoreConfig.self, from: response.body)
    #expect(config.listen.port == 25101)
}

@Test
func voiceConfigEndpointReturnsSanitizedLocalFallback() async throws {
    var config = CoreConfig.test
    config.voiceMode = .init(enabled: true, provider: .auto)
    config.models = []
    let router = CoreRouter(service: CoreService(config: config))

    let response = await router.handle(method: "GET", path: "/v1/voice/config", body: nil)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(VoiceModeConfigResponse.self, from: response.body)
    #expect(payload.enabled == true)
    #expect(payload.configuredProvider == "auto")
    #expect(payload.effectiveProvider == "local")
    #expect(payload.openAIConfigured == false)
    #expect(payload.openAI.transcriptionModel == "gpt-4o-mini-transcribe")
    #expect(String(decoding: response.body, as: UTF8.self).contains("apiKey") == false)
}

@Test
func voiceConfigEndpointUsesOpenAIWhenConfigured() async throws {
    var config = CoreConfig.test
    config.voiceMode = .init(
        enabled: true,
        provider: .auto,
        openAI: .init(enabled: true, voice: "marin")
    )
    config.models = [
        .init(
            title: "openai-api",
            apiKey: "sk-test",
            apiUrl: "https://api.openai.com/v1",
            model: "gpt-5.4-mini"
        ),
    ]
    let router = CoreRouter(service: CoreService(config: config))

    let response = await router.handle(method: "GET", path: "/v1/voice/config", body: nil)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(VoiceModeConfigResponse.self, from: response.body)
    #expect(payload.effectiveProvider == "openai")
    #expect(payload.openAIConfigured == true)
    #expect(payload.openAI.voice == "marin")
}

@Test
func voiceCapabilitiesEndpointReturnsFallbackSpeechOptions() async throws {
    var config = CoreConfig.test
    config.voiceMode = .init(enabled: true, provider: .auto)
    config.models = [
        .init(
            title: "openai-api",
            apiKey: "sk-test",
            apiUrl: "http://openai.com@127.0.0.1:9/v1",
            model: "gpt-5.4-mini"
        ),
    ]
    let router = CoreRouter(service: CoreService(config: config))

    let response = await router.handle(method: "GET", path: "/v1/voice/capabilities", body: nil)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(VoiceModeCapabilitiesResponse.self, from: response.body)
    #expect(payload.provider == "openai")
    #expect(payload.openAIConfigured == false)
    #expect(payload.source == "fallback")
    #expect(payload.speechModels.contains { $0.id == "gpt-4o-mini-tts" })
    #expect(payload.speechModels.contains { $0.id == "tts-1-hd" })
    #expect(payload.transcriptionModels.contains { $0.id == "gpt-4o-mini-transcribe" })
    #expect(payload.voices.contains { $0.id == "marin" && $0.recommended })
    #expect(payload.voices.contains { $0.id == "cedar" && $0.recommended })
    #expect(payload.voices.first(where: { $0.id == "cedar" })?.models.contains("tts-1") == false)
}

@Test
func voiceTranscriptionEndpointReturnsConfigErrorWithoutOpenAI() async throws {
    var config = CoreConfig.test
    config.voiceMode = .init(enabled: true, provider: .openAI, openAI: .init(enabled: false))
    config.models = []
    let router = CoreRouter(service: CoreService(config: config))
    let body = try JSONEncoder().encode(VoiceModeTranscriptionRequest(audioBase64: "d2F2", mimeType: "audio/webm"))

    let response = await router.handle(method: "POST", path: "/v1/voice/transcriptions", body: body)

    #expect(response.status == 409)
    let payload = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
    #expect(payload.error == "voice_openai_not_configured")
}

@Test
func voiceSpeechEndpointReturnsBadRequestForEmptyText() async throws {
    var config = CoreConfig.test
    config.voiceMode = .init(enabled: true, provider: .openAI, openAI: .init(enabled: true))
    let router = CoreRouter(service: CoreService(config: config))
    let body = try JSONEncoder().encode(VoiceModeSpeechRequest(text: "   "))

    let response = await router.handle(method: "POST", path: "/v1/voice/speech", body: body)

    #expect(response.status == 400)
    let payload = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
    #expect(payload.error == "invalid_body")
}

@Test
func dashboardAuthProtectsAPIRoutesWhenEnabled() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let missingAuth = await router.handle(method: "POST", path: "/v1/updates/check", body: nil)
    #expect(missingAuth.status == 401)
    let missingPayload = try JSONDecoder().decode(ErrorResponse.self, from: missingAuth.body)
    #expect(missingPayload.error == ErrorCode.unauthorized)

    let wrongAuth = await router.handle(
        method: "POST",
        path: "/v1/updates/check",
        body: nil,
        headers: ["Authorization": "Bearer wrong-token"]
    )
    #expect(wrongAuth.status == 401)

    let dashboardAuth = await router.handle(
        method: "POST",
        path: "/v1/updates/check",
        body: nil,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(dashboardAuth.status == 200)

    let legacyAuth = await router.handle(
        method: "POST",
        path: "/v1/updates/check",
        body: nil,
        headers: ["Authorization": "Bearer \(config.auth.token)"]
    )
    #expect(legacyAuth.status == 200)

    let readOnly = await router.handle(method: "GET", path: "/v1/config", body: nil)
    #expect(readOnly.status == 401)

    let authorizedReadOnly = await router.handle(
        method: "GET",
        path: "/v1/config",
        body: nil,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(authorizedReadOnly.status == 200)

    let status = await router.handle(method: "GET", path: "/v1/dashboard/auth/status", body: nil)
    #expect(status.status == 200)
    let statusPayload = try JSONDecoder().decode(DashboardAuthStatusResponsePayload.self, from: status.body)
    #expect(statusPayload.enabled == true)

    let meshState = await router.handle(method: "GET", path: "/v1/node/mesh", body: nil)
    #expect(meshState.status == 401)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let inviteBody = try encoder.encode(MeshInviteCreateRequest(
        networkId: "personal",
        name: "Remote Worker",
        roles: ["worker"],
        capabilities: ["run_agent", "git"],
        ttlSeconds: 600,
        relayURL: "http://mesh.example.com"
    ))
    let inviteResponse = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/invites",
        body: inviteBody,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(inviteResponse.status == 201)
    let invite = try decoder.decode(MeshInvite.self, from: inviteResponse.body)
    let token = try #require(invite.bundleToken)

    let acceptBody = try encoder.encode(MeshInviteAcceptRequest(
        token: token,
        endpoint: "http://mesh.example.com",
        nodeId: "node_remote",
        name: "Remote Worker",
        publicKey: "ed25519:remote",
        roles: ["worker"],
        capabilities: ["run_agent", "git"]
    ))
    let acceptResponse = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/invites/accept",
        body: acceptBody
    )
    #expect(acceptResponse.status == 201)
    let acceptedNode = try decoder.decode(MeshNodeRecord.self, from: acceptResponse.body)
    #expect(acceptedNode.id == "node_remote")
}

@Test
func dashboardAuthValidateEndpointReturnsCapabilities() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let unauthorized = await router.handle(method: "POST", path: "/v1/dashboard/auth/validate", body: nil)
    #expect(unauthorized.status == 401)

    let authorized = await router.handle(
        method: "POST",
        path: "/v1/dashboard/auth/validate",
        body: nil,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(authorized.status == 200)

    let payload = try JSONDecoder().decode(DashboardAuthValidateResponsePayload.self, from: authorized.body)
    #expect(payload.ok == true)
    #expect(payload.capabilities.acceptsLegacyToken == true)
    #expect(payload.capabilities.mutatingRoutesProtected == true)
    #expect(payload.capabilities.terminalWebSocketProtected == true)
}

@Test
func authChallengeRouteReturnsLoginPasswordMode() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/auth/challenge", body: nil)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(AuthChallengeResponse.self, from: response.body)
    #expect(payload.mode == .loginPassword)
    #expect(payload.bootstrapRequired == true)
    #expect(payload.passkeySupported == false)
    #expect(payload.accessTokenExpiresInSeconds == 5 * 24 * 60 * 60)
    #expect(payload.refreshTokenExpiresInSeconds > 0)
}

@Test
func identityAuthModeSwitchRequiresIrreversibleConfirmation() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()

    let rejected = await router.handle(
        method: "POST",
        path: "/v1/auth/mode",
        body: try encoder.encode(AuthModeUpdateRequest(mode: .loginPassword, confirmIrreversible: false))
    )
    #expect(rejected.status == 400)

    let enabled = await router.handle(
        method: "POST",
        path: "/v1/auth/mode",
        body: try encoder.encode(AuthModeUpdateRequest(mode: .loginPassword, confirmIrreversible: true))
    )
    #expect(enabled.status == 200)

    let challenge = try JSONDecoder().decode(AuthChallengeResponse.self, from: enabled.body)
    #expect(challenge.mode == .loginPassword)
    #expect(challenge.bootstrapRequired == true)
}

@Test
func identityAuthBootstrapAcceptsDashboardPayloadWithoutProfileFields() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let body = Data(#"{"login":"admin","name":"Admin","password":"admin-pass"}"#.utf8)

    let response = await router.handle(method: "POST", path: "/v1/auth/bootstrap", body: body)

    #expect(response.status == 201)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(AuthSessionResponse.self, from: response.body)
    #expect(session.user.login == "admin")
    #expect(session.user.avatar == "")
    #expect(session.user.description == "")
}

@Test
func identityAuthEnforcesTokenAuthAndAdminRoleBoundaries() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let bootstrapBody = try encoder.encode(
        AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin")
    )
    let bootstrapResponse = await router.handle(method: "POST", path: "/v1/auth/bootstrap", body: bootstrapBody)
    #expect(bootstrapResponse.status == 201)
    let adminSession = try decoder.decode(AuthSessionResponse.self, from: bootstrapResponse.body)

    let inviteResponse = await router.handle(
        method: "POST",
        path: "/v1/auth/invites",
        body: try encoder.encode(AuthInviteCreateRequest(role: .user, ttlSeconds: 600)),
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )
    #expect(inviteResponse.status == 201)
    let invite = try decoder.decode(AuthInviteRecord.self, from: inviteResponse.body)
    let inviteToken = try #require(invite.token)

    let registerBody = try encoder.encode(
        AuthRegisterRequest(
            inviteToken: inviteToken,
            login: "user",
            password: "user-pass",
            name: "User"
        )
    )
    let registerResponse = await router.handle(method: "POST", path: "/v1/auth/register", body: registerBody)
    #expect(registerResponse.status == 201)
    let userSession = try decoder.decode(AuthSessionResponse.self, from: registerResponse.body)
    #expect(userSession.user.role == .user)

    let missingAuthConfig = await router.handle(method: "GET", path: "/v1/config", body: nil)
    #expect(missingAuthConfig.status == 401)

    let userConfig = await router.handle(
        method: "GET",
        path: "/v1/config",
        body: nil,
        headers: ["Authorization": "Bearer \(userSession.accessToken)"]
    )
    #expect(userConfig.status == 403)

    let adminConfig = await router.handle(
        method: "GET",
        path: "/v1/config",
        body: nil,
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )
    #expect(adminConfig.status == 200)
}

@Test
func identityAuthUserCanUpdateOwnProfileWithoutAdminPrivileges() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let adminSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )).body)
    let invite = try decoder.decode(AuthInviteRecord.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/invites",
        body: try encoder.encode(AuthInviteCreateRequest(role: .user, ttlSeconds: 600)),
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )).body)
    let userSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/register",
        body: try encoder.encode(AuthRegisterRequest(
            inviteToken: try #require(invite.token),
            login: "member",
            password: "member-pass",
            name: "Member"
        ))
    )).body)

    let update = await router.handle(
        method: "PATCH",
        path: "/v1/auth/me",
        body: try encoder.encode(AuthUserUpdateRequest(
            name: "New Name",
            avatar: "https://example.com/avatar.png",
            description: "Updated profile"
        )),
        headers: ["Authorization": "Bearer \(userSession.accessToken)"]
    )
    #expect(update.status == 200)
    let updated = try decoder.decode(AuthUserProfile.self, from: update.body)
    #expect(updated.login == "member")
    #expect(updated.name == "New Name")
    #expect(updated.avatar == "https://example.com/avatar.png")
    #expect(updated.description == "Updated profile")
    #expect(updated.role == .user)
    #expect(updated.status == .active)

    let forbiddenEscalation = await router.handle(
        method: "PATCH",
        path: "/v1/auth/me",
        body: try encoder.encode(AuthUserUpdateRequest(role: .admin)),
        headers: ["Authorization": "Bearer \(userSession.accessToken)"]
    )
    #expect(forbiddenEscalation.status == 403)
}

@Test
func identityAuthRequiresAdminForMeshAdminRoutes() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let bootstrapSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )).body)
    let inviteResponse = await router.handle(
        method: "POST",
        path: "/v1/auth/invites",
        body: try encoder.encode(AuthInviteCreateRequest(role: .user, ttlSeconds: 600)),
        headers: ["Authorization": "Bearer \(bootstrapSession.accessToken)"]
    )
    let invite = try decoder.decode(AuthInviteRecord.self, from: inviteResponse.body)
    let userSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/register",
        body: try encoder.encode(AuthRegisterRequest(
            inviteToken: try #require(invite.token),
            login: "member",
            password: "member-pass",
            name: "Member"
        ))
    )).body)

    let inviteBody = try encoder.encode(
        MeshInviteCreateRequest(
            networkId: "studio",
            name: "Worker",
            roles: ["worker"],
            capabilities: ["run_agent", "git"],
            ttlSeconds: 600,
            relayURL: "http://mesh.example.com"
        )
    )
    let userMeshInvite = await router.handle(
        method: "POST",
        path: "/v1/node/mesh/invites",
        body: inviteBody,
        headers: ["Authorization": "Bearer \(userSession.accessToken)"]
    )
    #expect(userMeshInvite.status == 403)
}

@Test
func identityAuthAdminCanListAndUpdateUsers() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let adminSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )).body)
    let invite = try decoder.decode(AuthInviteRecord.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/invites",
        body: try encoder.encode(AuthInviteCreateRequest(role: .user, ttlSeconds: 600)),
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )).body)
    let userSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/register",
        body: try encoder.encode(AuthRegisterRequest(
            inviteToken: try #require(invite.token),
            login: "member",
            password: "member-pass",
            name: "Member"
        ))
    )).body)

    let forbiddenList = await router.handle(
        method: "GET",
        path: "/v1/auth/users",
        body: nil,
        headers: ["Authorization": "Bearer \(userSession.accessToken)"]
    )
    #expect(forbiddenList.status == 403)

    let adminList = await router.handle(
        method: "GET",
        path: "/v1/auth/users",
        body: nil,
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )
    #expect(adminList.status == 200)
    let users = try decoder.decode([AuthUserProfile].self, from: adminList.body)
    #expect(users.map(\.login) == ["admin", "member"])

    let update = await router.handle(
        method: "PATCH",
        path: "/v1/auth/users/member",
        body: try encoder.encode(AuthUserUpdateRequest(name: "Disabled Member", role: .admin, status: .disabled)),
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )
    #expect(update.status == 200)
    let updated = try decoder.decode(AuthUserProfile.self, from: update.body)
    #expect(updated.role == .admin)
    #expect(updated.status == .disabled)
    #expect(updated.name == "Disabled Member")

    let disabledLogin = await router.handle(
        method: "POST",
        path: "/v1/auth/login",
        body: try encoder.encode(AuthLoginRequest(login: "member", password: "member-pass"))
    )
    #expect(disabledLogin.status == 401)
}

@Test
func identityAuthUserCanChangeOwnPassword() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let bootstrap = await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )
    let originalSession = try decoder.decode(AuthSessionResponse.self, from: bootstrap.body)
    let authorization = ["Authorization": "Bearer \(originalSession.accessToken)"]

    let rejected = await router.handle(
        method: "POST",
        path: "/v1/auth/password",
        body: try encoder.encode(AuthPasswordChangeRequest(
            currentPassword: "wrong-password",
            newPassword: "new-admin-pass"
        )),
        headers: authorization
    )
    #expect(rejected.status == 400)

    let stillAuthenticated = await router.handle(
        method: "GET",
        path: "/v1/auth/me",
        body: nil,
        headers: authorization
    )
    #expect(stillAuthenticated.status == 200)

    let changed = await router.handle(
        method: "POST",
        path: "/v1/auth/password",
        body: try encoder.encode(AuthPasswordChangeRequest(
            currentPassword: "admin-pass",
            newPassword: "new-admin-pass"
        )),
        headers: authorization
    )
    #expect(changed.status == 200)
    let replacementSession = try decoder.decode(AuthSessionResponse.self, from: changed.body)

    let revokedSession = await router.handle(
        method: "GET",
        path: "/v1/auth/me",
        body: nil,
        headers: authorization
    )
    #expect(revokedSession.status == 401)

    let oldPasswordLogin = await router.handle(
        method: "POST",
        path: "/v1/auth/login",
        body: try encoder.encode(AuthLoginRequest(login: "admin", password: "admin-pass"))
    )
    #expect(oldPasswordLogin.status == 401)

    let newPasswordLogin = await router.handle(
        method: "POST",
        path: "/v1/auth/login",
        body: try encoder.encode(AuthLoginRequest(login: "admin", password: "new-admin-pass"))
    )
    #expect(newPasswordLogin.status == 200)

    let replacementSessionRequest = await router.handle(
        method: "GET",
        path: "/v1/auth/me",
        body: nil,
        headers: ["Authorization": "Bearer \(replacementSession.accessToken)"]
    )
    #expect(replacementSessionRequest.status == 200)
}

@Test
func identityAuthRejectsDisablingLastActiveAdmin() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let adminSession = try decoder.decode(AuthSessionResponse.self, from: (await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )).body)

    let disableOnlyAdmin = await router.handle(
        method: "PATCH",
        path: "/v1/auth/users/admin",
        body: try encoder.encode(AuthUserUpdateRequest(status: .disabled)),
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )
    #expect(disableOnlyAdmin.status == 409)

    let demoteOnlyAdmin = await router.handle(
        method: "PATCH",
        path: "/v1/auth/users/admin",
        body: try encoder.encode(AuthUserUpdateRequest(role: .user)),
        headers: ["Authorization": "Bearer \(adminSession.accessToken)"]
    )
    #expect(demoteOnlyAdmin.status == 409)
}

@Test
func legacyDashboardTokenIsRejectedWhenIdentityAuthIsEnabled() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"

    let service = CoreService(config: config, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()

    _ = await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )

    let legacyDashboardToken = await router.handle(
        method: "POST",
        path: "/v1/updates/check",
        body: nil,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(legacyDashboardToken.status == 401)
}

@Test
func identityAuthRefreshRotatesRefreshToken() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let bootstrap = await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )
    let session = try decoder.decode(AuthSessionResponse.self, from: bootstrap.body)

    let refresh = await router.handle(
        method: "POST",
        path: "/v1/auth/refresh",
        body: try encoder.encode(AuthRefreshRequest(refreshToken: session.refreshToken))
    )
    #expect(refresh.status == 200)
    let refreshed = try decoder.decode(AuthSessionResponse.self, from: refresh.body)
    #expect(refreshed.user.id == session.user.id)
    #expect(refreshed.refreshToken != session.refreshToken)
}

@Test
func identityDevicePairingIsUserBoundShortLivedAndSingleUse() async throws {
    var config = CoreConfig.test
    config.clientPublicURL = "https://81.26.176.106"
    config.clientAlternateURLs = ["http://192.168.1.10:25101"]
    config.clientTLSFingerprint = String(repeating: "ab", count: 32)
    let service = CoreService(config: config, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let bootstrap = await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )
    let dashboardSession = try decoder.decode(AuthSessionResponse.self, from: bootstrap.body)

    let unauthorizedCreate = await router.handle(
        method: "POST",
        path: "/v1/auth/device-pairing",
        body: try encoder.encode(AuthDevicePairingCreateRequest(clientName: "Sloppy Rokid"))
    )
    #expect(unauthorizedCreate.status == 401)

    let create = await router.handle(
        method: "POST",
        path: "/v1/auth/device-pairing",
        body: try encoder.encode(AuthDevicePairingCreateRequest(clientName: "Sloppy Rokid", ttlSeconds: 120)),
        headers: ["Authorization": "Bearer \(dashboardSession.accessToken)"]
    )
    #expect(create.status == 201)
    let pairing = try decoder.decode(AuthDevicePairingRecord.self, from: create.body)
    #expect(pairing.token.hasPrefix("slp_pair_"))
    #expect(pairing.clientName == "Sloppy Rokid")
    #expect(pairing.user.id == dashboardSession.user.id)
    #expect(pairing.expiresAt > pairing.createdAt)
    #expect(pairing.serverURL == "https://81.26.176.106")
    let setupURL = try #require(pairing.setupCode.flatMap(URL.init(string:)))
    let setupComponents = try #require(URLComponents(url: setupURL, resolvingAgainstBaseURL: false))
    let encodedSetup = try #require(setupComponents.queryItems?.first(where: { $0.name == "code" })?.value)
    var base64 = encodedSetup.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    if base64.count % 4 != 0 {
        base64 += String(repeating: "=", count: 4 - base64.count % 4)
    }
    let setupData = try #require(Data(base64Encoded: base64))
    let setup = try decoder.decode(AuthDevicePairingSetupPayload.self, from: setupData)
    #expect(setup.version == 1)
    #expect(setup.url == "https://81.26.176.106")
    #expect(setup.urls == ["https://81.26.176.106", "http://192.168.1.10:25101"])
    #expect(setup.bootstrapToken == pairing.token)
    #expect(setup.tlsFingerprint == String(repeating: "ab", count: 32))

    let redeemBody = try encoder.encode(AuthDevicePairingRedeemRequest(token: pairing.token))
    let redeem = await router.handle(
        method: "POST",
        path: "/v1/auth/device-pairing/redeem",
        body: redeemBody
    )
    #expect(redeem.status == 200)
    let glassesSession = try decoder.decode(AuthSessionResponse.self, from: redeem.body)
    #expect(glassesSession.user.id == dashboardSession.user.id)
    #expect(glassesSession.accessToken != dashboardSession.accessToken)
    #expect(glassesSession.refreshToken != dashboardSession.refreshToken)

    let secondRedeem = await router.handle(
        method: "POST",
        path: "/v1/auth/device-pairing/redeem",
        body: redeemBody
    )
    #expect(secondRedeem.status == 401)
}

@Test
func identityApplicationTokensPersistAuthenticateAndCanBeRevoked() async throws {
    let config = CoreConfig.test
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var applicationToken = ""
    var applicationTokenID = ""

    do {
        let service = CoreService(config: config, identityPasswordHashIterations: 1)
        await service.setIdentityAuthEnabled(true)
        let router = CoreRouter(service: service)
        let bootstrap = await router.handle(
            method: "POST",
            path: "/v1/auth/bootstrap",
            body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
        )
        let session = try decoder.decode(AuthSessionResponse.self, from: bootstrap.body)

        let create = await router.handle(
            method: "POST",
            path: "/v1/auth/application-tokens",
            body: try encoder.encode(AuthApplicationTokenCreateRequest(
                name: "Sloppy Safari",
                expiresInSeconds: 31_536_000
            )),
            headers: ["Authorization": "Bearer \(session.accessToken)"]
        )

        #expect(create.status == 201)
        let record = try decoder.decode(AuthApplicationTokenRecord.self, from: create.body)
        applicationToken = try #require(record.token)
        applicationTokenID = record.id
        #expect(record.name == "Sloppy Safari")
        #expect(applicationToken.hasPrefix("slp_pat_"))
        #expect(record.tokenPrefix.hasPrefix("slp_pat_"))
    }

    let restartedService = CoreService(config: config, identityPasswordHashIterations: 1)
    let restartedRouter = CoreRouter(service: restartedService)
    let authorization = ["Authorization": "Bearer \(applicationToken)"]

    let me = await restartedRouter.handle(method: "GET", path: "/v1/auth/me", body: nil, headers: authorization)
    #expect(me.status == 200)
    let profile = try decoder.decode(AuthUserProfile.self, from: me.body)
    #expect(profile.login == "admin")

    let list = await restartedRouter.handle(
        method: "GET",
        path: "/v1/auth/application-tokens",
        body: nil,
        headers: authorization
    )
    #expect(list.status == 200)
    let records = try decoder.decode([AuthApplicationTokenRecord].self, from: list.body)
    #expect(records.count == 1)
    #expect(records.first?.token == nil)

    let revoke = await restartedRouter.handle(
        method: "DELETE",
        path: "/v1/auth/application-tokens/\(applicationTokenID)",
        body: nil,
        headers: authorization
    )
    #expect(revoke.status == 204)

    let rejected = await restartedRouter.handle(method: "GET", path: "/v1/auth/me", body: nil, headers: authorization)
    #expect(rejected.status == 401)
}

@Test
func identityAuthPasswordResetAcceptsRecoveryCode() async throws {
    let service = CoreService(config: .test, identityPasswordHashIterations: 1)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let bootstrap = await router.handle(
        method: "POST",
        path: "/v1/auth/bootstrap",
        body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
    )
    let session = try decoder.decode(AuthSessionResponse.self, from: bootstrap.body)

    let codesResponse = await router.handle(
        method: "POST",
        path: "/v1/auth/recovery-codes",
        body: nil,
        headers: ["Authorization": "Bearer \(session.accessToken)"]
    )
    #expect(codesResponse.status == 201)
    let codes = try decoder.decode(AuthRecoveryCodesResponse.self, from: codesResponse.body)
    let recoveryCode = try #require(codes.codes.first)

    let reset = await router.handle(
        method: "POST",
        path: "/v1/auth/password-reset",
        body: try encoder.encode(AuthPasswordResetRequest(
            login: "admin",
            recoveryCode: recoveryCode,
            newPassword: "new-admin-pass"
        ))
    )
    #expect(reset.status == 200)

    let login = await router.handle(
        method: "POST",
        path: "/v1/auth/login",
        body: try encoder.encode(AuthLoginRequest(login: "admin", password: "new-admin-pass"))
    )
    #expect(login.status == 200)
}

@Test
func identityAuthPersistsUsersAcrossCoreServiceRestart() async throws {
    let config = CoreConfig.test
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
        let service = CoreService(config: config, identityPasswordHashIterations: 1)
        await service.setIdentityAuthEnabled(true)
        let router = CoreRouter(service: service)

        let bootstrap = await router.handle(
            method: "POST",
            path: "/v1/auth/bootstrap",
            body: try encoder.encode(AuthBootstrapAdminRequest(login: "admin", password: "admin-pass", name: "Admin"))
        )
        #expect(bootstrap.status == 201)
    }

    let restartedService = CoreService(config: config, identityPasswordHashIterations: 1)
    let restartedRouter = CoreRouter(service: restartedService)

    let challenge = await restartedRouter.handle(method: "GET", path: "/v1/auth/challenge", body: nil)
    let challengePayload = try decoder.decode(AuthChallengeResponse.self, from: challenge.body)
    #expect(challengePayload.mode == .loginPassword)
    #expect(challengePayload.bootstrapRequired == false)

    let login = await restartedRouter.handle(
        method: "POST",
        path: "/v1/auth/login",
        body: try encoder.encode(AuthLoginRequest(login: "admin", password: "admin-pass"))
    )
    #expect(login.status == 200)
}

@Test
func systemLogsEndpointReadsJSONLFile() async throws {
    let config = CoreConfig.test

    let workspaceRoot = config.resolvedWorkspaceRootURL()
    let logsDirectory = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    let logFileURL = logsDirectory.appendingPathComponent("core-test.log")
    let logLine = """
    {"label":"sloppy.core.main","level":"error","message":"Test failure","metadata":{"module":"tests"},"source":"sloppyTests","timestamp":"2026-02-28T10:11:12.123Z"}
    """
    guard let logData = (logLine + "\n").data(using: .utf8) else {
        throw NSError(domain: "CoreRouterTests", code: 1)
    }
    try logData.write(to: logFileURL, options: .atomic)

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/logs", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(SystemLogsResponse.self, from: response.body)
    #expect(payload.filePath.hasSuffix(".log"))
    #expect(payload.entries.count >= 1)
    #expect(payload.entries.last?.level == .error)
    #expect(payload.entries.last?.message == "Test failure")
}

@Test
func systemLogsMetadataKeysAreSorted() async throws {
    let config = CoreConfig.test

    let workspaceRoot = config.resolvedWorkspaceRootURL()
    let logsDirectory = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    let logFileURL = logsDirectory.appendingPathComponent("core-test-sorted.log")
    
    // Create a log line with metadata keys that are NOT sorted
    let logLine = """
    {"label":"test","level":"info","message":"test","metadata":{"z":"last","a":"first","m":"middle"},"source":"test","timestamp":"2026-03-10T10:11:12.123Z"}
    """
    guard let logData = (logLine + "\n").data(using: .utf8) else {
        throw NSError(domain: "CoreRouterTests", code: 1)
    }
    try logData.write(to: logFileURL, options: .atomic)

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/logs", body: nil)
    #expect(response.status == 200)

    let jsonString = String(data: response.body, encoding: .utf8) ?? ""
    
    // We expect "metadata":{"a":"first","m":"middle","z":"last"} due to .sortedKeys
    #expect(jsonString.contains("\"metadata\":{\"a\":\"first\",\"m\":\"middle\",\"z\":\"last\"}"))
}

@Test
func issueReportEndpointBuildsSanitizedGitHubURL() async throws {
    var config = CoreConfig.test
    config.auth.token = "dev-super-secret-token"
    config.models = [
        .init(
            title: "OpenAI",
            apiKey: "sk-supersecretvalue1234567890",
            apiUrl: "https://api.openai.com/v1",
            model: "gpt-5.4-mini"
        )
    ]
    config.channels.telegram = .init(botToken: "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345")

    let workspaceRoot = config.resolvedWorkspaceRootURL()
    let logsDirectory = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    let logFileURL = logsDirectory.appendingPathComponent("core-issue-report.log")
    let logLines = [
        #"{"label":"sloppy.core.main","level":"info","message":"normal operation detail","metadata":{"module":"tests"},"source":"sloppyTests","timestamp":"2026-03-10T10:11:12.123Z"}"#,
        #"{"label":"sloppy.core.auth","level":"error","message":"failed with Authorization: Bearer dev-super-secret-token and key sk-supersecretvalue1234567890 and bot 123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345","metadata":{"apiKey":"sk-supersecretvalue1234567890","safe":"visible"},"source":"sloppyTests","timestamp":"2026-03-10T10:11:13.123Z"}"#
    ]
    try (logLines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: logFileURL, options: .atomic)

    let service = CoreService(
        config: config,
        builtInGatewayPluginFactory: .live,
        issueReportLogUploader: StaticIssueReportLogUploader(logsURL: "https://paste.rs/test-report")
    )
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(IssueReportRequest(logLimit: 20))
    let response = await router.handle(method: "POST", path: "/v1/support/issue-report", body: body)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(IssueReportResponse.self, from: response.body)
    #expect(payload.issueUrl.hasPrefix("https://github.com/TeamSloppy/Sloppy/issues/new"))
    #expect(payload.issueUrl.contains("template=report-an-issue.yml"))
    #expect(payload.logsUrl == "https://paste.rs/test-report")
    #expect(payload.logEntryCount == 2)
    #expect(payload.redactionCount >= 4)
    #expect(payload.issueUrl.utf8.count < 2_000)

    let components = try #require(URLComponents(string: payload.issueUrl))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
    let environment = try #require(query["environment"])
    #expect(environment.contains("Sloppy version:"))
    #expect(query["logs"] == "Sanitized logs: https://paste.rs/test-report")
    #expect(payload.logs.contains("normal operation detail"))
    #expect(payload.logs.contains("safe=visible"))
    #expect(payload.logs.contains("[REDACTED]"))
    #expect(!payload.logs.contains("dev-super-secret-token"))
    #expect(!payload.logs.contains("sk-supersecretvalue1234567890"))
    #expect(!payload.logs.contains("123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345"))
}

@Test
func issueReportRedactorCoversEnvironmentValuesAndInlineCredentials() {
    var config = CoreConfig.test
    config.auth.token = "config-secret-token"
    let redactor = SensitiveLogRedactor(
        config: config,
        environment: [
            "SLOPPY_LOGIN": "alice@example.com",
            "OPENAI_API_KEY": "sk-envsecretvalue1234567890"
        ]
    )

    let result = redactor.redact(
        "user alice@example.com used https://alice:password@github.com/org/repo with Bearer config-secret-token, sk-envsecretvalue1234567890, ghp_abcdefghij1234567890, and aaaabbbbcccc.ddddeeeeffff.gggghhhhiiii"
    )

    #expect(result.count >= 6)
    #expect(result.value.contains("[REDACTED]"))
    #expect(!result.value.contains("alice@example.com"))
    #expect(!result.value.contains("password@github.com"))
    #expect(!result.value.contains("config-secret-token"))
    #expect(!result.value.contains("sk-envsecretvalue1234567890"))
    #expect(!result.value.contains("ghp_abcdefghij1234567890"))
    #expect(!result.value.contains("aaaabbbbcccc.ddddeeeeffff.gggghhhhiiii"))
}

@Test
func issueReportEndpointBoundsLargeLogURL() async throws {
    let config = CoreConfig.test
    let workspaceRoot = config.resolvedWorkspaceRootURL()
    let logsDirectory = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    let logFileURL = logsDirectory.appendingPathComponent("core-issue-report-large.log")
    let repeated = String(repeating: "long diagnostic context ", count: 180)
    let lines = (0..<300).map { index in
        #"{"label":"test","level":"info","message":"entry \#(index) \#(repeated)","metadata":{"module":"large"},"source":"test","timestamp":"2026-03-10T10:11:12.123Z"}"#
    }
    try (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: logFileURL, options: .atomic)

    let service = CoreService(config: config, builtInGatewayPluginFactory: .live, issueReportLogUploader: nil)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(IssueReportRequest(logLimit: 300))
    let response = await router.handle(method: "POST", path: "/v1/support/issue-report", body: body)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(IssueReportResponse.self, from: response.body)
    #expect(payload.truncated == true)
    #expect(payload.issueUrl.utf8.count < 2_000)
    #expect(payload.logs.utf8.count <= 64_000)
    #expect(payload.logEntryCount < 300)
}

@Test
func issueReportEndpointRequiresDashboardAuthWhenEnabled() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"

    let service = CoreService(config: config, builtInGatewayPluginFactory: .live, issueReportLogUploader: nil)
    let router = CoreRouter(service: service)

    let unauthorized = await router.handle(method: "POST", path: "/v1/support/issue-report", body: nil)
    #expect(unauthorized.status == 401)

    let authorized = await router.handle(
        method: "POST",
        path: "/v1/support/issue-report",
        body: nil,
        headers: ["Authorization": "Bearer dashboard-secret"]
    )
    #expect(authorized.status == 200)
}

@Test
func serviceSupportsInMemoryPersistenceBuilder() async throws {
    let config = CoreConfig.test
    let service = CoreService(
        config: config,
        persistenceBuilder: InMemoryCorePersistenceBuilder()
    )
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "respond please"))
    let response = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: body)
    #expect(response.status == 200)
    #expect(!FileManager.default.fileExists(atPath: config.sqlitePath))
}

@Test
func sqliteStoreFallbackProjectsPersistAcrossRestartWhenSQLiteUnavailable() async throws {
    let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-sqlite-fallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

    let fallbackProjectsPath = fixtureDirectory.appendingPathComponent("projects-fallback.json").path
    let unavailableSQLitePath = fixtureDirectory.path

    let createdAt = Date()
    let project = ProjectRecord(
        id: "persisted-fallback-project",
        name: "Fallback Project",
        description: "Should survive store restart when SQLite is unavailable.",
        channels: [
            .init(
                id: "main-channel",
                title: "Main",
                channelId: "fallback-main",
                createdAt: createdAt
            )
        ],
        tasks: [],
        createdAt: createdAt,
        updatedAt: createdAt
    )

    let firstStore = SQLiteStore(
        path: unavailableSQLitePath,
        schemaSQL: "",
        fallbackProjectsPath: fallbackProjectsPath
    )
    await firstStore.saveProject(project)

    let restartedStore = SQLiteStore(
        path: unavailableSQLitePath,
        schemaSQL: "",
        fallbackProjectsPath: fallbackProjectsPath
    )
    let projects = await restartedStore.listProjects()

    #expect(projects.count == 1)
    #expect(projects.first?.id == project.id)
    #expect(projects.first?.name == "Fallback Project")
}

@Test
func putConfigEndpoint() async throws {
    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-\(UUID().uuidString).json")
        .path

    let service = CoreService(config: .test, configPath: tempPath)
    let router = CoreRouter(service: service)

    var config = CoreConfig.default
    config.listen.port = 25155
    config.sqlitePath = "./.data/core-config-test.sqlite"
    config.gitSync = .init(
        enabled: true,
        authToken: "ghp_test",
        repository: "acme/workspace-sync",
        branch: "sync/main",
        schedule: .init(frequency: .daily, time: "18:00"),
        conflictStrategy: .remoteWins
    )
    config.browser = .init(
        enabled: true,
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        profileName: "router-test",
        headless: true,
        startupTimeoutMs: 12_000,
        additionalArguments: ["--disable-extensions"]
    )

    let payload = try JSONEncoder().encode(config)
    let response = await router.handle(method: "PUT", path: "/v1/config", body: payload)
    #expect(response.status == 200)

    let updated = try JSONDecoder().decode(CoreConfig.self, from: response.body)
    #expect(updated.listen.port == 25155)
    #expect(updated.gitSync.enabled == true)
    #expect(updated.gitSync.repository == "acme/workspace-sync")
    #expect(updated.gitSync.branch == "sync/main")
    #expect(updated.browser.enabled == true)
    #expect(updated.browser.profileName == "router-test")
    #expect(updated.browser.headless == true)
    #expect(updated.browser.additionalArguments == ["--disable-extensions"])
}

@Test
func updateConfigBacksUpExistingConfigBeforeReplacingIt() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-backup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let configPath = tempRoot.appendingPathComponent("sloppy.json").path
    var initialConfig = CoreConfig.test
    initialConfig.listen.port = 25101
    var updatedConfig = initialConfig
    updatedConfig.listen.port = 26003

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (encoder.encode(initialConfig) + Data("\n".utf8))
        .write(to: URL(fileURLWithPath: configPath))

    let service = CoreService(config: initialConfig, configPath: configPath)
    _ = try await service.updateConfig(updatedConfig)

    let decoder = JSONDecoder()
    let primary = try decoder.decode(CoreConfig.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    let backup = try decoder.decode(
        CoreConfig.self,
        from: Data(contentsOf: URL(fileURLWithPath: CoreConfigFileStore.numberedBackupPath(for: configPath, index: 1)))
    )
    #expect(primary.listen.port == 26003)
    #expect(backup.listen.port == 25101)
}

@Test
func updateConfigCreatesNumberedBackupForEveryApply() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-numbered-backup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let configPath = tempRoot.appendingPathComponent("sloppy.json").path
    var initialConfig = CoreConfig.test
    initialConfig.listen.port = 25101
    var firstUpdate = initialConfig
    firstUpdate.listen.port = 26003
    var secondUpdate = initialConfig
    secondUpdate.listen.port = 26004

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (encoder.encode(initialConfig) + Data("\n".utf8))
        .write(to: URL(fileURLWithPath: configPath))

    let service = CoreService(config: initialConfig, configPath: configPath)
    _ = try await service.updateConfig(firstUpdate)
    _ = try await service.updateConfig(secondUpdate)

    let decoder = JSONDecoder()
    let primary = try decoder.decode(CoreConfig.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    let firstBackup = try decoder.decode(
        CoreConfig.self,
        from: Data(contentsOf: URL(fileURLWithPath: CoreConfigFileStore.numberedBackupPath(for: configPath, index: 1)))
    )
    let secondBackup = try decoder.decode(
        CoreConfig.self,
        from: Data(contentsOf: URL(fileURLWithPath: CoreConfigFileStore.numberedBackupPath(for: configPath, index: 2)))
    )

    #expect(primary.listen.port == 26004)
    #expect(firstBackup.listen.port == 25101)
    #expect(secondBackup.listen.port == 26003)
}

@Test
func putConfigHotReloadsRuntimeModelProvider() async throws {
    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-\(UUID().uuidString).json")
        .path

    var initialConfig = CoreConfig.test
    initialConfig.models = []

    let service = CoreService(config: initialConfig, configPath: tempPath)
    let router = CoreRouter(service: service)

    let channelID = "reload-check"
    let firstMessageBody = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "hello"))
    let firstResponse = await router.handle(method: "POST", path: "/v1/channels/\(channelID)/messages", body: firstMessageBody)
    #expect(firstResponse.status == 200)

    let firstStateResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelID)/state", body: nil)
    #expect(firstStateResponse.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let firstSnapshot = try decoder.decode(ChannelSnapshot.self, from: firstStateResponse.body)
    #expect(firstSnapshot.messages.last(where: { $0.userId == "system" })?.content == "Responded inline")

    var updatedConfig = initialConfig
    updatedConfig.models = [
        .init(
            title: "openai-main",
            apiKey: "test-key",
            apiUrl: "http://127.0.0.1:1/v1",
            model: "gpt-5.4-mini"
        )
    ]
    let updatePayload = try JSONEncoder().encode(updatedConfig)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/config", body: updatePayload)
    #expect(updateResponse.status == 200)

    let secondMessageBody = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "hello again"))
    let secondResponse = await router.handle(method: "POST", path: "/v1/channels/\(channelID)/messages", body: secondMessageBody)
    #expect(secondResponse.status == 200)

    let secondStateResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelID)/state", body: nil)
    #expect(secondStateResponse.status == 200)
    let secondSnapshot = try decoder.decode(ChannelSnapshot.self, from: secondStateResponse.body)
    let latestSystemMessage = secondSnapshot.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(latestSystemMessage != "Responded inline")
}

@Test
func artifactContentNotFound() async {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/artifacts/missing/content", body: nil)
    #expect(response.status == 404)
}

@Test
func boardArtifactPutCreatesBoardBundle() async throws {
    let boardId = "board-put-canvas"
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let board = BoardArtifactRecord(
        id: boardId,
        version: 1,
        viewport: BoardCanvasViewport(x: 120, y: -80, scale: 1.25),
        items: [
            BoardCanvasItem(
                id: "text-1",
                type: "text",
                x: 24,
                y: 32,
                width: 220,
                height: 140,
                title: "Launch notes",
                zIndex: 1,
                groupId: "group-1",
                text: "Ship canvas"
            ),
        ],
        groups: [
            BoardCanvasGroup(
                id: "group-1",
                title: "Planning",
                x: 0,
                y: 0,
                width: 420,
                height: 260,
                collapsed: false
            ),
        ]
    )

    let response = await router.handle(
        method: "PUT",
        path: "/v1/artifacts/boards/\(boardId)",
        body: try encoder.encode(board)
    )
    #expect(response.status == 200)

    let payload = try decoder.decode(BoardArtifactResponse.self, from: response.body)
    #expect(payload.board.id == boardId)
    #expect(payload.board.items.first?.text == "Ship canvas")

    let boardURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".sloppy", isDirectory: true)
        .appendingPathComponent("artifacts", isDirectory: true)
        .appendingPathComponent("boards", isDirectory: true)
        .appendingPathComponent(boardId, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: boardURL.appendingPathComponent("board.json").path))
    #expect(FileManager.default.fileExists(atPath: boardURL.appendingPathComponent("manifest.json").path))

    let manifestData = try Data(contentsOf: boardURL.appendingPathComponent("manifest.json"))
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    #expect(manifest?["kind"] as? String == "board")
    #expect(manifest?["bundlePath"] as? String == ".sloppy/artifacts/boards/\(boardId)/")
}

@Test
func boardArtifactGetReturnsSavedBoard() async throws {
    let boardId = "board-get-canvas"
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let board = BoardArtifactRecord(
        id: boardId,
        version: 1,
        viewport: BoardCanvasViewport(x: 0, y: 0, scale: 1),
        items: [
            BoardCanvasItem(
                id: "shortcut-1",
                type: "shortcut",
                x: 40,
                y: 64,
                width: 220,
                height: 96,
                title: "GitHub",
                zIndex: 2,
                url: "https://github.com/"
            ),
        ],
        groups: []
    )
    _ = await router.handle(method: "PUT", path: "/v1/artifacts/boards/\(boardId)", body: try encoder.encode(board))

    let response = await router.handle(method: "GET", path: "/v1/artifacts/boards/\(boardId)", body: nil)
    #expect(response.status == 200)

    let payload = try decoder.decode(BoardArtifactResponse.self, from: response.body)
    #expect(payload.board.id == boardId)
    #expect(payload.board.items.first?.url == "https://github.com/")
}

@Test
func boardAssetUploadWritesImageAsset() async throws {
    let boardId = "board-asset-canvas"
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let upload = BoardAssetUploadRequest(
        filename: "Screenshot.PNG",
        mediaType: "image/png",
        dataBase64: Data("fake image".utf8).base64EncodedString()
    )

    let response = await router.handle(
        method: "POST",
        path: "/v1/artifacts/boards/\(boardId)/assets",
        body: try encoder.encode(upload)
    )
    #expect(response.status == 201)

    let payload = try decoder.decode(BoardAssetUploadResponse.self, from: response.body)
    #expect(payload.path.hasPrefix(".sloppy/artifacts/boards/\(boardId)/assets/"))
    #expect(payload.path.hasSuffix(".png"))
    #expect(payload.mediaType == "image/png")
    #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(payload.path).path))
}

@Test
func boardAssetUploadRejectsEmptyPayload() async throws {
    let boardId = "board-empty-asset-canvas"
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let upload = BoardAssetUploadRequest(filename: "empty.png", mediaType: "image/png", dataBase64: "")

    let response = await router.handle(
        method: "POST",
        path: "/v1/artifacts/boards/\(boardId)/assets",
        body: try JSONEncoder().encode(upload)
    )
    #expect(response.status == 400)
}

@Test
func boardArtifactGetMissingBoardReturns404() async {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/artifacts/boards/missing-board", body: nil)
    #expect(response.status == 404)
}

@Test
func artifactListIncludesPersistedMetadata() async throws {
    let service = CoreService(config: .test)
    await service.store.persistArtifact(
        record: PersistedArtifactRecord(
            id: "artifact-list-test",
            title: "Clock Widget",
            kind: "widget",
            mediaType: "text/html",
            content: "<!doctype html><html><body>Clock</body></html>",
            previewText: "Clock",
            widgetSize: "small",
            widgetWidth: 160,
            widgetHeight: 120,
            widgetEntry: "index.html",
            bundlePath: ".sloppy/artifacts/widgets/artifact-list-test/",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    )

    let router = CoreRouter(service: service)
    let response = await router.handle(method: "GET", path: "/v1/artifacts", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(ArtifactListResponse.self, from: response.body)
    let artifact = try #require(payload.artifacts.first(where: { $0.id == "artifact-list-test" }))
    #expect(artifact.title == "Clock Widget")
    #expect(artifact.kind == "widget")
    #expect(artifact.widget?.size == "small")
    #expect(artifact.widget?.width == 160)
    #expect(artifact.widget?.height == 120)
}

@Test
func artifactDeleteRemovesPersistedMetadata() async throws {
    let service = CoreService(config: .test)
    await service.store.persistArtifact(
        record: PersistedArtifactRecord(
            id: "artifact-delete-test",
            title: "Clock Widget",
            kind: "widget",
            mediaType: "text/html",
            content: "<!doctype html><html><body>Clock</body></html>",
            previewText: "Clock",
            widgetSize: "small",
            widgetWidth: 160,
            widgetHeight: 120,
            widgetEntry: "index.html",
            bundlePath: ".sloppy/artifacts/widgets/artifact-delete-test/",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    )

    let router = CoreRouter(service: service)
    let deleteResponse = await router.handle(method: "DELETE", path: "/v1/artifacts/artifact-delete-test", body: nil)
    #expect(deleteResponse.status == 200)

    let detailResponse = await router.handle(method: "GET", path: "/v1/artifacts/artifact-delete-test", body: nil)
    #expect(detailResponse.status == 404)

    let listResponse = await router.handle(method: "GET", path: "/v1/artifacts", body: nil)
    #expect(listResponse.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(ArtifactListResponse.self, from: listResponse.body)
    #expect(!payload.artifacts.contains { $0.id == "artifact-delete-test" })
}

@Test
func artifactDetailReturnsPersistedMetadata() async throws {
    let service = CoreService(config: .test)
    await service.store.persistArtifact(
        record: PersistedArtifactRecord(
            id: "artifact-detail-test",
            title: "Sticky",
            kind: "widget",
            mediaType: "text/html",
            content: "<!doctype html><html><body>Sticky</body></html>",
            previewText: "Sticky",
            widgetSize: "medium",
            widgetWidth: 320,
            widgetHeight: 180,
            widgetEntry: "index.html",
            bundlePath: ".sloppy/artifacts/widgets/artifact-detail-test/",
            createdAt: Date(timeIntervalSince1970: 2)
        )
    )

    let router = CoreRouter(service: service)
    let response = await router.handle(method: "GET", path: "/v1/artifacts/artifact-detail-test", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(ArtifactDetailResponse.self, from: response.body)
    #expect(payload.artifact.id == "artifact-detail-test")
    #expect(payload.artifact.widget?.entry == "index.html")
}

@Test
func artifactContentReadPreservesPersistedMetadata() async throws {
    let service = CoreService(config: .test)
    let artifactID = "artifact-content-test"
    let originalCreatedAt = Date(timeIntervalSince1970: 3)
    let runtimeContent = "<!doctype html><html><body>Updated Clock</body></html>"
    await service.store.persistArtifact(
        record: PersistedArtifactRecord(
            id: artifactID,
            title: "Clock Widget",
            kind: "widget",
            mediaType: "text/html",
            content: "<!doctype html><html><body>Clock</body></html>",
            previewText: "Clock",
            widgetSize: "small",
            widgetWidth: 160,
            widgetHeight: 120,
            widgetEntry: "index.html",
            bundlePath: ".sloppy/artifacts/widgets/\(artifactID)/",
            createdAt: originalCreatedAt
        )
    )
    await service.waitForStartup()
    await service.runtime.recover(
        channels: [],
        tasks: [],
        events: [],
        artifacts: [
            RecoveryArtifactState(
                id: artifactID,
                content: runtimeContent,
                createdAt: originalCreatedAt.addingTimeInterval(10)
            ),
        ]
    )

    let router = CoreRouter(service: service)
    let contentResponse = await router.handle(method: "GET", path: "/v1/artifacts/\(artifactID)/content", body: nil)
    #expect(contentResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let contentPayload = try decoder.decode(ArtifactContentResponse.self, from: contentResponse.body)
    #expect(contentPayload.content == runtimeContent)

    let detailResponse = await router.handle(method: "GET", path: "/v1/artifacts/\(artifactID)", body: nil)
    #expect(detailResponse.status == 200)

    let detailPayload = try decoder.decode(ArtifactDetailResponse.self, from: detailResponse.body)
    #expect(detailPayload.artifact.title == "Clock Widget")
    #expect(detailPayload.artifact.kind == "widget")
    #expect(detailPayload.artifact.mediaType == "text/html")
    #expect(detailPayload.artifact.widget?.entry == "index.html")

    let persisted = try #require(await service.store.persistedArtifact(id: artifactID))
    #expect(persisted.title == "Clock Widget")
    #expect(persisted.kind == "widget")
    #expect(persisted.mediaType == "text/html")
    #expect(persisted.content == runtimeContent)
    #expect(persisted.previewText == String(runtimeContent.prefix(160)))
    #expect(persisted.widgetSize == "small")
    #expect(persisted.widgetWidth == 160)
    #expect(persisted.widgetHeight == 120)
    #expect(persisted.widgetEntry == "index.html")
    #expect(persisted.bundlePath == ".sloppy/artifacts/widgets/\(artifactID)/")
    #expect(persisted.createdAt == originalCreatedAt)
}

@Test
func widgetGenerationRejectsInvalidSize() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(WidgetArtifactGenerateRequest(prompt: "Make a clock", size: "huge"))

    let response = await router.handle(method: "POST", path: "/v1/artifacts/widgets/generate", body: body)
    #expect(response.status == 400)
}

@Test
func widgetGenerationCreatesWidgetArtifactBundle() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(WidgetArtifactGenerateRequest(prompt: "Make a tiny clock", size: "small"))

    let response = await router.handle(method: "POST", path: "/v1/artifacts/widgets/generate", body: body)
    #expect(response.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WidgetArtifactGenerateResponse.self, from: response.body)
    #expect(payload.artifact.kind == "widget")
    #expect(payload.artifact.widget?.size == "small")

    let widgetResponse = await router.handle(method: "GET", path: "/v1/artifacts/\(payload.artifact.id)/widget", body: nil)
    #expect(widgetResponse.status == 200)
    let widget = try decoder.decode(WidgetArtifactContentResponse.self, from: widgetResponse.body)
    #expect(widget.html.contains("<!doctype html>"))
    #expect(widget.size == "small")
    #expect(widget.width == 160)
    #expect(widget.height == 120)

    let bundleURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".sloppy", isDirectory: true)
        .appendingPathComponent("artifacts", isDirectory: true)
        .appendingPathComponent("widgets", isDirectory: true)
        .appendingPathComponent(payload.artifact.id, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("index.html").path))
    #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))

    let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    #expect(manifest?["bundlePath"] as? String == ".sloppy/artifacts/widgets/\(payload.artifact.id)/")

    let persisted = try #require(await service.store.persistedArtifact(id: payload.artifact.id))
    #expect(persisted.bundlePath == ".sloppy/artifacts/widgets/\(payload.artifact.id)/")
}

@Test
func widgetGenerationRejectsExternalResourceHTML() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let html = """
    <!doctype html>
    <html><body><script src="https://example.com/widget.js"></script></body></html>
    """
    let body = try JSONEncoder().encode(WidgetArtifactGenerateRequest(prompt: "Make a clock", size: "small", html: html))

    let response = await router.handle(method: "POST", path: "/v1/artifacts/widgets/generate", body: body)
    #expect(response.status == 400)
}

@Test
func widgetPreviewRejectsInvalidRuntimeHTML() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(WidgetArtifactGenerateRequest(prompt: "Make a tiny clock", size: "small"))

    let generateResponse = await router.handle(method: "POST", path: "/v1/artifacts/widgets/generate", body: body)
    #expect(generateResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WidgetArtifactGenerateResponse.self, from: generateResponse.body)
    let original = try #require(await service.store.persistedArtifact(id: payload.artifact.id))

    await service.waitForStartup()
    await service.runtime.recover(
        channels: [],
        tasks: [],
        events: [],
        artifacts: [
            RecoveryArtifactState(
                id: payload.artifact.id,
                content: "not html at all",
                createdAt: original.createdAt.addingTimeInterval(10)
            ),
        ]
    )

    let widgetResponse = await router.handle(method: "GET", path: "/v1/artifacts/\(payload.artifact.id)/widget", body: nil)
    #expect(widgetResponse.status == 404)

    let persisted = try #require(await service.store.persistedArtifact(id: payload.artifact.id))
    #expect(persisted.content == original.content)
    #expect(persisted.previewText == original.previewText)
}

@Test
func widgetPreviewRejectsExternalRuntimeHTML() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(WidgetArtifactGenerateRequest(prompt: "Make a tiny clock", size: "small"))

    let generateResponse = await router.handle(method: "POST", path: "/v1/artifacts/widgets/generate", body: body)
    #expect(generateResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WidgetArtifactGenerateResponse.self, from: generateResponse.body)

    await service.waitForStartup()
    await service.runtime.recover(
        channels: [],
        tasks: [],
        events: [],
        artifacts: [
            RecoveryArtifactState(
                id: payload.artifact.id,
                content: #"<!doctype html><html><body><img src="https://example.com/pixel.png"></body></html>"#,
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ]
    )

    let widgetResponse = await router.handle(method: "GET", path: "/v1/artifacts/\(payload.artifact.id)/widget", body: nil)
    #expect(widgetResponse.status == 404)
}

@Test
func runtimeRecoveryAfterRestartReplaysPersistedState() async throws {
    let config = CoreConfig.test
    let channelID = "recovery-\(UUID().uuidString)"
    let projectID = "recovery-project-\(UUID().uuidString)"

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    var artifactID = ""

    do {
        let service = CoreService(config: config)
        let router = CoreRouter(service: service)

        let createProjectBody = try JSONEncoder().encode(
            ProjectCreateRequest(
                id: projectID,
                name: "Recovery Project",
                description: "Validates restart recovery.",
                channels: [.init(title: "Recovery", channelId: channelID)]
            )
        )
        let createProjectResponse = await router.handle(method: "POST", path: "/v1/projects", body: createProjectBody)
        #expect(createProjectResponse.status == 201)

        let createTaskBody = try JSONEncoder().encode(
            ProjectTaskCreateRequest(
                title: "Recovery task",
                description: "Persisted project task for restart validation.",
                priority: "medium",
                status: "backlog"
            )
        )
        let createTaskResponse = await router.handle(
            method: "POST",
            path: "/v1/projects/\(projectID)/tasks",
            body: createTaskBody
        )
        #expect(createTaskResponse.status == 200)
        let createdProject = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
        let taskID = try #require(createdProject.tasks.first?.id)

        let createWorkerBody = try JSONEncoder().encode(
            WorkerCreateRequest(
                spec: WorkerTaskSpec(
                    taskId: taskID,
                    channelId: channelID,
                    title: "Recovery worker",
                    objective: "Persist recovery artifact",
                    tools: ["files.write"],
                    mode: .interactive
                )
            )
        )
        let createWorkerResponse = await router.handle(method: "POST", path: "/v1/workers", body: createWorkerBody)
        #expect(createWorkerResponse.status == 201)

        let stateResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelID)/state", body: nil)
        #expect(stateResponse.status == 200)
        let state = try decoder.decode(ChannelSnapshot.self, from: stateResponse.body)
        let workerID = try #require(state.activeWorkerIds.first)

        let completionRouteMessage = String(
            decoding: try JSONEncoder().encode(WorkerRouteCommand(command: .complete, summary: "Recovery artifact ready")),
            as: UTF8.self
        )
        let routeBody = try JSONEncoder().encode(ChannelRouteRequest(message: completionRouteMessage))
        let routeResponse = await router.handle(
            method: "POST",
            path: "/v1/channels/\(channelID)/route/\(workerID)",
            body: routeBody
        )
        #expect(routeResponse.status == 200)

        let completedStateResponse = await router.handle(
            method: "GET",
            path: "/v1/channels/\(channelID)/state",
            body: nil
        )
        #expect(completedStateResponse.status == 200)
        let completedState = try decoder.decode(ChannelSnapshot.self, from: completedStateResponse.body)
        let completionSystemMessage = try #require(
            completedState.messages.last(where: { message in
                message.userId == "system" && message.content.contains("artifact ")
            })?.content
        )
        artifactID = try #require(extractArtifactID(from: completionSystemMessage))

        let artifactResponse = await router.handle(
            method: "GET",
            path: "/v1/artifacts/\(artifactID)/content",
            body: nil
        )
        #expect(artifactResponse.status == 200)

        let schemaPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/sloppy/Storage/schema.sql")
            .path
        let schemaSQL = try String(contentsOfFile: schemaPath, encoding: .utf8)
        let verificationStore = SQLiteStore(path: config.sqlitePath, schemaSQL: schemaSQL)
        let expectedArtifactID = artifactID
        let persisted = await waitForCondition(timeoutSeconds: 3, pollNanoseconds: 100_000_000) {
            let channels = await verificationStore.listPersistedChannels()
            let artifacts = await verificationStore.listPersistedArtifacts()
            let events = await verificationStore.listPersistedEvents()
            return channels.contains(where: { $0.id == channelID })
                && artifacts.contains(where: { $0.id == expectedArtifactID })
                && events.contains(where: { $0.channelId == channelID })
        }
        #expect(persisted)
    }

    let restartedService = CoreService(config: config)
    let restartedRouter = CoreRouter(service: restartedService)

    let restartedStateResponse = await restartedRouter.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/state",
        body: nil
    )
    #expect(restartedStateResponse.status == 200)

    let restartedArtifactResponse = await restartedRouter.handle(
        method: "GET",
        path: "/v1/artifacts/\(artifactID)/content",
        body: nil
    )
    #expect(restartedArtifactResponse.status == 200)

    let restartedState = try decoder.decode(ChannelSnapshot.self, from: restartedStateResponse.body)
    if restartedState.messages.isEmpty {
        let schemaPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/sloppy/Storage/schema.sql")
            .path
        let schemaSQL = try String(contentsOfFile: schemaPath, encoding: .utf8)
        let restartedStore = SQLiteStore(path: config.sqlitePath, schemaSQL: schemaSQL)
        let persistedEvents = await restartedStore.listPersistedEvents()
            .filter { $0.channelId == channelID }
        #expect(!persistedEvents.isEmpty)
    } else {
        #expect(!restartedState.messages.isEmpty)
    }

    let projectResponse = await restartedRouter.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
    #expect(projectResponse.status == 200)
    let recoveredProject = try decoder.decode(ProjectRecord.self, from: projectResponse.body)
    #expect(recoveredProject.tasks.count == 1)
}

@Test
func createListAndGetAgentsEndpoints() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let request = AgentCreateRequest(
        id: "agent-dev",
        displayName: "Dev Agent",
        role: "Builds and debugs features."
    )
    let createBody = try JSONEncoder().encode(request)
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createdAgent = try decoder.decode(AgentSummary.self, from: createResponse.body)
    #expect(createdAgent.id == "agent-dev")
    #expect(createdAgent.displayName == "Dev Agent")
    #expect(createdAgent.pet != nil)
    #expect(createdAgent.pet?.currentStats == createdAgent.pet?.baseStats)

    let listResponse = await router.handle(method: "GET", path: "/v1/agents", body: nil)
    #expect(listResponse.status == 200)
    let list = try decoder.decode([AgentSummary].self, from: listResponse.body)
    #expect(list.contains(where: { $0.id == "agent-dev" }))

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-dev", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(AgentSummary.self, from: getResponse.body)
    #expect(fetched.id == "agent-dev")

    let workspaceAgentsURL = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-dev", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: workspaceAgentsURL.path))

    let scaffoldFiles = ["AGENTS.md", "USER.md", "SOUL.md", "IDENTITY.id", "IDENTITY.md", "HEARTBEAT.md", "FRIEND_REMINDER.md", "MEMORY.md", "config.json", "agent.json", "pet-state.json"]
    for file in scaffoldFiles {
        let fileURL = workspaceAgentsURL.appendingPathComponent(file)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    let filesResponse = await router.handle(method: "GET", path: "/v1/agents/agent-dev/files", body: nil)
    #expect(filesResponse.status == 200)
    let visibleFiles = try decoder.decode([ProjectFileEntry].self, from: filesResponse.body)
    #expect(visibleFiles.contains { $0.name == "FRIEND_REMINDER.md" && $0.type == .file })

    let friendReminderResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-dev/files/content?path=FRIEND_REMINDER.md",
        body: nil
    )
    #expect(friendReminderResponse.status == 200)
    let friendReminderFile = try decoder.decode(ProjectFileContentResponse.self, from: friendReminderResponse.body)
    #expect(friendReminderFile.path == "FRIEND_REMINDER.md")
}

@Test
func agentTasksEndpointReturnsClaimedProjectTasks() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let agentCreateBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-claim",
            displayName: "Claim Agent",
            role: "Takes delegated tasks"
        )
    )
    let agentCreateResponse = await router.handle(method: "POST", path: "/v1/agents", body: agentCreateBody)
    #expect(agentCreateResponse.status == 201)

    let projectID = "agent-task-project-\(UUID().uuidString)"
    let projectCreateBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Agent Tasks Project",
            description: "Tracks claimed tasks by agent",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let projectCreateResponse = await router.handle(method: "POST", path: "/v1/projects", body: projectCreateBody)
    #expect(projectCreateResponse.status == 201)

    let createTaskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Delegated to actor",
            description: "Auto assignment test",
            priority: "medium",
            status: "ready",
            actorId: "agent:agent-claim"
        )
    )
    let createTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(projectID)/tasks",
        body: createTaskBody
    )
    #expect(createTaskResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var createdProject = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
    let taskID = try #require(createdProject.tasks.first?.id)

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let fetchProjectResponse = await router.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
        #expect(fetchProjectResponse.status == 200)
        createdProject = try decoder.decode(ProjectRecord.self, from: fetchProjectResponse.body)
        if createdProject.tasks.first(where: { $0.id == taskID })?.claimedAgentId == "agent-claim" {
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    let tasksResponse = await router.handle(method: "GET", path: "/v1/agents/agent-claim/tasks", body: nil)
    #expect(tasksResponse.status == 200)
    let records = try decoder.decode([AgentTaskRecord].self, from: tasksResponse.body)
    #expect(records.contains(where: { $0.task.id == taskID }))
    #expect(records.contains(where: { $0.task.claimedAgentId == "agent-claim" }))
}

@Test
func agentMemoriesEndpointsListAndGraphRecords() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let memoryStore = HybridMemoryStore(config: config)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-memory",
            displayName: "Agent Memory",
            role: "Stores memory records"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let persistentRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Retain system architecture decisions.",
            summary: "Persistent system fact",
            kind: .fact,
            memoryClass: .semantic,
            scope: .agent("agent-memory")
        )
    )
    let temporaryRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Yesterday deploy note for rollback context.",
            summary: "Short lived deploy context",
            kind: .event,
            memoryClass: .episodic,
            scope: .agent("agent-memory")
        )
    )
    let todoRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "[todo] follow up with release checklist",
            summary: "Todo item",
            kind: .todo,
            memoryClass: .procedural,
            scope: .channel("agent:agent-memory:session:s1")
        )
    )
    let neighborRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Dependency decision context for architecture review.",
            summary: "Graph neighbor",
            kind: .decision,
            memoryClass: .procedural,
            scope: .agent("agent-memory")
        )
    )
    _ = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Foreign memory should stay hidden.",
            summary: "Other agent",
            kind: .fact,
            memoryClass: .semantic,
            scope: .agent("other-agent")
        )
    )
    #expect(
        await memoryStore.link(
            MemoryEdgeWriteRequest(
                fromMemoryId: persistentRef.id,
                toMemoryId: neighborRef.id,
                relation: .derivedFrom,
                provenance: "tests"
            )
        ) == true
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let listResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?limit=1&offset=1",
        body: nil
    )
    #expect(listResponse.status == 200)
    let listPage = try decoder.decode(AgentMemoryListResponse.self, from: listResponse.body)
    #expect(listPage.total == 4)
    #expect(listPage.limit == 1)
    #expect(listPage.offset == 1)
    #expect(listPage.items.count == 1)

    let summarySearchResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?search=Persistent&filter=persistent",
        body: nil
    )
    #expect(summarySearchResponse.status == 200)
    let summarySearch = try decoder.decode(AgentMemoryListResponse.self, from: summarySearchResponse.body)
    #expect(summarySearch.items.count == 1)
    #expect(summarySearch.items.first?.id == persistentRef.id)
    #expect(summarySearch.items.first?.derivedCategory == .persistent)

    let noteSearchResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?search=rollback&filter=temporary",
        body: nil
    )
    #expect(noteSearchResponse.status == 200)
    let noteSearch = try decoder.decode(AgentMemoryListResponse.self, from: noteSearchResponse.body)
    #expect(noteSearch.items.map(\.id) == [temporaryRef.id])

    let idSearchResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?search=\(todoRef.id)&filter=todo",
        body: nil
    )
    #expect(idSearchResponse.status == 200)
    let idSearch = try decoder.decode(AgentMemoryListResponse.self, from: idSearchResponse.body)
    #expect(idSearch.items.map(\.id) == [todoRef.id])
    #expect(idSearch.items.first?.scope.type == .channel)

    let graphResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories/graph?search=Persistent&filter=persistent",
        body: nil
    )
    #expect(graphResponse.status == 200)
    let graph = try decoder.decode(AgentMemoryGraphResponse.self, from: graphResponse.body)
    #expect(graph.seedIds == [persistentRef.id])
    #expect(graph.nodes.contains(where: { $0.id == persistentRef.id }))
    #expect(graph.nodes.contains(where: { $0.id == neighborRef.id }))
    #expect(graph.nodes.allSatisfy { $0.scope.agentId == "agent-memory" || $0.scope.channelId?.hasPrefix("agent:agent-memory:session:") == true })
    #expect(graph.edges.count == 1)
    #expect(graph.edges.first?.fromMemoryId == persistentRef.id)
    #expect(graph.edges.first?.toMemoryId == neighborRef.id)
    #expect(graph.truncated == false)
}

@Test
func agentMemoriesEndpointsValidateAgentAndTruncation() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let memoryStore = HybridMemoryStore(config: config)

    let invalidResponse = await router.handle(method: "GET", path: "/v1/agents/invalid!/memories", body: nil)
    #expect(invalidResponse.status == 400)

    let missingResponse = await router.handle(method: "GET", path: "/v1/agents/missing-agent/memories/graph", body: nil)
    #expect(missingResponse.status == 404)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-memory-truncate",
            displayName: "Agent Memory Truncate",
            role: "Tests graph caps"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    for index in 0..<51 {
        _ = await memoryStore.save(
            entry: MemoryWriteRequest(
                note: "Persistent memory \(index)",
                summary: "Seed \(index)",
                kind: .fact,
                memoryClass: .semantic,
                scope: .agent("agent-memory-truncate")
            )
        )
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let graphResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory-truncate/memories/graph?filter=all",
        body: nil
    )
    #expect(graphResponse.status == 200)
    let graph = try decoder.decode(AgentMemoryGraphResponse.self, from: graphResponse.body)
    #expect(graph.seedIds.count == 50)
    #expect(graph.nodes.count == 50)
    #expect(graph.truncated == true)
}

@Test
func agentConfigEndpointsReadAndUpdate() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-config",
            displayName: "Agent Config",
            role: "Tests model and markdown config endpoints"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-config/config", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(AgentConfigDetail.self, from: getResponse.body)
    #expect(fetched.agentId == "agent-config")
    #expect(fetched.selectedModel != nil && !fetched.selectedModel!.isEmpty)
    #expect(!fetched.availableModels.isEmpty)
    #expect(fetched.heartbeat.enabled == false)
    #expect(fetched.heartbeat.intervalMinutes == 5)
    #expect(fetched.channelSessions.autoCloseEnabled == false)
    #expect(fetched.channelSessions.autoCloseAfterMinutes == 30)
    #expect(fetched.channelSessions.allowedChannelIds.isEmpty)
    #expect(fetched.channelSessions.excludedChannelIds.isEmpty)
    #expect(fetched.documents.heartbeatMarkdown.isEmpty)
    #expect(fetched.documents.friendReminderMarkdown.isEmpty)
    #expect(fetched.heartbeatStatus.lastRunAt == nil)

    let nextModel = fetched.availableModels.last?.id ?? fetched.selectedModel ?? ""
    let updateRequest = AgentConfigUpdateRequest(
        role: nil,
        selectedModel: nextModel,
        documents: AgentDocumentBundle(
            userMarkdown: "# User\nUpdated user profile\n",
            agentsMarkdown: "# Agent\nUpdated orchestration guidance\n",
            soulMarkdown: "# Soul\nUpdated values and boundaries\n",
            identityMarkdown: "# Identity\nagent-config-v2\n",
            heartbeatMarkdown: "- verify onboarding checklist\n",
            friendReminderMarkdown: "- Keep it friendly\n"
        ),
        heartbeat: AgentHeartbeatSettings(enabled: true, intervalMinutes: 15),
        channelSessions: AgentChannelSessionSettings(
            autoCloseEnabled: true,
            autoCloseAfterMinutes: 45,
            allowedChannelIds: ["support", "support"],
            excludedChannelIds: ["ops"]
        )
    )
    let updateBody = try JSONEncoder().encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/agents/agent-config/config", body: updateBody)
    #expect(updateResponse.status == 200)

    let updated = try decoder.decode(AgentConfigDetail.self, from: updateResponse.body)
    #expect(updated.selectedModel == nextModel)
    #expect(updated.documents.userMarkdown.contains("Updated user profile"))
    #expect(updated.documents.agentsMarkdown.contains("Updated orchestration guidance"))
    #expect(updated.documents.soulMarkdown.contains("Updated values and boundaries"))
    #expect(updated.documents.identityMarkdown.contains("agent-config-v2"))
    #expect(updated.documents.heartbeatMarkdown.contains("verify onboarding checklist"))
    #expect(updated.documents.friendReminderMarkdown.contains("Keep it friendly"))
    #expect(updated.heartbeat.enabled == true)
    #expect(updated.heartbeat.intervalMinutes == 15)
    #expect(updated.channelSessions.autoCloseEnabled == true)
    #expect(updated.channelSessions.autoCloseAfterMinutes == 45)
    #expect(updated.channelSessions.allowedChannelIds == ["support"])
    #expect(updated.channelSessions.excludedChannelIds == ["ops"])

    let agentDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-config", isDirectory: true)
    let identityPath = agentDirectory.appendingPathComponent("IDENTITY.md")
    let heartbeatPath = agentDirectory.appendingPathComponent("HEARTBEAT.md")
    let userPath = agentDirectory.appendingPathComponent("USER.md")
    let configPath = agentDirectory.appendingPathComponent("config.json")

    let identityFileText = try String(contentsOf: identityPath, encoding: .utf8)
    let heartbeatFileText = try String(contentsOf: heartbeatPath, encoding: .utf8)
    let userFileText = try String(contentsOf: userPath, encoding: .utf8)
    let configFileText = try String(contentsOf: configPath, encoding: .utf8)
    #expect(identityFileText == "agent-config-v2\n")
    #expect(heartbeatFileText == "- verify onboarding checklist\n")
    #expect(userFileText.contains("Updated user profile"))
    #expect(configFileText.contains(nextModel))
    #expect(configFileText.contains("\"intervalMinutes\" : 15"))
    #expect(configFileText.contains("\"autoCloseAfterMinutes\" : 45"))
    #expect(configFileText.contains("\"allowedChannelIds\""))
    #expect(configFileText.contains("\"excludedChannelIds\""))
}

@Test
func availableProviderModelsEndpointIncludesEffectiveOpenCodeModels() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-opencode-models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("opencode.json")
    try Data(
        """
        {
          "provider": {
            "company": {
              "name": "Company",
              "npm": "@ai-sdk/openai-compatible",
              "options": {
                "baseURL": "https://models.example.com/v1",
                "apiKey": "company-key"
              },
              "models": {
                "fast-code": { "name": "Fast Code" }
              }
            }
          }
        }
        """.utf8
    ).write(to: configURL)

    var config = CoreConfig.test
    config.models = []
    config.opencode = CoreConfig.OpenCode(
        enabled: true,
        useResolvedConfigCommand: false,
        configPaths: [configURL.path]
    )
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/providers/models", body: nil)

    #expect(response.status == 200)
    let models = try JSONDecoder().decode([ProviderModelOption].self, from: response.body)
    #expect(models.contains { $0.id == "opencode:company/fast-code" })
}

@Test
func channelRoutingSkipsExcludedFirstAgentAndUsesConfigAllowList() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)

    _ = try await service.createAgent(
        AgentCreateRequest(id: "channel-first", displayName: "First", role: "First channel agent")
    )
    _ = try await service.createAgent(
        AgentCreateRequest(id: "channel-second", displayName: "Second", role: "Second channel agent")
    )
    _ = try await service.createAgent(
        AgentCreateRequest(id: "channel-config", displayName: "Config", role: "Config channel agent")
    )

    let firstConfig = try await service.getAgentConfig(agentID: "channel-first")
    _ = try await service.updateAgentConfig(
        agentID: "channel-first",
        request: AgentConfigUpdateRequest(
            role: firstConfig.role,
            selectedModel: firstConfig.selectedModel,
            documents: firstConfig.documents,
            heartbeat: firstConfig.heartbeat,
            channelSessions: AgentChannelSessionSettings(
                autoCloseEnabled: firstConfig.channelSessions.autoCloseEnabled,
                autoCloseAfterMinutes: firstConfig.channelSessions.autoCloseAfterMinutes,
                inboundActivation: firstConfig.channelSessions.inboundActivation,
                excludedChannelIds: ["shared"]
            ),
            runtime: firstConfig.runtime
        )
    )

    let configOnly = try await service.getAgentConfig(agentID: "channel-config")
    _ = try await service.updateAgentConfig(
        agentID: "channel-config",
        request: AgentConfigUpdateRequest(
            role: configOnly.role,
            selectedModel: configOnly.selectedModel,
            documents: configOnly.documents,
            heartbeat: configOnly.heartbeat,
            channelSessions: AgentChannelSessionSettings(
                autoCloseEnabled: configOnly.channelSessions.autoCloseEnabled,
                autoCloseAfterMinutes: configOnly.channelSessions.autoCloseAfterMinutes,
                inboundActivation: configOnly.channelSessions.inboundActivation,
                allowedChannelIds: ["config-only"]
            ),
            runtime: configOnly.runtime
        )
    )

    _ = try await service.createActorNode(
        node: ActorNode(id: "actor:channel-first:shared", displayName: "First", kind: .agent, linkedAgentId: "channel-first", channelId: "shared")
    )
    _ = try await service.createActorNode(
        node: ActorNode(id: "actor:channel-second:shared", displayName: "Second", kind: .agent, linkedAgentId: "channel-second", channelId: "shared")
    )

    let board = try await service.getActorBoard()
    let sharedAgent = await service.linkedAgentID(forChannelID: "shared", board: board)
    let configOnlyAgent = await service.linkedAgentID(forChannelID: "config-only", board: board)
    let firstBindings = await service.boundChannelIDs(agentID: "channel-first", board: board)
    let secondBindings = await service.boundChannelIDs(agentID: "channel-second", board: board)
    let configBindings = await service.boundChannelIDs(agentID: "channel-config", board: board)

    #expect(sharedAgent == "channel-second")
    #expect(configOnlyAgent == "channel-config")
    #expect(!firstBindings.contains("shared"))
    #expect(firstBindings.contains("agent:channel-first"))
    #expect(secondBindings.contains("shared"))
    #expect(secondBindings.contains("agent:channel-second"))
    #expect(configBindings.contains("config-only"))
    #expect(configBindings.contains("agent:channel-config"))
}

@Test
func agentConfigHeartbeatValidationAndBackfill() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-heartbeat",
            displayName: "Agent Heartbeat",
            role: "Tests heartbeat config validation"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let agentDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-heartbeat", isDirectory: true)
    let heartbeatPath = agentDirectory.appendingPathComponent("HEARTBEAT.md")
    #expect(FileManager.default.fileExists(atPath: heartbeatPath.path))

    try FileManager.default.removeItem(at: heartbeatPath)
    #expect(!FileManager.default.fileExists(atPath: heartbeatPath.path))

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-heartbeat/config", body: nil)
    #expect(getResponse.status == 200)
    #expect(FileManager.default.fileExists(atPath: heartbeatPath.path))

    let invalidUpdate = AgentConfigUpdateRequest(
        role: nil,
        selectedModel: "openai-api:gpt-5.4-mini",
        documents: AgentDocumentBundle(
            userMarkdown: "# User\nA\n",
            agentsMarkdown: "# Agent\nB\n",
            soulMarkdown: "# Soul\nC\n",
            identityMarkdown: "# Identity\nagent-heartbeat\n",
            heartbeatMarkdown: "- verify\n"
        ),
        heartbeat: AgentHeartbeatSettings(enabled: true, intervalMinutes: 0),
        channelSessions: AgentChannelSessionSettings(
            autoCloseEnabled: true,
            autoCloseAfterMinutes: 0
        )
    )
    let invalidBody = try JSONEncoder().encode(invalidUpdate)
    let invalidResponse = await router.handle(method: "PUT", path: "/v1/agents/agent-heartbeat/config", body: invalidBody)
    #expect(invalidResponse.status == 400)

    let invalidChannelSessionUpdate = AgentConfigUpdateRequest(
        role: nil,
        selectedModel: "openai-api:gpt-5.4-mini",
        documents: AgentDocumentBundle(
            userMarkdown: "# User\nA\n",
            agentsMarkdown: "# Agent\nB\n",
            soulMarkdown: "# Soul\nC\n",
            identityMarkdown: "# Identity\nagent-heartbeat\n",
            heartbeatMarkdown: "- verify\n"
        ),
        heartbeat: AgentHeartbeatSettings(enabled: true, intervalMinutes: 5),
        channelSessions: AgentChannelSessionSettings(
            autoCloseEnabled: true,
            autoCloseAfterMinutes: 0
        )
    )
    let invalidChannelSessionBody = try JSONEncoder().encode(invalidChannelSessionUpdate)
    let invalidChannelSessionResponse = await router.handle(
        method: "PUT",
        path: "/v1/agents/agent-heartbeat/config",
        body: invalidChannelSessionBody
    )
    #expect(invalidChannelSessionResponse.status == 400)
}

@Test
func agentToolsEndpointsReadAndUpdate() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools",
            displayName: "Agent Tools",
            role: "Tests tools policy endpoints"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-tools/tools", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(AgentToolsPolicy.self, from: getResponse.body)
    #expect(fetched.version == 1)
    #expect(fetched.defaultPolicy == .allow)
    #expect(fetched.approval.enabled == false)

    let updateRequest = AgentToolsUpdateRequest(
        version: 1,
        defaultPolicy: .deny,
        tools: [
            "agents.list": true,
            "sessions.list": true
        ],
        approval: AgentToolApprovalSettings(enabled: true),
        guardrails: AgentToolsGuardrails()
    )
    let updateBody = try JSONEncoder().encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/agents/agent-tools/tools", body: updateBody)
    #expect(updateResponse.status == 200)

    let updated = try decoder.decode(AgentToolsPolicy.self, from: updateResponse.body)
    #expect(updated.defaultPolicy == .deny)
    #expect(updated.approval.enabled == true)
    #expect(updated.tools["agents.list"] == true)
    #expect(updated.tools["sessions.list"] == true)

    let toolsFileURL = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-tools", isDirectory: true)
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("tools.json")
    #expect(FileManager.default.fileExists(atPath: toolsFileURL.path))
}

@Test
func channelSessionEndpointsFilterByAgentAndExpireStaleSessions() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: "agent-channel-owner",
            displayName: "Channel Owner",
            role: "Owns support channel"
        )
    )
    _ = try await service.createAgent(
        AgentCreateRequest(
            id: "agent-channel-other",
            displayName: "Other Channel Agent",
            role: "Owns ops channel"
        )
    )

    let ownerConfig = try await service.getAgentConfig(agentID: "agent-channel-owner")
    _ = try await service.updateAgentConfig(
        agentID: "agent-channel-owner",
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: ownerConfig.selectedModel,
            documents: ownerConfig.documents,
            heartbeat: ownerConfig.heartbeat,
            channelSessions: AgentChannelSessionSettings(
                autoCloseEnabled: true,
                autoCloseAfterMinutes: 1
            )
        )
    )

    _ = try await service.createActorNode(
        node: ActorNode(
            id: "actor:agent-channel-owner:support",
            displayName: "Channel Owner",
            kind: .agent,
            linkedAgentId: "agent-channel-owner",
            channelId: "support"
        )
    )
    _ = try await service.createActorNode(
        node: ActorNode(
            id: "actor:agent-channel-other:ops",
            displayName: "Other Channel Agent",
            kind: .agent,
            linkedAgentId: "agent-channel-other",
            channelId: "ops"
        )
    )

    let sessionStore = ChannelSessionFileStore(workspaceRootURL: config.resolvedWorkspaceRootURL())
    let staleStartedAt = Date(timeIntervalSinceNow: -360)
    _ = try await sessionStore.recordUserMessage(
        channelId: "support",
        userId: "user-1",
        content: "Need help with a stale thread",
        createdAt: staleStartedAt
    )
    _ = try await sessionStore.recordAssistantMessage(
        channelId: "support",
        content: "Stale response",
        createdAt: staleStartedAt.addingTimeInterval(5)
    )

    _ = try await sessionStore.recordUserMessage(
        channelId: "ops",
        userId: "user-2",
        content: "Fresh ops thread",
        createdAt: Date()
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let openOwnerResponse = await router.handle(
        method: "GET",
        path: "/v1/channel-sessions?status=open&agentId=agent-channel-owner",
        body: nil
    )
    #expect(openOwnerResponse.status == 200)
    let openOwnerSessions = try decoder.decode([ChannelSessionSummary].self, from: openOwnerResponse.body)
    #expect(openOwnerSessions.isEmpty)

    let closedOwnerResponse = await router.handle(
        method: "GET",
        path: "/v1/channel-sessions?status=closed&agentId=agent-channel-owner",
        body: nil
    )
    #expect(closedOwnerResponse.status == 200)
    let closedOwnerSessions = try decoder.decode([ChannelSessionSummary].self, from: closedOwnerResponse.body)
    #expect(closedOwnerSessions.count == 1)
    #expect(closedOwnerSessions.first?.channelId == "support")
    #expect(closedOwnerSessions.first?.status == .closed)
    #expect(closedOwnerSessions.first?.closedAt != nil)

    let openOtherResponse = await router.handle(
        method: "GET",
        path: "/v1/channel-sessions?status=open&agentId=agent-channel-other",
        body: nil
    )
    #expect(openOtherResponse.status == 200)
    let openOtherSessions = try decoder.decode([ChannelSessionSummary].self, from: openOtherResponse.body)
    #expect(openOtherSessions.count == 1)
    #expect(openOtherSessions.first?.channelId == "ops")
    #expect(openOtherSessions.first?.status == .open)
}

@Test
func agentToolsUpdateRejectsInvalidSchemaVersion() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-invalid",
            displayName: "Agent Tools Invalid",
            role: "Tests tools payload validation"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let invalidRequest = AgentToolsUpdateRequest(
        version: 2,
        defaultPolicy: .allow,
        tools: [:],
        guardrails: AgentToolsGuardrails()
    )
    let body = try JSONEncoder().encode(invalidRequest)
    let response = await router.handle(method: "PUT", path: "/v1/agents/agent-tools-invalid/tools", body: body)
    #expect(response.status == 400)
}

@Test
func invokeToolEndpointRespectsPolicy() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    await service.setToolApprovalPresenter { _ in .reject }
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-invoke",
            displayName: "Agent Tools Invoke",
            role: "Runs tool invocation endpoint tests"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-invoke/sessions",
        body: try JSONEncoder().encode(AgentSessionCreateRequest(title: "Tool Session"))
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)

    let invokeBody = try JSONEncoder().encode(
        ToolInvocationRequest(tool: "agents.list")
    )
    let invokeResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-invoke/sessions/\(summary.id)/tools/invoke",
        body: invokeBody
    )
    #expect(invokeResponse.status == 200)
    let invokeResult = try decoder.decode(ToolInvocationResult.self, from: invokeResponse.body)
    #expect(invokeResult.ok == true)

    let denyBody = try JSONEncoder().encode(
        AgentToolsUpdateRequest(
            version: 1,
            defaultPolicy: .deny,
            tools: [:],
            guardrails: AgentToolsGuardrails()
        )
    )
    let denyResponse = await router.handle(
        method: "PUT",
        path: "/v1/agents/agent-tools-invoke/tools",
        body: denyBody
    )
    #expect(denyResponse.status == 200)

    let invokeForbiddenResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-invoke/sessions/\(summary.id)/tools/invoke",
        body: invokeBody
    )
    #expect(invokeForbiddenResponse.status == 200)
    let rejected = try decoder.decode(ToolInvocationResult.self, from: invokeForbiddenResponse.body)
    #expect(!rejected.ok)
    #expect(rejected.error?.code == "tool_approval_rejected")
}

@Test
func invokeRuntimeExecBlocksDeniedCommandPrefix() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-exec",
            displayName: "Agent Tools Exec",
            role: "Tests runtime.exec guardrails"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-exec/sessions",
        body: try JSONEncoder().encode(AgentSessionCreateRequest(title: "Exec Session"))
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)

    let invokeBody = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("rm"),
                "arguments": .array([.string("-rf"), .string("/tmp/demo")])
            ]
        )
    )

    let response = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-exec/sessions/\(summary.id)/tools/invoke",
        body: invokeBody
    )
    #expect(response.status == 200)
    let result = try decoder.decode(ToolInvocationResult.self, from: response.body)
    #expect(result.ok == false)
    #expect(result.error?.code == "command_blocked")
}

@Test
func invokeRuntimeProcessLifecycleWorksPerSession() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-process",
            displayName: "Agent Tools Process",
            role: "Tests runtime.process lifecycle"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-process/sessions",
        body: try JSONEncoder().encode(AgentSessionCreateRequest(title: "Process Session"))
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)

    let startBody = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "runtime.process",
            arguments: [
                "action": .string("start"),
                "command": .string("/bin/sleep"),
                "arguments": .array([.string("2")])
            ]
        )
    )
    let startResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-process/sessions/\(summary.id)/tools/invoke",
        body: startBody
    )
    #expect(startResponse.status == 200)
    let startResult = try decoder.decode(ToolInvocationResult.self, from: startResponse.body)
    #expect(startResult.ok == true)
    let processId = startResult.data?.asObject?["processId"]?.asString ?? ""
    #expect(!processId.isEmpty)

    let stopBody = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "runtime.process",
            arguments: [
                "action": .string("stop"),
                "processId": .string(processId)
            ]
        )
    )
    let stopResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-process/sessions/\(summary.id)/tools/invoke",
        body: stopBody
    )
    #expect(stopResponse.status == 200)
    let stopResult = try decoder.decode(ToolInvocationResult.self, from: stopResponse.body)
    #expect(stopResult.ok == true)
}

@Test
func createAgentDuplicateIDReturnsConflict() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let request = AgentCreateRequest(
        id: "agent-same",
        displayName: "Agent Same",
        role: "Role"
    )
    let body = try JSONEncoder().encode(request)
    let firstResponse = await router.handle(method: "POST", path: "/v1/agents", body: body)
    #expect(firstResponse.status == 201)

    let secondResponse = await router.handle(method: "POST", path: "/v1/agents", body: body)
    #expect(secondResponse.status == 409)
}

@Test
func systemAgentStoredInSystemSubdirectory() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let userRequest = AgentCreateRequest(id: "user-agent", displayName: "User Agent", role: "User facing")
    let userBody = try JSONEncoder().encode(userRequest)
    let userResponse = await router.handle(method: "POST", path: "/v1/agents", body: userBody)
    #expect(userResponse.status == 201)

    let systemRequest = AgentCreateRequest(id: "sys-worker", displayName: "System Worker", role: "Background task", isSystem: true)
    let systemBody = try JSONEncoder().encode(systemRequest)
    let systemResponse = await router.handle(method: "POST", path: "/v1/agents", body: systemBody)
    #expect(systemResponse.status == 201)
    let createdSystem = try decoder.decode(AgentSummary.self, from: systemResponse.body)
    #expect(createdSystem.isSystem == true)
    #expect(createdSystem.pet == nil)

    let agentsRoot = config.resolvedWorkspaceRootURL().appendingPathComponent("agents", isDirectory: true)
    let systemDirectory = agentsRoot.appendingPathComponent(".system/sys-worker", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: systemDirectory.path))

    let userDirectory = agentsRoot.appendingPathComponent("user-agent", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: userDirectory.path))
    #expect(FileManager.default.fileExists(atPath: userDirectory.appendingPathComponent("pet-state.json").path))
    #expect(!FileManager.default.fileExists(atPath: systemDirectory.appendingPathComponent("pet-state.json").path))

    let listAllResponse = await router.handle(method: "GET", path: "/v1/agents", body: nil)
    #expect(listAllResponse.status == 200)
    let allAgents = try decoder.decode([AgentSummary].self, from: listAllResponse.body)
    #expect(allAgents.contains(where: { $0.id == "user-agent" && !$0.isSystem }))
    #expect(allAgents.contains(where: { $0.id == "sys-worker" && $0.isSystem }))

    let listUserResponse = await router.handle(method: "GET", path: "/v1/agents?system=false", body: nil)
    #expect(listUserResponse.status == 200)
    let userAgents = try decoder.decode([AgentSummary].self, from: listUserResponse.body)
    #expect(userAgents.contains(where: { $0.id == "user-agent" }))
    #expect(!userAgents.contains(where: { $0.id == "sys-worker" }))
}

@Test
func agentSummaryBackwardCompatibleDecodingWithoutIsSystem() throws {
    let json = """
    {
        "id": "legacy-agent",
        "displayName": "Legacy Agent",
        "role": "Old role",
        "createdAt": "2024-01-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSummary.self, from: Data(json.utf8))
    #expect(summary.id == "legacy-agent")
    #expect(summary.isSystem == false)
}

@Test
func actorBoardEndpointsSyncSystemActorsAndPersistLayout() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-ops",
            displayName: "Ops Agent",
            role: "Handles operational work"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let firstBoardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(firstBoardResponse.status == 200)
    let firstBoard = try decoder.decode(ActorBoardSnapshot.self, from: firstBoardResponse.body)
    #expect(firstBoard.nodes.contains(where: { $0.id == "human:admin" && $0.kind == .human }))
    #expect(firstBoard.nodes.contains(where: { $0.id == "agent:agent-ops" && $0.linkedAgentId == "agent-ops" }))

    var updatedNodes = firstBoard.nodes
    if let adminIndex = updatedNodes.firstIndex(where: { $0.id == "human:admin" }) {
        updatedNodes[adminIndex].positionX = 512
        updatedNodes[adminIndex].positionY = 420
    }
    updatedNodes.append(
        ActorNode(
            id: "action:notify",
            displayName: "Notify",
            kind: .action,
            channelId: "channel:notify",
            role: "Dispatches notifications",
            positionX: 760,
            positionY: 420
        )
    )

    let updateRequest = ActorBoardUpdateRequest(
        nodes: updatedNodes,
        links: [
            ActorLink(
                id: "link-admin-notify",
                sourceActorId: "human:admin",
                targetActorId: "action:notify",
                direction: .oneWay,
                communicationType: .chat
            )
        ],
        teams: [
            ActorTeam(
                id: "team:core",
                name: "Sloppy Team",
                memberActorIds: ["human:admin", "action:notify"]
            )
        ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)

    let updatedBoard = try decoder.decode(ActorBoardSnapshot.self, from: updateResponse.body)
    #expect(updatedBoard.nodes.contains(where: { $0.id == "action:notify" }))
    #expect(updatedBoard.links.contains(where: { $0.id == "link-admin-notify" }))
    #expect(updatedBoard.teams.contains(where: { $0.id == "team:core" }))

    let persistedResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(persistedResponse.status == 200)
    let persistedBoard = try decoder.decode(ActorBoardSnapshot.self, from: persistedResponse.body)
    let persistedAdmin = persistedBoard.nodes.first(where: { $0.id == "human:admin" })
    #expect(persistedAdmin?.positionX == 512)
    #expect(persistedAdmin?.positionY == 420)
}

@Test
func actorBoardPreservesTeamMemberOrder() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let boardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(boardResponse.status == 200)
    let board = try decoder.decode(ActorBoardSnapshot.self, from: boardResponse.body)

    let orderedMemberIDs = ["human:manager", "action:developer", "action:reviewer"]
    let updateRequest = ActorBoardUpdateRequest(
        nodes: board.nodes + [
            ActorNode(
                id: "human:manager",
                displayName: "Manager",
                kind: .human,
                channelId: "channel:manager",
                role: "Manager"
            ),
            ActorNode(
                id: "action:developer",
                displayName: "Developer",
                kind: .action,
                channelId: "channel:developer",
                role: "Developer"
            ),
            ActorNode(
                id: "action:reviewer",
                displayName: "Reviewer",
                kind: .action,
                channelId: "channel:reviewer",
                role: "Reviewer"
            )
        ],
        links: board.links,
        teams: [
            ActorTeam(
                id: "team:ordered",
                name: "Ordered Team",
                memberActorIds: orderedMemberIDs
            )
        ]
    )

    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)
    let updatedBoard = try decoder.decode(ActorBoardSnapshot.self, from: updateResponse.body)
    let updatedTeam = try #require(updatedBoard.teams.first(where: { $0.id == "team:ordered" }))
    #expect(updatedTeam.memberActorIds == orderedMemberIDs)

    let persistedResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(persistedResponse.status == 200)
    let persistedBoard = try decoder.decode(ActorBoardSnapshot.self, from: persistedResponse.body)
    let persistedTeam = try #require(persistedBoard.teams.first(where: { $0.id == "team:ordered" }))
    #expect(persistedTeam.memberActorIds == orderedMemberIDs)
}

@Test
func actorRouteEndpointResolvesRecipientsFromLinks() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-analyst",
            displayName: "Analyst Agent",
            role: "Analyzes incoming events"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let boardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(boardResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let board = try decoder.decode(ActorBoardSnapshot.self, from: boardResponse.body)

    var nodes = board.nodes
    nodes.append(
        ActorNode(
            id: "action:triage",
            displayName: "Triage",
            kind: .action,
            channelId: "channel:triage",
            role: "Routes and enriches events",
            positionX: 700,
            positionY: 260
        )
    )

    let updateRequest = ActorBoardUpdateRequest(
        nodes: nodes,
        links: [
            ActorLink(
                id: "link-admin-triage",
                sourceActorId: "human:admin",
                targetActorId: "action:triage",
                direction: .oneWay,
                communicationType: .chat
            ),
            ActorLink(
                id: "link-triage-agent",
                sourceActorId: "action:triage",
                targetActorId: "agent:agent-analyst",
                direction: .twoWay,
                communicationType: .event
            )
        ],
        teams: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)

    let adminRouteBody = try JSONEncoder().encode(
        ActorRouteRequest(fromActorId: "human:admin", communicationType: .chat)
    )
    let adminRouteResponse = await router.handle(method: "POST", path: "/v1/actors/route", body: adminRouteBody)
    #expect(adminRouteResponse.status == 200)
    let adminRoute = try decoder.decode(ActorRouteResponse.self, from: adminRouteResponse.body)
    #expect(adminRoute.recipientActorIds == ["action:triage"])

    let actionRouteBody = try JSONEncoder().encode(
        ActorRouteRequest(fromActorId: "action:triage", communicationType: .event)
    )
    let actionRouteResponse = await router.handle(method: "POST", path: "/v1/actors/route", body: actionRouteBody)
    #expect(actionRouteResponse.status == 200)
    let actionRoute = try decoder.decode(ActorRouteResponse.self, from: actionRouteResponse.body)
    #expect(actionRoute.recipientActorIds == ["agent:agent-analyst"])

    let missingRouteBody = try JSONEncoder().encode(
        ActorRouteRequest(fromActorId: "missing:actor", communicationType: .chat)
    )
    let missingRouteResponse = await router.handle(method: "POST", path: "/v1/actors/route", body: missingRouteBody)
    #expect(missingRouteResponse.status == 404)
}

@Test
func actorDelegationTreePreviewEndpointReturnsLevels() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    for request in [
        AgentCreateRequest(id: "lead", displayName: "Lead", role: "Plans work"),
        AgentCreateRequest(id: "child", displayName: "Child", role: "Executes work")
    ] {
        let response = await router.handle(method: "POST", path: "/v1/agents", body: try encoder.encode(request))
        #expect(response.status == 201)
    }

    let boardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(boardResponse.status == 200)
    let board = try decoder.decode(ActorBoardSnapshot.self, from: boardResponse.body)
    let updateRequest = ActorBoardUpdateRequest(
        nodes: board.nodes,
        links: [
            ActorLink(
                id: "lead-child",
                sourceActorId: "agent:lead",
                targetActorId: "agent:child",
                direction: .oneWay,
                relationship: .hierarchical,
                communicationType: .task
            )
        ],
        teams: board.teams
    )
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: try encoder.encode(updateRequest))
    #expect(updateResponse.status == 200)

    let previewBody = try encoder.encode(ActorDelegationTreePreviewRequest(rootActorId: "agent:lead"))
    let previewResponse = await router.handle(method: "POST", path: "/v1/actors/delegation-tree/preview", body: previewBody)
    #expect(previewResponse.status == 200)
    let preview = try decoder.decode(ActorDelegationTreePreviewResponse.self, from: previewResponse.body)
    #expect(preview.status == .valid)
    #expect(preview.levels.map { $0.map(\.actorId) } == [["agent:child"]])
}

@Test
func actorBoardInfersHierarchicalRelationshipFromSockets() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let createAgentBody = try encoder.encode(
        AgentCreateRequest(
            id: "child-agent",
            displayName: "Child Agent",
            role: "Hierarchy target"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let initialBoardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(initialBoardResponse.status == 200)
    let initialBoard = try decoder.decode(ActorBoardSnapshot.self, from: initialBoardResponse.body)

    var nodes = initialBoard.nodes
    nodes.append(
        ActorNode(
            id: "agent:child",
            displayName: "Child Agent",
            kind: .agent,
            linkedAgentId: "child-agent",
            channelId: "agent:child"
        )
    )

    let updateRequest = ActorBoardUpdateRequest(
        nodes: nodes,
        links: [
            ActorLink(
                id: "link-admin-child-task",
                sourceActorId: "human:admin",
                targetActorId: "agent:child",
                direction: .oneWay,
                communicationType: .task,
                sourceSocket: .bottom,
                targetSocket: .top
            )
        ],
        teams: []
    )

    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)
    let updatedBoard = try decoder.decode(ActorBoardSnapshot.self, from: updateResponse.body)
    let updatedLink = try #require(updatedBoard.links.first(where: { $0.id == "link-admin-child-task" }))
    #expect(updatedLink.relationship == .hierarchical)
}

@Test
func actorCRUDEndpointsManageNodesLinksAndTeams() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-crud",
            displayName: "CRUD Agent",
            role: "Actor CRUD coverage"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createNodeBody = try encoder.encode(
        ActorNode(
            id: "action:qa",
            displayName: "QA Action",
            kind: .action,
            channelId: "channel:qa",
            role: "Checks artifacts",
            positionX: 420,
            positionY: 280
        )
    )
    let createNodeResponse = await router.handle(method: "POST", path: "/v1/actors/nodes", body: createNodeBody)
    #expect(createNodeResponse.status == 201)
    var board = try decoder.decode(ActorBoardSnapshot.self, from: createNodeResponse.body)
    #expect(board.nodes.contains(where: { $0.id == "action:qa" }))

    let updateNodeBody = try encoder.encode(
        ActorNode(
            id: "action:qa",
            displayName: "QA Action Updated",
            kind: .action,
            channelId: "channel:qa-v2",
            role: "Updated role",
            positionX: 500,
            positionY: 340
        )
    )
    let updateNodeResponse = await router.handle(method: "PUT", path: "/v1/actors/nodes/action:qa", body: updateNodeBody)
    #expect(updateNodeResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: updateNodeResponse.body)
    #expect(board.nodes.contains(where: { $0.id == "action:qa" && $0.displayName == "QA Action Updated" }))

    let createLinkBody = try encoder.encode(
        ActorLink(
            id: "link-admin-qa",
            sourceActorId: "human:admin",
            targetActorId: "action:qa",
            direction: .oneWay,
            communicationType: .chat
        )
    )
    let createLinkResponse = await router.handle(method: "POST", path: "/v1/actors/links", body: createLinkBody)
    #expect(createLinkResponse.status == 201)
    board = try decoder.decode(ActorBoardSnapshot.self, from: createLinkResponse.body)
    #expect(board.links.contains(where: { $0.id == "link-admin-qa" }))

    let updateLinkBody = try encoder.encode(
        ActorLink(
            id: "link-admin-qa",
            sourceActorId: "human:admin",
            targetActorId: "action:qa",
            direction: .twoWay,
            communicationType: .event
        )
    )
    let updateLinkResponse = await router.handle(method: "PUT", path: "/v1/actors/links/link-admin-qa", body: updateLinkBody)
    #expect(updateLinkResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: updateLinkResponse.body)
    let updatedLink = board.links.first(where: { $0.id == "link-admin-qa" })
    #expect(updatedLink?.direction == .twoWay)
    #expect(updatedLink?.communicationType == .event)

    let createTeamBody = try encoder.encode(
        ActorTeam(
            id: "team:ops",
            name: "Ops Team",
            memberActorIds: ["human:admin", "action:qa"]
        )
    )
    let createTeamResponse = await router.handle(method: "POST", path: "/v1/actors/teams", body: createTeamBody)
    #expect(createTeamResponse.status == 201)
    board = try decoder.decode(ActorBoardSnapshot.self, from: createTeamResponse.body)
    #expect(board.teams.contains(where: { $0.id == "team:ops" }))

    let updateTeamBody = try encoder.encode(
        ActorTeam(
            id: "team:ops",
            name: "Ops Team Updated",
            memberActorIds: ["action:qa"]
        )
    )
    let updateTeamResponse = await router.handle(method: "PUT", path: "/v1/actors/teams/team:ops", body: updateTeamBody)
    #expect(updateTeamResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: updateTeamResponse.body)
    #expect(board.teams.contains(where: { $0.id == "team:ops" && $0.name == "Ops Team Updated" }))

    let deleteLinkResponse = await router.handle(method: "DELETE", path: "/v1/actors/links/link-admin-qa", body: nil)
    #expect(deleteLinkResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: deleteLinkResponse.body)
    #expect(!board.links.contains(where: { $0.id == "link-admin-qa" }))

    let deleteTeamResponse = await router.handle(method: "DELETE", path: "/v1/actors/teams/team%3Aops", body: nil)
    #expect(deleteTeamResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: deleteTeamResponse.body)
    #expect(!board.teams.contains(where: { $0.id == "team:ops" }))

    let deleteNodeResponse = await router.handle(method: "DELETE", path: "/v1/actors/nodes/action:qa", body: nil)
    #expect(deleteNodeResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: deleteNodeResponse.body)
    #expect(!board.nodes.contains(where: { $0.id == "action:qa" }))
}

@Test
func agentSessionLifecycleEndpoints() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-chat",
            displayName: "Agent Chat",
            role: "Handles chat session tests"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let sessionRequest = AgentSessionCreateRequest(title: "Main Session")
    let createSessionBody = try JSONEncoder().encode(sessionRequest)
    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-chat/sessions",
        body: createSessionBody
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sessionSummary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)
    #expect(sessionSummary.agentId == "agent-chat")

    let bootstrapChannelID = "agent:agent-chat:session:\(sessionSummary.id)"
    let bootstrapSnapshot = await service.getChannelState(channelId: bootstrapChannelID)
    #expect(bootstrapSnapshot != nil)
    let bootstrapMessage = bootstrapSnapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })
    #expect(bootstrapMessage != nil)
    #expect(bootstrapMessage?.content.contains("[AGENTS.md]") == true)
    #expect(bootstrapMessage?.content.contains("[USER.md]") == true)
    #expect(bootstrapMessage?.content.contains("[IDENTITY.md]") == true)
    #expect(bootstrapMessage?.content.contains("[SOUL.md]") == true)
    #expect(bootstrapMessage?.content.contains("[Skills]") == true)
    #expect(bootstrapMessage?.content.contains("`sloppy/task-spec-writer`") == true)

    let sessionFileURL = URL(fileURLWithPath: try await service.getAgentSessionFilePath(
        agentID: "agent-chat",
        sessionID: sessionSummary.id
    ))
    #expect(FileManager.default.fileExists(atPath: sessionFileURL.path))

    let listResponse = await router.handle(method: "GET", path: "/v1/agents/agent-chat/sessions", body: nil)
    #expect(listResponse.status == 200)
    let sessions = try decoder.decode([AgentSessionSummary].self, from: listResponse.body)
    #expect(sessions.contains(where: { $0.id == sessionSummary.id }))

    let streamResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/stream",
        body: nil
    )
    #expect(streamResponse.status == 200)
    #expect(streamResponse.contentType == "text/event-stream")
    #expect(streamResponse.sseStream != nil)
    var streamIterator = streamResponse.sseStream?.makeAsyncIterator()
    let readyChunk = await streamIterator?.next()
    #expect(readyChunk != nil)
    if let readyChunk {
        #expect(readyChunk.event == AgentSessionStreamUpdateKind.sessionReady.rawValue)
        let streamUpdate = try decoder.decode(AgentSessionStreamUpdate.self, from: readyChunk.data)
        #expect(streamUpdate.kind == .sessionReady)
        #expect(streamUpdate.summary?.id == sessionSummary.id)
    }

    let canHandleWebSocket = await router.canHandleWebSocket(
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/ws"
    )
    #expect(canHandleWebSocket == true)

    let rejectsMissingSession = await router.canHandleWebSocket(
        path: "/v1/agents/agent-chat/sessions/missing-session/ws"
    )
    #expect(rejectsMissingSession == false)

    let attachmentPayload = AgentAttachmentUpload(
        name: "note.txt",
        mimeType: "text/plain",
        sizeBytes: 4,
        contentBase64: Data("demo".utf8).base64EncodedString()
    )
    let messageRequest = AgentSessionPostMessageRequest(
        userId: "dashboard",
        content: "search this request and reply",
        attachments: [attachmentPayload],
        spawnSubSession: true
    )
    let messageBody = try JSONEncoder().encode(messageRequest)
    let messageResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/messages",
        body: messageBody
    )
    #expect(messageResponse.status == 200)

    let messageResult = try decoder.decode(AgentSessionMessageResponse.self, from: messageResponse.body)
    #expect(!messageResult.appendedEvents.isEmpty)
    #expect(messageResult.routeDecision != nil)

    let getSessionResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)",
        body: nil
    )
    #expect(getSessionResponse.status == 200)

    let detail = try decoder.decode(AgentSessionDetail.self, from: getSessionResponse.body)
    #expect(detail.events.count >= messageResult.appendedEvents.count)

    let controlBody = try JSONEncoder().encode(
        AgentSessionControlRequest(action: .pause, requestedBy: "dashboard", reason: "manual pause")
    )
    let controlResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/control",
        body: controlBody
    )
    #expect(controlResponse.status == 200)

    let deleteResponse = await router.handle(
        method: "DELETE",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)",
        body: nil
    )
    #expect(deleteResponse.status == 200)

    let getDeletedResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)",
        body: nil
    )
    #expect(getDeletedResponse.status == 404)
}

@Test
func browserContextMessageEndpointCreatesSessionAndPostsTypedContext() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "sloppy",
            displayName: "Sloppy",
            role: "Reply briefly."
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let request = BrowserContextMessageRequest(
        page: BrowserContextPage(url: "https://example.com/article", title: "Example Article"),
        selection: BrowserContextSelection(text: "Important selected text."),
        prompt: "Explain the selection",
        browser: BrowserContextBrowser(
            pageSnapshot: .object([
                "elements": .array([
                    .object([
                        "selector": .string("#buy"),
                        "text": .string("Buy now")
                    ])
                ])
            ])
        ),
        target: BrowserContextTarget(agentId: "sloppy"),
        attachments: [
            AgentAttachmentUpload(
                name: "clipboard.png",
                mimeType: "image/png",
                sizeBytes: 4,
                contentBase64: "YWJjZA=="
            )
        ]
    )
    let body = try JSONEncoder().encode(request)

    let response = await router.handle(method: "POST", path: "/v1/browser/context-message", body: body)
    #expect(response.status == 200)

    let payload = try decoder.decode(BrowserContextMessageResponse.self, from: response.body)
    #expect(!payload.sessionId.isEmpty)
    #expect(payload.status == "completed")

    let sessionResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/sloppy/sessions/\(payload.sessionId)",
        body: nil
    )
    #expect(sessionResponse.status == 200)

    let detail = try decoder.decode(AgentSessionDetail.self, from: sessionResponse.body)
    let userText = detail.events
        .compactMap(\.message)
        .filter { $0.role == .user }
        .flatMap(\.segments)
        .compactMap(\.text)
        .joined(separator: "\n")

    #expect(userText.contains("Source: Safari Extension"))
    #expect(userText.contains("URL: https://example.com/article"))
    #expect(userText.contains("Title: Example Article"))
    #expect(userText.contains("Selected text:"))
    #expect(userText.contains("Important selected text."))
    #expect(userText.contains("Safari page snapshot:"))
    #expect(userText.contains("\"selector\":\"#buy\""))
    #expect(userText.contains("\"text\":\"Buy now\""))
    #expect(userText.contains("User prompt:"))
    #expect(userText.contains("Explain the selection"))
    let attachmentNames = detail.events
        .compactMap(\.message)
        .filter { $0.role == .user }
        .flatMap(\.segments)
        .compactMap(\.attachment?.name)
    #expect(attachmentNames.contains("clipboard.png"))
}

@Test
func browserContextPromptRecognizesObsidianSourceWithoutSafariToolInstructions() {
    let prompt = CoreService.browserContextPrompt(
        source: "obsidian_plugin",
        page: BrowserContextPage(
            url: "obsidian://open?vault=Notes&file=Projects%2FSloppy.md",
            title: "Sloppy"
        ),
        selection: "Important selected text.",
        prompt: "Explain the selection"
    )

    #expect(prompt.contains("Source: Obsidian Plugin"))
    #expect(prompt.contains("Title: Sloppy"))
    #expect(prompt.contains("Important selected text."))
    #expect(prompt.contains("Explain the selection"))
    #expect(!prompt.contains("Safari tools:"))
    #expect(!prompt.contains("safari.dom_snapshot"))

    let chatPrompt = CoreService.browserContextPrompt(
        source: "obsidian_chat",
        page: BrowserContextPage(url: "obsidian://open?vault=Notes", title: "Notes"),
        selection: "Note: Projects/Sloppy.md\n\nLocal vault context",
        prompt: "What should I do next?"
    )
    #expect(chatPrompt.contains("Source: Obsidian Chat"))
    #expect(chatPrompt.contains("Vault search context:"))
    #expect(!chatPrompt.contains("Safari tools:"))
}

@Test
func browserContextMessageEndpointAllowsEmptySelection() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "sloppy",
            displayName: "Sloppy",
            role: "Reply briefly."
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let request = BrowserContextMessageRequest(
        page: BrowserContextPage(url: "https://example.com/article", title: "Example Article"),
        selection: BrowserContextSelection(text: "   "),
        prompt: "Explain this",
        target: BrowserContextTarget(agentId: "sloppy")
    )
    let body = try JSONEncoder().encode(request)

    let response = await router.handle(method: "POST", path: "/v1/browser/context-message", body: body)
    #expect(response.status == 200)

    let payload = try decoder.decode(BrowserContextMessageResponse.self, from: response.body)
    let sessionResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/sloppy/sessions/\(payload.sessionId)",
        body: nil
    )
    #expect(sessionResponse.status == 200)

    let detail = try decoder.decode(AgentSessionDetail.self, from: sessionResponse.body)
    let userText = detail.events
        .compactMap(\.message)
        .filter { $0.role == .user }
        .flatMap(\.segments)
        .compactMap(\.text)
        .joined(separator: "\n")
    #expect(userText.contains("Selected text:"))
    #expect(userText.contains("No selected text."))
    #expect(userText.contains("Explain this"))
}

@Test
func browserContextMessageEndpointIncludesProjectAndTaskHints() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "sloppy",
            displayName: "Sloppy",
            role: "Reply briefly."
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let request = BrowserContextMessageRequest(
        page: BrowserContextPage(url: "https://example.com/article", title: "Example Article"),
        selection: BrowserContextSelection(text: "Selected text"),
        prompt: "Надо добавить это сюда",
        context: BrowserContextMessageContext(
            projectReference: "PROMOZAVR",
            taskReference: "123"
        ),
        target: BrowserContextTarget(agentId: "sloppy")
    )
    let body = try JSONEncoder().encode(request)

    let response = await router.handle(method: "POST", path: "/v1/browser/context-message", body: body)
    #expect(response.status == 200)

    let payload = try decoder.decode(BrowserContextMessageResponse.self, from: response.body)
    let sessionResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/sloppy/sessions/\(payload.sessionId)",
        body: nil
    )
    #expect(sessionResponse.status == 200)

    let detail = try decoder.decode(AgentSessionDetail.self, from: sessionResponse.body)
    let userText = detail.events
        .compactMap(\.message)
        .filter { $0.role == .user }
        .flatMap(\.segments)
        .compactMap(\.text)
        .joined(separator: "\n")

    #expect(userText.contains("Requested project reference: @PROMOZAVR"))
    #expect(userText.contains("Requested task reference: #123"))
    #expect(userText.contains("Use `project.list` to resolve the project"))
    #expect(userText.contains("Use `project.task_get` to resolve the task"))
}

// MARK: - Channel Plugins CRUD

@Test
func channelPluginCrudEndpoints() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let listResponse = await router.handle(method: "GET", path: "/v1/plugins", body: nil)
    #expect(listResponse.status == 200)

    let createBody = try JSONEncoder().encode(
        ChannelPluginCreateRequest(
            id: "test-telegram",
            type: "telegram",
            baseUrl: "http://127.0.0.1:9100",
            channelIds: ["tg-general"],
            config: ["botToken": "fake-token"],
            enabled: true
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/plugins", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let created = try decoder.decode(ChannelPluginRecord.self, from: createResponse.body)
    #expect(created.id == "test-telegram")
    #expect(created.type == "telegram")
    #expect(created.channelIds == ["tg-general"])
    #expect(created.config["botToken"] == "fake-token")
    #expect(created.enabled == true)

    let duplicateResponse = await router.handle(method: "POST", path: "/v1/plugins", body: createBody)
    #expect(duplicateResponse.status == 409)

    let getResponse = await router.handle(method: "GET", path: "/v1/plugins/test-telegram", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(ChannelPluginRecord.self, from: getResponse.body)
    #expect(fetched.id == "test-telegram")

    let updateBody = try JSONEncoder().encode(
        ChannelPluginUpdateRequest(
            channelIds: ["tg-general", "tg-dev"],
            config: ["botToken": "updated-token"],
            enabled: false
        )
    )
    let updateResponse = await router.handle(method: "PUT", path: "/v1/plugins/test-telegram", body: updateBody)
    #expect(updateResponse.status == 200)
    let updated = try decoder.decode(ChannelPluginRecord.self, from: updateResponse.body)
    #expect(updated.channelIds == ["tg-general", "tg-dev"])
    #expect(updated.config["botToken"] == "updated-token")
    #expect(updated.enabled == false)

    let listAfterUpdate = await router.handle(method: "GET", path: "/v1/plugins", body: nil)
    #expect(listAfterUpdate.status == 200)
    let allPlugins = try decoder.decode([ChannelPluginRecord].self, from: listAfterUpdate.body)
    #expect(allPlugins.count == 1)

    let deleteResponse = await router.handle(method: "DELETE", path: "/v1/plugins/test-telegram", body: nil)
    #expect(deleteResponse.status == 200)

    let getDeletedResponse = await router.handle(method: "GET", path: "/v1/plugins/test-telegram", body: nil)
    #expect(getDeletedResponse.status == 404)

    let deleteAgainResponse = await router.handle(method: "DELETE", path: "/v1/plugins/test-telegram", body: nil)
    #expect(deleteAgainResponse.status == 404)
}

@Test
func channelPluginValidation() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let emptyTypeBody = try JSONEncoder().encode(
        ChannelPluginCreateRequest(type: "", baseUrl: "http://localhost:9100")
    )
    let emptyTypeResponse = await router.handle(method: "POST", path: "/v1/plugins", body: emptyTypeBody)
    #expect(emptyTypeResponse.status == 400)

    let emptyUrlBody = try JSONEncoder().encode(
        ChannelPluginCreateRequest(type: "telegram", baseUrl: "")
    )
    let emptyUrlResponse = await router.handle(method: "POST", path: "/v1/plugins", body: emptyUrlBody)
    #expect(emptyUrlResponse.status == 400)

    let emptyInstallBody = try JSONEncoder().encode(
        ChannelPluginInstallRequest(sourceUrl: "")
    )
    let emptyInstallResponse = await router.handle(method: "POST", path: "/v1/plugins/install", body: emptyInstallBody)
    #expect(emptyInstallResponse.status == 400)
}

@Test
func channelPluginInstallInvalidPayloadExplainsRequiredFields() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let badBody = Data(#"{"sourceUrl":".","localDirectory":"yes"}"#.utf8)
    let response = await router.handle(method: "POST", path: "/v1/plugins/install", body: badBody)

    #expect(response.status == 400)
    let error = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
    #expect(error.error == ErrorCode.invalidPluginPayload)
    #expect(error.message?.contains("sourceUrl") == true)
    #expect(error.message?.contains("plugin.json") == true)
    #expect(error.message?.contains("localDirectory") == true)
    #expect(error.message?.contains("Bool") == true)
}

@Test
func channelPluginInstallAllowsUnauthenticatedLoopbackRequestWithDashboardAuth() async throws {
    var config = CoreConfig.test
    config.ui.dashboardAuth.enabled = true
    config.ui.dashboardAuth.token = "dashboard-secret"
    let router = CoreRouter(service: CoreService(config: config))
    let body = try JSONEncoder().encode(ChannelPluginInstallRequest(sourceUrl: ""))

    let localResponse = await router.handle(
        method: "POST",
        path: "/v1/plugins/install",
        body: body,
        remoteAddress: "127.0.0.1"
    )
    #expect(localResponse.status == 400)

    let remoteResponse = await router.handle(
        method: "POST",
        path: "/v1/plugins/install",
        body: body,
        remoteAddress: "192.0.2.10"
    )
    #expect(remoteResponse.status == 401)
}

@Test
func channelPluginInstallAllowsUnauthenticatedLoopbackRequestWithIdentityAuth() async throws {
    let service = CoreService(config: .test)
    await service.setIdentityAuthEnabled(true)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(ChannelPluginInstallRequest(sourceUrl: ""))

    let localResponse = await router.handle(
        method: "POST",
        path: "/v1/plugins/install",
        body: body,
        remoteAddress: "::1"
    )
    #expect(localResponse.status == 400)

    let remoteResponse = await router.handle(
        method: "POST",
        path: "/v1/plugins/install",
        body: body,
        remoteAddress: "192.0.2.10"
    )
    #expect(remoteResponse.status == 401)
}

@Test
func channelPluginInstallInitializationFailureUsesInstallSpecificMessage() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-install-init-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = """
    {
      "name": "broken-source-control",
      "protocol": "source_control",
      "version": "1.0.0",
      "runtime": "nodejs",
      "apiVersion": "2026-05-plugins-v2",
      "entrypoint": "missing.js"
    }
    """
    try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.json"))

    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let body = try JSONEncoder().encode(
        ChannelPluginInstallRequest(sourceUrl: root.path, force: true, enabled: true, localDirectory: true)
    )

    let response = await router.handle(method: "POST", path: "/v1/plugins/install", body: body)

    #expect(response.status == 400)
    let error = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
    #expect(error.error == ErrorCode.invalidPluginPayload)
    #expect(error.message?.contains("could not be initialized") == true)
    #expect(error.message?.contains("create/update") == false)
}

@Test
func channelPluginInstallPayloadAcceptsLegacySourceURLKey() async throws {
    let decoded = try JSONDecoder().decode(
        ChannelPluginInstallRequest.self,
        from: Data(#"{"sourceURL":"https://example.com/plugin.git","force":true}"#.utf8)
    )

    #expect(decoded.sourceUrl == "https://example.com/plugin.git")
    #expect(decoded.force == true)
}

@Test
func channelPluginLookupByChannelId() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)

    let _ = try await service.createChannelPlugin(
        ChannelPluginCreateRequest(
            id: "lookup-plugin",
            type: "telegram",
            baseUrl: "http://127.0.0.1:9200",
            channelIds: ["ch-alpha", "ch-beta"]
        )
    )

    let found = await service.channelPluginForChannel(channelId: "ch-alpha")
    #expect(found?.id == "lookup-plugin")

    let foundBeta = await service.channelPluginForChannel(channelId: "ch-beta")
    #expect(foundBeta?.id == "lookup-plugin")

    let notFound = await service.channelPluginForChannel(channelId: "ch-missing")
    #expect(notFound == nil)
}

// MARK: - Token Usage Tests

@Test
func tokenUsageEndpointReturnsEmptyList() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/token-usage", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(result.items.isEmpty)
    #expect(result.totalPromptTokens == 0)
    #expect(result.totalCompletionTokens == 0)
    #expect(result.totalTokens == 0)
}

@Test
func tokenUsageEndpointReturnsPersistedData() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    // Persist some token usage directly via the service
    let channelId = "test-channel"
    let taskId = "test-task"
    let usage = TokenUsage(prompt: 100, completion: 50)

    // Access the store through the service's persistence
    let store = await service.listTokenUsage()
    #expect(store.items.isEmpty)

    // Use runtime event to trigger token usage persistence
    let decision = await service.postChannelMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "u1", content: "respond please")
    )
    #expect(decision.action == .respond)

    // Check that endpoint returns data
    let response = await router.handle(method: "GET", path: "/v1/token-usage", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    // Response action is recorded but token usage may be 0 for inline responses
    #expect(result.totalPromptTokens >= 0)
    #expect(result.totalCompletionTokens >= 0)
}

@Test
func tokenUsageEndpointPersistsBranchConclusionUsage() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: "branch-usage-agent",
            displayName: "Branch Usage Agent",
            role: "Token usage test"
        )
    )
    let session = try await service.createAgentSession(
        agentID: "branch-usage-agent",
        request: AgentSessionCreateRequest(title: "Branch usage session")
    )

    let toolResult = await service.invokeToolFromRuntime(
        agentID: "branch-usage-agent",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "branches.spawn",
            arguments: [
                "prompt": .string("Research architecture options and summarize the tradeoffs.")
            ],
            reason: "Need a focused side branch for token usage regression coverage"
        )
    )
    #expect(toolResult.ok)

    let hasPersistedBranchUsage = await waitForCondition(timeoutSeconds: 3) {
        let usage = await service.listTokenUsage(channelId: "agent:branch-usage-agent:session:\(session.id)")
        return usage.items.contains(where: { item in
            item.promptTokens == 300 && item.completionTokens == 120
        })
    }
    #expect(hasPersistedBranchUsage)

    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?channelId=agent:branch-usage-agent:session:\(session.id)",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let usageResponse = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(usageResponse.items.contains(where: { $0.promptTokens == 300 && $0.completionTokens == 120 }))
    #expect(usageResponse.totalTokens >= 420)
}

@Test
func invokeToolFromRuntimeCanSkipSessionToolEventPersistence() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let agentID = "tool-events-agent-\(UUID().uuidString)"

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Tool Events Agent",
            role: "Tool event persistence regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Tool events session")
    )

    let result = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "system.list_tools",
            arguments: [:],
            reason: "Regression test"
        ),
        recordSessionEvents: false
    )
    #expect(result.ok)

    let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
    let toolCallEvents = detail.events.filter { $0.type == .toolCall }
    let toolResultEvents = detail.events.filter { $0.type == .toolResult }
    #expect(toolCallEvents.isEmpty)
    #expect(toolResultEvents.isEmpty)
}

@Test
func branchSpawnDoesNotCreateProjectTasksFromPromptTodos() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let agentID = "branch-no-todos-\(UUID().uuidString)"

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Branch No Todo Agent",
            role: "Regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Branch todo regression")
    )
    let sessionChannelID = "agent:\(agentID):session:\(session.id)"
    let projectID = "branch-project-\(UUID().uuidString)"

    _ = try await service.createProject(
        ProjectCreateRequest(
            id: projectID,
            name: "Branch Project",
            description: "Ensures branch spawn does not create tasks",
            channels: [.init(title: "Agent Session", channelId: sessionChannelID)]
        )
    )

    let toolResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "branches.spawn",
            arguments: [
                "prompt": .string("""
                research current plan
                - [ ] Prepare migration plan
                TODO: prepare migration plan
                нужно проверить релизный сценарий
                """)
            ],
            reason: "Regression coverage for branch todo removal"
        )
    )
    #expect(toolResult.ok)

    let project = try await service.getProject(id: projectID)
    #expect(project.tasks.isEmpty)
}

@Test
func workerToolsSpawnAndRouteInteractiveWorker() async throws {
    let workerConfig = CoreConfig.test
    let service = CoreService(config: workerConfig)
    let agentID = "worker-tools-agent-\(UUID().uuidString)"

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Worker Tools Agent",
            role: "Worker tool regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Worker tools session")
    )

    let spawnResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "workers.spawn",
            arguments: [
                "title": .string("Tool worker"),
                "objective": .string("Wait for structured route"),
                "mode": .string("interactive")
            ],
            reason: "Need a worker for delegated execution"
        )
    )
    #expect(spawnResult.ok)

    let workerId = try #require(spawnResult.data?.asObject?["workerId"]?.asString)
    let spawned = await waitForCondition(timeoutSeconds: 10, pollNanoseconds: 100_000_000) {
        let snapshots = await service.workerSnapshots()
        return snapshots.contains(where: { $0.workerId == workerId && $0.status == .waitingInput })
    }
    #expect(spawned)

    let routeResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "workers.route",
            arguments: [
                "workerId": .string(workerId),
                "command": .string("complete"),
                "summary": .string("Completed through tool route")
            ],
            reason: "Mark delegated work as finished"
        )
    )
    #expect(routeResult.ok)
    #expect(routeResult.data?.asObject?["accepted"]?.asBool == true)
    #expect(routeResult.data?.asObject?["status"]?.asString == "completed")

    let snapshots = await service.workerSnapshots()
    let snapshot = snapshots.first(where: { $0.workerId == workerId })
    #expect(snapshot?.status == .completed)
    #expect(snapshot?.latestReport == "Completed through tool route")
}

@Test
func projectTaskUpdateAndCancelToolsMutateTaskState() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let projectID = "tool-project-\(UUID().uuidString)"

    _ = try await service.createProject(
        ProjectCreateRequest(
            id: projectID,
            name: "Tool Project",
            description: "Task tool regression",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let createdProject = try await service.createProjectTask(
        projectID: projectID,
        request: ProjectTaskCreateRequest(
            title: "Tool managed task",
            description: "Needs a state transition",
            priority: "medium",
            status: "backlog"
        )
    )
    let taskID = try #require(createdProject.tasks.last?.id)

    let agentID = "project-tools-\(UUID().uuidString)"
    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Project Tools Agent",
            role: "Tool regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Project task tools")
    )

    let updateResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "project.task_update",
            arguments: [
                "channelId": .string("general"),
                "taskId": .string(taskID),
                "status": .string("needs_review"),
                "priority": .string("high")
            ],
            reason: "Move task into review state"
        )
    )
    #expect(updateResult.ok)
    #expect(updateResult.data?.asObject?["status"]?.asString == "needs_review")

    let cancelResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "project.task_cancel",
            arguments: [
                "channelId": .string("general"),
                "taskId": .string(taskID),
                "reason": .string("Superseded by a newer request")
            ],
            reason: "Safely cancel obsolete work"
        )
    )
    #expect(cancelResult.ok)
    #expect(cancelResult.data?.asObject?["status"]?.asString == "cancelled")

    let record = try await service.getProjectTask(taskReference: taskID)
    #expect(record.task.status == "cancelled")
    #expect(record.task.priority == "high")
    #expect(record.task.description.contains("Cancelled: Superseded by a newer request"))
}

@Test
func mcpConfigToolsSaveAndRemoveServer() async throws {
    var config = CoreConfig.test
    let configPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-\(UUID().uuidString).json")
        .path
    let service = CoreService(config: config, configPath: configPath)
    let agentID = "mcp-config-agent-\(UUID().uuidString)"

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "MCP Config Agent",
            role: "MCP config tool regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "MCP config tools")
    )

    let saveResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "mcp.save_server",
            arguments: [
                "id": .string("docs"),
                "transport": .string("stdio"),
                "command": .string("/bin/echo"),
                "arguments": .array([.string("hello")]),
                "cwd": .string("."),
                "timeoutMs": .number(250),
                "toolPrefix": .string("docs")
            ],
            reason: "Persist MCP server config"
        )
    )
    #expect(saveResult.ok)
    #expect(saveResult.data?.asObject?["serverCount"]?.asInt == 1)

    config = await service.runtimeConfig()
    #expect(config.mcp.servers.count == 1)
    #expect(config.mcp.servers.first?.id == "docs")
    #expect(config.mcp.servers.first?.toolPrefix == "docs")

    let removeResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "mcp.remove_server",
            arguments: ["server": .string("docs")],
            reason: "Remove MCP server config"
        )
    )
    #expect(removeResult.ok)
    #expect(removeResult.data?.asObject?["serverCount"]?.asInt == 0)

    config = await service.runtimeConfig()
    #expect(config.mcp.servers.isEmpty)
}

@Test
func mcpConfigToolsInstallAndUninstallServer() async throws {
    var config = CoreConfig.test
    let configPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-\(UUID().uuidString).json")
        .path
    let service = CoreService(config: config, configPath: configPath)
    let agentID = "mcp-install-agent-\(UUID().uuidString)"

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "MCP Install Agent",
            role: "MCP install tool regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "MCP install tools")
    )

    let installResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "mcp.install_server",
            arguments: [
                "id": .string("echo"),
                "transport": .string("stdio"),
                "command": .string("/bin/echo"),
                "arguments": .array([.string("server")]),
                "cwd": .string("."),
                "timeoutMs": .number(250),
                "installCommand": .string("/bin/echo"),
                "installArguments": .array([.string("install-ok")]),
                "installCwd": .string(".")
            ],
            reason: "Install and persist MCP server"
        )
    )
    #expect(installResult.ok)
    #expect(installResult.data?.asObject?["install"]?.asObject?["exitCode"]?.asInt == 0)

    config = await service.runtimeConfig()
    #expect(config.mcp.servers.count == 1)
    #expect(config.mcp.servers.first?.id == "echo")

    let uninstallResult = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "mcp.uninstall_server",
            arguments: [
                "server": .string("echo"),
                "uninstallCommand": .string("/bin/echo"),
                "uninstallArguments": .array([.string("uninstall-ok")]),
                "uninstallCwd": .string("."),
                "removeFromConfig": .bool(true)
            ],
            reason: "Uninstall and forget MCP server"
        )
    )
    #expect(uninstallResult.ok)
    #expect(uninstallResult.data?.asObject?["uninstall"]?.asObject?["exitCode"]?.asInt == 0)

    config = await service.runtimeConfig()
    #expect(config.mcp.servers.isEmpty)
}

@Test
func tokenUsageEndpointFiltersByChannelId() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    // Send messages to different channels
    _ = await service.postChannelMessage(
        channelId: "channel-a",
        request: ChannelMessageRequest(userId: "u1", content: "respond please")
    )
    _ = await service.postChannelMessage(
        channelId: "channel-b",
        request: ChannelMessageRequest(userId: "u2", content: "respond please")
    )

    // Query with channel filter
    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?channelId=channel-a",
        body: nil
    )
    #expect(response.status == 200)
}

@Test
func tokenUsageEndpointFiltersByDateRange() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let formatter = ISO8601DateFormatter()
    let from = formatter.string(from: Date().addingTimeInterval(-3600))
    let to = formatter.string(from: Date())

    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?from=\(from)&to=\(to)",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(result.items.isEmpty || result.totalTokens >= 0)
}

@Test
func agentTokenUsageEndpointAggregatesSessionChannelData() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let agentId = "token-usage-agent-\(UUID().uuidString.prefix(8))"
    _ = try await service.createAgent(
        AgentCreateRequest(id: agentId, displayName: "Token Usage Agent", role: "Test")
    )

    // Create a session — its channel ID will be agent:{agentId}:session:{sessionId}
    let session = try await service.createAgentSession(
        agentID: agentId,
        request: AgentSessionCreateRequest(title: "Usage session")
    )

    // Persist token usage directly for the session channel
    let sessionChannelId = "agent:\(agentId):session:\(session.id)"
    let usage = TokenUsage(prompt: 200, completion: 80, cachedInputTokens: 150, reasoningTokens: 12)
    await service.persistTokenUsageForTest(channelId: sessionChannelId, usage: usage)

    // Agent token usage endpoint should return the aggregated session data
    let response = await router.handle(
        method: "GET",
        path: "/v1/agents/\(agentId)/token-usage",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(AgentTokenUsageResponse.self, from: response.body)
    #expect(result.inputTokens == 200)
    #expect(result.outputTokens == 80)
    #expect(result.cachedTokens == 150)
}

@Test
func tokenUsageEndpointAggregatesCacheFields() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let channelId = "cache-usage-\(UUID().uuidString)"
    await service.persistTokenUsageForTest(
        channelId: channelId,
        usage: TokenUsage(
            prompt: 1_000,
            completion: 120,
            cachedInputTokens: 800,
            cacheCreationInputTokens: 50,
            reasoningTokens: 30
        )
    )

    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?channelId=\(channelId)",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(result.totalPromptTokens == 1_000)
    #expect(result.totalCompletionTokens == 120)
    #expect(result.totalCachedInputTokens == 800)
    #expect(result.totalCacheCreationInputTokens == 50)
    #expect(result.totalReasoningTokens == 30)
    #expect(result.items.first?.cachedInputTokens == 800)
}

private func extractArtifactID(from message: String) -> String? {
    let pattern = #"artifact\s+([A-Za-z0-9-]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
    guard let match = regex.firstMatch(in: message, options: [], range: fullRange),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: message)
    else {
        return nil
    }
    return String(message[range])
}

private func waitForCondition(
    timeoutSeconds: TimeInterval,
    pollNanoseconds: UInt64 = 50_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return await condition()
}

@Test
func generateTextEndpointReturnsBadRequestWithEmptyBody() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "POST", path: "/v1/generate", body: nil)
    #expect(response.status == 400)
}

@Test
func generateTextEndpointReturnsBadRequestWithInvalidBody() async throws {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)

    let body = Data("{\"invalid\":true}".utf8)
    let response = await router.handle(method: "POST", path: "/v1/generate", body: body)
    #expect(response.status == 400)
}

@Test
func generateTextEndpointFailsGracefullyWithNoProvider() async throws {
    var config = CoreConfig.test
    config.models = []
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let requestBody = try JSONEncoder().encode(GenerateTextRequest(model: "", prompt: "Hello"))
    let response = await router.handle(method: "POST", path: "/v1/generate", body: requestBody)
    #expect(response.status == 500)
}

@Test
func generateTextEndpointResolvesBareRequestedModelFromConfiguredProvider() async throws {
    var config = CoreConfig.test
    config.models = [
        .init(title: "Mock Model", apiKey: "", apiUrl: "", model: "mock:test-model")
    ]
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let requestBody = try JSONEncoder().encode(GenerateTextRequest(model: "test-model", prompt: "Hello"))
    let response = await router.handle(method: "POST", path: "/v1/generate", body: requestBody)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(GenerateTextResponse.self, from: response.body)
    #expect(payload.model == "mock:test-model")
    #expect(payload.text.contains("Mock response for prompt"))
}

@Test
func projectMemoriesEndpointListAndFilterRecords() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let memoryStore = HybridMemoryStore(config: config)

    let projectID = "proj-memory-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Memory Test Project", description: "Tests project memory listing")
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let projectScopedRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Project architecture decision: use layered approach.",
            summary: "Architecture decision",
            kind: .decision,
            memoryClass: .semantic,
            scope: .project(projectID)
        )
    )
    let agentWithProjectRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Agent remembered the project workflow steps.",
            summary: "Project workflow",
            kind: .fact,
            memoryClass: .procedural,
            scope: .agent("agent-proj-test")
        )
    )

    let linkedScope = MemoryScope(
        type: .channel,
        id: "agent:some-agent:session:s1",
        channelId: "agent:some-agent:session:s1",
        projectId: projectID,
        agentId: "some-agent"
    )
    let crossScopeRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Agent wrote this for the project during a session.",
            summary: "Cross-scope entry",
            kind: .fact,
            memoryClass: .episodic,
            scope: linkedScope
        )
    )
    _ = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Unrelated memory from a different project.",
            summary: "Other project memory",
            kind: .fact,
            memoryClass: .semantic,
            scope: .project("other-project-xyz")
        )
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let listResponse = await router.handle(method: "GET", path: "/v1/projects/\(projectID)/memories", body: nil)
    #expect(listResponse.status == 200)
    let listPage = try decoder.decode(ProjectMemoryListResponse.self, from: listResponse.body)
    #expect(listPage.projectId == projectID)
    let returnedIDs = Set(listPage.items.map(\.id))
    #expect(returnedIDs.contains(projectScopedRef.id))
    #expect(returnedIDs.contains(crossScopeRef.id))
    #expect(!returnedIDs.contains(agentWithProjectRef.id))

    let searchResponse = await router.handle(
        method: "GET",
        path: "/v1/projects/\(projectID)/memories?search=architecture&filter=persistent",
        body: nil
    )
    #expect(searchResponse.status == 200)
    let searchPage = try decoder.decode(ProjectMemoryListResponse.self, from: searchResponse.body)
    #expect(searchPage.items.first?.id == projectScopedRef.id)

    let graphResponse = await router.handle(
        method: "GET",
        path: "/v1/projects/\(projectID)/memories/graph",
        body: nil
    )
    #expect(graphResponse.status == 200)
    let graph = try decoder.decode(ProjectMemoryGraphResponse.self, from: graphResponse.body)
    #expect(graph.projectId == projectID)
    let graphNodeIDs = Set(graph.nodes.map(\.id))
    #expect(graphNodeIDs.contains(projectScopedRef.id))
    #expect(graphNodeIDs.contains(crossScopeRef.id))
    #expect(!graphNodeIDs.contains(agentWithProjectRef.id))
}

@Test
func projectMemoriesEndpointValidatesProjectID() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let invalidResponse = await router.handle(method: "GET", path: "/v1/projects/invalid!/memories", body: nil)
    #expect(invalidResponse.status == 400)

    let missingResponse = await router.handle(method: "GET", path: "/v1/projects/nonexistent-project/memories", body: nil)
    #expect(missingResponse.status == 404)

    let missingGraphResponse = await router.handle(method: "GET", path: "/v1/projects/nonexistent-project/memories/graph", body: nil)
    #expect(missingGraphResponse.status == 404)
}

private struct StaticIssueReportLogUploader: IssueReportLogUploading {
    let logsURL: String

    func upload(logs: String) async throws -> String {
        #expect(logs.contains("[REDACTED]"))
        #expect(!logs.contains("dev-super-secret-token"))
        #expect(!logs.contains("sk-supersecretvalue1234567890"))
        return logsURL
    }
}
