import Testing
import Foundation
@testable import ArchiveCore

/// The staged attachment files are copied into the media store on the NAS's side, then attached
/// on the Mac from a plan without reading them (only a sample is re-hashed). Synthetic data (the standard chat.db fixture).
@Suite struct AttachmentPlanTests {
    static let heic = Data(Fixtures.blob(31, count: 9000)), mov = Data(Fixtures.blob(32, count: 7000)), extra = Data(Fixtures.blob(33, count: 800))
    static func sha(_ d: Data) -> String { d.withUnsafeBytes { Hashing.sha256Hex($0) } }

    /// The archive: the standard snapshot up to 2022-03-31 (M-4 has the note "2 attachments not on this Mac, offloaded to iCloud:
    /// IMG_0002.HEIC, video.mov"), M-3 turned into an attachment-only system line, and a provenance duplicate of M-2 (its chat.db row
    /// re-pointed to a canonical row of another source).
    static func archive() throws -> TestArchive {
        let t = try TestArchive()
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        try t.db.exec("UPDATE message SET kind = 'system', note = '(attachment not on this Mac, offloaded to iCloud: extra.jpg)' WHERE source_key = 'ios:M-3'")
        try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-backup', 'x', 'phone', 0, 0)")
        try t.db.exec("""
            INSERT INTO message(thread_id, sender_handle_id, ts_ms, is_from_me, service, body, source_id, source_key, canonical_id, content_hash)
            SELECT thread_id, sender_handle_id, ts_ms, is_from_me, service, body, (SELECT max(id) FROM source), 'ios:M-2', NULL, content_hash
            FROM message WHERE source_key = 'ios:M-2'
            """)
        let canon = try t.db.scalarInt("SELECT max(id) FROM message")
        try t.db.exec("UPDATE message SET canonical_id = \(canon) WHERE source_key = 'ios:M-2' AND id <> \(canon)")
        return t
    }

    static func input(_ dir: URL, _ rows: [(String, String, String, Data)]) throws -> URL {
        var lines = ["device\tmsg_guid\tatt_guid\tdate\tmime\tbytes\tsha256\tstaged_path"]
        for (msg, att, name, d) in rows { lines.append("test\t\(msg)\t\(att)\t2022-01-01\t-\t\(d.count)\t\(sha(d))\t" + AttachmentPlan.escape("/stage/\(att)/\(name)")) }
        let u = dir.appendingPathComponent("input-\(UUID().uuidString).tsv")
        try (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// What the copy on the NAS does: each planned file at its media path under the root.
    static func place(_ t: TestArchive, _ plan: [AttachmentPlan.Row], _ data: [String: Data]) throws {
        for r in plan where r.decision == "attach" {
            let u = t.root.resolve(relativePath: r.mediaPath)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: u.path) { try data[r.sha256]!.write(to: u) }
        }
    }

    @Test func thePlanNamesFilesAsTheStoreDoesAndPicksTheCanonicalRow() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let photoSha = try t.db.scalarString("SELECT sha256 FROM media LIMIT 1")!                  // the fixture's stored photo
        let photo = try Data(contentsOf: t.root.resolve(relativePath: try t.db.scalarString("SELECT path FROM media LIMIT 1")!))
        let input = try Self.input(t.dir, [("M-4", "A2", "IMG_0002.HEIC", Self.heic), ("M-4", "A2b", "IMG_0002.HEIC", Self.heic),
                                           ("M-404", "AX", "nope.jpg", Self.extra), ("M-2", "AP", "photo.jpg", photo), ("M-3", "A9", "extra.jpg", Self.extra)])
        let plan = try AttachmentPlan.make(input: input, db: t.db, root: t.root)
        #expect(plan.map(\.decision) == ["attach", "repeat-in-plan", "message-not-in-archive", "attach", "attach"])
        #expect(plan[0].mediaPath == "media/\(Self.sha(Self.heic).prefix(2))/\(Self.sha(Self.heic)).heic" && plan[0].mime == "image/heic")
        #expect(plan[3].mediaPath == (try t.db.scalarString("SELECT path FROM media WHERE sha256 = '\(photoSha)'")) && plan[3].mediaPresent)
        let canon = try t.db.scalarInt("SELECT canonical_id FROM message WHERE source_key = 'ios:M-2' AND canonical_id IS NOT NULL")
        #expect(plan[3].messageID == canon)                      // the canonical row, not the chat.db duplicate
    }

