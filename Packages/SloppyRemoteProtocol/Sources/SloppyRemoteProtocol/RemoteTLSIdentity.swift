import Crypto
import Foundation

/// RFC 8410 Ed25519 self-signed identity, used only with explicit certificate
/// pinning. It is never added to the OS or WebPKI trust store.
public struct RemoteTLSIdentity: Codable, Sendable {
    public var certificateDER: Data
    public var privateKeyDER: Data
    public var signingPublicKey: Data
    public init(signingPrivateKey: Data, deviceID: UUID, now: Date = Date()) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        signingPublicKey = key.publicKey.rawRepresentation
        let algorithm = Self.der(0x30, Self.der(0x06, Data([0x2B, 0x65, 0x70])))
        privateKeyDER = Self.der(0x30, Self.der(0x02, Data([0])) + algorithm + Self.der(0x04, Self.der(0x04, signingPrivateKey)))
        let name = Self.der(0x30, Self.der(0x31, Self.der(0x30, Self.der(0x06, Data([0x55, 0x04, 0x03])) + Self.der(0x0c, Data(deviceID.uuidString.utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let validity = Self.der(0x30, Self.der(0x18, Data(formatter.string(from: now.addingTimeInterval(-300)).utf8)) + Self.der(0x18, Data(formatter.string(from: now.addingTimeInterval(3650 * 86400)).utf8)))
        let serial = Data([0x01]) + Data((0..<15).map { _ in UInt8.random(in: 0...255) })
        let publicInfo = Self.der(0x30, algorithm + Self.der(0x03, Data([0]) + signingPublicKey))
        let tbs = Self.der(0x30, Self.der(0xa0, Self.der(0x02, Data([2]))) + Self.der(0x02, serial) + algorithm + name + validity + name + publicInfo)
        certificateDER = Self.der(0x30, tbs + algorithm + Self.der(0x03, Data([0]) + (try key.signature(for: tbs))))
    }
    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 { length.append(UInt8(content.count)) }
        else { var value = content.count, bytes: [UInt8] = []; while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }; length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes) }
        return Data([tag]) + length + content
    }
}
