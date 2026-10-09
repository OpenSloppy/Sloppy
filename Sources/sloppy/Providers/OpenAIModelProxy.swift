import Foundation
import AnyLanguageModel
import PluginSDK
import Protocols

struct OpenAIModelProxyRequest: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        struct Call: Decodable, Sendable {
            struct Function: Decodable, Sendable { var name: String; var arguments: String }
            var id: String; var function: Function
        }
        var role: String
        var content: JSONValue?
        var tool_calls: [Call]?
        var tool_call_id: String?
    }
    struct FunctionTool: Decodable, Sendable {
        struct Definition: Decodable, Sendable { var name: String; var description: String?; var parameters: JSONValue }
        var type: String; var function: Definition
    }
    var model: String
    var messages: [Message]
    var tools: [FunctionTool]?
    var stream: Bool?
    var max_tokens: Int?
    var max_completion_tokens: Int?
    var temperature: Double?
    var reasoning_effort: ReasoningEffort?
    var tool_choice: JSONValue?

    func inference(modelID: String) throws -> SloppyInferenceRequest {
        guard !messages.isEmpty, ["user", "tool"].contains(messages.last?.role ?? ""),
              (max_completion_tokens ?? max_tokens ?? 8192) > 0,
              tool_choice == nil || tool_choice == .string("auto") else { throw SloppyRemoteError.invalidURL }
        if let temperature, !temperature.isFinite || !(0...1).contains(temperature) { throw SloppyRemoteError.invalidURL }
        var entries: [Transcript.Entry] = []
        for message in messages {
            let segments = try Self.segments(message.content)
            switch message.role {
            case "system", "developer": entries.append(.instructions(.init(segments: segments, toolDefinitions: [])))
            case "user": entries.append(.prompt(.init(segments: segments)))
            case "assistant":
                if !segments.isEmpty { entries.append(.response(.init(assetIDs: [], segments: segments))) }
                if let calls = message.tool_calls, !calls.isEmpty {
                    entries.append(.toolCalls(.init(try calls.map { .init(id: $0.id, toolName: $0.function.name,
                        arguments: try GeneratedContent(json: $0.function.arguments)) })))
                }
            case "tool":
                guard let id = message.tool_call_id, !id.isEmpty else { throw SloppyRemoteError.invalidURL }
                entries.append(.toolOutput(.init(id: id, toolName: "", segments: segments)))
            default: throw SloppyRemoteError.invalidURL
            }
        }
        let definitions = try (tools ?? []).map { tool in
            guard tool.type == "function", !tool.function.name.isEmpty else { throw SloppyRemoteError.invalidURL }
            return SloppyInferenceToolDefinition(name: tool.function.name, description: tool.function.description ?? "",
                parameters: try JSONDecoder().decode(GenerationSchema.self, from: JSONEncoder().encode(tool.function.parameters)))
        }
        return .init(model: modelID, transcript: .init(entries: entries), tools: definitions,
            options: .init(temperature: temperature, maximumResponseTokens: min(32_000, max_completion_tokens ?? max_tokens ?? 8192)),
            reasoningEffort: reasoning_effort, stream: stream == true)
    }

    private static func segments(_ value: JSONValue?) throws -> [Transcript.Segment] {
        guard let value, value != .null else { return [] }
        if let text = value.asString { return [.text(.init(content: text))] }
        guard let parts = value.asArray else { throw SloppyRemoteError.invalidURL }
        return try parts.map { part in
            guard let object = part.asObject else { throw SloppyRemoteError.invalidURL }
            if object["type"]?.asString == "text", let text = object["text"]?.asString { return .text(.init(content: text)) }
            guard object["type"]?.asString == "image_url", let raw = object["image_url"]?.asObject?["url"]?.asString else { throw SloppyRemoteError.invalidURL }
            if raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ",") {
                let header = String(raw[..<comma])
                guard header.hasSuffix(";base64"), let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) else { throw SloppyRemoteError.invalidURL }
                return .image(.init(data: data, mimeType: String(header.dropFirst(5).dropLast(7))))
            }
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else { throw SloppyRemoteError.invalidURL }
            return .image(.init(url: url))
        }
    }
}

enum OpenAIModelProxyWire {
    static func error(_ message: String, type: String = "invalid_request_error") -> JSONValue {
        .object(["error": .object(["message": .string(message), "type": .string(type), "code": .null, "param": .null])])
    }
    static func response(_ response: SloppyInferenceResponse, model: String, id: String, created: Int) -> JSONValue {
        var message: [String: JSONValue] = ["role": .string("assistant"), "content": .string(response.text)]
        if !response.toolCalls.isEmpty { message["tool_calls"] = .array(response.toolCalls.map(call)) }
        return .object(["id": .string(id), "object": .string("chat.completion"), "created": .number(Double(created)), "model": .string(model),
            "choices": .array([.object(["index": .number(0), "message": .object(message), "finish_reason": .string(response.toolCalls.isEmpty ? "stop" : "tool_calls")])])])
    }
    static func chunk(delta: [String: JSONValue], finishReason: String? = nil, model: String, id: String, created: Int) -> JSONValue {
        .object(["id": .string(id), "object": .string("chat.completion.chunk"), "created": .number(Double(created)), "model": .string(model),
            "choices": .array([.object(["index": .number(0), "delta": .object(delta), "finish_reason": finishReason.map(JSONValue.string) ?? .null])])])
    }
    static func call(_ call: Transcript.ToolCall) -> JSONValue {
        .object(["id": .string(call.id), "type": .string("function"),
                 "function": .object(["name": .string(call.toolName), "arguments": .string(call.arguments.jsonString)])])
    }
}
