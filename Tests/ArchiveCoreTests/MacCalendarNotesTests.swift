import Testing
import Foundation
@testable import ArchiveCore

/// An older Mac's Calendar Cache (Core Data) and its 2012-15 local Notes store (NotesV7.storedata): both go into the
/// existing additive tables, change nothing already there, and hold anything the table already has. Synthetic data only.
enum MacStoreFixtures {
    static let t0: Double = 600_000_000            // 2020-01-06 (seconds since 2001-01-01)

    /// Entity 5 = Event, 6 = Task, as in the real cache's Z_PRIMARYKEY.
    static func calendarCache(dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("Calendar Cache")
        let db = try Database(path: url.path)
        try db.exec("""
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY VALUES (4, 'CalendarItem', 0, 0), (5, 'Event', 4, 0), (6, 'Task', 4, 0);
            CREATE TABLE ZNODE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZTITLE VARCHAR);
            INSERT INTO ZNODE VALUES (1, 43, 'Home'), (2, 41, 'Work');
            CREATE TABLE ZLOCATION (Z_PK INTEGER PRIMARY KEY, ZITEMFORLOCATION INTEGER, ZTITLE VARCHAR, ZADDRESS VARCHAR);
            INSERT INTO ZLOCATION VALUES (1, 3, 'Example Park', NULL);
            CREATE TABLE ZCALENDARITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZCALENDAR INTEGER, ZSHAREDUID VARCHAR, ZTITLE VARCHAR, ZNOTES VARCHAR,
                ZSTARTDATE TIMESTAMP, ZENDDATE TIMESTAMP, ZISALLDAY INTEGER, ZTIMEZONE VARCHAR, ZRECURRENCERULE VARCHAR, ZISDETACHED INTEGER,
                ZSTRUCTUREDLOCATION INTEGER, ZCREATIONDATE TIMESTAMP, ZLASTMODIFIEDDATE TIMESTAMP);
            INSERT INTO ZCALENDARITEM VALUES
                (1, 5, 1, 'U-OLD', 'Dentist', NULL, \(t0 + 3600), \(t0 + 7200), 0, 'America/New_York', NULL, 0, NULL, \(t0 - 100), \(t0 - 50)),
                (2, 5, 1, 'U-ALLDAY', 'Birthday', NULL, \(t0 + 86400), \(t0 + 172800), 1, NULL, 'FREQ=YEARLY', 0, NULL, \(t0), \(t0)),
                (3, 5, 2, 'U-NEW', 'Run', 'bring water', \(t0 + 90000), \(t0 + 93600), 0, 'America/New_York', NULL, 1, 1, \(t0), \(t0 + 10)),
                (4, 6, 1, 'U-TASK', 'a task', NULL, NULL, NULL, 0, NULL, NULL, 0, NULL, \(t0), \(t0)),
                (5, 5, 1, NULL, 'no uid', NULL, \(t0 + 5000), \(t0 + 6000), 0, 'America/New_York', NULL, 0, NULL, \(t0), \(t0));
            """)
        return url
    }

    static func notesV7(dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("NotesV7.storedata")
        let db = try Database(path: url.path)
        try db.exec("""
            CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR);
            INSERT INTO ZFOLDER VALUES (1, 'Notes');
            CREATE TABLE ZNOTEBODY (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZHTMLSTRING VARCHAR);
            CREATE TABLE ZNOTE (Z_PK INTEGER PRIMARY KEY, ZBODY INTEGER, ZFOLDER INTEGER, ZDATECREATED TIMESTAMP, ZDATEEDITED TIMESTAMP,
                ZTITLE VARCHAR, ZUNIVERSALLYUNIQUEID VARCHAR, ZREMOTEID VARCHAR);
            INSERT INTO ZNOTEBODY VALUES (1, 1, '<div>Groceries</div><div>milk</div>'),
                (2, 2, '<div>Hello <b>world</b> &amp; you</div><div><br></div><div>line&nbsp;2</div>'),
                (3, 3, '<div>Same words, other title</div>');
            INSERT INTO ZNOTE VALUES (1, 1, 1, \(t0), \(t0 + 5), 'Groceries', 'V7-1', NULL),
                (2, 2, 1, \(t0 + 100), \(t0 + 200), 'Hello world', 'V7-2', NULL),
                (3, 3, 1, \(t0 + 300), \(t0 + 300), 'Renamed', 'V7-3', NULL);
            """)
        return url
    }

