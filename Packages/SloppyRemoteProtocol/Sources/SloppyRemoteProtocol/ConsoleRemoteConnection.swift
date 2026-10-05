import Crypto
import Foundation
import SloppyConsoleProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ConsoleRemotePacket: Codable, Sendable {
    public var kind: String
    public var payload: Data
    public var proof: SignedInstanceAccessProof?
    public init(kind: String, payload: Data, proof: SignedInstanceAccessProof? = nil) { self.kind = kind; self.payload = payload; self.proof = proof }
}

protocol ConsoleRemoteTransport: Sendable {
    var messages: AsyncThrowingStream<Data, any Error> { get }
    func connect(url: URL, token: String) async throws
    func send(_ data: Data) async throws
    func close() async
}

extension RelayWebSocketConnection: ConsoleRemoteTransport {}

/// Pins are supplied by the local trust store or verified pairing, never by
/// the Relay directory. Every logical connection negotiates fresh TLS keys.
public actor ConsoleRemoteConnection {
    public typealias PacketHandler = @Sendable (UUID, Data, ConsoleRemotePacket) async throws -> ConsoleRemotePacket?
    private struct Peer {
        var sessionID: UUID
        var certificate: Data
        var tls: RemoteTLSChannel
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var ready = false
    }
    private let deviceID: UUID
    private let signingPrivateKey: Data
    private let identity: RemoteTLSIdentity
    private let relayURL: URL
    private var pins: [UUID: Data]
    private var peers: [UUID: Peer] = [:]
    private var connectTask: Task<Void, any Error>?
    private var connectID: UUID?
    private var socket: (any ConsoleRemoteTransport)?
    private var socketID: UUID?
    private struct PendingSend {
        let id: UUID
        let task: Task<Void, any Error>
    }
    private var pendingSends: [UUID: PendingSend] = [:]
    private let transportFactory: @Sendable () -> any ConsoleRemoteTransport
    private let authenticateDevice: (@Sendable () async throws -> ManagedDeviceSession)?
    private var receiveTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var handler: PacketHandler?
    private var disconnectHandler: (@Sendable () async -> Void)?
    public init(deviceID: UUID, signingPrivateKey: Data, identity: RemoteTLSIdentity, relayURL: URL, pins: [UUID: Data]) {
        self.deviceID = deviceID; self.signingPrivateKey = signingPrivateKey; self.identity = identity; self.relayURL = relayURL; self.pins = pins
        self.transportFactory = { RelayWebSocketConnection() }
        self.authenticateDevice = nil
    }
    init(deviceID: UUID, signingPrivateKey: Data, identity: RemoteTLSIdentity, relayURL: URL, pins: [UUID: Data], transportFactory: @escaping @Sendable () -> any ConsoleRemoteTransport, authenticateDevice: @escaping @Sendable () async throws -> ManagedDeviceSession) {
        self.deviceID = deviceID; self.signingPrivateKey = signingPrivateKey; self.identity = identity; self.relayURL = relayURL; self.pins = pins
        self.transportFactory = transportFactory
        self.authenticateDevice = authenticateDevice
    }
    public func setHandler(_ handler: @escaping PacketHandler) { self.handler = handler }
    public func setDisconnectHandler(_ handler: @escaping @Sendable () async -> Void) { disconnectHandler = handler }
    public func updatePins(_ pins: [UUID: Data]) async {
        self.pins = pins
        for (id, peer) in peers where pins[id] != peer.certificate {
            peers[id] = nil
            pendingSends.removeValue(forKey: id)?.task.cancel()
            await peer.tls.close()
        }
    }
    public func connect() async throws {
        if socket != nil { return }
        if let task = connectTask { try await task.value; return }
        let id = UUID()
        let task = Task { try await connectOnce() }
        connectID = id; connectTask = task
        do {
            try await task.value
            if connectID == id { connectTask = nil; connectID = nil }
        } catch {
            if connectID == id { connectTask = nil; connectID = nil }
            throw error
        }
    }
    private func connectOnce() async throws {
        if socket != nil { return }
        struct Challenge: Decodable { var id: UUID; var nonce: Data }
        struct Request: Encodable { var challengeID: UUID; var signature: Data }
        let session: ManagedDeviceSession
        if let authenticateDevice {
            session = try await authenticateDevice()
        } else {
            let challenge: Challenge = try await request("v1/device-auth/challenge", body: JSONEncoder().encode(["deviceID": deviceID.uuidString]))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
            session = try await request("v1/device-auth/session", body: JSONEncoder().encode(Request(challengeID: challenge.id, signature: key.signature(for: challenge.nonce))))
        }
        try Task.checkCancellation()
        guard session.device.id == deviceID, session.device.signingPublicKey == identity.signingPublicKey else { throw RemoteTLSError.invalidPeer }
        let socket = transportFactory(); try await socket.connect(url: relayURL, token: session.token)
        do { try Task.checkCancellation() }
        catch { await socket.close(); throw error }
        let connectionID = UUID()
        self.socket = socket
        socketID = connectionID
        receiveTask = Task { [weak self] in
            do { for try await data in socket.messages { try await self?.receive(data) } } catch {}
            await self?.disconnect(ifCurrent: connectionID)
        }
        expiryTask = Task { [weak self] in
            let delay = max(1, min(session.expiresAt.timeIntervalSinceNow, 300))
            try? await Task.sleep(for: .seconds(delay)); if !Task.isCancelled { await self?.disconnect(ifCurrent: connectionID) }
        }
    }
    private func disconnect(ifCurrent id: UUID) async {
        guard socketID == id else { return }
        await disconnect()
    }
    public func disconnect() async {
        connectTask?.cancel(); connectTask = nil; connectID = nil
        socketID = nil
        for send in pendingSends.values { send.task.cancel() }; pendingSends.removeAll()
        receiveTask?.cancel(); receiveTask = nil; expiryTask?.cancel(); expiryTask = nil
        let previous = socket; socket = nil
        let previousPeers = peers; peers.removeAll()
        if previous != nil { await disconnectHandler?() }
        await previous?.close()
        for peer in previousPeers.values { await peer.tls.close() }
    }
    public func send(_ packet: ConsoleRemotePacket, to peerID: UUID) async throws {
        // Actor reentrancy otherwise lets concurrent requests initialize different
        // sessions or emit encrypted records out of order for the same peer.
        let previous = pendingSends[peerID]?.task
        let id = UUID()
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await sendOnce(packet, to: peerID)
        }
        pendingSends[peerID] = PendingSend(id: id, task: task)
        do {
            try await task.value
            if pendingSends[peerID]?.id == id { pendingSends[peerID] = nil }
        } catch {
            if pendingSends[peerID]?.id == id { pendingSends[peerID] = nil }
            throw error
        }
    }
    private func sendOnce(_ packet: ConsoleRemotePacket, to peerID: UUID) async throws {
        try await connect()
        if peers[peerID] == nil {
            guard let certificate = pins[peerID], peers.count < 20 else { throw RemoteTLSError.invalidPeer }
            let tls = try await RemoteTLSChannel(identity: identity, peerCertificate: certificate, isClient: true)
            try Task.checkCancellation()
            guard pins[peerID] == certificate else { await tls.close(); throw RemoteTLSError.invalidPeer }
            peers[peerID] = Peer(sessionID: UUID(), certificate: certificate, tls: tls)
            try await emit(tls.start(), to: peerID)
        }
        let deadline = Date().addingTimeInterval(15)
        while peers[peerID]?.ready != true {
            try Task.checkCancellation()
            guard socket != nil, peers[peerID] != nil, Date() < deadline else { throw RemoteTLSError.handshakeIncomplete }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let peer = peers[peerID] else { throw RemoteTLSError.closed }
        try await emit(peer.tls.send(ConsoleWire.encode(packet)), to: peerID)
    }
    private func receive(_ data: Data) async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(RemoteSealedEnvelope.self, from: data) else { return } // relay_ready/control
        guard envelope.kind == RemoteTLSFrame.kind, envelope.to == deviceID,
              let certificate = pins[envelope.from] else { throw RemoteTLSError.invalidPeer }
        let frame = try ConsoleWire.decode(RemoteTLSFrame.self, from: envelope.ciphertext)
        guard frame.version == 2, frame.from == envelope.from, frame.to == deviceID else { throw RemoteTLSError.invalidFrame }
        if let previous = peers[frame.from], previous.sessionID != frame.sessionID {
            // A reconnect starts at sequence zero with fresh TLS keys. Keep the
            // verified certificate pin; do not reuse the previous TLS channel.
            guard frame.sequence == 0 else { throw RemoteTLSError.invalidFrame }
            peers[frame.from] = nil
            await previous.tls.close()
        }
        if peers[frame.from] == nil {
            guard frame.sequence == 0, peers.count < 20 else { throw RemoteTLSError.invalidFrame }
            peers[frame.from] = Peer(sessionID: frame.sessionID, certificate: certificate, tls: try await RemoteTLSChannel(identity: identity, peerCertificate: certificate, isClient: false))
        }
        guard var peer = peers[frame.from], peer.sessionID == frame.sessionID, peer.received == frame.sequence, peer.certificate == certificate else { throw RemoteTLSError.invalidFrame }
        peer.received += 1; peers[frame.from] = peer
        let result = try await peer.tls.receive(frame.records)
        try await emit(result, to: frame.from)
        if result.handshakeComplete { peers[frame.from]?.ready = true }
        for message in result.messages {
            let packet = try ConsoleWire.decode(ConsoleRemotePacket.self, from: message)
            if let reply = try await handler?(frame.from, certificate, packet) { try await send(reply, to: frame.from) }
        }
    }
    private func emit(_ result: RemoteTLSResult, to peerID: UUID) async throws {
        guard let socket else { throw RemoteTLSError.closed }
        // TLS splits large responses into small records. Batch them so a chat
        // transcript does not overflow the bounded WebSocket receive buffer.
        // One MiB leaves room for both layers of base64 in the Relay envelope.
        var batches: [Data] = []
        var batch = Data()
        for record in result.records {
            if !batch.isEmpty, batch.count + record.count > 1024 * 1024 {
                batches.append(batch)
                batch = Data()
            }
            batch.append(record)
        }
        if !batch.isEmpty { batches.append(batch) }
        for record in batches {
            guard var peer = peers[peerID] else { throw RemoteTLSError.closed }
            let frame = RemoteTLSFrame(sessionID: peer.sessionID, sequence: peer.sent, from: deviceID, to: peerID, records: record)
            peer.sent += 1; peers[peerID] = peer
            let envelope = RemoteSealedEnvelope(from: deviceID, to: peerID, kind: RemoteTLSFrame.kind, ciphertext: try ConsoleWire.encode(frame))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try await socket.send(encoder.encode(envelope))
        }
    }
    private func request<T: Decodable>(_ path: String, body: Data) async throws -> T {
        guard relayURL.scheme == "https" else { throw RemoteTLSError.invalidPeer }
        var request = URLRequest(url: relayURL.appendingPathComponent(path)); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 15; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RemoteTLSError.invalidPeer }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(T.self, from: data)
    }
}
