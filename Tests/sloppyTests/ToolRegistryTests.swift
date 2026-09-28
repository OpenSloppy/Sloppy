import Foundation
import AnyLanguageModel
import Logging
import PluginSDK
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

@Suite("ToolRegistry")
struct ToolRegistryTests {
    private let registry = ToolRegistry.makeDefault()

    @Test("Built-in and MCP tools are registered")
    func allToolsRegistered() {
        let expectedIDs: Set<String> = [
            "files.read", "files.edit", "files.write", "images.generate", "artifacts.widget.generate", "artifacts.web.create",
            "runtime.exec", "runtime.process",
            "computer.click", "computer.type", "computer.key", "computer.screenshot",
            "browser.open", "browser.navigate", "browser.click", "browser.type",
            "browser.screenshot", "browser.status", "browser.close",
            "debug.read_logs",
            "web.search", "web.fetch",
            "branches.spawn",
            "workers.spawn", "agents.delegate_task", "agent_delegate.finish", "workers.route",
            "sessions.spawn", "sessions.list", "sessions.history", "sessions.status",
            "messages.send", "sessions.send",
            "memory.recall", "memory.get", "memory.save", "memory.search",
            "mcp.list_servers", "mcp.list_tools", "mcp.call_tool",
            "mcp.list_resources", "mcp.read_resource",
            "mcp.list_prompts", "mcp.get_prompt",
            "mcp.save_server", "mcp.update_server",
            "mcp.remove_server", "mcp.delete_server",
            "mcp.install_server", "mcp.uninstall_server",
            "agents.list",
            "channel.history",
            "system.list_tools", "session.complete",
            "planning.select_route", "planning.request_input", "planning.progress_update",
            "cron",
            "project.list", "project.current", "project.create", "project.update", "project.delete",
            "project.task_list", "project.task_create", "project.task_get",
            "project.task_update", "project.task_clarification_create",
            "project.task_cancel", "project.task_delete", "project.escalate_to_user",
            "actor.discuss_with_actor", "actor.conclude_discussion",
            "skills.search", "skills.list", "skills.install", "skills.manage", "skills.uninstall"
        ]
        let knownIDs = registry.knownToolIDs
        for id in expectedIDs {
            #expect(knownIDs.contains(id), "Missing tool ID: \(id)")
        }
    }

    @Test("Catalog entries count matches unique tools")
    func catalogEntriesCountMatchesUniqueTools() {
        let entries = registry.catalogEntries
        // sessions.send is an alias for messages.send, so count is unique primary IDs
        #expect(entries.count >= 29)
        #expect(entries.allSatisfy { !$0.id.isEmpty })
    }

    @Test("Catalog entry IDs match known tool IDs")
    func catalogEntryIDsAreRegistered() {
        let entries = registry.catalogEntries
        let knownIDs = registry.knownToolIDs
        for entry in entries {
            #expect(knownIDs.contains(entry.id), "Catalog entry '\(entry.id)' not found in registry")
        }
    }

    @Test("ToolCatalog.entries is non-empty")
    func toolCatalogEntriesNonEmpty() {
        #expect(!ToolCatalog.builtInEntries.isEmpty)
    }

    @Test("ToolCatalog.knownToolIDs contains expected tools")
    func toolCatalogKnownToolIDs() {
        #expect(ToolCatalog.knownToolIDs.contains("files.read"))
        #expect(ToolCatalog.knownToolIDs.contains("project.current"))
        #expect(ToolCatalog.knownToolIDs.contains("project.task_list"))
        #expect(ToolCatalog.knownToolIDs.contains("actor.discuss_with_actor"))
        #expect(ToolCatalog.knownToolIDs.contains("agent_delegate.finish"))
        #expect(ToolCatalog.knownToolIDs.contains("mcp.call_tool"))
        #expect(ToolCatalog.knownToolIDs.contains("browser.open"))
        #expect(ToolCatalog.knownToolIDs.contains("browser.screenshot"))
        #expect(ToolCatalog.knownToolIDs.contains("debug.read_logs"))
        #expect(ToolCatalog.knownToolIDs.contains("session.complete"))
        #expect(ToolCatalog.knownToolIDs.contains("artifacts.widget.generate"))
        #expect(ToolCatalog.knownToolIDs.contains("artifacts.web.create"))
        #expect(ToolCatalog.knownToolIDs.contains("images.generate"))
    }

    @Test("ToolCatalog schema advertises project.current arguments")
    func toolCatalogProjectCurrentSchema() throws {
        let schema = try #require(ToolCatalog.parameterSchemas["project.current"]?.asObject)
        let properties = try #require(schema["properties"]?.asObject)
        #expect(properties.keys.contains("channelId"))
        #expect(properties.keys.contains("topicId"))
    }

