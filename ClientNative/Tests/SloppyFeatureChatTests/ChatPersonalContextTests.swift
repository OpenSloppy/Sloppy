import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Personal chat context", .serialized)
@MainActor
struct ChatPersonalContextTests {
    @Test("project navigation shows its context before agents finish loading", arguments: [false, true])
    func projectNavigationBeforeInitialLoad(selectsPersonal: Bool) async throws {
        let settings = ClientSettings()
        let previousAgent = settings.lastAgentId
        let previousProject = settings.lastProjectId
        let previousSession = settings.lastSessionId
        defer {
            settings.lastAgentId = previousAgent
            settings.lastProjectId = previousProject
            settings.lastSessionId = previousSession
            PersonalChatURLProtocol.reset()
        }

        let project = APIProjectRecord(id: "workspace", name: "Workspace", kind: .workspace)
        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "personal-agent", displayName: "Agent")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalChatURLProtocol.self]
        let api = SloppyAPIClient(
            baseURL: try #require(URL(string: "http://navigation-\(UUID().uuidString).invalid")),
            session: URLSession(configuration: configuration)
        )
        let model = ChatScreenViewModel(
            apiClient: api,
            cacheStore: cache,
            settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false,
            responseNotificationScheduler: PersonalChatNotifications(),
            onOpenSettings: { _ in }
        )
        model.loadInitialData()
        let request = ChatNavigationRequest(
            id: 1,
            context: .project(projectId: project.id, projectName: project.name, agentId: nil),
            opensPreferredSession: false
        )
        model.applyNavigationRequest(request)

        #expect(model.agents.isEmpty)
        #expect(model.activeProjectIdForWorkspacePanel == project.id)
        #expect(model.activeProjectNameForWorkspacePanel == project.name)
        #expect(model.composerFocusRequestToken > 0)

        if selectsPersonal {
            model.pickPersonal()
            await model.waitForInitialData()
            #expect(model.activeProjectIdForWorkspacePanel == nil)
            #expect(model.activeContextTitle == nil)
            #expect(settings.lastProjectId == nil)
            return
        }

        await model.waitForInitialData()
        #expect(model.activeProjectIdForWorkspacePanel == project.id)
        #expect(model.activeProjectNameForWorkspacePanel == project.name)
        #expect(model.selectedSessionId == nil)
        #expect(settings.lastProjectId == project.id)

        model.dismissComposerFocus()
        let focusToken = model.composerFocusRequestToken
        model.applyNavigationRequest(request)
        #expect(model.composerFocusRequestToken == focusToken)
        model.startNewMessage()
        #expect(model.composerFocusRequestToken == focusToken + 1)
        #expect(model.activeProjectIdForWorkspacePanel == project.id)
        model.pickSession(ChatSessionSummary(
            id: "project-session",
            agentId: "personal-agent",
            title: "Project chat",
            projectId: project.id
        ))
        #expect(model.selectedSessionId == "project-session")
        #expect(model.composerFocusRequestToken == focusToken + 2)
        model.pickPersonal()
        #expect(model.composerFocusRequestToken == focusToken + 3)
        #expect(model.activeProjectIdForWorkspacePanel == nil)
    }

    @Test("project entry opens long chat and new message explicitly creates a separate chat")
    func projectDefaultsAndSeparateChat() async throws {
        let settings = ClientSettings()
        let previous = (settings.lastAgentId, settings.lastProjectId, settings.lastSessionId)
        defer {
            settings.lastAgentId = previous.0
            settings.lastProjectId = previous.1
            settings.lastSessionId = previous.2
            PersonalChatURLProtocol.reset()
        }
        settings.lastProjectId = nil
        settings.lastSessionId = nil
        let cache = ClientCacheStore(path: ":memory:")
        let project = APIProjectRecord(id: "workspace", name: "Workspace", kind: .workspace)
        await cache.cacheAgents([APIAgentRecord(id: "personal-agent", displayName: "Agent")])
        await cache.cacheProjects([project])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalChatURLProtocol.self]
        let api = SloppyAPIClient(baseURL: try #require(URL(string: "http://project-default.invalid")),
                                  session: URLSession(configuration: configuration))
        let model = ChatScreenViewModel(
            apiClient: api, cacheStore: cache, settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL), restoresLastSession: false,
            responseNotificationScheduler: PersonalChatNotifications(), onOpenSettings: { _ in })
        await model.waitForInitialData()
        model.applyNavigationRequest(.init(id: 101, context: .project(projectId: project.id, projectName: project.name, agentId: nil)))
        for _ in 0..<200 where model.selectedSessionId == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isLongChat)
        #expect(model.activeProjectIdForWorkspacePanel == project.id)
        let opened = try #require(PersonalChatURLProtocol.capturedRequests.first { $0.path.hasSuffix("/long-chat") })
        let body = try #require(JSONSerialization.jsonObject(with: opened.body) as? [String: Any])
        #expect(body["projectId"] as? String == project.id)
        model.startNewMessage()
        model.sendMessage(content: "Separate task")
        for _ in 0..<200 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }
        let separate = try #require(PersonalChatURLProtocol.capturedRequests.first { $0.path.hasSuffix("/sessions") })
        let payload = try #require(JSONSerialization.jsonObject(with: separate.body) as? [String: Any])
        #expect(payload["separateChat"] as? Bool == true)
        #expect(payload["projectId"] as? String == project.id)
        model.closeSession()
    }

    @Test("typing in an empty chat survives delayed initial revalidation", arguments: [false, true])
    func typingSurvivesInitialRevalidation(switchesProject: Bool) async throws {
        let settings = ClientSettings()
        let previousAgent = settings.lastAgentId
        let previousProject = settings.lastProjectId
        let previousSession = settings.lastSessionId
        defer {
            PersonalChatURLProtocol.releaseGETs()
            PersonalChatURLProtocol.reset()
            settings.lastAgentId = previousAgent
            settings.lastProjectId = previousProject
            settings.lastSessionId = previousSession
        }
        settings.lastAgentId = "personal-agent"
        settings.lastProjectId = nil
        settings.lastSessionId = nil
        let project = APIProjectRecord(id: "workspace", name: "Workspace", kind: .workspace)
        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "personal-agent", displayName: "Agent")])
        await cache.cacheProjects([project])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalChatURLProtocol.self]
        let api = SloppyAPIClient(
            baseURL: try #require(URL(string: "http://draft-\(UUID().uuidString).invalid")),
            session: URLSession(configuration: configuration)
        )
        let model = ChatScreenViewModel(
            apiClient: api, cacheStore: cache, settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false, loadsGlobalSessionCatalog: false,
            responseNotificationScheduler: PersonalChatNotifications(), onOpenSettings: { _ in }
        )
        PersonalChatURLProtocol.holdGETs()
        model.loadInitialData()
        for _ in 0..<200 {
            if model.didLoadInitialData && PersonalChatURLProtocol.hasHeldGETs { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.didLoadInitialData)
        #expect(PersonalChatURLProtocol.hasHeldGETs)
        model.composerDraft.text = "Typed while loading"
        model.addQuoteToComposer("Quoted while loading")
        // The quote saves a snapshot, then normal TextField edits must remain authoritative.
        model.composerDraft.text += " — latest edit"
        if switchesProject {
            model.pickProject(project)
            model.composerDraft.text = "Project draft while loading"
        }
        PersonalChatURLProtocol.releaseGETs()
        await model.waitForInitialData()
        #expect(model.composerDraft.text == (switchesProject
            ? "Project draft while loading" : "Typed while loading — latest edit"))
        if switchesProject {
            model.pickPersonal()
            #expect(model.composerDraft.text == "Typed while loading — latest edit")
        }
        #expect(model.composerQuotes.map(\.text) == ["Quoted while loading"])
        model.sendMessage(content: model.composerDraft.text)
        #expect(model.composerDraft.text.isEmpty)
        for _ in 0..<200 where model.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSending)
        #expect(model.sendErrorMessage == nil)
    }

    @Test("accepted messages request composer focus immediately, including queued messages")
    func acceptedMessagesRequestComposerFocus() async throws {
        let settings = ClientSettings()
        let previousAgent = settings.lastAgentId
        let previousProject = settings.lastProjectId
        let previousSession = settings.lastSessionId
        defer {
            settings.lastAgentId = previousAgent
            settings.lastProjectId = previousProject
            settings.lastSessionId = previousSession
            PersonalChatURLProtocol.reset()
        }

        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "personal-agent", displayName: "Agent")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalChatURLProtocol.self]
        let api = SloppyAPIClient(
            baseURL: try #require(URL(string: "http://focus-\(UUID().uuidString).invalid")),
            session: URLSession(configuration: configuration)
        )
        let model = ChatScreenViewModel(
            apiClient: api,
            cacheStore: cache,
            settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false,
            loadsGlobalSessionCatalog: false,
            responseNotificationScheduler: PersonalChatNotifications(),
            onOpenSettings: { _ in }
        )
        model.pickPersonal()
        await model.waitForInitialData()
        model.dismissComposerFocus()
        let requestToken = model.composerFocusRequestToken
        let resetToken = model.composerFocusResetToken

        model.sendMessage(content: "")
        #expect(model.composerFocusRequestToken == requestToken)

        model.composerDraft.text = "First message"
        model.sendMessage(content: model.composerDraft.text)
        #expect(model.isSending)
        #expect(model.composerDraft.text.isEmpty)
        #expect(model.composerFocusRequestToken == requestToken + 1)
        #expect(model.composerFocusResetToken == resetToken)

        model.composerDraft.text = "Queued message"
        model.sendMessage(content: model.composerDraft.text)
        #expect(model.queuedMessages.map(\.content) == ["Queued message"])
        #expect(model.composerDraft.text.isEmpty)
        #expect(model.composerFocusRequestToken == requestToken + 2)
        #expect(model.composerFocusResetToken == resetToken)
        let queuedMessage = try #require(model.queuedMessages.first)
        model.cancelQueuedMessage(id: queuedMessage.id)

        for _ in 0..<200 where model.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSending)
        #expect(model.composerFocusRequestToken == requestToken + 2)
    }

    @Test("Personal clears project context, preserves drafts, and sends an unscoped chat")
    func switchesContextAndSendsMessage() async throws {
        let settings = ClientSettings()
        let previousAgent = settings.lastAgentId
        let previousProject = settings.lastProjectId
        let previousSession = settings.lastSessionId
        defer {
            settings.lastAgentId = previousAgent
            settings.lastProjectId = previousProject
            settings.lastSessionId = previousSession
            PersonalChatURLProtocol.reset()
        }

        let project = APIProjectRecord(id: "workspace", name: "Workspace", kind: .workspace)
        let cache = ClientCacheStore(path: ":memory:")
        await cache.cacheAgents([APIAgentRecord(id: "personal-agent", displayName: "Agent")])
        await cache.cacheProjects([project])
        settings.lastProjectId = project.id
        settings.lastSessionId = "previous-session"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalChatURLProtocol.self]
        let api = SloppyAPIClient(
            baseURL: try #require(URL(string: "http://personal-\(UUID().uuidString).invalid")),
            session: URLSession(configuration: configuration)
        )
        let model = ChatScreenViewModel(
            apiClient: api,
            cacheStore: cache,
            settings: settings,
            connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false,
            loadsGlobalSessionCatalog: false,
            responseNotificationScheduler: PersonalChatNotifications(),
            onOpenSettings: { _ in }
        )
        model.pickPersonal()
        #expect(settings.lastSessionId == nil)
        await model.waitForInitialData()
        #expect(model.activeProjectIdForWorkspacePanel == nil)
        model.pickProject(project)
        #expect(model.activeProjectIdForWorkspacePanel == project.id)

        model.composerDraft.text = "Workspace draft"
        model.pickPersonal()
        #expect(model.activeProjectIdForWorkspacePanel == nil)
        #expect(model.activeContextTitle == nil)
        #expect(model.selectedSessionId == nil)
        #expect(settings.lastProjectId == nil)
        #expect(model.composerFocusRequestToken > 0)

        model.composerDraft.text = "Personal draft"
        model.pickProject(project)
        #expect(model.activeProjectIdForWorkspacePanel == project.id)
        #expect(model.composerDraft.text == "Workspace draft")
        model.pickPersonal()
        #expect(model.composerDraft.text == "Personal draft")

        model.sendMessage(content: "Hello")
        for _ in 0..<200 where model.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSending)
        #expect(model.sendErrorMessage == nil)
        #expect(model.selectedSessionId == "personal-session")
        let requests = PersonalChatURLProtocol.capturedRequests
        let creation = try #require(requests.first { $0.path.hasSuffix("/sessions") })
        let payload = try #require(JSONSerialization.jsonObject(with: creation.body) as? [String: Any])
        #expect(payload["kind"] as? String == "chat")
        #expect(payload["projectId"] == nil)
        #expect(payload["taskId"] == nil)
        #expect(payload["workspaceId"] == nil)
        let message = try #require(requests.first { $0.path.hasSuffix("/messages") })
        let messagePayload = try #require(JSONSerialization.jsonObject(with: message.body) as? [String: Any])
        #expect(messagePayload["content"] as? String == "Hello")

        model.pickPersonal()
        model.startNewMessage()
        await model.refreshCurrentContext()
        #expect(model.activeProjectIdForWorkspacePanel == nil)
        #expect(model.selectedSessionId == nil)
        #expect(settings.lastProjectId == nil)
    }
}