    /// An archive that already holds one calendar event (U-OLD, at another start) and two notes (Groceries, created at t0; a note
    /// whose body is the third V7 note's text).
    static func archive() throws -> TestArchive {
        let t = try TestArchive()
        try CalendarImporter.ensureTables(t.db)
        try NotesImporter.ensureTables(t.db)
        let ms = { (s: Double) in (Int64(s) + 978_307_200) * 1000 }
        try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-calendar', 'x', 'seed', 0, 0)")
        try t.db.exec("""
            INSERT INTO calendar_event(source_id, source_label, uid, calendar, summary, start_ts_ms, end_ts_ms, all_day, recurring, exception, hidden, dkey)
            VALUES (1, 'phone2', 'U-OLD', 'Home', 'Dentist', \(ms(t0 + 7200)), \(ms(t0 + 9000)), 0, 0, 0, 0, 'U-OLD|x|');
            INSERT INTO note(source_id, source_label, uid, title, created_ms, modified_ms, body, dkey)
            VALUES (1, 'phone2', 'N-1', 'Groceries', \(ms(t0 + 20)), \(ms(t0 + 20)), 'Groceries\nmilk', 'N-1'),
                   (1, 'phone2', 'N-2', 'Something', \(ms(t0 + 9999)), \(ms(t0 + 9999)), 'Same words,  other title', 'N-2');
            """)
        return t
    }
}

@Suite struct MacCalendarNotesTests {
    @Test func macCalendarCacheAddsOnlyEventsTheTableLacksAndChangesNothingElse() throws {
        let t = try MacStoreFixtures.archive(); defer { t.cleanup() }
        let url = try MacStoreFixtures.calendarCache(dir: t.dir)
        let before = try t.db.scalarString("SELECT group_concat(id || source_label || uid || start_ts_ms || dkey, ';') FROM calendar_event")
        let r = try CalendarImporter.importMacCalendarCache(at: url, label: "mac-2021", into: t.db)
        #expect(r.items == 4)                                     // the 4 events; the task is not one
        #expect(r.inserted == 3 && r.alreadyThere == 1)           // U-OLD is held by its uid even at another start
        #expect(try t.db.scalarString("SELECT group_concat(id || source_label || uid || start_ts_ms || dkey, ';') FROM calendar_event WHERE id = 1") == before)
        #expect(try t.db.scalarInt("SELECT count(*) FROM calendar_event WHERE uid = 'U-OLD'") == 1)
        let ms = { (s: Double) in (Int64(s) + 978_307_200) * 1000 }
        #expect(try t.db.scalarInt("SELECT start_ts_ms FROM calendar_event WHERE uid = 'U-NEW'") == ms(MacStoreFixtures.t0 + 90000))
        #expect(try t.db.scalarString("SELECT calendar || '|' || location || '|' || notes || '|' || exception FROM calendar_event WHERE uid = 'U-NEW'") == "Work|Example Park|bring water|1")
        #expect(try t.db.scalarString("SELECT tz || '|' || all_day || '|' || recurring FROM calendar_event WHERE uid = 'U-ALLDAY'") == "floating|1|1")
        #expect(try t.db.scalarInt("SELECT count(*) FROM calendar_event WHERE source_label = 'mac-2021'") == 3)
        #expect(try t.db.scalarInt("SELECT count(*) FROM calendar_event WHERE uid IS NULL AND summary = 'no uid'") == 1)
        #expect(try CalendarImporter.importMacCalendarCache(at: url, label: "mac-2021", into: t.db).alreadyImported)
        #expect(try t.db.scalarInt("SELECT count(*) FROM calendar_event") == 4)
    }

