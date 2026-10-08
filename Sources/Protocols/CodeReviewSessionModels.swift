import Foundation

/// Provider IDs and provider-scoped review IDs are kept separate from display titles.
public struct CodeReviewReference: Codable, Sendable, Hashable {
    public var providerId: String
    public var reviewId: String
    public var repository: String

    public init(providerId: String, reviewId: String, repository: String) {
        self.providerId = providerId
        self.reviewId = reviewId
        self.repository = repository
    }
}

public struct CodeReviewSessionRequest: Codable, Sendable {
    public var repository: String
    public var agentId: String
    /// An existing working session to attach. Omit to reopen or create the PR chat.
    public var sessionId: String?
    public var title: String?

    public init(repository: String, agentId: String, sessionId: String? = nil, title: String? = nil) {
        self.repository = repository
        self.agentId = agentId
        self.sessionId = sessionId
        self.title = title
    }
}
