import Foundation

public struct CodeReviewReference: Codable, Sendable, Hashable {
    public var providerId: String
    public var reviewId: String
    public var repository: String

    public init(item: CodeReviewItem) {
        providerId = item.providerId
        reviewId = item.id
        repository = item.repository
    }
}

extension CodeReviewItem {
    public var reviewReference: CodeReviewReference { CodeReviewReference(item: self) }
}

public struct CodeReviewSessionRequest: Codable, Sendable {
    public var repository: String
    public var agentId: String
    public var sessionId: String?
    public var title: String?

    public init(repository: String, agentId: String, sessionId: String? = nil, title: String? = nil) {
        self.repository = repository
        self.agentId = agentId
        self.sessionId = sessionId
        self.title = title
    }
}

extension SloppyAPIClient {
    public func fetchCodeReviewSessions(_ item: CodeReviewItem) async throws -> [ChatSessionSummary] {
        try await http.get("\(reviewSessionsPath(item))?repository=\(BackendHTTPClient.encodeQueryValue(item.repository))")
    }

    public func openCodeReviewSession(_ item: CodeReviewItem, agentId: String, sessionId: String? = nil) async throws -> ChatSessionSummary {
        try await http.post(reviewSessionsPath(item), body: CodeReviewSessionRequest(
            repository: item.repository, agentId: agentId, sessionId: sessionId, title: item.title
        ))
    }

    private func reviewSessionsPath(_ item: CodeReviewItem) -> String {
        "/v1/code-reviews/\(BackendHTTPClient.encodePathSegment(item.providerId))/\(BackendHTTPClient.encodePathSegment(item.id))/sessions"
    }
}

public struct CodeReviewSubmission: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var content: String

    public init(id: UUID, content: String) {
        self.id = id
        self.content = content
    }
}

public struct CodeReviewSelection: Codable, Sendable, Equatable {
    public var requestID = UUID()
    public var comments: [CodeReviewComment] = []
    public var pendingContent: String?

    public init() {}
}

extension SloppyAPIClient {
    /// Resolves the PR chat and waits for server acceptance. Presentation belongs to the caller.
    public func sendCodeReview(_ item: CodeReviewItem, agentId: String, sessionId: String? = nil,
                               submission: CodeReviewSubmission) async throws -> ChatSessionSummary {
        let summary = try await openCodeReviewSession(item, agentId: agentId, sessionId: sessionId)
        return try await postSessionMessageWithReceipt(agentId: summary.agentId, sessionId: summary.id,
            content: submission.content, clientMessageId: submission.id.uuidString).summary
    }
}

public struct CodeReviewFixDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var filePath: String
    public var line: Int
    public var side: CodeReviewDiffSide
    public var content: String
    public var body: String

    public init(id: UUID = UUID(), line: CodeReviewLineContext, body: String = "") {
        self.id = id
        filePath = line.filePath
        self.line = line.line
        side = line.side
        content = line.content
        self.body = body
    }

    public func isAnchored(to row: CodeReviewDiffRow, filePath: String) -> Bool {
        let cell = side == .old ? row.old : row.new
        return self.filePath == filePath && cell.lineNumber == line && cell.text == content
    }
}

public final class CodeReviewDraftStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load(item: CodeReviewItem, endpoint: SloppyInstanceEndpoint) -> [CodeReviewFixDraft] {
        guard let data = defaults.data(forKey: key(item, endpoint)),
              let drafts = try? JSONDecoder().decode([CodeReviewFixDraft].self, from: data) else { return [] }
        return drafts
    }

    public func save(_ drafts: [CodeReviewFixDraft], item: CodeReviewItem, endpoint: SloppyInstanceEndpoint) {
        if drafts.isEmpty { defaults.removeObject(forKey: key(item, endpoint)); return }
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        defaults.set(data, forKey: key(item, endpoint))
    }

    public func loadSelection(item: CodeReviewItem, endpoint: SloppyInstanceEndpoint) -> CodeReviewSelection {
        guard let data = defaults.data(forKey: key(item, endpoint) + ".selection"),
              let selection = try? JSONDecoder().decode(CodeReviewSelection.self, from: data) else { return .init() }
        return selection
    }

    public func saveSelection(_ selection: CodeReviewSelection, item: CodeReviewItem, endpoint: SloppyInstanceEndpoint) {
        if selection.comments.isEmpty && selection.pendingContent == nil {
            defaults.removeObject(forKey: key(item, endpoint) + ".selection")
            return
        }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: key(item, endpoint) + ".selection")
    }

    private func key(_ item: CodeReviewItem, _ endpoint: SloppyInstanceEndpoint) -> String {
        let parts = [endpoint.cacheNamespace, item.providerId, item.repository, item.id]
        let scope = (try? JSONEncoder().encode(parts)) ?? Data()
        return "client_code_review_drafts_v1." + scope.base64EncodedString()
    }
}

