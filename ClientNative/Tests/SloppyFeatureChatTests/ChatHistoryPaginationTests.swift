import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Chat history pagination", .serialized)
@MainActor
struct ChatHistoryPaginationTests {
    @Test func initialLoadIsBoundedAndReadyDoesNotDuplicateIt() async throws {
        let fixture = try await HistoryFixture.make(holdsLatest: true)
        defer { fixture.finish() }
        fixture.model.pickSession(.init(id: "one", agentId: "agent", title: "One"))
        try await fixture.wait { fixture.server.latestCount == 1 }
        fixture.stream.yield(.init(kind: .sessionReady, cursor: 1_000_000))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.server.latestCount == 1)
        #expect(fixture.model.isLoadingTranscript)
        fixture.server.releaseLatest()
        try await fixture.wait { !fixture.model.isLoadingTranscript }
        #expect(fixture.model.transcript.messages.count == 64)
        #expect(fixture.model.transcript.messages.first?.id == "msg-128")
        #expect(fixture.model.hasEarlierTranscriptMessages)
        #expect(fixture.server.queries.allSatisfy { $0["eventLimit"] == "64" })
    }

    @Test func olderPagesPreserveMessagesAndStopAtHistoryStart() async throws {
        let fixture = try await HistoryFixture.make()
        defer { fixture.finish() }
        fixture.model.pickSession(.init(id: "one", agentId: "agent", title: "One"))
        try await fixture.wait { !fixture.model.isLoadingTranscript }
        fixture.model.loadEarlierMessages()
        fixture.model.loadEarlierMessages()
        try await fixture.wait { !fixture.model.isLoadingEarlierMessages }
        #expect(fixture.server.olderCount == 1)
        #expect(fixture.model.transcript.messages.map(\.id) == (64..<192).map { "msg-\($0)" })
        // A tail refresh must retain both the older page and its cursor.
        fixture.model.handleStreamUpdate(.init(kind: .sessionReady, cursor: 1_000_000), agentId: "agent", sessionId: "one")
        try await fixture.wait { fixture.server.latestCount == 2 }
        fixture.model.loadEarlierMessages()
        try await fixture.wait { !fixture.model.isLoadingEarlierMessages }
        #expect(fixture.model.transcript.messages.map(\.id) == (0..<192).map { "msg-\($0)" })
        #expect(!fixture.model.hasEarlierTranscriptMessages)
        fixture.model.loadEarlierMessages()
        #expect(fixture.server.olderCount == 2)
    }

    @Test func failedPageRetainsCursorAndCanBeRetried() async throws {
        let fixture = try await HistoryFixture.make()
        defer { fixture.finish() }
        fixture.model.pickSession(.init(id: "one", agentId: "agent", title: "One"))
        try await fixture.wait { !fixture.model.isLoadingTranscript }
        fixture.server.failsOlder = true
        fixture.model.loadEarlierMessages()
        try await fixture.wait { !fixture.model.isLoadingEarlierMessages }
        #expect(fixture.model.transcriptLoadError != nil)
        #expect(fixture.model.transcript.messages.count == 64)
        #expect(fixture.model.hasEarlierTranscriptMessages)
        fixture.server.failsOlder = false
        fixture.model.retryTranscriptLoad()
        try await fixture.wait { !fixture.model.isLoadingEarlierMessages }
        #expect(fixture.model.transcriptLoadError == nil)
        #expect(fixture.model.transcript.messages.count == 128)
    }

    @Test func programmaticPositioningNeverLoadsHistory() {
        var trigger = ChatHistoryScrollTrigger()
        let results = [
            trigger.didScroll(distanceFromTop: 0, isUserInitiated: false),
            trigger.didScroll(distanceFromTop: 60, isUserInitiated: true),
            trigger.didScroll(distanceFromTop: 10, isUserInitiated: true),
            trigger.didScroll(distanceFromTop: 200, isUserInitiated: false),
            trigger.didScroll(distanceFromTop: 0, isUserInitiated: true),
        ]
        #expect(results == [false, true, false, false, true])
    }

    @Test func initialFailureCanBeRetriedWhileCachedMessagesStayVisible() async throws {
        let fixture = try await HistoryFixture.make(cachedHistory: true)
        defer { fixture.finish() }
        fixture.server.failsLatest = true
        fixture.model.pickSession(.init(id: "one", agentId: "agent", title: "One"))
        try await fixture.wait { !fixture.model.isLoadingTranscript }
        #expect(fixture.model.transcript.messages.count == 64)
        #expect(fixture.model.transcriptLoadError != nil)
        fixture.server.failsLatest = false
        fixture.model.retryTranscriptLoad()
        try await fixture.wait { !fixture.model.isLoadingTranscript }
        #expect(fixture.model.transcriptLoadError == nil)
        #expect(fixture.server.latestCount == 2)
        #expect(fixture.server.olderCount == 0)
    }

    @Test func leavingChatCancelsOlderPageAndIgnoresItsLateResponse() async throws {
        let fixture = try await HistoryFixture.make()
        defer { fixture.finish() }
        fixture.model.pickSession(.init(id: "one", agentId: "agent", title: "One"))
        try await fixture.wait { !fixture.model.isLoadingTranscript }
        fixture.server.holdsOlder = true
        fixture.model.loadEarlierMessages()
        try await fixture.wait { fixture.server.olderCount == 1 }
        fixture.model.pickPersonal()
        fixture.server.releaseLatest()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.model.selectedSessionId == nil)
        #expect(fixture.model.transcript.isEmpty)
        #expect(!fixture.model.isLoadingEarlierMessages)
    }

    @Test func prependingHistoryDeduplicatesOverlapAndPreservesStreaming() {
        let transcript = ChatTranscriptState()
        transcript.replaceAll(HistoryServer.messages(64..<128))
        transcript.appendStreamingAssistantText("Live", messageId: "streaming")
        transcript.reconcile(with: HistoryServer.messages(0..<70), revealingEarlier: true)
        #expect(transcript.messages.count == 129)
        #expect(Set(transcript.messages.map(\.id)).count == 129)
        #expect(transcript.messages.last?.textContent == "Live")
        #expect(transcript.messages.first?.id == "msg-0")
        let previousText = transcript.messages.first?.textContent
        transcript.reconcile(with: [.init(id: "msg-0", role: .user,
                                         segments: [.init(kind: .text, text: "Old version")])], revealingEarlier: true)
        #expect(transcript.messages.first?.textContent == previousText)
    }
}

