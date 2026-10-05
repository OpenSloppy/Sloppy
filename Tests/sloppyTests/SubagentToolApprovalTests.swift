import Foundation
import Protocols
import Testing
@testable import sloppy

@Suite("Conversation worker tool approvals")
struct SubagentToolApprovalTests {
    @Test func executionWorkerCanRunShellWithoutAnExtraApproval() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: false)
        let result = await service.invokeToolFromRuntime(
            agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("implementation"))
        #expect(result.ok)
        #expect(await service.listPendingToolApprovals().isEmpty)
    }

    @Test func readOnlyExecAsksUserEvenWhenSessionBypassesApprovals() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        await service.setSessionToolApprovalBypass(sessionID: worker.childID, enabled: true)
        let invocation = Task {
            await service.invokeToolFromRuntime(
                agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("approved"))
        }
        let pending = try await pendingApproval(service)
        #expect(pending.sessionId == worker.childID)
        #expect(pending.displaySessionId == worker.parentID)
        _ = await service.approveToolApproval(id: pending.id, decidedBy: "user", scope: .once)
        #expect((await invocation.value).ok)

        let second = Task {
            await service.invokeToolFromRuntime(
                agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("rejected"))
        }
        let next = try await pendingApproval(service)
        _ = await service.rejectToolApproval(id: next.id, decidedBy: "user")
        #expect((await second.value).error?.code == "tool_approval_rejected")
        let write = await service.invokeToolFromRuntime(
            agentID: worker.agentID, sessionID: worker.childID,
            request: .init(tool: "files.write", arguments: ["path": .string("unapproved.txt"), "content": .string("no")]))
        #expect(write.error?.code == "tool_forbidden")
    }

    @Test func semanticReviewGetsOriginalUserScopeAndApprovesOneCall() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        let provider = ApprovalDecisionProvider(choice: "approve", confidence: 0.99)
        await service.semanticModelRouter.setProviderFactory { _ in provider }
        let result = await service.invokeToolFromRuntime(
            agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("reviewed"))
        #expect(result.ok)
        #expect(await service.listPendingToolApprovals().isEmpty)
        let requests = await provider.requests
        let request = try #require(requests.first)
        #expect(request.questionID == "subagent_tool_approval")
        let context = try #require(JSONSerialization.jsonObject(with: Data(request.state.utf8)) as? [String: Any])
        #expect(context["userRequest"] as? String == "Inspect this workspace and verify the result.")
        #expect(context["objective"] as? String == "Inspect the assigned workspace")
        #expect(context["readOnly"] as? Bool == true)
        #expect((context["arguments"] as? [String: Any])?["command"] as? String == "/bin/echo")
        #expect((await service.sessionApprovalGrants(
            agentID: worker.agentID, sessionID: worker.childID, channelID: nil)).isEmpty)
        let parent = try await service.getAgentSession(agentID: worker.agentID, sessionID: worker.parentID)
        #expect(!parent.events.contains { $0.runStatus?.label == "Tool approval required" })
    }

    @Test func readOnlyWorkerCanRequestDisabledExecAndCatalogMatchesItsScope() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        _ = try await service.updateAgentToolsPolicy(agentID: worker.agentID,
            request: .init(tools: ["runtime.exec": false]))
        try await service.restoreLongChatWorkerScope(agentID: worker.agentID, childID: worker.childID)
        let catalog = await service.invokeToolFromRuntime(
            agentID: worker.agentID, sessionID: worker.childID, request: .init(tool: "system.list_tools", arguments: [:]))
        let names = Set(catalog.data?.asArray?.compactMap { $0.asObject?["name"]?.asString } ?? [])
        #expect(names.contains("runtime.exec"))
        #expect(!names.contains("files.write"))
        #expect(!names.contains("workers.spawn"))
        let invocation = Task {
            await service.invokeToolFromRuntime(
                agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("disabled-policy"))
        }
        let pending = try await pendingApproval(service)
        #expect(pending.approvalKind == .missingAccess)
        _ = await service.approveToolApproval(id: pending.id, decidedBy: "user")
        #expect((await invocation.value).ok)
    }

    @Test func missingDirectoryApprovalAlsoApprovesTheExactReadOnlyCommand() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        await service.setSessionToolApprovalBypass(sessionID: worker.childID, enabled: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = echoRequest("directory")
        request.arguments["cwd"] = .string(directory.path)
        let command = request
        let invocation = Task {
            await service.invokeToolFromRuntime(agentID: worker.agentID, sessionID: worker.childID, request: command)
        }
        let pending = try await pendingApproval(service)
        #expect(pending.approvalKind == .missingAccess)
        _ = await service.approveToolApproval(id: pending.id, decidedBy: "user")
        #expect((await invocation.value).ok)
        #expect(await service.listPendingToolApprovals().isEmpty)
    }

    @Test func semanticRejectionPreventsShellEffects() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        let provider = ApprovalDecisionProvider(choice: "reject", confidence: 0.99)
        await service.semanticModelRouter.setProviderFactory { _ in provider }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = await service.invokeToolFromRuntime(
            agentID: worker.agentID, sessionID: worker.childID,
            request: .init(tool: "runtime.exec", arguments: [
                "command": .string("/usr/bin/touch"), "arguments": .array([.string(marker.path)]),
            ]))
        #expect(result.error?.code == "tool_approval_rejected")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: ["ask_user", "low_confidence", "nonfinite", "invalid", "unavailable"])
    func uncertainReviewFallsBackToUser(mode: String) async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        let provider = ApprovalDecisionProvider(
            choice: ["low_confidence", "nonfinite"].contains(mode) ? "approve" : mode,
            confidence: mode == "nonfinite" ? .nan : (mode == "low_confidence" ? 0.1 : 0.99),
            unavailable: mode == "unavailable")
        await service.semanticModelRouter.setProviderFactory { _ in provider }
        let invocation = Task {
            await service.invokeToolFromRuntime(
                agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("needs-user"))
        }
        let pending = try await pendingApproval(service)
        #expect(pending.displaySessionId == worker.parentID)
        _ = await service.approveToolApproval(id: pending.id, decidedBy: "user")
        #expect((await invocation.value).ok)
    }

    @Test(arguments: [false, true])
    func missingAuthorityOrOversizedArgumentsRequireUser(oversized: Bool) async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(
            readOnly: true, userRequest: oversized ? "Inspect this workspace and verify the result." : "")
        let provider = ApprovalDecisionProvider(choice: "approve", confidence: 0.99)
        await service.semanticModelRouter.setProviderFactory { _ in provider }
        let request = echoRequest(oversized ? String(repeating: "x", count: 20_000) : "no-authority")
        let invocation = Task {
            await service.invokeToolFromRuntime(agentID: worker.agentID, sessionID: worker.childID, request: request)
        }
        let pending = try await pendingApproval(service)
        #expect(await provider.requests.isEmpty)
        _ = await service.rejectToolApproval(id: pending.id, decidedBy: "user")
        #expect((await invocation.value).error?.code == "tool_approval_rejected")
    }

    @Test func cancellationWhileApprovalIsPendingPreventsExecution() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true)
        let invocation = Task {
            await service.invokeToolFromRuntime(
                agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("cancelled"))
        }
        let pending = try await pendingApproval(service)
        try await service.cancelLongChatTasks(agentID: worker.agentID, sessionID: worker.parentID, taskID: worker.taskID)
        _ = await service.approveToolApproval(id: pending.id, decidedBy: "user")
        #expect((await invocation.value).error?.code == "tool_forbidden")
    }

    @Test func workerNotificationCannotSupplyUserAuthorization() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        defer { Task { await service.stop() } }
        let worker = try await service.prepareApprovalWorker(readOnly: true, notificationSource: true)
        let provider = ApprovalDecisionProvider(choice: "approve", confidence: 0.99)
        await service.semanticModelRouter.setProviderFactory { _ in provider }
        let invocation = Task {
            await service.invokeToolFromRuntime(
                agentID: worker.agentID, sessionID: worker.childID, request: echoRequest("notification"))
        }
        let pending = try await pendingApproval(service)
        #expect(await provider.requests.isEmpty)
        _ = await service.rejectToolApproval(id: pending.id, decidedBy: "user")
        #expect((await invocation.value).error?.code == "tool_approval_rejected")
    }

    private func echoRequest(_ text: String) -> ToolInvocationRequest {
        .init(tool: "runtime.exec", arguments: ["command": .string("/bin/echo"), "arguments": .array([.string(text)])])
    }

    private func pendingApproval(_ service: CoreService) async throws -> ToolApprovalRecord {
        for _ in 0..<200 {
            if let pending = await service.listPendingToolApprovals().first { return pending }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ApprovalTestError.noPendingApproval
    }
}