    @Test("session.complete schema requires a typed outcome")
    func sessionCompleteSchemaRequiresTypedOutcome() throws {
        let schema = try #require(ToolCatalog.parameterSchemas["session.complete"]?.asObject)
        let properties = try #require(schema["properties"]?.asObject)
        let status = try #require(properties["status"]?.asObject)

        #expect(schema["required"]?.asArray?.compactMap(\.asString) == ["status", "summary"])
        #expect(status["enum"]?.asArray?.compactMap(\.asString) == ["completed", "blocked", "waiting_input"])
        #expect(properties["verification"]?.asObject?["type"]?.asString == "array")
        #expect(properties["verificationEvidenceIds"]?.asObject?["type"]?.asString == "array")
        #expect(properties["limitations"]?.asObject?["type"]?.asString == "array")
    }

    @Test("allTools returns unique tools with valid names and parameters")
    func allToolsAreUniqueAndWellFormed() {
        let tools = registry.allTools
        #expect(!tools.isEmpty)
        let names = tools.map { $0.name }
        let uniqueNames = Set(names)
        #expect(names.count == uniqueNames.count, "allTools contains duplicate tool names")
        for tool in tools {
            #expect(!tool.name.isEmpty)
            #expect(!tool.description.isEmpty)
        }
    }

    @Test("all tool parameter schemas encode object roots")
    func allToolParameterSchemasEncodeObjectRoots() throws {
        for tool in registry.allTools {
            let schema = try schemaRoot(tool.parameters)
            #expect(schema["type"] as? String == "object", "\(tool.name) parameters must be an object schema")
        }
    }

    @Test("all tool schemas avoid nested refs after root resolution")
    func allToolSchemasAvoidNestedRefsAfterRootResolution() throws {
        for tool in registry.allTools {
            let schema = try schemaRoot(tool.parameters)
            #expect(containsJSONSchemaRef(schema) == false, "\(tool.name) parameters must not contain nested $ref")
        }
    }

    @Test("allTools count matches catalog entries count")
    func allToolsCountMatchesCatalogEntries() {
        let tools = registry.allTools
        let catalog = registry.catalogEntries
        #expect(tools.count == catalog.count)
    }

    @Test("Memory recall and search schemas advertise scope arguments")
    func memoryRecallAndSearchSchemasAdvertiseScopeArguments() throws {
        let tools = Dictionary(uniqueKeysWithValues: registry.allTools.map { ($0.name, $0) })
        let recall = try #require(tools["memory.recall"])
        let search = try #require(tools["memory.search"])

        let recallProperties = try schemaPropertyNames(recall.parameters)
        let searchProperties = try schemaPropertyNames(search.parameters)

        for key in ["scope", "scope_type", "scope_id"] {
            #expect(recallProperties.contains(key), "memory.recall missing \(key)")
            #expect(searchProperties.contains(key), "memory.search missing \(key)")
        }
    }

    @Test("Project task create schema requires title")
    func projectTaskCreateSchemaRequiresTitle() throws {
        let tools = Dictionary(uniqueKeysWithValues: registry.allTools.map { ($0.name, $0) })
        let taskCreate = try #require(tools["project.task_create"])
        let schema = try schemaRoot(taskCreate.parameters)
        let properties = try #require(schema["properties"] as? [String: Any])
        let required = try #require(schema["required"] as? [String])

        #expect(properties.keys.contains("title"))
        #expect(required.contains("title"))
    }

    @Test("Skills manage schema advertises save arguments")
    func skillsManageSchemaAdvertisesSaveArguments() throws {
        let tools = Dictionary(uniqueKeysWithValues: registry.allTools.map { ($0.name, $0) })
        let skillsManage = try #require(tools["skills.manage"])
        let schema = try schemaRoot(skillsManage.parameters)
        let properties = try #require(schema["properties"] as? [String: Any])
        let required = try #require(schema["required"] as? [String])

        #expect(properties.keys.contains("repo"))
        #expect(properties.keys.contains("skillMarkdown"))
        #expect(properties.keys.contains("files"))
        #expect(properties.keys.contains("allowedTools"))
        #expect(required.contains("repo"))
        #expect(required.contains("skillMarkdown"))
    }

    @Test("Skills manage schema exports as provider-safe object schema")
    func skillsManageSchemaExportsAsProviderSafeObjectSchema() throws {
        let tools = Dictionary(uniqueKeysWithValues: registry.allTools.map { ($0.name, $0) })
        let skillsManage = try #require(tools["skills.manage"])

        let schema = ModelToolSchemaNormalizer.providerSafeObjectSchema(skillsManage.parameters)
        let properties = try #require(schema["properties"] as? [String: Any])
        let files = try #require(properties["files"] as? [String: Any])
        let fileItems = try #require(files["items"] as? [String: Any])

        #expect(schema["type"] as? String == "object")
        #expect(schema["$ref"] == nil)
        #expect(schema["$defs"] == nil)
        #expect(fileItems["type"] as? String == "object")
        #expect(fileItems["$ref"] == nil)
        #expect(fileItems["$defs"] == nil)
    }

