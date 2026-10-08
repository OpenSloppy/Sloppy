import Foundation
import SloppyClientCore
import Testing
@testable import SloppyFeatureChat

@Suite("Tool approval notifications")
struct ToolApprovalNotificationTests {
    @Test("worker approval links to the parent chat and retains its expiry")
    func parentChatLink() throws {
        let expiry = Date().addingTimeInterval(600)
        let record = PendingToolApprovalRecord(id: "approval", status: "pending", agentId: "agent/one",
            sessionId: "worker", displaySessionId: "parent chat", tool: "runtime.exec",
            updatedAt: Date(), expiresAt: expiry)
        let notification = try #require(AgentToolApprovalNotification(approval: record))
        let components = try #require(URLComponents(string: notification.deepLink))
        #expect(components.queryItems?.first { $0.name == "id" }?.value == "parent chat")
        #expect(components.queryItems?.first { $0.name == "agent" }?.value == "agent/one")
        #expect(notification.expiresAt == expiry)
        #expect(notification.identifier == "tool-approval.approval")
    }

    @Test("resolved approvals cannot create a new actionable notification", arguments: ["approved", "rejected", "timed_out"])
    func resolvedApproval(status: String) {
        let record = PendingToolApprovalRecord(id: "approval", status: status, agentId: "agent",
            sessionId: "chat", updatedAt: Date())
        #expect(AgentToolApprovalNotification(approval: record) == nil)
    }
}
