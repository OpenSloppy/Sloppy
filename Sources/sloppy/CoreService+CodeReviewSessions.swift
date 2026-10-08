import Foundation
import Protocols

extension CoreService {
    private var codeReviewSessionStore: CodeReviewSessionStore {
        CodeReviewSessionStore(url: workspaceRootURL.appendingPathComponent("code-review-sessions.json"))
    }

    func codeReviewSessions(_ review: CodeReviewReference) throws -> [AgentSessionSummary] {
        try validateCodeReviewReference(review)
        let sessions = try listAllAgentSessions(includeWorkers: true)
        return CodeReviewSessionStore.associatedSessions(
            review: review, links: try codeReviewSessionStore.links(), sessions: sessions
        )
    }

    func attachCodeReviewSession(_ review: CodeReviewReference, agentID: String, sessionID: String) throws -> AgentSessionSummary {
        try validateCodeReviewReference(review)
        let summary = try getAgentSession(agentID: agentID, sessionID: sessionID, eventLimit: 1).summary
        try codeReviewSessionStore.link(review, session: summary)
        return summary
    }

    /// A task coalesces concurrent opens across actor reentrancy during session creation.
    func openCodeReviewSession(_ review: CodeReviewReference, request: CodeReviewSessionRequest) async throws -> AgentSessionSummary {
        try validateCodeReviewReference(review)
        if let sessionID = request.sessionId {
            return try attachCodeReviewSession(review, agentID: request.agentId, sessionID: sessionID)
        }
        if let task = codeReviewChatOpenTasks[review] { return try await task.value }
        if let existing = try codeReviewSessions(review).first { return existing }
        let task = Task { try await self.createCodeReviewSession(review, request: request) }
        codeReviewChatOpenTasks[review] = task
        defer { codeReviewChatOpenTasks.removeValue(forKey: review) }
        return try await task.value
    }

    private func createCodeReviewSession(_ review: CodeReviewReference, request: CodeReviewSessionRequest) async throws -> AgentSessionSummary {
        // Recheck after startup/task scheduling in case an agent has just attached its working chat.
        await waitForStartup()
        if let existing = try codeReviewSessions(review).first { return existing }
        let summary = try await createAgentSession(agentID: request.agentId, request: .init(
            title: "PR \(review.reviewId): \(request.title ?? review.repository)", separateChat: true
        ))
        do {
            try codeReviewSessionStore.link(review, session: summary)
        } catch {
            try? sessionStore.deleteSession(agentID: summary.agentId, sessionID: summary.id)
            throw error
        }
        return summary
    }

    private func validateCodeReviewReference(_ review: CodeReviewReference) throws {
        guard codeReviewProviders[review.providerId] != nil,
              !review.reviewId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !review.repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentSessionError.invalidPayload
        }
    }

    func linkCurrentSessionToCodeReview(providerID: String, reviewID: String, agentID: String, sessionID: String) async throws -> AgentSessionSummary {
        let detail = try await codeReviewDetail(providerID: providerID, reviewID: reviewID, maxDiffBytes: 1)
        return try attachCodeReviewSession(.init(
            providerId: detail.item.providerId, reviewId: detail.item.id, repository: detail.item.repository
        ), agentID: agentID, sessionID: sessionID)
    }
}
