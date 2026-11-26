import Foundation

/// The photos and videos of Facebook and Instagram posts: a media plan (one row per media item a post's record carries, written by the
/// plan builder from the records, the live ledgers, PhotoPrism's index and the export's hashes) becomes `post_media` rows.
///
/// Row actions: `link-photoprism` (PhotoPrism holds the file by sha1: the row keeps its photo uid and sha1, no sha256, nothing copied),
/// `already-in-store` (the archive's media store has the file: the row keeps its sha256), `copy` (the file was copied into the media store
/// at `media/<xx>/<sha256>.<ext>` beforehand, outside this command: the row keeps its sha256 and the file gets its `media` row); and two
/// that are ledgered without a row, `same-as-2011-file` and `missing-from-export`.
///
/// Before anything is written, everything is checked and any failure refuses the whole plan: every copied file is present at its target
/// path, the plan's size, and hashes to the plan's sha256 (each read whole); every target path is the store's own name for that sha256;
/// every link's (sha1, uid) pair is live in PhotoPrism (the list given); every post exists; no (post, ordinal) is named twice or taken by a
/// different row; a sha256 already in `media` has the plan's size and path; an in-store file has its media row and is at that path
/// with that size. A row already there identically is counted, not written again. One transaction, one ledger line per plan row
/// (stored with the import); a rerun of the same plan is "already imported". A dry run makes the same checks and decisions and writes
/// nothing.
public struct PostsMediaStats: Codable, Equatable, Sendable {
    public var rows = 0
    public var linked = 0
    public var inStore = 0
    public var copied = 0
    public var alreadyThere = 0
    public var newMediaRows = 0
    public var newBytes = 0
    public var notARow: [String: Int] = [:]
}

public struct PostsMediaReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64?
    public var stats: PostsMediaStats
}

public enum PostsMedia {
    static let rowActions: Set<String> = ["link-photoprism", "already-in-store", "copy"]
    static let ledgerOnly: Set<String> = ["same-as-2011-file", "missing-from-export"]
    static let ledgerHeader = "export\trid\tpost_id\tordinal\taction\tdecision\tsha256\tphotoprism_uid\ttarget_path\texport_path\tnew_media"

    struct Row {
        var line: Int
        var export = "", rid = "", action = "", exportPath = "", sha256 = "", sha1 = "", uid = "", target = "", mime = ""
        var postID: Int64?, ordinal: Int?, bytes: Int?
        var filename: String? { exportPath.isEmpty ? nil : (exportPath as NSString).lastPathComponent }
    }

