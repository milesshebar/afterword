import Testing
import Foundation
@testable import ArchiveCore

@Suite struct AttachmentBackfillTests {
    struct Staged { let guid: String, message: String, name: String, data: Data, kind: String }

    func stage(_ items: [Staged], in dir: URL, badHashFor: String? = nil) throws -> URL {
        let s = dir.appendingPathComponent("staging-\(UUID().uuidString)")
        var lines = ["attachment_guid\tmessage_guid\tkind\tbytes\tsha1\tsha256\tfrom_me\tsent_unix\trelative_path\tsource"]
        for i in items {
            let rel = "files/\(i.guid)/\(i.name)"
            let u = s.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try i.data.write(to: u)
            var sha = i.data.withUnsafeBytes { Hashing.sha256Hex($0) }
            if i.guid == badHashFor { sha = String(repeating: "0", count: 64) }
            lines.append("\(i.guid)\t\(i.message)\t\(i.kind)\t\(i.data.count)\t-\t\(sha)\t1\t0\t\(rel)\ttest")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: s.appendingPathComponent("map.tsv"), atomically: true, encoding: .utf8)
        return s
    }

    @Test func noteEditing() {
        #expect(AttachmentBackfill.removing("a.jpg", from: "(attachment not on this Mac, offloaded to iCloud: a.jpg)") == (nil, true))
        #expect(AttachmentBackfill.removing("a.jpg", from: "(2 attachments not on this Mac, offloaded to iCloud: a.jpg, b.mov)")
                == ("(attachment not on this Mac, offloaded to iCloud: b.mov)", true))
        #expect(AttachmentBackfill.removing("c.jpg", from: "(attachment not on this Mac, offloaded to iCloud: a.jpg)").found == false)
        #expect(AttachmentBackfill.removing("x, y.jpg", from: "(attachment not on this Mac, offloaded to iCloud: x, y.jpg)") == (nil, true))
        #expect(AttachmentBackfill.removing("a.jpg", from: "edited").found == false)
    }

    @Test func attachesByGuidShortensThenClearsTheNoteAndIsIdempotent() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        let heic = Data(Fixtures.blob(21, count: 9000)), mov = Data(Fixtures.blob(22, count: 9000)), extra = Data(Fixtures.blob(23, count: 700))
        // M-3 becomes an attachment-only system line for the third case
        try t.db.exec("UPDATE message SET kind = 'system', note = '(attachment not on this Mac, offloaded to iCloud: extra.jpg)' WHERE source_key = 'ios:M-3'")

        let first = try stage([Staged(guid: "A2", message: "M-4", name: "IMG_0002.HEIC", data: heic, kind: "image"),
                               Staged(guid: "AX", message: "M-404", name: "nope.jpg", data: extra, kind: "image"),
                               Staged(guid: "AB", message: "M-3", name: "bad.jpg", data: extra, kind: "image")], in: t.dir, badHashFor: "AB")
        let dry = try AttachmentBackfill.run(stagingDir: first, into: t.db, root: t.root, dryRun: true)
        #expect(dry.attached == 1 && dry.messageNotInArchive == 1 && dry.hashMismatch == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 1)

        let s1 = try AttachmentBackfill.run(stagingDir: first, into: t.db, root: t.root)
        #expect(s1.attached == 1 && s1.notesShortened == 1 && s1.newFiles == 1)
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-4'") == "(attachment not on this Mac, offloaded to iCloud: video.mov)")
        #expect(try t.db.scalarString("SELECT a.mime FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.source_key = 'ios:M-4'") == "image/heic")

        let second = try stage([Staged(guid: "A2", message: "M-4", name: "IMG_0002.HEIC", data: heic, kind: "image"),
                                Staged(guid: "A3", message: "M-4", name: "video.mov", data: mov, kind: "video"),
                                Staged(guid: "A9", message: "M-3", name: "extra.jpg", data: extra, kind: "image")], in: t.dir)
        let s2 = try AttachmentBackfill.run(stagingDir: second, into: t.db, root: t.root)
        #expect(s2.alreadyThere == 1 && s2.attached == 2 && s2.notesCleared == 2 && s2.systemLinesRestored == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:M-4' AND note IS NULL") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:M-3' AND kind IS NULL AND note IS NULL") == 1)
        let attHash = try t.db.scalarInt("SELECT att_hash FROM message WHERE source_key = 'ios:M-4'")
        let shas = [heic, mov].map { d in d.withUnsafeBytes { Hashing.sha256Hex($0) } }
        #expect(attHash == Hashing.attachmentHash(shas))
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'attachments-backfill'") == 2)

        let again = try AttachmentBackfill.run(stagingDir: second, into: t.db, root: t.root)
        #expect(again.attached == 0 && again.alreadyThere == 3)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 4)       // M-3's original + 3 backfilled
    }

    @Test func findsMessagesImportedFromAnIPhoneBackupToo() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        // Move M-4 to another source kind, as a message that arrived through an iPhone sms.db import would be.
        try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-backup', 'x', 'iphone-src', 0, 0)")
        try t.db.exec("UPDATE message SET source_id = (SELECT id FROM source WHERE sha256 = 'iphone-src') WHERE source_key = 'ios:M-4'")
        let heic = Data(Fixtures.blob(31, count: 5000))
        let st = try stage([Staged(guid: "B1", message: "M-4", name: "IMG_9.HEIC", data: heic, kind: "image")], in: t.dir)
        let r = try AttachmentBackfill.run(stagingDir: st, into: t.db, root: t.root)
        #expect(r.attached == 1 && r.messageNotInArchive == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.source_key = 'ios:M-4'") >= 1)
    }

    @Test func sameNameTwiceOneRecoveredAndRerunsLeaveTheOtherName() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        try t.db.exec("UPDATE message SET note = '(4 attachments not on this Mac, offloaded to iCloud: image.jpeg, image.jpeg, b.jpg, b.jpg)' WHERE source_key = 'ios:M-4'")
        let one = Data(Fixtures.blob(31, count: 800)), same = Data(Fixtures.blob(32, count: 900))
        // one image.jpeg recovered; both b.jpg recovered and byte-identical (same bytes twice on one message)
        let st = try stage([Staged(guid: "G1", message: "M-4", name: "image.jpeg", data: one, kind: "image"),
                            Staged(guid: "G3", message: "M-4", name: "b.jpg", data: same, kind: "image"),
                            Staged(guid: "G4", message: "M-4", name: "b.jpg", data: same, kind: "image")], in: t.dir)
        let r = try AttachmentBackfill.run(stagingDir: st, into: t.db, root: t.root)
        #expect(r.attached == 2 && r.alreadyThere == 1)
        let want = "(attachment not on this Mac, offloaded to iCloud: image.jpeg)"
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-4'") == want)
        _ = try AttachmentBackfill.run(stagingDir: st, into: t.db, root: t.root)
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-4'") == want)   // a rerun changes nothing
    }
}
