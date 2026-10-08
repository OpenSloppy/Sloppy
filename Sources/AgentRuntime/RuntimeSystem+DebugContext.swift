import AnyLanguageModel
import Foundation

extension RuntimeSystem {
    /// Captures the prepared transcript plus the pending prompt exactly once, before streaming.
    /// Text previews are bounded; image bytes are represented by metadata rather than copied.
    func captureModelContext(
        channelId: String, model: String, transcript: Transcript,
        userMessage: String, images: [Transcript.ImageSegment],
        tools: [any Tool], options: GenerationOptions
    ) async {
        var entries = Array(transcript)
        var segments: [Transcript.Segment] = []
        if !userMessage.isEmpty { segments.append(.text(.init(content: userMessage))) }
        segments.append(contentsOf: images.map { .image($0) })
        entries.append(.prompt(Transcript.Prompt(segments: segments, options: options, responseFormat: nil)))

        let entryLimit = 500
        // Preserve instructions and the most recent messages when diagnostic retention is exceeded.
        let retained = entries.count <= entryLimit ? entries : [entries[0]] + Array(entries.suffix(entryLimit - 1))
        let previewLimit = min(16_000, 128_000 / max(1, retained.count))
        let previews = retained.map { entry in
            let content = Self.debugContextContent(entry)
            let kind: String
            switch entry {
            case .instructions: kind = "instructions"
            case .prompt: kind = "user"
            case .response: kind = "assistant"
            case .toolCalls: kind = "tool_calls"
            case .toolOutput: kind = "tool_output"
            }
            return ModelContextEntryDiagnostic(
                id: entry.id, kind: kind, content: String(content.prefix(previewLimit)),
                characters: content.count, estimatedTokens: TranscriptContextManager.estimate(entry: entry),
                truncated: content.count > previewLimit
            )
        }
        await memoryDiagnostics.recordContext(channelId: channelId, context: ModelContextDiagnostic(
            recordedAt: Date(), model: model, entries: previews, entryCount: entries.count,
            characters: entries.reduce(0) { $0 + Self.debugContextContent($1).count },
            estimatedTokens: TranscriptContextManager.estimate(Transcript(entries: entries)),
            imageCount: entries.reduce(0) { $0 + Self.debugContextImageCount($1) },
            toolNames: tools.map(\.name), truncated: entries.count > entryLimit || previews.contains { $0.truncated },
            memoryInjection: memoryInjectionByChannel[channelId]
        ))
    }

    private static func debugContextSegments(_ segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let value): return value.content
            case .structure(let value): return value.content.jsonString
            case .image(let value):
                switch value.source {
                case .data(let bytes, let mime): return "[Image \(value.id): \(mime), \(bytes.count) bytes]"
                case .url(let url): return "[Image \(value.id): \(url.absoluteString)]"
                }
            }
        }.joined(separator: "\n")
    }

    private static func debugContextContent(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions(let value):
            let definitions = (try? JSONEncoder().encode(value.toolDefinitions)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return debugContextSegments(value.segments) + "\n[Tool definitions]\n" + definitions
        case .prompt(let value): return debugContextSegments(value.segments)
        case .response(let value): return debugContextSegments(value.segments)
        case .toolOutput(let value): return "[\(value.toolName), id=\(value.id)]\n" + debugContextSegments(value.segments)
        case .toolCalls(let value): return value.map { "[\($0.toolName), id=\($0.id)] \($0.arguments.jsonString)" }.joined(separator: "\n")
        }
    }

    private static func debugContextImageCount(_ entry: Transcript.Entry) -> Int {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let value): segments = value.segments
        case .prompt(let value): segments = value.segments
        case .response(let value): segments = value.segments
        case .toolOutput(let value): segments = value.segments
        case .toolCalls: return 0
        }
        return segments.filter { if case .image = $0 { return true }; return false }.count
    }
}
