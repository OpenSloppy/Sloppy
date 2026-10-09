import Foundation
import Logging
import Protocols
import SloppyNodeCore

actor NodeMeshRelay {
    private struct Connection {
        var id: UUID
        var node: MeshNodeRecord
        var context: WebSocketConnectionContext
    }

    private var connections: [String: Connection] = [:]
    private var nodes: [String: MeshNodeRecord] = [:]
    private struct ActiveStream: Sendable {
        var source: String
        var target: String
        var kind: String
    }
    private var activeStreams: [String: ActiveStream] = [:]
    private let store: NodeMeshStore?
    private let logger: Logger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(store: NodeMeshStore? = nil, logger: Logger = Logger.sloppy(label: "sloppy.node.mesh.relay")) {
        self.store = store
        self.logger = logger
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func attach(connection: WebSocketConnectionContext, remoteAddress: String?) async {
        var attachedNodeId: String?
        let connectionId = UUID()
        let authChallenge = makeAuthChallenge()
        var authenticatedNode: MeshNodeRecord?
        defer {
            if let attachedNodeId {
                markOffline(nodeId: attachedNodeId, connectionId: connectionId)
            }
        }

        do {
            try await Task.sleep(nanoseconds: 1_000_000)
            try await send(authChallenge, over: connection)
        } catch {
            logger.warning("Node mesh auth challenge failed", metadata: ["error": .string(String(describing: error))])
            await connection.close()
            return
        }

        for await text in connection.incomingMessages() {
            guard let data = text.data(using: .utf8) else {
                continue
            }
            do {
                let envelope = try decoder.decode(MeshEnvelope.self, from: data)
                switch envelope.type {
                case .authResponse:
                    switch verifyAuthResponse(envelope, challenge: authChallenge) {
                    case let .success(node):
                        authenticatedNode = node
                    case let .failure(message):
                        try await sendAuthFailure(to: envelope.from, message: message, over: connection)
                        await connection.close()
                        return
                    }
                case .nodeHello:
                    guard let authenticatedNode, authenticatedNode.id == envelope.from else {
                        try await sendAuthFailure(to: envelope.from, message: "Node is not authenticated.", over: connection)
                        await connection.close()
                        return
                    }
                    let node = nodeRecord(from: envelope, authenticatedNode: authenticatedNode, remoteAddress: remoteAddress)
                    nodes[node.id] = node
                    if let previous = connections[node.id], previous.id != connectionId {
                        await previous.context.close()
                    }
                    connections[node.id] = Connection(id: connectionId, node: node, context: connection)
                    attachedNodeId = node.id
                    persist {
                        try store?.upsertNodeRecord(node, auditAction: "node.hello")
                    }
                    try await sendPendingTaskDispatches(to: node.id)
                    try await publishModelDirectory()
                case .nodeHeartbeat:
                    guard authenticatedNode?.id == envelope.from else {
                        continue
                    }
                    handleHeartbeat(envelope)
                default:
                    guard let authenticatedNode, authenticatedNode.id == envelope.from else {
                        continue
                    }
                    guard connections[envelope.from]?.id == connectionId else {
                        continue
                    }
                    try await route(envelope)
                }
            } catch {
                logger.warning("Node mesh websocket message failed", metadata: ["error": .string(String(describing: error))])
            }
        }
    }

    private enum AuthVerificationResult {
        case success(MeshNodeRecord)
        case failure(String)
    }

    /// Public peer keys/capabilities are delivered only after node authentication.
    /// Unlike mesh state this snapshot contains no invites or private credentials.
    private func publishModelDirectory() async throws {
        guard let records = try? store?.listNodes() else { return }
        let eligible = records.filter { $0.capabilities.contains("sloppy.models.inference") || $0.capabilities.contains("sloppy.core.remote") }
        let value = try JSONValueCoder.encode(eligible)
        for record in eligible {
            guard let connection = connections[record.id] else { continue }
            try await send(.init(type: .eventPublish, from: "relay", to: record.id,
                payload: .object(["kind": .string("models.directory"), "nodes": value])), over: connection.context)
        }
    }

    private func makeAuthChallenge() -> MeshEnvelope {
        MeshEnvelope(
            type: .authChallenge,
            from: "relay",
            payload: .object([
                "nonce": .string(NodeIdentityGenerator.randomToken(byteCount: 24)),
                "nodeId": .string(""),
                "publicKey": .string(""),
                "issuedAt": .string(ISO8601DateFormatter().string(from: Date())),
            ])
        )
    }

    private func verifyAuthResponse(_ envelope: MeshEnvelope, challenge: MeshEnvelope) -> AuthVerificationResult {
        guard let store else {
            return .failure("Node mesh store is not configured.")
        }
        do {
            let challengePayload = try JSONValueCoder.decode(MeshAuthChallengePayload.self, from: challenge.payload)
            let response = try JSONValueCoder.decode(MeshAuthResponsePayload.self, from: envelope.payload)
            guard response.nonce == challengePayload.nonce else {
                return .failure("Auth nonce does not match.")
            }
            guard response.nodeId == envelope.from else {
                return .failure("Auth node id does not match envelope sender.")
            }
            guard let registered = try store.listNodes().first(where: { $0.id == response.nodeId }) else {
                return .failure("Node is not registered.")
            }
            guard response.publicKey == registered.publicKey else {
                return .failure("Auth public key does not match registered node.")
            }
            guard NodeIdentityGenerator.verify(
                signature: response.signature,
                challenge: Data(response.nonce.utf8),
                publicKey: registered.publicKey
            ) else {
                return .failure("Auth signature is invalid.")
            }
            return .success(registered)
        } catch {
            return .failure("Auth response is invalid.")
        }
    }

    func activeNodeIds() -> [String] {
        Array(connections.keys).sorted()
    }

    func nodeRecord(id: String) -> MeshNodeRecord? {
        nodes[id]
    }

    private func route(_ envelope: MeshEnvelope) async throws {
        if envelope.type == .taskStatusUpdate {
            if let denial = taskStatusUpdateAuthorizationDenial(for: envelope) {
                try await sendForbiddenRPCResponse(for: envelope, message: denial)
                if let target = envelope.to {
                    persist {
                        try store?.recordRouteFailure(envelope, target: target, message: denial)
                    }
                }
                return
            }
            persistTaskStatusUpdate(envelope)
        }
        if envelope.type == .eventAck {
            guard let messageId = envelope.payload.asObject?["messageId"]?.asString else {
                return
            }
            persist {
                try store?.ackEnvelope(id: messageId, acknowledgedBy: envelope.from)
            }
            return
        }
        guard let target = envelope.to else {
            if envelope.type == .projectSyncEvent {
                if let denial = projectSyncAuthorizationDenial(for: envelope, target: nil) {
                    try await sendForbiddenRPCResponse(for: envelope, message: denial)
                    return
                }
                try await publishProjectSyncEvent(envelope)
            }
            return
        }
        if envelope.type == .projectSyncEvent, let denial = projectSyncAuthorizationDenial(for: envelope, target: target) {
            try await sendForbiddenRPCResponse(for: envelope, message: denial)
            persist {
                try store?.recordRouteFailure(envelope, target: target, message: denial)
            }
            return
        }
        if envelope.type == .rpcRequest, let denial = rpcAuthorizationDenial(for: envelope, target: target) {
            try await sendForbiddenRPCResponse(for: envelope, message: denial)
            persist {
                try store?.recordRouteFailure(envelope, target: target, message: denial)
            }
            return
        }
        if envelope.type == .streamOpen {
            if let denial = streamAuthorizationDenial(for: envelope, target: target) {
                try await sendStreamClose(for: envelope, message: denial)
                return
            }
            guard let streamID = envelope.payload.asObject?["streamId"]?.asString,
                  let kind = envelope.payload.asObject?["kind"]?.asString,
                  activeStreams[streamID] == nil else {
                try await sendStreamClose(for: envelope, message: "stream id is invalid or already active")
                return
            }
            activeStreams[streamID] = ActiveStream(source: envelope.from, target: target, kind: kind)
        } else if envelope.type == .streamChunk || envelope.type == .streamClose {
            if envelope.type == .streamClose, let id = envelope.payload.asObject?["streamId"]?.asString, activeStreams[id] == nil {
                // Close can race the peer's completion/cancellation; it is idempotent.
                return
            }
            guard let streamID = envelope.payload.asObject?["streamId"]?.asString,
                  let stream = activeStreams[streamID],
                  (envelope.from == stream.source && target == stream.target)
                    || (envelope.from == stream.target && target == stream.source)
            else {
                try await sendStreamClose(for: envelope, message: "stream is not authorized")
                return
            }
            if envelope.type == .streamClose {
                activeStreams[streamID] = nil
            }
        }
        if envelope.type == .taskDispatch, let denial = taskDispatchAuthorizationDenial(for: envelope, target: target) {
            try await sendForbiddenRPCResponse(for: envelope, message: denial)
            persist {
                try store?.recordRouteFailure(envelope, target: target, message: denial)
            }
            return
        }
        if envelope.type == .eventPublish {
            persist {
                try store?.routeEnvelope(envelope)
            }
            guard let connection = connections[target] else {
                return
            }
            try await send(envelope, over: connection.context)
            return
        }
        guard let connection = connections[target] else {
            logger.warning(
                "Node mesh target is not connected",
                metadata: [
                    "from": .string(envelope.from),
                    "target": .string(target),
                    "type": .string(envelope.type.rawValue),
                ]
            )
            try await sendUnavailableTargetError(for: envelope, target: target)
            if envelope.type == .taskDispatch {
                let taskId = envelope.payload.asObject?["taskId"]?.asString ?? envelope.id
                persist {
                    try store?.recordTaskDispatchDelivery(
                        taskId: taskId,
                        target: target,
                        delivered: false,
                        message: "target node unavailable"
                    )
                }
            }
            return
        }
        if shouldPersist(envelope) {
            persist {
                try store?.routeEnvelope(envelope)
            }
        }
        try await send(envelope, over: connection.context)
        if envelope.type == .taskDispatch {
            let taskId = envelope.payload.asObject?["taskId"]?.asString ?? envelope.id
            persist {
                try store?.recordTaskDispatchDelivery(taskId: taskId, target: target, delivered: true)
            }
        }
    }

    private func sendPendingTaskDispatches(to nodeId: String) async throws {
        guard let store, let connection = connections[nodeId] else {
            return
        }
        let state = try store.load()
        for envelope in state.envelopes where envelope.type == .taskDispatch && envelope.to == nodeId {
            guard taskDispatchAuthorizationDenial(for: envelope, target: nodeId, allowTrustedLocal: true) == nil else {
                continue
            }
            try await send(envelope, over: connection.context)
            let taskId = envelope.payload.asObject?["taskId"]?.asString ?? envelope.id
            persist {
                try store.recordTaskDispatchDelivery(taskId: taskId, target: nodeId, delivered: true)
            }
        }
        for envelope in state.envelopes where envelope.type == .projectSyncEvent && envelope.to == nodeId {
            guard try node(nodeId, canReceiveProjectSync: envelope, store: store) else {
                continue
            }
            try await send(envelope, over: connection.context)
        }
        for envelope in state.envelopes where envelope.type == .eventPublish && envelope.to == nodeId {
            try await send(envelope, over: connection.context)
        }
    }

    private func publishProjectSyncEvent(_ envelope: MeshEnvelope) async throws {
        guard let store,
              let projectId = projectId(from: envelope),
              let project = try? sharedProject(projectIdOrName: projectId, in: store)
        else {
            return
        }
        let memberNodeIds = Set(project.members.map(\.nodeId))
        for nodeId in memberNodeIds where nodeId != envelope.from {
            var scopedEnvelope = envelope
            scopedEnvelope.to = nodeId
            persist {
                try store.routeEnvelope(scopedEnvelope)
            }
            guard let connection = connections[nodeId] else {
                continue
            }
            try await send(scopedEnvelope, over: connection.context)
        }
    }

    private func projectId(from envelope: MeshEnvelope) -> String? {
        if let scope = envelope.scope, scope.hasPrefix("sharedProject:") {
            return String(scope.dropFirst("sharedProject:".count))
        }
        return envelope.payload.asObject?["projectId"]?.asString
    }

    private func node(_ nodeId: String, canReceiveProjectSync envelope: MeshEnvelope, store: NodeMeshStore) throws -> Bool {
        projectSyncAuthorizationDenial(for: envelope, target: nodeId, allowTrustedLocal: true) == nil
    }

    private func persistTaskStatusUpdate(_ envelope: MeshEnvelope) {
        guard let store else { return }
        let payload = envelope.payload.asObject ?? [:]
        guard let taskId = payload["taskId"]?.asString,
              let rawStatus = payload["status"]?.asString,
              let status = MeshTaskStatus(rawValue: rawStatus)
        else { return }
        persist {
            guard try taskStatusUpdateIsAuthorized(
                taskId: taskId,
                projectIdOrName: payload["projectId"]?.asString,
                actor: envelope.from,
                store: store
            ) else {
                throw NodeMeshStoreError.permissionDenied("task.status.update")
            }
            _ = try store.updateTaskStatus(
                taskId: taskId,
                projectIdOrName: payload["projectId"]?.asString,
                status: status,
                actor: envelope.from,
                branch: payload["branch"]?.asString,
                commit: payload["commit"]?.asString,
                summary: payload["summary"]?.asString
            )
        }
    }

    private func projectSyncAuthorizationDenial(
        for envelope: MeshEnvelope,
        target: String?,
        allowTrustedLocal: Bool = false
    ) -> String? {
        guard let store,
              envelope.type == .projectSyncEvent
        else {
            return nil
        }
        guard let projectId = projectId(from: envelope) else {
            return "shared project scope is unknown"
        }
        do {
            let trustedLocal = allowTrustedLocal && (envelope.from == "local" || envelope.from == "api")
            let liveProject = try sharedProject(projectIdOrName: projectId, in: store)
            guard let project = liveProject ?? removableProjectSnapshot(from: envelope, trustedLocal: trustedLocal) else {
                return "shared project scope is unknown"
            }
            if !(allowTrustedLocal && (envelope.from == "local" || envelope.from == "api")) {
                guard let sourceMember = project.members.first(where: { $0.nodeId == envelope.from }) else {
                    return "source node is not a project member"
                }
                guard sourceMember.permissions.contains(MeshPermission.projectWrite.rawValue) else {
                    return "missing project.write permission"
                }
            }
            if let target {
                guard project.members.contains(where: { $0.nodeId == target }) else {
                    return "target node is not a project member"
                }
            }
            return nil
        } catch {
            return "mesh authorization state is unavailable"
        }
    }

    private func removableProjectSnapshot(from envelope: MeshEnvelope, trustedLocal: Bool) -> SharedProjectRecord? {
        guard trustedLocal,
              envelope.payload.asObject?["action"]?.asString == "shared_project.remove",
              let projectValue = envelope.payload.asObject?["project"]
        else {
            return nil
        }
        return try? JSONValueCoder.decode(SharedProjectRecord.self, from: projectValue)
    }

    private func rpcAuthorizationDenial(for envelope: MeshEnvelope, target: String) -> String? {
        if envelope.payload.asObject?["method"]?.asString == "models.catalog" {
            return modelAccessDenial(source: envelope.from, target: target)
        }
        if envelope.payload.asObject?["method"]?.asString == "core.http" {
            return fullCoreAccessDenial(source: envelope.from, target: target)
        }
        guard let store,
              envelope.scope?.hasPrefix("sharedProject:") == true,
              let projectId = envelope.scope.map({ String($0.dropFirst("sharedProject:".count)) })
        else {
            return nil
        }

        do {
            guard let project = try sharedProject(projectIdOrName: projectId, in: store) else {
                return "shared project scope is unknown"
            }
            guard let sourceMember = project.members.first(where: { $0.nodeId == envelope.from }) else {
                return "source node is not a project member"
            }
            guard project.members.contains(where: { $0.nodeId == target }) else {
                return "target node is not a project member"
            }
            guard sourceMember.permissions.contains(MeshPermission.nodeRPC.rawValue) else {
                return "missing node.rpc permission"
            }
            return nil
        } catch {
            return "mesh authorization state is unavailable"
        }
    }

    private func streamAuthorizationDenial(for envelope: MeshEnvelope, target: String) -> String? {
        guard let kind = envelope.payload.asObject?["kind"]?.asString else {
            return "stream kind is missing"
        }
        if kind == "models.inference" { return modelAccessDenial(source: envelope.from, target: target) }
        if let denial = fullCoreAccessDenial(source: envelope.from, target: target) {
            return denial
        }
        if kind == "dashboard.terminal",
           nodes[target]?.capabilities.contains("sloppy.terminal.control") != true {
            return "target has not granted terminal control"
        }
        return nil
    }

    private func fullCoreAccessDenial(source: String, target: String) -> String? {
        guard nodes[source]?.capabilities.contains("sloppy.core.remote") == true else {
            return "source does not have a full Core access grant"
        }
        guard nodes[target]?.capabilities.contains("sloppy.core.remote") == true else {
            return "target has not granted full Core access"
        }
        return nil
    }

    private func modelAccessDenial(source: String, target: String) -> String? {
        for id in [source, target] {
            guard let node = nodes[id], node.capabilities.contains("sloppy.models.inference") || node.capabilities.contains("sloppy.core.remote") else {
                return "model access is not granted to both computers"
            }
        }
        return nil
    }

    private func shouldPersist(_ envelope: MeshEnvelope) -> Bool {
        if envelope.type == .streamOpen || envelope.type == .streamChunk || envelope.type == .streamClose {
            return false
        }
        return !["core.http", "models.catalog"].contains(envelope.payload.asObject?["method"]?.asString ?? "")
    }

    private func sharedProject(projectIdOrName: String, in store: NodeMeshStore) throws -> SharedProjectRecord? {
        let projects = try store.listSharedProjects()
        if let project = projects.first(where: { $0.id == projectIdOrName }) {
            return project
        }
        return projects.first(where: { $0.name == projectIdOrName })
    }

    private func taskStatusUpdateIsAuthorized(
        taskId: String,
        projectIdOrName: String?,
        actor: String,
        store: NodeMeshStore
    ) throws -> Bool {
        let tasks = try store.listTasks(projectIdOrName: projectIdOrName)
            .filter { $0.id == taskId }
        guard !tasks.isEmpty else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        guard tasks.count == 1, let task = tasks.first else {
            throw NodeMeshStoreError.taskAmbiguous(taskId)
        }
        guard let project = try sharedProject(projectIdOrName: task.projectId, in: store),
              let actorMember = project.members.first(where: { $0.nodeId == actor }),
              actorMember.permissions.contains(MeshPermission.taskUpdate.rawValue)
        else {
            return false
        }
        let ownsTask = task.assignedNodeId == actor
        let hasElevatedTaskPermission = actorMember.permissions.contains(MeshPermission.taskAssign.rawValue)
            || actorMember.permissions.contains(MeshPermission.taskCreate.rawValue)
        return ownsTask || hasElevatedTaskPermission
    }

    private func taskStatusUpdateAuthorizationDenial(for envelope: MeshEnvelope) -> String? {
        guard let store,
              envelope.type == .taskStatusUpdate
        else {
            return nil
        }
        let payload = envelope.payload.asObject ?? [:]
        guard let taskId = payload["taskId"]?.asString,
              let rawStatus = payload["status"]?.asString,
              MeshTaskStatus(rawValue: rawStatus) != nil
        else {
            return "task status update payload is invalid"
        }
        do {
            guard try taskStatusUpdateIsAuthorized(
                taskId: taskId,
                projectIdOrName: payload["projectId"]?.asString,
                actor: envelope.from,
                store: store
            ) else {
                return "missing task status update permission"
            }
            return nil
        } catch NodeMeshStoreError.taskAmbiguous(_) {
            return "task status target is ambiguous"
        } catch NodeMeshStoreError.taskMissing(_) {
            return "task status target is unknown"
        } catch {
            return "mesh authorization state is unavailable"
        }
    }

    private func taskDispatchAuthorizationDenial(
        for envelope: MeshEnvelope,
        target: String,
        allowTrustedLocal: Bool = false
    ) -> String? {
        guard let store,
              envelope.type == .taskDispatch
        else {
            return nil
        }
        let payload = envelope.payload.asObject ?? [:]
        let taskId = payload["taskId"]?.asString ?? envelope.id
        let projectIdOrName = payload["projectId"]?.asString ?? projectId(from: envelope)
        do {
            let tasks = try store.listTasks(projectIdOrName: projectIdOrName).filter { $0.id == taskId }
            guard let task = tasks.first, tasks.count == 1 else {
                return "task dispatch target is ambiguous or unknown"
            }
            guard task.assignedNodeId == target else {
                return "task is not assigned to target node"
            }
            guard let project = try sharedProject(projectIdOrName: task.projectId, in: store) else {
                return "shared project scope is unknown"
            }
            if !(allowTrustedLocal && envelope.from == "local") {
                guard let sourceMember = project.members.first(where: { $0.nodeId == envelope.from }) else {
                    return "source node is not a project member"
                }
                guard sourceMember.permissions.contains(MeshPermission.taskCreate.rawValue),
                      sourceMember.permissions.contains(MeshPermission.taskAssign.rawValue)
                else {
                    return "missing task dispatch permission"
                }
            }
            guard let targetMember = project.members.first(where: { $0.nodeId == target }),
                  targetMember.permissions.contains(MeshPermission.taskUpdate.rawValue)
                    || targetMember.permissions.contains(MeshPermission.taskAssign.rawValue)
            else {
                return "target node is not an eligible task assignee"
            }
            return nil
        } catch {
            return "mesh authorization state is unavailable"
        }
    }

    private func handleHeartbeat(_ envelope: MeshEnvelope) {
        guard var node = nodes[envelope.from] else {
            return
        }
        node.status = .online
        node.lastSeenAt = Date()
        nodes[node.id] = node
        if var connection = connections[node.id] {
            connection.node = node
            connections[node.id] = connection
        }
        persist {
            try store?.updateNodeStatus(nodeId: node.id, status: .online, auditAction: "node.heartbeat")
        }
    }

    private func markOffline(nodeId: String, connectionId: UUID) {
        guard connections[nodeId]?.id == connectionId else {
            return
        }
        connections[nodeId] = nil
        activeStreams = activeStreams.filter { _, stream in
            stream.source != nodeId && stream.target != nodeId
        }
        guard var node = nodes[nodeId] else {
            return
        }
        node.status = .offline
        node.lastSeenAt = Date()
        nodes[nodeId] = node
        persist {
            try store?.updateNodeStatus(nodeId: nodeId, status: .offline, auditAction: "node.offline")
        }
    }

    private func nodeRecord(
        from envelope: MeshEnvelope,
        authenticatedNode: MeshNodeRecord,
        remoteAddress: String?
    ) -> MeshNodeRecord {
        let payload = envelope.payload.asObject ?? [:]
        return MeshNodeRecord(
            id: envelope.from,
            name: payload["name"]?.asString ?? envelope.from,
            publicKey: authenticatedNode.publicKey,
            roles: authenticatedNode.roles,
            endpoint: remoteAddress,
            status: .online,
            lastSeenAt: Date(),
            capabilities: authenticatedNode.capabilities,
            encryptionPublicKey: payload["encryptionPublicKey"]?.asString,
            encryptionKeySignature: payload["encryptionKeySignature"]?.asString
        )
    }

    private func stringArray(_ value: JSONValue?) -> [String] {
        guard case let .array(values) = value else {
            return []
        }
        return values.compactMap(\.asString)
    }

    private func sendUnavailableTargetError(for envelope: MeshEnvelope, target: String) async throws {
        guard let source = connections[envelope.from] else {
            return
        }
        if envelope.type == .streamOpen || envelope.type == .streamChunk || envelope.type == .streamClose {
            try await sendStreamClose(for: envelope, message: "Target node is not connected.")
            return
        }
        let errorEnvelope = MeshEnvelope(
            type: .rpcResponse,
            from: "relay",
            to: envelope.from,
            scope: envelope.scope,
            payload: .object([
                "requestId": .string(envelope.id),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("node_unavailable"),
                    "target": .string(target),
                    "message": .string("Target node is not connected."),
                ]),
            ])
        )
        try await send(errorEnvelope, over: source.context)
        persist {
            try store?.recordRouteFailure(envelope, target: target, message: "target node unavailable")
        }
    }

    private func sendStreamClose(for envelope: MeshEnvelope, message: String) async throws {
        guard let source = connections[envelope.from],
              let streamID = envelope.payload.asObject?["streamId"]?.asString else {
            return
        }
        if let stream = activeStreams[streamID], stream.source == envelope.from, stream.target == envelope.to {
            activeStreams[streamID] = nil
        }
        try await send(
            MeshEnvelope(
                type: .streamClose,
                from: "relay",
                to: envelope.from,
                payload: .object([
                    "streamId": .string(streamID),
                    "ok": .bool(false),
                    "message": .string(message),
                ])
            ),
            over: source.context
        )
    }

    private func sendForbiddenRPCResponse(for envelope: MeshEnvelope, message: String) async throws {
        guard let source = connections[envelope.from] else {
            return
        }
        let errorEnvelope = MeshEnvelope(
            type: .rpcResponse,
            from: "relay",
            to: envelope.from,
            scope: envelope.scope,
            payload: .object([
                "requestId": .string(envelope.id),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("forbidden"),
                    "message": .string(message),
                ]),
            ])
        )
        try await send(errorEnvelope, over: source.context)
    }

    private func sendAuthFailure(to nodeId: String, message: String, over connection: WebSocketConnectionContext) async throws {
        let errorEnvelope = MeshEnvelope(
            type: .rpcResponse,
            from: "relay",
            to: nodeId.isEmpty ? nil : nodeId,
            payload: .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string("auth_failed"),
                    "message": .string(message),
                ]),
            ])
        )
        try await send(errorEnvelope, over: connection)
    }

    private func send(_ envelope: MeshEnvelope, over connection: WebSocketConnectionContext) async throws {
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }
        _ = await connection.sendText(text)
    }

    private func persist(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            logger.warning("Node mesh persistence failed", metadata: ["error": .string(String(describing: error))])
        }
    }
}
