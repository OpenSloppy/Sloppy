#if os(macOS)
import Foundation
import Darwin

public enum LocalOwnerAuthentication {
    struct Credential: Codable {
        var version: Int
        var baseURL: URL
        var token: String
    }

    public static func restore(
        baseURL: URL,
        credentialURLs: [URL] = defaultCredentialURLs,
        authSessionStore: AuthSessionStore = .shared,
        session: URLSession? = nil
    ) async throws -> Bool {
        guard baseURL.scheme == "http", ServerAddress.isLoopbackHost(baseURL.host),
              baseURL.user == nil, baseURL.password == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.query == nil, baseURL.fragment == nil else { return false }
        guard let credential = credentialURLs.compactMap({ load($0, for: baseURL) }).first else {
            return false
        }
        let transport = session ?? URLSession(
            configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil
        )
        defer { if session == nil { transport.invalidateAndCancel() } }
        // Keep the bootstrap secret out of persisted client sessions.
        let http = BackendHTTPClient(baseURL: baseURL, authToken: credential.token,
                                     session: transport, authSessionStore: AuthSessionStore(persistence: .memory))
        let ownerSession: AuthSession = try await http.post("/v1/auth/local-session", body: [String: String]())
        guard !Task.isCancelled, !ownerSession.accessToken.isEmpty,
              !ownerSession.refreshToken.isEmpty else { throw APIError.invalidResponse }
        await http.setAuthToken(ownerSession.accessToken)
        let user: AuthUserProfile = try await http.get("/v1/auth/me")
        guard !Task.isCancelled, user.id == ownerSession.user?.id else { throw APIError.invalidResponse }
        await authSessionStore.save(ownerSession, for: baseURL)
        return true
    }

    public static var defaultCredentialURLs: [URL] {
        let fileManager = FileManager.default
        let roots = [fileManager.homeDirectoryForCurrentUser,
                     URL(fileURLWithPath: fileManager.currentDirectoryPath)]
        return roots.map { $0.appendingPathComponent(".sloppy/local-client.json") }
    }

    static func load(_ url: URL, for baseURL: URL) -> Credential? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.version == 1, credential.token.hasPrefix("slp_local_"),
              credential.token.count >= 40,
              credential.baseURL.scheme == baseURL.scheme,
              ServerAddress.isLoopbackHost(credential.baseURL.host),
              credential.baseURL.port == baseURL.port else { return nil }
        return credential
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
