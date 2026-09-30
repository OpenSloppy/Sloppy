import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Chat delivery reliability", .serialized)
@MainActor
struct ChatDeliveryReliabilityTests {
    @Test("an unrelated old user event cannot remove a new submission")
    func unrelatedAcknowledgement() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.model.sendMessage(content: "new submission")
        try await fixture.wait { fixture.server.posts.count == 1 }
        let optimisticID = try #require(fixture.model.transcript.optimisticMessages.first?.id)
        fixture.model.handleStreamUpdate(ChatStreamUpdate(
            kind: .sessionEvent, cursor: 1,
            message: ChatMessage(id: "old-message", role: .user, segments: [.init(kind: .text, text: "old")])
        ), agentId: "agent", sessionId: "one")
        #expect(fixture.model.transcript.optimisticMessages.map(\.id) == [optimisticID])
        let clientID = String(optimisticID.dropFirst("optimistic-user-".count))
        #expect(fixture.server.posts.first?.payload["clientMessageId"] as? String == clientID)
        fixture.model.handleStreamUpdate(ChatStreamUpdate(
            kind: .sessionEvent, cursor: 2,
            message: ChatMessage(id: clientID, role: .user, segments: [.init(kind: .text, text: "new submission")])
        ), agentId: "agent", sessionId: "one")
        #expect(fixture.model.transcript.optimisticMessages.isEmpty)
        #expect(fixture.model.transcript.messages.contains { $0.id == "old-message" })
    }

    @Test("done before POST response still drains the queue and preserves the composer")
    func completionBeforePost() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.model.sendMessage(content: "first")
        try await fixture.wait { fixture.server.posts.count == 1 }
        fixture.model.sendMessage(content: "second")
        fixture.model.composerDraft.text = "unsent draft"
        fixture.done(sessionId: "one", cursor: 1)
        await Task.yield()
        #expect(fixture.server.posts.count == 1)
        fixture.server.releasePost(0)
        try await fixture.wait { fixture.server.posts.count == 2 }
        #expect(fixture.server.posts.map { $0.payload["content"] as? String } == ["first", "second"])
        #expect(fixture.model.composerDraft.text == "unsent draft")
        #expect(fixture.model.queuedMessages.isEmpty)
    }

    @Test("switching chats keeps queued sends in their original chat")
    func backgroundQueue() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.model.sendMessage(content: "first")
        try await fixture.wait { fixture.server.posts.count == 1 }
        fixture.model.sendMessage(content: "second")
        fixture.model.pickSession(.init(id: "two", agentId: "agent", title: "Two"))
        try await fixture.wait { fixture.model.selectedSessionId == "two" && !fixture.model.isLoadingTranscript }
        fixture.model.composerDraft.text = "other chat draft"
        fixture.server.releasePost(0)
        try await fixture.wait { fixture.server.posts.count == 2 }
        #expect(fixture.server.posts[1].path.contains("/sessions/one/messages"))
        #expect(fixture.model.selectedSessionId == "two")
        #expect(!fixture.model.isSending)
        #expect(fixture.model.composerDraft.text == "other chat draft")
        #expect(!fixture.model.transcript.messages.contains { $0.textContent == "second" })
    }

    @Test("queued delivery survives the screen releasing its view model")
    func deliverySurvivesScreenRelease() async throws {
        var fixture: DeliveryFixture? = try await DeliveryFixture.make()
        let server = try #require(fixture?.server)
        let stream = try #require(fixture?.stream)
        let settings = try #require(fixture?.settings)
        let previous = try #require(fixture?.previousSettings)
        weak var model = fixture?.model
        defer {
            server.releaseAll()
            stream.finish()
            settings.lastAgentId = previous.0
            settings.lastProjectId = previous.1
            settings.lastSessionId = previous.2
        }
        fixture?.model.handleStreamUpdate(.init(kind: .sessionEvent, cursor: 1, streamEvent: .init(
            id: "working-before-open", type: .runStatus, runStatus: .init(stage: .thinking, label: "Thinking")
        )), agentId: "agent", sessionId: "one")
        fixture?.model.sendMessage(content: "send after background run")
        try await fixture?.wait { fixture?.model.isStopping == false }
        fixture = nil
        stream.yield(.init(kind: .sessionEvent, cursor: 2, streamEvent: .init(
            id: "background-done", type: .runStatus, runStatus: .init(stage: .done, label: "Done")
        )))
        for _ in 0..<300 {
            if server.posts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.posts.count == 1)
        #expect(model != nil)
        #expect(server.posts.first?.payload["content"] as? String == "send after background run")
    }

    @Test("navigation during first-session creation preserves queued submissions")
    func navigationDuringCreation() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.model.pickPersonal()
        fixture.model.sendMessage(content: "first new chat message")
        try await fixture.wait { fixture.server.creationCount == 1 }
        fixture.model.sendMessage(content: "second new chat message")
        fixture.model.pickSession(.init(id: "two", agentId: "agent", title: "Two"))
        try await fixture.wait { fixture.model.selectedSessionId == "two" && !fixture.model.isLoadingTranscript }
        fixture.model.composerDraft.text = "draft in another chat"
        fixture.server.releaseCreation()
        try await fixture.wait { fixture.server.posts.count == 1 }
        fixture.server.releasePost(0)
        try await fixture.wait { fixture.server.posts.count == 2 }
        #expect(fixture.server.posts.allSatisfy { $0.path.contains("/sessions/created/messages") })
        #expect(fixture.model.selectedSessionId == "two")
        #expect(fixture.model.composerDraft.text == "draft in another chat")
    }

    @Test("the POST receipt acknowledges one submission on legacy Core versions")
    func legacyReceiptAcknowledgement() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.model.sendMessage(content: "legacy")
        try await fixture.wait { fixture.server.posts.count == 1 }
        fixture.server.releasePost(0, echoesClientID: false)
        try await fixture.wait { !fixture.model.isSending }
        #expect(fixture.model.transcript.optimisticMessages.isEmpty)
        #expect(fixture.model.transcript.messages.contains { $0.id == "legacy-message" && $0.textContent == "legacy" })
    }

    @Test("slow auxiliary HTTP does not block the next WebSocket message")
    func auxiliaryRequestDoesNotBlockStream() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.server.holdsUsage = true
        fixture.stream.yield(.init(kind: .sessionEvent, cursor: 1, streamEvent: .init(
            id: "working", type: .runStatus, runStatus: .init(stage: .thinking, label: "Thinking", selectedModel: "model")
        )))
        try await fixture.wait { fixture.server.heldUsageCount > 0 }
        fixture.stream.yield(.init(kind: .sessionEvent, cursor: 2, message: .init(
            id: "next-message", role: .user, segments: [.init(kind: .text, text: "visible while usage waits")]
        )))
        try await fixture.wait { fixture.model.transcript.messages.contains { $0.id == "next-message" } }
        #expect(fixture.server.heldUsageCount > 0)
    }

    @Test("cursor gaps request history without applying an old run status over a live one")
    func gapRecovery() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.server.historyMessages = [ChatMessage(id: "missed", role: .user, segments: [.init(kind: .text, text: "Recovered")])]
        fixture.model.handleStreamUpdate(.init(kind: .heartbeat, cursor: 100), agentId: "agent", sessionId: "one")
        fixture.model.handleStreamUpdate(.init(kind: .heartbeat, cursor: 103), agentId: "agent", sessionId: "one")
        try await fixture.wait { fixture.model.transcript.messages.contains { $0.id == "missed" } }
    }

    @Test("a delayed history response cannot roll a live run back to done")
    func staleHistoryDoesNotOverrideLiveStatus() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.server.historyMessages = [.init(id: "stale-history", role: .user, segments: [.init(kind: .text, text: "Snapshot")])]
        fixture.server.holdsHistory = true
        fixture.model.handleStreamUpdate(.init(kind: .sessionReady, cursor: 100), agentId: "agent", sessionId: "one")
        try await fixture.wait { fixture.server.heldHistoryCount > 0 }
        fixture.model.handleStreamUpdate(.init(kind: .sessionEvent, cursor: 101, streamEvent: .init(
            id: "new-turn", type: .runStatus, runStatus: .init(stage: .thinking, label: "Thinking")
        )), agentId: "agent", sessionId: "one")
        fixture.server.releaseHistory()
        try await fixture.wait { fixture.model.transcript.messages.contains { $0.id == "stale-history" } }
        #expect(fixture.model.isAwaitingAgentResponse)
        #expect(fixture.model.activeRunStatus?.stage == .thinking)
    }

    @Test("a POST failure after the matching live acknowledgement does not restore a duplicate draft")
    func acknowledgedPostFailure() async throws {
        let fixture = try await DeliveryFixture.make()
        defer { fixture.finish() }
        fixture.model.sendMessage(content: "persisted")
        try await fixture.wait { fixture.server.posts.count == 1 }
        let optimistic = try #require(fixture.model.transcript.optimisticMessages.first)
        let id = String(optimistic.id.dropFirst("optimistic-user-".count))
        fixture.model.handleStreamUpdate(.init(kind: .sessionEvent, cursor: 1, message: .init(
            id: id, role: .user, segments: [.init(kind: .text, text: "persisted")]
        )), agentId: "agent", sessionId: "one")
        fixture.server.posts[0].request.respond("{}", status: 500)
        try await fixture.wait { !fixture.model.isSending }
        #expect(fixture.model.composerDraft.text.isEmpty)
        #expect(fixture.model.sendErrorMessage == nil)
        #expect(fixture.model.transcript.messages.contains { $0.id == id })
    }

    @Test("repeated heartbeats and connection resets do not create false cursor gaps")
    func cursorTracking() {
        var tracker = ChatStreamCursorTracker()
        let results = [
            tracker.observe(.init(kind: .sessionReady, cursor: 1_000_000)),
            tracker.observe(.init(kind: .heartbeat, cursor: 1_000_000)),
            tracker.observe(.init(kind: .sessionEvent, cursor: 1_000_001)),
            tracker.observe(.init(kind: .sessionEvent, cursor: 1_000_003)),
            tracker.observe(.init(kind: .sessionReady, cursor: 0)),
            tracker.observe(.init(kind: .sessionReady, cursor: 1_000_000))
        ]
        #expect(results == [false, false, false, true, false, false])
    }
}

