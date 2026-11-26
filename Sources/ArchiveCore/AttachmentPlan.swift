import Foundation

/// Messages attachment files recovered and staged elsewhere go into the media store by a separate copy (for example on the machine
/// that holds the media), then are attached here without being read (the media mount may stay read-only; a sample is re-hashed). The plan is the one place that names
/// each file's media path, by `MediaStore`'s own rule, so the copy and the attach step cannot disagree.
///
/// Input TSV (header): device, msg_guid, att_guid, date, mime, bytes, sha256, staged_path (the sha256 is the stage's copy ledger's).
/// Each row gets: the file name; the mime the archive gives it (`AttachmentBackfill.mime(forFilename:)`, else the input's); the media
/// path (the one the media table already records for that sha256, else `media/<sha[:2]>/<sha>.<ext>`); whether the media table has
/// it; the target message (the canonical row of the guid's duplicate group, so the apps show the file); and a decision: attach,
/// already-attached (that message group has the file), repeat-in-plan (the same file for the same message again), message-not-in-archive.
public enum AttachmentPlan {
    public struct Row: Sendable {
        public var device: String, messageGUID: String, attachmentGUID: String, date: String
        public var bytes: Int, sha256: String, stagedPath: String
        public var filename: String, mime: String?, mediaPath: String, mediaPresent: Bool
        public var messageID: Int64?, decision: String
    }
    static let columns = ["device", "msg_guid", "att_guid", "date", "mime", "bytes", "sha256", "staged_path", "filename", "media_path",
                          "media_present", "message_id", "decision"]

