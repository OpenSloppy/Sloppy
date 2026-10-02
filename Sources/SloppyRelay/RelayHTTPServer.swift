import Foundation
import Logging
import ManagedRelayCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import PostgresNIO
import SloppyRemoteProtocol

struct RelayHTTPResponse: Sendable {
    var status: HTTPResponseStatus
    var body: Data
    var contentType: String = "application/json"
    var headers: [(String, String)] = []

    static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return RelayHTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ code: String, status: HTTPResponseStatus) -> Self {
        json(["error": code], status: status)
    }

    static func html(_ value: String) -> Self {
        RelayHTTPResponse(status: .ok, body: Data(value.utf8), contentType: "text/html; charset=utf-8")
    }
}

actor RelayHTTPRouter {
    private let coordinator: ManagedRelayCoordinator
    private let store: ManagedRelayPostgresStore
    private let publicOrigin: String
    private let decoder: JSONDecoder

    init(coordinator: ManagedRelayCoordinator, store: ManagedRelayPostgresStore, publicURL: URL) {
        self.coordinator = coordinator
        self.store = store
        var components = URLComponents()
        components.scheme = publicURL.scheme
        components.host = publicURL.host
        components.port = publicURL.port
        publicOrigin = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func authorizeWebSocket(headers: HTTPHeaders) async -> Bool {
        guard let token = bearerToken(headers) else { return false }
        return (try? await coordinator.authorize(token: token)) != nil
    }

    func handle(method: HTTPMethod, uri: String, headers: HTTPHeaders, body: Data) async -> RelayHTTPResponse {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let segments = path.split(separator: "/").map(String.init)
        if method == .GET && (path == "/healthz" || path == "/health") {
            return .json(["status": "ok"])
        }
        if method == .GET && path == "/admin" {
            var response = RelayHTTPResponse.html(RelayAdminPage.html)
            response.headers.append((
                "Content-Security-Policy",
                "default-src 'none'; connect-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
            ))
            return response
        }
        if method == .GET && path == "/readyz" {
            do {
                _ = try await store.client.query("SELECT 1")
                return .json(["status": "ready"])
            } catch {
                return .error("database_unavailable", status: .serviceUnavailable)
            }
        }

        do {
            if method == .POST && path == "/v1/internal/presence" {
                struct Input: Decodable { var deviceIDs: Set<UUID> }
                struct Output: Encodable { var onlineDeviceIDs: Set<UUID> }
                let payload = try decode(Input.self, body)
                return .json(Output(onlineDeviceIDs: try await coordinator.connectionPresence(deviceIDs: payload.deviceIDs, credential: headers.first(name: "Authorization"))))
            }
            if method == .POST && path == "/v1/admin/auth/challenge" {
                let payload = try decode(ChallengeRequest.self, body)
                let result = try await coordinator.adminChallenge(deviceID: payload.deviceID)
                return .json(ChallengeResponse(id: result.id, nonce: result.nonce))
            }
            if method == .POST && path == "/v1/admin/auth/session" {
                let payload = try decode(SessionRequest.self, body)
                let result = try await coordinator.authenticateAdmin(
                    challengeID: payload.challengeID,
                    signature: payload.signature
                )
                var response = RelayHTTPResponse.json(["expiresAt": ISO8601DateFormatter().string(from: result.expiresAt)])
                response.headers.append((
                    "Set-Cookie",
                    "__Host-sloppy-relay-admin=\(result.token); Path=/; Max-Age=900; Secure; HttpOnly; SameSite=Strict"
                ))
                return response
            }
            if path.hasPrefix("/v1/admin/") {
                guard let token = adminCookie(headers),
                      let admin = try await store.adminDevice(forSessionToken: token) else {
                    return .error("unauthorized", status: .unauthorized)
                }
                if method != .GET && !validAdminMutation(headers) {
                    return .error("invalid_origin", status: .forbidden)
                }
                if method == .GET && path == "/v1/admin/spaces" {
                    return .json(try await store.listSpaces())
                }
                if method == .GET && path == "/v1/admin/invites" {
                    return .json(try await store.listInvites())
                }
                if method == .GET && path == "/v1/admin/audit" {
                    return .json(try await store.listAuditEvents())
                }
                if method == .GET && path == "/v1/admin/metrics" {
                    let healthy = (try? await store.client.query("SELECT 1")) != nil
                    return .json(AdminMetricsResponse(
                        relay: await coordinator.metrics(), databaseHealthy: healthy
                    ))
                }
                if segments.count == 5 && segments[0] == "v1" &&
                    segments[1] == "admin" && segments[2] == "spaces" &&
                    segments[4] == "devices" && method == .GET,
                    let id = UUID(uuidString: segments[3]) {
                    return .json(try await store.listDeviceSummaries(spaceID: id))
                }
                if segments.count == 4 && segments[0] == "v1" &&
                    segments[1] == "admin" && segments[2] == "devices" &&
                    method == .DELETE, let id = UUID(uuidString: segments[3]) {
                    _ = try await store.revokeDeviceAsAdmin(id: id)
                    await coordinator.disconnectDevice(id)
                    return .json(["status": "revoked"])
                }
                if method == .POST && path == "/v1/admin/invites" {
                    let payload = try decode(AdminInviteRequest.self, body)
                    guard (1...1440).contains(payload.ttlMinutes) else {
                        return .error("invalid_ttl", status: .badRequest)
                    }
                    let invite = try await store.createServiceInvite(
                        adminDeviceID: admin.id,
                        expiresAt: Date().addingTimeInterval(Double(payload.ttlMinutes * 60))
                    )
                    return .json(["invite": invite], status: .created)
                }
                if segments.count == 4 && segments[0] == "v1" &&
                    segments[1] == "admin" && segments[2] == "invites" &&
                    method == .DELETE, let id = UUID(uuidString: segments[3]) {
                    try await store.revokeInvite(id: id)
                    return .json(["status": "revoked"])
                }
                if segments.count == 5 && segments[0] == "v1" &&
                    segments[1] == "admin" && segments[2] == "spaces" &&
                    method == .POST, let id = UUID(uuidString: segments[3]),
                    segments[4] == "suspend" || segments[4] == "resume" {
                    try await store.setSpaceSuspended(
                        id: id,
                        suspended: segments[4] == "suspend"
                    )
                    if segments[4] == "suspend" {
                        await coordinator.disconnectSpace(id)
                    }
                    return .json(["status": segments[4] == "suspend" ? "suspended" : "active"])
                }
                return .error("not_found", status: .notFound)
            }
            if method == .POST && path == "/v1/enrollments/consume" {
                let payload = try decode(EnrollmentRequest.self, body)
                let result = try await coordinator.enroll(
                    invite: payload.invite,
                    hostName: payload.hostName,
                    signingPublicKey: payload.signingPublicKey,
                    encryptionPublicKey: payload.encryptionPublicKey,
                    encryptionKeySignature: payload.encryptionKeySignature
                )
                return .json(result, status: .created)
            }
            if method == .POST && path == "/v1/device-auth/challenge" {
                let payload = try decode(ChallengeRequest.self, body)
                let result = try await coordinator.challenge(deviceID: payload.deviceID)
                return .json(ChallengeResponse(id: result.id, nonce: result.nonce))
            }
            if method == .POST && path == "/v1/device-auth/session" {
                let payload = try decode(SessionRequest.self, body)
                return .json(try await coordinator.authenticate(
                    challengeID: payload.challengeID,
                    signature: payload.signature
                ))
            }
            if method == .POST && path == "/v1/recovery" {
                let payload = try decode(RecoveryRequest.self, body)
                return .json(try await coordinator.recover(
                    spaceID: payload.spaceID,
                    code: payload.code,
                    name: payload.name,
                    signingPublicKey: payload.signingPublicKey,
                    encryptionPublicKey: payload.encryptionPublicKey,
                    encryptionKeySignature: payload.encryptionKeySignature
                ), status: .created)
            }
            if segments.count == 4 && segments[0] == "v1" &&
                segments[1] == "device-pairings" && segments[3] == "claim" &&
                method == .POST, let id = UUID(uuidString: segments[2]) {
                let payload = try decode(PairingClaimRequest.self, body)
                try await coordinator.claimPairing(
                    id: id,
                    nonce: payload.nonce,
                    deviceID: payload.deviceID,
                    kind: payload.kind,
                    name: payload.name,
                    signingPublicKey: payload.signingPublicKey,
                    encryptionPublicKey: payload.encryptionPublicKey,
                    encryptionKeySignature: payload.encryptionKeySignature,
                    claimSignature: payload.claimSignature
                )
                return .json(["status": "pending"], status: .accepted)
            }
            if segments.count == 4 && segments[0] == "v1" &&
                segments[1] == "device-pairings" && segments[3] == "status" &&
                method == .GET, let id = UUID(uuidString: segments[2]),
                let nonce = pairingNonce(headers) {
                return .json(try await coordinator.pairingStatus(id: id, nonce: nonce))
            }

            guard let token = bearerToken(headers) else {
                return .error("unauthorized", status: .unauthorized)
            }
            if method == .GET && path == "/v1/remote/me" {
                return .json(try await coordinator.authorize(token: token))
            }
            if method == .GET && (path == "/v1/remote/devices" || path == "/v1/remote/hosts") {
                let devices = try await coordinator.listDevices(token: token)
                return .json(path.hasSuffix("/hosts") ? devices.filter { $0.kind == .host } : devices)
            }
            if method == .GET && path == "/v1/remote/device-pairings" {
                return .json(try await coordinator.pendingPairings(token: token))
            }
            if method == .POST && path == "/v1/remote/device-pairings" {
                let payload = try decode(PairingCreateRequest.self, body)
                return .json(try await coordinator.createPairing(token: token, kind: payload.kind), status: .created)
            }
            if method == .POST && path == "/v1/remote/recovery-codes/rotate" {
                return .json(["codes": try await coordinator.rotateRecoveryCodes(token: token)])
            }
            if segments.count == 5 && segments[0] == "v1" &&
                segments[1] == "remote" && segments[2] == "device-pairings" &&
                method == .POST, let id = UUID(uuidString: segments[3]),
                segments[4] == "approve" || segments[4] == "reject" {
                let result = try await coordinator.decidePairing(
                    id: id, token: token, approve: segments[4] == "approve"
                )
                return .json(PairingDecisionResponse(device: result))
            }
            if segments.count == 4 && segments[0] == "v1" &&
                segments[1] == "remote" && segments[2] == "devices" &&
                method == .DELETE, let id = UUID(uuidString: segments[3]) {
                try await coordinator.revokeDevice(id: id, token: token)
                return .json(["status": "revoked"])
            }
            return .error("not_found", status: .notFound)
        } catch let error as ManagedRelayError {
            switch error {
            case .unauthorized, .invalidSignature, .challengeExpired:
                return .error("unauthorized", status: .unauthorized)
            case .forbidden, .crossSpaceRoute:
                return .error("forbidden", status: .forbidden)
            case .hostOffline:
                return .error("host_offline", status: .serviceUnavailable)
            case .inviteConsumed, .pairingAlreadyClaimed, .pairingNotPending:
                return .error("conflict", status: .conflict)
            default:
                return .error("invalid_request", status: .badRequest)
            }
        } catch let transaction as PostgresTransactionError {
            if let domain = transaction.closureError as? ManagedRelayError {
                switch domain {
                case .invalidRecoveryCode, .invalidPairing:
                    return .error("invalid_request", status: .badRequest)
                case .forbidden:
                    return .error("forbidden", status: .forbidden)
                default:
                    return .error("conflict", status: .conflict)
                }
            }
            if let database = transaction.closureError as? ManagedRelayDatabaseError,
               case .inviteUnavailable = database {
                return .error("invite_unavailable", status: .conflict)
            }
            return .error("database_unavailable", status: .serviceUnavailable)
        } catch is DecodingError {
            return .error("invalid_request", status: .badRequest)
        } catch let database as ManagedRelayDatabaseError {
            if case .inviteUnavailable = database {
                return .error("invite_unavailable", status: .conflict)
            }
            return .error("invalid_request", status: .badRequest)
        } catch {
            return .error("database_unavailable", status: .serviceUnavailable)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    private func bearerToken(_ headers: HTTPHeaders) -> String? {
        let value = headers.first(name: "Authorization") ?? ""
        guard value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pairingNonce(_ headers: HTTPHeaders) -> String? {
        let value = headers.first(name: "Authorization") ?? ""
        guard value.lowercased().hasPrefix("pairing ") else { return nil }
        return String(value.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func adminCookie(_ headers: HTTPHeaders) -> String? {
        let cookies = headers.first(name: "Cookie") ?? ""
        return cookies.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.hasPrefix("__Host-sloppy-relay-admin=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init)
    }

    private func validAdminMutation(_ headers: HTTPHeaders) -> Bool {
        guard headers.first(name: "X-Sloppy-Admin-Action") == "1",
              let origin = headers.first(name: "Origin"),
              origin == publicOrigin else { return false }
        return true
    }
}

private struct EnrollmentRequest: Decodable {
    var invite: String
    var hostName: String
    var signingPublicKey: Data
    var encryptionPublicKey: Data
    var encryptionKeySignature: Data
}

private struct ChallengeRequest: Decodable { var deviceID: UUID }
private struct ChallengeResponse: Encodable { var id: UUID; var nonce: Data }
private struct SessionRequest: Decodable { var challengeID: UUID; var signature: Data }
private struct RecoveryRequest: Decodable {
    var spaceID: UUID
    var code: String
    var name: String
    var signingPublicKey: Data
    var encryptionPublicKey: Data
    var encryptionKeySignature: Data
}
private struct PairingCreateRequest: Decodable { var kind: RemoteDeviceKind }
private struct PairingClaimRequest: Decodable {
    var nonce: String
    var deviceID: UUID
    var kind: RemoteDeviceKind
    var name: String
    var signingPublicKey: Data
    var encryptionPublicKey: Data
    var encryptionKeySignature: Data
    var claimSignature: Data
}
private struct PairingDecisionResponse: Encodable { var device: RemoteDevice? }
private struct AdminInviteRequest: Decodable { var ttlMinutes: Int }
private struct AdminMetricsResponse: Encodable {
    var relay: ManagedRelayMetricsSnapshot
    var databaseHealthy: Bool
}

private final class RelayChannelHandle: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }

    func onEventLoop(_ action: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            context.eventLoop.execute {
                action()
                continuation.resume()
            }
        }
    }

    func sendHTTP(_ response: RelayHTTPResponse, version: HTTPVersion) {
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: String(response.body.count))
            headers.add(name: "Cache-Control", value: "no-store")
            for (name, value) in response.headers {
                headers.add(name: name, value: value)
            }
            self.context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(
                version: version, status: response.status, headers: headers
            ))), promise: nil)
            var output = self.context.channel.allocator.buffer(capacity: response.body.count)
            output.writeBytes(response.body)
            self.context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(output))), promise: nil)
            self.context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }

    func sendWebSocket(_ data: Data) async -> Bool {
        guard context.channel.isActive else { return false }
        context.eventLoop.execute {
            var buffer = self.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            self.context.writeAndFlush(NIOAny(WebSocketFrame(
                fin: true, opcode: .text, data: buffer
            )), promise: nil)
        }
        return true
    }

    func close() async {
        context.eventLoop.execute { self.context.close(promise: nil) }
    }
}

