import Foundation
import AgentRuntime
import Protocols

enum MemoryImportError: Error, LocalizedError {
    case invalid(String)
    case notFound
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .verification(let message): return message
        case .notFound: return "Memory import or source was not found."
        }
    }
}

private struct StoredImportUnit: Codable, Sendable {
    var id: String
    var sourceID: String
    var start: Int
    var end: Int
    var decision: MemoryImportDecision?
    var memoryIDs: [String]
    var completed: Bool
}

private struct StoredMemoryImport: Codable, Sendable {
    var projectID: String? = nil
    var id: String
    var agentID: String
    var sessionID: String
    var status: MemoryImportStatus
    var sources: [MemoryImportSourceInfo]
    var units: [StoredImportUnit]
    var error: String?
    var createdAt: Date
    var updatedAt: Date

    var summary: MemoryImportJob {
        let sources = sources.map { source -> MemoryImportSourceInfo in
            var result = source
            result.completedUnits = units.filter { $0.sourceID == source.id && $0.completed }.count
            return result
        }
        return MemoryImportJob(id: id, agentId: agentID, sessionId: sessionID, status: status, sources: sources,
            totalUnits: units.count, completedUnits: units.filter(\.completed).count,
            savedCount: units.reduce(0) { $0 + $1.memoryIDs.count },
            duplicateCount: units.filter(\.completed).reduce(0) { $0 + ($1.decision?.entries.filter { !$0.duplicateID.isEmpty }.count ?? 0) },
            ignoredCount: units.filter { $0.completed && $0.decision?.disposition != "retained" }.count,
            error: error, createdAt: createdAt, updatedAt: updatedAt,
            parts: units.map { unit in
                MemoryImportPart(id: unit.id, sourceId: unit.sourceID, startUTF8: unit.start, endUTF8: unit.end,
                    completed: unit.completed, disposition: unit.decision?.disposition, reason: unit.decision?.reason,
                    memoryIds: unit.memoryIDs + (unit.decision?.entries.compactMap { $0.duplicateID.isEmpty ? nil : $0.duplicateID } ?? []))
            }, projectId: projectID)
    }
}

