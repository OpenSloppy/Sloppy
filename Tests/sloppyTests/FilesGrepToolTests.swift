import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("files.grep")
struct FilesGrepToolTests {
    private func makeContext(
        workspaceRootURL: URL,
        maxReadBytes: Int = 512 * 1024,
        allowedWriteRoots: [String] = [],
        currentDirectoryURL: URL? = nil
    ) -> ToolContext {
        let guardrails = AgentToolsGuardrails(
            maxReadBytes: maxReadBytes,
            allowedWriteRoots: allowedWriteRoots
        )
        let policy = AgentToolsPolicy(guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
            workspaceRootURL: workspaceRootURL,
            currentDirectoryURL: currentDirectoryURL,
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

    @Test("literal grep finds UTF-8 files recursively and skips excluded directories")
    func literalGrepFindsMatchesAndSkipsExcludedDirectories() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let src = workspace.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "first\nHello Needle\nlast\n".write(to: src.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let nodeModules = workspace.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "Needle should be ignored\n".write(to: nodeModules.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

        let result = await FilesGrepTool().invoke(
            arguments: ["query": .string("needle"), "path": .string(".")],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == true)
        let matches = result.data?.asObject?["matches"]?.asArray ?? []
        #expect(matches.count == 1)
        let first = matches.first?.asObject
        #expect(first?["path"]?.asString == "src/App.swift")
        #expect(first?["line"]?.asInt == 2)
        #expect(first?["column"]?.asInt == 7)
        #expect(first?["match"]?.asString == "Needle")
        #expect(result.data?.asObject?["filesSkipped"]?.asInt == 0)
    }

    @Test("regex grep supports case-sensitive matching")
    func regexGrepSupportsCaseSensitiveMatching() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "RouteAction\nrouteAction\n".write(to: workspace.appendingPathComponent("routes.txt"), atomically: true, encoding: .utf8)

        let result = await FilesGrepTool().invoke(
            arguments: [
                "query": .string(#"Route[A-Z][A-Za-z]+"#),
                "regex": .bool(true),
                "caseSensitive": .bool(true),
            ],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == true)
        let matches = result.data?.asObject?["matches"]?.asArray ?? []
        #expect(matches.count == 1)
        #expect(matches.first?.asObject?["match"]?.asString == "RouteAction")
    }

    @Test("invalid regex returns invalid_arguments")
    func invalidRegexReturnsInvalidArguments() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = await FilesGrepTool().invoke(
            arguments: ["query": .string("["), "regex": .bool(true)],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
    }

    @Test("grep clamps matches and marks result truncated")
    func grepClampsMatchesAndMarksTruncated() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "hit\nhit\nhit\n".write(to: workspace.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)

        let result = await FilesGrepTool().invoke(
            arguments: ["query": .string("hit"), "maxMatches": .number(2)],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["matchesCount"]?.asInt == 2)
        #expect(result.data?.asObject?["truncated"]?.asBool == true)
    }

    @Test("grep skips files larger than maxFileBytes")
    func grepSkipsLargeFiles() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "needle in a too-large file\n".write(to: workspace.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)

        let result = await FilesGrepTool(executableResolver: { _ in nil }).invoke(
            arguments: ["query": .string("needle"), "maxFileBytes": .number(4)],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["backend"]?.asString == "swift")
        #expect(result.data?.asObject?["matchesCount"]?.asInt == 0)
        #expect(result.data?.asObject?["filesSkipped"]?.asInt == 1)
    }

    @Test("grep prefers rg when available")
    func grepPrefersRipgrepWhenAvailable() async throws {
        guard let rgURL = findExecutableInPath(named: "rg") else {
            return
        }
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "needle\n".write(to: workspace.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let result = await FilesGrepTool(executableResolver: { name in
            name == "rg" ? rgURL : nil
        }).invoke(
            arguments: ["query": .string("needle")],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["backend"]?.asString == "rg")
        #expect(result.data?.asObject?["matchesCount"]?.asInt == 1)
    }

    @Test("grep falls back to system grep when rg is unavailable")
    func grepFallsBackToSystemGrepWhenRipgrepIsUnavailable() async throws {
        let grepURL = try #require(findExecutableInPath(named: "grep"))
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "needle\n".write(to: workspace.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let result = await FilesGrepTool(executableResolver: { name in
            name == "grep" ? grepURL : nil
        }).invoke(
            arguments: ["query": .string("needle")],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["backend"]?.asString == "grep")
        #expect(result.data?.asObject?["matchesCount"]?.asInt == 1)
    }

    @Test("grep rejects paths outside allowed roots")
    func grepRejectsOutsidePath() async throws {
        let workspace = try makeWorkspace()
        let outside = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }

        let result = await FilesGrepTool().invoke(
            arguments: ["query": .string("needle"), "path": .string(outside.path)],
            context: makeContext(workspaceRootURL: workspace)
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "path_not_allowed")
    }

    @Test("default grep searches added roots as well as current directory")
    func defaultGrepSearchesAddedRoots() async throws {
        let workspace = try makeWorkspace()
        let firstRoot = try makeWorkspace()
        let secondRoot = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        try "only in second root\n".write(
            to: secondRoot.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = await FilesGrepTool(executableResolver: { _ in nil }).invoke(
            arguments: ["query": .string("second root")],
            context: makeContext(
                workspaceRootURL: workspace,
                allowedWriteRoots: [firstRoot.path, secondRoot.path],
                currentDirectoryURL: firstRoot
            )
        )

        #expect(result.ok == true)
        let paths = (result.data?.asObject?["paths"]?.asArray ?? []).compactMap(\.asString)
        #expect(paths.contains(secondRoot.path))
        let matches = result.data?.asObject?["matches"]?.asArray ?? []
        #expect(matches.first?.asObject?["path"]?.asString == secondRoot.appendingPathComponent("marker.txt").path)
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sloppy-files-grep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}
