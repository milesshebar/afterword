import Foundation

/// A Snapchat "My Data" export (unzipped: `json/`, `html/`, `chat_media/`, `memories/`). Snapchat keeps only the chat messages somebody
/// SAVED, so `chat_history.json` is "all it kept", not a broken export.
///
/// Mapping:
/// - people are `sn:<username>` handles (kind `snapchat-user`), named from `friends.json` display names;
/// - `chat_history.json` is `{conversation key: [messages]}`. A key that is a UUID, with a `Conversation Title`, is a group (keyed by its
///   writers plus the key); any other key is a 1:1 thread with that friend;
/// - `TEXT` is a message; `MEDIA` is a message whose picture/video is linked from `chat_media/` by its Media ID (files are named
///   `<date>_<media id>.<ext>`); a snap whose file is not in the export, a `STICKER` and a `SHARE` (no content in the export) are system lines;
/// - times are `Created(microseconds)`, UTC;
/// - `friends.json` adds dates to the people layer through the additive table `contact_date` (who was added, deleted, requested or blocked,
///   when). It is a signal about the relationship, not a message; handles are linked only when the archive already has them.
/// Memories (`memories/`, `memories_history.json`) are photos, not messages: they are handled by the photo pipeline, not here.
public struct SnapchatImportStats: Codable, Equatable, Sendable {
    public var threads = 0, groups = 0, dms = 0
    public var parsed = 0
    public var inserted = 0, duplicates = 0
    public var text = 0, media = 0, stickers = 0, shares = 0
    public var emptySkipped = 0
    public var attachmentsStored = 0, mediaMissing = 0, mediaNewFiles = 0, mediaNewBytes = 0
    public var people = 0
    public var friendDates: [String: Int] = [:]      // contact_date rows written, by list
    public var byYear: [String: Int] = [:]           // messages by year
    public var firstTsMs: Int64?, lastTsMs: Int64?
    public var me: String?
    public var seconds = 0.0
}

public struct SnapchatImportReport: Sendable {
    public enum Status: Sendable { case imported, alreadyImported }
    public var status: Status
    public var stats: SnapchatImportStats
}

