import Foundation
import SQLite3

enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)

    var description: String {
        switch self {
        case .open(let m): "open: \(m)"
        case .prepare(let m): "prepare: \(m)"
        case .step(let m): "step: \(m)"
        case .bind(let m): "bind: \(m)"
        }
    }
}

enum SQLiteValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Not thread-safe by itself — always owned by a single actor.
/// WAL journaling + transactions keep the cache consistent across crashes.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statementCache: [String: Statement] = [:]

    init(url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA temp_store=MEMORY;")
        sqlite3_busy_timeout(db, 2_000)
    }

    /// In-memory database for tests.
    init(inMemory: Void = ()) throws {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else { throw SQLiteError.open("memory") }
        handle = db
    }

    deinit {
        statementCache.values.forEach { $0.finalize() }
        sqlite3_close_v2(handle)
    }

    var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw SQLiteError.step(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        if let cached = statementCache[sql] {
            cached.reset()
            return cached
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(errorMessage)
        }
        let statement = Statement(handle: stmt, database: self)
        statementCache[sql] = statement
        return statement
    }

    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        while try stmt.step() {}
        stmt.reset()
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], map: (Statement) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        var rows: [T] = []
        while try stmt.step() { rows.append(try map(stmt)) }
        stmt.reset()
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version;") { Int($0.int(0)) }.first) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue);") }
    }
}

final class Statement {
    fileprivate let handle: OpaquePointer
    private unowned let database: SQLiteDatabase

    fileprivate init(handle: OpaquePointer, database: SQLiteDatabase) {
        self.handle = handle
        self.database = database
    }

    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(handle, index)
            case .int(let v): rc = sqlite3_bind_int64(handle, index, v)
            case .double(let v): rc = sqlite3_bind_double(handle, index, v)
            case .text(let v): rc = sqlite3_bind_text(handle, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            }
            if rc != SQLITE_OK { throw SQLiteError.bind(database.errorMessage) }
        }
    }

    /// Returns true when a row is available.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(database.errorMessage)
        }
    }

    func reset() {
        sqlite3_reset(handle)
    }

    fileprivate func finalize() {
        sqlite3_finalize(handle)
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
