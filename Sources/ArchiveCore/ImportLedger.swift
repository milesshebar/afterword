import Foundation

/// An importer's decision ledger kept with the import itself: the ledger text is
/// written into `import_ledger` inside the import's transaction, so it commits or rolls back with the rows; the file is published from it
/// after COMMIT, and a retry of an already imported source publishes it again from the database. Additive table (`CREATE TABLE IF NOT
/// EXISTS`), like the call tables: no schema version bump.
public enum ImportLedger {
    static let sql = "CREATE TABLE IF NOT EXISTS import_ledger (source_id INTEGER PRIMARY KEY REFERENCES source(id), body TEXT NOT NULL)"

    public static func save(_ db: Database, sourceID: Int64, body: String) throws {
        try db.exec(sql)
        let st = try db.prepare("INSERT OR REPLACE INTO import_ledger(source_id, body) VALUES (?, ?)")
        st.bind(1, sourceID).bind(2, body)
        try st.run()
    }

    public static func load(_ db: Database, sourceID: Int64) throws -> String? {
        guard try db.tableExists("import_ledger") else { return nil }
        let st = try db.prepare("SELECT body FROM import_ledger WHERE source_id = ?")
        st.bind(1, sourceID)
        defer { st.reset() }
        return try st.step() ? st.string(0) : nil
    }

    /// Writes `<url>.partial`, then renames it to `url` (replacing an older file).
    public static func publish(_ body: String, to url: URL) throws {
        let partial = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".partial")
        try body.write(to: partial, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }
}
