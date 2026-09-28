import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Test
func taskCreateWithProjectIdSucceedsWithoutChannelLink() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    let context = makeToolContext(service: service, sessionID: "session-no-channel")
    let tool = ProjectTaskCreateTool()

    let result = await tool.invoke(
        arguments: [
            "title": .string("Track nutrition"),
            "status": .string("backlog"),
            "projectId": .string(projectID)
        ],
        context: context
    )

    #expect(result.ok == true)

    if let taskId = result.data?.asObject?["taskId"]?.asString {
        #expect(!taskId.isEmpty)
    } else {
        Issue.record("Expected taskId in result data")
    }
}

@Test
func taskCreateWithoutProjectIdFailsWhenChannelNotLinked() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    let context = makeToolContext(service: service, sessionID: "session-no-channel")
    let tool = ProjectTaskCreateTool()

    let result = await tool.invoke(
        arguments: ["title": .string("Track nutrition")],
        context: context
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "project_not_found")
}

@Test
func taskListWithProjectIdSucceedsWithoutChannelLink() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    let taskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(title: "Task One", description: "", priority: "medium", status: "backlog")
    )
    let taskResp = await router.handle(method: "POST", path: "/v1/projects/\(projectID)/tasks", body: taskBody)
    #expect(taskResp.status == 200)

    let context = makeToolContext(service: service, sessionID: "session-no-channel")
    let tool = ProjectTaskListTool()

    let result = await tool.invoke(
        arguments: ["projectId": .string(projectID)],
        context: context
    )

    #expect(result.ok == true)
    let tasks = result.data?.asObject?["tasks"]?.asArray
    #expect(tasks?.count == 1)
}

@Test
func taskCreateAcceptsKanbanGraphFields() async throws {
    let fixture = try await makeTaskUpdateFixture()
    let createTool = ProjectTaskCreateTool()

    let parent = await createTool.invoke(
        arguments: [
            "title": .string("Umbrella"),
            "status": .string(ProjectTaskStatus.backlog.rawValue),
            "projectId": .string(fixture.projectID),
            "tags": .array([.string("feature")]),
            "changedBy": .string("agent:test-agent")
        ],
        context: fixture.context
    )
    let parentID = try #require(parent.data?.asObject?["taskId"]?.asString)

    let child = await createTool.invoke(
        arguments: [
            "title": .string("Child"),
            "status": .string(ProjectTaskStatus.backlog.rawValue),
            "projectId": .string(fixture.projectID),
            "parentTaskId": .string(parentID),
            "dependsOnTaskIds": .array([.string(fixture.taskID)]),
            "selectedModel": .string("mock:fast"),
            "tags": .array([.string("feature"), .string("autopilot")]),
            "changedBy": .string("agent:test-agent")
        ],
        context: fixture.context
    )

    #expect(child.ok == true)
    let childID = try #require(child.data?.asObject?["taskId"]?.asString)
    let project = try await fixture.service.getProject(id: fixture.projectID)
    let childTask = try #require(project.tasks.first { $0.id == childID })
    #expect(childTask.parentTaskId == parentID)
    #expect(childTask.dependsOnTaskIds == [fixture.taskID])
    #expect(childTask.selectedModel == "mock:fast")
    #expect(childTask.tags == ["feature", "autopilot"])
    #expect(childTask.createdBy == "agent:test-agent")
}

@Test
func taskUpdateAcceptsKanbanGraphFields() async throws {
    let fixture = try await makeTaskUpdateFixture()
    let createTool = ProjectTaskCreateTool()
    let updateTool = ProjectTaskUpdateTool()

    let parent = await createTool.invoke(
        arguments: [
            "title": .string("Parent"),
            "status": .string(ProjectTaskStatus.backlog.rawValue),
            "projectId": .string(fixture.projectID)
        ],
        context: fixture.context
    )
    let dependency = await createTool.invoke(
        arguments: [
            "title": .string("Dependency"),
            "status": .string(ProjectTaskStatus.backlog.rawValue),
            "projectId": .string(fixture.projectID)
        ],
        context: fixture.context
    )
    let parentID = try #require(parent.data?.asObject?["taskId"]?.asString)
    let dependencyID = try #require(dependency.data?.asObject?["taskId"]?.asString)

    let result = await updateTool.invoke(
        arguments: [
            "taskId": .string(fixture.taskID),
            "projectId": .string(fixture.projectID),
            "parentTaskId": .string(parentID),
            "dependsOnTaskIds": .array([.string(dependencyID)]),
            "selectedModel": .string("mock:precise"),
            "tags": .array([.string("skills"), .string("planning")])
        ],
        context: fixture.context
    )

    #expect(result.ok == true)
    let task = try #require(result.data?.asObject?["task"]?.asObject)
    #expect(task["parentTaskId"]?.asString == parentID)
    #expect(task["dependsOnTaskIds"]?.asArray?.compactMap(\.asString) == [dependencyID])
    #expect(task["selectedModel"]?.asString == "mock:precise")
    #expect(task["tags"]?.asArray?.compactMap(\.asString) == ["skills", "planning"])
}

