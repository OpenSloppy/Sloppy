import Foundation
import Testing
import CMigrationSQLite
import libzstd
@testable import SloppyMigration

private func fixture(_ operation: (URL) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("migration-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try operation(home)
}
private func write(_ home: URL, _ path: String, _ content: String) throws {
    let url = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
}

@Test func discoveryDoesNotReadOrTraverseUnknownDirectories() throws {
    try fixture { home in
        try write(home, ".codex/config.toml", "broken config")
        try write(home, "unrelated/.hermes/MEMORY.md", "Private")
        let sources = MigrationScanner.discover(home: home)
        #expect(sources.map(\.kind) == [.codex])
    }
}

@Test func codexImportsCanonicalMessagesWithoutEventEchoesAndPreservesSource() throws {
    try fixture { home in
        let text = """
        {"type":"session_meta","timestamp":"2026-01-01T00:00:00Z","payload":{"id":"thread-1","cwd":"/project"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"duplicate"}}
        {"type":"response_item","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
        {"type":"response_item","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"function_call","name":"exec","call_id":"a","arguments":"{}"}}
        {"type":"response_item","timestamp":"2026-01-01T00:00:02Z","payload":{"type":"function_call_output","call_id":"a","output":"done"}}
        broken trailing record
        """
        try write(home, ".codex/sessions/s.jsonl", text)
        try write(home, ".codex/config.toml", "[mcp_servers.\"server.with.dots\"]\ncommand = 'npx'\nargs = ['a', 'b']\n[mcp_servers.\"server.with.dots\".env]\nKEY = 'fixture'")
        try write(home, ".agents/skills/test/SKILL.md", "---\nname: test\n---\nInstructions")
        try write(home, ".agents/skills/test/scripts/run.sh", "#!/bin/sh\ntrue")
        let source = MigrationScanner.discover(home: home)
        let catalog = try MigrationScanner.scan(sources: source)
        let session = try #require(catalog.items.first { $0.category == .session })
        #expect(session.messages.map(\.kind) == [.user, .toolCall, .toolResult])
        #expect(session.messages.first?.text == "hello")
        #expect(catalog.items.first { $0.category == .mcp }?.mcp?.arguments == ["a", "b"])
        #expect(catalog.items.first { $0.category == .skill }?.files.count == 2)
        #expect(!catalog.warnings.isEmpty)
        #expect(try String(contentsOf: home.appendingPathComponent(".codex/sessions/s.jsonl"), encoding: .utf8) == text)
        #expect(try MigrationScanner.scan(sources: source).items == catalog.items)
    }
}

@Test func claudeReadsGlobalMCPCommandsAndProjectMemory() throws {
    try fixture { home in
        try write(home, ".claude.json", "{\"mcpServers\":{\"test\":{\"url\":\"https://example.com/mcp\"}}}")
        try write(home, ".claude/commands/review.md", "Review $ARGUMENTS")
        try write(home, ".claude/projects/p/memory/MEMORY.md", "Project knowledge")
        try write(home, ".claude/projects/p/session.jsonl", "{\"uuid\":\"a\",\"sessionId\":\"s\",\"cwd\":\"/work/p\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}")
        let catalog = try MigrationScanner.scan(sources: MigrationScanner.discover(home: home))
        #expect(catalog.items.contains { $0.category == .mcp })
        #expect(catalog.items.contains { $0.category == .skill && $0.files.first?.path == "SKILL.md" })
        #expect(catalog.items.contains { $0.category == .memory && $0.projectPath == "/work/p" })
    }
}

@Test func hermesReadsCommittedWALAndDoesNotDuplicateLegacySessions() throws {
    try fixture { home in
        try write(home, ".hermes/config.yaml", "mcp_servers:\n  test:\n    command: npx\n    args: [one]\n")
        let path = home.appendingPathComponent(".hermes/state.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE sessions(id TEXT, started_at REAL, title TEXT, cwd TEXT); CREATE TABLE messages(session_id TEXT, timestamp REAL, id INTEGER, role TEXT, content TEXT, active INTEGER); INSERT INTO sessions VALUES('s', 1, 'Title', '/work'); INSERT INTO messages VALUES('s', 2, 1, 'user', 'hello', 1);", nil, nil, nil) == SQLITE_OK)
        try write(home, ".hermes/sessions/session_s.json", "{\"session_id\":\"s\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}")
        let before = try Data(contentsOf: path)
        let catalog = try MigrationScanner.scan(sources: MigrationScanner.discover(home: home))
        #expect(catalog.items.filter { $0.category == .session }.count == 1)
        #expect(catalog.items.first { $0.category == .session }?.messages.first?.text == "hello")
        #expect(try Data(contentsOf: path) == before)
        #expect(catalog.items.first { $0.category == .mcp }?.mcp?.arguments == ["one"])
    }
}