extension CodeReviewComment {
    public var diffSide: CodeReviewDiffSide? {
        switch side?.uppercased() {
        case "LEFT", "OLD": .old
        case "RIGHT", "NEW": .new
        default: nil
        }
    }
}

/// Group replies once, preserving missing-parent threads and guarding provider cycles.
public struct CodeReviewCommentThread: Sendable, Equatable, Identifiable {
    public var comments: [CodeReviewComment]
    public var id: String { comments[0].id }
    public var root: CodeReviewComment { comments[0] }

    public static func group(_ comments: [CodeReviewComment]) -> [Self] {
        let known = Set(comments.map(\.id))
        let roots = comments.filter { $0.inReplyToId.map { !known.contains($0) } ?? true }
        var visited = Set<String>()
        var result: [Self] = []
        func appendThread(_ root: CodeReviewComment) {
            var rows: [CodeReviewComment] = []
            func walk(_ comment: CodeReviewComment) {
                guard visited.insert(comment.id).inserted else { return }
                rows.append(comment)
                for reply in comments where reply.inReplyToId == comment.id { walk(reply) }
            }
            walk(root)
            if !rows.isEmpty { result.append(Self(comments: rows)) }
        }
        for root in roots { appendThread(root) }
        for comment in comments where !visited.contains(comment.id) { appendThread(comment) }
        return result
    }

    public var side: CodeReviewDiffSide? { root.diffSide }

    public func isAnchored(to row: CodeReviewDiffRow, filePath: String) -> Bool {
        guard root.isOutdated != true, let path = root.filePath, let line = root.line,
              path == filePath else { return false }
        switch side {
        case .old: return row.old.lineNumber == line
        case .new: return row.new.lineNumber == line
        case nil: return row.new.lineNumber == line || row.old.lineNumber == line
        }
    }
}

extension CodeReviewChatPromptBuilder {
    public static func prompt(for drafts: [CodeReviewFixDraft], in detail: CodeReviewDetail) -> String {
        var lines = [
            "Address the following requested fixes in this pull request.", "",
            "PR ID: \(detail.item.id)", "Provider ID: \(detail.item.providerId)",
            "Repository: \(detail.item.repository)", "URL: \(detail.item.url)", "",
        ]
        for draft in drafts where !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(contentsOf: [
                "Location: \(draft.filePath):\(draft.line) (\(draft.side.rawValue))",
                "Code: \(draft.content)", "Requested fix: \(draft.body)", "",
            ])
        }
        lines.append("Inspect the current checkout, verify these comments still apply, implement the fixes, and run focused tests. Do not publish or merge unless I ask.")
        return lines.joined(separator: "\n")
    }
}

extension CodeReviewChatPromptBuilder {
    public static func promptForReview(fixes: [CodeReviewFixDraft], comments: [CodeReviewComment], in detail: CodeReviewDetail) -> String {
        var lines = [prompt(for: fixes, in: detail)]
        if !comments.isEmpty {
            lines.append("\nSelected review comments:")
            for comment in comments {
                let location = comment.filePath.map { path in
                    (comment.line ?? comment.originalLine).map { "\(path):\($0)" } ?? path
                } ?? "General"
                lines.append(contentsOf: [
                    "Comment ID: \(comment.id)",
                    "Location: \(location)",
                    "Side: \(comment.side ?? "unspecified")",
                    "Author: \(comment.author ?? "Reviewer")",
                    "Comment: \(comment.body)", "",
                ])
            }
        }
        return lines.joined(separator: "\n")
    }
}
