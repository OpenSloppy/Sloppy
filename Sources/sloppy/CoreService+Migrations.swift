import Foundation
import Protocols
import SloppyMigration

extension CoreService {
    func discoverMigrationSources() -> [MigrationSource] { MigrationScanner.discover() }
    func scanMigrationSources(_ request: MigrationScanRequest) async throws -> MigrationCatalog {
        // Only administrators can call this route; source roots are explicitly selected by the operator.
        try await Task.detached { try MigrationScanner.scan(sources: request.sources) }.value
    }
    func previewMigration(_ selection: MigrationSelection) async throws -> MigrationPreview {
        var preview = try await migrations.preview(selection)
        for agentID in selection.agentMappings.values { _ = try getAgent(id: agentID) }
        for path in Set(selection.items.compactMap(\.projectPath)) {
            if let target = selection.projectMappings[path], !target.isEmpty,
               !FileManager.default.fileExists(atPath: target) { preview.warnings.append("Destination folder is unavailable: \(target)") }
        }
        for item in selection.items where item.category == .instructions {
            if selection.agentMappings[item.profileKey] != nil { preview.conflicts.append(item.id) }
        }
        return preview
    }
    func createMigration(_ request: MigrationCreateRequest) async throws -> MigrationJob { try await migrations.create(request) }
    func uploadMigration(_ id: String, chunk: MigrationUploadChunk) async throws -> MigrationJob { try await migrations.upload(id: id, chunk: chunk) }
    func migrationJobs() async throws -> [MigrationJob] { try await migrations.list() }
    func migrationJob(_ id: String) async throws -> MigrationJob { try await migrations.get(id) }
    func cancelMigration(_ id: String) async throws -> MigrationJob { try await migrations.cancel(id) }
    func resumeMigration(_ id: String) async throws -> MigrationJob {
        if let uploading = try await migrations.resumeUpload(id) { return uploading }
        return try await startMigration(id)
    }
    func startMigration(_ id: String) async throws -> MigrationJob {
        try await migrations.start(id) { [weak self] item, selection, jobID in
            guard let self else { throw MigrationError.missing }
            return try await self.applyMigrationItem(item, selection: selection, jobID: jobID)
        }
    }
    func importMigration(_ selection: MigrationSelection) async throws -> MigrationJob {
        _ = try await previewMigration(selection)
        let job = try await migrations.accept(selection: selection, destination: "Core")
        return try await startMigration(job.id)
    }
    func resumePendingMigrations() async {
        do {
            for job in try await migrations.list() where [.queued, .running, .waitingForModel].contains(job.status) {
                _ = try await startMigration(job.id)
            }
        } catch { logger.error("Migration recovery failed: \(error.localizedDescription)") }
    }

