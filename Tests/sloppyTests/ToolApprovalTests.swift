import Foundation
import Testing
@testable import ChannelPluginTelegram
@testable import Protocols
@testable import sloppy

@Suite("Tool approvals", .serialized)
struct ToolApprovalTests {

@Test
func largeWorkspaceDeletionUsesRiskyToolApprovalClassification() async {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let deleteOperations: [JSONValue] = (0..<10).map { index in
        .object([
            "type": .string(WorkspaceOperationKind.deleteElement.rawValue),
            "targetId": .string("element-\(index)"),
        ])
    }
    let largeDeletionRequiresApproval = await service.requiresHumanApproval(
        toolID: "workspace.transaction.apply",
        arguments: ["operations": .array(deleteOperations)]
    )
    let smallDeletionRequiresApproval = await service.requiresHumanApproval(
        toolID: "workspace.transaction.apply",
        arguments: ["operations": .array(Array(deleteOperations.prefix(9)))]
    )
    #expect(largeDeletionRequiresApproval)
    #expect(!smallDeletionRequiresApproval)
}

@Test
func toolApprovalIsDisabledByDefaultForRuntimeTools() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-default-off")

    let result = await service.invokeToolFromRuntime(
        agentID: "approval-default-off",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("/bin/echo"),
                "arguments": .array([.string("no-approval")])
            ]
        ),
        recordSessionEvents: false
    )

    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func toolsPolicyCanEnableToolApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-policy-on")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-policy-on",
        request: AgentToolsUpdateRequest(approval: AgentToolApprovalSettings(enabled: true))
    )

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-policy-on",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/echo"),
                    "arguments": .array([.string("policy-approved")])
                ]
            ),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.tool == "runtime.exec")

    let approved = await service.approveToolApproval(id: pending.id, decidedBy: "test")
    #expect(approved?.status == .approved)

    let result = await invocation.value
    #expect(result.ok == true)
}

@Test
func toolsPolicyCanEnableToolApprovalWithOnRequestPolicy() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-policy-on-request")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-policy-on-request",
        request: AgentToolsUpdateRequest(approval: AgentToolApprovalSettings(policy: .onRequest))
    )

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-policy-on-request",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/echo"),
                    "arguments": .array([.string("policy-on-request")])
                ]
            ),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.approvalKind == .riskyTool)

    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test")
    let result = await invocation.value
    #expect(result.ok == true)
}

