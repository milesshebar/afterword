import Foundation

/// Attaches Messages attachments that were offloaded to iCloud when chat.db was imported and have since been recovered (from an iPhone
/// backup, or downloaded by Messages), matched by the message guid.
///
/// Input is a staging folder with `map.tsv` (tab-separated, header row: `attachment_guid`, `message_guid`, `kind`, `bytes`, `sha1`,
/// `sha256`, `from_me`, `sent_unix`, `relative_path`, `source`) and the files at `relative_path` under it (one folder per attachment guid,
/// so equal names never collide). For each row the message is found by `source_key = 'ios:<message guid>'` (a Mac chat.db row first, then any other iOS-keyed row such as an iPhone sms.db import, canonical rows before duplicates);
/// the file must hash to the map's SHA-256; it is stored content-addressed, an `attachment` row is added, `att_hash` is recomputed,
/// and the file's name is taken out of the message's `(… not on this Mac, offloaded to iCloud: …)` note. A note left with no names is
/// removed, and a message that was only that note stops being a `system` line. Idempotent: a message that already has an attachment
/// with the same SHA-256 is skipped. One transaction.
public struct AttachmentBackfillStats: Codable, Equatable, Sendable {
    public var rows = 0
    public var attached = 0
    public var alreadyThere = 0
    public var messageNotInArchive = 0
    public var fileMissing = 0
    public var hashMismatch = 0
    public var notesShortened = 0          // the name came out of the note, others remain
    public var notesCleared = 0            // the note had no names left
    public var systemLinesRestored = 0     // attachment-only system lines that now have an attachment (ordinary messages again)
    public var nameNotInNote = 0           // attached, but the note did not list this name (left as it was)
    public var onDuplicateRows = 0         // the chat.db row is a provenance duplicate (its canonical row is another source's)
    public var newFiles = 0, newBytes = 0
    public var byKind: [String: Int] = [:]
}

public enum AttachmentBackfill {
    static let notePrefixes = ["attachment not on this Mac, offloaded to iCloud: ", " attachments not on this Mac, offloaded to iCloud: "]

    public static func mime(forFilename name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "3gp": return "video/3gpp"
        case "caf": return "audio/x-caf"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "amr": return "audio/amr"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        default: return nil
        }
    }

    /// The note with `name` taken out of its list: nil when no names remain, the same note when `name` is not listed.
    public static func removing(_ name: String, from note: String) -> (note: String?, found: Bool) {
        if case .removed(let n) = noteRemoval(name, from: note) { return (n, true) }
        return (note, false)
    }

    public static func run(stagingDir: URL, into db: Database, root: ArchiveRoot, dryRun: Bool = false) throws -> AttachmentBackfillStats {
        var stats = AttachmentBackfillStats()
        let mapURL = stagingDir.appendingPathComponent("map.tsv")
        let text = try String(contentsOf: mapURL, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return stats }
        let header = lines.removeFirst().components(separatedBy: "\t")
        func col(_ n: String) throws -> Int {
            guard let i = header.firstIndex(of: n) else { throw ArchiveError("map.tsv has no \(n) column") }
            return i
        }
        let cMsg = try col("message_guid"), cKind = try col("kind"), cSha = try col("sha256"), cPath = try col("relative_path")
        let cBytes = try col("bytes")

        let store = MediaStore(root: root)
        let selMsg = try db.prepare("""
            SELECT m.id, m.note, m.kind, m.body, m.canonical_id FROM message m JOIN source s ON s.id = m.source_id
            WHERE m.source_key = ? ORDER BY (s.kind = 'macos-chatdb') DESC, (m.canonical_id IS NULL) DESC, m.id LIMIT 1
            """)
        let has = try db.prepare("SELECT 1 FROM attachment WHERE message_id = ? AND sha256 = ? LIMIT 1")
        let selMedia = try db.prepare("SELECT path FROM media WHERE sha256 = ?")
        let insMedia = try db.prepare("INSERT OR IGNORE INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
        let insAtt = try db.prepare("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (?,?,?,?,?,?)")
        let attShas = try db.prepare("SELECT sha256 FROM attachment WHERE message_id = ?")
        let upd = try db.prepare("UPDATE message SET note = ?, kind = ?, att_hash = ? WHERE id = ?")

        var attachedThisRun = Set<String>()
        try db.transaction {
            for line in lines {
                let f = line.components(separatedBy: "\t")
                guard f.count == header.count else { continue }
                stats.rows += 1
                selMsg.bind(1, "ios:" + f[cMsg])
                guard try selMsg.step() else { selMsg.reset(); stats.messageNotInArchive += 1; continue }
                let mid = selMsg.int(0), note = selMsg.string(1), kind = selMsg.string(2), body = selMsg.string(3)
                let isDuplicate = !selMsg.isNull(4)
                selMsg.reset()
                let file = stagingDir.appendingPathComponent(f[cPath])
                guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count > 0 else { stats.fileMissing += 1; continue }
                if let b = Int(f[cBytes]), b != data.count { stats.hashMismatch += 1; continue }
                let name = file.lastPathComponent
                let mime = mime(forFilename: name)
                let sha = data.withUnsafeBytes { Hashing.sha256Hex($0) }
                guard sha == f[cSha] else { stats.hashMismatch += 1; continue }
                has.bind(1, mid).bind(2, sha)
                let already = try has.step(); has.reset()
                if already {
                    // The same bytes twice on one message within this run: nothing more to store, but this second file's name
                    // still leaves the note. On a rerun the note was already edited, so it is left alone (two files can share a name).
                    stats.alreadyThere += 1
                    if !dryRun, attachedThisRun.contains("\(mid)\u{1}\(sha)"), let n = note {
                        let r = removing(name, from: n)
                        if r.found {
                            if r.note == nil { stats.notesCleared += 1 } else { stats.notesShortened += 1 }
                            let fix = try db.prepare("UPDATE message SET note = ? WHERE id = ?")
                            fix.bind(1, r.note).bind(2, mid)
                            try fix.run()
                        }
                    }
                    continue
                }
                if dryRun { stats.attached += 1; stats.byKind[f[cKind], default: 0] += 1; continue }
                let stored = try data.withUnsafeBytes { raw in
                    try store.store(raw, mime: mime, filename: name, lookup: { h in
                        selMedia.bind(1, h); defer { selMedia.reset() }
                        return (try? selMedia.step()) == true ? selMedia.string(0) : nil
                    })
                }
                if stored.wasNew { stats.newFiles += 1; stats.newBytes += stored.bytes }
                insMedia.bind(1, stored.sha256).bind(2, stored.relativePath).bind(3, stored.bytes).bind(4, mime)
                try insMedia.run()
                insAtt.bind(1, mid).bind(2, mime).bind(3, name).bind(4, stored.relativePath).bind(5, stored.bytes).bind(6, stored.sha256)
                try insAtt.run()
                stats.attached += 1
                attachedThisRun.insert("\(mid)\u{1}\(sha)")
                stats.byKind[f[cKind], default: 0] += 1
                if isDuplicate { stats.onDuplicateRows += 1 }

                // The importer's rule: a message is a `system` line only while it has no text and no attachment.
                var newNote = note, newKind = kind
                if kind == "system" && body == nil { newKind = nil; stats.systemLinesRestored += 1 }
                if let n = note {
                    let r = removing(name, from: n)
                    if r.found {
                        newNote = r.note
                        if r.note == nil { stats.notesCleared += 1 } else { stats.notesShortened += 1 }
                    } else { stats.nameNotInNote += 1 }
                } else { stats.nameNotInNote += 1 }
                var shas: [String] = []
                attShas.bind(1, mid)
                while try attShas.step() { if let s = attShas.string(0) { shas.append(s) } }
                attShas.reset()
                upd.bind(1, newNote).bind(2, newKind).bind(3, Hashing.attachmentHash(shas)).bind(4, mid)
                try upd.run()
            }
            if !dryRun && stats.attached > 0 {
                let ins = try db.prepare("INSERT OR IGNORE INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES ('attachments-backfill', ?, ?, ?, ?, ?)")
                ins.bind(1, stagingDir.path).bind(2, "attachments-backfill:" + (try Hashing.sha256Hex(ofFile: mapURL).hex))
                    .bind(3, Int64(stats.newBytes)).bind(4, Int64(Date().timeIntervalSince1970))
                    .bind(5, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self))
                try ins.run()
            }
        }
        return stats
    }
}