/// Owns source snapshots, verified coverage, crash recovery and indexing writes.
/// A model response cannot set a job's completion state.
actor MemoryImportService {
    typealias Observer = @Sendable (MemoryImportJob) async -> Void
    let root: URL
    private let memoryStore: any MemoryStore
    private var tasks: [String: Task<Void, Never>] = [:]
    private var persistenceFailures: [String: MemoryImportJob] = [:]

    init(root: URL, memoryStore: any MemoryStore) {
        self.root = root
        self.memoryStore = memoryStore
    }

    func create(agentID: String, sessionID: String, files: [AgentAttachmentUpload], projectID: String? = nil) throws -> MemoryImportJob {
        guard !files.isEmpty, files.count <= 20 else { throw MemoryImportError.invalid("Choose between 1 and 20 Markdown files.") }
        var total = 0
        let decoded = try files.map { file -> (String, Data) in
            guard ["md", "markdown"].contains(URL(fileURLWithPath: file.name).pathExtension.lowercased()),
                  let base64 = file.contentBase64, base64.utf8.count <= ((1024 * 1024 + 2) / 3) * 4, let data = Data(base64Encoded: base64),
                  !data.isEmpty, data.count <= 1024 * 1024,
                  let text = String(data: data, encoding: .utf8), !text.contains("\0"),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryImportError.invalid("\(file.name): expected nonempty UTF-8 Markdown, up to 1 MB.")
            }
            total += data.count
            return (URL(fileURLWithPath: file.name).lastPathComponent, data)
        }
        guard total <= 5 * 1024 * 1024 else { throw MemoryImportError.invalid("Total import size exceeds 5 MB.") }
        let digests = decoded.map { TaskSyncCrypto.sha256Hex($0.1) }.sorted()
        if let existing = try list(agentID: agentID).first(where: {
            $0.projectId == projectID && $0.sessionId == sessionID && $0.sources.map(\.sha256).sorted() == digests
        }) { return existing }

        let id = UUID().uuidString.lowercased()
        let directory = try jobDirectory(agentID: agentID, id: id)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sources"), withIntermediateDirectories: true)
        var sources: [MemoryImportSourceInfo] = []
        var units: [StoredImportUnit] = []
        for (name, data) in decoded {
            let sourceID = UUID().uuidString.lowercased()
            try data.write(to: directory.appendingPathComponent("sources/\(sourceID).md"), options: .atomic)
            let bytes = [UInt8](data)
            var start = 0
            var count = 0
            while start < bytes.count {
                var end = min(start + 2048, bytes.count)
                while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
                // Prefer a nearby line boundary without dropping any bytes.
                if end < bytes.count, let newline = bytes[(start + (end - start) / 2)..<end].lastIndex(of: 10) { end = newline + 1 }
                units.append(.init(id: "\(sourceID):\(count)", sourceID: sourceID, start: start, end: end, decision: nil, memoryIDs: [], completed: false))
                start = end; count += 1
            }
            sources.append(.init(id: sourceID, name: name, sha256: TaskSyncCrypto.sha256Hex(data), sizeBytes: data.count, totalUnits: count, completedUnits: 0))
        }
        let job = StoredMemoryImport(projectID: projectID, id: id, agentID: agentID, sessionID: sessionID, status: .queued,
            sources: sources, units: units, error: nil, createdAt: Date(), updatedAt: Date())
        try persist(job)
        return job.summary
    }

    func list(agentID: String) throws -> [MemoryImportJob] {
        let directory = try agentDirectory(agentID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return persistenceFailures.values.filter { $0.agentId == agentID }.sorted { $0.createdAt > $1.createdAt }
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { try? get(agentID: agentID, id: $0.lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func pending() throws -> [MemoryImportJob] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let jobs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap { try list(agentID: $0.lastPathComponent) }
        for summary in jobs where summary.status == .cancelling && tasks[summary.id] == nil {
            var job = try load(agentID: summary.agentId, id: summary.id)
            job.status = .cancelled
            try persist(job)
        }
        return jobs.filter { $0.status == .queued || $0.status == .running }
    }

    func get(agentID: String, id: String) throws -> MemoryImportJob {
        let id = id.lowercased()
        if let failure = persistenceFailures[id], failure.agentId == agentID { return failure }
        return try load(agentID: agentID, id: id).summary
    }

    func sourceLocations(agentID: String, memoryID: String) throws -> [MemoryImportSourceLocation] {
        try list(agentID: agentID).flatMap { summary -> [MemoryImportSourceLocation] in
            let job = try load(agentID: agentID, id: summary.id)
            return job.units.filter { unit in
                unit.completed && (unit.memoryIDs.contains(memoryID) || unit.decision?.entries.contains(where: { $0.duplicateID == memoryID }) == true)
            }.compactMap { unit -> MemoryImportSourceLocation? in
                guard let source = job.sources.first(where: { $0.id == unit.sourceID }) else { return nil }
                return MemoryImportSourceLocation(jobId: job.id, sourceId: source.id, name: source.name, startUTF8: unit.start, endUTF8: unit.end)
            }
        }
    }

    func source(agentID: String, id: String, sourceID: String) throws -> MemoryImportSourceContent {
        let job = try load(agentID: agentID, id: id)
        guard let source = job.sources.first(where: { $0.id == sourceID }) else { throw MemoryImportError.notFound }
        let data = try sourceData(job, source: source)
        return .init(name: source.name, sha256: source.sha256, content: String(decoding: data, as: UTF8.self))
    }

    func launch(agentID: String, id: String, processor: any MemoryImportProcessing, observer: @escaping Observer) async throws -> MemoryImportJob {
        let id = id.lowercased()
        if let task = tasks[id] {
            if task.isCancelled { await task.value } else { return try get(agentID: agentID, id: id) }
        }
        var job = try load(agentID: agentID, id: id)
        guard job.status != .completed else { return job.summary }
        job.status = .queued; job.error = nil; job.updatedAt = Date()
        try persist(job)
        persistenceFailures.removeValue(forKey: id)
        tasks[id] = Task { await self.run(agentID: agentID, id: id, processor: processor, observer: observer) }
        return job.summary
    }

    func cancel(agentID: String, id: String) throws -> MemoryImportJob {
        let id = id.lowercased()
        var job = try load(agentID: agentID, id: id)
        guard job.status != .completed else { return job.summary }
        tasks[id]?.cancel()
        job.status = tasks[id] == nil ? .cancelled : .cancelling; job.updatedAt = Date()
        try persist(job)
        persistenceFailures.removeValue(forKey: id)
        return job.summary
    }

    func waitForIdle(id: String) async { await tasks[id.lowercased()]?.value }

    func markFailed(agentID: String, id: String, message: String) throws {
        let id = id.lowercased()
        var job = try load(agentID: agentID, id: id)
        guard job.status != .completed else { return }
        job.status = .failed; job.error = message; job.updatedAt = Date()
        do { try persist(job) }
        catch { persistenceFailures[id] = job.summary; throw error }
    }

    private func run(agentID: String, id: String, processor: any MemoryImportProcessing, observer: @escaping Observer) async {
        defer { tasks.removeValue(forKey: id) }
        guard var job = try? load(agentID: agentID, id: id) else { return }
        let scope = job.projectID.map(MemoryScope.project) ?? .agent(agentID)
        do {
            try Task.checkCancellation()
            job.status = .running
            try persist(job); await observer(job.summary)
            while let first = job.units.firstIndex(where: { !$0.completed }) {
                try Task.checkCancellation()
                let indices = Array(job.units.indices.filter { $0 >= first && !job.units[$0].completed }.prefix(4))
                let unprepared = indices.filter { job.units[$0].decision == nil }
                let work = try unprepared.map { index -> MemoryImportWorkUnit in
                    let unit = job.units[index]
                    guard let source = job.sources.first(where: { $0.id == unit.sourceID }) else { throw MemoryImportError.notFound }
                    let data = try sourceData(job, source: source)
                    guard unit.start >= 0, unit.end > unit.start, unit.end <= data.count else {
                        throw MemoryImportError.verification("Archived source range is invalid.")
                    }
                    return .init(id: unit.id, filename: source.name, text: String(decoding: data[unit.start..<unit.end], as: UTF8.self))
                }
                if !unprepared.isEmpty {
                    let query = work.map(\.text).joined(separator: "\n")
                    let hits = await memoryStore.recall(request: .init(query: query, limit: 20, scope: scope))
                    let hitIDs = Set(hits.map { $0.ref.id })
                    let entries = await memoryStore.entries(filter: .init(scope: scope))
                    let existing = entries.filter { hitIDs.contains($0.id) }
                    let extraction = try await verifiedExtraction(processor, units: work, existing: existing)
                    try Task.checkCancellation()
                    for index in unprepared { job.units[index].decision = extraction.decisions.first { $0.unitID == job.units[index].id } }
                    // Persist the accepted plan before any writes; recovery never regenerates committed work.
                    try persist(job)
                }
                for index in indices {
                    try Task.checkCancellation()
                    guard let decision = job.units[index].decision else { throw MemoryImportError.verification("Missing decision for a source unit.") }
                    for (itemIndex, candidate) in decision.entries.enumerated() {
                        try Task.checkCancellation()
                        let active = await memoryStore.entries(filter: .init(scope: scope))
                        if !candidate.duplicateID.isEmpty {
                            guard active.contains(where: { $0.id == candidate.duplicateID }) else {
                                throw MemoryImportError.verification("A verified duplicate was removed; review is required.")
                            }
                            continue
                        }
                        if let duplicate = active.first(where: { $0.note == candidate.note && $0.metadata["import_item_id"]?.asString != "\(id)/\(job.units[index].id)/\(itemIndex)" }) {
                            job.units[index].decision?.entries[itemIndex].duplicateID = duplicate.id
                            try persist(job)
                            continue
                        }
                        let key = "\(id)/\(job.units[index].id)/\(itemIndex)"
                        let savedID: String
                        if let existing = active.first(where: { $0.metadata["import_item_id"]?.asString == key }) {
                            savedID = existing.id
                        } else {
                            let unit = job.units[index]
                            guard let source = job.sources.first(where: { $0.id == unit.sourceID }) else { throw MemoryImportError.notFound }
                            let ref = await memoryStore.save(entry: .init(
                                note: candidate.note, summary: candidate.summary,
                                kind: MemoryKind(rawValue: candidate.kind),
                                memoryClass: ["event", "observation"].contains(candidate.kind) ? .episodic : .semantic, scope: scope,
                                source: .init(type: "memory_import", id: "v1/\(agentID)/\(id)/\(source.id)"),
                                metadata: ["import_item_id": .string(key), "import_job_id": .string(id),
                                    "source_name": .string(source.name), "source_sha256": .string(source.sha256),
                                    "source_start_utf8": .number(Double(unit.start)), "source_end_utf8": .number(Double(unit.end)),
                                    "evidence_quote": .string(candidate.evidenceQuote)]
                            ))
                            let stored = await memoryStore.entries(filter: .init(scope: scope))
                            guard stored.contains(where: { $0.id == ref.id && $0.note == candidate.note && $0.metadata["import_item_id"]?.asString == key }) else {
                                throw MemoryImportError.verification("The memory store did not confirm a saved record.")
                            }
                            savedID = ref.id
                        }
                        if !job.units[index].memoryIDs.contains(savedID) { job.units[index].memoryIDs.append(savedID) }
                        try persist(job)
                        try await verifyRecall(id: savedID, note: candidate.note, scope: scope)
                    }
                    job.units[index].completed = true
                    job.updatedAt = Date()
                    try persist(job)
                }
                await observer(job.summary)
            }
            try Task.checkCancellation()
            guard job.units.allSatisfy({ $0.completed && $0.decision != nil }) else {
                throw MemoryImportError.verification("Unprocessed source units remain.")
            }
            job.status = .completed; job.error = nil
        } catch {
            job.status = Task.isCancelled ? .cancelled : .failed
            job.error = Task.isCancelled ? nil : error.localizedDescription
        }
        job.updatedAt = Date()
        do { try persist(job) }
        catch {
            job.status = .failed
            job.error = "Could not persist import progress: \(error.localizedDescription)"
            persistenceFailures[id] = job.summary
        }
        await observer(job.summary)
    }

    private func verifiedExtraction(_ processor: any MemoryImportProcessing, units: [MemoryImportWorkUnit], existing: [MemoryEntry]) async throws -> MemoryImportExtraction {
        var feedback = ""
        for _ in 0..<3 {
            try Task.checkCancellation()
            do {
                let extraction = try await processor.extract(units: units, existing: existing, feedback: feedback)
                try Task.checkCancellation()
                try Self.validate(extraction, units: units, existing: existing)
                let review = try await processor.review(units: units, existing: existing, extraction: extraction)
                try Task.checkCancellation()
                guard Set(review.reviewedUnitIDs) == Set(units.map(\.id)), review.reviewedUnitIDs.count == units.count else {
                    throw MemoryImportError.verification("The coverage reviewer omitted source units.")
                }
                if review.accepted { return extraction }
                feedback = "Coverage review rejected the extraction: " + review.feedback
            } catch {
                if Task.isCancelled { throw CancellationError() }
                feedback = Self.extractionErrorFeedback(error)
            }
        }
        throw MemoryImportError.verification("Extraction could not pass coverage verification after 3 attempts. " + feedback)
    }

    private static func extractionErrorFeedback(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "JSON is missing required field: " + (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "JSON has an invalid value at: " + context.codingPath.map(\.stringValue).joined(separator: ".")
        case is DecodingError:
            return "Return valid JSON matching the required schema, without Markdown fences or commentary."
        default:
            return error.localizedDescription
        }
    }

    private func verifyRecall(id: String, note: String, scope: MemoryScope) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let hits = await memoryStore.recall(request: .init(query: note, limit: 10, scope: scope))
            if hits.contains(where: { $0.ref.id == id }) { return }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
        }
        throw MemoryImportError.verification("A saved record is not available through scoped recall yet. Restore the memory index and resume this job.")
    }

    static func validate(_ extraction: MemoryImportExtraction, units: [MemoryImportWorkUnit], existing: [MemoryEntry]) throws {
        guard extraction.decisions.count == units.count, Set(extraction.decisions.map(\.unitID)) == Set(units.map(\.id)) else {
            throw MemoryImportError.verification("Return exactly one decision for every source unit; partial coverage is not accepted.")
        }
        for decision in extraction.decisions {
            guard let unit = units.first(where: { $0.id == decision.unitID }) else { throw MemoryImportError.notFound }
            if decision.disposition == "retained" {
                guard !decision.entries.isEmpty else { throw MemoryImportError.verification("A retained unit has no records.") }
            } else {
                guard ["not_memory", "sensitive"].contains(decision.disposition), decision.entries.isEmpty, !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MemoryImportError.verification("Every discarded unit needs a valid disposition and reason.")
                }
            }
            for entry in decision.entries {
                guard !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !entry.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      MemoryKind(rawValue: entry.kind) != nil,
                      !entry.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      unit.text.contains(entry.evidenceQuote) else {
                    throw MemoryImportError.verification("Each record needs self-contained text, a valid kind, and a verbatim evidence quote from its unit.")
                }
                if !entry.duplicateID.isEmpty && !existing.contains(where: { $0.id == entry.duplicateID }) {
                    throw MemoryImportError.verification("A duplicate ID was not supplied in the scoped existing memory.")
                }
            }
        }
    }

    private func agentDirectory(_ agentID: String) throws -> URL {
        guard !agentID.isEmpty, !agentID.contains("/"), !agentID.contains("\\"), agentID != ".", agentID != ".." else { throw MemoryImportError.notFound }
        return root.appendingPathComponent(agentID, isDirectory: true)
    }

    private func jobDirectory(agentID: String, id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MemoryImportError.notFound }
        return try agentDirectory(agentID).appendingPathComponent(id.lowercased(), isDirectory: true)
    }

    private func load(agentID: String, id: String) throws -> StoredMemoryImport {
        let path = try jobDirectory(agentID: agentID, id: id).appendingPathComponent("job.json")
        guard let data = try? Data(contentsOf: path) else { throw MemoryImportError.notFound }
        let job = try JSONDecoder().decode(StoredMemoryImport.self, from: data)
        guard job.agentID == agentID, job.id == id.lowercased() else { throw MemoryImportError.notFound }
        return job
    }

    private func persist(_ job: StoredMemoryImport) throws {
        let path = try jobDirectory(agentID: job.agentID, id: job.id).appendingPathComponent("job.json")
        try JSONEncoder().encode(job).write(to: path, options: .atomic)
    }

    private func sourceData(_ job: StoredMemoryImport, source: MemoryImportSourceInfo) throws -> Data {
        guard UUID(uuidString: source.id) != nil else { throw MemoryImportError.notFound }
        let directory = try jobDirectory(agentID: job.agentID, id: job.id).appendingPathComponent("sources").resolvingSymlinksInPath()
        let path = directory.appendingPathComponent("\(source.id).md").resolvingSymlinksInPath()
        guard path.path.hasPrefix(directory.path + "/") else { throw MemoryImportError.notFound }
        let data = try Data(contentsOf: path)
        guard TaskSyncCrypto.sha256Hex(data) == source.sha256 else { throw MemoryImportError.verification("Archived source integrity check failed.") }
        return data
    }
}
