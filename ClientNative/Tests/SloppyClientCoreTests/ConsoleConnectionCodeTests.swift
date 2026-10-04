import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Console connection QR")
struct ConsoleConnectionCodeTests {
    private func instance() -> InstanceBinding {
        InstanceBinding(ownerID: UUID(), spaceID: UUID(), name: "Mac", authorityPublicKey: Data(), hostDeviceID: UUID(), hostCertificateFingerprint: String(repeating: "ab", count: 32), status: .active)
    }

    @Test func roundTripAndCertificateRotation() throws {
        let binding = instance()
        let code = try #require(ConsoleConnectionCode(instance: binding))
        let url = try #require(code.url)
        #expect(ConsoleConnectionCode.parse(url) == code)
        #expect(code.matches(binding))
        var changed = binding
        changed.hostCertificateFingerprint = String(repeating: "cd", count: 32)
        #expect(!code.matches(changed))
        changed = binding; changed.id = UUID()
        #expect(!code.matches(changed))
        changed = binding; changed.hostDeviceID = UUID()
        #expect(!code.matches(changed))
        changed = binding; changed.status = .revoked
        #expect(!code.matches(changed))
        #expect(ConsoleConnectionCode(instance: changed) == nil)
    }

    @Test func rejectsAmbiguousAndUnsupportedCodes() throws {
        let code = try #require(ConsoleConnectionCode(instance: instance()))
        let link = try #require(code.url).absoluteString
        for invalid in [link + "&v=1", link + "&token=secret", link + "#fragment",
                        link.replacingOccurrences(of: "v=1", with: "v=2"),
                        link.replacingOccurrences(of: "sloppy://", with: "https://"),
                        link.replacingOccurrences(of: code.fingerprint, with: "invalid")] {
            #expect(ConsoleConnectionCode.parse(try #require(URL(string: invalid))) == nil)
        }
    }

    @Test func acceptsCopiedHexButRejectsInvalidFingerprints() {
        #expect(ConsoleConnectionCode.normalizeFingerprint(" SHA256:" + Array(repeating: "AB", count: 32).joined(separator: ":") + "\n") == String(repeating: "ab", count: 32))
        #expect(ConsoleConnectionCode.normalizeFingerprint(String(repeating: "g", count: 64)) == nil)
        #expect(ConsoleConnectionCode.normalizeFingerprint(String(repeating: "a", count: 63)) == nil)
    }
}
