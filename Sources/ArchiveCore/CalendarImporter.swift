import Foundation

/// Calendar events from an iPhone backup's `Calendar.sqlitedb` (a decrypted extract), as an additive, source-tagged table `calendar_event`
/// (`CREATE TABLE IF NOT EXISTS`, no schema version bump: the deployed web app still opens the archive). Read-only on the extract.
///
/// One row per `CalendarItem` of entity type 2 (events). A recurring event is one row (`recurring = 1`; the series is not expanded) and each
/// edited occurrence is its own row (`exception = 1`), as the phone stores them. Times are Unix ms UTC from Core Data seconds; an all-day
/// event's start is the floating midnight the phone stores (`all_day = 1`, `tz` the event's zone or "floating"). Shown by the Mac app's
/// Calendar window and under the web app's day headers (`NotesCalendarReader.swift`). Idempotent: the same file imports once (its SHA-256), and a later backup adds only events whose key
/// (`uid|start|original occurrence`) is not in the table.
public enum CalendarImporter {
    public static let kind = "ios-calendar"
    static let appleEpoch: Int64 = 978_307_200

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS calendar_event (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES source(id),
            source_label TEXT NOT NULL,         -- which backup: phone-2026-04-20
            uid TEXT,                           -- the event's unique identifier
            calendar TEXT,                      -- calendar title (Home, Family ..., an account's name)
            summary TEXT,
            location TEXT,
            notes TEXT,
            start_ts_ms INTEGER,                -- Unix ms UTC (all-day: floating midnight)
            end_ts_ms INTEGER,
            all_day INTEGER NOT NULL DEFAULT 0,
            tz TEXT,
            recurring INTEGER NOT NULL DEFAULT 0,
            exception INTEGER NOT NULL DEFAULT 0,  -- an edited occurrence of a recurring event
            hidden INTEGER NOT NULL DEFAULT 0,
            created_ms INTEGER,
            modified_ms INTEGER,
            dkey TEXT NOT NULL UNIQUE
        )
        """,
        "CREATE INDEX IF NOT EXISTS calendar_event_start ON calendar_event(start_ts_ms)",
    ]

    public struct Report: Sendable, Codable, Equatable {
        public var label = ""
        public var alreadyImported = false
        public var items = 0              // CalendarItem rows of the event type
        public var inserted = 0, alreadyThere = 0
        public var recurring = 0, exceptions = 0, allDay = 0, hidden = 0, withLocation = 0, withNotes = 0
        public var calendars = 0
        public var firstTsMs: Int64?, lastTsMs: Int64?      // of the events with a plausible date (after 1970)
        public var byYear: [String: Int] = [:]
        public var skippedCalendar: Int?                     // Mac cache: events of a calendar named in skipCalendars
    }

    public static func ensureTables(_ db: Database) throws { for s in tableSQL { try db.exec(s) } }

    /// `path`: `Calendar.sqlitedb`, or a folder that holds `HomeDomain/Library/Calendar/Calendar.sqlitedb`.
    public static func importCalendar(at path: URL, label: String, into db: Database) throws -> Report {
        var url = path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
            url = path.appendingPathComponent("HomeDomain/Library/Calendar/Calendar.sqlitedb")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError("no Calendar.sqlitedb at \(url.path)") }
        try ensureTables(db)
        let (sha, size) = try Hashing.sha256Hex(ofFile: url)
        let seen = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, sha)
        if try seen.step() {
            var r = seen.string(0).flatMap { try? JSONDecoder().decode(Report.self, from: Data($0.utf8)) } ?? Report()
            r.alreadyImported = true
            seen.reset()
            return r
        }
        seen.reset()
        var report = Report()
        report.label = label
        let cal = try Database(path: url.path, readOnly: true, immutable: true)
        let q = try cal.prepare("""
            SELECT c.ROWID, c.unique_identifier, k.title, c.summary, l.title, c.description, c.start_date, c.end_date, coalesce(c.all_day, 0), c.start_tz,
                   coalesce(c.has_recurrences, 0), coalesce(c.orig_item_id, 0), coalesce(c.hidden, 0), c.creation_date, c.last_modified, c.orig_date
            FROM CalendarItem c LEFT JOIN Calendar k ON k.ROWID = c.calendar_id LEFT JOIN Location l ON l.ROWID = c.location_id
            WHERE c.entity_type = 2 ORDER BY c.ROWID
            """)
        func ms(_ v: Double?) -> Int64? { v.map { (Int64($0) + appleEpoch) * 1000 } }
        var calendars = Set<String>()
        try db.transaction {
            let src = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            src.bind(1, kind).bind(2, url.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try src.run()
            let sid = db.lastInsertRowID
            let ins = try db.prepare("""
                INSERT OR IGNORE INTO calendar_event(source_id, source_label, uid, calendar, summary, location, notes, start_ts_ms, end_ts_ms, all_day, tz,
                                                     recurring, exception, hidden, created_ms, modified_ms, dkey) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            while try q.step() {
                report.items += 1
                let rowid = q.int(0)
                let uid = q.string(1)
                let start = q.isNull(6) ? nil : ms(q.double(6)), end = q.isNull(7) ? nil : ms(q.double(7))
                let allDay = q.int(8) != 0, recurring = q.int(10) != 0, exception = q.int(11) > 0, hidden = q.int(12) != 0
                let orig = q.isNull(15) ? "" : String(Int64(q.double(15)))
                let dkey = "\(uid ?? "rowid:\(rowid)")|\(start.map(String.init) ?? "")|\(exception ? orig : "")"
                let summary = q.string(3), location = q.string(4)?.nilIfEmpty, notes = q.string(5)?.nilIfEmpty
                ins.bind(1, sid).bind(2, label).bind(3, uid).bind(4, q.string(2)).bind(5, summary).bind(6, location).bind(7, notes)
                    .bind(8, start).bind(9, end).bind(10, allDay).bind(11, q.string(9)?.nilIfEmpty ?? (allDay ? "floating" : nil))
                    .bind(12, recurring).bind(13, exception).bind(14, hidden)
                    .bind(15, q.isNull(13) ? nil : ms(q.double(13))).bind(16, q.isNull(14) ? nil : ms(q.double(14))).bind(17, dkey)
                try ins.run()
                if db.changes == 0 { report.alreadyThere += 1; continue }
                report.inserted += 1
                if recurring { report.recurring += 1 }
                if exception { report.exceptions += 1 }
                if allDay { report.allDay += 1 }
                if hidden { report.hidden += 1 }
                if location != nil { report.withLocation += 1 }
                if notes != nil { report.withNotes += 1 }
                if let c = q.string(2) { calendars.insert(c) }
                if let s = start, s > 0 {
                    report.firstTsMs = min(report.firstTsMs ?? s, s); report.lastTsMs = max(report.lastTsMs ?? s, s)
                    let y = String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(s) / 1000)).prefix(4))
                    report.byYear[y, default: 0] += 1
                }
            }
            q.reset()
            report.calendars = calendars.count
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(report), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return report
    }

    public static func summary(_ db: Database) throws -> (rows: Int, first: Int64?, last: Int64?)? {
        guard try db.tableExists("calendar_event") else { return nil }
        let q = try db.prepare("SELECT count(*), min(CASE WHEN start_ts_ms > 0 THEN start_ts_ms END), max(CASE WHEN start_ts_ms < 4102444800000 THEN start_ts_ms END) FROM calendar_event")
        defer { q.reset() }
        guard try q.step() else { return nil }
        return (Int(q.int(0)), q.optInt(1), q.optInt(2))
    }
}

