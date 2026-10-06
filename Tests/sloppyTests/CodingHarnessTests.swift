import Foundation
import Logging
import Testing
import LanguageServerProtocol
import SloppyRuntime
@testable import AgentRuntime
@testable import Protocols
@testable import sloppy

struct CodingHarnessFixture {
    let root: URL
    let mutations = FileMutationCoordinator()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sloppy-harness-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func context(session: String = "session-test", lsp: LSPServerManager? = nil, maxOutputBytes: Int? = nil) -> ToolContext {
        var policy = AgentToolsPolicy()
        if let maxOutputBytes { policy.guardrails.maxExecOutputBytes = maxOutputBytes }
        return ToolContext(
            agentID: "test-agent", sessionID: session, policy: policy, workspaceRootURL: root,
            runtime: RuntimeSystem(), memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: root),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: root), agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(), channelSessionStore: ChannelSessionFileStore(workspaceRootURL: root),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp), logger: .sloppy(label: "test.harness"),
            projectService: nil, configService: nil, skillsService: nil, lspManager: lsp,
            fileMutations: mutations, applyAgentMarkdown: nil, delegateSubagent: nil
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Coding harness file mutations")
struct CodingHarnessFileTests {
    @Test("Public tool catalog exposes optimistic hash parameters")
    func catalogParameters() async throws {
        let catalog = await ToolCatalog.listToolsPayload(mcpRegistry: nil)
        for name in ["files.edit", "files.write"] {
            let entry = try #require(catalog.first { $0.asObject?["name"] == .string(name) }?.asObject)
            let properties = try #require(entry["parameters"]?.asObject?["properties"]?.asObject)
            #expect(properties["expectedContentHash"]?.asObject?["type"] == .string("string"))
        }
    }

    @Test("Ambiguous edits preserve bytes and return candidate lines; all is explicit")
    func ambiguousEdit() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("code.swift")
        try "value\nvalue\n".write(to: file, atomically: true, encoding: .utf8)
        let context = fixture.context()
        let args: [String: JSONValue] = ["path": .string("code.swift"), "search": .string("value"), "replace": .string("fixed")]
        let rejected = await FilesEditTool().invoke(arguments: args, context: context)
        #expect(rejected.error?.code == "ambiguous_match")
        #expect(rejected.data?.asObject?["candidateLines"] == .array([.number(1), .number(2)]))
        #expect(try String(contentsOf: file, encoding: .utf8) == "value\nvalue\n")
        var allArgs = args
        allArgs["all"] = .bool(true)
        let accepted = await FilesEditTool().invoke(arguments: allArgs, context: context)
        #expect(accepted.ok)
        #expect(accepted.data?.asObject?["replacements"] == .number(2))
        #expect(try String(contentsOf: file, encoding: .utf8) == "fixed\nfixed\n")
    }

    @Test("Hash from a complete read rejects an external edit without overwriting it")
    func staleHash() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("code.swift")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let context = fixture.context()
        let read = await FilesReadTool().invoke(arguments: ["path": .string("code.swift")], context: context)
        let hash = try #require(read.data?.asObject?["contentHash"]?.asString)
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        let partial = await FilesReadTool().invoke(arguments: ["path": .string("code.swift"), "maxBytes": .number(2)], context: context)
        #expect(partial.data?.asObject?["contentHash"] == .null)
        try "external".write(to: file, atomically: true, encoding: .utf8)
        let write = await FilesWriteTool().invoke(arguments: [
            "path": .string("code.swift"), "content": .string("overwrite"), "expectedContentHash": .string(hash)
        ], context: context)
        #expect(write.error?.code == "file_changed")
        #expect(try String(contentsOf: file, encoding: .utf8) == "external")
    }

    @Test("Concurrent hash-guarded writes across sessions have one winner")
    func concurrentGuardedWrites() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("code.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let hash = TaskSyncCrypto.sha256Hex(Data("original".utf8))
        let a = fixture.context(session: "a")
        let b = fixture.context(session: "b")
        async let first = FilesWriteTool().invoke(arguments: ["path": .string("code.swift"), "content": .string("first"), "expectedContentHash": .string(hash)], context: a)
        async let second = FilesWriteTool().invoke(arguments: ["path": .string("code.swift"), "content": .string("second"), "expectedContentHash": .string(hash)], context: b)
        let results = await [first, second]
        #expect(results.filter(\.ok).count == 1)
        #expect(results.filter { $0.error?.code == "file_changed" }.count == 1)
    }

    @Test("Concurrent exact edits through a symlink alias retain both changes")
    func concurrentAliasEdits() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("code.swift")
        try "alpha beta".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("alias.swift"), withDestinationURL: file)
        async let first = FilesEditTool().invoke(arguments: ["path": .string("code.swift"), "search": .string("alpha"), "replace": .string("A")], context: fixture.context(session: "a"))
        async let second = FilesEditTool().invoke(arguments: ["path": .string("alias.swift"), "search": .string("beta"), "replace": .string("B")], context: fixture.context(session: "b"))
        let results = await [first, second]
        #expect(results.allSatisfy { $0.ok })
        #expect(try String(contentsOf: file, encoding: .utf8) == "A B")
    }

    @Test("Diffs stay bounded and unavailable diagnostics do not imply verification")
    func boundedDiff() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let result = await FilesWriteTool().invoke(arguments: ["path": .string("large.txt"), "content": .string(String(repeating: "long line\n", count: 5_000))], context: fixture.context())
        #expect(result.ok)
        #expect(result.data?.asObject?["diffTruncated"] == .bool(true))
        #expect((result.data?.asObject?["diff"]?.asString?.utf8.count ?? 0) <= 16_384)
        #expect(result.data?.asObject?["diagnostics"]?.asObject?["status"] == .string("unavailable"))
        #expect(result.data?.asObject?["verificationEvidence"] == nil)
    }
}