@Test
func projectCurrentExposesAutopilotSettingsAndTaskSyncLinkedProjects() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)
    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    _ = try await service.updateProject(
        projectID: projectID,
        request: ProjectUpdateRequest(
            actors: ["actor:builder"],
            teams: ["team:platform"],
            models: ["mock:fast"],
            autopilotSettings: ProjectAutopilotSettings(
                enabled: true,
                defaultAgentId: "builder",
                includedTags: ["autopilot"],
                trustedAuthors: ["agent:test-agent"]
            )
        )
    )
    _ = try await service.updateTaskSyncSettings(
        projectID: projectID,
        request: ProjectTaskSyncSettingsUpdateRequest(
            linkedProjects: [
                ProjectTaskSyncLinkedProject(
                    title: "Roadmap",
                    projectURL: "https://github.com/orgs/example/projects/1",
                    tag: "gh:roadmap"
                )
            ]
        )
    )

    let context = makeToolContext(service: service, sessionID: "session-no-channel", currentProjectID: projectID)
    let tool = ProjectCurrentTool()

    let result = await tool.invoke(arguments: [:], context: context)

    #expect(result.ok == true)
    let data = try #require(result.data?.asObject)
    let autopilot = try #require(data["autopilotSettings"]?.asObject)
    #expect(autopilot["enabled"]?.asBool == true)
    #expect(autopilot["includedTags"]?.asArray?.compactMap(\.asString) == ["autopilot"])
    #expect(autopilot["ignoredTags"]?.asArray?.compactMap(\.asString) == [])
    #expect(autopilot["trustedAuthors"]?.asArray?.compactMap(\.asString) == ["agent:test-agent"])
    #expect(data["models"]?.asArray?.compactMap(\.asString) == ["mock:fast"])

    let taskSyncSettings = try #require(data["taskSyncSettings"]?.asObject)
    let linkedProjects = try #require(taskSyncSettings["linkedProjects"]?.asArray)
    #expect(linkedProjects.first?.asObject?["tag"]?.asString == "gh:roadmap")
}

@Test
func taskListExposesKanbanGraphSummaryFields() async throws {
    let fixture = try await makeTaskUpdateFixture()
    let createTool = ProjectTaskCreateTool()
    let listTool = ProjectTaskListTool()

    let child = await createTool.invoke(
        arguments: [
            "title": .string("Child summary"),
            "kind": .string(ProjectTaskKind.execution.rawValue),
            "loopModeOverride": .string(ProjectLoopMode.agent.rawValue),
            "status": .string(ProjectTaskStatus.backlog.rawValue),
            "projectId": .string(fixture.projectID),
            "parentTaskId": .string(fixture.taskID),
            "dependsOnTaskIds": .array([.string(fixture.taskID)]),
            "selectedModel": .string("mock:fast"),
            "tags": .array([.string("tools")]),
            "changedBy": .string("agent:test-agent")
        ],
        context: fixture.context
    )
    let childID = try #require(child.data?.asObject?["taskId"]?.asString)

    let result = await listTool.invoke(
        arguments: ["projectId": .string(fixture.projectID)],
        context: fixture.context
    )

    #expect(result.ok == true)
    let tasks = try #require(result.data?.asObject?["tasks"]?.asArray)
    let listedChild = try #require(tasks.compactMap(\.asObject).first { $0["id"]?.asString == childID })
    #expect(listedChild["kind"]?.asString == ProjectTaskKind.execution.rawValue)
    #expect(listedChild["loopModeOverride"]?.asString == ProjectLoopMode.agent.rawValue)
    #expect(listedChild["parentTaskId"]?.asString == fixture.taskID)
    #expect(listedChild["dependsOnTaskIds"]?.asArray?.compactMap(\.asString) == [fixture.taskID])
    #expect(listedChild["createdBy"]?.asString == "agent:test-agent")
    #expect(listedChild["selectedModel"]?.asString == "mock:fast")
    #expect(listedChild["tags"]?.asArray?.compactMap(\.asString) == ["tools"])
    #expect(listedChild["isArchived"]?.asBool == false)
}
@Test
func taskCancelAcceptsMultipleTaskIds() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    let context = makeToolContext(service: service, sessionID: "session-no-channel")
    let createTool = ProjectTaskCreateTool()
    let first = await createTool.invoke(
        arguments: ["title": .string("Task One"), "status": .string("backlog"), "projectId": .string(projectID)],
        context: context
    )
    let second = await createTool.invoke(
        arguments: ["title": .string("Task Two"), "status": .string("backlog"), "projectId": .string(projectID)],
        context: context
    )
    let firstID = try #require(first.data?.asObject?["taskId"]?.asString)
    let secondID = try #require(second.data?.asObject?["taskId"]?.asString)

    let cancelTool = ProjectTaskCancelTool()
    let result = await cancelTool.invoke(
        arguments: [
            "taskIds": .array([.string(firstID), .string(secondID)]),
            "projectId": .string(projectID),
            "reason": .string("No longer needed")
        ],
        context: context
    )

    #expect(result.ok == true)
    #expect(result.data?.asObject?["cancelledCount"]?.asNumber == 2)

    let project = try await service.getProject(id: projectID)
    let statuses = Dictionary(uniqueKeysWithValues: project.tasks.map { ($0.id, $0.status) })
    #expect(statuses[firstID] == ProjectTaskStatus.cancelled.rawValue)
    #expect(statuses[secondID] == ProjectTaskStatus.cancelled.rawValue)
}

