import AnyLanguageModel
import Foundation
import PluginSDK
import Protocols
import Testing
@testable import AgentRuntime

@Suite("Artifact-aware model context")
struct TranscriptContextManagerTests {
    private func prompt(_ text: String) -> Transcript.Entry { .prompt(.init(segments: [.text(.init(content: text))])) }
    private func response(_ text: String) -> Transcript.Entry { .response(.init(assetIDs: [], segments: [.text(.init(content: text))])) }
    private func output(id: String, artifact: Bool = true) throws -> Transcript.Entry {
        var data: [String: Protocols.JSONValue] = ["stdout": .string(String(repeating: "old build log\n", count: 2_000)), "exitCode": .number(0), "verificationEvidence": .object(["id": .string("proof-1")])]
        if artifact { data["stdoutArtifact"] = .object(["path": .string("/workspace/log-1.log"), "complete": .bool(true)]) }
        let payload: Protocols.JSONValue = .object(["ok": .bool(true), "data": .object(data)])
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return .toolOutput(.init(id: id, toolName: "runtime.exec", segments: [.text(.init(content: text))]))
    }

    @Test("Old bulky outputs become references, preserve evidence, and leave the source untouched")
    func pruneBeforeSummary() async throws {
        let full = Transcript(entries: [prompt("original task"), try output(id: "old"), response("old response"), prompt("recent turn"), response("recent response"), prompt("current task")])
        let prepared = try await TranscriptContextManager.prepare(full, inputBudget: 1_000, protectRecentEntries: 2, summarize: { _, _ in
            Issue.record("Pruning should have removed enough context without summarization")
            return "unused"
        })
        #expect(prepared.1.prunedToolOutputs == 1)
        #expect(!prepared.1.summarized)
        #expect(prepared.1.afterTokens < prepared.1.beforeTokens)
        #expect(TranscriptContextManager.render(full[1]).contains("old build log"))
        #expect(TranscriptContextManager.render(prepared.0[1]).contains("proof-1"))
        guard case .toolOutput(let prunedOutput) = prepared.0[1], case .text(let segment) = prunedOutput.segments[0] else { Issue.record("Expected tool output"); return }
        let payload = try JSONDecoder().decode(Protocols.JSONValue.self, from: Data(segment.content.utf8))
        #expect(payload.asObject?["data"]?.asObject?["artifacts"]?.asArray?.first?.asObject?["path"] == .string("/workspace/log-1.log"))
        #expect(prepared.0.last == full.last)
    }

    @Test("A result without an artifact is archived before its model-visible body is pruned")
    func archiveRequired() async throws {
        let full = Transcript(entries: [prompt("task"), try output(id: "old", artifact: false), prompt("tail1"), prompt("tail2")])
        let prepared = try await TranscriptContextManager.prepare(full, inputBudget: 800, protectRecentEntries: 1,
            archive: { id, text in
                #expect(id == "old")
                #expect(text.contains("old build log"))
                return .object(["path": .string("/workspace/saved.json"), "complete": .bool(true)])
            }, summarize: { _, _ in "unused" })
        #expect(prepared.1.prunedToolOutputs == 1)
    }

    @Test("Summary preserves instructions, the latest turns and matching call/result pairs")
    func summaryRetainsTail() async throws {
        let instructions = Transcript.Entry.instructions(.init(segments: [.text(.init(content: "Never change protected files"))], toolDefinitions: []))
        let full = Transcript(entries: [instructions, prompt("old objective"), response(String(repeating: "historical discussion ", count: 300)), prompt("recent request"), response("recent answer"), prompt("latest correction")])
        let prepared = try await TranscriptContextManager.prepare(full, inputBudget: 3_000, protectRecentEntries: 2, forceSummary: true, summarize: { history, _ in
            #expect(history.contains("historical discussion"))
            #expect(!history.contains("latest correction"))
            return "Objective, decisions, constraints and artifact paths retained."
        })
        #expect(prepared.1.summarized)
        #expect(prepared.0.first == instructions)
        #expect(prepared.0.last == full.last)
        #expect(TranscriptContextManager.render(prepared.0[prepared.0.count - 3]).contains("recent request"))
    }

    @Test("Protected current evidence is never silently dropped when it cannot fit")
    func protectedOverflow() async throws {
        let full = Transcript(entries: [prompt("current task"), try output(id: "current")])
        do {
            _ = try await TranscriptContextManager.prepare(full, inputBudget: 100, summarize: { _, _ in "unsafe" })
            Issue.record("Expected an explicit overflow instead of discarding the current result")
        } catch TranscriptContextError.protectedContextExceedsBudget {}
    }

    @Test("Selected model limits reserve output and enforce the smaller input limit")
    func selectedModelBudget() {
        let limits = ModelContextLimits(contextWindowTokens: 16_000, maxInputTokens: 12_000, maxOutputTokens: 2_000)
        #expect(limits.inputBudget(reserving: 4_000) == 10_000)
        #expect(limits.outputReserve(4_000) == 2_000)
    }

    @Test("Runtime applies the selected model budget before sending its recovered transcript")
    func runtimeIntegration() async throws {
        let capture = ContextRuntimeCapture()
        let provider = ContextTestProvider(capture: capture)
        let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "test:small", compactorConfiguration: .init(protectTailMessages: 2), preResponseMemoryLimit: 0)
        let history = Transcript(entries: [prompt("original task"), try output(id: "old"), response("old reply"), prompt("recent request"), response("recent reply")])
        await runtime.setChannelRecoveryTranscript(channelId: "channel", transcript: history)
        _ = await runtime.postMessage(channelId: "channel", request: .init(userId: "user", content: "current correction", model: "test:small"))
        let report = try #require(await runtime.contextPreparationReport(channelId: "channel"))
        #expect(report.prunedToolOutputs == 1)
        let sent = try #require(await capture.latest())
        #expect(!sent.contains("old build log"))
        #expect(sent.contains("proof-1"))
        #expect(await runtime.contextLedgerSnapshot(channelId: "channel")?.contextWindowTokens == 2_000)
    }
}

private actor ContextRuntimeCapture {
    var text: String?
    func record(_ transcript: Transcript) { text = transcript.map(TranscriptContextManager.render).joined(separator: "\n") }
    func latest() -> String? { text }
}

private struct ContextTestProvider: ModelProvider {
    let capture: ContextRuntimeCapture
    var id: String { "test" }
    var supportedModels: [String] { ["test:small"] }
    func contextLimits(for modelName: String) -> ModelContextLimits? { .init(contextWindowTokens: 2_000, maxOutputTokens: 256) }
    func createLanguageModel(for modelName: String) async throws -> any LanguageModel { ContextTestLanguageModel(capture: capture) }
}

private struct ContextTestLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let capture: ContextRuntimeCapture
    func respond<Content>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type, includeSchemaInPrompt: Bool, options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        .init(content: "Summary preserves task, evidence and artifacts" as! Content, rawContent: GeneratedContent("Summary"), transcriptEntries: [])
    }
    func streamResponse<Content>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type, includeSchemaInPrompt: Bool, options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                await capture.record(session.transcript)
                continuation.yield(.init(content: "Done" as! Content.PartiallyGenerated, rawContent: GeneratedContent("Done")))
                continuation.finish()
            }
        }
        return .init(stream: stream)
    }
}
