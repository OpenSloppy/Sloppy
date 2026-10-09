import Foundation
import Protocols

public enum NodeMeshStreamError: LocalizedError, Sendable, Equatable {
    case relayNotConnected
    case remoteClosed(String?)
    case backpressureOverflow

    public var errorDescription: String? {
        switch self {
        case .relayNotConnected:
            "Mesh relay connection is not ready."
        case .remoteClosed(let message):
            message ?? "Remote mesh stream closed."
        case .backpressureOverflow:
            "Remote mesh stream exceeded its bounded receive buffer."
        }
    }
}

public struct NodeMeshStream: Sendable {
    public let id: String
    public let messages: AsyncThrowingStream<JSONValue, Error>

    public init(id: String, messages: AsyncThrowingStream<JSONValue, Error>) {
        self.id = id
        self.messages = messages
    }
}

public actor NodeMeshStreamManager {
    private var continuations: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var peers: [String: String] = [:]

    public init() {}

    public func register(streamID: String, peerID: String? = nil) -> NodeMeshStream {
        peers[streamID] = peerID
        let messages = AsyncThrowingStream<JSONValue, Error>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            continuations[streamID] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.remove(streamID: streamID) }
            }
        }
        return NodeMeshStream(id: streamID, messages: messages)
    }

    @discardableResult
    public func receive(_ envelope: MeshEnvelope) -> Bool {
        guard envelope.type == .streamChunk || envelope.type == .streamClose,
              let object = envelope.payload.asObject,
              let streamID = object["streamId"]?.asString,
              let continuation = continuations[streamID]
        else {
            return false
        }
        if let peer = peers[streamID], envelope.from != peer {
            // Relay-generated failures are control messages, never inference data.
            guard envelope.from == "relay", envelope.type == .streamClose, object["ok"]?.asBool == false else { return false }
        }

        if envelope.type == .streamChunk {
            if case .dropped = continuation.yield(object["data"] ?? .null) {
                continuations[streamID] = nil
                continuation.finish(throwing: NodeMeshStreamError.backpressureOverflow)
            }
        } else {
            continuations[streamID] = nil
            let message = object["message"]?.asString
            if object["ok"]?.asBool == false {
                continuation.finish(throwing: NodeMeshStreamError.remoteClosed(message))
            } else {
                continuation.finish()
            }
        }
        return true
    }

    public func failAll(_ error: Error) {
        let active = continuations.values
        continuations.removeAll()
        peers.removeAll()
        for continuation in active {
            continuation.finish(throwing: error)
        }
    }

    public func fail(streamID: String, error: Error) {
        guard let continuation = continuations.removeValue(forKey: streamID) else { return }
        continuation.finish(throwing: error)
        peers[streamID] = nil
    }

    public func finish(streamID: String) {
        guard let continuation = continuations.removeValue(forKey: streamID) else { return }
        continuation.finish()
        peers[streamID] = nil
    }

    private func remove(streamID: String) {
        continuations[streamID] = nil
        peers[streamID] = nil
    }
}
