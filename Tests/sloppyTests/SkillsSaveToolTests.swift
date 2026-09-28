import AgentRuntime
import Foundation
import Logging
import Protocols
import Testing
import SloppyRuntime
@testable import sloppy

@Test
func skillsManageToolCreatesAndUpdatesAgentSkillFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skills-save-tool-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var config = CoreConfig.test
    config.workspace = .init(name: "skills-save-tool", basePath: root.path)
    let service = CoreService(
        config: config,
        persistenceBuilder: InMemoryCorePersistenceBuilder(),
        sharedSkillsRootURLs: []
    )
    _ = try await service.createAgent(
        AgentCreateRequest(
            id: "skill-author",
            displayName: "Skill Author",
            role: "Builder"
        )
    )

    let tool = SkillsManageTool()
    let context = makeSkillsManageToolContext(root: root, service: service)
    let createArguments: [String: JSONValue] = [
        "repo": .string("draft-skill"),
        "skillMarkdown": .string("""
        ---
        name: draft-skill
        description: Helps draft focused plans.
        ---

        # Draft Skill

        Ask for one concrete next step.
        """),
        "files": .object([
            "references/checklist.md": .string("# Checklist\n")
        ])
    ]
    let created = await tool.invoke(
        arguments: createArguments,
        context: context
    )

    #expect(created.ok)
    let createdData = try #require(created.data?.asObject)
    #expect(createdData["id"]?.asString == "local/draft-skill")
    #expect(createdData["status"]?.asString == "created")
    let localPath = try #require(createdData["localPath"]?.asString)
    #expect(try String(contentsOfFile: URL(fileURLWithPath: localPath).appendingPathComponent("SKILL.md").path, encoding: .utf8).contains("Ask for one concrete next step."))
    #expect(try String(contentsOfFile: URL(fileURLWithPath: localPath).appendingPathComponent("references/checklist.md").path, encoding: .utf8) == "# Checklist\n")

    let updateArguments: [String: JSONValue] = [
        "repo": .string("draft-skill"),
        "skillMarkdown": .string("""
        ---
        name: draft-skill
        description: Helps draft focused plans.
        ---

        # Draft Skill

        Ask for one concrete next step, then write acceptance criteria.
        """)
    ]
    let updated = await tool.invoke(
        arguments: updateArguments,
        context: context
    )

    #expect(updated.ok)
    #expect(updated.data?.asObject?["status"]?.asString == "updated")
    #expect(try String(contentsOfFile: URL(fileURLWithPath: localPath).appendingPathComponent("SKILL.md").path, encoding: .utf8).contains("acceptance criteria"))
}

@Test
func skillsManageToolRejectsUnsafeExtraFilePaths() async throws {
    let service = RecordingSkillsService()
    let tool = SkillsManageTool()
    let context = makeSkillsManageToolContext(root: FileManager.default.temporaryDirectory, service: service)
    let arguments: [String: JSONValue] = [
        "repo": .string("bad-skill"),
        "skillMarkdown": .string("""
        ---
        name: bad-skill
        description: Bad path test.
        ---

        # Bad
        """),
        "files": .object([
            "../escape.md": .string("nope")
        ])
    ]

    let result = await tool.invoke(
        arguments: arguments,
        context: context
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "invalid_arguments")
    #expect(await service.saveCallCount() == 0)
}

private func makeSkillsManageToolContext(
    root: URL,
    service: any SkillsToolService
) -> ToolContext {
    ToolContext(
        agentID: "skill-author",
        sessionID: "test-session",
        policy: AgentToolsPolicy(),
        workspaceRootURL: root,
        runtime: RuntimeSystem(),
        memoryStore: InMemoryMemoryStore(),
        sessionStore: AgentSessionFileStore(agentsRootURL: root.appendingPathComponent("agents", isDirectory: true)),
        agentCatalogStore: AgentCatalogFileStore(agentsRootURL: root.appendingPathComponent("agents", isDirectory: true)),
        agentSkillsStore: nil,
        processRegistry: SessionProcessRegistry(),
        channelSessionStore: ChannelSessionFileStore(workspaceRootURL: root),
        store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
        searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
        mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
        logger: .sloppy(label: "test"),
        projectService: nil,
        configService: nil,
        skillsService: service,
        lspManager: nil,
        applyAgentMarkdown: nil,
        delegateSubagent: nil
    )
}

private actor RecordingSkillsService: SkillsToolService {
    private var calls = 0

    func saveCallCount() -> Int {
        calls
    }

    func fetchSkillsRegistry(search _: String?, sort _: String, limit _: Int, offset _: Int) async throws -> SkillsRegistryResponse {
        SkillsRegistryResponse(skills: [], total: 0)
    }

    func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse {
        AgentSkillsResponse(agentId: agentID, skills: [], skillsPath: "")
    }

    func installAgentSkill(agentID _: String, request _: SkillInstallRequest) async throws -> InstalledSkill {
        throw CoreService.AgentSkillsError.storageFailure
    }

    func uninstallAgentSkill(agentID _: String, skillID _: String) async throws {}

    func saveAgentSkill(agentID _: String, request _: SkillSaveRequest) async throws -> SkillSaveResult {
        calls += 1
        throw CoreService.AgentSkillsError.storageFailure
    }
}
