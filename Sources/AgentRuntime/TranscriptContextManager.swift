import AnyLanguageModel
import Foundation
import PluginSDK
import Protocols

public struct TranscriptContextReport: Sendable, Equatable {
    public var beforeTokens: Int
    public var afterTokens: Int
    public var prunedToolOutputs: Int
    public var summarized: Bool
}

public enum TranscriptContextError: Error, Sendable {
    case protectedContextExceedsBudget
    case summaryFailed
}

/// Transforms a model-visible copy, leaving persisted events and their evidence intact.
public enum TranscriptContextManager {
    public typealias Archive = @Sendable (String, String) async -> Protocols.JSONValue?
    public typealias Summarize = @Sendable (String, Int) async throws -> String

    public static func estimate(_ transcript: Transcript) -> Int {
        transcript.reduce(0) { $0 + estimate(entry: $1) }
    }

    public static func estimate(entry: Transcript.Entry) -> Int {
        TokenPressureEstimator().estimateTextTokens(render(entry)) + 16
    }

    public static func render(_ entry: Transcript.Entry) -> String {
        func segments(_ segments: [Transcript.Segment]) -> String {
            segments.map {
                switch $0 {
                case .text(let value): return value.content
                case .structure(let value): return value.content.jsonString
                case .image: return String(repeating: " ", count: 3_072)
                }
            }.joined(separator: "\n")
        }
        switch entry {
        case .instructions(let value):
            let definitions = (try? JSONEncoder().encode(value.toolDefinitions)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "[Instructions]\n" + segments(value.segments) + definitions
        case .prompt(let value): return "[User]\n" + segments(value.segments)
        case .response(let value): return "[Assistant]\n" + segments(value.segments)
        case .toolOutput(let value): return "[Tool \(value.toolName) id=\(value.id)]\n" + segments(value.segments)
        case .toolCalls(let value): return value.map { "[Call \($0.toolName) id=\($0.id)] \($0.arguments.jsonString)" }.joined(separator: "\n")
        }
    }

    public static func prepare(
        _ original: Transcript,
        inputBudget: Int,
        protectRecentEntries: Int = 8,
        forceSummary: Bool = false,
        archive: Archive? = nil,
        summarize: Summarize
    ) async throws -> (Transcript, TranscriptContextReport) {
        var entries = Array(original)
        let before = estimate(original)
        var pruned = 0
        let prompts = entries.indices.filter { if case .prompt = entries[$0] { return true }; return false }
        let recentStart = max(0, entries.count - max(1, protectRecentEntries))
        let protectedPrompts = Set(prompts.suffix(2))
        for index in entries.indices where index < recentStart {
            guard case .toolOutput(let output) = entries[index],
                  output.segments.allSatisfy({ if case .text = $0 { return true }; return false }),
                  estimate(entry: entries[index]) > 512 else { continue }
            let text = output.segments.map { if case .text(let value) = $0 { return value.content }; return "" }.joined(separator: "\n")
            guard var payload = (try? JSONDecoder().decode(Protocols.JSONValue.self, from: Data(text.utf8)))?.asObject else { continue }
            let data = payload["data"]?.asObject ?? [:]
            let state = payload["executionOutcome"]?.asObject?["state"]?.asString
            if state == ExecutionState.interrupted.rawValue || payload["error"]?.asObject?["code"] == .string("tool_execution_interrupted") { continue }
            var refs = ["outputArtifact", "stdoutArtifact", "stderrArtifact"].compactMap { key -> Protocols.JSONValue? in
                guard let ref = data[key], ref.asObject?["complete"] == .bool(true) else { return nil }
                return ref
            }
            if refs.isEmpty, let ref = await archive?(output.id, text) { refs = [ref] }
            guard !refs.isEmpty else { continue }
            var replacement: [String: Protocols.JSONValue] = ["compacted": .bool(true), "artifacts": .array(refs)]
            for key in ["verificationEvidence", "exitCode", "timedOut", "contentHash", "executionOutcome", "requiresReconciliation"] {
                if let value = data[key] { replacement[key] = value }
            }
            payload["data"] = .object(replacement)
            let encoded = try JSONEncoder().encode(Protocols.JSONValue.object(payload))
            let next = Transcript.Entry.toolOutput(.init(id: output.id, toolName: output.toolName, segments: [.text(.init(content: String(decoding: encoded, as: UTF8.self)))]))
            guard estimate(entry: next) < estimate(entry: entries[index]) else { continue }
            entries[index] = next
            pruned += 1
        }
        var transcript = Transcript(entries: entries)
        if estimate(transcript) <= inputBudget && !forceSummary {
            return (transcript, .init(beforeTokens: before, afterTokens: estimate(transcript), prunedToolOutputs: pruned, summarized: false))
        }
        let outputs = Set(entries.compactMap { if case .toolOutput(let value) = $0 { return value.id }; return nil })
        var tailStart = recentStart
        for index in entries.indices {
            if case .toolCalls(let calls) = entries[index], calls.contains(where: { !outputs.contains($0.id) }) {
                tailStart = min(tailStart, index)
            }
        }
        // Never split a tool-call/result transaction at the retained-tail boundary.
        let tailOutputIDs = Set(entries.suffix(from: tailStart).compactMap { if case .toolOutput(let value) = $0 { return value.id }; return nil })
        for index in entries.indices where index < tailStart {
            if case .toolCalls(let calls) = entries[index], calls.contains(where: { tailOutputIDs.contains($0.id) }) { tailStart = index; break }
        }
        let head = entries.prefix(tailStart).enumerated().filter { index, entry in
            if case .instructions = entry { return false }
            return !protectedPrompts.contains(index)
        }.map(\.element)
        let instructions = entries.prefix(tailStart).filter { if case .instructions = $0 { return true }; return false }
        let retainedPrompts = entries.prefix(tailStart).enumerated().filter { protectedPrompts.contains($0.offset) }.map(\.element)
        let tail = Array(entries.suffix(from: tailStart))
        let protectedTokens = estimate(Transcript(entries: instructions + retainedPrompts + tail))
        let remaining = inputBudget - protectedTokens - 64
        guard remaining > 0 else { throw TranscriptContextError.protectedContextExceedsBudget }
        guard !head.isEmpty else {
            if estimate(transcript) <= inputBudget { return (transcript, .init(beforeTokens: before, afterTokens: estimate(transcript), prunedToolOutputs: pruned, summarized: false)) }
            throw TranscriptContextError.protectedContextExceedsBudget
        }
        // Bound the summary request too; never ask the same model to summarize an
        // input larger than it can accept. Prefer pruning instead of dropping evidence.
        let history = head.map(render).joined(separator: "\n\n")
        guard TokenPressureEstimator().estimateTextTokens(history) + 512 <= inputBudget else { throw TranscriptContextError.protectedContextExceedsBudget }
        let summary = try await summarize(history, min(remaining, max(128, inputBudget / 4)))
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptContextError.summaryFailed }
        transcript = Transcript(entries: instructions + [.response(.init(assetIDs: [], segments: [.text(.init(content: "[Compacted conversation context]\n" + summary))]))] + retainedPrompts + tail)
        guard estimate(transcript) <= inputBudget else { throw TranscriptContextError.protectedContextExceedsBudget }
        return (transcript, .init(beforeTokens: before, afterTokens: estimate(transcript), prunedToolOutputs: pruned, summarized: true))
    }
}
