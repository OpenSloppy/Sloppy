import Foundation
import PluginSDK
import Protocols
import Testing
@testable import sloppy

@Suite("PR chat association")
struct CodeReviewSessionTests {
    private let review = CodeReviewReference(providerId: "github", reviewId: "github:team/repo#42", repository: "team/repo")

    @Test func linksPersistAndKeepMultipleChatsWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-links-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("links.json")
        let store = CodeReviewSessionStore(url: url)
        let first = AgentSessionSummary(id: "first", agentId: "agent", title: "Work")
        let second = AgentSessionSummary(id: "second", agentId: "other", title: "Review")
        try store.link(review, session: first)
        try store.link(review, session: first)
        try store.link(review, session: second)
        let restored = try CodeReviewSessionStore(url: url).links()
        #expect(restored.count == 2)
        #expect(CodeReviewSessionStore.associatedSessions(review: review, links: restored, sessions: [second, first]).map(\.id) == ["first", "second"])
        let other = CodeReviewReference(providerId: "gitlab", reviewId: review.reviewId, repository: review.repository)
        #expect(CodeReviewSessionStore.associatedSessions(review: other, links: restored, sessions: [first, second]).isEmpty)
    }

    @Test func workingTaskChatsAndDescendantsAreLinkedButOtherProjectsAndDeletedSessionsAreNot() {
        let working = AgentSessionSummary(id: "working", agentId: "agent", title: "Task", projectId: "project", taskId: "task")
        let sameTask = AgentSessionSummary(id: "task-chat", agentId: "other", title: "Task chat", projectId: "project", taskId: "task")
        let child = AgentSessionSummary(id: "child", agentId: "worker", title: "Work", parentSessionId: working.id)
        let grandchild = AgentSessionSummary(id: "grandchild", agentId: "worker", title: "Work", parentSessionId: child.id)
        let otherProject = AgentSessionSummary(id: "unrelated", agentId: "agent", title: "Task", projectId: "other", taskId: "task")
        let link = CodeReviewSessionStore.Link(review: review, agentId: working.agentId, sessionId: working.id)
        let sessions = [grandchild, sameTask, child, otherProject, working]
        let found = CodeReviewSessionStore.associatedSessions(review: review, links: [link], sessions: sessions)
        #expect(Set(found.map(\.id)) == ["working", "task-chat", "child", "grandchild"])
        #expect(CodeReviewSessionStore.associatedSessions(review: review, links: [link], sessions: [child]).isEmpty)
    }

    @Test func simultaneousOpensCreateOneChatAndDeletedPrimaryIsRecreated() async throws {
        let service = CoreService(config: .test)
        let root = await service.workspaceRootURL
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.createAgent(.init(id: "review-agent", displayName: "Review Agent", role: "Test"))
        let request = CodeReviewSessionRequest(repository: review.repository, agentId: "review-agent", title: "Fix")
        async let first = service.openCodeReviewSession(review, request: request)
        async let second = service.openCodeReviewSession(review, request: request)
        let pair = try await (first, second)
        #expect(pair.0.id == pair.1.id)
        #expect(pair.0.title.contains(review.reviewId))
        #expect(try await service.codeReviewSessions(review).count == 1)
        try await service.deleteAgentSession(agentID: pair.0.agentId, sessionID: pair.0.id)
        let replacement = try await service.openCodeReviewSession(review, request: request)
        #expect(replacement.id != pair.0.id)
        #expect(try await service.codeReviewSessions(review).map(\.id) == [replacement.id])
        await service.shutdownChannelPlugins()
    }

    @Test func agentToolLinksItsActualSessionAndDoesNotCreateAnotherChat() async throws {
        let service = CoreService(config: .test)
        let root = await service.workspaceRootURL
        defer { try? FileManager.default.removeItem(at: root) }
        await service.registerCodeReviewProvider(LinkTestProvider())
        _ = try await service.createAgent(.init(id: "worker", displayName: "Worker", role: "Test"))
        let session = try await service.createAgentSession(agentID: "worker", request: .init(title: "Existing working chat"))
        let result = await service.invokeToolFromRuntime(agentID: session.agentId, sessionID: session.id,
            request: .init(tool: "code_review.link_session", arguments: ["providerId": .string("test-review"), "reviewId": .string("42")]), recordSessionEvents: false)
        #expect(result.ok, "\(result.error?.message ?? "")")
        let ref = CodeReviewReference(providerId: "test-review", reviewId: "42", repository: "team/repo")
        let opened = try await service.openCodeReviewSession(ref, request: .init(repository: ref.repository, agentId: "worker"))
        #expect(opened.id == session.id)
        await service.shutdownChannelPlugins()
    }
}

private struct LinkTestProvider: CodeReviewProvider {
    let id = "test-review"
    func listCodeReviews(query: CodeReviewQuery) async throws -> [CodeReviewItem] { [] }
    func codeReviewDetail(id: String, maxDiffBytes: Int, credential: String?) async throws -> CodeReviewDetail {
        CodeReviewDetail(item: .init(id: id, providerId: self.id, providerName: "Test", repository: "team/repo", title: "Fix", url: "https://example.test/pr/42"))
    }
}
