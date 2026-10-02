import Foundation
import Protocols
import SloppyRuntime
import Testing

@testable import sloppy

@Suite("Long chat durable scheduling")
struct LongChatTests {
    private func makeStore() throws -> (LongChatFileStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("long-chat-tests-\(UUID().uuidString)")
        let store = try LongChatFileStore(root: root)
        try store.transaction {
            $0.conversations.append(.init(agentId: "agent", userId: "user", sessionId: "session-test", assignments: []))
        }
        return (store, root)
    }

    private func request(_ tasks: [LongChatTaskRequest], key: String = "request") -> LongChatDelegationRequest {
        .init(requestKey: key, title: "Assignment", acceptanceCriteria: "Both outcomes verified", tasks: tasks)
    }

    @Test func persistsAssignmentsAndDeduplicatesDelegation() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = request([
            .init(
                key: "report", title: "Report", objective: "Publish the authorized report", resourceKeys: ["ticket:123"]
            )
        ])
        let first = try store.delegate(sessionId: "session-test", sourceMessageId: "source", request: payload)
        let again = try store.delegate(sessionId: "session-test", sourceMessageId: "source", request: payload)
        #expect(first.id == again.id)
        let reopened = try LongChatFileStore(root: root)
        #expect(try reopened.conversation(sessionId: "session-test").assignments == [first])
    }

    @Test func independentTasksParallelizeAndResourceChangesSerialize() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.delegate(
            sessionId: "session-test", sourceMessageId: "source",
            request: request([
                .init(key: "one", title: "One", objective: "Edit", resourceKeys: ["project:p"]),
                .init(key: "two", title: "Two", objective: "Edit", resourceKeys: ["project:p"]),
                .init(key: "read", title: "Read", objective: "Read"),
                .init(key: "other", title: "Other", objective: "Other", resourceKeys: ["ticket:b"]),
                .init(key: "four", title: "Four", objective: "Four"),
            ]))
        let ready = try store.runnableTasks(sessionId: "session-test")
        #expect(ready.map(\.task.key) == ["one", "read", "other"])
        for (_, task) in ready {
            try store.updateTask(sessionId: "session-test", taskId: task.id) { $0.attempts[0].status = .running }
        }
        #expect(try store.runnableTasks(sessionId: "session-test").isEmpty)
        try store.updateTask(sessionId: "session-test", taskId: ready[0].task.id) { $0.attempts[0].status = .completed }
        #expect(try store.runnableTasks(sessionId: "session-test").map(\.task.key) == ["two"])
    }

    @Test func dependenciesWaitForSuccessAndCyclesAreRejected() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let assignment = try store.delegate(
            sessionId: "session-test", sourceMessageId: "source",
            request: request([
                .init(key: "first", title: "First", objective: "Implement"),
                .init(key: "second", title: "Second", objective: "Report", dependsOn: ["first"]),
            ]))
        #expect(try store.runnableTasks(sessionId: "session-test").map(\.task.key) == ["first"])
        try store.updateTask(sessionId: "session-test", taskId: assignment.tasks[0].id) {
            $0.attempts[0].status = .failed
        }
        #expect(try store.runnableTasks(sessionId: "session-test").isEmpty)
        #expect(throws: LongChatFileStore.StoreError.self) {
            try store.delegate(
                sessionId: "session-test", sourceMessageId: "cycle",
                request: request([
                    .init(key: "a", title: "A", objective: "A", dependsOn: ["b"]),
                    .init(key: "b", title: "B", objective: "B", dependsOn: ["a"]),
                ]))
        }
    }

    @Test func coordinatorFailsClosedAndAllowsOnlyOwnMemory() {
        for tool in [
            "files.write", "files.edit", "runtime.exec", "runtime.process", "agents.delegate_task", "workers.spawn",
            "mcp.read_and_delete", "web.request",
        ] {
            #expect(!LongChatCoordinatorPolicy.allows(.init(tool: tool, arguments: [:]), agentID: "agent"))
        }
        #expect(LongChatCoordinatorPolicy.allows(.init(tool: "files.read", arguments: [:]), agentID: "agent"))
        #expect(LongChatCoordinatorPolicy.allows(.init(tool: "long_chat.delegate", arguments: [:]), agentID: "agent"))
        #expect(
            LongChatCoordinatorPolicy.allows(
                .init(tool: "memory.save", arguments: ["scope_type": .string("agent"), "scope_id": .string("agent")]),
                agentID: "agent"))
        #expect(
            !LongChatCoordinatorPolicy.allows(
                .init(
                    tool: "memory.save", arguments: ["scope_type": .string("global"), "scope_id": .string("shared")]),
                agentID: "agent"))
    }

    @Test func corruptStorageDoesNotSilentlyEraseAssignments() throws {
        let (_, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid".utf8).write(to: root.appendingPathComponent("long-chat/state.json"))
        #expect(throws: DecodingError.self) { try LongChatFileStore(root: root) }
    }
}

