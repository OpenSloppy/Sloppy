import AgentRuntime
import Foundation
import Logging
import Protocols

#if canImport(CSQLite3)
import CSQLite3
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// SQLite-canonical memory store with pluggable provider indexing.
public actor HybridMemoryStore: MemoryStore {
#if canImport(CSQLite3)
    private var db: OpaquePointer?
#endif
    private let provider: (any MemoryProvider)?
    private let embeddingService: EmbeddingService?
    private let retrieval: CoreConfig.Memory.Retrieval
    private let retention: CoreConfig.Memory.Retention
    private let logger: Logger
    private let isoFormatter: ISO8601DateFormatter

    init(
        config: CoreConfig,
        mcpRegistry: MCPClientRegistry? = nil,
        embeddingService: EmbeddingService? = nil,
        logger: Logger = Logger.sloppy(label: "sloppy.memory")
    ) {
        self.retrieval = config.memory.retrieval
        self.retention = config.memory.retention
        self.logger = logger
        let resolvedMCPRegistry = mcpRegistry ?? MCPClientRegistry(config: config.mcp)
        self.provider = MemoryProviderRegistry.makeProvider(config: config, mcpRegistry: resolvedMCPRegistry, logger: logger)
        self.embeddingService = embeddingService
        self.isoFormatter = ISO8601DateFormatter()

#if canImport(CSQLite3)
        var opened: OpaquePointer?
        let sqlitePath = config.resolvedSQLiteURL().path
        let directory = URL(fileURLWithPath: sqlitePath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        if sqlite3_open(sqlitePath, &opened) == SQLITE_OK {
            db = opened
            Self.applySchema(db: opened)
        } else {
            db = nil
        }
#endif
    }

    public func save(entry: MemoryWriteRequest) async -> MemoryRef {
        let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = entry.updatedAt ?? Date()
        let resolvedKind = entry.kind ?? inferredKind(note: note)
        let resolvedClass = entry.memoryClass ?? defaultClass(for: resolvedKind)
        let resolvedScope = entry.scope ?? .default
        let expiresAt = resolveExpiry(
            explicit: entry.expiresAt,
            kind: resolvedKind,
            memoryClass: resolvedClass,
            metadata: entry.metadata,
            now: now
        )

        let document = MemoryProviderDocument(
            id: UUID().uuidString,
            text: note,
            summary: entry.summary,
            kind: resolvedKind,
            memoryClass: resolvedClass,
            scope: resolvedScope,
            source: entry.source,
            metadata: entry.metadata,
            createdAt: now
        )

#if canImport(CSQLite3)
        persistCanonicalEntry(
            id: document.id,
            note: note,
            summary: entry.summary,
            kind: resolvedKind,
            memoryClass: resolvedClass,
            scope: resolvedScope,
            source: entry.source,
            importance: entry.importance ?? 0.5,
            confidence: entry.confidence ?? 0.7,
            metadata: entry.metadata,
            createdAt: now,
            updatedAt: now,
            expiresAt: expiresAt,
            deletedAt: nil
        )

        if let payload = try? JSONEncoder().encode(document),
           let payloadString = String(data: payload, encoding: .utf8) {
            enqueueOutbox(memoryId: document.id, op: "upsert", payload: payloadString, now: now)
        }
#endif

        if let provider {
            do {
                try await provider.upsert(document: document)
#if canImport(CSQLite3)
                deleteOutboxRows(memoryId: document.id, op: "upsert")
#endif
            } catch {
                logger.warning("Memory provider upsert failed: \(String(describing: error))")
            }
        }

        if let embeddingService {
            do {
                let vector = try await embeddingService.embed(text: note)
#if canImport(CSQLite3)
                persistEmbedding(memoryId: document.id, vector: vector)
#endif
            } catch {
                logger.warning("Memory embedding failed for \(document.id): \(String(describing: error))")
            }
        }

        return MemoryRef(
            id: document.id,
            score: 1.0,
            kind: resolvedKind,
            memoryClass: resolvedClass,
            source: entry.source,
            createdAt: now
        )
    }

    public func recall(request: MemoryRecallRequest) async -> [MemoryHit] {
        await recallWithDiagnostics(request: request).hits
    }

    public func recallWithDiagnostics(request: MemoryRecallRequest) async -> MemoryRecallResult {
        let started = ContinuousClock.now
        var stages: [MemoryRetrievalStage] = []
        let limit = max(1, request.limit)
        let semanticLimit = max(40, limit)

        var mergedScores: [String: Double] = [:]

        if let provider {
            let stageStart = ContinuousClock.now
            var candidateCount = 0
            var failure: String?
            do {
                let semantic = try await provider.query(
                    request: MemoryProviderQuery(
                        query: request.query,
                        limit: semanticLimit,
                        scope: request.scope
                    )
                )
                candidateCount = semantic.count
                for result in semantic {
                    let weighted = normalize(result.score) * retrieval.semanticWeight
                    mergedScores[result.id] = max(mergedScores[result.id] ?? 0, weighted)
                }
            } catch {
                failure = "Provider query failed: \(String(reflecting: type(of: error))) (code \((error as NSError).code))"
                logger.warning("Memory provider query failed: \(String(describing: error))")
            }
            stages.append(MemoryRetrievalStage(name: "provider", durationMs: memoryElapsedMilliseconds(since: stageStart), candidateCount: candidateCount, error: failure))
        }

        if let embeddingService {
            let stageStart = ContinuousClock.now
            var candidateCount = 0
            var failure: String?
            do {
                let queryVector = try await embeddingService.embed(text: request.query)
#if canImport(CSQLite3)
                let cosineMatches = queryCosineMatches(
                    queryVector: queryVector,
                    limit: semanticLimit,
                    scope: request.scope
                )
                candidateCount = cosineMatches.count
                for (id, score) in cosineMatches {
                    let weighted = Double(score) * retrieval.semanticWeight
                    mergedScores[id] = max(mergedScores[id] ?? 0, weighted)
                }
#endif
            } catch {
                failure = "Embedding query failed: \(String(reflecting: type(of: error))) (code \((error as NSError).code))"
                logger.warning("Embedding query failed: \(String(describing: error))")
            }
            stages.append(MemoryRetrievalStage(name: "embedding", durationMs: memoryElapsedMilliseconds(since: stageStart), candidateCount: candidateCount, error: failure))
        }

#if canImport(CSQLite3)
        let keywordStart = ContinuousClock.now
        let keywordMatches = queryKeywordMatches(query: request.query, limit: semanticLimit, scope: request.scope)
        stages.append(MemoryRetrievalStage(name: "keyword", durationMs: memoryElapsedMilliseconds(since: keywordStart), candidateCount: keywordMatches.count, error: db == nil ? "Memory database is unavailable" : nil))
        for match in keywordMatches {
            let weighted = normalize(match.score) * retrieval.keywordWeight
            mergedScores[match.id] = max(mergedScores[match.id] ?? 0, weighted)
        }

        let seedVisibilityDate = Date()
        mergedScores = mergedScores.filter { id, _ in
            guard let entry = loadEntry(id: id) else {
                return false
            }
            return isRecallVisible(entry, now: seedVisibilityDate)
        }

        let graphStart = ContinuousClock.now
        let expanded = graphExpand(seedIDs: Array(mergedScores.keys), limit: semanticLimit)
        stages.append(MemoryRetrievalStage(name: "graph", durationMs: memoryElapsedMilliseconds(since: graphStart), candidateCount: expanded.count))
        for id in expanded {
            mergedScores[id] = max(mergedScores[id] ?? 0, retrieval.graphWeight)
        }
        let finalVisibilityDate = Date()
        mergedScores = mergedScores.filter { id, _ in
            guard let entry = loadEntry(id: id) else {
                return false
            }
            return isRecallVisible(entry, now: finalVisibilityDate)
        }

        let sortedIDs = mergedScores
            .sorted(by: { $0.value > $1.value })
            .map(\.key)
        let topIDs = Array(sortedIDs.prefix(max(limit, retrieval.topK)))

        let now = Date()
        var hits: [MemoryHit] = []
        for id in topIDs {
            guard let entry = loadEntry(id: id) else {
                continue
            }
            guard isRecallVisible(entry, now: now) else {
                continue
            }
            if let scope = request.scope,
               (entry.scope.type != scope.type || entry.scope.id != scope.id) {
                continue
            }
            if !request.kinds.isEmpty && !request.kinds.contains(entry.kind) {
                continue
            }
            if !request.classes.isEmpty && !request.classes.contains(entry.memoryClass) {
                continue
            }

            let ref = MemoryRef(
                id: entry.id,
                score: min(max(mergedScores[id] ?? 0.3, 0), 1),
                kind: entry.kind,
                memoryClass: entry.memoryClass,
                source: entry.source,
                createdAt: entry.createdAt
            )
            hits.append(MemoryHit(ref: ref, note: entry.note, summary: entry.summary))
        }

        let returnedHits = Array(hits.prefix(limit))
        let durationMs = memoryElapsedMilliseconds(since: started)
        persistRecallLog(request: request, ids: returnedHits.map { $0.ref.id }, latencyMs: Int(durationMs.rounded()))
        return MemoryRecallResult(hits: returnedHits, durationMs: durationMs, stages: stages)
#else
        stages.append(MemoryRetrievalStage(name: "local_index", durationMs: 0, candidateCount: 0, error: "SQLite is unavailable"))
        return MemoryRecallResult(hits: [], durationMs: memoryElapsedMilliseconds(since: started), stages: stages)
#endif
    }

    public func link(_ edge: MemoryEdgeWriteRequest) async -> Bool {
#if canImport(CSQLite3)
        guard let db else {
            return false
        }

        let sql =
            """
            INSERT OR REPLACE INTO memory_edges(
                id,
                from_memory_id,
                to_memory_id,
                relation,
                weight,
                provenance,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        bindText(UUID().uuidString, at: 1, statement: statement)
        bindText(edge.fromMemoryId, at: 2, statement: statement)
        bindText(edge.toMemoryId, at: 3, statement: statement)
        bindText(edge.relation.rawValue, at: 4, statement: statement)
        sqlite3_bind_double(statement, 5, edge.weight)
        bindOptionalText(edge.provenance, at: 6, statement: statement)
        bindText(isoFormatter.string(from: Date()), at: 7, statement: statement)

        return sqlite3_step(statement) == SQLITE_DONE
#else
        return false
#endif
    }

    public func entries(filter: MemoryEntryFilter) async -> [MemoryEntry] {
#if canImport(CSQLite3)
        let all = listEntries()
        let now = Date()
        let scoped = all.filter { entry in
            if !filter.includeDeleted, entry.deletedAt != nil {
                return false
            }
            if !filter.includeExpired,
               let expiresAt = entry.expiresAt,
               expiresAt < now {
                return false
            }
            if let scope = filter.scope,
               (entry.scope.type != scope.type || entry.scope.id != scope.id) {
                return false
            }
            if !filter.kinds.isEmpty && !filter.kinds.contains(entry.kind) {
                return false
            }
            if !filter.classes.isEmpty && !filter.classes.contains(entry.memoryClass) {
                return false
            }
            return true
        }

        if let limit = filter.limit {
            return Array(scoped.prefix(max(0, limit)))
        }
        return scoped
#else
        return []
#endif
    }

    public func edges(for memoryIDs: [String]) async -> [MemoryEdgeRecord] {
#if canImport(CSQLite3)
        listEdges(for: memoryIDs)
#else
        []
#endif
    }

    public func updateImportance(id: String, importance: Double) async -> Bool {
#if canImport(CSQLite3)
        guard let db else { return false }
        let clamped = min(max(importance, 0), 1)
        let sql = "UPDATE memory_entries SET importance = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, clamped)
        bindText(isoFormatter.string(from: Date()), at: 2, statement: statement)
        bindText(id, at: 3, statement: statement)
        _ = sqlite3_step(statement)
        return sqlite3_changes(db) > 0
#else
        return false
#endif
    }

    public func updateEntry(id: String, note: String?, summary: String?, kind: MemoryKind?, importance: Double?, confidence: Double?) async -> MemoryEntry? {
#if canImport(CSQLite3)
        guard let db else { return nil }
        var setClauses: [String] = []
        let noteChanged = note != nil
        if note != nil { setClauses.append("text = ?") }
        if summary != nil { setClauses.append("summary = ?") }
        if kind != nil { setClauses.append("kind = ?") }
        if importance != nil { setClauses.append("importance = ?") }
        if confidence != nil { setClauses.append("confidence = ?") }
        guard !setClauses.isEmpty else { return nil }
        setClauses.append("updated_at = ?")
        let sql = "UPDATE memory_entries SET \(setClauses.joined(separator: ", ")) WHERE id = ? AND deleted_at IS NULL;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var idx: Int32 = 1
        if let note { bindText(note, at: idx, statement: statement); idx += 1 }
        if let summary { bindText(summary, at: idx, statement: statement); idx += 1 }
        if let kind { bindText(kind.rawValue, at: idx, statement: statement); idx += 1 }
        if let importance { sqlite3_bind_double(statement, idx, min(max(importance, 0), 1)); idx += 1 }
        if let confidence { sqlite3_bind_double(statement, idx, min(max(confidence, 0), 1)); idx += 1 }
        let now = isoFormatter.string(from: Date())
        bindText(now, at: idx, statement: statement); idx += 1
        bindText(id, at: idx, statement: statement)
        _ = sqlite3_step(statement)
        let changed = sqlite3_changes(db)
        sqlite3_finalize(statement)
        guard changed > 0 else { return nil }
        guard let updated = loadEntry(id: id) else { return nil }
        upsertFTS(id: updated.id, note: updated.note, summary: updated.summary)
        await syncProviderUpsert(entry: updated, now: Date())
        if noteChanged, let embeddingService {
            do {
                let vector = try await embeddingService.embed(text: updated.note)
                persistEmbedding(memoryId: updated.id, vector: vector)
            } catch {
                logger.warning("Memory embedding refresh failed for \(updated.id): \(String(describing: error))")
            }
        }
        return updated
#else
        return nil
#endif
    }

    public func softDelete(id: String) async -> Bool {
#if canImport(CSQLite3)
        guard let db else { return false }
        let now = isoFormatter.string(from: Date())
        let sql = "UPDATE memory_entries SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        bindText(now, at: 1, statement: statement)
        bindText(now, at: 2, statement: statement)
        bindText(id, at: 3, statement: statement)
        _ = sqlite3_step(statement)
        let changed = sqlite3_changes(db)
        sqlite3_finalize(statement)
        guard changed > 0 else { return false }
        deleteFTS(id: id)
        deleteEmbedding(memoryId: id)
        enqueueOutbox(memoryId: id, op: "delete", payload: "{}", now: Date())
        if let provider {
            do {
                try await provider.delete(id: id)
                deleteOutboxRows(memoryId: id, op: "delete")
            } catch {
                logger.warning("Memory provider delete failed for \(id): \(String(describing: error))")
            }
        }
        return true
#else
        return false
#endif
    }

    /// Returns true if an embedding vector is stored for the given memory id.
    /// Used internally to verify embedding persistence in tests.
    func hasEmbedding(for memoryId: String) -> Bool {
#if canImport(CSQLite3)
        guard let db else { return false }
        let sql = "SELECT 1 FROM memory_embeddings WHERE memory_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        _ = memoryId.withCString { ptr in
            sqlite3_bind_text(statement, 1, ptr, -1, sqliteTransient)
        }
        return sqlite3_step(statement) == SQLITE_ROW
#else
        return false
#endif
    }

    public func flushOutbox(limit: Int = 50) async -> Int {
#if canImport(CSQLite3)
        let rows = nextOutboxRows(limit: limit)
        guard !rows.isEmpty else {
            return 0
        }

        var processed = 0
        for row in rows {
            guard let provider else {
                break
            }

            do {
                switch row.op {
                case "upsert":
                    let data = Data(row.payloadJSON.utf8)
                    let document = try JSONDecoder().decode(MemoryProviderDocument.self, from: data)
                    try await provider.upsert(document: document)
                case "delete":
                    try await provider.delete(id: row.memoryID)
                default:
                    throw MemoryProviderError.invalidResponse
                }

                deleteOutboxRow(id: row.id)
                processed += 1
            } catch {
                bumpOutboxRetry(id: row.id, attempt: row.attempt + 1, error: String(describing: error))
            }
        }
        return processed
#else
        return 0
#endif
    }
}

// MARK: - Internal helpers (accessible from tests)

extension HybridMemoryStore {
    /// Computes cosine similarity between two float vectors. Returns 0 for empty or mismatched inputs.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

#if canImport(CSQLite3)
    func persistEmbedding(memoryId: String, vector: [Float]) {
        guard let db, !vector.isEmpty else { return }

        let blobData = floatsToData(vector)
        let sql = """
            INSERT OR REPLACE INTO memory_embeddings(memory_id, embedding, model, dimensions, created_at)
            VALUES(?, ?, 'local', ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(memoryId, at: 1, statement: statement)
        _ = blobData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(statement, 2, ptr.baseAddress, Int32(blobData.count), sqliteTransient)
        }
        sqlite3_bind_int(statement, 3, Int32(vector.count))
        bindText(isoFormatter.string(from: Date()), at: 4, statement: statement)
        _ = sqlite3_step(statement)
    }

    func queryCosineMatches(queryVector: [Float], limit: Int, scope: MemoryScope?) -> [(String, Float)] {
        guard let db, !queryVector.isEmpty else { return [] }

        let scopeJoin: String
        let scopeBindings: [String]
        if let scope {
            scopeJoin = """
                INNER JOIN memory_entries me
                    ON me.id = me2.memory_id
                   AND me.deleted_at IS NULL
                   AND (me.expires_at IS NULL OR me.expires_at > ?)
                   AND me.scope_type = ?
                   AND me.scope_id = ?
                """
            scopeBindings = [isoFormatter.string(from: Date()), scope.type.rawValue, scope.id]
        } else {
            scopeJoin = """
                INNER JOIN memory_entries me
                    ON me.id = me2.memory_id
                   AND me.deleted_at IS NULL
                   AND (me.expires_at IS NULL OR me.expires_at > ?)
                """
            scopeBindings = [isoFormatter.string(from: Date())]
        }

        let sql = """
            SELECT me2.memory_id, me2.embedding
            FROM memory_embeddings me2
            \(scopeJoin)
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var idx: Int32 = 1
        for binding in scopeBindings {
            bindText(binding, at: idx, statement: statement)
            idx += 1
        }
        sqlite3_bind_int(statement, idx, Int32(max(1, limit * 4)))

        var results: [(String, Float)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idPtr)
            let blobSize = sqlite3_column_bytes(statement, 1)
            guard blobSize > 0, let blobPtr = sqlite3_column_blob(statement, 1) else { continue }
            let blobData = Data(bytes: blobPtr, count: Int(blobSize))
            let storedVector = dataToFloats(blobData)
            guard !storedVector.isEmpty else { continue }
            let score = Self.cosineSimilarity(queryVector, storedVector)
            results.append((id, score))
        }

        return results
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }
#endif
}

// MARK: - Private SQL helpers

private extension HybridMemoryStore {
    func isRecallVisible(_ entry: MemoryEntry, now: Date) -> Bool {
        if entry.deletedAt != nil {
            return false
        }
        if let expiresAt = entry.expiresAt, expiresAt < now {
            return false
        }
        return true
    }

#if canImport(CSQLite3)
    struct KeywordMatch: Sendable {
        var id: String
        var score: Double
    }

    struct OutboxRow: Sendable {
        var id: String
        var memoryID: String
        var op: String
        var payloadJSON: String
        var attempt: Int
    }

    func syncProviderUpsert(entry: MemoryEntry, now: Date) async {
        let document = MemoryProviderDocument(
            id: entry.id,
            text: entry.note,
            summary: entry.summary,
            kind: entry.kind,
            memoryClass: entry.memoryClass,
            scope: entry.scope,
            source: entry.source,
            metadata: entry.metadata,
            createdAt: entry.createdAt
        )

        if let payload = try? JSONEncoder().encode(document),
           let payloadString = String(data: payload, encoding: .utf8) {
            enqueueOutbox(memoryId: entry.id, op: "upsert", payload: payloadString, now: now)
        }

        if let provider {
            do {
                try await provider.upsert(document: document)
                deleteOutboxRows(memoryId: entry.id, op: "upsert")
            } catch {
                logger.warning("Memory provider upsert refresh failed for \(entry.id): \(String(describing: error))")
            }
        }
    }

    static func applySchema(db: OpaquePointer?) {
        guard let db else {
            return
        }

        let statements = [
            """
            CREATE TABLE IF NOT EXISTS memory_entries (
                id TEXT PRIMARY KEY,
                class TEXT NOT NULL,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                summary TEXT,
                scope_type TEXT NOT NULL,
                scope_id TEXT NOT NULL,
                channel_id TEXT,
                project_id TEXT,
                agent_id TEXT,
                importance REAL NOT NULL DEFAULT 0.5,
                confidence REAL NOT NULL DEFAULT 0.7,
                source_type TEXT,
                source_id TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                expires_at TEXT,
                deleted_at TEXT
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_edges (
                id TEXT PRIMARY KEY,
                from_memory_id TEXT NOT NULL,
                to_memory_id TEXT NOT NULL,
                relation TEXT NOT NULL,
                weight REAL NOT NULL DEFAULT 1.0,
                provenance TEXT,
                created_at TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_provider_outbox (
                id TEXT PRIMARY KEY,
                memory_id TEXT NOT NULL,
                op TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                attempt INTEGER NOT NULL DEFAULT 0,
                next_retry_at TEXT NOT NULL,
                last_error TEXT,
                created_at TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_recall_log (
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                scope_type TEXT,
                scope_id TEXT,
                top_k INTEGER NOT NULL,
                result_ids_json TEXT NOT NULL,
                latency_ms INTEGER NOT NULL,
                created_at TEXT NOT NULL
            );
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(
                id UNINDEXED,
                text,
                summary
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_time ON memory_entries(scope_type, scope_id, created_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_kind ON memory_entries(kind);",
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_class ON memory_entries(class);",
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_expires ON memory_entries(expires_at);",
            "CREATE INDEX IF NOT EXISTS idx_memory_edges_from ON memory_edges(from_memory_id);",
            "CREATE INDEX IF NOT EXISTS idx_memory_edges_to ON memory_edges(to_memory_id);",
            "CREATE INDEX IF NOT EXISTS idx_memory_outbox_retry ON memory_provider_outbox(next_retry_at, attempt);",
            """
            CREATE TABLE IF NOT EXISTS memory_embeddings (
                memory_id TEXT PRIMARY KEY,
                embedding BLOB NOT NULL,
                model TEXT NOT NULL,
                dimensions INTEGER NOT NULL,
                created_at TEXT NOT NULL
            );
            """
        ]

        for statement in statements {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    func persistCanonicalEntry(
        id: String,
        note: String,
        summary: String?,
        kind: MemoryKind,
        memoryClass: MemoryClass,
        scope: MemoryScope,
        source: MemorySource?,
        importance: Double,
        confidence: Double,
        metadata: [String: JSONValue],
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date?,
        deletedAt: Date?
    ) {
        guard let db else {
            return
        }

        let sql =
            """
            INSERT OR REPLACE INTO memory_entries(
                id,
                class,
                kind,
                text,
                summary,
                scope_type,
                scope_id,
                channel_id,
                project_id,
                agent_id,
                importance,
                confidence,
                source_type,
                source_id,
                metadata_json,
                created_at,
                updated_at,
                expires_at,
                deleted_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        bindText(memoryClass.rawValue, at: 2, statement: statement)
        bindText(kind.rawValue, at: 3, statement: statement)
        bindText(note, at: 4, statement: statement)
        bindOptionalText(summary, at: 5, statement: statement)
        bindText(scope.type.rawValue, at: 6, statement: statement)
        bindText(scope.id, at: 7, statement: statement)
        bindOptionalText(scope.channelId, at: 8, statement: statement)
        bindOptionalText(scope.projectId, at: 9, statement: statement)
        bindOptionalText(scope.agentId, at: 10, statement: statement)
        sqlite3_bind_double(statement, 11, importance)
        sqlite3_bind_double(statement, 12, confidence)
        bindOptionalText(source?.type, at: 13, statement: statement)
        bindOptionalText(source?.id, at: 14, statement: statement)
        let metadataString = (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}"
        bindText(metadataString, at: 15, statement: statement)
        bindText(isoFormatter.string(from: createdAt), at: 16, statement: statement)
        bindText(isoFormatter.string(from: updatedAt), at: 17, statement: statement)
        bindOptionalText(expiresAt.map(isoFormatter.string(from:)), at: 18, statement: statement)
        bindOptionalText(deletedAt.map(isoFormatter.string(from:)), at: 19, statement: statement)

        _ = sqlite3_step(statement)

        upsertFTS(id: id, note: note, summary: summary)
    }

    func upsertFTS(id: String, note: String, summary: String?) {
        guard let db else {
            return
        }

        deleteFTS(id: id)

        let insertSQL = "INSERT INTO memory_entries_fts(id, text, summary) VALUES(?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        bindText(note, at: 2, statement: statement)
        bindOptionalText(summary, at: 3, statement: statement)
        _ = sqlite3_step(statement)
    }

    func deleteFTS(id: String) {
        guard let db else {
            return
        }

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memory_entries_fts WHERE id = ?;", -1, &statement, nil) == SQLITE_OK {
            bindText(id, at: 1, statement: statement)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func deleteEmbedding(memoryId: String) {
        guard let db else {
            return
        }

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memory_embeddings WHERE memory_id = ?;", -1, &statement, nil) == SQLITE_OK {
            bindText(memoryId, at: 1, statement: statement)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func dataToFloats(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.stride == 0 else { return [] }
        return data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    }

    func queryKeywordMatches(query: String, limit: Int, scope: MemoryScope?) -> [KeywordMatch] {
        guard db != nil else {
            return []
        }

        let normalizedQuery = normalizedSearchQuery(query)
        guard !normalizedQuery.isEmpty else {
            return []
        }
        let terms = keywordTerms(from: normalizedQuery)

        var ids: [String] = runFTSLookup(query: normalizedQuery, limit: limit)
        if ids.isEmpty, !terms.isEmpty {
            let booleanQuery = terms.joined(separator: " OR ")
            ids = runFTSLookup(query: booleanQuery, limit: limit)
        }
        if ids.isEmpty {
            ids = runLikeFallback(normalizedQuery: normalizedQuery, terms: terms, limit: limit)
        }

        var seen = Set<String>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }

        let now = Date()
        return uniqueIDs.compactMap { id in
            guard let entry = loadEntry(id: id) else {
                return nil
            }
            guard isRecallVisible(entry, now: now) else {
                return nil
            }
            if let scope,
               (entry.scope.type != scope.type || entry.scope.id != scope.id) {
                return nil
            }
            let score = keywordRelevanceScore(entry: entry, normalizedQuery: normalizedQuery, terms: terms)
            guard score > 0 else {
                return nil
            }
            return KeywordMatch(id: id, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    func runFTSLookup(query: String, limit: Int) -> [String] {
        guard let db else {
            return []
        }

        var ids: [String] = []
        let sql = "SELECT id, bm25(memory_entries_fts) FROM memory_entries_fts WHERE memory_entries_fts MATCH ? LIMIT ?;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindText(query, at: 1, statement: statement)
            sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(statement, 0) else {
                    continue
                }
                ids.append(String(cString: idPtr))
            }
        }
        sqlite3_finalize(statement)
        return ids
    }

    func runLikeFallback(normalizedQuery: String, terms: [String], limit: Int) -> [String] {
        guard let db else {
            return []
        }

        let now = isoFormatter.string(from: Date())
        var clauses = ["text LIKE ?", "summary LIKE ?"]
        var bindings = ["%\(normalizedQuery)%", "%\(normalizedQuery)%"]

        for term in terms {
            clauses.append("text LIKE ?")
            bindings.append("%\(term)%")
            clauses.append("summary LIKE ?")
            bindings.append("%\(term)%")
        }

        let whereClause = clauses.joined(separator: " OR ")
        let sql =
            """
            SELECT id
            FROM memory_entries
            WHERE deleted_at IS NULL
              AND (expires_at IS NULL OR expires_at > ?)
              AND (\(whereClause))
            LIMIT ?;
            """

        var ids: [String] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindText(now, at: 1, statement: statement)
            var index: Int32 = 2
            for binding in bindings {
                bindText(binding, at: index, statement: statement)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(max(1, limit)))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(statement, 0) else {
                    continue
                }
                ids.append(String(cString: idPtr))
            }
        }
        sqlite3_finalize(statement)
        return ids
    }

    func normalizedSearchQuery(_ query: String) -> String {
        query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func keywordTerms(from query: String) -> [String] {
        query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    func keywordRelevanceScore(entry: MemoryEntry, normalizedQuery: String, terms: [String]) -> Double {
        let content = (entry.note + " " + (entry.summary ?? "")).lowercased()
        if content.contains(normalizedQuery) {
            return 0.98
        }

        let uniqueTerms = Array(Set(terms))
        guard !uniqueTerms.isEmpty else {
            return 0
        }

        let matchedCount = uniqueTerms.reduce(into: 0) { result, term in
            if content.contains(term) {
                result += 1
            }
        }
        guard matchedCount > 0 else {
            return 0
        }

        let ratio = Double(matchedCount) / Double(uniqueTerms.count)
        return min(0.95, 0.55 + ratio * 0.4)
    }

    func graphExpand(seedIDs: [String], limit: Int) -> [String] {
        guard let db, !seedIDs.isEmpty else {
            return []
        }

        let cappedSeeds = Array(seedIDs.prefix(max(1, limit)))
        let placeholders = Array(repeating: "?", count: cappedSeeds.count).joined(separator: ",")
        let sql =
            """
            SELECT from_memory_id, to_memory_id
            FROM memory_edges
            WHERE from_memory_id IN (\(placeholders)) OR to_memory_id IN (\(placeholders))
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        for id in cappedSeeds {
            bindText(id, at: index, statement: statement)
            index += 1
        }
        for id in cappedSeeds {
            bindText(id, at: index, statement: statement)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(1, limit)))

        var expanded = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let fromPtr = sqlite3_column_text(statement, 0),
                  let toPtr = sqlite3_column_text(statement, 1)
            else {
                continue
            }
            expanded.insert(String(cString: fromPtr))
            expanded.insert(String(cString: toPtr))
        }

        for id in cappedSeeds {
            expanded.remove(id)
        }
        return Array(expanded)
    }

    func loadEntry(id: String) -> MemoryEntry? {
        guard let db else {
            return nil
        }

        let sql =
            """
            SELECT
                id,
                text,
                summary,
                kind,
                class,
                scope_type,
                scope_id,
                channel_id,
                project_id,
                agent_id,
                importance,
                confidence,
                source_type,
                source_id,
                metadata_json,
                created_at,
                updated_at,
                expires_at,
                deleted_at
            FROM memory_entries
            WHERE id = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return decodeEntry(statement: statement)
    }

    func listEntries() -> [MemoryEntry] {
        guard let db else {
            return []
        }

        let sql =
            """
            SELECT
                id,
                text,
                summary,
                kind,
                class,
                scope_type,
                scope_id,
                channel_id,
                project_id,
                agent_id,
                importance,
                confidence,
                source_type,
                source_id,
                metadata_json,
                created_at,
                updated_at,
                expires_at,
                deleted_at
            FROM memory_entries
            ORDER BY created_at DESC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [MemoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = decodeEntry(statement: statement) {
                result.append(entry)
            }
        }
        return result
    }

    func listEdges(for memoryIDs: [String]) -> [MemoryEdgeRecord] {
        guard let db else {
            return []
        }

        let ids = Array(Set(memoryIDs)).sorted()
        guard !ids.isEmpty else {
            return []
        }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql =
            """
            SELECT
                from_memory_id,
                to_memory_id,
                relation,
                weight,
                provenance,
                created_at
            FROM memory_edges
            WHERE from_memory_id IN (\(placeholders)) OR to_memory_id IN (\(placeholders))
            ORDER BY created_at DESC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        for id in ids {
            bindText(id, at: index, statement: statement)
            index += 1
        }
        for id in ids {
            bindText(id, at: index, statement: statement)
            index += 1
        }

        var result: [MemoryEdgeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let fromPtr = sqlite3_column_text(statement, 0),
                  let toPtr = sqlite3_column_text(statement, 1),
                  let relationPtr = sqlite3_column_text(statement, 2),
                  let createdAtPtr = sqlite3_column_text(statement, 5)
            else {
                continue
            }

            let relation = MemoryEdgeRelation(rawValue: String(cString: relationPtr)) ?? .about
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            result.append(
                MemoryEdgeRecord(
                    fromMemoryId: String(cString: fromPtr),
                    toMemoryId: String(cString: toPtr),
                    relation: relation,
                    weight: sqlite3_column_double(statement, 3),
                    provenance: optionalText(statement: statement, index: 4),
                    createdAt: createdAt
                )
            )
        }

        return result
    }

    func decodeEntry(statement: OpaquePointer?) -> MemoryEntry? {
        guard let statement,
              let idPtr = sqlite3_column_text(statement, 0),
              let notePtr = sqlite3_column_text(statement, 1),
              let kindPtr = sqlite3_column_text(statement, 3),
              let classPtr = sqlite3_column_text(statement, 4),
              let scopeTypePtr = sqlite3_column_text(statement, 5),
              let scopeIDPtr = sqlite3_column_text(statement, 6),
              let createdAtPtr = sqlite3_column_text(statement, 15),
              let updatedAtPtr = sqlite3_column_text(statement, 16)
        else {
            return nil
        }

        let summary = optionalText(statement: statement, index: 2)
        let kind = MemoryKind(rawValue: String(cString: kindPtr)) ?? .fact
        let memoryClass = MemoryClass(rawValue: String(cString: classPtr)) ?? .semantic
        let scope = MemoryScope(
            type: MemoryScopeType(rawValue: String(cString: scopeTypePtr)) ?? .global,
            id: String(cString: scopeIDPtr),
            channelId: optionalText(statement: statement, index: 7),
            projectId: optionalText(statement: statement, index: 8),
            agentId: optionalText(statement: statement, index: 9)
        )
        let importance = sqlite3_column_double(statement, 10)
        let confidence = sqlite3_column_double(statement, 11)

        let sourceType = optionalText(statement: statement, index: 12)
        let sourceID = optionalText(statement: statement, index: 13)
        let source: MemorySource?
        if let sourceType {
            source = MemorySource(type: sourceType, id: sourceID)
        } else {
            source = nil
        }

        let metadataJSON = optionalText(statement: statement, index: 14) ?? "{}"
        let metadataData = Data(metadataJSON.utf8)
        let metadata = (try? JSONDecoder().decode([String: JSONValue].self, from: metadataData)) ?? [:]

        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
        let expiresAt = optionalText(statement: statement, index: 17).flatMap(isoFormatter.date(from:))
        let deletedAt = optionalText(statement: statement, index: 18).flatMap(isoFormatter.date(from:))

        return MemoryEntry(
            id: String(cString: idPtr),
            note: String(cString: notePtr),
            summary: summary,
            kind: kind,
            memoryClass: memoryClass,
            scope: scope,
            source: source,
            importance: importance,
            confidence: confidence,
            metadata: metadata,
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            deletedAt: deletedAt
        )
    }

    func enqueueOutbox(memoryId: String, op: String, payload: String, now: Date) {
        guard let db else {
            return
        }

        let sql =
            """
            INSERT INTO memory_provider_outbox(
                id,
                memory_id,
                op,
                payload_json,
                attempt,
                next_retry_at,
                last_error,
                created_at
            ) VALUES(?, ?, ?, ?, 0, ?, NULL, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(UUID().uuidString, at: 1, statement: statement)
        bindText(memoryId, at: 2, statement: statement)
        bindText(op, at: 3, statement: statement)
        bindText(payload, at: 4, statement: statement)
        bindText(isoFormatter.string(from: now), at: 5, statement: statement)
        bindText(isoFormatter.string(from: now), at: 6, statement: statement)

        _ = sqlite3_step(statement)
    }

    func nextOutboxRows(limit: Int) -> [OutboxRow] {
        guard let db else {
            return []
        }

        let sql =
            """
            SELECT id, memory_id, op, payload_json, attempt
            FROM memory_provider_outbox
            WHERE next_retry_at <= ?
            ORDER BY created_at ASC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bindText(isoFormatter.string(from: Date()), at: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var rows: [OutboxRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0),
                  let memoryIDPtr = sqlite3_column_text(statement, 1),
                  let opPtr = sqlite3_column_text(statement, 2),
                  let payloadPtr = sqlite3_column_text(statement, 3)
            else {
                continue
            }

            rows.append(
                OutboxRow(
                    id: String(cString: idPtr),
                    memoryID: String(cString: memoryIDPtr),
                    op: String(cString: opPtr),
                    payloadJSON: String(cString: payloadPtr),
                    attempt: Int(sqlite3_column_int(statement, 4))
                )
            )
        }

        return rows
    }

    func deleteOutboxRows(memoryId: String, op: String) {
        guard let db else {
            return
        }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memory_provider_outbox WHERE memory_id = ? AND op = ?;", -1, &statement, nil) == SQLITE_OK {
            bindText(memoryId, at: 1, statement: statement)
            bindText(op, at: 2, statement: statement)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func deleteOutboxRow(id: String) {
        guard let db else {
            return
        }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memory_provider_outbox WHERE id = ?;", -1, &statement, nil) == SQLITE_OK {
            bindText(id, at: 1, statement: statement)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func bumpOutboxRetry(id: String, attempt: Int, error: String) {
        guard let db else {
            return
        }

        let backoffSeconds = min(300, max(5, Int(pow(2.0, Double(attempt)))))
        let next = Date().addingTimeInterval(TimeInterval(backoffSeconds))

        let sql =
            """
            UPDATE memory_provider_outbox
            SET attempt = ?, next_retry_at = ?, last_error = ?
            WHERE id = ?;
            """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(attempt))
            bindText(isoFormatter.string(from: next), at: 2, statement: statement)
            bindText(error, at: 3, statement: statement)
            bindText(id, at: 4, statement: statement)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func persistRecallLog(request: MemoryRecallRequest, ids: [String], latencyMs: Int) {
        guard let db else {
            return
        }

        let sql =
            """
            INSERT INTO memory_recall_log(
                id,
                query,
                scope_type,
                scope_id,
                top_k,
                result_ids_json,
                latency_ms,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        let resultIDs = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
        bindText(UUID().uuidString, at: 1, statement: statement)
        bindText(request.query, at: 2, statement: statement)
        bindOptionalText(request.scope?.type.rawValue, at: 3, statement: statement)
        bindOptionalText(request.scope?.id, at: 4, statement: statement)
        sqlite3_bind_int(statement, 5, Int32(request.limit))
        bindText(resultIDs, at: 6, statement: statement)
        sqlite3_bind_int64(statement, 7, Int64(max(0, latencyMs)))
        bindText(isoFormatter.string(from: Date()), at: 8, statement: statement)

        _ = sqlite3_step(statement)
    }

    func bindText(_ value: String, at index: Int32, statement: OpaquePointer?) {
        _ = value.withCString { ptr in
            sqlite3_bind_text(statement, index, ptr, -1, sqliteTransient)
        }
    }

    func bindOptionalText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            bindText(value, at: index, statement: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func optionalText(statement: OpaquePointer?, index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: ptr)
    }
#endif

    func inferredKind(note: String) -> MemoryKind {
        let normalized = note.lowercased()
        if normalized.hasPrefix("[todo]") {
            return .todo
        }
        if normalized.hasPrefix("[bulletin]") {
            return .event
        }
        if normalized.contains("prefer") {
            return .preference
        }
        if normalized.contains("decision") || normalized.contains("decided") {
            return .decision
        }
        if normalized.contains("goal") {
            return .goal
        }
        if normalized.contains("identity") {
            return .identity
        }
        if normalized.contains("observ") {
            return .observation
        }
        return .fact
    }

    func defaultClass(for kind: MemoryKind) -> MemoryClass {
        switch kind {
        case .identity, .preference, .fact:
            return .semantic
        case .goal, .decision, .todo:
            return .procedural
        case .event, .observation:
            return .episodic
        }
    }

    func resolveExpiry(
        explicit: Date?,
        kind: MemoryKind,
        memoryClass: MemoryClass,
        metadata: [String: JSONValue],
        now: Date
    ) -> Date? {
        if let explicit {
            return explicit
        }

        if memoryClass == .bulletin {
            return Calendar.current.date(byAdding: .day, value: retention.bulletinDays, to: now)
        }
        if memoryClass == .episodic {
            return Calendar.current.date(byAdding: .day, value: retention.episodicDays, to: now)
        }
        if kind == .todo,
           let status = metadata["status"]?.asString?.lowercased(),
           ["done", "completed", "cancelled", "canceled"].contains(status) {
            return Calendar.current.date(byAdding: .day, value: retention.todoCompletedDays, to: now)
        }

        return nil
    }

    func normalize(_ value: Double) -> Double {
        if value.isNaN || value.isInfinite {
            return 0
        }
        return min(max(value, 0), 1)
    }
}