@Test
func taskDeleteAcceptsMultipleReferences() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    let context = makeToolContext(service: service, sessionID: "session-no-channel")
    let createTool = ProjectTaskCreateTool()
    let first = await createTool.invoke(
        arguments: ["title": .string("Task One"), "status": .string("backlog"), "projectId": .string(projectID)],
        context: context
    )
    let second = await createTool.invoke(
        arguments: ["title": .string("Task Two"), "status": .string("backlog"), "projectId": .string(projectID)],
        context: context
    )
    let firstID = try #require(first.data?.asObject?["taskId"]?.asString)
    let secondID = try #require(second.data?.asObject?["taskId"]?.asString)

    let deleteTool = ProjectTaskDeleteTool()
    let result = await deleteTool.invoke(
        arguments: [
            "references": .array([.string(firstID), .string(secondID.lowercased())]),
            "projectId": .string(projectID)
        ],
        context: context
    )

    #expect(result.ok == true)
    #expect(result.data?.asObject?["deletedCount"]?.asNumber == 2)

    let project = try await service.getProject(id: projectID)
    #expect(project.tasks.isEmpty)
}

@Test
func taskUpdateInvalidStatusReturnsInvalidPayload() async throws {
    let fixture = try await makeTaskUpdateFixture()
    let tool = ProjectTaskUpdateTool()

    let result = await tool.invoke(
        arguments: [
            "taskId": .string(fixture.taskID),
            "projectId": .string(fixture.projectID),
            "status": .string("finished")
        ],
        context: fixture.context
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "invalid_payload")
    #expect(result.error?.retryable == false)
    #expect(result.error?.hint?.contains("Allowed status values") == true)
}

@Test
func taskUpdateRequiresCompletionEvidence() async throws {
    let fixture = try await makeTaskUpdateFixture()
    let tool = ProjectTaskUpdateTool()

    let result = await tool.invoke(
        arguments: [
            "taskId": .string(fixture.taskID),
            "projectId": .string(fixture.projectID),
            "status": .string(ProjectTaskStatus.done.rawValue)
        ],
        context: fixture.context
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "completion_confirmation_required")
}

@Test
func taskUpdateCanSetDoneWithCompletionEvidence() async throws {
    let fixture = try await makeTaskUpdateFixture()
    let tool = ProjectTaskUpdateTool()

    let result = await tool.invoke(
        arguments: [
            "taskId": .string(fixture.taskID),
            "projectId": .string(fixture.projectID),
            "status": .string(ProjectTaskStatus.done.rawValue),
            "completionConfidence": .string(ProjectTaskCompletionConfidence.done.rawValue),
            "completionNote": .string("Verified the requested change and checked the final state.")
        ],
        context: fixture.context
    )

    #expect(result.ok == true)
    #expect(result.data?.asObject?["status"]?.asString == ProjectTaskStatus.done.rawValue)
}

// MARK: - Helper

private func makeTaskUpdateFixture() async throws -> (service: CoreService, context: ToolContext, projectID: String, taskID: String) {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)

    let projectID = "tool-proj-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Tool Test Project", description: "", channels: [])
    )
    let createResp = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResp.status == 201)

    let taskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Task Update Diagnostics",
            description: "Exercise agent tool update errors",
            priority: "medium",
            status: ProjectTaskStatus.inProgress.rawValue
        )
    )
    let taskResp = await router.handle(method: "POST", path: "/v1/projects/\(projectID)/tasks", body: taskBody)
    #expect(taskResp.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let project = try decoder.decode(ProjectRecord.self, from: taskResp.body)
    let taskID = try #require(project.tasks.first?.id)
    let context = makeToolContext(service: service, sessionID: "session-no-channel")
    return (service, context, projectID, taskID)
}

private func makeToolContext(service: CoreService, sessionID: String, currentProjectID: String? = nil) -> ToolContext {
    let tmpURL = FileManager.default.temporaryDirectory
    return ToolContext(
        agentID: "test-agent",
        sessionID: sessionID,
        policy: AgentToolsPolicy(),
        workspaceRootURL: tmpURL,
        currentProjectID: currentProjectID,
        runtime: RuntimeSystem(),
        memoryStore: InMemoryMemoryStore(),
        sessionStore: AgentSessionFileStore(agentsRootURL: tmpURL),
        agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmpURL),
        agentSkillsStore: nil,
        processRegistry: SessionProcessRegistry(),
        channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmpURL),
        store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
        searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
        mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
        logger: .sloppy(label: "test"),
        projectService: service,
        configService: nil,
        skillsService: nil,
        lspManager: nil,
        applyAgentMarkdown: nil,
        delegateSubagent: nil
    )
}