    static func isHex(_ s: String, _ n: Int) -> Bool { s.count == n && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    static func readPlan(_ url: URL) throws -> [Row] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { throw ArchiveError("the plan is empty") }
        let header = lines.removeFirst().components(separatedBy: "\t")
        func col(_ n: String) throws -> Int {
            guard let i = header.firstIndex(of: n) else { throw ArchiveError("the plan has no \(n) column") }
            return i
        }
        let c = try (export: col("export"), post: col("post_id"), ordinal: col("ordinal"), path: col("export_path"), bytes: col("bytes"),
                     sha256: col("sha256"), sha1: col("sha1"), uid: col("photoprism_uid"), action: col("action"), target: col("target_path"),
                     mime: col("mime"), rid: col("rid"))
        var out: [Row] = []
        for (i, line) in lines.enumerated() {
            let f = line.components(separatedBy: "\t")
            guard f.count == header.count else { throw ArchiveError("plan line \(i + 2): \(f.count) fields, the header has \(header.count); nothing written") }
            var r = Row(line: i + 2)
            r.export = f[c.export]; r.rid = f[c.rid]; r.action = f[c.action]; r.exportPath = f[c.path]
            r.sha256 = f[c.sha256]; r.sha1 = f[c.sha1]; r.uid = f[c.uid]; r.target = f[c.target]; r.mime = f[c.mime]
            r.postID = Int64(f[c.post]); r.ordinal = Int(f[c.ordinal]); r.bytes = Int(f[c.bytes])
            guard rowActions.contains(r.action) || ledgerOnly.contains(r.action) else { throw ArchiveError("plan line \(r.line): unknown action '\(r.action)'; nothing written") }
            if rowActions.contains(r.action) {
                guard let p = r.postID, p > 0, let o = r.ordinal, o >= 0 else { throw ArchiveError("plan line \(r.line): a row needs a post id and an ordinal; nothing written") }
                if r.action == "link-photoprism" {
                    guard isHex(r.sha1, 40), !r.uid.isEmpty else { throw ArchiveError("plan line \(r.line): a link needs PhotoPrism's sha1 and uid; nothing written") }
                } else {
                    guard isHex(r.sha256, 64), let b = r.bytes, b > 0 else { throw ArchiveError("plan line \(r.line): a stored file needs its sha256 and size; nothing written") }
                }
                if r.action == "copy" {
                    let ext = (r.target as NSString).pathExtension
                    let expected = "\(ArchiveRoot.mediaDirName)/\(r.sha256.prefix(2))/\(r.sha256).\(ext)"
                    guard r.target == expected, !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLowercase || $0.isNumber }) else {
                        throw ArchiveError("plan line \(r.line): target \(r.target) is not the store's name for \(r.sha256); nothing written")
                    }
                }
            }
            out.append(r)
        }
        return out
    }

    /// PhotoPrism's live files as "sha1<TAB>uid" pairs (header `sha1`, `photo_uid`), built from a fresh index dump.
    static func readLive(_ url: URL) throws -> Set<String> {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty, lines.removeFirst().components(separatedBy: "\t").prefix(2) == ["sha1", "photo_uid"] else {
            throw ArchiveError("the PhotoPrism list needs the header sha1<TAB>photo_uid")
        }
        return Set(lines.map { $0.components(separatedBy: "\t").prefix(2).joined(separator: "\t") })
    }

    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }

    public static func run(plan url: URL, into db: Database, root: ArchiveRoot, photoprismLive: URL?, dryRun: Bool = false,
                           ledger: URL? = nil, origin: String? = nil) throws -> PostsMediaReport {
        let rows = try readPlan(url)
        let (planSHA, planBytes) = try Hashing.sha256Hex(ofFile: url)
        let key = "posts-media-plan:" + planSHA
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let id = seen.int(0)
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(PostsMediaStats.self, from: Data($0.utf8)) } ?? PostsMediaStats()
            seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return PostsMediaReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()

        // The plan on its own: no (post, ordinal) twice; every link live in PhotoPrism.
        var keys = Set<String>()
        for r in rows where rowActions.contains(r.action) {
            guard keys.insert("\(r.postID!)/\(r.ordinal!)").inserted else { throw ArchiveError("plan line \(r.line): post \(r.postID!) ordinal \(r.ordinal!) is named twice; nothing written") }
        }
        let links = rows.filter { $0.action == "link-photoprism" }
        if !links.isEmpty {
            guard let photoprismLive else { throw ArchiveError("the plan has \(links.count) PhotoPrism links and no --photoprism-live list to check them; nothing written") }
            let live = try readLive(photoprismLive)
            let dead = links.filter { !live.contains($0.sha1 + "\t" + $0.uid) }
            guard dead.isEmpty else { throw ArchiveError("\(dead.count) links are not live in PhotoPrism (first: plan line \(dead[0].line), uid \(dead[0].uid)); nothing written") }
        }
        // Every copied file, whole: present at its target, the plan's size and sha256.
        var missing = 0, wrongSize = 0, wrongHash = 0, checked = Set<String>(), first: Int?
        for r in rows where r.action == "copy" && checked.insert(r.target).inserted {
            let file = root.resolve(relativePath: r.target)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { missing += 1; first = first ?? r.line; continue }
            guard size == r.bytes else { wrongSize += 1; first = first ?? r.line; continue }
            if try Hashing.sha256Hex(ofFile: file).hex != r.sha256 { wrongHash += 1; first = first ?? r.line }
        }
        guard missing == 0, wrongSize == 0, wrongHash == 0 else {
            throw ArchiveError("not every copied file is in the media store as planned: \(missing) missing, \(wrongSize) of another size, \(wrongHash) with another sha256 (first: plan line \(first!)); nothing written")
        }

        var stats = PostsMediaStats()
        var out = [ledgerHeader]
        var sourceID: Int64?
        func body() throws {
            let postThere = try db.prepare("SELECT 1 FROM post WHERE id = ?")
            let existing = try db.prepare("SELECT sha256, photoprism_uid, photoprism_sha1, filename, mime, bytes, export_path FROM post_media WHERE post_id = ? AND ordinal = ?")
            let mediaRow = try db.prepare("SELECT bytes, path FROM media WHERE sha256 = ?")
            let insMedia = try db.prepare("INSERT INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
            let insRow = try db.prepare("INSERT INTO post_media(post_id, ordinal, sha256, photoprism_uid, photoprism_sha1, filename, mime, bytes, export_path) VALUES (?,?,?,?,?,?,?,?,?)")
            var plannedMedia: [String: (bytes: Int, path: String)] = [:]   // this run's new media rows (size and path), so a dry run decides as a run
            for r in rows {
                stats.rows += 1
                func log(_ decision: String, newMedia: Bool = false) {
                    out.append([r.export, r.rid, r.postID.map(String.init) ?? "", r.ordinal.map(String.init) ?? "", r.action, decision, r.sha256, r.uid,
                                r.target, r.exportPath, newMedia ? "1" : "0"].map(clean).joined(separator: "\t"))
                }
                guard rowActions.contains(r.action) else { stats.notARow[r.action, default: 0] += 1; log("not-a-row"); continue }
                let pid = r.postID!, ord = r.ordinal!
                postThere.bind(1, pid)
                let there = try postThere.step(); postThere.reset()
                guard there else { throw ArchiveError("plan line \(r.line): post \(pid) is not in the archive; nothing written") }
                let isLink = r.action == "link-photoprism"
                let sha: String? = isLink ? nil : r.sha256
                let mime: String? = r.mime.isEmpty ? nil : r.mime
                let bytes: Int? = isLink ? r.bytes : r.bytes!
                existing.bind(1, pid).bind(2, ord)
                if try existing.step() {
                    let same = existing.string(0) == sha && existing.string(1) == (isLink ? r.uid : nil) && existing.string(2) == (isLink ? r.sha1 : nil)
                        && existing.string(3) == r.filename && existing.string(4) == mime && (existing.isNull(5) ? nil : Int(existing.int(5))) == bytes
                        && existing.string(6) == (r.exportPath.isEmpty ? nil : r.exportPath)
                    existing.reset()
                    guard same else { throw ArchiveError("plan line \(r.line): post \(pid) ordinal \(ord) is taken by a different row; nothing written") }
                    stats.alreadyThere += 1; log("already-there"); continue
                }
                existing.reset()
                var newMedia = false
                if let sha {
                    mediaRow.bind(1, sha)
                    let have: (bytes: Int, path: String)? = try mediaRow.step() ? (Int(mediaRow.int(0)), mediaRow.string(1) ?? "") : plannedMedia[sha]
                    mediaRow.reset()
                    if let have {
                        guard have.bytes == r.bytes else { throw ArchiveError("plan line \(r.line): media \(sha) is recorded with \(have.bytes) bytes, the plan says \(r.bytes!); nothing written") }
                        // media the row's file must be the one this plan names (and, for a file already in the store, be there)
                        guard have.path == r.target else { throw ArchiveError("plan line \(r.line): media \(sha) is recorded at \(have.path), the plan says \(r.target); nothing written") }
                        if r.action == "already-in-store" {
                            let file = root.resolve(relativePath: have.path)
                            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
                            guard size == have.bytes else { throw ArchiveError("plan line \(r.line): \(have.path) is not in the media store with \(have.bytes) bytes (\(size.map { "\($0) bytes" } ?? "missing")); nothing written") }
                        }
                    } else {
                        guard r.action == "copy" else { throw ArchiveError("plan line \(r.line): \(sha) is planned as already in the store but has no media row; nothing written") }
                        newMedia = true
                        stats.newMediaRows += 1; stats.newBytes += r.bytes!
                        plannedMedia[sha] = (r.bytes!, r.target)
                        if !dryRun { insMedia.bind(1, sha).bind(2, r.target).bind(3, r.bytes!).bind(4, mime); try insMedia.run() }
                    }
                }
                if !dryRun {
                    insRow.bind(1, pid).bind(2, ord).bind(3, sha).bind(4, isLink ? r.uid : nil).bind(5, isLink ? r.sha1 : nil)
                        .bind(6, r.filename).bind(7, mime).bind(8, bytes.map { Int64($0) }).bind(9, r.exportPath.isEmpty ? nil : r.exportPath)
                    try insRow.run()
                }
                switch r.action {
                case "link-photoprism": stats.linked += 1; log("link")
                case "already-in-store": stats.inStore += 1; log("in-store")
                default: stats.copied += 1; log("copy", newMedia: newMedia)
                }
            }
            if !dryRun {
                let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES ('posts-media', ?, ?, ?, ?, ?)")
                let json = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
                ins.bind(1, origin ?? url.path).bind(2, key).bind(3, planBytes).bind(4, Int64(Date().timeIntervalSince1970)).bind(5, json)
                try ins.run()
                sourceID = db.lastInsertRowID
                try ImportLedger.save(db, sourceID: sourceID!, body: out.joined(separator: "\n") + "\n")
            }
        }
        if dryRun { try body() } else { try db.transaction { try body() } }
        if let ledger {
            if let sourceID, let saved = try ImportLedger.load(db, sourceID: sourceID) { try ImportLedger.publish(saved, to: ledger) }
            else { try ImportLedger.publish(out.joined(separator: "\n") + "\n", to: ledger) }
        }
        return PostsMediaReport(status: .imported, sourceID: sourceID, stats: stats)
    }
}
