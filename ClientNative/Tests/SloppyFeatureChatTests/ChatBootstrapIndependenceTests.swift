import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Chat bootstrap independence", .serialized)
@MainActor
struct ChatBootstrapIndependenceTests {
    @Test func chatsAndSubmissionBecomeAvailableWhileModelDiscoveryIsStillPending() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BootstrapURLProtocol.self]
        let api = SloppyAPIClient(baseURL: URL(string: "http://bootstrap.invalid")!,
                                  session: URLSession(configuration: configuration),
                                  authSessionStore: AuthSessionStore(persistence: .memory))
        let settings = ClientSettings()
        let previousAgent = settings.lastAgentId, previousSession = settings.lastSessionId
        let previousProject = settings.lastProjectId
        settings.lastProjectId = nil
        settings.lastSessionId = nil
        defer {
            settings.lastAgentId = previousAgent
            settings.lastSessionId = previousSession
            settings.lastProjectId = previousProject
        }
        let model = ChatScreenViewModel(apiClient: api, cacheStore: ClientCacheStore(path: ":memory:"),
                                        settings: settings, connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
                                        loadsGlobalSessionCatalog: true,
                                        responseNotificationScheduler: BootstrapNotifications(), onOpenSettings: { _ in })
        defer { model.closeSession() }
        model.loadInitialData()
        let deadline = ContinuousClock.now + .seconds(1)
        while (model.sessionCatalog.isEmpty || model.projects.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.canSubmitMessage)
        #expect(model.sessionCatalog.map(\.id) == ["existing-chat"])
        #expect(model.availableModels.isEmpty)
        #expect(model.projects.map(\.id) == ["workspace"])
        #expect(!model.sendMessage(content: ""))
        await model.waitForInitialData()
    }
}

@MainActor
private final class BootstrapNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}

private final class BootstrapURLProtocol: URLProtocol, @unchecked Sendable {
    private var responseWork: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        switch url.path {
        case "/v1/agents":
            data = (try? encoder.encode([APIAgentRecord(id: "first", displayName: "First")])) ?? Data()
        case "/v1/projects":
            data = (try? encoder.encode([APIProjectRecord(id: "workspace", name: "Workspace", kind: .workspace)])) ?? Data()
        case "/v1/agents/first/sessions":
            data = (try? encoder.encode([ChatSessionSummary(id: "existing-chat", agentId: "first", title: "Existing chat")])) ?? Data()
        default:
            data = Data("[]".utf8)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                          headerFields: ["Content-Type": "application/json"]) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        responseWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (url.path == "/v1/providers/models" ? 2 : 0), execute: work)
    }
    override func stopLoading() { responseWork?.cancel() }
}
