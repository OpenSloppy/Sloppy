import Foundation
import Protocols

public enum MemoryQuerySource: String, Codable, Sendable {
    case bootstrap
    case automatic
    case toolSearch = "memory.search"
    case toolRecall = "memory.recall"
}

public struct MemoryRetrievalStage: Codable, Sendable {
    public var name: String
    public var durationMs: Double
    public var candidateCount: Int
    public var error: String?

    public init(name: String, durationMs: Double, candidateCount: Int, error: String? = nil) {
        self.name = name
        self.durationMs = durationMs
        self.candidateCount = candidateCount
        self.error = error
    }
}

public struct MemoryRecallResult: Sendable {
    public var hits: [MemoryHit]
    public var durationMs: Double
    public var stages: [MemoryRetrievalStage]

    public init(hits: [MemoryHit], durationMs: Double, stages: [MemoryRetrievalStage] = []) {
        self.hits = hits
        self.durationMs = durationMs
        self.stages = stages
    }
}

public func memoryElapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return max(0, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
}

public struct MemoryQueryDiagnostic: Codable, Sendable {
    public var id: String
    public var recordedAt: Date
    public var channelId: String
    public var operationId: String?
    public var source: MemoryQuerySource
    public var query: String
    public var queryCharacters: Int
    public var scope: MemoryScope?
    public var kinds: [MemoryKind]
    public var classes: [MemoryClass]
    public var limit: Int
    public var durationMs: Double
    public var resultCount: Int
    public var resultCharacters: Int
    public var estimatedResultTokens: Int
    public var hits: [MemoryHit]
    public var truncated: Bool
    public var stages: [MemoryRetrievalStage]
}

public struct MemoryInjectionDiagnostic: Codable, Sendable {
    public var operationId: String
    public var durationMs: Double
    public var hitIds: [String]
    public var content: String
    public var characters: Int
    public var estimatedTokens: Int
}

public struct ModelContextEntryDiagnostic: Codable, Sendable {
    public var id: String
    public var kind: String
    public var content: String
    public var characters: Int
    public var estimatedTokens: Int
    public var truncated: Bool
}

/// The input at the start of a runtime model turn, after context preparation.
/// Provider-specific serialization and subsequent internal tool-loop requests are not captured.
public struct ModelContextDiagnostic: Codable, Sendable {
    public var recordedAt: Date
    public var model: String
    public var entries: [ModelContextEntryDiagnostic]
    public var entryCount: Int
    public var characters: Int
    public var estimatedTokens: Int
    public var imageCount: Int
    public var toolNames: [String]
    public var truncated: Bool
    public var memoryInjection: MemoryInjectionDiagnostic?
}

public struct MemoryDiagnosticsSnapshot: Codable, Sendable {
    public var collectionStartedAt: Date
    public var retentionLimit: Int
    public var queries: [MemoryQueryDiagnostic]
    public var modelContext: ModelContextDiagnostic?
}

/// Process-local, bounded diagnostics. Reading debug state never runs retrieval.
public actor MemoryDiagnostics {
    private let collectionStartedAt = Date()
    private let retentionLimit: Int
    private var queries: [MemoryQueryDiagnostic] = []
    private var contexts: [(channelId: String, context: ModelContextDiagnostic)] = []

    public init(retentionLimit: Int = 200) {
        self.retentionLimit = max(1, retentionLimit)
    }

    public func record(
        request: MemoryRecallRequest, result: MemoryRecallResult,
        channelId: String, source: MemoryQuerySource, operationId: String? = nil
    ) {
        let resultCharacters = result.hits.reduce(0) { $0 + $1.note.count + ($1.summary?.count ?? 0) }
        let estimatedTokens = result.hits.reduce(0) {
            $0 + TokenPressureEstimator().estimateTextTokens($1.note + "\n" + ($1.summary ?? ""))
        }
        let hits = result.hits.prefix(100).map {
            MemoryHit(ref: $0.ref, note: String($0.note.prefix(1000)), summary: $0.summary.map { String($0.prefix(500)) })
        }
        queries.append(MemoryQueryDiagnostic(
            id: UUID().uuidString, recordedAt: Date(), channelId: channelId, operationId: operationId,
            source: source, query: String(request.query.prefix(8000)), queryCharacters: request.query.count,
            scope: request.scope, kinds: request.kinds, classes: request.classes,
            limit: request.limit, durationMs: result.durationMs,
            resultCount: result.hits.count, resultCharacters: resultCharacters, estimatedResultTokens: estimatedTokens,
            hits: hits, truncated: request.query.count > 8000 || result.hits.count > 100
                || result.hits.contains { $0.note.count > 1000 || ($0.summary?.count ?? 0) > 500 },
            stages: result.stages
        ))
        if queries.count > retentionLimit { queries.removeFirst(queries.count - retentionLimit) }
    }

    public func recordContext(channelId: String, context: ModelContextDiagnostic) {
        contexts.removeAll { $0.channelId == channelId }
        contexts.append((channelId, context))
        if contexts.count > 16 { contexts.removeFirst(contexts.count - 16) }
    }

    public func snapshot(channelId: String) -> MemoryDiagnosticsSnapshot {
        MemoryDiagnosticsSnapshot(
            collectionStartedAt: collectionStartedAt, retentionLimit: retentionLimit,
            queries: queries.filter { $0.channelId == channelId }.reversed(),
            modelContext: contexts.last { $0.channelId == channelId }?.context
        )
    }

    public func remove(channelId: String) {
        queries.removeAll { $0.channelId == channelId }
        contexts.removeAll { $0.channelId == channelId }
    }
}