@Test
func approveForMeUsesConfiguredReviewerAgentDecision() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-agent-reviewed")
    _ = try await service.createAgent(AgentCreateRequest(
        id: "security-reviewer",
        displayName: "Security Reviewer",
        role: "Review tool calls"
    ))
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-agent-reviewed",
        request: AgentToolsUpdateRequest(
            approval: AgentToolApprovalSettings(
                policy: .approveForMe,
                reviewerAgentId: "security-reviewer"
            )
        )
    )
    await service.setToolApprovalAgentReviewOverride { record, reviewerAgentID in
        #expect(record.tool == "runtime.exec")
        #expect(reviewerAgentID == "security-reviewer")
        return .approve(reason: "The read-only command is scoped and justified.")
    }

    let result = await service.invokeToolFromRuntime(
        agentID: "approval-agent-reviewed",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("/bin/echo"),
                "arguments": .array([.string("agent-approved")])
            ],
            reason: "Verify the command output"
        ),
        recordSessionEvents: false
    )

    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func approveForMeFailsClosedWhenReviewerRejects() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-agent-rejected")
    _ = try await service.createAgent(AgentCreateRequest(
        id: "cautious-reviewer",
        displayName: "Cautious Reviewer",
        role: "Reject unsafe tool calls"
    ))
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-agent-rejected",
        request: AgentToolsUpdateRequest(
            approval: AgentToolApprovalSettings(
                policy: .approveForMe,
                reviewerAgentId: "cautious-reviewer"
            )
        )
    )
    await service.setToolApprovalAgentReviewOverride { _, _ in
        .reject(reason: "The write is not justified.")
    }

    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-review-rejected-\(UUID().uuidString).txt")
    let result = await service.invokeToolFromRuntime(
        agentID: "approval-agent-rejected",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "files.write",
            arguments: ["path": .string(target.path), "content": .string("blocked")]
        ),
        recordSessionEvents: false
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "tool_approval_rejected")
    #expect(result.data?.asObject?["decidedBy"]?.asString == "agent:cautious-reviewer")
    #expect(result.data?.asObject?["decisionReason"]?.asString == "The write is not justified.")
    #expect(FileManager.default.fileExists(atPath: target.path) == false)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func autonomousSessionBypassesRiskyToolApprovalPrompt() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-autonomous-session")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-autonomous-session",
        request: AgentToolsUpdateRequest(approval: AgentToolApprovalSettings(enabled: true))
    )
    await service.setSessionToolApprovalBypass(sessionID: session.id, enabled: true)

    let result = await service.invokeToolFromRuntime(
        agentID: "approval-autonomous-session",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("/bin/echo"),
                "arguments": .array([.string("autonomous")])
            ]
        ),
        recordSessionEvents: false
    )

    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func autonomousSessionBypassesMissingDirectoryAccessApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-autonomous-directory")
    let file = try makeApprovalTempFile(contents: "autonomous")
    await service.setSessionToolApprovalBypass(sessionID: session.id, enabled: true)

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-autonomous-directory",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
            recordSessionEvents: false
        )
    }

    let pending = await waitForPendingToolApprovalIfAny(service)
    if let pending {
        _ = await service.rejectToolApproval(id: pending.id, decidedBy: "test")
    }

    let result = await invocation.value
    #expect(pending == nil)
    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func fullAccessSandboxBypassesMissingDirectoryAccessApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-full-access-directory")
    let file = try makeApprovalTempFile(contents: "full access")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-full-access-directory",
        request: AgentToolsUpdateRequest(
            approval: AgentToolApprovalSettings(policy: .onRequest),
            sandbox: AgentSandboxSettings(mode: .fullAccess)
        )
    )

    let result = await service.invokeToolFromRuntime(
        agentID: "approval-full-access-directory",
        sessionID: session.id,
        request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
        recordSessionEvents: false
    )

    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func temporaryDirectoryBypassesMissingDirectoryAccessApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-temp-directory")
    let file = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("sloppy-approval-\(UUID().uuidString)")
        .appendingPathComponent("fixture.txt")
        .standardizedFileURL
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let result = await service.invokeToolFromRuntime(
        agentID: "approval-temp-directory",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "files.write",
            arguments: [
                "path": .string(file.path),
                "content": .string("tmp")
            ]
        ),
        recordSessionEvents: false
    )

    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "tmp")
}

@Test
func autopilotWorkerSessionBypassesMissingDirectoryAccessApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(
        service: service,
        agentID: "approval-autopilot-worker",
        title: "task-task-1-attempt-1"
    )
    let file = try makeApprovalTempFile(contents: "autopilot")
    let task = ProjectTask(
        id: "task-1",
        title: "Autopilot worker",
        description: "",
        priority: "medium",
        status: ProjectTaskStatus.inProgress.rawValue,
        createdBy: "autopilot",
        tags: ["autopilot"]
    )
    await service.store.saveProject(ProjectRecord(
        id: "approval-autopilot-project",
        name: "Approval Autopilot Project",
        description: "",
        channels: [],
        tasks: [task],
        autopilotSettings: ProjectAutopilotSettings(enabled: true, defaultAgentId: "approval-autopilot-worker")
    ))

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-autopilot-worker",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
            recordSessionEvents: false
        )
    }

    let pending = await waitForPendingToolApprovalIfAny(service)
    if let pending {
        _ = await service.rejectToolApproval(id: pending.id, decidedBy: "test")
    }

    let result = await invocation.value
    #expect(pending == nil)
    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func sessionScopedToolApprovalSkipsNextSameToolApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-session-allow")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-session-allow",
        request: AgentToolsUpdateRequest(approval: AgentToolApprovalSettings(enabled: true))
    )

    let firstInvocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-session-allow",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/echo"),
                    "arguments": .array([.string("first")])
                ]
            ),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    let approved = await service.approveToolApproval(id: pending.id, decidedBy: "test", scope: .session)
    #expect(approved?.status == .approved)
    #expect((await firstInvocation.value).ok == true)

    let second = await service.invokeToolFromRuntime(
        agentID: "approval-session-allow",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("/bin/echo"),
                "arguments": .array([.string("second")])
            ]
        ),
        recordSessionEvents: false
    )

    #expect(second.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func riskyToolWaitsForApprovalBeforeExecution() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-waits")

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-waits",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/echo"),
                    "arguments": .array([.string("approved")])
                ],
                reason: "Need to run a command"
            ),
            recordSessionEvents: false,
            requireApproval: true
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.tool == "runtime.exec")
    #expect(pending.agentId == "approval-waits")

    let approved = await service.approveToolApproval(id: pending.id, decidedBy: "test")
    #expect(approved?.status == .approved)

    let result = await invocation.value
    #expect(result.ok == true)
}

