import Testing
import Foundation
@testable import ArchiveCore

/// Slack's HTTP cache (Chromium simple cache) entries for synthetic files, tied to synthetic Slack messages (invented ids and names).
enum SlackCacheFixtures {
    typealias J = SlackFixtures.J
    static let team = SlackFixtures.team

    /// One `<hash>_0` entry: header, key, body (stream 1) and its EOF record, HTTP headers (stream 0) and its EOF record.
    static func entry(url: String, body: Data, status: Int = 200, contentLength: Int? = nil, contentType: String? = nil, omitContentLength: Bool = false,
                      crcFlag: Bool = true) -> Data {
        func le<T: FixedWidthInteger>(_ v: T, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        var d = Data()
        le(UInt64(0xfcfb6d1ba7725c30), &d); le(UInt32(5), &d); le(UInt32(url.utf8.count), &d); le(UInt32(0), &d); le(UInt32(0), &d)
        d.append(contentsOf: Array(url.utf8)); d.append(body)
        le(UInt64(0xf4fa6f45970d41d8), &d); le(UInt32(crcFlag ? 1 : 0), &d); le(crcFlag ? SlackCachedFiles.crc32(body) : 0, &d); le(UInt32(body.count), &d); le(UInt32(0), &d)
        var h = "HTTP/1.1 \(status) OK\0" + (omitContentLength ? "" : "content-length: \(contentLength ?? body.count)\0")
        if let contentType { h += "content-type: \(contentType)\0" }
        h += "\0"
        let hd = Data(h.utf8); d.append(hd)
        le(UInt64(0xf4fa6f45970d41d8), &d); le(UInt32(0), &d); le(UInt32(0), &d); le(UInt32(hd.count), &d); le(UInt32(0), &d)
        return d
    }
    static func png(_ seed: UInt8, _ n: Int = 300) -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<n).map { UInt8(truncatingIfNeeded: Int($0) * 7 + Int(seed)) }) }
    static func pdf(_ n: Int = 200) -> Data { Data(Array("%PDF-1.4\n".utf8) + (0..<n).map { UInt8(truncatingIfNeeded: $0) }) }

    static let pngFull = png(1), pngThumb = png(2), pdfThumbBig = png(3, 900), pdfThumbSmall = png(4, 50), partThumb = png(5), wrongType = png(6)
    static let pri = "https://files.slack.com/files-pri", tmb = "https://files.slack.com/files-tmb"

    static func file(_ id: String, name: String, type: String, mime: String, size: Int, thumbs: [(String, String)] = [], extra: [(String, J)] = []) -> (String, J) {
        var f: [(String, J)] = [("id", .s(id)), ("name", .s(name)), ("title", .s(name)), ("pretty_type", .s(type)), ("mimetype", .s(mime)), ("mode", .s("hosted")),
                                ("size", .i(size)), ("url_private", .s("\(pri)/\(team)-\(id)/\(name)"))]
        for (k, u) in thumbs { f.append(("thumb_\(k)", .s(u))) }
        return (id, .o(f + extra))
    }

    /// The saves (messages listing the files) and the cache folder. Messages: M1 general ts(30) (FIMG only, no text); M2 dm ts(100)
    /// "see this" with FJPG (bytes are PNG: left out); M3 dm ts(110) and M4 group ts(200) both list FPDF (thumbnails only); M5 general
    /// ts(40) with FPART (the full file is a 206 range entry; its thumbnail attached) and text; FDEL deleted; FLONE listed by no message.
    static func make(dir: URL) throws -> (idb: URL, cache: URL) {
        let g = SlackFixtures.general, dm = SlackFixtures.dmAnn, grp = SlackFixtures.group
        func ts(_ d: Int) -> String { SlackFixtures.ts(d) }
        let files: [(String, J)] = [
            file("FIMG00002", name: "frame.png", type: "PNG", mime: "image/png", size: pngFull.count, thumbs: [("720", "\(tmb)/\(team)-FIMG00002-aa11/frame_720.png")]),
            file("FJPG00002", name: "still.jpg", type: "JPEG", mime: "image/jpeg", size: wrongType.count),
            file("FPDF00002", name: "notes.pdf", type: "PDF", mime: "application/pdf", size: 5000,
                 thumbs: [("pdf", "\(tmb)/\(team)-FPDF00002-bb22/notes_thumb_pdf.png"), ("64", "\(tmb)/\(team)-FPDF00002-bb22/notes_64.png")]),
            file("FPART0002", name: "take.mp4", type: "MPEG 4 Video", mime: "video/mp4", size: 99999, thumbs: [("video", "\(tmb)/\(team)-FPART0002-cc33/take_thumb_video.png")]),
            ("FGONE0002", .o([("id", .s("FGONE0002")), ("mode", .s("tombstone"))])),
            file("FLONE0002", name: "lone.png", type: "PNG", mime: "image/png", size: 10, thumbs: [("360", "\(tmb)/\(team)-FLONE0002-dd44/lone_360.png")]),
            // Two files with one title on one message, both thumbnails: both attached; one full and one thumbnail: neither.
            file("FDUPA0002", name: "image.png", type: "PNG", mime: "image/png", size: 7000, thumbs: [("720", "\(tmb)/\(team)-FDUPA0002-ee01/image_720.png")]),
            file("FDUPB0002", name: "image.png", type: "PNG", mime: "image/png", size: 7000, thumbs: [("720", "\(tmb)/\(team)-FDUPB0002-ee02/image_720.png")]),
            file("FDUPC0002", name: "pic.png", type: "PNG", mime: "image/png", size: png(12).count),
            file("FDUPD0002", name: "pic.png", type: "PNG", mime: "image/png", size: 7000, thumbs: [("720", "\(tmb)/\(team)-FDUPD0002-ee04/pic_720.png")]),
        ]
        func fl(_ ids: String...) -> [(String, J)] { [("files", .a(ids.map { .s($0) }))] }
        let s = SlackFixtures.save(messages: [
            (g, [SlackFixtures.msg(ts(30), g, user: SlackFixtures.bo, text: "", extra: fl("FIMG00002")),
                 SlackFixtures.msg(ts(40), g, user: SlackFixtures.me, text: "the take", extra: fl("FPART0002")),
                 SlackFixtures.msg(ts(50), g, user: SlackFixtures.ann, text: "", extra: fl("FGONE0002")),
                 SlackFixtures.msg(ts(60), g, user: SlackFixtures.ann, text: "no files here"),
                 SlackFixtures.msg(ts(70), g, user: SlackFixtures.ann, text: "", extra: fl("FDUPA0002", "FDUPB0002")),
                 SlackFixtures.msg(ts(80), g, user: SlackFixtures.ann, text: "", extra: fl("FDUPC0002", "FDUPD0002"))]),
            (dm, [SlackFixtures.msg(ts(100), dm, user: SlackFixtures.ann, text: "see this", extra: fl("FJPG00002")),
                  SlackFixtures.msg(ts(110), dm, user: SlackFixtures.me, text: "the notes", extra: fl("FPDF00002"))]),
            (grp, [SlackFixtures.msg(ts(200), grp, user: SlackFixtures.cy, text: "", extra: fl("FPDF00002"))]),
        ], extraFiles: files)
        let idb = try SlackFixtures.write([s], to: dir.appendingPathComponent("slack"))
        let cache = dir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        func put(_ name: String, _ d: Data) throws { try d.write(to: cache.appendingPathComponent(name + "_0")) }
        try put("a1", entry(url: "\(pri)/\(team)-FIMG00002/frame.png", body: pngFull, contentType: "image/png"))
        try put("a2", entry(url: "\(tmb)/\(team)-FIMG00002-aa11/frame_720.png", body: pngThumb, contentType: "image/png"))
        try put("a3", entry(url: "\(pri)/\(team)-FJPG00002/download/still.jpg", body: wrongType, contentType: "image/jpeg"))
        try put("a4", entry(url: "\(tmb)/\(team)-FPDF00002-bb22/notes_thumb_pdf.png", body: pdfThumbBig))
        try put("a5", entry(url: "\(tmb)/\(team)-FPDF00002-bb22/notes_64.png", body: pdfThumbSmall))
        try put("a6", entry(url: "\(pri)/\(team)-FPART0002/take.mp4", body: Data([0, 0, 0, 0x18] + Array("ftypmp42".utf8)), status: 206, contentLength: 99999))
        try put("a7", entry(url: "\(tmb)/\(team)-FPART0002-cc33/take_thumb_video.png", body: partThumb))
        try put("a8", entry(url: "\(pri)/\(team)-FGONE0002/gone.png", body: png(7)))
        try put("a9", entry(url: "\(tmb)/\(team)-FLONE0002-dd44/lone_360.png", body: png(8)))
        try put("b1", entry(url: "\(tmb)/\(team)-FIMG00002-ff99/frame_480.png", body: png(9)))      // not one of its addresses
        try put("b2", entry(url: "https://a.slack-edge.com/app.js", body: Data("x".utf8)))           // not a Slack file
        try put("c1", entry(url: "\(tmb)/\(team)-FDUPA0002-ee01/image_720.png", body: png(10)))
        try put("c2", entry(url: "\(tmb)/\(team)-FDUPB0002-ee02/image_720.png", body: png(11)))
        try put("c3", entry(url: "\(pri)/\(team)-FDUPC0002/pic.png", body: png(12)))
        try put("c4", entry(url: "\(tmb)/\(team)-FDUPD0002-ee04/pic_720.png", body: png(13)))
        try Data([1, 2, 3]).write(to: cache.appendingPathComponent("b3_0"))                          // not an entry at all... unreadable
        return (idb, cache)
    }
}

