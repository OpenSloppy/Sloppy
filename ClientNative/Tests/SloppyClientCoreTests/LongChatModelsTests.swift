import Foundation
import Testing

@testable import SloppyClientCore

@Suite("Long chat client events")
struct LongChatModelsTests {
    @Test func taskEventsDecodeIntoTranscriptCardsAndKeepExplicitSessionLinks() throws {
        let task = LongChatTask(
            id: "task", key: "t", title: "Report", objective: "Report", projectId: nil, resourceKeys: [], dependsOn: [],
            attempts: [.init(number: 1)])
        var attempt = task.attempts[0]
        attempt.sessionId = "child"
        attempt.status = .running
        var updated = task
        updated.attempts = [attempt]
        let payload = LongChatTaskEvent(assignmentId: "assignment", task: updated, reason: "started")
        let encoded = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let envelope = try JSONSerialization.data(withJSONObject: [
            "id": "event", "type": "long_chat_task", "createdAt": 0, "longChatTask": object,
        ])
        let decoded = try JSONDecoder().decode(ChatEventEnvelope.self, from: envelope)
        #expect(decoded.message?.longChatTask?.task.attempts.last?.sessionId == "child")
        #expect(decoded.message?.id == "long-chat-task-task")
        #expect(decoded.message?.longChatTask?.task.status == .running)
    }
}
