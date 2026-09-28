import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

@Test
func projectMetaMemoryToolWritesWorkspacePrivateMemoryWithoutRepoPath() async throws {
    let config = CoreConfig.test
    let workspaceRoot = config.resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let projectID = "meta-memory-\(UUID().uuidString.prefix(8).lowercased())"
    _ = try await service.createProject(
        ProjectCreateRequest(id: projectID, name: "Meta Memory", description: "No repo path")
    )

    let tool = ProjectMetaMemoryTool()
    let result = await tool.invoke(
        arguments: [
            "projectId": .string(projectID),
            "content": .string("# Project Memory\n\n- Workspace-private fact.")
        ],
        context: makeProjectMemoryToolContext(service: service, workspaceRootURL: workspaceRoot)
    )

    #expect(result.ok == true)
    let memoryURL = workspaceRoot
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectID, isDirectory: true)
        .appendingPathComponent(".meta", isDirectory: true)
        .appendingPathComponent("MEMORY.md", isDirectory: false)
    let text = try String(contentsOf: memoryURL, encoding: .utf8)
    #expect(text.contains("Workspace-private fact."))
    let bootstrap = try #require(await service.projectBootstrapMarkdownForAgentSession(projectID: projectID))
    #expect(bootstrap.contains("Workspace-private fact."))
    #expect(result.data?.asObject?["path"]?.asString == memoryURL.path)
}

@Test
func projectContextRefreshLoadsWorkspacePrivateMetaMemory() async throws {
    let config = CoreConfig.test
    let workspaceRoot = config.resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
    let repoRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-context-repo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try "Repo instructions".write(to: repoRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "Project user preferences".write(to: repoRoot.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
    try "Project soul instructions".write(to: repoRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let projectID = "ctx-memory-\(UUID().uuidString.prefix(8).lowercased())"
    _ = try await service.createProject(
        ProjectCreateRequest(id: projectID, name: "Context Memory", repoPath: repoRoot.path)
    )
    let memoryURL = workspaceRoot
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectID, isDirectory: true)
        .appendingPathComponent(".meta", isDirectory: true)
        .appendingPathComponent("MEMORY.md", isDirectory: false)
    try FileManager.default.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "Workspace project memory".write(to: memoryURL, atomically: true, encoding: .utf8)

    let response = try await service.refreshProjectContext(projectID: projectID)
    #expect(response.loadedDocPaths.contains(repoRoot.appendingPathComponent("AGENTS.md").path))
    #expect(response.loadedDocPaths.contains(repoRoot.appendingPathComponent("USER.md").path))
    #expect(response.loadedDocPaths.contains(repoRoot.appendingPathComponent("SOUL.md").path))
    #expect(response.loadedDocPaths.contains(".meta/MEMORY.md"))

    let bootstrap = try #require(await service.projectBootstrapMarkdownForAgentSession(projectID: projectID))
    #expect(bootstrap.contains("[\(repoRoot.appendingPathComponent("USER.md").path)]"))
    #expect(bootstrap.contains("Project user preferences"))
    #expect(bootstrap.contains("[\(repoRoot.appendingPathComponent("SOUL.md").path)]"))
    #expect(bootstrap.contains("Project soul instructions"))
    #expect(bootstrap.contains("[.meta/MEMORY.md]"))
    #expect(bootstrap.contains("Workspace project memory"))
}

@Test
func memoryCheckpointAllowsProjectMemorySaveAndMentionsWorkspaceMetaPath() {
    #expect(CoreService.memoryCheckpointToolAllowlist.contains("memory.search"))
    #expect(CoreService.memoryCheckpointToolAllowlist.contains("memory.save"))

    let bootstrap = CoreService.memoryCheckpointBootstrap(
        agentID: "sloppy",
        sessionID: "session-1",
        reason: "project_task_needs_review:sloppy:SLOPPY-1",
        userMarkdown: "",
        memoryMarkdown: "",
        transcript: "[user] done",
        projectIndex: "- `sloppy`: Sloppy",
        currentProject: "- id: `sloppy`\n- name: Sloppy\n- memoryPath: /tmp/.sloppy/projects/sloppy/.meta/MEMORY.md",
        currentProjectMetaMemory: "Existing workspace project memory"
    )

    #expect(bootstrap.contains("`memory.save`"))
    #expect(bootstrap.contains("`memory.search`"))
    #expect(bootstrap.contains("scope_type`: `project"))
    #expect(bootstrap.contains("Before saving with `memory.save`, call `memory.search`"))
    #expect(bootstrap.contains("secrets, credentials, tokens, private URLs"))
    #expect(bootstrap.contains("confidence`: 0.8"))
    #expect(bootstrap.contains("~/.sloppy/projects/<projectId>/.meta/MEMORY.md"))
    #expect(bootstrap.contains("Existing workspace project memory"))
}

@Test
func memoryCheckpointScopedProjectSaveAppearsInProjectMemories() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let memoryStore = HybridMemoryStore(config: config)
    let projectID = "checkpoint-memory-\(UUID().uuidString.prefix(8).lowercased())"

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Checkpoint Memory")
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let ref = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Checkpoint stored project decision.",
            summary: "Checkpoint project decision",
            kind: .decision,
            memoryClass: .semantic,
            scope: .project(projectID),
            source: MemorySource(type: "memory_checkpoint", id: "session-1")
        )
    )

    let listResponse = await router.handle(method: "GET", path: "/v1/projects/\(projectID)/memories", body: nil)
    #expect(listResponse.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let page = try decoder.decode(ProjectMemoryListResponse.self, from: listResponse.body)
    #expect(page.items.contains(where: { $0.id == ref.id }))
}

