import Foundation

public struct CachedMessageSearchResult: Sendable, Equatable, Identifiable {
    public var id: String { messageId }
    public let messageId: String
    public let agentId: String
    public let sessionId: String
    public let projectId: String?
    public let role: String
    public let createdAt: Date
    public let text: String

    public init(
        messageId: String,
        agentId: String,
        sessionId: String,
        projectId: String?,
        role: String,
        createdAt: Date,
        text: String
    ) {
        self.messageId = messageId
        self.agentId = agentId
        self.sessionId = sessionId
        self.projectId = projectId
        self.role = role
        self.createdAt = createdAt
        self.text = text
    }
}

#if canImport(CSQLite3)
import CSQLite3
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

public actor ClientCacheStore {
#if canImport(CSQLite3)
    private var db: OpaquePointer?
#endif

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let cacheDateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractionalCacheDateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private var fallbackAgents: [String: APIAgentRecord] = [:]
    private var fallbackProjects: [String: APIProjectRecord] = [:]
    private var fallbackSessions: [String: [String: ChatSessionSummary]] = [:]
    private var fallbackSessionDetails: [String: [String: ChatSessionDetail]] = [:]
    private var fallbackMessages: [String: CachedMessageSearchResult] = [:]

    public init(path: String? = nil, namespace: String? = nil) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = Self.cachedDate(from: str) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(str)")
        }
        self.decoder = decoder

#if canImport(CSQLite3)
        self.db = Self.openDatabase(path: path ?? Self.defaultDatabasePath(namespace: namespace)).0
#endif
    }

    static func cachedDate(from string: String) -> Date? {
        if string.contains("."), let date = try? fractionalCacheDateFormat.parse(string) {
            return date
        }
        return try? cacheDateFormat.parse(string)
    }

    public func cacheAgents(_ agents: [APIAgentRecord]) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackAgents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
            return
        }

        _ = execute(sql: "DELETE FROM cached_agents;", db: db)
        for agent in agents {
            guard let json = encode(agent) else { continue }
            _ = execute(
                sql:
                "INSERT OR REPLACE INTO cached_agents(id, json_payload) VALUES(?, ?);",
                binds: [.text(agent.id), .text(json)],
                db: db
            )
        }
#else
        fallbackAgents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
#endif
    }

    public func loadAgents() async -> [APIAgentRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackAgents.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        return decodeRows(
            sql: "SELECT json_payload FROM cached_agents ORDER BY id ASC;",
            db: db,
            as: APIAgentRecord.self
        )
#else
        return fallbackAgents.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
#endif
    }

    public func cacheProjects(_ projects: [APIProjectRecord]) async {
#if canImport(CSQLite3)
        guard let db else {
            fallbackProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.storageID, $0) })
            return
        }

        _ = execute(sql: "DELETE FROM cached_projects;", db: db)
        for project in projects {
            guard let json = encode(project) else { continue }
            _ = execute(
                sql:
                "INSERT OR REPLACE INTO cached_projects(id, json_payload) VALUES(?, ?);",
                binds: [.text(project.storageID), .text(json)],
                db: db
            )
        }
#else
        fallbackProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.storageID, $0) })
