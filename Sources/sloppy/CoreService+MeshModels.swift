import Foundation
import PluginSDK
import Protocols
import SloppyNodeCore

struct MeshModelStreamRegistration: Sendable {
    var generation: UUID
    var owner: String
    var task: Task<Void, Never>
}

extension CoreService {
    func meshModelAccessAllowed(from nodeID: String) -> Bool {
        guard let peer = try? nodeMeshStore.listNodes().first(where: { $0.id == nodeID }) else { return false }
        return peer.capabilities.contains("sloppy.models.inference") || peer.capabilities.contains("sloppy.core.remote")
    }

    func handleMeshModelCatalog(_ envelope: MeshEnvelope) async -> JSONValue {
        guard meshModelAccessAllowed(from: envelope.from) else {
            return .object(["requestId": .string(envelope.id), "method": .string("models.catalog"), "ok": .bool(false),
                            "error": .object(["code": .string("model_access_denied")])])
        }
        let models = listAvailableProviderModels().filter { !$0.id.hasPrefix("sloppy:") }
        guard let value = try? JSONValueCoder.encode(models) else { return .null }
        return .object(["requestId": .string(envelope.id), "method": .string("models.catalog"), "ok": .bool(true), "result": value])
    }

    /// `send` is a transport seam used by in-process hosts/tests; production uses
    /// the already authenticated and encrypted NodeMeshClient connection.
    func handleMeshModelStream(_ envelope: MeshEnvelope, send: (@Sendable (MeshEnvelope) async throws -> Void)? = nil) async -> [MeshEnvelope] {
        guard let object = envelope.payload.asObject, let streamID = object["streamId"]?.asString, !streamID.isEmpty else { return [] }
        func close(_ message: String) -> [MeshEnvelope] {
            [.init(type: .streamClose, from: envelope.to ?? "", to: envelope.from,
                   payload: .object(["streamId": .string(streamID), "ok": .bool(false), "message": .string(message)]))]
        }
        if envelope.type == .streamClose {
            guard let registration = meshModelStreams[streamID], registration.owner == envelope.from else { return [] }
            meshModelStreams[streamID] = nil
            registration.task.cancel()
            return []
        }
        guard envelope.type == .streamOpen, object["kind"]?.asString == "models.inference",
              meshModelAccessAllowed(from: envelope.from) else { return close("Model access is not granted to this computer.") }
        guard meshModelStreams.count < 16, meshModelStreams[streamID] == nil,
              let params = object["params"], var request = try? JSONValueCoder.decode(SloppyInferenceRequest.self, from: params),
              !request.model.hasPrefix("sloppy:") else { return close("Invalid model request, active stream, or forwarding loop.") }
        request.stream = true
        let payload = request
        let generation = UUID()
        let target = envelope.from
        let local = envelope.to ?? ""
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            let transmit: @Sendable (MeshEnvelope) async throws -> Void = { response in
                if let send { try await send(response) }
                else { try await self.sendMeshModelEnvelope(response) }
            }
            do {
                let updates = try await self.streamRemoteInference(payload)
                var complete = false
                for await event in updates {
                    try Task.checkCancellation()
                    guard event.event != "error" else { throw MeshModelBridge.BridgeError.remoteFailure }
                    let value = try JSONValueCoder.encode(JSONDecoder().decode(SloppyInferenceResponse.self, from: event.data))
                    try await transmit(.init(type: .streamChunk, from: local, to: target,
                        payload: .object(["streamId": .string(streamID), "data": .object(["event": .string(event.event), "response": value])])))
                    if event.event == "complete" { complete = true }
                }
                guard complete else { throw MeshModelBridge.BridgeError.invalidResponse }
                try await transmit(.init(type: .streamClose, from: local, to: target,
                    payload: .object(["streamId": .string(streamID), "ok": .bool(true)])))
            } catch {
                if !Task.isCancelled {
                    try? await transmit(.init(type: .streamClose, from: local, to: target,
                        payload: .object(["streamId": .string(streamID), "ok": .bool(false), "message": .string("Remote inference stopped or failed.")])))
                }
            }
            await self.finishMeshModelStream(streamID, generation: generation)
        }
        meshModelStreams[streamID] = .init(generation: generation, owner: target, task: task)
        return []
    }

    private func finishMeshModelStream(_ id: String, generation: UUID) {
        if meshModelStreams[id]?.generation == generation { meshModelStreams[id] = nil }
    }

    private func sendMeshModelEnvelope(_ envelope: MeshEnvelope) async throws {
        guard let client = nodeMeshClient, let target = envelope.to, let streamID = envelope.payload.asObject?["streamId"]?.asString else {
            throw MeshModelBridge.BridgeError.notConnected
        }
        if envelope.type == .streamChunk {
            try await client.sendStreamChunk(streamID: streamID, to: target, data: envelope.payload.asObject?["data"] ?? .null)
        } else {
            try await client.closeStream(streamID: streamID, to: target, ok: envelope.payload.asObject?["ok"]?.asBool == true,
                                         message: envelope.payload.asObject?["message"]?.asString)
        }
    }
}
