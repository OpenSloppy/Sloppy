import Foundation
import CMigrationSQLite

/// A read transaction pins a consistent view and sees committed WAL records.
final class MigrationSQLite {
    private var database: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw MigrationError.invalid("Cannot read session database.")
        }
        sqlite3_busy_timeout(database, 1000)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw MigrationError.invalid("Cannot take database snapshot.") }
    }
    deinit { if let database { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close(database) } }
    func rows(_ sql: String, values: [String] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw MigrationError.invalid("Unsupported session database schema.") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [[String: Any]] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw MigrationError.invalid("Session database read failed.") }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_INTEGER, SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, column) { row[name] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))) }
                default: break
                }
            }
            result.append(row)
        }
        return result
    }
    var tables: Set<String> { Set((try? rows("SELECT name FROM sqlite_master WHERE type='table'"))?.compactMap { $0["name"] as? String } ?? []) }
}