@Suite("Coding harness output artifacts")
struct CodingHarnessOutputTests {
    @Test("Tool execution service returns a scoped artifact for a large file read")
    func serviceBoundary() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let context = fixture.context(maxOutputBytes: 32)
        let content = String(repeating: "payload", count: 1_000)
        try content.write(to: fixture.root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let service = ToolExecutionService(
            workspaceRootURL: fixture.root, runtime: context.runtime, memoryStore: context.memoryStore,
            sessionStore: context.sessionStore, agentCatalogStore: context.agentCatalogStore,
            processRegistry: context.processRegistry, channelSessionStore: context.channelSessionStore,
            store: context.store, searchProviderService: context.searchProviderService, mcpRegistry: context.mcpRegistry
        )
        let result = await service.invoke(
            agentID: context.agentID, sessionID: context.sessionID,
            request: .init(tool: "files.read", arguments: ["path": .string("large.txt")]), policy: context.policy
        )
        #expect(result.ok)
        #expect(result.data?.asObject?["outputTruncated"] == .bool(true))
        #expect((result.data?.asObject?["content"]?.asString?.utf8.count ?? 0) <= 32)
        let path = try #require(result.data?.asObject?["outputArtifact"]?.asObject?["path"]?.asString)
        let full = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(full.asObject?["content"] == .string(content))
        let readable = await FilesReadTool().invoke(arguments: ["path": .string(path), "maxBytes": .number(32)], context: context)
        #expect(readable.ok)
        await service.shutdown()
    }

