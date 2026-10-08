import Foundation
import Protocols

public struct MemoryEntry: Codable, Sendable, Equatable {
    public var id: String
    public var note: String
    public var summary: String?
    public var kind: MemoryKind
    public var memoryClass: MemoryClass
    public var scope: MemoryScope
    public var source: MemorySource?
    public var importance: Double
    public var confidence: Double
    public var metadata: [String: JSONValue]
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date?
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        note: String,
        summary: String? = nil,
        kind: MemoryKind = .fact,
        memoryClass: MemoryClass = .semantic,
        scope: MemoryScope = .default,
        source: MemorySource? = nil,
        importance: Double = 0.5,
        confidence: Double = 0.7,
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.note = note
        self.summary = summary
        self.kind = kind
        self.memoryClass = memoryClass
        self.scope = scope
        self.source = source
        self.importance = importance
        self.confidence = confidence
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.deletedAt = deletedAt
    }
}

public protocol MemoryStore: Sendable {
    /// Retrieves matching memory hits for a structured query.
    func recall(request: MemoryRecallRequest) async -> [MemoryHit]
    /// Measures retrieval, with optional backend stage details.
    func recallWithDiagnostics(request: MemoryRecallRequest) async -> MemoryRecallResult
    /// Stores memory entry and returns reference.
    func save(entry: MemoryWriteRequest) async -> MemoryRef
    /// Persists one typed relationship between memory entries.
    func link(_ edge: MemoryEdgeWriteRequest) async -> Bool
    /// Returns memory entries using structured filters.
    func entries(filter: MemoryEntryFilter) async -> [MemoryEntry]
    /// Returns edges touching any of the given memory ids.
    func edges(for memoryIDs: [String]) async -> [MemoryEdgeRecord]
    /// Updates the importance score of a memory entry. Returns true on success.
    func updateImportance(id: String, importance: Double) async -> Bool
    /// Updates mutable fields of a memory entry. Returns the updated entry on success.
    func updateEntry(id: String, note: String?, summary: String?, kind: MemoryKind?, importance: Double?, confidence: Double?) async -> MemoryEntry?
    /// Soft-deletes a memory entry by setting deletedAt. Returns true on success.
    func softDelete(id: String) async -> Bool
}

public extension MemoryStore {
    func recallWithDiagnostics(request: MemoryRecallRequest) async -> MemoryRecallResult {
        let start = ContinuousClock.now
        let hits = await recall(request: request)
        return MemoryRecallResult(hits: hits, durationMs: memoryElapsedMilliseconds(since: start))
    }

    func recallDiagnosed(
        request: MemoryRecallRequest, channelId: String, source: MemoryQuerySource,
        diagnostics: MemoryDiagnostics, operationId: String? = nil
    ) async -> [MemoryHit] {
        let result = await recallWithDiagnostics(request: request)
        await diagnostics.record(request: request, result: result, channelId: channelId, source: source, operationId: operationId)
        return result.hits
    }

    /// Backward-compatible recall API.
    func recall(query: String, limit: Int) async -> [MemoryRef] {
        await recall(request: MemoryRecallRequest(query: query, limit: limit)).map(\.ref)
    }

    /// Backward-compatible save API.
    func save(note: String) async -> MemoryRef {
        await save(entry: MemoryWriteRequest(note: note))
    }

    /// Backward-compatible listing API.
    func entries() async -> [MemoryEntry] {
        await entries(filter: .default)
    }

    func edges(for memoryIDs: [String]) async -> [MemoryEdgeRecord] {
        []
    }

    func updateImportance(id: String, importance: Double) async -> Bool {
        false
    }

    func updateEntry(id: String, note: String?, summary: String?, kind: MemoryKind?, importance: Double?, confidence: Double?) async -> MemoryEntry? {
        nil
    }

    func softDelete(id: String) async -> Bool {
        false
    }
}

private struct StoredEdge: Sendable, Equatable {
    var fromMemoryId: String
    var toMemoryId: String
    var relation: MemoryEdgeRelation
    var weight: Double
    var provenance: String?
    var createdAt: Date
}