@Test
func toolApprovalPausesSessionAndMarksLinkedTaskWaitingInput() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "approval-task-link"
    _ = try await service.createAgent(AgentCreateRequest(
        id: agentID,
        displayName: agentID,
        role: "Tests linked task approvals"
    ))
    let projectID = "approval-project-\(UUID().uuidString)"
    let projectResult = try await service.createProject(ProjectCreateRequest(
        id: projectID,
        name: "Approval Project",
        description: "",
        channels: []
    ))
    let projectWithTask = try await service.createProjectTask(
        projectID: projectResult.project.id,
        request: ProjectTaskCreateRequest(
            title: "Needs approval",
            description: "",
            priority: "medium",
            status: ProjectTaskStatus.inProgress.rawValue
        )
    )
    let taskID = try #require(projectWithTask.tasks.first?.id)
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "task-\(taskID)", projectId: projectID)
    )

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/echo"),
                    "arguments": .array([.string("approved")])
                ],
                reason: "Need shell access"
            ),
            recordSessionEvents: false,
            requireApproval: true
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    let savedProject = try await service.getProject(id: projectID)
    let savedTask = try #require(savedProject.tasks.first(where: { $0.id == taskID }))
    #expect(savedTask.status == ProjectTaskStatus.waitingInput.rawValue)

    let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
    let paused = detail.events.compactMap(\.runStatus).last(where: { $0.stage == .paused })
    #expect(paused?.label == "Tool approval required")

    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test")
    #expect((await invocation.value).ok == true)
}

@Test
func rejectedRiskyToolDoesNotExecute() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-rejects")
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("should-not-exist-\(UUID().uuidString).txt")

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-rejects",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "files.write",
                arguments: [
                    "path": .string(target.path),
                    "content": .string("nope")
                ],
                reason: "Need to write a file"
            ),
            recordSessionEvents: false,
            requireApproval: true
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    _ = await service.rejectToolApproval(id: pending.id, decidedBy: "test")

    let result = await invocation.value
    #expect(result.ok == false)
    #expect(result.error?.code == "tool_approval_rejected")
    #expect(FileManager.default.fileExists(atPath: target.path) == false)
}

@Test
func readOnlyToolBypassesApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-bypass")

    let result = await service.invokeToolFromRuntime(
        agentID: "approval-bypass",
        sessionID: session.id,
        request: ToolInvocationRequest(tool: "agents.list"),
        recordSessionEvents: false,
        requireApproval: true
    )

    #expect(result.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func disabledToolRequestsMissingAccessApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-disabled-tool")
    let file = try makeApprovalTempFile(contents: "hello")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-disabled-tool",
        request: AgentToolsUpdateRequest(tools: ["files.read": false])
    )

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-disabled-tool",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.approvalKind == .missingAccess)
    #expect(pending.grants.contains(where: { $0.kind == .tool && $0.tool == "files.read" }))

    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test")
    let result = await invocation.value
    #expect(result.ok == true)
}

