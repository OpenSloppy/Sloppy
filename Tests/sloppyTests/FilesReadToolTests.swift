import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("files.read and filesystem error mapping")
struct FilesReadToolTests {

    private func makeContext(workspaceRootURL: URL) -> ToolContext {
        let guardrails = AgentToolsGuardrails()
        let policy = AgentToolsPolicy(guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
            workspaceRootURL: workspaceRootURL,
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

    @Test("files.read returns not_found for missing file")
    func readMissingFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: ["path": .string("does-not-exist.txt")], context: context)

        #expect(result.ok == false)
        #expect(result.error?.code == "not_found")
        #expect(result.error?.retryable == false)
        #expect(result.error?.message.contains("does-not-exist.txt") == true || result.error?.message.contains(workspace.path) == true)
        #expect(result.error?.hint?.isEmpty == false)
    }

    @Test("files.read succeeds for UTF-8 file")
    func readExistingFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("note.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: ["path": .string("note.txt")], context: context)

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "hello")
        #expect(result.data?.asObject?["sizeBytes"]?.asInt == 5)
        #expect(result.data?.asObject?["offset"]?.asInt == 0)
        #expect(result.data?.asObject?["readBytes"]?.asInt == 5)
        #expect(result.data?.asObject?["nextOffset"]?.asInt == 5)
        #expect(result.data?.asObject?["truncated"]?.asBool == false)
    }

    @Test("files.read returns bounded chunk for oversized file")
    func readBoundedChunkForOversizedFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-chunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("large.txt")
        try "abcdef".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: [
            "path": .string("large.txt"),
            "maxBytes": .number(3),
        ], context: context)

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "abc")
        #expect(result.data?.asObject?["sizeBytes"]?.asInt == 6)
        #expect(result.data?.asObject?["offset"]?.asInt == 0)
        #expect(result.data?.asObject?["readBytes"]?.asInt == 3)
        #expect(result.data?.asObject?["nextOffset"]?.asInt == 3)
        #expect(result.data?.asObject?["truncated"]?.asBool == true)
    }

    @Test("files.read supports byte offsets")
    func readWithOffset() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-offset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("note.txt")
        try "abcdef".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: [
            "path": .string("note.txt"),
            "offset": .number(2),
            "maxBytes": .number(3),
        ], context: context)

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "cde")
        #expect(result.data?.asObject?["offset"]?.asInt == 2)
        #expect(result.data?.asObject?["readBytes"]?.asInt == 3)
        #expect(result.data?.asObject?["nextOffset"]?.asInt == 5)
        #expect(result.data?.asObject?["truncated"]?.asBool == true)
    }

    @Test("files.read preserves UTF-8 boundaries when chunk ends mid-scalar")
    func readTrimsIncompleteUTF8Suffix() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-utf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("unicode.txt")
        try "éé".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: [
            "path": .string("unicode.txt"),
            "maxBytes": .number(3),
        ], context: context)

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "é")
        #expect(result.data?.asObject?["sizeBytes"]?.asInt == 4)
        #expect(result.data?.asObject?["readBytes"]?.asInt == 2)
        #expect(result.data?.asObject?["nextOffset"]?.asInt == 2)
        #expect(result.data?.asObject?["truncated"]?.asBool == true)
    }

    @Test("files.read rejects invalid UTF-8")
    func readInvalidUTF8() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-invalid-utf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("binary.dat")
        try Data([0xC3]).write(to: fileURL)

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: ["path": .string("binary.dat")], context: context)

        #expect(result.ok == false)
        #expect(result.error?.code == "binary_not_supported")
    }

    @Test("files.read returns is_directory when path is a directory")
    func readDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-files-read-dir-\(UUID().uuidString)", isDirectory: true)
        let subdir = workspace.appendingPathComponent("adir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = makeContext(workspaceRootURL: workspace)
        let tool = FilesReadTool()
        let result = await tool.invoke(arguments: ["path": .string("adir")], context: context)

        #expect(result.ok == false)
        #expect(result.error?.code == "is_directory")
        #expect(result.error?.retryable == false)
        #expect(result.error?.hint?.isEmpty == false)
    }

    @Test("FileSystemToolErrorMapping maps Cocoa read not found")
    func mapsCocoaReadNotFound() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [:])
        let d = FileSystemToolErrorMapping.describe(error: error, operation: .read, path: "/tmp/missing.md")
        #expect(d.code == "not_found")
        #expect(d.retryable == false)
        #expect(d.hint?.isEmpty == false)
    }

    @Test("FileSystemToolErrorMapping maps POSIX EACCES for read")
    func mapsPOSIXPermissionRead() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [:])
        let d = FileSystemToolErrorMapping.describe(error: error, operation: .read, path: "/tmp/x")
        #expect(d.code == "permission_denied")
        #expect(d.retryable == false)
    }
}
