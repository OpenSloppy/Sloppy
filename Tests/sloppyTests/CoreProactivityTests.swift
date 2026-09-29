import AnyLanguageModel
import Foundation
import Testing
import PluginSDK
import Protocols
@testable import sloppy

private struct ReportingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    func respond<Content>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
                          includeSchemaInPrompt: Bool, options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { throw ProactiveHeartbeatError.invalidReport }
        if let delegate = session.toolExecutionDelegate {
            for (name, arguments) in [
                ("project.task_update", ["taskId": "t", "status": "done"]),
                ("heartbeat.report", ["sourceId": "task:p:t", "outcome": "notify", "reason": "Review required", "evidence": "Status is needs_review", "nextStep": "Open task t"]),
            ] {
                let call = Transcript.ToolCall(id: UUID().uuidString, toolName: name,
                    arguments: try GeneratedContent(json: String(decoding: JSONEncoder().encode(arguments), as: UTF8.self)))
                await delegate.didGenerateToolCalls([call], in: session)
                if case .provideOutput(let segments) = await delegate.toolCallDecision(for: call, in: session) {
                    await delegate.didExecuteToolCall(call, output: .init(id: call.id, toolName: name, segments: segments), in: session)
                }
            }
        }
        return .init(content: "Review complete" as! Content, rawContent: GeneratedContent("Review complete"), transcriptEntries: [])
    }

    func streamResponse<Content>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
                                includeSchemaInPrompt: Bool, options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                do {
                    let result = try await respond(within: session, to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
                    continuation.yield(.init(content: result.content.asPartiallyGenerated(), rawContent: result.rawContent))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        return .init(stream: stream)
    }
}

private actor ReportingModelProvider: ModelProvider {
    nonisolated let id = "proactive-test"
    nonisolated let supportedModels = ["mock:fast", "mock:strong"]
    var requested: [String] = []
    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        requested.append(modelName)
        return ReportingLanguageModel()
    }
}

@Suite("Core proactivity")
struct CoreProactivityTests {
    @Test func realRuntimeUsesExplicitStrongModelAndRejectsMutatingTools() async throws {
        let service = CoreService(config: .test)
        let provider = ReportingModelProvider()
        await service.overrideModelProviderForTests(provider, defaultModel: "mock:fast")
        _ = try await service.createAgent(.init(id: "attention", displayName: "Attention", role: "Reviewer"))
        let snapshot = ProactiveSnapshot(source: .init(id: "task:p:t", kind: .task, title: "Task", projectId: "p", taskId: "t"),
                                        scope: "project:p", revision: "1", summary: "needs_review", updatedAt: .distantPast)
        let result = try await service.analyzeProactiveSnapshots(agentID: "attention", snapshots: [snapshot], model: "mock:strong")
        #expect(result.reports.first?.outcome == .notify)
        #expect(await provider.requested.contains("mock:strong"))
        #expect(!(await provider.requested.contains("mock:fast")))
        let detail = try await service.getAgentSession(agentID: "attention", sessionID: result.sessionID)
        #expect(detail.summary.kind == .heartbeat)
        #expect(detail.events.contains { $0.toolResult?.tool == "project.task_update" && $0.toolResult?.error?.code == "proactive_tool_forbidden" })
        #expect(detail.events.contains { $0.toolResult?.tool == "heartbeat.report" && $0.toolResult?.ok == true })
        #expect(detail.events.last?.message?.role == .assistant)
    }

    @Test func settingsEndpointPreservesOtherAgentConfigurationAndValidatesWindow() async throws {
        let service = CoreService(config: .test)
        _ = try await service.createAgent(.init(id: "attention", displayName: "Attention", role: "Reviewer"))
        let before = try await service.getAgentConfig(agentID: "attention")
        let router = CoreRouter(service: service)
        var settings = AgentHeartbeatSettings(mode: .proactive)
        settings.proactive.timeZone = "Invalid/Zone"
        var response = await router.handle(method: "PUT", path: "/v1/agents/attention/proactivity/settings",
            body: try JSONEncoder().encode(ProactiveSettingsRequest(heartbeat: settings)))
        #expect(response.status == 400)
        settings.proactive.timeZone = "Europe/Moscow"
        response = await router.handle(method: "PUT", path: "/v1/agents/attention/proactivity/settings",
            body: try JSONEncoder().encode(ProactiveSettingsRequest(heartbeat: settings, heartbeatMarkdown: "Watch PRs")))
        #expect(response.status == 200)
        let after = try await service.getAgentConfig(agentID: "attention")
        #expect(before.selectedModel == after.selectedModel)
        #expect(before.role == after.role)
        #expect(before.runtime == after.runtime)
        #expect(before.skills == after.skills)
        #expect(after.documents.heartbeatMarkdown == "Watch PRs")
        response = await router.handle(method: "GET", path: "/v1/agents/attention/proactivity", body: nil)
        #expect(response.status == 200)
        response = await router.handle(method: "POST", path: "/v1/agents/attention/proactivity/findings/missing/action", body: Data("{\"action\":\"dismiss\"}".utf8))
        #expect(response.status == 404)
    }
}
