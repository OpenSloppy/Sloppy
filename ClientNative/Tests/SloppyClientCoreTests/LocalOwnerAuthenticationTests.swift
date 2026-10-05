#if os(macOS)
import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Local owner client authentication", .serialized)
struct LocalOwnerAuthenticationTests {
    @Test("Live local Core accepts the client filesystem exchange",
          .enabled(if: ProcessInfo.processInfo.environment["SLOPPY_LOCAL_OWNER_LIVE"] == "1"))
    func liveLocalOwnerRestore() async throws {
        let baseURL = try #require(URL(string: "http://localhost:25101"))
        let store = AuthSessionStore(persistence: .memory)
        #expect(try await LocalOwnerAuthentication.restore(baseURL: baseURL, authSessionStore: store))
        let session = try #require(await store.session(for: baseURL))
        #expect(session.user?.role == "admin")
        let client = SloppyAPIClient(baseURL: baseURL, authSessionStore: store)
        #expect(try await client.fetchCurrentAuthUser().id == session.user?.id)
    }

    @Test("A local file opens a session and subsequent API clients use it")
    func restoresAndSharesSession() async throws {
        try await withCredential { file, secret in
            let baseURL = try #require(URL(string: "http://localhost:25101"))
            let store = AuthSessionStore(persistence: .memory)
            LocalAuthURLProtocol.handler = { request in
                switch request.url?.path {
                case "/v1/auth/local-session":
                    #expect(request.httpMethod == "POST")
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
                    return (200, Data(Self.sessionJSON.utf8))
                case "/v1/auth/me":
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-access")
                    return (200, Data(Self.userJSON.utf8))
                case "/v1/projects":
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-access")
                    return (200, Data("[]".utf8))
                default:
                    Issue.record("Unexpected local auth request")
                    return (404, Data())
                }
            }
            defer { LocalAuthURLProtocol.handler = nil }
            let transport = makeSession()
            #expect(try await LocalOwnerAuthentication.restore(baseURL: baseURL, credentialURLs: [file],
                                                              authSessionStore: store, session: transport))
            let session = try #require(await store.session(for: baseURL))
            #expect(session.accessToken == "session-access")
            #expect(session.accessToken != secret)
            let http = BackendHTTPClient(baseURL: baseURL, session: transport, authSessionStore: store)
            #expect(try await http.getData("/v1/projects") == Data("[]".utf8))
        }
    }

    @Test("Failed exchange or user validation never saves a session", arguments: [false, true])
    func rejectionDoesNotSaveSession(rejectUser: Bool) async throws {
        try await withCredential { file, _ in
            let baseURL = try #require(URL(string: "http://localhost:25101"))
            let store = AuthSessionStore(persistence: .memory)
            LocalAuthURLProtocol.handler = { request in
                if rejectUser && request.url?.path == "/v1/auth/local-session" {
                    return (200, Data(Self.sessionJSON.utf8))
                }
                return (401, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            defer { LocalAuthURLProtocol.handler = nil }
            await #expect(throws: APIError.self) {
                try await LocalOwnerAuthentication.restore(baseURL: baseURL, credentialURLs: [file],
                                                          authSessionStore: store, session: makeSession())
            }
            #expect(await store.session(for: baseURL) == nil)
        }
    }

    @Test("Local credentials are never used for a remote endpoint")
    func remoteEndpointCannotUseLocalSecret() async throws {
        try await withCredential { file, _ in
            let remote = try #require(URL(string: "http://remote.example:25101"))
            #expect(try await !LocalOwnerAuthentication.restore(baseURL: remote, credentialURLs: [file],
                authSessionStore: AuthSessionStore(persistence: .memory), session: makeSession()))
        }
    }

    @Test("World-readable files, symlinks and a different local port are rejected")
    func rejectsMismatchedOrUnsafeFile() async throws {
        try await withCredential { file, _ in
            let local = try #require(URL(string: "http://localhost:25101"))
            let otherPort = try #require(URL(string: "http://localhost:25202"))
            #expect(LocalOwnerAuthentication.load(file, for: local) != nil)
            #expect(LocalOwnerAuthentication.load(file, for: otherPort) == nil)
            let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(LocalOwnerAuthentication.load(link, for: local) == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(LocalOwnerAuthentication.load(file, for: local) == nil)
        }
    }

    private static let userJSON = #"{"id":"owner","login":"owner","name":"Owner","role":"admin","status":"active"}"#
    private static let sessionJSON = #"{"accessToken":"session-access","refreshToken":"session-refresh","user":{"id":"owner","login":"owner","name":"Owner","role":"admin","status":"active"}}"#

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalAuthURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func withCredential(_ body: (URL, String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("local-client.json")
        let secret = "slp_local_" + String(repeating: "a", count: 43)
        let credential = LocalOwnerAuthentication.Credential(version: 1,
            baseURL: try #require(URL(string: "http://127.0.0.1:25101")), token: secret)
        #expect(FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(credential),
                                               attributes: [.posixPermissions: 0o600]))
        try await body(file, secret)
    }
}

private final class LocalAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: (@Sendable (URLRequest) -> (Int, Data))?
    static var handler: (@Sendable (URLRequest) -> (Int, Data))? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
