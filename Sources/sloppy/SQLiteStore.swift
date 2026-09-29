import Foundation
import Protocols

#if canImport(CSQLite3)
import CSQLite3
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// SQLite-backed persistence store.
/// This backend works when the package `CSQLite3` system module can import `sqlite3`,
/// otherwise the actor automatically falls back to in-memory storage.
public actor SQLiteStore: PersistenceStore {
    private var fallbackProactiveStates: [String: Data] = [:]

    public func loadProactiveState(agentId: String) async throws -> Data? {
#if canImport(CSQLite3)
        guard let db else { return fallbackProactiveStates[agentId] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM agent_proactive_state WHERE agent_id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw ProactivePersistenceError.database
        }
        defer { sqlite3_finalize(statement) }
        bindText(agentId, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ProactivePersistenceError.database }
        return Data(String(cString: text).utf8)
#else
        return fallbackProactiveStates[agentId]
#endif
    }

    public func saveProactiveState(agentId: String, data: Data) async throws {
#if canImport(CSQLite3)
        guard let db else { fallbackProactiveStates[agentId] = data; return }
        guard let payload = String(data: data, encoding: .utf8) else { throw ProactivePersistenceError.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO agent_proactive_state (agent_id, payload) VALUES (?, ?) ON CONFLICT(agent_id) DO UPDATE SET payload = excluded.payload", -1, &statement, nil) == SQLITE_OK else {
            throw ProactivePersistenceError.database
        }
        defer { sqlite3_finalize(statement) }
        bindText(agentId, at: 1, statement: statement)
        bindText(payload, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProactivePersistenceError.database }
#else
        fallbackProactiveStates[agentId] = data
#endif
    }
#if canImport(CSQLite3)
    private var db: OpaquePointer?
#endif
    private let isoFormatter = ISO8601DateFormatter()
    private let fallbackProjectsFileURL: URL

    private var fallbackEvents: [EventEnvelope] = []
    private var fallbackSemanticDecisionUsages: [SemanticDecisionUsageRecord] = []
    private var fallbackBulletins: [MemoryBulletin] = []
    private var fallbackArtifacts: [String: PersistedArtifactRecord] = [:]
    private var fallbackPublishedSites: [String: PersistedPublishedSiteRecord] = [:]
    private var fallbackChannels: [String: PersistedChannelRecord] = [:]
    private var fallbackTasks: [String: PersistedTaskRecord] = [:]
    private var fallbackProjects: [String: ProjectRecord] = [:]
    private var fallbackWorkspaces: [String: WorkspaceRecord] = [:]
    private var fallbackWorkspaceDocuments: [String: WorkspaceDocument] = [:]
    private var fallbackWorkspaceTransactions: [String: [WorkspaceCommittedTransaction]] = [:]
    private var fallbackWorkspaceMembers: [String: [WorkspaceMember]] = [:]
    private var fallbackWorkspaceTemplates: [String: WorkspaceTemplate] = [:]
    private var fallbackPlugins: [String: ChannelPluginRecord] = [:]
    private var fallbackAgentPlugins: [String: InstalledAgentPlugin] = [:]
    private var fallbackAgentPluginRegistries: [String: AgentPluginRegistry] = [:]
    private var fallbackCronTasks: [String: AgentCronTask] = [:]
    private var fallbackAccessUsers: [String: ChannelAccessUser] = [:]
    private var fallbackSelfImprovementProposalReviewJobs: [String: SelfImprovementProposalReviewJob] = [:]
    private var fallbackAutodreamSessionReviews: [String: AutodreamSessionReviewRecord] = [:]
    private var fallbackWorkflowRuns: [String: WorkflowRun] = [:]
    private var fallbackWorkflowRunSteps: [String: WorkflowRunStep] = [:]
    private var fallbackWorkflowPendingActions: [String: WorkflowPendingAction] = [:]
    private var fallbackAutomationRuns: [String: AutomationRun] = [:]
    private var fallbackProjectInitiatives: [String: InitiativeRecord] = [:]
    private var fallbackDecisionPacketsByID: [String: DecisionPacketRecord] = [:]

    /// Creates a persistence store and applies schema when SQLite is available.
    public init(path: String, schemaSQL: String, fallbackProjectsPath: String? = nil) {
        fallbackProjectsFileURL = Self.resolveFallbackProjectsFileURL(
            sqlitePath: path,
            explicitPath: fallbackProjectsPath
        )
        fallbackProjects = Self.loadFallbackProjects(from: fallbackProjectsFileURL)
#if canImport(CSQLite3)
        self.db = Self.openDatabase(path: path, schemaSQL: schemaSQL).0
#endif
    }

    @discardableResult
    static func prepareDatabase(path: String, schemaSQL: String) -> String? {
#if canImport(CSQLite3)
        let (db, error) = openDatabase(path: path, schemaSQL: schemaSQL)
        if let db {
            sqlite3_close(db)
            return nil
        }
        return error ?? "Unknown SQLite initialization error"
#else
        return "SQLite3 is not available on this platform"
#endif
    }

    /// Persists runtime event envelope.
    public func persist(event: EventEnvelope) async {
#if canImport(CSQLite3)
        guard let db else {
            persistFallbackEvent(event)
            return
        }

        let sql =
            """
            INSERT INTO events(
                id,
                message_type,
                channel_id,
                task_id,
                branch_id,
                worker_id,
                payload_json,
                extensions_json,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            persistFallbackEvent(event)
            return
        }
        defer { sqlite3_finalize(statement) }

        let payloadData = try? JSONEncoder().encode(event.payload)
        let payloadString = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let extensionsData = try? JSONEncoder().encode(event.extensions)
        let extensionsString = extensionsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        bindText(event.messageId, at: 1, statement: statement)
        bindText(event.messageType.rawValue, at: 2, statement: statement)
        bindText(event.channelId, at: 3, statement: statement)
        bindOptionalText(event.taskId, at: 4, statement: statement)
        bindOptionalText(event.branchId, at: 5, statement: statement)
        bindOptionalText(event.workerId, at: 6, statement: statement)
        bindText(payloadString, at: 7, statement: statement)
        bindText(extensionsString, at: 8, statement: statement)
        bindText(isoFormatter.string(from: event.ts), at: 9, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            persistFallbackEvent(event)
            return
        }

        upsertChannel(db: db, channelId: event.channelId, timestamp: event.ts)
        upsertTask(db: db, event: event)
#else
        persistFallbackEvent(event)
#endif
    }

    /// Persists prompt/completion token usage metrics.
    public func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async {
#if canImport(CSQLite3)
        guard let db else { return }

        let sql =
            """
            INSERT INTO token_usage(
                id,
                channel_id,
                task_id,
                prompt_tokens,
                completion_tokens,
                total_tokens,
                cached_input_tokens,
                cache_creation_input_tokens,
                reasoning_tokens,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(UUID().uuidString, at: 1, statement: statement)
        bindText(channelId, at: 2, statement: statement)
        bindOptionalText(taskId, at: 3, statement: statement)
        sqlite3_bind_int(statement, 4, Int32(usage.prompt))
        sqlite3_bind_int(statement, 5, Int32(usage.completion))
        sqlite3_bind_int(statement, 6, Int32(usage.total))
        sqlite3_bind_int(statement, 7, Int32(usage.cachedInput))
        sqlite3_bind_int(statement, 8, Int32(usage.cacheCreationInput))
        sqlite3_bind_int(statement, 9, Int32(usage.reasoning))
        bindText(isoFormatter.string(from: Date()), at: 10, statement: statement)

        _ = sqlite3_step(statement)
#endif
    }

    /// Lists token usage records with optional filters.
    public func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> [TokenUsageRecord] {
#if canImport(CSQLite3)
        guard let db else { return [] }

        var conditions: [String] = []
        if channelId != nil { conditions.append("channel_id = ?") }
        if taskId != nil { conditions.append("task_id = ?") }
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql =
            """
            SELECT id, channel_id, task_id, prompt_tokens, completion_tokens, total_tokens,
                   cached_input_tokens, cache_creation_input_tokens, reasoning_tokens, created_at
            FROM token_usage
            \(whereClause)
            ORDER BY created_at DESC
            LIMIT 1000;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        if let channelId {
            bindText(channelId, at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let taskId {
            bindOptionalText(taskId, at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let from {
            bindText(isoFormatter.string(from: from), at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: paramIndex, statement: statement)
        }

        var result: [TokenUsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let channelIdPtr = sqlite3_column_text(statement, 1),
                let createdAtPtr = sqlite3_column_text(statement, 9)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let recordChannelId = String(cString: channelIdPtr)
            let taskId = optionalText(statement: statement, index: 2)
            let promptTokens = Int(sqlite3_column_int(statement, 3))
            let completionTokens = Int(sqlite3_column_int(statement, 4))
            let totalTokens = Int(sqlite3_column_int(statement, 5))
            let cachedInputTokens = Int(sqlite3_column_int(statement, 6))
            let cacheCreationInputTokens = Int(sqlite3_column_int(statement, 7))
            let reasoningTokens = Int(sqlite3_column_int(statement, 8))
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()

            result.append(
                TokenUsageRecord(
                    id: id,
                    channelId: recordChannelId,
                    taskId: taskId,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: totalTokens,
                    cachedInputTokens: cachedInputTokens,
                    cacheCreationInputTokens: cacheCreationInputTokens,
                    reasoningTokens: reasoningTokens,
                    createdAt: createdAt
                )
            )
        }

        return result
#else
        return []
#endif
    }

    public func listTokenUsage(channelIds: [String], from: Date?, to: Date?) async -> [TokenUsageRecord] {
#if canImport(CSQLite3)
        guard let db else { return [] }
        guard !channelIds.isEmpty else { return [] }

        var conditions: [String] = []
        let placeholders = channelIds.map { _ in "?" }.joined(separator: ", ")
        conditions.append("channel_id IN (\(placeholders))")
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")

        let sql =
            """
            SELECT id, channel_id, task_id, prompt_tokens, completion_tokens, total_tokens,
                   cached_input_tokens, cache_creation_input_tokens, reasoning_tokens, created_at
            FROM token_usage
            \(whereClause)
            ORDER BY created_at DESC
            LIMIT 2000;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        for id in channelIds {
            bindText(id, at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let from {
            bindText(isoFormatter.string(from: from), at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: paramIndex, statement: statement)
        }

        var result: [TokenUsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let channelIdPtr = sqlite3_column_text(statement, 1),
                let createdAtPtr = sqlite3_column_text(statement, 9)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let recordChannelId = String(cString: channelIdPtr)
            let taskId = optionalText(statement: statement, index: 2)
            let promptTokens = Int(sqlite3_column_int(statement, 3))
            let completionTokens = Int(sqlite3_column_int(statement, 4))
            let totalTokens = Int(sqlite3_column_int(statement, 5))
            let cachedInputTokens = Int(sqlite3_column_int(statement, 6))
            let cacheCreationInputTokens = Int(sqlite3_column_int(statement, 7))
            let reasoningTokens = Int(sqlite3_column_int(statement, 8))
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()

            result.append(
                TokenUsageRecord(
                    id: id,
                    channelId: recordChannelId,
                    taskId: taskId,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: totalTokens,
                    cachedInputTokens: cachedInputTokens,
                    cacheCreationInputTokens: cacheCreationInputTokens,
                    reasoningTokens: reasoningTokens,
                    createdAt: createdAt
                )
            )
        }

        return result
#else
        return []
#endif
    }

    public func persistSemanticDecisionUsage(record: SemanticDecisionUsageRecord) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackSemanticDecisionUsages.append(record)
            return
        }
        let sql = """
            INSERT INTO semantic_decision_usage(
                id, channel_id, input_tokens, output_tokens, cost_usd, cost_is_estimated, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackSemanticDecisionUsages.append(record)
            return
        }
        defer { sqlite3_finalize(statement) }
        bindText(record.id, at: 1, statement: statement)
        bindText(record.channelId, at: 2, statement: statement)
        sqlite3_bind_int64(statement, 3, Int64(record.inputTokens))
        sqlite3_bind_int64(statement, 4, Int64(record.outputTokens))
        sqlite3_bind_double(statement, 5, record.costUSD)
        sqlite3_bind_int(statement, 6, record.costIsEstimated ? 1 : 0)
        bindText(isoFormatter.string(from: record.createdAt), at: 7, statement: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackSemanticDecisionUsages.append(record)
        }
#else
        fallbackSemanticDecisionUsages.append(record)
#endif
    }

    public func listSemanticDecisionUsage(channelId: String?, from: Date?, to: Date?) async -> [SemanticDecisionUsageRecord] {
        let fallback = fallbackSemanticDecisionUsages.filter { record in
            if let channelId, record.channelId != channelId { return false }
            if let from, record.createdAt < from { return false }
            if let to, record.createdAt > to { return false }
            return true
        }
#if canImport(CSQLite3)
        guard let db else { return fallback }
        var conditions: [String] = []
        if channelId != nil { conditions.append("channel_id = ?") }
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, channel_id, input_tokens, output_tokens, cost_usd, cost_is_estimated, created_at
            FROM semantic_decision_usage
            \(whereClause)
            ORDER BY created_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return fallback }
        defer { sqlite3_finalize(statement) }
        var parameterIndex: Int32 = 1
        if let channelId {
            bindText(channelId, at: parameterIndex, statement: statement)
            parameterIndex += 1
        }
        if let from {
            bindText(isoFormatter.string(from: from), at: parameterIndex, statement: statement)
            parameterIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: parameterIndex, statement: statement)
        }
        var records = fallback
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let channelPointer = sqlite3_column_text(statement, 1),
                  let datePointer = sqlite3_column_text(statement, 6),
                  let createdAt = isoFormatter.date(from: String(cString: datePointer))
            else { continue }
            records.append(SemanticDecisionUsageRecord(
                id: String(cString: idPointer),
                channelId: String(cString: channelPointer),
                inputTokens: Int(sqlite3_column_int64(statement, 2)),
                outputTokens: Int(sqlite3_column_int64(statement, 3)),
                costUSD: sqlite3_column_double(statement, 4),
                costIsEstimated: sqlite3_column_int(statement, 5) != 0,
                createdAt: createdAt
            ))
        }
        return records
#else
        return fallback
#endif
    }

    public func persistToolInvocation(
        id: String,
        projectId: String?,
        taskId: String?,
        agentId: String,
        sessionId: String,
        tool: String,
        ok: Bool,
        durationMs: Int?,
        traceId: String?,
        createdAt: Date
    ) async {
#if canImport(CSQLite3)
        guard let db else { return }

        let sql =
            """
            INSERT INTO tool_invocations(
                id,
                project_id,
                task_id,
                agent_id,
                session_id,
                tool,
                ok,
                duration_ms,
                trace_id,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        bindOptionalText(projectId, at: 2, statement: statement)
        bindOptionalText(taskId, at: 3, statement: statement)
        bindText(agentId, at: 4, statement: statement)
        bindText(sessionId, at: 5, statement: statement)
        bindText(tool, at: 6, statement: statement)
        sqlite3_bind_int(statement, 7, ok ? 1 : 0)
        if let durationMs {
            sqlite3_bind_int(statement, 8, Int32(durationMs))
        } else {
            sqlite3_bind_null(statement, 8)
        }
        bindOptionalText(traceId, at: 9, statement: statement)
        bindText(isoFormatter.string(from: createdAt), at: 10, statement: statement)

        _ = sqlite3_step(statement)
#endif
    }

    public func persistProjectEventFact(
        id: String,
        projectId: String,
        channelId: String,
        messageType: String,
        traceId: String?,
        createdAt: Date
    ) async {
#if canImport(CSQLite3)
        guard let db else { return }

        let sql =
            """
            INSERT INTO project_event_facts(
                id,
                project_id,
                channel_id,
                message_type,
                trace_id,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        bindText(projectId, at: 2, statement: statement)
        bindText(channelId, at: 3, statement: statement)
        bindText(messageType, at: 4, statement: statement)
        bindOptionalText(traceId, at: 5, statement: statement)
        bindText(isoFormatter.string(from: createdAt), at: 6, statement: statement)

        _ = sqlite3_step(statement)
#endif
    }

    public func listProjectEventCounts(projectId: String, from: Date?, to: Date?) async -> [String: Int] {
#if canImport(CSQLite3)
        guard let db else { return [:] }

        var conditions: [String] = ["project_id = ?"]
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")

        let sql =
            """
            SELECT message_type, COUNT(*)
            FROM project_event_facts
            \(whereClause)
            GROUP BY message_type;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        bindText(projectId, at: paramIndex, statement: statement)
        paramIndex += 1
        if let from {
            bindText(isoFormatter.string(from: from), at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: paramIndex, statement: statement)
        }

        var result: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typePtr = sqlite3_column_text(statement, 0) else { continue }
            let type = String(cString: typePtr)
            let count = Int(sqlite3_column_int(statement, 1))
            result[type] = count
        }
        return result
#else
        return [:]
#endif
    }

    public func listToolInvocationAggregates(projectId: String, from: Date?, to: Date?) async -> [PersistedToolInvocationAggregate] {
#if canImport(CSQLite3)
        guard let db else { return [] }

        var conditions: [String] = ["project_id = ?"]
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")

        let sql =
            """
            SELECT tool,
                   COUNT(*) AS calls,
                   SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END) AS failures,
                   COALESCE(SUM(COALESCE(duration_ms, 0)), 0) AS total_duration
            FROM tool_invocations
            \(whereClause)
            GROUP BY tool;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        bindText(projectId, at: paramIndex, statement: statement)
        paramIndex += 1
        if let from {
            bindText(isoFormatter.string(from: from), at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: paramIndex, statement: statement)
        }

        var result: [PersistedToolInvocationAggregate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let toolPtr = sqlite3_column_text(statement, 0) else { continue }
            let tool = String(cString: toolPtr)
            let calls = Int(sqlite3_column_int(statement, 1))
            let failures = Int(sqlite3_column_int(statement, 2))
            let totalDuration = Int(sqlite3_column_int(statement, 3))
            result.append(.init(tool: tool, calls: calls, failures: failures, totalDurationMs: totalDuration))
        }
        return result
#else
        return []
#endif
    }

    public func listToolInvocations(projectId: String?, taskId: String?, limit: Int) async -> [PersistedToolInvocationRecord] {
#if canImport(CSQLite3)
        guard let db else { return [] }

        var conditions: [String] = []
        if projectId != nil { conditions.append("project_id = ?") }
        if taskId != nil { conditions.append("task_id = ?") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let clampedLimit = max(1, min(limit, 500))

        let sql =
            """
            SELECT id, project_id, task_id, agent_id, session_id, tool, ok, duration_ms, trace_id, created_at
            FROM tool_invocations
            \(whereClause)
            ORDER BY created_at DESC
            LIMIT \(clampedLimit);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        if let projectId {
            bindText(projectId, at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let taskId {
            bindText(taskId, at: paramIndex, statement: statement)
        }

        var result: [PersistedToolInvocationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0),
                  let agentPtr = sqlite3_column_text(statement, 3),
                  let sessionPtr = sqlite3_column_text(statement, 4),
                  let toolPtr = sqlite3_column_text(statement, 5),
                  let createdAtPtr = sqlite3_column_text(statement, 9)
            else { continue }

            let durationMs: Int?
            if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                durationMs = nil
            } else {
                durationMs = Int(sqlite3_column_int(statement, 7))
            }

            result.append(PersistedToolInvocationRecord(
                id: String(cString: idPtr),
                projectId: sqlite3_column_text(statement, 1).map { String(cString: $0) },
                taskId: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                agentId: String(cString: agentPtr),
                sessionId: String(cString: sessionPtr),
                tool: String(cString: toolPtr),
                ok: sqlite3_column_int(statement, 6) != 0,
                durationMs: durationMs,
                traceId: sqlite3_column_text(statement, 8).map { String(cString: $0) },
                createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            ))
        }
        return result
#else
        return []
#endif
    }

    public func upsertSelfImprovementProposalReviewJob(
        agentId: String,
        sessionId: String,
        projectId: String,
        reason: String,
        reviewContext: String?,
        nextRunAt: Date
    ) async -> SelfImprovementProposalReviewJob {
        let now = Date()
#if canImport(CSQLite3)
        guard let db else {
            return upsertFallbackSelfImprovementProposalReviewJob(
                agentId: agentId,
                sessionId: sessionId,
                projectId: projectId,
                reason: reason,
                reviewContext: reviewContext,
                nextRunAt: nextRunAt,
                now: now
            )
        }
        if var existing = loadSelfImprovementProposalReviewJob(
            db: db,
            agentId: agentId,
            sessionId: sessionId,
            reason: reason
        ) {
            existing.projectId = projectId
            existing.reviewContext = reviewContext
            existing.status = "pending"
            existing.nextRunAt = nextRunAt
            existing.lastError = nil
            existing.updatedAt = now
            await saveSelfImprovementProposalReviewJob(existing)
            return existing
        }
#endif
        let job = SelfImprovementProposalReviewJob(
            id: UUID().uuidString.lowercased(),
            agentId: agentId,
            sessionId: sessionId,
            projectId: projectId,
            reason: reason,
            reviewContext: reviewContext,
            nextRunAt: nextRunAt,
            createdAt: now,
            updatedAt: now
        )
        await saveSelfImprovementProposalReviewJob(job)
        return job
    }

    public func listSelfImprovementProposalReviewJobs(statuses: [String]?) async -> [SelfImprovementProposalReviewJob] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackSelfImprovementProposalReviewJobs(statuses: statuses)
        }
        var sql =
            """
            SELECT id, agent_id, session_id, project_id, reason, review_context, status, attempts, next_run_at, last_error, created_at, updated_at
            FROM self_improvement_proposal_review_queue
            """
        if let statuses, !statuses.isEmpty {
            sql += " WHERE status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ",")))"
        }
        sql += " ORDER BY created_at ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let statuses {
            for (index, status) in statuses.enumerated() {
                bindText(status, at: Int32(index + 1), statement: statement)
            }
        }
        var jobs: [SelfImprovementProposalReviewJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let job = decodeSelfImprovementProposalReviewJob(statement: statement) {
                jobs.append(job)
            }
        }
        return jobs
