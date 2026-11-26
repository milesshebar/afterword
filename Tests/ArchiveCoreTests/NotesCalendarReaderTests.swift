import Testing
import Foundation
@testable import ArchiveCore

/// The read side of `note` and `calendar_event`: the Mac app's Notes and Calendar lists, and the web
/// app's events under a thread's day headers. Synthetic data only.
@Suite struct NotesCalendarReaderTests {
    static let ny = TimeZone(identifier: "America/New_York")!
    static func ms(_ iso: String) -> Int64 { Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000) }

    static func event(_ start: String, _ end: String? = nil, allDay: Bool = false, floating: Bool = false, title: String = "e") -> CalendarEventItem {
        CalendarEventItem(id: 1, uid: nil, calendar: "Home", summary: title, location: nil, notes: nil, startMs: ms(start), endMs: end.map(ms),
                          allDay: allDay, floating: floating, recurring: false, sourceLabel: "t")
    }

    @Test func eachEventLandsOnTheRightDays() {
        let ny = Self.ny
        // 23:30 New York on May 3 is May 4 in UTC: the viewer's zone decides.
        #expect(CalendarDays.days(of: Self.event("2024-05-04T03:30:00Z"), zone: ny) == [20240503])
        // a floating 23:30 is wall-clock time: May 4, wherever the viewer is
        #expect(CalendarDays.days(of: Self.event("2024-05-04T23:30:00Z", floating: true), zone: ny) == [20240504])
        // all-day: the stored UTC date, with the end as 23:59:59 of the last day or the next midnight
        #expect(CalendarDays.days(of: Self.event("2024-05-03T00:00:00Z", "2024-05-03T23:59:59Z", allDay: true), zone: ny) == [20240503])
        #expect(CalendarDays.days(of: Self.event("2024-05-03T00:00:00Z", "2024-05-04T00:00:00Z", allDay: true), zone: ny) == [20240503])
        #expect(CalendarDays.days(of: Self.event("2024-04-30T00:00:00Z", "2024-05-02T23:59:59Z", allDay: true), zone: ny) == [20240430, 20240501, 20240502])
        // no end, or a runaway span: capped
        #expect(CalendarDays.days(of: Self.event("2024-05-03T00:00:00Z", allDay: true), zone: ny) == [20240503])
        #expect(CalendarDays.days(of: Self.event("2024-01-01T00:00:00Z", "2025-01-01T00:00:00Z", allDay: true), zone: ny).count == CalendarDays.maxSpan)
        // a timed event past midnight stays on its first day
        #expect(CalendarDays.days(of: Self.event("2024-05-03T22:00:00Z", "2024-05-05T02:00:00Z"), zone: ny) == [20240503])
        #expect(CalendarDays.start(ofKey: 20240503, in: ny) == Self.ms("2024-05-03T04:00:00Z"))
    }

    @Test func groupingSortsAllDayFirstThenByStart() {
        let days = CalendarDays.group([Self.event("2024-05-03T20:00:00Z", title: "dinner"), Self.event("2024-05-03T13:00:00Z", title: "coffee"),
                                       Self.event("2024-05-03T00:00:00Z", "2024-05-03T23:59:59Z", allDay: true, title: "birthday"),
                                       Self.event("2024-05-01T13:00:00Z", title: "earlier")], zone: Self.ny)
        #expect(days.map(\.key) == [20240501, 20240503])
        #expect(days[1].events.map(\.displaySummary) == ["birthday", "coffee", "dinner"])
        #expect(CalendarDays.group(days.flatMap(\.events), zone: Self.ny, only: [20240503]).map(\.key) == [20240503])
    }

    static func seed(_ t: TestArchive) throws {
        try CalendarImporter.ensureTables(t.db)
        try NotesImporter.ensureTables(t.db)
        try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-calendar', 'x', 'seed', 0, 0)")
        let e = { (iso: String) in Self.ms(iso) }
        try t.db.exec("""
            INSERT INTO calendar_event(source_id, source_label, uid, calendar, summary, location, start_ts_ms, end_ts_ms, all_day, tz, recurring, exception, hidden, dkey) VALUES
              (1, 'phone', 'U-1', 'Home', 'Dinner', 'Cafe Example', \(e("2024-05-03T23:00:00Z")), \(e("2024-05-04T01:00:00Z")), 0, 'America/New_York', 0, 0, 0, 'a'),
              (1, 'mac',   'U-1', 'Home', 'Dinner', 'Cafe Example', \(e("2024-05-03T23:00:00Z")), \(e("2024-05-04T01:00:00Z")), 0, 'America/New_York', 0, 0, 0, 'b'),
              (1, 'phone', 'U-2', 'Birthdays', 'Ana', NULL, \(e("2024-05-03T00:00:00Z")), \(e("2024-05-03T23:59:59Z")), 1, 'floating', 1, 0, 0, 'c'),
              (1, 'phone', 'U-3', 'Home', 'hidden one', NULL, \(e("2024-05-03T15:00:00Z")), NULL, 0, 'GMT', 0, 0, 1, 'd'),
              (1, 'phone', 'U-4', 'Work', NULL, NULL, \(e("2024-06-10T14:00:00Z")), NULL, 0, '_float', 0, 0, 0, 'e');
            INSERT INTO note(source_id, source_label, uid, title, snippet, folder, account, created_ms, modified_ms, deleted, locked, body, dkey) VALUES
              (1, 'phone', 'N-1', 'Groceries', 'milk', 'Notes', 'iCloud', 1000, 5000, 0, 0, 'Groceries\nmilk, eggs', 'n1'),
              (1, 'phone', 'N-2', NULL, NULL, 'Notes', 'iCloud', 1000, 9000, 0, 0, '\n  First line here\nsecond', 'n2'),
              (1, 'phone', 'N-3', NULL, NULL, 'Private', 'iCloud', 1000, 2000, 0, 1, NULL, 'n3'),
              (1, 'phone', 'N-4', 'Old idea', NULL, 'Recently Deleted', 'iCloud', 1000, NULL, 1, 0, 'café plans', 'n4');
            """)
    }

    @Test func readerListsNotesNewestFirstAndEventsOnceEach() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let empty = try ArchiveReader(root: t.root)
        #expect(try !empty.hasNotes() && !empty.hasCalendar())
        #expect(try empty.notes().isEmpty && empty.calendarEvents().isEmpty && empty.calendarDays([20240503], zone: Self.ny).isEmpty)
        try Self.seed(t)
        let r = try ArchiveReader(root: t.root)
        #expect(try r.hasNotes() && r.hasCalendar())
        let notes = try r.notes()
        #expect(notes.map(\.displayTitle) == ["First line here", "Groceries", "Locked note", "Old idea"])
        #expect(notes[2].locked && notes[2].body == nil && notes[3].deleted)
        #expect(notes.filter { $0.matches("EGGS") }.map(\.id) == [1])
        #expect(notes.filter { $0.matches("cafe") }.map(\.id) == [4])           // diacritics do not matter
        let events = try r.calendarEvents()
        #expect(events.map(\.displaySummary) == ["Ana", "Dinner", "(no title)"])   // hidden left out, the second Dinner (same uid and start) too
        #expect(events[0].floating && events[0].recurring && events[2].floating && !events[1].floating)
        let days = try r.calendarDays([20240503, 20240610, 20240101], zone: Self.ny)
        #expect(days.map(\.key) == [20240503, 20240610])
        #expect(days[0].events.map(\.displaySummary) == ["Ana", "Dinner"])
        #expect(try r.calendarDays([20240504], zone: Self.ny).isEmpty)          // dinner at 19:00 New York is on the 3rd, not the 4th
        #expect(try r.calendarDays([20240504], zone: TimeZone(identifier: "Europe/Paris")!).first?.events.map(\.displaySummary) == ["Dinner"])
    }

    @Test func webMessagesCarryTheDaysEventsWhenAskedWithAZone() throws {
        let dir = Fixtures.tempDir("web-events"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir.appendingPathComponent("archive"))
        try DemoSeed.seed(root: root, options: DemoSeed.Options(scale: 0.02))
        var thread: Int64 = 0, ts: Int64 = 0
        do {
            let db = try Schema.openArchive(root: root)
            let q = try db.prepare("SELECT thread_id, ts_ms FROM message WHERE canonical_id IS NULL ORDER BY ts_ms DESC, id DESC LIMIT 1")
            #expect(try q.step())
            thread = q.int(0); ts = q.int(1); q.reset()
            try CalendarImporter.ensureTables(db)
            try db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-calendar', 'x', 'cal-seed', 0, 0)")
            let sid = db.lastInsertRowID
            try db.exec("""
                INSERT INTO calendar_event(source_id, source_label, uid, calendar, summary, location, start_ts_ms, end_ts_ms, all_day, tz, recurring, exception, hidden, dkey)
                VALUES (\(sid), 'phone', 'W-1', 'Home', 'Movie night', 'Cinema Example', \(ts), \(ts + 3_600_000), 0, 'America/New_York', 0, 0, 0, 'w1')
                """)
        }
        let site = WebSite(service: try WebService(root: root))
        func get(_ query: [String: String]) -> [String: Any] {
            let r = site.handle(HTTPRequest(method: "GET", path: "/api/messages", query: query,
                                            headers: ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith], peer: "127.0.0.1"))
            #expect(r.status == 200)
            return (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        }
        let plain = get(["thread": String(thread), "limit": "10"])
        #expect(plain["events"] == nil)                                           // an older page (no zone) gets the same answer as before
        let withZone = get(["thread": String(thread), "limit": "10", "zone": "America/New_York"])
        let days = withZone["events"] as? [[String: Any]] ?? []
        #expect(days.count == 1)
        #expect(days.first?["day"] as? Int == CalendarDays.key(ts, in: Self.ny))
        let ev = (days.first?["events"] as? [[String: Any]])?.first ?? [:]
        #expect(ev["summary"] as? String == "Movie night" && ev["location"] as? String == "Cinema Example" && ev["allDay"] as? Bool == false)
        let around = get(["thread": String(thread), "mode": "around", "ts": String(ts), "zone": "America/New_York"])
        #expect((around["events"] as? [[String: Any]])?.count == 1)
        let bogus = get(["thread": String(thread), "limit": "10", "zone": "Not/AZone"])
        #expect(bogus["events"] == nil)
    }
}
