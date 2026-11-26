import Foundation

// Read side of the two additive tables the iPhone and Mac imports fill: `note` (Apple Notes, kept private: the
// web app does not show them) and `calendar_event`. The Mac app lists both; the web
// app shows a day's events as a line under the day header of a thread. Both tables are optional: an archive without them reads as
// empty. Read-only, like the rest of ArchiveReader.

public struct NoteItem: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var title: String?
    public var snippet: String?
    public var folder: String?
    public var account: String?
    public var createdMs: Int64?
    public var modifiedMs: Int64?
    /// In Recently Deleted when the backup was taken.
    public var deleted: Bool
    /// Password protected: no body.
    public var locked: Bool
    public var body: String?
    public var sourceLabel: String

    /// The list title: the note's title, else its first line, else a placeholder.
    public var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let line = (body ?? snippet)?.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(line.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        return locked ? "Locked note" : "Untitled note"
    }

    /// Case- and diacritic-insensitive match on the title, folder, snippet and body.
    public func matches(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return [title, folder, snippet, body].contains { $0?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public struct CalendarEventItem: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var uid: String?
    public var calendar: String?
    public var summary: String?
    public var location: String?
    public var notes: String?
    public var startMs: Int64
    public var endMs: Int64?
    public var allDay: Bool
    /// The stored time is a wall-clock time with no zone (all-day events, and timed events the phone kept "floating"): it reads in UTC.
    public var floating: Bool
    /// The first occurrence of a repeating series (the series is not expanded).
    public var recurring: Bool
    public var sourceLabel: String

    public var displaySummary: String {
        if let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        return "(no title)"
    }

    public func matches(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return [summary, location, calendar, notes].contains { $0?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// One day of the calendar list: its key (`yyyymmdd`, the same number the web app's `dayKey` makes) and its events, all-day first.
public struct CalendarDay: Sendable, Identifiable, Hashable {
    public var key: Int
    public var events: [CalendarEventItem]
    public var id: Int { key }
}

/// Which days an event is shown on, in the viewer's zone. A timed event is on the day it starts (floating times read in UTC); an
/// all-day event on every date from its start to the day before its end (the phone stores the end as 23:59:59 of the last day or the
/// next midnight), at most `maxSpan` days. A timed event that runs past midnight stays on its first day.
public enum CalendarDays {
    public static let maxSpan = 31
    static let utc = TimeZone(identifier: "UTC")!

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        return c
    }

    public static func key(_ ms: Int64, in zone: TimeZone) -> Int {
        let d = calendar(zone).dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return (d.year ?? 0) * 10000 + (d.month ?? 0) * 100 + (d.day ?? 0)
    }

    /// Midnight that starts the day, in `zone` (nil for a key that is not a date).
    public static func start(ofKey key: Int, in zone: TimeZone) -> Int64? {
        let comps = DateComponents(year: key / 10000, month: key / 100 % 100, day: key % 100)
        guard let d = calendar(zone).date(from: comps) else { return nil }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    public static func days(of e: CalendarEventItem, zone: TimeZone) -> [Int] {
        if !e.allDay { return [key(e.startMs, in: e.floating ? utc : zone)] }
        let lastMs = max(e.startMs, (e.endMs ?? e.startMs) - 1)
        var out: [Int] = []
        var ms = e.startMs
        let last = key(lastMs, in: utc)
        while out.count < maxSpan {
            let k = key(ms, in: utc)
            out.append(k)
            if k >= last { break }
            ms += 86_400_000
        }
        return out
    }

    /// Events grouped by day, days ascending; within a day all-day events first, then by start, then by title.
    public static func group(_ events: [CalendarEventItem], zone: TimeZone, only keys: Set<Int>? = nil) -> [CalendarDay] {
        var byDay: [Int: [CalendarEventItem]] = [:]
        for e in events {
            for k in days(of: e, zone: zone) where keys?.contains(k) ?? true { byDay[k, default: []].append(e) }
        }
        return byDay.keys.sorted().map { k in
            CalendarDay(key: k, events: byDay[k]!.sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                return $0.displaySummary.localizedCaseInsensitiveCompare($1.displaySummary) == .orderedAscending
            })
        }
    }
}

extension ArchiveReader {
    /// The archive has a `note` table with rows.
    public func hasNotes() throws -> Bool {
        try locked { try db.tableExists("note") && db.scalarInt("SELECT count(*) FROM note") > 0 }
    }

    public func hasCalendar() throws -> Bool {
        try locked { try db.tableExists("calendar_event") && db.scalarInt("SELECT count(*) FROM calendar_event WHERE hidden = 0") > 0 }
    }

    /// Every note, most recently modified first (bodies included: the table is small, and the list searches them).
    public func notes() throws -> [NoteItem] {
        try locked {
            guard try db.tableExists("note") else { return [] }
            let q = try db.prepare("""
                SELECT id, title, snippet, folder, account, created_ms, modified_ms, deleted, locked, body, source_label FROM note
                ORDER BY coalesce(modified_ms, created_ms, 0) DESC, id DESC
                """)
            defer { q.reset() }
            var out: [NoteItem] = []
            while try q.step() {
                out.append(NoteItem(id: q.int(0), title: q.string(1), snippet: q.string(2), folder: q.string(3), account: q.string(4),
                                    createdMs: q.optInt(5), modifiedMs: q.optInt(6), deleted: q.int(7) != 0, locked: q.int(8) != 0,
                                    body: q.string(9), sourceLabel: q.string(10) ?? ""))
            }
            return out
        }
    }

    /// Calendar events that are not hidden, by start; with `startsFrom`/`startsBefore`, only those whose start is in that range.
    /// The same event (uid and start) from two sources is listed once.
    public func calendarEvents(startsFrom lo: Int64? = nil, startsBefore hi: Int64? = nil) throws -> [CalendarEventItem] {
        try locked {
            guard try db.tableExists("calendar_event") else { return [] }
            var sql = """
                SELECT id, uid, calendar, summary, location, notes, start_ts_ms, end_ts_ms, all_day, tz, recurring, source_label
                FROM calendar_event WHERE hidden = 0 AND start_ts_ms IS NOT NULL
                """
            if lo != nil { sql += " AND start_ts_ms >= ?" }
            if hi != nil { sql += " AND start_ts_ms < ?" }
            sql += " ORDER BY start_ts_ms, id"
            let q = try db.prepare(sql)
            defer { q.reset() }
            var i: Int32 = 1
            if let lo { q.bind(i, lo); i += 1 }
            if let hi { q.bind(i, hi) }
            var out: [CalendarEventItem] = []
            var seen = Set<String>()
            while try q.step() {
                let uid = q.string(1), start = q.int(6)
                if let uid, !seen.insert("\(uid)|\(start)").inserted { continue }
                let tz = q.string(9)
                out.append(CalendarEventItem(id: q.int(0), uid: uid, calendar: q.string(2), summary: q.string(3), location: q.string(4),
                                             notes: q.string(5), startMs: start, endMs: q.optInt(7), allDay: q.int(8) != 0,
                                             floating: tz == "floating" || tz == "_float", recurring: q.int(10) != 0, sourceLabel: q.string(11) ?? ""))
            }
            return out
        }
    }

    /// The events shown on each of these days (keys `yyyymmdd` in `zone`); only days that have events come back.
    public func calendarDays(_ keys: Set<Int>, zone: TimeZone) throws -> [CalendarDay] {
        let starts = keys.compactMap { CalendarDays.start(ofKey: $0, in: zone) }
        guard let first = starts.min(), let last = starts.max() else { return [] }
        // Slack: a floating time reads in UTC (up to 14 h from the zone), and an all-day event can start up to maxSpan days earlier.
        let day: Int64 = 86_400_000
        let events = try calendarEvents(startsFrom: first - Int64(CalendarDays.maxSpan + 1) * day, startsBefore: last + 2 * day)
        return CalendarDays.group(events, zone: zone, only: keys)
    }
}