final class RelayHTTPServer {
    private let host: String
    private let port: Int
    private let router: RelayHTTPRouter
    private let coordinator: ManagedRelayCoordinator
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    init(host: String, port: Int, router: RelayHTTPRouter, coordinator: ManagedRelayCoordinator) {
        self.host = host
        self.port = port
        self.router = router
        self.coordinator = coordinator
        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { [router, coordinator] channel in
                let http = RelayHTTPHandler(router: router)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 4 * 1024 * 1024,
                    shouldUpgrade: { channel, head in
                        let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                        Task {
                            let isRelayPath = head.uri == "/v1/relay/ws"
                            let isAuthorized = await router.authorizeWebSocket(headers: head.headers)
                            let accepted = isRelayPath && isAuthorized
                            channel.eventLoop.execute {
                                if accepted { promise.succeed(HTTPHeaders()) }
                                else { promise.fail(ManagedRelayError.unauthorized) }
                            }
                        }
                        return promise.futureResult
                    },
                    upgradePipelineHandler: { channel, head in
                        channel.pipeline.addHandler(
                            RelayWebSocketHandler(
                                coordinator: coordinator,
                                authorization: head.headers.first(name: "Authorization") ?? ""
                            )
                        )
                    }
                )
                let configuration = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    completionHandler: { context in
                        _ = context.pipeline.syncOperations.removeHandler(http)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: configuration)
                    .flatMap { channel.pipeline.addHandler(http) }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    func wait() throws {
        try channel?.closeFuture.wait()
    }
}

private final class RelayHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RelayHTTPRouter
    private var head: HTTPRequestHead?
    private var body = Data()
    private var oversized = false