@Test
func allowOnceForDisabledToolDoesNotAuthorizeNextCall() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-once-tool")
    let file = try makeApprovalTempFile(contents: "hello")
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-once-tool",
        request: AgentToolsUpdateRequest(tools: ["files.read": false])
    )

    let first = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-once-tool",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
            recordSessionEvents: false
        )
    }
    let firstPending = try await waitForPendingToolApproval(service)
    _ = await service.approveToolApproval(id: firstPending.id, decidedBy: "test", scope: .once)
    #expect((await first.value).ok == true)

    let second = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-once-tool",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
            recordSessionEvents: false
        )
    }
    let secondPending = try await waitForPendingToolApproval(service)
    #expect(secondPending.id != firstPending.id)
    _ = await service.rejectToolApproval(id: secondPending.id, decidedBy: "test")
    #expect((await second.value).error?.code == "tool_approval_rejected")
}

@Test
func sessionScopedDirectoryApprovalIsExactToToolAndRoot() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-directory-session")
    let allowedDir = try makeApprovalTempDirectory()
    let otherDir = try makeApprovalTempDirectory()
    let firstFile = allowedDir.appendingPathComponent("first.txt")
    let secondFile = allowedDir.appendingPathComponent("second.txt")
    let otherFile = otherDir.appendingPathComponent("other.txt")
    try "first".write(to: firstFile, atomically: true, encoding: .utf8)
    try "second".write(to: secondFile, atomically: true, encoding: .utf8)
    try "other".write(to: otherFile, atomically: true, encoding: .utf8)

    let first = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-directory-session",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(firstFile.path)]),
            recordSessionEvents: false
        )
    }
    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.approvalKind == .missingAccess)
    let hasReadGrant = containsApprovalGrant(
        pending.grants,
        kind: .directory,
        tool: "files.read",
        operation: "read",
        resource: allowedDir.path
    )
    #expect(hasReadGrant)
    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test", scope: .session)
    #expect((await first.value).ok == true)

    let sameDirectory = await service.invokeToolFromRuntime(
        agentID: "approval-directory-session",
        sessionID: session.id,
        request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(secondFile.path)]),
        recordSessionEvents: false
    )
    #expect(sameDirectory.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)

    let writeSameDirectory = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-directory-session",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "files.write",
                arguments: ["path": .string(allowedDir.appendingPathComponent("write.txt").path), "content": .string("no")]
            ),
            recordSessionEvents: false
        )
    }
    let writePending = try await waitForPendingToolApproval(service)
    #expect(writePending.grants.contains(where: { $0.tool == "files.write" }))
    _ = await service.rejectToolApproval(id: writePending.id, decidedBy: "test")
    #expect((await writeSameDirectory.value).error?.code == "tool_approval_rejected")

    let otherDirectory = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-directory-session",
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(otherFile.path)]),
            recordSessionEvents: false
        )
    }
    let otherPending = try await waitForPendingToolApproval(service)
    #expect(otherPending.grants.contains(where: { $0.resource == otherDir.path }))
    _ = await service.rejectToolApproval(id: otherPending.id, decidedBy: "test")
    #expect((await otherDirectory.value).error?.code == "tool_approval_rejected")
}