private final class PersonalChatURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [(path: String, body: Data)] = []

    static var capturedRequests: [(path: String, body: Data)] { lock.withLock { requests } }
    nonisolated(unsafe) private static var holdsGETs = false
    nonisolated(unsafe) private static var heldGETs: [PersonalChatURLProtocol] = []
    static var hasHeldGETs: Bool { lock.withLock { !heldGETs.isEmpty } }
    static func holdGETs() { lock.withLock { holdsGETs = true } }
    static func releaseGETs() {
        let pending = lock.withLock {
            holdsGETs = false
            let pending = heldGETs
            heldGETs = []
            return pending
        }
        for request in pending { request.failGET() }
    }
    static func reset() { lock.withLock { requests = []; holdsGETs = false; heldGETs = [] } }
    private func failGET() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        guard request.httpMethod == "POST" else {
            let held = Self.lock.withLock {
                guard Self.holdsGETs else { return false }
                Self.heldGETs.append(self)
                return true
            }
            if !held { failGET() }
            return
        }
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
        Self.lock.withLock { Self.requests.append((url.path, body)) }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let summary = url.path.hasSuffix("/long-chat")
            ? ChatSessionSummary(id: "project-long", agentId: "personal-agent", title: "Main", kind: "long_chat", projectId: payload?["projectId"] as? String)
            : ChatSessionSummary(id: "personal-session", agentId: "personal-agent", title: "Personal")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = url.path.hasSuffix("/messages")
                ? try encoder.encode(["summary": summary])
                : try encoder.encode(summary)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class PersonalChatNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
