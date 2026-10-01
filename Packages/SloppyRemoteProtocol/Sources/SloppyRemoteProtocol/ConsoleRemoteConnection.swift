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
    private var socket: RelayWebSocketConnection?
    private var receiveTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var handler: PacketHandler?
    public init(deviceID: UUID, signingPrivateKey: Data, identity: RemoteTLSIdentity, relayURL: URL, pins: [UUID: Data]) {
        self.deviceID = deviceID; self.signingPrivateKey = signingPrivateKey; self.identity = identity; self.relayURL = relayURL; self.pins = pins
    }
    public func setHandler(_ handler: @escaping PacketHandler) { self.handler = handler }
    public func updatePins(_ pins: [UUID: Data]) async {
        self.pins = pins
        for (id, peer) in peers where pins[id] != peer.certificate { await peer.tls.close(); peers[id] = nil }
    }
    public func connect() async throws {
        if socket != nil { return }
        if let task = connectTask { try await task.value; return }
        let task = Task { try await connectOnce() }; connectTask = task
        do { try await task.value; connectTask = nil } catch { connectTask = nil; throw error }
    }
    private func connectOnce() async throws {
        if socket != nil { return }
        struct Challenge: Decodable { var id: UUID; var nonce: Data }
        struct Request: Encodable { var challengeID: UUID; var signature: Data }
        let challenge: Challenge = try await request("v1/device-auth/challenge", body: JSONEncoder().encode(["deviceID": deviceID.uuidString]))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        let session: ManagedDeviceSession = try await request("v1/device-auth/session", body: JSONEncoder().encode(Request(challengeID: challenge.id, signature: key.signature(for: challenge.nonce))))
        guard session.device.id == deviceID, session.device.signingPublicKey == identity.signingPublicKey else { throw RemoteTLSError.invalidPeer }
        let socket = RelayWebSocketConnection(); try await socket.connect(url: relayURL, token: session.token)
        self.socket = socket
        receiveTask = Task { [weak self] in
            do { for try await data in socket.messages { try await self?.receive(data) } } catch {}
            await self?.disconnect()
        }
        expiryTask = Task { [weak self] in
            let delay = max(1, min(session.expiresAt.timeIntervalSinceNow, 300))
            try? await Task.sleep(for: .seconds(delay)); if !Task.isCancelled { await self?.disconnect() }
        }
    }
    public func disconnect() async {
        receiveTask?.cancel(); receiveTask = nil; expiryTask?.cancel(); expiryTask = nil
        let previous = socket; socket = nil; await previous?.close()
        for peer in peers.values { await peer.tls.close() }; peers.removeAll()
    }
    public func send(_ packet: ConsoleRemotePacket, to peerID: UUID) async throws {
        try await connect()
        if peers[peerID] == nil {
            guard let certificate = pins[peerID], peers.count < 20 else { throw RemoteTLSError.invalidPeer }
            let tls = try await RemoteTLSChannel(identity: identity, peerCertificate: certificate, isClient: true)
            peers[peerID] = Peer(sessionID: UUID(), certificate: certificate, tls: tls)
            try await emit(tls.start(), to: peerID)
        }
        let deadline = Date().addingTimeInterval(15)
        while peers[peerID]?.ready != true {
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
        if peers[frame.from] == nil {
            guard frame.sequence == 0, peers.count < 20 else { throw RemoteTLSError.invalidFrame }
            peers[frame.from] = Peer(sessionID: frame.sessionID, certificate: certificate, tls: try await RemoteTLSChannel(identity: identity, peerCertificate: certificate, isClient: false))
        }
        guard var peer = peers[frame.from], peer.sessionID == frame.sessionID, peer.received == frame.sequence, peer.certificate == certificate else { throw RemoteTLSError.invalidFrame }
        peer.received += 1; peers[frame.from] = peer
        let result = try await peer.tls.receive(frame.records)
        if result.handshakeComplete { peers[frame.from]?.ready = true }
        try await emit(result, to: frame.from)
        for message in result.messages {
            let packet = try ConsoleWire.decode(ConsoleRemotePacket.self, from: message)
            if let reply = try await handler?(frame.from, certificate, packet) { try await send(reply, to: frame.from) }
        }
    }
    private func emit(_ result: RemoteTLSResult, to peerID: UUID) async throws {
        guard let socket else { throw RemoteTLSError.closed }
        for record in result.records {
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
