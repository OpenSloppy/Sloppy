import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import Protocols

/// Versioned inference transport. Tools always execute on the requesting server.
public struct SloppyInferenceRequest: Codable, Sendable {
    public var model: String
    public var transcript: Transcript
    public var tools: [SloppyInferenceToolDefinition]
    public var options: GenerationOptions
    public var reasoningEffort: ReasoningEffort?
    public var stream: Bool?
    public var replay: SloppyInferenceReplay?

    public init(model: String, transcript: Transcript, tools: [SloppyInferenceToolDefinition], options: GenerationOptions, reasoningEffort: ReasoningEffort? = nil, stream: Bool = false, replay: SloppyInferenceReplay? = nil) {
        self.model = model
        self.transcript = transcript
        self.tools = tools
        self.options = options
        self.reasoningEffort = reasoningEffort
        self.stream = stream
        self.replay = replay
    }
}

public struct SloppyInferenceToolDefinition: Codable, Sendable {
    public var name: String
    public var description: String
    public var parameters: GenerationSchema

    public init(tool: some Tool) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
    }

    public init(name: String, description: String, parameters: GenerationSchema) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

/// One remote generation; the requesting host owns all tool execution.
public typealias SloppyInferenceTransport = @Sendable (SloppyInferenceRequest, (@Sendable (SloppyInferenceResponse) -> Void)?) async throws -> SloppyInferenceResponse

public enum SloppyRelayEndpoint {
    public static func isRelay(_ value: String) -> Bool { value.lowercased().hasPrefix("sloppy-relay:") }
    public static func nodeID(_ value: String) throws -> String {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "sloppy-relay", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw SloppyRemoteError.invalidURL }
        return host
    }
}

public struct SloppyInferenceResponse: Codable, Sendable {
    public var text: String
    public var toolCalls: [Transcript.ToolCall]
    public var replay: SloppyInferenceReplay?

    public init(text: String, toolCalls: [Transcript.ToolCall], replay: SloppyInferenceReplay? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.replay = replay
    }
}

/// Opaque provider state, bound to its visible projection. Never contains auth.
public struct SloppyInferenceReplay: Codable, Sendable {
    public var provider: String
    public var model: String
    public var message: Protocols.JSONValue
    public init(provider: String, model: String, message: Protocols.JSONValue) {
        self.provider = provider; self.model = model; self.message = message
    }
}

public actor SloppyInferenceReplayCapture {
    private var replay: SloppyInferenceReplay?
    public init() {}
    public func store(_ value: SloppyInferenceReplay?) { replay = value }
    public func snapshot() -> SloppyInferenceReplay? { replay }
}

public enum SloppyRemoteError: Error, LocalizedError {
    case invalidURL
    case http(Int)
    case unknownModel
    case toolUnavailable(String)
    case toolLoopLimit

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid Sloppy server URL (http or https)."
        case .http(let status): "Sloppy server returned HTTP \(status). Check the address, access token, and server version."
        case .unknownModel: "The requested model is not available for remote inference on this Sloppy server."
        case .toolUnavailable(let name): "Tool \(name) is not available on the requesting server."
        case .toolLoopLimit: "Sloppy remote inference exceeded the tool round limit."
        }
    }
}

public enum SloppyRemoteEndpoint {
    public static func url(base: String, path: String) throws -> URL {
        guard var url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw SloppyRemoteError.invalidURL }
        if url.lastPathComponent == "v1" { url.deleteLastPathComponent() }
        return url.appendingPathComponent("v1").appendingPathComponent(path)
    }
}

public struct SloppyRemoteModel: LanguageModel {
    public typealias UnavailableReason = Never
    public struct CustomGenerationOptions: AnyLanguageModel.CustomGenerationOptions {
        public var reasoningEffort: ReasoningEffort?
        public init(reasoningEffort: ReasoningEffort?) { self.reasoningEffort = reasoningEffort }
    }
    public let baseURL: String
    public let accessToken: String
    public let model: String
    public let httpSession: URLSession
    private let inferenceTransport: SloppyInferenceTransport?
    public var replaySeed: SloppyInferenceReplay?
    public let replayCapture = SloppyInferenceReplayCapture()

    public init(baseURL: String, accessToken: String, model: String, session: URLSession = .shared, inferenceTransport: SloppyInferenceTransport? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.model = model
        self.httpSession = session
        self.inferenceTransport = inferenceTransport
    }

