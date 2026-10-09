import Foundation
import Protocols

public enum NodeMeshRPCError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let requestId):
            "Invalid RPC request: \(requestId)"
        case .timeout(let requestId):
            "Mesh RPC request timed out: \(requestId)"
        }
    }
}

public actor NodeMeshRPCManager {
    public typealias Sender = @Sendable (MeshEnvelope) async throws -> Void

    private struct PendingRequest {
        var continuation: CheckedContinuation<MeshEnvelope, Error>
        var peerID: String?
        var encryptedMethod: String?
    }
    private var pending: [String: PendingRequest] = [:]

    public init() {}

    public func send(
        _ request: MeshEnvelope,
        timeout: TimeInterval = 30,
        send: @escaping Sender
    ) async throws -> MeshEnvelope {
        guard request.type == .rpcRequest else {
            throw NodeMeshRPCError.invalidRequest(request.id)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let method = request.payload.asObject?["method"]?.asString
                pending[request.id] = .init(continuation: continuation, peerID: request.to,
                    encryptedMethod: ["core.http", "models.catalog"].contains(method ?? "") ? method : nil)
                Task {
                    do {
                        try await send(request)
                    } catch {
                        fail(requestId: request.id, error: error)
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    fail(requestId: request.id, error: NodeMeshRPCError.timeout(request.id))
                }
            }
        } onCancel: {
            Task {
                await self.fail(requestId: request.id, error: CancellationError())
            }
        }
    }

    @discardableResult
    public func receive(_ response: MeshEnvelope) -> Bool {
        guard response.type == .rpcResponse,
              let requestId = response.payload.asObject?["requestId"]?.asString,
              let request = pending[requestId]
        else {
            return false
        }
        let relayFailure = response.from == "relay" && response.payload.asObject?["ok"]?.asBool == false
        if let peer = request.peerID, response.from != peer, !relayFailure { return false }
        if let method = request.encryptedMethod,
           response.payload.asObject?["method"]?.asString != method, !relayFailure { return false }
        pending[requestId] = nil
        request.continuation.resume(returning: response)
        return true
    }

    private func fail(requestId: String, error: Error) {
        guard let request = pending.removeValue(forKey: requestId) else {
            return
        }
        request.continuation.resume(throwing: error)
    }
}