@Test
func alwaysScopedDirectoryApprovalPersistsAcrossSessionsAndKeepsToolAndRootBoundaries() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "approval-always-\(UUID().uuidString)"
    let session = try await makeApprovalSession(service: service, agentID: agentID)
    let allowedDir = try makeApprovalTempDirectory()
    let otherDir = try makeApprovalTempDirectory()
    let file = allowedDir.appendingPathComponent("read.txt")
    let otherFile = otherDir.appendingPathComponent("read.txt")
    try "allowed".write(to: file, atomically: true, encoding: .utf8)
    try "other".write(to: otherFile, atomically: true, encoding: .utf8)

    let first = Task {
        await service.invokeToolFromRuntime(
            agentID: agentID, sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
            recordSessionEvents: false
        )
    }
    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.approvalKind == .missingAccess)
    let response = await CoreRouter(service: service).handle(
        method: "POST", path: "/v1/tool-approvals/\(pending.id)/approve",
        body: try JSONEncoder().encode(ToolApprovalDecisionRequest(decidedBy: "test", scope: .always))
    )
    #expect(response.status == 200)
    #expect((await first.value).ok)

    await service.toolsAuthorization.invalidateCachedPolicies()
    let saved = try await service.getAgentToolsPolicy(agentID: agentID)
    #expect(saved.approvalGrants.contains(where: { $0.tool == "files.read" && $0.resource == allowedDir.path }))
    #expect(saved.guardrails.allowedWriteRoots.contains(allowedDir.path) == false)
    let nextSession = try await service.createAgentSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Another chat"))
    let next = await service.invokeToolFromRuntime(
        agentID: agentID, sessionID: nextSession.id,
        request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(file.path)]),
        recordSessionEvents: false
    )
    #expect(next.ok)
    #expect(await service.listPendingToolApprovals().isEmpty)

    for request in [
        ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(otherFile.path)]),
        ToolInvocationRequest(tool: "files.write", arguments: ["path": .string(file.path), "content": .string("blocked")])
    ] {
        let attempt = Task {
            await service.invokeToolFromRuntime(agentID: agentID, sessionID: nextSession.id, request: request, recordSessionEvents: false)
        }
        let blocked = try await waitForPendingToolApproval(service)
        _ = await service.rejectToolApproval(id: blocked.id, decidedBy: "test")
        #expect((await attempt.value).error?.code == "tool_approval_rejected")
    }
    let remaining = try String(contentsOf: file, encoding: .utf8)
    #expect(remaining == "allowed")
}

@Test
func alwaysScopedRiskyToolApprovalSurvivesPolicyReloadAndIsAgentSpecific() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "approval-risky-always-\(UUID().uuidString)"
    let session = try await makeApprovalSession(service: service, agentID: agentID)
    let request = ToolInvocationRequest(tool: "runtime.exec")
    let first = Task {
        await service.requestToolApprovalIfNeeded(
            agentID: agentID, sessionID: session.id, channelID: nil, topicID: nil,
            request: request, requireApproval: true
        )
    }
    let pending = try await waitForPendingToolApproval(service)
    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test", scope: .always)
    guard case .approved = await first.value else {
        Issue.record("Expected approval")
        return
    }
    await service.toolsAuthorization.invalidateCachedPolicies()
    let next = await service.requestToolApprovalIfNeeded(
        agentID: agentID, sessionID: "another-session", channelID: nil, topicID: nil,
        request: request, requireApproval: true
    )
    #expect(next == nil)
    #expect(await service.isToolApprovalAllowedForSession(agentID: agentID, sessionID: nil, channelID: nil, toolID: "runtime.exec"))
    #expect(await service.isToolApprovalAllowedForSession(agentID: "another-agent", sessionID: session.id, channelID: nil, toolID: "runtime.exec") == false)
    #expect(await service.isToolApprovalAllowedForSession(agentID: agentID, sessionID: session.id, channelID: nil, toolID: "files.write") == false)
}

@Test
func cwdApprovalAllowsRuntimeExecForApprovedDirectory() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-cwd")
    let cwd = try makeApprovalTempDirectory()

    let invocation = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-cwd",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/pwd"),
                    "cwd": .string(cwd.path)
                ]
            ),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    let hasCwdGrant = containsApprovalGrant(
        pending.grants,
        kind: .directory,
        tool: "runtime.exec",
        operation: "exec",
        resource: cwd.path
    )
    #expect(hasCwdGrant)
    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test")
    #expect((await invocation.value).ok == true)
}

@Test
func sessionScopedCwdApprovalSkipsNextMatchingRiskyApproval() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let session = try await makeApprovalSession(service: service, agentID: "approval-cwd-session")
    let cwd = try makeApprovalTempDirectory()
    _ = try await service.updateAgentToolsPolicy(
        agentID: "approval-cwd-session",
        request: AgentToolsUpdateRequest(approval: AgentToolApprovalSettings(enabled: true))
    )

    let first = Task {
        await service.invokeToolFromRuntime(
            agentID: "approval-cwd-session",
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "runtime.exec",
                arguments: [
                    "command": .string("/bin/pwd"),
                    "cwd": .string(cwd.path)
                ]
            ),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.approvalKind == .missingAccess)
    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test", scope: .session)
    #expect((await first.value).ok == true)

    let second = await service.invokeToolFromRuntime(
        agentID: "approval-cwd-session",
        sessionID: session.id,
        request: ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("/bin/echo"),
                "arguments": .array([.string("ok")]),
                "cwd": .string(cwd.path)
            ]
        ),
        recordSessionEvents: false
    )

    #expect(second.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)
}

