import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Personal chat context", .serialized)
@MainActor
struct ChatPersonalContextTests {
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
    static func reset() { lock.withLock { requests = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        guard request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
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
        let summary = ChatSessionSummary(id: "personal-session", agentId: "personal-agent", title: "Personal")
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