#else
        return fallbackSelfImprovementProposalReviewJobs(statuses: statuses)
#endif
    }

    public func claimNextSelfImprovementProposalReviewJob(now: Date) async -> SelfImprovementProposalReviewJob? {
#if canImport(CSQLite3)
        guard let db else {
            return claimFallbackSelfImprovementProposalReviewJob(now: now)
        }
        let sql =
            """
            SELECT id, agent_id, session_id, project_id, reason, review_context, status, attempts, next_run_at, last_error, created_at, updated_at
            FROM self_improvement_proposal_review_queue
            WHERE status = 'pending' AND next_run_at <= ?
            ORDER BY next_run_at ASC, created_at ASC
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(isoFormatter.string(from: now), at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              var job = decodeSelfImprovementProposalReviewJob(statement: statement)
        else { return nil }
        job.status = "running"
        job.updatedAt = now
        await saveSelfImprovementProposalReviewJob(job)
        return job
#else
        return claimFallbackSelfImprovementProposalReviewJob(now: now)
#endif
    }

    public func saveSelfImprovementProposalReviewJob(_ job: SelfImprovementProposalReviewJob) async {
        fallbackSelfImprovementProposalReviewJobs[job.id] = job
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO self_improvement_proposal_review_queue(
                id, agent_id, session_id, project_id, reason, review_context, status, attempts, next_run_at, last_error, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(job.id, at: 1, statement: statement)
        bindText(job.agentId, at: 2, statement: statement)
        bindText(job.sessionId, at: 3, statement: statement)
        bindText(job.projectId, at: 4, statement: statement)
        bindText(job.reason, at: 5, statement: statement)
        bindOptionalText(job.reviewContext, at: 6, statement: statement)
        bindText(job.status, at: 7, statement: statement)
        sqlite3_bind_int(statement, 8, Int32(job.attempts))
        bindText(isoFormatter.string(from: job.nextRunAt), at: 9, statement: statement)
        bindOptionalText(job.lastError, at: 10, statement: statement)
        bindText(isoFormatter.string(from: job.createdAt), at: 11, statement: statement)
        bindText(isoFormatter.string(from: job.updatedAt), at: 12, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func autodreamSessionReview(agentId: String, sessionId: String) async -> AutodreamSessionReviewRecord? {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackAutodreamSessionReviews[autodreamSessionReviewKey(agentId: agentId, sessionId: sessionId)]
        }
        let sql =
            """
            SELECT agent_id, session_id, status, reason, session_updated_at, reviewed_at, last_error
            FROM autodream_session_reviews
            WHERE agent_id = ? AND session_id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(agentId, at: 1, statement: statement)
        bindText(sessionId, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeAutodreamSessionReview(statement: statement)
#else
        return fallbackAutodreamSessionReviews[autodreamSessionReviewKey(agentId: agentId, sessionId: sessionId)]
#endif
    }

    public func saveAutodreamSessionReview(_ record: AutodreamSessionReviewRecord) async {
        fallbackAutodreamSessionReviews[autodreamSessionReviewKey(agentId: record.agentId, sessionId: record.sessionId)] = record
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO autodream_session_reviews(
                agent_id, session_id, status, reason, session_updated_at, reviewed_at, last_error
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(record.agentId, at: 1, statement: statement)
        bindText(record.sessionId, at: 2, statement: statement)
        bindText(record.status, at: 3, statement: statement)
        bindText(record.reason, at: 4, statement: statement)
        bindText(isoFormatter.string(from: record.sessionUpdatedAt), at: 5, statement: statement)
        bindText(isoFormatter.string(from: record.reviewedAt), at: 6, statement: statement)
        bindOptionalText(record.lastError, at: 7, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func listToolInvocationDurations(projectId: String, from: Date?, to: Date?, limit: Int) async -> [Int] {
#if canImport(CSQLite3)
        guard let db else { return [] }

        var conditions: [String] = ["project_id = ?"]
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }
        conditions.append("duration_ms IS NOT NULL")
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        let clampedLimit = max(1, min(limit, 20_000))

        let sql =
            """
            SELECT duration_ms
            FROM tool_invocations
            \(whereClause)
            ORDER BY created_at DESC
            LIMIT \(clampedLimit);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        bindText(projectId, at: paramIndex, statement: statement)
        paramIndex += 1
        if let from {
            bindText(isoFormatter.string(from: from), at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: paramIndex, statement: statement)
        }

        var result: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Int(sqlite3_column_int(statement, 0)))
        }
        return result
#else
        return []
#endif
    }

    public func saveWorkflowRun(_ run: WorkflowRun) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackWorkflowRuns[run.id] = run
            return
        }
        let sql =
            """
            INSERT OR REPLACE INTO workflow_runs(
                id, workflow_id, workflow_version, project_id, task_id, status,
                current_node_ids_json, started_by, started_at, finished_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackWorkflowRuns[run.id] = run
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(run.id, at: 1, statement: statement)
        bindText(run.workflowId, at: 2, statement: statement)
        sqlite3_bind_int(statement, 3, Int32(run.workflowVersion))
        bindText(run.projectId, at: 4, statement: statement)
        bindOptionalText(run.taskId, at: 5, statement: statement)
        bindText(run.status.rawValue, at: 6, statement: statement)
        bindText(jsonString(run.currentNodeIds, fallback: "[]"), at: 7, statement: statement)
        bindText(run.startedBy, at: 8, statement: statement)
        bindText(isoFormatter.string(from: run.startedAt), at: 9, statement: statement)
        bindOptionalText(run.finishedAt.map { isoFormatter.string(from: $0) }, at: 10, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackWorkflowRuns[run.id] = run
        }
#else
        fallbackWorkflowRuns[run.id] = run
#endif
    }

    public func listWorkflowRuns(projectId: String) async -> [WorkflowRun] {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkflowRuns(projectId: projectId) }
        let sql =
            """
            SELECT id, workflow_id, workflow_version, project_id, task_id, status, current_node_ids_json, started_by, started_at, finished_at
            FROM workflow_runs
            WHERE project_id = ?
            ORDER BY started_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(projectId, at: 1, statement: statement)
        var result: [WorkflowRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let run = decodeWorkflowRun(statement: statement) {
                result.append(run)
            }
        }
        return result
#else
        return fallbackWorkflowRuns(projectId: projectId)
#endif
    }

    public func getWorkflowRun(id: String) async -> WorkflowRun? {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkflowRuns[id] }
        let sql =
            """
            SELECT id, workflow_id, workflow_version, project_id, task_id, status, current_node_ids_json, started_by, started_at, finished_at
            FROM workflow_runs
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeWorkflowRun(statement: statement)
#else
        return fallbackWorkflowRuns[id]
#endif
    }

    public func saveWorkflowRunStep(_ step: WorkflowRunStep) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackWorkflowRunSteps[step.id] = step
            return
        }
        let sql =
            """
            INSERT OR REPLACE INTO workflow_run_steps(
                id, run_id, node_id, status, input_json, output_json, error, started_at, finished_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackWorkflowRunSteps[step.id] = step
            return
        }
        defer { sqlite3_finalize(statement) }
        bindText(step.id, at: 1, statement: statement)
        bindText(step.runId, at: 2, statement: statement)
        bindText(step.nodeId, at: 3, statement: statement)
        bindText(step.status.rawValue, at: 4, statement: statement)
        bindText(jsonString(step.input, fallback: "{}"), at: 5, statement: statement)
        bindText(jsonString(step.output, fallback: "{}"), at: 6, statement: statement)
        bindOptionalText(step.error, at: 7, statement: statement)
        bindText(isoFormatter.string(from: step.startedAt), at: 8, statement: statement)
        bindOptionalText(step.finishedAt.map { isoFormatter.string(from: $0) }, at: 9, statement: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackWorkflowRunSteps[step.id] = step
        }
#else
        fallbackWorkflowRunSteps[step.id] = step
#endif
    }

    public func listWorkflowRunSteps(runId: String) async -> [WorkflowRunStep] {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkflowRunSteps(runId: runId) }
        let sql =
            """
            SELECT id, run_id, node_id, status, input_json, output_json, error, started_at, finished_at
            FROM workflow_run_steps
            WHERE run_id = ?
            ORDER BY started_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(runId, at: 1, statement: statement)
        var result: [WorkflowRunStep] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let step = decodeWorkflowRunStep(statement: statement) {
                result.append(step)
            }
        }
        return result
#else
        return fallbackWorkflowRunSteps(runId: runId)
#endif
    }

    public func saveWorkflowPendingAction(_ action: WorkflowPendingAction) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackWorkflowPendingActions[action.id] = action
            return
        }
        let sql =
            """
            INSERT OR REPLACE INTO workflow_pending_actions(
                id, project_id, workflow_run_id, node_id, task_id, assignee, prompt,
                decisions_json, created_at, resolved_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackWorkflowPendingActions[action.id] = action
            return
        }
        defer { sqlite3_finalize(statement) }
        bindText(action.id, at: 1, statement: statement)
        bindText(action.projectId, at: 2, statement: statement)
        bindText(action.workflowRunId, at: 3, statement: statement)
        bindText(action.nodeId, at: 4, statement: statement)
        bindOptionalText(action.taskId, at: 5, statement: statement)
        bindText(action.assignee, at: 6, statement: statement)
        bindText(action.prompt, at: 7, statement: statement)
        bindText(jsonString(action.decisions, fallback: "[]"), at: 8, statement: statement)
        bindText(isoFormatter.string(from: action.createdAt), at: 9, statement: statement)
        bindOptionalText(action.resolvedAt.map { isoFormatter.string(from: $0) }, at: 10, statement: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackWorkflowPendingActions[action.id] = action
        }
#else
        fallbackWorkflowPendingActions[action.id] = action
#endif
    }

    public func listWorkflowPendingActions(projectId: String, includeResolved: Bool) async -> [WorkflowPendingAction] {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkflowPendingActions(projectId: projectId, includeResolved: includeResolved) }
        let resolvedClause = includeResolved ? "" : "AND resolved_at IS NULL"
        let sql =
            """
            SELECT id, project_id, workflow_run_id, node_id, task_id, assignee, prompt, decisions_json, created_at, resolved_at
            FROM workflow_pending_actions
            WHERE project_id = ? \(resolvedClause)
            ORDER BY created_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(projectId, at: 1, statement: statement)
        var result: [WorkflowPendingAction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let action = decodeWorkflowPendingAction(statement: statement) {
                result.append(action)
            }
        }
        return result
#else
        return fallbackWorkflowPendingActions(projectId: projectId, includeResolved: includeResolved)
