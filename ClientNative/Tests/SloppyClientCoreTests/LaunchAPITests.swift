import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Launch API", .serialized)
struct LaunchAPITests {
    @Test func commandsAndSelectionKeepCheckoutAndTarget() async throws {
        let state = LaunchSessionState(agentID: "agent one", sessionID: "chat/two")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let capture = LaunchRequestCapture()
        LaunchAPIURLProtocol.install { request in
            capture.add(request)
            return (200, try encoder.encode(state))
        }
        defer { LaunchAPIURLProtocol.install(nil) }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [LaunchAPIURLProtocol.self]
        let client = SloppyAPIClient(baseURL: URL(string: "https://launch.sloppy.test")!,
                                     session: URLSession(configuration: sessionConfig), authSessionStore: AuthSessionStore(persistence: .memory))
        let request = LaunchConfigurationRequest(name: "Second App", target: "Desktop", platform: .macOS,
                                                checkoutPath: "/tmp/worktree-a", workingDirectory: "apps/second",
                                                build: [.init(executable: "swift", arguments: ["build", "--product", "Desktop"])], appPath: "dist/Desktop.app")
        _ = try await client.configureLaunch(agentID: "agent one", sessionID: "chat/two", request: request)
        _ = try await client.selectLaunch(agentID: "agent one", sessionID: "chat/two", request: .init(configurationID: "target-two"))
        let requests = capture.requests
        let configure = try #require(requests.first)
        #expect(configure.url?.absoluteString.contains("agent%20one/sessions/chat%2Ftwo/launch/configurations") == true)
        let payload = try JSONDecoder().decode(LaunchConfigurationRequest.self, from: #require(body(configure)))
        #expect(payload.checkoutPath == "/tmp/worktree-a")
        #expect(payload.workingDirectory == "apps/second")
        #expect(payload.build.first?.arguments == ["build", "--product", "Desktop"])
        let select = try #require(requests.last)
        let selected = try JSONDecoder().decode(LaunchSelectionRequest.self, from: #require(body(select)))
        #expect(selected.configurationID == "target-two")
    }

    @Test func previewPathsKeepInstanceRouting() async throws {
        let direct = SloppyAPIClient(baseURL: URL(string: "http://127.0.0.1:25101")!)
        let relay = SloppyAPIClient(endpoint: .relay(coordinatorBaseURL: URL(string: "https://relay.test")!, targetNodeID: "mac-one"))
        let managed = SloppyAPIClient(endpoint: .managed(relayURL: URL(string: "https://relay.test")!, targetDeviceID: UUID()))
        let path = "/v1/agents/agent/sessions/chat/launch/runs/run/preview/ws"
        #expect(await direct.launchPreviewSocketPath(agentID: "agent", sessionID: "chat", runID: "run") == path)
        #expect(await managed.launchPreviewSocketPath(agentID: "agent", sessionID: "chat", runID: "run") == path)
        #expect(await relay.launchPreviewSocketPath(agentID: "agent", sessionID: "chat", runID: "run") == "/v1/node/mesh/nodes/mac-one" + path.dropFirst(3))
    }

    @Test func oldLaunchStateDefaultsToUnarchived() throws {
        let state = try JSONDecoder().decode(LaunchSessionState.self, from: Data(#"{"agentID":"agent","sessionID":"chat"}"#.utf8))
        #expect(!state.isArchived)
        #expect(state.configurations.isEmpty)
        #expect(state.runs.isEmpty)
    }

    private func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }; result.append(bytes, count: count)
        }
        return result
    }
}

private final class LaunchRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { items } }
    func add(_ request: URLRequest) { lock.withLock { items.append(request) } }
}

private final class LaunchAPIURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    static func install(_ handler: Handler?) { lock.withLock { self.handler = handler } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "launch.sloppy.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.lock.withLock { Self.handler })
            let (code, data) = try handler(request)
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
