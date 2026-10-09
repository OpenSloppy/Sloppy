import Foundation
import SloppyClientCore
import SloppyFeatureChat
import Testing
@testable import SloppyClient

@Suite("Inbox instance loading", .serialized)
@MainActor
struct InboxInstanceLoadingTests {
    @Test(arguments: ["/v1/projects", "/v1/agents/agent/sessions"])
    func skeletonWaitsForProjectsAndSessionCatalog(delayedPath: String) async throws {
        let fixture = InboxLoadingFixture(delayedPath: delayedPath)
        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "agent", displayName: "Cached agent")])
        await cache.cacheProjects([APIProjectRecord(id: "cached", name: "Cached project")])
        let model = makeModel(api: fixture.api, cache: cache)
        let previousSelection = model.settings.instanceSelection
        let previousContext = (model.settings.lastAgentId, model.settings.lastProjectId, model.settings.lastSessionId)
        defer {
            fixture.release()
            model.chatViewModel.closeSession()
            model.settings.instanceSelection = previousSelection
            model.settings.lastAgentId = previousContext.0
            model.settings.lastProjectId = previousContext.1
            model.settings.lastSessionId = previousContext.2
        }
        let projects = Task { await model.loadProjects() }
        let catalog = Task {
            await model.chatViewModel.waitForInitialData()
            await model.loadAggregatedChatCatalogIfNeeded()
        }
        try await waitUntil { fixture.hasPendingResponse && model.chatViewModel.didLoadInitialData }
        #expect(!model.hasLoadedInitialContent)
        fixture.release()
        await projects.value
        await catalog.value
        #expect(model.hasLoadedInitialContent)
        #expect(model.projects.map(\.id) == ["fresh"])
        #expect(model.sidebarSessionCatalog.map(\.id) == ["fresh-chat"])
        if delayedPath == "/v1/projects" {
            fixture.holdAgain()
            let refresh = Task { await model.loadProjects(force: true) }
            try await waitUntil { fixture.hasPendingResponse }
            #expect(model.hasLoadedInitialContent)
            fixture.release()
            await refresh.value
        }
    }

    @Test func switchingInstancesRejectsThePreviousInboxResponse() async throws {
        let fixture = InboxLoadingFixture(delayedPath: "/v1/projects")
        let cache = ClientCacheStore(path: ":memory:")
        let model = makeModel(api: fixture.api, cache: cache)
        let previousSelection = model.settings.instanceSelection
        defer {
            fixture.release()
            model.chatViewModel.closeSession()
            model.settings.instanceSelection = previousSelection
        }
        let request = Task { await model.loadProjects() }
        try await waitUntil { fixture.hasPendingResponse }
        model.selectInstance(.instance("another-instance"))
        #expect(!model.hasLoadedInitialContent)
        fixture.release()
        await request.value
        #expect(model.projects.isEmpty)
        #expect(await cache.loadProjects().isEmpty)
        await model.loadAggregatedChatCatalogIfNeeded()
        #expect(!model.hasLoadedInitialContent)
    }

    @Test func defaultCachesKeepAgentsAndSessionsOnTheirOwnInstance() async {
        let first = makeModel(api: InboxLoadingFixture(delayedPath: "").api)
        let second = makeModel(api: InboxLoadingFixture(delayedPath: "").api)
        defer {
            first.chatViewModel.closeSession()
            second.chatViewModel.closeSession()
            for model in [first, second] {
                let namespaces = [model.endpoint.cacheNamespace,
                    model.endpoint.cacheNamespace + ":inbox-projects:" + model.settings.instanceDirectoryKey]
                for namespace in namespaces {
                    let path = ClientCacheStore.defaultDatabasePath(namespace: namespace)
                    for suffix in ["", "-wal", "-shm"] {
                        try? FileManager.default.removeItem(atPath: path + suffix)
                    }
                }
            }
        }
        await first.cacheStore.cacheAgents([APIAgentRecord(id: "same-id", displayName: "First instance")])
        await first.cacheStore.cacheSessions(agentId: "same-id", projectId: nil,
            sessions: [ChatSessionSummary(id: "old-chat", agentId: "same-id", title: "First instance")])
        #expect(await second.cacheStore.loadAgents().isEmpty)
        #expect(await second.cacheStore.loadSessions(agentId: "same-id").isEmpty)
    }

    private func makeModel(api: SloppyAPIClient, cache: ClientCacheStore? = nil) -> MainViewModel {
        let settings = ClientSettings()
        // An empty directory uses the injected primary API, as a standalone instance does.
        settings.discoveredInstances = []
        return MainViewModel(endpoint: api.endpoint, settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL), cacheStore: cache, apiClient: api,
            responseNotificationScheduler: InboxLoadingNotifications(),
            onOpenSettings: { _ in }, onOpenWorkspace: {})
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
}

@MainActor
private final class InboxLoadingNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}

private final class InboxLoadingFixture: @unchecked Sendable {
    let api: SloppyAPIClient
    private let state: InboxLoadingURLProtocol.State

    init(delayedPath: String) {
        let host = "inbox-\(UUID().uuidString).invalid"
        state = InboxLoadingURLProtocol.State(delayedPath: delayedPath)
        InboxLoadingURLProtocol.registry.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InboxLoadingURLProtocol.self]
        api = SloppyAPIClient(baseURL: URL(string: "http://\(host)")!,
            session: URLSession(configuration: configuration), authSessionStore: AuthSessionStore(persistence: .memory))
    }

    var hasPendingResponse: Bool { state.hasPendingResponse }
    func release() { state.release() }
    func holdAgain() { state.holdAgain() }
}

private final class InboxLoadingURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let state = Self.registry.state(host: url.host ?? "") else { return }
        state.respond(self, path: url.path)
    }
    override func stopLoading() {}

    func finish() {
        guard let url = request.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        switch url.path {
        case "/v1/projects":
            data = try! encoder.encode([APIProjectRecord(id: "fresh", name: "Fresh project")])
        case "/v1/agents":
            data = try! encoder.encode([APIAgentRecord(id: "agent", displayName: "Fresh agent")])
        case "/v1/agents/agent/sessions":
            data = try! encoder.encode([ChatSessionSummary(id: "fresh-chat", agentId: "agent", title: "Fresh chat")])
        default:
            data = Data("[]".utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let delayedPath: String
        private var released = false
        private var pending: [InboxLoadingURLProtocol] = []
        init(delayedPath: String) { self.delayedPath = delayedPath }
        var hasPendingResponse: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !pending.isEmpty
        }
        func respond(_ request: InboxLoadingURLProtocol, path: String) {
            lock.lock()
            let hold = path == delayedPath && !released
            if hold { pending.append(request) }
            lock.unlock()
            if !hold { request.finish() }
        }
        func release() {
            lock.lock()
            released = true
            let requests = pending
            pending.removeAll()
            lock.unlock()
            for request in requests { request.finish() }
        }
        func holdAgain() {
            lock.lock()
            defer { lock.unlock() }
            released = false
        }
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String: State] = [:]
        func register(_ state: State, host: String) {
            lock.lock()
            defer { lock.unlock() }
            states[host] = state
        }
        func state(host: String) -> State? {
            lock.lock()
            defer { lock.unlock() }
            return states[host]
        }
    }
}
