import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Pull Requests inbox")
struct CodeReviewSourceTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("decodes provider-neutral review response")
    func decodesResponse() throws {
        let data = Data(
            """
            {
              "items": [{
                "id": "github:TeamSloppy/Sloppy#42",
                "providerId": "github",
                "providerName": "GitHub",
                "repository": "TeamSloppy/Sloppy",
                "number": 42,
                "title": "Add pull request inbox",
                "url": "https://github.com/TeamSloppy/Sloppy/pull/42",
                "author": "vlad",
                "state": "open",
                "isDraft": false,
                "roles": ["authored", "review_requested"],
                "sourceBranch": "feature/pull-request-inbox",
                "targetBranch": "main",
                "labels": []
              }],
              "providers": [{
                "id": "github",
                "displayName": "GitHub",
                "capabilities": ["list_pull_requests"]
              }],
              "failures": {}
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodeReviewInboxResponse.self, from: data)
        #expect(response.items.first?.roles == [.authored, .reviewRequested])
        #expect(response.items.first?.sourceBranch == "feature/pull-request-inbox")
        #expect(response.items.first?.targetBranch == "main")
        #expect(response.providers.first?.displayName == "GitHub")
    }

    @Test("decodes comments and a bounded diff for a pull request")
    func decodesDetail() throws {
        let data = Data(
            """
            {
              "item": {
                "id": "arcadia-code-review:15674740",
                "providerId": "arcadia-code-review",
                "providerName": "Arcadia",
                "repository": "arcadia",
                "number": 15674740,
                "title": "Read comments and diff",
                "url": "https://a.yandex-team.ru/review/15674740",
                "state": "open",
                "isDraft": false,
                "roles": ["authored"],
                "labels": []
              },
              "description": "A detailed review",
              "sourceBranch": "users/vlad-prusakov/feature",
              "targetBranch": "trunk",
              "reviewers": ["reviewer"],
              "comments": [{
                "id": "-10",
                "author": "reviewer",
                "body": "Please add a test",
                "filePath": "Sources/File.swift",
                "line": 10,
                "side": "right",
                "diffHunk": "@@ -9,2 +9,2 @@\\n-old\\n+new",
                "isResolved": false,
                "status": "open"
              }],
              "diff": "+new",
              "diffTruncated": false
            }
            """.utf8
        )

        let detail = try JSONDecoder().decode(CodeReviewDetail.self, from: data)
        #expect(detail.comments.first?.filePath == "Sources/File.swift")
        #expect(detail.comments.first?.diffHunk?.contains("+new") == true)
        #expect(detail.description == "A detailed review")
        #expect(detail.diff == "+new")
    }

    @Test("API errors expose HTTP status and server details")
    func apiErrorsExposeDetails() {
        let error = APIError.httpError(statusCode: 404, body: #"{"error":"route_not_found"}"#)

        #expect(error.localizedDescription.contains("HTTP 404"))
        #expect(error.localizedDescription.contains("route_not_found"))
    }

    @Test("client and platform navigation expose Pull Requests")
    func navigationWiring() throws {
        let api = try source("Sources/SloppyClientCore/SloppyAPIClient.swift")
        let screen = try source("Sources/SloppyClient/CodeReview/PullRequestsScreen.swift")
        let detail = try source("Sources/SloppyClient/CodeReview/PullRequestDetailView.swift")
        let diff = try source("Sources/SloppyClient/CodeReview/CodeReviewDiffView.swift")
        let model = try source("Sources/SloppyClient/Navigation/Main/MainViewModel.swift")
        let macSidebar = try source("Sources/SloppyClient/Navigation/Platforms/macOS/MacMainSidebar.swift")
        let iosSidebar = try source("Sources/SloppyClient/Navigation/Platforms/iOS/IOSMainSidebar.swift")

        #expect(api.contains("/v1/code-reviews?"))
        #expect(api.contains("fetchCodeReviewDetail"))
        #expect(screen.contains("PullRequestsScreen"))
        #expect(screen.contains("HSplitView"))
        #expect(screen.contains("PullRequestDetailView"))
        #expect(screen.contains("response.failures"))
        #expect(screen.contains("CodeReviewFilterStore"))
        #expect(screen.contains("_filters = State(initialValue: filterStore.load(endpoint: apiClient.endpoint))"))
        #expect(screen.contains(".onChange(of: filters)"))
        #expect(screen.contains("filterStore.save(filters, endpoint: apiClient.endpoint)"))
        #expect(screen.contains("@State private var searchText = \"\""))
        #expect(screen.contains("maxHeight: .infinity, alignment: .topLeading"))
        #expect(screen.contains("Button(\"Try Again\")"))
        #expect(detail.contains("case code = \"Code\""))
        #expect(diff.contains("CodeReviewSideBySideDiffView"))
        #expect(diff.contains("Add diff line to chat"))
        #expect(diff.contains("Task.detached(priority: .userInitiated)"))
        #expect(diff.contains("CodeReviewDiffSkeletonView"))
        #expect(diff.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        #expect(!diff.contains("private var files: [CodeReviewDiffFile]"))
        #expect(model.contains("func addToSideChat(_ text: String)"))
        #expect(model.contains("func startInSideChat(_ text: String)"))
        #expect(model.contains("sideChatViewModel()?.addTextSelectionToComposer(text)"))
        #expect(model.contains("chat.sendMessage(content: text)"))
        #expect(model.contains("case pullRequests"))
        #expect(macSidebar.contains("title: \"Pull Requests\""))
        #expect(iosSidebar.contains("Tab(\"Pull Requests\""))
    }
}