@MainActor
private struct DeliveryFixture {
    let model: ChatScreenViewModel
    let server: DeliveryHTTPState
    let stream: AsyncStream<ChatStreamUpdate>.Continuation
    let settings: ClientSettings
    let previousSettings: (String?, String?, String?)

    static func make() async throws -> Self {
        let server = DeliveryHTTPState()
        let host = "delivery-\(UUID().uuidString.lowercased()).invalid"
        DeliveryURLProtocol.register(server, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeliveryURLProtocol.self]
        let api = SloppyAPIClient(baseURL: try #require(URL(string: "http://\(host)")), session: URLSession(configuration: configuration))
        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "agent", displayName: "Agent")])
        let settings = ClientSettings()
        let previousSettings = (settings.lastAgentId, settings.lastProjectId, settings.lastSessionId)
        settings.lastAgentId = "agent"
        settings.lastProjectId = nil
        settings.lastSessionId = nil
        let pair = AsyncStream<ChatStreamUpdate>.makeStream()
        let model = ChatScreenViewModel(
            apiClient: api, cacheStore: cache, settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL), restoresLastSession: false,
            responseNotificationScheduler: DeliveryNotifications(),
            sessionStreamProvider: { _, session in session == "one" ? pair.stream : AsyncStream { _ in } },
            onOpenSettings: { _ in }
        )
        model.loadInitialData()
        await model.waitForInitialData()
        model.pickSession(.init(id: "one", agentId: "agent", title: "One"))
        let fixture = Self(model: model, server: server, stream: pair.continuation, settings: settings, previousSettings: previousSettings)
        try await fixture.wait { !model.isLoadingTranscript }
        return fixture
    }

    func done(sessionId: String, cursor: Int) {
        model.handleStreamUpdate(.init(kind: .sessionEvent, cursor: cursor, streamEvent: .init(
            id: "done-\(cursor)", type: .runStatus, runStatus: .init(stage: .done, label: "Done")
        )), agentId: "agent", sessionId: sessionId)
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for chat delivery")
        throw URLError(.timedOut)
    }

    func finish() {
        server.releaseAll()
        stream.finish()
        model.pickPersonal()
        settings.lastAgentId = previousSettings.0
        settings.lastProjectId = previousSettings.1
        settings.lastSessionId = previousSettings.2
    }
}

