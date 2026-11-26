import Foundation

/// GroupMe account-data export (Settings → Export data): a folder with `profile/profile.json` and one folder per
/// conversation. A group folder is the group's numeric id; a direct-message folder is `<myUserID>_<otherUserID>`.
/// Each holds `conversation.json`, `message.json` (newest first), `likes/`, `gallery/` (a few downloaded images, named
/// `<messageID>_<w>x<h>.<hash>.<ext>`) and sometimes `poll.json`.
///
/// Mapping:
/// - people are `gm:<user id>` handles (a user id is stable; the display name is per group and changes), named from the
///   group's member list, DM partner and the names on messages;
/// - a group is a group thread keyed by its members plus the group id; a DM is a 1:1 thread;
/// - `sender_type == "system"` rows are system lines; `favorited_by` becomes one ❤️ reaction per liker;
/// - an image or video that is not in the export (almost all of them: the export only downloads a few) is kept as its
///   `i.groupme.com` / `v.groupme.com` URL on its own line of the body, so nothing is lost and it still opens in a browser;
/// - times are Unix seconds (UTC), no time zone question.
public struct GroupMeImportStats: Codable, Equatable, Sendable {
    public var conversations = 0
    public var groups = 0, dms = 0
    public var foldersImported = 0
    public var foldersSkipped = 0         // already imported (same folder hash)
    public var parsed = 0                 // messages in the files
    public var inserted = 0               // canonical rows written
    public var duplicates = 0             // rows linked to an earlier copy (kept)
    public var system = 0
    public var reactions = 0              // likes written as ❤️ reactions
    public var attachmentsStored = 0      // gallery images that were in the export
    public var remoteLinks = 0            // images/videos kept as their URL
    public var polls = 0
    public var filesMissing = 0           // `file` attachments (no URL in the export)
    public var emojiPlaceholders = 0      // GroupMe emoji-pack characters (U+FFFD) removed from the text
    public var emptySkipped = 0
    public var mediaBytes = 0, mediaNewBytes = 0, mediaNewFiles = 0
    public var firstTsMs: Int64?, lastTsMs: Int64?
    public var seconds = 0.0
}

public struct GroupMeImportReport: Sendable {
    public enum Status: Sendable { case imported, alreadyImported }
    public var status: Status
    public var meName: String?
    public var meID: String?
    public var stats: GroupMeImportStats
}

public enum GroupMeImporter {
    public static let exportKind = "groupme-export"
    public static let threadKind = "groupme-thread"
    public static let nameOrigin = "groupme-export"
    public static let likeEmoji = "❤️"

    // MARK: detection