@Suite("Long chat Core API")
struct LongChatAPITests {
    private func service() async throws -> CoreService {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        _ = try await service.createAgent(.init(id: "long-agent", displayName: "Long Agent", role: "Testing"))
        return service
    }

    @Test func openIsAtomicAndMessagesHaveImmediateDeduplicatedReceipts() async throws {
        let service = try await service()
        defer { Task { await service.stop() } }
        async let first = service.openLongChat(agentID: "long-agent", userID: "local")
        async let second = service.openLongChat(agentID: "long-agent", userID: "local")
        let (a, b) = try await (first, second)
        #expect(a.id == b.id)
        #expect(a.kind == .longChat)
        let other = try await service.openLongChat(agentID: "long-agent", userID: "another-user")
        #expect(a.id != other.id)
        let id = UUID().uuidString
        let request = AgentSessionPostMessageRequest(userId: "local", content: "Hello", clientMessageId: id)
        let receipt = try await service.postAgentSessionMessage(
            agentID: "long-agent", sessionID: a.id, request: request)
        #expect(receipt.appendedEvents.first?.message?.id == id)
        _ = try await service.postAgentSessionMessage(agentID: "long-agent", sessionID: a.id, request: request)
        let detail = try await service.getAgentSession(agentID: "long-agent", sessionID: a.id)
        #expect(detail.events.filter { $0.message?.id == id }.count == 1)
    }

    @Test func coordinatorBlocksMutationBeforeAnyApprovalRequest() async throws {
        let service = try await service()
        defer { Task { await service.stop() } }
        let chat = try await service.openLongChat(agentID: "long-agent", userID: "local")
        for tool in ["files.write", "runtime.exec", "mcp.unknown", "agents.delegate_task", "workers.spawn"] {
            let result = await service.invokeToolFromRuntime(
                agentID: "long-agent", sessionID: chat.id, request: .init(tool: tool, arguments: [:]))
            #expect(result.error?.code == "tool_forbidden")
        }
        #expect(await service.listPendingToolApprovals().isEmpty)
    }

    @Test func routerUsesAuthenticatedOwnerRatherThanCallerSuppliedUserID() async throws {
        let service = try await service()
        defer { Task { await service.stop() } }
        let router = CoreRouter(service: service)
        let body = try JSONEncoder().encode(LongChatOpenRequest(userId: "spoofed"))
        let response = await router.handle(method: "POST", path: "/v1/agents/long-agent/long-chat", body: body)
        #expect(response.status == 200)
        let sessions = try await service.listAgentSessions(agentID: "long-agent")
        let chat = try #require(sessions.first(where: { $0.kind == .longChat }))
        #expect(try await service.getLongChat(agentID: "long-agent", sessionID: chat.id).userId == "local")
        let message = try JSONEncoder().encode(AgentSessionPostMessageRequest(userId: "spoofed", content: "Hi"))
        let sent = await router.handle(
            method: "POST", path: "/v1/agents/long-agent/sessions/\(chat.id)/messages", body: message)
        #expect(sent.status == 200)
    }

