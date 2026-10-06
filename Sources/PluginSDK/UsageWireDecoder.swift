import Foundation
import Protocols

/// Provider wire fields, not assistant prose, define attribution.
public actor UsageWireDecoder {
    private struct Call {
        var id: String
        var tool: String
        var arguments: String
        var skill: String?
        var server: String?
        var generationObserved: Bool
    }
    private var knownCalls: [String: Call] = [:]
    private let context: ModelUsageContext
    private var provenance: UsageProvenance
    public init(context: ModelUsageContext) { self.context = context; self.provenance = context.provenance }

    public func record(requestId: String, body: Data?, response: Data, createdAt: Date,
                       failed: Bool, truncated: Bool = false) async -> UsageRequestRecord {
        if var refreshed = await context.provenanceProvider?() {
            // Catalogs can be removed while their descriptions/history remain in this session.
            for (tool, server) in context.provenance.toolServers where refreshed.toolServers[tool] == nil {
                refreshed.toolServers[tool] = server
            }
            let currentSkills = Set(refreshed.skills.map(\.id))
            refreshed.skills += context.provenance.skills.filter { !currentSkills.contains($0.id) }
            provenance = refreshed
            provenance.toolNameMap = context.provenance.toolNameMap
        }
        let channel = context.channelId
        let parts = channel.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let agent = parts.count == 4 && parts[0] == "agent" && parts[2] == "session" ? parts[1] : nil
        let session = agent == nil ? nil : parts[3]
        var record = UsageRequestRecord(id: requestId, channelId: channel, sessionId: session,
            agentId: agent, provider: context.provider, model: context.model, createdAt: createdAt,
            failed: failed, complete: !truncated)
        var measurements: [(UsageComponentKind, String?, String?, String?, String)] = []
        let input = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let input {
            var schemas = input["tools"] as? [[String: Any]] ?? []
            schemas = schemas.flatMap { ($0["functionDeclarations"] as? [[String: Any]]) ?? [$0] }
            for schema in schemas {
                let function = schema["function"] as? [String: Any] ?? schema
                guard let name = function["name"] as? String else { record.complete = false; continue }
                measurements.append((.toolSchema, tool(name), nil, nil, Self.json(schema)))
            }
            let messages = (input["input"] as? [[String: Any]]) ?? (input["messages"] as? [[String: Any]]) ?? (input["contents"] as? [[String: Any]]) ?? []
            let referenced = Self.referencedCallIds(messages)
            knownCalls = knownCalls.filter { referenced.contains($0.key) }
            // Register calls before results, including recovered history after process restart.
            for message in messages {
                if message["type"] as? String == "function_call" { register(message) }
                if message["role"] as? String == "tool", message["tool_call_id"] == nil { record.complete = false }
                if (message["tool_calls"] as? [[String: Any]] ?? []).contains(where: { $0["id"] == nil }) { record.complete = false }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    register(["id": call["id"] ?? "", "name": function["name"] ?? "", "arguments": function["arguments"] ?? ""])
                }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    register(["id": block["id"] ?? "", "name": block["name"] ?? "", "arguments": Self.json(block["input"] ?? [:])])
                }
            }
            for message in messages {
                if message["type"] as? String == "function_call", let id = message["call_id"] as? String, let call = knownCalls[id] {
                    measurements.append((.argumentsInput, call.tool, id, nil, call.arguments))
                }
                for wire in message["tool_calls"] as? [[String: Any]] ?? [] {
                    if let id = wire["id"] as? String, let call = knownCalls[id] {
                        measurements.append((.argumentsInput, call.tool, id, nil, call.arguments))
                    }
                }
                if message["type"] as? String == "function_call_output", let id = message["call_id"] as? String {
                    addResult(id: id, output: Self.text(message["output"]), media: Self.hasMedia(["content": message["output"] ?? []]), to: &measurements, record: &record)
                }
                if message["role"] as? String == "tool", let id = message["tool_call_id"] as? String {
                    addResult(id: id, output: Self.text(message["content"]), media: Self.hasMedia(message), to: &measurements, record: &record)
                }
                for block in message["content"] as? [[String: Any]] ?? [] {
                    if block["type"] as? String == "tool_use", let id = block["id"] as? String, let call = knownCalls[id] {
                        measurements.append((.argumentsInput, call.tool, id, nil, call.arguments))
                    }
                    if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                        addResult(id: id, output: Self.text(block["content"]), isError: block["is_error"] as? Bool,
                                  media: Self.hasMedia(["content": block["content"] ?? []]), to: &measurements, record: &record)
                    }
                }
                // Gemini does not preserve tool-call IDs on the wire; don't fabricate a link.
                for part in message["parts"] as? [[String: Any]] ?? [] {
                    if part["functionCall"] != nil || part["functionResponse"] != nil { record.complete = false }
                    if part["inlineData"] != nil || part["fileData"] != nil { record.complete = false }
                }
                if Self.hasMedia(message) { record.complete = false }
            }
            let instructionText = Self.text(input["instructions"]) + "\n" + Self.text(input["system"]) + "\n" + messages.map { Self.text($0["content"]) }.joined(separator: "\n")
            for skill in provenance.skills where !skill.catalogEntry.isEmpty {
                let occurrences = instructionText.components(separatedBy: skill.catalogEntry).count - 1
                for _ in 0..<occurrences { measurements.append((.skillCatalog, nil, nil, skill.id, skill.catalogEntry)) }
            }
            if input["previous_response_id"] != nil || input["conversation"] != nil { record.complete = false }
        } else { record.complete = false }

        let decoded = Self.responseObjects(response)
        var generated: [String: [String: Any]] = [:]
        var chatDeltas: [Int: (id: String, name: String, arguments: String)] = [:]
        var anthropicDeltas: [Int: (id: String, name: String, arguments: String)] = [:]
        var inputTokens: Int?, outputTokens: Int?, cached = 0, creation = 0, reasoning = 0
        var cacheIsSeparateInput = false
        for event in decoded {
            let object = event["response"] as? [String: Any] ?? event
            if ["error", "response.failed"].contains(event["type"] as? String ?? "") || object["error"] != nil { record.failed = true }
            if let message = object["message"] as? [String: Any],
               !(message["tool_calls"] as? [[String: Any]] ?? []).isEmpty { record.complete = false }
            let usage = object["usage"] as? [String: Any] ?? (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            if let usage {
                if usage["cache_read_input_tokens"] != nil || usage["cache_creation_input_tokens"] != nil { cacheIsSeparateInput = true }
                if let value = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int { inputTokens = value }
                if let value = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int { outputTokens = value }
                let details = usage["input_tokens_details"] as? [String: Any] ?? usage["prompt_tokens_details"] as? [String: Any] ?? [:]
                cached = usage["cache_read_input_tokens"] as? Int ?? details["cached_tokens"] as? Int ?? cached
                creation = usage["cache_creation_input_tokens"] as? Int ?? details["cache_write_tokens"] as? Int ?? creation
                let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? usage["completion_tokens_details"] as? [String: Any] ?? [:]
                reasoning = outputDetails["reasoning_tokens"] as? Int ?? reasoning
            }
            if (object["candidates"] as? [[String: Any]] ?? []).contains(where: { candidate in
                let content = candidate["content"] as? [String: Any] ?? [:]
                return (content["parts"] as? [[String: Any]] ?? []).contains { $0["functionCall"] != nil }
            }) { record.complete = false }
            let gemini = object["usageMetadata"] as? [String: Any]
            if let gemini {
                inputTokens = gemini["promptTokenCount"] as? Int
                outputTokens = (gemini["candidatesTokenCount"] as? Int ?? 0) + (gemini["thoughtsTokenCount"] as? Int ?? 0)
                cached = gemini["cachedContentTokenCount"] as? Int ?? 0
                reasoning = gemini["thoughtsTokenCount"] as? Int ?? 0
            }
            if let prompt = object["prompt_eval_count"] as? Int, let completion = object["eval_count"] as? Int {
                inputTokens = prompt; outputTokens = completion
            }
            for output in object["output"] as? [[String: Any]] ?? [] where output["type"] as? String == "function_call" {
                if let id = output["call_id"] as? String { generated[id] = output }
            }
            if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call", let id = item["call_id"] as? String {
                generated[id] = item
            }
            for block in object["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                if let id = block["id"] as? String {
                    generated[id] = ["id": id, "name": block["name"] ?? "", "arguments": Self.json(block["input"] ?? [:])]
                }
            }
            if event["type"] as? String == "content_block_start", let index = event["index"] as? Int,
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                anthropicDeltas[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
            }
            if let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any], let text = delta["partial_json"] as? String {
                anthropicDeltas[index]?.arguments += text
            }
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                let message = choice["message"] as? [String: Any] ?? choice["delta"] as? [String: Any] ?? [:]
                for wire in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = wire["function"] as? [String: Any] ?? [:]
                    let index = wire["index"] as? Int ?? generated.count
                    if choice["message"] != nil, let id = wire["id"] as? String {
                        generated[id] = ["id": id, "name": function["name"] ?? "", "arguments": function["arguments"] ?? ""]
                    } else {
                        var value = chatDeltas[index] ?? ("", "", "")
                        value.id += wire["id"] as? String ?? ""
                        value.name += function["name"] as? String ?? ""
                        value.arguments += function["arguments"] as? String ?? ""
                        chatDeltas[index] = value
                    }
                }
            }
        }
        for value in Array(chatDeltas.values) + Array(anthropicDeltas.values) where !value.id.isEmpty {
            generated[value.id] = ["id": value.id, "name": value.name, "arguments": value.arguments]
        }
        for (id, wire) in generated.sorted(by: { $0.key < $1.key }) {
            register(wire)
            knownCalls[id]?.generationObserved = true
            guard let call = knownCalls[id] else { record.complete = false; continue }
            record.calls.append(callRecord(call, requestId: requestId, date: createdAt))
            measurements.append((.argumentsOutput, call.tool, id, nil, call.arguments))
        }
        if let prompt = inputTokens, let completion = outputTokens {
            record.usage = TokenUsage(prompt: prompt + (cacheIsSeparateInput ? cached + creation : 0), completion: completion,
                cachedInputTokens: cached, cacheCreationInputTokens: creation, reasoningTokens: reasoning)
        }
        if record.usage == nil { record.complete = false }
        for (kind, tool, callID, skill, text) in measurements {
            let count = await UsageTokenCounter.shared.count(text, model: context.model)
            var component = UsageComponentRecord(requestId: requestId, toolCallId: callID, tool: tool,
                serverId: callID.flatMap { knownCalls[$0]?.server } ?? tool.flatMap { provenance.toolServers[$0] }, skillId: skill,
                kind: kind, tokens: count.tokens, method: count.method, encoding: count.encoding)
            if kind == .resultInput, let callID, knownCalls[callID]?.generationObserved == false {
                // Input-only calls belong to restored history, not a newly observed generation.
                component.repeated = true
                record.complete = false
            }
            record.components.append(component)
        }
        return record
    }

    private func tool(_ name: String) -> String { provenance.toolNameMap[name] ?? name }
    private func register(_ wire: [String: Any]) {
        guard let id = wire["call_id"] as? String ?? wire["id"] as? String, !id.isEmpty,
              let name = wire["name"] as? String, !name.isEmpty else { return }
        let args = wire["arguments"] as? String ?? Self.json(wire["arguments"] ?? [:])
        var resolved = tool(name)
        let object = args.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let previous = knownCalls[id]
        var server = previous?.server ?? provenance.toolServers[resolved]
        if resolved == "mcp.call_tool", let serverId = object?["server"] as? String, let toolName = object?["tool"] as? String {
            server = serverId
            resolved = "mcp.\(serverId).\(toolName)"
        }
        let path = object?["path"] as? String
        let skill = previous?.skill ?? (resolved == "files.read" ? path.flatMap { self.skill(for: $0) } : nil)
        knownCalls[id] = Call(id: id, tool: resolved, arguments: args, skill: skill, server: server, generationObserved: previous?.generationObserved ?? false)
    }
    private func skill(for path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return provenance.skills.first {
            let root = URL(fileURLWithPath: $0.directory).resolvingSymlinksInPath().standardizedFileURL.path
            return file.hasPrefix(root + "/")
        }?.id
    }
    private func callRecord(_ call: Call, requestId: String, date: Date, ok: Bool? = nil) -> UsageToolCallRecord {
        let parts = context.channelId.split(separator: ":").map(String.init)
        let isSession = parts.count == 4 && parts[0] == "agent" && parts[2] == "session"
        return .init(id: call.id, requestId: requestId, channelId: context.channelId,
            sessionId: isSession ? parts[3] : nil, agentId: isSession ? parts[1] : nil,
            tool: call.tool, serverId: call.server, skillId: call.skill, ok: ok, createdAt: date)
    }
    private func addResult(id: String, output: String, isError: Bool? = nil, media: Bool = false,
                           to measurements: inout [(UsageComponentKind, String?, String?, String?, String)], record: inout UsageRequestRecord) {
        guard let call = knownCalls[id] else { record.complete = false; return }
        let payload = output.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let ok = isError.map { !$0 } ?? payload?["ok"] as? Bool
        var effectiveCall = call
        let data = payload?["data"] as? [String: Any]
        if call.tool == "files.read", let path = data?["path"] as? String { effectiveCall.skill = skill(for: path) }
        if ok == false { effectiveCall.skill = nil }
        var outcome = callRecord(effectiveCall, requestId: record.id, date: record.createdAt, ok: ok)
        outcome.generated = false
        record.calls.append(outcome)
        measurements.append((.resultInput, call.tool, id, effectiveCall.skill, output))
        if media {
            record.complete = false
            record.components.append(.init(requestId: record.id, toolCallId: id, tool: call.tool,
                serverId: call.server, skillId: effectiveCall.skill, kind: .resultInput, tokens: nil, method: .unavailable))
        }
    }
    private static func referencedCallIds(_ value: Any) -> Set<String> {
        if let objects = value as? [Any] { return objects.reduce(into: Set<String>()) { $0.formUnion(referencedCallIds($1)) } }
        guard let object = value as? [String: Any] else { return [] }
        var ids = Set(["id", "call_id", "tool_call_id", "tool_use_id"].compactMap { object[$0] as? String })
        for value in object.values { ids.formUnion(referencedCallIds(value)) }
        return ids
    }
    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
    private static func hasMedia(_ message: [String: Any]) -> Bool {
        (message["content"] as? [[String: Any]] ?? []).contains {
            ["image", "image_url", "input_image", "input_audio", "audio", "document", "input_file"].contains($0["type"] as? String ?? "")
        }
    }
    private static func responseObjects(_ data: Data) -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return [object] }
        if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return objects }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.hasPrefix("data:") ? line.dropFirst(5).trimmingCharacters(in: .whitespaces) : String(line)
            return value.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }
}
