import Foundation

enum CodexMigrationAdapter {
    static func read(_ reader: SourceReader) throws {
        let root = reader.root
        reader.skills(root.appendingPathComponent("skills"))
        reader.skills(root.deletingLastPathComponent().appendingPathComponent(".agents/skills"))
        reader.documents(root)
        let config = reader.config(root.appendingPathComponent("config.toml"))
        reader.mcp(config["mcp_servers"] as? [String: Any] ?? [:])
        for path in (config["projects"] as? [String: Any] ?? [:]).keys.sorted() { reader.project(path) }
        for folder in ["sessions", "archived_sessions"] {
            for file in reader.files(root.appendingPathComponent(folder), extensions: ["jsonl"]) {
                try Task.checkCancellation()
                let rows = reader.lines(file)
                let meta = rows.first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any] ?? [:]
                let externalID = meta["id"] as? String ?? file.deletingPathExtension().lastPathComponent
                let project = meta["cwd"] as? String
                if let project { reader.project(project) }
                var messages: [MigrationMessage] = []
                let canonical = rows.contains { $0["type"] as? String == "response_item" }
                for (index, row) in rows.enumerated() {
                    let payload = row["payload"] as? [String: Any] ?? [:]
                    if row["type"] as? String == "response_item" {
                        switch payload["type"] as? String {
                        case "message": messages += SourceReader.messages(payload, fallbackID: "\(index)", timestamp: row["timestamp"])
                        case "function_call", "custom_tool_call":
                            messages.append(.init(id: "\(index)", kind: .toolCall, text: payload["arguments"] as? String ?? payload["input"] as? String ?? "", tool: payload["name"] as? String, callID: payload["call_id"] as? String, createdAt: SourceReader.date(row["timestamp"])))
                        case "function_call_output", "custom_tool_call_output":
                            messages.append(.init(id: "\(index)", kind: .toolResult, text: SourceReader.content(payload["output"]), callID: payload["call_id"] as? String, createdAt: SourceReader.date(row["timestamp"])))
                        default: break
                        }
                    } else if !canonical, row["type"] as? String == "event_msg", ["user_message", "agent_message"].contains(payload["type"] as? String ?? "") {
                        messages.append(.init(id: "\(index)", kind: payload["type"] as? String == "user_message" ? .user : .assistant, text: payload["message"] as? String ?? "", createdAt: SourceReader.date(row["timestamp"])))
                    }
                }
                guard !messages.isEmpty else { continue }
                reader.items.append(.init(source: reader.source, externalID: externalID, category: .session,
                                          title: meta["title"] as? String ?? "Codex \(externalID.prefix(8))", projectPath: project,
                                          parentExternalID: meta["parent_thread_id"] as? String, createdAt: SourceReader.date(meta["timestamp"]), archived: folder == "archived_sessions", messages: messages))
            }
        }
    }
}
