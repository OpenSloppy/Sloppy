import Foundation
import PluginSDK
import SloppyConsoleProtocol
import SloppyRemoteProtocol

struct ConsoleModelStreamRegistration: Sendable {
    var generation: UUID
    var senderID: UUID
    var proof: SignedInstanceAccessProof
    var certificate: Data
    var task: Task<Void, Never>
    var expiry: Task<Void, Never>
}

extension CoreService {
    func consoleModelInstances() async throws -> [ConsoleModelInstance] {
        await startConsoleRelayIfBound()
        return try await consoleModelBridge.instances()
    }
    func handleConsoleModelRequest(senderID: UUID, certificate: Data, packet: ConsoleRemotePacket) async -> ConsoleRemotePacket? {
        guard let request = try? ConsoleWire.decode(ConsoleModelRequest.self, from: packet.payload) else { return nil }
        func errorReply(_ message: String, accessDenied: Bool = true) -> ConsoleRemotePacket? {
            guard let data = try? ConsoleWire.encode(ConsoleModelResponse(id: request.id, event: .error, message: message, accessDenied: accessDenied)) else { return nil }
            return .init(kind: "models.response", payload: data)
        }
        do {
            guard let store = consoleTrustStore, let proof = packet.proof, proof.proof.deviceID == senderID,
                  proof.proof.instanceID == request.instanceID else { throw ConsoleTrustError.forbidden }
            let context = try await store.authorize(proof, peerCertificate: certificate)
            try ConsoleModelAuthorization.require(context, inference: request.action != .catalog)
            if request.action == .catalog {
                let models = listAvailableProviderModels().filter { !$0.id.hasPrefix("sloppy:") && modelProvider?.supports(modelName: $0.id) == true }
                return .init(kind: "models.response", payload: try ConsoleWire.encode(ConsoleModelResponse(id: request.id, event: .catalog, models: models)))
            }
            if request.action == .cancel {
                guard consoleModelStreams[request.id]?.senderID == senderID else { return nil }
                closeConsoleModelStream(request.id)
                return nil
            }
            guard let input = request.inference, !input.model.hasPrefix("sloppy:"),
                  consoleModelStreams.count < 16, consoleModelStreams[request.id] == nil,
                  let remote = consoleRemoteConnection else { throw ConsoleTrustError.forbidden }
            let generation = UUID()
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                do {
                    let updates = try await self.streamRemoteInference(input)
                    var completed = false
                    for await event in updates {
                        try Task.checkCancellation()
                        let current = try await store.authorize(proof, peerCertificate: certificate)
                        try ConsoleModelAuthorization.require(current, inference: true)
                        guard event.event != "error" else { throw ConsoleModelBridge.BridgeError.unavailable }
                        let response = try JSONDecoder().decode(SloppyInferenceResponse.self, from: event.data)
                        let frame = ConsoleModelResponse(id: request.id, event: event.event == "complete" ? .complete : .snapshot, response: response)
                        try await remote.send(.init(kind: "models.response", payload: ConsoleWire.encode(frame)), to: senderID)
                        if event.event == "complete" { completed = true }
                    }
                    guard completed else { throw ConsoleModelBridge.BridgeError.invalidResponse }
                } catch {
                    if !Task.isCancelled, let reply = errorReply("The Console instance could not complete model inference.", accessDenied: error is ConsoleTrustError) {
                        try? await remote.send(reply, to: senderID)
                    }
                }
                await self.finishConsoleModelStream(request.id, generation: generation)
            }
            let expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, context.expiresAt.timeIntervalSinceNow))) }
                catch { return }
                await self?.closeConsoleModelStream(request.id)
            }
            consoleModelStreams[request.id] = .init(generation: generation, senderID: senderID, proof: proof, certificate: certificate, task: task, expiry: expiry)
            return nil
        } catch { return errorReply(ConsoleModelBridge.BridgeError.accessDenied.localizedDescription) }
    }
    func validateConsoleModelStreams() async {
        guard let store = consoleTrustStore else { return }
        for (id, stream) in consoleModelStreams {
            do {
                let context = try await store.authorize(stream.proof, peerCertificate: stream.certificate)
                try ConsoleModelAuthorization.require(context, inference: true)
            } catch { closeConsoleModelStream(id) }
        }
    }
    func closeConsoleModelStream(_ id: UUID) {
        guard let stream = consoleModelStreams.removeValue(forKey: id) else { return }
        stream.task.cancel(); stream.expiry.cancel()
    }
    private func finishConsoleModelStream(_ id: UUID, generation: UUID) {
        if consoleModelStreams[id]?.generation == generation {
            let stream = consoleModelStreams.removeValue(forKey: id)
            stream?.expiry.cancel()
        }
    }
    func consoleModelsDisconnected() async {
        for id in Array(consoleModelStreams.keys) { closeConsoleModelStream(id) }
        await consoleModelBridge.failPending()
    }
}