extension CalendarImporter {
    public static let macKind = "macos-calendar-cache"

    /// A Mac's `~/Library/Calendars/Calendar Cache` (Core Data; take a snapshot with its WAL folded in first: it is opened immutable), into
    /// `calendar_event` (from an older Mac's backup). Add-only: an event whose uid (`ZSHAREDUID`, the iCalendar UID the
    /// phone's `unique_identifier` carries too) is already in the table, under any label and at any start, is held, not stored again; nothing
    /// already in the table changes. Times as the phone reader stores them (Core Data seconds since 2001 -> Unix ms; all-day starts are the
    /// floating midnight, `tz` "floating"). One row per `Event` (entity found by name); tasks are not events. Idempotent by the file's SHA-256.
    public static func importMacCalendarCache(at url: URL, label: String, into db: Database, origin: String? = nil,
                                              skipCalendars: Set<String> = []) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError("no Calendar Cache at \(url.path)") }
        try ensureTables(db)
        let (fileSHA, size) = try Hashing.sha256Hex(ofFile: url)
        let sha = fileSHA + (skipCalendars.isEmpty ? "" : ":skip=" + skipCalendars.sorted().joined(separator: ","))
        let seen = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, sha)
        if try seen.step() {
            var r = seen.string(0).flatMap { try? JSONDecoder().decode(Report.self, from: Data($0.utf8)) } ?? Report()
            r.alreadyImported = true
            seen.reset()
            return r
        }
        seen.reset()
        var report = Report()
        report.label = label
        let cal = try Database(path: url.path, readOnly: true, immutable: true)
        guard try cal.tableExists("ZCALENDARITEM") else { throw ArchiveError("\(url.path) is not a Mac Calendar Cache") }
        let eventEnt = try cal.scalarInt("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'Event'")
        let q = try cal.prepare("""
            SELECT c.Z_PK, c.ZSHAREDUID, n.ZTITLE, c.ZTITLE,
                   coalesce((SELECT l.ZTITLE FROM ZLOCATION l WHERE l.Z_PK = c.ZSTRUCTUREDLOCATION), (SELECT l.ZTITLE FROM ZLOCATION l WHERE l.ZITEMFORLOCATION = c.Z_PK LIMIT 1)),
                   c.ZNOTES, c.ZSTARTDATE, c.ZENDDATE, coalesce(c.ZISALLDAY, 0), c.ZTIMEZONE,
                   c.ZRECURRENCERULE IS NOT NULL, coalesce(c.ZISDETACHED, 0), c.ZCREATIONDATE, c.ZLASTMODIFIEDDATE
            FROM ZCALENDARITEM c LEFT JOIN ZNODE n ON n.Z_PK = c.ZCALENDAR
            WHERE c.Z_ENT = \(eventEnt) ORDER BY c.Z_PK
            """)
        func ms(_ v: Double) -> Int64 { (Int64(v) + appleEpoch) * 1000 }
        var known = Set<String>()
        let k = try db.prepare("SELECT uid FROM calendar_event WHERE uid IS NOT NULL")
        while try k.step() { if let u = k.string(0) { known.insert(u) } }
        var calendars = Set<String>()
        try db.transaction {
            let src = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            src.bind(1, macKind).bind(2, origin ?? url.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try src.run()
            let sid = db.lastInsertRowID
            let ins = try db.prepare("""
                INSERT OR IGNORE INTO calendar_event(source_id, source_label, uid, calendar, summary, location, notes, start_ts_ms, end_ts_ms, all_day, tz,
                                           recurring, exception, hidden, created_ms, modified_ms, dkey) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?,?)
                """)
            while try q.step() {
                report.items += 1
                let uid = q.string(1)?.nilIfEmpty
                if let uid, known.contains(uid) { report.alreadyThere += 1; continue }
                if let c = q.string(2), skipCalendars.contains(c) { report.skippedCalendar = (report.skippedCalendar ?? 0) + 1; continue }
                let start = q.isNull(6) ? nil : ms(q.double(6)), end = q.isNull(7) ? nil : ms(q.double(7))
                let allDay = q.int(8) != 0, recurring = q.int(10) != 0, exception = q.int(11) != 0
                let location = q.string(4)?.nilIfEmpty, notes = q.string(5)?.nilIfEmpty
                // A key no phone row can carry (theirs is uid|start|orig): this label's own, so a later phone import is not blocked by it.
                let dkey = "\(label)|\(uid ?? "pk:\(q.int(0))")|\(start.map(String.init) ?? "")"
                ins.bind(1, sid).bind(2, label).bind(3, uid).bind(4, q.string(2)).bind(5, q.string(3)).bind(6, location).bind(7, notes)
                    .bind(8, start).bind(9, end).bind(10, allDay).bind(11, q.string(9)?.nilIfEmpty ?? (allDay ? "floating" : nil))
                    .bind(12, recurring).bind(13, exception)
                    .bind(14, q.isNull(12) ? nil : ms(q.double(12))).bind(15, q.isNull(13) ? nil : ms(q.double(13))).bind(16, dkey)
                try ins.run()
                // The key is already there (an event without a uid that an earlier snapshot of this Mac brought): held, nothing changes.
                // dkey is the table's only unique key, so nothing else is ignored here.
                if db.changes == 0 { report.alreadyThere += 1; continue }
                if let uid { known.insert(uid) }
                report.inserted += 1
                if recurring { report.recurring += 1 }
                if exception { report.exceptions += 1 }
                if allDay { report.allDay += 1 }
                if location != nil { report.withLocation += 1 }
                if notes != nil { report.withNotes += 1 }
                if let c = q.string(2) { calendars.insert(c) }
                if let s = start, s > 0 {
                    report.firstTsMs = min(report.firstTsMs ?? s, s); report.lastTsMs = max(report.lastTsMs ?? s, s)
                    report.byYear[String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(s) / 1000)).prefix(4)), default: 0] += 1
                }
            }
            q.reset()
            report.calendars = calendars.count
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(report), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return report
    }
}