#endif
    }

    public func loadProjects() async -> [APIProjectRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackProjects.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return decodeRows(
            sql: "SELECT json_payload FROM cached_projects ORDER BY id ASC;",
            db: db,
            as: APIProjectRecord.self
        )
#else
        return fallbackProjects.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
#endif
    }

    public func cacheSessions(agentId: String, projectId: String?, sessions: [ChatSessionSummary]) async {
#if canImport(CSQLite3)
        guard let db else {
            var byAgent = fallbackSessions[agentId] ?? [:]
            if projectId == nil {
                byAgent.removeAll()
            } else {
                byAgent = byAgent.filter { $0.value.projectId != projectId }
            }
            sessions.forEach { byAgent[$0.storageID] = $0 }
            fallbackSessions[agentId] = byAgent
            return
        }

        if let projectId, !projectId.isEmpty {
            _ = execute(
                sql:
                "DELETE FROM cached_sessions WHERE agent_id = ? AND project_id = ?;",
                binds: [.text(agentId), .text(projectId)],
                db: db
            )
        } else {
            _ = execute(
                sql:
                "DELETE FROM cached_sessions WHERE agent_id = ?;",
                binds: [.text(agentId)],
                db: db
            )
        }

        for session in sessions {
            guard let json = encode(session) else { continue }
            _ = execute(
                sql:
                """
                INSERT OR REPLACE INTO cached_sessions(
                    agent_id, session_id, project_id, updated_at, message_count, json_payload
                ) VALUES(?, ?, ?, ?, ?, ?);
                """,
                binds: [
                    .text(agentId),
                    .text(session.storageID),
                    .optionalText(session.projectId),
                    .double(session.updatedAt.timeIntervalSince1970),
                    .int(session.messageCount),
                    .text(json),
                ],
                db: db
            )
        }
#else
        var byAgent = fallbackSessions[agentId] ?? [:]
        if projectId == nil {
            byAgent.removeAll()
        } else {
            byAgent = byAgent.filter { $0.value.projectId != projectId }
        }
        sessions.forEach { byAgent[$0.storageID] = $0 }
        fallbackSessions[agentId] = byAgent
#endif
    }

    public func loadSessions(agentId: String, projectId: String? = nil) async -> [ChatSessionSummary] {
#if canImport(CSQLite3)
        guard let db else {
            let sessions = Array((fallbackSessions[agentId] ?? [:]).values)
            return filterAndSortSessions(sessions, projectId: projectId)
        }

        let sql: String
        let binds: [SQLiteBind]
        if let projectId, !projectId.isEmpty {
            sql = "SELECT json_payload FROM cached_sessions WHERE agent_id = ? AND project_id = ? ORDER BY updated_at DESC;"
            binds = [.text(agentId), .text(projectId)]
        } else {
            sql = "SELECT json_payload FROM cached_sessions WHERE agent_id = ? ORDER BY updated_at DESC;"
            binds = [.text(agentId)]
        }
        return decodeRows(sql: sql, binds: binds, db: db, as: ChatSessionSummary.self)
#else
        let sessions = Array((fallbackSessions[agentId] ?? [:]).values)
        return filterAndSortSessions(sessions, projectId: projectId)
#endif
    }

    public func cacheSessionDetail(agentId: String, detail: ChatSessionDetail) async {
#if canImport(CSQLite3)
        guard let db else {
            var byAgent = fallbackSessionDetails[agentId] ?? [:]
            byAgent[detail.summary.id] = detail
            fallbackSessionDetails[agentId] = byAgent
            storeFallbackMessages(agentId: agentId, detail: detail)
            return
        }

        struct CachedDetailPayload: Encodable {
            let summary: ChatSessionSummary
            let messages: [ChatMessage]
            let historyPage: ChatSessionHistoryPage?
        }
        let messages = detail.messages
        guard let json = encode(CachedDetailPayload(
            summary: detail.summary, messages: messages, historyPage: detail.historyPage
        )) else { return }
        _ = execute(
            sql:
            "INSERT OR REPLACE INTO cached_session_details(agent_id, session_id, json_payload) VALUES(?, ?, ?);",
            binds: [.text(agentId), .text(detail.summary.id), .text(json)],
            db: db
        )
        _ = execute(
            sql: "DELETE FROM cached_messages WHERE agent_id = ? AND session_id = ?;",
            binds: [.text(agentId), .text(detail.summary.id)],
            db: db
        )
        _ = execute(
            sql: "DELETE FROM cached_message_fts WHERE session_id = ?;",
            binds: [.text(detail.summary.id)],
            db: db
        )

        for message in messages {
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            _ = execute(
                sql:
                """
                INSERT OR REPLACE INTO cached_messages(
                    message_id, agent_id, session_id, project_id, role, created_at, text
                ) VALUES(?, ?, ?, ?, ?, ?, ?);
                """,
                binds: [
                    .text(message.id),
                    .text(agentId),
                    .text(detail.summary.id),
                    .optionalText(detail.summary.projectId),
                    .text(message.role.rawValue),
                    .double(message.createdAt.timeIntervalSince1970),
                    .text(text),
                ],
                db: db
            )
            _ = execute(
                sql:
                """
                INSERT INTO cached_message_fts(message_id, session_id, text)
                VALUES(?, ?, ?);
                """,
                binds: [.text(message.id), .text(detail.summary.id), .text(text)],
                db: db
            )
        }
#else
        var byAgent = fallbackSessionDetails[agentId] ?? [:]
        byAgent[detail.summary.id] = detail
        fallbackSessionDetails[agentId] = byAgent
        storeFallbackMessages(agentId: agentId, detail: detail)
#endif
    }

    public func loadSessionDetail(agentId: String, sessionId: String) async -> ChatSessionDetail? {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackSessionDetails[agentId]?[sessionId]
        }

        guard let json = firstTextRow(
            sql: "SELECT json_payload FROM cached_session_details WHERE agent_id = ? AND session_id = ? LIMIT 1;",
            binds: [.text(agentId), .text(sessionId)],
            db: db
        ) else {
            return nil
        }
        struct CachedDetailPayload: Decodable {
            let summary: ChatSessionSummary
            let messages: [ChatMessage]
            let historyPage: ChatSessionHistoryPage?
        }
        guard let payload = decode(json, as: CachedDetailPayload.self) else {
            return nil
        }
        return ChatSessionDetail(summary: payload.summary, messages: payload.messages, historyPage: payload.historyPage)
#else
        return fallbackSessionDetails[agentId]?[sessionId]