    /// A subscribed public calendar (US Holidays) stays out; `skipCalendars` names it, and
    /// the source row carries the origin given (the NAS's location), not the snapshot's path.
    @Test func macCalendarCacheSkipsNamedCalendarsAndRecordsTheOrigin() throws {
        let t = try MacStoreFixtures.archive(); defer { t.cleanup() }
        let url = try MacStoreFixtures.calendarCache(dir: t.dir)
        let r = try CalendarImporter.importMacCalendarCache(at: url, label: "mac-2021", into: t.db, origin: "host:/x/Calendar Cache",
                                                            skipCalendars: ["Work"])
        #expect(r.inserted == 2 && r.alreadyThere == 1 && r.skippedCalendar == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM calendar_event WHERE uid = 'U-NEW'") == 0)
        #expect(try t.db.scalarString("SELECT path FROM source WHERE kind = 'macos-calendar-cache'") == "host:/x/Calendar Cache")
        let n = try MacStoreFixtures.notesV7(dir: t.dir)
        _ = try NotesImporter.importNotesV7(at: n, label: "mac-2021", into: t.db, origin: "host:/x/NotesV7.storedata")
        #expect(try t.db.scalarString("SELECT path FROM source WHERE kind = 'macos-notes-v7'") == "host:/x/NotesV7.storedata")
    }

    @Test func notesV7AddsOnlyNotesTheTableLacks() throws {
        let t = try MacStoreFixtures.archive(); defer { t.cleanup() }
        let url = try MacStoreFixtures.notesV7(dir: t.dir)
        let before = try t.db.scalarString("SELECT group_concat(id || uid || title || body, ';') FROM note")
        let r = try NotesImporter.importNotesV7(at: url, label: "mac-2021", into: t.db)
        #expect(r.notes == 3)
        // Groceries: same title, created within a minute -> held; Renamed: same text (whitespace aside) as N-2 -> held.
        #expect(r.inserted == 1 && r.alreadyThere == 2)
        #expect(try t.db.scalarString("SELECT group_concat(id || uid || title || body, ';') FROM note WHERE id <= 2") == before)
        #expect(try t.db.scalarString("SELECT body FROM note WHERE uid = 'V7-2'") == "Hello world & you\n\nline 2")
        #expect(try t.db.scalarString("SELECT source_label || '|' || title || '|' || folder FROM note WHERE uid = 'V7-2'") == "mac-2021|Hello world|Notes")
        #expect(try NotesImporter.importNotesV7(at: url, label: "mac-2021", into: t.db).alreadyImported)
        #expect(try t.db.scalarInt("SELECT count(*) FROM note") == 3)
    }

    /// The real store keeps each note's id as an archived NSUUID (a bplist blob with NULs), not text: read as text, every id is "bplist00"
    /// and the second new note collided with the first (seen on a real copy). The id is the UUID inside the blob.
    @Test func notesV7IdsAreArchivedUUIDs() throws {
        let t = try MacStoreFixtures.archive(); defer { t.cleanup() }
        let url = try MacStoreFixtures.notesV7(dir: t.dir)
        let w = try Database(path: url.path)
        let u2 = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, u3 = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        try w.exec("INSERT INTO ZNOTEBODY VALUES (4, 4, '<div>another new one</div>')")
        try w.exec("INSERT INTO ZNOTE VALUES (4, 4, 1, \(MacStoreFixtures.t0 + 900), \(MacStoreFixtures.t0 + 900), 'Fourth', NULL, NULL)")
        for (pk, u) in [(2, u2), (4, u3)] {
            let blob = try NSKeyedArchiver.archivedData(withRootObject: u as NSUUID, requiringSecureCoding: true)
            let st = try w.prepare("UPDATE ZNOTE SET ZUNIVERSALLYUNIQUEID = ? WHERE Z_PK = ?")
            st.bindBlob(1, blob).bind(2, Int64(pk))
            try st.run()
        }
        let r = try NotesImporter.importNotesV7(at: url, label: "mac-2021", into: t.db)
        #expect(r.inserted == 2)
        #expect(try t.db.scalarString("SELECT uid FROM note WHERE title = 'Hello world'") == u2.uuidString)
        #expect(try t.db.scalarString("SELECT uid FROM note WHERE title = 'Fourth'") == u3.uuidString)
    }

