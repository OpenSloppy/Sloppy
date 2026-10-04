import AnyLanguageModel
import Foundation
import Testing
@testable import PluginSDK
@testable import Protocols
@testable import sloppy

private struct DelegateAwareToolCallingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let toolName: String
    let successText: String
    let missingDelegateText: String

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else {
            fatalError("DelegateAwareToolCallingLanguageModel only supports String responses")
        }

        guard let delegate = session.toolExecutionDelegate else {
            return LanguageModelSession.Response(
                content: missingDelegateText as! Content,
                rawContent: GeneratedContent(missingDelegateText),
                transcriptEntries: []
            )
        }

        let toolCall = Transcript.ToolCall(
            id: UUID().uuidString,
            toolName: toolName,
            arguments: GeneratedContent("")
        )
        await delegate.didGenerateToolCalls([toolCall], in: session)
        let decision = await delegate.toolCallDecision(for: toolCall, in: session)

        var entries: [Transcript.Entry] = [.toolCalls(Transcript.ToolCalls([toolCall]))]
        if case .provideOutput(let segments) = decision {
            let output = Transcript.ToolOutput(id: toolCall.id, toolName: toolCall.toolName, segments: segments)
            await delegate.didExecuteToolCall(toolCall, output: output, in: session)
            entries.append(.toolOutput(output))
        }

        return LanguageModelSession.Response(
            content: successText as! Content,
            rawContent: GeneratedContent(successText),
            transcriptEntries: ArraySlice(entries)
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                do {
                    let response = try await respond(
                        within: session,
                        to: prompt,
                        generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt,
                        options: options
                    )
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor DelegateAwareToolCallingModelProvider: ModelProvider {
    nonisolated let id: String = "delegate-aware-tool-calling"
    nonisolated let supportedModels: [String] = ["mock:linked-agent", "mock:test-model"]

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        DelegateAwareToolCallingLanguageModel(
            toolName: "system.list_tools",
            successText: "tool delegate used",
            missingDelegateText: "missing tool delegate"
        )
    }
}

private actor CronMessagePosterProbe {
    private var requests: [(channelId: String, request: ChannelMessageRequest)] = []

    func record(channelId: String, request: ChannelMessageRequest) {
        requests.append((channelId, request))
    }

    func snapshot() -> [(channelId: String, request: ChannelMessageRequest)] {
        requests
    }
}

private extension CoreService {
    func cronInboxTurnsForTests() throws -> [LongChatFileStore.Turn] {
        try longChats().state.turns
    }
}

@Suite("Linked agent channel cron")
struct LinkedAgentChannelCronTests {
    @Test("malformed and out-of-range schedules are rejected", arguments: [
        "* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8",
        "*/0 * * * *", "1,,2 * * * *", "5-1 * * * *", "1,bad * * * *", "* * * * 1-5/0",
    ])
    func rejectsInvalidSchedule(expression: String) {
        #expect(!CronEvaluator.isValid(cronExpression: expression))
        #expect(!CronEvaluator.isDue(cronExpression: expression))
    }

    @Test("ranges, steps, lists and both Sunday aliases match local calendar dates")
    func cronExpressionVariantsMatch() throws {
        let monday = try #require(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 9, minute: 20)))
        #expect(CronEvaluator.isDue(cronExpression: "0-30/10 9 * * 1-5", date: monday))
        #expect(CronEvaluator.isDue(cronExpression: "*/10 9 * * 1,3,5", date: monday))
        #expect(!CronEvaluator.isDue(cronExpression: "0-30/15 9 * * 1-5", date: monday))
        let sunday = try #require(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 7, hour: 9)))
        #expect(CronEvaluator.isDue(cronExpression: "0 9 * * 0", date: sunday))
        #expect(CronEvaluator.isDue(cronExpression: "0 9 * * 7", date: sunday))
        #expect(!CronEvaluator.isDue(cronExpression: "0 9 * * 1-5", date: sunday))
    }

    @Test("the documented weekday range fires on Monday")
    func documentedWeekdayScheduleIsDue() throws {
        let monday = try #require(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 9)))
        #expect(CronEvaluator.isDue(cronExpression: "0 9 * * 1-5", date: monday))
    }

    @Test("cron creates a visible agent chat for the default target")
    func cronCreatesAgentSession() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        await service.overrideModelProviderForTests(DelegateAwareToolCallingModelProvider(), defaultModel: "mock:linked-agent")
        let agentID = "cron-new-\(UUID().uuidString.lowercased())"
        _ = try await service.createAgent(AgentCreateRequest(id: agentID, displayName: "Cron", role: "Assistant"))
        _ = try await service.createAgentCronTask(
            agentID: agentID,
            request: AgentCronTaskCreateRequest(channelId: "main", schedule: "* * * * *", command: "Scheduled check")
        )
        let runner = await service.makeCronRunner()
        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_200))
        let sessions = try await service.listAgentSessions(agentID: agentID)
        #expect(sessions.count == 1)
        if let session = sessions.first {
            let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
            #expect(detail.events.contains(where: { $0.message?.userId == "system_cron" && $0.message?.segments.first?.text?.contains("Scheduled check") == true }))
            #expect(detail.events.contains(where: { $0.message?.role == .assistant && $0.message?.segments.first?.text == "tool delegate used" }))
        }
        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_260))
        let nextSessions = try await service.listAgentSessions(agentID: agentID)
        #expect(nextSessions.count == 2)
        #expect(Set(nextSessions.map(\.id)).count == 2)
        await service.shutdownChannelPlugins()
    }

    @Test("cron appends to the existing chat instead of a separate channel history", arguments: [false, true])
    func cronResumesAgentSession(bareSessionID: Bool) async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        await service.overrideModelProviderForTests(DelegateAwareToolCallingModelProvider(), defaultModel: "mock:linked-agent")
        let agentID = "cron-resume-\(UUID().uuidString.lowercased())"
        _ = try await service.createAgent(AgentCreateRequest(id: agentID, displayName: "Cron", role: "Assistant"))
        let session = try await service.createAgentSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Existing chat"))
        _ = try await service.postAgentSessionMessage(
            agentID: agentID, sessionID: session.id,
            request: AgentSessionPostMessageRequest(userId: "owner", content: "Previous conversation")
        )
        let before = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
        _ = try await service.createAgentCronTask(
            agentID: agentID,
            request: AgentCronTaskCreateRequest(channelId: bareSessionID ? session.id : sessionChannelID(agentID: agentID, sessionID: session.id), schedule: "* * * * *", command: "Continue scheduled work")
        )
        let runner = await service.makeCronRunner()
        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_200))
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
        #expect(detail.events.count > before.events.count)
        #expect(Array(detail.events.prefix(before.events.count)) == before.events)
        #expect(detail.events.contains(where: { $0.message?.userId == "system_cron" && $0.message?.segments.first?.text?.contains("Continue scheduled work") == true }))
        #expect(detail.events.contains(where: { $0.message?.role == .assistant && $0.message?.segments.first?.text == "tool delegate used" }))
        #expect(try await service.listAgentSessions(agentID: agentID).count == 1)
        await service.shutdownChannelPlugins()
    }

    @Test("cron enters the durable Long Chat inbox using the conversation owner", arguments: [false, true])
    func cronResumesLongChat(bareSessionID: Bool) async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "cron-long-\(UUID().uuidString.lowercased())"
        _ = try await service.createAgent(AgentCreateRequest(id: agentID, displayName: "Cron", role: "Assistant"))
        let session = try await service.openLongChat(agentID: agentID, userID: "owner")
        _ = try await service.createAgentCronTask(
            agentID: agentID,
            request: AgentCronTaskCreateRequest(
                channelId: bareSessionID ? session.id : sessionChannelID(agentID: agentID, sessionID: session.id),
                schedule: "* * * * *", command: "Scheduled coordinator work"
            )
        )
        let runner = await service.makeCronRunner()
        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_200))
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
        #expect(detail.events.contains(where: {
            $0.message?.userId == "owner" && $0.message?.segments.first?.text?.contains("Scheduled coordinator work") == true
        }))
        let turns = try await service.cronInboxTurnsForTests()
        #expect(turns.count == 1)
        #expect(turns.first?.sessionId == session.id)
        #expect(turns.first?.request.userId == "owner")
        await service.shutdownChannelPlugins()
    }

    @Test("cron API accepts the documented CLI payload and rejects invalid schedules")
    func cronAPIValidatesScheduleAndDefaultsTarget() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        _ = try await service.createAgent(AgentCreateRequest(id: "cron-api", displayName: "Cron", role: "Assistant"))
        let router = CoreRouter(service: service)
        let path = "/v1/agents/cron-api/cron"
        let response = await router.handle(
            method: "POST", path: path,
            body: Data(#"{"schedule":"0 9 * * 1-5","command":"Daily check"}"#.utf8)
        )
        #expect(response.status == 201)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(AgentCronTask.self, from: response.body)
        #expect(task.channelId == "main")
        let invalid = await router.handle(
            method: "POST", path: path,
            body: Data(#"{"schedule":"60 * * * *","command":"Daily check"}"#.utf8)
        )
        #expect(invalid.status == 400)
        let update = await router.handle(
            method: "PUT", path: path + "/" + task.id,
            body: Data(#"{"schedule":"*/0 * * * *"}"#.utf8)
        )
        #expect(update.status == 400)
        let saved = try await service.listAgentCronTasks(agentID: "cron-api")
        #expect(saved.count == 1)
        #expect(saved.first?.schedule == "0 9 * * 1-5")
        await service.shutdownChannelPlugins()
    }

    @Test("explicit external channels still receive cron messages")
    func cronPostsToExternalChannel() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "cron-external-\(UUID().uuidString.lowercased())"
        _ = try await service.createAgent(AgentCreateRequest(id: agentID, displayName: "Cron", role: "Assistant"))
        _ = try await service.createAgentCronTask(agentID: agentID, request: .init(
            channelId: "external-general", schedule: "* * * * *", command: "External check"
        ))
        let runner = await service.makeCronRunner()
        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_200))
        let state = await service.getChannelState(channelId: "external-general")
        #expect(state?.messages.contains(where: { $0.userId == "system_cron" }) == true)
        #expect(try await service.listAgentSessions(agentID: agentID).isEmpty)
        await service.shutdownChannelPlugins()
    }

    @Test("a missing chat fails without creating an invisible channel or blocking the next job")
    func missingChatDoesNotBlockOtherCronTasks() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "cron-missing-\(UUID().uuidString.lowercased())"
        _ = try await service.createAgent(AgentCreateRequest(id: agentID, displayName: "Cron", role: "Assistant"))
        _ = try await service.createAgentCronTask(agentID: agentID, request: .init(
            channelId: "session-missing", schedule: "* * * * *", command: "Missing chat"
        ))
        _ = try await service.createAgentCronTask(agentID: agentID, request: .init(
            schedule: "* * * * *", command: "Next job"
        ))
        let runner = await service.makeCronRunner()
        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_200))
        #expect(await service.getChannelState(channelId: "session-missing") == nil)
        let sessions = try await service.listAgentSessions(agentID: agentID)
        #expect(sessions.count == 1)
        #expect(sessions.first?.title == "Cron: Next job")
        await service.shutdownChannelPlugins()
    }

    @Test("postChannelMessage uses linked agent tool delegate for agent-bound channels")
    func postChannelMessageUsesLinkedAgentToolDelegate() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "cron-linked-\(UUID().uuidString.lowercased())"
        _ = try await service.createAgent(
            AgentCreateRequest(
                id: agentID,
                displayName: "Cron Linked",
                role: "Use tools when invoked from a linked channel."
            )
        )
        await service.overrideModelProviderForTests(DelegateAwareToolCallingModelProvider(), defaultModel: "mock:linked-agent")

        let decision = await service.postChannelMessage(
            channelId: "agent:\(agentID)",
            request: ChannelMessageRequest(
                userId: "system_cron_test",
                content: "List your tools."
            )
        )

        #expect(decision.action == .respond)

        let snapshot = await service.getChannelState(channelId: "agent:\(agentID)")
        let systemReply = snapshot?.messages.last(where: { $0.userId == "system" })?.content
        #expect(systemReply == "tool delegate used")
    }

    @Test("cron runner posts due tasks through injected channel message poster")
    func cronRunnerPostsDueTasksThroughInjectedPoster() async throws {
        let store = InMemoryCorePersistenceBuilder().makeStore(config: .test)
        let cronTask = AgentCronTask(
            id: "cron-1",
            agentId: "agent-1",
            channelId: "agent:agent-1",
            schedule: "* * * * *",
            command: "Ping the linked agent",
            enabled: true
        )
        await store.saveCronTask(cronTask)

        let probe = CronMessagePosterProbe()
        let runner = CronRunner(store: store) { channelId, request in
            await probe.record(channelId: channelId, request: request)
        }

        await runner.triggerImmediately(date: Date(timeIntervalSince1970: 1_704_067_200))

        let requests = await probe.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.channelId == "agent:agent-1")
        #expect(requests.first?.request.userId == "system_cron")
        #expect(requests.first?.request.content.contains("CRON TRIGGER: Ping the linked agent") == true)
    }

    @Test("disabled and not-due tasks are skipped and ticks deduplicate within a minute")
    func cronRunnerSkipsDisabledAndDuplicateTicks() async {
        let store = InMemoryCorePersistenceBuilder().makeStore(config: .test)
        for (id, schedule, enabled) in [("due", "* * * * *", true), ("disabled", "* * * * *", false), ("later", "59 * * * *", true)] {
            await store.saveCronTask(AgentCronTask(id: id, agentId: "agent", channelId: id, schedule: schedule, command: id, enabled: enabled))
        }
        let probe = CronMessagePosterProbe()
        let runner = CronRunner(store: store) { channelId, request in
            await probe.record(channelId: channelId, request: request)
        }
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        await runner.triggerImmediately(date: date)
        await runner.triggerImmediately(date: date.addingTimeInterval(10))
        #expect(await probe.snapshot().map(\.channelId) == ["due"])
        await runner.triggerImmediately(date: date.addingTimeInterval(60))
        #expect(await probe.snapshot().map(\.channelId) == ["due", "due"])
    }
}
