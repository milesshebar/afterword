import Foundation

/// The user's manual corrections to the automatic person matching, kept in a small database of their own (`people.sqlite` in
/// the archive root) so the app can keep opening `archive.sqlite` read-only. Handles are referenced by their normalized
/// spelling, not by row id, so the corrections survive re-imports, re-matching and even a rebuilt archive.
///
/// The effective mapping is: automatic groups, then these overrides on top (`PeopleIndex.build`).
public struct OverrideSet: Sendable, Equatable {
    /// Pairs of handles that are the same person (a merge stores every cross pair of the two people's handles).
    public var links: [[String]] = []
    /// Handles taken out of their automatic group (a split).
    public var detached: Set<String> = []
    /// Handle -> (name, when). A person takes the newest rename among its handles.
    public var renames: [String: Rename] = [:]
    /// Handles whose person is hidden from the list (a person is hidden when all its handles are).
    public var hidden: Set<String> = []
    public struct Rename: Sendable, Equatable { public var name: String; public var at: Int64 }
    public init() {}
    public var isEmpty: Bool { links.isEmpty && detached.isEmpty && renames.isEmpty && hidden.isEmpty }
    public var count: Int { links.count + detached.count + renames.count + hidden.count }
}

public final class PeopleOverrides {
    public static let fileName = "people.sqlite"

    public static func fileURL(root: ArchiveRoot) -> URL { root.url.appendingPathComponent(fileName) }

    private let db: Database
    public let url: URL

    /// Opens (creating if needed) for writing. A rollback journal always: the file is tiny, and a root on a network
    /// volume cannot use WAL.
    public init(root: ArchiveRoot) throws {
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        url = Self.fileURL(root: root)
        let existed = FileManager.default.fileExists(atPath: url.path)
        db = try Database(path: url.path)
        try db.exec("PRAGMA journal_mode = DELETE")
        try db.exec("PRAGMA synchronous = FULL")
        try Self.migrate(db, backupOf: existed ? url : nil)
    }

    /// people.sqlite schema version. 0 = the four correction tables; 1 adds `reject` (pairs the user said are not the same person)
    /// and `decision` (the review site's undo log). Both are plain new tables, so an older build reading the file never notices.
    public static let schemaVersion = 1

    /// Brings the file up to `schemaVersion`. Idempotent; runs in one transaction; a file that already holds corrections is
    /// copied to `people.sqlite.pre-v1` first (once) so the change can always be taken back.
    static func migrate(_ db: Database, backupOf file: URL?) throws {
        let v = try db.userVersion()
        if v > schemaVersion { throw ArchiveError("people.sqlite is schema v\(v), newer than this build (v\(schemaVersion))") }
        if v < 1, let file {
            let hasRows = (try? db.tableExists("link")) == true
            let bak = file.appendingPathExtension("pre-v1")
            if hasRows, !FileManager.default.fileExists(atPath: bak.path) { try? FileManager.default.copyItem(at: file, to: bak) }
        }
        try db.transaction {
            try createSchema(db)
            try db.exec("CREATE TABLE IF NOT EXISTS reject (a TEXT NOT NULL, b TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (a, b)) WITHOUT ROWID")
            try db.exec("CREATE TABLE IF NOT EXISTS decision (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, at INTEGER NOT NULL, undone INTEGER NOT NULL DEFAULT 0, label TEXT, payload TEXT NOT NULL)")
            try db.setUserVersion(schemaVersion)
        }
    }

