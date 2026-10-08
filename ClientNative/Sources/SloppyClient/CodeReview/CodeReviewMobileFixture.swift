#if DEBUG && os(iOS)
import Foundation
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyFeatureChat
import SwiftUI

/// Isolated QA entry point; no live account, chat or model is used.
@MainActor
struct CodeReviewMobileFixture: View {
    private let item = CodeReviewItem(id: "github:team/repo#42", providerId: "github", providerName: "GitHub",
        repository: "team/repo", number: 42, title: "Keep cancellation and review feedback scoped to the working task",
        url: "https://example.invalid/pr/42")
    private let api: SloppyAPIClient
    @State private var submitted: CodeReviewSubmission?
    @State private var selectedTab = 2
    @State private var chat: ChatScreenViewModel
    @State private var attention = AttentionInbox(fetchAgents: { [] }, fetchInbox: { _ in .init(findings: []) },
        updateFinding: { _, _, _ in throw APIError.invalidResponse })

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeReviewFixtureURLProtocol.self]
        api = SloppyAPIClient(baseURL: URL(string: "https://mobile-review-ui.invalid")!,
            session: URLSession(configuration: configuration), authSessionStore: AuthSessionStore(persistence: .memory))
        _chat = State(initialValue: ChatScreenViewModel(apiClient: api, cacheStore: ClientCacheStore(path: ":memory:"),
            settings: ClientSettings(), connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false, onOpenSettings: { _ in }))
        if ProcessInfo.processInfo.arguments.contains("--composer-ui-fixture") { _selectedTab = State(initialValue: 0) }
    }

    private var review: some View {
        NavigationStack {
            PullRequestsScreen(apiClient: api, onLinkChat: { _, _ in },
                onSendReview: { detail, submission in
                    _ = try await api.sendCodeReview(detail.item, agentId: "qa", submission: submission)
                    submitted = submission
                })

        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Inbox", systemImage: "tray", value: 0) {
                NavigationStack {
                    ScrollView { Text("All").font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                        .mobileScreenBackground()
                        .navigationTitle("Inbox")
                }
                .modifier(IOSComposerContainer(composer: {
                    AnyView(ChatComposerOverlay(viewModel: chat, contentWidth: ChatComposerView.panelWidth,
                        composerBottomInset: 8, tabs: [], tabActions: nil))
                }, viewModel: chat))
            }
            Tab("Attention", systemImage: "bell.badge", value: 1) {
                NavigationStack { AttentionScreen(inbox: attention) }
            }
            Tab("Pull Requests", systemImage: "arrow.triangle.branch", value: 2) { review }
            Tab("Usage", systemImage: "chart.bar", value: 3) { Color.clear }
            Tab("Workspace", systemImage: "square.grid.2x2", value: 4) { Color.clear }
        }
        .sheet(item: $submitted) { submission in
            NavigationStack {
                ScrollView { Text(submission.content).textSelection(.enabled).padding(16) }
                    .navigationTitle("PR #42")
            }
        }
        .environment(\.theme, .sloppyDark)
        .preferredColorScheme(.dark)
    }

}

private final class CodeReviewFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let summary = #"{"id":"review-chat","agentId":"qa","title":"PR #42","messageCount":1,"updatedAt":"2026-10-07T12:00:00Z","kind":"chat"}"#
        var json: String
        if request.url?.path.hasSuffix("/messages") == true {
            json = "{\"summary\":\(summary),\"appendedEvents\":[]}"
        } else if request.url?.path.hasSuffix("/sessions") == true {
            json = request.httpMethod == "POST" ? summary : "[]"
        } else {
            json = #"{"item":{"id":"github:team/repo#42","providerId":"github","providerName":"GitHub","repository":"team/repo","number":42,"title":"Keep cancellation and review feedback scoped to the working task","url":"https://example.invalid/pr/42","state":"open","isDraft":false,"roles":[],"labels":[]},"sourceBranch":"codex/cancellation","targetBranch":"main","reviewers":["Reviewer"],"comments":[{"id":"comment-1","author":"Reviewer","body":"The operation should stop when its parent stops.","filePath":"Sources/Worker.swift","line":3,"side":"RIGHT"}],"diff":"diff --git a/Sources/Worker.swift b/Sources/Worker.swift\n--- a/Sources/Worker.swift\n+++ b/Sources/Worker.swift\n@@ -1,5 +1,5 @@\n func start() async {\n     guard !Task.isCancelled else { return }\n-    await run()\n+    let work = Task { await runLongOperationAndSaveItsResult() }\n     await save()\n }","diffTruncated":false}"#
        }
        if request.url?.path == "/v1/code-reviews", let data = json.data(using: .utf8),
           let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let item = detail["item"],
           let inbox = try? JSONSerialization.data(withJSONObject: ["items": [item], "providers": [["id": "github", "displayName": "GitHub", "capabilities": ["list_pull_requests"]]], "failures": [:]]) {
            json = String(decoding: inbox, as: UTF8.self)
        }
        if let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
#endif
