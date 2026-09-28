import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

@Test
func workflowToolIsRegisteredInDefaultRegistry() {
    let registry = ToolRegistry.makeDefault()

    #expect(registry.knownToolIDs.contains("project.workflow"))
    #expect(registry.knownToolIDs.contains("web.request"))
}

@Test
func workflowToolProposesWorkflowAndReturnsDashboardUrl() async throws {
    let fixture = try await makeWorkflowToolFixture()
    let tool = WorkflowTool()

    let result = await tool.invoke(
        arguments: starterWorkflowArguments(projectID: fixture.projectID, taskID: fixture.taskID),
        context: fixture.context
    )

    #expect(result.ok == true)
    let data = try #require(result.data?.asObject)
    let workflowID = try #require(data["workflowId"]?.asString)
    #expect(!workflowID.isEmpty)
    #expect(data["definitionUrl"]?.asString == "/projects/\(fixture.projectID)/workflows/\(workflowID)")
    #expect(data["runId"] == JSONValue.null)
    #expect(data["validationIssues"]?.asArray?.isEmpty == true)

    let definitions = try await fixture.service.listWorkflowDefinitions(projectID: fixture.projectID)
    #expect(definitions.map(\.id) == [workflowID])
    #expect(definitions.first?.nodes.contains { $0.type == .agentStep } == true)
    #expect(definitions.first?.nodes.first { $0.id == "implement" }?.config["agentId"]?.asString == "test-agent")
    #expect(definitions.first?.edges.first?.sourceSocket == "right")
    #expect(definitions.first?.edges.first?.targetSocket == "left")
}

@Test
func workflowToolRejectsInvalidGraphWithValidationIssues() async throws {
    let fixture = try await makeWorkflowToolFixture()
    let tool = WorkflowTool()
    var arguments = starterWorkflowArguments(projectID: fixture.projectID, taskID: fixture.taskID)
    arguments["edges"] = .array([
        .object([
            "id": .string("missing"),
            "sourceNodeId": .string("start"),
            "targetNodeId": .string("missing-node")
        ])
    ])

    let result = await tool.invoke(arguments: arguments, context: fixture.context)

    #expect(result.ok == false)
    #expect(result.error?.code == "validation_failed")
    let issues = result.data?.asObject?["validationIssues"]?.asArray ?? []
    #expect(issues.isEmpty == false)
}

@Test
func workflowToolStartsAndReportsWorkflowRunUrl() async throws {
    let fixture = try await makeWorkflowToolFixture()
    let tool = WorkflowTool()
    let proposed = await tool.invoke(
        arguments: starterWorkflowArguments(projectID: fixture.projectID, taskID: fixture.taskID),
        context: fixture.context
    )
    let workflowID = try #require(proposed.data?.asObject?["workflowId"]?.asString)

    let startArguments: [String: JSONValue] = [
            "operation": .string("start"),
            "projectId": .string(fixture.projectID),
            "workflowId": .string(workflowID),
            "taskId": .string(fixture.taskID),
            "startedBy": .string("agent:test-agent")
    ]
    let started = await tool.invoke(
        arguments: startArguments,
        context: fixture.context
    )

    #expect(started.ok == true)
    let runID = try #require(started.data?.asObject?["runId"]?.asString)
    #expect(started.data?.asObject?["runUrl"]?.asString == "/projects/\(fixture.projectID)/workflow-runs/\(runID)")

    let statusArguments: [String: JSONValue] = [
            "operation": .string("status"),
            "projectId": .string(fixture.projectID),
            "runId": .string(runID)
    ]
    let status = await tool.invoke(
        arguments: statusArguments,
        context: fixture.context
    )

    #expect(status.ok == true)
    #expect(status.data?.asObject?["runUrl"]?.asString == "/projects/\(fixture.projectID)/workflow-runs/\(runID)")
}