    public func respond<Content: Generable>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        try await generate(within: session, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    private func generate<Content: Generable>(
        within session: LanguageModelSession, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LanguageModelSession.Response<Content> {
        var transcript = Array(session.transcript)
        var entries: [Transcript.Entry] = []
        var replay = replaySeed
        let definitions = session.tools.map { SloppyInferenceToolDefinition(tool: $0) }
        if type != String.self, includeSchemaInPrompt {
            let schema = String(decoding: try JSONEncoder().encode(type.generationSchema), as: UTF8.self)
            transcript.append(.instructions(.init(
                segments: [.text(.init(content: "Return JSON matching this schema: \(schema)"))],
                toolDefinitions: []
            )))
        }
        for _ in 0..<64 {
            try Task.checkCancellation()
            let payload = SloppyInferenceRequest(model: model, transcript: Transcript(entries: transcript), tools: definitions, options: options,
                reasoningEffort: options[custom: SloppyRemoteModel.self]?.reasoningEffort, stream: onText != nil, replay: replay)
            let result: SloppyInferenceResponse
            if let inferenceTransport {
                let callback: (@Sendable (SloppyInferenceResponse) -> Void)?
                if let onText { callback = { onText($0.text) } } else { callback = nil }
                result = try await inferenceTransport(payload, callback)
            } else {
                var request = URLRequest(url: try SloppyRemoteEndpoint.url(base: baseURL, path: "providers/inference"))
                request.httpMethod = "POST"
                request.timeoutInterval = 300
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
                request.httpBody = try JSONEncoder().encode(payload)
                if let onText {
                    result = try await streamingRequest(request, onText: onText)
                } else {
                    let (data, response) = try await httpSession.data(for: request)
                    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard response.statusCode == 200 else { throw SloppyRemoteError.http(response.statusCode) }
                    result = try JSONDecoder().decode(SloppyInferenceResponse.self, from: data)
                }
            }
            replay = result.replay
            await replayCapture.store(result.replay)
            if result.toolCalls.isEmpty {
                let raw = type == String.self ? GeneratedContent(result.text) : try GeneratedContent(json: result.text)
                return .init(content: try type.init(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
            }
            if !result.text.isEmpty {
                let entry = Transcript.Entry.response(.init(assetIDs: [], segments: [.text(.init(content: result.text))]))
                entries.append(entry); transcript.append(entry)
            }
            let calls = Transcript.Entry.toolCalls(.init(result.toolCalls))
            entries.append(calls)
            transcript.append(calls)
            await session.toolExecutionDelegate?.didGenerateToolCalls(result.toolCalls, in: session)
            for call in result.toolCalls {
                let decision = await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session) ?? .execute
                let segments: [Transcript.Segment]
                switch decision {
                case .stop:
                    let raw = type == String.self ? GeneratedContent("") : try GeneratedContent(json: "{}")
                    return .init(content: try type.init(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
                case .provideOutput(let output): segments = output
                case .execute:
                    guard let tool = session.tools.first(where: { $0.name == call.toolName }) else {
                        throw SloppyRemoteError.toolUnavailable(call.toolName)
                    }
                    do { segments = try await execute(tool, arguments: call.arguments) }
                    catch {
                        await session.toolExecutionDelegate?.didFailToolCall(call, error: error, in: session)
                        throw error
                    }
                }
                let output = Transcript.ToolOutput(id: call.id, toolName: call.toolName, segments: segments)
                entries.append(.toolOutput(output))
                transcript.append(.toolOutput(output))
                await session.toolExecutionDelegate?.didExecuteToolCall(call, output: output, in: session)
            }
        }
        throw SloppyRemoteError.toolLoopLimit
    }

    public func streamResponse<Content: Generable>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    let onText: @Sendable (String) -> Void = { text in
                        if let snapshot = partialSnapshot(text, generating: type) {
                            continuation.yield(snapshot)
                        }
                    }
                    let response = try await generate(within: session, generating: type,
                                                      includeSchemaInPrompt: includeSchemaInPrompt,
                                                      options: options, onText: onText)
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }

    private func partialSnapshot<Content: Generable>(_ text: String, generating type: Content.Type) -> LanguageModelSession.ResponseStream<Content>.Snapshot? {
        do {
            let raw: GeneratedContent
            if type == String.self { raw = GeneratedContent(text) }
            else { raw = try GeneratedContent(json: text) }
            let content = try Content.PartiallyGenerated(raw)
            return .init(content: content, rawContent: raw)
        } catch { return nil }
    }

    private func streamingRequest(_ request: URLRequest, onText: @Sendable (String) -> Void) async throws -> SloppyInferenceResponse {
        #if canImport(FoundationNetworking)
        let (bytes, response) = try await httpSession.linuxBytes(for: request)
        #else
        let (bytes, response) = try await httpSession.bytes(for: request)
        #endif
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else { throw SloppyRemoteError.http(response.statusCode) }
        var event = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                guard event != "error" else { throw SloppyRemoteError.http(502) }
                let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                let snapshot = try JSONDecoder().decode(SloppyInferenceResponse.self, from: data)
                if event == "complete" { return snapshot }
                if event == "snapshot" { onText(snapshot.text) }
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private func execute<T: Tool>(_ tool: T, arguments: GeneratedContent) async throws -> [Transcript.Segment] {
        let output = try await tool.call(arguments: T.Arguments(arguments))
        if let structured = output as? any ConvertibleToGeneratedContent {
            return [.structure(.init(source: tool.name, content: structured.generatedContent))]
        }
        return [.text(.init(content: output.promptRepresentation.description))]
    }
}
