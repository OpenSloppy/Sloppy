import Foundation
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

@Test("site tools publish, list, update, and delete for current principal")
func publishedSiteToolLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("published-site-tools-\(UUID().uuidString)", isDirectory: true)
    let build = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try Data("<html>tool</html>".utf8).write(to: build.appendingPathComponent("index.html"))
    defer { try? FileManager.default.removeItem(at: root) }

    let service = CoreService(
        config: .test,
        currentDirectory: root.path,
        persistenceBuilder: InMemoryCorePersistenceBuilder(),
        sharedSkillsRootURLs: []
    )
    let context = ToolContext(
        agentID: "site-agent",
        sessionID: "site-session",
        userID: "owner-1",
        policy: AgentToolsPolicy(guardrails: AgentToolsGuardrails()),
        workspaceRootURL: root,
        currentDirectoryURL: root,
        currentProjectID: "project-1",
        runtime: RuntimeSystem(),
        memoryStore: InMemoryMemoryStore(),
        sessionStore: AgentSessionFileStore(agentsRootURL: root),
        agentCatalogStore: AgentCatalogFileStore(agentsRootURL: root),
        agentSkillsStore: nil,
        processRegistry: SessionProcessRegistry(),
        channelSessionStore: ChannelSessionFileStore(workspaceRootURL: root),
        store: InMemoryCorePersistenceBuilder().makeStore(config: .test),
        searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
        mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
        logger: .sloppy(label: "test.sites"),
        projectService: nil,
        configService: nil,
        skillsService: nil,
        siteService: service,
        lspManager: nil,
        applyAgentMarkdown: nil,
        delegateSubagent: nil
    )

    let published = await SitesPublishTool().invoke(arguments: [
        "sourcePath": .string("dist"),
        "slug": .string("tool-site"),
        "title": .string("Tool Site"),
    ], context: context)
    #expect(published.ok)
    let siteID = try #require(published.data?.asObject?["site"]?.asObject?["id"]?.asString)

    let listed = await SitesListTool().invoke(arguments: [:], context: context)
    #expect(listed.data?.asObject?["sites"]?.asArray?.count == 1)

    let updated = await SitesUpdateTool().invoke(arguments: [
        "siteId": .string(siteID),
        "title": .string("Updated Tool Site"),
    ], context: context)
    #expect(updated.ok)

    let confirmationRequired = await SitesDeleteTool().invoke(arguments: [
        "siteId": .string(siteID),
        "confirmed": .bool(false),
    ], context: context)
    #expect(confirmationRequired.error?.code == "confirmation_required")

    let deleted = await SitesDeleteTool().invoke(arguments: [
        "siteId": .string(siteID),
        "confirmed": .bool(true),
    ], context: context)
    #expect(deleted.ok)
}
