import Foundation
import Protocols
import SloppyNodeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CoreLocalClientCredential: Codable, Sendable {
    var version = 1
    var baseURL: URL
    var token: String

    static func isLoopbackAddress(_ address: String?) -> Bool {
        guard let address else { return false }
        let host = address.lowercased()
        if host == "::1" || host == "::ffff:127.0.0.1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    func matches(_ candidate: String) -> Bool {
        let lhs = Array(token.utf8), rhs = Array(candidate.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension CoreService {
    func publishLocalClientCredential(port: Int, fileURL: URL) throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        guard let baseURL = components.url else { throw CoreIdentityAuthError.invalidCredentials }
        let credential = CoreLocalClientCredential(
            baseURL: baseURL, token: "slp_local_" + NodeIdentityGenerator.randomToken(byteCount: 32)
        )
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".local-client-" + UUID().uuidString)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: temporary) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(credential))
        try handle.close()
        guard rename(temporary.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        localClientCredential = credential
    }

    func exchangeLocalClientCredential(_ authorization: String?) async throws -> AuthSessionResponse {
        guard let credential = localClientCredential,
              let authorization, authorization.hasPrefix("Bearer "),
              credential.matches(String(authorization.dropFirst(7))) else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        guard await identityAuthChallenge().mode == .loginPassword else {
            throw CoreIdentityAuthError.disabled
        }
        return try await identityAuthService.makeLocalOwnerSession()
    }
}