    @Test("Runtime exec timeout retains the output already produced")
    func timeoutOutput() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let context = fixture.context(maxOutputBytes: 3)
        let result = await RuntimeExecTool().invoke(arguments: [
            "command": .string("/bin/sh"),
            "arguments": .array([.string("-c"), .string("printf 'before-timeout'; exec /bin/sleep 60")]),
            "timeoutMs": .number(150),
        ], context: context)
        #expect(result.error?.code == "tool_timeout")
        let path = try #require(result.data?.asObject?["stdoutArtifact"]?.asObject?["path"]?.asString)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "before-timeout")
    }

    @Test("Capture failure is visible and does not claim a saved full output")
    func captureFailure() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let context = fixture.context(maxOutputBytes: 3)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".sloppy"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: context.outputArtifacts.root, withDestinationURL: outside)
        let result = await RuntimeExecTool().invoke(arguments: [
            "command": .string("/bin/echo"), "arguments": .array([.string("output")])
        ], context: context)
        #expect(result.ok)
        #expect(result.data?.asObject?["outputCaptureError"]?.asString?.isEmpty == false)
        #expect(result.data?.asObject?["stdoutArtifact"] == nil)
    }

    @Test("Full stdout and stderr, including final bytes, survive small previews")
    func fullProcessOutput() async throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let context = fixture.context()
        let payload = try await runForegroundProcess(
            command: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do printf 'abcdef'; printf 'error!' >&2; i=$((i+1)); done; printf 'FINAL'; printf 'END' >&2"],
            cwd: fixture.root, timeoutMs: 10_000, maxOutputBytes: 17, outputArtifacts: context.outputArtifacts
        )
        #expect(payload.asObject?["stdoutTruncated"] == .bool(true))
        #expect(payload.asObject?["stdoutTotalBytes"] == .number(30_005))
        for (stream, expected) in [("stdout", String(repeating: "abcdef", count: 5000) + "FINAL"), ("stderr", String(repeating: "error!", count: 5000) + "END")] {
            let artifact = try #require(payload.asObject?[stream + "Artifact"]?.asObject)
            let path = try #require(artifact["path"]?.asString)
            #expect(artifact["complete"] == .bool(true))
            #expect(try String(contentsOfFile: path, encoding: .utf8) == expected)
            let own = await FilesReadTool().invoke(arguments: ["path": .string(path)], context: context)
            #expect(own.ok)
            let other = await FilesReadTool().invoke(arguments: ["path": .string(path)], context: fixture.context(session: "other"))
            #expect(other.error?.code == "path_not_allowed")
            let write = await FilesWriteTool().invoke(arguments: ["path": .string(path), "content": .string("tamper")], context: context)
            #expect(write.error?.code == "path_not_allowed")
        }
    }

    @Test("Large MCP-shaped text preserves typed errors and evidence and saves full JSON")
    func structuredOutput() throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.context().outputArtifacts
        let text = String(repeating: "日本語", count: 100)
        let result = ToolInvocationResult(tool: "mcp.fake", ok: false, data: .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "verificationEvidence": .object(["id": .string("proof-123")]),
        ]), error: .init(code: "known_failure", message: "Exact error", retryable: false))
        let bounded = store.bound(result, maxBytes: 17)
        #expect(!bounded.ok)
        #expect(bounded.error == result.error)
        #expect(bounded.data?.asObject?["verificationEvidence"] == result.data?.asObject?["verificationEvidence"])
        let preview = try #require(bounded.data?.asObject?["content"]?.asArray?.first?.asObject?["text"]?.asString)
        #expect(preview.utf8.count <= 17)
        #expect(!preview.contains("�"))
        let path = try #require(bounded.data?.asObject?["outputArtifact"]?.asObject?["path"]?.asString)
        let full = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(full == result.data)
    }

    @Test("Retention removes only old completed artifacts and leaves captures and symlinks")
    func retention() throws {
        let fixture = try CodingHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.context().outputArtifacts
        try store.prepare()
        let old = store.directory.appendingPathComponent("old.log")
        let active = store.directory.appendingPathComponent("active.capture")
        let outside = fixture.root.appendingPathComponent("keep.txt")
        for file in [old, active, outside] {
            try Data("keep".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        }
        let link = store.directory.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let otherStore = fixture.context(session: "abandoned").outputArtifacts
        try otherStore.prepare()
        let abandoned = otherStore.directory.appendingPathComponent("old.json")
        try Data("old".utf8).write(to: abandoned)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: abandoned.path)
        store.cleanupAllSessions()
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }
}
