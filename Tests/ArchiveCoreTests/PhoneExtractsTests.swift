import Testing
import Foundation
import Compression
@testable import ArchiveCore

// Decrypted iPhone-backup extracts (sms.db tree, AddressBook, Calendar, Notes): synthetic data in the real table and column names.

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum ExtractFixtures {
    /// `<dir>/HomeDomain/Library/SMS/sms.db` (modern schema) plus one attachment under MediaDomain, like extracted/sms.
    static func smsTree(extra: Bool = false) throws -> URL {
        let dir = Fixtures.tempDir("smstree")
        let smsDir = dir.appendingPathComponent("HomeDomain/Library/SMS")
        try FileManager.default.createDirectory(at: smsDir, withIntermediateDirectories: true)
        let att = dir.appendingPathComponent("MediaDomain/Library/SMS/Attachments/ab/11/GUID1")
        try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        try Data(Fixtures.blob(7, count: 2000)).write(to: att.appendingPathComponent("IMG_0001.jpg"))
        let db = try Database(path: smsDir.appendingPathComponent("sms.db").path)
        for s in IOSFixtures.modernSchema { try db.exec(s) }
        let t: Int64 = 1_700_000_000
        try db.exec("""
            INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage');
            INSERT INTO chat(guid, style, chat_identifier, service_name) VALUES ('iMessage;-;+12125550111', 45, '+12125550111', 'iMessage');
            INSERT INTO chat_handle_join VALUES (1,1);
            INSERT INTO message(guid, text, handle_id, service, date, is_from_me, cache_has_attachments) VALUES
                ('E-1', 'first from the extract', 1, 'iMessage', \(IOSFixtures.appleNS(t)), 0, 0),
                ('E-2', 'a reply', 1, 'iMessage', \(IOSFixtures.appleNS(t + 60)), 1, 0),
                ('E-3', 'with a picture', 1, 'iMessage', \(IOSFixtures.appleNS(t + 120)), 0, 1)\(extra ? ", ('E-4', 'only in the later copy', 1, 'iMessage', \(IOSFixtures.appleNS(t + 180)), 0, 0)" : "");
            INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3)\(extra ? ",(1,4)" : "");
            INSERT INTO attachment(guid, filename, mime_type, transfer_name, total_bytes) VALUES
                ('A1', '~/Library/SMS/Attachments/ab/11/GUID1/IMG_0001.jpg', 'image/jpeg', 'IMG_0001.jpg', 2000);
            INSERT INTO message_attachment_join VALUES (3,1);
            """)
        return dir
    }

    static func addressBook() throws -> URL {
        let dir = Fixtures.tempDir("ab")
        let lib = dir.appendingPathComponent("HomeDomain/Library/AddressBook")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let ab = try Database(path: lib.appendingPathComponent("AddressBook.sqlitedb").path)
        try ab.exec("""
            CREATE TABLE ABPerson (ROWID INTEGER PRIMARY KEY, First TEXT, Last TEXT, Middle TEXT, Organization TEXT, Nickname TEXT);
            CREATE TABLE ABMultiValue (UID INTEGER PRIMARY KEY, record_id INTEGER, property INTEGER, identifier INTEGER, label INTEGER, value TEXT);
            INSERT INTO ABPerson(ROWID, First, Last, Organization) VALUES (1,'Alice','Example',NULL), (2,NULL,NULL,'Bob Industries'), (3,'Nobody','Known',NULL);
            INSERT INTO ABMultiValue(record_id, property, identifier, label, value) VALUES
                (1, 3, 0, 1, '(212) 555-0111'), (2, 4, 0, 1, 'BOB@example.com'), (3, 3, 0, 1, '212-555-0199'), (1, 5, 2, 1, '123 Fake St');
            """)
        return dir
    }

    static func calendar() throws -> URL {
        let dir = Fixtures.tempDir("cal")
        let lib = dir.appendingPathComponent("HomeDomain/Library/Calendar")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let db = try Database(path: lib.appendingPathComponent("Calendar.sqlitedb").path)
        try db.exec("""
            CREATE TABLE Calendar (ROWID INTEGER PRIMARY KEY, title TEXT);
            CREATE TABLE Location (ROWID INTEGER PRIMARY KEY, title TEXT, address TEXT);
            CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY, summary TEXT, location_id INTEGER, description TEXT, start_date REAL, start_tz TEXT,
                end_date REAL, all_day INTEGER, calendar_id INTEGER, orig_item_id INTEGER, orig_date REAL, hidden INTEGER, has_recurrences INTEGER,
                unique_identifier TEXT, entity_type INTEGER, creation_date REAL, last_modified REAL);
            INSERT INTO Calendar VALUES (1, 'Home'), (2, 'Work');
            INSERT INTO Location VALUES (1, 'Cafe Example', '1 Main St');
            INSERT INTO CalendarItem VALUES
                (1, 'Dinner', 1, 'bring wine', 700000000, 'America/New_York', 700003600, 0, 1, 0, NULL, 0, 0, 'UID-A', 2, 690000000, 690000100),
                (2, 'Birthday', 0, NULL, 700086400, NULL, 700172800, 1, 1, 0, NULL, 0, 1, 'UID-B', 2, NULL, NULL),
                (3, 'Birthday', 0, NULL, 731622400, NULL, 731708800, 1, 1, 2, 700086400, 0, 0, 'UID-B', 2, NULL, NULL),
                (4, 'A task, not an event', 0, NULL, NULL, NULL, NULL, 0, 2, 0, NULL, 0, 0, 'UID-T', 3, NULL, NULL),
                (5, 'Dinner', 1, 'bring wine', 700000000, 'America/New_York', 700003600, 0, 2, 0, NULL, 0, 0, 'UID-A', 2, 690000000, 690000100);
            """)
        return dir
    }

    // MARK: notes

    static func varint(_ n: Int) -> [UInt8] {
        var out: [UInt8] = [], v = n
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
        return out
    }
    static func field(_ number: Int, _ payload: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(payload.count) + payload }

    static func gzip(_ raw: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: raw.count + 256)
        let n = raw.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { d in compression_encode_buffer(d.baseAddress!, d.count, s.baseAddress!, raw.count, nil, COMPRESSION_ZLIB) } }
        let size = UInt32(raw.count)
        let trailer: [UInt8] = [0, 0, 0, 0, UInt8(size & 255), UInt8(size >> 8 & 255), UInt8(size >> 16 & 255), UInt8(size >> 24 & 255)]
        return Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + out[0..<n] + trailer)
    }

    static func noteData(_ text: String) -> Data { gzip(field(2, field(3, field(2, Array(text.utf8))))) }

    static func notes() throws -> URL {
        let dir = Fixtures.tempDir("notes")
        let db = try Database(path: dir.appendingPathComponent("NoteStore.sqlite").path)
        try db.exec("""
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME TEXT);
            INSERT INTO Z_PRIMARYKEY VALUES (12, 'ICNote'), (14, 'ICAccount'), (15, 'ICFolder');
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZTITLE1 TEXT, ZSNIPPET TEXT, ZTITLE2 TEXT, ZNAME TEXT,
                ZFOLDER INTEGER, ZACCOUNT4 INTEGER, ZCREATIONDATE1 REAL, ZMODIFICATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER, ZISPASSWORDPROTECTED INTEGER);
            CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);
            INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK, Z_ENT, ZNAME) VALUES (1, 14, 'iCloud');
            INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK, Z_ENT, ZTITLE2) VALUES (2, 15, 'Notes');
            INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZSNIPPET, ZFOLDER, ZACCOUNT4, ZCREATIONDATE1, ZMODIFICATIONDATE1, ZMARKEDFORDELETION, ZISPASSWORDPROTECTED) VALUES
                (10, 12, 'N-1', 'Groceries', 'milk', 2, 1, 600000000, 600000500, 0, 0),
                (11, 12, 'N-2', 'Secret', NULL, 2, 1, 610000000, 610000500, 0, 1),
                (12, 12, 'N-3', 'Empty one', NULL, 2, 1, 620000000, 620000500, 1, 0);
            """)
        let ins = try db.prepare("INSERT INTO ZICNOTEDATA(ZNOTE, ZDATA) VALUES (?, ?)")
        let body = noteData("Groceries\nmilk\neggs \u{FFFC}")
        ins.bind(1, 10)
        ins.bindBlob(2, body)
        try ins.run()
        return dir
    }
}