#endif
    }

    public func listWorkflowPendingActions(runId: String) async -> [WorkflowPendingAction] {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkflowPendingActions(runId: runId) }
        let sql =
            """
            SELECT id, project_id, workflow_run_id, node_id, task_id, assignee, prompt, decisions_json, created_at, resolved_at
            FROM workflow_pending_actions
            WHERE workflow_run_id = ?
            ORDER BY created_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(runId, at: 1, statement: statement)
        var result: [WorkflowPendingAction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let action = decodeWorkflowPendingAction(statement: statement) {
                result.append(action)
            }
        }
        return result
#else
        return fallbackWorkflowPendingActions(runId: runId)
#endif
    }

    public func resolveWorkflowPendingAction(actionId: String, resolvedAt: Date) async -> WorkflowPendingAction? {
#if canImport(CSQLite3)
        guard let db else { return resolveFallbackWorkflowPendingAction(actionId: actionId, resolvedAt: resolvedAt) }
        let sql = "UPDATE workflow_pending_actions SET resolved_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(isoFormatter.string(from: resolvedAt), at: 1, statement: statement)
        bindText(actionId, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return workflowPendingAction(id: actionId)
#else
        return resolveFallbackWorkflowPendingAction(actionId: actionId, resolvedAt: resolvedAt)
#endif
    }

    public func saveAutomationRun(_ run: AutomationRun) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackAutomationRuns[run.id] = run
            return
        }
        let sql =
            """
            INSERT OR REPLACE INTO automation_runs(
                id, automation_id, project_id, workflow_id, workflow_run_id, repository_full_name,
                trigger_type, trigger_event_id, status, task_id, summary, started_at, finished_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackAutomationRuns[run.id] = run
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(run.id, at: 1, statement: statement)
        bindText(run.automationId, at: 2, statement: statement)
        bindText(run.projectId, at: 3, statement: statement)
        bindText(run.workflowId, at: 4, statement: statement)
        bindOptionalText(run.workflowRunId, at: 5, statement: statement)
        bindText(run.repositoryFullName, at: 6, statement: statement)
        bindText(run.triggerType.rawValue, at: 7, statement: statement)
        bindOptionalText(run.triggerEventId, at: 8, statement: statement)
        bindText(run.status.rawValue, at: 9, statement: statement)
        bindOptionalText(run.taskId, at: 10, statement: statement)
        bindOptionalText(run.summary, at: 11, statement: statement)
        bindText(isoFormatter.string(from: run.startedAt), at: 12, statement: statement)
        bindOptionalText(run.finishedAt.map { isoFormatter.string(from: $0) }, at: 13, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackAutomationRuns[run.id] = run
        }
#else
        fallbackAutomationRuns[run.id] = run
#endif
    }

    public func listAutomationRuns(projectId: String) async -> [AutomationRun] {
#if canImport(CSQLite3)
        guard let db else { return fallbackAutomationRuns(projectId: projectId) }
        let sql =
            """
            SELECT id, automation_id, project_id, workflow_id, workflow_run_id, repository_full_name, trigger_type, trigger_event_id, status, task_id, summary, started_at, finished_at
            FROM automation_runs
            WHERE project_id = ?
            ORDER BY started_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(projectId, at: 1, statement: statement)
        var result: [AutomationRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let run = decodeAutomationRun(statement: statement) {
                result.append(run)
            }
        }
        return result
#else
        return fallbackAutomationRuns(projectId: projectId)
#endif
    }

    public func listAutomationRuns(automationId: String) async -> [AutomationRun] {
#if canImport(CSQLite3)
        guard let db else { return fallbackAutomationRuns(automationId: automationId) }
        let sql =
            """
            SELECT id, automation_id, project_id, workflow_id, workflow_run_id, repository_full_name, trigger_type, trigger_event_id, status, task_id, summary, started_at, finished_at
            FROM automation_runs
            WHERE automation_id = ?
            ORDER BY started_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(automationId, at: 1, statement: statement)
        var result: [AutomationRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let run = decodeAutomationRun(statement: statement) {
                result.append(run)
            }
        }
        return result
#else
        return fallbackAutomationRuns(automationId: automationId)
#endif
    }

    public func getAutomationRun(id: String) async -> AutomationRun? {
#if canImport(CSQLite3)
        guard let db else { return fallbackAutomationRuns[id] }
        let sql =
            """
            SELECT id, automation_id, project_id, workflow_id, workflow_run_id, repository_full_name, trigger_type, trigger_event_id, status, task_id, summary, started_at, finished_at
            FROM automation_runs
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeAutomationRun(statement: statement)
#else
        return fallbackAutomationRuns[id]
#endif
    }

    /// Persists generated memory bulletin.
    public func persistBulletin(_ bulletin: MemoryBulletin) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackBulletins.append(bulletin)
            return
        }

        let sql =
            """
            INSERT INTO memory_bulletins(
                id,
                headline,
                digest,
                items_json,
                created_at
            ) VALUES(?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackBulletins.append(bulletin)
            return
        }
        defer { sqlite3_finalize(statement) }

        let itemsJSON = (try? String(data: JSONEncoder().encode(bulletin.items), encoding: .utf8)) ?? "[]"
        bindText(bulletin.id, at: 1, statement: statement)
        bindText(bulletin.headline, at: 2, statement: statement)
        bindText(bulletin.digest, at: 3, statement: statement)
        bindText(itemsJSON, at: 4, statement: statement)
        bindText(isoFormatter.string(from: bulletin.generatedAt), at: 5, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackBulletins.append(bulletin)
        }
#else
        fallbackBulletins.append(bulletin)
#endif
    }

    /// Lists persisted events in deterministic replay order.
    public func listPersistedEvents() async -> [EventEnvelope] {
#if canImport(CSQLite3)
        guard let db else {
            return sortedFallbackEvents()
        }

        let result = loadPersistedEvents(db: db)
        if result.isEmpty && !fallbackEvents.isEmpty {
            return sortedFallbackEvents()
        }
        return result
#else
        return sortedFallbackEvents()
#endif
    }

    public func listChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) async -> [EventEnvelope] {
        guard limit > 0 else {
            return []
        }
#if canImport(CSQLite3)
        guard let db else {
            return filteredFallbackChannelEvents(
                channelId: channelId,
                limit: limit,
                cursor: cursor,
                before: before,
                after: after
            )
        }

        let result = loadChannelEvents(
            db: db,
            channelId: channelId,
            limit: limit,
            cursor: cursor,
            before: before,
            after: after
        )
        if result.isEmpty && !fallbackEvents.isEmpty {
            return filteredFallbackChannelEvents(
                channelId: channelId,
                limit: limit,
                cursor: cursor,
                before: before,
                after: after
            )
        }
        return result
#else
        return filteredFallbackChannelEvents(
            channelId: channelId,
            limit: limit,
            cursor: cursor,
            before: before,
            after: after
        )
#endif
    }

    /// Lists persisted channels in creation order.
    public func listPersistedChannels() async -> [PersistedChannelRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackChannels.values.sorted { $0.createdAt < $1.createdAt }
        }

        let result = loadPersistedChannels(db: db)
        if result.isEmpty && !fallbackChannels.isEmpty {
            return fallbackChannels.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackChannels.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    /// Lists persisted task rows in creation order.
    public func listPersistedTasks() async -> [PersistedTaskRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackTasks.values.sorted { $0.createdAt < $1.createdAt }
        }

        let result = loadPersistedTasks(db: db)
        if result.isEmpty && !fallbackTasks.isEmpty {
            return fallbackTasks.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackTasks.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    /// Lists persisted artifacts in creation order.
    public func listPersistedArtifacts() async -> [PersistedArtifactRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackArtifacts.values.sorted { $0.createdAt < $1.createdAt }
        }

        let result = loadPersistedArtifacts(db: db)
        if result.isEmpty && !fallbackArtifacts.isEmpty {
            return fallbackArtifacts.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackArtifacts.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    /// Persists artifact metadata and content by identifier.
    public func persistArtifact(record: PersistedArtifactRecord) async {
#if canImport(CSQLite3)
        guard let db else {
            persistFallbackArtifact(record: record)
            return
        }

        let sql =
            """
            INSERT OR REPLACE INTO artifacts(
                id,
                title,
                kind,
                media_type,
                content,
                preview_text,
                widget_size,
                widget_width,
                widget_height,
                widget_entry,
                bundle_path,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            persistFallbackArtifact(record: record)
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(record.id, at: 1, statement: statement)
        bindText(record.title, at: 2, statement: statement)
        bindText(record.kind, at: 3, statement: statement)
        bindText(record.mediaType, at: 4, statement: statement)
        bindText(record.content, at: 5, statement: statement)
        bindOptionalText(record.previewText, at: 6, statement: statement)
        bindOptionalText(record.widgetSize, at: 7, statement: statement)
        bindOptionalInt(record.widgetWidth, at: 8, statement: statement)
        bindOptionalInt(record.widgetHeight, at: 9, statement: statement)
        bindOptionalText(record.widgetEntry, at: 10, statement: statement)
        bindOptionalText(record.bundlePath, at: 11, statement: statement)
        bindText(isoFormatter.string(from: record.createdAt), at: 12, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            persistFallbackArtifact(record: record)
            return
        }

        fallbackArtifacts[record.id] = record
#else
        persistFallbackArtifact(record: record)
#endif
    }

    /// Persists artifact text payload by identifier.
    public func persistArtifact(id: String, content: String) async {
        let record = await persistedArtifact(id: id)?.updatingContent(content) ?? PersistedArtifactRecord(
            id: id,
            content: content,
            previewText: String(content.prefix(160)),
            createdAt: Date()
        )
        await persistArtifact(
            record: record
        )
    }

    /// Removes persisted artifact metadata and content by identifier.
    public func deleteArtifact(id: String) async -> Bool {
        let removedFallback = fallbackArtifacts.removeValue(forKey: id) != nil
#if canImport(CSQLite3)
        guard let db else {
            return removedFallback
        }

        let sql = "DELETE FROM artifacts WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return removedFallback
        }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            return removedFallback
        }
        return sqlite3_changes(db) > 0 || removedFallback
#else
        return removedFallback
#endif
    }

    public func listPublishedSites() async -> [PersistedPublishedSiteRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackPublishedSites.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        let sql = """
            SELECT id, slug, title, visibility, owner_id, project_id, entry_file,
                   bundle_path, revision, created_at, updated_at
            FROM published_sites
            ORDER BY updated_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackPublishedSites.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        defer { sqlite3_finalize(statement) }
        var sites: [PersistedPublishedSiteRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let site = persistedPublishedSite(from: statement) {
                sites.append(site)
            }
        }
        return sites.isEmpty && !fallbackPublishedSites.isEmpty
            ? fallbackPublishedSites.values.sorted { $0.updatedAt > $1.updatedAt }
            : sites
#else
        return fallbackPublishedSites.values.sorted { $0.updatedAt > $1.updatedAt }
#endif
    }

    public func publishedSite(id: String) async -> PersistedPublishedSiteRecord? {
        await loadPublishedSite(column: "id", value: id) ?? fallbackPublishedSites[id]
    }

    public func publishedSite(slug: String) async -> PersistedPublishedSiteRecord? {
        await loadPublishedSite(column: "slug", value: slug)
            ?? fallbackPublishedSites.values.first { $0.slug == slug }
    }

    public func savePublishedSite(_ site: PersistedPublishedSiteRecord) async {
        fallbackPublishedSites[site.id] = site
#if canImport(CSQLite3)
        guard let db else { return }
        let sql = """
            INSERT INTO published_sites(
                id, slug, title, visibility, owner_id, project_id, entry_file,
                bundle_path, revision, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                slug = excluded.slug,
                title = excluded.title,
                visibility = excluded.visibility,
                owner_id = excluded.owner_id,
                project_id = excluded.project_id,
                entry_file = excluded.entry_file,
                bundle_path = excluded.bundle_path,
                revision = excluded.revision,
                updated_at = excluded.updated_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(site.id, at: 1, statement: statement)
        bindText(site.slug, at: 2, statement: statement)
        bindText(site.title, at: 3, statement: statement)
        bindText(site.visibility.rawValue, at: 4, statement: statement)
        bindText(site.ownerId, at: 5, statement: statement)
        bindOptionalText(site.projectId, at: 6, statement: statement)
        bindText(site.entryFile, at: 7, statement: statement)
        bindText(site.bundlePath, at: 8, statement: statement)
        sqlite3_bind_int64(statement, 9, Int64(site.revision))
        bindText(isoFormatter.string(from: site.createdAt), at: 10, statement: statement)
        bindText(isoFormatter.string(from: site.updatedAt), at: 11, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func deletePublishedSite(id: String) async -> Bool {
        let removedFallback = fallbackPublishedSites.removeValue(forKey: id) != nil
#if canImport(CSQLite3)
        guard let db else { return removedFallback }
        let sql = "DELETE FROM published_sites WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return removedFallback
        }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { return removedFallback }
        return sqlite3_changes(db) > 0 || removedFallback
#else
        return removedFallback
#endif
    }

    private func loadPublishedSite(column: String, value: String) async -> PersistedPublishedSiteRecord? {
#if canImport(CSQLite3)
        guard let db, column == "id" || column == "slug" else { return nil }
        let sql = """
            SELECT id, slug, title, visibility, owner_id, project_id, entry_file,
                   bundle_path, revision, created_at, updated_at
            FROM published_sites
            WHERE \(column) = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(value, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return persistedPublishedSite(from: statement)
#else
        return nil
#endif
    }

#if canImport(CSQLite3)
    private func persistedPublishedSite(from statement: OpaquePointer?) -> PersistedPublishedSiteRecord? {
        guard let id = optionalText(statement: statement, index: 0),
              let slug = optionalText(statement: statement, index: 1),
              let title = optionalText(statement: statement, index: 2),
              let rawVisibility = optionalText(statement: statement, index: 3),
              let visibility = PublishedSiteVisibility(rawValue: rawVisibility),
              let ownerId = optionalText(statement: statement, index: 4),
              let entryFile = optionalText(statement: statement, index: 6),
              let bundlePath = optionalText(statement: statement, index: 7),
              let createdRaw = optionalText(statement: statement, index: 9),
              let updatedRaw = optionalText(statement: statement, index: 10)
        else { return nil }
        return PersistedPublishedSiteRecord(
            id: id,
            slug: slug,
            title: title,
            visibility: visibility,
            ownerId: ownerId,
            projectId: optionalText(statement: statement, index: 5),
            entryFile: entryFile,
            bundlePath: bundlePath,
            revision: Int(sqlite3_column_int64(statement, 8)),
            createdAt: isoFormatter.date(from: createdRaw) ?? Date(),
            updatedAt: isoFormatter.date(from: updatedRaw) ?? Date()
        )
    }
#endif

    public func listInitiatives(projectID: String) async -> [InitiativeRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackInitiatives(projectID: projectID)
        }

        let sql =
            """
            SELECT
                id,
                project_id,
                title,
                goal,
                phase,
                execution_mode,
                success_metrics_json,
                constraints_json,
                resume_point,
                blocker,
                metadata_json,
                created_at,
                updated_at
            FROM project_initiatives
            WHERE project_id = ?
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackInitiatives(projectID: projectID)
        }
        defer { sqlite3_finalize(statement) }

        bindText(projectID, at: 1, statement: statement)
        var result: [InitiativeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = initiativeRecord(from: statement) {
                result.append(record)
            }
        }
        return result.isEmpty ? fallbackInitiatives(projectID: projectID) : result
#else
        return fallbackInitiatives(projectID: projectID)
#endif
    }

    public func getInitiative(projectID: String, initiativeID: String) async -> InitiativeRecord? {
#if canImport(CSQLite3)
        if let db {
            let sql =
                """
                SELECT
                    id,
                    project_id,
                    title,
                    goal,
                    phase,
                    execution_mode,
                    success_metrics_json,
                    constraints_json,
                    resume_point,
                    blocker,
                    metadata_json,
                    created_at,
                    updated_at
                FROM project_initiatives
                WHERE project_id = ? AND id = ?
                LIMIT 1;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackProjectInitiatives[initiativeID]
            }
            defer { sqlite3_finalize(statement) }

            bindText(projectID, at: 1, statement: statement)
            bindText(initiativeID, at: 2, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return initiativeRecord(from: statement)
            }
        }
#endif
        guard let record = fallbackProjectInitiatives[initiativeID], record.projectID == projectID else {
            return nil
        }
        return record
    }

    public func saveInitiative(_ record: InitiativeRecord) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackProjectInitiatives[record.id] = record
            return
        }

        let sql =
            """
            INSERT OR REPLACE INTO project_initiatives(
                id,
                project_id,
                title,
                goal,
                phase,
                execution_mode,
                success_metrics_json,
                constraints_json,
                resume_point,
                blocker,
                metadata_json,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackProjectInitiatives[record.id] = record
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(record.id, at: 1, statement: statement)
        bindText(record.projectID, at: 2, statement: statement)
        bindText(record.title, at: 3, statement: statement)
        bindText(record.goal, at: 4, statement: statement)
        bindText(record.phase.rawValue, at: 5, statement: statement)
        bindText(record.executionMode.rawValue, at: 6, statement: statement)
        bindText(jsonString(record.successMetrics, fallback: "[]"), at: 7, statement: statement)
        bindText(jsonString(record.constraints, fallback: "[]"), at: 8, statement: statement)
        bindOptionalText(record.resumePoint, at: 9, statement: statement)
        bindOptionalText(record.blocker, at: 10, statement: statement)
        bindText(jsonString(record.metadata, fallback: "{}"), at: 11, statement: statement)
        bindText(isoFormatter.string(from: record.createdAt), at: 12, statement: statement)
        bindText(isoFormatter.string(from: record.updatedAt), at: 13, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackProjectInitiatives[record.id] = record
            return
        }

        fallbackProjectInitiatives[record.id] = record
#else
        fallbackProjectInitiatives[record.id] = record
#endif
    }

    public func deleteInitiative(projectID: String, initiativeID: String) async -> Bool {
        let removedFallback = fallbackProjectInitiatives.removeValue(forKey: initiativeID)?.projectID == projectID
        fallbackDecisionPacketsByID = fallbackDecisionPacketsByID.filter { _, packet in
            !(packet.projectID == projectID && packet.initiativeID == initiativeID)
        }
#if canImport(CSQLite3)
        guard let db else {
            return removedFallback
        }

        let deletePacketsSQL = "DELETE FROM initiative_decision_packets WHERE project_id = ? AND initiative_id = ?;"
        var packetStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deletePacketsSQL, -1, &packetStatement, nil) == SQLITE_OK {
            bindText(projectID, at: 1, statement: packetStatement)
            bindText(initiativeID, at: 2, statement: packetStatement)
            _ = sqlite3_step(packetStatement)
        }
        sqlite3_finalize(packetStatement)

        let sql = "DELETE FROM project_initiatives WHERE project_id = ? AND id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return removedFallback
        }
        defer { sqlite3_finalize(statement) }

        bindText(projectID, at: 1, statement: statement)
        bindText(initiativeID, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            return removedFallback
        }
        return sqlite3_changes(db) > 0 || removedFallback
#else
        return removedFallback
#endif
    }

    public func listDecisionPackets(projectID: String, initiativeID: String) async -> [DecisionPacketRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackDecisionPackets(projectID: projectID, initiativeID: initiativeID)
        }

        let sql =
            """
            SELECT
                id,
                project_id,
                initiative_id,
                summary,
                rationale,
                tradeoffs_json,
                requested_action,
                resume_point,
                status,
                created_at,
                updated_at
            FROM initiative_decision_packets
            WHERE project_id = ? AND initiative_id = ?
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackDecisionPackets(projectID: projectID, initiativeID: initiativeID)
        }
        defer { sqlite3_finalize(statement) }

        bindText(projectID, at: 1, statement: statement)
        bindText(initiativeID, at: 2, statement: statement)
        var result: [DecisionPacketRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decisionPacketRecord(from: statement) {
                result.append(record)
            }
        }
        return result.isEmpty ? fallbackDecisionPackets(projectID: projectID, initiativeID: initiativeID) : result
#else
        return fallbackDecisionPackets(projectID: projectID, initiativeID: initiativeID)
#endif
    }

    public func saveDecisionPacket(_ record: DecisionPacketRecord) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackDecisionPacketsByID[record.id] = record
            return
        }

        let sql =
            """
            INSERT OR REPLACE INTO initiative_decision_packets(
                id,
                project_id,
                initiative_id,
                summary,
                rationale,
                tradeoffs_json,
                requested_action,
                resume_point,
                status,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackDecisionPacketsByID[record.id] = record
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(record.id, at: 1, statement: statement)
        bindText(record.projectID, at: 2, statement: statement)
        bindText(record.initiativeID, at: 3, statement: statement)
        bindText(record.summary, at: 4, statement: statement)
        bindText(record.rationale, at: 5, statement: statement)
        bindText(jsonString(record.tradeoffs, fallback: "[]"), at: 6, statement: statement)
        bindText(record.requestedAction, at: 7, statement: statement)
        bindOptionalText(record.resumePoint, at: 8, statement: statement)
        bindText(record.status, at: 9, statement: statement)
        bindText(isoFormatter.string(from: record.createdAt), at: 10, statement: statement)
        bindText(isoFormatter.string(from: record.updatedAt), at: 11, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackDecisionPacketsByID[record.id] = record
            return
        }

        fallbackDecisionPacketsByID[record.id] = record
#else
        fallbackDecisionPacketsByID[record.id] = record
#endif
    }

    /// Returns artifact metadata by identifier.
    public func persistedArtifact(id: String) async -> PersistedArtifactRecord? {
#if canImport(CSQLite3)
        if let db {
            let sql =
                """
                SELECT
                    id,
                    title,
                    kind,
                    media_type,
                    content,
                    preview_text,
                    widget_size,
                    widget_width,
                    widget_height,
                    widget_entry,
                    bundle_path,
                    created_at
                FROM artifacts
                WHERE id = ?
                LIMIT 1;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackArtifacts[id]
            }
            defer { sqlite3_finalize(statement) }

            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return persistedArtifact(from: statement)
            }
        }
#endif
        return fallbackArtifacts[id]
    }

    /// Returns artifact text payload by identifier.
    public func artifactContent(id: String) async -> String? {
#if canImport(CSQLite3)
        if let db {
            let sql =
                """
                SELECT content
                FROM artifacts
                WHERE id = ?
                LIMIT 1;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackArtifacts[id]?.content
            }
            defer { sqlite3_finalize(statement) }

            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                return String(cString: cString)
            }
        }
#endif
        return fallbackArtifacts[id]?.content
    }

    /// Lists recent memory bulletins.
    public func listBulletins() async -> [MemoryBulletin] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackBulletins
        }

        let sql =
            """
            SELECT id, headline, digest, items_json, created_at
            FROM memory_bulletins
            ORDER BY created_at DESC
            LIMIT 100;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackBulletins
        }
        defer { sqlite3_finalize(statement) }

        var result: [MemoryBulletin] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let headlinePtr = sqlite3_column_text(statement, 1),
                let digestPtr = sqlite3_column_text(statement, 2),
                let itemsPtr = sqlite3_column_text(statement, 3),
                let createdAtPtr = sqlite3_column_text(statement, 4)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let headline = String(cString: headlinePtr)
            let digest = String(cString: digestPtr)
            let itemsJSON = String(cString: itemsPtr)
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let itemsData = Data(itemsJSON.utf8)
            let items = (try? JSONDecoder().decode([String].self, from: itemsData)) ?? []

            result.append(
                MemoryBulletin(
                    id: id,
                    generatedAt: createdAt,
                    headline: headline,
                    digest: digest,
                    items: items
                )
            )
        }

        if result.isEmpty {
            return fallbackBulletins
        }
        return result
#else
        return fallbackBulletins
