import Testing
import Foundation
@testable import ArchiveCore

/// `archivectl posts-media`: a media plan (built by the user's own tooling) becomes post_media rows. Links to PhotoPrism carry its uid and sha1;
/// a file already in the store and a file copied into it carry their sha256 (the copy also gets its media row). Every file is re-hashed
/// and every check holds before anything is written, or nothing is.
@Suite struct PostsMediaTests {
    static let cols = ["export", "post_id", "decision", "ordinal", "export_path", "bytes", "sha256", "sha1", "photoprism_uid", "photoprism_file",
                       "in_store", "action", "target_path", "mime", "rid", "note"]

    struct Setup {
        let t: TestArchive
        let posts: [Int64]
        let copyBytes: Data, copySHA: String, copyPath: String
        let storeBytes: Data, storeSHA: String
        let live: URL
        func cleanup() { t.cleanup() }
    }

    /// Three posts; a file already in the media store (with its media row); a file copied into the store at its planned path; PhotoPrism's
    /// live list with one photo.
    func setup() throws -> Setup {
        let t = try PostsImportTests().seeded()
        let f = PostFixtures.self
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-m"), [
            f.post("a", author: "Ann Example", ts: 1_400_000_000_000, body: "one", dkey: "m|a"),
            f.post("b", author: "Ann Example", ts: 1_400_000_100_000, body: "two", dkey: "m|b"),
            f.post("c", author: "Ann Example", ts: 1_400_000_200_000, body: "three", dkey: "m|c"),
        ], in: t.dir, name: "m.jsonl"), into: t.db)
        let st = try t.db.prepare("SELECT id FROM post ORDER BY id")
        var posts: [Int64] = []
        while try st.step() { posts.append(st.int(0)) }
        let storeBytes = Data("a photo already stored by a message".utf8)
        let storeSHA = storeBytes.withUnsafeBytes { Hashing.sha256Hex($0) }
        let storeRel = "media/\(storeSHA.prefix(2))/\(storeSHA).jpg"
        try write(storeBytes, to: t.root.resolve(relativePath: storeRel))
        try t.db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(storeSHA)', '\(storeRel)', \(storeBytes.count), 'image/jpeg')")
        let copyBytes = Data("a photo copied from the export".utf8)
        let copySHA = copyBytes.withUnsafeBytes { Hashing.sha256Hex($0) }
        let copyPath = "media/\(copySHA.prefix(2))/\(copySHA).jpg"
        try write(copyBytes, to: t.root.resolve(relativePath: copyPath))
        let live = t.dir.appendingPathComponent("pp-live.tsv")
        try "sha1\tphoto_uid\n\(String(repeating: "a", count: 40))\tpqx1live\n".write(to: live, atomically: true, encoding: .utf8)
        return Setup(t: t, posts: posts, copyBytes: copyBytes, copySHA: copySHA, copyPath: copyPath, storeBytes: storeBytes, storeSHA: storeSHA, live: live)
    }

    func write(_ d: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url)
    }

    /// The five kinds of plan row: a link, a file in the store, a copy, a record whose file is the 2011 row's, a file missing from the export.
    func rows(_ s: Setup) -> [[String: String]] {
        let p = s.posts.map(String.init)
        return [
            ["export": "fb", "post_id": p[0], "decision": "new", "ordinal": "0", "export_path": "x/photos/1.jpg", "bytes": "9", "sha256": String(repeating: "b", count: 64),
             "sha1": String(repeating: "a", count: 40), "photoprism_uid": "pqx1live", "photoprism_file": "2014/1.jpg", "in_store": "no", "action": "link-photoprism", "mime": "image/jpeg", "rid": "r1"],
            ["export": "fb", "post_id": p[1], "decision": "new", "ordinal": "0", "export_path": "x/photos/2.jpg", "bytes": "\(s.storeBytes.count)", "sha256": s.storeSHA,
             "sha1": String(repeating: "c", count: 40), "in_store": "yes", "action": "already-in-store", "target_path": "media/\(s.storeSHA.prefix(2))/\(s.storeSHA).jpg", "mime": "image/jpeg", "rid": "r2"],
            ["export": "fb", "post_id": p[1], "decision": "new", "ordinal": "1", "export_path": "x/photos/3.jpg", "bytes": "\(s.copyBytes.count)", "sha256": s.copySHA,
             "sha1": String(repeating: "d", count: 40), "in_store": "no", "action": "copy", "target_path": s.copyPath, "mime": "image/jpeg", "rid": "r3"],
            ["export": "fb", "post_id": p[2], "decision": "held", "ordinal": "", "export_path": "x/photos/4.jpg", "bytes": "5", "sha256": String(repeating: "e", count: 64),
             "sha1": String(repeating: "f", count: 40), "action": "same-as-2011-file", "rid": "r4", "note": "no row: the 2011 row's file"],
            ["export": "fb", "post_id": p[2], "decision": "live", "ordinal": "0", "action": "missing-from-export", "rid": "", "note": "the folder has no such file"],
        ]
    }

    func plan(_ rows: [[String: String]], in s: Setup, name: String = "plan.tsv") throws -> URL {
        let u = s.t.dir.appendingPathComponent(name)
        let body = ([Self.cols.joined(separator: "\t")] + rows.map { r in Self.cols.map { r[$0] ?? "" }.joined(separator: "\t") }).joined(separator: "\n") + "\n"
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func counts(_ s: Setup) throws -> [Int64] {
        try ["post_media", "media", "source", "post", "import_ledger"].map { try s.t.db.scalarInt("SELECT count(*) FROM \($0)") }
    }

    @Test func writesLinksStoredFilesAndCopiesOnceAndADryRunWritesNothing() throws {
        let s = try setup(); defer { s.cleanup() }
        let u = try plan(rows(s), in: s)
        let before = try counts(s)
        let dryLedger = s.t.dir.appendingPathComponent("dry.tsv"), runLedger = s.t.dir.appendingPathComponent("run.tsv")
        let dry = try PostsMedia.run(plan: u, into: s.t.db, root: s.t.root, photoprismLive: s.live, dryRun: true, ledger: dryLedger)
        #expect(try counts(s) == before)
        #expect(dry.stats.linked == 1 && dry.stats.inStore == 1 && dry.stats.copied == 1 && dry.stats.newMediaRows == 1)

        let r = try PostsMedia.run(plan: u, into: s.t.db, root: s.t.root, photoprismLive: s.live, ledger: runLedger)
        #expect(r.status == .imported)
        #expect(r.stats.rows == 5 && r.stats.linked == 1 && r.stats.inStore == 1 && r.stats.copied == 1 && r.stats.newMediaRows == 1 && r.stats.newBytes == s.copyBytes.count)
        #expect(r.stats.notARow == ["same-as-2011-file": 1, "missing-from-export": 1])
        let after = try counts(s)
        #expect(after[0] == before[0] + 3 && after[1] == before[1] + 1 && after[2] == before[2] + 1 && after[3] == before[3])
        // the link: no sha256, PhotoPrism's uid and sha1; the stored file and the copy: their sha256
        let link = try s.t.db.prepare("SELECT sha256 IS NULL, photoprism_uid, photoprism_sha1, filename, export_path FROM post_media WHERE post_id = \(s.posts[0]) AND ordinal = 0")
        #expect(try link.step() && link.int(0) == 1 && link.string(1) == "pqx1live" && link.string(2) == String(repeating: "a", count: 40) && link.string(3) == "1.jpg" && link.string(4) == "x/photos/1.jpg")
        #expect(try s.t.db.scalarInt("SELECT count(*) FROM post_media WHERE post_id = \(s.posts[1]) AND ((ordinal = 0 AND sha256 = '\(s.storeSHA)') OR (ordinal = 1 AND sha256 = '\(s.copySHA)'))") == 2)
        #expect(try s.t.db.scalarInt("SELECT count(*) FROM media WHERE sha256 = '\(s.copySHA)' AND path = '\(s.copyPath)' AND bytes = \(s.copyBytes.count) AND mime = 'image/jpeg'") == 1)
        // dry run = run, one ledger line per plan row
        func decisions(_ u: URL) throws -> [String] { try String(contentsOf: u, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).prefix(7).joined(separator: "\t") } }
        #expect(try decisions(dryLedger) == decisions(runLedger))
        #expect(try decisions(runLedger).count == 6)
        // a second run adds nothing and republishes the ledger
        let again = try PostsMedia.run(plan: u, into: s.t.db, root: s.t.root, photoprismLive: s.live, ledger: runLedger)
        let afterAgain = try counts(s)
        #expect(again.status == .alreadyImported && afterAgain == after)
    }

    @Test func aRowAlreadyThereIdenticallyIsCountedNotWrittenAgain() throws {
        let s = try setup(); defer { s.cleanup() }
        let all = rows(s)
        _ = try PostsMedia.run(plan: try plan([all[2]], in: s, name: "first.tsv"), into: s.t.db, root: s.t.root, photoprismLive: s.live)
        let r = try PostsMedia.run(plan: try plan(all, in: s), into: s.t.db, root: s.t.root, photoprismLive: s.live)
        #expect(r.stats.alreadyThere == 1 && r.stats.copied == 0 && r.stats.newMediaRows == 0 && r.stats.inStore == 1 && r.stats.linked == 1)
        #expect(try s.t.db.scalarInt("SELECT count(*) FROM post_media") == 3)
    }

    /// Every refusal stops the whole plan before anything is written.
    func refused(_ s: Setup, _ rows: [[String: String]], live: URL?? = nil, _ why: String, saying: String) throws {
        let before = try counts(s)
        let u = try plan(rows, in: s, name: "refused-\(abs(why.hashValue)).tsv")
        for dry in [false, true] {
            do {
                _ = try PostsMedia.run(plan: u, into: s.t.db, root: s.t.root, photoprismLive: live ?? s.live, dryRun: dry)
                Issue.record("\(why)\(dry ? " (dry run)" : ""): not refused")
            } catch {
                #expect("\(error)".contains(saying) && "\(error)".contains("nothing written"), "\(why): refused for another reason: \(error)")
            }
        }
        #expect(try counts(s) == before, "\(why): something was written")
    }

    @Test func refusesAMissingPost() throws {
        let s = try setup(); defer { s.cleanup() }
        var r = rows(s); r[2]["post_id"] = "999999"
        try refused(s, r, "a post that is not in the archive", saying: "is not in the archive")
    }

    @Test func refusesATakenPostAndOrdinal() throws {
        let s = try setup(); defer { s.cleanup() }
        try s.t.db.exec("INSERT INTO post_media(post_id, ordinal, photoprism_uid, photoprism_sha1, filename) VALUES (\(s.posts[1]), 1, 'other', '\(String(repeating: "9", count: 40))', 'other.jpg')")
        try refused(s, rows(s), "(post, ordinal) taken by another row", saying: "is taken by a different row")
        var twice = rows(s); twice[1]["ordinal"] = "1"
        try s.t.db.exec("DELETE FROM post_media")
        try refused(s, twice, "the plan itself names one (post, ordinal) twice", saying: "is named twice")
    }

    @Test func refusesAFileThatIsNotInTheStoreAsPlanned() throws {
        let s = try setup(); defer { s.cleanup() }
        try Data("other bytes of the same size!!".utf8).write(to: s.t.root.resolve(relativePath: s.copyPath))
        try refused(s, rows(s), "a copied file with another sha256", saying: "1 with another sha256")
        var r = rows(s); r[2]["bytes"] = "1"
        try write(s.copyBytes, to: s.t.root.resolve(relativePath: s.copyPath))
        try refused(s, r, "a copied file of another size", saying: "1 of another size")
        var gone = rows(s); gone[2]["target_path"] = "media/\(s.copySHA.prefix(2))/\(s.copySHA).png"
        try refused(s, gone, "a target path that is not media/<xx>/<sha256>.<ext> of a file there", saying: "1 missing")
        var odd = rows(s); odd[2]["target_path"] = "media/zz/\(s.copySHA).jpg"
        try refused(s, odd, "a target path off the store's naming rule", saying: "is not the store's name")
    }

    @Test func refusesALinkThatIsNotLiveInPhotoPrism() throws {
        let s = try setup(); defer { s.cleanup() }
        var r = rows(s); r[0]["photoprism_uid"] = "pqx1gone"
        try refused(s, r, "a uid PhotoPrism no longer has live", saying: "not live in PhotoPrism")
        var r2 = rows(s); r2[0]["sha1"] = String(repeating: "0", count: 40)
        try refused(s, r2, "a live uid with another sha1", saying: "not live in PhotoPrism")
        try refused(s, rows(s), live: .some(nil), "links with no PhotoPrism list to check them against", saying: "no --photoprism-live list")
    }

    @Test func refusesAMediaRowOfAnotherSize() throws {
        let s = try setup(); defer { s.cleanup() }
        try s.t.db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(s.copySHA)', '\(s.copyPath)', 7, 'image/jpeg')")
        try refused(s, rows(s), "the copy's sha256 already in media with another size", saying: "is recorded with 7 bytes")
        try s.t.db.exec("DELETE FROM media WHERE sha256 = '\(s.copySHA)'")
        try s.t.db.exec("UPDATE media SET bytes = 3 WHERE sha256 = '\(s.storeSHA)'")
        try refused(s, rows(s), "an in-store file whose media row has another size", saying: "is recorded with 3 bytes")
        try s.t.db.exec("DELETE FROM media WHERE sha256 = '\(s.storeSHA)'")
        try refused(s, rows(s), "an in-store file with no media row", saying: "has no media row")
    }

    /// A sha256 already in media is accepted only at the plan's own path, and an in-store file must be at its
    /// media path with the recorded size.
    @Test func refusesAnExistingMediaRowAtAnotherPath() throws {
        let s = try setup(); defer { s.cleanup() }
        let other = "media/\(s.copySHA.prefix(2))/\(s.copySHA).png"
        try s.t.db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(s.copySHA)', '\(other)', \(s.copyBytes.count), 'image/png')")
        try refused(s, rows(s), "the copy's sha256 already in media at another path", saying: "is recorded at \(other)")
        try s.t.db.exec("DELETE FROM media WHERE sha256 = '\(s.copySHA)'")
        var r = rows(s); r[1]["target_path"] = "media/\(s.storeSHA.prefix(2))/\(s.storeSHA).png"
        try refused(s, r, "an in-store row whose media row has another path", saying: "is recorded at media/")
    }

    @Test func refusesAnInStoreFileThatIsNotAtItsMediaPath() throws {
        let s = try setup(); defer { s.cleanup() }
        let storeFile = s.t.root.resolve(relativePath: "media/\(s.storeSHA.prefix(2))/\(s.storeSHA).jpg")
        try Data("short".utf8).write(to: storeFile)
        try refused(s, rows(s), "an in-store file of another size than its media row", saying: "is not in the media store with")
        let moved = storeFile.deletingLastPathComponent().appendingPathComponent("elsewhere.jpg")
        try FileManager.default.moveItem(at: storeFile, to: moved)
        try refused(s, rows(s), "an in-store file missing at its media path", saying: "is not in the media store with")
    }

    /// A dry run remembers the path of a media row it plans, so it refuses the same plans as the real run (two rows,
    /// one new sha256, two target paths).
    @Test func aDryRunRefusesOneNewFilePlannedAtTwoPaths() throws {
        let s = try setup(); defer { s.cleanup() }
        let png = "media/\(s.copySHA.prefix(2))/\(s.copySHA).png"
        try write(s.copyBytes, to: s.t.root.resolve(relativePath: png))
        var second = rows(s)[2]; second["post_id"] = String(s.posts[2]); second["ordinal"] = "0"; second["target_path"] = png; second["rid"] = "r5"
        try refused(s, [rows(s)[2], second], "one new sha256 planned at two paths", saying: "is recorded at \(s.copyPath), the plan says \(png)")
    }
}
