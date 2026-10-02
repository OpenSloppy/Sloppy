import Foundation
import SloppyRemoteProtocol

public struct ManagedRelayMetricsSnapshot: Codable, Sendable {
    public var activeSessions: Int
    public var hostsOnline: Int
    public var pairingsApproved: Int64
    public var pairingsRejected: Int64
    public var authFailures: Int64
    public var crossTenantDenials: Int64
    public var routedEnvelopes: Int64
    public var meanRelayLatencyMilliseconds: Double
}

public actor ManagedRelayCoordinator {
    public typealias SendFrame = @Sendable (Data) async -> Bool
    public typealias CloseConnection = @Sendable () async -> Void

    private struct Challenge {
        var deviceID: UUID
        var nonce: Data
        var expiresAt: Date
    }

    private struct AdminChallenge {
        var adminDeviceID: UUID
        var nonce: Data
        var expiresAt: Date
    }

    private struct Connection {
        var id: UUID
        var device: RemoteDevice
        var token: String
        var send: SendFrame
        var close: CloseConnection
    }

    private let consoleAuthority: ConsoleRelayAuthority?
    private let store: ManagedRelayPostgresStore
    private let publicURL: URL
    private var challenges: [UUID: Challenge] = [:]
    private var adminChallenges: [UUID: AdminChallenge] = [:]
    private var connections: [UUID: Connection] = [:]
    private struct RoutedID: Hashable {
        var spaceID: UUID
        var envelopeID: UUID
    }
    private var recentlyRouted: [RoutedID: Date] = [:]
    private var pairingsApproved: Int64 = 0
    private var pairingsRejected: Int64 = 0
    private var authFailures: Int64 = 0
    private var crossTenantDenials: Int64 = 0
    private var routedEnvelopes: Int64 = 0
    private var totalRelayLatencyMilliseconds = 0.0

    public init(store: ManagedRelayPostgresStore, publicURL: URL, consoleAuthority: ConsoleRelayAuthority? = nil) {
        self.consoleAuthority = consoleAuthority
        self.store = store
        self.publicURL = publicURL
    }

    public func enroll(
        invite: String,
        hostName: String,
        signingPublicKey: Data,
        encryptionPublicKey: Data,
        encryptionKeySignature: Data
    ) async throws -> ManagedEnrollment {
        guard consoleAuthority == nil else { throw ManagedRelayError.forbidden }
        return try await store.consumeServiceInvite(
            invite,
            hostName: hostName,
            signingPublicKey: signingPublicKey,
            encryptionPublicKey: encryptionPublicKey,
            encryptionKeySignature: encryptionKeySignature
        )
    }

    public func claimPairing(
        id: UUID,
        nonce: String,
        deviceID: UUID,
        kind: RemoteDeviceKind,
        name: String,
        signingPublicKey: Data,
        encryptionPublicKey: Data,
        encryptionKeySignature: Data,
        claimSignature: Data
    ) async throws {
        try await store.claimPairing(
            id: id,
            nonce: nonce,
            claimedDeviceID: deviceID,
            kind: kind,
            name: name,
            signingPublicKey: signingPublicKey,
            encryptionPublicKey: encryptionPublicKey,
            encryptionKeySignature: encryptionKeySignature,
            claimSignature: claimSignature
        )
    }

    public func pairingStatus(id: UUID, nonce: String) async throws -> ManagedPairingRequest {
        guard let request = try await store.pairingStatus(id: id, nonce: nonce) else {
            throw ManagedRelayError.invalidPairing
        }
        return request
    }

    public func recover(
        spaceID: UUID,
        code: String,
        name: String,
        signingPublicKey: Data,
        encryptionPublicKey: Data,
        encryptionKeySignature: Data
    ) async throws -> RemoteDevice {
        guard consoleAuthority == nil else { throw ManagedRelayError.forbidden }
        return try await store.recover(
            spaceID: spaceID,
            code: code,
            name: name,
            signingPublicKey: signingPublicKey,
            encryptionPublicKey: encryptionPublicKey,
            encryptionKeySignature: encryptionKeySignature
        )
    }

    public func challenge(deviceID: UUID, now: Date = Date()) async throws -> (id: UUID, nonce: Data) {
        guard let device = try await store.device(id: deviceID),
              device.status == .active else {
            authFailures += 1
            throw ManagedRelayError.unauthorized
        }
        let nonce = Data(RemoteSecret.random().utf8)
        let id = UUID()
        challenges[id] = Challenge(deviceID: deviceID, nonce: nonce, expiresAt: now.addingTimeInterval(60))
        return (id, nonce)
    }

    public func adminChallenge(
        deviceID: UUID,
        now: Date = Date()
    ) async throws -> (id: UUID, nonce: Data) {
        guard try await store.adminDevice(id: deviceID) != nil else {
            authFailures += 1
            throw ManagedRelayError.unauthorized
        }
        let id = UUID()
        let nonce = Data(RemoteSecret.random().utf8)
        adminChallenges[id] = AdminChallenge(
            adminDeviceID: deviceID,
            nonce: nonce,
            expiresAt: now.addingTimeInterval(60)
        )
        return (id, nonce)
    }

    public func authenticateAdmin(
        challengeID: UUID,
        signature: Data,
        now: Date = Date()
    ) async throws -> (token: String, expiresAt: Date) {
        guard let challenge = adminChallenges.removeValue(forKey: challengeID),
              challenge.expiresAt > now,
              let device = try await store.adminDevice(id: challenge.adminDeviceID) else {
            authFailures += 1
            throw ManagedRelayError.challengeExpired
        }
        guard RemoteDeviceKeys.verify(
            signature: signature,
            challenge: challenge.nonce,
            publicKey: device.publicKey
        ) else {
            authFailures += 1
            throw ManagedRelayError.invalidSignature
        }
        let token = RemoteSecret.random()
        let expiresAt = now.addingTimeInterval(15 * 60)
        try await store.saveAdminSession(
            token: token,
            adminDeviceID: device.id,
            expiresAt: expiresAt
        )
        return (token, expiresAt)
    }

    public func authenticate(
        challengeID: UUID,
        signature: Data,
        now: Date = Date()
    ) async throws -> ManagedDeviceSession {
        guard let challenge = challenges.removeValue(forKey: challengeID),
              challenge.expiresAt > now,
              let device = try await store.device(id: challenge.deviceID),
              device.status == .active else {
            authFailures += 1
            throw ManagedRelayError.challengeExpired
        }
        guard RemoteDeviceKeys.verify(
            signature: signature,
            challenge: challenge.nonce,
            publicKey: device.signingPublicKey
        ) else {
            authFailures += 1
            throw ManagedRelayError.invalidSignature
        }
        let token = RemoteSecret.random()
        let expiresAt = now.addingTimeInterval(15 * 60)
        try await store.saveSession(token: token, deviceID: device.id, expiresAt: expiresAt)
        return ManagedDeviceSession(device: device, token: token, expiresAt: expiresAt)
    }

    public func authorize(token: String) async throws -> RemoteDevice {
        guard let device = try await store.device(forSessionToken: token) else {
            authFailures += 1
            throw ManagedRelayError.unauthorized
        }
        if let consoleAuthority, !(await consoleAuthority.authorize(deviceID: device.id)) { throw ManagedRelayError.forbidden }
        return device
    }

    public func listDevices(token: String) async throws -> [RemoteDevice] {
        let caller = try await authorize(token: token)
        return try await store.devices(spaceID: caller.spaceID).map { device in
            var result = device
            result.online = connections[device.id] != nil
            return result
        }
    }
    public func connectionPresence(deviceIDs: Set<UUID>, credential: String?) async throws -> Set<UUID> {
        guard consoleAuthority?.acceptsServiceCredential(credential) == true else { throw ManagedRelayError.unauthorized }
        guard deviceIDs.count <= 1000 else { throw ManagedRelayError.forbidden }
        var online: Set<UUID> = []
        for id in deviceIDs {
            guard let connection = connections[id], try await store.device(forSessionToken: connection.token) != nil,
                  connections[id]?.id == connection.id else { continue }
            online.insert(id)
        }
        return online
    }

    public func createPairing(token: String, kind: RemoteDeviceKind) async throws -> RemotePairingCode {
        let caller = try await authorize(token: token)
        return try await store.createPairing(creator: caller, kind: kind, relayURL: publicURL)
    }

    public func pendingPairings(token: String) async throws -> [ManagedPairingRequest] {
        let caller = try await authorize(token: token)
        guard caller.kind == .host else { throw ManagedRelayError.forbidden }
        return try await store.pendingPairings(spaceID: caller.spaceID, creatorID: caller.id)
    }

    public func decidePairing(id: UUID, token: String, approve: Bool) async throws -> RemoteDevice? {
        let caller = try await authorize(token: token)
        let result = try await store.decidePairing(id: id, approvingHost: caller, approve: approve)
        if approve { pairingsApproved += 1 } else { pairingsRejected += 1 }
        return result
    }

    public func revokeDevice(id: UUID, token: String) async throws {
        let caller = try await authorize(token: token)
        try await store.revokeDevice(id: id, actor: caller)
        await disconnectDevice(id)
    }

    public func disconnectDevice(_ id: UUID) async {
        if let connection = connections.removeValue(forKey: id) {
            await connection.close()
        }
    }

    public func rotateRecoveryCodes(token: String) async throws -> [String] {
        let caller = try await authorize(token: token)
        return try await store.rotateRecoveryCodes(actor: caller)
    }

    public func attach(
        token: String,
        send: @escaping SendFrame,
        close: @escaping CloseConnection
    ) async throws -> (deviceID: UUID, connectionID: UUID) {
        let device = try await authorize(token: token)
        try await store.touchDevice(id: device.id)
        let connectionID = UUID()
        if let previous = connections[device.id] {
            await previous.close()
        }
        connections[device.id] = Connection(
            id: connectionID,
            device: device,
            token: token,
            send: send,
            close: close
        )
        return (device.id, connectionID)
    }

    public func detach(deviceID: UUID, connectionID: UUID) {
        guard connections[deviceID]?.id == connectionID else { return }
        connections[deviceID] = nil
    }

    public func disconnectSpace(_ spaceID: UUID) async {
        let matching = connections.values.filter { $0.device.spaceID == spaceID }
        for connection in matching {
            connections[connection.device.id] = nil
            await connection.close()
        }
    }

    public func expireConsoleConnections() async {
        guard let consoleAuthority else { return }
        for connection in Array(connections.values) {
            if !(await consoleAuthority.authorize(deviceID: connection.device.id)) { await disconnectDevice(connection.device.id) }
        }
    }

    public func metrics() -> ManagedRelayMetricsSnapshot {
        ManagedRelayMetricsSnapshot(
            activeSessions: connections.count,
            hostsOnline: connections.values.filter { $0.device.kind == .host }.count,
            pairingsApproved: pairingsApproved,
            pairingsRejected: pairingsRejected,
            authFailures: authFailures,
            crossTenantDenials: crossTenantDenials,
            routedEnvelopes: routedEnvelopes,
            meanRelayLatencyMilliseconds: routedEnvelopes == 0
                ? 0 : totalRelayLatencyMilliseconds / Double(routedEnvelopes)
        )
    }

    public func route(
        _ envelope: RemoteSealedEnvelope,
        senderID: UUID,
        connectionID: UUID,
        now: Date = Date()
    ) async throws {
        let startedAt = Date()
        if let consoleAuthority {
            guard envelope.kind == "console.tls.v2", await consoleAuthority.authorize(deviceID: senderID, peerID: envelope.to, byteCount: Int64(envelope.ciphertext.count)) else { throw ManagedRelayError.forbidden }
        }
        guard let connection = connections[senderID],
              connection.id == connectionID,
              envelope.from == senderID,
              let sender = try await store.device(forSessionToken: connection.token),
              sender.id == senderID,
              sender.status == .active else {
            throw ManagedRelayError.unauthorized
        }
        let lookedUpTarget = try await store.device(id: envelope.to)
        guard let target = lookedUpTarget,
              target.status == .active,
              (consoleAuthority != nil || target.spaceID == sender.spaceID) else {
            if let lookedUpTarget, lookedUpTarget.spaceID != sender.spaceID {
                crossTenantDenials += 1
            }
            throw ManagedRelayError.crossSpaceRoute
        }
        guard connections[senderID]?.id == connectionID else {
            throw ManagedRelayError.unauthorized
        }
        guard !envelope.ciphertext.isEmpty else { throw ManagedRelayError.plaintextPayload }
        guard abs(envelope.createdAt.timeIntervalSince(now)) < 300 else { throw ManagedRelayError.replay }
        guard allowed(kind: envelope.kind, sender: sender) else { throw ManagedRelayError.forbidden }
        guard let destination = connections[target.id],
              try await store.device(forSessionToken: destination.token) != nil else {
            throw ManagedRelayError.hostOffline
        }

        recentlyRouted = recentlyRouted.filter { now.timeIntervalSince($0.value) < 300 }
        guard recentlyRouted.count < 100_000 else { throw ManagedRelayError.forbidden }
        let routedID = RoutedID(spaceID: sender.spaceID, envelopeID: envelope.id)
        guard recentlyRouted[routedID] == nil else { throw ManagedRelayError.replay }
        recentlyRouted[routedID] = now
        let frame = try JSONEncoder().encode(envelope)
        guard await destination.send(frame) else {
            connections[target.id] = nil
            throw ManagedRelayError.hostOffline
        }
        routedEnvelopes += 1
        totalRelayLatencyMilliseconds += Date().timeIntervalSince(startedAt) * 1_000
    }

    private func allowed(kind: String, sender: RemoteDevice) -> Bool {
        switch kind {
        case "console.tls.v2":
            return consoleAuthority != nil
        case "core.http", "core.http.response", "session.stream", "session.stream.response":
            return sender.capabilities.contains("sloppy.core.remote")
        case "terminal.stream", "terminal.stream.response":
            return sender.capabilities.contains("sloppy.terminal.control")
        default:
            return false
        }
    }
}
