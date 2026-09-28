import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("ToolContext path resolution with extra roots")
struct ToolPathResolutionTests {

    // MARK: - Helpers

    private func makeContext(
        workspaceRootURL: URL,
        allowedExecRoots: [String] = [],
        allowedWriteRoots: [String] = [],
        readOnlyRoots: [String] = [],
        sandbox: AgentSandboxSettings = .init()
    ) -> ToolContext {
        let guardrails = AgentToolsGuardrails(
            allowedWriteRoots: allowedWriteRoots,
            allowedExecRoots: allowedExecRoots
        )
        let policy = AgentToolsPolicy(sandbox: sandbox, guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
            workspaceRootURL: workspaceRootURL,
            readOnlyRoots: readOnlyRoots,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: tmp),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmp),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmp),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
            logger: .sloppy(label: "test"),
            projectService: nil,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }

    // MARK: - resolveExecCwd

    @Test("resolveExecCwd accepts absolute path under workspaceRootURL")
    func resolveCwdInsideWorkspace() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let subdir = workspace.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let context = makeContext(workspaceRootURL: workspace)
        let resolved = context.resolveExecCwd(subdir.path)
        #expect(resolved != nil)
    }

    @Test("resolveExecCwd rejects absolute path outside workspaceRootURL when no extra roots")
    func resolveCwdOutsideWorkspaceNoRoots() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let outside = tmp.appendingPathComponent("sloppy-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }

        let context = makeContext(workspaceRootURL: workspace)
        let resolved = context.resolveExecCwd(outside.path)
        #expect(resolved == nil)
    }

    @Test("resolveExecCwd accepts worktree path when added to allowedExecRoots")
    func resolveCwdWithWorktreeInExecRoots() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let worktree = tmp.appendingPathComponent("sloppy-worktrees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: worktree)
        }

        let context = makeContext(workspaceRootURL: workspace, allowedExecRoots: [worktree.path])
        let resolved = context.resolveExecCwd(worktree.path)
        #expect(resolved != nil)
        #expect(resolved?.path == worktree.resolvingSymlinksInPath().path)
    }

    @Test("resolveExecCwd accepts subdirectory of allowedExecRoots path")
    func resolveCwdSubdirOfAllowedRoot() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let worktree = tmp.appendingPathComponent("sloppy-worktrees-\(UUID().uuidString)", isDirectory: true)
        let subdir = worktree.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: worktree)
        }

        let context = makeContext(workspaceRootURL: workspace, allowedExecRoots: [worktree.path])
        let resolved = context.resolveExecCwd(subdir.path)
        #expect(resolved != nil)
    }

    // MARK: - resolveReadablePath

    @Test("resolveReadablePath rejects file outside workspace when no extra roots")
    func resolveReadableOutsideNoRoots() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let outside = tmp.appendingPathComponent("sloppy-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }

        let context = makeContext(workspaceRootURL: workspace)
        let resolved = context.resolveReadablePath(outside.appendingPathComponent("file.txt").path)
        #expect(resolved == nil)
    }

    @Test("resolveReadablePath accepts file in allowedWriteRoots (repo root)")
    func resolveReadableInWriteRoots() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let repoRoot = tmp.appendingPathComponent("sloppy-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: repoRoot)
        }

        let filePath = repoRoot.appendingPathComponent("Package.swift").path
        let context = makeContext(workspaceRootURL: workspace, allowedWriteRoots: [repoRoot.path])
        let resolved = context.resolveReadablePath(filePath)
        #expect(resolved != nil)
    }

    @Test("full access allows readable and writable paths outside workspace")
    func resolvePathsOutsideWorkspaceWithFullAccess() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let outside = tmp.appendingPathComponent("sloppy-full-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }

        let filePath = outside.appendingPathComponent("note.txt").path
        let context = makeContext(workspaceRootURL: workspace, sandbox: .init(mode: .fullAccess))

        #expect(context.resolveReadablePath(filePath) != nil)
        #expect(context.resolveWritablePath(filePath) != nil)
    }

    @Test("full access allows exec cwd outside workspace")
    func resolveExecCwdOutsideWorkspaceWithFullAccess() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let outside = tmp.appendingPathComponent("sloppy-full-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }

        let context = makeContext(workspaceRootURL: workspace, sandbox: .init(mode: .fullAccess))

        #expect(context.resolveExecCwd(outside.path) != nil)
    }

    @Test("resolveReadablePath accepts read-only roots without allowing writes")
    func resolveReadableWithReadOnlyRoots() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let sharedRoot = tmp.appendingPathComponent("sloppy-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sharedRoot)
        }

        let filePath = sharedRoot.appendingPathComponent("skills/prd/SKILL.md").path
        let context = makeContext(workspaceRootURL: workspace, readOnlyRoots: [sharedRoot.path])

        #expect(context.resolveReadablePath(filePath) != nil)
        #expect(context.resolveWritablePath(filePath) == nil)
    }

    @Test("resolveReadablePath resolves relative paths from current session directory")
    func resolveReadableRelativeFromCurrentDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-ws-\(UUID().uuidString)", isDirectory: true)
        let repoRoot = tmp.appendingPathComponent("sloppy-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: repoRoot)
        }

        let context = ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: AgentToolsPolicy(guardrails: AgentToolsGuardrails(allowedWriteRoots: [repoRoot.path])),
            workspaceRootURL: workspace,
            currentDirectoryURL: repoRoot,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: tmp),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmp),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmp),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
            logger: .sloppy(label: "test"),
            projectService: nil,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )

        let resolved = context.resolveReadablePath("package.json")
        #expect(resolved?.path == repoRoot.appendingPathComponent("package.json").resolvingSymlinksInPath().path)
    }

    @Test("sessionToolRoots does not promote plain repo path to filesystem root")
    func sessionToolRootsForRepoPath() {
        let roots = sessionToolRoots(forWorkingDirectory: "/projects/adawebsite")
        #expect(roots == ["/projects/adawebsite"])
    }

    @Test("sessionToolRoots includes repository root for managed worktree")
    func sessionToolRootsForManagedWorktree() {
        let roots = sessionToolRoots(forWorkingDirectory: "/repo/.sloppy-worktrees/task-123")
        #expect(roots.first == "/repo/.sloppy-worktrees/task-123")
        #expect(roots.contains("/repo"))
        #expect(!roots.contains("/"))
    }

    // MARK: - sessionExtraRoots integration via CoreService

    @Test("invokeToolFromRuntime rejects cwd outside workspace when no extra roots registered")
    func invokeToolRejectsCwdWithoutExtraRoots() async throws {
        let config = CoreConfig.test
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
        await service.setToolApprovalPresenter { _ in .reject }
        let router = CoreRouter(service: service)

        let agentID = "test-extra-roots-agent"
        let agentBody = try JSONEncoder().encode(
            AgentCreateRequest(id: agentID, displayName: "Extra Roots Agent", role: "assistant")
        )
        let agentResp = await router.handle(method: "POST", path: "/v1/agents", body: agentBody)
        #expect(agentResp.status == 201)

        let sessionBody = try JSONEncoder().encode(AgentSessionCreateRequest(title: "test"))
        let sessionResp = await router.handle(method: "POST", path: "/v1/agents/\(agentID)/sessions", body: sessionBody)
        #expect(sessionResp.status == 201)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessionSummary = try decoder.decode(AgentSessionSummary.self, from: sessionResp.body)
        let sessionID = sessionSummary.id

        let tmp = FileManager.default.temporaryDirectory
        let outsidePath = tmp.appendingPathComponent("outside-\(UUID().uuidString)").path

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "runtime.exec", arguments: [
                "command": .string("bash"),
                "arguments": .array([.string("-lc"), .string("pwd")]),
                "cwd": .string(outsidePath)
            ])
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "tool_approval_rejected")
    }

    @Test("add session directory allows tools to use outside cwd")
    func addSessionDirectoryAllowsOutsideCwd() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let outside = tmp.appendingPathComponent("sloppy-added-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let config = CoreConfig.test
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "test-add-dir-agent"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Add Dir Agent", role: "assistant")
        )
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "test")
        )

        let response = try await service.addAgentSessionDirectory(
            agentID: agentID,
            sessionID: session.id,
            request: AgentSessionDirectoryRequest(path: outside.path)
        )
        #expect(response.path == outside.resolvingSymlinksInPath().path)
        #expect(response.workingDirectory == response.path)
        #expect(response.directories.contains(response.path))

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "runtime.exec", arguments: [
                "command": .string("pwd"),
                "cwd": .string(outside.path),
            ]),
            recordSessionEvents: false
        )
        #expect(result.ok == true)
    }

    @Test("subagent inherits parent session directories")
    func subagentInheritsParentSessionDirectories() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let firstRoot = tmp.appendingPathComponent("sloppy-parent-root-a-\(UUID().uuidString)", isDirectory: true)
        let secondRoot = tmp.appendingPathComponent("sloppy-parent-root-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "test-subagent-root-agent"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Subagent Root Agent", role: "assistant")
        )
        let parent = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "parent")
        )

        _ = try await service.addAgentSessionDirectory(
            agentID: agentID,
            sessionID: parent.id,
            request: AgentSessionDirectoryRequest(path: firstRoot.path)
        )
        _ = try await service.addAgentSessionDirectory(
            agentID: agentID,
            sessionID: parent.id,
            request: AgentSessionDirectoryRequest(path: secondRoot.path)
        )

        let context = await service.subagentToolContext(
            agentID: agentID,
            parentSessionID: parent.id,
            fallbackWorkingDirectory: firstRoot.path
        )

        #expect(context.workingDirectory == firstRoot.resolvingSymlinksInPath().path)
        #expect(context.extraRoots.contains(firstRoot.resolvingSymlinksInPath().path))
        #expect(context.extraRoots.contains(secondRoot.resolvingSymlinksInPath().path))
    }

    @Test("add channel directory allows channel tools to use outside cwd")
    func addChannelDirectoryAllowsOutsideCwd() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let outside = tmp.appendingPathComponent("sloppy-channel-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let config = CoreConfig.test
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "test-channel-add-dir-agent"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Channel Add Dir Agent", role: "assistant")
        )
        let channelID = "telegram-add-dir-\(UUID().uuidString.prefix(8))"

        let response = try await service.addChannelSessionDirectory(
            channelID: channelID,
            request: AgentSessionDirectoryRequest(path: outside.path)
        )
        #expect(response.path == outside.resolvingSymlinksInPath().path)

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: channelID,
            request: ToolInvocationRequest(tool: "runtime.exec", arguments: [
                "command": .string("pwd"),
                "cwd": .string(outside.path),
            ])
        )
        #expect(result.ok == true)
    }

    @Test("project session uses project repo path as default cwd")
    func projectSessionUsesProjectRepoPathAsDefaultCwd() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let repoRoot = tmp.appendingPathComponent("sloppy-project-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let markerURL = repoRoot.appendingPathComponent("PROJECT_MARKER.txt")
        try "hello".write(to: markerURL, atomically: true, encoding: .utf8)

        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "test-project-session-cwd-agent"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Project Session CWD Agent", role: "assistant")
        )
        _ = try await service.createProject(
            ProjectCreateRequest(id: "project-session-cwd", name: "Project Session CWD", repoPath: repoRoot.path)
        )
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "chat", projectId: "project-session-cwd")
        )

        let pwdResult = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "runtime.exec", arguments: [
                "command": .string("pwd"),
            ]),
            recordSessionEvents: false
        )
        #expect(pwdResult.ok == true)
        #expect(
            pwdResult.data?.asObject?["stdout"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix(repoRoot.lastPathComponent) == true
        )

        let readResult = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: [
                "path": .string("PROJECT_MARKER.txt"),
            ]),
            recordSessionEvents: false
        )
        #expect(readResult.ok == true)
        #expect(readResult.data?.asObject?["content"]?.asString == "hello")
    }

    @Test("debug tool invocation creates repo debug directory before command writes logs")
    func debugToolInvocationCreatesRepoDebugDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let repoRoot = tmp.appendingPathComponent("sloppy-debug-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "test-debug-dir-agent"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Debug Dir Agent", role: "assistant")
        )
        _ = try await service.createProject(
            ProjectCreateRequest(id: "debug-dir", name: "Debug Dir", repoPath: repoRoot.path)
        )
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "chat", projectId: "debug-dir")
        )

        let debugURL = repoRoot.appendingPathComponent(".sloppy/debug", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: debugURL.path))

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "runtime.exec", arguments: [
                "command": .string("bash"),
                "arguments": .array([
                    .string("-lc"),
                    .string("printf '{\"sessionId\":\"test\"}\\n' > .sloppy/debug/debug-test.log"),
                ]),
            ]),
            recordSessionEvents: false,
            chatMode: .debug
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["exitCode"]?.asInt == 0)
        #expect(FileManager.default.fileExists(atPath: debugURL.path))
        let logURL = debugURL.appendingPathComponent("debug-test.log")
        #expect((try? String(contentsOf: logURL, encoding: .utf8)) == #"{"sessionId":"test"}"# + "\n")
    }

    @Test("invokeToolFromRuntime restores project roots for task sessions")
    func invokeToolRestoresProjectRootsForTaskSession() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let repoRoot = tmp.appendingPathComponent("sloppy-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let packageURL = repoRoot.appendingPathComponent("package.json")
        try #"{"name":"demo"}"#.write(to: packageURL, atomically: true, encoding: .utf8)

        let config = CoreConfig.test
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "test-task-roots-agent"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Task Roots Agent", role: "assistant")
        )
        _ = try await service.createProject(
            ProjectCreateRequest(id: "task-roots", name: "Task Roots", repoPath: repoRoot.path)
        )
        let project = try await service.createProjectTask(
            projectID: "task-roots",
            request: ProjectTaskCreateRequest(title: "Read project", status: "in_progress")
        )
        let taskID = try #require(project.tasks.first?.id)
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "task-\(taskID)")
        )

        let absoluteResult = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: [
                "path": .string(packageURL.path),
            ]),
            recordSessionEvents: false
        )
        #expect(absoluteResult.ok == true)

        let relativeResult = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(tool: "files.read", arguments: [
                "path": .string("package.json"),
            ]),
            recordSessionEvents: false
        )
        #expect(relativeResult.ok == true)
        #expect(relativeResult.data?.asObject?["content"]?.asString == #"{"name":"demo"}"#)
    }
}
