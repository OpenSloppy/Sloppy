import Foundation

extension SloppyAPIClient {
    public func openLongChat(agentId: String, userId: String = "user", projectId: String? = nil) async throws -> ChatSessionSummary {
        try await http.post(
            "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/long-chat",
            body: LongChatOpenRequest(userId: userId, projectId: projectId))
    }

    public func fetchLongChat(agentId: String, sessionId: String) async throws -> LongChatConversation {
        try await http.get(longChatPath(agentId: agentId, sessionId: sessionId))
    }

    public func updateLongChatTask(agentId: String, sessionId: String, taskId: String, action: String) async throws
        -> LongChatConversation
    {
        struct Empty: Encodable {}
        return try await http.post(
            longChatPath(agentId: agentId, sessionId: sessionId)
                + "/tasks/\(BackendHTTPClient.encodePathSegment(taskId))/\(BackendHTTPClient.encodePathSegment(action))",
            body: Empty())
    }

    public func cancelLongChatTasks(agentId: String, sessionId: String) async throws {
        struct Empty: Encodable {}
        struct Response: Decodable { var status: String }
        let _: Response = try await http.post(
            longChatPath(agentId: agentId, sessionId: sessionId) + "/cancel", body: Empty())
    }

    private func longChatPath(agentId: String, sessionId: String) -> String {
        "/v1/agents/\(BackendHTTPClient.encodePathSegment(agentId))/sessions/\(BackendHTTPClient.encodePathSegment(sessionId))/long-chat"
    }
}