    @Test("Memory save still rejects missing scope")
    func memorySaveRejectsMissingScope() async {
        let tool = MemorySaveTool()
        let result = await tool.invoke(
            arguments: ["note": .string("remember this without scope")],
            context: makeMemoryToolContext()
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
        #expect(result.error?.message.contains("Set memory scope") == true)
    }

    @Test("Memory tools reject shared scope when disabled")
    func memoryToolsRejectSharedScopeWhenDisabled() async {
        let context = makeMemoryToolContext(sharedMemoryEnabled: false)
        let arguments: [String: Protocols.JSONValue] = [
            "query": .string("user name"),
            "scope_type": .string("global"),
            "scope_id": .string("shared")
        ]

        let recallResult = await MemoryGetTool().invoke(arguments: arguments, context: context)
        let searchResult = await MemorySearchTool().invoke(arguments: arguments, context: context)
        let saveResult = await MemorySaveTool().invoke(
            arguments: [
                "note": .string("The user's name is Vlad."),
                "scope_type": .string("global"),
                "scope_id": .string("shared")
            ],
            context: context
        )

        #expect(recallResult.ok == false)
        #expect(recallResult.error?.code == "shared_memory_disabled")
        #expect(searchResult.ok == false)
        #expect(searchResult.error?.code == "shared_memory_disabled")
        #expect(saveResult.ok == false)
        #expect(saveResult.error?.code == "shared_memory_disabled")
    }

    @Test("Dynamic MCP tool ids use configured prefix or server default")
    func dynamicMCPToolIDNaming() {
        #expect(
            MCPClientRegistry.dynamicToolID(serverID: "fs", toolName: "read_file", prefix: nil)
                == "mcp.fs.read_file"
        )
        #expect(
            MCPClientRegistry.dynamicToolID(serverID: "fs", toolName: "read_file", prefix: "workspace")
                == "workspace.read_file"
        )
    }

    private func schemaPropertyNames(_ schema: GenerationSchema) throws -> Set<String> {
        let data = try JSONEncoder().encode(schema)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties: [String: Any]
        if let inline = object["properties"] as? [String: Any] {
            properties = inline
        } else {
            let ref = try #require(object["$ref"] as? String)
            let name = ref.replacingOccurrences(of: "#/$defs/", with: "")
            let defs = try #require(object["$defs"] as? [String: Any])
            let root = try #require(defs[name] as? [String: Any])
            properties = try #require(root["properties"] as? [String: Any])
        }
        return Set(properties.keys)
    }

    private func schemaRoot(_ schema: GenerationSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let ref = object["$ref"] as? String {
            let name = ref.replacingOccurrences(of: "#/$defs/", with: "")
            let defs = try #require(object["$defs"] as? [String: Any])
            object = try #require(defs[name] as? [String: Any])
        }
        return object
    }

    private func containsJSONSchemaRef(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object["$ref"] != nil { return true }
            return object.values.contains { containsJSONSchemaRef($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsJSONSchemaRef($0) }
        }
        return false
    }

    @Test("Memory corrections update the same record and cannot cross scopes")
    func memorySaveUpdatesExistingScopedRecord() async {
        let context = makeMemoryToolContext()
        let tool = MemorySaveTool()
        let original = await tool.invoke(arguments: [
            "note": .string("Project uses XCTest"), "summary": .string("XCTest"),
            "scope_type": .string("project"), "scope_id": .string("aurora")
        ], context: context)
        guard let memoryID = original.data?.asObject?["id"]?.asString else {
            Issue.record("Memory was not saved")
            return
        }
        let wrongScope = await tool.invoke(arguments: [
            "note": .string("Incorrect scope mutation"), "memory_id": .string(memoryID),
            "scope_type": .string("project"), "scope_id": .string("other")
        ], context: context)
        #expect(wrongScope.ok == false)
        let corrected = await tool.invoke(arguments: [
            "note": .string("Project uses Swift Testing"), "memory_id": .string(memoryID),
            "scope_type": .string("project"), "scope_id": .string("aurora")
        ], context: context)
        #expect(corrected.ok)
        let entries = await context.memoryStore.entries(filter: .init(scope: .project("aurora")))
        #expect(entries.count == 1)
        #expect(entries.first?.id == memoryID)
        #expect(entries.first?.note == "Project uses Swift Testing")
        #expect(entries.first?.summary == "Project uses Swift Testing")
    }

    private func makeMemoryToolContext(sharedMemoryEnabled: Bool = true) -> ToolContext {
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "test-session",
            sharedMemoryEnabled: sharedMemoryEnabled,
            policy: AgentToolsPolicy(),
            workspaceRootURL: tmp,
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
}