    @Test func twoWorkersDoNotBlockNewMessagesAndResultsAreDeliveredOnce() async throws {
        let service = try await service()
        defer { Task { await service.stop() } }
        let chat = try await service.openLongChat(agentID: "long-agent", userID: "local")
        let assignment = try await service.reserveLongChatTestAssignment(
            sessionID: chat.id,
            request: .init(
                requestKey: "two", title: "Two jobs", acceptanceCriteria: "Both verified",
                tasks: [
                    .init(key: "a", title: "Report", objective: "Report"),
                    .init(key: "b", title: "Finish", objective: "Finish"),
                ]))
        let childA = try await service.attachLongChatTestWorker(
            sessionID: chat.id, taskID: assignment.tasks[0].id, agentID: "long-agent")
        _ = try await service.attachLongChatTestWorker(
            sessionID: chat.id, taskID: assignment.tasks[1].id, agentID: "long-agent")
        let receipt = try await service.postAgentSessionMessage(
            agentID: "long-agent", sessionID: chat.id, request: .init(userId: "local", content: "A third topic"))
        #expect(receipt.appendedEvents.contains { $0.message?.role == .user })
        #expect(
            try await service.getLongChat(agentID: "long-agent", sessionID: chat.id).assignments[0].tasks.allSatisfy {
                $0.status == .running
            })
        let finish = AgentSessionEvent(
            agentId: "long-agent", sessionId: childA, type: .toolResult,
            toolResult: .init(
                tool: "agent_delegate.finish", ok: true,
                data: .object([
                    "status": .string("completed"), "summary": .string("Published"),
                    "evidence": .array([.string("Verified response")]),
                    "artifacts": .array([.string("https://example.com/report")]),
                ])))
        _ = try await service.appendAgentSessionEvents(
            agentID: "long-agent", sessionID: childA, request: .init(events: [finish]))
        await service.reconcileLongChatWorker(agentID: "long-agent", childID: childA)
        await service.reconcileLongChatWorker(agentID: "long-agent", childID: childA)
        let updated = try await service.currentLongChatTask(sessionID: chat.id, taskID: assignment.tasks[0].id)
        #expect(updated.status == .completed)
        #expect(updated.attempts.last?.evidence == ["Verified response"])
        let parent = try await service.getAgentSession(agentID: "long-agent", sessionID: chat.id)
        #expect(
            parent.events.filter { $0.longChatTask?.task.id == updated.id && $0.longChatTask?.reason == "completed" }
                .count == 1)
        #expect(try await service.listAgentSessions(agentID: "long-agent").allSatisfy { $0.parentSessionId != chat.id })
    }

    @Test func missingStructuredFinishIsFailure() async throws {
        let service = try await service()
        defer { Task { await service.stop() } }
        let chat = try await service.openLongChat(agentID: "long-agent", userID: "local")
        let assignment = try await service.reserveLongChatTestAssignment(
            sessionID: chat.id,
            request: .init(
                requestKey: "missing", title: "Missing finish", acceptanceCriteria: "Verified",
                tasks: [.init(key: "t", title: "Work", objective: "Work")]))
        let taskID = assignment.tasks[0].id
        let child = try await service.attachLongChatTestWorker(
            sessionID: chat.id, taskID: taskID, agentID: "long-agent")
        await service.reconcileLongChatWorker(agentID: "long-agent", childID: child)
        #expect(try await service.currentLongChatTask(sessionID: chat.id, taskID: taskID).status == .failed)
    }

    @Test func restartPreservesWaitingInputAndDoesNotReplayInterruptedChanges() async throws {
        let config = CoreConfig.test
        let first = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
        _ = try await first.createAgent(.init(id: "long-agent", displayName: "Long Agent", role: "Testing"))
        let chat = try await first.openLongChat(agentID: "long-agent", userID: "local")
        let assignment = try await first.reserveLongChatTestAssignment(
            sessionID: chat.id,
            request: .init(
                requestKey: "restart", title: "Restart", acceptanceCriteria: "Verified",
                tasks: [
                    .init(key: "a", title: "Await answer", objective: "Await answer"),
                    .init(key: "b", title: "Modify", objective: "Modify", resourceKeys: ["ticket:1"]),
                ]))
        let child = try await first.attachLongChatTestWorker(
            sessionID: chat.id, taskID: assignment.tasks[0].id, agentID: "long-agent")
        _ = try await first.attachLongChatTestWorker(
            sessionID: chat.id, taskID: assignment.tasks[1].id, agentID: "long-agent")
        let input = PlanInputRequest(
            title: "Choose",
            questions: [
                .init(
                    id: "q", question: "Which destination?",
                    options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")])
            ])
        _ = try await first.appendAgentSessionEvents(
            agentID: "long-agent", sessionID: child,
            request: .init(events: [
                .init(agentId: "long-agent", sessionId: child, type: .inputRequest, inputRequest: input)
            ]))
        await first.reconcileLongChatWorker(agentID: "long-agent", childID: child)
        await first.stop()
        let second = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
        await second.waitForStartup()
        let state = try await second.getLongChat(agentID: "long-agent", sessionID: chat.id)
        #expect(state.assignments[0].tasks[0].status == .waitingInput)
        #expect(state.assignments[0].tasks[1].status == .failed)
        #expect(state.assignments[0].tasks[1].attempts.last?.automaticRetryAllowed == false)
        await #expect(throws: LongChatFileStore.StoreError.self) {
            try await second.retryLongChatTask(
                agentID: "long-agent", sessionID: chat.id, taskID: assignment.tasks[1].id, automatic: true)
        }
        #expect(
            try await second.getAgentSession(agentID: "long-agent", sessionID: child).events.contains {
                $0.inputRequest?.id == input.id
            })
        await second.stop()
    }

    @Test func cancelPersistsBeforeLateResultsAndRetryKeepsHistory() async throws {
        let service = try await service()
        defer { Task { await service.stop() } }
        let chat = try await service.openLongChat(agentID: "long-agent", userID: "local")
        let payload = LongChatDelegationRequest(
            requestKey: "test", title: "Test", acceptanceCriteria: "Verified",
            tasks: [.init(key: "t", title: "Work", objective: "Work")])
        // Persist without starting so the cancellation race is deterministic.
        let assignment = try await service.reserveLongChatTestAssignment(sessionID: chat.id, request: payload)
        let taskID = assignment.tasks[0].id
        try await service.cancelLongChatTasks(agentID: "long-agent", sessionID: chat.id, taskID: taskID)
        #expect(try await service.currentLongChatTask(sessionID: chat.id, taskID: taskID).status == .cancelled)
        await #expect(throws: LongChatFileStore.StoreError.self) {
            try await service.retryLongChatTask(
                agentID: "long-agent", sessionID: chat.id, taskID: taskID, automatic: true)
        }
        try await service.retryLongChatTask(agentID: "long-agent", sessionID: chat.id, taskID: taskID)
        let retried = try await service.currentLongChatTask(sessionID: chat.id, taskID: taskID)
        #expect(retried.attempts.count == 2)
        #expect(retried.attempts[0].status == .cancelled)
    }
}

