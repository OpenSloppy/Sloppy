import Foundation
import AnyLanguageModel
import PluginSDK
import Protocols
import SloppyNodeCore

/// A service-owned bridge shared by model instances; no HTTP loopback token and
/// no Claude credentials leave the personal machine.
actor MeshModelBridge {
    enum BridgeError: Error, LocalizedError {
        case notConnected
        case invalidResponse
        case remoteFailure
        var errorDescription: String? {
            switch self {
            case .notConnected: "Join the Sloppy relay on this computer and wait for the connection before using remote models."
            case .invalidResponse: "The remote model returned an invalid or incomplete response."
            case .remoteFailure: "The remote computer could not complete inference. Check its model configuration and access grant."
            }
        }
    }
    private var client: NodeMeshClient?
    func setClient(_ client: NodeMeshClient?) { self.client = client }

    func catalog(nodeID: String) async throws -> [ProviderModelOption] {
        guard let client else { throw BridgeError.notConnected }
        let reply = try await client.sendRPCRequest(to: nodeID, method: "models.catalog", timeout: 30)
        guard reply.payload.asObject?["ok"]?.asBool == true,
              let result = reply.payload.asObject?["result"] else { throw BridgeError.remoteFailure }
        return try JSONValueCoder.decode([ProviderModelOption].self, from: result)
    }

    func infer(nodeID: String, request: SloppyInferenceRequest, onSnapshot: (@Sendable (SloppyInferenceResponse) -> Void)?) async throws -> SloppyInferenceResponse {
        guard let client else { throw BridgeError.notConnected }
        let stream = try await client.openStream(to: nodeID, kind: "models.inference", params: JSONValueCoder.encode(request))
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            let result = try await withThrowingTaskGroup(of: SloppyInferenceResponse.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        for try await value in stream.messages {
                            try Task.checkCancellation()
                            guard let event = value.asObject?["event"]?.asString,
                                  let payload = value.asObject?["response"] else { throw BridgeError.invalidResponse }
                            let response = try JSONValueCoder.decode(SloppyInferenceResponse.self, from: payload)
                            if event == "snapshot" { onSnapshot?(response) }
                            else if event == "complete" { return response }
                            else { throw BridgeError.invalidResponse }
                        }
                        throw BridgeError.invalidResponse
                    } onCancel: {
                        Task { try? await client.closeStream(streamID: stream.id, to: nodeID) }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until: deadline); throw BridgeError.remoteFailure }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw BridgeError.invalidResponse }
                return response
            }
            return result
        } catch {
            try? await client.closeStream(streamID: stream.id, to: nodeID)
            throw error
        }
    }
}
