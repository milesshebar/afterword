import Foundation

public struct ArchiveStats {
    public struct SourceRow { public var id: Int64; public var kind: String; public var path: String; public var messages: Int; public var duplicates: Int; public var importedAt: Int64 }
    public var sources: [SourceRow] = []
    public var totalRows = 0
    public var canonicalRows = 0
    public var byService: [(String, Int)] = []
    public var byYear: [(String, Int)] = []
    public var threads = 0
    public var groupThreads = 0
    public var handles = 0
    public var contactNames = 0
    public var contactNamesByOrigin: [(String, Int)] = []
    public var attachmentRows = 0
    public var mediaFiles = 0
    public var mediaBytes: Int64 = 0
    /// GroupMe (canonical rows unless noted); `threads` is 0 when the archive has none.
    public struct GroupMeSummary { public var threads = 0, groups = 0, messages = 0, systemRows = 0, reactions = 0, attachments = 0, people = 0
        public var firstTsMs: Int64?, lastTsMs: Int64? }
    public var groupme = GroupMeSummary()
    /// Skype and WhatsApp: the same shape (`people` counts the service's handles; `reactions` is 0 for Skype).
    public var skype = GroupMeSummary()
    public var whatsapp = GroupMeSummary()
    public var snapchat = GroupMeSummary()
    public var metaThreads = 0, metaHiddenThreads = 0, systemRows = 0, reactions = 0

