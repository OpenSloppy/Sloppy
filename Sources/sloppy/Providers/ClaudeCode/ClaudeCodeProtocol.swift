import Foundation
import AnyLanguageModel
import Protocols

enum ClaudeCodeError: Error, LocalizedError {
    case missingCLI
    case loggedOut
    case conflictingEnvironment([String])
    case invalidConfiguration
    case invalidStream
    case unsupportedReplay
    case nativeFailure(String)
    case upstream(Int)
    case timeout
    case toolUnavailable(String)
    case toolRoundLimit

    var errorDescription: String? {
        switch self {
        case .missingCLI: "Claude Code is not installed on the Sloppy server. Install the official CLI, then run claude auth login."
        case .loggedOut: "Claude Code is not signed in to a subscription on the Sloppy server. Run claude auth login there."
        case .conflictingEnvironment(let keys): "Claude Code subscription refuses auth/backend overrides: \(keys.joined(separator: ", "))."
        case .invalidConfiguration: "Claude Code subscription does not accept an API key or API URL. Configure the official CLI instead."
        case .invalidStream: "Claude Code returned an invalid or incomplete response."
        case .unsupportedReplay: "This Claude Code version does not support zero-turn history replay. Update the official CLI."
        case .nativeFailure(let code): "Claude Code failed (\(code)). Check its login, subscription limits, and CLI version."
        case .upstream(let code): "Claude Code upstream returned HTTP \(code)."
        case .timeout: "Claude Code request timed out."
        case .toolUnavailable(let name): "Claude Code requested an unavailable Sloppy tool: \(name)."
        case .toolRoundLimit: "Claude Code exceeded Sloppy's tool round limit."
        }
    }
}

extension JSONValue {
    var claudeObject: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
    var claudeArray: [JSONValue] { if case .array(let value) = self { value } else { [] } }
    var claudeString: String? { if case .string(let value) = self { value } else { nil } }
    var claudeInt: Int { if case .number(let value) = self, value.isFinite, value >= 0, value < Double(Int.max) { Int(value) } else { 0 } }
    subscript(claude key: String) -> JSONValue { claudeObject[key] ?? .null }
}

struct ClaudeCodeHistory: Sendable {
    var system: String
    var messages: [JSONValue]

    init(transcript: Transcript, names: [String: String]) throws {
        var instructions: [String] = []
        messages = []
        system = ""
        for entry in transcript {
            switch entry {
            case .instructions(let value):
                instructions.append(try Self.text(value.segments))
            case .prompt(let value):
                append(role: "user", blocks: try Self.blocks(value.segments))
            case .response(let value):
                append(role: "assistant", blocks: try Self.blocks(value.segments))
            case .toolCalls(let calls):
                append(role: "assistant", blocks: try calls.map { call in
                    let input = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.jsonString.utf8))
                    return .object(["type": .string("tool_use"), "id": .string(call.id),
                                    "name": .string(names[call.toolName] ?? call.toolName), "input": input])
                })
            case .toolOutput(let value):
                append(role: "user", blocks: [.object(["type": .string("tool_result"),
                    "tool_use_id": .string(value.id), "content": .array(try Self.blocks(value.segments))])])
            }
        }
        system = instructions.joined(separator: "\n\n")
        guard messages.last?[claude: "role"].claudeString == "user", messages.last?[claude: "content"].claudeArray.isEmpty == false else {
            throw ClaudeCodeError.invalidStream
        }
    }

    mutating func append(role: String, blocks: [JSONValue]) {
        guard !blocks.isEmpty else { return }
        if messages.last?[claude: "role"].claudeString == role {
            var last = messages.removeLast().claudeObject
            last["content"] = .array((last["content"]?.claudeArray ?? []) + blocks)
            messages.append(.object(last))
        } else { messages.append(.object(["role": .string(role), "content": .array(blocks)])) }
    }

    mutating func restoreReplay(_ native: JSONValue) throws {
        guard native[claude: "role"].claudeString == "assistant",
              let index = messages.lastIndex(where: { $0[claude: "role"].claudeString == "assistant" }),
              Self.projection(native) == Self.projection(messages[index]) else { throw ClaudeCodeError.unsupportedReplay }
        messages[index] = native
    }

    private static func projection(_ message: JSONValue) -> JSONValue {
        let blocks = message[claude: "content"].claudeArray
        let text = blocks.filter { $0[claude: "type"].claudeString == "text" }.compactMap { $0[claude: "text"].claudeString }.joined()
        let calls = blocks.filter { $0[claude: "type"].claudeString == "tool_use" }.map { block in
            JSONValue.object(["id": block[claude: "id"], "name": block[claude: "name"], "input": block[claude: "input"]])
        }
        return .object(["text": .string(text), "calls": .array(calls)])
    }

    static func text(_ segments: [Transcript.Segment]) throws -> String {
        try segments.map { segment in
            switch segment {
            case .text(let value): value.content
            case .structure(let value): value.content.jsonString
            case .image: throw ClaudeCodeError.invalidStream
            }
        }.joined(separator: "\n")
    }

    static func blocks(_ segments: [Transcript.Segment]) throws -> [JSONValue] {
        try segments.map { segment in
            switch segment {
            case .text(let value): return .object(["type": .string("text"), "text": .string(value.content)])
            case .structure(let value): return .object(["type": .string("text"), "text": .string(value.content.jsonString)])
            case .image(let image):
                let source: JSONValue
                switch image.source {
                case .data(let data, let mimeType):
                    source = .object(["type": .string("base64"), "media_type": .string(mimeType), "data": .string(data.base64EncodedString())])
                case .url(let url): source = .object(["type": .string("url"), "url": .string(url.absoluteString)])
                }
                return .object(["type": .string("image"), "source": source])
            }
        }
    }
}