    /// Tabs, newlines and backslashes inside a field are written as \\t, \\n, \\r, \\\\: a name can never split a row.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }
    public static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = "", it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n { case "t": out.append("\t"); case "n": out.append("\n"); case "r": out.append("\r"); default: out.append(n) }
        }
        return out
    }

    /// What the plan was made against: the archive's message count and its newest message, source and attachment ids.
    /// The attach step refuses a plan whose fingerprint is not the archive's now (another archive, or one imported into since).
    public static func fingerprint(_ db: Database) throws -> String {
        "messages=\(try db.scalarInt("SELECT count(*) FROM message"));max_message=\(try db.scalarInt("SELECT coalesce(max(id), 0) FROM message"))"
            + ";max_source=\(try db.scalarInt("SELECT coalesce(max(id), 0) FROM source"));max_attachment=\(try db.scalarInt("SELECT coalesce(max(id), 0) FROM attachment"))"
    }

    public static func make(input: URL, db: Database, root: ArchiveRoot) throws -> [Row] {
        let text = try String(contentsOf: input, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().components(separatedBy: "\t")
        func col(_ n: String) throws -> Int { guard let i = header.firstIndex(of: n) else { throw ArchiveError("plan input has no \(n) column") }; return i }
        let cDev = try col("device"), cMsg = try col("msg_guid"), cAtt = try col("att_guid"), cDate = try col("date"), cMime = try col("mime")
        let cBytes = try col("bytes"), cSha = try col("sha256"), cPath = try col("staged_path")
        let store = MediaStore(root: root)
        let selMedia = try db.prepare("SELECT path FROM media WHERE sha256 = ?")
        let selMsg = try db.prepare("SELECT coalesce(canonical_id, id) FROM message WHERE source_key = ? ORDER BY (canonical_id IS NULL) DESC, id LIMIT 1")
        // What the canonical row (the one the apps show) has decides, not a duplicate's attachments.
        let has = try db.prepare("SELECT 1 FROM attachment WHERE message_id = ?1 AND sha256 = ?2 LIMIT 1")
        var seen = Set<String>(), out: [Row] = [], pathOf: [String: String] = [:]
        for (n, line) in lines.enumerated() {
            let f = line.components(separatedBy: "\t").map(unescape)
            guard f.count == header.count else { throw ArchiveError("plan input line \(n + 2) has \(f.count) fields, not \(header.count)") }
            let name = (f[cPath] as NSString).lastPathComponent
            let sha = f[cSha].lowercased()
            let mime = AttachmentBackfill.mime(forFilename: name) ?? (f[cMime] == "-" || f[cMime].isEmpty ? nil : f[cMime])
            selMedia.bind(1, sha)
            let existing = try selMedia.step() ? selMedia.string(0) : nil
            selMedia.reset()
            // One path per sha256 for the whole plan (the store's, else the first name's).
            let path = existing ?? pathOf[sha] ?? store.relativePath(sha256: sha, ext: MediaStore.fileExtension(mime: mime, filename: name))
            pathOf[sha] = path
            selMsg.bind(1, "ios:" + f[cMsg])
            let mid: Int64? = try selMsg.step() ? selMsg.int(0) : nil
            selMsg.reset()
            var decision = "attach"
            if let mid {
                has.bind(1, mid).bind(2, sha)
                if try has.step() { decision = "already-attached" }
                has.reset()
            } else { decision = "message-not-in-archive" }
            // Keyed by the canonical row, not the guid: two guids of one duplicate group are one target (re-review B2).
            if decision == "attach", let mid, !seen.insert("\(mid)\u{1}\(sha)").inserted { decision = "repeat-in-plan" }
            out.append(Row(device: f[cDev], messageGUID: f[cMsg], attachmentGUID: f[cAtt], date: f[cDate], bytes: Int(f[cBytes]) ?? -1, sha256: sha,
                           stagedPath: f[cPath], filename: name, mime: mime, mediaPath: path, mediaPresent: existing != nil, messageID: mid, decision: decision))
        }
        if out.count != lines.count { throw ArchiveError("plan input: \(lines.count) lines but \(out.count) rows") }
        return out
    }

    /// A digest of the plan's target messages as they are (re-review C): per distinct (message id, guid), the row's id, the guid, its
    /// canonical id, att_hash, note and kind, in id order. The attach step recomputes it inside its transaction and refuses any change.
    public static func targetDigest(_ rows: [Row], db: Database) throws -> String {
        let st = try db.prepare("SELECT id, canonical_id, att_hash, note, kind FROM message WHERE id = ?")
        var lines: [String] = []
        for (id, guid) in Set(rows.compactMap { r in r.messageID.map { ($0, r.messageGUID) } }.map { "\($0.0)\u{1}\($0.1)" }).sorted().map({ k -> (Int64, String) in
            let p = k.split(separator: "\u{1}", maxSplits: 1); return (Int64(p[0])!, String(p[1])) }) {
            st.bind(1, id)
            if try st.step() {
                lines.append([String(st.int(0)), guid, st.optInt(1).map(String.init) ?? "", st.optInt(2).map(String.init) ?? "",
                              escape(st.string(3) ?? "\u{0}"), st.string(4) ?? "\u{0}"].joined(separator: "|"))
            } else { lines.append("\(id)|\(guid)|missing") }
            st.reset()
        }
        return Data(lines.joined(separator: "\n").utf8).withUnsafeBytes { Hashing.sha256Hex($0) }
    }

    /// The plan file: `#archive<TAB><fingerprint>`, `#targets<TAB><digest>`, the header, one escaped line per row, `#rows<TAB><n>`.
    public static func write(_ rows: [Row], to url: URL, db: Database) throws {
        var s = "#archive\t" + (try fingerprint(db)) + "\n#targets\t" + (try targetDigest(rows, db: db)) + "\n" + columns.joined(separator: "\t") + "\n"
        for r in rows {
            s += [r.device, r.messageGUID, r.attachmentGUID, r.date, r.mime ?? "-", String(r.bytes), r.sha256, r.stagedPath, r.filename,
                  r.mediaPath, r.mediaPresent ? "1" : "0", r.messageID.map(String.init) ?? "", r.decision].map(escape).joined(separator: "\t") + "\n"
        }
        s += "#rows\t\(rows.count)\n"
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func read(_ url: URL) throws -> [Row] { try readPlan(url).rows }

    /// Every line must be a whole row and the count must match the trailer: nothing can vanish silently.
    public static func readPlan(_ url: URL) throws -> (rows: [Row], fingerprint: String, targets: String) {
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 4, lines[0].hasPrefix("#archive\t"), lines[1].hasPrefix("#targets\t"), lines[2].components(separatedBy: "\t") == columns,
              let last = lines.last, last.hasPrefix("#rows\t"), let n = Int(last.dropFirst(6)) else { throw ArchiveError("\(url.path) is not an attachments plan") }
        let fp = String(lines[0].dropFirst(9)), targets = String(lines[1].dropFirst(9))
        lines = Array(lines[3..<(lines.count - 1)])
        guard lines.count == n else { throw ArchiveError("\(url.path): \(lines.count) rows, the trailer says \(n)") }
        let rows = try lines.enumerated().map { (i, l) -> Row in
            let f = l.components(separatedBy: "\t").map(unescape)
            guard f.count == columns.count else { throw ArchiveError("\(url.path) row \(i + 1) has \(f.count) fields") }
            return Row(device: f[0], messageGUID: f[1], attachmentGUID: f[2], date: f[3], bytes: Int(f[5]) ?? -1, sha256: f[6], stagedPath: f[7],
                       filename: f[8], mime: f[4] == "-" ? nil : f[4], mediaPath: f[9], mediaPresent: f[10] == "1", messageID: Int64(f[11]), decision: f[12])
        }
        return (rows, fp, targets)
    }

    /// What the plan would do to notes (re-review B: the list read before the go): per target message in plan order, every name the
    /// plan recovers taken out with the same rule the attach step uses; `changed` and `ambiguous` lines only.
    public static func notePreview(_ rows: [Row], db: Database) throws -> [(messageID: Int64, oldNote: String, newNote: String?, status: String)] {
        let st = try db.prepare("SELECT note FROM message WHERE id = ?")
        var notes: [Int64: String?] = [:], original: [Int64: String] = [:], order: [Int64] = [], ambiguous = Set<Int64>()
        for r in rows where r.decision != "message-not-in-archive" {
            guard let mid = r.messageID else { continue }
            if notes[mid] == nil {
                st.bind(1, mid); let n = try st.step() ? st.string(0) : nil; st.reset()
                notes[mid] = .some(n); if let n { original[mid] = n; order.append(mid) }
            }
            guard let cur = notes[mid] ?? nil else { continue }
            switch AttachmentBackfill.noteRemoval(r.filename, from: cur) {
            case .removed(let n): notes[mid] = .some(n)
            case .ambiguous: ambiguous.insert(mid)
            case .notListed: break
            }
        }
        return order.compactMap { mid in
            let old = original[mid]!, new = notes[mid] ?? nil
            if ambiguous.contains(mid) { return (mid, old, new, new == old ? "ambiguous-left" : "changed-and-ambiguous-left") }
            return new == old ? nil : (mid, old, new, "changed")
        }
    }
}

public struct AttachmentPlanReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64
    public var stats: AttachmentBackfillStats
}