@Test
func workflowToolListsAndStartsWorkflowByName() async throws {
    let fixture = try await makeWorkflowToolFixture()
    let tool = WorkflowTool()
    let proposed = await tool.invoke(
        arguments: starterWorkflowArguments(projectID: fixture.projectID, taskID: fixture.taskID),
        context: fixture.context
    )
    let workflowID = try #require(proposed.data?.asObject?["workflowId"]?.asString)

    let listed = await tool.invoke(
        arguments: [
            "operation": .string("list"),
            "projectId": .string(fixture.projectID)
        ],
        context: fixture.context
    )

    #expect(listed.ok == true)
    let workflows = try #require(listed.data?.asObject?["workflows"]?.asArray)
    #expect(workflows.first?.asObject?["workflowId"]?.asString == workflowID)
    #expect(workflows.first?.asObject?["name"]?.asString == "Implement feature workflow")

    let started = await tool.invoke(
        arguments: [
            "operation": .string("start"),
            "projectId": .string(fixture.projectID),
            "name": .string("Implement feature workflow"),
            "taskId": .string(fixture.taskID)
        ],
        context: fixture.context
    )

    #expect(started.ok == true)
    #expect(started.data?.asObject?["workflowId"]?.asString == workflowID)
    #expect(started.data?.asObject?["runId"]?.asString?.isEmpty == false)
}

private struct WorkflowToolFixture {
    var service: CoreService
    var context: ToolContext
    var projectID: String
    var taskID: String
}

private func makeWorkflowToolFixture() async throws -> WorkflowToolFixture {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let router = CoreRouter(service: service)
    let projectID = "workflow-tool-\(UUID().uuidString)"
    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(id: projectID, name: "Workflow Tool Project", description: "", channels: [])
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let taskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(title: "Implement workflow skill", description: "", priority: "medium", status: "backlog")
    )
    let taskResponse = await router.handle(method: "POST", path: "/v1/projects/\(projectID)/tasks", body: taskBody)
    #expect(taskResponse.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let project = try decoder.decode(ProjectRecord.self, from: taskResponse.body)
    let taskID = try #require(project.tasks.first?.id)

    return WorkflowToolFixture(
        service: service,
        context: makeWorkflowToolContext(service: service, projectID: projectID),
        projectID: projectID,
        taskID: taskID
    )
}

private func makeWorkflowToolContext(service: CoreService, projectID: String) -> ToolContext {
    let tmpURL = FileManager.default.temporaryDirectory
    return ToolContext(
        agentID: "test-agent",
        sessionID: "session-workflow-tool",
        policy: AgentToolsPolicy(),
        workspaceRootURL: tmpURL,
        currentProjectID: projectID,
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

private func starterWorkflowArguments(projectID: String, taskID: String) -> [String: JSONValue] {
    [
        "operation": .string("propose"),
        "projectId": .string(projectID),
        "taskId": .string(taskID),
        "name": .string("Implement feature workflow"),
        "rationale": .string("Visible plan before execution"),
        "lanes": .array([
            .object(["id": .string("agent"), "title": .string("Agent"), "kind": .string("agent")]),
            .object(["id": .string("system"), "title": .string("System"), "kind": .string("system")])
        ]),
        "nodes": .array([
            .object(["id": .string("start"), "type": .string("trigger"), "title": .string("Start"), "laneId": .string("system"), "positionX": .number(80), "positionY": .number(80)]),
            .object([
                "id": .string("implement"),
                "type": .string("agent_step"),
                "title": .string("Implement"),
                "laneId": .string("agent"),
                "config": .string(#"{"agentId":"test-agent","sessionId":"session-workflow-tool"}"#),
                "positionX": .number(360),
                "positionY": .number(80)
            ]),
            .object(["id": .string("done"), "type": .string("end"), "title": .string("Done"), "laneId": .string("system"), "config": .object(["status": .string("completed")]), "positionX": .number(640), "positionY": .number(80)])
        ]),
        "edges": .array([
            .object([
                "id": .string("e_start_implement"),
                "sourceNodeId": .string("start"),
                "targetNodeId": .string("implement"),
                "sourceSocket": .string("right"),
                "targetSocket": .string("left")
            ]),
            .object([
                "id": .string("e_implement_done"),
                "sourceNodeId": .string("implement"),
                "targetNodeId": .string("done"),
                "sourceSocket": .string("bottom"),
                "targetSocket": .string("top")
            ])
        ])
    ]
}