#endif
    }

    public nonisolated static func defaultDatabasePath(namespace: String? = nil) -> String {
        let fileManager = FileManager.default
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("SloppyClient", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let namespace, !namespace.isEmpty else {
            return directoryURL.appendingPathComponent("offline-cache.sqlite3").path
        }
        let encoded = Data(namespace.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directoryURL.appendingPathComponent("offline-cache-\(encoded).sqlite3").path
    }

    public func searchMessages(query: String, limit: Int = 20) async -> [CachedMessageSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

#if canImport(CSQLite3)
        guard let db else {
            return fallbackMessages.values
                .filter { $0.text.localizedCaseInsensitiveContains(normalizedQuery) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
                .map { $0 }
        }

        let sql = """
        SELECT m.message_id, m.agent_id, m.session_id, m.project_id, m.role, m.created_at, m.text
        FROM cached_message_fts f
        JOIN cached_messages m ON m.message_id = f.message_id
        WHERE cached_message_fts MATCH ?
        ORDER BY m.created_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindAll([.text(normalizedQuery), .int(limit)], to: statement)

        var results: [CachedMessageSearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let messageIdPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let sessionIdPtr = sqlite3_column_text(statement, 2),
                let rolePtr = sqlite3_column_text(statement, 4),
                let textPtr = sqlite3_column_text(statement, 6)
            else {
                continue
            }

            let projectId: String?
            if let projectIdPtr = sqlite3_column_text(statement, 3) {
                projectId = String(cString: projectIdPtr)
            } else {
                projectId = nil
            }

            results.append(
                CachedMessageSearchResult(
                    messageId: String(cString: messageIdPtr),
                    agentId: String(cString: agentIdPtr),
                    sessionId: String(cString: sessionIdPtr),
                    projectId: projectId,
                    role: String(cString: rolePtr),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    text: String(cString: textPtr)
                )
            )
        }
        return results
#else
        return fallbackMessages.values
            .filter { $0.text.localizedCaseInsensitiveContains(normalizedQuery) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
#endif
    }

    private func filterAndSortSessions(_ sessions: [ChatSessionSummary], projectId: String?) -> [ChatSessionSummary] {
        sessions
            .filter { projectId == nil || $0.projectId == projectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func storeFallbackMessages(agentId: String, detail: ChatSessionDetail) {
        fallbackMessages = fallbackMessages.filter { $0.value.sessionId != detail.summary.id }
        for message in detail.messages {
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            fallbackMessages[message.id] = CachedMessageSearchResult(
                messageId: message.id,
                agentId: agentId,
                sessionId: detail.summary.id,
                projectId: detail.summary.projectId,
                role: message.role.rawValue,
                createdAt: message.createdAt,
                text: text
            )
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decode<T: Decodable>(_ json: String, as type: T.Type) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

#if canImport(CSQLite3)
    private static func openDatabase(path: String) -> (OpaquePointer?, String?) {
        var db: OpaquePointer?
        let openResult = sqlite3_open(path, &db)
        guard openResult == SQLITE_OK, let db else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Could not open SQLite database"
            if let db {
                sqlite3_close(db)
            }
            return (nil, message)
        }

        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS cached_agents(
            id TEXT PRIMARY KEY,
            json_payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cached_projects(
            id TEXT PRIMARY KEY,
            json_payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cached_sessions(
            agent_id TEXT NOT NULL,
            session_id TEXT PRIMARY KEY,
            project_id TEXT,
            updated_at REAL NOT NULL,
            message_count INTEGER NOT NULL,
            json_payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS cached_sessions_agent_project_idx
            ON cached_sessions(agent_id, project_id, updated_at DESC);
        CREATE TABLE IF NOT EXISTS cached_session_details(
            agent_id TEXT NOT NULL,
            session_id TEXT PRIMARY KEY,
            json_payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cached_messages(
            message_id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            project_id TEXT,
            role TEXT NOT NULL,
            created_at REAL NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS cached_messages_session_created_idx
            ON cached_messages(session_id, created_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS cached_message_fts USING fts5(
            message_id UNINDEXED,
            session_id UNINDEXED,
            text
        );
        """

        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Could not initialize SQLite schema"
            sqlite3_close(db)
            return (nil, message)
        }

        return (db, nil)
    }

    private func decodeRows<T: Decodable>(
        sql: String,
        binds: [SQLiteBind] = [],
        db: OpaquePointer,
        as type: T.Type
    ) -> [T] {
        guard let rows = textRows(sql: sql, binds: binds, db: db) else { return [] }
        return rows.compactMap { decode($0, as: type) }
    }

    private func firstTextRow(sql: String, binds: [SQLiteBind], db: OpaquePointer) -> String? {
        textRows(sql: sql, binds: binds, db: db)?.first
    }

    private func textRows(sql: String, binds: [SQLiteBind], db: OpaquePointer) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindAll(binds, to: statement)

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(statement, 0) else { continue }
            rows.append(String(cString: ptr))
        }
        return rows
    }

    @discardableResult
    private func execute(sql: String, binds: [SQLiteBind] = [], db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bindAll(binds, to: statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func bindAll(_ binds: [SQLiteBind], to statement: OpaquePointer?) {
        for (offset, bind) in binds.enumerated() {
            let index = Int32(offset + 1)
            switch bind {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .optionalText(let value):
                if let value {
                    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .int(let value):
                sqlite3_bind_int(statement, index, Int32(value))
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            }
        }
    }

    private enum SQLiteBind {
        case text(String)
        case optionalText(String?)
        case int(Int)
        case double(Double)
    }
#endif
}
