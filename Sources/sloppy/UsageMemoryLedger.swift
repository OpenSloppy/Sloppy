import Foundation
import Protocols

/// Equivalent behavior for injected in-memory stores and SQLite-unavailable platforms.
actor UsageMemoryLedger {
    private let startedAt = Date()
    private var requests: [String: UsageRequestRecord] = [:]
    private var calls: [String: UsageToolCallRecord] = [:]
    private var seenInputs: Set<String> = []
    @discardableResult func persist(_ input: UsageRequestRecord) -> Bool {
        guard requests[input.id] == nil else { return false }
        var record = input
        let priorInputs = seenInputs
        for index in record.components.indices {
            let component = record.components[index]
            if [.argumentsInput, .resultInput].contains(component.kind), let call = component.toolCallId {
                let key = UsageCallCursor.encode(.init(id:call,requestId:"",channelId:record.channelId,tool:"")) + ":" + component.kind.rawValue
                record.components[index].repeated = component.repeated || priorInputs.contains(key)
                seenInputs.insert(key)
            }
        }
        for call in record.calls {
            let key = UsageCallCursor.encode(call)
            if var old = calls[key] {
                old.ok = call.ok ?? old.ok; old.skillId = call.skillId ?? old.skillId; calls[key] = old
            } else if call.generated { calls[key] = call }
        }
        requests[record.id] = record
        return true
    }
    func outcome(channelId: String, callId: String, ok: Bool) { calls[UsageCallCursor.encode(.init(id:callId,requestId:"",channelId:channelId,tool:""))]?.ok = ok }
    func breakdown(_ query: UsageBreakdownQuery) throws -> UsageBreakdownResponse {
        let records = requests.values.filter { r in
            (query.from.map { r.createdAt >= $0 } ?? true) && (query.to.map { r.createdAt <= $0 } ?? true)
                && (query.channelId == nil || r.channelId == query.channelId)
                && (query.sessionId == nil || r.sessionId == query.sessionId)
                && (query.provider == nil || r.provider == query.provider)
                && (query.model == nil || r.model == query.model)
                && (query.serverId == nil || r.components.contains { $0.serverId == query.serverId } || r.calls.contains { $0.serverId == query.serverId })
        }
        let ids = Set(records.map(\.id))
        let selectedCalls = calls.values.filter { ids.contains($0.requestId) && (query.serverId == nil || $0.serverId == query.serverId) }
        var groups: [String: UsageBreakdownGroup] = [:]
        func key(tool: String?, server: String?, skill: String?) -> String? {
            query.groupBy == "skill" ? skill : query.groupBy == "server" ? server : tool
        }
        for call in selectedCalls {
            guard let id = key(tool: call.tool, server: call.serverId, skill: call.skillId) else { continue }
            var group = groups[id] ?? .init(id: id)
            group.calls += 1; group.failures += call.ok == false ? 1 : 0; groups[id] = group
        }
        for record in records {
            for c in record.components where query.serverId == nil || c.serverId == query.serverId {
                guard let id = key(tool: c.tool, server: c.serverId, skill: c.skillId) else { continue }
                var group = groups[id] ?? .init(id: id)
                switch c.method {
                case .tokenizer: group.tokenizerMeasurements += 1
                case .estimate: group.estimatedMeasurements += 1
                case .unavailable: group.unavailableMeasurements += 1
                }
                let n = c.tokens ?? 0
                switch c.kind {
                case .argumentsOutput: group.argumentsTokens += n
                case .argumentsInput: group.replayTokens += n // Generated once, subsequently charged as input.
                case .resultInput: if c.repeated { group.replayTokens += n } else { group.resultTokens += n }
                case .toolSchema: group.schemaTokens += n
                case .skillCatalog: group.catalogTokens += n
                }
                groups[id] = group
            }
        }
        let cursor = query.cursor.flatMap(UsageCallCursor.decode)
        if query.cursor != nil && cursor == nil { throw UsageStoreError.invalidCursor }
        let filteredCalls = selectedCalls.filter { query.groupId == nil || key(tool: $0.tool, server: $0.serverId, skill: $0.skillId) == query.groupId }
            .sorted { $0.channelId == $1.channelId ? $0.id < $1.id : $0.channelId < $1.channelId }
            .filter { call in cursor.map { call.channelId > $0.channel || (call.channelId == $0.channel && call.id > $0.call) } ?? true }
        var page = Array(filteredCalls.prefix(query.limit))
        for index in page.indices {
            for record in records where record.channelId == page[index].channelId {
                for c in record.components where c.toolCallId == page[index].id {
                    switch c.kind {
                    case .argumentsOutput: page[index].argumentsTokens += c.tokens ?? 0
                    case .resultInput: if c.repeated { page[index].replayTokens += c.tokens ?? 0 } else { page[index].resultTokens += c.tokens ?? 0 }
                    case .argumentsInput: page[index].replayTokens += c.tokens ?? 0
                    default: break
                    }
                    switch c.method {
                    case .tokenizer: page[index].tokenizerMeasurements += 1
                    case .estimate: page[index].estimatedMeasurements += 1
                    case .unavailable: page[index].unavailableMeasurements += 1
                    }
                }
            }
        }
        var total = TokenUsage(prompt: 0, completion: 0)
        for r in records { if let u = r.usage { total.prompt += u.prompt; total.completion += u.completion; total.cachedInput += u.cachedInput; total.cacheCreationInput += u.cacheCreationInput; total.reasoning += u.reasoning } }
        return .init(collectionStartedAt: startedAt, requestCount: records.count,
            reportedRequestCount: records.filter { $0.usage != nil }.count,
            completeRequestCount: records.filter(\.complete).count, providerUsage: total,
            groups: groups.values.sorted { $0.totalTokens == $1.totalTokens ? $0.id < $1.id : $0.totalTokens > $1.totalTokens },
            calls: page, nextCursor: filteredCalls.count > page.count ? page.last.map(UsageCallCursor.encode) : nil)
    }
}

extension InMemoryPersistenceStore {
    public func persistUsageRequest(_ record: UsageRequestRecord) async throws {
        if await usageMemoryLedger.persist(record), let usage = record.usage {
            await persistTokenUsage(channelId: record.channelId, taskId: nil, usage: usage)
        }
    }
    public func usageBreakdown(_ query: UsageBreakdownQuery) async throws -> UsageBreakdownResponse { try await usageMemoryLedger.breakdown(query) }
    public func updateUsageToolOutcome(channelId: String, callId: String, ok: Bool) async throws { await usageMemoryLedger.outcome(channelId: channelId, callId: callId, ok: ok) }
}

extension PersistenceStore {
    public func persistUsageRequest(_ record: UsageRequestRecord) async throws { throw UsageStoreError.database("Usage storage is unsupported") }
    public func usageBreakdown(_ query: UsageBreakdownQuery) async throws -> UsageBreakdownResponse { throw UsageStoreError.database("Usage storage is unsupported") }
    public func updateUsageToolOutcome(channelId: String, callId: String, ok: Bool) async throws {}
}
