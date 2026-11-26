import Testing
import Foundation
@testable import ArchiveCore

// Openers: the 2011 export prints a conversation's first message (m0) with a later time
// (in 54 of its 58 multi-message conversations, the time of one of the replies), so an opener whose printed time is not
// earlier than its first reply has no time of its own. Synthetic names and text only; the assertions use counts and
// queries, so this file also ran against 7646b74 to show the defect.

@Suite struct FacebookDYI2011OpenerTests {
    typealias M = DYIFixture.M
    private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
    private func imp(_ dir: URL, _ db: Database) throws -> FacebookDYI2011Report {
        try FacebookDYI2011Importer.importExport(at: dir, into: db, allowUnverified: true, zone: .utcMinus4)
    }
    private func written(_ db: Database) throws -> Int64 {
        try q(db, "SELECT count(*) FROM message m JOIN source s ON s.id = m.source_id WHERE s.kind = 'fb-dyi-2011'")
    }
    static let day: Int64 = 86_400_000

    // An opener printed at its last reply's time, held in the archive two days earlier: held, never written again.
    @Test func r4_openerPrintedLateIsMatchedBeforeTheFirstReply() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 2 * Self.day, fromMe: false, "an opener sent two days before the replies")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 600_000 + 20_000, fromMe: true, "a first reply ten minutes before")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: false, "and the last reply, long enough")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "an opener sent two days before the replies"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:32 pm", body: "a first reply ten minutes before"),
                                     M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "and the last reply, long enough")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 3)
        #expect(try written(t.db) == 0)
    }

    // An opener with no time of its own and no archive copy is left out, not written at the printed (reply's) time.
    @Test func r4_unmatchedOpenerWithoutItsOwnTimeIsLeftOut() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 600_000 + 20_000, fromMe: true, "a first reply ten minutes before")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: false, "and the last reply, long enough")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "an opener the later export lost"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:32 pm", body: "a first reply ten minutes before"),
                                     M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "and the last reply, long enough")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 2)
        #expect(try written(t.db) == 0)
        #expect(r.leftOut.count == 1)
    }

    // An opener printed before its first reply keeps its own time and the ordinary window (the 4 real cases).
    @Test func r4_openerWithItsOwnTimeIsUnchanged() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 25_000, fromMe: false, "an opener with its own time")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + Self.day + 10_000, fromMe: true, "a reply the next day, long")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "an opener with its own time"),
                                     M(author: DYIFixture.me, time: "May 11, 2011 at 9:42 pm", body: "a reply the next day, long")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 2 && r.stats.inserted == 0)
    }

    // The late opener never takes an archive row a reply has claimed, and never one after the first reply.
    @Test func r4_lateOpenerRespectsClaimsAndTheFirstReply() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 600_000 + 20_000, fromMe: false, "same words twice, long enough")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: false, "a last reply that is long")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "same words twice, long enough"),
                                     M(author: "Pat Pine", time: "May 10, 2011 at 9:32 pm", body: "same words twice, long enough"),
                                     M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "a last reply that is long")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 2)               // the two replies; the opener's only candidate is the first reply's row
        #expect(try written(t.db) == 0)          // and the opener is left out, not written at the printed time
    }

    // A late opener needs the same text: a tail variant (one text plus an appended link) is not enough without a time.
    @Test func r4_lateOpenerNeedsTheSameText() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 40 * Self.day, fromMe: false, "an opener that is long enough to compare http://example.invalid/x")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 600_000 + 20_000, fromMe: true, "a first reply ten minutes before")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 20_000, fromMe: false, "and the last reply, long enough")
        let dir = DYIFixture.export([[M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "an opener that is long enough to compare"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:32 pm", body: "a first reply ten minutes before"),
                                     M(author: "Pat Pine", time: "May 10, 2011 at 9:42 pm", body: "and the last reply, long enough")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 2 && r.stats.heldTextDiffers == 0)
        #expect(try written(t.db) == 0 && r.leftOut.count == 1)
    }
}
