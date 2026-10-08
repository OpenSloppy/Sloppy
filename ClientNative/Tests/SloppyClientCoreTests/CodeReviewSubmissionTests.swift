import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Send Review", .serialized)
struct CodeReviewSubmissionTests {
    @Test func sendsOneMessageToTheResolvedWorkingChatWithAStableRetryID() async throws {
        let capture = ReviewSubmissionCapture()
        ReviewSubmissionURLProtocol.capture = capture
        defer { ReviewSubmissionURLProtocol.capture = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewSubmissionURLProtocol.self]
        let api = SloppyAPIClient(baseURL: URL(string: "https://review-submit.invalid")!,
            session: URLSession(configuration: configuration), authSessionStore: AuthSessionStore(persistence: .memory))
        let item = CodeReviewItem(id: "github:team/repo#42", providerId: "github", providerName: "GitHub",
                                 repository: "team/repo", title: "Review", url: "https://example.invalid/pr/42")
        let submission = CodeReviewSubmission(id: UUID(), content: "One collected review")
        let accepted = try await api.sendCodeReview(item, agentId: "default-agent", submission: submission)
        #expect(accepted.id == "working-chat")
        let requests = capture.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path.hasSuffix("/sessions") == true)
        #expect(requests[1].url?.path == "/v1/agents/working-agent/sessions/working-chat/messages")
        let payload = try #require(capture.payloads.last)
        #expect(payload["content"] as? String == submission.content)
        #expect(payload["clientMessageId"] as? String == submission.id.uuidString)
        capture.failMessages = true
        await #expect(throws: APIError.self) {
            try await api.sendCodeReview(item, agentId: "default-agent", submission: submission)
        }
        capture.failMessages = false
        _ = try await api.sendCodeReview(item, agentId: "default-agent", submission: submission)
        #expect(capture.payloads.last?["clientMessageId"] as? String == submission.id.uuidString)
    }

    @Test func selectionAndPendingSubmissionSurviveReloadWithoutCrossingPRScopes() throws {
        let suite = "review-selection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CodeReviewDraftStore(defaults: defaults)
        let endpoint = SloppyInstanceEndpoint.direct(baseURL: URL(string: "https://review-submit.invalid")!)
        let item = CodeReviewItem(id: "42", providerId: "test", providerName: "Test", repository: "team/repo", title: "Review", url: "https://example.invalid")
        var selection = CodeReviewSelection()
        selection.comments = try JSONDecoder().decode([CodeReviewComment].self, from: Data(#"[{"id":"general","body":"Please verify the behavior"}]"#.utf8))
        selection.pendingContent = "Pending submission"
        store.saveSelection(selection, item: item, endpoint: endpoint)
        #expect(CodeReviewDraftStore(defaults: defaults).loadSelection(item: item, endpoint: endpoint) == selection)
        var other = item
        other.id = "43"
        #expect(store.loadSelection(item: other, endpoint: endpoint).comments.isEmpty)
    }
}

private final class ReviewSubmissionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var storedPayloads: [[String: Any]] = []
    private var storedFailMessages = false
    var requests: [URLRequest] { lock.withLock { storedRequests } }
    var payloads: [[String: Any]] { lock.withLock { storedPayloads } }
    var failMessages: Bool {
        get { lock.withLock { storedFailMessages } }
        set { lock.withLock { storedFailMessages = newValue } }
    }
    func record(_ request: URLRequest) {
        let data: Data?
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            data = body
        } else { data = nil }
        let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        lock.withLock {
            storedRequests.append(request)
            if let payload { storedPayloads.append(payload) }
        }
    }
}

private final class ReviewSubmissionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capture: ReviewSubmissionCapture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capture?.record(request)
        let message = request.url?.path.hasSuffix("/messages") == true
        let summary = #"{"id":"working-chat","agentId":"working-agent","title":"Working task","messageCount":1,"updatedAt":"2026-10-07T12:00:00Z","kind":"chat"}"#
        let status = message && Self.capture?.failMessages == true ? 503 : 200
        let json = status == 503 ? #"{"error":"unavailable"}"# : (message ? "{\"summary\":\(summary)}" : summary)
        if let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
