import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Attention inbox")
@MainActor
struct AttentionInboxTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func finding(_ id: String, agent: String = "agent", createdAt: Date? = nil) -> ProactiveFinding {
        ProactiveFinding(id: id, agentId: agent, source: .init(id: id, kind: .task, title: id),
                         revision: "1", outcome: .needsInput, reason: "Decision needed", evidence: "New report",
                         nextStep: "Review report", sessionId: "session", createdAt: createdAt ?? now)
    }

    @Test func badgeCountsOnlyUnreadActionableFindings() async {
        let pending = finding("pending")
        var read = finding("read"); read.readAt = now
        var dismissed = finding("dismissed"); dismissed.dismissedAt = now
        var resolved = finding("resolved"); resolved.resolvedAt = now
        var snoozed = finding("snoozed"); snoozed.snoozedUntil = now.addingTimeInterval(60)
        var expired = finding("expired"); expired.snoozedUntil = now
        var quiet = finding("quiet"); quiet.outcome = .quiet
        let findings = [pending, read, dismissed, resolved, snoozed, expired, quiet]
        let inbox = AttentionInbox(fetchAgents: { [.init(id: "agent", displayName: "Agent")] },
                                   fetchInbox: { _ in .init(findings: findings) },
                                   updateFinding: { _, _, _ in pending })
        await inbox.refresh()
        #expect(inbox.unreadCount(at: now) == 2)
        #expect(inbox.unreadCount(at: now.addingTimeInterval(61)) == 3)
        #expect(read.isActiveAttention(at: now))
        #expect(!snoozed.isActiveAttention(at: now))
    }

    @Test func aggregatesAgentsNewestFirstAndKeepsQueueHealth() async {
        let first = finding("older", agent: "first")
        let second = finding("newer", agent: "second", createdAt: now.addingTimeInterval(10))
        let now = now
        let inbox = AttentionInbox(fetchAgents: {
            [.init(id: "first", displayName: "First"), .init(id: "second", displayName: "Second")]
        }, fetchInbox: { id in
            .init(findings: [id == "first" ? first : second], lastCheckedAt: now,
                  pendingAnalysisCount: 1, sourceErrors: id == "second" ? ["tracker": "Unavailable"] : [:])
        }, updateFinding: { _, _, _ in first })
        await inbox.refresh()
        #expect(inbox.findings.map(\.id) == ["newer", "older"])
        #expect(inbox.agentNames["second"] == "Second")
        #expect(inbox.pendingAnalysisCount == 2)
        #expect(inbox.lastCheckedAt == now)
        #expect(inbox.errors == ["Second · tracker: Unavailable"])
    }

    @Test(arguments: [ProactiveFindingActionRequest.Action.read, .snooze, .dismiss])
    func actionsUpdateFeedAndBadgeImmediately(action: ProactiveFindingActionRequest.Action) async {
        let original = finding("pending")
        let now = now
        let inbox = AttentionInbox(fetchAgents: { [.init(id: "agent", displayName: "Agent")] },
                                   fetchInbox: { _ in .init(findings: [original]) },
                                   updateFinding: { agent, id, requested in
            #expect(agent == "agent")
            #expect(id == "pending")
            #expect(requested == action)
            var updated = original
            switch requested {
            case .read: updated.readAt = now
            case .snooze: updated.snoozedUntil = now.addingTimeInterval(86_400)
            case .dismiss: updated.dismissedAt = now
            }
            return updated
        })
        await inbox.refresh()
        #expect(inbox.unreadCount(at: now) == 1)
        await inbox.act(original, action: action)
        #expect(inbox.unreadCount(at: now) == 0)
        #expect(inbox.busyFindingIDs.isEmpty)
        #expect(inbox.findings.count == 1)
    }

    @Test func partialRefreshFailureKeepsPreviousFindingsAndReportsError() async {
        let fixture = AttentionFixture(first: finding("one", agent: "first"), second: finding("two", agent: "second"))
        let inbox = AttentionInbox(fetchAgents: {
            [.init(id: "first", displayName: "First"), .init(id: "second", displayName: "Second")]
        }, fetchInbox: { try await fixture.fetch($0) }, updateFinding: { _, _, _ in await fixture.first })
        await inbox.refresh()
        await fixture.failSecond()
        await inbox.refresh()
        #expect(inbox.findings.count == 2)
        #expect(inbox.errors.count == 1)
        #expect(inbox.errors.first?.hasPrefix("Second:") == true)
    }

    @Test func failedActionPreservesUnreadState() async {
        let original = finding("pending")
        let inbox = AttentionInbox(fetchAgents: { [.init(id: "agent", displayName: "Agent")] },
                                   fetchInbox: { _ in .init(findings: [original]) },
                                   updateFinding: { _, _, _ in throw URLError(.notConnectedToInternet) })
        await inbox.refresh()
        await inbox.act(original, action: .read)
        #expect(inbox.unreadCount(at: now) == 1)
        #expect(inbox.findings.first?.readAt == nil)
        #expect(!inbox.errors.isEmpty)
        #expect(inbox.busyFindingIDs.isEmpty)
    }
}

private actor AttentionFixture {
    let first: ProactiveFinding
    let second: ProactiveFinding
    private var shouldFailSecond = false

    init(first: ProactiveFinding, second: ProactiveFinding) {
        self.first = first
        self.second = second
    }

    func failSecond() { shouldFailSecond = true }

    func fetch(_ agent: String) throws -> ProactiveInbox {
        if agent == "second", shouldFailSecond { throw URLError(.notConnectedToInternet) }
        return .init(findings: [agent == "first" ? first : second])
    }
}
