import Crypto
import Foundation
import SloppyRemoteProtocol
import Testing

@Test func tlsAuthenticatesPinnedEndpointsAndEncryptsTraffic() async throws {
    let a = try RemoteTLSIdentity(signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceID: UUID())
    let b = try RemoteTLSIdentity(signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceID: UUID())
    let client = try await RemoteTLSChannel(identity: a, peerCertificate: b.certificateDER, isClient: true)
    let host = try await RemoteTLSChannel(identity: b, peerCertificate: a.certificateDER, isClient: false)
    var outgoing = try await client.start().records
    for _ in 0..<12 {
        var replies: [Data] = []
        for record in outgoing { replies += try await host.receive(record).records }
        outgoing = []
        for record in replies { outgoing += try await client.receive(record).records }
        if outgoing.isEmpty { break }
    }
    let secret = Data("private agent payload".utf8)
    let encrypted = try await client.send(secret)
    #expect(encrypted.handshakeComplete)
    #expect(!encrypted.records.contains { $0.range(of: secret) != nil })
    var decrypted: [Data] = []
    for record in encrypted.records { decrypted += try await host.receive(record).messages }
    #expect(decrypted == [secret])
    await client.close(); await host.close()
}

@Test func tlsRejectsDirectoryKeySubstitution() async throws {
    let a = try RemoteTLSIdentity(signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceID: UUID())
    let b = try RemoteTLSIdentity(signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceID: UUID())
    let attacker = try RemoteTLSIdentity(signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceID: UUID())
    let client = try await RemoteTLSChannel(identity: a, peerCertificate: b.certificateDER, isClient: true)
    let host = try await RemoteTLSChannel(identity: attacker, peerCertificate: a.certificateDER, isClient: false)
    let start = try await client.start()
    var rejected = false
    for record in start.records {
        let replies = try await host.receive(record)
        for reply in replies.records { do { _ = try await client.receive(reply) } catch { rejected = true } }
    }
    #expect(rejected)
    await client.close(); await host.close()
}
