import Crypto
import Foundation
import SloppyConsoleProtocol
import Testing
@testable import SloppyRemoteProtocol

@Suite("Console peer transport", .serialized)
struct ConsoleRemoteConnectionTests {
    @Test func concurrentRequestsShareOneTLSHandshakeAndDeliverAllReplies() async throws {
        let fixture = try Fixture()
        await fixture.host.setHandler { _, _, packet in
            ConsoleRemotePacket(kind: "reply", payload: packet.payload)
        }
        await fixture.client.setHandler { _, _, packet in
            await fixture.replies.append(packet.payload)
            return nil
        }
        try await fixture.host.connect()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("request-\(index)".utf8)), to: fixture.hostID)
                }
            }
            try await group.waitForAll()
        }
        try await fixture.replies.waitForCount(16)
        let replies = await fixture.replies.values
        #expect(Set(replies).count == 16)
        let frames = await fixture.relay.frames.filter { $0.from == fixture.clientID }
        #expect(Set(frames.map(\.sessionID)).count == 1)
        #expect(frames.map(\.sequence) == Array(0..<UInt64(frames.count)))
        await fixture.close()
    }

    @Test func reconnectRenegotiatesTLSWhileHostRetainsThePreviousPeer() async throws {
        let fixture = try Fixture()
        await fixture.host.setHandler { _, _, packet in
            ConsoleRemotePacket(kind: "reply", payload: packet.payload)
        }
        await fixture.client.setHandler { _, _, packet in
            await fixture.replies.append(packet.payload)
            return nil
        }
        try await fixture.host.connect()
        try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("before".utf8)), to: fixture.hostID)
        try await fixture.replies.waitForCount(1)
        await fixture.client.disconnect()
        try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("after".utf8)), to: fixture.hostID)
        try await fixture.replies.waitForCount(2)
        #expect(await fixture.replies.values == [Data("before".utf8), Data("after".utf8)])
        let starts = await fixture.relay.frames.filter { $0.from == fixture.clientID && $0.sequence == 0 }
        #expect(starts.count == 2)
        #expect(Set(starts.map(\.sessionID)).count == 2)
        await fixture.close()
    }

    @Test func largeChatResponseBatchesTLSRecordsWithinTheRelayFrameLimit() async throws {
        let fixture = try Fixture()
        let transcript = Data(repeating: 97, count: 512 * 1024)
        await fixture.host.setHandler { _, _, _ in
            ConsoleRemotePacket(kind: "reply", payload: transcript)
        }
        await fixture.client.setHandler { _, _, packet in
            await fixture.replies.append(packet.payload)
            return nil
        }
        try await fixture.host.connect()
        try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data()), to: fixture.hostID)
        try await fixture.replies.waitForCount(1)
        #expect(await fixture.replies.values == [transcript])
        let responseFrames = await fixture.relay.frames.filter { $0.from == fixture.hostID }
        #expect(responseFrames.count < 16)
        #expect(responseFrames.allSatisfy { $0.records.count <= 1024 * 1024 })
        await fixture.close()
    }

    @Test func relayLossNotifiesTheOwnerAndTheNextRequestReconnects() async throws {
        let fixture = try Fixture()
        let disconnects = PacketMailbox()
        await fixture.client.setDisconnectHandler { await disconnects.append(Data()) }
        await fixture.host.setHandler { _, _, packet in ConsoleRemotePacket(kind: "reply", payload: packet.payload) }
        await fixture.client.setHandler { _, _, packet in
            await fixture.replies.append(packet.payload)
            return nil
        }
        try await fixture.host.connect()
        try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("before".utf8)), to: fixture.hostID)
        try await fixture.replies.waitForCount(1)
        await fixture.relay.dropConnection(deviceID: fixture.clientID)
        try await disconnects.waitForCount(1)
        try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("after".utf8)), to: fixture.hostID)
        try await fixture.replies.waitForCount(2)
        #expect(await fixture.replies.values == [Data("before".utf8), Data("after".utf8)])
        await fixture.close()
    }

    @Test func revokedPinCannotSendOnAnEstablishedChannel() async throws {
        let fixture = try Fixture()
        await fixture.host.setHandler { _, _, packet in
            await fixture.replies.append(packet.payload)
            return nil
        }
        try await fixture.host.connect()
        try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("allowed".utf8)), to: fixture.hostID)
        try await fixture.replies.waitForCount(1)
        await fixture.client.updatePins([:])
        await #expect(throws: RemoteTLSError.self) {
            try await fixture.client.send(ConsoleRemotePacket(kind: "request", payload: Data("revoked".utf8)), to: fixture.hostID)
        }
        #expect(await fixture.replies.values == [Data("allowed".utf8)])
        await fixture.close()
    }
}