    /// Is `url` a GroupMe export root (a profile folder plus conversation folders)?
    public static func detect(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("profile/profile.json").path) else { return false }
        return !conversationFolders(url).isEmpty
    }

    /// `url` itself, or the export folders one level below it.
    public static func detectAll(_ url: URL) -> [URL] {
        if detect(url) { return [url] }
        let kids = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return kids.filter { detect($0) }
    }

    static func conversationFolders(_ root: URL) -> [URL] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return kids.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fm.fileExists(atPath: $0.appendingPathComponent("conversation.json").path)
                && fm.fileExists(atPath: $0.appendingPathComponent("message.json").path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: import

    public static func importExport(at exportRoot: URL, into db: Database, root: ArchiveRoot, origin: String? = nil,
                                    progress: ((Int, Int, Int) -> Void)? = nil) throws -> GroupMeImportReport {
        let t0 = Date()
        var stats = GroupMeImportStats()
        let folders = conversationFolders(exportRoot)
        stats.conversations = folders.count

        let profileData = try Data(contentsOf: exportRoot.appendingPathComponent("profile/profile.json"))
        guard let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any], let meID = anyString(profile["id"]) else {
            throw ArchiveError("GroupMe export: profile/profile.json has no user id")
        }
        let meName = (profile["name"] as? String) ?? "Me"

        // One hash per conversation folder (its JSON files and the names of its gallery files), so an unchanged conversation is
        // never imported twice and a changed one (a newer export) is imported again with the overlap linked as duplicates.
        var hashes: [String] = [], bytesByFolder: [Int64] = []
        for f in folders {
            var h = "groupme-thread-v1|\(f.lastPathComponent)\n"
            var total: Int64 = 0
            for name in ["conversation.json", "message.json", "poll.json"] {
                let u = f.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                let (hex, n) = try Hashing.sha256Hex(ofFile: u)
                h += "\(name):\(hex)\n"; total += n
            }
            let gallery = f.appendingPathComponent("gallery")
            for g in ((try? FileManager.default.contentsOfDirectory(atPath: gallery.path)) ?? []).sorted() where g != "manifest.json" {
                h += "gallery:\(g)\n"
            }
            hashes.append(sha256(of: h)); bytesByFolder.append(total)
        }
        let exportHash = sha256(of: "groupme-export-v1|\(meID)|" + hashes.sorted().joined(separator: ","))
        let sel = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        sel.bind(1, exportHash)
        if try sel.step() {
            let st = sel.string(0).flatMap { try? JSONDecoder().decode(GroupMeImportStats.self, from: Data($0.utf8)) } ?? GroupMeImportStats()
            sel.reset()
            return GroupMeImportReport(status: .alreadyImported, meName: meName, meID: meID, stats: st)
        }
        sel.reset()

        try MetaImporter.setMeta(db, "groupme.me", meName)
        try MetaImporter.setMeta(db, "groupme.me_id", meID)

        let store = MediaStore(root: root)
        let existing = try db.prepare("SELECT 1 FROM source WHERE sha256 = ?")
        var messages = 0
        for (i, f) in folders.enumerated() {
            existing.bind(1, hashes[i])
            let have = try existing.step()
            existing.reset()
            if have { stats.foldersSkipped += 1; progress?(i + 1, folders.count, messages); continue }
            try db.transaction {
                try importFolder(f, hash: hashes[i], bytes: bytesByFolder[i], meID: meID, store: store, db: db, stats: &stats)
            }
            stats.foldersImported += 1
            messages = stats.inserted + stats.duplicates
            progress?(i + 1, folders.count, messages)
        }
        stats.seconds = Date().timeIntervalSince(t0)
        let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,?)")
        ins.bind(1, exportKind).bind(2, origin ?? exportRoot.path).bind(3, exportHash)
            .bind(4, bytesByFolder.reduce(0, +)).bind(5, Int64(Date().timeIntervalSince1970))
            .bind(6, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self))
        try ins.run()
        return GroupMeImportReport(status: .imported, meName: meName, meID: meID, stats: stats)
    }

    // MARK: one conversation

    struct Person {
        var id: String
        var names: [String] = []                 // distinct display names, best first
        var handle: ServiceHandle { ServiceHandle.groupme(userID: id, name: names.first ?? "GroupMe user \(id)") }
    }

    static func importFolder(_ f: URL, hash: String, bytes: Int64, meID: String, store: MediaStore, db: Database,
                             stats: inout GroupMeImportStats) throws {
        let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
        ins.bind(1, threadKind).bind(2, f.path).bind(3, hash).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
        try ins.run()
        let sid = db.lastInsertRowID

        guard let conv = try JSONSerialization.jsonObject(with: Data(contentsOf: f.appendingPathComponent("conversation.json"))) as? [String: Any],
              let msgs = try JSONSerialization.jsonObject(with: Data(contentsOf: f.appendingPathComponent("message.json"))) as? [[String: Any]] else {
            throw ArchiveError("GroupMe export: \(f.lastPathComponent) is not a conversation folder")
        }
        let dmInfo = conv["chat"] as? [String: Any]
        let isDM = dmInfo != nil
        var externalID = f.lastPathComponent
        var title: String?
        var people: [String: Person] = [:]
        var order: [String] = []
        func note(_ id: String?, _ name: String?) {
            guard let id, id != meID, id != "system", id != "0" else { return }
            if people[id] == nil { people[id] = Person(id: id); order.append(id) }
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, !people[id]!.names.contains(n) { people[id]!.names.append(n) }
        }
        if let dm = dmInfo {
            stats.dms += 1
            if let other = dm["other_user"] as? [String: Any] { note(anyString(other["id"]), other["name"] as? String) }
        } else {
            stats.groups += 1
            externalID = anyString(conv["id"]) ?? externalID
            title = (conv["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            for m in conv["members"] as? [[String: Any]] ?? [] {
                // The member list is current members; the nickname is what that person is called in this group.
                note(anyString(m["user_id"]), m["nickname"] as? String)
                note(anyString(m["user_id"]), m["name"] as? String)
            }
        }
        // People who wrote here but are no longer listed, and the names they used on messages (most used first would be
        // nicer, but a first-seen order over a newest-first file is stable and the member nickname already leads).
        var nameCount: [String: [String: Int]] = [:]
        for m in msgs where (m["sender_type"] as? String) == "user" {
            if let id = anyString(m["sender_id"]), id != meID, let n = m["name"] as? String { nameCount[id, default: [:]][n, default: 0] += 1 }
        }
        for m in msgs where (m["sender_type"] as? String) == "user" { note(anyString(m["sender_id"]), nil) }
        for id in order {
            let used = (nameCount[id] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            for n in used.prefix(1) { note(id, n) }
        }
        if order.isEmpty { note("unknown-\(externalID)", "Unknown") }

        let polls = try loadPolls(f)
        let gallery = loadGallery(f)

        // Chronological order: ids are time-ordered integers; ties and odd ids fall back to the timestamp.
        let sorted = msgs.sorted { a, b in
            let ta = tsSeconds(a), tb = tsSeconds(b)
            if ta != tb { return ta < tb }
            return (anyString(a["id"]).flatMap { Int64($0) } ?? 0) < (anyString(b["id"]).flatMap { Int64($0) } ?? 0)
        }

        let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: threadKind)
        writer.groupKeySuffix = "gm-" + externalID
        let participantHandles = order.map { people[$0]!.handle }
        var threadID: Int64?
        var inserted = 0, duplicates = 0
        var firstTs: Int64?, lastTs: Int64?
        var mediaCache: [String: AttachmentRecord] = [:]
        for m in sorted {
            stats.parsed += 1
            guard let secs = tsSecondsOptional(m) else { stats.emptySkipped += 1; continue }
            let tsMs = secs * 1000
            let senderID = anyString(m["sender_id"])
            let isSystem = (m["sender_type"] as? String) == "system" || senderID == "system"
            let isMe = !isSystem && senderID == meID
            var text = (m["text"] as? String) ?? ""
            var rec = MessageRecord(participants: [], sender: nil, tsMs: tsMs, isFromMe: isMe, service: "groupme",
                                    body: nil, subject: nil, sourceKey: nil, attachments: [])
            rec.participantHandles = participantHandles
            if !isMe, !isSystem, let id = senderID { rec.senderHandle = (people[id] ?? Person(id: id)).handle }

            if isSystem {
                rec.kind = "system"; rec.note = text.isEmpty ? "(group event)" : text
                stats.system += 1
            } else {
                var lines: [String] = []
                var hadAttachment = false
                for a in m["attachments"] as? [[String: Any]] ?? [] {
                    switch a["type"] as? String {
                    case "emoji":
                        // GroupMe's own emoji packs: the text holds one U+FFFD per emoji and the pack is not in the export.
                        let n = text.filter { $0 == "\u{FFFD}" }.count
                        if n > 0 { stats.emojiPlaceholders += n; text = text.replacingOccurrences(of: "\u{FFFD}", with: "") }
                    case "image":
                        hadAttachment = true
                        guard let url = a["url"] as? String else { break }
                        if let rec2 = try storedGalleryImage(url: url, messageID: anyString(m["id"]), gallery: gallery, store: store, writer: writer,
                                                             cache: &mediaCache, stats: &stats) {
                            rec.attachments.append(rec2); stats.attachmentsStored += 1
                        } else { lines.append(url); stats.remoteLinks += 1 }
                    case "linked_image":
                        hadAttachment = true
                        if let url = a["url"] as? String, !text.contains(url) { lines.append(url); stats.remoteLinks += 1 }
                    case "video":
                        hadAttachment = true
                        if let url = a["url"] as? String { lines.append(url); stats.remoteLinks += 1 }
                    case "poll":
                        hadAttachment = true
                        if let id = anyString(a["poll_id"]), let line = polls[id] { lines.append(line); stats.polls += 1 }
                        else { lines.append("Poll (details not in the export)"); stats.polls += 1 }
                    case "file":
                        hadAttachment = true
                        lines.append("(file attachment not in export)"); stats.filesMissing += 1
                    default: break          // mentions (already @name in the text), postprocessing, autokicked_member
                    }
                }
                var body = text
                for l in lines { body += (body.isEmpty ? "" : "\n") + l }
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { rec.body = body }
                if rec.body == nil && rec.attachments.isEmpty {
                    if hadAttachment { rec.kind = "system"; rec.note = "(attachment not in export)"; stats.system += 1 }
                    else { stats.emptySkipped += 1; continue }
                }
            }
            for liker in m["favorited_by"] as? [Any] ?? [] {
                guard let uid = anyString(liker) else { continue }
                if uid == meID { rec.reactions.append(ReactionRecord(emoji: likeEmoji, actor: nil, byMe: true)) }
                else { rec.reactions.append(ReactionRecord(emoji: likeEmoji, actor: (people[uid] ?? Person(id: uid)).handle, byMe: false)) }
                stats.reactions += 1
            }
            switch try writer.add(rec) {
            case .inserted: inserted += 1
            case .duplicate: duplicates += 1
            }
            threadID = writer.lastThreadID
            firstTs = min(firstTs ?? tsMs, tsMs); lastTs = max(lastTs ?? tsMs, tsMs)
        }
        stats.inserted += inserted; stats.duplicates += duplicates
        if let a = firstTs { stats.firstTsMs = min(stats.firstTsMs ?? a, a) }
        if let b = lastTs { stats.lastTsMs = max(stats.lastTsMs ?? b, b) }

        for id in order {
            let p = people[id]!
            for n in p.names { try writer.noteName(service: p.handle, name: n, origin: nameOrigin, priority: ContactPriority.androidXML) }
        }

        if let tid = threadID {
            let sel = try db.prepare("SELECT title, is_group FROM thread WHERE id = ?")
            sel.bind(1, tid)
            _ = try sel.step()
            let oldTitle = sel.string(0), isGroup = sel.int(1) != 0
            sel.reset()
            let newTitle = (oldTitle == nil && isGroup) ? title : oldTitle
            let up = try db.prepare("UPDATE thread SET service = 'groupme', origin = ?, hidden = 0, external_id = COALESCE(external_id, ?), title = ? WHERE id = ?")
            up.bind(1, isDM ? "dm" : "group").bind(2, externalID).bind(3, newTitle).bind(4, tid)
            try up.run()
        }
        var s = GroupMeImportStats()
        s.parsed = msgs.count; s.inserted = inserted; s.duplicates = duplicates
        let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
        up.bind(1, String(decoding: try JSONEncoder().encode(s), as: UTF8.self)).bind(2, sid)
        try up.run()
    }

    // MARK: pieces

    /// The ❤️-less summary of a poll: "Poll: subject — option (votes), ...".
    static func loadPolls(_ folder: URL) throws -> [String: String] {
        let u = folder.appendingPathComponent("poll.json")
        guard let data = try? Data(contentsOf: u), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for item in arr {
            guard let d = item["data"] as? [String: Any], let id = anyString(d["id"]) else { continue }
            let subject = (d["subject"] as? String) ?? ""
            let opts = (d["options"] as? [[String: Any]] ?? []).map { o -> String in
                let title = (o["title"] as? String) ?? ""
                let votes = (o["votes"] as? Int) ?? Int(anyString(o["votes"]) ?? "") ?? 0
                return "\(title) (\(votes))"
            }
            out[id] = "Poll: \(subject)" + (opts.isEmpty ? "" : " — " + opts.joined(separator: ", "))
        }
        return out
    }

    /// Gallery files by image hash (the part of the URL after the extension: `.../1005x531.jpeg.<hash>`).
    static func loadGallery(_ folder: URL) -> [String: URL] {
        let dir = folder.appendingPathComponent("gallery")
        var out: [String: URL] = [:]
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) where name != "manifest.json" {
            // <messageID>_<w>x<h>.<hash>.<ext>
            let parts = name.split(separator: ".")
            if parts.count >= 3 { out[String(parts[parts.count - 2])] = dir.appendingPathComponent(name) }
        }
        return out
    }

    static func storedGalleryImage(url: String, messageID: String?, gallery: [String: URL], store: MediaStore, writer: ArchiveWriter,
                                   cache: inout [String: AttachmentRecord], stats: inout GroupMeImportStats) throws -> AttachmentRecord? {
        guard let hash = url.split(separator: ".").last.map(String.init), let file = gallery[hash] else { return nil }
        if let c = cache[hash] { stats.mediaBytes += c.bytes; return c }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let ext = file.pathExtension.lowercased()
        let mime = MetaImporter.mimeByExtension[ext] ?? "image/jpeg"
        let stored = try data.withUnsafeBytes { raw in
            try store.store(raw, mime: mime, filename: file.lastPathComponent, lookup: { writer.existingMediaPath(sha256: $0) })
        }
        if stored.wasNew { stats.mediaNewFiles += 1; stats.mediaNewBytes += stored.bytes }
        stats.mediaBytes += stored.bytes
        let rec = AttachmentRecord(mime: mime, filename: file.lastPathComponent, sha256: stored.sha256, relativePath: stored.relativePath, bytes: stored.bytes)
        cache[hash] = rec
        return rec
    }

    static func tsSecondsOptional(_ m: [String: Any]) -> Int64? {
        if let n = m["created_at"] as? NSNumber { return n.int64Value }
        if let s = m["created_at"] as? String { return Int64(s) }
        return nil
    }
    static func tsSeconds(_ m: [String: Any]) -> Int64 { tsSecondsOptional(m) ?? 0 }

    /// JSON ids come as strings or numbers depending on the file.
    static func anyString(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func sha256(of s: String) -> String { MetaImporter.sha256(of: s) }
}
