#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import SloppyClientCore
import SloppyClientUI
import SloppyUITestSupport
@testable import SloppyClient

@Suite("Inline PR review interaction", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct CodeReviewInlineInteractionTests {
    @Test(arguments: CodeReviewDiffLayout.allCases)
    func collectsReviewWithoutOpeningChatAndRetriesOnlyAfterExplicitSend(layout: CodeReviewDiffLayout) async throws {
        let preferenceKey = "client_code_review_diff_layout"
        let previousLayout = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set(layout.rawValue, forKey: preferenceKey)
        defer {
            if let previousLayout { UserDefaults.standard.set(previousLayout, forKey: preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: preferenceKey) }
        }
        AppKitTestAccessibility.enable()
        let item = CodeReviewItem(id: "github:team/repo#42", providerId: "github", providerName: "GitHub",
                                  repository: "team/repo", number: 42, title: "Make cancellation reliable",
                                  url: "https://github.com/team/repo/pull/42")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewWorkspaceURLProtocol.self]
        let api = SloppyAPIClient(baseURL: URL(string: "https://pr-ui-\(UUID()).test")!,
            session: URLSession(configuration: configuration), authSessionStore: AuthSessionStore(persistence: .memory))
        let drafts = [CodeReviewFixDraft(line: .init(filePath: "Sources/Worker.swift", line: 3, side: .new,
            content: "    let work = Task { await run() }"), body: "Cancel this task when the parent is cancelled.")]
        let store = CodeReviewDraftStore()
        store.save(drafts, item: item, endpoint: api.endpoint)
        defer {
            store.save([], item: item, endpoint: api.endpoint)
            store.saveSelection(.init(), item: item, endpoint: api.endpoint)
        }
        var linked = 0
        var presentedChats = 0
        var attempts: [CodeReviewSubmission] = []
        var failSubmission = true
        let host = NSHostingView(rootView: PullRequestDetailView(
            apiClient: api, item: item, showsBackButton: false, onBack: {},
            onLinkChat: { _, _ in linked += 1 },
            onSendReview: { detail, submission in
                #expect(detail.item.id == item.id)
                attempts.append(submission)
                if failSubmission { throw APIError.httpError(statusCode: 503, body: nil) }
                presentedChats += 1
            }
        ).environment(\.theme, .sloppyDark).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1380, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        var nativeEditor: NSTextView?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            nativeEditor = descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == drafts[0].body }
            if nativeEditor != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(linked == 0 && presentedChats == 0 && attempts.isEmpty)
        let editor = try #require(nativeEditor)
        let revisedBody = "Cancel this task when the parent is cancelled, and add a regression test."
        editor.string = revisedBody
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(100))
        let navigationMode = try #require(descendants(host).compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 2 && $0.label(forSegment: 0) == "Summary"
        })
        navigationMode.selectedSegment = 0
        #expect(navigationMode.sendAction(navigationMode.action, to: navigationMode.target))
        try await Task.sleep(for: .milliseconds(100))
        var includeButton: NSObject?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            includeButton = AppKitTestAccessibility.element(in: host, identifier: "code-review-select-comment-comment-1")
            if includeButton != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        if includeButton == nil {
            let screenshot = Process()
            screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screenshot.arguments = ["-x", "-l", String(window.windowNumber), "/private/tmp/sloppy-send-review-diagnostic.png"]
            try screenshot.run()
            screenshot.waitUntilExit()
        }
        let include = try #require(includeButton)
        #expect(AppKitTestAccessibility.press(include))
        try await Task.sleep(for: .milliseconds(100))
        #expect(linked == 0 && presentedChats == 0 && attempts.isEmpty)
        #expect(store.loadSelection(item: item, endpoint: api.endpoint).comments.map(\.id) == ["comment-1"])
        navigationMode.selectedSegment = 1
        #expect(navigationMode.sendAction(navigationMode.action, to: navigationMode.target))
        try await Task.sleep(for: .milliseconds(100))
        let otherLayout: CodeReviewDiffLayout = layout == .sideBySide ? .oneSide : .sideBySide
        for selected in [otherLayout, layout] {
            let picker = try #require(descendants(host).compactMap { $0 as? NSSegmentedControl }.first {
                $0.segmentCount == 2 && $0.label(forSegment: 1) == "One side"
            })
            picker.selectedSegment = selected == .sideBySide ? 0 : 1
            #expect(picker.sendAction(picker.action, to: picker.target))
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            #expect(UserDefaults.standard.string(forKey: preferenceKey) == selected.rawValue)
            #expect(AppKitTestAccessibility.element(in: host, identifier: "code-review-fix-\(drafts[0].id)") != nil)
            #expect(AppKitTestAccessibility.element(in: host, identifier: "code-review-select-comment-comment-1") == nil)
        }
        #expect(linked == 0 && presentedChats == 0 && attempts.isEmpty)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/private/tmp/sloppy-send-review-\(layout.rawValue).png"]
        try capture.run()
        capture.waitUntilExit()
        let button = try #require(AppKitTestAccessibility.element(in: host, identifier: "code-review-send-review"))
        #expect(AppKitTestAccessibility.press(button))
        for _ in 0..<100 {
            if attempts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts.count == 1 && presentedChats == 0)
        #expect(attempts[0].content.contains("PR ID: \(item.id)"))
        #expect(attempts[0].content.contains(revisedBody))
        #expect(attempts[0].content.contains("Comment ID: comment-1"))
        #expect(store.load(item: item, endpoint: api.endpoint).first?.body == revisedBody)
        failSubmission = false
        #expect(AppKitTestAccessibility.press(button))
        for _ in 0..<100 {
            if attempts.count == 2 && store.load(item: item, endpoint: api.endpoint).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(attempts.count == 2 && presentedChats == 1 && linked == 0)
        #expect(attempts[0] == attempts[1])
        #expect(store.load(item: item, endpoint: api.endpoint).isEmpty)
        #expect(store.loadSelection(item: item, endpoint: api.endpoint).comments.isEmpty)
    }

}

private final class ReviewWorkspaceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json: String
        if request.url?.path.hasSuffix("/sessions") == true {
            json = #"[{"id":"pr-chat","agentId":"worker","title":"PR #42","messageCount":0,"updatedAt":"2026-10-07T11:00:00Z","kind":"chat"}]"#
        } else {
            json = #"{"item":{"id":"github:team/repo#42","providerId":"github","providerName":"GitHub","repository":"team/repo","number":42,"title":"Make cancellation reliable","url":"https://github.com/team/repo/pull/42","state":"open","isDraft":false,"roles":[],"labels":[]},"sourceBranch":"codex/cancellation","targetBranch":"main","reviewers":["Reviewer"],"comments":[{"id":"comment-1","author":"Reviewer","body":"The operation should stop when its parent stops.","filePath":"Sources/Worker.swift","line":3,"side":"RIGHT"}],"diff":"diff --git a/Sources/Worker.swift b/Sources/Worker.swift\n--- a/Sources/Worker.swift\n+++ b/Sources/Worker.swift\n@@ -1,5 +1,5 @@\n func start() async {\n     guard !Task.isCancelled else { return }\n-    await run()\n+    let work = Task { await run() }\n     await save()\n }\n","diffTruncated":false}"#
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