    init(router: RelayHTTPRouter) { self.router = router }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
            oversized = false
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= 65_536 else {
                oversized = true
                body = Data()
                return
            }
            guard !oversized else { return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            if oversized {
                RelayChannelHandle(context).sendHTTP(
                    .error("request_too_large", status: HTTPResponseStatus(statusCode: 413)),
                    version: head.version
                )
                oversized = false
                return
            }
            let requestBody = body
            body = Data()
            let router = self.router
            let handle = RelayChannelHandle(context)
            Task {
                let response = await router.handle(
                    method: head.method,
                    uri: head.uri,
                    headers: head.headers,
                    body: requestBody
                )
                handle.sendHTTP(response, version: head.version)
            }
        }
    }
}

private final class RelayWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let coordinator: ManagedRelayCoordinator
    private let authorization: String
    private var identity: (deviceID: UUID, connectionID: UUID)?
    private var pendingFrameTask: Task<Void, Never>?

    init(coordinator: ManagedRelayCoordinator, authorization: String) {
        self.coordinator = coordinator
        self.authorization = authorization
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let token = String(authorization.dropFirst(7))
        let handle = RelayChannelHandle(context)
        Task {
            do {
                let attached = try await coordinator.attach(
                    token: token,
                    send: { data in await handle.sendWebSocket(data) },
                    close: { await handle.close() }
                )
                await handle.onEventLoop { self.identity = attached }
                if let ready = try? JSONEncoder().encode(RemoteRelayReadyFrame()) {
                    _ = await handle.sendWebSocket(ready)
                }
            } catch {
                await handle.close()
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.opcode == .ping {
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(
                fin: true, opcode: .pong, data: frame.data
            )), promise: nil)
            return
        }
        guard frame.opcode == .text, let identity else { return }
        var buffer = frame.unmaskedData
        guard let data = buffer.readData(length: buffer.readableBytes),
              let envelope = try? JSONDecoder().decode(RemoteSealedEnvelope.self, from: data) else {
            context.close(promise: nil)
            return
        }
        let handle = RelayChannelHandle(context)
        let previous = pendingFrameTask
        pendingFrameTask = Task {
            await previous?.value
            do {
                try await coordinator.route(
                    envelope,
                    senderID: identity.deviceID,
                    connectionID: identity.connectionID
                )
            } catch ManagedRelayError.hostOffline {
                if let response = try? JSONEncoder().encode(RemoteRelayControlFrame(
                    envelopeID: envelope.id, code: "host_offline"
                )) {
                    _ = await handle.sendWebSocket(response)
                }
            } catch {
                await handle.close()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pendingFrameTask?.cancel()
        pendingFrameTask = nil
        if let identity {
            Task {
                await coordinator.detach(deviceID: identity.deviceID, connectionID: identity.connectionID)
            }
        }
        context.fireChannelInactive()
    }
}