    /// Counts are of canonical rows (what the UI shows) unless noted.
    public static func collect(db: Database) throws -> ArchiveStats {
        var s = ArchiveStats()
        let src = try db.prepare("""
            SELECT s.id, s.kind, s.path, s.imported_at, count(m.id), sum(m.canonical_id IS NOT NULL)
            FROM source s LEFT JOIN message m ON m.source_id = s.id GROUP BY s.id ORDER BY s.id
            """)
        while try src.step() {
            s.sources.append(SourceRow(id: src.int(0), kind: src.string(1) ?? "", path: src.string(2) ?? "",
                                       messages: Int(src.int(4)), duplicates: Int(src.int(5)), importedAt: src.int(3)))
        }
        s.totalRows = Int(try db.scalarInt("SELECT count(*) FROM message"))
        s.canonicalRows = Int(try db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL"))
        let sv = try db.prepare("SELECT service, count(*) FROM message WHERE canonical_id IS NULL GROUP BY service ORDER BY 2 DESC")
        while try sv.step() { s.byService.append((sv.string(0) ?? "", Int(sv.int(1)))) }
        let yr = try db.prepare("""
            SELECT strftime('%Y', ts_ms / 1000, 'unixepoch') y, count(*) FROM message WHERE canonical_id IS NULL GROUP BY y ORDER BY y
            """)
        while try yr.step() { s.byYear.append((yr.string(0) ?? "?", Int(yr.int(1)))) }
        s.threads = Int(try db.scalarInt("SELECT count(*) FROM thread"))
        s.groupThreads = Int(try db.scalarInt("SELECT count(*) FROM thread WHERE is_group = 1"))
        s.handles = Int(try db.scalarInt("SELECT count(*) FROM handle"))
        s.contactNames = Int(try db.scalarInt("SELECT count(*) FROM contact_name"))
        let co = try db.prepare("SELECT origin, count(*) FROM contact_name GROUP BY origin ORDER BY 2 DESC")
        while try co.step() { s.contactNamesByOrigin.append((co.string(0) ?? "", Int(co.int(1)))) }
        s.attachmentRows = Int(try db.scalarInt("SELECT count(*) FROM attachment"))
        s.mediaFiles = Int(try db.scalarInt("SELECT count(*) FROM media"))
        s.mediaBytes = try db.scalarInt("SELECT coalesce(sum(bytes),0) FROM media")
        s.metaThreads = Int(try db.scalarInt("SELECT count(*) FROM thread WHERE service IS NOT NULL"))
        s.metaHiddenThreads = Int(try db.scalarInt("SELECT count(*) FROM thread WHERE hidden = 1"))
        s.systemRows = Int(try db.scalarInt("SELECT count(*) FROM message WHERE kind IS NOT NULL AND canonical_id IS NULL"))
        s.reactions = Int(try db.scalarInt("SELECT count(*) FROM reaction"))
        func summary(service: String, handleKind: String) throws -> GroupMeSummary {
            var g = GroupMeSummary()
            g.threads = Int(try db.scalarInt("SELECT count(*) FROM thread WHERE service = '\(service)'"))
            guard g.threads > 0 else { return g }
            g.groups = Int(try db.scalarInt("SELECT count(*) FROM thread WHERE service = '\(service)' AND is_group = 1"))
            let q = try db.prepare("""
                SELECT count(*), coalesce(sum(m.kind IS NOT NULL), 0), min(m.ts_ms), max(m.ts_ms)
                FROM message m WHERE m.service = '\(service)' AND m.canonical_id IS NULL
                """)
            if try q.step() { g.messages = Int(q.int(0)); g.systemRows = Int(q.int(1)); g.firstTsMs = q.optInt(2); g.lastTsMs = q.optInt(3) }
            q.reset()
            g.reactions = Int(try db.scalarInt("SELECT count(*) FROM reaction r JOIN message m ON m.id = r.message_id WHERE m.service = '\(service)' AND m.canonical_id IS NULL"))
            g.attachments = Int(try db.scalarInt("SELECT count(*) FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.service = '\(service)' AND m.canonical_id IS NULL"))
            g.people = Int(try db.scalarInt("SELECT count(*) FROM handle WHERE kind = '\(handleKind)'"))
            return g
        }
        s.groupme = try summary(service: "groupme", handleKind: "groupme-user")
        s.skype = try summary(service: "skype", handleKind: "skype-user")
        s.whatsapp = try summary(service: "whatsapp", handleKind: "whatsapp-user")
        s.snapchat = try summary(service: "snapchat", handleKind: "snapchat-user")
        return s
    }
}

public struct VerifyResult {
    public var lines: [String] = []
    public var failures = 0
    mutating func ok(_ s: String) { lines.append("ok    \(s)") }
    mutating func fail(_ s: String) { lines.append("FAIL  \(s)"); failures += 1 }
    mutating func note(_ s: String) { lines.append("note  \(s)") }
    public var passed: Bool { failures == 0 }
}

public enum ArchiveVerifier {
    public static func run(db: Database, root: ArchiveRoot) throws -> VerifyResult {
        var r = VerifyResult()

        let ic = try db.scalarString("PRAGMA integrity_check") ?? "?"
        ic == "ok" ? r.ok("sqlite integrity_check") : r.fail("sqlite integrity_check: \(ic)")

        let fk = try db.prepare("PRAGMA foreign_key_check")
        var fkn = 0
        while try fk.step() { fkn += 1 }
        fkn == 0 ? r.ok("foreign keys") : r.fail("\(fkn) foreign key violation(s)")

        // FTS: external-content tables report content-table counts, so compare the index's own docsize rows and run
        // FTS5's built-in content/index comparison.
        let messages = try db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL")
        let indexed = try db.scalarInt("SELECT count(*) FROM message_fts_docsize")
        indexed == messages ? r.ok("FTS rows \(indexed) == canonical messages \(messages)") : r.fail("FTS rows \(indexed) != canonical messages \(messages)")
        do {
            try db.exec("INSERT INTO message_fts(message_fts, rank) VALUES ('integrity-check', 1)")
            r.ok("FTS index matches content")
        } catch { r.fail("FTS integrity-check: \(error)") }

        // Canonical chains: a canonical_id must point at a canonical row, never at itself.
        let bad = try db.scalarInt("""
            SELECT count(*) FROM message m JOIN message c ON c.id = m.canonical_id WHERE c.canonical_id IS NOT NULL OR c.id = m.id
            """)
        bad == 0 ? r.ok("canonical chains are flat") : r.fail("\(bad) message(s) point at a non-canonical row")

        // Media: rows vs files vs references.
        let fm = FileManager.default
        var missing = 0, wrongSize = 0, absolute = 0
        let media = try db.prepare("SELECT path, bytes FROM media")
        var known = Set<String>()
        while try media.step() {
            let p = media.string(0) ?? ""
            known.insert(p)
            if p.hasPrefix("/") || p.contains("..") { absolute += 1; continue }
            let u = root.resolve(relativePath: p)
            if let attr = try? fm.attributesOfItem(atPath: u.path), let size = attr[.size] as? NSNumber {
                if size.int64Value != media.int(1) { wrongSize += 1 }
            } else { missing += 1 }
        }
        missing == 0 ? r.ok("all media files present") : r.fail("\(missing) media file(s) missing on disk")
        wrongSize == 0 ? r.ok("media sizes match") : r.fail("\(wrongSize) media file(s) with wrong size")
        let attAbs = try db.scalarInt("SELECT count(*) FROM attachment WHERE media_path LIKE '/%' OR media_path LIKE '%..%'")
        (absolute + Int(attAbs)) == 0 ? r.ok("all stored paths are root-relative") : r.fail("\(absolute + Int(attAbs)) absolute stored path(s); archive is not relocatable")
        let attMismatch = try db.scalarInt("SELECT count(*) FROM attachment a JOIN media m ON m.sha256 = a.sha256 WHERE a.media_path != m.path")
        attMismatch == 0 ? r.ok("attachment paths agree with media table") : r.fail("\(attMismatch) attachment(s) disagree with the media table")

        var orphanFiles = 0
        let mediaBase = root.mediaURL.resolvingSymlinksInPath().path     // enumerator yields symlink-resolved paths
        if let en = fm.enumerator(at: root.mediaURL.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in en {
                let isFile = (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if !isFile { continue }
                let rel = ArchiveRoot.mediaDirName + "/" + u.resolvingSymlinksInPath().path.dropFirst(mediaBase.count + 1)
                if !known.contains(rel) { orphanFiles += 1 }
            }
        }
        orphanFiles == 0 ? r.ok("no orphan media files") : r.note("\(orphanFiles) media file(s) on disk not in the media table (left by an interrupted import; safe to delete)")
        // A media row is used by a message attachment, a post's photo or video (post_media) or a recording (its own audio or its playable copy).
        var unusedSQL = "SELECT count(*) FROM media m WHERE NOT EXISTS (SELECT 1 FROM attachment a WHERE a.sha256 = m.sha256)"
        if try db.tableExists("post_media") { unusedSQL += " AND NOT EXISTS (SELECT 1 FROM post_media p WHERE p.sha256 = m.sha256)" }
        if try db.tableExists("recording") {
            let chat = try db.hasColumn("recording", "chat_sha256") ? " OR g.chat_sha256 = m.sha256" : ""
            unusedSQL += " AND NOT EXISTS (SELECT 1 FROM recording g WHERE g.sha256 = m.sha256 OR g.play_sha256 = m.sha256\(chat))"
        }
        // and a voice message's playable copy (its own audio is an attachment's)
        if try db.tableExists("voice_message") { unusedSQL += " AND NOT EXISTS (SELECT 1 FROM voice_message v WHERE v.play_sha256 = m.sha256)" }
        let unreferenced = try db.scalarInt(unusedSQL)
        unreferenced == 0 ? r.ok("no unreferenced media rows") : r.fail("\(unreferenced) media row(s) that no attachment, post, recording or voice message uses")

        // Voicemails and voice memos: flat duplicate chains, the search index one row per canonical recording, transcripts of audio the table has.
        if try db.tableExists("recording") {
            let recordings = try db.scalarInt("SELECT count(*) FROM recording WHERE canonical_id IS NULL")
            let deep = try db.scalarInt("SELECT count(*) FROM recording g JOIN recording c ON c.id = g.canonical_id WHERE c.canonical_id IS NOT NULL OR c.id = g.id")
            deep == 0 ? r.ok("recordings: duplicate chains are flat") : r.fail("\(deep) recording(s) point at a non-canonical row")
            let indexed = try db.scalarInt("SELECT count(*) FROM recording_fts")
            indexed == recordings ? r.ok("recordings: search rows \(indexed) == canonical recordings \(recordings)") : r.fail("recordings: search rows \(indexed) != canonical recordings \(recordings)")
            // a transcript is of a recording's audio or of a voice message's (an attachment's audio, VoiceMessageImporter)
            let voice = try db.tableExists("voice_message") ? " AND NOT EXISTS (SELECT 1 FROM voice_message v WHERE v.sha256 = t.sha256)" : ""
            let stray = try db.scalarInt("SELECT count(*) FROM recording_transcript t WHERE NOT EXISTS (SELECT 1 FROM recording g WHERE g.sha256 = t.sha256)" + voice)
            stray == 0 ? r.ok("recordings: every transcript is of a recording's or a voice message's audio") : r.fail("\(stray) transcript(s) of audio no recording or voice message has")
        }
        // Voice messages: each is an attachment's audio on a canonical message, has its machine transcript, and the search index holds one row
        // per voice message with words.
        if try db.tableExists("voice_message") {
            let orphan = try db.scalarInt("""
                SELECT count(*) FROM voice_message v WHERE NOT EXISTS (SELECT 1 FROM attachment a JOIN message m ON m.id = a.message_id
                WHERE a.sha256 = v.sha256 AND m.canonical_id IS NULL)
                """)
            orphan == 0 ? r.ok("voice messages: each is the audio of a canonical message") : r.fail("\(orphan) voice message(s) whose audio no canonical message carries")
            let untranscribed = try db.scalarInt("SELECT count(*) FROM voice_message v WHERE NOT EXISTS (SELECT 1 FROM recording_transcript t WHERE t.sha256 = v.sha256 AND t.origin = 'machine')")
            untranscribed == 0 ? r.ok("voice messages: each has its machine transcript") : r.fail("\(untranscribed) voice message(s) without a machine transcript")
            // each search row names a voice message with words (a machine transcript, of any model, that is not empty), once
            let hasWords = "EXISTS (SELECT 1 FROM recording_transcript t WHERE t.sha256 = v.sha256 AND t.origin = 'machine' AND t.text <> '')"
            let strayRefs = try db.scalarInt("SELECT count(*) FROM voice_message_fts f LEFT JOIN voice_message v ON v.sha256 = f.ref WHERE v.sha256 IS NULL OR NOT \(hasWords)")
            let repeated = try db.scalarInt("SELECT count(*) - count(DISTINCT ref) FROM voice_message_fts")
            strayRefs == 0 && repeated == 0 ? r.ok("voice messages: every search row is one voice message with words")
                : r.fail("voice messages: \(strayRefs) search row(s) naming no voice message with words, \(repeated) repeated")
            let worded = try db.scalarInt("SELECT count(*) FROM voice_message v WHERE \(hasWords)")
            let indexed = try db.scalarInt("SELECT count(*) FROM voice_message_fts")
            indexed == worded ? r.ok("voice messages: search rows \(indexed) == voice messages with words \(worded)") : r.fail("voice messages: search rows \(indexed) != voice messages with words \(worded)")
        }

        // People (stage B): the stored automatic matching must be internally consistent.
        if PeopleStore.hasTables(db) {
            let persons = try db.scalarInt("SELECT count(*) FROM person")
            if persons > 0 {
                let badCount = try db.scalarInt("SELECT count(*) FROM person p WHERE p.handle_count != (SELECT count(*) FROM person_handle h WHERE h.person_id = p.id)")
                badCount == 0 ? r.ok("people: \(persons) persons, handle counts agree") : r.fail("\(badCount) person(s) whose handle_count disagrees with person_handle")
                let anchor = try db.scalarInt("SELECT count(*) FROM person p WHERE p.id != (SELECT min(handle_id) FROM person_handle h WHERE h.person_id = p.id)")
                anchor == 0 ? r.ok("people: every person id is its smallest handle id") : r.fail("\(anchor) person id(s) are not their smallest handle id")
            } else { r.note("people: not matched yet (run `archivectl people match`)") }
        }
        if FileManager.default.fileExists(atPath: PeopleOverrides.fileURL(root: root).path) {
            r.ok("people.sqlite readable (\(PeopleOverrides.read(root: root).count) correction rows)")
        }
        return r
    }
}
