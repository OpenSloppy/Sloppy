import Foundation

enum ClaudeMigrationAdapter {
    static func read(_ reader: SourceReader) throws {
        let root = reader.root
        reader.skills(root.appendingPathComponent("skills")); reader.commands(root.appendingPathComponent("commands")); reader.documents(root)
        let global = reader.optionalJSON(root.deletingLastPathComponent().appendingPathComponent(".claude.json"))
        reader.mcp(global["mcpServers"] as? [String: Any] ?? [:])
        reader.mcp(reader.optionalJSON(root.appendingPathComponent("settings.json"))["mcpServers"] as? [String: Any] ?? [:], origin: "settings")
        let knownProjects = global["projects"] as? [String: [String: Any]] ?? [:]
        for (path, config) in knownProjects.sorted(by: { $0.key < $1.key }) {
            reader.project(path)
            reader.mcp(config["mcpServers"] as? [String: Any] ?? [:], project: path, origin: path)
            let project = URL(fileURLWithPath: path)
            reader.markdown(project.appendingPathComponent("CLAUDE.md"), category: .instructions, project: path)
            reader.markdown(project.appendingPathComponent("AGENTS.md"), category: .instructions, project: path)
            reader.documents(project.appendingPathComponent(".claude"), project: path)
            reader.skills(project.appendingPathComponent(".claude/skills"), project: path)
            reader.commands(project.appendingPathComponent(".claude/commands"), project: path)
            reader.mcp(reader.optionalJSON(project.appendingPathComponent(".mcp.json"))["mcpServers"] as? [String: Any] ?? [:], project: path, origin: path + "/.mcp.json")
        }
        for file in reader.files(root.appendingPathComponent("projects"), extensions: ["jsonl"]) {
            try Task.checkCancellation()
            let rows = reader.lines(file)
            let externalID = rows.first(where: { $0["sessionId"] != nil })?["sessionId"] as? String ?? file.deletingPathExtension().lastPathComponent
            let project = rows.first(where: { $0["cwd"] != nil })?["cwd"] as? String
            if let project { reader.project(project) }
            var seen = Set<String>()
            let messages = rows.enumerated().flatMap { index, row -> [MigrationMessage] in
                guard let message = row["message"] as? [String: Any] else { return [] }
                let id = row["uuid"] as? String ?? "\(index)"
                guard seen.insert(id).inserted else { return [] }
                return SourceReader.messages(message, fallbackID: id, timestamp: row["timestamp"])
            }
            guard !messages.isEmpty else { continue }
            let title = rows.last(where: { $0["type"] as? String == "summary" })?["summary"] as? String ?? "Claude \(externalID.prefix(8))"
            reader.items.append(.init(source: reader.source, externalID: externalID + (file.path.contains("/subagents/") ? ":" + file.lastPathComponent : ""), category: .session,
                                      title: title, projectPath: project, createdAt: messages.first?.createdAt, messages: messages))
            reader.documents(file.deletingLastPathComponent(), project: project)
        }
        for file in reader.files(root.appendingPathComponent("agent-memory"), extensions: ["md"]) { reader.markdown(file, category: .memory, profile: file.deletingLastPathComponent().lastPathComponent) }
    }
}