@MainActor
private final class DeliveryNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}

private final class DeliveryHTTPState: @unchecked Sendable {
    struct Post {
        let path: String
        let payload: [String: Any]
        let request: DeliveryURLProtocol
    }
    private let lock = NSLock()
    private var storedPosts: [Post] = []
    private var creations: [DeliveryURLProtocol] = []
    private var releasesAutomatically = false
    private var usage: [DeliveryURLProtocol] = []
    private var holdUsage = false
    private var history: [ChatMessage] = []
    private var holdHistory = false
    private var pendingHistory: [(DeliveryURLProtocol, String)] = []
    var posts: [Post] { lock.withLock { storedPosts } }
    var creationCount: Int { lock.withLock { creations.count } }
    func releaseCreation() {
        for request in lock.withLock({ creations }) {
            request.respond(#"{"id":"created","agentId":"agent","title":"Created","messageCount":0,"kind":"chat","updatedAt":"2026-10-01T00:00:00Z"}"#)
        }
    }
    var holdsUsage: Bool {
        get { lock.withLock { holdUsage } }
        set { lock.withLock { holdUsage = newValue } }
    }
    var heldUsageCount: Int { lock.withLock { usage.count } }
    var historyMessages: [ChatMessage] {
        get { lock.withLock { history } }
        set { lock.withLock { history = newValue } }
    }

    var holdsHistory: Bool {
        get { lock.withLock { holdHistory } }
        set { lock.withLock { holdHistory = newValue } }
    }
    var heldHistoryCount: Int { lock.withLock { pendingHistory.count } }
    func releaseHistory() {
        let pending = lock.withLock { let result = pendingHistory; pendingHistory = []; holdHistory = false; return result }
        for (request, json) in pending { request.respond(json) }
    }

    func receive(_ request: DeliveryURLProtocol) {
        let path = request.request.url!.path
        if path.hasSuffix("/sessions"), request.request.httpMethod == "POST" {
            lock.withLock { creations.append(request) }
            return
        }
        if path.hasSuffix("/messages"), request.request.httpMethod == "POST" {
            var data = request.request.httpBody ?? Data()
            if let stream = request.request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let releaseIndex = lock.withLock { () -> Int? in
                storedPosts.append(Post(path: path, payload: payload, request: request))
                return releasesAutomatically ? storedPosts.count - 1 : nil
            }
            if let releaseIndex { releasePost(releaseIndex) }
            return
        }
        if path.contains("token-usage"), holdsUsage {
            lock.withLock { usage.append(request) }
            return
        }
        if path == "/v1/agents" { request.respond(#"[{"id":"agent","displayName":"Agent"}]"#); return }
        if path.hasSuffix("/sessions") { request.respond("[]"); return }
        if path.hasSuffix("/one") || path.hasSuffix("/two") {
            let id = path.hasSuffix("/one") ? "one" : "two"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let messages = String(data: (try? encoder.encode(historyMessages)) ?? Data("[]".utf8), encoding: .utf8)!
            let events = holdsHistory ? #"[{"id":"old-done","type":"run_status","runStatus":{"stage":"done","label":"Done"}}]"# : "[]"
            let json = "{\"summary\":{\"id\":\"\(id)\",\"agentId\":\"agent\",\"title\":\"Chat\",\"messageCount\":0,\"updatedAt\":\"2026-10-01T00:00:00Z\",\"kind\":\"chat\"},\"events\":\(events),\"messages\":\(messages)}"
            if holdsHistory {
                lock.withLock { pendingHistory.append((request, json)) }
            } else { request.respond(json) }
            return
        }
        if path.contains("approvals") { request.respond("[]"); return }
        if path.contains("token-usage") { request.respond("{}"); return }
        request.respond("{}", status: 404)
    }

    func releasePost(_ index: Int, echoesClientID: Bool = true) {
        guard posts.indices.contains(index) else { return }
        let post = posts[index]
        let id = echoesClientID ? (post.payload["clientMessageId"] as? String ?? "legacy-message") : "legacy-message"
        let content = post.payload["content"] as? String ?? ""
        let payload: [String: Any] = [
            "summary": ["id": String(post.path.components(separatedBy: "/sessions/").last?.split(separator: "/").first ?? "one"), "agentId": "agent", "title": "Chat", "messageCount": 1, "kind": "chat", "updatedAt": "2026-10-01T00:00:00Z"],
            "appendedEvents": [
                ["id": UUID().uuidString, "type": "message", "message": ["id": id, "role": "user", "createdAt": "2026-10-01T00:00:00Z", "segments": [["kind": "text", "text": content]]]],
                ["id": UUID().uuidString, "type": "run_status", "runStatus": ["stage": "done", "label": "Done"]]
            ]
        ]
        post.request.respond(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
    }

    func releaseAll() {
        lock.withLock { releasesAutomatically = true }
        releaseCreation()
        releaseHistory()
        for index in posts.indices { releasePost(index) }
        let pending = lock.withLock { let result = usage; usage = []; return result }
        for request in pending { request.respond("{}") }
    }
}

private final class DeliveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: DeliveryHTTPState] = [:]
    static func register(_ state: DeliveryHTTPState, host: String) { lock.withLock { states[host] = state } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host, let state = Self.lock.withLock({ Self.states[host] }) {
            state.receive(self)
        } else { respond("{}", status: 404) }
    }
    override func stopLoading() {}
    private let responseLock = NSLock()
    private var responded = false
    func respond(_ json: String, status: Int = 200) {
        let shouldRespond = responseLock.withLock { if responded { return false }; responded = true; return true }
        guard shouldRespond else { return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
