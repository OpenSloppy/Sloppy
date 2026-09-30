import Foundation
import Protocols
import Testing
@testable import sloppy

@Suite("Session delivery stream")
struct SessionDeliveryStreamTests {
    @Test("overflow terminates the stream instead of silently dropping live events")
    func overflowTerminatesStream() async {
        let service = CoreService(config: .test)
        let pair = AsyncStream<AgentSessionStreamUpdate>.makeStream(bufferingPolicy: .bufferingNewest(2))
        for cursor in 1...3 {
            await service.yieldLiveSessionUpdate(.init(kind: .sessionDelta, cursor: cursor, message: "chunk"), to: pair.continuation)
        }
        var received: [Int] = []
        for await update in pair.stream { received.append(update.cursor) }
        #expect(received == [2, 3])
        if case .terminated = pair.continuation.yield(.init(kind: .heartbeat, cursor: 3)) {
        } else {
            Issue.record("Overflowing stream must finish to trigger reconnect and history resync")
        }
    }

    @Test("a new session starts at the live cursor baseline and both subscribers see contiguous updates")
    func cursorsHaveStableBaseline() async throws {
        let service = CoreService(config: .test)
        let agentID = "stream-delivery-\(UUID().uuidString)"
        _ = try await service.createAgent(.init(id: agentID, displayName: "Agent", role: "Test"))
        let session = try await service.createAgentSession(agentID: agentID, request: .init(title: "Test"))
        let first = try await service.streamAgentSessionEvents(agentID: agentID, sessionID: session.id)
        let second = try await service.streamAgentSessionEvents(agentID: agentID, sessionID: session.id)
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let ready = try #require(await firstIterator.next())
        let otherReady = try #require(await secondIterator.next())
        #expect(ready.cursor >= 1_000_000)
        #expect(otherReady.cursor == ready.cursor)
        await service.publishLiveSessionDelta(agentID: agentID, sessionID: session.id, chunk: "hello")
        let update = try #require(await firstIterator.next())
        let otherUpdate = try #require(await secondIterator.next())
        #expect(update.cursor == ready.cursor + 1)
        #expect(otherUpdate.cursor == update.cursor)
    }
}
