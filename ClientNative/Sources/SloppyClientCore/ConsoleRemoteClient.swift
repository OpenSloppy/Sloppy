import Crypto
import Foundation
import Security
import SloppyConsoleProtocol
import SloppyRemoteProtocol

public struct ConsoleDeviceCredential: Codable, Sendable {
    public var deviceID: UUID
    public var privateKey: Data
    public var tls: RemoteTLSIdentity
    public static func load() -> Self? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "team.sloppy.console.identity", kSecAttrAccount as String: "device", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        query.removeAll(); return try? ConsoleWire.decode(Self.self, from: data)
    }
    public static func createIfNeeded() throws -> Self {
        if let existing = load() { return existing }
        let key = Curve25519.Signing.PrivateKey(), id = UUID()
        let value = Self(deviceID: id, privateKey: key.rawRepresentation, tls: try RemoteTLSIdentity(signingPrivateKey: key.rawRepresentation, deviceID: id))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "team.sloppy.console.identity", kSecAttrAccount as String: "device", kSecValueData as String: try ConsoleWire.encode(value), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ConsoleTrustError.invalidConfiguration }; return value
    }
}

public actor ConsoleRemoteClientRegistry {
    public static let shared = ConsoleRemoteClientRegistry()
    private struct Connected {
        var instance: InstanceBinding
        var connection: ConsoleRemoteConnection
        var organizationID: UUID?
        var certificate: Data
    }
    private struct SavedPin: Codable { var instance: InstanceBinding; var certificate: Data; var organizationID: UUID? }
    private var savedPins: [UUID: SavedPin] = {
        guard let data = UserDefaults.standard.data(forKey: "sloppy.console.host-pins") else { return [:] }
        return (try? ConsoleWire.decode([UUID: SavedPin].self, from: data)) ?? [:]
    }()
    private var directoryHostIDs: Set<UUID> = []
    private var transport: ConsoleRemoteConnection?
    private struct StreamEntry { var hostID: UUID; var kind: String; var continuation: AsyncStream<RemoteStreamFrame>.Continuation }
    private var streams: [UUID: StreamEntry] = [:]
    private var connections: [UUID: Connected] = [:]
    private var requests: [UUID: CheckedContinuation<RemoteCoreResponse, any Error>] = [:]
    public func contains(hostID: UUID) -> Bool { directoryHostIDs.contains(hostID) || connections[hostID] != nil || savedPins[hostID] != nil }
    public func installDirectory(_ snapshot: ConsoleAccountClient.Snapshot) async -> Set<UUID> {
        directoryHostIDs = Set(snapshot.instances.map(\.hostDeviceID))
        var unverified: Set<UUID> = []
        for instance in snapshot.instances {
            let host = snapshot.devices.first { $0.id == instance.hostDeviceID && $0.status == .active }
            let trusted = host.map { host in
                savedPins[instance.hostDeviceID].map { pin in
                    Self.trustMatches(instance: instance, savedInstance: pin.instance, certificate: pin.certificate)
                        && pin.certificate == host.certificateDER
                } ?? false
            } ?? false
            if !trusted {
                unverified.insert(instance.hostDeviceID)
                savedPins[instance.hostDeviceID] = nil
                connections[instance.hostDeviceID] = nil
            }
        }
        UserDefaults.standard.set(try? ConsoleWire.encode(savedPins), forKey: "sloppy.console.host-pins")
        await transport?.updatePins(connections.mapValues { $0.certificate })
        return unverified
    }
    public func hasTrustedPin(for instance: InstanceBinding) -> Bool {
        guard let pin = savedPins[instance.hostDeviceID] else { return false }
        return Self.trustMatches(instance: instance, savedInstance: pin.instance, certificate: pin.certificate)
    }
    static func trustMatches(instance: InstanceBinding, savedInstance: InstanceBinding, certificate: Data) -> Bool {
        instance.status == .active
            && savedInstance.id == instance.id
            && savedInstance.hostDeviceID == instance.hostDeviceID
            && savedInstance.hostCertificateFingerprint == instance.hostCertificateFingerprint
            && ConsoleTrust.fingerprint(certificate) == instance.hostCertificateFingerprint
    }
    public func connect(instance: InstanceBinding, hostCertificate: Data, expectedFingerprint: String, organizationID: UUID?) async throws {
        guard expectedFingerprint.lowercased() == ConsoleTrust.fingerprint(hostCertificate),
              expectedFingerprint.lowercased() == instance.hostCertificateFingerprint else { throw ConsoleTrustError.invalidSignature }
        let credential = try ConsoleDeviceCredential.createIfNeeded()
        // Renew a human access proof before opening a Relay socket.
        _ = try await ConsoleAccountClient.shared.proof(instanceID: instance.id, deviceID: credential.deviceID, organizationID: organizationID)
        let connection: ConsoleRemoteConnection
        if let current = transport { connection = current }
        else {
            connection = ConsoleRemoteConnection(deviceID: credential.deviceID, signingPrivateKey: credential.privateKey, identity: credential.tls, relayURL: ManagedRemoteClient.productionURL, pins: [:])
            transport = connection
            await connection.setDisconnectHandler { [weak self] in await self?.transportDisconnected() }
            await connection.setHandler { [weak self] from, _, packet in
                guard let self else { return nil }
                if packet.kind == "core.http.response" { await self.complete(try ConsoleWire.decode(RemoteCoreResponse.self, from: packet.payload)) }
                else { try await self.receiveStream(senderID: from, packet: packet) }
                return nil
            }
        }
        savedPins[instance.hostDeviceID] = SavedPin(instance: instance, certificate: hostCertificate, organizationID: organizationID)
        UserDefaults.standard.set(try ConsoleWire.encode(savedPins), forKey: "sloppy.console.host-pins")
        connections[instance.hostDeviceID] = Connected(instance: instance, connection: connection, organizationID: organizationID, certificate: hostCertificate)
        await connection.updatePins(connections.mapValues { $0.certificate })
        try await connection.connect()
    }
    public func request(hostID: UUID, method: String, path: String, body: Data?) async throws -> RemoteCoreResponse {
        if connections[hostID] == nil, let saved = savedPins[hostID] {
            try await connect(instance: saved.instance, hostCertificate: saved.certificate, expectedFingerprint: saved.instance.hostCertificateFingerprint, organizationID: saved.organizationID)
        }
        guard let connected = connections[hostID], let credential = ConsoleDeviceCredential.load() else { throw ConsoleTrustError.forbidden }
        let proof = try await ConsoleAccountClient.shared.proof(instanceID: connected.instance.id, deviceID: credential.deviceID, organizationID: connected.organizationID)
        let request = RemoteCoreRequest(method: method, path: path, body: body)
        return try await withCheckedThrowingContinuation { continuation in
            requests[request.requestID] = continuation
            Task {
                do { try await connected.connection.send(ConsoleRemotePacket(kind: "core.http", payload: ConsoleWire.encode(request), proof: proof), to: hostID) }
                catch { fail(request.requestID, error: error) }
            }
            Task { try? await Task.sleep(for: .seconds(30)); fail(request.requestID, error: RemoteTLSError.closed) }
        }
    }
    public func openStream(hostID: UUID, kind: String, path: String) async throws -> (id: UUID, frames: AsyncStream<RemoteStreamFrame>) {
        if connections[hostID] == nil, let saved = savedPins[hostID] {
            try await connect(instance: saved.instance, hostCertificate: saved.certificate, expectedFingerprint: saved.instance.hostCertificateFingerprint, organizationID: saved.organizationID)
        }
        guard connections[hostID] != nil, streams.count < 20, ["session.stream", "terminal.stream", "preview.stream"].contains(kind) else { throw ConsoleTrustError.forbidden }
        let id = UUID(), pair = AsyncStream<RemoteStreamFrame>.makeStream(bufferingPolicy: .bufferingNewest(32))
        streams[id] = StreamEntry(hostID: hostID, kind: kind, continuation: pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.closeStream(id: id, hostID: hostID, kind: kind) } }
        do {
            try await sendStream(frame: RemoteStreamFrame(streamID: id, action: .open, path: path), hostID: hostID, kind: kind)
        } catch {
            streams.removeValue(forKey: id)?.continuation.finish()
            throw error
        }
        return (id, pair.stream)
    }
    public func sendStream(frame: RemoteStreamFrame, hostID: UUID, kind: String) async throws {
        if connections[hostID] == nil, let saved = savedPins[hostID] {
            try await connect(instance: saved.instance, hostCertificate: saved.certificate, expectedFingerprint: saved.instance.hostCertificateFingerprint, organizationID: saved.organizationID)
        }
        guard let connected = connections[hostID], let credential = ConsoleDeviceCredential.load() else { throw ConsoleTrustError.forbidden }
        let proof = try await ConsoleAccountClient.shared.proof(instanceID: connected.instance.id, deviceID: credential.deviceID, organizationID: connected.organizationID)
        try await connected.connection.send(ConsoleRemotePacket(kind: kind, payload: ConsoleWire.encode(frame), proof: proof), to: hostID)
        if frame.action == .close { streams.removeValue(forKey: frame.streamID)?.continuation.finish() }
    }
    private func closeStream(id: UUID, hostID: UUID, kind: String) async {
        // Finishing an already removed stream must not send a second close to
        // the host, which would reject it as an unknown stream.
        guard streams.removeValue(forKey: id) != nil else { return }
        try? await sendStream(frame: RemoteStreamFrame(streamID: id, action: .close), hostID: hostID, kind: kind)
    }
    private func receiveStream(senderID: UUID, packet: ConsoleRemotePacket) throws {
        let frame = try ConsoleWire.decode(RemoteStreamFrame.self, from: packet.payload)
        // Data already in flight may arrive after local cancellation or a
        // remote close. It must not tear down the shared Relay connection.
        guard let stream = streams[frame.streamID] else { return }
        guard stream.hostID == senderID, packet.kind == stream.kind + ".response" else { throw ConsoleTrustError.forbidden }
        if frame.action == .close { streams.removeValue(forKey: frame.streamID)?.continuation.finish() }
        else if case .dropped = stream.continuation.yield(frame) { streams.removeValue(forKey: frame.streamID)?.continuation.finish() }
    }
    private func transportDisconnected() {
        let pending = requests; requests.removeAll()
        for continuation in pending.values { continuation.resume(throwing: RemoteTLSError.closed) }
        let activeStreams = streams; streams.removeAll()
        for stream in activeStreams.values { stream.continuation.finish() }
    }
    public func disconnectAll() async {
        connections.removeAll(); await transport?.disconnect(); transport = nil
        for stream in streams.values { stream.continuation.finish() }; streams.removeAll()
        for continuation in requests.values { continuation.resume(throwing: RemoteTLSError.closed) }; requests.removeAll()
    }
    private func complete(_ response: RemoteCoreResponse) { requests.removeValue(forKey: response.requestID)?.resume(returning: response) }
    private func fail(_ id: UUID, error: any Error) { requests.removeValue(forKey: id)?.resume(throwing: error) }
}