    // MARK: edge cases

    /// A later snapshot that still holds an already imported event without a uid must hold it, not collide on its key and roll
    /// the whole import back.
    @Test func aLaterSnapshotHoldsAnEventWithoutAUidItAlreadyImported() throws {
        let t = try MacStoreFixtures.archive(); defer { t.cleanup() }
        let url = try MacStoreFixtures.calendarCache(dir: t.dir)
        _ = try CalendarImporter.importMacCalendarCache(at: url, label: "mac-2021", into: t.db)
        let w = try Database(path: url.path)
        try w.exec("INSERT INTO ZCALENDARITEM (Z_PK, Z_ENT, ZCALENDAR, ZSHAREDUID, ZTITLE, ZSTARTDATE, ZENDDATE, ZISALLDAY) VALUES (6, 5, 1, 'U-LATER', 'later', \(MacStoreFixtures.t0 + 99999), \(MacStoreFixtures.t0 + 99999), 0)")
        let r = try CalendarImporter.importMacCalendarCache(at: url, label: "mac-2021", into: t.db)
        #expect(r.inserted == 1 && r.alreadyThere == 4)
        #expect(try t.db.scalarInt("SELECT count(*) FROM calendar_event WHERE summary = 'no uid'") == 1)
    }

    /// Two notes in one store with the same text (or the same id) are one note: the second is held.
    @Test func notesV7HoldsTheSecondCopyInsideOneStore() throws {
        let t = try MacStoreFixtures.archive(); defer { t.cleanup() }
        let url = try MacStoreFixtures.notesV7(dir: t.dir)
        let w = try Database(path: url.path)
        try w.exec("""
            INSERT INTO ZNOTEBODY VALUES (5, 5, '<div>Hello <b>world</b> &amp; you</div><div><br></div><div>line&nbsp;2</div>'), (6, 6, '<div>twin id</div>'), (7, 7, '<div>twin id, other text</div>');
            INSERT INTO ZNOTE VALUES (5, 5, 1, \(MacStoreFixtures.t0 + 5000), \(MacStoreFixtures.t0 + 5000), 'Copy', 'V7-5', NULL),
                (6, 6, 1, \(MacStoreFixtures.t0 + 6000), \(MacStoreFixtures.t0 + 6000), 'Six', 'V7-6', NULL),
                (7, 7, 1, \(MacStoreFixtures.t0 + 7000), \(MacStoreFixtures.t0 + 7000), 'Seven', 'V7-6', NULL);
            """)
        let r = try NotesImporter.importNotesV7(at: url, label: "mac-2021", into: t.db)
        #expect(r.notes == 6)
        #expect(r.inserted == 2 && r.alreadyThere == 4)          // V7-2 and V7-6 new; Groceries, Renamed, the text copy and the id twin held
        #expect(try t.db.scalarInt("SELECT count(*) FROM note WHERE uid = 'V7-6'") == 1)
    }

    /// Numeric and named character references become their characters.
    @Test func notesV7DecodesCharacterReferences() {
        #expect(NotesImporter.htmlText("<div>caf&#233; &#x1F600; &mdash; &eacute;t&eacute; &rsquo;s &hellip; &amp;amp; &bogus;</div>") == "café 😀 — été ’s … &amp; &bogus;")
    }

    @Test func notesV7HTMLBecomesText() {
        #expect(NotesImporter.htmlText("<div>a&lt;b</div><div>c<br>d</div>") == "a<b\nc\nd")
        #expect(NotesImporter.htmlText("plain") == "plain")
    }
}
