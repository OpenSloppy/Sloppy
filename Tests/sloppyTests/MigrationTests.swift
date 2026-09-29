import Foundation
import Testing
import AnyLanguageModel
import AgentRuntime
import Protocols
import SloppyRuntime
import SloppyMigration
@testable import sloppy

@Suite struct MigrationTests {
    private func item(category: MigrationCategory = .session) -> MigrationItem {
        .init(source: .init(kind: .codex, path: "/fixture/.codex"), externalID: "source-session", category: category, title: "Imported discussion",
              messages: category == .session ? [.init(id: "user-1", kind: .user, text: "Project knowledge", createdAt: Date(timeIntervalSince1970: 1)),
                .init(id: "call-1", kind: .toolCall, text: "{}", tool: "exec", callID: "call", createdAt: Date(timeIntervalSince1970: 2))] : [])
    }
    @Test func uploadRetryAndRestartKeepAcknowledgedOffsetAndDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = MigrationSelection(items: [item()])
        let data = try MigrationDigest.encoder.encode(selection)
        let engine = MigrationJobService(root: root)
        let job = try await engine.create(.init(destination: "https://selected-core", totalBytes: data.count, sha256: MigrationDigest.sha256(data), totalItems: 1))
        let chunk = MigrationUploadChunk(offset: 0, data: data)
        _ = try await engine.upload(id: job.id, chunk: chunk)
        _ = try await engine.upload(id: job.id, chunk: chunk)
        let restarted = MigrationJobService(root: root)
        #expect(try await restarted.get(job.id).uploadedBytes == data.count)
        #expect(try await restarted.get(job.id).destination == "https://selected-core")
        _ = try await restarted.start(job.id) { item, _, _ in .init(item: item, status: "imported") }
        await restarted.wait(job.id)
        #expect(try await restarted.get(job.id).status == .completed)
        #expect(try await restarted.preview(selection).duplicates == [selection.items[0].id])
    }
    @Test func cancelledPartialUploadCanResumeWithoutLosingAcknowledgedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-upload-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MigrationJobService(root: root)
        let data = try MigrationDigest.encoder.encode(MigrationSelection(items: [item()]))
        let job = try await engine.create(.init(destination: "fixture", totalBytes: data.count, sha256: MigrationDigest.sha256(data), totalItems: 1))
        let split = data.count / 2
        _ = try await engine.upload(id: job.id, chunk: .init(offset: 0, data: Data(data[..<split])))
        _ = try await engine.cancel(job.id)
        #expect(try await engine.get(job.id).status == .cancelled)
        let resumed = try #require(try await engine.resumeUpload(job.id))
        #expect(resumed.uploadedBytes == split)
        _ = try await engine.upload(id: job.id, chunk: .init(offset: split, data: Data(data[split...])))
        _ = try await engine.start(job.id) { item, _, _ in .init(item: item, status: "imported") }
        await engine.wait(job.id)
        #expect(try await engine.get(job.id).status == .completed)
    }
    @Test func importCreatesResumableNativeSessionAndRevisionPreservesContinuedChat() async throws {
        let config = CoreConfig.test
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder(), sharedSkillsRootURLs: [])
        var imported = item()
        let selection = MigrationSelection(items: [imported])
        let job = try await service.importMigration(selection)
        let jobs = await service.migrations
        await jobs.wait(job.id)
        let completed = try await service.migrationJob(job.id)
        let outcome = try #require(completed.outcomes.first)
        let agentID = try #require(outcome.agentID); let sessionID = try #require(outcome.sessionID)
        #expect(outcome.status == "imported")
        let store = await service.sessionStore
        var detail = try store.loadSession(agentID: agentID, sessionID: sessionID)
        #expect(detail.events.filter { $0.message != nil }.count == 1)
        let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)
        #expect(!transcript.contains { if case .toolCalls = $0 { return true }; return false })
        #expect(transcript.count == 2)
        _ = try await service.postAgentSessionMessage(agentID: agentID, sessionID: sessionID,
            request: .init(userId: "fixture-user", content: "Native continuation", mode: .ask))
        let runtime = await service.runtime
        let bootstrap = await runtime.channelBootstrapContent(channelId: "agent:\(agentID):session:\(sessionID)")
        #expect(bootstrap?.contains("Project knowledge") == true)
        let repeated = try await service.importMigration(selection); await jobs.wait(repeated.id)
        #expect(try await service.migrationJob(repeated.id).outcomes.first?.status == "duplicate")
        imported.messages.append(.init(id: "source-new", kind: .assistant, text: "Changed source", createdAt: Date(timeIntervalSince1970: 3)))
        let revision = try await service.importMigration(.init(items: [imported])); await jobs.wait(revision.id)
        #expect(try await service.migrationJob(revision.id).outcomes.first?.sessionID != sessionID)
        detail = try store.loadSession(agentID: agentID, sessionID: sessionID)
        #expect(detail.events.contains { $0.message?.segments.first?.text?.contains("Native continuation") == true })
        let reopened = AgentSessionFileStore(agentsRootURL: await service.agentsRootURL)
        #expect(try reopened.loadSession(agentID: agentID, sessionID: sessionID).events == detail.events)
    }
    @Test func importedMCPStaysDisabledAndMemoryWaitsForModel() async throws {
        var config = CoreConfig.test
        config.models = []
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder(), sharedSkillsRootURLs: [])
        var mcp = item(category: .mcp); mcp.mcp = .init(command: "must-not-be-executed", arguments: ["--fixture"])
        var memory = item(category: .memory); memory.files = [.init(path: "MEMORY.md", content: Data("Durable project knowledge".utf8))]
        let job = try await service.importMigration(.init(items: [mcp, memory])); let jobs = await service.migrations; await jobs.wait(job.id)
        let completed = try await service.migrationJob(job.id)
        #expect(completed.status == .waitingForModel)
        let serverID = try #require(completed.outcomes.first { $0.category == .mcp }?.mcpID)
        #expect(await service.currentConfig.mcp.servers.first { $0.id == serverID }?.enabled == false)
    }
    @Test func cancellationRetainsJournalAndAllowsResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MigrationJobService(root: root)
        let job = try await engine.accept(selection: .init(items: [item()]), destination: "fixture")
        let gate = MigrationStartedGate()
        _ = try await engine.start(job.id) { item, _, _ in
            await gate.enter()
            try await Task.sleep(for: .seconds(10))
            return .init(item: item, status: "imported")
        }
        await gate.waitForStart()
        _ = try await engine.cancel(job.id)
        await engine.wait(job.id)
        #expect(try await engine.get(job.id).status == .cancelled)
        _ = try await engine.start(job.id) { item, _, _ in .init(item: item, status: "imported") }
        await engine.wait(job.id)
        #expect(try await engine.get(job.id).status == .completed)
    }
    @Test func legacyEventAndMemoryRequestRemainDecodable() throws {
        let event = AgentSessionEvent(agentId: "a", sessionId: "s", type: .message)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var raw = try #require(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]); raw.removeValue(forKey: "importOrigin")
        let decoded = try MigrationDigest.decoder.decode(AgentSessionEvent.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(decoded.importOrigin == nil)
        #expect(try JSONDecoder().decode(MemoryImportRequest.self, from: Data("{\"attachments\":[]}".utf8)).projectId == nil)
    }
    @Test func skillsAndInstructionsCopyThroughMacOSTemporaryDirectoryAlias() async throws {
        var config = CoreConfig.test
        #if os(macOS)
        config.workspace.basePath = "/private/tmp"
        #endif
        let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder(), sharedSkillsRootURLs: [])
        var skill = item(category: .skill)
        skill.files = [.init(path: "SKILL.md", content: Data("---\nname: fixture\ndescription: Review changes\n---\nUse fixture knowledge".utf8)),
                       .init(path: "scripts/check.sh", content: Data("#!/bin/sh\ntrue".utf8), executable: true)]
        var instructions = item(category: .instructions)
        instructions.files = [.init(path: "USER.md", content: Data("Keep the original profile and add imported preferences.".utf8))]
        let job = try await service.importMigration(.init(items: [skill, instructions]))
        let jobs = await service.migrations; await jobs.wait(job.id)
        let completed = try await service.migrationJob(job.id)
        #expect(completed.status == .completed)
        #expect(completed.outcomes.allSatisfy { $0.status == "imported" })
        let agent = try #require(completed.outcomes.first?.agentID)
        let skills = try await service.listAgentSkills(agentID: agent)
        let imported = try #require(skills.skills.first { $0.owner == "imported-codex" })
        #expect(try String(contentsOf: URL(fileURLWithPath: imported.localPath).appendingPathComponent("scripts/check.sh"), encoding: .utf8) == "#!/bin/sh\ntrue")
        #expect(FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: imported.localPath).appendingPathComponent("scripts/check.sh").path))
    }
    @Test func memoryImportRespectsProjectScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryMemoryStore()
        let importer = MemoryImportService(root: root, memoryStore: store)
        let data = Data("Unique project knowledge".utf8)
        let job = try await importer.create(agentID: "a", sessionID: "s", files: [.init(name: "MEMORY.md", mimeType: "text/markdown", sizeBytes: data.count, contentBase64: data.base64EncodedString())], projectID: "p")
        _ = try await importer.launch(agentID: "a", id: job.id, processor: MigrationMemoryFixture(), observer: { _ in })
        await importer.waitForIdle(id: job.id)
        #expect(try await importer.get(agentID: "a", id: job.id).status == .completed)
        #expect(await store.entries(filter: .init(scope: .project("p"))).count == 1)
        #expect(await store.entries(filter: .init(scope: .agent("a"))).isEmpty)
        let reopened = MemoryImportService(root: root, memoryStore: store)
        #expect(try await reopened.get(agentID: "a", id: job.id).projectId == "p")
    }
    @Test func traversalCannotReachDestinationFiles() async throws {
        var skill = item(category: .skill); skill.files = [.init(path: "../outside", content: Data())]
        #expect(throws: MigrationError.self) { try MigrationJobService.validate(.init(items: [skill])) }
    }
}

private struct MigrationMemoryFixture: MemoryImportProcessing {
    func extract(units: [MemoryImportWorkUnit], existing: [MemoryEntry], feedback: String) async throws -> MemoryImportExtraction {
        .init(decisions: units.map { .init(unitID: $0.id, disposition: "retained", reason: "Project fact", entries: [.init(note: $0.text, summary: "Project fact", kind: "fact", evidenceQuote: $0.text, duplicateID: "")]) })
    }
    func review(units: [MemoryImportWorkUnit], existing: [MemoryEntry], extraction: MemoryImportExtraction) async throws -> MemoryImportReview {
        .init(reviewedUnitIDs: units.map(\.id), accepted: true, feedback: "")
    }
}

private actor MigrationStartedGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() { started = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
