import Foundation
import libzstd

enum OpenClawMigrationAdapter {
    static func read(_ reader: SourceReader) throws {
        let config = reader.config(reader.root.appendingPathComponent("openclaw.json"))
        reader.skills(reader.root.appendingPathComponent("skills"))
        reader.mcp(config["mcpServers"] as? [String: Any] ?? config["mcp_servers"] as? [String: Any] ?? [:])
        reader.mcp((config["mcp"] as? [String: Any])?["servers"] as? [String: Any] ?? [:], origin: "mcp.servers")
        let agents = config["agents"] as? [String: Any] ?? [:]
        let defaults = agents["defaults"] as? [String: Any] ?? [:]
        let profiles = agents["list"] as? [[String: Any]] ?? [["id": "main"]]
        for profile in profiles {
            let id = profile["id"] as? String ?? "main"
            let rawPath = profile["workspace"] as? String ?? defaults["workspace"] as? String ?? reader.root.appendingPathComponent("workspace").path
            let workspace = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            reader.documents(workspace, profile: id); reader.skills(workspace.appendingPathComponent("skills"), profile: id)
            reader.project(workspace.path, profile: id)
            let directory = reader.root.appendingPathComponent("agents/\(id)")
            let databaseURL = directory.appendingPathComponent("agent/openclaw-agent.sqlite")
            var imported = Set<String>()
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                do {
                    let db = try MigrationSQLite(url: databaseURL)
                    guard db.tables.contains("session_windows"), db.tables.contains("transcript_events") else { throw MigrationError.invalid("Unsupported OpenClaw session schema.") }
                    let nodes = try db.rows("SELECT * FROM session_nodes")
                    for window in try db.rows("SELECT * FROM session_windows ORDER BY created_at") {
                        guard let sessionID = window["session_id"] as? String else { continue }
                        let node = nodes.first { $0["session_key"] as? String == window["session_key"] as? String } ?? [:]
                        let entries = try db.rows("SELECT * FROM transcript_events WHERE session_id=? ORDER BY seq", values: [sessionID])
                        var events: [[String: Any]] = []
                        for entry in entries {
                            let data: Data
                            if let text = entry["event_json"] as? String { data = Data(text.utf8) }
                            else if let compressed = entry["event_zstd"] as? Data { data = try decompress(compressed) }
                            else { continue }
                            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            events.append(event)
                        }
                        let messages = normalize(events)
                        guard !messages.isEmpty else { continue }
                        reader.items.append(.init(source: reader.source, externalID: sessionID, profile: id, category: .session,
                                                  title: node["display_name"] as? String ?? node["label"] as? String ?? "OpenClaw \(sessionID.prefix(8))",
                                                  projectPath: workspace.path, parentExternalID: window["previous_session_id"] as? String,
                                                  createdAt: SourceReader.date(window["created_at"]), archived: node["archived_at"] != nil, messages: messages))
                        imported.insert(sessionID)
                    }
                } catch { reader.warn(databaseURL, error.localizedDescription) }
            }
            let legacyIndex = reader.optionalJSON(directory.appendingPathComponent("sessions/sessions.json"))
            for file in reader.files(directory.appendingPathComponent("sessions"), extensions: ["jsonl", "zst"]) {
                do {
                    let events: [[String: Any]]
                    if file.pathExtension == "zst" {
                        let data = try decompress(reader.data(file))
                        events = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    } else { events = reader.lines(file) }
                    let sessionID = events.first(where: { $0["type"] as? String == "session" })?["id"] as? String ?? file.deletingPathExtension().lastPathComponent
                    guard !imported.contains(sessionID) else { continue }
                    let meta = legacyIndex.values.compactMap { $0 as? [String: Any] }.first { $0["sessionId"] as? String == sessionID } ?? [:]
                    let messages = normalize(events)
                    guard !messages.isEmpty else { continue }
                    reader.items.append(.init(source: reader.source, externalID: sessionID, profile: id, category: .session,
                                              title: meta["label"] as? String ?? "OpenClaw \(sessionID.prefix(8))", projectPath: workspace.path,
                                              createdAt: messages.first?.createdAt, archived: meta["archivedAt"] != nil, messages: messages))
                    imported.insert(sessionID)
                } catch { reader.warn(file, error.localizedDescription) }
            }
        }
    }
    private static func normalize(_ events: [[String: Any]]) -> [MigrationMessage] {
        var selected = events
        // Pi transcripts are trees. Follow the selected latest message's ancestry rather than replay abandoned branches.
        let byID = Dictionary(events.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }; return (id, row)
        }, uniquingKeysWith: { _, last in last })
        if let leaf = events.last(where: { $0["message"] != nil && $0["parentId"] != nil }), let leafID = leaf["id"] as? String {
            var chain: [[String: Any]] = []; var visited = Set<String>(); var next: String? = leafID
            while let id = next, visited.insert(id).inserted, let row = byID[id] { chain.append(row); next = row["parentId"] as? String }
            selected = chain.reversed()
        }
        return selected.enumerated().flatMap { index, event in
            SourceReader.messages(event["message"] as? [String: Any] ?? event, fallbackID: event["id"] as? String ?? "\(index)", timestamp: event["timestamp"])
        }
    }
    private static func decompress(_ data: Data) throws -> Data {
        let size = data.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
        let limit = 32 * 1024 * 1024
        guard size != UInt64.max, size == UInt64.max - 1 || size <= UInt64(limit) else { throw MigrationError.invalid("Unsupported or oversized compressed transcript.") }
        var output = Data(count: limit)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in ZSTD_decompress(destination.baseAddress, destination.count, source.baseAddress, source.count) }
        }
        guard ZSTD_isError(count) == 0, count <= output.count else { throw MigrationError.integrity }
        output.count = count
        return output
    }
}
