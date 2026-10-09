import Foundation
import Protocols

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NodeMeshClientError: LocalizedError, Equatable {
    case invalidRelayURL(String)
    case unsupportedRelayScheme(String)
    case missingRelayURL
    case relayNotConnected
    case insecureRelayURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRelayURL(let value):
            "Invalid relay URL: \(value)"
        case .unsupportedRelayScheme(let scheme):
            "Unsupported relay URL scheme: \(scheme)"
        case .missingRelayURL:
            "Mesh relay URL is required."
        case .relayNotConnected:
            "Mesh relay connection is not ready."
        case .insecureRelayURL(let value):
            "Public mesh relays must use TLS (https/wss). HTTP/WS is supported on localhost and private IPv4 LAN addresses: \(value)"
        }
    }
}

public actor NodeMeshClient {
    public typealias EnvelopeHandler = @Sendable (MeshEnvelope) async -> [MeshEnvelope]
    public typealias RPCRequestHandler = @Sendable (MeshEnvelope, String, JSONValue) async -> JSONValue?

    private let config: NodeConfig
    private let daemon: NodeDaemon
    private let meshStore: NodeMeshStore?
    private let heartbeatInterval: TimeInterval
    private let reconnectDelay: TimeInterval
    private let onEnvelope: EnvelopeHandler?
    private let rpcHandler: RPCRequestHandler?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var isRelayAuthenticated: Bool
    private var isRunLoopActive = false
    private let rpcManager = NodeMeshRPCManager()
    private let streamManager = NodeMeshStreamManager()
    private var seenEncryptedEnvelopeIDs: Set<String> = []
    #if !os(Linux)
    private var activeWebSocketTask: URLSessionWebSocketTask?
    #endif

    public init(
        config: NodeConfig,
        daemon: NodeDaemon? = nil,
        meshStore: NodeMeshStore? = nil,
        heartbeatInterval: TimeInterval = 15,
        reconnectDelay: TimeInterval = 2,
        onEnvelope: EnvelopeHandler? = nil,
        rpcHandler: RPCRequestHandler? = nil
    ) {
        self.config = config
        self.daemon = daemon ?? NodeDaemon(config: config)
        self.meshStore = meshStore
        self.heartbeatInterval = max(1, heartbeatInterval)
        self.reconnectDelay = max(0.25, reconnectDelay)
        self.onEnvelope = onEnvelope
        self.rpcHandler = rpcHandler
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.isRelayAuthenticated = false
    }

    public static func resolveRelayWebSocketURL(_ relayURL: String) throws -> URL {
        guard var components = URLComponents(string: relayURL), let scheme = components.scheme?.lowercased() else {
            throw NodeMeshClientError.invalidRelayURL(relayURL)
        }

        switch scheme {
        case "http":
            guard Self.isLocalRelayHost(components.host) else {
                throw NodeMeshClientError.insecureRelayURL(relayURL)
            }
            components.scheme = "ws"
            components.path = "/v1/node/mesh/ws"
        case "https":
            components.scheme = "wss"
            components.path = "/v1/node/mesh/ws"
        case "ws":
            guard Self.isLocalRelayHost(components.host) else {
                throw NodeMeshClientError.insecureRelayURL(relayURL)
            }
        case "wss":
            break
        default:
            throw NodeMeshClientError.unsupportedRelayScheme(scheme)
        }

        guard let url = components.url else {
            throw NodeMeshClientError.invalidRelayURL(relayURL)
        }
        return url
    }

    private static func isLocalRelayHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if ["localhost", "::1", "[::1]"].contains(host) { return true }
        // Only canonical numeric literals qualify; DNS names and abbreviated or
        // octal IPv4 spellings must not bypass the public transport policy.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let octets = parts.compactMap(UInt8.init)
        guard parts.count == 4, octets.count == 4,
              zip(parts, octets).allSatisfy({ $0.0 == String($0.1) }) else { return false }
        return octets[0] == 127 || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    public static func makeHelloEnvelope(identity: NodeIdentity) -> MeshEnvelope {
        MeshEnvelope(
            type: .nodeHello,
            from: identity.nodeId,
            payload: .object([
                "name": .string(identity.name),
                "publicKey": .string(identity.publicKey),
                "encryptionPublicKey": identity.encryptionPublicKey.map(JSONValue.string) ?? .null,
                "encryptionKeySignature": identity.encryptionKeySignature.map(JSONValue.string) ?? .null,
                "roles": .array(identity.roles.map(JSONValue.string)),
                "capabilities": .array(identity.capabilities.map(JSONValue.string)),
            ])
        )
    }

    public static func makeHeartbeatEnvelope(identity: NodeIdentity) -> MeshEnvelope {
        MeshEnvelope(type: .nodeHeartbeat, from: identity.nodeId)
    }

    public static func makeRPCRequestEnvelope(identity: NodeIdentity, to targetNodeId: String, method: String, params: JSONValue = .object([:])) -> MeshEnvelope {
        MeshEnvelope(
            type: .rpcRequest,
            from: identity.nodeId,
            to: targetNodeId,
            payload: .object([
                "method": .string(method),
                "params": params,
            ])
        )
    }

    public static func makeAuthResponseEnvelope(identity: NodeIdentity, challengeEnvelope: MeshEnvelope) throws -> MeshEnvelope? {
        guard challengeEnvelope.type == .authChallenge else {
            return nil
        }
        let challenge = try JSONValueCoder.decode(MeshAuthChallengePayload.self, from: challengeEnvelope.payload)
        guard challenge.nodeId.isEmpty || challenge.nodeId == identity.nodeId else {
            return nil
        }
        let signature = try NodeIdentityGenerator.sign(
            challenge: Data(challenge.nonce.utf8),
            privateKey: identity.privateKey
        )
        return MeshEnvelope(
            type: .authResponse,
            from: identity.nodeId,
            to: challengeEnvelope.from,
            scope: challengeEnvelope.scope,
            payload: try JSONValueCoder.encode(
                MeshAuthResponsePayload(
                    nonce: challenge.nonce,
                    nodeId: identity.nodeId,
                    publicKey: identity.publicKey,
                    signature: signature
                )
            )
        )
    }

    public func response(to envelope: MeshEnvelope) async -> MeshEnvelope? {
        await responses(to: envelope).first
    }

    public func responses(to envelope: MeshEnvelope) async -> [MeshEnvelope] {
        if envelope.type == .authChallenge {
            do {
                guard let response = try Self.makeAuthResponseEnvelope(identity: config.identity, challengeEnvelope: envelope) else {
                    return []
                }
                isRelayAuthenticated = true
                return [response]
            } catch {
                return []
            }
        }

        guard isRelayAuthenticated else {
            return []
        }

        if envelope.from == "relay", envelope.type == .eventPublish,
           let object = envelope.payload.asObject, object["kind"]?.asString == "models.directory",
           let value = object["nodes"], let records = try? JSONValueCoder.decode([MeshNodeRecord].self, from: value) {
            for record in records { _ = try? meshStore?.upsertNodeRecord(record, auditAction: "node.models.directory.sync") }
            return []
        }

        if envelope.type == .taskDispatch {
            return handleTaskDispatch(envelope)
        }

        guard envelope.type == .rpcRequest else {
            if let onEnvelope {
                return await onEnvelope(envelope)
            }
            return []
        }

        let payload = envelope.payload.asObject ?? [:]
        let method = payload["method"]?.asString ?? ""
        let responsePayload: JSONValue
        switch method {
        case "node.ping":
            responsePayload = .object([
                "requestId": .string(envelope.id),
                "method": .string(method),
                "ok": .bool(true),
                "time": .string(ISO8601DateFormatter().string(from: Date())),
            ])
        case "node.status":
            let status = await daemon.invoke(NodeActionRequest(action: .status))
            responsePayload = .object([
                "requestId": .string(envelope.id),
                "method": .string(method),
                "ok": .bool(status.ok),
                "result": status.data ?? .object([:]),
            ])
        case "node.capabilities":
            responsePayload = .object([
                "requestId": .string(envelope.id),
                "method": .string(method),
                "ok": .bool(true),
                "result": .object([
                    "roles": .array(config.identity.roles.map(JSONValue.string)),
                    "capabilities": .array(config.identity.capabilities.map(JSONValue.string)),
                ]),
            ])
        case "project.status":
            responsePayload = projectStatusResponse(for: envelope, method: method)
        case "shared_project.list":
            responsePayload = sharedProjectListResponse(for: envelope, method: method)
        case "shared_project.get":
            responsePayload = sharedProjectGetResponse(for: envelope, method: method)
        default:
            if let rpcHandler,
               let handledPayload = await rpcHandler(envelope, method, payload["params"] ?? .object([:])) {
                responsePayload = handledPayload
            } else {
                responsePayload = .object([
                    "requestId": .string(envelope.id),
                    "method": .string(method),
                    "ok": .bool(false),
                    "error": .object([
                        "code": .string("unknown_method"),
                        "message": .string("Unknown mesh RPC method."),
                    ]),
                ])
            }
        }

        return [MeshEnvelope(
            type: .rpcResponse,
            from: config.identity.nodeId,
            to: envelope.from,
            scope: envelope.scope,
            payload: responsePayload
        )]
    }

    private func sharedProjectListResponse(for envelope: MeshEnvelope, method: String) -> JSONValue {
        do {
            let projects = try visibleSharedProjects(for: envelope.from)
            return .object([
                "requestId": .string(envelope.id),
                "method": .string(method),
                "ok": .bool(true),
                "result": .object([
                    "projects": .array(try projects.map { try JSONValueCoder.encode($0) }),
                ]),
            ])
        } catch {
            return rpcErrorPayload(requestId: envelope.id, method: method, code: "mesh_store_unavailable", message: error.localizedDescription)
        }
    }

    private func projectStatusResponse(for envelope: MeshEnvelope, method: String) -> JSONValue {
        let params = envelope.payload.asObject?["params"]?.asObject ?? [:]
        guard let sharedProjectId = params["sharedProjectId"]?.asString, !sharedProjectId.isEmpty else {
            return rpcErrorPayload(requestId: envelope.id, method: method, code: "invalid_params", message: "sharedProjectId is required.")
        }

        do {
            guard let project = try visibleSharedProjects(for: envelope.from).first(where: { $0.id == sharedProjectId || $0.name == sharedProjectId }) else {
                return rpcErrorPayload(
                    requestId: envelope.id,
                    method: method,
                    code: "forbidden",
                    message: "Shared project is not visible to the caller."
                )
            }
            guard let localMember = project.members.first(where: { $0.nodeId == config.identity.nodeId }) else {
                return rpcErrorPayload(
                    requestId: envelope.id,
                    method: method,
                    code: "not_member",
                    message: "This node is not a shared project member."
                )
            }

            var result: [String: JSONValue] = [
                "sharedProjectId": .string(project.id),
                "name": .string(project.name),
                "repoUrl": .string(project.repoUrl),
                "defaultBranch": .string(project.defaultBranch),
                "localRepoPath": .string(localMember.localRepoPath),
            ]
            if FileManager.default.fileExists(atPath: localMember.localRepoPath) {
                result["gitBranch"] = gitOutput(arguments: ["branch", "--show-current"], at: localMember.localRepoPath)
                    .map(JSONValue.string) ?? .null
                result["dirty"] = .bool((gitOutput(arguments: ["status", "--porcelain"], at: localMember.localRepoPath) ?? "").isEmpty == false)
            }
            if let meshStore {
                let tasks = try meshStore.listTasks(projectIdOrName: project.id)
                result["tasks"] = .array(try tasks.map { try JSONValueCoder.encode($0) })
            }
            return .object([
                "requestId": .string(envelope.id),
                "method": .string(method),
                "ok": .bool(true),
                "result": .object(result),
            ])
        } catch {
            return rpcErrorPayload(requestId: envelope.id, method: method, code: "mesh_store_unavailable", message: error.localizedDescription)
        }
    }

    private func sharedProjectGetResponse(for envelope: MeshEnvelope, method: String) -> JSONValue {
        let params = envelope.payload.asObject?["params"]?.asObject ?? [:]
        let projectIdOrName = params["id"]?.asString ?? params["name"]?.asString ?? ""
        do {
            guard let project = try visibleSharedProjects(for: envelope.from).first(where: { $0.id == projectIdOrName || $0.name == projectIdOrName }) else {
                return rpcErrorPayload(
                    requestId: envelope.id,
                    method: method,
                    code: "forbidden",
                    message: "Shared project is not visible to the caller."
                )
            }
            return .object([
                "requestId": .string(envelope.id),
                "method": .string(method),
                "ok": .bool(true),
                "result": try JSONValueCoder.encode(project),
            ])
        } catch {
            return rpcErrorPayload(requestId: envelope.id, method: method, code: "mesh_store_unavailable", message: error.localizedDescription)
        }
    }

    private func visibleSharedProjects(for callerNodeId: String) throws -> [SharedProjectRecord] {
        guard let meshStore else {
            throw NodeMeshStoreError.projectMissing("mesh_store")
        }
        return try meshStore.listSharedProjects().filter { project in
            project.members.contains { member in
                member.nodeId == callerNodeId && member.permissions.contains(MeshPermission.projectRead.rawValue)
            }
        }
    }

    private func rpcErrorPayload(requestId: String, method: String, code: String, message: String) -> JSONValue {
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

    private func handleTaskDispatch(_ envelope: MeshEnvelope) -> [MeshEnvelope] {
        let payload = envelope.payload.asObject ?? [:]
        let taskId = payload["taskId"]?.asString ?? envelope.id
        let projectId = payload["projectId"]?.asString ?? ""

        do {
            guard let meshStore else {
                return [makeTaskStatusUpdate(
                    taskId: taskId,
                    projectId: projectId,
                    status: .blocked,
                    to: envelope.from,
                    scope: envelope.scope,
                    summary: "Worker mesh store is not configured."
                )]
            }
            let projects = try meshStore.listSharedProjects()
            guard let project = projects.first(where: { $0.id == projectId })
                ?? projects.first(where: { $0.name == projectId }) else {
                return [makeTaskStatusUpdate(
                    taskId: taskId,
                    projectId: projectId,
                    status: .blocked,
                    to: envelope.from,
                    scope: envelope.scope,
                    summary: "Shared project is not configured on this node."
                )]
            }
            guard project.members.contains(where: { $0.nodeId == config.identity.nodeId }) else {
                return [makeTaskStatusUpdate(
                    taskId: taskId,
                    projectId: project.id,
                    status: .blocked,
                    to: envelope.from,
                    scope: envelope.scope,
                    summary: "This node is not a member of the shared project."
                )]
            }
            guard let task = try meshStore.listTasks(projectIdOrName: project.id).first(where: { $0.id == taskId }),
                  task.assignedNodeId == config.identity.nodeId
            else {
                return [makeTaskStatusUpdate(
                    taskId: taskId,
                    projectId: project.id,
                    status: .blocked,
                    to: envelope.from,
                    scope: envelope.scope,
                    summary: "Task is not assigned to this node."
                )]
            }

            let claimed = try meshStore.updateTaskStatus(
                taskId: taskId,
                projectIdOrName: project.id,
                status: .claimed,
                actor: config.identity.nodeId,
                summary: "Task dispatch claimed by \(config.identity.name)."
            )
            let started = try meshStore.updateTaskStatus(
                taskId: taskId,
                projectIdOrName: project.id,
                status: .started,
                actor: config.identity.nodeId,
                summary: "Task execution started by \(config.identity.name)."
            )
            return [
                makeTaskStatusUpdate(
                    taskId: claimed.id,
                    projectId: claimed.projectId,
                    status: claimed.status,
                    to: envelope.from,
                    scope: envelope.scope,
                    summary: claimed.summary
                ),
                makeTaskStatusUpdate(
                    taskId: started.id,
                    projectId: started.projectId,
                    status: started.status,
                    to: envelope.from,
                    scope: envelope.scope,
                    summary: started.summary
                ),
            ]
        } catch {
            return [makeTaskStatusUpdate(
                taskId: taskId,
                projectId: projectId,
                status: .blocked,
                to: envelope.from,
                scope: envelope.scope,
                summary: error.localizedDescription
            )]
        }
    }

    private func makeTaskStatusUpdate(
        taskId: String,
        projectId: String,
        status: MeshTaskStatus,
        to: String,
        scope: String?,
        summary: String?
    ) -> MeshEnvelope {
        MeshEnvelope(
            type: .taskStatusUpdate,
            from: config.identity.nodeId,
            to: to,
            scope: scope ?? (projectId.isEmpty ? nil : "sharedProject:\(projectId)"),
            payload: .object([
                "taskId": .string(taskId),
                "projectId": .string(projectId),
                "nodeId": .string(config.identity.nodeId),
                "status": .string(status.rawValue),
                "summary": summary.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private func gitOutput(arguments: [String], at path: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    public func run(relayURL: String? = nil) async throws {
        let configuredRelayURL = relayURL ?? config.relayURL
        guard let configuredRelayURL, !configuredRelayURL.isEmpty else {
            return
        }
        let url = try Self.resolveRelayWebSocketURL(configuredRelayURL)
        isRunLoopActive = true
        defer { isRunLoopActive = false }

        while !Task.isCancelled {
            do {
                try await runConnection(url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            }
        }
    }

    public func sendRPCRequest(
        relayURL: String? = nil,
        to targetNodeId: String,
        method: String,
        params: JSONValue = .object([:]),
        timeout: TimeInterval = 30
    ) async throws -> MeshEnvelope {
        #if !os(Linux)
        if isRunLoopActive && (activeWebSocketTask == nil || !isRelayAuthenticated) {
            let deadline = Date().addingTimeInterval(min(5, max(0.25, timeout)))
            while Date() < deadline && (activeWebSocketTask == nil || !isRelayAuthenticated) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        if let activeWebSocketTask, isRelayAuthenticated {
            let request = Self.makeRPCRequestEnvelope(
                identity: config.identity,
                to: targetNodeId,
                method: method,
                params: params
            )
            return try await rpcManager.send(request, timeout: timeout) { [weak self] outbound in
                guard let self else {
                    throw CancellationError()
                }
                try await self.send(outbound, over: activeWebSocketTask)
            }
        }
        if isRunLoopActive {
            throw NodeMeshClientError.relayNotConnected
        }
        #endif

        let configuredRelayURL = relayURL ?? config.relayURL
        guard let configuredRelayURL, !configuredRelayURL.isEmpty else {
            throw NodeMeshClientError.missingRelayURL
        }
        let url = try Self.resolveRelayWebSocketURL(configuredRelayURL)
        let request = Self.makeRPCRequestEnvelope(identity: config.identity, to: targetNodeId, method: method, params: params)

        return try await withThrowingTaskGroup(of: MeshEnvelope.self) { group in
            group.addTask {
                try await self.runRPCConnection(url: url, request: request, timeout: timeout)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw NodeMeshRPCError.timeout(request.id)
            }

            guard let response = try await group.next() else {
                throw NodeMeshRPCError.timeout(request.id)
            }
            group.cancelAll()
            return response
        }
    }

    public func openStream(
        to targetNodeID: String,
        kind: String,
        params: JSONValue = .object([:])
    ) async throws -> NodeMeshStream {
        #if os(Linux)
        throw NodeMeshClientError.unsupportedRelayScheme("linux-urlsession-websocket")
        #else
        guard let activeWebSocketTask, isRelayAuthenticated else {
            throw NodeMeshStreamError.relayNotConnected
        }
        let streamID = UUID().uuidString.lowercased()
        let stream = await streamManager.register(streamID: streamID, peerID: targetNodeID)
        let envelope = MeshEnvelope(
            type: .streamOpen,
            from: config.identity.nodeId,
            to: targetNodeID,
            payload: .object([
                "streamId": .string(streamID),
                "kind": .string(kind),
                "params": params,
            ])
        )
        do {
            try await send(envelope, over: activeWebSocketTask)
            return stream
        } catch {
            await streamManager.fail(streamID: streamID, error: error)
            throw error
        }
        #endif
    }

    public func sendStreamChunk(
        streamID: String,
        to targetNodeID: String,
        data: JSONValue
    ) async throws {
        try await sendConnectedEnvelope(
            MeshEnvelope(
                type: .streamChunk,
                from: config.identity.nodeId,
                to: targetNodeID,
                payload: .object([
                    "streamId": .string(streamID),
                    "data": data,
                ])
            )
        )
    }

    public func closeStream(
        streamID: String,
        to targetNodeID: String,
        ok: Bool = true,
        message: String? = nil
    ) async throws {
        try await sendConnectedEnvelope(
            MeshEnvelope(
                type: .streamClose,
                from: config.identity.nodeId,
                to: targetNodeID,
                payload: .object([
                    "streamId": .string(streamID),
                    "ok": .bool(ok),
                    "message": message.map(JSONValue.string) ?? .null,
                ])
            )
        )
        await streamManager.finish(streamID: streamID)
    }

    private func runConnection(url: URL) async throws {
        #if os(Linux)
        throw NodeMeshClientError.unsupportedRelayScheme("linux-urlsession-websocket")
        #else
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        activeWebSocketTask = task
        isRelayAuthenticated = false
        defer {
            if activeWebSocketTask === task {
                activeWebSocketTask = nil
                isRelayAuthenticated = false
            }
            task.cancel(with: .goingAway, reason: nil)
            Task { await streamManager.failAll(NodeMeshStreamError.relayNotConnected) }
        }

        var sentHello = false
        var heartbeatTask: Task<Void, Error>?
        defer { heartbeatTask?.cancel() }

        while !Task.isCancelled {
            let message = try await task.receive()
            guard let text = Self.text(from: message), let data = text.data(using: .utf8) else {
                continue
            }
            let wireEnvelope = try decoder.decode(MeshEnvelope.self, from: data)
            let envelope = try prepareInbound(wireEnvelope)
            if await rpcManager.receive(envelope) {
                continue
            }
            if await streamManager.receive(envelope) {
                continue
            }
            let responseEnvelopes = await responses(to: envelope)
            for responseEnvelope in responseEnvelopes {
                try await send(responseEnvelope, over: task)
            }
            if envelope.type == .authChallenge, !responseEnvelopes.isEmpty, !sentHello {
                await daemon.connect()
                try await send(Self.makeHelloEnvelope(identity: config.identity), over: task)
                sentHello = true
                heartbeatTask = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                        await daemon.heartbeat()
                        try await send(Self.makeHeartbeatEnvelope(identity: config.identity), over: task)
                    }
                }
            }
        }
        #endif
    }

    private func runRPCConnection(url: URL, request: MeshEnvelope, timeout: TimeInterval) async throws -> MeshEnvelope {
        #if os(Linux)
        throw NodeMeshClientError.unsupportedRelayScheme("linux-urlsession-websocket")
        #else
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let manager = NodeMeshRPCManager()
        var sentRequest = false
        var responseTask: Task<MeshEnvelope, Error>?
        defer { responseTask?.cancel() }

        while !Task.isCancelled {
            let message = try await task.receive()
            guard let text = Self.text(from: message), let data = text.data(using: .utf8) else {
                continue
            }
            let wireEnvelope = try decoder.decode(MeshEnvelope.self, from: data)
            let envelope = try prepareInbound(wireEnvelope)
            let responseEnvelopes = await responses(to: envelope)
            for responseEnvelope in responseEnvelopes {
                try await send(responseEnvelope, over: task)
            }

            if envelope.type == .authChallenge, !responseEnvelopes.isEmpty, !sentRequest {
                await daemon.connect()
                try await send(Self.makeHelloEnvelope(identity: config.identity), over: task)
                sentRequest = true
                responseTask = Task {
                    try await manager.send(request, timeout: timeout) { outbound in
                        try await self.send(outbound, over: task)
                    }
                }
            }

            if await manager.receive(envelope), let responseTask {
                return try await responseTask.value
            }
        }

        throw CancellationError()
        #endif
    }

    private func sendConnectedEnvelope(_ envelope: MeshEnvelope) async throws {
        #if os(Linux)
        throw NodeMeshClientError.unsupportedRelayScheme("linux-urlsession-websocket")
        #else
        guard let activeWebSocketTask, isRelayAuthenticated else {
            throw NodeMeshStreamError.relayNotConnected
        }
        try await send(envelope, over: activeWebSocketTask)
        #endif
    }

    #if !os(Linux)
    private func send(_ envelope: MeshEnvelope, over task: URLSessionWebSocketTask) async throws {
        let outbound = try prepareOutbound(envelope)
        let data = try encoder.encode(outbound)
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }
        try await task.send(.string(text))
    }

    func prepareOutbound(_ envelope: MeshEnvelope) throws -> MeshEnvelope {
        guard requiresPayloadEncryption(envelope), !NodeMeshPayloadCrypto.isSealed(envelope.payload) else {
            return envelope
        }
        guard let target = envelope.to,
              let recipient = try meshStore?.listNodes().first(where: { $0.id == target })
        else {
            throw NodeMeshPayloadCryptoError.missingKey(envelope.to ?? "unknown")
        }
        var sealed = envelope
        sealed.payload = try NodeMeshPayloadCrypto.seal(
            envelope.payload,
            envelope: envelope,
            sender: config.identity,
            recipient: recipient
        )
        return sealed
    }

    func prepareInbound(_ envelope: MeshEnvelope) throws -> MeshEnvelope {
        guard NodeMeshPayloadCrypto.isSealed(envelope.payload) else {
            if requiresPayloadEncryption(envelope) {
                let relayFailure = envelope.from == "relay"
                    && (envelope.type == .rpcResponse || envelope.type == .streamClose)
                    && envelope.payload.asObject?["ok"]?.asBool == false
                guard relayFailure else { throw NodeMeshPayloadCryptoError.invalidPayload }
            }
            return envelope
        }
        guard !seenEncryptedEnvelopeIDs.contains(envelope.id) else {
            throw NodeMeshPayloadCryptoError.invalidPayload
        }
        guard var sender = try meshStore?.listNodes().first(where: { $0.id == envelope.from }) else {
            throw NodeMeshPayloadCryptoError.missingKey(envelope.from)
        }
        var opened = envelope
        opened.payload = try NodeMeshPayloadCrypto.open(
            envelope.payload,
            envelope: envelope,
            recipient: config.identity,
            senderSigningPublicKey: sender.publicKey
        )
        if let object = envelope.payload.asObject,
           let encryptionPublicKey = object["senderEncryptionPublicKey"]?.asString,
           let encryptionKeySignature = object["senderEncryptionKeySignature"]?.asString {
            sender.encryptionPublicKey = encryptionPublicKey
            sender.encryptionKeySignature = encryptionKeySignature
            _ = try? meshStore?.upsertNodeRecord(sender, auditAction: "node.encryption-key.sync")
        }
        seenEncryptedEnvelopeIDs.insert(envelope.id)
        if seenEncryptedEnvelopeIDs.count > 10_000 {
            seenEncryptedEnvelopeIDs.removeAll(keepingCapacity: true)
            seenEncryptedEnvelopeIDs.insert(envelope.id)
        }
        return opened
    }

    private func requiresPayloadEncryption(_ envelope: MeshEnvelope) -> Bool {
        switch envelope.type {
        case .streamOpen, .streamChunk, .streamClose:
            return true
        case .rpcRequest, .rpcResponse:
            return ["core.http", "models.catalog"].contains(envelope.payload.asObject?["method"]?.asString ?? "")
        default:
            return false
        }
    }

    private static func text(from message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }
    #endif
}