extension CoreService {
    fileprivate func reserveLongChatTestAssignment(sessionID: String, request: LongChatDelegationRequest) throws
        -> LongChatAssignment
    {
        try longChats().delegate(sessionId: sessionID, sourceMessageId: "source", request: request)
    }
    fileprivate func attachLongChatTestWorker(sessionID: String, taskID: String, agentID: String) throws -> String {
        let child = try sessionStore.createSession(
            agentID: agentID, request: .init(title: "Worker", parentSessionId: sessionID))
        try longChats().updateTask(sessionId: sessionID, taskId: taskID) {
            $0.attempts[$0.attempts.count - 1].status = .running
            $0.attempts[$0.attempts.count - 1].sessionId = child.id
        }
        return child.id
    }
}

@Test func longChatWorkersUseOriginalPolicyAndReadOnlyTasksCannotMutate() async {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let policy = AgentToolsPolicy(defaultPolicy: .allow)
    var task = LongChatTask(
        id: "t", key: "t", title: "Work", objective: "Work", projectId: nil, resourceKeys: ["ticket:123"],
        dependsOn: [], attempts: [.init(number: 1)])
    let known: Set<String> = [
        "files.read", "files.write", "agent_delegate.finish", "agents.delegate_task", "long_chat.delegate",
    ]
    let execution = await service.longChatWorkerTools(task: task, policy: policy, known: known)
    #expect(execution.contains("files.write"))
    #expect(!execution.contains("agents.delegate_task"))
    #expect(!execution.contains("long_chat.delegate"))
    task.resourceKeys = []
    let readOnly = await service.longChatWorkerTools(task: task, policy: policy, known: known)
    #expect(readOnly.contains("files.read"))
    #expect(readOnly.contains("agent_delegate.finish"))
    #expect(!readOnly.contains("files.write"))
    await service.stop()
}