public enum SnapchatImporter {
    public static let sourceKind = "snapchat-export"
    public static let nameOrigin = "snapchat-export"

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS contact_date (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES source(id),
            service TEXT NOT NULL,              -- snapchat
            username TEXT NOT NULL,
            display_name TEXT,
            list TEXT NOT NULL,                 -- friend | deleted | request-sent | blocked
            created_ms INTEGER,                 -- when the person was added / requested / blocked
            modified_ms INTEGER,
            how TEXT,                           -- Snapchat's own "added by ..." text
            handle_id INTEGER REFERENCES handle(id),   -- only when the archive already has the handle (a chat with them)
            UNIQUE(service, username, list)
        )
        """,
        "CREATE INDEX IF NOT EXISTS contact_date_created ON contact_date(created_ms)",
    ]

    public static func ensureTables(_ db: Database) throws { for s in tableSQL { try db.exec(s) } }

    /// A folder with `json/chat_history.json` and `json/friends.json`.
    public static func detect(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("json/chat_history.json").path)
            && fm.fileExists(atPath: url.appendingPathComponent("json/friends.json").path)
    }

    static func iso(_ s: String?) -> Int64? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return f.date(from: s).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    public static func importExport(at folder: URL, into db: Database, root: ArchiveRoot, origin: String? = nil) throws -> SnapchatImportReport {
        let t0 = Date()
        let chatURL = folder.appendingPathComponent("json/chat_history.json")
        let friendsURL = folder.appendingPathComponent("json/friends.json")
        let (h1, b1) = try Hashing.sha256Hex(ofFile: chatURL)
        let (h2, b2) = try Hashing.sha256Hex(ofFile: friendsURL)
        let hash = MetaImporter.sha256(of: "snapchat-export-v1|\(h1)|\(h2)")
        try ensureTables(db)
        let sel = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        sel.bind(1, hash)
        if try sel.step() {
            let st = sel.string(0).flatMap { try? JSONDecoder().decode(SnapchatImportStats.self, from: Data($0.utf8)) } ?? SnapchatImportStats()
            sel.reset()
            return SnapchatImportReport(status: .alreadyImported, stats: st)
        }
        sel.reset()

        guard let chats = try JSONSerialization.jsonObject(with: Data(contentsOf: chatURL)) as? [String: [[String: Any]]] else {
            throw ArchiveError("Snapchat export: json/chat_history.json is not {conversation: [messages]}")
        }
        let friends = (try JSONSerialization.jsonObject(with: Data(contentsOf: friendsURL)) as? [String: Any]) ?? [:]
        var me = "me"
        if let acc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("json/account.json")))) as? [String: Any],
           let basic = acc["Basic Information"] as? [String: Any], let u = basic["Username"] as? String, !u.isEmpty { me = u.lowercased() }

        var display: [String: String] = [:]
        for key in ["Friends", "Deleted Friends", "Friend Requests Sent", "Blocked Users"] {
            for e in friends[key] as? [[String: Any]] ?? [] {
                if let u = (e["Username"] as? String)?.lowercased(), let n = e["Display Name"] as? String, !n.isEmpty, display[u] == nil { display[u] = n }
            }
        }

        // chat_media files by media id (the part of the name after "<date>_").
        let mediaDir = folder.appendingPathComponent("chat_media")
        var mediaFiles: [(name: String, url: URL)] = []
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path)) ?? []).sorted() where !n.hasPrefix(".") {
            let ext = (n as NSString).pathExtension.lowercased()
            if ext == "unknown" || n.contains("metadata~") || n.contains("thumbnail~") { continue }
            mediaFiles.append((n.lowercased(), mediaDir.appendingPathComponent(n)))
        }

        var stats = SnapchatImportStats()
        stats.me = me
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, sourceKind).bind(2, origin ?? folder.path).bind(3, hash).bind(4, b1 + b2).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: sourceKind)
            let store = MediaStore(root: root)
            func handle(_ u: String) -> ServiceHandle { ServiceHandle.snapchat(username: u, name: display[u.lowercased()] ?? u) }

            var threadInfo: [Int64: (key: String, isGroup: Bool, title: String?)] = [:]
            var people = Set<String>()
            var mediaCache: [String: AttachmentRecord] = [:]
            for (key, msgs) in chats.sorted(by: { $0.key < $1.key }) {
                let title = msgs.compactMap { ($0["Conversation Title"] as? String).flatMap { $0.isEmpty ? nil : $0 } }.first
                let isGroup = title != nil
                var others: [String] = []
                for m in msgs {
                    if let f = (m["From"] as? String)?.lowercased(), f != me, !f.isEmpty, !others.contains(f) { others.append(f) }
                }
                if others.isEmpty && !isGroup { others = [key.lowercased()] }
                if others.isEmpty { stats.emptySkipped += msgs.count; stats.parsed += msgs.count; continue }
                stats.threads += 1
                if isGroup { stats.groups += 1 } else { stats.dms += 1 }
                writer.groupKeySuffix = isGroup ? "sn-" + key : nil
                let ordered = msgs.sorted { ($0["Created(microseconds)"] as? NSNumber)?.int64Value ?? 0 < ($1["Created(microseconds)"] as? NSNumber)?.int64Value ?? 0 }
                for m in ordered {
                    stats.parsed += 1
                    // "Created(microseconds)" is in milliseconds in real exports (a 13-digit value such as 1600000000000 is 2020-09-13); a true microsecond value
                    // (16 digits) is divided down. The `Created` text is the fallback.
                    guard let raw = (m["Created(microseconds)"] as? NSNumber)?.int64Value ?? iso(m["Created"] as? String) else { stats.emptySkipped += 1; continue }
                    let tsMs = raw > 100_000_000_000_000 ? raw / 1000 : raw
                    let micros = raw
                    let from = (m["From"] as? String)?.lowercased() ?? ""
                    let isMe = (m["IsSender"] as? Bool) ?? (from == me)
                    let type = (m["Media Type"] as? String) ?? "TEXT"
                    let content = (m["Content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    var rec = MessageRecord(participants: [], sender: nil, tsMs: tsMs, isFromMe: isMe, service: "snapchat", body: nil, subject: nil,
                                            sourceKey: "snapchat:\(me):\(key):\(micros):\(from)", attachments: [])
                    rec.participantHandles = others.map(handle)
                    if !isMe, !from.isEmpty { rec.senderHandle = handle(from) }
                    switch type {
                    case "MEDIA":
                        stats.media += 1
                        let ids = ((m["Media IDs"] as? String) ?? "").split(whereSeparator: { $0 == "|" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                        for id in ids {
                            for f in mediaFiles where f.name.contains(id) {
                                if let c = mediaCache[f.name] { rec.attachments.append(c); continue }
                                guard let data = try? Data(contentsOf: f.url, options: .alwaysMapped) else { continue }
                                let ext = f.url.pathExtension.lowercased()
                                let mime = MetaImporter.mimeByExtension[ext] ?? (ext == "mp4" ? "video/mp4" : "application/octet-stream")
                                let stored = try data.withUnsafeBytes { raw in
                                    try store.store(raw, mime: mime, filename: f.url.lastPathComponent, lookup: { writer.existingMediaPath(sha256: $0) })
                                }
                                if stored.wasNew { stats.mediaNewFiles += 1; stats.mediaNewBytes += Int(stored.bytes) }
                                let a = AttachmentRecord(mime: mime, filename: f.url.lastPathComponent, sha256: stored.sha256, relativePath: stored.relativePath, bytes: stored.bytes)
                                mediaCache[f.name] = a
                                rec.attachments.append(a)
                            }
                        }
                        if !rec.attachments.isEmpty { stats.attachmentsStored += rec.attachments.count; if !content.isEmpty { rec.body = content } }
                        else if !content.isEmpty { rec.body = content; stats.mediaMissing += 1 }
                        else { rec.kind = "system"; rec.note = "(snap not in the export)"; stats.mediaMissing += 1 }
                    case "STICKER":
                        stats.stickers += 1
                        if content.isEmpty { rec.kind = "system"; rec.note = "(sticker)" } else { rec.body = content }
                    case "SHARE":
                        stats.shares += 1
                        if content.isEmpty { rec.kind = "system"; rec.note = "(shared a Snapchat item)" } else { rec.body = content }
                    default:
                        stats.text += 1
                        if content.isEmpty { stats.emptySkipped += 1; continue }
                        rec.body = content
                    }
                    switch try writer.add(rec) {
                    case .inserted: stats.inserted += 1
                    case .duplicate: stats.duplicates += 1
                    }
                    if writer.lastThreadID != 0 { threadInfo[writer.lastThreadID] = (key, isGroup, title) }
                    stats.firstTsMs = min(stats.firstTsMs ?? tsMs, tsMs); stats.lastTsMs = max(stats.lastTsMs ?? tsMs, tsMs)
                    let y = String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(tsMs) / 1000)).prefix(4))
                    stats.byYear[y, default: 0] += 1
                }
                for o in others { people.insert(o) }
            }
            stats.people = people.count
            for u in people.sorted() { if let n = display[u] { try writer.noteName(service: handle(u), name: n, origin: nameOrigin, priority: ContactPriority.androidXML) } }

            let sel = try db.prepare("SELECT title FROM thread WHERE id = ?")
            let up = try db.prepare("UPDATE thread SET service = 'snapchat', origin = ?, hidden = 0, external_id = COALESCE(external_id, ?), title = ? WHERE id = ?")
            for (tid, info) in threadInfo.sorted(by: { $0.key < $1.key }) {
                sel.bind(1, tid); _ = try sel.step(); let old = sel.string(0); sel.reset()
                up.bind(1, info.isGroup ? "group" : "dm").bind(2, info.key).bind(3, (old == nil && info.isGroup) ? info.title : old).bind(4, tid)
                try up.run()
            }

            // friends.json -> contact_date
            var handles: [String: Int64] = [:]
            let hq = try db.prepare("SELECT id, normalized FROM handle WHERE kind = 'snapchat-user'")
            while try hq.step() { if let n = hq.string(1) { handles[n] = hq.int(0) } }
            hq.reset()
            let putDate = try db.prepare("""
                INSERT OR IGNORE INTO contact_date(source_id, service, username, display_name, list, created_ms, modified_ms, how, handle_id)
                VALUES (?, 'snapchat', ?, ?, ?, ?, ?, ?, ?)
                """)
            for (key, list) in [("Friends", "friend"), ("Deleted Friends", "deleted"), ("Friend Requests Sent", "request-sent"), ("Blocked Users", "blocked")] {
                for e in friends[key] as? [[String: Any]] ?? [] {
                    guard let u = (e["Username"] as? String)?.lowercased(), !u.isEmpty else { continue }
                    putDate.bind(1, sid).bind(2, u).bind(3, (e["Display Name"] as? String)?.nilIfEmpty).bind(4, list)
                        .bind(5, iso(e["Creation Timestamp"] as? String)).bind(6, iso(e["Last Modified Timestamp"] as? String))
                        .bind(7, e["Source"] as? String).bind(8, handles["sn:" + u])
                    try putDate.run()
                    if db.changes > 0 { stats.friendDates[list, default: 0] += 1 }
                }
            }
            stats.seconds = Date().timeIntervalSince(t0)
            let upS = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            upS.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try upS.run()
        }
        return SnapchatImportReport(status: .imported, stats: stats)
    }
}