@Test func openclawReadsJSON5AndLegacyTranscriptTree() throws {
    try fixture { home in
        let workspace = home.appendingPathComponent(".openclaw/workspace").path
        try write(home, ".openclaw/openclaw.json", "{agents: {defaults: {workspace: '\(workspace)'}}, mcp: { servers: { fixture: {command: 'npx', env: {STATIC: 'value', SECRET: {source: 'env', id: 'KEY'}}}}},}")
        try write(home, ".openclaw/workspace/SOUL.md", "Personality")
        try write(home, ".openclaw/agents/main/sessions/a.jsonl", """
        {"type":"session","id":"a"}
        {"id":"one","message":{"role":"user","content":"root"}}
        {"id":"discarded","parentId":"one","message":{"role":"assistant","content":"old branch"}}
        {"id":"selected","parentId":"one","message":{"role":"assistant","content":"new branch"}}
        """)
        let catalog = try MigrationScanner.scan(sources: MigrationScanner.discover(home: home))
        #expect(catalog.items.first { $0.category == .session }?.messages.map(\.text) == ["root", "new branch"])
        #expect(catalog.items.contains { $0.category == .instructions })
        let server = try #require(catalog.items.first { $0.category == .mcp })
        #expect(server.mcp?.environment == ["STATIC": "value"])
        #expect(!server.warnings.isEmpty)
    }
}

@Test func traversalPathsAreRejected() {
    for path in ["../secret", "/absolute", "a/../../b", "a//b", "a\\b", "a/./b"] { #expect(!MigrationDigest.safeRelativePath(path)) }
    #expect(MigrationDigest.safeRelativePath("scripts/run.sh"))
}

@Test func openclawSQLiteReadsCompressedEventsWithoutCredentialTables() throws {
    try fixture { home in
        try write(home, ".openclaw/openclaw.json", "{}")
        let directory = home.appendingPathComponent(".openclaw/agents/main/agent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("openclaw-agent.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let json = Data("{\"id\":\"u\",\"message\":{\"role\":\"user\",\"content\":\"compressed history\"}}".utf8)
        var compressed = Data(count: ZSTD_compressBound(json.count))
        let count = compressed.withUnsafeMutableBytes { output in json.withUnsafeBytes { input in ZSTD_compress(output.baseAddress, output.count, input.baseAddress, input.count, 1) } }
        #expect(ZSTD_isError(count) == 0); compressed.count = count
        let hex = compressed.map { String(format: "%02x", $0) }.joined()
        let sql = "CREATE TABLE session_nodes(session_key TEXT, current_session_id TEXT, display_name TEXT); CREATE TABLE session_windows(session_id TEXT, session_key TEXT, created_at REAL); CREATE TABLE transcript_events(session_id TEXT, seq INTEGER, event_json TEXT, event_zstd BLOB); CREATE TABLE auth(password TEXT); INSERT INTO auth VALUES('fixture-credential-must-not-transfer'); INSERT INTO session_nodes VALUES('key','s','Name'); INSERT INTO session_windows VALUES('s','key',1); INSERT INTO transcript_events VALUES('s',1,NULL,X'\(hex)');"
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        let catalog = try MigrationScanner.scan(sources: MigrationScanner.discover(home: home))
        #expect(catalog.items.first { $0.category == .session }?.messages.first?.text == "compressed history")
        #expect(!String(decoding: try MigrationDigest.encoder.encode(catalog), as: UTF8.self).contains("fixture-credential-must-not-transfer"))
    }
}
