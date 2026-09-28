import AnyLanguageModel
import Foundation
import Protocols

public enum AgentSessionTranscriptBuilder {
    public static func buildRecoveryTranscript(
        current detail: AgentSessionDetail,
        source sourceDetail: AgentSessionDetail? = nil
    ) -> Transcript {
        var entries: [Transcript.Entry] = []
        if let sourceDetail, sourceDetail.summary.id != detail.summary.id {
            entries.append(contentsOf: transcriptEntries(from: sourceDetail))
        }
        entries.append(contentsOf: transcriptEntries(from: detail))
        return Transcript(entries: entries)
    }

    public static func hasRecoverableEntries(_ transcript: Transcript) -> Bool {
        transcript.contains { entry in
            switch entry {
            case .prompt, .response, .toolCalls, .toolOutput:
                return true
            case .instructions:
                return false
            }
        }
    }

    private static func transcriptEntries(from detail: AgentSessionDetail) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        var pendingToolCallIDsByTool: [String: [String]] = [:]
        var pendingToolCallEntryIndicesByID: [String: Int] = [:]

        for event in detail.events {
            switch event.type {
            case .message:
                guard let message = event.message,
                      let text = transcriptText(from: message),
                      !text.isEmpty
                else {
                    continue
                }

                switch message.role {
                case .user:
                    entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: text))])))
                case .assistant:
                    entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))])))
                case .system:
                    continue
                }

            case .toolCall:
                guard let toolCall = event.toolCall else {
                    continue
                }
                let callID = deterministicToolCallID(for: event)
                pendingToolCallIDsByTool[toolCall.tool, default: []].append(callID)
                pendingToolCallEntryIndicesByID[callID] = entries.count
                entries.append(.toolCalls(Transcript.ToolCalls([
                    Transcript.ToolCall(
                        id: callID,
                        toolName: toolCall.tool,
                        arguments: generatedContent(from: .object(toolCall.arguments))
                    )
                ])))

            case .toolResult:
                guard let toolResult = event.toolResult else {
                    continue
                }
                let matchedCallID = dequeuePendingToolCallID(
                    tool: toolResult.tool,
                    pendingToolCallIDsByTool: &pendingToolCallIDsByTool
                )
                if let matchedCallID {
                    pendingToolCallEntryIndicesByID.removeValue(forKey: matchedCallID)
                }
                let callID = matchedCallID ?? deterministicToolCallID(for: event)
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: callID,
                    toolName: toolResult.tool,
                    segments: [.text(.init(content: toolResultText(from: toolResult)))]
                )))

            case .sessionCreated, .runStatus, .memoryCheckpoint, .buildProgress, .planArtifact, .subSession, .runControl, .inputRequest, .inputResponse, .selfImprovementReview:
                continue
            }
        }

        if pendingToolCallEntryIndicesByID.isEmpty {
            return entries
        }
        return entries.enumerated().compactMap { index, entry in
            switch entry {
            case .toolCalls(let calls):
                let unresolvedIDs = calls.map(\.id).filter { pendingToolCallEntryIndicesByID[$0] == index }
                return unresolvedIDs.isEmpty ? entry : nil
            default:
                return entry
            }
        }
    }

    private static func transcriptText(from message: AgentSessionMessage) -> String? {
        var parts: [String] = []
        for segment in message.segments {
            switch segment.kind {
            case .text:
                if let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    parts.append(text)
                }
            case .attachment:
                if let attachment = segment.attachment {
                    parts.append(attachmentReferenceText(attachment))
                }
            case .thinking:
                continue
            }
        }

        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func attachmentReferenceText(_ attachment: AgentAttachment) -> String {
        var fields = ["name: \(attachment.name)", "type: \(attachment.mimeType)", "size: \(attachment.sizeBytes) bytes"]
        if let relativePath = attachment.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !relativePath.isEmpty {
            fields.append("path: \(relativePath)")
        }
        return "[Attachment: \(fields.joined(separator: ", "))]"
    }

    private static func toolResultText(from result: AgentToolResultEvent) -> String {
        var payload: [String: JSONValue] = [
            "ok": .bool(result.ok)
        ]
        if let data = result.data {
            payload["data"] = data
        }
        if let error = result.error {
            payload["error"] = encodeJSONValue(error)
        }
        if let durationMs = result.durationMs {
            payload["durationMs"] = .number(Double(durationMs))
        }
        return compactJSONString(.object(payload))
    }

    private static func deterministicToolCallID(for event: AgentSessionEvent) -> String {
        "session-event-\(event.id)"
    }

    private static func dequeuePendingToolCallID(
        tool: String,
        pendingToolCallIDsByTool: inout [String: [String]]
    ) -> String? {
        guard var pending = pendingToolCallIDsByTool[tool], !pending.isEmpty else {
            return nil
        }
        let id = pending.removeFirst()
        if pending.isEmpty {
            pendingToolCallIDsByTool.removeValue(forKey: tool)
        } else {
            pendingToolCallIDsByTool[tool] = pending
        }
        return id
    }

    private static func generatedContent(from value: JSONValue) -> GeneratedContent {
        switch value {
        case .string(let string):
            return GeneratedContent(string)
        case .number(let number):
            return GeneratedContent(number)
        case .bool(let bool):
            return GeneratedContent(bool)
        case .null:
            return GeneratedContent(kind: .null)
        case .array(let values):
            return GeneratedContent(kind: .array(values.map(generatedContent(from:))))
        case .object(let object):
            let orderedKeys = object.keys.sorted()
            let properties = Dictionary(uniqueKeysWithValues: orderedKeys.map { key in
                (key, generatedContent(from: object[key] ?? .null))
            })
            return GeneratedContent(kind: .structure(properties: properties, orderedKeys: orderedKeys))
        }
    }

    private static func encodeJSONValue<T: Encodable>(_ value: T) -> JSONValue {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return .null
        }
    }

    private static func compactJSONString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }
}
