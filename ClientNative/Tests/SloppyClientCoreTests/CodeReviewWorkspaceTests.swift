import Foundation
import Testing
@testable import SloppyClientCore

@Suite("PR review workspace")
struct CodeReviewWorkspaceTests {
    private func item(id: String = "42", provider: String = "gitlab", repository: String = "team/repo") -> CodeReviewItem {
        CodeReviewItem(id: id, providerId: provider, providerName: provider, repository: repository,
                       number: 42, title: "Fix", url: "https://example.test/pr/42")
    }

    @Test func draftsSurviveReloadAndAreIsolatedByServerProviderRepositoryAndPR() throws {
        let suite = "pr-drafts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = SloppyInstanceEndpoint.direct(baseURL: URL(string: "https://one.test")!)
        let other = SloppyInstanceEndpoint.direct(baseURL: URL(string: "https://two.test")!)
        let draft = CodeReviewFixDraft(line: .init(filePath: "File.swift", line: 12, side: .old, content: "old"), body: "Fix the guard")
        CodeReviewDraftStore(defaults: defaults).save([draft], item: item(), endpoint: endpoint)
        let reloaded = CodeReviewDraftStore(defaults: defaults)
        #expect(reloaded.load(item: item(), endpoint: endpoint) == [draft])
        #expect(reloaded.load(item: item(id: "43"), endpoint: endpoint).isEmpty)
        #expect(reloaded.load(item: item(provider: "github"), endpoint: endpoint).isEmpty)
        #expect(reloaded.load(item: item(repository: "other/repo"), endpoint: endpoint).isEmpty)
        #expect(reloaded.load(item: item(), endpoint: other).isEmpty)
        reloaded.save([], item: item(), endpoint: endpoint)
        #expect(reloaded.load(item: item(), endpoint: endpoint).isEmpty)
    }

    @Test func threadAnchorsRespectDiffSideAndDoNotPlaceOutdatedCommentsOnNewCode() throws {
        let comments = try JSONDecoder().decode([CodeReviewComment].self, from: Data(#"[{"id":"left","body":"Old guard","filePath":"File.swift","line":12,"side":"LEFT"},{"id":"reply","body":"Agree","inReplyToId":"left"},{"id":"outdated","body":"Stale","filePath":"File.swift","line":12,"isOutdated":true}]"#.utf8))
        let threads = CodeReviewCommentThread.group(comments)
        #expect(threads.map(\.comments.count) == [2, 1])
        let row = CodeReviewDiffRow(id: 0, old: .init(lineNumber: 12, text: "old", kind: .deletion), new: .init(lineNumber: 13, text: "new", kind: .insertion))
        #expect(threads[0].isAnchored(to: row, filePath: "File.swift"))
        #expect(!threads[0].isAnchored(to: row, filePath: "Other.swift"))
        #expect(!threads[1].isAnchored(to: row, filePath: "File.swift"))
    }

    @Test func malformedCyclesAndMissingParentsKeepEveryCommentOnce() throws {
        let comments = try JSONDecoder().decode([CodeReviewComment].self, from: Data(#"[{"id":"a","body":"a","inReplyToId":"b"},{"id":"b","body":"b","inReplyToId":"a"},{"id":"orphan","body":"orphan","inReplyToId":"missing"}]"#.utf8))
        let ids = CodeReviewCommentThread.group(comments).flatMap { $0.comments.map(\.id) }
        #expect(ids.count == 3)
        #expect(Set(ids) == Set(comments.map(\.id)))
    }

    @Test func changedCodeDoesNotMoveADraftOntoAnotherChangeAtTheSameLine() {
        let draft = CodeReviewFixDraft(line: .init(filePath: "File.swift", line: 12, side: .new, content: "old request"))
        let row = CodeReviewDiffRow(id: 0, old: .init(lineNumber: nil, text: "", kind: .empty),
                                   new: .init(lineNumber: 12, text: "new request", kind: .insertion))
        #expect(!draft.isAnchored(to: row, filePath: "File.swift"))
    }

    @Test func sameNumericIDDoesNotCollideAcrossProvidersOrRepositories() {
        #expect(item().reviewReference != item(provider: "github").reviewReference)
        #expect(item().reviewReference != item(repository: "other/repo").reviewReference)
        var renamed = item()
        renamed.title = "New title"
        #expect(renamed.reviewReference == item().reviewReference)
    }

    @Test func collectedFixesCarryExactIdentityAndLineContextAndSkipEmptyEditors() throws {
        let detail = try JSONDecoder().decode(CodeReviewDetail.self, from: Data(#"{"item":{"id":"42","providerId":"gitlab","providerName":"GitLab","repository":"team/repo","number":42,"title":"Fix","url":"https://example.test/pr/42","state":"open","isDraft":false,"roles":[],"labels":[]},"reviewers":[],"comments":[],"diff":"","diffTruncated":false}"#.utf8))
        let line = CodeReviewLineContext(filePath: "File.swift", line: 12, side: .new, content: "let guardValue = true")
        let prompt = CodeReviewChatPromptBuilder.prompt(for: [.init(line: line, body: "Use cancellation"), .init(line: line, body: "  ")], in: detail)
        #expect(prompt.contains("PR ID: 42"))
        #expect(prompt.contains("Provider ID: gitlab"))
        #expect(prompt.contains("File.swift:12 (new)"))
        #expect(prompt.contains("Requested fix: Use cancellation"))
        #expect(prompt.components(separatedBy: "Location:").count == 2)
        #expect(prompt.contains("verify these comments still apply"))
    }
}
