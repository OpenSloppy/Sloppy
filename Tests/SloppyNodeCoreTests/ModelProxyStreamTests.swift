import Foundation
import Testing
import Protocols
@testable import SloppyNodeCore

@Suite("Model proxy stream peer binding")
struct ModelProxyStreamTests {
    @Test func anotherPeerCannotInjectModelDataOrCloseTheStream() async throws {
        let manager = NodeMeshStreamManager()
        let stream = await manager.register(streamID: "model-stream", peerID: "personal")
        var iterator = stream.messages.makeAsyncIterator()
        #expect(await manager.receive(.init(type: .streamChunk, from: "other", to: "work",
            payload: .object(["streamId": .string(stream.id), "data": .string("injected")]))) == false)
        #expect(await manager.receive(.init(type: .streamClose, from: "other", to: "work",
            payload: .object(["streamId": .string(stream.id), "ok": .bool(true)]))) == false)
        #expect(await manager.receive(.init(type: .streamChunk, from: "personal", to: "work",
            payload: .object(["streamId": .string(stream.id), "data": .string("model-response")]))))
        #expect(try await iterator.next() == .string("model-response"))
        await manager.finish(streamID: stream.id)
        #expect(try await iterator.next() == nil)
    }

    @Test func relayMayReportFailureButCannotSupplyInferenceData() async throws {
        let manager = NodeMeshStreamManager()
        let stream = await manager.register(streamID: "unavailable-stream", peerID: "personal")
        var iterator = stream.messages.makeAsyncIterator()
        #expect(await manager.receive(.init(type: .streamChunk, from: "relay", to: "work",
            payload: .object(["streamId": .string(stream.id), "data": .string("injected")]))) == false)
        #expect(await manager.receive(.init(type: .streamClose, from: "relay", to: "work",
            payload: .object(["streamId": .string(stream.id), "ok": .bool(false), "message": .string("Computer offline")]))))
        await #expect(throws: NodeMeshStreamError.self) { try await iterator.next() }
    }
}