extension AttachmentBackfill {
    public enum NoteRemoval: Equatable, Sendable { case removed(String?), notListed, ambiguous }

    /// Takes `name` out of an offloaded-attachments note only when the note reads one way: the list is cut on ", "
    /// into every possible sequence of exactly the note's own count of names; the name is removed only if every reading lists it and
    /// every reading leaves the same remainder. A reading that never lists it: `notListed`; readings that disagree: `ambiguous` (the
    /// caller leaves the note exactly as it is).
    public static func noteRemoval(_ name: String, from note: String) -> NoteRemoval {
        guard note.hasPrefix("("), note.hasSuffix(")") else { return .notListed }
        let inner = String(note.dropFirst().dropLast())
        var listStart: String.Index?
        for p in notePrefixes { if let r = inner.range(of: p) { listStart = r.upperBound; break } }
        guard let start = listStart else { return .notListed }
        let list = String(inner[start...])
        let head = inner[..<start]
        let count = head.hasPrefix("attachment ") ? 1 : Int(head.prefix { $0.isNumber }) ?? 0
        guard count >= 1 else { return .notListed }
        let tokens = list.components(separatedBy: ", ")
        guard tokens.count >= count, tokens.count <= 64 else { return .ambiguous }
        // Every way to group the tokens into `count` consecutive names.
        var readings: [[String]] = []
        func split(_ from: Int, _ left: Int, _ acc: [String]) {
            if readings.count > 4096 { return }
            if left == 1 { readings.append(acc + [tokens[from...].joined(separator: ", ")]); return }
            for end in from..<(tokens.count - left + 1) { split(end + 1, left - 1, acc + [tokens[from...end].joined(separator: ", ")]) }
        }
        split(0, count, [])
        if readings.count > 4096 { return .ambiguous }
        let withName = readings.filter { $0.contains(name) }
        if withName.isEmpty { return .notListed }
        if withName.count != readings.count { return .ambiguous }
        let rests = Set(withName.map { r -> String in var x = r; x.remove(at: x.firstIndex(of: name)!); return x.joined(separator: ", ") })
        guard rests.count == 1, let rest = rests.first else { return .ambiguous }
        let left = count - 1
        if left == 0 { return .removed(nil) }
        return .removed("(\(left == 1 ? "attachment" : "\(left) attachments") not on this Mac, offloaded to iCloud: \(rest))")
    }
}
