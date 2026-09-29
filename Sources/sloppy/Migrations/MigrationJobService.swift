import Foundation
import SloppyMigration

private struct MemoryMigrationProgress: Codable, Sendable { var completed: Int; var total: Int }

private struct StoredMigration: Codable, Sendable {
    var job: MigrationJob
    var digest: String
    var selection: MigrationSelection?
    var memoryProgress: [String: MemoryMigrationProgress] = [:]
}

/// Durable transfer journal and serialized item commits. Only Core applies data.
actor MigrationJobService {
    typealias Apply = @Sendable (MigrationItem, MigrationSelection, String) async throws -> MigrationOutcome
    let root: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    private var persistenceFailures: [String: MigrationJob] = [:]
    private var ledger: [String: MigrationOutcome]?
    init(root: URL) { self.root = root }
    func create(_ request: MigrationCreateRequest) throws -> MigrationJob {
        guard request.totalBytes > 0, request.totalBytes <= 256 * 1024 * 1024,
              request.totalItems > 0, request.totalItems <= 100_000,
              request.sha256.count == 64, !request.destination.isEmpty else { throw MigrationError.invalid("Invalid migration manifest (maximum 256 MB).") }
        for candidate in try list() where candidate.destination == request.destination && candidate.status == .uploading {
            if try load(candidate.id).digest == request.sha256 { return candidate }
        }
        let job = MigrationJob(destination: request.destination, totalItems: request.totalItems, totalBytes: request.totalBytes)
        try persist(.init(job: job, digest: request.sha256))
        return job
    }
    func upload(id: String, chunk: MigrationUploadChunk) throws -> MigrationJob {
        var state = try load(id)
        guard state.job.status == .uploading, chunk.offset >= 0, !chunk.data.isEmpty, chunk.data.count <= 1024 * 1024,
              chunk.offset + chunk.data.count <= state.job.totalBytes else { throw MigrationError.invalid("Invalid upload chunk.") }
        let url = try directory(id).appendingPathComponent("upload.data")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        if chunk.offset < length {
            try handle.seek(toOffset: UInt64(chunk.offset))
            guard try handle.read(upToCount: chunk.data.count) == chunk.data else { throw MigrationError.integrity }
        } else {
            guard chunk.offset == length else { throw MigrationError.invalid("Resume at the acknowledged upload offset.") }
            try handle.write(contentsOf: chunk.data); try handle.synchronize()
        }
        state.job.uploadedBytes = max(length, chunk.offset + chunk.data.count)
        try persist(state); return state.job
    }
    func accept(selection: MigrationSelection, destination: String) throws -> MigrationJob {
        try Self.validate(selection)
        let data = try MigrationDigest.encoder.encode(selection)
        var state = StoredMigration(job: .init(destination: destination, totalItems: selection.items.count, totalBytes: data.count), digest: MigrationDigest.sha256(data), selection: selection)
        state.job.uploadedBytes = data.count; state.job.status = .queued
        try persist(state); return state.job
    }
    func get(_ id: String) throws -> MigrationJob {
        if let failure = persistenceFailures[id] { return failure }
        var state = try load(id)
        if state.job.status == .uploading {
            let url = try directory(id).appendingPathComponent("upload.data")
            state.job.uploadedBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return state.job
    }
    func list() throws -> [MigrationJob] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { try? get($0.lastPathComponent) }.sorted { $0.createdAt > $1.createdAt }
    }
    func preview(_ selection: MigrationSelection) throws -> MigrationPreview {
        try Self.validate(selection)
        let records = try readLedger()
        var duplicates: [String] = []; var conflicts: [String] = []
        for item in selection.items {
            if records[key(item, selection)] != nil { duplicates.append(item.id) }
            else if records.values.contains(where: { $0.id == item.id }) { conflicts.append(item.id) }
        }
        return .init(selection: selection, duplicates: duplicates, conflicts: conflicts)
    }
    func start(_ id: String, apply: @escaping Apply) throws -> MigrationJob {
        if tasks[id] != nil { return try get(id) }
        var state = try load(id)
        if state.job.status == .completed { return state.job }
        if state.selection == nil {
            let data = try Data(contentsOf: directory(id).appendingPathComponent("upload.data"))
            guard data.count == state.job.totalBytes, MigrationDigest.sha256(data) == state.digest else { throw MigrationError.integrity }
            state.selection = try MigrationDigest.decoder.decode(MigrationSelection.self, from: data)
        }
        guard let selection = state.selection else { throw MigrationError.integrity }
        try Self.validate(selection)
        guard selection.items.count == state.job.totalItems else { throw MigrationError.integrity }
        state.job.outcomes.removeAll { ["error", "waiting"].contains($0.status) }
        state.job.status = .queued; try persist(state)
        persistenceFailures.removeValue(forKey: id)
        tasks[id] = Task { await run(id, apply: apply) }
        return state.job
    }
    func resumeUpload(_ id: String) throws -> MigrationJob? {
        var state = try load(id)
        guard state.selection == nil else { return nil }
        let file = try directory(id).appendingPathComponent("upload.data")
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < state.job.totalBytes else { return nil }
        state.job.status = .uploading; state.job.stage = .transfer; state.job.uploadedBytes = size
        try persist(state)
        return state.job
    }
    func cancel(_ id: String) throws -> MigrationJob {
        tasks[id]?.cancel()
        var state = try load(id)
        if state.job.status == .completed { return state.job }
        state.job.status = .cancelled; try persist(state)
        return state.job
    }
    func recordMemoryProgress(_ id: String, memoryJobID: String, completed: Int, total: Int) {
        guard var state = try? load(id) else { return }
        state.memoryProgress[memoryJobID] = .init(completed: completed, total: total)
        state.job.stage = .memory
        state.job.memoryCompletedUnits = state.memoryProgress.values.reduce(0) { $0 + $1.completed }
        state.job.memoryTotalUnits = state.memoryProgress.values.reduce(0) { $0 + $1.total }
        try? persist(state)
    }
    func wait(_ id: String) async { await tasks[id]?.value }
    private func run(_ id: String, apply: @escaping Apply) async {
        defer { tasks.removeValue(forKey: id) }
        guard var state = try? load(id), let selection = state.selection else { return }
        do {
            state.job.status = .running; state.job.stage = .importing; try persist(state)
            let priority: [MigrationCategory: Int] = [.project: 0, .instructions: 1, .skill: 2, .mcp: 3, .session: 4, .memory: 5]
            let items = selection.items.sorted { (priority[$0.category] ?? 0, $0.id) < (priority[$1.category] ?? 0, $1.id) }
            for item in items {
                try Task.checkCancellation()
                if state.job.outcomes.contains(where: { $0.id == item.id && !["error", "waiting"].contains($0.status) }) { continue }
                let recordKey = key(item, selection)
                if var existing = try readLedger()[recordKey] {
                    existing.status = "duplicate"; state.job.outcomes.append(existing)
                } else {
                    do {
                        let outcome = try await apply(item, selection, id)
                        try Task.checkCancellation()
                        if let updated = try? load(id) {
                            state.job.memoryCompletedUnits = updated.job.memoryCompletedUnits
                            state.job.memoryTotalUnits = updated.job.memoryTotalUnits
                        }
                        state.job.outcomes.append(outcome)
                        if outcome.status == "imported" {
                            var records = try readLedger(); records[recordKey] = outcome
                            try MigrationDigest.encoder.encode(records).write(to: root.appendingPathComponent("ledger.json"), options: .atomic)
                            ledger = records
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { state.job.outcomes.append(.init(item: item, status: "error", message: error.localizedDescription)) }
                }
                if let updated = try? load(id) {
                    state.memoryProgress = updated.memoryProgress
                    state.job.memoryCompletedUnits = updated.job.memoryCompletedUnits
                    state.job.memoryTotalUnits = updated.job.memoryTotalUnits
                }
                state.job.stage = item.category == .memory ? .memory : .importing
                try persist(state)
            }
            try Task.checkCancellation()
            state.job.stage = .verifying; try persist(state)
            state.job.warnings = (selection.warnings ?? []) + selection.items.flatMap(\.warnings)
            state.job.status = state.job.outcomes.contains(where: { $0.status == "waiting" }) ? .waitingForModel :
                state.job.outcomes.contains(where: { $0.status == "error" }) || !state.job.warnings.isEmpty ? .completedWithIssues : .completed
            state.job.stage = .result
        } catch {
            state.job.status = Task.isCancelled ? .cancelled : .failed
            if !Task.isCancelled { state.job.warnings.append(error.localizedDescription) }
        }
        do { try persist(state) }
        catch {
            state.job.status = .failed
            state.job.warnings.append("Could not persist migration progress: " + error.localizedDescription)
            persistenceFailures[id] = state.job
        }
    }
    private func key(_ item: MigrationItem, _ selection: MigrationSelection) -> String {
        MigrationDigest.id(item.id + ":" + item.checksum + ":" + (selection.agentMappings[item.profileKey] ?? "new") + ":" + (selection.projectMappings[item.projectPath ?? ""] ?? ""))
    }
    private func readLedger() throws -> [String: MigrationOutcome] {
        if let ledger { return ledger }
        let url = root.appendingPathComponent("ledger.json")
        let value = FileManager.default.fileExists(atPath: url.path) ? try MigrationDigest.decoder.decode([String: MigrationOutcome].self, from: Data(contentsOf: url)) : [:]
        ledger = value; return value
    }
    private func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MigrationError.invalid("Invalid migration ID.") }
        return root.appendingPathComponent(id.lowercased(), isDirectory: true)
    }
    private func load(_ id: String) throws -> StoredMigration {
        let url = try directory(id).appendingPathComponent("job.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw MigrationError.missing }
        return try MigrationDigest.decoder.decode(StoredMigration.self, from: Data(contentsOf: url))
    }
    private func persist(_ state: StoredMigration) throws {
        let folder = try directory(state.job.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try MigrationDigest.encoder.encode(state).write(to: folder.appendingPathComponent("job.json"), options: .atomic)
    }
    static func validate(_ selection: MigrationSelection) throws {
        guard !selection.items.isEmpty, Set(selection.items.map(\.id)).count == selection.items.count else { throw MigrationError.invalid("Choose unique migration objects.") }
        for item in selection.items {
            guard item.id == MigrationDigest.id(item.source.id + ":" + item.profile + ":" + item.category.rawValue + ":" + item.externalID),
                  item.files.allSatisfy({ MigrationDigest.safeRelativePath($0.path) && $0.content.count <= 10 * 1024 * 1024 }),
                  Set(item.files.map(\.path)).count == item.files.count else { throw MigrationError.invalid("Invalid imported file or object identity.") }
        }
    }
}