@Test
func subagentApprovalDisplaysOnParentSessionButScopesToChildSession() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "approval-subagent-parent"
    _ = try await service.createAgent(AgentCreateRequest(
        id: agentID,
        displayName: agentID,
        role: "Tests delegated tool approvals"
    ))
    let parent = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Parent")
    )
    let child = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Child", parentSessionId: parent.id)
    )
    let allowedDir = try makeApprovalTempDirectory()
    let firstFile = allowedDir.appendingPathComponent("first.txt")
    let secondFile = allowedDir.appendingPathComponent("second.txt")
    try "first".write(to: firstFile, atomically: true, encoding: .utf8)
    try "second".write(to: secondFile, atomically: true, encoding: .utf8)

    let first = Task {
        await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: child.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(firstFile.path)]),
            recordSessionEvents: false
        )
    }

    let pending = try await waitForPendingToolApproval(service)
    #expect(pending.approvalKind == .missingAccess)
    #expect(pending.sessionId == child.id)
    #expect(pending.displaySessionId == parent.id)

    let parentDetail = try await service.getAgentSession(agentID: agentID, sessionID: parent.id)
    #expect(parentDetail.events.contains(where: {
        $0.runStatus?.stage == .paused &&
            $0.runStatus?.label == "Tool approval required"
    }))
    let childDetail = try await service.getAgentSession(agentID: agentID, sessionID: child.id)
    #expect(childDetail.events.contains(where: {
        $0.runStatus?.stage == .paused &&
            $0.runStatus?.label == "Tool approval required"
    }))

    _ = await service.approveToolApproval(id: pending.id, decidedBy: "test", scope: .session)
    #expect((await first.value).ok == true)

    let childSameDirectory = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: child.id,
        request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(secondFile.path)]),
        recordSessionEvents: false
    )
    #expect(childSameDirectory.ok == true)
    #expect(await service.listPendingToolApprovals().isEmpty)

    let parentRead = Task {
        await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: parent.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string(secondFile.path)]),
            recordSessionEvents: false
        )
    }
    let parentPending = try await waitForPendingToolApproval(service)
    #expect(parentPending.sessionId == parent.id)
    #expect(parentPending.displaySessionId == nil)
    _ = await service.rejectToolApproval(id: parentPending.id, decidedBy: "test")
    #expect((await parentRead.value).error?.code == "tool_approval_rejected")
}

@Test
func legacyToolApprovalRecordDecodesWithoutGrantMetadata() throws {
    let json = """
    {
      "id": "legacy-approval",
      "status": "pending",
      "agentId": "agent",
      "tool": "files.read",
      "arguments": {},
      "createdAt": 0,
      "updatedAt": 0,
      "expiresAt": 60
    }
    """

    let record = try JSONDecoder().decode(ToolApprovalRecord.self, from: Data(json.utf8))

    #expect(record.id == "legacy-approval")
    #expect(record.approvalKind == nil)
    #expect(record.grants.isEmpty)
}

@Test
func toolApprovalTimeoutReturnsTimedOut() async {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let record = await service.toolApprovalService.createPending(
        agentId: "approval-timeout",
        sessionId: "session-timeout",
        channelId: nil,
        topicId: nil,
        request: ToolInvocationRequest(tool: "runtime.exec"),
        timeoutSeconds: 0.05
    )

    let result = await service.toolApprovalService.waitForDecision(id: record.id, timeoutSeconds: 0.05)
    if case .timedOut(let timedOut) = result {
        #expect(timedOut.status == .timedOut)
    } else {
        Issue.record("Expected timedOut result")
    }
}

