import Foundation
import Testing
import SloppyClientCore
import SloppyFeatureChat
@testable import SloppyClient

@Suite("Workspace source file navigation", .serialized)
@MainActor
struct WorkspaceSourceFileTests {
    @Test func opensUsingTheConversationEndpointRatherThanTheMainEndpoint() throws {
        let mainAPI = SloppyAPIClient(baseURL: URL(string: "https://main.invalid")!)
        let originAPI = SloppyAPIClient(endpoint: .managed(relayURL: URL(string: "https://relay.invalid")!, targetDeviceID: UUID()))
        let notifications = SourceFileNavigationNotifications()
        let main = MainViewModel(endpoint: mainAPI.endpoint, settings: ClientSettings(),
            connectionMonitor: ConnectionMonitor(baseURL: mainAPI.baseURL), cacheStore: ClientCacheStore(path: ":memory:"),
            apiClient: mainAPI, responseNotificationScheduler: notifications, onOpenSettings: { _ in }, onOpenWorkspace: {})
        let origin = ChatScreenViewModel(apiClient: originAPI, cacheStore: ClientCacheStore(path: ":memory:"), settings: ClientSettings(),
            connectionMonitor: ConnectionMonitor(baseURL: originAPI.baseURL), responseNotificationScheduler: notifications, onOpenSettings: { _ in })
        defer { main.chatViewModel.closeSession(); origin.closeSession() }
        main.openSourceFile(.init(path: "/remote/File.swift", line: 42), from: origin)
        let file = try #require(main.workspaceDockState.selectedTab?.sourceFile)
        #expect(file.apiClient.endpoint == originAPI.endpoint)
        #expect(file.apiClient.endpoint != mainAPI.endpoint)
        #expect(file.reference.line == 42)
        #expect(main.workspaceDockState.isPresented)
    }

    @Test func reusesFileTabAndKeepsOtherFilesAndTools() throws {
        let api = SloppyAPIClient(baseURL: URL(string: "https://file-test.invalid")!)
        let dock = WorkspaceDockState()
        let browser = dock.open(.browser)
        let first = dock.openSourceFile(.init(path: "Sources/First.swift", line: 10), apiClient: api, scope: .project("one"))
        let second = dock.openSourceFile(.init(path: "Sources/Second.swift", line: 20), apiClient: api, scope: .project("one"))
        dock.hide()
        let reopened = dock.openSourceFile(.init(path: "Sources/First.swift", line: 30), apiClient: api, scope: .project("one"))
        #expect(reopened === first)
        #expect(dock.tabs.count == 3)
        #expect(dock.isPresented)
        #expect(dock.selectedID == first.id)
        #expect(first.title == "First.swift")
        #expect(first.sourceFile?.reference.line == 30)
        #expect(second.sourceFile?.reference.line == 20)
        #expect(dock.tabs.contains { $0 === browser })
        let files = dock.open(.files)
        #expect(files.sourceFile == nil)
        #expect(files !== first && files !== second)
        dock.close(first.id)
        #expect(!dock.tabs.contains { $0 === first })
    }

    @Test func samePathOnDifferentServersOrProjectsHasSeparateTabs() {
        let api = SloppyAPIClient(baseURL: URL(string: "https://first.invalid")!)
        let remote = SloppyAPIClient(endpoint: .managed(relayURL: URL(string: "https://relay.invalid")!, targetDeviceID: UUID()))
        let dock = WorkspaceDockState()
        let ref = SourceFileReference(path: "File.swift", line: 1)
        dock.openSourceFile(ref, apiClient: api, scope: .project("one"))
        dock.openSourceFile(ref, apiClient: api, scope: .project("two"))
        dock.openSourceFile(ref, apiClient: remote, scope: .project("one"))
        #expect(dock.tabs.count == 3)
        #expect(dock.selectedTab?.sourceFile?.apiClient.endpoint == remote.endpoint)
    }

    @Test func loadsThroughOriginAPIAndNormalizesLines() async throws {
        let fixture = SourceFileFixture()
        let model = WorkspaceSourceFileViewModel(reference: .init(path: "/remote/File.swift", line: 2),
            apiClient: fixture.api, scope: .project("project"))
        await model.loadIfNeeded()
        #expect(model.lines == ["first", "second", "third", ""])
        #expect(model.targetLine == 2)
        #expect(model.errorMessage == nil)
        let request = try #require(fixture.requests.first)
        #expect(request.url?.path == "/v1/projects/project/files/content")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/remote/File.swift")
        model.navigate(to: .init(path: "/remote/File.swift", line: 999))
        await model.loadIfNeeded()
        #expect(model.targetLine == 4)
        #expect(model.isLineOutsideFile)
        #expect(fixture.requests.count == 1)
        model.reload()
        await model.loadIfNeeded()
        #expect(fixture.requests.count == 2)
        #expect(model.reference.line == 999)
        #expect(model.content != nil)
    }

    @Test func agentWorkspaceAndFailureStayInPanel() async throws {
        let fixture = SourceFileFixture()
        let model = WorkspaceSourceFileViewModel(reference: .init(path: "missing.swift"),
            apiClient: fixture.api, scope: .agent("agent"))
        await model.loadIfNeeded()
        #expect(fixture.requests.first?.url?.path == "/v1/agents/agent/files/content")
        #expect(model.content == nil)
        #expect(model.errorMessage != nil)
        let unavailable = WorkspaceSourceFileViewModel(reference: .init(path: "File.swift"), apiClient: fixture.api, scope: .unavailable)
        await unavailable.loadIfNeeded()
        #expect(unavailable.errorMessage != nil)
        #expect(fixture.requests.count == 1)
    }
}

@MainActor
private final class SourceFileNavigationNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}

final class SourceFileFixture: @unchecked Sendable {
    let api: SloppyAPIClient
    private let host = "source-file-\(UUID().uuidString).invalid"
    init(content: String = "first\r\nsecond\rthird\n") {
        SourceFileURLProtocol.register(content: content, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFileURLProtocol.self]
        api = SloppyAPIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: config),
                              authSessionStore: AuthSessionStore(persistence: .memory))
    }
    var requests: [URLRequest] { SourceFileURLProtocol.requests(for: host) }
}

private final class SourceFileURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var contents: [String: String] = [:]
    static func register(content: String, host: String) {
        lock.withLock { contents[host] = content }
    }
    static func requests(for host: String) -> [URLRequest] {
        lock.withLock { captured.filter { $0.url?.host == host } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.captured.append(request) }
        guard let url = request.url else { return }
        let missing = url.query?.contains("missing.swift") == true
        let response = HTTPURLResponse(url: url, statusCode: missing ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        let text = Self.lock.withLock { Self.contents[url.host ?? ""] ?? "" }
        let content = ProjectFileContentResponse(path: "/remote/File.swift", content: text, sizeBytes: text.utf8.count)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: missing ? Data("{}".utf8) : (try! JSONEncoder().encode(content)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
