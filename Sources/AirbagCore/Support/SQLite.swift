import Foundation
import SQLite3

/// Errors raised by `SQLiteConnection`. `code` is the extended result code.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public enum Phase: String, Sendable { case open, prepare, bind, step, exec }
    public let phase: Phase
    public let code: Int32
    public let message: String
    public let sql: String?

    public var primaryCode: Int32 { code & 0xFF }
    public var isBusy: Bool { primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED }
    public var isCorrupt: Bool { primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB }
    public var isConstraint: Bool { primaryCode == SQLITE_CONSTRAINT }

    public var description: String {
        "SQLite \(phase.rawValue) error \(code): \(message)" + (sql.map { " [\($0.prefix(120))]" } ?? "")
    }
}

/// A value that can be bound to a statement parameter.
public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }

extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .integer(self) } }
extension Int32: SQLBindable { public var sqlValue: SQLValue { .integer(Int64(self)) } }
extension UInt64: SQLBindable { public var sqlValue: SQLValue { .integer(Int64(bitPattern: self)) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .real(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only view of the current result row.
public struct SQLRow {
    fileprivate let stmt: OpaquePointer

    public var columnCount: Int32 { sqlite3_column_count(stmt) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func intOrNil(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func bool(_ i: Int32) -> Bool { int(i) != 0 }
    public func text(_ i: Int32) -> String { textOrNil(i) ?? "" }
    public func textOrNil(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
    public func blob(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

/// A single SQLite connection with a prepared-statement cache. Not thread-safe: confine to one thread/actor.
public final class SQLiteConnection {
    public enum TransactionKind: String { case deferred = "DEFERRED", immediate = "IMMEDIATE", exclusive = "EXCLUSIVE" }

    public let path: String
    private var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    /// Opens (and creates, unless `readOnly`) the database file.
    public init(path: String, readOnly: Bool = false, busyTimeoutMs: Int32 = 300) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
            | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(phase: .open, code: rc, message: msg, sql: path)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, busyTimeoutMs)
    }

    deinit { close() }

    public func close() {
        for (_, stmt) in cache { sqlite3_finalize(stmt) }
        cache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private var db: OpaquePointer {
        guard let handle else { preconditionFailure("SQLiteConnection used after close") }
        return handle
    }

    private func error(_ phase: SQLiteError.Phase, _ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(phase: phase, code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }

    /// Executes one or more statements without parameters (DDL, pragmas).
    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            throw SQLiteError(phase: .exec, code: rc, message: msg, sql: sql)
        }
    }

    private func statement(_ sql: String, cached: Bool) throws -> OpaquePointer {
        if cached, let stmt = cache[sql] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(db, sql, -1, cached ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(.prepare, rc, sql) }
        if cached { cache[sql] = stmt }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLBindable?], _ sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard expected == args.count else {
            throw SQLiteError(phase: .bind, code: SQLITE_RANGE, message: "expected \(expected) args, got \(args.count)", sql: sql)
        }
        for (offset, arg) in args.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch arg?.sqlValue ?? .null {
            case .null: rc = sqlite3_bind_null(stmt, i)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, i, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, i, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, i, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, Int32(buf.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            if rc != SQLITE_OK { throw error(.bind, rc, sql) }
        }
    }

    /// Runs a single statement, iterating every result row through `row`.
    public func query(_ sql: String, _ args: [SQLBindable?] = [], cached: Bool = true, _ row: (SQLRow) throws -> Void) throws {
        let stmt = try statement(sql, cached: cached)
        defer {
            if cached { sqlite3_reset(stmt) } else { sqlite3_finalize(stmt) }
        }
        try bind(stmt, args, sql)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try row(SQLRow(stmt: stmt)); continue }
            if rc == SQLITE_DONE { return }
            throw error(.step, rc, sql)
        }
    }

    /// Runs a statement that returns no rows (or ignores them).
    public func run(_ sql: String, _ args: [SQLBindable?] = [], cached: Bool = true) throws {
        try query(sql, args, cached: cached) { _ in }
    }

    public func all<T>(_ sql: String, _ args: [SQLBindable?] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        var out: [T] = []
        try query(sql, args) { out.append(try map($0)) }
        return out
    }

    public func first<T>(_ sql: String, _ args: [SQLBindable?] = [], _ map: (SQLRow) throws -> T) throws -> T? {
        var out: T?
        try query(sql, args) { row in if out == nil { out = try map(row) } }
        return out
    }

    public func scalarInt(_ sql: String, _ args: [SQLBindable?] = []) throws -> Int64? {
        try first(sql, args) { $0.intOrNil(0) } ?? nil
    }

    public func scalarText(_ sql: String, _ args: [SQLBindable?] = []) throws -> String? {
        try first(sql, args) { $0.textOrNil(0) } ?? nil
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    public var changes: Int { Int(sqlite3_changes(db)) }
    public var isInTransaction: Bool { sqlite3_get_autocommit(db) == 0 }

    /// Runs `body` in a transaction. Nested calls become savepoints. Rolls back on any thrown error.
    @discardableResult
    public func transaction<T>(_ kind: TransactionKind = .immediate, _ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            let name = "sp\(transactionDepth)"
            try execute("SAVEPOINT \(name)")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try body()
                try execute("RELEASE \(name)")
                return result
            } catch {
                try? execute("ROLLBACK TO \(name); RELEASE \(name)")
                throw error
            }
        }
        try execute("BEGIN \(kind.rawValue)")
        transactionDepth = 1
        defer { transactionDepth = 0 }
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            if isInTransaction { try? execute("ROLLBACK") }
            throw error
        }
    }
}