@Test
func toolApprovalRoutesListAndResolvePendingApprovals() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)
    let record = await service.toolApprovalService.createPending(
        agentId: "approval-router",
        sessionId: "session-router",
        channelId: nil,
        topicId: nil,
        request: ToolInvocationRequest(tool: "files.write", reason: "router test")
    )

    let listResponse = await router.handle(method: "GET", path: "/v1/tool-approvals/pending", body: nil)
    #expect(listResponse.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let listed = try decoder.decode([ToolApprovalRecord].self, from: listResponse.body)
    #expect(listed.contains(where: { $0.id == record.id }))

    let body = try JSONEncoder().encode(ToolApprovalDecisionRequest(decidedBy: "router"))
    let approveResponse = await router.handle(
        method: "POST",
        path: "/v1/tool-approvals/\(record.id)/approve",
        body: body
    )
    #expect(approveResponse.status == 200)
    let approved = try decoder.decode(ToolApprovalRecord.self, from: approveResponse.body)
    #expect(approved.status == .approved)
}

@Test
func toolApprovalNotificationContainsRoutingMetadata() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let stream = await service.notificationService.subscribe()
    let waiter = Task<DashboardNotification?, Never> {
        for await notification in stream {
            if notification.type == .toolApproval {
                return notification
            }
        }
        return nil
    }

    let record = await service.toolApprovalService.createPending(
        agentId: "approval-notification",
        sessionId: "session-notification",
        channelId: "channel:telegram",
        topicId: "10",
        request: ToolInvocationRequest(tool: "runtime.exec", reason: "notify")
    )

    let notification = try #require(await waiter.value)
    #expect(notification.metadata["approvalId"] == record.id)
    #expect(notification.metadata["agentId"] == "approval-notification")
    #expect(notification.metadata["sessionId"] == "session-notification")
    #expect(notification.metadata["channelId"] == "channel:telegram")
    #expect(notification.metadata["topicId"] == "10")
    #expect(notification.metadata["tool"] == "runtime.exec")
}

@Test
func telegramToolApprovalCallbackParsing() {
    #expect(TelegramToolApproval.parseCallback("TA|A|abc") == .approve("abc"))
    #expect(TelegramToolApproval.parseCallback("TA|R|abc") == .reject("abc"))
    #expect(TelegramToolApproval.parseCallback("M|1|S|0") == .unknown)
}

}

private func makeApprovalSession(
    service: CoreService,
    agentID: String,
    title: String = "Approval Session"
) async throws -> AgentSessionSummary {
    _ = try await service.createAgent(AgentCreateRequest(
        id: agentID,
        displayName: agentID,
        role: "Tests tool approvals"
    ))
    return try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: title)
    )
}

private func makeApprovalTempDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/sloppy-approval-fixtures", isDirectory: true)
        .appendingPathComponent("sloppy-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.standardizedFileURL
}

private func makeApprovalTempFile(contents: String) throws -> URL {
    let directory = try makeApprovalTempDirectory()
    let file = directory.appendingPathComponent("fixture.txt")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file.standardizedFileURL
}

private func containsApprovalGrant(
    _ grants: [ToolApprovalGrant],
    kind: ToolApprovalGrantKind,
    tool: String,
    operation: String? = nil,
    resource: String? = nil
) -> Bool {
    grants.contains { grant in
        guard grant.kind == kind, grant.tool == tool else {
            return false
        }
        if let operation, grant.operation != operation {
            return false
        }
        if let resource, grant.resource != resource {
            return false
        }
        return true
    }
}

private func waitForPendingToolApproval(_ service: CoreService) async throws -> ToolApprovalRecord {
    for _ in 0..<100 {
        if let pending = await service.listPendingToolApprovals().first {
            return pending
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw ToolApprovalTestError.timeout
}

private func waitForPendingToolApprovalIfAny(_ service: CoreService) async -> ToolApprovalRecord? {
    for _ in 0..<10 {
        if let pending = await service.listPendingToolApprovals().first {
            return pending
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return nil
}

private enum ToolApprovalTestError: Error {
    case timeout
}