    private func migrationAgent(_ item: MigrationItem, selection: MigrationSelection) async throws -> String {
        if let existing = selection.agentMappings[item.profileKey] {
            let config = try getAgentConfig(agentID: existing)
            guard config.runtime.type == .native else { throw MigrationError.invalid("Select a native Sloppy agent for imported conversations.") }
            return existing
        }
        let id = "import-\(item.source.kind.rawValue)-\(MigrationDigest.id(item.profileKey).prefix(12))"
        if (try? getAgent(id: id)) == nil {
            _ = try await createAgent(.init(id: id, displayName: "\(item.source.kind.rawValue.capitalized) · \(item.profile)", role: "Imported assistant", runtime: .init(sharedMemoryEnabled: false)))
        }
        return id
    }
    private func migrationProject(_ path: String, selection: MigrationSelection) async throws -> String {
        let mapped = selection.projectMappings[path]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = mapped.isEmpty ? nil : URL(fileURLWithPath: mapped).standardizedFileURL.path
        if let target, let project = await listProjects().first(where: { $0.directoryPaths.contains(target) || $0.repoPath == target }) { return project.id }
        let id = "import-project-" + MigrationDigest.id(path + ":" + (target ?? ""))
        if await store.project(id: id) == nil {
            _ = try await createProject(.init(id: id, name: URL(fileURLWithPath: path).lastPathComponent,
                                             description: "Imported context from \(path)", repoPath: target))
        }
        return id
    }
    private func migrationSessionID(_ item: MigrationItem, selection: MigrationSelection) -> String {
        "session-import-" + MigrationDigest.id(item.id + ":" + item.checksum + ":" + (selection.agentMappings[item.profileKey] ?? "new") + ":" + (selection.projectMappings[item.projectPath ?? ""] ?? ""))
    }
    private func applyMigrationItem(_ item: MigrationItem, selection: MigrationSelection, jobID: String) async throws -> MigrationOutcome {
        try Task.checkCancellation()
        let agentID = try await migrationAgent(item, selection: selection)
        let projectID: String?
        let projectSelected = item.projectPath.map { path in selection.items.contains { $0.category == .project && $0.projectPath == path } } ?? false
        if let path = item.projectPath, projectSelected { projectID = try await migrationProject(path, selection: selection) } else { projectID = nil }
        if item.projectPath != nil, !projectSelected, [.instructions, .memory].contains(item.category) {
            return .init(item: item, status: "skipped", agentID: agentID, message: "Project context was not selected. Document retained in migration snapshot.")
        }
        var outcome = MigrationOutcome(item: item, status: "imported", agentID: agentID, projectID: projectID)
        switch item.category {
        case .project: break
        case .skill:
            guard item.files.contains(where: { $0.path == "SKILL.md" }) else { throw MigrationError.invalid("Skill entrypoint is missing.") }
            let owner = "imported-" + item.source.kind.rawValue
            let repo = MigrationDigest.id(item.id + ":" + item.checksum)
            let directory = try agentCatalogStore.directoryURL(agentID: agentID).appendingPathComponent("skills/\(owner)/\(repo)")
            try writeMigrationFiles(item.files, to: directory)
            if (try? agentSkillsStore.getSkill(agentID: agentID, skillID: owner + "/" + repo)) == nil {
                _ = try agentSkillsStore.installSkill(agentID: agentID, owner: owner, repo: repo, name: item.title,
                                                       description: item.description ?? "Imported from \(item.source.kind.rawValue)", localPath: directory.path)
            }
            let installed = try agentSkillsStore.getSkill(agentID: agentID, skillID: owner + "/" + repo)
            guard URL(fileURLWithPath: installed.localPath).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else { throw MigrationError.integrity }
            await sessionOrchestrator.notifySkillsChanged(agentID: agentID)
        case .mcp:
            guard let config = item.mcp else { throw MigrationError.invalid("MCP configuration is missing.") }
            let id = "import-" + MigrationDigest.id(item.id + ":" + item.checksum)
            if !currentConfig.mcp.servers.contains(where: { $0.id == id }) {
                var next = currentConfig
                next.mcp.servers.append(.init(id: id, transport: config.endpoint == nil ? .stdio : .http,
                                             command: config.command, arguments: config.arguments, cwd: config.cwd,
                                             endpoint: config.endpoint, headers: config.headers, environment: config.environment, enabled: false))
                _ = try await updateRuntimeConfig(next)
            }
            outcome.mcpID = id; outcome.message = "Imported disabled. Check dependencies and authorization on this Core before enabling."
        case .instructions:
            guard let file = item.files.first, String(data: file.content, encoding: .utf8) != nil else { throw MigrationError.invalid("Invalid instruction document.") }
            if let projectID {
                let directory = projectMetaDirectoryURL(projectID: projectID).appendingPathComponent("imported-instructions/\(agentID)")
                try writeMigrationFiles([.init(path: MigrationDigest.id(item.id + ":" + item.checksum) + ".md", content: file.content)], to: directory)
            } else {
                let directory = try agentCatalogStore.directoryURL(agentID: agentID).appendingPathComponent("imported-instructions")
                try writeMigrationFiles([.init(path: MigrationDigest.id(item.id + ":" + item.checksum) + "-" + file.path, content: file.content)], to: directory)
            }
            await sessionOrchestrator.notifyAgentDocumentsChanged(agentID: agentID)
        case .session:
            let sessionID = migrationSessionID(item, selection: selection)
            let parent = selection.items.first { $0.category == .session && $0.profileKey == item.profileKey && $0.externalID == item.parentExternalID }
            _ = try sessionStore.createSession(agentID: agentID, request: .init(title: item.title,
                parentSessionId: parent.map { migrationSessionID($0, selection: selection) }, projectId: projectID),
                createdAt: item.createdAt ?? item.messages.first?.createdAt ?? Date(timeIntervalSince1970: 0), importedSessionID: sessionID)
            let current = try sessionStore.loadSession(agentID: agentID, sessionID: sessionID)
            let existing = Set(current.events.map(\.id))
            let origin = AgentSessionImportOrigin(source: .init(rawValue: item.source.kind.rawValue) ?? .codex,
                                                  sourceID: item.source.id, externalID: item.externalID, jobID: jobID, archived: item.archived)
            let names = Dictionary(item.messages.compactMap { message -> (String, String)? in
                guard message.kind == .toolCall, let id = message.callID, let name = message.tool else { return nil }; return (id, name)
            }, uniquingKeysWith: { first, _ in first })
            var events: [AgentSessionEvent] = []
            for message in item.messages {
                let id = "import-event-" + MigrationDigest.id(item.id + ":" + message.id)
                guard !existing.contains(id) else { continue }
                var event = AgentSessionEvent(id: id, agentId: agentID, sessionId: sessionID, type: .message, createdAt: message.createdAt)
                event.importOrigin = origin
                switch message.kind {
                case .user, .assistant:
                    event.message = .init(id: id, role: message.kind == .user ? .user : .assistant, segments: [.init(kind: .text, text: message.text)], createdAt: message.createdAt)
                case .toolCall:
                    event.type = .toolCall
                    let args = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(message.text.utf8))) ?? ["input": .string(message.text)]
                    event.toolCall = .init(tool: message.tool ?? "external-tool", arguments: args)
                case .toolResult:
                    event.type = .toolResult
                    event.toolResult = .init(tool: message.tool ?? names[message.callID ?? ""] ?? "external-tool", ok: true, data: .object(["text": .string(message.text)]))
                }
                events.append(event)
            }
            if !events.isEmpty { _ = try sessionStore.appendEvents(agentID: agentID, sessionID: sessionID, events: events) }
            let detail = try sessionStore.loadSession(agentID: agentID, sessionID: sessionID)
            guard Set(detail.events.map(\.id)).isSuperset(of: events.map(\.id)) else { throw MigrationError.integrity }
            outcome.sessionID = sessionID
        case .memory:
            let id = "session-import-memory-" + MigrationDigest.id(item.id + ":" + agentID)
            _ = try sessionStore.createSession(agentID: agentID, request: .init(title: "Imported memory · \(item.title)", projectId: projectID), importedSessionID: id)
            guard (try? memoryImportProcessor(agentID: agentID)) != nil else {
                outcome.status = "waiting"; outcome.message = "Source preserved. Configure a native model and resume memory processing."; return outcome
            }
            guard let processor = try? memoryImportProcessor(agentID: agentID) else { throw MigrationError.invalid("Model unavailable.") }
            for file in item.files {
                guard file.content.count <= 1024 * 1024 else { throw MigrationError.invalid("Memory document exceeds 1 MB.") }
                let job = try await memoryImports.create(agentID: agentID, sessionID: id,
                    files: [.init(name: file.path, mimeType: "text/markdown", sizeBytes: file.content.count, contentBase64: file.content.base64EncodedString())], projectID: projectID)
                _ = try await memoryImports.launch(agentID: agentID, id: job.id, processor: processor) { [weak self] progress in
                    await self?.migrations.recordMemoryProgress(jobID, memoryJobID: progress.id, completed: progress.completedUnits, total: progress.totalUnits)
                }
                try await withTaskCancellationHandler {
                    await memoryImports.waitForIdle(id: job.id); try Task.checkCancellation()
                } onCancel: { [memoryImports] in Task { _ = try? await memoryImports.cancel(agentID: agentID, id: job.id) } }
                let completed = try await memoryImports.get(agentID: agentID, id: job.id)
                guard completed.status == .completed else { throw MigrationError.invalid(completed.error ?? "Memory processing did not complete.") }
            }
        }
        return outcome
    }
    private func writeMigrationFiles(_ files: [MigrationFile], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let root = canonicalDirectory.path
        for file in files {
            guard MigrationDigest.safeRelativePath(file.path) else { throw MigrationError.invalid("Invalid imported path.") }
            let url = canonicalDirectory.appendingPathComponent(file.path)
            guard url.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw MigrationError.invalid("Imported path escapes destination.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: url.path)
            guard MigrationDigest.sha256(try Data(contentsOf: url)) == MigrationDigest.sha256(file.content) else { throw MigrationError.integrity }
        }
    }
    func importedProjectInstructions(projectID: String, agentID: String) -> String {
        guard normalizedAgentID(agentID) != nil else { return "" }
        let directory = projectMetaDirectoryURL(projectID: projectID).appendingPathComponent("imported-instructions/\(agentID)")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var remaining = 40_000
        return files.sorted { $0.path < $1.path }.compactMap { file in
            guard remaining > 0, let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let content = String(text.prefix(min(20_000, remaining))); remaining -= content.count
            return "\n\n[Imported project instructions]\n" + content
        }.joined()
    }
}

extension CoreService {
    func enableMigrationMCP(_ id: String, ids: [String]) async throws -> [MigrationMCPConnectionStatus] {
        let job = try await migrationJob(id)
        let permitted = Set(job.outcomes.compactMap(\.mcpID))
        guard !ids.isEmpty, Set(ids).isSubset(of: permitted) else { throw MigrationError.invalid("Choose servers imported by this migration.") }
        var config = currentConfig
        for index in config.mcp.servers.indices where ids.contains(config.mcp.servers[index].id) { config.mcp.servers[index].enabled = true }
        _ = try await updateRuntimeConfig(config)
        return await mcpRegistry.serverStatuses().filter { ids.contains($0.id) }.map {
            MigrationMCPConnectionStatus(id: $0.id, connected: $0.connected, error: $0.connected ? nil : $0.message)
        }
    }
}
