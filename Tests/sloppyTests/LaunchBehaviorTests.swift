import Foundation
import Testing
import Protocols
import NIOCore
import NIOPosix
@testable import sloppy

private actor LaunchFrames {
    var data = Data()
    func append(_ text: String) -> Bool {
        guard let bytes = Data(base64Encoded: text) else { return false }
        data.append(bytes); return true
    }
    func snapshot() -> Data { data }
}

private func freshLaunchService() -> LaunchRunService {
    LaunchRunService(store: InMemoryCorePersistenceBuilder().makeStore(config: .test), processes: SessionProcessRegistry())
}

@Test func launchWebReadinessAndPreviewPreserveHTTPAssetsAndWebSocketBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let reserve = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(reserve.localAddress?.port)
    try await reserve.close().get()
    let script = """
    import http.server, hashlib, base64, struct
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get('Upgrade', '').lower() == 'websocket':
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101)
                self.send_header('Upgrade','websocket'); self.send_header('Connection','Upgrade')
                self.send_header('Sec-WebSocket-Accept',accept); self.end_headers()
                self.wfile.write(bytes([0x81,5])+b'hello'); self.wfile.flush()
                return
            body = b'asset-content' if self.path == '/assets/test.css' else b'preview-ready'
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
            self.wfile.write(body)
    http.server.ThreadingHTTPServer(('127.0.0.1', \(port)),Handler).serve_forever()
    """
    try Data(script.utf8).write(to: root.appendingPathComponent("server.py"))
    let service = freshLaunchService()
    let configuration = LaunchConfiguration(id: "web", agentID: "agent", sessionID: "chat", hostName: "Test Mac",
        request: .init(name: "Web", target: "web", platform: .web, checkoutPath: root.path,
                       launch: .init(executable: "python3", arguments: ["server.py"]), webPort: port), updatedAt: Date())
    _ = try await service.configure(configuration)
    let run = try await service.start(configuration: configuration, environment: [:], timeoutMs: 5_000, maxProcesses: 2)
    for _ in 0..<100 {
        let current = try await service.state(agentID: "agent", sessionID: "chat").runs.first
        if current?.status == .running { break }
        if current?.status == .failed { Issue.record("Launch failed: \(current?.error ?? "unknown")"); return }
        try await Task.sleep(for: .milliseconds(50))
    }
    let ready = try await service.state(agentID: "agent", sessionID: "chat")
    #expect(ready.runs.first?.status == .running)
    #expect(ready.runs.first?.buildSucceeded == true)
    #expect(ready.runs.first?.launchSucceeded == true)
    for request in [
        "GET /assets/test.css HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /socket HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ] {
        let input = AsyncStream<String>.makeStream()
        let frames = LaunchFrames()
        let connection = WebSocketConnectionContext(sendText: { await frames.append($0) }, close: { input.continuation.finish() }, incomingMessages: { input.stream })
        let forwarding = Task { await LaunchPreviewBridge.forward(port: port, connection: connection) {
            (try? await service.previewPort(agentID: "agent", sessionID: "chat", runID: run.id)) != nil
        } }
        input.continuation.yield(Data(request.utf8).base64EncodedString())
        for _ in 0..<100 {
            let output = await frames.snapshot()
            if String(decoding: output, as: UTF8.self).contains(request.contains("Upgrade:") ? "hello" : "asset-content") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let output = await frames.snapshot()
        #expect(String(decoding: output, as: UTF8.self).contains(request.contains("Upgrade:") ? "101 Switching Protocols" : "asset-content"))
        if request.contains("Upgrade:") { #expect(output.suffix(7) == Data([0x81, 5]) + Data("hello".utf8)) }
        input.continuation.finish()
        await forwarding.value
    }
    _ = try await service.stop(agentID: "agent", sessionID: "chat", runID: run.id)
    await #expect(throws: LaunchRunService.Failure.self) { try await service.previewPort(agentID: "agent", sessionID: "chat", runID: run.id) }
}

@Test func launchMissingCheckoutFailsWithoutFallbackAndArchiveReleasesRetention() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = freshLaunchService()
    let configuration = LaunchConfiguration(id: "web", agentID: "agent", sessionID: "chat", hostName: "Test Mac",
        request: .init(name: "Missing", target: "web", platform: .web, checkoutPath: root.path,
                       launch: .init(executable: "/bin/sleep", arguments: ["30"]), webPort: 49178), updatedAt: Date())
    _ = try await service.configure(configuration)
    let run = try await service.start(configuration: configuration, environment: [:], timeoutMs: 1000, maxProcesses: 2)
    for _ in 0..<50 {
        if try await service.state(agentID: "agent", sessionID: "chat").runs.first?.status == .failed { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await service.state(agentID: "agent", sessionID: "chat").runs.first?.error?.contains(root.path) == true)
    let archived = try await service.archive(agentID: "agent", sessionID: "chat", isArchived: true)
    #expect(archived.configurations.count == 1)
    #expect(try await !service.retainsCheckout(root.path))
    await #expect(throws: LaunchRunService.Failure.self) { try await service.start(configuration: configuration, environment: [:], timeoutMs: 1000, maxProcesses: 2) }
    _ = try await service.archive(agentID: "agent", sessionID: "chat", isArchived: false)
    #expect(try await service.retainsCheckout(root.path))
    #expect(archived.runs.first?.id == run.id)
}

@Test func launchRouterRejectsEscapesAndKeepsMultipleTargets() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "launch-" + UUID().uuidString.lowercased()
    _ = try await service.createAgent(AgentCreateRequest(id: agentID, displayName: "Launch", role: "Testing"))
    let session = try await service.createAgentSession(agentID: agentID, request: .init(title: "Play"))
    let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("play-router-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let router = CoreRouter(service: service)
    let path = "/v1/agents/\(agentID)/sessions/\(session.id)/launch"
    var request = LaunchConfigurationRequest(name: "Web", target: "app-a", platform: .web, checkoutPath: root.path,
                                             launch: .init(executable: "/bin/sleep", arguments: ["1"]), webPort: 49179)
    let encoder = JSONEncoder()
    let saved = await router.handle(method: "POST", path: path + "/configurations", body: try encoder.encode(request))
    #expect(saved.status == 200, "Response: \(String(decoding: saved.body, as: UTF8.self))")
    request.target = "app-b"
    let second = await router.handle(method: "POST", path: path + "/configurations", body: try encoder.encode(request))
    #expect(second.status == 200)
    let state = try await service.launchState(agentID: agentID, sessionID: session.id)
    #expect(state.configurations.count == 2)
    let noBuild = LaunchConfigurationRequest(name: "Stale app", target: "macOS", platform: .macOS, checkoutPath: root.path, appPath: "dist/App.app")
    let stale = await router.handle(method: "POST", path: path + "/configurations", body: try encoder.encode(noBuild))
    #expect(stale.status == 400)
    #expect(String(decoding: stale.body, as: UTF8.self).contains("build command"))
    request.workingDirectory = "../escape"
    let rejected = await router.handle(method: "POST", path: path + "/configurations", body: try encoder.encode(request))
    #expect(rejected.status == 400)
    #expect(try await service.launchState(agentID: agentID, sessionID: session.id).configurations.count == 2)
    let unavailable = await router.handle(method: "GET", path: "/v1/agents/\(agentID)/sessions/missing/launch", body: nil)
    #expect(unavailable.status == 404)
    try await service.deleteAgentSession(agentID: agentID, sessionID: session.id)
    #expect(try await !service.launches.retainsCheckout(root.path))
}
