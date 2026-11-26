import Foundation

/// The call table: who the owner called or was called by, when, for how long, from every call log found.
///
/// Input is `calls.tsv` (+ `sources.tsv`): one row per call per log, nothing deduplicated across logs, so every row keeps the
/// log it came from (`source_label`). calls.tsv columns: source, source_key, address, name, ts (Unix seconds UTC), duration (seconds),
/// direction (in|out), outcome (answered|missed|declined|voicemail|blocked|cancelled), service (phone|facetime-audio|facetime-video|
/// whatsapp|skype|viber|google-voice|google-meet|instagram|other-app); sources.tsv: label, description, files, rows. Messenger, Instagram and GroupMe calls are read from the archive's own
/// `message.kind = 'call'` rows (they stay messages too; the call row links back with `message_id`).
///
/// The table is additive and created here (`CREATE TABLE IF NOT EXISTS`), not by a numbered migration: a schema version bump would make the
/// deployed web app (an older build) refuse the archive; older readers ignore these tables.
///
/// Dedupe: rows from different logs that are the same call are linked, never dropped. `canonical_id` is NULL on the row that wins and points
/// at it on the others. Same service and the log's own id (iOS `ZUNIQUE_ID`, a WhatsApp call id, a Skype call id), or same service, same
/// number, start within 2 s, duration within 2 s and same direction, **in two different logs** (two calls in one log are two calls). The winner is the log earliest in `priority` (the newest phone's own
/// log first). Idempotent: a row is keyed by (source label, the log's id or number+time+duration+direction), so a rerun or a later export
/// that overlaps adds only new rows.
///
/// `call_gap` records the spans where no phone or FaceTime log covers the time (90 days or more), because the missing years are a fact the
/// memoir needs to know about; `call_source` summarizes each log.
public struct CallImportStats: Codable, Equatable, Sendable {
    public struct PerSource: Codable, Equatable, Sendable {
        public var rows = 0, canonical = 0, duplicates = 0, minutes = 0, alreadyThere = 0
        public var firstTsMs: Int64?, lastTsMs: Int64?
    }
    public var rows = 0                    // rows written this run
    public var alreadyThere = 0
    public var canonical = 0               // canonical rows in the table after this run
    public var duplicates = 0              // rows linked to a canonical row, in the table after this run
    public var totalRows = 0
    public var linkedToHandle = 0, linkedToThread = 0
    public var perSource: [String: PerSource] = [:]    // totals in the table after this run, by source label
    public var gaps: [String] = []
    public var bad = 0                     // rows skipped for a bad time or field
    public var seconds = 0.0
}

public struct CallImportReport: Sendable {
    public enum Status: Sendable { case imported, alreadyImported }
    public var status: Status
    public var stats: CallImportStats
}