@Suite struct SlackCachedFilesTests {
    struct Setup { let t: TestArchive; let idb: URL; let cache: URL; let plan: URL }
    static func setup() throws -> Setup {
        let t = try TestArchive()
        let (idb, cache) = try SlackCacheFixtures.make(dir: t.dir)
        _ = try SlackCacheImporter.importCache(at: idb, into: t.db)
        return Setup(t: t, idb: idb, cache: cache, plan: t.dir.appendingPathComponent("plan.tsv"))
    }
    static func sk(_ cid: String, _ dt: Int) -> String { "slack:\(SlackFixtures.team):\(cid):\(SlackFixtures.ts(dt))" }
    /// What extract plus the file copy do on the NAS, done here into the test archive's media folder.
    static func place(_ s: Setup) throws {
        let out = s.t.dir.appendingPathComponent("extracted"), list = s.t.dir.appendingPathComponent("copy.tsv")
        _ = try SlackCachedFiles.extract(plan: s.plan, cacheDir: s.cache, out: out, ledger: s.t.dir.appendingPathComponent("extract.tsv"), copyList: list)
        for l in try String(contentsOf: list, encoding: .utf8).split(separator: "\n") {
            let f = l.split(separator: "\t").map(String.init)
            let dest = s.t.root.resolve(relativePath: f[1])
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: f[0]), to: dest)
        }
    }

    @Test func plansByFileIDWithTypesFromTheBytes() throws {
        let s = try Self.setup(); defer { s.t.cleanup() }
        let rows = try SlackCachedFiles.makePlan(cacheDir: s.cache, indexedDB: s.idb, db: s.t.db, root: s.t.root)
        let att = rows.filter { $0.decision == "attach" }
        // FIMG full on M1; FPDF's largest thumbnail on M3 and M4 (one file, two rows); FPART's thumbnail on M5.
        #expect(att.map { "\($0.fileID) \($0.kind) \($0.thumbSize) \($0.sourceKey)" }.sorted() == [
            "FDUPA0002 thumb 720 \(Self.sk(SlackFixtures.general, 70))",
            "FDUPB0002 thumb 720 \(Self.sk(SlackFixtures.general, 70))",
            "FIMG00002 full  \(Self.sk(SlackFixtures.general, 30))",
            "FPART0002 thumb video \(Self.sk(SlackFixtures.general, 40))",
            "FPDF00002 thumb pdf \(Self.sk(SlackFixtures.dmAnn, 110))",
            "FPDF00002 thumb pdf \(Self.sk(SlackFixtures.group, 200))",
        ])
        #expect(att.allSatisfy { $0.mime == "image/png" && $0.ext == "png" && !$0.mediaPresent && $0.mediaPath == "media/\($0.sha256.prefix(2))/\($0.sha256).png" })
        #expect(att.first { $0.fileID == "FIMG00002" }?.sha256 == SlackCacheFixtures.pngFull.withUnsafeBytes { Hashing.sha256Hex($0) })
        let out = Dictionary(uniqueKeysWithValues: rows.filter { $0.decision != "attach" }.map { ($0.entry, $0.reason) })
        #expect(out["a2"] == "the full file is attached instead")
        #expect(out["a3"] == "bytes are image/png, Slack records image/jpeg")
        #expect(out["a5"] == "another copy of this file is attached instead")
        #expect(out["a6"]?.hasPrefix("HTTP status 206") == true)
        #expect(out["a8"]?.hasPrefix("file deleted in Slack") == true && rows.first { $0.entry == "a8" }?.sourceKey == Self.sk(SlackFixtures.general, 50))
        #expect(out["a9"] == "no cached message lists this file")
        #expect(out["b1"] == "URL is not one of this file's thumbnail addresses")
        #expect(out["b3"] == "unreadable cache entry" && out["b2"] == nil)
        // Notes: before as stored, after with each planned file named as attached; other files and text untouched.
        let m1 = att.first { $0.fileID == "FIMG00002" }!
        #expect(m1.noteBefore == "(PNG “frame.png” not attached (the Slack cache keeps no copy))" && m1.noteAfter == "(PNG “frame.png” attached from Slack's cache)")
        let m3 = att.first { $0.sourceKey == Self.sk(SlackFixtures.dmAnn, 110) }!
        #expect(att.first { $0.fileID == "FDUPA0002" }?.noteAfter == "(PNG “image.png”: a thumbnail from Slack's cache is attached (the full file was not kept); PNG “image.png”: a thumbnail from Slack's cache is attached (the full file was not kept))")
        #expect(out["c3"] == "the note does not name this file one way" && out["c4"] == "the note does not name this file one way")
        #expect(m3.noteAfter == "PDF “notes.pdf”: a thumbnail from Slack's cache is attached (the full file was not kept)")
    }

    @Test func extractsAttachesOnceAndChangesNothingElse() throws {
        let s = try Self.setup(); defer { s.t.cleanup() }
        let db = s.t.db
        try SlackCachedFiles.write(try SlackCachedFiles.makePlan(cacheDir: s.cache, indexedDB: s.idb, db: db, root: s.t.root), to: s.plan, db: db)
        try Self.place(s)
        let ledgerLines = try String(contentsOf: s.t.dir.appendingPathComponent("extract.tsv"), encoding: .utf8).split(separator: "\n")
        #expect(ledgerLines.count == 6)                                                     // header + 5 distinct files
        let snapshot = { (sql: String) throws -> String in
            let st = try db.prepare(sql); var out: [String] = []
            while try st.step() { out.append(st.string(0) ?? "∅") }
            return out.joined(separator: "\n")
        }
        let otherBefore = try snapshot("SELECT id || '|' || thread_id || '|' || coalesce(sender_handle_id,'') || '|' || ts_ms || '|' || is_from_me || '|' || coalesce(body,'∅') || '|' || coalesce(note,'∅') || '|' || coalesce(kind,'∅') || '|' || coalesce(att_hash,'∅') || '|' || coalesce(canonical_id,'') || '|' || content_hash FROM message WHERE source_key NOT IN ('\(Self.sk(SlackFixtures.general, 30))','\(Self.sk(SlackFixtures.general, 40))','\(Self.sk(SlackFixtures.dmAnn, 110))','\(Self.sk(SlackFixtures.group, 200))','\(Self.sk(SlackFixtures.general, 70))') OR source_key IS NULL ORDER BY id")
        let ledger = s.t.dir.appendingPathComponent("attach.tsv")
        let r = try SlackCachedFiles.attach(plan: s.plan, into: db, root: s.t.root, ledger: ledger)
        #expect(r.status == .imported && r.stats.attached == 6 && r.stats.newFiles == 5 && r.stats.messages == 5 && r.stats.notesChanged == 5 && r.stats.fileRowsNowMessages == 3)
        #expect(try db.scalarInt("SELECT count(*) FROM attachment") == 6 && db.scalarInt("SELECT count(*) FROM media") == 5)
        #expect(try snapshot("SELECT id || '|' || thread_id || '|' || coalesce(sender_handle_id,'') || '|' || ts_ms || '|' || is_from_me || '|' || coalesce(body,'∅') || '|' || coalesce(note,'∅') || '|' || coalesce(kind,'∅') || '|' || coalesce(att_hash,'∅') || '|' || coalesce(canonical_id,'') || '|' || content_hash FROM message WHERE source_key NOT IN ('\(Self.sk(SlackFixtures.general, 30))','\(Self.sk(SlackFixtures.general, 40))','\(Self.sk(SlackFixtures.dmAnn, 110))','\(Self.sk(SlackFixtures.group, 200))','\(Self.sk(SlackFixtures.general, 70))') OR source_key IS NULL ORDER BY id") == otherBefore)
        #expect(try db.scalarString("SELECT coalesce(kind, '-') || '|' || note FROM message WHERE source_key = '\(Self.sk(SlackFixtures.general, 30))'") == "-|(PNG “frame.png” attached from Slack's cache)")
        #expect(try db.scalarString("SELECT coalesce(kind, '-') || '|' || body || '|' || note FROM message WHERE source_key = '\(Self.sk(SlackFixtures.general, 40))'")
                == "-|the take|MPEG 4 Video “take.mp4”: a thumbnail from Slack's cache is attached (the full file was not kept)")
        #expect(try db.scalarInt("SELECT count(*) FROM message WHERE id IN (SELECT message_id FROM attachment) AND att_hash IS NULL") == 0)
        #expect(try db.scalarInt("SELECT count(DISTINCT sha256) FROM attachment WHERE message_id IN (SELECT id FROM message WHERE source_key IN ('\(Self.sk(SlackFixtures.dmAnn, 110))','\(Self.sk(SlackFixtures.group, 200))'))") == 1)
        #expect(try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").count == 1 + (try SlackCachedFiles.read(s.plan)).rows.count)
        // A second run adds nothing.
        #expect(try SlackCachedFiles.attach(plan: s.plan, into: db, root: s.t.root).status == .alreadyImported)
        #expect(try db.scalarInt("SELECT count(*) FROM attachment") == 6)
    }

    @Test func refusesAChangedArchiveOrAMissingFileAndWritesNothing() throws {
        let s = try Self.setup(); defer { s.t.cleanup() }
        let db = s.t.db
        try SlackCachedFiles.write(try SlackCachedFiles.makePlan(cacheDir: s.cache, indexedDB: s.idb, db: db, root: s.t.root), to: s.plan, db: db)
        // A missing media file: nothing written.
        #expect(throws: (any Error).self) { try SlackCachedFiles.attach(plan: s.plan, into: db, root: s.t.root) }
        try Self.place(s)
        // A target's note changed since the plan: refused, nothing written.
        try db.exec("UPDATE message SET note = note || ' ' WHERE source_key = '\(Self.sk(SlackFixtures.dmAnn, 110))'")
        #expect(throws: (any Error).self) { try SlackCachedFiles.attach(plan: s.plan, into: db, root: s.t.root) }
        try db.exec("UPDATE message SET note = rtrim(note) WHERE source_key = '\(Self.sk(SlackFixtures.dmAnn, 110))'")
        // Another message imported since the plan: the fingerprint differs, refused.
        try db.exec("INSERT INTO message(thread_id, ts_ms, is_from_me, service, body, source_id, content_hash) SELECT thread_id, 1, 1, 'sms', 'x', source_id, 0 FROM message LIMIT 1")
        #expect(throws: (any Error).self) { try SlackCachedFiles.attach(plan: s.plan, into: db, root: s.t.root) }
        #expect(try db.scalarInt("SELECT count(*) FROM attachment") == 0 && db.scalarInt("SELECT count(*) FROM media") == 0)
        #expect(try db.scalarInt("SELECT count(*) FROM source WHERE kind = 'slack-cache-files'") == 0)
    }

    @Test func readsCacheEntriesAndSniffsTypes() throws {
        let e = try SlackCachedFiles.readEntry(SlackCacheFixtures.entry(url: "https://x/y", body: SlackCacheFixtures.pngFull, contentType: "image/png"))
        #expect(e.url == "https://x/y" && e.status == 200 && e.bodyLength == SlackCacheFixtures.pngFull.count && e.contentType == "image/png" && e.crcOK)
        #expect(SlackCachedFiles.sniff(SlackCacheFixtures.pdf())?.mime == "application/pdf" && SlackCachedFiles.sniff(Data([0xff, 0xd8, 0xff, 0xe0]))?.ext == "jpg")
        #expect(SlackCachedFiles.sniff(Data("hello".utf8)) == nil)
        #expect(SlackCachedFiles.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }

    // MARK: edge cases

    /// One message in #general listing the given files (string ids, or inline objects), the files' records, and cache entries.
    static func mini(_ name: String, files: [(String, SlackFixtures.J)], list: [SlackFixtures.J], entries: [(String, Data)],
                     before: ((Database) throws -> Void)? = nil) throws -> Setup {
        let t = try TestArchive()
        let g = SlackFixtures.general
        let s = SlackFixtures.save(messages: [(g, [SlackFixtures.msg(SlackFixtures.ts(900), g, user: SlackFixtures.ann, text: "", extra: [("files", .a(list))])])], extraFiles: files)
        let idb = try SlackFixtures.write([s], to: t.dir.appendingPathComponent("slack-" + name))
        let cache = t.dir.appendingPathComponent("cache-" + name)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for (n, d) in entries { try d.write(to: cache.appendingPathComponent(n + "_0")) }
        _ = try SlackCacheImporter.importCache(at: idb, into: t.db)
        try before?(t.db)
        return Setup(t: t, idb: idb, cache: cache, plan: t.dir.appendingPathComponent("plan-\(name).tsv"))
    }
    static func plan(_ s: Setup) throws -> [SlackCachedFiles.Row] { try SlackCachedFiles.makePlan(cacheDir: s.cache, indexedDB: s.idb, db: s.t.db, root: s.t.root) }
    static let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8) + (0..<64).map { UInt8($0) })

    /// An ISO-BMFF HEIC file is an image/heic, not an mp4, and its full copy is attached.
    @Test func heicIsAnImage() throws {
        #expect(SlackCachedFiles.sniff(Self.heic)?.mime == "image/heic" && SlackCachedFiles.sniff(Self.heic)?.ext == "heic")
        let T = SlackFixtures.team, pri = SlackCacheFixtures.pri
        let s = try Self.mini("heic", files: [SlackCacheFixtures.file("FHEIC0003", name: "IMG_1.HEIC", type: "HEIC", mime: "image/heic", size: Self.heic.count)],
                              list: [.s("FHEIC0003")], entries: [("h1", SlackCacheFixtures.entry(url: "\(pri)/\(T)-FHEIC0003/IMG_1.HEIC", body: Self.heic))])
        defer { s.t.cleanup() }
        let att = try Self.plan(s).filter { $0.decision == "attach" }
        #expect(att.count == 1 && att.first?.kind == "full" && att.first?.ext == "heic")
    }

    /// The 2022-23 cache: Chromium prefixes each key with the credential mode and upload id (`1/0/https://…`). The URL is what
    /// follows; the body still starts after the whole key; nothing else that merely contains a URL is read as one.
    @Test func aPrefixedCacheKeyIsItsURL() throws {
        #expect(SlackCachedFiles.keyURL("1/0/https://files.slack.com/files-tmb/T1-F1-aa/x_720.png") == "https://files.slack.com/files-tmb/T1-F1-aa/x_720.png")
        #expect(SlackCachedFiles.keyURL("1/0/http://x/y") == "http://x/y")
        #expect(SlackCachedFiles.keyURL("https://files.slack.com/a/1/0/https://b") == "https://files.slack.com/a/1/0/https://b")
        // An upload id (the response to a POST), another credential mode, an isolation prefix: not a plain cached GET, left as it is.
        for odd in ["1/12345/https://files.slack.com/x", "0/0/https://files.slack.com/x", "999/0/https://a", "0/12345/http://x/y", "1/00/https://a", "01/0/https://a",
                    "1/0/_dk_https://a https://b https://files.slack.com/x", "_dk_https://a https://b https://files.slack.com/x", "x/0/https://a", "1/https://a", "1/0/ftp://a", "1/0/", ""] {
            #expect(SlackCachedFiles.keyURL(odd) == odd)
        }
        let T = SlackFixtures.team, tmb = SlackCacheFixtures.tmb, pri = SlackCacheFixtures.pri
        let thumb = SlackCacheFixtures.png(30), full = SlackCacheFixtures.png(31)
        let e = try SlackCachedFiles.readEntry(SlackCacheFixtures.entry(url: "1/0/\(tmb)/\(T)-FKEY00003-ab12/k_720.png", body: thumb))
        #expect(e.url == "\(tmb)/\(T)-FKEY00003-ab12/k_720.png" && e.bodyLength == thumb.count && e.crcOK)
        let s = try Self.mini("key", files: [SlackCacheFixtures.file("FKEY00003", name: "k.png", type: "PNG", mime: "image/png", size: 9000, thumbs: [("720", "\(tmb)/\(T)-FKEY00003-ab12/k_720.png")]),
                                             SlackCacheFixtures.file("FKEY00004", name: "f.png", type: "PNG", mime: "image/png", size: full.count)],
                              list: [.s("FKEY00003"), .s("FKEY00004")],
                              entries: [("k1", SlackCacheFixtures.entry(url: "1/0/\(tmb)/\(T)-FKEY00003-ab12/k_720.png", body: thumb)),
                                        ("k2", SlackCacheFixtures.entry(url: "1/0/\(pri)/\(T)-FKEY00004/f.png", body: full))])
        defer { s.t.cleanup() }
        let att = try Self.plan(s).filter { $0.decision == "attach" }.sorted { $0.fileID < $1.fileID }
        #expect(att.map(\.kind) == ["thumb", "full"] && att.map(\.bodyLength) == [thumb.count, full.count])
        #expect(att.map(\.sha256) == [thumb, full].map { $0.withUnsafeBytes { Hashing.sha256Hex($0) } })
        try SlackCachedFiles.write(try Self.plan(s), to: s.plan, db: s.t.db)
        let out = s.t.dir.appendingPathComponent("out-key")
        let x = try SlackCachedFiles.extract(plan: s.plan, cacheDir: s.cache, out: out, ledger: s.t.dir.appendingPathComponent("xl.tsv"), copyList: s.t.dir.appendingPathComponent("cl.tsv"))
        #expect(x.files == 2 && x.bytes == Int64(thumb.count + full.count))
        // The same thumbnail address under an upload id, with other bytes: no candidate, whether alone or beside the real one.
        let other = SlackCacheFixtures.png(32, 5000)
        let f3 = SlackCacheFixtures.file("FKEY00005", name: "p.png", type: "PNG", mime: "image/png", size: 9000, thumbs: [("720", "\(tmb)/\(T)-FKEY00005-ab12/p_720.png")])
        let post = try Self.mini("post", files: [f3], list: [.s("FKEY00005")], entries: [("p1", SlackCacheFixtures.entry(url: "1/12345/\(tmb)/\(T)-FKEY00005-ab12/p_720.png", body: other))])
        defer { post.t.cleanup() }
        #expect(try Self.plan(post).isEmpty)
        let both = try Self.mini("both", files: [f3], list: [.s("FKEY00005")], entries: [("p1", SlackCacheFixtures.entry(url: "1/12345/\(tmb)/\(T)-FKEY00005-ab12/p_720.png", body: other)),
                                                                                       ("p2", SlackCacheFixtures.entry(url: "1/0/\(tmb)/\(T)-FKEY00005-ab12/p_720.png", body: thumb))])
        defer { both.t.cleanup() }
        let chosen = try Self.plan(both).filter { $0.decision == "attach" }
        #expect(chosen.count == 1 && chosen.first?.entry == "p2" && chosen.first?.bodyLength == thumb.count)
    }

    /// The note text the plan looks for is the one the importer wrote, from the message's inline file object when it has one.
    @Test func inlineFileObjectsNameTheFileAsTheImporterDid() throws {
        let T = SlackFixtures.team, tmb = SlackCacheFixtures.tmb
        let rec = SlackCacheFixtures.file("FINL00003", name: "new.png", type: "PNG", mime: "image/png", size: 9000, thumbs: [("720", "\(tmb)/\(T)-FINL00003-ab12/new_720.png")])
        let inline: SlackFixtures.J = .o([("id", .s("FINL00003")), ("title", .s("old.png")), ("name", .s("old.png")), ("pretty_type", .s("PNG")), ("mode", .s("hosted"))])
        let s = try Self.mini("inline", files: [rec], list: [inline], entries: [("i1", SlackCacheFixtures.entry(url: "\(tmb)/\(T)-FINL00003-ab12/new_720.png", body: SlackCacheFixtures.png(20)))])
        defer { s.t.cleanup() }
        let att = try Self.plan(s).filter { $0.decision == "attach" }
        #expect(att.count == 1 && att.first?.noteAfter == "(PNG “old.png”: a thumbnail from Slack's cache is attached (the full file was not kept))")
    }

    /// A file already attached to the message (an earlier backfill) still leaves the message true: note rewritten, kind
    /// converted, no second attachment row; a second run changes nothing.
    @Test func anAlreadyAttachedFileStillRewritesTheNote() throws {
        let T = SlackFixtures.team, pri = SlackCacheFixtures.pri
        let body = SlackCacheFixtures.png(21), sha = body.withUnsafeBytes { Hashing.sha256Hex($0) }
        let path = "media/\(sha.prefix(2))/\(sha).png"
        let s = try Self.mini("present", files: [SlackCacheFixtures.file("FPRE00003", name: "had.png", type: "PNG", mime: "image/png", size: body.count)],
                              list: [.s("FPRE00003")], entries: [("p1", SlackCacheFixtures.entry(url: "\(pri)/\(T)-FPRE00003/had.png", body: body))]) { db in
            try db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(sha)', '\(path)', \(body.count), 'image/png')")
            try db.exec("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) SELECT id, 'image/png', 'had.png', '\(path)', \(body.count), '\(sha)' FROM message WHERE source_key LIKE 'slack:%:\(SlackFixtures.ts(900))'")
        }
        defer { s.t.cleanup() }
        let dest = s.t.root.resolve(relativePath: path)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: dest)
        try SlackCachedFiles.write(try Self.plan(s), to: s.plan, db: s.t.db)
        let r = try SlackCachedFiles.attach(plan: s.plan, into: s.t.db, root: s.t.root)
        #expect(r.stats.attached == 0 && r.stats.alreadyThere == 1 && r.stats.notesChanged == 1 && r.stats.fileRowsNowMessages == 1)
        let q = "SELECT coalesce(kind, '-') || '|' || note FROM message WHERE source_key LIKE 'slack:%:\(SlackFixtures.ts(900))'"
        #expect(try s.t.db.scalarString(q) == "-|(PNG “had.png” attached from Slack's cache)")
        #expect(try s.t.db.scalarInt("SELECT count(*) FROM attachment") == 1 && s.t.db.scalarInt("SELECT count(*) FROM media") == 1)
        #expect(try SlackCachedFiles.attach(plan: s.plan, into: s.t.db, root: s.t.root).status == .alreadyImported)
        #expect(try s.t.db.scalarString(q) == "-|(PNG “had.png” attached from Slack's cache)")
    }

    /// A full-file address with a query matches the same address with that query.
    @Test func fullFileAddressesWithAQueryMatch() throws {
        let T = SlackFixtures.team, pri = SlackCacheFixtures.pri
        let body = SlackCacheFixtures.png(22), url = "\(pri)/\(T)-FQRY00003/x.png?t=123"
        let rec: (String, SlackFixtures.J) = ("FQRY00003", .o([("id", .s("FQRY00003")), ("name", .s("x.png")), ("title", .s("x.png")), ("pretty_type", .s("PNG")),
                                                            ("mimetype", .s("image/png")), ("mode", .s("hosted")), ("size", .i(body.count)), ("url_private", .s(url))]))
        let s = try Self.mini("query", files: [rec], list: [.s("FQRY00003")], entries: [("q1", SlackCacheFixtures.entry(url: url, body: body))])
        defer { s.t.cleanup() }
        #expect(try Self.plan(s).filter { $0.decision == "attach" }.map(\.kind) == ["full"])
    }

    /// A full file must prove it is whole: Content-Length present and equal, Slack's size present and equal, CRC flagged and right.
    @Test func aFullFileMustProveItIsWhole() throws {
        let T = SlackFixtures.team, pri = SlackCacheFixtures.pri
        let body = SlackCacheFixtures.png(23)
        func rec(_ id: String, size: Int?) -> (String, SlackFixtures.J) {
            var f: [(String, SlackFixtures.J)] = [("id", .s(id)), ("name", .s("\(id).png")), ("title", .s("\(id).png")), ("pretty_type", .s("PNG")), ("mimetype", .s("image/png")),
                                                  ("mode", .s("hosted")), ("url_private", .s("\(pri)/\(T)-\(id)/\(id).png"))]
            if let size { f.append(("size", .i(size))) }
            return (id, .o(f))
        }
        let s = try Self.mini("whole", files: [rec("FNOCL0003", size: body.count), rec("FNOSZ0003", size: nil), rec("FZRSZ0003", size: 0), rec("FNCRC0003", size: body.count)],
                              list: [.s("FNOCL0003"), .s("FNOSZ0003"), .s("FZRSZ0003"), .s("FNCRC0003")],
                              entries: [("w1", SlackCacheFixtures.entry(url: "\(pri)/\(T)-FNOCL0003/FNOCL0003.png", body: body, omitContentLength: true)),
                                        ("w2", SlackCacheFixtures.entry(url: "\(pri)/\(T)-FNOSZ0003/FNOSZ0003.png", body: body)),
                                        ("w3", SlackCacheFixtures.entry(url: "\(pri)/\(T)-FZRSZ0003/FZRSZ0003.png", body: body)),
                                        ("w4", SlackCacheFixtures.entry(url: "\(pri)/\(T)-FNCRC0003/FNCRC0003.png", body: body, crcFlag: false))])
        defer { s.t.cleanup() }
        let rows = try Self.plan(s)
        #expect(rows.filter { $0.decision == "attach" }.isEmpty)
        let why = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry, $0.reason) })
        #expect(why["w1"] == "no Content-Length to prove the body whole" && why["w2"] == "Slack records no size to prove the body whole"
                && why["w3"] == "Slack records no size to prove the body whole" && why["w4"] == "no CRC to prove the body whole")
    }
}