@Test
func memoryCheckpointActionRecorderBuildsSummaryOnlyForWrites() async {
    let recorder = MemoryCheckpointActionRecorder()

    await recorder.record(ToolInvocationResult(tool: "memory.search", ok: true, data: .object([:])))
    let empty = await recorder.review(reason: "test")
    #expect(empty == nil)

    await recorder.record(ToolInvocationResult(tool: "memory.save", ok: true, data: .object([:])))
    await recorder.record(ToolInvocationResult(tool: "agent.documents.set_memory_markdown", ok: true, data: .object([:])))
    let review = await recorder.review(reason: "test")

    #expect(review?.summary == "Self-improvement review: 1 memory saved, MEMORY.md updated")
    #expect(review?.actions == ["1 memory saved", "MEMORY.md updated"])
}

@Test
func memoryCheckpointSummaryEventPersistsAsSelfImprovementReview() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "review-summary-\(UUID().uuidString.prefix(8).lowercased())"
    _ = try await service.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Review Summary", role: "Testing")
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Summary")
    )

    await service.appendMemoryCheckpointReviewSummary(
        agentID: agentID,
        sessionID: session.id,
        review: AgentSelfImprovementReviewEvent(
            summary: "Self-improvement review: 1 memory saved",
            actions: ["1 memory saved"],
            reason: "test"
        )
    )

    let detail = try await service.getAgentSession(agentID: agentID, sessionID: session.id)
    let event = try #require(detail.events.last(where: { $0.type == .selfImprovementReview }))
    #expect(event.selfImprovementReview?.summary == "Self-improvement review: 1 memory saved")
    #expect(event.selfImprovementReview?.actions == ["1 memory saved"])
    #expect(event.selfImprovementReview?.reason == "test")
}

@Test
func projectTaskUpdateTriggersMemoryCheckpointOnNeedsReview() async {
    let task = ProjectTask(
        id: "TASK-1",
        title: "Task",
        description: "",
        priority: "medium",
        status: ProjectTaskStatus.inProgress.rawValue
    )
    let project = ProjectRecord(
        id: "proj",
        name: "Project",
        description: "",
        channels: [],
        tasks: [task]
    )
    let service = SpyProjectToolService(project: project)
    let tool = ProjectTaskUpdateTool()

    let result = await tool.invoke(
        arguments: [
            "projectId": .string("proj"),
            "taskId": .string("TASK-1"),
            "status": .string(ProjectTaskStatus.needsReview.rawValue)
        ],
        context: makeProjectMemoryToolContext(projectService: service)
    )

    #expect(result.ok == true)
    let requests = await service.checkpointRequestsSnapshot()
    #expect(requests.count == 1)
    #expect(requests.first?.agentID == "test-agent")
    #expect(requests.first?.sessionID == "test-session")
    #expect(requests.first?.projectID == "proj")
    #expect(requests.first?.taskID == "TASK-1")
    #expect(requests.first?.status == ProjectTaskStatus.needsReview.rawValue)
}

