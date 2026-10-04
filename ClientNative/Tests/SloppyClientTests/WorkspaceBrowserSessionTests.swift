#if os(macOS)
import AppKit
import Foundation
import SloppyClientCore
import Testing
import SloppyUITestSupport
@testable import SloppyClient

@Suite("Workspace browser connection", .serialized, .appKitUI)
@MainActor
struct WorkspaceBrowserSessionTests {
    @Test func pollsExecutesAndReturnsPageAndScreenshot() async throws {
        let site = try BrowserHTTPFixture()
        let url = try await site.start()
        let probe = BrowserBridgeProbe(url: url.absoluteString)
        BrowserBridgeURLProtocol.install { request, body in
            await probe.respond(path: request.url?.path ?? "", token: request.value(forHTTPHeaderField: "Authorization"), body: body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BrowserBridgeURLProtocol.self]
        let api = SloppyAPIClient(baseURL: try #require(URL(string: "https://browser-test.invalid")),
                                  authToken: "browser-test-token", session: URLSession(configuration: config))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        var browser: WorkspaceBrowserSession?
        var presentations = 0
        browser = WorkspaceBrowserSession(apiClient: api, agentID: "agent", sessionID: "session") {
            presentations += 1
            window.contentView = browser?.viewModel.browserRuntime?.webView
        }
        let active = try #require(browser)
        active.start()
        defer {
            active.stop()
            window.orderOut(nil)
            browser = nil
            BrowserBridgeURLProtocol.install(nil)
        }
        for _ in 0..<600 {
            if await probe.results.count == 4 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let results = await probe.results
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0.error == nil && $0.binding.bridgeId == active.binding.bridgeId })
        #expect(results.last?.data?.visibleText.contains("Verified: Sloppy") == true)
        let screenshot = try #require(results.last?.imageBase64.flatMap { Data(base64Encoded: $0) })
        #expect(screenshot.starts(with: [137, 80, 78, 71]))
        #expect(presentations == 4)
        #expect(await probe.usedExpectedToken)
        active.stop()
        for _ in 0..<100 {
            if await probe.didDisconnect { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.didDisconnect)
        withExtendedLifetime(site) {}
    }
}

private actor BrowserBridgeProbe {
    var results: [WorkspaceBrowserCompletion] = []
    var usedExpectedToken = true
    var didDisconnect = false
    private var sent = 0
    private let url: String

    init(url: String) { self.url = url }

    func respond(path: String, token: String?, body: Data) -> Data {
        usedExpectedToken = usedExpectedToken && token == "Bearer browser-test-token"
        if path.hasSuffix("/poll") {
            let commands: [[String: Any]] = [
                ["id": "open", "name": "open", "input": ["url": url]],
                ["id": "type", "name": "type", "input": ["selector": "#name", "text": "Sloppy"]],
                ["id": "click", "name": "click", "input": ["selector": "#check"]],
                ["id": "screenshot", "name": "screenshot", "input": [:]],
            ]
            let next = sent < commands.count ? [commands[sent]] : []
            sent += 1
            return (try? JSONSerialization.data(withJSONObject: ["commands": next])) ?? Data()
        }
        if path.hasSuffix("/disconnect") { didDisconnect = true }
        if path.hasSuffix("/complete"), let result = try? JSONDecoder().decode(WorkspaceBrowserCompletion.self, from: body) {
            results.append(result)
        }
        return Data("{}".utf8)
    }
}

private final class BrowserBridgeURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) async -> Data
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: Handler?) { lock.withLock { self.handler = handler } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        let requestBody = body
        Task {
            guard let handler, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let data = await handler(request, requestBody)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
#endif
