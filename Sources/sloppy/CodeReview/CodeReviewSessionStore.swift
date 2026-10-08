import Foundation
import Protocols

/// Accessed only from CoreService's actor; writes replace the complete file atomically.
struct CodeReviewSessionStore {
    struct Link: Codable, Equatable {
        var review: CodeReviewReference
        var agentId: String
        var sessionId: String
    }

    let url: URL

    func links() throws -> [Link] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Link].self, from: Data(contentsOf: url))
    }

    func link(_ review: CodeReviewReference, session: AgentSessionSummary) throws {
        var records = try links()
        let link = Link(review: review, agentId: session.agentId, sessionId: session.id)
        guard !records.contains(link) else { return }
        records.append(link)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    /// Working task chats and their children share the PR of the explicit working session.
    static func associatedSessions(
        review: CodeReviewReference, links: [Link], sessions: [AgentSessionSummary]
    ) -> [AgentSessionSummary] {
        let direct = links.filter { $0.review == review }.compactMap { link in
            sessions.first { $0.id == link.sessionId && $0.agentId == link.agentId }
        }
        var result = direct
        var ids = Set(direct.map(\.id))
        for session in sessions where !ids.contains(session.id) {
            if let taskID = session.taskId, let projectID = session.projectId,
               direct.contains(where: { $0.taskId == taskID && $0.projectId == projectID }) {
                result.append(session)
                ids.insert(session.id)
            }
        }
        var grew = true
        while grew {
            grew = false
            for session in sessions where !ids.contains(session.id) {
                if let parentID = session.parentSessionId, ids.contains(parentID) {
                    result.append(session)
                    ids.insert(session.id)
                    grew = true
                }
            }
        }
        return result
    }
}