public actor InMemoryMemoryStore: MemoryStore {
    private var storage: [MemoryEntry] = []
    private var byID: [String: MemoryEntry] = [:]
    private var edges: [StoredEdge] = []

    public init() {}

    /// Performs in-memory relevance scoring and returns top matches.
    public func recall(request: MemoryRecallRequest) async -> [MemoryHit] {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = query.lowercased()

        let now = Date()
        let filtered = storage.filter { entry in
            if entry.deletedAt != nil {
                return false
            }
            if let expiresAt = entry.expiresAt, expiresAt < now {
                return false
            }
            if let scope = request.scope,
               (entry.scope.type != scope.type || entry.scope.id != scope.id) {
                return false
            }
            if !request.kinds.isEmpty && !request.kinds.contains(entry.kind) {
                return false
            }
            if !request.classes.isEmpty && !request.classes.contains(entry.memoryClass) {
                return false
            }
            return true
        }

        let scored = filtered.map { entry -> (MemoryEntry, Double) in
            let text = entry.note.lowercased()
            let summary = (entry.summary ?? "").lowercased()
            let content = text + " " + summary

            let exactBoost = content.contains(normalizedQuery) ? 0.55 : 0.0
            let tokenBoost = tokenOverlapScore(query: normalizedQuery, content: content) * 0.30
            let recencyBoost = recencyScore(createdAt: entry.createdAt) * 0.10
            let importanceBoost = min(max(entry.importance, 0), 1) * 0.03
            let confidenceBoost = min(max(entry.confidence, 0), 1) * 0.02
            return (entry, exactBoost + tokenBoost + recencyBoost + importanceBoost + confidenceBoost)
        }

        let boundedLimit = max(1, request.limit)
        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.1 > rhs.1
            }
            .prefix(boundedLimit)
            .map { entry, score in
                let ref = MemoryRef(
                    id: entry.id,
                    score: min(max(score, 0), 1),
                    kind: entry.kind,
                    memoryClass: entry.memoryClass,
                    source: entry.source,
                    createdAt: entry.createdAt
                )
                return MemoryHit(ref: ref, note: entry.note, summary: entry.summary)
            }
    }

    /// Appends one memory entry into in-memory store.
    public func save(entry: MemoryWriteRequest) async -> MemoryRef {
        let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKind = entry.kind ?? inferredKind(from: note)
        let resolvedClass = entry.memoryClass ?? Self.defaultClass(for: resolvedKind)
        let scope = entry.scope ?? .default
        let importance = min(max(entry.importance ?? 0.5, 0), 1)
        let confidence = min(max(entry.confidence ?? 0.7, 0), 1)

        let now = Date()
        let memoryEntry = MemoryEntry(
            note: note,
            summary: entry.summary,
            kind: resolvedKind,
            memoryClass: resolvedClass,
            scope: scope,
            source: entry.source,
            importance: importance,
            confidence: confidence,
            metadata: entry.metadata,
            createdAt: entry.updatedAt ?? now,
            updatedAt: entry.updatedAt ?? now,
            expiresAt: entry.expiresAt
        )

        storage.append(memoryEntry)
        byID[memoryEntry.id] = memoryEntry

        return MemoryRef(
            id: memoryEntry.id,
            score: 1.0,
            kind: memoryEntry.kind,
            memoryClass: memoryEntry.memoryClass,
            source: memoryEntry.source,
            createdAt: memoryEntry.createdAt
        )
    }

    public func link(_ edge: MemoryEdgeWriteRequest) async -> Bool {
        guard byID[edge.fromMemoryId] != nil, byID[edge.toMemoryId] != nil else {
            return false
        }

        if edges.contains(where: {
            $0.fromMemoryId == edge.fromMemoryId &&
                $0.toMemoryId == edge.toMemoryId &&
                $0.relation == edge.relation
        }) {
            return true
        }

        edges.append(
            StoredEdge(
                fromMemoryId: edge.fromMemoryId,
                toMemoryId: edge.toMemoryId,
                relation: edge.relation,
                weight: edge.weight,
                provenance: edge.provenance,
                createdAt: Date()
            )
        )
        return true
    }

    public func edges(for memoryIDs: [String]) async -> [MemoryEdgeRecord] {
        let ids = Set(memoryIDs)
        guard !ids.isEmpty else {
            return []
        }

        return edges.compactMap { edge in
            guard ids.contains(edge.fromMemoryId) || ids.contains(edge.toMemoryId) else {
                return nil
            }

            return MemoryEdgeRecord(
                fromMemoryId: edge.fromMemoryId,
                toMemoryId: edge.toMemoryId,
                relation: edge.relation,
                weight: edge.weight,
                provenance: edge.provenance,
                createdAt: edge.createdAt
            )
        }
    }

    /// Lists all in-memory entries using structured filters.
    public func entries(filter: MemoryEntryFilter) async -> [MemoryEntry] {
        let now = Date()
        var result = storage.filter { entry in
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

        result.sort { $0.createdAt > $1.createdAt }
        if let limit = filter.limit {
            return Array(result.prefix(max(0, limit)))
        }
        return result
    }

    public func updateImportance(id: String, importance: Double) async -> Bool {
        guard var entry = byID[id] else { return false }
        entry.importance = min(max(importance, 0), 1)
        entry.updatedAt = Date()
        byID[id] = entry
        if let index = storage.firstIndex(where: { $0.id == id }) {
            storage[index] = entry
        }
        return true
    }

    public func updateEntry(id: String, note: String?, summary: String?, kind: MemoryKind?, importance: Double?, confidence: Double?) async -> MemoryEntry? {
        guard var entry = byID[id], entry.deletedAt == nil else { return nil }
        if let note { entry.note = note }
        if let summary { entry.summary = summary }
        if let kind { entry.kind = kind }
        if let importance { entry.importance = min(max(importance, 0), 1) }
        if let confidence { entry.confidence = min(max(confidence, 0), 1) }
        entry.updatedAt = Date()
        byID[id] = entry
        if let index = storage.firstIndex(where: { $0.id == id }) {
            storage[index] = entry
        }
        return entry
    }

    public func softDelete(id: String) async -> Bool {
        guard var entry = byID[id] else { return false }
        guard entry.deletedAt == nil else { return true }
        entry.deletedAt = Date()
        entry.updatedAt = Date()
        byID[id] = entry
        if let index = storage.firstIndex(where: { $0.id == id }) {
            storage[index] = entry
        }
        return true
    }

    private static func defaultClass(for kind: MemoryKind) -> MemoryClass {
        switch kind {
        case .identity, .preference, .fact:
            return .semantic
        case .goal, .decision, .todo:
            return .procedural
        case .event, .observation:
            return .episodic
        }
    }

    private func inferredKind(from note: String) -> MemoryKind {
        let normalized = note.lowercased()
        if normalized.hasPrefix("[todo]") {
            return .todo
        }
        if normalized.hasPrefix("[bulletin]") {
            return .event
        }
        if normalized.contains("decided") || normalized.contains("decision") {
            return .decision
        }
        if normalized.contains("prefer") {
            return .preference
        }
        if normalized.contains("goal") {
            return .goal
        }
        return .fact
    }

    private func tokenOverlapScore(query: String, content: String) -> Double {
        let queryTokens = Set(query.split(whereSeparator: \.isWhitespace).map { String($0) }.filter { !$0.isEmpty })
        if queryTokens.isEmpty {
            return 0
        }

        let contentTokens = Set(content.split(whereSeparator: \.isWhitespace).map { String($0) }.filter { !$0.isEmpty })
        let overlap = queryTokens.intersection(contentTokens).count
        return Double(overlap) / Double(max(1, queryTokens.count))
    }

    private func recencyScore(createdAt: Date) -> Double {
        let age = Date().timeIntervalSince(createdAt)
        switch age {
        case ..<3_600:
            return 1.0
        case ..<86_400:
            return 0.7
        case ..<604_800:
            return 0.45
        default:
            return 0.2
        }
    }
}