private func makeProjectMemoryToolContext(
    service: CoreService,
    workspaceRootURL: URL
) -> ToolContext {
    makeProjectMemoryToolContext(projectService: service, workspaceRootURL: workspaceRootURL)
}

private func makeProjectMemoryToolContext(
    projectService: any ProjectToolService,
    workspaceRootURL: URL = FileManager.default.temporaryDirectory
) -> ToolContext {
    ToolContext(
        agentID: "test-agent",
        sessionID: "test-session",
        policy: AgentToolsPolicy(),
        workspaceRootURL: workspaceRootURL,
        runtime: RuntimeSystem(),
        memoryStore: InMemoryMemoryStore(),
        sessionStore: AgentSessionFileStore(agentsRootURL: workspaceRootURL),
        agentCatalogStore: AgentCatalogFileStore(agentsRootURL: workspaceRootURL),
        agentSkillsStore: nil,
        processRegistry: SessionProcessRegistry(),
        channelSessionStore: ChannelSessionFileStore(workspaceRootURL: workspaceRootURL),
        store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
        searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
        mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
        logger: .sloppy(label: "test.project-memory"),
        projectService: projectService,
        configService: nil,
        skillsService: nil,
        lspManager: nil,
        applyAgentMarkdown: nil,
        delegateSubagent: nil
    )
}

private actor SpyProjectToolService: ProjectToolService {
    struct CheckpointRequest: Equatable {
        var agentID: String
        var sessionID: String
        var projectID: String
        var taskID: String
        var status: String
    }

    private var project: ProjectRecord
    private var checkpointRequests: [CheckpointRequest] = []

    init(project: ProjectRecord) {
        self.project = project
    }

    func findProjectForChannel(channelId: String, topicId: String?) async -> ProjectRecord? { project }
    func getProject(id: String) async throws -> ProjectRecord { project }
    func createTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord { throw CoreService.ProjectError.notFound }

    func updateTask(projectID: String, taskID: String, request: ProjectTaskUpdateRequest) async throws -> ProjectRecord {
        guard let index = project.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw CoreService.ProjectError.notFound
        }
        if let status = request.status {
            project.tasks[index].status = status
        }
        if let title = request.title {
            project.tasks[index].title = title
        }
        if let description = request.description {
            project.tasks[index].description = description
        }
        return project
    }

    func cancelTaskWithReason(projectID: String, taskID: String, reason: String?) async throws -> ProjectRecord { throw CoreService.ProjectError.notFound }
    func deleteTask(projectID: String, taskID: String) async throws -> ProjectRecord { throw CoreService.ProjectError.notFound }
    func getTask(reference: String) async throws -> AgentTaskRecord { throw CoreService.ProjectError.notFound }
    func createTaskClarification(projectID: String, taskID: String, request: TaskClarificationCreateRequest) async throws -> TaskClarificationRecord { throw CoreService.ProjectError.notFound }
    func deliverMessage(channelId: String, content: String) async {}
    func actorBoard() async throws -> ActorBoardSnapshot { throw CoreService.ProjectError.notFound }

    func requestProjectMemoryCheckpoint(agentID: String, sessionID: String, projectID: String, taskID: String, status: String) async {
        checkpointRequests.append(
            CheckpointRequest(agentID: agentID, sessionID: sessionID, projectID: projectID, taskID: taskID, status: status)
        )
    }

    func listAllProjects() async -> [ProjectRecord] { [project] }
    func createProject(_ request: ProjectCreateRequest) async throws -> ProjectCreateResult { throw CoreService.ProjectError.notFound }
    func updateProject(projectID: String, request: ProjectUpdateRequest) async throws -> ProjectRecord { throw CoreService.ProjectError.notFound }
    func linkProjectChannel(projectID: String, request: ProjectChannelLinkRequest) async throws -> ProjectChannelLinkResponse { throw CoreService.ProjectError.notFound }
    func deleteProject(projectID: String) async throws {}

    func checkpointRequestsSnapshot() -> [CheckpointRequest] {
        checkpointRequests
    }
}
