import Testing
import Foundation
@testable import ArchiveCore

// A synthetic 2011 Facebook "Download Your Information" export: the real markup (div.thread > div.message[.reply] >
// span.profile / span.page, span.time, div.msgbody with div.subject), invented names and text.

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum DYIFixtures {
    static let messages = """
    <!DOCTYPE html><html><head><title>Me Person -  Messages </title></head><body><div id="content" class="tabmessages">
    <div class="thread" style="margin-bottom:25px;">
    <div class="message">
    <span class="profile">Pat Oldname</span>
    <span class="time">May 10, 2011 at 9:42 pm</span>
    <div class="msgbody"><div class="subject">Plans</div>an opening line that the later export lost<BR><BR>second line &amp; more</div>
    </div>
    <div class="message reply">
    <span class="profile">Me Person</span>
    <span class="time">May 10, 2011 at 9:45 pm</span>
    <div class="msgbody">a reply that the later export kept</div>
    </div>
    <div class="message reply">
    <span class="profile">Pat Oldname</span>
    <span class="time">May 10, 2011 at 9:47 pm</span>
    <div class="msgbody">and a second long line it kept too</div>
    </div>
    </div>
    <div class="thread"><div class="message"><span class="profile">Kim Lo</span>
    <span class="time">January 2, 2010 at 8:00 am</span><div class="msgbody">happy new year from kim</div></div></div>
    <div class="thread"><div class="message"><span class="page">Club Page</span>
    <span class="time">March 3, 2011 at 4:00 pm</span><div class="msgbody"><div class="subject">Meeting</div>club meeting on friday</div></div></div>
    <div class="thread"><div class="message"><span class="profile">Jo Ra</span>
    <span class="time">March 4, 2011 at 4:00 pm</span><div class="msgbody"></div></div></div>
    <div class="thread"><div class="message"><span class="profile">Me Person</span> to <span class="profile">Lee Vu</span>
    <span class="time">April 1, 2011 at 1:00 pm</span><div class="msgbody">hi lee, first message</div></div></div>
    </div></body></html>
    """

    static func export(_ html: String = messages) -> URL {
        let dir = Fixtures.tempDir("dyi2011")
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("html"), withIntermediateDirectories: true)
        try! Data(html.utf8).write(to: dir.appendingPathComponent("html/messages.html"))
        try! Data("Downloaded by Me Person (http://www.facebook.com/profile.php?id=1) on May 16, 2011 at 10:02 pm".utf8).write(to: dir.appendingPathComponent("README.txt"))
        return dir
    }

    /// What a Meta export import already holds: Pat (under the name the account has now, sharing only a first name, so
    /// the thread is found by corroboration: two distinct archive messages) with two of the messages, at second precision
    /// (+20 s and +15 s into the printed minute), and an unrelated Kim 1:1 thread from another day.
    static func seed(_ db: Database) throws {
        try db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('messenger-thread', 'seed', 'seed', 0, 0)")
        let w = try ArchiveWriter(db: db, sourceID: db.lastInsertRowID, sourceKind: "messenger-thread")
        func add(_ who: String, _ ts: Int64, me: Bool, _ body: String) throws {
            var r = MessageRecord(participants: [], sender: nil, tsMs: ts, isFromMe: me, service: "messenger", body: body, subject: nil, sourceKey: nil, attachments: [])
            r.participantHandles = [.facebook(name: who)]
            if !me { r.senderHandle = .facebook(name: who) }
            try w.add(r)
        }
        // 2011-05-10 21:45 at UTC-04:00 = 2011-05-11 01:45 UTC
        try add("Pat Newname", 1_305_078_300_000 + 20_000, me: true, "A reply that the later export kept!")
        try add("Pat Newname", 1_305_078_420_000 + 15_000, me: false, "And a second long line it kept too")
        try add("Kim Lo", 1_262_000_000_000, me: false, "an older kim message")
    }
}

@Suite struct FacebookDYI2011Tests {
    @Test func parsesThreadsMessagesPagesAndSubjects() throws {
        let dir = DYIFixtures.export(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FacebookDYI2011Importer.detect(dir) == dir)
        #expect(FacebookDYI2011Importer.detect(dir.appendingPathComponent("html/messages.html")) == dir)
        let (title, m) = FacebookDYI2011Importer.parse(try Data(contentsOf: dir.appendingPathComponent("html/messages.html")))
        #expect(title == "Me Person -  Messages")
        #expect(m.count == 7)
        #expect(m[0].author == "Pat Oldname" && m[0].subject == "Plans" && m[0].body == "an opening line that the later export lost\nsecond line & more")
        #expect(m[1].isReply && m[1].author == "Me Person")
        #expect(m[4].author == "Club Page")           // a Page's broadcast
        #expect(m[6].recipients == ["Lee Vu"])        // "A to B"
        #expect(m[5].body.isEmpty)
    }