private struct Fixture: Sendable {
    let relay = MemoryRelay()
    let replies = PacketMailbox()
    let clientID = UUID()
    let hostID = UUID()
    let client: ConsoleRemoteConnection
    let host: ConsoleRemoteConnection

    init() throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientIdentity = try RemoteTLSIdentity(signingPrivateKey: clientKey.rawRepresentation, deviceID: clientID)
        let hostIdentity = try RemoteTLSIdentity(signingPrivateKey: hostKey.rawRepresentation, deviceID: hostID)
        let relay = relay
        let clientID = clientID, hostID = hostID
        client = Self.connection(id: clientID, key: clientKey.rawRepresentation, identity: clientIdentity,
                                 pins: [hostID: hostIdentity.certificateDER], relay: relay)
        host = Self.connection(id: hostID, key: hostKey.rawRepresentation, identity: hostIdentity,
                               pins: [clientID: clientIdentity.certificateDER], relay: relay)
    }

    private static func connection(id: UUID, key: Data, identity: RemoteTLSIdentity, pins: [UUID: Data], relay: MemoryRelay) -> ConsoleRemoteConnection {
        ConsoleRemoteConnection(deviceID: id, signingPrivateKey: key, identity: identity,
            relayURL: URL(string: "https://relay.test")!, pins: pins,
            transportFactory: { MemoryTransport(deviceID: id, relay: relay) },
            authenticateDevice: {
                ManagedDeviceSession(device: RemoteDevice(id: id, spaceID: UUID(), principalID: UUID(), kind: .host,
                    name: "Test", signingPublicKey: identity.signingPublicKey, encryptionPublicKey: Data(),
                    encryptionKeySignature: Data(), capabilities: []), token: "test", expiresAt: Date().addingTimeInterval(300))
            })
    }

    func close() async { await client.disconnect(); await host.disconnect() }
}

private actor PacketMailbox {
    var values: [Data] = []
    func append(_ data: Data) { values.append(data) }
    func waitForCount(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while values.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(values.count == count)
    }
}

private actor MemoryRelay {
    private var connections: [UUID: (UUID, AsyncThrowingStream<Data, any Error>.Continuation)] = [:]
    var frames: [RemoteTLSFrame] = []
    func register(deviceID: UUID, socketID: UUID, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        connections[deviceID] = (socketID, continuation)
    }
    func close(deviceID: UUID, socketID: UUID) {
        if connections[deviceID]?.0 == socketID { connections.removeValue(forKey: deviceID)?.1.finish() }
    }
    func dropConnection(deviceID: UUID) {
        connections.removeValue(forKey: deviceID)?.1.finish()
    }
    func route(_ data: Data) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(RemoteSealedEnvelope.self, from: data)
        frames.append(try ConsoleWire.decode(RemoteTLSFrame.self, from: envelope.ciphertext))
        guard let target = connections[envelope.to] else { throw RemoteTLSError.closed }
        if case .dropped = target.1.yield(data) { throw RemoteTLSError.oversizedMessage }
    }
}

private actor MemoryTransport: ConsoleRemoteTransport {
    nonisolated let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let deviceID: UUID
    private let socketID = UUID()
    private let relay: MemoryRelay
    init(deviceID: UUID, relay: MemoryRelay) {
        self.deviceID = deviceID; self.relay = relay
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
        messages = pair.stream; continuation = pair.continuation
    }
    func connect(url: URL, token: String) async throws {
        await relay.register(deviceID: deviceID, socketID: socketID, continuation: continuation)
    }
    func send(_ data: Data) async throws { try await relay.route(data) }
    func close() async {
        continuation.finish()
        await relay.close(deviceID: deviceID, socketID: socketID)
    }
}
