import Foundation
import Protocols
import SloppyRuntime
import Testing
@testable import sloppy

@Suite("Agent session collaboration")
struct SessionMessagingTests {
    private func fixture() async throws -> (CoreService, AgentSessionSummary, AgentSessionSummary, URL) {
        let config = CoreConfig.test
        let service = CoreService(config: config)
        _ = try await service.createAgent(.init(id: "sender", displayName: "Sender", role: "Test"))
        _ = try await service.createAgent(.init(id: "receiver", displayName: "Receiver", role: "Test"))
        let sender = try await service.createAgentSession(agentID: "sender", request: .init(title: "Same title"))
        let receiver = try await service.createAgentSession(agentID: "receiver", request: .init(title: "Same title"))
        return (service, sender, receiver, await service.workspaceRootURL)
    }

    @Test func crossAgentReadAndExplicitReply() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.postAgentSessionMessage(agentID: receiver.agentId, sessionID: receiver.id,
            request: .init(userId: "user", content: "Existing evidence", mode: .ask))
        let listing = await service.invokeToolFromRuntime(agentID: sender.agentId, sessionID: sender.id,
            request: .init(tool: "sessions.list", arguments: ["scope": .string("all")]), recordSessionEvents: false)
        #expect(listing.ok)
        #expect(listing.data?.asArray?.contains { $0.asObject?["agentId"]?.asString == receiver.agentId } == true)
        let history = await service.invokeToolFromRuntime(agentID: sender.agentId, sessionID: sender.id,
            request: .init(tool: "sessions.history", arguments: ["agentId": .string(receiver.agentId), "sessionId": .string(receiver.id)]),
            recordSessionEvents: false)
        #expect(history.ok)
        #expect(history.data?.asObject?["summary"]?.asObject?["agentId"]?.asString == receiver.agentId)
        await service.holdSessionInboxForTests(receiver.id)
        let send = await service.invokeToolFromRuntime(agentID: sender.agentId, sessionID: sender.id,
            request: .init(tool: "messages.send", arguments: ["agentId": .string(receiver.agentId), "sessionId": .string(receiver.id), "content": .string("Please inspect the evidence")]),
            recordSessionEvents: false)
        #expect(send.ok)
        let id = try #require(send.data?.asObject?["messageId"]?.asString)
        let accepted = try await service.getAgentSession(agentID: receiver.agentId, sessionID: receiver.id)
        #expect(accepted.events.first { $0.message?.id == id }?.message?.peerOrigin?.agentId == sender.agentId)
        await service.releaseSessionInboxForTests(agentID: receiver.agentId, sessionID: receiver.id)
        try await waitForDelivery(service, id: id)
        let reply = try await service.sendPeerSessionMessage(senderAgentID: receiver.agentId, senderSessionID: receiver.id,
            targetAgentID: sender.agentId, targetSessionID: sender.id, content: "Evidence checked", messageID: nil)
        try await waitForDelivery(service, id: try #require(reply.asObject?["messageId"]?.asString))
        let senderDetail = try await service.getAgentSession(agentID: sender.agentId, sessionID: sender.id)
        #expect(senderDetail.events.compactMap(\.message).contains { $0.peerOrigin?.agentId == receiver.agentId })
        await service.shutdownChannelPlugins()
    }

