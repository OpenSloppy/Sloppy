import Foundation
import AnyLanguageModel
import PluginSDK
import Protocols
import Crypto

extension CoreService {
    func authorizeModelProxy(_ request: HTTPRequest) async -> Bool {
        let identityEnabled = await identityAuthEnabled()
        if request.consoleContext != nil || identityEnabled {
            return await CoreRouter.identityActor(for: request, service: self) != nil
        }
        if dashboardAuthStatus().enabled { return validateDashboardAuthorizationHeader(request.header("authorization")) }
        let token = currentConfig.auth.token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !token.isEmpty && Self.extractBearerToken(from: request.header("authorization")) == token
    }
    func modelProxyScope(_ request: HTTPRequest) async -> String {
        if let actor = await CoreRouter.identityActor(for: request, service: self) { return "identity:" + actor.user.id }
        let token = Self.extractBearerToken(from: request.header("authorization")) ?? ""
        return "token:" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func modelProxyRequest(_ request: SloppyInferenceRequest, scope: String) async -> SloppyInferenceRequest {
        var request = request
        if case .toolOutput? = request.transcript.last {
            let calls = request.transcript.reversed().compactMap { entry -> [String]? in
                if case .toolCalls(let calls) = entry { return calls.map(\.id) }
                return nil
            }.first ?? []
            request.replay = await modelProxyReplayCache.replay(scope: scope, model: request.model, callIDs: calls)
        }
        return request
    }
    private func proxyReplay(_ model: any LanguageModel, modelID: String) async -> SloppyInferenceReplay? {
        if let claude = model as? ClaudeCodeLanguageModel { return await claude.replayCapture.snapshot(model: modelID) }
        if let remote = model as? SloppyRemoteModel { return await remote.replayCapture.snapshot() }
        return nil
    }
    func modelProxyInference(_ request: SloppyInferenceRequest, scope: String) async throws -> SloppyInferenceResponse {
        let (model, session, capture, options) = try await prepareRemoteInference(request, allowRemoteModel: true)
        let result = try await model.respond(within: session, to: Prompt(""), generating: String.self, includeSchemaInPrompt: false, options: options)
        let replay = await proxyReplay(model, modelID: request.model)
        let calls = await capture.calls
        await modelProxyReplayCache.store(replay, scope: scope, model: request.model, callIDs: calls.map(\.id))
        return .init(text: result.content, toolCalls: calls, replay: replay)
    }

    func streamModelProxy(_ request: SloppyInferenceRequest, displayModel: String, scope: String) async throws -> AsyncStream<CoreRouterServerSentEvent> {
        let (model, session, capture, options) = try await prepareRemoteInference(request, allowRemoteModel: true)
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task<Void, Never> {
                let id = "chatcmpl-" + UUID().uuidString.lowercased()
                let created = Int(Date().timeIntervalSince1970)
                func emit(_ value: JSONValue) throws {
                    if case .dropped = continuation.yield(.init(event: "", data: try JSONEncoder().encode(value))) {
                        throw MeshModelBridge.BridgeError.invalidResponse
                    }
                }
                do {
                    try emit(OpenAIModelProxyWire.chunk(delta: ["role": .string("assistant")], model: displayModel, id: id, created: created))
                    var previous = ""
                    let stream = model.streamResponse(within: session, to: Prompt(""), generating: String.self, includeSchemaInPrompt: false, options: options)
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        guard snapshot.content.hasPrefix(previous) else { throw MeshModelBridge.BridgeError.invalidResponse }
                        let delta = String(snapshot.content.dropFirst(previous.count))
                        previous = snapshot.content
                        if !delta.isEmpty { try emit(OpenAIModelProxyWire.chunk(delta: ["content": .string(delta)], model: displayModel, id: id, created: created)) }
                    }
                    let calls = await capture.calls
                    let replay = await proxyReplay(model, modelID: request.model)
                    await modelProxyReplayCache.store(replay, scope: scope, model: request.model, callIDs: calls.map(\.id))
                    if !calls.isEmpty {
                        let wire = calls.enumerated().map { index, call -> JSONValue in
                            var object = OpenAIModelProxyWire.call(call).asObject ?? [:]
                            object["index"] = .number(Double(index))
                            return .object(object)
                        }
                        try emit(OpenAIModelProxyWire.chunk(delta: ["tool_calls": .array(wire)], model: displayModel, id: id, created: created))
                    }
                    try emit(OpenAIModelProxyWire.chunk(delta: [:], finishReason: calls.isEmpty ? "stop" : "tool_calls", model: displayModel, id: id, created: created))
                    continuation.yield(.init(event: "", data: Data("[DONE]".utf8)))
                } catch {
                    let error = JSONValue.object(["error": .object(["type": .string("server_error"), "message": .string("Model inference stopped or failed.")])])
                    if let data = try? JSONEncoder().encode(error) { continuation.yield(.init(event: "", data: data)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
