import Foundation
import AnyLanguageModel
import PluginSDK
import Protocols

/// Claude Code supplies only generations. Sloppy owns history, tool dispatch,
/// approvals, compaction, cancellation, and every follow-up request.
struct ClaudeCodeLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    struct CustomGenerationOptions: AnyLanguageModel.CustomGenerationOptions {
        var effort: String?
    }
    typealias Generate = @Sendable (ClaudeCodeHistory, [String: JSONValue], String?, (@Sendable (String) -> Void)?) async throws -> ClaudeCodeResponse

    let generate: Generate
    let reasoningCapture: ReasoningContentCapture
    let tokenUsageCapture: TokenUsageCapture
    var captureFallbackUsage = true
    var replaySeed: SloppyInferenceReplay?
    let replayCapture = ClaudeCodeReplayCapture()

    func respond<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> {
        try await run(session: session, type: type, options: options)
    }

    func streamResponse<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    let onText: @Sendable (String) -> Void = { text in
                        if let snapshot = partialSnapshot(text, type: type) { continuation.yield(snapshot) }
                    }
                    let response = try await run(session: session, type: type, options: options, onText: onText)
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(stream: stream)
    }

    private func partialSnapshot<Content: Generable>(_ text: String, type: Content.Type) -> LanguageModelSession.ResponseStream<Content>.Snapshot? {
        do {
            let raw: GeneratedContent
            if type == String.self { raw = GeneratedContent(text) } else { raw = try GeneratedContent(json: text) }
            return .init(content: try Content.PartiallyGenerated(raw), rawContent: raw)
        } catch { return nil }
    }

    private func run<Content: Generable>(session: LanguageModelSession, type: Content.Type, options: GenerationOptions,
        onText: (@Sendable (String) -> Void)? = nil) async throws -> LanguageModelSession.Response<Content> {
        let names = Dictionary(uniqueKeysWithValues: session.tools.map { ($0.name, $0.name) })
        var history = try ClaudeCodeHistory(transcript: session.transcript, names: names)
        if let replaySeed { try history.restoreReplay(replaySeed.message) }
        var body: [String: JSONValue] = ["max_tokens": .number(Double(max(1, options.maximumResponseTokens ?? 4096)))]
        let definitions: [JSONValue] = try session.tools.map { tool in
            let schema = ModelToolSchemaNormalizer.providerSafeObjectSchema(tool.parameters)
            let input = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: schema))
            return .object(["name": .string(tool.name), "description": .string(tool.description), "input_schema": input])
        }
        // Override the empty native inventory even for requests without tools.
        body["tools"] = .array(definitions)
        if type != String.self {
            let schema = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(type.generationSchema))
            body["output_config"] = .object(["format": .object(["type": .string("json_schema"), "schema": schema])])
        }
        let effort = options[custom: ClaudeCodeLanguageModel.self]?.effort
        var entries: [Transcript.Entry] = []
        var priorText = ""
        for _ in 0..<64 {
            try Task.checkCancellation()
            let prefix = priorText
            let callback: (@Sendable (String) -> Void)?
            if let onText { callback = { text in onText(prefix + text) } } else { callback = nil }
            let response = try await generate(history, body, effort, callback)
            await replayCapture.store(.object(["role": .string("assistant"), "content": .array(response.content)]))
            reasoningCapture.append(response.reasoning)
            let cached = response.usage["cache_read_input_tokens"]?.claudeInt ?? 0
            let created = response.usage["cache_creation_input_tokens"]?.claudeInt ?? 0
            if captureFallbackUsage {
                tokenUsageCapture.store(promptTokens: (response.usage["input_tokens"]?.claudeInt ?? 0) + cached + created,
                    completionTokens: response.usage["output_tokens"]?.claudeInt ?? 0,
                    cachedInputTokens: cached, cacheCreationInputTokens: created,
                    requestId: response.message[claude: "id"].claudeString ?? UUID().uuidString)
            }
            let calls: [Transcript.ToolCall] = try response.content.compactMap { block -> Transcript.ToolCall? in
                guard block[claude: "type"].claudeString == "tool_use" else { return nil }
                guard let name = block[claude: "name"].claudeString, names[name] != nil,
                      let id = block[claude: "id"].claudeString, !id.isEmpty,
                      case .object = block[claude: "input"] else { throw ClaudeCodeError.toolUnavailable(block[claude: "name"].claudeString ?? "unknown") }
                let json = String(decoding: try JSONEncoder().encode(block[claude: "input"]), as: UTF8.self)
                return .init(id: id, toolName: name, arguments: try GeneratedContent(json: json))
            }
            if calls.isEmpty {
                let text = priorText + response.text
                let raw = type == String.self ? GeneratedContent(text) : try GeneratedContent(json: response.text)
                return .init(content: try Content(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
            }
            if !response.text.isEmpty {
                priorText += response.text
            }
            // Preserve signed thinking and all native blocks across tool rounds.
            history.append(role: "assistant", blocks: response.content)
            entries.append(.toolCalls(.init(calls)))
            await session.toolExecutionDelegate?.didGenerateToolCalls(calls, in: session)
            for call in calls {
                try Task.checkCancellation()
                let decision = await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session) ?? .execute
                let segments: [Transcript.Segment]
                switch decision {
                case .stop:
                    let raw = type == String.self ? GeneratedContent(priorText) : try GeneratedContent(json: "{}")
                    return .init(content: try Content(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
                case .provideOutput(let output): segments = output
                case .execute:
                    guard let tool = session.tools.first(where: { $0.name == call.toolName }) else { throw ClaudeCodeError.toolUnavailable(call.toolName) }
                    do { segments = try await execute(tool, arguments: call.arguments) }
                    catch {
                        await session.toolExecutionDelegate?.didFailToolCall(call, error: error, in: session)
                        throw error
                    }
                }
                let output = Transcript.ToolOutput(id: call.id, toolName: call.toolName, segments: segments)
                entries.append(.toolOutput(output))
                history.append(role: "user", blocks: [.object(["type": .string("tool_result"),
                    "tool_use_id": .string(call.id), "content": .array(try ClaudeCodeHistory.blocks(segments))])])
                await session.toolExecutionDelegate?.didExecuteToolCall(call, output: output, in: session)
            }
        }
        throw ClaudeCodeError.toolRoundLimit
    }

    private func execute<T: Tool>(_ tool: T, arguments: GeneratedContent) async throws -> [Transcript.Segment] {
        let result = try await tool.call(arguments: T.Arguments(arguments))
        if let structured = result as? any ConvertibleToGeneratedContent {
            return [.structure(.init(source: tool.name, content: structured.generatedContent))]
        }
        return [.text(.init(content: result.promptRepresentation.description))]
    }
}

actor ClaudeCodeReplayCapture {
    private var message: JSONValue?
    func store(_ value: JSONValue) { message = value }
    func snapshot(model: String) -> SloppyInferenceReplay? {
        message.map { .init(provider: "claude-code", model: model, message: $0) }
    }
}