/// Parse the admitted upstream stream, not the CLI's later tool-denial/retry text.
struct ClaudeCodeResponse: Sendable {
    var message: JSONValue = .object([:])
    var blocks: [Int: [String: JSONValue]] = [:]
    var inputs: [Int: String] = [:]
    var usage: [String: JSONValue] = [:]
    var complete = false
    private var started = false
    private var openBlocks: Set<Int> = []
    init() {}
    var text: String { blocks.keys.sorted().compactMap { blocks[$0]?["text"]?.claudeString }.joined() }
    var reasoning: String { blocks.keys.sorted().compactMap { blocks[$0]?["thinking"]?.claudeString }.joined() }
    var content: [JSONValue] { blocks.keys.sorted().map { .object(blocks[$0] ?? [:]) } }

    mutating func receive(_ event: JSONValue) throws {
        let index = event[claude: "index"].claudeInt
        switch event[claude: "type"].claudeString {
        case "message_start":
            guard !started else { throw ClaudeCodeError.invalidStream }
            started = true
            message = event[claude: "message"]
            usage = message[claude: "usage"].claudeObject
        case "content_block_start":
            guard started, blocks[index] == nil else { throw ClaudeCodeError.invalidStream }
            openBlocks.insert(index)
            blocks[index] = event[claude: "content_block"].claudeObject
        case "content_block_delta":
            guard blocks[index] != nil else { throw ClaudeCodeError.invalidStream }
            let delta = event[claude: "delta"]
            switch delta[claude: "type"].claudeString {
            case "text_delta": append(delta[claude: "text"].claudeString ?? "", field: "text", index: index)
            case "thinking_delta": append(delta[claude: "thinking"].claudeString ?? "", field: "thinking", index: index)
            case "signature_delta": append(delta[claude: "signature"].claudeString ?? "", field: "signature", index: index)
            case "input_json_delta": inputs[index, default: ""] += delta[claude: "partial_json"].claudeString ?? ""
            default: break
            }
        case "content_block_stop":
            guard openBlocks.remove(index) != nil else { throw ClaudeCodeError.invalidStream }
            if let json = inputs[index], !json.isEmpty {
                blocks[index]?["input"] = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            }
        case "message_delta":
            var fields = message.claudeObject
            fields.merge(event[claude: "delta"].claudeObject) { _, new in new }
            message = .object(fields)
            usage.merge(event[claude: "usage"].claudeObject) { _, new in new }
        case "message_stop":
            guard started, openBlocks.isEmpty, message[claude: "stop_reason"].claudeString != nil else { throw ClaudeCodeError.invalidStream }
            complete = true
        case "error": throw ClaudeCodeError.nativeFailure(event[claude: "error"][claude: "type"].claudeString ?? "upstream_error")
        default: break
        }
    }

    private mutating func append(_ value: String, field: String, index: Int) {
        let previous = blocks[index]?[field]?.claudeString ?? ""
        blocks[index]?[field] = .string(previous + value)
    }
}