    @Test func busyDeliveryIsFIFOAndDeduplicated() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await service.holdSessionInboxForTests(receiver.id)
        let firstID = UUID().uuidString
        for (id, content) in [(firstID, "First"), (firstID, "First"), (UUID().uuidString, "Second")] {
            _ = try await service.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
                targetAgentID: receiver.agentId, targetSessionID: receiver.id, content: content, messageID: id)
        }
        let entries = try await service.inboxEntriesForTests()
        #expect(entries.map(\.request.content) == ["First", "Second"])
        #expect(entries.allSatisfy { $0.state == .queued })
        let detail = try await service.getAgentSession(agentID: receiver.agentId, sessionID: receiver.id)
        #expect(detail.events.compactMap(\.message).map { $0.segments.first?.text } == ["First", "Second"])
        await #expect(throws: PeerSessionMessageError.self) {
            try await service.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
                targetAgentID: receiver.agentId, targetSessionID: receiver.id, content: "Different", messageID: firstID)
        }
        await service.releaseSessionInboxForTests(agentID: receiver.agentId, sessionID: receiver.id)
        for entry in entries { try await waitForDelivery(service, id: entry.id) }
        await service.shutdownChannelPlugins()
    }

    @Test func inboxRestartsDoNotReplayProcessingMessages() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await service.holdSessionInboxForTests(receiver.id)
        let receipt = try await service.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
            targetAgentID: receiver.agentId, targetSessionID: receiver.id, content: "May have executed", messageID: nil)
        let id = try #require(receipt.asObject?["messageId"]?.asString)
        try await service.markMessageProcessingForTests(id)
        let restarted = CoreService(config: await service.getConfig())
        await restarted.waitForStartup()
        let entries = try await restarted.inboxEntriesForTests()
        #expect(entries.first?.state == .interrupted)
        let detail = try await restarted.getAgentSession(agentID: receiver.agentId, sessionID: receiver.id)
        #expect(detail.events.contains { $0.id == "delivery-interrupted-" + id })
        #expect(!detail.events.compactMap(\.message).contains { $0.role == .assistant })
        await service.shutdownChannelPlugins()
        await restarted.shutdownChannelPlugins()
    }

    @Test func finishedWorkerCommunicatesWithoutReopeningTask() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await service.openLongChat(agentID: receiver.agentId, userID: "user")
        let child = try await service.makeClosedWorkerForTests(parent: parent)
        await service.holdSessionInboxForTests(child.id)
        let receipt = try await service.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
            targetAgentID: child.agentId, targetSessionID: child.id, content: "Explain your evidence", messageID: nil)
        try await service.prepareClosedPeerForTests(agentID: child.agentId, sessionID: child.id)
        for tool in ["files.write", "runtime.exec", "agent_delegate.finish"] {
            let result = await service.invokeToolFromRuntime(agentID: child.agentId, sessionID: child.id,
                request: .init(tool: tool, arguments: [:]), recordSessionEvents: false)
            #expect(result.error?.code == "tool_forbidden")
        }
        await service.releaseSessionInboxForTests(agentID: child.agentId, sessionID: child.id)
        try await waitForDelivery(service, id: try #require(receipt.asObject?["messageId"]?.asString))
        let conversation = try await service.getLongChat(agentID: parent.agentId, sessionID: parent.id)
        #expect(conversation.assignments.first?.tasks.first?.status == .completed)
        #expect(conversation.assignments.first?.tasks.first?.attempts.count == 1)
        await service.shutdownChannelPlugins()
    }

    @Test func pendingInputDoesNotConsumePeerMessage() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = AgentSessionEvent(agentId: receiver.agentId, sessionId: receiver.id, type: .inputRequest,
            inputRequest: .init(questions: []))
        _ = try await service.appendAgentSessionEvents(agentID: receiver.agentId, sessionID: receiver.id,
            request: .init(events: [pending]))
        _ = try await service.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
            targetAgentID: receiver.agentId, targetSessionID: receiver.id, content: "Cannot approve this", messageID: nil)
        await service.awaitSessionInboxForTests(receiver.id)
        #expect(try await service.inboxEntriesForTests().first?.state == .queued)
        let detail = try await service.getAgentSession(agentID: receiver.agentId, sessionID: receiver.id)
        #expect(detail.events.compactMap(\.inputResponse).isEmpty)
        await service.shutdownChannelPlugins()
    }

    @Test func mentionAddsTargetEvidenceToModelContext() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.appendAgentSessionEvents(agentID: receiver.agentId, sessionID: receiver.id,
            request: .init(events: [.init(agentId: receiver.agentId, sessionId: receiver.id, type: .message,
                message: .init(role: .assistant, segments: [.init(kind: .text, text: "Evidence exists only in the referenced session.")]))]))
        let reference = AgentSessionReference(agentId: receiver.agentId, sessionId: receiver.id)
        let response = try await service.postAgentSessionMessage(agentID: sender.agentId, sessionID: sender.id,
            request: .init(userId: "user", content: "Read [@Same title](\(try #require(reference.url)))", mode: .ask))
        let text = response.appendedEvents.compactMap(\.message).filter { $0.role == .assistant }
            .flatMap(\.segments).compactMap(\.text).joined()
        #expect(text.contains("Referenced session"))
        #expect(text.contains("Evidence exists only in the referenced session."))
        let message = response.appendedEvents.compactMap(\.message).first { $0.role == .user }
        #expect(message?.sessionReferences == [reference])
        await service.shutdownChannelPlugins()
    }

    @Test func queuedPeerContentIsExcludedFromRestoredBootstrap() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await service.holdSessionInboxForTests(receiver.id)
        _ = try await service.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
            targetAgentID: receiver.agentId, targetSessionID: receiver.id, content: "UNDELIVERED_PEER_CONTENT", messageID: nil)
        _ = try await service.prepareAgentSessionContext(agentID: receiver.agentId, sessionID: receiver.id)
        let runtime = await service.runtime
        let context = await runtime.channelBootstrapContent(channelId: "agent:\(receiver.agentId):session:\(receiver.id)")
        #expect(context?.contains("UNDELIVERED_PEER_CONTENT") == false)
        #expect(await service.pendingSessionMessageIDs(agentID: receiver.agentId, sessionID: receiver.id).count == 1)
        await service.shutdownChannelPlugins()
    }

    @Test func conversationPeerRecoveryIsVisibleAndNotReplayed() async throws {
        let (service, sender, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await service.openLongChat(agentID: receiver.agentId, userID: "user")
        let id = try await service.addProcessingPeerTurnForTests(sender: sender, parent: parent)
        let restarted = CoreService(config: await service.getConfig())
        await restarted.waitForStartup()
        let detail = try await restarted.getAgentSession(agentID: parent.agentId, sessionID: parent.id)
        #expect(detail.events.contains { $0.id == "delivery-interrupted-" + id })
        let retry = try await restarted.sendPeerSessionMessage(senderAgentID: sender.agentId, senderSessionID: sender.id,
            targetAgentID: parent.agentId, targetSessionID: parent.id, content: "Interrupted peer turn", messageID: id)
        #expect(retry.asObject?["state"]?.asString == "interrupted")
        await service.shutdownChannelPlugins()
        await restarted.shutdownChannelPlugins()
    }

    @Test func historyCursorReturnsEarlierEvents() async throws {
        let (service, _, receiver, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = (0..<5).map { index in
            AgentSessionEvent(agentId: receiver.agentId, sessionId: receiver.id, type: .message,
                message: .init(role: .user, segments: [.init(kind: .text, text: "Event \(index)")]))
        }
        _ = try await service.appendAgentSessionEvents(agentID: receiver.agentId, sessionID: receiver.id, request: .init(events: events))
        let detail = try await service.getAgentSession(agentID: receiver.agentId, sessionID: receiver.id)
        let last = try SessionToolQuery.history(detail, arguments: ["limit": .number(2)])
        let cursor = try #require(last.asObject?["beforeEventId"]?.asString)
        let previous = try SessionToolQuery.history(detail, arguments: ["limit": .number(2), "beforeEventId": .string(cursor)])
        #expect(last.asObject?["events"]?.asArray?.first?.asObject?["id"]?.asString == events[3].id)
        #expect(previous.asObject?["events"]?.asArray?.first?.asObject?["id"]?.asString == events[1].id)
        #expect(throws: SessionToolQuery.QueryError.self) { try SessionToolQuery.history(detail, arguments: ["beforeEventId": .string("missing")]) }
    }

    private func waitForDelivery(_ service: CoreService, id: String) async throws {
        guard let initial = try await service.inboxEntriesForTests().first(where: { $0.id == id }) else {
            Issue.record("Missing message \(id)")
            return
        }
        await service.awaitSessionInboxForTests(initial.sessionId)
        #expect(try await service.inboxEntriesForTests().first(where: { $0.id == id })?.state == .delivered)
    }

}

private extension CoreService {
    func holdSessionInboxForTests(_ id: String) { activeSessionMessageRuns.insert(id) }
    func releaseSessionInboxForTests(agentID: String, sessionID: String) {
        activeSessionMessageRuns.remove(sessionID)
        scheduleSessionInbox(agentID: agentID, sessionID: sessionID)
    }
    func markMessageProcessingForTests(_ id: String) throws { try sessionMessageInbox().update(id: id, state: .processing) }
    func awaitSessionInboxForTests(_ id: String) async { await sessionMessageRunners[id]?.value }
    func prepareClosedPeerForTests(agentID: String, sessionID: String) async throws {
        try await preparePeerConversation(agentID: agentID, detail: getAgentSession(agentID: agentID, sessionID: sessionID))
    }
    func addProcessingPeerTurnForTests(sender: AgentSessionSummary, parent: AgentSessionSummary) throws -> String {
        let id = UUID().uuidString
        var turn = LongChatFileStore.Turn(id: id, agentId: parent.agentId, sessionId: parent.id,
            request: .init(userId: "user", content: "Interrupted peer turn", clientMessageId: id),
            isNotification: false, peerOrigin: .init(agentId: sender.agentId, sessionId: sender.id, chainId: UUID().uuidString, depth: 1))
        turn.processing = true
        try longChats().transaction { $0.turns.append(turn) }
        _ = try persistLongChatTurnIfNeeded(turn)
        return id
    }
    func makeClosedWorkerForTests(parent: AgentSessionSummary) throws -> AgentSessionSummary {
        let child = try sessionStore.createSession(agentID: parent.agentId,
            request: .init(title: "Closed worker", parentSessionId: parent.id, kind: .longChatWorker))
        let storage = try longChats()
        let assignment = try storage.delegate(sessionId: parent.id, sourceMessageId: "source",
            request: .init(requestKey: "closed", title: "Closed", acceptanceCriteria: "Done",
                           tasks: [.init(key: "one", title: "One", objective: "Inspect", resourceKeys: ["project:p"], readOnly: false)]))
        try storage.updateTask(sessionId: parent.id, taskId: assignment.tasks[0].id) {
            $0.attempts[0].sessionId = child.id
            $0.attempts[0].status = .completed
        }
        return child
    }
    func inboxEntriesForTests() throws -> [SessionMessageInboxFileStore.Entry] { try sessionMessageInbox().entries }
}
