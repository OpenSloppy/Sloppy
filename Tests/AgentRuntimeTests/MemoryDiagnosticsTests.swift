import AnyLanguageModel
import Foundation
import Testing
@testable import AgentRuntime
import Protocols

@Suite
struct MemoryDiagnosticsTests {
    @Test
    func bootstrapMetricsReportCandidatesAndTheBoundedSelection() async {
        let memory = InMemoryMemoryStore()
        let preference = await memory.save(entry: .init(note: "Use focused tests", kind: .preference, scope: .agent("helper")))
        _ = await memory.save(entry: .init(note: String(repeating: "long fact ", count: 100), scope: .agent("helper")))
        let runtime = RuntimeSystem(memoryStore: memory)
        let channel = "agent:helper:session:bootstrap"
        let context = await runtime.persistentMemoryContext(channelId: channel, maxCharacters: 500)
        let diagnostic = await runtime.memoryDiagnostics.snapshot(channelId: channel)
        #expect(context.contains("Use focused tests"))
        #expect(!context.contains("long fact"))
        #expect(diagnostic.queries.count == 1)
        #expect(diagnostic.queries[0].source == .bootstrap)
        #expect(diagnostic.queries[0].hits.map(\.ref.id) == [preference.id])
        #expect(diagnostic.queries[0].stages[0].candidateCount == 2)
        #expect(diagnostic.modelContext == nil)
    }

    @Test
    func automaticQueriesAreScopedAndInjectionMatchesTheActualPrompt() async throws {
        let memory = InMemoryMemoryStore()
        let runtime = RuntimeSystem(memoryStore: memory, preResponseMemoryLimit: 2)
        let channel = "agent:helper:session:current"
        await runtime.setMemoryProject(channelId: channel, projectID: "aurora")
        for scope in [MemoryScope.agent("helper"), .project("aurora"), .channel(channel), .agent("other")] {
            _ = await memory.save(entry: MemoryWriteRequest(note: "Aurora \(scope.id)", scope: scope))
        }
        let prompt = await runtime.userMessageWithAutoRecalledMemory(channelId: channel, userMessage: "Aurora")
        let queries = await runtime.memoryDiagnostics.snapshot(channelId: channel).queries
        #expect(queries.count == 3)
        #expect(queries.allSatisfy { $0.source == .automatic && $0.query == "Aurora" && $0.durationMs >= 0 })
        #expect(Set(queries.compactMap { $0.scope?.id }) == ["helper", "aurora", channel])
        #expect(Set(queries.compactMap(\.operationId)).count == 1)
        #expect(!prompt.contains("Aurora other"))
        await runtime.captureModelContext(channelId: channel, model: "mock", transcript: Transcript(),
            userMessage: prompt, images: [], tools: [], options: GenerationOptions())
        let snapshot = await runtime.memoryDiagnostics.snapshot(channelId: channel)
        let injection = try #require(snapshot.modelContext?.memoryInjection)
        #expect(injection.hitIds.count == 2)
        #expect(injection.operationId == queries.first?.operationId)
        #expect(prompt.hasPrefix(injection.content))
        #expect(injection.characters == injection.content.count)
        #expect(injection.estimatedTokens > 0)
        #expect(snapshot.modelContext?.entries.last?.content == prompt)
        #expect(snapshot.queries.count == queries.count)
        _ = await runtime.userMessageWithAutoRecalledMemory(channelId: channel, userMessage: "")
        #expect(await runtime.memoryInjectionByChannel[channel] == nil)
    }

    @Test
    func disabledRecallDoesNotQueryOrInject() async {
        let runtime = RuntimeSystem(preResponseMemoryLimit: 0)
        let channel = "agent:helper:session:disabled"
        #expect(await runtime.userMessageWithAutoRecalledMemory(channelId: channel, userMessage: "Hello") == "Hello")
        #expect(await runtime.memoryDiagnostics.snapshot(channelId: channel).queries.isEmpty)
        #expect(await runtime.memoryInjectionByChannel[channel] == nil)
    }

    @Test
    func contextCapturesPreparedHistoryPendingPromptAndImageMetadataOnce() async throws {
        let runtime = RuntimeSystem()
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Bootstrap with curated memory"))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Retained user history"))], options: GenerationOptions(), responseFormat: nil)),
        ])
        let image = Transcript.ImageSegment(data: Data([1, 2, 3]), mimeType: "image/png")
        await runtime.captureModelContext(channelId: "channel", model: "mock", transcript: transcript,
            userMessage: "Current request", images: [image], tools: [], options: GenerationOptions())
        let context = try #require(await runtime.memoryDiagnostics.snapshot(channelId: "channel").modelContext)
        #expect(context.entryCount == 3)
        #expect(context.entries.map(\.kind) == ["instructions", "user", "user"])
        #expect(context.entries.first?.content.contains("Bootstrap with curated memory") == true)
        #expect(context.entries.first?.content.contains("Tool definitions") == true)
        #expect(context.entries[1].content == "Retained user history")
        #expect(context.entries.last?.content.contains("Current request") == true)
        #expect(context.entries.last?.content.contains("image/png, 3 bytes") == true)
        #expect(context.imageCount == 1)
        #expect(context.estimatedTokens > 0)
        #expect(!context.truncated)
        #expect(await runtime.memoryDiagnostics.snapshot(channelId: "other").modelContext == nil)
    }

    @Test
    func contextPreviewsAreBoundedAndKeepOriginalSizes() async throws {
        let runtime = RuntimeSystem()
        let message = String(repeating: "x", count: 20_000)
        await runtime.captureModelContext(channelId: "channel", model: "mock", transcript: Transcript(),
            userMessage: message, images: [], tools: [], options: GenerationOptions())
        let context = try #require(await runtime.memoryDiagnostics.snapshot(channelId: "channel").modelContext)
        #expect(context.truncated)
        #expect(context.characters == 20_000)
        #expect(context.entries[0].content.count == 16_000)
        #expect(context.entries[0].characters == 20_000)
        #expect(context.entries[0].truncated)
    }

    @Test
    func queryBufferIsBoundedIsolatedAndRetainsBackendFailures() async {
        let diagnostics = MemoryDiagnostics(retentionLimit: 2)
        let result = MemoryRecallResult(hits: [], durationMs: 10, stages: [
            .init(name: "provider", durationMs: 9, candidateCount: 0, error: "unavailable")
        ])
        for channel in ["old", "current", "other"] {
            await diagnostics.record(request: MemoryRecallRequest(query: channel), result: result,
                channelId: channel, source: .toolRecall)
        }
        #expect(await diagnostics.snapshot(channelId: "old").queries.isEmpty)
        let snapshot = await diagnostics.snapshot(channelId: "current")
        #expect(snapshot.queries.count == 1)
        #expect(snapshot.queries[0].query == "current")
        #expect(snapshot.queries[0].resultCount == 0)
        #expect(snapshot.queries[0].stages[0].error == "unavailable")
        await diagnostics.remove(channelId: "current")
        #expect(await diagnostics.snapshot(channelId: "current").queries.isEmpty)
        #expect(await diagnostics.snapshot(channelId: "other").queries.count == 1)
    }
}