@Suite struct PhoneExtractsTests {
    @Test func smsTreeImportsLikeABackupAndLaterCopiesLinkDuplicates() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let tree = try ExtractFixtures.smsTree(); defer { try? FileManager.default.removeItem(at: tree) }
        let r = try IOSBackupImporter.importExtractedTree(sms: tree, into: t.db, root: t.root)
        #expect(r.status == .imported && r.stats.manifestFormat == "tree")
        #expect(r.stats.messagesParsed == 3 && r.stats.inserted == 3 && r.stats.duplicates == 0)
        #expect(r.stats.attachmentsStored == 1 && r.stats.attachmentsMissing == 0)
        #expect(r.stats.contactsNote == "contacts not read from this extract")
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == 1)
        #expect(try IOSBackupImporter.importExtractedTree(sms: tree, into: t.db, root: t.root).status == .alreadyImported)
        let later = try ExtractFixtures.smsTree(extra: true); defer { try? FileManager.default.removeItem(at: later) }
        let r2 = try IOSBackupImporter.importExtractedTree(sms: later, into: t.db, root: t.root)
        #expect(r2.stats.inserted == 1 && r2.stats.duplicates == 3)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE canonical_id IS NULL") == 4)
    }

    @Test func addressBookNamesOnlyExistingHandlesAndCountsTheNewlyNamed() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let tree = try ExtractFixtures.smsTree(); defer { try? FileManager.default.removeItem(at: tree) }
        _ = try IOSBackupImporter.importExtractedTree(sms: tree, into: t.db, root: t.root)
        let ab = try ExtractFixtures.addressBook(); defer { try? FileManager.default.removeItem(at: ab) }
        let handlesBefore = try q(t.db, "SELECT count(*) FROM handle")
        let r = try IOSAddressBookImporter.importAddressBook(at: ab, label: "test-1", into: t.db)
        #expect(r.cards == 3 && r.namedCards == 3 && r.values == 3)              // the address row (property 5) is not a phone or email
        #expect(r.valuesMatched == 1 && r.handlesNamed == 1 && r.handlesNewlyNamed == 1 && r.phoneHandlesNewlyNamed == 1 && r.namesStored == 1)
        #expect(r.handlesWithoutAnyNameBefore == 1 && r.handlesWithoutAnyNameAfter == 0)
        #expect(try q(t.db, "SELECT count(*) FROM handle") == handlesBefore)       // never creates handles
        #expect(try qs(t.db, "SELECT c.name || '/' || c.origin || '/' || c.priority FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = '+12125550111'") == "Alice Example/iphone-addressbook-test-1/20")
        #expect(try IOSAddressBookImporter.importAddressBook(at: ab, label: "test-1", into: t.db).alreadyImported)
    }

    @Test func calendarKeepsEventsRecurringAndEditedOccurrencesAndSkipsTasks() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let cal = try ExtractFixtures.calendar(); defer { try? FileManager.default.removeItem(at: cal) }
        let r = try CalendarImporter.importCalendar(at: cal, label: "test-1", into: t.db)
        #expect(r.items == 4 && r.inserted == 3 && r.alreadyThere == 1)           // the task is not an event; item 5 repeats item 1 in another calendar
        #expect(r.recurring == 1 && r.exceptions == 1 && r.allDay == 2 && r.withLocation == 1 && r.withNotes == 1)
        #expect(r.calendars == 1)
        #expect(try qs(t.db, "SELECT summary || '|' || calendar || '|' || location || '|' || notes || '|' || tz FROM calendar_event WHERE uid = 'UID-A'") == "Dinner|Home|Cafe Example|bring wine|America/New_York")
        #expect(try q(t.db, "SELECT start_ts_ms FROM calendar_event WHERE uid = 'UID-A'") == (700_000_000 + 978_307_200) * 1000)
        #expect(try qs(t.db, "SELECT tz FROM calendar_event WHERE uid = 'UID-B' AND exception = 0") == "floating")
        #expect(try CalendarImporter.importCalendar(at: cal, label: "test-1", into: t.db).alreadyImported)
        #expect(try CalendarImporter.summary(t.db)?.rows == 3)
    }

    @Test func notesDecodeBodiesAndKeepLockedAndEmptyOnesWithoutOne() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let n = try ExtractFixtures.notes(); defer { try? FileManager.default.removeItem(at: n) }
        let r = try NotesImporter.importNotes(at: n, label: "test-1", into: t.db)
        #expect(r.notes == 3 && r.inserted == 3 && r.withBody == 1 && r.locked == 1 && r.deleted == 1 && r.noData == 1 && r.undecodable == 0 && r.folders == 1)
        #expect(try qs(t.db, "SELECT body FROM note WHERE uid = 'N-1'") == "Groceries\nmilk\neggs \u{FFFC}")
        #expect(try qs(t.db, "SELECT title || '|' || folder || '|' || account FROM note WHERE uid = 'N-1'") == "Groceries|Notes|iCloud")
        #expect(try q(t.db, "SELECT count(*) FROM note WHERE body IS NULL") == 2)
        #expect(try q(t.db, "SELECT locked FROM note WHERE uid = 'N-2'") == 1)
        #expect(try q(t.db, "SELECT modified_ms FROM note WHERE uid = 'N-1'") == (600_000_500 + 978_307_200) * 1000)
        #expect(try NotesImporter.importNotes(at: n, label: "test-1", into: t.db).alreadyImported)
    }

    @Test func protobufAndGzipHelpersRejectGarbage() {
        #expect(NotesImporter.decodeBody(Data([1, 2, 3])) == nil)
        #expect(NotesImporter.decodeBody(ExtractFixtures.gzip([0x0A, 0x01, 0x41])) == nil)      // valid gzip, no Document/Note/text fields
        #expect(NotesImporter.decodeBody(ExtractFixtures.noteData("ok")) == "ok")
    }
}

