import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct ArchiveError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

private let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the system SQLite3. Not thread-safe; one connection per thread.
public final class Database: @unchecked Sendable {
    let handle: OpaquePointer

    /// `immutable` opens a file we do not own (a backup, possibly on a network mount) as a read-only URI with
    /// `immutable=1`, so SQLite never creates a `-shm`/`-wal`/`-journal` next to it.
    public init(path: String, readOnly: Bool = false, immutable: Bool = false) throws {
        var db: OpaquePointer?
        var flags = readOnly || immutable ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var target = path
        if immutable {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#%")
            target = "file:" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path) + "?immutable=1"
            flags |= SQLITE_OPEN_URI
        }
        let rc = sqlite3_open_v2(target, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(rc))"
            if let db { sqlite3_close(db) }
            throw ArchiveError("cannot open \(path): \(msg)")
        }
        handle = db
        sqlite3_busy_timeout(db, 30_000)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw ArchiveError("sql error: \(m) in: \(sql.prefix(120))")
        }
    }

    public func prepare(_ sql: String) throws -> Statement { try Statement(db: self, sql: sql) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Convenience scalar queries.
    public func scalarInt(_ sql: String) throws -> Int64 {
        let st = try prepare(sql)
        return try st.step() ? st.int(0) : 0
    }

    public func scalarString(_ sql: String) throws -> String? {
        let st = try prepare(sql)
        return try st.step() ? st.string(0) : nil
    }

    public func tableExists(_ name: String) throws -> Bool {
        let st = try prepare("SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?")
        st.bind(1, name)
        return try st.step()
    }

    public func hasColumn(_ table: String, _ column: String) throws -> Bool {
        let st = try prepare("PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\")")
        while try st.step() { if st.string(1) == column { return true } }
        return false
    }

    public func userVersion() throws -> Int { Int(try scalarInt("PRAGMA user_version")) }
    public func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version = \(v)") }
}

public final class Statement {
    let stmt: OpaquePointer
    unowned let db: Database

    init(db: Database, sql: String) throws {
        self.db = db
        var s: OpaquePointer?
        guard sqlite3_prepare_v3(db.handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &s, nil) == SQLITE_OK, let s else {
            throw ArchiveError("prepare failed: \(db.lastError) in: \(sql.prefix(160))")
        }
        stmt = s
    }

    deinit { sqlite3_finalize(stmt) }

    public func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }

    @discardableResult public func bind(_ i: Int32, _ v: Int64) -> Statement { sqlite3_bind_int64(stmt, i, v); return self }
    @discardableResult public func bind(_ i: Int32, _ v: Int) -> Statement { sqlite3_bind_int64(stmt, i, Int64(v)); return self }
    @discardableResult public func bind(_ i: Int32, _ v: Int64?) -> Statement {
        if let v { sqlite3_bind_int64(stmt, i, v) } else { sqlite3_bind_null(stmt, i) }
        return self
    }
    @discardableResult public func bind(_ i: Int32, _ v: String?) -> Statement {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT_) } else { sqlite3_bind_null(stmt, i) }
        return self
    }
    @discardableResult public func bindBlob(_ i: Int32, _ v: Data) -> Statement {
        v.withUnsafeBytes { raw in _ = sqlite3_bind_blob(stmt, i, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT_) }
        return self
    }
    @discardableResult public func bind(_ i: Int32, _ v: Double) -> Statement { sqlite3_bind_double(stmt, i, v); return self }
    @discardableResult public func bind(_ i: Int32, _ v: Bool) -> Statement { sqlite3_bind_int64(stmt, i, v ? 1 : 0); return self }

    /// Returns true when a row is available.
    @discardableResult public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw ArchiveError("step failed: \(db.lastError)")
    }

    /// Run to completion (for INSERT/UPDATE/DELETE) and reset.
    public func run() throws {
        defer { reset() }
        _ = try step()
    }

    public func blob(_ c: Int32) -> Data? {
        guard sqlite3_column_type(stmt, c) == SQLITE_BLOB || sqlite3_column_type(stmt, c) == SQLITE_TEXT,
              let p = sqlite3_column_blob(stmt, c) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, c))
        return n == 0 ? nil : Data(bytes: p, count: n)
    }

    public func int(_ c: Int32) -> Int64 { sqlite3_column_int64(stmt, c) }
    public func double(_ c: Int32) -> Double { sqlite3_column_double(stmt, c) }
    public func isNull(_ c: Int32) -> Bool { sqlite3_column_type(stmt, c) == SQLITE_NULL }
    public func optInt(_ c: Int32) -> Int64? { isNull(c) ? nil : int(c) }
    public func string(_ c: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, c) else { return nil }
        return String(cString: p)
    }
}