private enum ApprovalTestError: Error { case noPendingApproval, unavailable }

private actor ApprovalDecisionProvider: SemanticDecisionProvider {
    var requests: [SemanticChoiceRequest] = []
    let choice: String
    let confidence: Double
    let unavailable: Bool

    init(choice: String, confidence: Double, unavailable: Bool = false) {
        self.choice = choice
        self.confidence = confidence
        self.unavailable = unavailable
    }

    func choose(_ request: SemanticChoiceRequest) async throws -> SemanticChoiceResponse {
        requests.append(request)
        if unavailable { throw ApprovalTestError.unavailable }
        return .init(choice: choice, confidence: confidence, probabilities: [:],
                     usage: .init(inputTokens: 10, outputTokens: 0, costUSD: 0, costIsEstimated: false))
    }
}

private struct ApprovalTestWorker: Sendable {
    var agentID: String
    var parentID: String
    var childID: String
    var taskID: String
}

private extension CoreService {
    func prepareApprovalWorker(
        readOnly: Bool, userRequest: String = "Inspect this workspace and verify the result.",
        notificationSource: Bool = false
    ) async throws -> ApprovalTestWorker {
        let agentID = "approval-worker"
        _ = try await createAgent(.init(id: agentID, displayName: "Worker", role: "Test"))
        let parent = try await openLongChat(agentID: agentID, userID: "user")
        let source = AgentSessionMessage(id: "source", role: notificationSource ? .system : .user,
                                        segments: [.init(kind: .text, text: userRequest)])
        _ = try sessionStore.appendEvents(agentID: agentID, sessionID: parent.id, events: [
            .init(agentId: agentID, sessionId: parent.id, type: .message, message: source),
        ])
        if notificationSource {
            try longChats().transaction {
                $0.turns.append(.init(id: source.id, agentId: agentID, sessionId: parent.id,
                                     request: .init(userId: "user", content: userRequest), isNotification: true,
                                     delivered: true))
            }
        }
        let assignment = try longChats().delegate(sessionId: parent.id, sourceMessageId: source.id,
            request: .init(requestKey: "request", title: "Inspection", acceptanceCriteria: "Result verified",
                           tasks: [.init(key: "inspect", title: "Inspect", objective: "Inspect the assigned workspace",
                                         resourceKeys: ["workspace:" + workspaceRootURL.path], readOnly: readOnly)]))
        let taskID = assignment.tasks[0].id
        let child = try sessionStore.createSession(agentID: agentID,
            request: .init(title: "Worker", parentSessionId: parent.id, kind: .longChatWorker))
        try longChats().updateTask(sessionId: parent.id, taskId: taskID) {
            $0.attempts[0].status = .running
            $0.attempts[0].sessionId = child.id
        }
        sessionWorkingDirectories[child.id] = workspaceRootURL.path
        try await restoreLongChatWorkerScope(agentID: agentID, childID: child.id)
        return .init(agentID: agentID, parentID: parent.id, childID: child.id, taskID: taskID)
    }
}