@Test func longChatDependencyFailureAndRepairDoNotLoseDependentWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("long-dependency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LongChatFileStore(root: root)
    try store.transaction { $0.conversations.append(.init(agentId: "a", userId: "u", sessionId: "s", assignments: [])) }
    let assignment = try store.delegate(
        sessionId: "s", sourceMessageId: "m",
        request: .init(
            requestKey: "r", title: "Work", acceptanceCriteria: "Verified",
            tasks: [
                .init(key: "a", title: "Implement", objective: "Implement"),
                .init(key: "b", title: "Report", objective: "Report", dependsOn: ["a"]),
            ]))
    try store.updateTask(sessionId: "s", taskId: assignment.tasks[0].id) { $0.attempts[0].status = .failed }
    _ = try store.resolveDependencies(sessionId: "s")
    let failed = try store.conversation(sessionId: "s").assignments[0]
    #expect(failed.isTerminal)
    #expect(failed.tasks[1].attempts[0].blockedByTaskId == failed.tasks[0].id)
    try store.updateTask(sessionId: "s", taskId: assignment.tasks[0].id) { $0.attempts.append(.init(number: 2)) }
    _ = try store.resolveDependencies(sessionId: "s")
    #expect(try store.conversation(sessionId: "s").assignments[0].tasks[1].status == .queued)
    #expect(try store.runnableTasks(sessionId: "s").map(\.task.key) == ["a"])
}

@Test func longChatOnlyAllowsMCPWithExplicitReadOnlyMetadata() {
    let request = ToolInvocationRequest(tool: "mcp.tracker.get", arguments: [:])
    #expect(!LongChatCoordinatorPolicy.allows(request, agentID: "a"))
    #expect(LongChatCoordinatorPolicy.allows(request, agentID: "a", readOnlyMCPTools: ["mcp.tracker.get"]))
    #expect(
        !LongChatCoordinatorPolicy.allows(
            .init(tool: "mcp.tracker.delete", arguments: [:]), agentID: "a", readOnlyMCPTools: ["mcp.tracker.get"]))
}

@Test func longChatCancelledSourceCannotSpawnMoreWorkersAfterStopAll() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("long-stop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LongChatFileStore(root: root)
    try store.transaction {
        $0.conversations.append(.init(agentId: "a", userId: "u", sessionId: "s", assignments: []))
        $0.cancelledSourceMessageIds = ["cancelled-turn"]
    }
    let request = LongChatDelegationRequest(
        requestKey: "r", title: "Work", acceptanceCriteria: "Verified",
        tasks: [.init(key: "t", title: "Work", objective: "Work")])
    #expect(throws: LongChatFileStore.StoreError.self) {
        try store.delegate(sessionId: "s", sourceMessageId: "cancelled-turn", request: request)
    }
    #expect(try store.delegate(sessionId: "s", sourceMessageId: "new-turn", request: request).tasks.count == 1)
}