extension AttachmentBackfill {
    /// Attaches the plan's `attach` rows whose file is already in the media store (copied there on the NAS's side). Before anything is
    /// written, EVERY file is checked: present at its media path, the plan's size, and hashing to the plan's sha256 (re-review A: no
    /// sample). Inside one BEGIN IMMEDIATE transaction: the archive's fingerprint and the digest of the target messages must equal the
    /// plan's, and every row's message must be the canonical row of a group carrying its guid (re-review C); then `media` and `attachment`
    /// rows, `att_hash`, and the recovered names out of the offloaded notes, only where the note reads one way (an ambiguous note is left
    /// exactly as it is and ledgered `note-ambiguous-left`). Repeat rows (the same file for the same canonical row) clean their name too.
    /// Pre-existing rows change only in note, kind and att_hash of the targets; the ledger has a line per plan row with the old and new
    /// note and kind, is stored with the import (`import_ledger`) and published after COMMIT; a rerun is "already imported".
    public static func runPlan(plan url: URL, into db: Database, root: ArchiveRoot, ledger: URL? = nil, origin: String? = nil) throws -> AttachmentPlanReport {
        let (rows, planFP, planTargets) = try AttachmentPlan.readPlan(url)
        let (planSHA, _) = try Hashing.sha256Hex(ofFile: url)
        let key = "attachments-plan:" + planSHA
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let id = seen.int(0)
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(AttachmentBackfillStats.self, from: Data($0.utf8)) } ?? AttachmentBackfillStats()
            seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return AttachmentPlanReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()
        // Every file, whole: present, the plan's size and sha256 (all or nothing, before the transaction).
        var missing = 0, wrongSize = 0, wrongHash = 0, checked = Set<String>()
        for r in rows where r.decision == "attach" && checked.insert(r.mediaPath).inserted {
            let file = root.resolve(relativePath: r.mediaPath)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { missing += 1; continue }
            guard size == r.bytes else { wrongSize += 1; continue }
            let (h, _) = try Hashing.sha256Hex(ofFile: file)
            if h != r.sha256 { wrongHash += 1 }
        }
        guard missing == 0, wrongSize == 0, wrongHash == 0 else {
            throw ArchiveError("not every file is in the media store as planned: \(missing) missing, \(wrongSize) of another size, \(wrongHash) with another sha256; nothing written")
        }
        var stats = AttachmentBackfillStats()
        var out = ["msg_guid\tatt_guid\tsha256\tmedia_path\tdecision\tmessage_id\tattachment_id\told_kind\tnew_kind\told_note\tnew_note"]
        func clean(_ s: String?) -> String { AttachmentPlan.escape(s ?? "") }
        var report: AttachmentPlanReport!
        try db.transaction {
            // Inside BEGIN IMMEDIATE: nothing can change the targets between these checks and the writes.
            let now = try AttachmentPlan.fingerprint(db)
            guard planFP == now else { throw ArchiveError("the plan was made against another archive state (\(planFP)); this archive is \(now): make the plan again") }
            guard try AttachmentPlan.targetDigest(rows, db: db) == planTargets else { throw ArchiveError("a target message changed since the plan was made: make the plan again") }
            let carries = try db.prepare("SELECT 1 FROM message m WHERE m.source_key = ? AND coalesce(m.canonical_id, m.id) = ? AND (SELECT canonical_id FROM message c WHERE c.id = ?) IS NULL LIMIT 1")
            for r in rows where r.messageID != nil {
                carries.bind(1, "ios:" + r.messageGUID).bind(2, r.messageID!).bind(3, r.messageID!)
                let ok = try carries.step(); carries.reset()
                guard ok else { throw ArchiveError("plan row \(r.attachmentGUID): message \(r.messageID!) is not the canonical row of the guid \(r.messageGUID): refused") }
            }
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES ('attachments-backfill', ?, ?, 0, ?, NULL)")
            ins.bind(1, origin ?? url.path).bind(2, key).bind(3, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let row = try db.prepare("SELECT note, kind, body FROM message WHERE id = ?")
            let has = try db.prepare("SELECT 1 FROM attachment WHERE message_id = ? AND sha256 = ? LIMIT 1")
            let insMedia = try db.prepare("INSERT OR IGNORE INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
            let insAtt = try db.prepare("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (?,?,?,?,?,?)")
            let attShas = try db.prepare("SELECT sha256 FROM attachment WHERE message_id = ?")
            let upd = try db.prepare("UPDATE message SET note = ?, kind = ?, att_hash = ? WHERE id = ?")
            let setNote = try db.prepare("UPDATE message SET note = ? WHERE id = ?")
            for r in rows {
                stats.rows += 1
                func log(_ d: String, _ mid: Int64? = nil, _ aid: Int64? = nil, _ ok: String? = nil, _ nk: String? = nil, _ on: String? = nil, _ nn: String? = nil) {
                    out.append([r.messageGUID, r.attachmentGUID, r.sha256, r.mediaPath, d, mid.map(String.init) ?? "", aid.map(String.init) ?? "",
                                clean(ok), clean(nk), clean(on), clean(nn)].joined(separator: "\t"))
                }
                guard let mid = r.messageID, r.decision != "message-not-in-archive" else { stats.messageNotInArchive += 1; log(r.decision); continue }
                row.bind(1, mid)
                guard try row.step() else { row.reset(); throw ArchiveError("message \(mid) vanished inside the transaction") }
                let note = row.string(0), kind = row.string(1), body = row.string(2)
                row.reset()
                has.bind(1, mid).bind(2, r.sha256)
                let already = try has.step(); has.reset()
                var aid: Int64? = nil, newKind = kind, shasChanged = false
                if r.decision == "attach" && !already {
                    insMedia.bind(1, r.sha256).bind(2, r.mediaPath).bind(3, r.bytes).bind(4, r.mime)
                    try insMedia.run()
                    if db.changes > 0 { stats.newFiles += 1; stats.newBytes += r.bytes }
                    insAtt.bind(1, mid).bind(2, r.mime).bind(3, r.filename).bind(4, r.mediaPath).bind(5, r.bytes).bind(6, r.sha256)
                    try insAtt.run()
                    aid = db.lastInsertRowID
                    stats.attached += 1
                    stats.byKind[r.mime.map { String($0.prefix { $0 != "/" }) } ?? "file", default: 0] += 1
                    if kind == "system" && body == nil { newKind = nil; stats.systemLinesRestored += 1 }
                    shasChanged = true
                } else {
                    stats.alreadyThere += 1
                    guard already else { log(r.decision + "-file-not-on-message", mid); continue }   // a repeat whose file is not there: nothing to clean
                }
                // The name leaves the note only when the note reads one way.
                var newNote = note, decision = aid != nil ? "attached" : r.decision
                if let n = note {
                    switch noteRemoval(r.filename, from: n) {
                    case .removed(let x): newNote = x; if x == nil { stats.notesCleared += 1 } else { stats.notesShortened += 1 }
                        if aid == nil { decision += "-note-cleaned" }
                    case .ambiguous: decision += "-note-ambiguous-left"
                    case .notListed: stats.nameNotInNote += 1
                    }
                } else { stats.nameNotInNote += 1 }
                if shasChanged {
                    var shas: [String] = []
                    attShas.bind(1, mid)
                    while try attShas.step() { if let s = attShas.string(0) { shas.append(s) } }
                    attShas.reset()
                    upd.bind(1, newNote).bind(2, newKind).bind(3, Hashing.attachmentHash(shas)).bind(4, mid)
                    try upd.run()
                } else if newNote != note {
                    setNote.bind(1, newNote).bind(2, mid)
                    try setNote.run()
                }
                log(decision, mid, aid, kind, newKind, note, newNote)
            }
            let st = try db.prepare("UPDATE source SET stats_json = ?, bytes = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, Int64(stats.newBytes)).bind(3, sid)
            try st.run()
            try ImportLedger.save(db, sourceID: sid, body: out.joined(separator: "\n") + "\n")
            report = AttachmentPlanReport(status: .imported, sourceID: sid, stats: stats)
        }
        if let ledger, let body = try ImportLedger.load(db, sourceID: report.sourceID) { try ImportLedger.publish(body, to: ledger) }
        return report
    }
}
