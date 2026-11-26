import Testing
import Foundation
@testable import ArchiveCore

// Regression tests for the 2011 export importer's edge cases. Synthetic names and text only.

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }

enum DYIFixture {
    /// T = "May 10, 2011 at 9:42 pm" at UTC-04:00 = 2011-05-11 01:42:00 UTC
    static let T: Int64 = 1_305_078_120_000
    static let me = "Me Person"

    struct M { var author: String; var to: String? = nil; var time: String; var body: String; var page = false }

    /// messages.html with one div.thread per conversation
    static func html(_ threads: [[M]]) -> String {
        var s = "<html><head><title>\(me) -  Messages </title></head><body><div id=\"content\" class=\"tabmessages\">\n"
        for t in threads {
            s += "<div class=\"thread\">\n"
            for (i, m) in t.enumerated() {
                let cls = i == 0 ? "message" : "message reply"
                let who = "<span class=\"\(m.page ? "page" : "profile")\">\(m.author)</span>" + (m.to.map { " to <span class=\"profile\">\($0)</span>" } ?? "")
                s += "<div class=\"\(cls)\">\(who)<span class=\"time\">\(m.time)</span><div class=\"msgbody\">\(m.body)</div></div>\n"
            }
            s += "</div>\n"
        }
        return s + "</div></body></html>\n"
    }

    static func export(_ threads: [[M]]) -> URL { DYIFixtures.export(html(threads)) }

    /// A source plus writer for seeding what a Meta import holds (each call is a separate source).
    static func seeder(_ db: Database, _ tag: String) throws -> ArchiveWriter {
        try db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('messenger-thread', '\(tag)', '\(tag)', 0, 0)")
        return try ArchiveWriter(db: db, sourceID: db.lastInsertRowID, sourceKind: "messenger-thread")
    }

    static func add(_ w: ArchiveWriter, with who: String, at ts: Int64, fromMe: Bool, _ body: String) throws {
        var r = MessageRecord(participants: [], sender: nil, tsMs: ts, isFromMe: fromMe, service: "messenger", body: body, subject: nil, sourceKey: nil, attachments: [])
        r.participantHandles = [.facebook(name: who)]
        if !fromMe { r.senderHandle = .facebook(name: who) }
        try w.add(r)
    }

    static func threadOf(_ db: Database, _ name: String) throws -> Int64 {
        try q(db, "SELECT t.id FROM thread t JOIN thread_member tm ON tm.thread_id = t.id JOIN handle h ON h.id = tm.handle_id WHERE h.normalized = 'fb:\(ServiceHandle.foldName(name))' AND NOT t.is_group LIMIT 1")
    }
}

@Suite struct FacebookDYI2011EdgeCaseTests {
    typealias M = DYIFixture.M