public enum CallImporter {
    public static let sourceKind = "calls-tsv"
    public static let messageSourceKind = "calls-from-messages"
    /// Who wins a duplicate group: earlier is better. Log labels are matched by prefix (`phone` covers `phone-2024`, `phone-old`...),
    /// so calls.tsv labels follow a convention: `phone-...` (a phone's own call history, from a backup), `mac-...` (a Mac's
    /// CallHistoryDB, an iCloud copy of the phone's log), `android-xml`, `whatsapp-app`, `skype-...`; the archive's own Messenger,
    /// Instagram and GroupMe call lines last. Within one prefix the label naming the later year wins (`SourceRank`), then the
    /// earlier call, then the older row. A label matching no prefix ranks after all of these.
    public static let priority = ["phone", "mac", "android-xml", "whatsapp-app", "skype", "messenger", "instagram", "groupme"]
    /// A log added after the table was built is labeled `late-<label>`: it ranks after every other log, listed above or not, so it only
    /// ever links to rows already there (every import re-links the whole table, and a late log must never take a group over).
    public static let addedLaterPrefix = "late-"
    static func rank(_ label: String) -> Int {
        if label.hasPrefix(addedLaterPrefix) { return 10 * SourceRank.unmatched + rank(String(label.dropFirst(addedLaterPrefix.count))) }
        return SourceRank.rank(label, prefixes: priority)
    }
    public static let gapDays = 90

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS call (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES source(id),     -- the import (one row per calls.tsv / message pass)
            source_label TEXT NOT NULL,                           -- the log this call came from: android-xml, phone-2026, mac, skype-2011, messenger ...
            handle_id INTEGER REFERENCES handle(id),              -- the other party when the archive already knows the number/name; never created here
            thread_id INTEGER REFERENCES thread(id),              -- that person's 1:1 thread, when there is one
            message_id INTEGER REFERENCES message(id),            -- Messenger/Instagram/GroupMe: the call line in the thread
            address TEXT,                                         -- normalized number (+1...), wa:<jid>, sk:<name>, or the Meta display name; NULL = withheld
            name TEXT,                                            -- the name the log itself recorded
            ts_ms INTEGER NOT NULL,                               -- start, Unix ms UTC
            duration_s INTEGER NOT NULL DEFAULT 0,                -- 0 for missed / cancelled
            direction TEXT NOT NULL,                              -- in | out
            outcome TEXT NOT NULL,                                -- answered | missed | declined | voicemail | blocked | cancelled
            service TEXT NOT NULL,                                -- phone | facetime-audio | facetime-video | whatsapp | skype | viber | google-voice | messenger | instagram | ...
            source_key TEXT,                                      -- the log's own id (iOS ZUNIQUE_ID, WhatsApp call id, Skype call id); NULL for Android
            dkey TEXT NOT NULL,                                   -- idempotence key within a source label
            canonical_id INTEGER REFERENCES call(id)              -- NULL = canonical; else the copy of the same call that wins
        )
        """,
        "CREATE INDEX IF NOT EXISTS call_ts ON call(ts_ms)",
        "CREATE INDEX IF NOT EXISTS call_handle ON call(handle_id, ts_ms)",
        "CREATE INDEX IF NOT EXISTS call_source_ts ON call(source_label, ts_ms)",
        "CREATE UNIQUE INDEX IF NOT EXISTS call_dkey ON call(source_label, dkey)",
        """
        CREATE TABLE IF NOT EXISTS call_source (
            label TEXT PRIMARY KEY, description TEXT, files TEXT,
            rows INTEGER NOT NULL, canonical INTEGER NOT NULL, first_ts_ms INTEGER, last_ts_ms INTEGER
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS call_gap (
            id INTEGER PRIMARY KEY, scope TEXT NOT NULL, from_ts_ms INTEGER NOT NULL, to_ts_ms INTEGER NOT NULL, days INTEGER NOT NULL, note TEXT NOT NULL
        )
        """,
    ]

    public static func ensureTables(_ db: Database) throws { for s in tableSQL { try db.exec(s) } }

    // MARK: TSV

    struct TSVRow {
        var source: String, key: String, address: String, name: String
        var ts: Int64, duration: Int64, direction: String, outcome: String, service: String
    }

    static func readTSV(_ url: URL) throws -> (rows: [TSVRow], bad: Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [TSVRow] = [], bad = 0
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if first { first = false; continue }
            let f = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 9, let ts = Int64(f[4]), ts > 0, let dur = Int64(f[5]), ["in", "out"].contains(f[6]), !f[0].isEmpty else { bad += 1; continue }
            rows.append(TSVRow(source: f[0], key: f[1], address: f[2], name: f[3], ts: ts, duration: max(0, dur), direction: f[6], outcome: f[7], service: f[8]))
        }
        return (rows, bad)
    }

    /// The address as the archive writes handles: phone/email normalized, `wa:`/`sk:` for those services.
    static func normalizeAddress(_ raw: String, service: String) -> String? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return nil }
        switch service {
        case "whatsapp": return "wa:" + (r.split(separator: "@").first.map(String.init) ?? r)
        case "skype": return "sk:" + r.lowercased()
        default: return HandleNormalizer.normalize(r)?.normalized
        }
    }

    // MARK: import

    /// `folder` holds `calls.tsv` and `sources.tsv` (or is `calls.tsv` itself).
    public static func importExport(at path: URL, into db: Database, origin: String? = nil) throws -> CallImportReport {
        let t0 = Date()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? path : path.deletingLastPathComponent()
        let tsv = isDir.boolValue ? path.appendingPathComponent("calls.tsv") : path
        guard FileManager.default.fileExists(atPath: tsv.path) else { throw ArchiveError("no calls.tsv in \(path.path)") }
        let (hash, bytes) = try Hashing.sha256Hex(ofFile: tsv)
        try ensureTables(db)
        let sel = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        sel.bind(1, hash)
        if try sel.step() {
            let st = sel.string(0).flatMap { try? JSONDecoder().decode(CallImportStats.self, from: Data($0.utf8)) } ?? CallImportStats()
            sel.reset()
            return CallImportReport(status: .alreadyImported, stats: st)
        }
        sel.reset()
        let (rows, bad) = try readTSV(tsv)
        var stats = CallImportStats()
        stats.bad = bad
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, sourceKind).bind(2, origin ?? tsv.path).bind(3, hash).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let lookup = try Lookup(db)
            let insert = try db.prepare("""
                INSERT OR IGNORE INTO call(source_id, source_label, handle_id, thread_id, message_id, address, name, ts_ms, duration_s, direction, outcome,
                                           service, source_key, dkey) VALUES (?,?,?,?,NULL,?,?,?,?,?,?,?,?,?)
                """)
            for r in rows {
                let addr = normalizeAddress(r.address, service: r.service)
                let h = addr.flatMap { lookup.handle[$0] }
                let t = h.flatMap { lookup.thread[$0] }
                let dkey = r.key.isEmpty ? "\(r.ts)|\(addr ?? "")|\(r.duration)|\(r.direction)|\(r.outcome)" : "k:" + r.key
                insert.bind(1, sid).bind(2, r.source).bind(3, h).bind(4, t).bind(5, addr).bind(6, r.name.isEmpty ? nil : r.name)
                    .bind(7, r.ts * 1000).bind(8, r.duration).bind(9, r.direction).bind(10, r.outcome).bind(11, r.service)
                    .bind(12, r.key.isEmpty ? nil : r.key).bind(13, dkey)
                try insert.run()
                if db.changes > 0 { stats.rows += 1 } else { stats.alreadyThere += 1 }
            }
            try finish(db: db, folder: folder, stats: &stats)
            stats.seconds = Date().timeIntervalSince(t0)
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return CallImportReport(status: .imported, stats: stats)
    }

    /// Messenger / Instagram / GroupMe calls from the archive's `kind = 'call'` rows. Idempotent (keyed by the message id).
    public static func importMessageCalls(into db: Database) throws -> CallImportStats {
        try ensureTables(db)
        var stats = CallImportStats()
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, messageSourceKind).bind(2, "message.kind = 'call'").bind(3, "calls-from-messages-" + UUID().uuidString).bind(4, 0)
                .bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let q = try db.prepare("""
                SELECT m.id, m.thread_id, m.ts_ms, m.is_from_me, m.note, t.service, t.is_group,
                       (SELECT tm.handle_id FROM thread_member tm WHERE tm.thread_id = t.id LIMIT 1),
                       (SELECT h.normalized FROM thread_member tm JOIN handle h ON h.id = tm.handle_id WHERE tm.thread_id = t.id LIMIT 1)
                FROM message m JOIN thread t ON t.id = m.thread_id
                WHERE m.kind = 'call' AND m.canonical_id IS NULL AND t.service IN ('messenger', 'instagram', 'groupme') ORDER BY m.id
                """)
            struct M { var id: Int64, thread: Int64, ts: Int64, fromMe: Bool, note: String, service: String, handle: Int64?, address: String? }
            var ms: [M] = []
            while try q.step() {
                let isGroup = q.int(6) != 0
                ms.append(M(id: q.int(0), thread: q.int(1), ts: q.int(2), fromMe: q.int(3) != 0, note: q.string(4) ?? "", service: q.string(5) ?? "",
                            handle: isGroup ? nil : q.optInt(7), address: isGroup ? nil : q.string(8)))
            }
            q.reset()
            let insert = try db.prepare("""
                INSERT OR IGNORE INTO call(source_id, source_label, handle_id, thread_id, message_id, address, name, ts_ms, duration_s, direction, outcome,
                                           service, source_key, dkey) VALUES (?,?,?,?,?,?,NULL,?,?,?,?,?,?,?)
                """)
            for m in ms {
                let dur = durationSeconds(in: m.note)
                let lower = m.note.lowercased()
                let outcome = lower.contains("missed") ? "missed" : (dur > 0 || lower.contains("ended") ? "answered" : "cancelled")
                insert.bind(1, sid).bind(2, m.service).bind(3, m.handle).bind(4, m.thread).bind(5, m.id).bind(6, m.address).bind(7, m.ts)
                    .bind(8, dur).bind(9, m.fromMe ? "out" : "in").bind(10, outcome).bind(11, m.service).bind(12, "msg:\(m.id)").bind(13, "k:msg:\(m.id)")
                try insert.run()
                if db.changes > 0 { stats.rows += 1 } else { stats.alreadyThere += 1 }
            }
            try finish(db: db, folder: nil, stats: &stats)
            if stats.rows == 0 {
                // Nothing new: leave no trace (a rerun must add nothing, not even an empty source row).
                let del = try db.prepare("DELETE FROM source WHERE id = ?")
                del.bind(1, sid)
                try del.run()
                return
            }
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return stats
    }

    /// "(Duration: 29 minutes)" / "(Duration: 50 seconds)" / "(Duration: 1 hour)".
    static func durationSeconds(in note: String) -> Int64 {
        guard let r = note.range(of: "Duration: ") else { return 0 }
        let parts = note[r.upperBound...].split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let n = Int64(parts[0]) else { return 0 }
        if parts[1].hasPrefix("minute") { return n * 60 }
        if parts[1].hasPrefix("hour") { return n * 3600 }
        return parts[1].hasPrefix("second") ? n : 0
    }

    // MARK: handle / thread lookup

    struct Lookup {
        var handle: [String: Int64] = [:]
        var thread: [Int64: Int64] = [:]
        init(_ db: Database) throws {
            let h = try db.prepare("SELECT id, normalized FROM handle")
            while try h.step() { if let n = h.string(1) { handle[n] = h.int(0) } }
            h.reset()
            // 1:1 threads by handle; phone threads (service NULL) win over a service thread of the same handle.
            let t = try db.prepare("""
                SELECT tm.handle_id, t.id, t.service IS NULL FROM thread t JOIN thread_member tm ON tm.thread_id = t.id
                WHERE t.is_group = 0 ORDER BY t.service IS NULL, t.id DESC
                """)
            while try t.step() { thread[t.int(0)] = t.int(1) }
            t.reset()
        }
    }

    // MARK: dedupe, summaries, gaps

    /// Re-links duplicates over the whole table (so a later, overlapping export is folded into earlier rows) and rewrites
    /// `call_source`, `call_gap` and the totals.
    static func finish(db: Database, folder: URL?, stats: inout CallImportStats) throws {
        try db.exec("UPDATE call SET canonical_id = NULL")
        struct C { var id: Int64, label: String, ts: Int64, dur: Int64, dir: String, service: String, addr: String, key: String? }
        let q = try db.prepare("SELECT id, source_label, ts_ms, duration_s, direction, service, coalesce(address, ''), source_key FROM call")
        var all: [C] = []
        while try q.step() {
            all.append(C(id: q.int(0), label: q.string(1) ?? "", ts: q.int(2), dur: q.int(3), dir: q.string(4) ?? "", service: q.string(5) ?? "",
                         addr: q.string(6) ?? "", key: q.string(7)))
        }
        q.reset()
        all.sort { (rank($0.label), $0.ts, $0.id) < (rank($1.label), $1.ts, $1.id) }
        var byKey: [String: Int64] = [:]               // service|key -> canonical id
        var byAddr: [String: [(ts: Int64, dur: Int64, dir: String, id: Int64, label: String)]] = [:]
        var dup: [(Int64, Int64)] = []
        for c in all {
            if let k = c.key, !k.isEmpty, !k.hasPrefix("msg:") {
                if let w = byKey[c.service + "|" + k] { dup.append((c.id, w)); continue }
            }
            let ak = c.service + "|" + c.addr
            if !c.addr.isEmpty, let cands = byAddr[ak],
               let w = cands.first(where: { $0.label != c.label && $0.dir == c.dir && abs($0.ts - c.ts) <= 2000 && abs($0.dur - c.dur) <= 2 }) {
                dup.append((c.id, w.id)); continue
            }
            if let k = c.key, !k.isEmpty, !k.hasPrefix("msg:") { byKey[c.service + "|" + k] = c.id }
            if !c.addr.isEmpty { byAddr[ak, default: []].append((c.ts, c.dur, c.dir, c.id, c.label)) }
        }
        let up = try db.prepare("UPDATE call SET canonical_id = ? WHERE id = ?")
        for (id, w) in dup { up.bind(1, w).bind(2, id); try up.run() }

        // Per source.
        let descriptions = folder.flatMap { readSources($0.appendingPathComponent("sources.tsv")) } ?? [:]
        let existingDesc = try db.prepare("SELECT label, description, files FROM call_source")
        var keep: [String: (String?, String?)] = [:]
        while try existingDesc.step() { keep[existingDesc.string(0) ?? ""] = (existingDesc.string(1), existingDesc.string(2)) }
        existingDesc.reset()
        try db.exec("DELETE FROM call_source")
        let agg = try db.prepare("""
            SELECT source_label, count(*), sum(canonical_id IS NULL), min(ts_ms), max(ts_ms), coalesce(sum(duration_s), 0) / 60
            FROM call GROUP BY source_label
            """)
        let putSource = try db.prepare("INSERT INTO call_source(label, description, files, rows, canonical, first_ts_ms, last_ts_ms) VALUES (?,?,?,?,?,?,?)")
        stats.perSource = [:]
        stats.totalRows = 0; stats.canonical = 0; stats.duplicates = 0
        while try agg.step() {
            let label = agg.string(0) ?? ""
            var p = CallImportStats.PerSource()
            p.rows = Int(agg.int(1)); p.canonical = Int(agg.int(2)); p.duplicates = p.rows - p.canonical
            p.firstTsMs = agg.optInt(3); p.lastTsMs = agg.optInt(4); p.minutes = Int(agg.int(5))
            stats.perSource[label] = p
            stats.totalRows += p.rows; stats.canonical += p.canonical; stats.duplicates += p.duplicates
            let d = descriptions[label] ?? (keep[label].map { ($0.0 ?? "", $0.1 ?? "") } ?? ("", ""))
            putSource.bind(1, label).bind(2, d.0.isEmpty ? nil : d.0).bind(3, d.1.isEmpty ? nil : d.1).bind(4, p.rows).bind(5, p.canonical)
                .bind(6, p.firstTsMs).bind(7, p.lastTsMs)
            try putSource.run()
        }
        agg.reset()
        stats.linkedToHandle = Int(try db.scalarInt("SELECT count(*) FROM call WHERE handle_id IS NOT NULL"))
        stats.linkedToThread = Int(try db.scalarInt("SELECT count(*) FROM call WHERE thread_id IS NOT NULL"))

        // Gaps in the phone and FaceTime record.
        try db.exec("DELETE FROM call_gap")
        let g = try db.prepare("""
            SELECT ts_ms FROM call WHERE canonical_id IS NULL AND service IN ('phone', 'facetime-audio', 'facetime-video') ORDER BY ts_ms
            """)
        var prev: Int64?
        let putGap = try db.prepare("INSERT INTO call_gap(scope, from_ts_ms, to_ts_ms, days, note) VALUES ('phone-and-facetime', ?, ?, ?, ?)")
        func day(_ ms: Int64) -> String { String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000)).prefix(10)) }
        var biggest: (Int64, Int64, Int)?
        while try g.step() {
            let ts = g.int(0)
            if let p = prev {
                let days = Int((ts - p) / 86_400_000)
                if days >= gapDays {
                    let note = "No phone or FaceTime call log covers \(day(p)) to \(day(ts)) (\(days) days); only Messenger, Instagram, WhatsApp or Skype calls exist then."
                    putGap.bind(1, p).bind(2, ts).bind(3, days).bind(4, note)
                    try putGap.run()
                    stats.gaps.append("\(day(p)) -> \(day(ts)) (\(days) days)")
                    if days > (biggest?.2 ?? 0) { biggest = (p, ts, days) }
                }
            }
            prev = ts
        }
        g.reset()
        if let b = biggest { try MetaImporter.setMeta(db, "calls.hole", "\(day(b.0)) -> \(day(b.1)) (\(b.2) days): no phone or FaceTime log") }
    }

    static func readSources(_ url: URL) -> [String: (String, String)]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String: (String, String)] = [:]
        var first = true
        for line in text.split(separator: "\n") {
            if first { first = false; continue }
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if f.count >= 3 { out[f[0]] = (f[1], f[2]) }
        }
        return out
    }
}
