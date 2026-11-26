import Testing
import Foundation
@testable import ArchiveCore

// Evidence rules for placing and holding 2011 messages, each case reproduced with synthetic data.
// Synthetic names and text only. Assertions use counts and queries, so the same file also ran against c81e1bb to show
// each case reproduced there.

@Suite struct FacebookDYI2011PlacementTests {
    typealias M = DYIFixture.M
    private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
    private func imp(_ dir: URL, _ db: Database) throws -> FacebookDYI2011Report {
        try FacebookDYI2011Importer.importExport(at: dir, into: db, allowUnverified: true, zone: .utcMinus4)
    }
    private func written(_ db: Database) throws -> Int64 {
        try q(db, "SELECT count(*) FROM message m JOIN source s ON s.id = m.source_id WHERE s.kind = 'fb-dyi-2011'")
    }

    // A1. A new group message whose sender matches no member and has no established mapping is left out, never written
    // under a fresh handle that is not in the thread.
    @Test func r3_A1_unresolvedGroupSenderIsLeftOut() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try FacebookDYI2011MatchingTests.group(w, ["Alice Ash", "Bob Birch", "Cy Dee"], suffix: "g1", at: DYIFixture.T + 20_000, from: nil, "a long reply from me in the group")
        let dir = DYIFixture.export([[M(author: "Yani Oldname", to: "Bob Birch", time: "May 10, 2011 at 9:40 pm", body: "hello group from yani"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "a long reply from me in the group")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try imp(dir, t.db)
        #expect(try written(t.db) == 0)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'fb:yani oldname'") == 0)
    }

    // A2. One message carried by two export conversations is written once.
    @Test func r3_A2_sameMessageInTwoConversationsWrittenOnce() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = DYIFixture.export([[M(author: "Icy Page", time: "May 10, 2011 at 9:42 pm", body: "a broadcast filed twice")],
                                    [M(author: "Icy Page", time: "May 10, 2011 at 9:42 pm", body: "a broadcast filed twice")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try imp(dir, t.db)
        #expect(try written(t.db) == 1)
    }

    // A3, as corrected later: the export prints the opener at a reply's minute; its archive copy (114 s earlier here,
    // days earlier elsewhere) is found in the thread before the first reply, not through a wider window.
    @Test func r3_A3_lateOpenerIsHeld() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Dora Dale", at: DYIFixture.T - 114_000, fromMe: true, "hello dora, a long opening line")
        try DYIFixture.add(w, with: "Dora Dale", at: DYIFixture.T + 79_000, fromMe: false, "hi casey, a long answer back")
        let dir = DYIFixture.export([[M(author: DYIFixture.me, to: "Dora Dale", time: "May 10, 2011 at 9:43 pm", body: "hello dora, a long opening line"),
                                     M(author: "Dora Dale", time: "May 10, 2011 at 9:43 pm", body: "hi casey, a long answer back")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 2 && r.stats.inserted == 0)
    }

    // B1. Corroboration needs distinct archive messages: two export messages matching one archive row is one match.
    @Test func r3_B1_corroborationNeedsDistinctArchiveRows() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed"), with: "Quinn Zed", at: DYIFixture.T + 10_000, fromMe: false, "the same long text twice here")
        let dir = DYIFixture.export([[M(author: "Pat Oldname", time: "May 10, 2011 at 9:30 pm", body: "an opener only in this export"),
                                     M(author: "Pat Oldname", time: "May 10, 2011 at 9:42 pm", body: "the same long text twice here"),
                                     M(author: "Pat Oldname", time: "May 10, 2011 at 9:42 pm", body: "the same long text twice here")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try imp(dir, t.db)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE thread_id = \(try DYIFixture.threadOf(t.db, "Quinn Zed"))") == 1)
        #expect(try written(t.db) == 0)
    }

    // B2. A shared first name is not the same person (John Adams is not John Baker).
    @Test func r3_B2_sharedFirstNameIsNotEnough() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try DYIFixture.add(try DYIFixture.seeder(t.db, "seed"), with: "John Baker", at: DYIFixture.T + 10_000, fromMe: false, "a long message about the game tonight")
        let dir = DYIFixture.export([[M(author: "John Adams", time: "May 10, 2011 at 9:30 pm", body: "an opener only in this export"),
                                     M(author: "John Adams", time: "May 10, 2011 at 9:42 pm", body: "a long message about the game tonight")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 0)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE thread_id = \(try DYIFixture.threadOf(t.db, "John Baker"))") == 1)
        #expect(try written(t.db) == 0)
    }

    // B3. Group sender elimination needs exactly one unmatched person on each side; with two, Bo's message is not
    // held against Ann's row.
    @Test func r3_B3_eliminationNeedsExactlyOneOnEachSide() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        let g = ["Ann Newname", "Bo Newname"]
        try FacebookDYI2011MatchingTests.group(w, g, suffix: "g1", at: DYIFixture.T + 10_000, from: "Ann Newname", "message one from ann, long")
        try FacebookDYI2011MatchingTests.group(w, g, suffix: "g1", at: DYIFixture.T + 20_000, from: nil, "my long reply to the group")
        try FacebookDYI2011MatchingTests.group(w, g, suffix: "g1", at: DYIFixture.T + 30_000, from: "Ann Newname", "message two from bo, long")
        let dir = DYIFixture.export([[M(author: "Ann Oldname", to: "Bo Oldname", time: "May 10, 2011 at 9:42 pm", body: "message one from ann, long"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "my long reply to the group"),
                                     M(author: "Bo Oldname", time: "May 10, 2011 at 9:42 pm", body: "message two from bo, long")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 1)           // only my own reply; neither incoming row can be tied to its sender
        #expect(try written(t.db) == 0)      // and the two incoming messages are left out, not written as duplicates
    }

    // B4. Held allocation maximizes matches: rows at T-80 s and T+30 s, export at T and T+2 min: both held.
    @Test func r3_B4_allocationMaximizesHeldMatches() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let w = try DYIFixture.seeder(t.db, "seed")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T - 80_000, fromMe: true, "hello")
        try DYIFixture.add(w, with: "Pat Pine", at: DYIFixture.T + 30_000, fromMe: true, "hello")
        let dir = DYIFixture.export([[M(author: DYIFixture.me, to: "Pat Pine", time: "May 10, 2011 at 9:30 pm", body: "an opener only in this export"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:42 pm", body: "hello"),
                                     M(author: DYIFixture.me, time: "May 10, 2011 at 9:44 pm", body: "hello")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try imp(dir, t.db)
        #expect(r.stats.held == 2 && r.stats.inserted == 1)
    }

    // C. The importer refuses any file but the one it was verified against unless told otherwise.
    @Test func r3_C_refusesAnUnverifiedFile() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = DYIFixture.export([[M(author: "Kim Lo", time: "May 10, 2011 at 9:42 pm", body: "hi")]])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { _ = try FacebookDYI2011Importer.importExport(at: dir, into: t.db) }
        #expect(try q(t.db, "SELECT count(*) FROM message") == 0)
    }
}