    // 1. An unrelated short match must neither hide Bob's message nor pull Bob's conversation into Alice's thread.
    @Test func unrelatedMatchDoesNotHideOrRedirect() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Alice Ash", at: DYIFixture.T + 20_000, fromMe: false, "OK")
        let dir = DYIFixture.export([[M(author: "Bob Birch", time: "May 10, 2011 at 9:32 pm", body: "a unique opener from bob"),
                                     M(author: "Bob Birch", time: "May 10, 2011 at 9:42 pm", body: "OK")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        // A lone short match from someone else is weak evidence: Bob's conversation is left out and listed,
        // neither held against Alice nor placed in her thread
        #expect(r.stats.held == 0 && r.stats.inserted == 0 && r.stats.weakEvidence == 2)
        let alice = try DYIFixture.threadOf(t.db, "Alice Ash")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE thread_id = \(alice)") == 1)
    }

    // 2. One archived row satisfies one export message: a genuinely repeated send is not lost.
    @Test func oneArchiveRowMatchesOnce() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: true, "hello")
        // An opener printed at a reply's minute has no time of its own, so the repeat is tested on two replies
        let dir = DYIFixture.export([[M(author: DYIFixture.me, to: "Pat Pine", time: "May 10, 2011 at 9:30 pm", body: "an opener with its own time"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "hello"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "hello")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 1 && r.stats.inserted == 2)   // the opener and the second "hello"
    }

    // 3. Long messages that share a beginning but end differently are different messages.
    @Test func sharedPrefixIsNotTheSameMessage() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: false, "abcdefghijklmnopqrstuvwxyzabcd YES")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "abcdefghijklmnopqrstuvwxyzabcd NO")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.inserted == 1 && r.stats.heldTextDiffers == 0)
    }

    // 3b. The real-data shape of "text differs": one text is the other plus a trailing link or character.
    @Test func appendedTailStillHeld() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: false, "a reasonably long message about plans http://example.invalid/x")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "a reasonably long message about plans")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.heldTextDiffers == 1 && r.stats.inserted == 0)
    }

    // 4. Emoji-only and punctuation-only messages are text, not empty.
    @Test func emojiAndPunctuationAreKept() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "👍")],
                                    [M(author: "Kim Lo", time: "May 10, 2011 at 9:43 pm", body: "!!!")],
                                    [M(author: "Jo Ra", time: "May 10, 2011 at 9:44 pm", body: "")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.inserted == 2 && r.stats.emptySkipped == 1)
    }

    // 5. A deactivated account ("Facebook user") is per conversation, as in the Meta importer.
    @Test func facebookUserIsPerConversation() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = DYIFixture.export([[M(author: "Facebook User", time: "May 10, 2011 at 9:42 pm", body: "first ghost")],
                                    [M(author: "Facebook User", time: "May 11, 2011 at 9:42 pm", body: "second ghost")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.inserted == 2)
        #expect(try q(t.db, "SELECT count(DISTINCT thread_id) FROM message") == 2)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized LIKE 'fb:facebook user#%'") == 2)
    }

    // 6. Text inside a nested div of the message body is part of the body.
    @Test func nestedDivTextIsKept() throws {
        let (_, m) = FacebookDYI2011Importer.parse(Data(DYIFixture.html([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "before<div>important words</div>after")],
                                                                     [M(author: "Kim Lo", time: "May 10, 2011 at 9:43 pm", body: "<div>only nested</div>")]]).utf8))
        #expect(m[0].body == "before\nimportant words\nafter")
        #expect(m[1].body == "only nested")
    }

    // 7. A message held only through a non-canonical duplicate row is still held.
    @Test func duplicateRowsCount() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed1"), with: "Pat Pine", at: DYIFixture.T + 91_000, fromMe: false, "the same words here")
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed2"), with: "Pat Pine", at: DYIFixture.T + 89_000, fromMe: false, "the same words here")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE canonical_id IS NOT NULL") == 1)
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "the same words here")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 1 && r.stats.inserted == 0)
    }

    // 8. A failed people rematch is reported, and a rerun of the same export rebuilds the people index.
    @Test func rematchFailureIsLoudAndRerunRepairs() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        _ = try PeopleStore.rematch(db: t.db)
        try t.db.exec("CREATE TRIGGER boom BEFORE INSERT ON person BEGIN SELECT RAISE(ABORT, 'boom'); END")
        let dir = DYIFixture.export([[M(author: "Nova Newhandle", time: "May 10, 2011 at 9:42 pm", body: "brand new person")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try FacebookDYI2011Importer.importAndRematch(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4) }
        #expect(try q(t.db, "SELECT count(*) FROM message") == 1)           // the import itself committed
        try t.db.exec("DROP TRIGGER boom")
        let again = try FacebookDYI2011Importer.importAndRematch(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(again.import.status == .alreadyImported)
        #expect(try q(t.db, "SELECT count(*) FROM person_handle ph JOIN handle h ON h.id = ph.handle_id WHERE h.normalized = 'fb:nova newhandle'") == 1)
    }

    // A shared first name with one match, or one short match with a deactivated account, is weak
    // evidence: such conversations are left out and listed, not placed and not written as new.
    @Test func weakRenamedEvidenceIsLeftOut() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Toby Fakewits", at: DYIFixture.T + 20_000, fromMe: true, "School")
        var ghost = MessageRecord(participants: [], sender: nil, tsMs: DYIFixture.T + 86_400_000 + 30_000, isFromMe: false, service: "messenger",
                                  body: "Lol", subject: nil, sourceKey: nil, attachments: [])
        ghost.participantHandles = [.facebook(name: "Facebook user", unique: "4242")]
        ghost.senderHandle = .facebook(name: "Facebook user", unique: "4242")
        try w.add(ghost)
        let dir = DYIFixture.export([[M(author: "Toby Middle Fakewitz", time: "May 10, 2011 at 9:30 pm", body: "an opener the later export lost"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "School")],
                                    [M(author: "Unknown", time: "May 11, 2011 at 9:42 pm", body: "Lol")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 0 && r.stats.inserted == 0 && r.stats.weakEvidence == 3)
        let tim = try DYIFixture.threadOf(t.db, "Toby Fakewits")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE thread_id = \(tim)") == 1)    // untouched
    }
}

// Matching edge cases. Synthetic names and text only.
@Suite struct FacebookDYI2011MatchingTests {
    typealias M = DYIFixture.M
    private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }

    static func group(_ w: ArchiveWriter, _ members: [String], suffix: String, at ts: Int64, from: String?, _ body: String) throws {
        var r = MessageRecord(participants: [], sender: nil, tsMs: ts, isFromMe: from == nil, service: "messenger", body: body, subject: nil, sourceKey: nil, attachments: [])
        r.participantHandles = members.map { .facebook(name: $0) }
        if let f = from { r.senderHandle = .facebook(name: f) }
        w.groupKeySuffix = suffix
        try w.add(r)
        w.groupKeySuffix = nil
    }

    // R2-1. A long text from a different sender is not evidence: Alice's thread is never Bob's, and Bob's text is not held.
    @Test func r2_1_longTextFromAnotherSenderIsNotEvidence() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed"), with: "Alice Ash", at: DYIFixture.T + 20_000, fromMe: false, "see you tomorrow")
        let dir = DYIFixture.export([[M(author: "Bob Birch", time: "May 10, 2011 at 9:32 pm", body: "a unique opener from bob"),
                                     M(author: "Bob Birch", time: "May 10, 2011 at 9:42 pm", body: "see you tomorrow")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 0 && r.stats.heldTextDiffers == 0)
        let alice = try DYIFixture.threadOf(t.db, "Alice Ash")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE thread_id = \(alice)") == 1)
        #expect(r.stats.inserted + r.stats.weakEvidence == 2)
    }

    // R2-2. Inside a group, an incoming message is held only against a row from the same sender.
    @Test func r2_2_groupHeldNeedsTheSameSender() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try Self.group(w, ["Alice Ash", "Bob Birch"], suffix: "g1", at: DYIFixture.T + 20_000, from: "Alice Ash", "OK")
        try Self.group(w, ["Alice Ash", "Bob Birch"], suffix: "g1", at: DYIFixture.T + 30_000, from: nil, "a unique outgoing reply in the group")
        let dir = DYIFixture.export([[M(author: "Bob Birch", to: "Alice Ash", time: "May 10, 2011 at 9:30 pm", body: "a group opener with its own time"),
                                     M(author: "Bob Birch", time: "May 10, 2011 at 9:42 pm", body: "OK"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "a unique outgoing reply in the group")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 1 && r.stats.inserted == 2)   // Bob's "OK" is not held against Alice's; the opener is new
    }

    // R2-3. One archive row is claimed once across the whole export, not once per export conversation.
    @Test func r2_3_claimsSpanConversations() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed"), with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: true, "hello")
        let dir = DYIFixture.export([[M(author: DYIFixture.me, to: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "hello")],
                                    [M(author: DYIFixture.me, to: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "hello")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 1 && r.stats.inserted == 1)
    }

    // R2-4. A genuine repeat the importer decided is new stays a visible message (the writer must not link it back).
    @Test func r2_4_newRowIsNeverLinkedToAClaimedRow() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed"), with: "Pat Pine", at: DYIFixture.T + 1_000, fromMe: true, "hello")
        let dir = DYIFixture.export([[M(author: DYIFixture.me, to: "Pat Pine", time: "May 10, 2011 at 9:30 pm", body: "an opener with its own time"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "hello"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "hello")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 1 && r.stats.inserted == 2 && r.stats.duplicates == 0)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE canonical_id IS NULL AND body = 'hello'") == 2)
    }

    // R2-5. Allocation is by distance, not by order: the exact-minute match keeps its row.
    @Test func r2_5_closestMatchWinsNotTheEarliest() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed"), with: "Pat Pine", at: DYIFixture.T + 60_000, fromMe: true, "hello")
        let dir = DYIFixture.export([[M(author: DYIFixture.me, to: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "hello"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:43 pm", body: "hello")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 1 && r.stats.inserted == 1)
        #expect(try q(t.db, "SELECT m.ts_ms FROM message m JOIN source s ON s.id = m.source_id WHERE s.kind = 'fb-dyi-2011'") == DYIFixture.T)
    }

    // R2-6. A header-looking span inside the body is body text and never the message's time or sender.
    @Test func r2_6_spansInsideTheBodyAreText() throws {
        let (_, m) = FacebookDYI2011Importer.parse(Data(DYIFixture.html([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm",
            body: "before<span class=\"time\">not a date</span>and<span class=\"profile\">Not Me</span>after")]]).utf8))
        #expect(m[0].timeText == "May 10, 2011 at 9:42 pm")
        #expect(m[0].profiles == ["Pat Pine"])
        #expect(m[0].body == "beforenot a dateandNot Meafter")
    }

    // R2-7. A deactivated account in a different export file is a different placeholder.
    @Test func r2_7_placeholdersAreScopedToTheFile() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let a = DYIFixture.export([[M(author: "Facebook User", time: "May 10, 2011 at 9:42 pm", body: "from file one")]])
        let b = DYIFixture.export([[M(author: "Facebook User", time: "May 12, 2011 at 9:42 pm", body: "from file two")]])
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        _ = try FacebookDYI2011Importer.importExport(at: a, into: t.db, allowUnverified: true, zone: .utcMinus4)
        _ = try FacebookDYI2011Importer.importExport(at: b, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized LIKE 'fb:facebook user#%'") == 2)
        #expect(try q(t.db, "SELECT count(DISTINCT thread_id) FROM message") == 2)
    }
}

// The real export's shapes behind the evidence rule: accounts deactivated or fully renamed since 2011.
@Suite struct FacebookDYI2011EvidenceTests {
    typealias M = DYIFixture.M
    private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }

    // Two messages of one conversation match one thread whose person has a wholly different name now: corroborated.
    @Test func corroboratedRenamedConversationIsHeld() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Quinn Zed", at: DYIFixture.T + 10_000, fromMe: false, "a long first message about the play")
        try DYIFixture.add(w, with: "Quinn Zed", at: DYIFixture.T + 70_000, fromMe: true, "ok")
        let dir = DYIFixture.export([[M(author: "Pat Oldname", time: "May 10, 2011 at 9:30 pm", body: "an opener the later export lost"),
                                     M(author: "Pat Oldname", time: "May 10, 2011 at 9:42 pm", body: "a long first message about the play"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:43 pm", body: "ok")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 2 && r.stats.inserted == 1 && r.stats.weakEvidence == 0)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE thread_id = \(try DYIFixture.threadOf(t.db, "Quinn Zed"))") == 3)
    }

    // One long message, the archive side a deactivated account: weak evidence, left out and listed.
    @Test func deactivatedAccountWithOneLongTextIsWeak() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        var g = MessageRecord(participants: [], sender: nil, tsMs: DYIFixture.T + 30_000, isFromMe: false, service: "messenger",
                              body: "happy birthday, have a great day", subject: nil, sourceKey: nil, attachments: [])
        g.participantHandles = [.facebook(name: "Facebook user", unique: "777")]; g.senderHandle = .facebook(name: "Facebook user", unique: "777")
        try DYIFixture.seeder(t.db, "seed").add(g)
        let dir = DYIFixture.export([[M(author: "Real Name", time: "May 10, 2011 at 9:42 pm", body: "happy birthday, have a great day")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 0 && r.stats.inserted == 0 && r.stats.weakEvidence == 1)
    }

    // In a group, a renamed sender is accepted only by elimination: neither name explains the other side.
    @Test func groupRenamedSenderByEliminationOnly() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try FacebookDYI2011MatchingTests.group(w, ["Anni Newname", "Bob Birch"], suffix: "g1", at: DYIFixture.T + 10_000, from: "Anni Newname", "a long message in the group chat")
        try FacebookDYI2011MatchingTests.group(w, ["Anni Newname", "Bob Birch"], suffix: "g1", at: DYIFixture.T + 20_000, from: "Bob Birch", "another long group message")
        let dir = DYIFixture.export([[M(author: "Yani Oldname", to: "Bob Birch", time: "May 10, 2011 at 9:42 pm", body: "a long message in the group chat"),
                                     M(author: "Bob Birch", time: "May 10, 2011 at 9:42 pm", body: "another long group message")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.held == 2 && r.stats.inserted == 0)
    }

    // A new message in an existing 1:1 thread is sent by that thread's person, never a fresh placeholder.
    @Test func newMessageInARenamedThreadUsesItsMember() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Helen Real", at: DYIFixture.T + 10_000, fromMe: false, "a long message that both copies have")
        try DYIFixture.add(w, with: "Helen Real", at: DYIFixture.T + 70_000, fromMe: true, "ok")
        let dir = DYIFixture.export([[M(author: "Unknown", time: "May 10, 2011 at 9:30 pm", body: "an opener the later export lost"),
                                     M(author: "Unknown", time: "May 10, 2011 at 9:42 pm", body: "a long message that both copies have"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:43 pm", body: "ok")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FacebookDYI2011Importer.importExport(at: dir, into: t.db, allowUnverified: true, zone: .utcMinus4)
        #expect(r.stats.inserted == 1 && r.stats.newHandles == 0)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized LIKE 'fb:unknown%'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE h.normalized = 'fb:helen real'") == 2)
    }
}