    @Test func attachingFromThePlanChangesOnlyTheTargetsNotes() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let input = try Self.input(t.dir, [("M-4", "A2", "IMG_0002.HEIC", Self.heic), ("M-4", "A3", "video.mov", Self.mov),
                                           ("M-3", "A9", "extra.jpg", Self.extra)])
        let plan = try AttachmentPlan.make(input: input, db: t.db, root: t.root)
        try Self.place(t, Array(plan.prefix(3)), [Self.sha(Self.heic): Self.heic, Self.sha(Self.mov): Self.mov, Self.sha(Self.extra): Self.extra])
        let planURL = t.dir.appendingPathComponent("plan.tsv")
        try AttachmentPlan.write(plan, to: planURL, db: t.db)
        func others() throws -> String? {
            try t.db.scalarString("SELECT group_concat(id || '|' || ifnull(body, '') || '|' || ifnull(note, '') || '|' || ifnull(kind, '') || '|' || ifnull(att_hash, ''), ';') FROM message WHERE source_key NOT IN ('ios:M-4', 'ios:M-3')")
        }
        let before = try others()
        let ledger = t.dir.appendingPathComponent("att.tsv")
        let r = try AttachmentBackfill.runPlan(plan: planURL, into: t.db, root: t.root, ledger: ledger)
        #expect(r.status == .imported)
        #expect(r.stats.attached == 3 && r.stats.notesCleared == 2 && r.stats.systemLinesRestored == 1)
        #expect(try others() == before)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:M-4' AND note IS NULL") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:M-3' AND kind IS NULL AND note IS NULL") == 1)
        #expect(try t.db.scalarInt("SELECT att_hash FROM message WHERE source_key = 'ios:M-4'") == Hashing.attachmentHash([Self.heic, Self.mov].map(Self.sha)))
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 4 && lines[0].contains("old_note") && lines[0].contains("new_note"))
        // Again: nothing more, and the ledger is published again from the database.
        try FileManager.default.removeItem(at: ledger)
        let again = try AttachmentBackfill.runPlan(plan: planURL, into: t.db, root: t.root, ledger: ledger)
        #expect(again.status == .alreadyImported && FileManager.default.fileExists(atPath: ledger.path))
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment WHERE sha256 IN ('\(Self.sha(Self.heic))', '\(Self.sha(Self.mov))', '\(Self.sha(Self.extra))')") == 3)
    }

    @Test func aSampledFileThatDoesNotHashToThePlanStopsTheRun() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let input = try Self.input(t.dir, [("M-4", "A2", "IMG_0002.HEIC", Self.heic)])
        let plan = try AttachmentPlan.make(input: input, db: t.db, root: t.root)
        try Self.place(t, plan, [Self.sha(Self.heic): Data(Fixtures.blob(99, count: 9000))])   // right size, wrong bytes
        let planURL = t.dir.appendingPathComponent("plan.tsv")
        try AttachmentPlan.write(plan, to: planURL, db: t.db)
        let attachments = try t.db.scalarInt("SELECT count(*) FROM attachment")
        #expect(throws: (any Error).self) { try AttachmentBackfill.runPlan(plan: planURL, into: t.db, root: t.root, ) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == attachments)
    }

    // MARK: edge cases

    static func planFile(_ t: TestArchive, _ rows: [(String, String, String, Data)], place: Bool = true) throws -> (URL, [AttachmentPlan.Row]) {
        let plan = try AttachmentPlan.make(input: try input(t.dir, rows), db: t.db, root: t.root)
        if place { try Self.place(t, plan, Dictionary(rows.map { (Self.sha($0.3), $0.3) }, uniquingKeysWith: { a, _ in a })) }
        let url = t.dir.appendingPathComponent("plan-\(UUID().uuidString).tsv")
        try AttachmentPlan.write(plan, to: url, db: t.db)
        return (url, plan)
    }

    /// A plan made against another (or an older) archive is refused; a row whose id does not carry its guid is refused.
    @Test func aPlanFromAnotherArchiveOrWithAWrongIdIsRefused() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let (url, _) = try Self.planFile(t, [("M-4", "A2", "IMG_0002.HEIC", Self.heic)])
        try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('test', 'y', 'later', 0, 0)")
        #expect(throws: (any Error).self) { try AttachmentBackfill.runPlan(plan: url, into: t.db, root: t.root, ) }
        let (url2, plan2) = try Self.planFile(t, [("M-4", "A2", "IMG_0002.HEIC", Self.heic)])
        var text = try String(contentsOf: url2, encoding: .utf8)
        let other = try t.db.scalarInt("SELECT id FROM message WHERE source_key = 'ios:M-1'")
        text = text.replacingOccurrences(of: "\t\(plan2[0].messageID!)\tattach", with: "\t\(other)\tattach")
        try text.write(to: url2, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try AttachmentBackfill.runPlan(plan: url2, into: t.db, root: t.root, ) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment WHERE sha256 = '\(Self.sha(Self.heic))'") == 0)
    }

    /// All or nothing: a missing or wrong-sized file refuses the whole run before anything is written.
    @Test func aMissingFileRefusesTheWholeRun() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let (url, plan) = try Self.planFile(t, [("M-4", "A2", "IMG_0002.HEIC", Self.heic), ("M-4", "A3", "video.mov", Self.mov)])
        try FileManager.default.removeItem(at: t.root.resolve(relativePath: plan[1].mediaPath))
        #expect(throws: (any Error).self) { try AttachmentBackfill.runPlan(plan: url, into: t.db, root: t.root, ) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'attachments-backfill'") == 0)
    }

    /// What counts is what the canonical row has, not a duplicate.
    @Test func aFileOnlyOnADuplicateStillGoesToTheCanonicalRow() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let dup = try t.db.scalarInt("SELECT id FROM message WHERE source_key = 'ios:M-2' AND canonical_id IS NOT NULL")
        try t.db.exec("INSERT OR IGNORE INTO media(sha256, path, bytes, mime) VALUES ('\(Self.sha(Self.extra))', 'media/x/y.jpg', 800, 'image/jpeg')")
        try t.db.exec("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (\(dup), 'image/jpeg', 'p.jpg', 'media/x/y.jpg', 800, '\(Self.sha(Self.extra))')")
        let plan = try AttachmentPlan.make(input: try Self.input(t.dir, [("M-2", "AP", "p.jpg", Self.extra)]), db: t.db, root: t.root)
        #expect(plan[0].decision == "attach")
    }

    /// One path per sha256 in a plan, whatever the names.
    @Test func oneShaGetsOnePath() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let plan = try AttachmentPlan.make(input: try Self.input(t.dir, [("M-4", "A2", "report.pdf", Self.mov), ("M-1", "A7", "report", Self.mov)]), db: t.db, root: t.root)
        #expect(plan[0].mediaPath == plan[1].mediaPath)
    }

    /// A tab or a newline in a name survives the plan's TSV; a malformed line is an error, not a dropped row.
    @Test func awkwardNamesSurviveThePlanAndBadLinesAreErrors() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let rows = try AttachmentPlan.make(input: try Self.input(t.dir, [("M-4", "A2", "a\u{0009}b\u{000A}c.heic", Self.heic)]), db: t.db, root: t.root)
        let u = t.dir.appendingPathComponent("p.tsv")
        try AttachmentPlan.write(rows, to: u, db: t.db)
        #expect(try AttachmentPlan.read(u).first?.filename == "a\tb\nc.heic")
        try (try String(contentsOf: u, encoding: .utf8) + "only\tthree\tfields\n").write(to: u, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try AttachmentPlan.read(u) }
    }

    /// A repeat row's name leaves the note too; a name with ", " in it is found in a multi-file note.
    @Test func notesLoseRepeatedAndCommaNames() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        try t.db.exec("UPDATE message SET note = '(2 attachments not on this Mac, offloaded to iCloud: IMG_0002.HEIC, copy.HEIC)' WHERE source_key = 'ios:M-4'")
        try t.db.exec("UPDATE message SET note = '(attachment not on this Mac, offloaded to iCloud: x, y.jpg)' WHERE source_key = 'ios:M-1'")
        let comma = Data(Fixtures.blob(41, count: 500))
        let (url, plan) = try Self.planFile(t, [("M-4", "A2", "IMG_0002.HEIC", Self.heic), ("M-4", "A2c", "copy.HEIC", Self.heic), ("M-1", "AC", "x, y.jpg", comma)])
        #expect(plan.map(\.decision) == ["attach", "repeat-in-plan", "attach"])
        _ = try AttachmentBackfill.runPlan(plan: url, into: t.db, root: t.root, )
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-4'") == nil)
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-1'") == nil)
        // Two readings of this list ("x, y.jpg" + "z.mov", or "x" + "y.jpg, z.mov"): left exactly as it is.
        #expect(AttachmentBackfill.noteRemoval("x, y.jpg", from: "(2 attachments not on this Mac, offloaded to iCloud: x, y.jpg, z.mov)") == .ambiguous)
        #expect(AttachmentBackfill.removing("y.jpg", from: "(attachment not on this Mac, offloaded to iCloud: x, y.jpg)").found == false)
    }

    // MARK: edge cases

    /// B: a name leaves a note only when the note reads one way; the re-review's two cases change nothing.
    @Test func notesAreChangedOnlyWhenTheyReadOneWay() {
        let two = "(2 attachments not on this Mac, offloaded to iCloud: "
        #expect(AttachmentBackfill.noteRemoval("b.jpg", from: two + "a, b.jpg, c.jpg)") == .notListed)
        #expect(AttachmentBackfill.noteRemoval("a.jpg, b.jpg", from: two + "a.jpg, b.jpg)") == .notListed)
        #expect(AttachmentBackfill.noteRemoval("b.jpg", from: two + "a.jpg, b.jpg)") == .removed("(attachment not on this Mac, offloaded to iCloud: a.jpg)"))
        #expect(AttachmentBackfill.noteRemoval("x, y.jpg", from: "(attachment not on this Mac, offloaded to iCloud: x, y.jpg)") == .removed(nil))
        // Three names, three tokens: one reading.
        #expect(AttachmentBackfill.noteRemoval("p.jpg", from: "(3 attachments not on this Mac, offloaded to iCloud: q, r.jpg, p.jpg)") == .removed("(2 attachments not on this Mac, offloaded to iCloud: q, r.jpg)"))
        // Two names, three tokens: two readings ("q" + "r.jpg, p.jpg", or "q, r.jpg" + "p.jpg"); only one lists p.jpg.
        #expect(AttachmentBackfill.noteRemoval("p.jpg", from: "(2 attachments not on this Mac, offloaded to iCloud: q, r.jpg, p.jpg)") == .ambiguous)
    }

    /// A: every file is re-hashed, not a sample: a same-size corrupt file anywhere in the plan stops the run.
    @Test func everyFileIsRehashed() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        // 201 distinct files (the old default sampled 200 and never the last): the last is corrupted, same size.
        let files = (0..<201).map { i in ("M-4", "F\(i)", "f\(i).jpg", Data(Fixtures.blob(UInt8(i % 250), count: 300 + i))) }
        let (url, plan) = try Self.planFile(t, files)
        try Data(Fixtures.blob(251, count: 500)).write(to: t.root.resolve(relativePath: plan[200].mediaPath))
        #expect(throws: (any Error).self) { try AttachmentBackfill.runPlan(plan: url, into: t.db, root: t.root) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment WHERE sha256 = '\(Self.sha(Self.heic))'") == 0)
    }

    /// B2: two guids of one duplicate group in a plan: the second file is a repeat of the canonical row's and its name is cleaned too.
    @Test func twoGuidsOfOneGroupAreOneTarget() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let canon = try t.db.scalarInt("SELECT canonical_id FROM message WHERE source_key = 'ios:M-2' AND canonical_id IS NOT NULL")
        try t.db.exec("UPDATE message SET source_key = 'ios:M-2b' WHERE id = \(canon)")       // the group now has two guids
        try t.db.exec("UPDATE message SET note = '(2 attachments not on this Mac, offloaded to iCloud: a.jpg, b.jpg)' WHERE id = \(canon)")
        let (url, plan) = try Self.planFile(t, [("M-2", "AA", "a.jpg", Self.extra), ("M-2b", "AB", "b.jpg", Self.extra)])
        #expect(plan.map(\.decision) == ["attach", "repeat-in-plan"])
        _ = try AttachmentBackfill.runPlan(plan: url, into: t.db, root: t.root)
        #expect(try t.db.scalarString("SELECT note FROM message WHERE id = \(canon)") == nil)
    }

    /// C: the plan carries a digest of its target messages; a change to one of them (here its note) refuses the run.
    @Test func aChangedTargetRefusesThePlan() throws {
        let t = try Self.archive(); defer { t.cleanup() }
        let (url, _) = try Self.planFile(t, [("M-4", "A2", "IMG_0002.HEIC", Self.heic)])
        try t.db.exec("UPDATE message SET note = 'changed meanwhile' WHERE source_key = 'ios:M-4'")
        #expect(throws: (any Error).self) { try AttachmentBackfill.runPlan(plan: url, into: t.db, root: t.root) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment WHERE sha256 = '\(Self.sha(Self.heic))'") == 0)
    }
}
