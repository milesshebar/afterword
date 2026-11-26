import Testing
import Foundation
@testable import ArchiveCore

// A synthetic Skype 5 main.db: invented people and text, the real table and column names (Accounts, Contacts, Chats, Messages).

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum SkypeFixtures {
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    /// Account `testme`; Erin (1:1, display name on her messages), a group of Erin, Sam and me ("Test Crew" topic), a chat where only I
    /// wrote (partner on record), a chat of two other people, and events of every skipped kind.
    static func mainDB(extra: [(Int, Int, String, String, String, String, String, String?)] = []) -> URL {
        let dir = Fixtures.tempDir("skype")
        let url = dir.appendingPathComponent("main.db")
        let db = try! Database(path: url.path)
        try! db.exec("""
            CREATE TABLE Accounts (id INTEGER PRIMARY KEY, skypename TEXT);
            CREATE TABLE Contacts (id INTEGER PRIMARY KEY, skypename TEXT, fullname TEXT, displayname TEXT);
            CREATE TABLE Chats (id INTEGER PRIMARY KEY, name TEXT, friendlyname TEXT, topic TEXT, participants TEXT);
            CREATE TABLE Messages (id INTEGER PRIMARY KEY, timestamp INTEGER, type INTEGER, chatname TEXT, author TEXT, from_dispname TEXT,
                                   dialog_partner TEXT, body_xml TEXT);
            INSERT INTO Accounts VALUES (1, 'testme');
            INSERT INTO Contacts VALUES (1, 'erin.ex', 'Erin Example', 'erin'), (2, 'quiet.pal', 'Quiet Pal', 'quiet');
            INSERT INTO Chats VALUES (1, '#testme/$erin.ex;aa', 'erin', '', 'erin.ex'),
                                     (2, '#sam.sample/$0123456789abcdef', 'Group', 'Test Crew', 'testme erin.ex sam.sample');
            """)
        let one = "#testme/$erin.ex;aa", grp = "#sam.sample/$0123456789abcdef", mine = "#testme/$quiet.pal;bb", others = "#erin.ex/$sam.sample;cc"
        var rows: [(Int, Int, String, String, String, String, String, String?)] = [
            (1, 61, one, "erin.ex", "Erin E", "erin.ex", "hello &amp; welcome <ss type=\"smile\">:)</ss>", nil),
            (2, 61, one, "testme", "Test Me", "erin.ex", "see <a href=\"http://example.invalid/x\">http://example.invalid/x</a>", nil),
            (3, 60, one, "erin.ex", "Erin E", "erin.ex", "waves", nil),
            (4, 68, one, "erin.ex", "Erin E", "erin.ex", "sent file &quot;pic one.png&quot;<files alt=\"\"><file size=\"2048\" index=\"0\">pic one.png</file></files>", nil),
            (5, 50, one, "erin.ex", "Erin E", "erin.ex", "Please add me", nil),
            (6, 61, grp, "sam.sample", "Sam S", "", "group says hi", nil),
            (7, 61, grp, "testme", "Test Me", "", "me too", nil),
            (8, 61, grp, "erin.ex", "Erin E", "", "&lt;3", nil),
            (9, 61, mine, "testme", "Test Me", "quiet.pal", "anyone there?", nil),
            (10, 61, others, "erin.ex", "Erin E", "", "between two others", nil),
            (11, 61, one, "erin.ex", "Erin E", "erin.ex", "", nil),                      // empty body: counted, not stored
            (12, 30, one, "erin.ex", "Erin E", "erin.ex", "<partlist/>", nil),            // call start
            (13, 39, one, "testme", "Test Me", "erin.ex", "<partlist/>", nil),            // call end
            (14, 10, grp, "sam.sample", "Sam S", "", "", nil),                            // member added
            (15, 100, grp, "testme", "Test Me", "", "", nil),                             // participant list
            (16, 51, one, "testme", "Test Me", "erin.ex", "", nil),                       // contact accepted
        ]
        rows += extra
        let ins = try! db.prepare("INSERT INTO Messages(id, timestamp, type, chatname, author, from_dispname, dialog_partner, body_xml) VALUES (?,?,?,?,?,?,?,?)")
        for r in rows {
            ins.bind(1, r.0).bind(2, 1_313_791_000 + r.0 * 60).bind(3, r.1).bind(4, r.2).bind(5, r.3).bind(6, r.4).bind(7, r.5).bind(8, r.6)
            try! ins.run()
        }
        return url
    }
}

