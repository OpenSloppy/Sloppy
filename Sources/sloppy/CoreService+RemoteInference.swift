import Foundation
import AnyLanguageModel
import PluginSDK

extension CoreService {
    func remoteInference(_ request: SloppyInferenceRequest) async throws -> SloppyInferenceResponse {
        let (model, session, capture, options) = try await prepareRemoteInference(request)
        let result = try await model.respond(within: session, to: Prompt(""), generating: String.self,
                                             includeSchemaInPrompt: false, options: options)
        let replay = await (model as? ClaudeCodeLanguageModel)?.replayCapture.snapshot(model: request.model)
        return await SloppyInferenceResponse(text: result.content, toolCalls: capture.calls, replay: replay)
    }

    func streamRemoteInference(_ request: SloppyInferenceRequest) async throws -> AsyncStream<CoreRouterServerSentEvent> {
        let (model, session, capture, options) = try await prepareRemoteInference(request)
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                do {
                    var text = ""
                    let stream = model.streamResponse(within: session, to: Prompt(""), generating: String.self,
                                                       includeSchemaInPrompt: false, options: options)
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        text = snapshot.content
                        let data = try JSONEncoder().encode(SloppyInferenceResponse(text: text, toolCalls: []))
                        continuation.yield(.init(event: "snapshot", data: data))
                    }
                    let replay = await (model as? ClaudeCodeLanguageModel)?.replayCapture.snapshot(model: request.model)
                    let result = await SloppyInferenceResponse(text: text, toolCalls: capture.calls, replay: replay)
                    continuation.yield(.init(event: "complete", data: try JSONEncoder().encode(result)))
                } catch {
                    continuation.yield(.init(event: "error", data: Data("{\"error\":\"remote_inference_failed\"}".utf8)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func prepareRemoteInference(_ request: SloppyInferenceRequest, allowRemoteModel: Bool = false) async throws -> (
        any LanguageModel, LanguageModelSession, RemoteInferenceToolCapture, GenerationOptions
    ) {
        // Only configured local models may be exposed; remote-to-remote forwarding would allow cycles.
        guard (allowRemoteModel || !request.model.hasPrefix("sloppy:")),
              listAvailableProviderModels().contains(where: { $0.id == request.model }),
              let provider = modelProvider, provider.supports(modelName: request.model) else {
            throw SloppyRemoteError.unknownModel
        }
        var model = try await provider.createLanguageModel(for: request.model)
        if let replay = request.replay {
            if var remote = model as? SloppyRemoteModel, allowRemoteModel {
                remote.replaySeed = replay
                model = remote
            } else {
                guard replay.provider == "claude-code", replay.model == request.model,
                      var claude = model as? ClaudeCodeLanguageModel else { throw SloppyRemoteError.unknownModel }
                claude.replaySeed = replay
                model = claude
            }
        }
        var options = provider.generationOptions(for: request.model,
                                                 maxTokens: request.options.maximumResponseTokens ?? 8192,
                                                 reasoningEffort: request.reasoningEffort)
        options.temperature = request.options.temperature
        options.sampling = request.options.sampling
        let capture = RemoteInferenceToolCapture()
        let session = LanguageModelSession(model: model, tools: request.tools.map(RemoteInferenceTool.init), transcript: request.transcript)
        session.toolExecutionDelegate = capture
        return (model, session, capture, options)
    }
}

actor RemoteInferenceToolCapture: ToolExecutionDelegate {
    var calls: [Transcript.ToolCall] = []
    func didGenerateToolCalls(_ toolCalls: [Transcript.ToolCall], in session: LanguageModelSession) {
        calls = toolCalls
    }
    func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) -> ToolExecutionDecision { .stop }
}

private struct RemoteInferenceTool: Tool {
    let definition: SloppyInferenceToolDefinition
    var name: String { definition.name }
    var description: String { definition.description }
    var parameters: GenerationSchema { definition.parameters }

    init(_ definition: SloppyInferenceToolDefinition) { self.definition = definition }

    func call(arguments: GeneratedContent) async throws -> String {
        throw SloppyRemoteError.toolUnavailable(name)
    }
}
