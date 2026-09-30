import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols
import SloppyNodeCore

extension CoreService {
    enum MeshCoreProxyError: Error, LocalizedError {
        case missingLocalNodeConfig
        case missingMeshUserContext
        case invalidResponse(String)
        case remoteError(String)

        var errorDescription: String? {
            switch self {
            case .missingLocalNodeConfig:
                return "Local node has not joined a remote mesh."
            case .missingMeshUserContext:
                return "Missing x-sloppy-user-context header in login/password mode."
            case .invalidResponse(let message):
                return "Invalid mesh Core response: \(message)"
            case .remoteError(let message):
                return message
            }
        }
    }

    public func getMeshState() async throws -> MeshState {
        var state = try nodeMeshStore.load()
        if let config = try? nodeConfigStore.load() {
            if let relayURL = config.relayURL,
               !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let coordinatorState = try? await Self.fetchMeshState(from: relayURL) {
                state = coordinatorState
            }
            if let networkId = config.networkId, !networkId.isEmpty {
                state.networkId = networkId
            }
            if let networkName = config.networkName, !networkName.isEmpty {
                state.networkName = networkName
            }
            state.localNode = MeshLocalNodeRecord(
                id: config.identity.nodeId,
                name: config.identity.name,
                publicKey: config.identity.publicKey,
                roles: config.identity.roles,
                capabilities: config.identity.capabilities,
                encryptionPublicKey: config.identity.encryptionPublicKey,
                encryptionKeySignature: config.identity.encryptionKeySignature,
                relayURL: config.relayURL,
                networkId: config.networkId,
                networkName: config.networkName
            )
        }
        return state
    }

    public func exportMeshDirectorySnapshot() async throws -> MeshDirectorySnapshotPayload {
        try nodeMeshStore.exportCoordinatorDirectorySnapshot()
    }

    public func applyMeshDirectorySnapshot(_ payload: MeshDirectorySnapshotPayload) async throws {
        try nodeMeshStore.applyUserDirectorySnapshot(payload)
    }

    public func applyMeshDirectoryDelta(_ payload: MeshDirectoryDeltaPayload) async throws {
        try nodeMeshStore.applyUserDirectoryDelta(payload)
    }

    public func applyMeshDirectoryRevocation(_ payload: MeshDirectoryRevocationPayload) async throws {
        try nodeMeshStore.applyUserDirectoryRevocation(payload)
    }

