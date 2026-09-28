import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

@Suite("DebugReadLogsTool")
struct DebugReadLogsToolTests {
    @Test("summarizes valid NDJSON and parse errors")
    func summarizesValidNDJSONAndParseErrors() async throws {
        let workspace = try makeWorkspace()
        let logURL = workspace.appendingPathComponent(".sloppy/debug/debug-abc123.log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"sessionId":"abc123","timestamp":1000,"hypothesisId":"H1","location":"Autocomplete:getSuggestions","message":"enter","data":{"elapsedMs":4,"itemCount":2}}
        {"sessionId":"abc123","timestamp":1200,"hypothesisId":"H1","location":"Autocomplete:getSuggestions","message":"enter","data":{"elapsedMs":8,"itemCount":3}}
        {"sessionId":"other","timestamp":1300,"hypothesisId":"H2","location":"Other","message":"ignored","data":{"elapsedMs":99}}
        not-json
        {"sessionId":"abc123","timestamp":1400,"hypothesisId":"H2","location":"Autocomplete:applyCompletion","message":"applied"}
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let result = await DebugReadLogsTool().invoke(
            arguments: [
                "path": .string(".sloppy/debug/debug-abc123.log"),
                "sessionId": .string("abc123"),
            ],
            context: makeContext(workspace: workspace)
        )

        #expect(result.ok == true)
        let data = try #require(result.data?.asObject)
        #expect(data["entryCount"]?.asInt == 3)
        #expect(data["parseErrorCount"]?.asInt == 1)
        #expect(data["firstTimestamp"]?.asInt == 1000)
        #expect(data["lastTimestamp"]?.asInt == 1400)

        let groups = try #require(data["groups"]?.asArray)
        #expect(groups.count == 2)
        let firstGroup = try #require(groups.first?.asObject)
        #expect(firstGroup["hypothesisId"]?.asString == "H1")
        #expect(firstGroup["count"]?.asInt == 2)
        let timing = try #require(firstGroup["timingSummary"]?.asObject)
        #expect(timing["count"]?.asInt == 2)
        #expect(timing["min"]?.asInt == 4)
        #expect(timing["max"]?.asInt == 8)
        #expect(timing["avg"]?.asInt == 6)

        let recent = try #require(data["recentEntries"]?.asArray)
        #expect(recent.count == 3)
    }

    @Test("empty log returns empty summary")
    func emptyLogReturnsEmptySummary() async throws {
        let workspace = try makeWorkspace()
        let logURL = workspace.appendingPathComponent(".sloppy/debug/debug-empty.log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: logURL, atomically: true, encoding: .utf8)

        let result = await DebugReadLogsTool().invoke(
            arguments: ["path": .string(".sloppy/debug/debug-empty.log")],
            context: makeContext(workspace: workspace)
        )

        #expect(result.ok == true)
        let data = try #require(result.data?.asObject)
        #expect(data["entryCount"]?.asInt == 0)
        #expect(data["parseErrorCount"]?.asInt == 0)
        #expect(data["groups"]?.asArray?.isEmpty == true)
    }

    @Test("rejects oversized log")
    func rejectsOversizedLog() async throws {
        let workspace = try makeWorkspace()
        let logURL = workspace.appendingPathComponent("debug.log")
        try String(repeating: "x", count: 20).write(to: logURL, atomically: true, encoding: .utf8)

        let result = await DebugReadLogsTool().invoke(
            arguments: [
                "path": .string("debug.log"),
                "maxBytes": .number(5),
            ],
            context: makeContext(workspace: workspace)
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "file_too_large")
    }

    @Test("rejects path outside workspace")
    func rejectsPathOutsideWorkspace() async throws {
        let workspace = try makeWorkspace()
        let outside = try makeWorkspace()
        let outsideLog = outside.appendingPathComponent("debug.log")
        try "{}\n".write(to: outsideLog, atomically: true, encoding: .utf8)

        let result = await DebugReadLogsTool().invoke(
            arguments: ["path": .string(outsideLog.path)],
            context: makeContext(workspace: workspace)
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "path_not_allowed")
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sloppy-debug-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeContext(workspace: URL) -> ToolContext {
        ToolContext(
            agentID: "test-agent",
            sessionID: "test-session",
            policy: AgentToolsPolicy(),
            workspaceRootURL: workspace,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: workspace),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: workspace),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: workspace),
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