#endif
    }

    public func listProjects() async -> [ProjectRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
        }

        let sql =
            """
            SELECT id, name, description, actors_json, teams_json,
                   models_json, agent_files_json, heartbeat_json,
                   created_at, updated_at, repo_path, review_settings_json,
                   icon, is_archived, task_loop_mode, task_sync_settings_json,
                   is_favorite, source_control_provider_id, autopilot_settings_json,
                   project_kind, directory_paths_json, automatic_task_pickup_enabled
            FROM dashboard_projects
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
        }
        defer { sqlite3_finalize(statement) }

        var result: [ProjectRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let namePtr = sqlite3_column_text(statement, 1),
                let descriptionPtr = sqlite3_column_text(statement, 2),
                let actorsPtr = sqlite3_column_text(statement, 3),
                let teamsPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 8),
                let updatedAtPtr = sqlite3_column_text(statement, 9)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let name = String(cString: namePtr)
            let description = String(cString: descriptionPtr)
            let actorsJSON = String(cString: actorsPtr)
            let teamsJSON = String(cString: teamsPtr)
            let modelsJSON = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "[]"
            let agentFilesJSON = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? "[]"
            let heartbeatJSON = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "{}"
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            let actors = (try? JSONDecoder().decode([String].self, from: Data(actorsJSON.utf8))) ?? []
            let teams = (try? JSONDecoder().decode([String].self, from: Data(teamsJSON.utf8))) ?? []
            let models = (try? JSONDecoder().decode([String].self, from: Data(modelsJSON.utf8))) ?? []
            let agentFiles = (try? JSONDecoder().decode([String].self, from: Data(agentFilesJSON.utf8))) ?? []
            let heartbeat = (try? JSONDecoder().decode(ProjectHeartbeatSettings.self, from: Data(heartbeatJSON.utf8))) ?? ProjectHeartbeatSettings()
            let repoPath = optionalText(statement: statement, index: 10)
            let reviewSettingsJSON = sqlite3_column_text(statement, 11).map { String(cString: $0) }
            let reviewSettings = reviewSettingsJSON.flatMap { try? JSONDecoder().decode(ProjectReviewSettings.self, from: Data($0.utf8)) } ?? ProjectReviewSettings()
            let autopilotSettingsJSON = sqlite3_column_text(statement, 18).map { String(cString: $0) } ?? "{}"
            let autopilotSettings = (try? JSONDecoder().decode(ProjectAutopilotSettings.self, from: Data(autopilotSettingsJSON.utf8))) ?? ProjectAutopilotSettings()
            let icon = optionalText(statement: statement, index: 12)
            let isArchived = sqlite3_column_int(statement, 13) != 0
            let taskLoopModeRaw = optionalText(statement: statement, index: 14)
            let taskLoopMode = taskLoopModeRaw.flatMap { ProjectLoopMode(rawValue: $0) } ?? .human
            let taskSyncJSON = sqlite3_column_text(statement, 15).map { String(cString: $0) } ?? "{}"
            let taskSyncSettings = (try? JSONDecoder().decode(ProjectTaskSyncSettings.self, from: Data(taskSyncJSON.utf8))) ?? ProjectTaskSyncSettings()
            let isFavorite = sqlite3_column_int(statement, 16) != 0
            let sourceControlProviderId = optionalText(statement: statement, index: 17)
            let kind = optionalText(statement: statement, index: 19).flatMap(ProjectKind.init(rawValue:)) ?? .project
            let directoryPathsJSON = sqlite3_column_text(statement, 20).map { String(cString: $0) } ?? "[]"
            let directoryPaths = (try? JSONDecoder().decode([String].self, from: Data(directoryPathsJSON.utf8))) ?? []
            let channels = loadProjectChannels(db: db, projectID: id)
            let tasks = loadProjectTasks(db: db, projectID: id)
            if let fallback = fallbackProjects[id], fallback.tasks.count > tasks.count {
                result.append(fallback)
                continue
            }
            result.append(
                ProjectRecord(
                    id: id,
                    name: name,
                    description: description,
                    icon: icon,
                    kind: kind,
                    directoryPaths: directoryPaths,
                    channels: channels,
                    tasks: tasks,
                    actors: actors,
                    teams: teams,
                    models: models,
                    agentFiles: agentFiles,
                    heartbeat: heartbeat,
                    repoPath: repoPath,
                    sourceControlProviderId: sourceControlProviderId,
                    reviewSettings: reviewSettings,
                    automaticTaskPickupEnabled: sqlite3_column_int(statement, 21) != 0,
                    autopilotSettings: autopilotSettings,
                    taskLoopMode: taskLoopMode,
                    taskSyncSettings: taskSyncSettings,
                    isFavorite: isFavorite,
                    isArchived: isArchived,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
#else
        return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func listProjectSummaries() async -> [ProjectListRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackProjects.values.map(Self.projectListRecord).sorted { $0.createdAt < $1.createdAt }
        }

        let sql =
            """
            SELECT p.id, p.name, p.description, p.actors_json, p.teams_json,
                   p.created_at, p.updated_at, p.repo_path, p.icon, p.is_archived,
                   p.is_favorite, p.source_control_provider_id,
                   COUNT(t.id) AS task_total,
                   SUM(CASE WHEN t.status = 'backlog' THEN 1 ELSE 0 END) AS task_backlog,
                   SUM(CASE WHEN t.status = 'ready' THEN 1 ELSE 0 END) AS task_ready,
                   SUM(CASE WHEN t.status = 'in_progress' THEN 1 ELSE 0 END) AS task_in_progress,
                   SUM(CASE WHEN t.status = 'waiting_input' THEN 1 ELSE 0 END) AS task_waiting_input,
                   SUM(CASE WHEN t.status = 'blocked' THEN 1 ELSE 0 END) AS task_blocked,
                   SUM(CASE WHEN t.status = 'needs_review' THEN 1 ELSE 0 END) AS task_needs_review,
                   SUM(CASE WHEN t.status = 'done' THEN 1 ELSE 0 END) AS task_done,
                   p.project_kind, p.directory_paths_json
            FROM dashboard_projects p
            LEFT JOIN dashboard_project_tasks t ON t.project_id = p.id
            GROUP BY p.id
            ORDER BY p.created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackProjects.values.map(Self.projectListRecord).sorted { $0.createdAt < $1.createdAt }
        }
        defer { sqlite3_finalize(statement) }

        var result: [ProjectListRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let namePtr = sqlite3_column_text(statement, 1),
                let descriptionPtr = sqlite3_column_text(statement, 2),
                let actorsPtr = sqlite3_column_text(statement, 3),
                let teamsPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 5),
                let updatedAtPtr = sqlite3_column_text(statement, 6)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let actorsJSON = String(cString: actorsPtr)
            let teamsJSON = String(cString: teamsPtr)
            let actors = (try? JSONDecoder().decode([String].self, from: Data(actorsJSON.utf8))) ?? []
            let teams = (try? JSONDecoder().decode([String].self, from: Data(teamsJSON.utf8))) ?? []
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            let taskTotal = Int(sqlite3_column_int(statement, 12))
            if let fallback = fallbackProjects[id], fallback.tasks.count > taskTotal {
                result.append(Self.projectListRecord(fallback))
                continue
            }
            result.append(
                ProjectListRecord(
                    id: id,
                    name: String(cString: namePtr),
                    description: String(cString: descriptionPtr),
                    icon: optionalText(statement: statement, index: 8),
                    kind: optionalText(statement: statement, index: 20).flatMap(ProjectKind.init(rawValue:)) ?? .project,
                    directoryPaths: sqlite3_column_text(statement, 21).flatMap {
                        try? JSONDecoder().decode([String].self, from: Data(String(cString: $0).utf8))
                    } ?? [],
                    channels: loadProjectChannels(db: db, projectID: id),
                    actors: actors,
                    teams: teams,
                    repoPath: optionalText(statement: statement, index: 7),
                    sourceControlProviderId: optionalText(statement: statement, index: 11),
                    taskCounts: ProjectTaskCountSummary(
                        total: taskTotal,
                        backlog: Int(sqlite3_column_int(statement, 13)),
                        ready: Int(sqlite3_column_int(statement, 14)),
                        inProgress: Int(sqlite3_column_int(statement, 15)),
                        waitingInput: Int(sqlite3_column_int(statement, 16)),
                        blocked: Int(sqlite3_column_int(statement, 17)),
                        needsReview: Int(sqlite3_column_int(statement, 18)),
                        done: Int(sqlite3_column_int(statement, 19))
                    ),
                    isFavorite: sqlite3_column_int(statement, 10) != 0,
                    isArchived: sqlite3_column_int(statement, 9) != 0,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
#else
        return fallbackProjects.values.map(Self.projectListRecord).sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func project(id: String) async -> ProjectRecord? {
#if canImport(CSQLite3)
        if let db {
            let sql =
                """
                SELECT id, name, description, actors_json, teams_json,
                       models_json, agent_files_json, heartbeat_json,
                       created_at, updated_at, repo_path, review_settings_json,
                       icon, is_archived, task_loop_mode, task_sync_settings_json,
                       is_favorite, source_control_provider_id, autopilot_settings_json,
                       project_kind, directory_paths_json, automatic_task_pickup_enabled
                FROM dashboard_projects
                WHERE id = ?
                LIMIT 1;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackProjects[id]
            }
            defer { sqlite3_finalize(statement) }

            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idPtr = sqlite3_column_text(statement, 0),
               let namePtr = sqlite3_column_text(statement, 1),
               let descriptionPtr = sqlite3_column_text(statement, 2),
               let actorsPtr = sqlite3_column_text(statement, 3),
               let teamsPtr = sqlite3_column_text(statement, 4),
               let createdAtPtr = sqlite3_column_text(statement, 8),
               let updatedAtPtr = sqlite3_column_text(statement, 9) {
                let projectID = String(cString: idPtr)
                let actorsJSON = String(cString: actorsPtr)
                let teamsJSON = String(cString: teamsPtr)
                let modelsJSON = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "[]"
                let agentFilesJSON = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? "[]"
                let heartbeatJSON = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "{}"
                let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
                let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
                let actors = (try? JSONDecoder().decode([String].self, from: Data(actorsJSON.utf8))) ?? []
                let teams = (try? JSONDecoder().decode([String].self, from: Data(teamsJSON.utf8))) ?? []
                let models = (try? JSONDecoder().decode([String].self, from: Data(modelsJSON.utf8))) ?? []
                let agentFiles = (try? JSONDecoder().decode([String].self, from: Data(agentFilesJSON.utf8))) ?? []
                let heartbeat = (try? JSONDecoder().decode(ProjectHeartbeatSettings.self, from: Data(heartbeatJSON.utf8))) ?? ProjectHeartbeatSettings()
                let repoPath = optionalText(statement: statement, index: 10)
                let reviewSettingsJSON = sqlite3_column_text(statement, 11).map { String(cString: $0) }
                let reviewSettings = reviewSettingsJSON.flatMap { try? JSONDecoder().decode(ProjectReviewSettings.self, from: Data($0.utf8)) } ?? ProjectReviewSettings()
                let autopilotSettingsJSON = sqlite3_column_text(statement, 18).map { String(cString: $0) } ?? "{}"
                let autopilotSettings = (try? JSONDecoder().decode(ProjectAutopilotSettings.self, from: Data(autopilotSettingsJSON.utf8))) ?? ProjectAutopilotSettings()
                let icon = optionalText(statement: statement, index: 12)
                let isArchived = sqlite3_column_int(statement, 13) != 0
                let taskLoopModeRaw = optionalText(statement: statement, index: 14)
                let taskLoopMode = taskLoopModeRaw.flatMap { ProjectLoopMode(rawValue: $0) } ?? .human
                let taskSyncJSON = sqlite3_column_text(statement, 15).map { String(cString: $0) } ?? "{}"
                let taskSyncSettings = (try? JSONDecoder().decode(ProjectTaskSyncSettings.self, from: Data(taskSyncJSON.utf8))) ?? ProjectTaskSyncSettings()
                let isFavorite = sqlite3_column_int(statement, 16) != 0
                let sourceControlProviderId = optionalText(statement: statement, index: 17)
                let kind = optionalText(statement: statement, index: 19).flatMap(ProjectKind.init(rawValue:)) ?? .project
                let directoryPathsJSON = sqlite3_column_text(statement, 20).map { String(cString: $0) } ?? "[]"
                let directoryPaths = (try? JSONDecoder().decode([String].self, from: Data(directoryPathsJSON.utf8))) ?? []
                let tasks = loadProjectTasks(db: db, projectID: projectID)
                if let fallback = fallbackProjects[id], fallback.tasks.count > tasks.count {
                    return fallback
                }
                return ProjectRecord(
                    id: projectID,
                    name: String(cString: namePtr),
                    description: String(cString: descriptionPtr),
                    icon: icon,
                    kind: kind,
                    directoryPaths: directoryPaths,
                    channels: loadProjectChannels(db: db, projectID: projectID),
                    tasks: tasks,
                    actors: actors,
                    teams: teams,
                    models: models,
                    agentFiles: agentFiles,
                    heartbeat: heartbeat,
                    repoPath: repoPath,
                    sourceControlProviderId: sourceControlProviderId,
                    reviewSettings: reviewSettings,
                    automaticTaskPickupEnabled: sqlite3_column_int(statement, 21) != 0,
                    autopilotSettings: autopilotSettings,
                    taskLoopMode: taskLoopMode,
                    taskSyncSettings: taskSyncSettings,
                    isFavorite: isFavorite,
                    isArchived: isArchived,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            }
            return nil
        }
#endif
        return fallbackProjects[id]
    }

    public func saveProject(_ project: ProjectRecord) async {
        fallbackProjects[project.id] = project
        persistFallbackProjectsToDisk()
#if canImport(CSQLite3)
        guard let db else {
            return
        }

        let projectSQL =
            """
            INSERT OR REPLACE INTO dashboard_projects(
                id,
                name,
                description,
                actors_json,
                teams_json,
                models_json,
                agent_files_json,
                heartbeat_json,
                created_at,
                updated_at,
                repo_path,
                review_settings_json,
                autopilot_settings_json,
                icon,
                is_archived,
                task_loop_mode,
                task_sync_settings_json,
                is_favorite,
                source_control_provider_id,
                project_kind,
                directory_paths_json,
                automatic_task_pickup_enabled
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var projectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, projectSQL, -1, &projectStatement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(projectStatement) }

        let actorsJSON = (try? String(data: JSONEncoder().encode(project.actors), encoding: .utf8)) ?? "[]"
        let teamsJSON = (try? String(data: JSONEncoder().encode(project.teams), encoding: .utf8)) ?? "[]"
        let modelsJSON = (try? String(data: JSONEncoder().encode(project.models), encoding: .utf8)) ?? "[]"
        let agentFilesJSON = (try? String(data: JSONEncoder().encode(project.agentFiles), encoding: .utf8)) ?? "[]"
        let heartbeatJSON = (try? String(data: JSONEncoder().encode(project.heartbeat), encoding: .utf8)) ?? "{}"
        let reviewSettingsJSON = (try? String(data: JSONEncoder().encode(project.reviewSettings), encoding: .utf8)) ?? "{}"
        let autopilotSettingsJSON = (try? String(data: JSONEncoder().encode(project.autopilotSettings), encoding: .utf8)) ?? "{}"
        let taskSyncSettingsJSON = (try? String(data: JSONEncoder().encode(project.taskSyncSettings), encoding: .utf8)) ?? "{}"
        let directoryPathsJSON = (try? String(data: JSONEncoder().encode(project.directoryPaths), encoding: .utf8)) ?? "[]"

        bindText(project.id, at: 1, statement: projectStatement)
        bindText(project.name, at: 2, statement: projectStatement)
        bindText(project.description, at: 3, statement: projectStatement)
        bindText(actorsJSON, at: 4, statement: projectStatement)
        bindText(teamsJSON, at: 5, statement: projectStatement)
        bindText(modelsJSON, at: 6, statement: projectStatement)
        bindText(agentFilesJSON, at: 7, statement: projectStatement)
        bindText(heartbeatJSON, at: 8, statement: projectStatement)
        bindText(isoFormatter.string(from: project.createdAt), at: 9, statement: projectStatement)
        bindText(isoFormatter.string(from: project.updatedAt), at: 10, statement: projectStatement)
        bindOptionalText(project.repoPath, at: 11, statement: projectStatement)
        bindText(reviewSettingsJSON, at: 12, statement: projectStatement)
        bindText(autopilotSettingsJSON, at: 13, statement: projectStatement)
        bindOptionalText(project.icon, at: 14, statement: projectStatement)
        sqlite3_bind_int(projectStatement, 15, project.isArchived ? 1 : 0)
        bindText(project.taskLoopMode.rawValue, at: 16, statement: projectStatement)
        bindText(taskSyncSettingsJSON, at: 17, statement: projectStatement)
        sqlite3_bind_int(projectStatement, 18, project.isFavorite ? 1 : 0)
        bindOptionalText(project.sourceControlProviderId, at: 19, statement: projectStatement)
        bindText(project.kind.rawValue, at: 20, statement: projectStatement)
        bindText(directoryPathsJSON, at: 21, statement: projectStatement)
        sqlite3_bind_int(projectStatement, 22, project.automaticTaskPickupEnabled ? 1 : 0)
        guard sqlite3_step(projectStatement) == SQLITE_DONE else {
            return
        }

        removeProjectChildren(db: db, projectID: project.id)

        let channelSQL =
            """
            INSERT INTO dashboard_project_channels(
                id,
                project_id,
                title,
                channel_id,
                created_at
            ) VALUES(?, ?, ?, ?, ?);
            """

        for channel in project.channels {
            var channelStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, channelSQL, -1, &channelStatement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(channelStatement) }
            bindText(channel.id, at: 1, statement: channelStatement)
            bindText(project.id, at: 2, statement: channelStatement)
            bindText(channel.title, at: 3, statement: channelStatement)
            bindText(channel.channelId, at: 4, statement: channelStatement)
            bindText(isoFormatter.string(from: channel.createdAt), at: 5, statement: channelStatement)
            _ = sqlite3_step(channelStatement)
        }

        let taskSQL =
            """
            INSERT INTO dashboard_project_tasks(
                id,
                project_id,
                title,
                description,
                priority,
                status,
                initiative_id,
                actor_id,
                team_id,
                claimed_actor_id,
                claimed_agent_id,
                parent_task_id,
                created_by,
                depends_on_task_ids_json,
                swarm_id,
                swarm_task_id,
                swarm_parent_task_id,
                swarm_dependency_ids_json,
                swarm_depth,
                swarm_actor_path_json,
                created_at,
                updated_at,
                worktree_branch,
                source_control_provider_id,
                kind,
                loop_mode_override,
                origin_type,
                origin_channel_id,
                is_archived,
                selected_model,
                attachments_json,
                external_metadata_json,
                tags_json,
                execution_node_id,
                kanban_column_entered_at,
                stage_assignments_json,
                active_stage
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        for task in project.tasks {
            var taskStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, taskSQL, -1, &taskStatement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(taskStatement) }
            let dependencyIdsJSON = encodedStringArray(task.swarmDependencyIds ?? [])
            let dependsOnTaskIdsJSON = encodedStringArray(task.dependsOnTaskIds)
            let actorPathJSON = encodedStringArray(task.swarmActorPath ?? [])
            let attachmentsJSON = (try? String(data: JSONEncoder().encode(task.attachments), encoding: .utf8)) ?? "[]"
            let externalJSON = task.externalMetadata.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
            let tagsJSON = encodedStringArray(task.tags)
            bindText(task.id, at: 1, statement: taskStatement)
            bindText(project.id, at: 2, statement: taskStatement)
            bindText(task.title, at: 3, statement: taskStatement)
            bindText(task.description, at: 4, statement: taskStatement)
            bindText(task.priority, at: 5, statement: taskStatement)
            bindText(task.status, at: 6, statement: taskStatement)
            bindOptionalText(task.initiativeID, at: 7, statement: taskStatement)
            bindOptionalText(task.actorId, at: 8, statement: taskStatement)
            bindOptionalText(task.teamId, at: 9, statement: taskStatement)
            bindOptionalText(task.claimedActorId, at: 10, statement: taskStatement)
            bindOptionalText(task.claimedAgentId, at: 11, statement: taskStatement)
            bindOptionalText(task.parentTaskId, at: 12, statement: taskStatement)
            bindOptionalText(task.createdBy, at: 13, statement: taskStatement)
            bindText(dependsOnTaskIdsJSON, at: 14, statement: taskStatement)
            bindOptionalText(task.swarmId, at: 15, statement: taskStatement)
            bindOptionalText(task.swarmTaskId, at: 16, statement: taskStatement)
            bindOptionalText(task.swarmParentTaskId, at: 17, statement: taskStatement)
            bindText(dependencyIdsJSON, at: 18, statement: taskStatement)
            if let swarmDepth = task.swarmDepth {
                sqlite3_bind_int(taskStatement, 19, Int32(swarmDepth))
            } else {
                sqlite3_bind_null(taskStatement, 19)
            }
            bindText(actorPathJSON, at: 20, statement: taskStatement)
            bindText(isoFormatter.string(from: task.createdAt), at: 21, statement: taskStatement)
            bindText(isoFormatter.string(from: task.updatedAt), at: 22, statement: taskStatement)
            bindOptionalText(task.worktreeBranch, at: 23, statement: taskStatement)
            bindOptionalText(task.sourceControlProviderId, at: 24, statement: taskStatement)
            bindOptionalText(task.kind?.rawValue, at: 25, statement: taskStatement)
            bindOptionalText(task.loopModeOverride?.rawValue, at: 26, statement: taskStatement)
            bindOptionalText(task.originType?.rawValue, at: 27, statement: taskStatement)
            bindOptionalText(task.originChannelId, at: 28, statement: taskStatement)
            sqlite3_bind_int(taskStatement, 29, task.isArchived ? 1 : 0)
            bindOptionalText(task.selectedModel, at: 30, statement: taskStatement)
            bindText(attachmentsJSON, at: 31, statement: taskStatement)
            bindOptionalText(externalJSON, at: 32, statement: taskStatement)
            bindText(tagsJSON, at: 33, statement: taskStatement)
            bindOptionalText(task.executionNodeId, at: 34, statement: taskStatement)
            bindOptionalText(task.kanbanColumnEnteredAt.map { isoFormatter.string(from: $0) }, at: 35, statement: taskStatement)
            let assignmentsJSON = task.stageAssignments.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
            bindOptionalText(assignmentsJSON, at: 36, statement: taskStatement)
            bindOptionalText(task.activeStage?.rawValue, at: 37, statement: taskStatement)
            _ = sqlite3_step(taskStatement)
        }
#endif
    }

    public func deleteProject(id: String) async {
        fallbackProjects[id] = nil
        persistFallbackProjectsToDisk()
#if canImport(CSQLite3)
        guard let db else {
            return
        }

        removeProjectChildren(db: db, projectID: id)

        let sql =
            """
            DELETE FROM dashboard_projects
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    // MARK: - Canvas Workspaces

    public func listWorkspaces() async -> [WorkspaceRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackWorkspaces.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        let sql =
            """
            SELECT id, title, description, cover, owner_id, project_id, revision, is_archived, created_at, updated_at
            FROM workspaces
            ORDER BY updated_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackWorkspaces.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        defer { sqlite3_finalize(statement) }
        var records: [WorkspaceRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodeWorkspace(statement: statement) {
                records.append(record)
            }
        }
        return records
#else
        return fallbackWorkspaces.values.sorted { $0.updatedAt > $1.updatedAt }
#endif
    }

    public func workspace(id: String) async -> WorkspaceRecord? {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkspaces[id] }
        let sql =
            """
            SELECT id, title, description, cover, owner_id, project_id, revision, is_archived, created_at, updated_at
            FROM workspaces
            WHERE id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackWorkspaces[id]
        }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return fallbackWorkspaces[id] }
        return decodeWorkspace(statement: statement)
#else
        return fallbackWorkspaces[id]
#endif
    }

    public func saveWorkspace(_ workspace: WorkspaceRecord) async {
        fallbackWorkspaces[workspace.id] = workspace
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT INTO workspaces(
                id, title, description, cover, owner_id, project_id, revision, is_archived, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                description = excluded.description,
                cover = excluded.cover,
                owner_id = excluded.owner_id,
                project_id = excluded.project_id,
                revision = excluded.revision,
                is_archived = excluded.is_archived,
                updated_at = excluded.updated_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(workspace.id, at: 1, statement: statement)
        bindText(workspace.title, at: 2, statement: statement)
        bindText(workspace.description, at: 3, statement: statement)
        bindOptionalText(workspace.cover, at: 4, statement: statement)
        bindText(workspace.ownerId, at: 5, statement: statement)
        bindOptionalText(workspace.projectId, at: 6, statement: statement)
        sqlite3_bind_int64(statement, 7, sqlite3_int64(workspace.revision))
        sqlite3_bind_int(statement, 8, workspace.isArchived ? 1 : 0)
        bindText(isoFormatter.string(from: workspace.createdAt), at: 9, statement: statement)
        bindText(isoFormatter.string(from: workspace.updatedAt), at: 10, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func workspaceDocument(id: String) async -> WorkspaceDocument? {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkspaceDocuments[id] }
        let sql = "SELECT document_json FROM workspace_snapshots WHERE workspace_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackWorkspaceDocuments[id]
        }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let payload = sqlite3_column_text(statement, 0)
        else {
            return fallbackWorkspaceDocuments[id]
        }
        return decodeJSON(
            WorkspaceDocument.self,
            from: String(cString: payload),
            fallback: WorkspaceDocument(workspaceId: id)
        )
#else
        return fallbackWorkspaceDocuments[id]
#endif
    }

    public func saveWorkspaceDocument(_ document: WorkspaceDocument) async {
        fallbackWorkspaceDocuments[document.workspaceId] = document
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO workspace_snapshots(workspace_id, revision, document_json, created_at)
            VALUES(?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(document.workspaceId, at: 1, statement: statement)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(document.revision))
        bindText(jsonString(document, fallback: "{}"), at: 3, statement: statement)
        bindText(isoFormatter.string(from: Date()), at: 4, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func listWorkspaceTransactions(
        workspaceId: String,
        afterRevision: Int
    ) async -> [WorkspaceCommittedTransaction] {
#if canImport(CSQLite3)
        guard let db else {
            return (fallbackWorkspaceTransactions[workspaceId] ?? [])
                .filter { $0.revision > afterRevision }
                .sorted { $0.revision < $1.revision }
        }
        let sql =
            """
            SELECT transaction_json
            FROM workspace_transactions
            WHERE workspace_id = ? AND revision > ?
            ORDER BY revision ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(workspaceId, at: 1, statement: statement)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(afterRevision))
        var records: [WorkspaceCommittedTransaction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let payload = sqlite3_column_text(statement, 0),
                  let data = String(cString: payload).data(using: .utf8),
                  let record = try? JSONDecoder().decode(WorkspaceCommittedTransaction.self, from: data)
            else {
                continue
            }
            records.append(record)
        }
        return records
#else
        return (fallbackWorkspaceTransactions[workspaceId] ?? [])
            .filter { $0.revision > afterRevision }
            .sorted { $0.revision < $1.revision }
#endif
    }

    public func workspaceTransaction(
        workspaceId: String,
        transactionId: String
    ) async -> WorkspaceCommittedTransaction? {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackWorkspaceTransactions[workspaceId]?.first { $0.id == transactionId }
        }
        let sql =
            """
            SELECT transaction_json
            FROM workspace_transactions
            WHERE workspace_id = ? AND id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(workspaceId, at: 1, statement: statement)
        bindText(transactionId, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let payload = sqlite3_column_text(statement, 0),
              let data = String(cString: payload).data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(WorkspaceCommittedTransaction.self, from: data)
#else
        return fallbackWorkspaceTransactions[workspaceId]?.first { $0.id == transactionId }
#endif
    }

    public func saveWorkspaceTransaction(_ transaction: WorkspaceCommittedTransaction) async {
        var fallback = fallbackWorkspaceTransactions[transaction.workspaceId] ?? []
        if let index = fallback.firstIndex(where: { $0.id == transaction.id }) {
            fallback[index] = transaction
        } else {
            fallback.append(transaction)
        }
        fallbackWorkspaceTransactions[transaction.workspaceId] = fallback
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO workspace_transactions(
                workspace_id, id, revision, transaction_json, created_at
            ) VALUES(?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(transaction.workspaceId, at: 1, statement: statement)
        bindText(transaction.id, at: 2, statement: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(transaction.revision))
        bindText(jsonString(transaction, fallback: "{}"), at: 4, statement: statement)
        bindText(isoFormatter.string(from: transaction.createdAt), at: 5, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func listWorkspaceMembers(workspaceId: String) async -> [WorkspaceMember] {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkspaceMembers[workspaceId] ?? [] }
        let sql =
            """
            SELECT principal_kind, principal_id, role, created_at
            FROM workspace_members
            WHERE workspace_id = ?
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(workspaceId, at: 1, statement: statement)
        var members: [WorkspaceMember] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kindPtr = sqlite3_column_text(statement, 0),
                  let idPtr = sqlite3_column_text(statement, 1),
                  let rolePtr = sqlite3_column_text(statement, 2),
                  let createdPtr = sqlite3_column_text(statement, 3),
                  let kind = WorkspacePrincipalKind(rawValue: String(cString: kindPtr)),
                  let role = WorkspaceMemberRole(rawValue: String(cString: rolePtr))
            else {
                continue
            }
            members.append(WorkspaceMember(
                workspaceId: workspaceId,
                principalKind: kind,
                principalId: String(cString: idPtr),
                role: role,
                createdAt: isoFormatter.date(from: String(cString: createdPtr)) ?? Date()
            ))
        }
        return members
#else
        return fallbackWorkspaceMembers[workspaceId] ?? []
#endif
    }

    public func saveWorkspaceMember(_ member: WorkspaceMember) async {
        var fallback = fallbackWorkspaceMembers[member.workspaceId] ?? []
        fallback.removeAll {
            $0.principalKind == member.principalKind && $0.principalId == member.principalId
        }
        fallback.append(member)
        fallbackWorkspaceMembers[member.workspaceId] = fallback
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO workspace_members(
                workspace_id, principal_kind, principal_id, role, created_at
            ) VALUES(?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(member.workspaceId, at: 1, statement: statement)
        bindText(member.principalKind.rawValue, at: 2, statement: statement)
        bindText(member.principalId, at: 3, statement: statement)
        bindText(member.role.rawValue, at: 4, statement: statement)
        bindText(isoFormatter.string(from: member.createdAt), at: 5, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func deleteWorkspaceMember(
        workspaceId: String,
        principalKind: WorkspacePrincipalKind,
        principalId: String
    ) async {
        fallbackWorkspaceMembers[workspaceId]?.removeAll {
            $0.principalKind == principalKind && $0.principalId == principalId
        }
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            DELETE FROM workspace_members
            WHERE workspace_id = ? AND principal_kind = ? AND principal_id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(workspaceId, at: 1, statement: statement)
        bindText(principalKind.rawValue, at: 2, statement: statement)
        bindText(principalId, at: 3, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func listWorkspaceTemplates() async -> [WorkspaceTemplate] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackWorkspaceTemplates.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        let sql = "SELECT template_json FROM workspace_templates ORDER BY updated_at DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var templates: [WorkspaceTemplate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let payload = sqlite3_column_text(statement, 0),
                  let data = String(cString: payload).data(using: .utf8),
                  let template = try? JSONDecoder().decode(WorkspaceTemplate.self, from: data)
            else {
                continue
            }
            templates.append(template)
        }
        return templates
#else
        return fallbackWorkspaceTemplates.values.sorted { $0.updatedAt > $1.updatedAt }
#endif
    }

    public func saveWorkspaceTemplate(_ template: WorkspaceTemplate) async {
        fallbackWorkspaceTemplates[template.id] = template
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO workspace_templates(
                id, visibility, owner_id, template_json, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(template.id, at: 1, statement: statement)
        bindText(template.visibility.rawValue, at: 2, statement: statement)
        bindOptionalText(template.ownerId, at: 3, statement: statement)
        bindText(jsonString(template, fallback: "{}"), at: 4, statement: statement)
        bindText(isoFormatter.string(from: template.createdAt), at: 5, statement: statement)
        bindText(isoFormatter.string(from: template.updatedAt), at: 6, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    // MARK: - Channel Plugins

    public func listChannelPlugins() async -> [ChannelPluginRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackPlugins.values.sorted { $0.createdAt < $1.createdAt }
        }
        let result = loadChannelPlugins(db: db)
        if result.isEmpty && !fallbackPlugins.isEmpty {
            return fallbackPlugins.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackPlugins.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func channelPlugin(id: String) async -> ChannelPluginRecord? {
#if canImport(CSQLite3)
        if let db {
            let sql =
                """
                SELECT id, type, base_url, channel_ids_json, config_json, enabled, delivery_mode, created_at, updated_at
                FROM channel_plugins
                WHERE id = ?
                LIMIT 1;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackPlugins[id]
            }
            defer { sqlite3_finalize(statement) }
            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return decodePluginRow(statement: statement)
            }
            return nil
        }
#endif
        return fallbackPlugins[id]
    }

    public func saveChannelPlugin(_ plugin: ChannelPluginRecord) async {
        fallbackPlugins[plugin.id] = plugin
#if canImport(CSQLite3)
        guard let db else { return }

        let sql =
            """
            INSERT OR REPLACE INTO channel_plugins(
                id, type, base_url, channel_ids_json, config_json, enabled, delivery_mode, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let channelIdsJSON = (try? String(data: JSONEncoder().encode(plugin.channelIds), encoding: .utf8)) ?? "[]"
        let configJSON = (try? String(data: JSONEncoder().encode(plugin.config), encoding: .utf8)) ?? "{}"

        bindText(plugin.id, at: 1, statement: statement)
        bindText(plugin.type, at: 2, statement: statement)
        bindText(plugin.baseUrl, at: 3, statement: statement)
        bindText(channelIdsJSON, at: 4, statement: statement)
        bindText(configJSON, at: 5, statement: statement)
        sqlite3_bind_int(statement, 6, plugin.enabled ? 1 : 0)
        bindText(plugin.deliveryMode, at: 7, statement: statement)
        bindText(isoFormatter.string(from: plugin.createdAt), at: 8, statement: statement)
        bindText(isoFormatter.string(from: plugin.updatedAt), at: 9, statement: statement)

        _ = sqlite3_step(statement)
#endif
    }

    public func deleteChannelPlugin(id: String) async {
        fallbackPlugins[id] = nil
#if canImport(CSQLite3)
        guard let db else { return }

        let sql = "DELETE FROM channel_plugins WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    // MARK: - Agent Plugins

    public func listAgentPlugins() async -> [InstalledAgentPlugin] {
#if canImport(CSQLite3)
        if let db {
            return loadAgentPluginJSONRows(db: db, table: "agent_plugins", as: InstalledAgentPlugin.self)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
#endif
        return fallbackAgentPlugins.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func agentPlugin(id: String) async -> InstalledAgentPlugin? {
#if canImport(CSQLite3)
        if let db {
            return loadAgentPluginJSONRow(db: db, table: "agent_plugins", id: id, as: InstalledAgentPlugin.self)
        }
#endif
        return fallbackAgentPlugins[id]
    }

    public func saveAgentPlugin(_ plugin: InstalledAgentPlugin) async {
        fallbackAgentPlugins[plugin.id] = plugin
#if canImport(CSQLite3)
        if let db { saveAgentPluginJSONRow(db: db, table: "agent_plugins", id: plugin.id, value: plugin) }
#endif
    }

    public func deleteAgentPlugin(id: String) async {
        fallbackAgentPlugins[id] = nil
#if canImport(CSQLite3)
        if let db { deleteAgentPluginJSONRow(db: db, table: "agent_plugins", id: id) }
#endif
    }

    public func listAgentPluginRegistries() async -> [AgentPluginRegistry] {
#if canImport(CSQLite3)
        let values: [AgentPluginRegistry]
        if let db {
            values = loadAgentPluginJSONRows(db: db, table: "agent_plugin_registries", as: AgentPluginRegistry.self)
        } else {
            values = Array(fallbackAgentPluginRegistries.values)
        }
#else
        let values = Array(fallbackAgentPluginRegistries.values)
#endif
        return values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func saveAgentPluginRegistry(_ registry: AgentPluginRegistry) async {
        if registry.isDefault {
            for key in fallbackAgentPluginRegistries.keys { fallbackAgentPluginRegistries[key]?.isDefault = false }
            for existing in await listAgentPluginRegistries() where existing.id != registry.id && existing.isDefault {
                var updated = existing
                updated.isDefault = false
                fallbackAgentPluginRegistries[updated.id] = updated
#if canImport(CSQLite3)
                if let db { saveAgentPluginJSONRow(db: db, table: "agent_plugin_registries", id: updated.id, value: updated) }
#endif
            }
        }
        fallbackAgentPluginRegistries[registry.id] = registry
#if canImport(CSQLite3)
        if let db { saveAgentPluginJSONRow(db: db, table: "agent_plugin_registries", id: registry.id, value: registry) }
#endif
    }

    public func deleteAgentPluginRegistry(id: String) async {
        fallbackAgentPluginRegistries[id] = nil
#if canImport(CSQLite3)
        if let db { deleteAgentPluginJSONRow(db: db, table: "agent_plugin_registries", id: id) }
#endif
    }

#if canImport(CSQLite3)
    private func loadAgentPluginJSONRows<T: Decodable>(db: OpaquePointer, table: String, as type: T.Type) -> [T] {
        let allowedTables = ["agent_plugins", "agent_plugin_registries"]
        guard allowedTables.contains(table) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT record_json FROM \(table);", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0),
                  let data = String(cString: pointer).data(using: .utf8),
                  let value = try? JSONDecoder().decode(T.self, from: data)
            else { continue }
            result.append(value)
        }
        return result
    }

    private func loadAgentPluginJSONRow<T: Decodable>(db: OpaquePointer, table: String, id: String, as type: T.Type) -> T? {
        let allowedTables = ["agent_plugins", "agent_plugin_registries"]
        guard allowedTables.contains(table) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT record_json FROM \(table) WHERE id = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0),
              let data = String(cString: pointer).data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveAgentPluginJSONRow<T: Encodable>(db: OpaquePointer, table: String, id: String, value: T) {
        let allowedTables = ["agent_plugins", "agent_plugin_registries"]
        guard allowedTables.contains(table),
              let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO \(table)(id, record_json, updated_at) VALUES(?, ?, ?);", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        bindText(json, at: 2, statement: statement)
        bindText(isoFormatter.string(from: Date()), at: 3, statement: statement)
        _ = sqlite3_step(statement)
    }

    private func deleteAgentPluginJSONRow(db: OpaquePointer, table: String, id: String) {
        let allowedTables = ["agent_plugins", "agent_plugin_registries"]
        guard allowedTables.contains(table) else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
    }
#endif

    private func persistFallbackProjectsToDisk() {
        let projects = fallbackProjects.values.sorted { left, right in
            left.createdAt < right.createdAt
        }

        let parentDirectory = fallbackProjectsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(projects) else {
            return
        }

        try? payload.write(to: fallbackProjectsFileURL, options: .atomic)
    }

    private static func resolveFallbackProjectsFileURL(
        sqlitePath: String,
        explicitPath: String?
    ) -> URL {
        if let explicitPath {
            let trimmed = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed)
            }
        }

        let fileManager = FileManager.default
        let sqliteDirectory = URL(fileURLWithPath: sqlitePath).deletingLastPathComponent().path
        let sqliteFileName = URL(fileURLWithPath: sqlitePath).lastPathComponent
        let fallbackFileName: String
        if sqliteFileName.isEmpty {
            fallbackFileName = "dashboard-projects-fallback.json"
        } else {
            fallbackFileName = "\(sqliteFileName).dashboard-projects-fallback.json"
        }
        if fileManager.isWritableFile(atPath: sqliteDirectory) {
            return URL(fileURLWithPath: sqliteDirectory, isDirectory: true)
                .appendingPathComponent(fallbackFileName)
        }

        let dataDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".data", isDirectory: true)
        return dataDirectory.appendingPathComponent(fallbackFileName)
    }

    private static func loadFallbackProjects(from fileURL: URL) -> [String: ProjectRecord] {
        guard let payload = try? Data(contentsOf: fileURL) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ProjectRecord].self, from: payload) else {
            return [:]
        }

        var map: [String: ProjectRecord] = [:]
        for project in decoded {
            map[project.id] = project
        }
        return map
    }

    private static func projectListRecord(_ project: ProjectRecord) -> ProjectListRecord {
        var counts = ProjectTaskCountSummary(total: project.tasks.count)
        for task in project.tasks {
            switch ProjectTaskStatus(rawValue: task.status) {
            case .backlog: counts.backlog += 1
            case .ready: counts.ready += 1
            case .inProgress: counts.inProgress += 1
            case .waitingInput: counts.waitingInput += 1
            case .blocked: counts.blocked += 1
            case .needsReview: counts.needsReview += 1
            case .done: counts.done += 1
            default: break
            }
        }
        return ProjectListRecord(
            id: project.id,
            name: project.name,
            description: project.description,
            icon: project.icon,
            kind: project.kind,
            directoryPaths: project.directoryPaths,
            channels: project.channels,
            actors: project.actors,
            teams: project.teams,
            repoPath: project.repoPath,
            sourceControlProviderId: project.sourceControlProviderId,
            taskCounts: counts,
            isFavorite: project.isFavorite,
            isArchived: project.isArchived,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    private func sortedFallbackEvents() -> [EventEnvelope] {
        fallbackEvents.sorted { left, right in
            if left.ts == right.ts {
                return left.messageId < right.messageId
            }
            return left.ts < right.ts
        }
    }

    private func filteredFallbackChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) -> [EventEnvelope] {
        var filtered = fallbackEvents
            .filter { $0.channelId == channelId }
            .sorted { left, right in
                if left.ts == right.ts {
                    return left.messageId > right.messageId
                }
                return left.ts > right.ts
            }

        filtered.removeAll { event in
            if let before, !(event.ts < before) {
                return true
            }
            if let after, !(event.ts > after) {
                return true
            }
            if let cursor {
                if event.ts > cursor.createdAt {
                    return true
                }
                if event.ts == cursor.createdAt, event.messageId >= cursor.eventId {
                    return true
                }
            }
            return false
        }

        return Array(filtered.prefix(limit))
    }

    private func persistFallbackEvent(_ event: EventEnvelope) {
        fallbackEvents.append(event)
        upsertFallbackChannel(channelId: event.channelId, timestamp: event.ts)
        upsertFallbackTask(event: event)
    }

    private func persistFallbackArtifact(record: PersistedArtifactRecord) {
        fallbackArtifacts[record.id] = record
    }

    private func upsertFallbackChannel(channelId: String, timestamp: Date) {
        if var existing = fallbackChannels[channelId] {
            existing.updatedAt = max(existing.updatedAt, timestamp)
            fallbackChannels[channelId] = existing
            return
        }

        fallbackChannels[channelId] = PersistedChannelRecord(
            id: channelId,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func upsertFallbackTask(event: EventEnvelope) {
        guard let taskID = event.taskId, !taskID.isEmpty else {
            return
        }

        let payload = event.payload.objectValue
        let status = inferredTaskStatus(from: event.messageType)
        let title = payload["title"]?.stringValue ?? payload["progress"]?.stringValue
        let objective = payload["objective"]?.stringValue

        if var existing = fallbackTasks[taskID] {
            existing.channelId = event.channelId
            existing.status = status ?? existing.status
            if let title, !title.isEmpty {
                existing.title = title
            }
            if let objective, !objective.isEmpty {
                existing.objective = objective
            }
            existing.updatedAt = max(existing.updatedAt, event.ts)
            fallbackTasks[taskID] = existing
            return
        }

        fallbackTasks[taskID] = PersistedTaskRecord(
            id: taskID,
            channelId: event.channelId,
            status: status ?? "unknown",
            title: title ?? "Task \(taskID)",
            objective: objective ?? "",
            createdAt: event.ts,
            updatedAt: event.ts
        )
    }

    private func inferredTaskStatus(from messageType: MessageType) -> String? {
        switch messageType {
        case .workerSpawned:
            "queued"
        case .workerProgress:
            "running"
        case .workerCompleted:
            "completed"
        case .workerFailed:
            "failed"
        default:
            nil
        }
    }

#if canImport(CSQLite3)
    private func removeProjectChildren(db: OpaquePointer, projectID: String) {
        let deleteChannelsSQL =
            """
            DELETE FROM dashboard_project_channels
            WHERE project_id = ?;
            """
        var channelsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteChannelsSQL, -1, &channelsStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(channelsStatement) }
            bindText(projectID, at: 1, statement: channelsStatement)
            _ = sqlite3_step(channelsStatement)
        }

        let deleteTasksSQL =
            """
            DELETE FROM dashboard_project_tasks
            WHERE project_id = ?;
            """
        var tasksStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteTasksSQL, -1, &tasksStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(tasksStatement) }
            bindText(projectID, at: 1, statement: tasksStatement)
            _ = sqlite3_step(tasksStatement)
        }
    }

    private func loadProjectChannels(db: OpaquePointer, projectID: String) -> [ProjectChannel] {
        let sql =
            """
            SELECT id, title, channel_id, created_at
            FROM dashboard_project_channels
            WHERE project_id = ?
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bindText(projectID, at: 1, statement: statement)

        var result: [ProjectChannel] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let titlePtr = sqlite3_column_text(statement, 1),
                let channelIDPtr = sqlite3_column_text(statement, 2),
                let createdAtPtr = sqlite3_column_text(statement, 3)
            else {
                continue
            }
            result.append(
                ProjectChannel(
                    id: String(cString: idPtr),
                    title: String(cString: titlePtr),
                    channelId: String(cString: channelIDPtr),
                    createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
                )
            )
        }

        return result
    }

    private func loadProjectTasks(db: OpaquePointer, projectID: String) -> [ProjectTask] {
        let sql =
            """
            SELECT
                id,
                title,
                description,
                priority,
                status,
                initiative_id,
                actor_id,
                team_id,
                claimed_actor_id,
                claimed_agent_id,
                parent_task_id,
                created_by,
                depends_on_task_ids_json,
                swarm_id,
                swarm_task_id,
                swarm_parent_task_id,
                swarm_dependency_ids_json,
                swarm_depth,
                swarm_actor_path_json,
                created_at,
                updated_at,
                worktree_branch,
                source_control_provider_id,
                kind,
                loop_mode_override,
                origin_type,
                origin_channel_id,
                is_archived,
                selected_model,
                attachments_json,
                external_metadata_json,
                tags_json,
                execution_node_id,
                kanban_column_entered_at,
                stage_assignments_json,
                active_stage
            FROM dashboard_project_tasks
            WHERE project_id = ?
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bindText(projectID, at: 1, statement: statement)

        var result: [ProjectTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let titlePtr = sqlite3_column_text(statement, 1),
                let descriptionPtr = sqlite3_column_text(statement, 2),
                let priorityPtr = sqlite3_column_text(statement, 3),
                let statusPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 19),
                let updatedAtPtr = sqlite3_column_text(statement, 20)
            else {
                continue
            }
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            let dependsOnTaskIds = decodeOptionalStringArray(optionalText(statement: statement, index: 12)) ?? []
            let dependencyIds = decodeOptionalStringArray(optionalText(statement: statement, index: 16))
            let actorPath = decodeOptionalStringArray(optionalText(statement: statement, index: 18))
            let kindRaw = optionalText(statement: statement, index: 23)
            let loopOverrideRaw = optionalText(statement: statement, index: 24)
            let originTypeRaw = optionalText(statement: statement, index: 25)
            let attachmentsJSON = optionalText(statement: statement, index: 29)
            let attachments = attachmentsJSON.flatMap { try? JSONDecoder().decode([AgentAttachmentUpload].self, from: Data($0.utf8)) } ?? []
            let externalJSON = optionalText(statement: statement, index: 30)
            let externalMetadata = externalJSON.flatMap { try? JSONDecoder().decode(TaskExternalMetadata.self, from: Data($0.utf8)) }
            let tags = decodeOptionalStringArray(optionalText(statement: statement, index: 31)) ?? []
            result.append(
                ProjectTask(
                    id: String(cString: idPtr),
                    title: String(cString: titlePtr),
                    description: String(cString: descriptionPtr),
                    priority: String(cString: priorityPtr),
                    status: String(cString: statusPtr),
                    initiativeID: optionalText(statement: statement, index: 5),
                    kind: kindRaw.flatMap { ProjectTaskKind(rawValue: $0) },
                    loopModeOverride: loopOverrideRaw.flatMap { ProjectLoopMode(rawValue: $0) },
                    originType: originTypeRaw.flatMap { TaskOriginType(rawValue: $0) },
                    originChannelId: optionalText(statement: statement, index: 26),
                    actorId: optionalText(statement: statement, index: 6),
                    executionNodeId: optionalText(statement: statement, index: 32),
                    teamId: optionalText(statement: statement, index: 7),
                    stageAssignments: optionalText(statement: statement, index: 34).flatMap {
                        try? JSONDecoder().decode(TaskStageAssignments.self, from: Data($0.utf8))
                    },
                    activeStage: optionalText(statement: statement, index: 35).flatMap(TaskExecutionStage.init(rawValue:)),
                    claimedActorId: optionalText(statement: statement, index: 8),
                    claimedAgentId: optionalText(statement: statement, index: 9),
                    parentTaskId: optionalText(statement: statement, index: 10),
                    createdBy: optionalText(statement: statement, index: 11),
                    dependsOnTaskIds: dependsOnTaskIds,
                    swarmId: optionalText(statement: statement, index: 13),
                    swarmTaskId: optionalText(statement: statement, index: 14),
                    swarmParentTaskId: optionalText(statement: statement, index: 15),
                    swarmDependencyIds: dependencyIds,
                    swarmDepth: optionalInt(statement: statement, index: 17),
                    swarmActorPath: actorPath,
                    worktreeBranch: optionalText(statement: statement, index: 21),
                    sourceControlProviderId: optionalText(statement: statement, index: 22),
                    selectedModel: optionalText(statement: statement, index: 28),
                    externalMetadata: externalMetadata,
                    attachments: attachments,
                    tags: tags,
                    isArchived: sqlite3_column_int(statement, 27) != 0,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    kanbanColumnEnteredAt: optionalText(statement: statement, index: 33).flatMap { isoFormatter.date(from: $0) }
                )
            )
        }

        return result
    }

    private func loadPersistedEvents(db: OpaquePointer) -> [EventEnvelope] {
        let sql =
            """
            SELECT id, message_type, channel_id, task_id, branch_id, worker_id, payload_json, extensions_json, created_at
            FROM events
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [EventEnvelope] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let messageTypePtr = sqlite3_column_text(statement, 1),
                let channelIDPtr = sqlite3_column_text(statement, 2),
                let payloadPtr = sqlite3_column_text(statement, 6),
                let extensionsPtr = sqlite3_column_text(statement, 7),
                let createdAtPtr = sqlite3_column_text(statement, 8)
            else {
                continue
            }

            let messageID = String(cString: idPtr)
            let rawMessageType = String(cString: messageTypePtr)
            guard let messageType = MessageType(rawValue: rawMessageType) else {
                continue
            }

            let timestamp = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let payloadJSON = String(cString: payloadPtr)
            let payloadData = Data(payloadJSON.utf8)
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: payloadData)) ?? .object([:])
            let extensionsJSON = String(cString: extensionsPtr)
            let extensionsData = Data(extensionsJSON.utf8)
            let extensions = (try? JSONDecoder().decode([String: JSONValue].self, from: extensionsData)) ?? [:]

            result.append(
                EventEnvelope(
                    messageId: messageID,
                    messageType: messageType,
                    ts: timestamp,
                    traceId: messageID,
                    channelId: String(cString: channelIDPtr),
                    taskId: optionalText(statement: statement, index: 3),
                    branchId: optionalText(statement: statement, index: 4),
                    workerId: optionalText(statement: statement, index: 5),
                    payload: payload,
                    extensions: extensions
                )
            )
        }

        return result
    }

    private func loadChannelEvents(
        db: OpaquePointer,
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) -> [EventEnvelope] {
        var conditions: [String] = ["channel_id = ?"]
        if before != nil {
            conditions.append("created_at < ?")
        }
        if after != nil {
            conditions.append("created_at > ?")
        }
        if cursor != nil {
            conditions.append("(created_at < ? OR (created_at = ? AND id < ?))")
        }

        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        let sql =
            """
            SELECT id, message_type, channel_id, task_id, branch_id, worker_id, payload_json, extensions_json, created_at
            FROM events
            \(whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var parameter: Int32 = 1
        bindText(channelId, at: parameter, statement: statement)
        parameter += 1

        if let before {
            bindText(isoFormatter.string(from: before), at: parameter, statement: statement)
            parameter += 1
        }
        if let after {
            bindText(isoFormatter.string(from: after), at: parameter, statement: statement)
            parameter += 1
        }
        if let cursor {
            let cursorTimestamp = isoFormatter.string(from: cursor.createdAt)
            bindText(cursorTimestamp, at: parameter, statement: statement)
            parameter += 1
            bindText(cursorTimestamp, at: parameter, statement: statement)
            parameter += 1
            bindText(cursor.eventId, at: parameter, statement: statement)
            parameter += 1
        }

        sqlite3_bind_int(statement, parameter, Int32(limit))

        var result: [EventEnvelope] = []
        result.reserveCapacity(limit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let messageTypePtr = sqlite3_column_text(statement, 1),
                let channelIDPtr = sqlite3_column_text(statement, 2),
                let payloadPtr = sqlite3_column_text(statement, 6),
                let extensionsPtr = sqlite3_column_text(statement, 7),
                let createdAtPtr = sqlite3_column_text(statement, 8)
            else {
                continue
            }

            let messageID = String(cString: idPtr)
            let rawMessageType = String(cString: messageTypePtr)
            guard let messageType = MessageType(rawValue: rawMessageType) else {
                continue
            }

            let timestamp = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let payloadJSON = String(cString: payloadPtr)
            let payloadData = Data(payloadJSON.utf8)
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: payloadData)) ?? .object([:])
            let extensionsJSON = String(cString: extensionsPtr)
            let extensionsData = Data(extensionsJSON.utf8)
            let extensions = (try? JSONDecoder().decode([String: JSONValue].self, from: extensionsData)) ?? [:]

            result.append(
                EventEnvelope(
                    messageId: messageID,
                    messageType: messageType,
                    ts: timestamp,
                    traceId: messageID,
                    channelId: String(cString: channelIDPtr),
                    taskId: optionalText(statement: statement, index: 3),
                    branchId: optionalText(statement: statement, index: 4),
                    workerId: optionalText(statement: statement, index: 5),
                    payload: payload,
                    extensions: extensions
                )
            )
        }

        return result
    }

    private func loadPersistedChannels(db: OpaquePointer) -> [PersistedChannelRecord] {
        let sql =
            """
            SELECT id, created_at, updated_at
            FROM channels
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [PersistedChannelRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let createdAtPtr = sqlite3_column_text(statement, 1),
                let updatedAtPtr = sqlite3_column_text(statement, 2)
            else {
                continue
            }
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            result.append(
                PersistedChannelRecord(
                    id: String(cString: idPtr),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
    }

    private func loadPersistedTasks(db: OpaquePointer) -> [PersistedTaskRecord] {
        let sql =
            """
            SELECT id, channel_id, status, title, objective, created_at, updated_at
            FROM tasks
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [PersistedTaskRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let channelIDPtr = sqlite3_column_text(statement, 1),
                let statusPtr = sqlite3_column_text(statement, 2),
                let titlePtr = sqlite3_column_text(statement, 3),
                let objectivePtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 5),
                let updatedAtPtr = sqlite3_column_text(statement, 6)
            else {
                continue
            }

            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            result.append(
                PersistedTaskRecord(
                    id: String(cString: idPtr),
                    channelId: String(cString: channelIDPtr),
                    status: String(cString: statusPtr),
                    title: String(cString: titlePtr),
                    objective: String(cString: objectivePtr),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
    }

    private func loadPersistedArtifacts(db: OpaquePointer) -> [PersistedArtifactRecord] {
        let sql =
            """
            SELECT
                id,
                title,
                kind,
                media_type,
                content,
                preview_text,
                widget_size,
                widget_width,
                widget_height,
                widget_entry,
                bundle_path,
                created_at
            FROM artifacts
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [PersistedArtifactRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let record = persistedArtifact(from: statement) else {
                continue
            }
            result.append(record)
        }

        return result
    }

    private func persistedArtifact(from statement: OpaquePointer?) -> PersistedArtifactRecord? {
        guard
            let statement,
            let idPtr = sqlite3_column_text(statement, 0),
            let contentPtr = sqlite3_column_text(statement, 4),
            let createdAtPtr = sqlite3_column_text(statement, 11)
        else {
            return nil
        }

        let id = String(cString: idPtr)
        let title = optionalText(statement: statement, index: 1) ?? id
        let kind = optionalText(statement: statement, index: 2) ?? "document"
        let mediaType = optionalText(statement: statement, index: 3) ?? "text/plain"
        let content = String(cString: contentPtr)
        let previewText = optionalText(statement: statement, index: 5)
        let widgetSize = optionalText(statement: statement, index: 6)
        let widgetWidth = optionalInt(statement: statement, index: 7)
        let widgetHeight = optionalInt(statement: statement, index: 8)
        let widgetEntry = optionalText(statement: statement, index: 9)
        let bundlePath = optionalText(statement: statement, index: 10)
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()

        return PersistedArtifactRecord(
            id: id,
            title: title,
            kind: kind,
            mediaType: mediaType,
            content: content,
            previewText: previewText,
            widgetSize: widgetSize,
            widgetWidth: widgetWidth,
            widgetHeight: widgetHeight,
            widgetEntry: widgetEntry,
            bundlePath: bundlePath,
            createdAt: createdAt
        )
    }

    private func initiativeRecord(from statement: OpaquePointer?) -> InitiativeRecord? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let projectIdPtr = sqlite3_column_text(statement, 1),
            let titlePtr = sqlite3_column_text(statement, 2),
            let goalPtr = sqlite3_column_text(statement, 3),
            let phasePtr = sqlite3_column_text(statement, 4),
            let modePtr = sqlite3_column_text(statement, 5),
            let successMetricsPtr = sqlite3_column_text(statement, 6),
            let constraintsPtr = sqlite3_column_text(statement, 7),
            let metadataPtr = sqlite3_column_text(statement, 10),
            let createdAtPtr = sqlite3_column_text(statement, 11),
            let updatedAtPtr = sqlite3_column_text(statement, 12)
        else {
            return nil
        }

        let phase = InitiativePhase(rawValue: String(cString: phasePtr)) ?? .intake
        let mode = InitiativeExecutionMode(rawValue: String(cString: modePtr)) ?? .singleAgent
        let successMetrics = decodeJSON([String].self, from: String(cString: successMetricsPtr), fallback: [])
        let constraints = decodeJSON([String].self, from: String(cString: constraintsPtr), fallback: [])
        let metadata = decodeJSON([String: String].self, from: String(cString: metadataPtr), fallback: [:])
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

        return InitiativeRecord(
            id: String(cString: idPtr),
            projectID: String(cString: projectIdPtr),
            title: String(cString: titlePtr),
            goal: String(cString: goalPtr),
            phase: phase,
            executionMode: mode,
            successMetrics: successMetrics,
            constraints: constraints,
            resumePoint: optionalText(statement: statement, index: 8),
            blocker: optionalText(statement: statement, index: 9),
            metadata: metadata,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decisionPacketRecord(from statement: OpaquePointer?) -> DecisionPacketRecord? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let projectIdPtr = sqlite3_column_text(statement, 1),
            let initiativeIdPtr = sqlite3_column_text(statement, 2),
            let summaryPtr = sqlite3_column_text(statement, 3),
            let rationalePtr = sqlite3_column_text(statement, 4),
            let tradeoffsPtr = sqlite3_column_text(statement, 5),
            let requestedActionPtr = sqlite3_column_text(statement, 6),
            let statusPtr = sqlite3_column_text(statement, 8),
            let createdAtPtr = sqlite3_column_text(statement, 9),
            let updatedAtPtr = sqlite3_column_text(statement, 10)
        else {
            return nil
        }

        let tradeoffs = decodeJSON([String].self, from: String(cString: tradeoffsPtr), fallback: [])
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

        return DecisionPacketRecord(
            id: String(cString: idPtr),
            projectID: String(cString: projectIdPtr),
            initiativeID: String(cString: initiativeIdPtr),
            summary: String(cString: summaryPtr),
            rationale: String(cString: rationalePtr),
            tradeoffs: tradeoffs,
            requestedAction: String(cString: requestedActionPtr),
            resumePoint: optionalText(statement: statement, index: 7),
            status: String(cString: statusPtr),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func upsertChannel(db: OpaquePointer, channelId: String, timestamp: Date) {
        let createdAtText = isoFormatter.string(from: timestamp)
        let updatedAtText = createdAtText
        let insertSQL =
            """
            INSERT OR IGNORE INTO channels(id, created_at, updated_at)
            VALUES(?, ?, ?);
            """
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(insertStatement) }
            bindText(channelId, at: 1, statement: insertStatement)
            bindText(createdAtText, at: 2, statement: insertStatement)
            bindText(updatedAtText, at: 3, statement: insertStatement)
            _ = sqlite3_step(insertStatement)
        }

        let updateSQL =
            """
            UPDATE channels
            SET updated_at = ?
            WHERE id = ?;
            """
        var updateStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(updateStatement) }
            bindText(updatedAtText, at: 1, statement: updateStatement)
            bindText(channelId, at: 2, statement: updateStatement)
            _ = sqlite3_step(updateStatement)
        }
    }

    private func upsertTask(db: OpaquePointer, event: EventEnvelope) {
        guard let taskID = event.taskId, !taskID.isEmpty else {
            return
        }

        let existing = loadPersistedTask(db: db, taskID: taskID)
        let payload = event.payload.objectValue
        let status = inferredTaskStatus(from: event.messageType) ?? existing?.status ?? "unknown"
        let title = payload["title"]?.stringValue ?? payload["progress"]?.stringValue ?? existing?.title ?? "Task \(taskID)"
        let objective = payload["objective"]?.stringValue ?? existing?.objective ?? ""
        let createdAt = existing?.createdAt ?? event.ts
        let updatedAt = max(existing?.updatedAt ?? event.ts, event.ts)

        let sql =
            """
            INSERT OR REPLACE INTO tasks(
                id,
                channel_id,
                status,
                title,
                objective,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            upsertFallbackTask(event: event)
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(taskID, at: 1, statement: statement)
        bindText(event.channelId, at: 2, statement: statement)
        bindText(status, at: 3, statement: statement)
        bindText(title, at: 4, statement: statement)
        bindText(objective, at: 5, statement: statement)
        bindText(isoFormatter.string(from: createdAt), at: 6, statement: statement)
        bindText(isoFormatter.string(from: updatedAt), at: 7, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            upsertFallbackTask(event: event)
        }
    }

    private func loadPersistedTask(db: OpaquePointer, taskID: String) -> PersistedTaskRecord? {
        let sql =
            """
            SELECT id, channel_id, status, title, objective, created_at, updated_at
            FROM tasks
            WHERE id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bindText(taskID, at: 1, statement: statement)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let idPtr = sqlite3_column_text(statement, 0),
              let channelIDPtr = sqlite3_column_text(statement, 1),
              let statusPtr = sqlite3_column_text(statement, 2),
              let titlePtr = sqlite3_column_text(statement, 3),
              let objectivePtr = sqlite3_column_text(statement, 4),
              let createdAtPtr = sqlite3_column_text(statement, 5),
              let updatedAtPtr = sqlite3_column_text(statement, 6)
        else {
            return nil
        }

        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
        return PersistedTaskRecord(
            id: String(cString: idPtr),
            channelId: String(cString: channelIDPtr),
            status: String(cString: statusPtr),
            title: String(cString: titlePtr),
            objective: String(cString: objectivePtr),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decodeWorkspace(statement: OpaquePointer?) -> WorkspaceRecord? {
        guard let idPtr = sqlite3_column_text(statement, 0),
              let titlePtr = sqlite3_column_text(statement, 1),
              let descriptionPtr = sqlite3_column_text(statement, 2),
              let ownerPtr = sqlite3_column_text(statement, 4),
              let createdPtr = sqlite3_column_text(statement, 8),
              let updatedPtr = sqlite3_column_text(statement, 9)
        else {
            return nil
        }
        return WorkspaceRecord(
            id: String(cString: idPtr),
            title: String(cString: titlePtr),
            description: String(cString: descriptionPtr),
            cover: optionalText(statement: statement, index: 3),
            ownerId: String(cString: ownerPtr),
            projectId: optionalText(statement: statement, index: 5),
            revision: Int(sqlite3_column_int64(statement, 6)),
            isArchived: sqlite3_column_int(statement, 7) != 0,
            createdAt: isoFormatter.date(from: String(cString: createdPtr)) ?? Date(),
            updatedAt: isoFormatter.date(from: String(cString: updatedPtr)) ?? Date()
        )
    }

    private func bindText(_ value: String, at index: Int32, statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func bindOptionalText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            bindText(value, at: index, statement: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalInt(_ value: Int?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func optionalText(statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func optionalInt(statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func jsonString<T: Encodable>(_ value: T, fallback: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? fallback
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from value: String, fallback: T) -> T {
        (try? JSONDecoder().decode(type, from: Data(value.utf8))) ?? fallback
    }

    private func fallbackWorkflowRuns(projectId: String) -> [WorkflowRun] {
        fallbackWorkflowRuns.values
            .filter { $0.projectId == projectId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func fallbackWorkflowRunSteps(runId: String) -> [WorkflowRunStep] {
        fallbackWorkflowRunSteps.values
            .filter { $0.runId == runId }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func fallbackWorkflowPendingActions(projectId: String, includeResolved: Bool) -> [WorkflowPendingAction] {
        fallbackWorkflowPendingActions.values
            .filter { $0.projectId == projectId && (includeResolved || $0.resolvedAt == nil) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func fallbackWorkflowPendingActions(runId: String) -> [WorkflowPendingAction] {
        fallbackWorkflowPendingActions.values
            .filter { $0.workflowRunId == runId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func fallbackAutomationRuns(projectId: String) -> [AutomationRun] {
        fallbackAutomationRuns.values
            .filter { $0.projectId == projectId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func fallbackAutomationRuns(automationId: String) -> [AutomationRun] {
        fallbackAutomationRuns.values
            .filter { $0.automationId == automationId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func fallbackInitiatives(projectID: String) -> [InitiativeRecord] {
        fallbackProjectInitiatives.values
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func fallbackDecisionPackets(projectID: String, initiativeID: String) -> [DecisionPacketRecord] {
        fallbackDecisionPacketsByID.values
            .filter { $0.projectID == projectID && $0.initiativeID == initiativeID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func resolveFallbackWorkflowPendingAction(actionId: String, resolvedAt: Date) -> WorkflowPendingAction? {
        guard var action = fallbackWorkflowPendingActions[actionId] else {
            return nil
        }
        action.resolvedAt = resolvedAt
        fallbackWorkflowPendingActions[actionId] = action
        return action
    }

    private func workflowPendingAction(id: String) -> WorkflowPendingAction? {
#if canImport(CSQLite3)
        guard let db else { return fallbackWorkflowPendingActions[id] }
        let sql =
            """
            SELECT id, project_id, workflow_run_id, node_id, task_id, assignee, prompt, decisions_json, created_at, resolved_at
            FROM workflow_pending_actions
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeWorkflowPendingAction(statement: statement)
#else
        return fallbackWorkflowPendingActions[id]
#endif
    }

    private func decodeWorkflowRun(statement: OpaquePointer?) -> WorkflowRun? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let workflowIdPtr = sqlite3_column_text(statement, 1),
            let projectIdPtr = sqlite3_column_text(statement, 3),
            let statusPtr = sqlite3_column_text(statement, 5),
            let currentNodeIdsPtr = sqlite3_column_text(statement, 6),
            let startedByPtr = sqlite3_column_text(statement, 7),
            let startedAtPtr = sqlite3_column_text(statement, 8)
        else {
            return nil
        }
        let currentNodeIds = decodeJSON([String].self, from: String(cString: currentNodeIdsPtr), fallback: [])
        let startedAt = isoFormatter.date(from: String(cString: startedAtPtr)) ?? Date()
        let finishedAt = optionalText(statement: statement, index: 9).flatMap { isoFormatter.date(from: $0) }
        return WorkflowRun(
            id: String(cString: idPtr),
            workflowId: String(cString: workflowIdPtr),
            workflowVersion: Int(sqlite3_column_int(statement, 2)),
            projectId: String(cString: projectIdPtr),
            taskId: optionalText(statement: statement, index: 4),
            status: WorkflowRunStatus(rawValue: String(cString: statusPtr)) ?? .failed,
            currentNodeIds: currentNodeIds,
            startedBy: String(cString: startedByPtr),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private func decodeWorkflowRunStep(statement: OpaquePointer?) -> WorkflowRunStep? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let runIdPtr = sqlite3_column_text(statement, 1),
            let nodeIdPtr = sqlite3_column_text(statement, 2),
            let statusPtr = sqlite3_column_text(statement, 3),
            let inputPtr = sqlite3_column_text(statement, 4),
            let outputPtr = sqlite3_column_text(statement, 5),
            let startedAtPtr = sqlite3_column_text(statement, 7)
        else {
            return nil
        }
        let input = decodeJSON([String: JSONValue].self, from: String(cString: inputPtr), fallback: [:])
        let output = decodeJSON([String: JSONValue].self, from: String(cString: outputPtr), fallback: [:])
        let startedAt = isoFormatter.date(from: String(cString: startedAtPtr)) ?? Date()
        let finishedAt = optionalText(statement: statement, index: 8).flatMap { isoFormatter.date(from: $0) }
        return WorkflowRunStep(
            id: String(cString: idPtr),
            runId: String(cString: runIdPtr),
            nodeId: String(cString: nodeIdPtr),
            status: WorkflowStepStatus(rawValue: String(cString: statusPtr)) ?? .failed,
            input: input,
            output: output,
            error: optionalText(statement: statement, index: 6),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private func decodeWorkflowPendingAction(statement: OpaquePointer?) -> WorkflowPendingAction? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let projectIdPtr = sqlite3_column_text(statement, 1),
            let runIdPtr = sqlite3_column_text(statement, 2),
            let nodeIdPtr = sqlite3_column_text(statement, 3),
            let assigneePtr = sqlite3_column_text(statement, 5),
            let promptPtr = sqlite3_column_text(statement, 6),
            let decisionsPtr = sqlite3_column_text(statement, 7),
            let createdAtPtr = sqlite3_column_text(statement, 8)
        else {
            return nil
        }
        let decisions = decodeJSON([WorkflowHumanDecision].self, from: String(cString: decisionsPtr), fallback: [])
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let resolvedAt = optionalText(statement: statement, index: 9).flatMap { isoFormatter.date(from: $0) }
        return WorkflowPendingAction(
            id: String(cString: idPtr),
            projectId: String(cString: projectIdPtr),
            workflowRunId: String(cString: runIdPtr),
            nodeId: String(cString: nodeIdPtr),
            taskId: optionalText(statement: statement, index: 4),
            assignee: String(cString: assigneePtr),
            prompt: String(cString: promptPtr),
            decisions: decisions,
            createdAt: createdAt,
            resolvedAt: resolvedAt
        )
    }

    private func decodeAutomationRun(statement: OpaquePointer?) -> AutomationRun? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let automationIdPtr = sqlite3_column_text(statement, 1),
            let projectIdPtr = sqlite3_column_text(statement, 2),
            let workflowIdPtr = sqlite3_column_text(statement, 3),
            let repositoryPtr = sqlite3_column_text(statement, 5),
            let triggerTypePtr = sqlite3_column_text(statement, 6),
            let statusPtr = sqlite3_column_text(statement, 8),
            let startedAtPtr = sqlite3_column_text(statement, 11)
        else {
            return nil
        }
        let startedAt = isoFormatter.date(from: String(cString: startedAtPtr)) ?? Date()
        let finishedAt = optionalText(statement: statement, index: 12).flatMap { isoFormatter.date(from: $0) }
        return AutomationRun(
            id: String(cString: idPtr),
            automationId: String(cString: automationIdPtr),
            projectId: String(cString: projectIdPtr),
            workflowId: String(cString: workflowIdPtr),
            workflowRunId: optionalText(statement: statement, index: 4),
            repositoryFullName: String(cString: repositoryPtr),
            triggerType: AutomationTriggerKind(rawValue: String(cString: triggerTypePtr)) ?? .manual,
            triggerEventId: optionalText(statement: statement, index: 7),
            status: AutomationRunStatus(rawValue: String(cString: statusPtr)) ?? .failed,
            taskId: optionalText(statement: statement, index: 9),
            summary: optionalText(statement: statement, index: 10),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private static func applyProjectTaskMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }

        let statements = [
            "ALTER TABLE dashboard_project_tasks ADD COLUMN actor_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN initiative_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN team_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN claimed_actor_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN claimed_agent_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_task_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_parent_task_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_dependency_ids_json TEXT NOT NULL DEFAULT '[]';",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_depth INTEGER;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_actor_path_json TEXT NOT NULL DEFAULT '[]';",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN parent_task_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN created_by TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN depends_on_task_ids_json TEXT NOT NULL DEFAULT '[]';",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN execution_node_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN kanban_column_entered_at TEXT;"
        ]

        for statement in statements {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    private static func applyRuntimeEventMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE events ADD COLUMN extensions_json TEXT NOT NULL DEFAULT '{}';",
            nil, nil, nil
        )
    }

    private static func applyArtifactMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }

        let statements = [
            "ALTER TABLE artifacts ADD COLUMN title TEXT;",
            "ALTER TABLE artifacts ADD COLUMN kind TEXT;",
            "ALTER TABLE artifacts ADD COLUMN media_type TEXT;",
            "ALTER TABLE artifacts ADD COLUMN preview_text TEXT;",
            "ALTER TABLE artifacts ADD COLUMN widget_size TEXT;",
            "ALTER TABLE artifacts ADD COLUMN widget_width INTEGER;",
            "ALTER TABLE artifacts ADD COLUMN widget_height INTEGER;",
            "ALTER TABLE artifacts ADD COLUMN widget_entry TEXT;",
            "ALTER TABLE artifacts ADD COLUMN bundle_path TEXT;"
        ]

        for statement in statements {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    private static func applyWorkspaceMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                cover TEXT,
                owner_id TEXT NOT NULL,
                project_id TEXT,
                revision INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_workspaces_project_updated ON workspaces(project_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_workspaces_archived_updated ON workspaces(is_archived, updated_at DESC);
            CREATE TABLE IF NOT EXISTS workspace_members (
                workspace_id TEXT NOT NULL,
                principal_kind TEXT NOT NULL,
                principal_id TEXT NOT NULL,
                role TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(workspace_id, principal_kind, principal_id)
            );
            CREATE TABLE IF NOT EXISTS workspace_snapshots (
                workspace_id TEXT PRIMARY KEY,
                revision INTEGER NOT NULL,
                document_json TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS workspace_transactions (
                workspace_id TEXT NOT NULL,
                id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                transaction_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(workspace_id, id),
                UNIQUE(workspace_id, revision)
            );
            CREATE INDEX IF NOT EXISTS idx_workspace_transactions_revision
                ON workspace_transactions(workspace_id, revision);
            CREATE TABLE IF NOT EXISTS workspace_templates (
                id TEXT PRIMARY KEY,
                visibility TEXT NOT NULL,
                owner_id TEXT,
                template_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """,
            nil, nil, nil
        )
    }

    private static func applyInitiativeMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }

        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS project_initiatives (
                id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                title TEXT NOT NULL,
                goal TEXT NOT NULL,
                phase TEXT NOT NULL,
                execution_mode TEXT NOT NULL,
                success_metrics_json TEXT NOT NULL DEFAULT '[]',
                constraints_json TEXT NOT NULL DEFAULT '[]',
                resume_point TEXT,
                blocker TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (project_id, id)
            );
            """,
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "CREATE INDEX IF NOT EXISTS idx_project_initiatives_project ON project_initiatives(project_id, created_at DESC);",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS initiative_decision_packets (
                id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                initiative_id TEXT NOT NULL,
                summary TEXT NOT NULL,
                rationale TEXT NOT NULL,
                tradeoffs_json TEXT NOT NULL DEFAULT '[]',
                requested_action TEXT NOT NULL,
                resume_point TEXT,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (project_id, id)
            );
            """,
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            """
            CREATE INDEX IF NOT EXISTS idx_initiative_decision_packets_initiative
            ON initiative_decision_packets(project_id, initiative_id, created_at DESC);
            """,
            nil, nil, nil
        )
    }

    private static func applyChannelPluginMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE channel_plugins ADD COLUMN delivery_mode TEXT NOT NULL DEFAULT 'http';",
            nil, nil, nil
        )
    }

    private static func applyWorkflowMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS workflow_runs (
                id TEXT PRIMARY KEY,
                workflow_id TEXT NOT NULL,
                workflow_version INTEGER NOT NULL,
                project_id TEXT NOT NULL,
                task_id TEXT,
                status TEXT NOT NULL,
                current_node_ids_json TEXT NOT NULL,
                started_by TEXT NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_workflow_runs_project ON workflow_runs(project_id, started_at DESC);

            CREATE TABLE IF NOT EXISTS workflow_run_steps (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                status TEXT NOT NULL,
                input_json TEXT NOT NULL,
                output_json TEXT NOT NULL,
                error TEXT,
                started_at TEXT NOT NULL,
                finished_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_workflow_run_steps_run ON workflow_run_steps(run_id, started_at ASC);

            CREATE TABLE IF NOT EXISTS workflow_pending_actions (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                workflow_run_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                task_id TEXT,
                assignee TEXT NOT NULL,
                prompt TEXT NOT NULL,
                decisions_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                resolved_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_workflow_pending_actions_project ON workflow_pending_actions(project_id, resolved_at, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_workflow_pending_actions_run ON workflow_pending_actions(workflow_run_id);
            """,
            nil, nil, nil
        )
    }

    private static func applyAutomationMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS automation_runs (
                id TEXT PRIMARY KEY,
                automation_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                workflow_id TEXT NOT NULL,
                workflow_run_id TEXT,
                repository_full_name TEXT NOT NULL,
                trigger_type TEXT NOT NULL,
                trigger_event_id TEXT,
                status TEXT NOT NULL,
                task_id TEXT,
                summary TEXT,
                started_at TEXT NOT NULL,
                finished_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_automation_runs_project ON automation_runs(project_id, started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_automation_runs_automation ON automation_runs(automation_id, started_at DESC);
            """,
            nil, nil, nil
        )
    }

    private static func applyAutodreamMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS autodream_session_reviews (
                agent_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                status TEXT NOT NULL,
                reason TEXT NOT NULL,
                session_updated_at TEXT NOT NULL,
                reviewed_at TEXT NOT NULL,
                last_error TEXT,
                PRIMARY KEY(agent_id, session_id)
            );
            CREATE INDEX IF NOT EXISTS idx_autodream_session_reviews_status_reviewed
            ON autodream_session_reviews(status, reviewed_at DESC);
            """,
            nil, nil, nil
        )
    }

    private func loadChannelPlugins(db: OpaquePointer) -> [ChannelPluginRecord] {
        let sql =
            """
            SELECT id, type, base_url, channel_ids_json, config_json, enabled, delivery_mode, created_at, updated_at
            FROM channel_plugins
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var result: [ChannelPluginRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodePluginRow(statement: statement) {
                result.append(record)
            }
        }
        return result
    }

    private func decodePluginRow(statement: OpaquePointer?) -> ChannelPluginRecord? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let typePtr = sqlite3_column_text(statement, 1),
            let baseUrlPtr = sqlite3_column_text(statement, 2),
            let channelIdsPtr = sqlite3_column_text(statement, 3),
            let configPtr = sqlite3_column_text(statement, 4),
            let createdAtPtr = sqlite3_column_text(statement, 7),
            let updatedAtPtr = sqlite3_column_text(statement, 8)
        else {
            return nil
        }

        let enabled = sqlite3_column_int(statement, 5) != 0
        let deliveryModePtr = sqlite3_column_text(statement, 6)
        let deliveryMode = deliveryModePtr.map { String(cString: $0) } ?? ChannelPluginRecord.DeliveryMode.http
        let channelIds = (try? JSONDecoder().decode([String].self, from: Data(String(cString: channelIdsPtr).utf8))) ?? []
        let config = (try? JSONDecoder().decode([String: String].self, from: Data(String(cString: configPtr).utf8))) ?? [:]
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

        return ChannelPluginRecord(
            id: String(cString: idPtr),
            type: String(cString: typePtr),
            baseUrl: String(cString: baseUrlPtr),
            channelIds: channelIds,
            config: config,
            enabled: enabled,
            deliveryMode: deliveryMode,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func fallbackSelfImprovementProposalReviewJobs(statuses: [String]?) -> [SelfImprovementProposalReviewJob] {
        let allowed = statuses.map(Set.init)
        return fallbackSelfImprovementProposalReviewJobs.values
            .filter { job in allowed?.contains(job.status) ?? true }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func upsertFallbackSelfImprovementProposalReviewJob(
        agentId: String,
        sessionId: String,
        projectId: String,
        reason: String,
        reviewContext: String?,
        nextRunAt: Date,
        now: Date
    ) -> SelfImprovementProposalReviewJob {
        if var existing = fallbackSelfImprovementProposalReviewJobs.values.first(where: {
            $0.agentId == agentId && $0.sessionId == sessionId && $0.reason == reason
        }) {
            existing.projectId = projectId
            existing.reviewContext = reviewContext
            existing.status = "pending"
            existing.nextRunAt = nextRunAt
            existing.lastError = nil
            existing.updatedAt = now
            fallbackSelfImprovementProposalReviewJobs[existing.id] = existing
            return existing
        }
        let job = SelfImprovementProposalReviewJob(
            id: UUID().uuidString.lowercased(),
            agentId: agentId,
            sessionId: sessionId,
            projectId: projectId,
            reason: reason,
            reviewContext: reviewContext,
            nextRunAt: nextRunAt,
            createdAt: now,
            updatedAt: now
        )
        fallbackSelfImprovementProposalReviewJobs[job.id] = job
        return job
    }

    private func claimFallbackSelfImprovementProposalReviewJob(now: Date) -> SelfImprovementProposalReviewJob? {
        guard var job = fallbackSelfImprovementProposalReviewJobs.values
            .filter({ $0.status == "pending" && $0.nextRunAt <= now })
            .sorted(by: { $0.nextRunAt < $1.nextRunAt })
            .first
        else { return nil }
        job.status = "running"
        job.updatedAt = now
        fallbackSelfImprovementProposalReviewJobs[job.id] = job
        return job
    }

    private func decodeSelfImprovementProposalReviewJob(statement: OpaquePointer?) -> SelfImprovementProposalReviewJob? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let agentPtr = sqlite3_column_text(statement, 1),
            let sessionPtr = sqlite3_column_text(statement, 2),
            let projectPtr = sqlite3_column_text(statement, 3),
            let reasonPtr = sqlite3_column_text(statement, 4),
            let statusPtr = sqlite3_column_text(statement, 6),
            let nextRunPtr = sqlite3_column_text(statement, 8),
            let createdAtPtr = sqlite3_column_text(statement, 10),
            let updatedAtPtr = sqlite3_column_text(statement, 11)
        else {
            return nil
        }
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        return SelfImprovementProposalReviewJob(
            id: String(cString: idPtr),
            agentId: String(cString: agentPtr),
            sessionId: String(cString: sessionPtr),
            projectId: String(cString: projectPtr),
            reason: String(cString: reasonPtr),
            reviewContext: optionalText(statement: statement, index: 5),
            status: String(cString: statusPtr),
            attempts: Int(sqlite3_column_int(statement, 7)),
            nextRunAt: isoFormatter.date(from: String(cString: nextRunPtr)) ?? Date(),
            lastError: optionalText(statement: statement, index: 9),
            createdAt: createdAt,
            updatedAt: isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
        )
    }

    private func loadSelfImprovementProposalReviewJob(
        db: OpaquePointer,
        agentId: String,
        sessionId: String,
        reason: String
    ) -> SelfImprovementProposalReviewJob? {
        let sql =
            """
            SELECT id, agent_id, session_id, project_id, reason, review_context, status, attempts, next_run_at, last_error, created_at, updated_at
            FROM self_improvement_proposal_review_queue
            WHERE agent_id = ? AND session_id = ? AND reason = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(agentId, at: 1, statement: statement)
        bindText(sessionId, at: 2, statement: statement)
        bindText(reason, at: 3, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeSelfImprovementProposalReviewJob(statement: statement)
    }

    private func decodeAutodreamSessionReview(statement: OpaquePointer?) -> AutodreamSessionReviewRecord? {
        guard
            let agentPtr = sqlite3_column_text(statement, 0),
            let sessionPtr = sqlite3_column_text(statement, 1),
            let statusPtr = sqlite3_column_text(statement, 2),
            let reasonPtr = sqlite3_column_text(statement, 3),
            let sessionUpdatedAtPtr = sqlite3_column_text(statement, 4),
            let reviewedAtPtr = sqlite3_column_text(statement, 5)
        else {
            return nil
        }
        let reviewedAt = isoFormatter.date(from: String(cString: reviewedAtPtr)) ?? Date()
        return AutodreamSessionReviewRecord(
            agentId: String(cString: agentPtr),
            sessionId: String(cString: sessionPtr),
            status: String(cString: statusPtr),
            reason: String(cString: reasonPtr),
            sessionUpdatedAt: isoFormatter.date(from: String(cString: sessionUpdatedAtPtr)) ?? reviewedAt,
            reviewedAt: reviewedAt,
            lastError: optionalText(statement: statement, index: 6)
        )
    }

    private func encodedStringArray(_ values: [String]) -> String {
        let encoded = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: encoded, encoding: .utf8) ?? "[]"
    }

    private func decodeOptionalStringArray(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return values.isEmpty ? nil : values
    }
#endif

    private func autodreamSessionReviewKey(agentId: String, sessionId: String) -> String {
        "\(agentId)::\(sessionId)"
    }

    // MARK: - Cron Tasks

    public func listAllCronTasks() async -> [AgentCronTask] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackCronTasks.values.sorted { $0.createdAt < $1.createdAt }
        }
        let sql =
            """
            SELECT id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            FROM agent_cron_tasks
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var result: [AgentCronTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let channelIdPtr = sqlite3_column_text(statement, 2),
                let schedulePtr = sqlite3_column_text(statement, 3),
                let commandPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 6),
                let updatedAtPtr = sqlite3_column_text(statement, 7)
            else { continue }

            let id = String(cString: idPtr)
            let agentId = String(cString: agentIdPtr)
            let channelId = String(cString: channelIdPtr)
            let schedule = String(cString: schedulePtr)
            let command = String(cString: commandPtr)
            let enabled = sqlite3_column_int(statement, 5) != 0

            guard
                let createdAtDate = isoFormatter.date(from: String(cString: createdAtPtr)),
                let updatedAtDate = isoFormatter.date(from: String(cString: updatedAtPtr))
            else { continue }

            result.append(
                AgentCronTask(
                    id: id,
                    agentId: agentId,
                    channelId: channelId,
                    schedule: schedule,
                    command: command,
                    enabled: enabled,
                    createdAt: createdAtDate,
                    updatedAt: updatedAtDate
                )
            )
        }
        return result
#else
        return fallbackCronTasks.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func listCronTasks(agentId: String) async -> [AgentCronTask] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackCronTasks.values.filter { $0.agentId == agentId }.sorted { $0.createdAt < $1.createdAt }
        }
        let sql =
            """
            SELECT id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            FROM agent_cron_tasks
            WHERE agent_id = ?
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(agentId, at: 1, statement: statement)

        var result: [AgentCronTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let channelIdPtr = sqlite3_column_text(statement, 2),
                let schedulePtr = sqlite3_column_text(statement, 3),
                let commandPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 6),
                let updatedAtPtr = sqlite3_column_text(statement, 7)
            else { continue }

            let enabled = sqlite3_column_int(statement, 5) != 0
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

            result.append(AgentCronTask(
                id: String(cString: idPtr),
                agentId: String(cString: agentIdPtr),
                channelId: String(cString: channelIdPtr),
                schedule: String(cString: schedulePtr),
                command: String(cString: commandPtr),
                enabled: enabled,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return result
#else
        return fallbackCronTasks.values.filter { $0.agentId == agentId }.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func saveCronTask(_ task: AgentCronTask) async {
        fallbackCronTasks[task.id] = task
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO agent_cron_tasks(
                id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(task.id, at: 1, statement: statement)
        bindText(task.agentId, at: 2, statement: statement)
        bindText(task.channelId, at: 3, statement: statement)
        bindText(task.schedule, at: 4, statement: statement)
        bindText(task.command, at: 5, statement: statement)
        sqlite3_bind_int(statement, 6, task.enabled ? 1 : 0)
        bindText(isoFormatter.string(from: task.createdAt), at: 7, statement: statement)
        bindText(isoFormatter.string(from: task.updatedAt), at: 8, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func deleteCronTask(id: String) async {
        fallbackCronTasks[id] = nil
#if canImport(CSQLite3)
        guard let db else { return }
        let sql = "DELETE FROM agent_cron_tasks WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func cronTask(id: String) async -> AgentCronTask? {
#if canImport(CSQLite3)
        guard let db else { return fallbackCronTasks[id] }
        let sql =
            """
            SELECT id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            FROM agent_cron_tasks
            WHERE id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return fallbackCronTasks[id] }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)

        if sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let channelIdPtr = sqlite3_column_text(statement, 2),
                let schedulePtr = sqlite3_column_text(statement, 3),
                let commandPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 6),
                let updatedAtPtr = sqlite3_column_text(statement, 7)
            else { return nil }

            let enabled = sqlite3_column_int(statement, 5) != 0
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

            return AgentCronTask(
                id: String(cString: idPtr),
                agentId: String(cString: agentIdPtr),
                channelId: String(cString: channelIdPtr),
                schedule: String(cString: schedulePtr),
                command: String(cString: commandPtr),
                enabled: enabled,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
        return nil
#else
        return fallbackCronTasks[id]
#endif
    }

    // MARK: - Task Clarifications

    public func listClarifications(projectId: String, taskId: String) async -> [TaskClarificationRecord] {
#if canImport(CSQLite3)
        guard let db else { return [] }
        let sql =
            """
            SELECT id, project_id, task_id, status, target_type, target_actor_id, target_channel_id,
                   question_text, options_json, allow_note, created_by_agent_id,
                   selected_option_ids_json, note, created_at, answered_at
            FROM task_clarifications
            WHERE project_id = ? AND task_id = ?
            ORDER BY created_at DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(projectId, at: 1, statement: statement)
        bindText(taskId, at: 2, statement: statement)
        var result: [TaskClarificationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodeClarificationRow(statement: statement) {
                result.append(record)
            }
        }
        return result
#else
        return []
#endif
    }

    public func clarification(id: String) async -> TaskClarificationRecord? {
#if canImport(CSQLite3)
        guard let db else { return nil }
        let sql =
            """
            SELECT id, project_id, task_id, status, target_type, target_actor_id, target_channel_id,
                   question_text, options_json, allow_note, created_by_agent_id,
                   selected_option_ids_json, note, created_at, answered_at
            FROM task_clarifications
            WHERE id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return decodeClarificationRow(statement: statement)
        }
        return nil
#else
        return nil
#endif
    }

    public func saveClarification(_ record: TaskClarificationRecord) async {
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO task_clarifications(
                id, project_id, task_id, status, target_type, target_actor_id, target_channel_id,
                question_text, options_json, allow_note, created_by_agent_id,
                selected_option_ids_json, note, created_at, answered_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let optionsJSON = (try? String(data: JSONEncoder().encode(record.options), encoding: .utf8)) ?? "[]"
        let selectedJSON = (try? String(data: JSONEncoder().encode(record.selectedOptionIds), encoding: .utf8)) ?? "[]"

        bindText(record.id, at: 1, statement: statement)
        bindText(record.projectId, at: 2, statement: statement)
        bindText(record.taskId, at: 3, statement: statement)
        bindText(record.status.rawValue, at: 4, statement: statement)
        bindText(record.targetType.rawValue, at: 5, statement: statement)
        bindOptionalText(record.targetActorId, at: 6, statement: statement)
        bindOptionalText(record.targetChannelId, at: 7, statement: statement)
        bindText(record.questionText, at: 8, statement: statement)
        bindText(optionsJSON, at: 9, statement: statement)
        sqlite3_bind_int(statement, 10, record.allowNote ? 1 : 0)
        bindOptionalText(record.createdByAgentId, at: 11, statement: statement)
        bindText(selectedJSON, at: 12, statement: statement)
        bindOptionalText(record.note, at: 13, statement: statement)
        bindText(isoFormatter.string(from: record.createdAt), at: 14, statement: statement)
        if let answeredAt = record.answeredAt {
            bindText(isoFormatter.string(from: answeredAt), at: 15, statement: statement)
        } else {
            sqlite3_bind_null(statement, 15)
        }
        _ = sqlite3_step(statement)
#endif
    }

    public func deleteClarification(id: String) async {
#if canImport(CSQLite3)
        guard let db else { return }
        let sql = "DELETE FROM task_clarifications WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

#if canImport(CSQLite3)
    private func decodeClarificationRow(statement: OpaquePointer?) -> TaskClarificationRecord? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let projectIdPtr = sqlite3_column_text(statement, 1),
            let taskIdPtr = sqlite3_column_text(statement, 2),
            let statusPtr = sqlite3_column_text(statement, 3),
            let targetTypePtr = sqlite3_column_text(statement, 4),
            let questionPtr = sqlite3_column_text(statement, 7),
            let optionsPtr = sqlite3_column_text(statement, 8),
            let createdAtPtr = sqlite3_column_text(statement, 13)
        else {
            return nil
        }

        let allowNote = sqlite3_column_int(statement, 9) != 0
        let selectedJSON = sqlite3_column_text(statement, 11).map { String(cString: $0) } ?? "[]"
        let selectedOptionIds = (try? JSONDecoder().decode([String].self, from: Data(selectedJSON.utf8))) ?? []
        let optionsJSON = String(cString: optionsPtr)
        let options = (try? JSONDecoder().decode([ClarificationOption].self, from: Data(optionsJSON.utf8))) ?? []
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let answeredAtRaw = optionalText(statement: statement, index: 14)
        let answeredAt = answeredAtRaw.flatMap { isoFormatter.date(from: $0) }

        return TaskClarificationRecord(
            id: String(cString: idPtr),
            projectId: String(cString: projectIdPtr),
            taskId: String(cString: taskIdPtr),
            status: ClarificationStatus(rawValue: String(cString: statusPtr)) ?? .pending,
            targetType: ClarificationTargetType(rawValue: String(cString: targetTypePtr)) ?? .human,
            targetActorId: optionalText(statement: statement, index: 5),
            targetChannelId: optionalText(statement: statement, index: 6),
            questionText: String(cString: questionPtr),
            options: options,
            allowNote: allowNote,
            createdByAgentId: optionalText(statement: statement, index: 10),
            selectedOptionIds: selectedOptionIds,
            note: optionalText(statement: statement, index: 12),
            createdAt: createdAt,
            answeredAt: answeredAt
        )
    }
#endif

    // MARK: - ChannelAccessUser

    public func listChannelAccessUsers(platform: String?) async -> [ChannelAccessUser] {
#if canImport(CSQLite3)
        guard let db else {
            let all = fallbackAccessUsers.values.sorted { $0.createdAt < $1.createdAt }
            guard let platform else { return all }
            return all.filter { $0.platform == platform }
        }
        let sql: String
        if let platform {
            sql = "SELECT id, platform, platform_user_id, display_name, status, created_at, updated_at FROM channel_access_users WHERE platform = ? ORDER BY created_at DESC;"
        } else {
            sql = "SELECT id, platform, platform_user_id, display_name, status, created_at, updated_at FROM channel_access_users ORDER BY created_at DESC;"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let platform {
            bindText(platform, at: 1, statement: statement)
        }
        var results: [ChannelAccessUser] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let platformPtr = sqlite3_column_text(statement, 1),
                let userIdPtr = sqlite3_column_text(statement, 2),
                let namePtr = sqlite3_column_text(statement, 3),
                let statusPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 5),
                let updatedAtPtr = sqlite3_column_text(statement, 6)
            else { continue }
            results.append(ChannelAccessUser(
                id: String(cString: idPtr),
                platform: String(cString: platformPtr),
                platformUserId: String(cString: userIdPtr),
                displayName: String(cString: namePtr),
                status: String(cString: statusPtr),
                createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date(),
                updatedAt: isoFormatter.date(from: String(cString: updatedAtPtr)) ?? Date()
            ))
        }
        return results
#else
        return []
#endif
    }

    public func channelAccessUser(platform: String, platformUserId: String) async -> ChannelAccessUser? {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackAccessUsers.values.first { $0.platform == platform && $0.platformUserId == platformUserId }
        }
        let sql = "SELECT id, platform, platform_user_id, display_name, status, created_at, updated_at FROM channel_access_users WHERE platform = ? AND platform_user_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(platform, at: 1, statement: statement)
        bindText(platformUserId, at: 2, statement: statement)
        if sqlite3_step(statement) == SQLITE_ROW,
           let idPtr = sqlite3_column_text(statement, 0),
           let platformPtr = sqlite3_column_text(statement, 1),
           let userIdPtr = sqlite3_column_text(statement, 2),
           let namePtr = sqlite3_column_text(statement, 3),
           let statusPtr = sqlite3_column_text(statement, 4),
           let createdAtPtr = sqlite3_column_text(statement, 5),
           let updatedAtPtr = sqlite3_column_text(statement, 6) {
            return ChannelAccessUser(
                id: String(cString: idPtr),
                platform: String(cString: platformPtr),
                platformUserId: String(cString: userIdPtr),
                displayName: String(cString: namePtr),
                status: String(cString: statusPtr),
                createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date(),
                updatedAt: isoFormatter.date(from: String(cString: updatedAtPtr)) ?? Date()
            )
        }
        return nil
#else
        return nil
#endif
    }

    public func saveChannelAccessUser(_ user: ChannelAccessUser) async {
#if canImport(CSQLite3)
        guard let db else {
            if let existing = fallbackAccessUsers.values.first(where: { $0.platform == user.platform && $0.platformUserId == user.platformUserId }) {
                fallbackAccessUsers[existing.id] = nil
            }
            fallbackAccessUsers[user.id] = user
            return
        }
        let sql = """
            INSERT INTO channel_access_users(id, platform, platform_user_id, display_name, status, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(platform, platform_user_id) DO UPDATE SET
                display_name = excluded.display_name,
                status = excluded.status,
                updated_at = excluded.updated_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bindText(user.id, at: 1, statement: statement)
        bindText(user.platform, at: 2, statement: statement)
        bindText(user.platformUserId, at: 3, statement: statement)
        bindText(user.displayName, at: 4, statement: statement)
        bindText(user.status, at: 5, statement: statement)
        bindText(isoFormatter.string(from: user.createdAt), at: 6, statement: statement)
        bindText(isoFormatter.string(from: user.updatedAt), at: 7, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func deleteChannelAccessUser(id: String) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackAccessUsers[id] = nil
            return
        }
        let sql = "DELETE FROM channel_access_users WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

#if canImport(CSQLite3)
    private static func applyCronTaskMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS agent_cron_tasks(
                id TEXT PRIMARY KEY,
                agent_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                schedule TEXT NOT NULL,
                command TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """,
            nil, nil, nil
        )
    }

    private static func applyTokenUsageMigrations(db: OpaquePointer?) {
        guard let db else { return }
        let statements = [
            "ALTER TABLE token_usage ADD COLUMN cached_input_tokens INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE token_usage ADD COLUMN cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE token_usage ADD COLUMN reasoning_tokens INTEGER NOT NULL DEFAULT 0;"
        ]
        for statement in statements {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    private static func applyClarificationMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS task_clarifications (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                target_type TEXT NOT NULL DEFAULT 'human',
                target_actor_id TEXT,
                target_channel_id TEXT,
                question_text TEXT NOT NULL,
                options_json TEXT NOT NULL DEFAULT '[]',
                allow_note INTEGER NOT NULL DEFAULT 1,
                created_by_agent_id TEXT,
                selected_option_ids_json TEXT NOT NULL DEFAULT '[]',
                note TEXT,
                created_at TEXT NOT NULL,
                answered_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_task_clarifications_task ON task_clarifications(project_id, task_id);
            """,
            nil, nil, nil
        )

        let taskColumnMigrations = [
            "ALTER TABLE dashboard_project_tasks ADD COLUMN kind TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN loop_mode_override TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN origin_type TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN origin_channel_id TEXT;"
        ]
        for statement in taskColumnMigrations {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }

        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN task_loop_mode TEXT NOT NULL DEFAULT 'human';",
            nil, nil, nil
        )
    }

    private static func applyDashboardProjectsMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN actors_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN teams_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN models_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN agent_files_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN heartbeat_json TEXT NOT NULL DEFAULT '{\"enabled\":false,\"intervalMinutes\":5}';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN repo_path TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN review_settings_json TEXT NOT NULL DEFAULT '{\"enabled\":false,\"approvalMode\":\"human\"}';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN automatic_task_pickup_enabled INTEGER NOT NULL DEFAULT 1;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN autopilot_settings_json TEXT NOT NULL DEFAULT '{}';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN worktree_branch TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN icon TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN selected_model TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN stage_assignments_json TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN active_stage TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN task_sync_settings_json TEXT NOT NULL DEFAULT '{}';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN external_metadata_json TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN source_control_provider_id TEXT;",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN project_kind TEXT NOT NULL DEFAULT 'project';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN directory_paths_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_project_tasks ADD COLUMN source_control_provider_id TEXT;",
            nil, nil, nil
        )
    }

    private static func openDatabase(path: String, schemaSQL: String) -> (OpaquePointer?, String?) {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                return (nil, "Failed to create database directory at \(directory): \(error.localizedDescription)")
            }
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open(path, &db)
        guard openResult == SQLITE_OK else {
            let errorMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Result code: \(openResult)"
            if let db {
                sqlite3_close(db)
            }
            return (nil, "Failed to open SQLite database at \(path): \(errorMsg)")
        }

        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)

        if sqlite3_exec(db, schemaSQL, nil, nil, nil) != SQLITE_OK {
            let errorMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown execution error"
            sqlite3_close(db)
            return (nil, "Failed to apply schema to database at \(path): \(errorMsg)")
        }

        applyRuntimeEventMigrations(db: db)
        applyArtifactMigrations(db: db)
        applyWorkspaceMigrations(db: db)
        applyProjectTaskMigrations(db: db)
        applyInitiativeMigrations(db: db)
        applyChannelPluginMigrations(db: db)
        applyWorkflowMigrations(db: db)
        applyAutomationMigrations(db: db)
        applyAutodreamMigrations(db: db)
        applyCronTaskMigrations(db: db)
        applyTokenUsageMigrations(db: db)
        applyDashboardProjectsMigrations(db: db)
        applyClarificationMigrations(db: db)
        if sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS agent_proactive_state (agent_id TEXT PRIMARY KEY, payload TEXT NOT NULL);", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db)
            return (nil, "Failed to apply proactive heartbeat schema")
        }
        return (db, nil)
    }
#endif
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
