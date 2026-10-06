import Foundation
import Protocols
#if canImport(CSQLite3)
import CSQLite3
private let usageTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

enum UsageStoreError: Error { case database(String), invalidCursor }

enum UsageCallCursor {
    static func encode(_ call: UsageToolCallRecord) -> String {
        // JSON preserves opaque IDs, including separators and prefix-related channel names.
        let data = (try? JSONEncoder().encode([call.channelId, call.id])) ?? Data()
        return data.base64EncodedString()
    }
    static func decode(_ value: String) -> (channel: String, call: String)? {
        guard value.count <= 8192, let data = Data(base64Encoded: value),
              let parts = try? JSONDecoder().decode([String].self, from: data), parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

extension SQLiteStore {
    public func persistUsageRequest(_ record: UsageRequestRecord) async throws {
#if canImport(CSQLite3)
        guard db != nil else { await usageMemoryLedger.persist(record); return }
        try usageExecute("BEGIN IMMEDIATE")
        do {
            let u = record.usage
            try usageExecute("""
                INSERT OR IGNORE INTO usage_requests VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [record.id, record.channelId, record.sessionId, record.agentId, record.provider, record.model,
                       usageDate(record.createdAt), u.map { String($0.prompt) }, u.map { String($0.completion) },
                       u.map { String($0.cachedInput) }, u.map { String($0.cacheCreationInput) }, u.map { String($0.reasoning) },
                       record.failed ? "1" : "0", record.complete ? "1" : "0"])
            guard let db, sqlite3_changes(db) > 0 else { try usageExecute("COMMIT"); return }
            for call in record.calls {
                if call.generated {
                    try usageExecute("""
                        INSERT INTO usage_calls VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(channel_id, id) DO UPDATE SET ok=COALESCE(excluded.ok,usage_calls.ok),
                        skill_id=COALESCE(excluded.skill_id,usage_calls.skill_id)
                        """, [call.id, call.channelId, call.requestId, call.sessionId, call.agentId, call.tool,
                               call.serverId, call.skillId, call.ok.map { $0 ? "1" : "0" }, usageDate(call.createdAt)])
                } else {
                    try usageExecute("UPDATE usage_calls SET ok=COALESCE(?,ok),skill_id=COALESCE(?,skill_id) WHERE channel_id=? AND id=?",
                        [call.ok.map { $0 ? "1" : "0" }, call.skillId, call.channelId, call.id])
                }
            }
            for c in record.components {
                var repeated = c.repeated
                if [.argumentsInput, .resultInput].contains(c.kind), let callId = c.toolCallId {
                    let seen = !(try usageRows("SELECT 1 FROM usage_components WHERE channel_id=? AND tool_call_id=? AND kind=? AND request_id<>? LIMIT 1",
                        [record.channelId, callId, c.kind.rawValue, record.id])).isEmpty
                    repeated = repeated || seen
                }
                try usageExecute("INSERT OR IGNORE INTO usage_components VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [c.id, record.id, record.channelId, c.toolCallId, c.tool, c.serverId, c.skillId, c.kind.rawValue,
                     c.tokens.map(String.init), c.method.rawValue, c.encoding, repeated ? "1" : "0"])
            }
            if let u {
                try usageExecute("""
                    INSERT OR IGNORE INTO token_usage
                    (id,channel_id,task_id,prompt_tokens,completion_tokens,total_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_tokens,created_at)
                    VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)
                    """, ["usage:" + record.id, record.channelId, String(u.prompt), String(u.completion), String(u.total),
                           String(u.cachedInput), String(u.cacheCreationInput), String(u.reasoning), isoFormatter.string(from: record.createdAt)])
            }
            try usageExecute("COMMIT")
        } catch { try? usageExecute("ROLLBACK"); throw error }
#else
        await usageMemoryLedger.persist(record)
#endif
    }

    public func updateUsageToolOutcome(channelId: String, callId: String, ok: Bool) async throws {
#if canImport(CSQLite3)
        guard db != nil else { await usageMemoryLedger.outcome(channelId: channelId, callId: callId, ok: ok); return }
        try usageExecute("UPDATE usage_calls SET ok=? WHERE channel_id=? AND id=?", [ok ? "1" : "0", channelId, callId])
#else
        await usageMemoryLedger.outcome(channelId: channelId, callId: callId, ok: ok)
#endif
    }

    public func usageBreakdown(_ q: UsageBreakdownQuery) async throws -> UsageBreakdownResponse {
#if canImport(CSQLite3)
        guard db != nil else { return try await usageMemoryLedger.breakdown(q) }
        var conditions = ["1=1"], values: [String?] = []
        for (column, value) in [("channel_id",q.channelId),("session_id",q.sessionId),("provider",q.provider),("model",q.model)] {
            if let value { conditions.append("r.\(column)=?"); values.append(value) }
        }
        if let date = q.from { conditions.append("r.created_at>=?"); values.append(usageDate(date)) }
        if let date = q.to { conditions.append("r.created_at<=?"); values.append(usageDate(date)) }
        if let server = q.serverId {
            conditions.append("(EXISTS(SELECT 1 FROM usage_components sc WHERE sc.request_id=r.id AND sc.server_id=?) OR EXISTS(SELECT 1 FROM usage_calls st WHERE st.request_id=r.id AND st.server_id=?))")
            values += [server, server]
        }
        let predicate = conditions.joined(separator: " AND ")
        let total = try usageRows("""
            SELECT COUNT(*),SUM(prompt_tokens IS NOT NULL),SUM(complete),COALESCE(SUM(prompt_tokens),0),
            COALESCE(SUM(completion_tokens),0),COALESCE(SUM(cached_tokens),0),COALESCE(SUM(cache_creation_tokens),0),
            COALESCE(SUM(reasoning_tokens),0) FROM usage_requests r WHERE \(predicate)
            """, values).first ?? []
        func n(_ row: [String?], _ index: Int) -> Int { index < row.count ? Int(row[index] ?? "0") ?? 0 : 0 }
        let column = q.groupBy == "skill" ? "skill_id" : q.groupBy == "server" ? "server_id" : "tool"
        let serverPredicate = q.serverId == nil ? "" : " AND c.server_id=?"
        let componentValues = values + (q.serverId.map { [$0] } ?? [])
        var groups: [String: UsageBreakdownGroup] = [:]
        let rows = try usageRows("""
            SELECT c.\(column),
            SUM(CASE WHEN c.kind='argumentsOutput' THEN COALESCE(c.tokens,0) ELSE 0 END),
            SUM(CASE WHEN c.kind='resultInput' AND c.repeated=0 THEN COALESCE(c.tokens,0) ELSE 0 END),
            SUM(CASE WHEN c.kind='argumentsInput' OR (c.kind='resultInput' AND c.repeated=1) THEN COALESCE(c.tokens,0) ELSE 0 END),
            SUM(CASE WHEN c.kind='toolSchema' THEN COALESCE(c.tokens,0) ELSE 0 END),
            SUM(CASE WHEN c.kind='skillCatalog' THEN COALESCE(c.tokens,0) ELSE 0 END),
            SUM(c.method='tokenizer'),SUM(c.method='estimate'),SUM(c.method='unavailable')
            FROM usage_components c JOIN usage_requests r ON r.id=c.request_id
            WHERE \(predicate) AND c.\(column) IS NOT NULL \(serverPredicate) GROUP BY c.\(column)
            """, componentValues)
        for row in rows {
            guard let id = row[0] else { continue }
            var group = UsageBreakdownGroup(id: id)
            group.argumentsTokens=n(row,1); group.resultTokens=n(row,2); group.replayTokens=n(row,3)
            group.schemaTokens=n(row,4); group.catalogTokens=n(row,5); group.tokenizerMeasurements=n(row,6)
            group.estimatedMeasurements=n(row,7); group.unavailableMeasurements=n(row,8); groups[id]=group
        }
        for row in try usageRows("""
            SELECT c.\(column),COUNT(*),SUM(c.ok=0) FROM usage_calls c JOIN usage_requests r ON r.id=c.request_id
            WHERE \(predicate) AND c.\(column) IS NOT NULL \(serverPredicate) GROUP BY c.\(column)
            """, componentValues) {
            guard let id = row[0] else { continue }
            var group = groups[id] ?? .init(id: id); group.calls=n(row,1); group.failures=n(row,2); groups[id]=group
        }
        var callPredicate = predicate + serverPredicate, callValues = componentValues
        if let id = q.groupId { callPredicate += " AND c.\(column)=?"; callValues.append(id) }
        if let cursor = q.cursor {
            guard let key = UsageCallCursor.decode(cursor) else { throw UsageStoreError.invalidCursor }
            callPredicate += " AND (c.channel_id,c.id)>(?,?)"
            callValues += [key.channel, key.call]
        }
        callValues.append(String(q.limit + 1))
        let callRows = try usageRows("""
            SELECT c.id,c.request_id,c.channel_id,c.session_id,c.agent_id,c.tool,c.server_id,c.skill_id,c.ok,c.created_at
            FROM usage_calls c JOIN usage_requests r ON r.id=c.request_id
            WHERE \(callPredicate) ORDER BY c.channel_id,c.id LIMIT ?
            """, callValues)
        var calls: [UsageToolCallRecord] = callRows.prefix(q.limit).compactMap { row in
            guard let id=row[0],let request=row[1],let channel=row[2],let tool=row[5],let date=row[9] else { return nil }
            return .init(id:id,requestId:request,channelId:channel,sessionId:row[3],agentId:row[4],tool:tool,
                serverId:row[6],skillId:row[7],ok:row[8].map { $0 == "1" },createdAt:usageParseDate(date) ?? Date())
        }
        if !calls.isEmpty {
            let keys = calls.map { [$0.channelId, $0.id] }
            let pairPredicate = calls.map { _ in "(c.channel_id=? AND c.tool_call_id=?)" }.joined(separator: " OR ")
            let details = try usageRows("""
                SELECT c.channel_id,c.tool_call_id,
                SUM(CASE WHEN c.kind='argumentsOutput' THEN COALESCE(c.tokens,0) ELSE 0 END),
                SUM(CASE WHEN c.kind='resultInput' AND c.repeated=0 THEN COALESCE(c.tokens,0) ELSE 0 END),
                SUM(CASE WHEN c.kind='argumentsInput' OR (c.kind='resultInput' AND c.repeated=1) THEN COALESCE(c.tokens,0) ELSE 0 END),
                SUM(c.method='tokenizer'),SUM(c.method='estimate'),SUM(c.method='unavailable')
                FROM usage_components c JOIN usage_requests r ON r.id=c.request_id
                WHERE \(predicate) \(serverPredicate) AND (\(pairPredicate))
                GROUP BY c.channel_id,c.tool_call_id
                """, componentValues + keys.flatMap { $0.map { Optional($0) } })
            let byKey = Dictionary(uniqueKeysWithValues: details.compactMap { row -> (String,[String?])? in guard let channel = row[0], let call = row[1] else { return nil }; return (UsageCallCursor.encode(.init(id:call,requestId:"",channelId:channel,tool:"")),row) })
            for index in calls.indices {
                guard let row = byKey[UsageCallCursor.encode(calls[index])] else { continue }
                calls[index].argumentsTokens=n(row,2); calls[index].resultTokens=n(row,3); calls[index].replayTokens=n(row,4)
                calls[index].tokenizerMeasurements=n(row,5); calls[index].estimatedMeasurements=n(row,6); calls[index].unavailableMeasurements=n(row,7)
            }
        }
        let started = try usageRows("SELECT started_at FROM usage_collection WHERE id=1").first?.first.flatMap { $0 }.flatMap { isoFormatter.date(from:$0) }
        return .init(collectionStartedAt:started,requestCount:n(total,0),reportedRequestCount:n(total,1),completeRequestCount:n(total,2),
            providerUsage:.init(prompt:n(total,3),completion:n(total,4),cachedInputTokens:n(total,5),cacheCreationInputTokens:n(total,6),reasoningTokens:n(total,7)),
            groups:groups.values.sorted { $0.totalTokens == $1.totalTokens ? $0.id < $1.id : $0.totalTokens > $1.totalTokens },
            calls:calls,nextCursor:callRows.count > q.limit ? calls.last.map(UsageCallCursor.encode) : nil)
#else
        return try await usageMemoryLedger.breakdown(q)
#endif
    }
    private func usageDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private func usageParseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? isoFormatter.date(from: text)
    }
#if canImport(CSQLite3)
    private func usageExecute(_ sql: String, _ values: [String?] = []) throws { _ = try usageRows(sql, values) }
    private func usageRows(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        guard let db else { throw UsageStoreError.database("Database unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else { throw UsageStoreError.database(String(cString:sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (index,value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement,Int32(index+1),value,-1,usageTransient) }
            else { sqlite3_bind_null(statement,Int32(index+1)) }
        }
        var rows: [[String?]] = []
        while true {
            let result=sqlite3_step(statement)
            if result==SQLITE_DONE { return rows }
            guard result==SQLITE_ROW else { throw UsageStoreError.database(String(cString:sqlite3_errmsg(db))) }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_type(statement,index)==SQLITE_NULL ? nil : sqlite3_column_text(statement,index).map { String(cString:$0) }
            })
        }
    }
#endif
}