@MainActor
private struct HistoryFixture {
    let model: ChatScreenViewModel
    let server: HistoryServer
    let stream: AsyncStream<ChatStreamUpdate>.Continuation
    let settings: ClientSettings
    let previous: (String?, String?, String?)

    static func make(holdsLatest: Bool = false, cachedHistory: Bool = false) async throws -> Self {
        let server = HistoryServer()
        server.holdsLatest = holdsLatest
        let host = "history-\(UUID().uuidString.lowercased()).invalid"
        HistoryURLProtocol.register(server, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HistoryURLProtocol.self]
        let api = SloppyAPIClient(baseURL: try #require(URL(string: "http://\(host)")),
                                  session: URLSession(configuration: config),
                                  authSessionStore: AuthSessionStore(persistence: .memory))
        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "agent", displayName: "Agent")])
        if cachedHistory {
            await cache.cacheSessionDetail(agentId: "agent", detail: .init(
                summary: .init(id: "one", agentId: "agent", title: "One"),
                messages: HistoryServer.messages(128..<192),
                historyPage: .init(nextBefore: "128", hasMore: true)
            ))
        }
        let settings = ClientSettings()
        let previous = (settings.lastAgentId, settings.lastSessionId, settings.lastProjectId)
        settings.lastAgentId = "agent"
        settings.lastSessionId = nil
        settings.lastProjectId = nil
        let pair = AsyncStream<ChatStreamUpdate>.makeStream()
        let model = ChatScreenViewModel(
            apiClient: api, cacheStore: cache, settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL), restoresLastSession: false,
            responseNotificationScheduler: HistoryNotifications(),
            sessionStreamProvider: { _, _ in pair.stream }, onOpenSettings: { _ in }
        )
        model.loadInitialData()
        await model.waitForInitialData()
        return Self(model: model, server: server, stream: pair.continuation, settings: settings, previous: previous)
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    func finish() {
        server.releaseLatest()
        stream.finish()
        model.closeSession()
        settings.lastAgentId = previous.0
        settings.lastSessionId = previous.1
        settings.lastProjectId = previous.2
    }
}