    private static func fetchMeshState(from relayURL: String) async throws -> MeshState {
        let base = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v1/node/mesh") else {
            throw MeshCoreProxyError.invalidResponse("invalid relay URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MeshCoreProxyError.invalidResponse("coordinator state unavailable")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeshState.self, from: data)
    }

    func startNodeMeshClientIfConfigured() async {
        guard nodeMeshClientTask == nil,
              let config = try? nodeConfigStore.load(),
              let relayURL = config.relayURL,
              !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        if let relayState = try? await Self.fetchMeshState(from: relayURL) {
            for node in relayState.nodes {
                _ = try? nodeMeshStore.upsertNodeRecord(node, auditAction: "node.directory.sync")
            }
        }
        var coreConfig = config
        coreConfig.identity.capabilities = Array(Set(
            coreConfig.identity.capabilities + ["sloppy.core.remote", "sloppy.terminal.control"]
        )).sorted()
        _ = try? nodeMeshStore.upsertNodeRecord(
            MeshNodeRecord(
                id: coreConfig.identity.nodeId,
                name: coreConfig.identity.name,
                publicKey: coreConfig.identity.publicKey,
                roles: coreConfig.identity.roles,
                status: .online,
                capabilities: coreConfig.identity.capabilities,
                encryptionPublicKey: coreConfig.identity.encryptionPublicKey,
                encryptionKeySignature: coreConfig.identity.encryptionKeySignature
            ),
            auditAction: "node.local-core.grant"
        )
        let client = NodeMeshClient(
            config: coreConfig,
            meshStore: nodeMeshStore,
            onEnvelope: { [weak self] envelope in
                guard let self else { return [] }
                return await self.handleMeshMailboxEnvelope(envelope)
            },
            rpcHandler: { [weak self] envelope, method, params in
                guard let self else { return nil }
                return await self.handleMeshCoreHTTPRPC(envelope: envelope, method: method, params: params)
            }
        )
        nodeMeshClient = client
        nodeMeshClientTask = Task {
            do {
                try await client.run(relayURL: relayURL)
            } catch is CancellationError {
            } catch {
                logger.warning("node.mesh.client.stopped", metadata: ["error": .string(String(describing: error))])
            }
        }
    }

    func proxyMeshCoreHTTPRequest(
        nodeId: String,
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        localAuthorizationHeader: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CoreRouterResponse {
        let config: NodeConfig
        do {
            config = try nodeConfigStore.load()
        } catch {
            throw MeshCoreProxyError.missingLocalNodeConfig
        }
        var forwardedHeaders = headers.reduce(into: [String: String]()) { partial, item in
            partial[item.key.lowercased()] = item.value
        }
        if await isLoginPasswordMode(), meshUserIdHeader(from: forwardedHeaders) == nil {
            throw MeshCoreProxyError.missingMeshUserContext
        }
        // The coordinator already authenticated the client. Never forward either the
        // client token or this node's dashboard token to another machine.
        forwardedHeaders["authorization"] = nil
        if nodeId == config.identity.nodeId {
            // Recheck the caller against local route permissions without exporting its token.
            forwardedHeaders["authorization"] = localAuthorizationHeader
            return await CoreRouter(service: self).handle(
                method: method,
                path: path,
                body: body,
                headers: forwardedHeaders
            )
        }
        let client: NodeMeshClient
        if let connectedClient = nodeMeshClient {
            client = connectedClient
        } else {
            client = NodeMeshClient(config: config, meshStore: nodeMeshStore)
        }
        var params: [String: JSONValue] = [
            "method": .string(method),
            "path": .string(path),
        ]
        if !forwardedHeaders.isEmpty {
            params["headers"] = .object(forwardedHeaders.mapValues(JSONValue.string))
        }
        if let body {
            params["bodyBase64"] = .string(body.base64EncodedString())
        }
        let response = try await client.sendRPCRequest(
            to: nodeId,
            method: "core.http",
            params: .object(params),
            timeout: timeout
        )
        return try decodeMeshCoreHTTPResponse(response)
    }

    private func decodeMeshCoreHTTPResponse(_ envelope: MeshEnvelope) throws -> CoreRouterResponse {
        guard let object = envelope.payload.asObject else {
            throw MeshCoreProxyError.invalidResponse("payload object missing")
        }
        if object["ok"]?.asBool == false {
            let error = object["error"]?.asObject
            let message = error?["message"]?.asString ?? "Remote mesh Core request failed."
            throw MeshCoreProxyError.remoteError(message)
        }
        guard let result = object["result"]?.asObject,
              let status = result["status"]?.asInt,
              let bodyBase64 = result["bodyBase64"]?.asString,
              let body = Data(base64Encoded: bodyBase64)
        else {
            throw MeshCoreProxyError.invalidResponse("result status/body missing")
        }
        return CoreRouterResponse(
            status: status,
            body: body,
            contentType: result["contentType"]?.asString ?? "application/json"
        )
    }

    public func listMeshNodes() throws -> [MeshNodeRecord] {
        try nodeMeshStore.listNodes()
    }

    public func configureMeshNetwork(_ request: MeshNetworkUpdateRequest) throws -> MeshState {
        try nodeMeshStore.createNetwork(id: request.id, name: request.name)
    }

    public func createMeshInvite(_ request: MeshInviteCreateRequest) throws -> MeshInvite {
        let relayURL = request.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.relayURL
            : currentConfig.nodeMeshPublicURL
        return try nodeMeshStore.createInvite(
            networkId: request.networkId,
            name: request.name,
            roles: request.roles,
            capabilities: request.capabilities,
            ttlSeconds: request.ttlSeconds,
            relayURL: relayURL,
            nodeId: request.nodeId,
            publicKey: request.publicKey
        )
    }

    public func deleteMeshInvite(token: String) throws {
        try nodeMeshStore.revokeInvite(token: token, actor: "api")
    }

    public func acceptMeshInvite(_ request: MeshInviteAcceptRequest) throws -> MeshNodeRecord {
        do {
            if let nodeId = request.nodeId,
               let publicKey = request.publicKey {
                let identity = NodeIdentity(
                    nodeId: nodeId,
                    name: normalizedMeshNodeName(request.name, fallback: nodeId),
                    publicKey: publicKey,
                    privateKey: "",
                    roles: request.roles ?? ["worker"],
                    capabilities: request.capabilities ?? ["run_agent", "git"],
                    encryptionPublicKey: request.encryptionPublicKey,
                    encryptionKeySignature: request.encryptionKeySignature
                )
                return try nodeMeshStore.consumeInvite(token: request.token, identity: identity, endpoint: request.endpoint)
            }
            return try nodeMeshStore.acceptInvite(token: request.token, endpoint: request.endpoint)
        } catch NodeMeshStoreError.inviteMissing {
            if let bundle = try? MeshInviteBundle.parse(request.token) {
                throw NodeMeshStoreError.inviteWrongCoordinator(bundle.relayURL)
            }
            throw NodeMeshStoreError.inviteMissing
        }
    }

    private func normalizedMeshNodeName(_ name: String?, fallback: String) -> String {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return fallback
        }
        return trimmed
    }

    public func joinRemoteMesh(_ request: MeshRemoteJoinRequest) async throws -> MeshRemoteJoinResult {
        let joiner = NodeMeshRemoteJoiner(
            configStore: nodeConfigStore,
            acceptInvite: { url, acceptRequest in
                try await Self.postMeshInviteAccept(to: url, request: acceptRequest)
            }
        )
        let result = try await joiner.join(request)
        await startNodeMeshClientIfConfigured()
        return result
    }

    private static func postMeshInviteAccept(to url: URL, request: MeshInviteAcceptRequest) async throws -> MeshNodeRecord {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        urlRequest.httpBody = try encoder.encode(request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MeshRemoteJoinError.coordinatorUnreachable(url.absoluteString)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeshNodeRecord.self, from: data)
    }

    public func registerMeshNode(_ request: MeshNodeRegisterRequest) throws -> MeshNodeRecord {
        try nodeMeshStore.upsertNodeRecord(
            MeshNodeRecord(
                id: request.id,
                name: request.name,
                publicKey: request.publicKey,
                roles: request.roles,
                endpoint: request.endpoint,
                status: .offline,
                capabilities: request.capabilities
            ),
            auditAction: "node.register.api"
        )
    }

    public func deleteMeshNode(id: String) throws {
        try nodeMeshStore.removeNodeRecord(nodeId: id, actor: "api")
    }

    public func listMeshSharedProjects() throws -> [SharedProjectRecord] {
        try nodeMeshStore.listSharedProjects()
    }

    public func createMeshSharedProject(_ request: MeshSharedProjectCreateRequest) throws -> SharedProjectRecord {
        try nodeMeshStore.createSharedProject(
            id: request.id,
            name: request.name,
            repoUrl: request.repoUrl,
            defaultBranch: request.defaultBranch
        )
    }

    public func deleteMeshSharedProject(id: String) throws {
        try nodeMeshStore.removeSharedProject(projectIdOrName: id, actor: "api")
    }

    public func attachMeshSharedProjectMember(
        projectId: String,
        request: MeshSharedProjectMemberRequest
    ) throws -> SharedProjectRecord {
        try nodeMeshStore.attachMember(
            projectIdOrName: projectId,
            nodeId: request.nodeId,
            localRepoPath: request.localRepoPath,
            role: request.role,
            actorId: request.actorId,
            permissions: request.permissions
        )
    }

    public func updateMeshSharedProject(
        id: String,
        request: MeshSharedProjectUpdateRequest
    ) throws -> SharedProjectRecord {
        try nodeMeshStore.updateSharedProject(
            projectIdOrName: id,
            name: request.name,
            repoUrl: request.repoUrl,
            defaultBranch: request.defaultBranch,
            policies: request.policies,
            actor: "api"
        )
    }

    public func listMeshTasks(projectId: String? = nil) throws -> [MeshTaskRecord] {
        try nodeMeshStore.listTasks(projectIdOrName: projectId)
    }

    public func listMeshAuditLog() throws -> [MeshAuditLogEntry] {
        try nodeMeshStore.load().auditLog.sorted { $0.time > $1.time }
    }

    public func createMeshTask(_ request: MeshTaskCreateRequest) throws -> MeshTaskRecord {
        try nodeMeshStore.dispatchTask(
            projectIdOrName: request.projectId,
            title: request.title,
            assignedNodeId: request.assignedNodeId
        )
    }

    public func updateMeshTask(id: String, request: MeshTaskUpdateRequest) throws -> MeshTaskRecord {
        try nodeMeshStore.updateTaskStatus(
            taskId: id,
            projectIdOrName: request.projectId,
            status: request.status,
            actor: "api",
            branch: request.branch,
            commit: request.commit,
            summary: request.summary
        )
    }

    func handleMeshCoreHTTPRPC(envelope: MeshEnvelope, method: String, params: JSONValue) async -> JSONValue {
        guard method == "core.http" else {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "unknown_method",
                message: "Unknown mesh Core RPC method."
            )
        }
        guard let source = try? nodeMeshStore.listNodes().first(where: { $0.id == envelope.from }),
              source.capabilities.contains("sloppy.core.remote") else {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "mesh_forbidden",
                message: "Source node does not have a full Core access grant."
            )
        }
        guard let object = params.asObject else {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "invalid_params",
                message: "core.http params object is required."
            )
        }
        let httpMethod = object["method"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "GET"
        guard let path = object["path"]?.asString,
              path.hasPrefix("/") else {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "invalid_params",
                message: "core.http path must start with /."
            )
        }
        guard !path.hasPrefix("/v1/node/mesh/nodes/") else {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "mesh_proxy_chaining_forbidden",
                message: "Nested mesh proxying is forbidden."
            )
        }

        let headers = (object["headers"]?.asObject ?? [:]).reduce(into: [String: String]()) { partial, item in
            if let value = item.value.asString {
                partial[item.key.lowercased()] = value
            }
        }

        if await isLoginPasswordMode(), meshUserIdHeader(from: headers) == nil {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "mesh_missing_user_context",
                message: "Missing x-sloppy-user-context header in login/password mode."
            )
        }

        let body: Data?
        if let bodyBase64 = object["bodyBase64"]?.asString, !bodyBase64.isEmpty {
            body = Data(base64Encoded: bodyBase64)
        } else {
            body = nil
        }

        let router = CoreRouter(service: self)
        let response = await router.handle(
            method: httpMethod,
            path: path,
            body: body,
            headers: headers,
            remoteAddress: "mesh-authorized:\(envelope.from)"
        )
        guard response.sseStream == nil else {
            return meshCoreRPCErrorPayload(
                requestId: envelope.id,
                method: method,
                code: "stream_unsupported",
                message: "core.http does not support streaming responses."
            )
        }

        return .object([
            "requestId": .string(envelope.id),
            "method": .string(method),
            "ok": .bool(response.status < 400),
            "result": .object([
                "status": .number(Double(response.status)),
                "contentType": .string(response.contentType),
                "bodyBase64": .string(response.body.base64EncodedString()),
            ]),
        ])
    }

    private func isLoginPasswordMode() async -> Bool {
        if await identityAuthEnabled() { return true }
        let status = dashboardAuthStatus()
        return status.enabled && !status.acceptsLegacyToken
    }

    private func meshUserIdHeader(from headers: [String: String]) -> String? {
        let expectedKey = "x-sloppy-user-context"
        for (key, value) in headers where key.lowercased() == expectedKey {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func handleMeshMailboxEnvelope(_ envelope: MeshEnvelope) async -> [MeshEnvelope] {
        if envelope.type == .streamOpen || envelope.type == .streamChunk || envelope.type == .streamClose {
            return await handleMeshStreamEnvelope(envelope)
        }
        guard envelope.type == .eventPublish,
              envelope.payload.asObject?["kind"]?.asString == "agent.browser_context_message",
              let requestValue = envelope.payload.asObject?["request"]
        else {
            return []
        }
        let localNodeId = envelope.to ?? ""
        if (try? nodeMeshStore.load().processedEnvelopeIDs.contains(envelope.id)) == true {
            return [meshMailboxAck(for: envelope, from: localNodeId)]
        }
        do {
            let request = try JSONValueCoder.decode(BrowserContextMessageRequest.self, from: requestValue)
            _ = try await postBrowserContextMessage(request)
            try nodeMeshStore.recordProcessedEnvelope(id: envelope.id, processedBy: localNodeId)
            return [meshMailboxAck(for: envelope, from: localNodeId)]
        } catch {
            logger.warning("node.mesh.mailbox.browser_context.failed", metadata: [
                "envelope": .string(envelope.id),
                "from": .string(envelope.from),
                "error": .string(String(describing: error)),
            ])
            return []
        }
    }

    func openMeshTerminalStream(
        nodeID: String,
        startMessage: DashboardTerminalClientMessage
    ) async throws -> NodeMeshStream {
        guard let nodeMeshClient else {
            throw MeshCoreProxyError.missingLocalNodeConfig
        }
        return try await nodeMeshClient.openStream(
            to: nodeID,
            kind: "dashboard.terminal",
            params: try JSONValueCoder.encode(startMessage)
        )
    }

    func openMeshAgentSessionStream(
        nodeID: String,
        agentID: String,
        sessionID: String
    ) async throws -> NodeMeshStream {
        guard let nodeMeshClient else {
            throw MeshCoreProxyError.missingLocalNodeConfig
        }
        return try await nodeMeshClient.openStream(
            to: nodeID,
            kind: "agent.session",
            params: .object([
                "agentId": .string(agentID),
                "sessionId": .string(sessionID),
            ])
        )
    }

    func closeMeshAgentSessionStream(streamID: String, nodeID: String) async {
        try? await nodeMeshClient?.closeStream(streamID: streamID, to: nodeID)
    }

    func sendMeshTerminalFrame(
        streamID: String,
        nodeID: String,
        message: DashboardTerminalClientMessage
    ) async throws {
        guard let nodeMeshClient else {
            throw MeshCoreProxyError.missingLocalNodeConfig
        }
        try await nodeMeshClient.sendStreamChunk(
            streamID: streamID,
            to: nodeID,
            data: try JSONValueCoder.encode(message)
        )
    }

    func closeMeshTerminalStream(streamID: String, nodeID: String) async {
        try? await nodeMeshClient?.closeStream(streamID: streamID, to: nodeID)
    }

    private func handleMeshStreamEnvelope(_ envelope: MeshEnvelope) async -> [MeshEnvelope] {
        guard let object = envelope.payload.asObject,
              let streamID = object["streamId"]?.asString else {
            return []
        }

        guard let source = try? nodeMeshStore.listNodes().first(where: { $0.id == envelope.from }),
              source.capabilities.contains("sloppy.core.remote") else {
            return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: "Source node is not authorized for remote Core streams.")]
        }

        switch envelope.type {
        case .streamOpen:
            guard meshTerminalForwardTasks[streamID] == nil,
                  meshTerminalSessionIDs[streamID] == nil else {
                return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: "Stream id is already active.")]
            }
            if object["kind"]?.asString == "launch.preview" {
                guard let params = object["params"]?.asObject,
                      let agentID = params["agentId"]?.asString,
                      let sessionID = params["sessionId"]?.asString,
                      let runID = params["runId"]?.asString else { return [] }
                do {
                    _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
                    _ = try await launches.previewPort(agentID: agentID, sessionID: sessionID, runID: runID)
                } catch { return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: error.localizedDescription)] }
                let input = AsyncStream<String>.makeStream()
                meshLaunchPreviewInputs[streamID] = input.continuation
                meshLaunchPreviewOwners[streamID] = envelope.from
                let target = envelope.from
                let connection = WebSocketConnectionContext(
                    sendText: { [weak self] text in
                        do { try await self?.sendMeshLaunchPreview(nodeID: target, streamID: streamID, data: text); return true }
                        catch { return false }
                    },
                    close: { [weak self] in await self?.closeMeshAgentSessionStream(streamID: streamID, nodeID: target) },
                    incomingMessages: { input.stream }
                )
                meshTerminalForwardTasks[streamID] = Task { [weak self] in
                    await self?.handleLaunchPreview(agentID: agentID, sessionID: sessionID, runID: runID, connection: connection)
                    await self?.finishMeshLaunchPreview(streamID: streamID)
                }
                return []
            }
            if object["kind"]?.asString == "agent.session" {
                guard let params = object["params"]?.asObject,
                      let agentID = params["agentId"]?.asString,
                      let sessionID = params["sessionId"]?.asString else {
                    return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: "Invalid agent session stream request.")]
                }
                do {
                    let updates = try streamAgentSessionEvents(agentID: agentID, sessionID: sessionID)
                    let targetNodeID = envelope.from
                    meshTerminalForwardTasks[streamID] = Task { [weak self] in
                        guard let self else { return }
                        for await update in updates {
                            guard let value = try? JSONValueCoder.encode(update) else { continue }
                            try? await self.nodeMeshClient?.sendStreamChunk(
                                streamID: streamID,
                                to: targetNodeID,
                                data: value
                            )
                        }
                        try? await self.nodeMeshClient?.closeStream(streamID: streamID, to: targetNodeID)
                        await self.finishMeshForwardedStream(streamID: streamID)
                    }
                    return []
                } catch {
                    return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: error.localizedDescription)]
                }
            }

            guard object["kind"]?.asString == "dashboard.terminal",
                  source.capabilities.contains("sloppy.terminal.control"),
                  let params = object["params"],
                  let start = try? JSONValueCoder.decode(DashboardTerminalClientMessage.self, from: params),
                  let cols = start.cols,
                  let rows = start.rows else {
                return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: "Invalid terminal stream request.")]
            }
            do {
                let terminal = try await startDashboardTerminalSession(
                    projectID: start.projectId,
                    cwd: start.cwd,
                    cols: cols,
                    rows: rows,
                    remoteAddress: "mesh:\(envelope.from)",
                    allowTrustedMesh: true
                )
                meshTerminalSessionIDs[streamID] = terminal.sessionID
                let targetNodeID = envelope.from
                meshTerminalForwardTasks[streamID] = Task { [weak self] in
                    guard let self else { return }
                    for await event in terminal.events {
                        let message: DashboardTerminalServerMessage
                        switch event {
                        case .output(let data):
                            message = DashboardTerminalServerMessage(type: "output", sessionId: terminal.sessionID, data: data)
                        case .exit(let code):
                            message = DashboardTerminalServerMessage(type: "exit", sessionId: terminal.sessionID, exitCode: code)
                        case .error(let code, let detail):
                            message = DashboardTerminalServerMessage(type: "error", sessionId: terminal.sessionID, code: code, message: detail)
                        case .closed:
                            message = DashboardTerminalServerMessage(type: "closed", sessionId: terminal.sessionID)
                        }
                        guard let value = try? JSONValueCoder.encode(message) else { continue }
                        try? await self.nodeMeshClient?.sendStreamChunk(
                            streamID: streamID,
                            to: targetNodeID,
                            data: value
                        )
                    }
                    try? await self.nodeMeshClient?.closeStream(
                        streamID: streamID,
                        to: targetNodeID
                    )
                    await self.finishMeshForwardedStream(streamID: streamID)
                }
                let ready = DashboardTerminalServerMessage(
                    type: "ready",
                    sessionId: terminal.sessionID,
                    cwd: terminal.cwd,
                    shell: terminal.shell,
                    pid: terminal.pid
                )
                return [meshStreamChunk(for: envelope, streamID: streamID, data: try JSONValueCoder.encode(ready))]
            } catch {
                return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: error.localizedDescription)]
            }

        case .streamChunk:
            if let owner = meshLaunchPreviewOwners[streamID], owner != envelope.from { return [] }
            if let input = meshLaunchPreviewInputs[streamID], let text = object["data"]?.asString {
                input.yield(text); return []
            }
            guard let sessionID = meshTerminalSessionIDs[streamID],
                  let data = object["data"],
                  let message = try? JSONValueCoder.decode(DashboardTerminalClientMessage.self, from: data) else {
                return []
            }
            do {
                switch message.type.lowercased() {
                case "input":
                    try await writeDashboardTerminalInput(sessionID: sessionID, data: message.data ?? "")
                case "resize":
                    guard let cols = message.cols, let rows = message.rows else { return [] }
                    try await resizeDashboardTerminalSession(sessionID: sessionID, cols: cols, rows: rows)
                case "close":
                    await closeDashboardTerminalSession(sessionID: sessionID)
                    meshTerminalSessionIDs[streamID] = nil
                    meshTerminalForwardTasks[streamID]?.cancel()
                    meshTerminalForwardTasks[streamID] = nil
                default:
                    break
                }
            } catch {
                return [meshStreamClose(for: envelope, streamID: streamID, ok: false, message: error.localizedDescription)]
            }
            return []

        case .streamClose:
            if let owner = meshLaunchPreviewOwners[streamID], owner != envelope.from { return [] }
            meshLaunchPreviewOwners[streamID] = nil
            meshLaunchPreviewInputs.removeValue(forKey: streamID)?.finish()
            if let sessionID = meshTerminalSessionIDs.removeValue(forKey: streamID) {
                await closeDashboardTerminalSession(sessionID: sessionID)
            }
            meshTerminalForwardTasks.removeValue(forKey: streamID)?.cancel()
            return []

        default:
            return []
        }
    }

    private func finishMeshForwardedStream(streamID: String) async {
        if let sessionID = meshTerminalSessionIDs.removeValue(forKey: streamID) {
            await closeDashboardTerminalSession(sessionID: sessionID)
        }
        meshTerminalForwardTasks[streamID] = nil
    }

    private func meshStreamChunk(for envelope: MeshEnvelope, streamID: String, data: JSONValue) -> MeshEnvelope {
        MeshEnvelope(
            type: .streamChunk,
            from: envelope.to ?? "",
            to: envelope.from,
            payload: .object(["streamId": .string(streamID), "data": data])
        )
    }

    private func meshStreamClose(
        for envelope: MeshEnvelope,
        streamID: String,
        ok: Bool,
        message: String?
    ) -> MeshEnvelope {
        MeshEnvelope(
            type: .streamClose,
            from: envelope.to ?? "",
            to: envelope.from,
            payload: .object([
                "streamId": .string(streamID),
                "ok": .bool(ok),
                "message": message.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private func meshMailboxAck(for envelope: MeshEnvelope, from nodeId: String) -> MeshEnvelope {
        MeshEnvelope(
            type: .eventAck,
            from: nodeId,
            to: envelope.from,
            payload: .object(["messageId": .string(envelope.id)])
        )
    }

    private func meshCoreRPCErrorPayload(requestId: String, method: String, code: String, message: String) -> JSONValue {
        .object([
            "requestId": .string(requestId),
            "method": .string(method),
            "ok": .bool(false),
            "error": .object([
                "code": .string(code),
                "message": .string(message),
            ]),
        ])
    }
}
