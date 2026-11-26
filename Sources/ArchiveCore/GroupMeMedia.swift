import Foundation

/// Attaches the GroupMe images and videos that were fetched from their `i.groupme.com` / `v.groupme.com` URLs after the export import
/// (the export only carries a handful of files; every other image is a URL on its own line of the message body).
///
/// A downloader you run yourself (not part of this package; fetch slowly) leaves a folder with `results.jsonl` (one JSON object per URL:
/// `url`, `status` = ok | gone | failed, `ctype`, `bytes`, `sha256`, `file`) and the downloaded files named by sha256. For every `ok` URL
/// this stores the bytes in the content-addressed media store, adds an `attachment` to each message that had the URL, and removes the URL
/// line from the body. The original URL is kept as the attachment's `filename` (provenance). Idempotent: once a URL line is gone there is nothing to do.
public struct GroupMeMediaStats: Codable, Equatable, Sendable {
    public var urls = 0, ok = 0, gone = 0, failed = 0
    public var attached = 0               // attachment rows added
    public var messagesChanged = 0
    public var bodiesEmptied = 0          // messages that were only the URL and now have no text
    public var newFiles = 0, newBytes = 0
    public var rejected = 0               // fetched files that failed the content check (kind, size, hash)
    public var urlsNotInArchive = 0
}

public enum GroupMeMedia {
    public static func attach(fetchedDir: URL, into db: Database, root: ArchiveRoot) throws -> GroupMeMediaStats {
        var stats = GroupMeMediaStats()
        let logURL = fetchedDir.appendingPathComponent("results.jsonl")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        var latest: [String: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let u = obj["url"] as? String else { continue }
            latest[u] = obj
        }
        stats.urls = latest.count
        let store = MediaStore(root: root)
        let selMsgs = try db.prepare("SELECT id, body FROM message WHERE service = 'groupme' AND body LIKE ? ESCAPE '\\'")
        let selMedia = try db.prepare("SELECT path FROM media WHERE sha256 = ?")
        let insMedia = try db.prepare("INSERT OR IGNORE INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
        let insAtt = try db.prepare("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (?,?,?,?,?,?)")
        let upd = try db.prepare("UPDATE message SET body = ?, content_hash = ?, att_hash = ? WHERE id = ?")
        let attShas = try db.prepare("SELECT sha256 FROM attachment WHERE message_id = ?")

        try db.transaction {
            for url in latest.keys.sorted() {
                let r = latest[url]!
                switch r["status"] as? String {
                case "gone"?: stats.gone += 1; continue
                case "ok"?: stats.ok += 1
                default: stats.failed += 1; continue
                }
                // The fetched file must be what the log says: right hash, right size, an image or a video.
                guard let file = r["file"] as? String, let sha = r["sha256"] as? String, let ctype = r["ctype"] as? String,
                      ctype.hasPrefix("image/") || ctype.hasPrefix("video/"),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped), data.count > 0,
                      (r["bytes"] as? Int).map({ $0 == data.count }) ?? true else { stats.rejected += 1; continue }
                let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                selMsgs.bind(1, "%" + escaped + "%")
                var rows: [(Int64, String)] = []
                while try selMsgs.step() { rows.append((selMsgs.int(0), selMsgs.string(1) ?? "")) }
                selMsgs.reset()
                if rows.isEmpty { stats.urlsNotInArchive += 1; continue }
                let stored = try data.withUnsafeBytes { raw in
                    try store.store(raw, mime: ctype, filename: url, lookup: { h in
                        selMedia.bind(1, h); defer { selMedia.reset() }
                        return (try? selMedia.step()) == true ? selMedia.string(0) : nil
                    })
                }
                guard stored.sha256 == sha else { stats.rejected += 1; continue }
                if stored.wasNew { stats.newFiles += 1; stats.newBytes += stored.bytes }
                insMedia.bind(1, stored.sha256).bind(2, stored.relativePath).bind(3, stored.bytes).bind(4, ctype)
                try insMedia.run()
                for (mid, body) in rows {
                    var lines = body.components(separatedBy: "\n")
                    guard let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == url }) else { continue }
                    lines.remove(at: at)
                    let newBody = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    insAtt.bind(1, mid).bind(2, ctype).bind(3, url).bind(4, stored.relativePath).bind(5, stored.bytes).bind(6, stored.sha256)
                    try insAtt.run()
                    stats.attached += 1; stats.messagesChanged += 1
                    var shas: [String] = []
                    attShas.bind(1, mid)
                    while try attShas.step() { if let s = attShas.string(0) { shas.append(s) } }
                    attShas.reset()
                    if newBody.isEmpty { stats.bodiesEmptied += 1 }
                    upd.bind(1, newBody.isEmpty ? nil : newBody).bind(2, Hashing.fnv1a(Hashing.normalizedBody(newBody.isEmpty ? nil : newBody)))
                        .bind(3, Hashing.attachmentHash(shas)).bind(4, mid)
                    try upd.run()
                }
            }
            let ins = try db.prepare("INSERT OR IGNORE INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES ('groupme-media', ?, ?, ?, ?, ?)")
            let shaOfLog = try Hashing.sha256Hex(ofFile: logURL).hex
            ins.bind(1, "fetched from groupme.com (log: \(logURL.lastPathComponent))").bind(2, shaOfLog).bind(3, Int64(stats.newBytes))
                .bind(4, Int64(Date().timeIntervalSince1970)).bind(5, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self))
            try ins.run()
        }
        return stats
    }
}
