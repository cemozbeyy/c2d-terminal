import Foundation
import SQLite3

public struct SQLiteError: Error, Equatable, Sendable {
    public let code: Int32
    public let message: String
}

/// Minimal wrapper over the system sqlite3 library (ADR-011, record store). One connection,
/// one lock; an actor owns it. WAL journal, busy timeout, `userVersion` for migrations.
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `path` of ":memory:" opens a private in-memory database.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError(code: rc, message: msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    public func exec(_ sql: String) throws {
        try withLock { db in
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw SQLiteError(code: rc, message: msg)
            }
        }
    }

    public var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")) ?? 0 }
        set { try? exec("PRAGMA user_version=\(newValue)") }
    }

    public var journalMode: String {
        (try? query("PRAGMA journal_mode", []) { $0.string(0) }.first ?? "") ?? ""
    }

    /// Rolls back when `body` throws; the error propagates.
    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        try withLock { db in
            let stmt = try prepare(db, sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        }
    }

    public func query<T>(_ sql: String, _ params: [SQLiteValue] = [], _ row: (Row) throws -> T) throws -> [T] {
        try withLock { db in
            let stmt = try prepare(db, sql, params)
            defer { sqlite3_finalize(stmt) }
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { out.append(try row(Row(stmt: stmt))) }
                else if rc == SQLITE_DONE { break }
                else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
            }
            return out
        }
    }

    public func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        try query(sql, params) { $0.int(0) }.first ?? 0
    }

    private func withLock<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "database closed") }
        return try body(db)
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            }
        }
        return stmt
    }

    /// One result row; valid only inside the `query` callback.
    public struct Row {
        let stmt: OpaquePointer
        public func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }
        public func int(_ i: Int) -> Int { Int(sqlite3_column_int64(stmt, Int32(i))) }
        public func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
        public func string(_ i: Int) -> String? {
            guard let c = sqlite3_column_text(stmt, Int32(i)) else { return nil }
            return String(cString: c)
        }
        public func data(_ i: Int) -> Data? {
            guard let p = sqlite3_column_blob(stmt, Int32(i)) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, Int32(i))))
        }
    }
}

public enum SQLiteValue: Sendable {
    case null, int(Int64), double(Double), text(String), blob(Data)
    public static func optText(_ s: String?) -> SQLiteValue { s.map { .text($0) } ?? .null }
    public static func optDate(_ d: Date?) -> SQLiteValue { d.map { .double($0.timeIntervalSince1970) } ?? .null }
}
