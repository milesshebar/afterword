import Testing
import Foundation
@testable import ArchiveCore

/// A synthetic macOS Contacts store (only the columns the importer reads), WAL-mode like the real one.
enum ContactsFixtures {
    static func store(in dir: URL, cards: [(first: String?, last: String?, org: String?, phones: [String], emails: [String])]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(path: dir.appendingPathComponent(MacContactsImporter.storeName).path)
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("""
            CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME VARCHAR, ZLASTNAME VARCHAR, ZORGANIZATION VARCHAR, ZNICKNAME VARCHAR, ZNAME VARCHAR);
            CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER VARCHAR);
            CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS VARCHAR);
            INSERT INTO ZABCDRECORD(ZNAME) VALUES ('A Group');
            """)
        let rec = try db.prepare("INSERT INTO ZABCDRECORD(ZFIRSTNAME, ZLASTNAME, ZORGANIZATION) VALUES (?,?,?)")
        let ph = try db.prepare("INSERT INTO ZABCDPHONENUMBER(ZOWNER, ZFULLNUMBER) VALUES (?,?)")
        let em = try db.prepare("INSERT INTO ZABCDEMAILADDRESS(ZOWNER, ZADDRESS) VALUES (?,?)")
        for c in cards {
            rec.bind(1, c.first).bind(2, c.last).bind(3, c.org); try rec.run()
            let id = db.lastInsertRowID
            for p in c.phones { ph.bind(1, id).bind(2, p); try ph.run() }
            for e in c.emails { em.bind(1, id).bind(2, e); try em.run() }
        }
        // leave the rows in the WAL (no checkpoint), as a live Contacts store often has them
        try db.exec("PRAGMA wal_autocheckpoint = 0")
    }
}

@Suite struct MacContactsTests {
    @Test func namesExistingHandlesOnlyAndRefreshReplaces() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_500_000_000_000, type: 1, body: "hi", name: "Ali"),
            Fixtures.sms(address: Fixtures.carol, date: 1_500_000_060_000, type: 1, body: "yo"),
        ]), name: "sms-1.xml")
        let w = try ArchiveWriter(db: t.db, sourceID: 1, sourceKind: "android-xml")
        _ = try w.handleID(raw: "Dana@Example.com")
        let handlesBefore = try t.db.scalarInt("SELECT count(*) FROM handle")

        let sources = t.dir.appendingPathComponent("Sources")
        try ContactsFixtures.store(in: sources.appendingPathComponent("S1"), cards: [
            ("Alice", "Example", nil, ["+1 (212) 555-0111"], []),
            ("Carol", nil, nil, ["2125550133"], ["carol@example.com"]),
            (nil, nil, "Dana Studio", [], ["dana@example.com"]),
            ("Eve", "Stranger", nil, ["+12125550199"], ["eve@example.com"]),          // not in the archive
        ])
        try ContactsFixtures.store(in: sources.appendingPathComponent("S2"), cards: [
            ("Carol", "Example", nil, ["+12125550133"], []),                            // same number, another card's name
        ])
        let dry = try MacContactsImporter.importContacts(from: sources, into: t.db, label: "macos-contacts-2024-01-01", dryRun: true)
        #expect(dry.handlesNamed == 3 && dry.namesStored == 4)
        #expect(try t.db.scalarInt("SELECT count(*) FROM contact_name WHERE origin LIKE 'macos-contacts%'") == 0)

        let r = try MacContactsImporter.importContacts(from: sources, into: t.db, label: "macos-contacts-2024-01-01")
        #expect(r.stores == 2 && r.namedCards == 5)
        #expect(r.handlesNamed == 3)                 // alice, carol, dana; eve has no handle
        #expect(r.handlesNewlyNamed == 2)            // alice already had "Ali" from the XML
        #expect(r.handlesWithSeveralNames == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM handle") == handlesBefore)      // never creates handles
        #expect(try t.db.scalarString("SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'dana@example.com'") == "Dana Studio")
        #expect(try t.db.scalarString("SELECT name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = '+12125550111' ORDER BY priority DESC LIMIT 1") == "Alice Example")
        #expect(try t.db.scalarInt("SELECT priority FROM contact_name WHERE origin = 'macos-contacts-2024-01-01' LIMIT 1") == 25)
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'macos-contacts'") == 1)

        // a later refresh replaces the earlier label's rows and source
        try FileManager.default.removeItem(at: sources.appendingPathComponent("S2"))
        let again = try MacContactsImporter.importContacts(from: sources, into: t.db, label: "macos-contacts-2027-01-01")
        #expect(again.previousNamesRemoved == 4)
        #expect(try t.db.scalarInt("SELECT count(*) FROM contact_name WHERE origin = 'macos-contacts-2024-01-01'") == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM contact_name WHERE origin = 'macos-contacts-2027-01-01'") == 3)
        #expect(try t.db.scalarString("SELECT path FROM source WHERE kind = 'macos-contacts'") == "macos-contacts-2027-01-01")
    }

    @Test func refusesAFolderWithoutStores() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        #expect(throws: ArchiveError.self) { try MacContactsImporter.importContacts(from: t.dir, into: t.db) }
        #expect(throws: ArchiveError.self) { try MacContactsImporter.importContacts(from: t.dir, into: t.db, label: "other") }
    }
}
