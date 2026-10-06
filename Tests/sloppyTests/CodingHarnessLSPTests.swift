import Foundation
import Testing
import LanguageServerProtocol
@testable import Protocols
@testable import sloppy

@Suite("Coding harness LSP feedback")
struct CodingHarnessLSPTests {
    @Test("Language IDs match language server conventions for Swift and Dashboard files")
    func languageIDs() {
        #expect(LSPServerInstance.language(forExtension: "swift").rawValue == "swift")
        #expect(LSPServerInstance.language(forExtension: "ts").rawValue == "typescript")
        #expect(LSPServerInstance.language(forExtension: "tsx").rawValue == "typescriptreact")
        #expect(LSPServerInstance.language(forExtension: "jsx").rawValue == "javascriptreact")
    }

    @Test("Stale and unversioned diagnostics never certify a changed document")
    func staleDiagnostics() async {
        let cache = LSPDiagnosticCache()
        let uri = DocumentURI(URL(fileURLWithPath: "/tmp/code.swift"))
        await cache.begin(uri: uri, version: 1)
        await cache.publish(.init(uri: uri, version: 1, diagnostics: []))
        #expect(await cache.diagnostics(uri: uri, version: 1) == [])
        await cache.begin(uri: uri, version: 2)
        await cache.publish(.init(uri: uri, version: 1, diagnostics: []))
        #expect(await cache.diagnostics(uri: uri, version: 2) == nil)
        await cache.publish(.init(uri: uri, diagnostics: []))
        #expect(await cache.diagnostics(uri: uri, version: 2) == nil)
        await cache.publish(.init(uri: uri, version: 2, diagnostics: []))
        #expect(await cache.diagnostics(uri: uri, version: 2) == [])
    }

    @Test("A real JSON-RPC subprocess receives open then change and returns current diagnostics")
    func subprocessDiagnostics() async throws {
        let fixture = try makeServer(mode: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tools = try CodingHarnessFixture()
        defer { tools.cleanup() }
        let file = tools.root.appendingPathComponent("code.swift")
        let instance = try await fixture.manager.instance(for: file.path)
        let context = tools.context(lsp: fixture.manager)
        let write = await FilesWriteTool().invoke(arguments: ["path": .string("code.swift"), "content": .string("broken")], context: context)
        #expect(write.ok)
        let first = try #require(write.data?.asObject?["diagnostics"])
        #expect(first.asObject?["status"] == .string("ready"), "\(first)")
        #expect(first.asObject?["version"] == .number(1))
        #expect(first.asObject?["items"]?.asArray?.first?.asObject?["severity"] == .string("error"))
        let edit = await FilesEditTool().invoke(arguments: ["path": .string("code.swift"), "search": .string("broken"), "replace": .string("fixed")], context: context)
        #expect(edit.ok)
        let second = try #require(edit.data?.asObject?["diagnostics"])
        #expect(second.asObject?["status"] == .string("ready"))
        #expect(second.asObject?["version"] == .number(2))
        #expect(second.asObject?["items"] == .array([]))
        await instance.shutdown()
        let events = try String(contentsOf: fixture.root.appendingPathComponent("events.txt"), encoding: .utf8)
        #expect(events.contains("textDocument/didOpen:1"))
        #expect(events.contains("textDocument/didChange:2"))
    }

    @Test("No diagnostic publication is pending; initialization timeout is unavailable")
    func boundedWait() async throws {
        for (mode, expected) in [("silent", "pending"), ("no-init", "unavailable")] {
            let fixture = try makeServer(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let file = fixture.root.appendingPathComponent("code.swift")
            try "fixed".write(to: file, atomically: true, encoding: .utf8)
            let result = await fixture.manager.feedbackAfterMutation(path: file.path, content: "fixed")
            #expect(result.asObject?["status"] == .string(expected))
            await fixture.manager.shutdown()
        }
    }

    private func makeServer(mode: String) throws -> (root: URL, manager: LSPServerManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sloppy-fake-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server.py")
        let source = #"""
        import sys, json
        mode, log = sys.argv[1:]
        def send(message):
            payload = json.dumps(message).encode()
            sys.stdout.buffer.write(b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
            sys.stdout.buffer.flush()
        while True:
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line: sys.exit(0)
                if line in (b"\r\n", b"\n"): break
                k, v = line.decode().split(":", 1)
                headers[k.lower()] = v.strip()
            msg = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
            method = msg.get("method", "")
            if method == "initialize":
                if mode != "no-init": send({"jsonrpc":"2.0", "id":msg["id"], "result":{"capabilities":{"textDocumentSync":2}}})
            elif method in ("textDocument/didOpen", "textDocument/didChange"):
                doc = msg["params"]["textDocument"]
                with open(log, "a") as f: f.write(method + ":" + str(doc["version"]) + "\n")
                text = doc.get("text", "") if method.endswith("didOpen") else msg["params"]["contentChanges"][0]["text"]
                if mode == "silent": continue
                errors = [] if "broken" not in text else [{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":1,"message":"Fake syntax error"}]
                send({"jsonrpc":"2.0", "method":"textDocument/publishDiagnostics", "params":{"uri":doc["uri"],"version":doc["version"],"diagnostics":errors}})
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let config = CoreConfig.LSP(servers: [CoreConfig.LSP.Server(
            id: "fake", command: "/usr/bin/env", arguments: ["python3", "-u", script.path, mode, root.appendingPathComponent("events.txt").path],
            extensions: [".swift"], timeoutMs: mode == "no-init" ? 150 : 5_000
        )])
        return (root, LSPServerManager(config: config, workspaceRootURL: root))
    }
}