    @Test func fixedUTCMinus4AllYear() {
        // summer and winter both +4 h: the export used one offset for the whole file (America/New_York would give +5 h in January)
        #expect(FacebookDYI2011Importer.unixMs("May 10, 2011 at 9:42 pm", zone: .utcMinus4) == 1_305_078_120_000)    // 2011-05-11 01:42 UTC
        #expect(FacebookDYI2011Importer.unixMs("January 2, 2010 at 8:00 am", zone: .utcMinus4) == 1_262_433_600_000) // 2010-01-02 12:00 UTC
    }

    @Test func importsOnlyWhatTheArchiveLacksIntoTheRightThreads() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixtures.seed(t.db)
        let dir = DYIFixtures.export(); defer { try? FileManager.default.removeItem(at: dir) }
        let before = try q(t.db, "SELECT count(*) FROM message")
        let dry = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4, dryRun: true)
        #expect(dry.status == .dryRun && dry.stats.held == 2 && dry.stats.emptySkipped == 1)
        #expect(try q(t.db, "SELECT count(*) FROM message") == before)

        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        let s = r.stats
        #expect(r.me == "Me Person")
        #expect(s.parsed == 7 && s.held == 2 && s.emptySkipped == 1 && s.inserted == 4 && s.duplicates == 0)
        #expect(r.leftOut.map { $0.1 } == ["no text"])
        // Pat's opener joins the thread the archive has for Pat under the new name, sent by that handle, at the printed minute
        let patThread = try q(t.db, "SELECT m.thread_id FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE h.normalized = 'fb:pat newname' OR m.is_from_me = 1 LIMIT 1")
        let opener = "SELECT %@ FROM message m JOIN source s ON s.id = m.source_id WHERE s.kind = 'fb-dyi-2011' AND m.subject = 'Plans'"
        #expect(try q(t.db, String(format: opener, "m.thread_id")) == patThread)
        #expect(try qs(t.db, String(format: opener, "(SELECT normalized FROM handle WHERE id = m.sender_handle_id)")) == "fb:pat newname")
        #expect(try q(t.db, String(format: opener, "m.ts_ms")) == 1_305_078_120_000)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'fb:pat oldname'") == 0)
        // Kim's one-message conversation lands in Kim's existing 1:1 thread (the Meta keying); the Page and Lee get new threads
        #expect(try q(t.db, "SELECT count(DISTINCT m.thread_id) FROM message m JOIN thread_member tm ON tm.thread_id = m.thread_id JOIN handle h ON h.id = tm.handle_id WHERE h.normalized = 'fb:kim lo'") == 1)
        #expect(s.intoExistingThreads == 2 && s.intoNewThreads == 2 && s.newThreads == 2 && s.newHandles == 2)
        #expect(dry.stats.intoExistingThreads == 2 && dry.stats.intoNewThreads == 2)   // the dry run now predicts the write: Kim lands in her keyed thread
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'fb:club page'") == "Club Page")
        #expect(try q(t.db, "SELECT count(*) FROM thread WHERE service = 'messenger' AND origin = 'inbox'") == 2)   // only the threads it created
        #expect(try q(t.db, "SELECT count(*) FROM message m JOIN source s ON s.id = m.source_id WHERE s.kind = 'fb-dyi-2011' AND m.canonical_id IS NULL") == 4)
        #expect(try qs(t.db, "SELECT value FROM meta WHERE key = 'fb-dyi-2011.time_rule'")?.contains("UTC-04:00") == true)

        // idempotent: the same file is skipped; a changed copy of it finds everything held and adds nothing
        #expect(try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4).status == .alreadyImported)
        let dir2 = DYIFixtures.export(DYIFixtures.messages + "\n<!-- a later copy -->"); defer { try? FileManager.default.removeItem(at: dir2) }
        let again = try FacebookDYI2011Importer.importExport(at: dir2, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(again.stats.inserted == 0 && again.stats.held == 6)
    }
}

@Suite struct FacebookDYI2011ZoneTests {
    @Test func zoneOptionTakesNamesAndFixedOffsets() {
        #expect(FacebookDYI2011Importer.zone(named: "UTC-04:00")?.secondsFromGMT() == -14_400)
        #expect(FacebookDYI2011Importer.zone(named: "UTC+5:30")?.secondsFromGMT() == 19_800)
        #expect(FacebookDYI2011Importer.zone(named: "UTC")?.secondsFromGMT() == 0)
        #expect(FacebookDYI2011Importer.zone(named: "America/Chicago")?.identifier == "America/Chicago")
        #expect(FacebookDYI2011Importer.zone(named: "UTC4") == nil && FacebookDYI2011Importer.zone(named: "No/Such_Zone") == nil)
        #expect(FacebookDYI2011Importer.describe(.utcMinus4) == "fixed UTC-04:00")
        #expect(FacebookDYI2011Importer.describe(TimeZone(identifier: "America/Chicago")!) == "America/Chicago with DST")
    }

    @Test func theZoneDecidesTheTime() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        #expect(FacebookDYI2011Importer.unixMs("May 10, 2011 at 9:42 pm", zone: chicago) == 1_305_081_720_000)   // CDT is UTC-05:00
    }
}