@Suite struct SkypeImportTests {
    @Test func detectsASkypeDatabaseOnly() throws {
        let u = SkypeFixtures.mainDB(); defer { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        #expect(SkypeImporter.isSkypeDB(u))
        let other = Fixtures.tempDir("notskype"); defer { try? FileManager.default.removeItem(at: other) }
        let f = other.appendingPathComponent("x.db")
        let d = try Database(path: f.path); try d.exec("CREATE TABLE t(a)")
        #expect(SkypeImporter.isSkypeDB(f) == false)
    }

    @Test func importsThreadsPeopleAndTextWithACountThatAddsUp() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let u = SkypeFixtures.mainDB(); defer { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        let r = try SkypeImporter.importDB(at: u, into: t.db, root: t.root)
        #expect(r.status == .imported && r.account == "testme")
        let s = r.stats
        // every row of Messages is accounted for: messages by kind plus events by type
        #expect(s.parsed == 16)
        #expect(s.textMessages == 8 && s.emotes == 1 && s.contactRequests == 1 && s.fileTransfers == 1)
        #expect(s.eventsSkipped == 5 && s.eventsByType == ["30": 1, "39": 1, "10": 1, "100": 1, "51": 1])
        #expect(s.parsed == s.textMessages + s.emotes + s.contactRequests + s.fileTransfers + s.eventsSkipped)
        #expect(s.emptySkipped == 1 && s.noChatSkipped == 0)
        #expect(s.inserted == 10 && s.duplicates == 0)
        #expect(s.inserted + s.emptySkipped + s.noChatSkipped + s.duplicates == s.textMessages + s.emotes + s.contactRequests + s.fileTransfers)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE service = 'skype' AND canonical_id IS NULL") == 10)
        #expect(try qs(t.db, "SELECT DISTINCT service FROM message") == "skype")

        // threads: Erin 1:1 (also holds the contact request and the file line), the group, the partner chat, the two-others group
        #expect(s.chats == 4 && s.groups == 2 && s.dms == 2)
        #expect(try q(t.db, "SELECT count(*) FROM thread WHERE service = 'skype'") == 4)
        #expect(try qs(t.db, "SELECT title FROM thread WHERE service = 'skype' AND origin = 'group' AND title IS NOT NULL") == "Test Crew")
        #expect(try q(t.db, "SELECT count(*) FROM thread_member tm JOIN thread t ON t.id = tm.thread_id WHERE t.title = 'Test Crew'") == 2)   // Erin, Sam (not me)
        // handles, names, direction
        #expect(try qs(t.db, "SELECT kind FROM handle WHERE normalized = 'sk:erin.ex'") == "skype-user")
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'sk:testme'") == 0)
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'sk:erin.ex'") == "Erin E")
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'sk:quiet.pal'") == "Quiet Pal")
        #expect(try q(t.db, "SELECT is_from_me FROM message WHERE body = 'me too'") == 1)
        #expect(try qs(t.db, "SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'group says hi'") == "sk:sam.sample")
        // body text: entities decoded, smiley text kept, link address kept, emote prefixed, file named, empty not stored
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'hello%'") == "hello & welcome :)")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'see %'") == "see http://example.invalid/x")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body = '<3'") == "<3")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE '/me %'") == "/me waves")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE '(file sent:%'") == "(file sent: pic one.png; the file is not in the Skype database)")
        // times are the file's Unix seconds
        #expect(try q(t.db, "SELECT ts_ms FROM message WHERE body LIKE 'hello%'") == (1_313_791_000 + 60) * 1000)
        #expect(s.firstTsMs == (1_313_791_000 + 60) * 1000 && s.lastTsMs == (1_313_791_000 + 10 * 60) * 1000)
        // search finds it (FTS is kept in step by the writer)
        #expect(try q(t.db, "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'between'") == 1)
    }

    @Test func rerunIsSkippedAndAnOverlappingCopyAddsOnlyNewRows() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let u = SkypeFixtures.mainDB(); defer { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        _ = try SkypeImporter.importDB(at: u, into: t.db, root: t.root)
        let again = try SkypeImporter.importDB(at: u, into: t.db, root: t.root)
        #expect(again.status == .alreadyImported && again.stats.inserted == 10)
        #expect(try q(t.db, "SELECT count(*) FROM message") == 10 && (try q(t.db, "SELECT count(*) FROM source WHERE kind = 'skype-main-db'")) == 1)
        // a later copy of the same database with one more message: the 10 are linked as duplicates, 1 new canonical row
        let u2 = SkypeFixtures.mainDB(extra: [(20, 61, "#testme/$erin.ex;aa", "erin.ex", "Erin E", "erin.ex", "a later one", nil)])
        defer { try? FileManager.default.removeItem(at: u2.deletingLastPathComponent()) }
        let r2 = try SkypeImporter.importDB(at: u2, into: t.db, root: t.root)
        #expect(r2.status == .imported && r2.stats.inserted == 1 && r2.stats.duplicates == 10)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE canonical_id IS NULL") == 11)
    }

    @Test func plainTextHandlesTagsAndEntities() {
        let a = SkypeImporter.strip("a &amp; b <ss type=\"cool\">8-)</ss> <a href=\"http://example.invalid/?a=1&amp;b=2\"></a>")
        #expect(a.0 == "a & b 8-) http://example.invalid/?a=1&b=2" && a.1 == 1 && a.2 == 1)
        #expect(SkypeImporter.strip("plain").0 == "plain")
    }
}
