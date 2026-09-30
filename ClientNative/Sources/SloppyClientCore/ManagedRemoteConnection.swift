import Foundation
import SloppyRemoteProtocol

public actor ManagedRemoteConnection {
    public static let shared = ManagedRemoteConnection()
    public typealias CoreRequestHandler = @Sendable (RemoteCoreRequest) async -> RemoteCoreResponse
    public typealias StreamFrameHandler = @Sendable (
        UUID, String, RemoteStreamFrame
    ) async -> Void

    private let client: ManagedRemoteClient
    private var socket: URLSessionWebSocketTask?
    private var socketExpiresAt: Date?
    private var socketReady = false
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var device: RemoteDevice?
    private var keys: RemoteDeviceKeys?
    private var directory: [UUID: RemoteDevice] = [:]
    private var pending: [UUID: CheckedContinuation<RemoteCoreResponse, Error>] = [:]
    private var requestByEnvelope: [UUID: UUID] = [:]
    private var streamByEnvelope: [UUID: UUID] = [:]
    private var handler: CoreRequestHandler?
    private var streamHandler: StreamFrameHandler?
    private var streams: [UUID: AsyncStream<RemoteStreamFrame>.Continuation] = [:]

    public init(client: ManagedRemoteClient = ManagedRemoteClient()) {
        self.client = client
    }

    public func setCoreRequestHandler(_ handler: CoreRequestHandler?) {
        self.handler = handler
    }

    public func setStreamFrameHandler(_ handler: StreamFrameHandler?) {
        streamHandler = handler
    }

    public func connect() async throws {
        if socket != nil, let socketExpiresAt,
           socketExpiresAt > Date().addingTimeInterval(30) {
            if socketReady { return }
            try await waitForReady()
            return
        }
        if socket != nil { disconnect() }
        guard let credential = ManagedRemoteCredentialStore.load(),
              let keys = credential.keys else {
            throw ManagedRemoteError.notEnrolled
        }
        let session = try await client.authenticate()
        let devices = try await client.devices()
        var components = URLComponents(url: credential.relayURL, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.path = "/v1/relay/ws"
        guard let url = components?.url else { throw ManagedRemoteError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        self.socketExpiresAt = session.expiresAt
        self.socketReady = false
        self.device = session.device
        self.keys = keys
        self.directory = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        socket.resume()
        receiveTask = Task { await receiveLoop(socket: socket) }
        try await waitForReady()
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketExpiresAt = nil
        socketReady = false
        for waiter in readyWaiters.values {
            waiter.resume(throwing: ManagedRemoteError.invalidResponse)
        }
        readyWaiters.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: ManagedRemoteError.invalidResponse)
        }
        pending.removeAll()
        requestByEnvelope.removeAll()
        streamByEnvelope.removeAll()
        for continuation in streams.values { continuation.finish() }
        streams.removeAll()
    }

    public var isConnected: Bool { socket != nil }

    private func waitForReady() async throws {
        if socketReady { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(10))
                readyWaiters.removeValue(forKey: id)?.resume(throwing: ManagedRemoteError.timeout)
            }
        }
    }

    public func sendCoreRequest(
        to hostID: UUID,
        method: String,
        path: String,
        body: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> RemoteCoreResponse {
        try await connect()
        let request = RemoteCoreRequest(method: method, path: path, body: body)
        let result = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RemoteCoreResponse, Error>) in
            pending[request.requestID] = continuation
            Task {
                do {
                    try await send(
                        request,
                        kind: "core.http",
                        to: hostID,
                        requestID: request.requestID
                    )
                } catch {
                    fail(requestID: request.requestID, error: error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                fail(requestID: request.requestID, error: ManagedRemoteError.timeout)
            }
        }
        return result
    }

    public func openStream(
        to hostID: UUID,
        kind: String,
        path: String
    ) async throws -> (id: UUID, frames: AsyncStream<RemoteStreamFrame>) {
        guard kind == "session.stream" || kind == "terminal.stream" || kind == "preview.stream" else {
            throw ManagedRemoteError.invalidResponse
        }
        try await connect()
        let id = UUID()
        let frames = AsyncStream<RemoteStreamFrame> { continuation in
            streams[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.closeStream(id: id, hostID: hostID, kind: kind)
                }
            }
        }
        do {
            try await send(
                RemoteStreamFrame(streamID: id, action: .open, path: path),
                kind: kind,
                to: hostID,
                streamID: id
            )
        } catch {
            streams.removeValue(forKey: id)?.finish()
            throw error
        }
        return (id, frames)
    }

    public func sendStreamData(
        id: UUID,
        hostID: UUID,
        kind: String,
        data: Data
    ) async throws {
        try await send(
            RemoteStreamFrame(streamID: id, action: .data, data: data),
            kind: kind,
            to: hostID
        )
    }

    public func sendStreamReply(
        _ frame: RemoteStreamFrame,
        to deviceID: UUID,
        kind: String
    ) async throws {
        try await send(frame, kind: kind + ".response", to: deviceID)
    }

    public func closeStream(id: UUID, hostID: UUID, kind: String) async {
        streams[id] = nil
        streamByEnvelope = streamByEnvelope.filter { $0.value != id }
        try? await send(
            RemoteStreamFrame(streamID: id, action: .close),
            kind: kind,
            to: hostID
        )
    }

    private func send<Payload: Encodable>(
        _ payload: Payload,
        kind: String,
        to recipientID: UUID,
        requestID: UUID? = nil,
        streamID: UUID? = nil
    ) async throws {
        guard let socket, let device, let keys,
              let recipient = directory[recipientID] else {
            throw ManagedRemoteError.invalidResponse
        }
        var envelope = RemoteSealedEnvelope(
            from: device.id,
            to: recipientID,
            kind: kind,
            ciphertext: Data()
        )
        envelope.ciphertext = try keys.seal(
            JSONEncoder().encode(payload),
            envelope: envelope,
            recipientPublicKey: recipient.encryptionPublicKey
        )
        let text = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        if let requestID { requestByEnvelope[envelope.id] = requestID }
        if let streamID { streamByEnvelope[envelope.id] = streamID }
        do {
            try await socket.send(.string(text))
        } catch {
            requestByEnvelope[envelope.id] = nil
            streamByEnvelope[envelope.id] = nil
            throw error
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                try await handleFrame(data)
            }
        } catch {
            if self.socket === socket {
                disconnect()
            }
        }
    }

    private func handleFrame(_ data: Data) async throws {
        if let ready = try? JSONDecoder().decode(RemoteRelayReadyFrame.self, from: data),
           ready.type == "relay_ready" {
            socketReady = true
            for waiter in readyWaiters.values { waiter.resume() }
            readyWaiters.removeAll()
            return
        }
        if let control = try? JSONDecoder().decode(RemoteRelayControlFrame.self, from: data),
           control.type == "relay_error" {
            let error: ManagedRemoteError = control.code == "host_offline"
                ? .hostOffline : .invalidResponse
            if let requestID = requestByEnvelope.removeValue(forKey: control.envelopeID) {
                fail(requestID: requestID, error: error)
            }
            if let streamID = streamByEnvelope.removeValue(forKey: control.envelopeID) {
                streams.removeValue(forKey: streamID)?.finish()
            }
            return
        }
        guard let keys else { throw ManagedRemoteError.notEnrolled }
        let envelope = try JSONDecoder().decode(RemoteSealedEnvelope.self, from: data)
        if directory[envelope.from] == nil {
            let devices = try await client.devices()
            directory = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        }
        guard let sender = directory[envelope.from],
              sender.spaceID == device?.spaceID,
              RemoteDeviceKeys.verifyEncryptionKey(
                signingPublicKey: sender.signingPublicKey,
                encryptionPublicKey: sender.encryptionPublicKey,
                signature: sender.encryptionKeySignature
              ) else {
            throw ManagedRemoteError.invalidResponse
        }
        let plaintext = try keys.open(envelope, senderPublicKey: sender.encryptionPublicKey)
        switch envelope.kind {
        case "core.http.response":
            let response = try JSONDecoder().decode(RemoteCoreResponse.self, from: plaintext)
            requestByEnvelope = requestByEnvelope.filter { $0.value != response.requestID }
            pending.removeValue(forKey: response.requestID)?.resume(returning: response)
        case "core.http":
            guard let handler else { throw ManagedRemoteError.invalidResponse }
            let request = try JSONDecoder().decode(RemoteCoreRequest.self, from: plaintext)
            let response = await handler(request)
            try await send(response, kind: "core.http.response", to: sender.id)
        case "session.stream", "terminal.stream", "preview.stream":
            guard let streamHandler else { throw ManagedRemoteError.invalidResponse }
            let frame = try JSONDecoder().decode(RemoteStreamFrame.self, from: plaintext)
            await streamHandler(sender.id, envelope.kind, frame)
        case "session.stream.response", "terminal.stream.response", "preview.stream.response":
            let frame = try JSONDecoder().decode(RemoteStreamFrame.self, from: plaintext)
            streams[frame.streamID]?.yield(frame)
            if frame.action == .close {
                streamByEnvelope = streamByEnvelope.filter { $0.value != frame.streamID }
                streams.removeValue(forKey: frame.streamID)?.finish()
            }
        default:
            break
        }
    }

    private func fail(requestID: UUID, error: Error) {
        requestByEnvelope = requestByEnvelope.filter { $0.value != requestID }
        pending.removeValue(forKey: requestID)?.resume(throwing: error)
    }
}