@MainActor
private final class HistoryNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}

private final class HistoryServer: @unchecked Sendable {
    private let lock = NSLock()
    private var storedQueries: [[String: String]] = []
    private var pending: [HistoryURLProtocol] = []
    private var holds = false
    private var holdsOld = false
    private var fails = false
    private var failsTail = false
    var holdsLatest: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }
    var holdsOlder: Bool {
        get { lock.withLock { holdsOld } }
        set { lock.withLock { holdsOld = newValue } }
    }
    var failsOlder: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }
    var failsLatest: Bool {
        get { lock.withLock { failsTail } }
        set { lock.withLock { failsTail = newValue } }
    }
    var queries: [[String: String]] { lock.withLock { storedQueries } }
    var latestCount: Int { queries.filter { $0["before"] == nil }.count }
    var olderCount: Int { queries.filter { $0["before"] != nil }.count }

    static func messages(_ range: Range<Int>) -> [ChatMessage] {
        range.map { ChatMessage(id: "msg-\($0)", role: .user,
                               segments: [.init(kind: .text, text: "Message \($0)")],
                               createdAt: Date(timeIntervalSince1970: Double($0))) }
    }

    func receive(_ request: HistoryURLProtocol) {
        guard let url = request.request.url else { return }
        if url.path == "/v1/agents" { request.respond(Data(#"[{"id":"agent","displayName":"Agent"}]"#.utf8)); return }
        if url.path.hasSuffix("/sessions") { request.respond(Data("[]".utf8)); return }
        guard url.path.hasSuffix("/one") else { request.respond(Data("{}".utf8), status: 404); return }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let held = lock.withLock {
            storedQueries.append(query)
            if (query["before"] == nil && holds) || (query["before"] != nil && holdsOld) {
                pending.append(request)
                return true
            }
            return false
        }
        if !held { respond(request, before: query["before"]) }
    }

    func releaseLatest() {
        let requests = lock.withLock { let result = pending; pending = []; holds = false; holdsOld = false; return result }
        for request in requests {
            let before = request.request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            }
            respond(request, before: before)
        }
    }

    private func respond(_ request: HistoryURLProtocol, before: String?) {
        if before != nil, failsOlder { request.respond(Data("{}".utf8), status: 503); return }
        if before == nil, failsLatest { request.respond(Data("{}".utf8), status: 503); return }
        let end = before.flatMap(Int.init) ?? 192
        let start = max(0, end - 64)
        struct Payload: Encodable {
            let summary: ChatSessionSummary
            let messages: [ChatMessage]
            let historyPage: ChatSessionHistoryPage
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(Payload(summary: .init(id: "one", agentId: "agent", title: "One"),
                                               messages: Self.messages(start..<end),
                                               historyPage: .init(nextBefore: start > 0 ? String(start) : nil, hasMore: start > 0)))
        request.respond(data)
    }
}

private final class HistoryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: HistoryServer] = [:]
    static func register(_ server: HistoryServer, host: String) { lock.withLock { servers[host] = server } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host, let server = Self.lock.withLock({ Self.servers[host] }) { server.receive(self) }
    }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