    static func createSchema(_ db: Database) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS link (a TEXT NOT NULL, b TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (a, b)) WITHOUT ROWID")
        try db.exec("CREATE TABLE IF NOT EXISTS detach (handle TEXT PRIMARY KEY, at INTEGER NOT NULL) WITHOUT ROWID")
        try db.exec("CREATE TABLE IF NOT EXISTS rename (handle TEXT PRIMARY KEY, name TEXT NOT NULL, at INTEGER NOT NULL) WITHOUT ROWID")
        try db.exec("CREATE TABLE IF NOT EXISTS hide (handle TEXT PRIMARY KEY, at INTEGER NOT NULL) WITHOUT ROWID")
    }

    /// Reads the overrides without creating anything. A missing file is an empty set.
    public static func read(root: ArchiveRoot) -> OverrideSet {
        let path = fileURL(root: root).path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? Database(path: path, readOnly: true, immutable: root.opensImmutable) else { return OverrideSet() }
        return (try? readAll(db)) ?? OverrideSet()
    }

    public func read() throws -> OverrideSet { try Self.readAll(db) }

    static func readAll(_ db: Database) throws -> OverrideSet {
        var s = OverrideSet()
        if try db.tableExists("link") {
            let st = try db.prepare("SELECT a, b FROM link ORDER BY a, b")
            while try st.step() { s.links.append([st.string(0) ?? "", st.string(1) ?? ""]) }
        }
        if try db.tableExists("detach") {
            let st = try db.prepare("SELECT handle FROM detach")
            while try st.step() { if let h = st.string(0) { s.detached.insert(h) } }
        }
        if try db.tableExists("rename") {
            let st = try db.prepare("SELECT handle, name, at FROM rename")
            while try st.step() { if let h = st.string(0) { s.renames[h] = OverrideSet.Rename(name: st.string(1) ?? "", at: st.int(2)) } }
        }
        if try db.tableExists("hide") {
            let st = try db.prepare("SELECT handle FROM hide")
            while try st.step() { if let h = st.string(0) { s.hidden.insert(h) } }
        }
        return s
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var txDepth = 0

    /// Runs `body` in one transaction; nested calls join the outer one. The review site wraps an edit and its decision-log row in
    /// a single call, so a crash can never leave an edit that the site cannot undo.
    @discardableResult
    public func atomically<T>(_ body: () throws -> T) throws -> T { try tx(body) }

    private func tx<T>(_ body: () throws -> T) throws -> T {
        if txDepth > 0 { return try body() }
        txDepth += 1
        defer { txDepth -= 1 }
        return try db.transaction(body)
    }

    // MARK: edits (all keyed by normalized handle spellings)

    /// Makes every handle of `a` and every handle of `b` one person (all cross pairs, so removing one handle later
    /// leaves the rest still joined).
    public func merge(_ a: [String], with b: [String]) throws { _ = try mergeReturningNew(a, with: b) }

    /// Like `merge`, and returns the link pairs that did not exist before (what an undo has to remove again).
    @discardableResult
    public func mergeReturningNew(_ a: [String], with b: [String]) throws -> [[String]] {
        try tx {
            let has = try db.prepare("SELECT 1 FROM link WHERE a = ? AND b = ?")
            let ins = try db.prepare("INSERT OR REPLACE INTO link(a, b, at) VALUES (?,?,?)")
            let t = now()
            var fresh: [[String]] = []
            for x in a { for y in b where x != y {
                let (lo, hi) = x < y ? (x, y) : (y, x)
                has.bind(1, lo).bind(2, hi)
                let exists = try has.step()
                has.reset()
                if !exists { fresh.append([lo, hi]) }
                ins.bind(1, lo).bind(2, hi).bind(3, t)
                try ins.run()
            } }
            return fresh
        }
    }

    /// Removes exactly these link pairs (an undo of a merge).
    public func removeLinks(_ pairs: [[String]]) throws {
        try tx {
            let del = try db.prepare("DELETE FROM link WHERE a = ? AND b = ?")
            for p in pairs where p.count == 2 { del.bind(1, p[0]).bind(2, p[1]); try del.run() }
        }
    }

    // MARK: rejections ("not the same person") and the decision log (review site)

    /// Records that every handle of `a` and every handle of `b` are different people. Returns the pairs newly stored.
    @discardableResult
    public func reject(_ a: [String], _ b: [String]) throws -> [[String]] {
        try tx {
            let has = try db.prepare("SELECT 1 FROM reject WHERE a = ? AND b = ?")
            let ins = try db.prepare("INSERT OR IGNORE INTO reject(a, b, at) VALUES (?,?,?)")
            let t = now()
            var fresh: [[String]] = []
            for x in a { for y in b where x != y {
                let (lo, hi) = x < y ? (x, y) : (y, x)
                has.bind(1, lo).bind(2, hi)
                let exists = try has.step()
                has.reset()
                if !exists { fresh.append([lo, hi]) }
                ins.bind(1, lo).bind(2, hi).bind(3, t)
                try ins.run()
            } }
            return fresh
        }
    }

    public func removeRejections(_ pairs: [[String]]) throws {
        try tx {
            let del = try db.prepare("DELETE FROM reject WHERE a = ? AND b = ?")
            for p in pairs where p.count == 2 { del.bind(1, p[0]).bind(2, p[1]); try del.run() }
        }
    }

    static func readRejections(_ db: Database) throws -> Set<String> {
        var out = Set<String>()
        guard try db.tableExists("reject") else { return out }
        let st = try db.prepare("SELECT a, b FROM reject")
        while try st.step() { out.insert(MatchSuggester.rejectionKey(st.string(0) ?? "", st.string(1) ?? "")) }
        return out
    }

    public static func readRejections(root: ArchiveRoot) -> Set<String> {
        let path = fileURL(root: root).path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? Database(path: path, readOnly: true, immutable: root.opensImmutable) else { return [] }
        return (try? readRejections(db)) ?? []
    }

    public struct Decision: Sendable, Equatable {
        public var id: Int64
        public var kind: String          // merge | reject | rename | none
        public var at: Int64
        public var undone: Bool
        public var label: String
        public var payload: String       // JSON
    }

    @discardableResult
    public func logDecision(kind: String, label: String, payload: [String: Any]) throws -> Int64 {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let st = try db.prepare("INSERT INTO decision(kind, at, undone, label, payload) VALUES (?,?,0,?,?)")
        st.bind(1, kind).bind(2, now()).bind(3, label).bind(4, String(decoding: data, as: UTF8.self))
        try st.run()
        return db.lastInsertRowID
    }

    /// Newest first.
    public func decisions(limit: Int) throws -> [Decision] { try Self.readDecisions(db, limit: limit) }

    /// The newest decision still in force: the only one an undo may take back (undo is last-in-first-out).
    public func newestLiveDecision() throws -> Decision? { try Self.readDecisions(db, limit: 1, liveOnly: true).first }

    static func readDecisions(_ db: Database, limit: Int, liveOnly: Bool = false) throws -> [Decision] {
        guard try db.tableExists("decision") else { return [] }
        let st = try db.prepare("SELECT id, kind, at, undone, label, payload FROM decision \(liveOnly ? "WHERE undone = 0 " : "")ORDER BY id DESC LIMIT ?")
        st.bind(1, limit)
        var out: [Decision] = []
        while try st.step() {
            out.append(Decision(id: st.int(0), kind: st.string(1) ?? "", at: st.int(2), undone: st.int(3) != 0, label: st.string(4) ?? "", payload: st.string(5) ?? "{}"))
        }
        return out
    }

    /// Read-only views for the review site's page loads: they never open people.sqlite for writing (no migration, no journal
    /// mode change). A missing file or a missing table is an empty answer.
    public static func readDecisions(root: ArchiveRoot, limit: Int) -> [Decision] {
        withReadOnly(root) { (try? readDecisions($0, limit: limit)) ?? [] } ?? []
    }
    public static func newestLiveDecision(root: ArchiveRoot) -> Decision? {
        withReadOnly(root) { (try? readDecisions($0, limit: 1, liveOnly: true))?.first } ?? nil
    }
    public static func decisionCount(root: ArchiveRoot, kind: String) -> Int {
        withReadOnly(root) { db -> Int in
            guard (try? db.tableExists("decision")) == true, let st = try? db.prepare("SELECT count(*) FROM decision WHERE kind = ? AND undone = 0") else { return 0 }
            st.bind(1, kind)
            return ((try? st.step()) == true) ? Int(st.int(0)) : 0
        } ?? 0
    }

    /// Handle spellings of every person the user marked "No match" in the Who's-this queue (decisions of kind `none` still in force).
    /// A plain use of the decision log: no table of its own, so an older build reading the file never notices.
    public static func readNoMatchKeys(root: ArchiveRoot) -> Set<String> {
        withReadOnly(root) { db -> Set<String> in
            guard (try? db.tableExists("decision")) == true, let st = try? db.prepare("SELECT payload FROM decision WHERE kind = 'none' AND undone = 0") else { return [] }
            var out = Set<String>()
            while (try? st.step()) == true {
                let obj = (try? JSONSerialization.jsonObject(with: Data((st.string(0) ?? "{}").utf8))) as? [String: Any] ?? [:]
                for k in obj["keys"] as? [String] ?? [] { out.insert(k) }
            }
            return out
        } ?? []
    }

    private static func withReadOnly<T>(_ root: ArchiveRoot, _ body: (Database) -> T) -> T? {
        let path = fileURL(root: root).path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? Database(path: path, readOnly: true, immutable: root.opensImmutable) else { return nil }
        return body(db)
    }

    /// Decisions of a kind that are still in force (not undone).
    public func decisionCount(kind: String) throws -> Int {
        let st = try db.prepare("SELECT count(*) FROM decision WHERE kind = ? AND undone = 0")
        st.bind(1, kind)
        return try st.step() ? Int(st.int(0)) : 0
    }

    public func markUndone(_ id: Int64) throws {
        let st = try db.prepare("UPDATE decision SET undone = 1 WHERE id = ?")
        st.bind(1, id)
        try st.run()
    }

    /// The renames currently stored for these handles (name, time), so a rename can be put back.
    public func renames(of handles: [String]) throws -> [String: OverrideSet.Rename] {
        let all = try read().renames
        return all.filter { handles.contains($0.key) }
    }

    /// Puts renames back exactly as they were: handles in `previous` get that name and time, the rest lose any rename.
    public func restoreRenames(handles: [String], previous: [String: OverrideSet.Rename]) throws {
        try tx {
            let del = try db.prepare("DELETE FROM rename WHERE handle = ?")
            let ins = try db.prepare("INSERT OR REPLACE INTO rename(handle, name, at) VALUES (?,?,?)")
            for h in handles {
                del.bind(1, h); try del.run()
                if let r = previous[h] { ins.bind(1, h).bind(2, r.name).bind(3, r.at); try ins.run() }
            }
        }
    }

    /// Takes `handles` out of whatever they were joined to. They stay together with each other when `together` is true
    /// (the usual "split this service off as one person").
    public func split(_ handles: [String], together: Bool = true) throws {
        try tx {
            let del = try db.prepare("DELETE FROM link WHERE a = ? OR b = ?")
            let det = try db.prepare("INSERT OR REPLACE INTO detach(handle, at) VALUES (?,?)")
            let ren = try db.prepare("DELETE FROM rename WHERE handle = ?")
            let hid = try db.prepare("DELETE FROM hide WHERE handle = ?")
            let t = now()
            for h in handles {
                del.bind(1, h).bind(2, h); try del.run()
                det.bind(1, h).bind(2, t); try det.run()
                ren.bind(1, h); try ren.run()
                hid.bind(1, h); try hid.run()
            }
        }
        if together, handles.count > 1 {
            for i in 0..<handles.count { for j in (i + 1)..<handles.count { try merge([handles[i]], with: [handles[j]]) } }
        }
    }

    /// Names a person (every handle of it carry the same name and time). An empty or nil name clears the rename.
    public func rename(_ handles: [String], to name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try tx {
            let del = try db.prepare("DELETE FROM rename WHERE handle = ?")
            let ins = try db.prepare("INSERT OR REPLACE INTO rename(handle, name, at) VALUES (?,?,?)")
            let t = now()
            for h in handles {
                del.bind(1, h); try del.run()
                if !trimmed.isEmpty { ins.bind(1, h).bind(2, trimmed).bind(3, t); try ins.run() }
            }
        }
    }

    public func setHidden(_ handles: [String], _ hidden: Bool) throws {
        try tx {
            let st = try db.prepare(hidden ? "INSERT OR REPLACE INTO hide(handle, at) VALUES (?, ?)" : "DELETE FROM hide WHERE handle = ?")
            let t = now()
            for h in handles {
                st.bind(1, h)
                if hidden { st.bind(2, t) }
                try st.run()
            }
        }
    }

    /// Forgets every correction that touches these handles (the automatic match applies again).
    public func reset(_ handles: [String]) throws {
        try tx {
            for (sql, twice) in [("DELETE FROM link WHERE a = ? OR b = ?", true), ("DELETE FROM detach WHERE handle = ?", false),
                                 ("DELETE FROM rename WHERE handle = ?", false), ("DELETE FROM hide WHERE handle = ?", false)] {
                let st = try db.prepare(sql)
                for h in handles { st.bind(1, h); if twice { st.bind(2, h) }; try st.run() }
            }
        }
    }
}
