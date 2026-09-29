import Foundation

enum HermesMigrationAdapter {
    static func read(_ reader: SourceReader) throws {
        try readProfile(reader, root: reader.root, profile: "default")
        let profiles = reader.root.appendingPathComponent("profiles")
        for url in (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try readProfile(reader, root: url, profile: url.lastPathComponent)
        }
    }
    private static func readProfile(_ reader: SourceReader, root: URL, profile: String) throws {
        reader.skills(root.appendingPathComponent("skills"), profile: profile); reader.documents(root, profile: profile)
        let config = reader.config(root.appendingPathComponent("config.yaml"))
        reader.mcp(config["mcp_servers"] as? [String: Any] ?? [:], profile: profile)
        var imported = Set<String>()
        let databaseURL = root.appendingPathComponent("state.db")
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                let db = try MigrationSQLite(url: databaseURL)
                for session in try db.rows("SELECT * FROM sessions ORDER BY started_at") {
                    guard let id = session["id"] as? String else { continue }
                    let project = session["cwd"] as? String ?? session["git_repo_root"] as? String
                    let actualProfile = session["profile_name"] as? String ?? profile
                    if let project { reader.project(project, profile: actualProfile) }
                    let rows = try db.rows("SELECT * FROM messages WHERE session_id=? ORDER BY timestamp, id", values: [id])
                    var messages: [MigrationMessage] = []
                    for (index, row) in rows.enumerated() where (row["active"] as? Double ?? 1) != 0 {
                        var normalized = row
                        if let calls = row["tool_calls"] as? String, let data = calls.data(using: .utf8) { normalized["tool_calls"] = try? JSONSerialization.jsonObject(with: data) }
                        messages += SourceReader.messages(normalized, fallbackID: "\(index)", timestamp: row["timestamp"])
                    }
                    guard !messages.isEmpty else { continue }
                    reader.items.append(.init(source: reader.source, externalID: id, profile: actualProfile, category: .session,
                                              title: session["title"] as? String ?? "Hermes \(id.prefix(8))", projectPath: project,
                                              parentExternalID: session["parent_session_id"] as? String, createdAt: SourceReader.date(session["started_at"]),
                                              archived: (session["archived"] as? Double ?? 0) != 0, messages: messages))
                    imported.insert(id)
                }
            } catch { reader.warn(databaseURL, error.localizedDescription) }
        }
        for file in reader.files(root.appendingPathComponent("sessions"), extensions: ["json", "jsonl"]) {
            let data = file.pathExtension == "json" ? reader.optionalJSON(file) : [:]
            let id = data["session_id"] as? String ?? file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "session_", with: "")
            guard !imported.contains(id) else { continue }
            let rows = data["messages"] as? [[String: Any]] ?? (file.pathExtension == "jsonl" ? reader.lines(file) : [])
            let messages = rows.enumerated().flatMap { SourceReader.messages($0.element, fallbackID: "\($0.offset)", timestamp: $0.element["timestamp"]) }
            guard !messages.isEmpty else { continue }
            reader.items.append(.init(source: reader.source, externalID: id, profile: profile, category: .session,
                                      title: data["title"] as? String ?? "Hermes \(id.prefix(8))", projectPath: data["cwd"] as? String, createdAt: messages.first?.createdAt, messages: messages))
        }
    }
}
