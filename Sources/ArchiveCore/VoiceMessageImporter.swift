import Foundation

/// Voice messages on threads: an iMessage audio message, a WhatsApp voice note, a
/// Messenger or Instagram voice clip, MMS audio, or a Voice Memos recording sent into a thread.
///
/// The message stays the message: nothing in `message` or `attachment` changes. What this adds is beside it, keyed by the attachment's
/// audio (its sha256), as the recordings are:
///   - `recording_transcript` (RecordingImporter's table, keyed by the audio's sha256): the machine transcript of those bytes, origin
///     `machine`. A transcript belongs to the bytes, so the same audio sent twice has one.
///   - `voice_message`: one row per transcribed audio file: what a browser plays (`play_sha256`: the file itself, or an AAC copy of a format
///     browsers do not play: Opus in CAF, AMR, Ogg Opus), its length, and whether the transcriber heard words.
///   - `voice_message_fts`: the transcripts, for search (`ref` = the audio's sha256; a hit is shown at every canonical message carrying it).
///
/// Input is a plan (`voice-messages.tsv`, made by your own survey of the threads' audio) and the transcript folder. Before anything is written: every
/// planned audio file must be an attachment of a canonical message whose media row has the plan's path and size, every file the plan
/// names (the audio and its playable copy) is read whole from the media store and must have the plan's size and sha256, and every
/// transcript file must hash to the plan's value and name its audio. Any failure refuses the whole plan. Additive tables, created here
/// (`CREATE TABLE IF NOT EXISTS`, no version bump), so the deployed web app of an older build reads the archive unchanged.
///
/// Idempotent: a plan already imported (by its sha256) is "already imported"; a row already there with the same values is left alone,
/// with other values it refuses the plan.
public struct VoiceMessageImportStats: Codable, Equatable, Sendable {
    public var planRows = 0
    public var written = 0
    public var alreadyThere = 0
    public var withWords = 0, noWords = 0                 // of the rows written this run
    public var playableCopies = 0                         // rows written whose playable file is a copy
    public var newMediaRows = 0
    public var newMediaBytes: Int64 = 0
    public var transcripts = 0, transcriptsAlready = 0     // already: the same audio had a machine transcript by the same model
    public var messages = 0                               // canonical messages carrying the rows written this run
    public var totalRows = 0                              // in the table after this run
}

public struct VoiceMessageImportReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64?
    public var stats: VoiceMessageImportStats
}

public enum VoiceMessageImporter {
    public static let sourceKind = "voice-messages-plan"
    static let contents: Set<String> = ["speech", "no-speech"]

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS voice_message (
            sha256 TEXT PRIMARY KEY REFERENCES media(sha256),     -- the attachment's audio (attachment.sha256); the transcript is keyed by it
            play_sha256 TEXT NOT NULL REFERENCES media(sha256),   -- what a browser plays: the same file, or an AAC copy (Opus in CAF, AMR, Ogg)
            duration_s REAL NOT NULL DEFAULT 0,
            content TEXT,                                         -- speech | no-speech (the transcriber heard no words)
            source_id INTEGER NOT NULL REFERENCES source(id)
        )
        """,
        "CREATE VIRTUAL TABLE IF NOT EXISTS voice_message_fts USING fts5(body, ref UNINDEXED, tokenize='unicode61 remove_diacritics 2')",
    ]

    public static func ensureTables(_ db: Database) throws {
        try RecordingImporter.ensureTables(db)                   // recording_transcript lives there
        for s in tableSQL { try db.exec(s) }
    }

    static let ledgerHeader = "rid\tsha256\tdecision\tplay_sha256\tnew_media\ttranscript\tcontent\tmessages"

    struct Row {
        var line: Int
        var rid = "", sha = "", target = "", playSha = "", playMime = "", playTarget = "", content = "", transcriptSha = ""
        var bytes: Int64 = 0, playBytes: Int64 = 0
        var duration = 0.0
    }

    static func readPlan(_ url: URL) throws -> [Row] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { throw ArchiveError("the plan is empty") }
        let header = lines.removeFirst().components(separatedBy: "\t")
        func col(_ n: String) throws -> Int {
            guard let i = header.firstIndex(of: n) else { throw ArchiveError("the plan has no \(n) column") }
            return i
        }
        let c = try (rid: col("rid"), sha: col("sha256"), bytes: col("bytes"), target: col("target_path"), playSha: col("play_sha256"),
                     playBytes: col("play_bytes"), playMime: col("play_mime"), playTarget: col("play_target_path"), duration: col("duration_s"),
                     content: col("content"), transcript: col("transcript_sha256"))
        var out: [Row] = []
        var rids = Set<String>(), shas = Set<String>()
        for (i, line) in lines.enumerated() {
            let f = line.components(separatedBy: "\t")
            let n = i + 2
            func bad(_ why: String) -> ArchiveError { ArchiveError("plan line \(n): \(why); nothing written") }
            guard f.count == header.count else { throw bad("\(f.count) fields, the header has \(header.count)") }
            var r = Row(line: n)
            r.rid = f[c.rid]; r.sha = f[c.sha]; r.target = f[c.target]; r.playSha = f[c.playSha]; r.playMime = f[c.playMime]
            r.playTarget = f[c.playTarget]; r.content = f[c.content]; r.transcriptSha = f[c.transcript]
            guard !r.rid.isEmpty, rids.insert(r.rid).inserted else { throw bad("rid '\(r.rid)' is empty or named twice") }
            guard RecordingImporter.isHex(r.sha, 64), shas.insert(r.sha).inserted else { throw bad("the audio's sha256 is malformed or named twice") }
            guard let b = Int64(f[c.bytes]), b > 0, RecordingImporter.storeName(r.sha, r.target) else { throw bad("the audio needs its size and the store's own path for it") }
            r.bytes = b
            guard RecordingImporter.isHex(r.playSha, 64), let pb = Int64(f[c.playBytes]), pb > 0, RecordingImporter.storeName(r.playSha, r.playTarget) else {
                throw bad("the audio needs a playable file (its own, or a copy): sha256, size and the store's own path")
            }
            r.playBytes = pb
            if r.playSha == r.sha { guard pb == b, r.playTarget == r.target else { throw bad("the playable file is the audio itself but its size or path differ") } }
            guard let d = Double(f[c.duration]), d >= 0, d <= RecordingImporter.maxDuration else { throw bad("duration_s '\(f[c.duration])'") }
            r.duration = d
            guard contents.contains(r.content) else { throw bad("content '\(r.content)' is not speech or no-speech") }
            guard RecordingImporter.isHex(r.transcriptSha, 64) else { throw bad("every row names its transcript by the sha256 of its JSON file") }
            out.append(r)
        }
        return out
    }

    public static func run(plan url: URL, transcripts: URL, into db: Database, root: ArchiveRoot, dryRun: Bool = false, ledger: URL? = nil,
                           origin: String? = nil) throws -> VoiceMessageImportReport {
        let rows = try readPlan(url)
        // a dry run writes nothing, its ledger included: it never replaces a file that is there
        if dryRun, let ledger, FileManager.default.fileExists(atPath: ledger.path) {
            throw ArchiveError("the ledger \(ledger.path) exists; a dry run does not replace a file: name a new one")
        }
        let (planSHA, planBytes) = try Hashing.sha256Hex(ofFile: url)
        let key = sourceKind + ":" + planSHA
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let id = seen.int(0)
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(VoiceMessageImportStats.self, from: Data($0.utf8)) } ?? VoiceMessageImportStats()
            seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return VoiceMessageImportReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()

        // Every planned audio file is an attachment of a canonical message, with the media row the plan names.
        let onMessage = try db.prepare("""
            SELECT count(DISTINCT m.id) FROM attachment a JOIN message m ON m.id = a.message_id WHERE a.sha256 = ? AND m.canonical_id IS NULL
            """)
        let mediaRow = try db.prepare("SELECT bytes, path FROM media WHERE sha256 = ?")
        var messagesOf: [String: Int] = [:]
        for r in rows {
            onMessage.bind(1, r.sha)
            let n = try onMessage.step() ? Int(onMessage.int(0)) : 0
            onMessage.reset()
            guard n > 0 else { throw ArchiveError("plan line \(r.line): \(r.sha) is not the audio of any canonical message's attachment; nothing written") }
            messagesOf[r.sha] = n
            mediaRow.bind(1, r.sha)
            guard try mediaRow.step() else { mediaRow.reset(); throw ArchiveError("plan line \(r.line): the archive has no media row for \(r.sha); nothing written") }
            let bytes = mediaRow.int(0), path = mediaRow.string(1) ?? ""
            mediaRow.reset()
            guard bytes == r.bytes, path == r.target else {
                throw ArchiveError("plan line \(r.line): media \(r.sha) is recorded with \(bytes) bytes at \(path), the plan says \(r.bytes) at \(r.target); nothing written")
            }
        }
        // Every file the plan names, whole: at its target, the plan's size and sha256. One sha256 has one size and one path in the plan.
        var files: [String: (target: String, bytes: Int64, mime: String, line: Int)] = [:]
        for r in rows {
            for (sha, target, bytes, mime) in [(r.sha, r.target, r.bytes, ""), (r.playSha, r.playTarget, r.playBytes, r.playMime)] {
                if let have = files[sha] {
                    guard have.target == target, have.bytes == bytes else { throw ArchiveError("plan line \(r.line): \(sha) is named with two sizes or paths; nothing written") }
                } else { files[sha] = (target, bytes, mime, r.line) }
            }
        }
        var missing = 0, wrongSize = 0, wrongHash = 0, first: Int?
        for (sha, f) in files.sorted(by: { $0.value.line < $1.value.line }) {
            guard root.mediaContains(relativePath: f.target) else {
                throw ArchiveError("plan line \(f.line): \(f.target) leads outside the media folder (a symlink on the way); nothing written")
            }
            let file = root.resolve(relativePath: f.target)
            guard let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value else { missing += 1; first = first ?? f.line; continue }
            guard size == f.bytes else { wrongSize += 1; first = first ?? f.line; continue }
            if try Hashing.sha256Hex(ofFile: file).hex != sha { wrongHash += 1; first = first ?? f.line }
        }
        guard missing == 0, wrongSize == 0, wrongHash == 0 else {
            throw ArchiveError("not every audio file is in the media store as planned: \(missing) missing, \(wrongSize) of another size, \(wrongHash) with another sha256 (first: plan line \(first!)); nothing written")
        }
        // Every transcript, read and checked. The same audio may already have a machine transcript by the same model (a voice memo sent
        // into a thread is also a recording): that one is kept and the plan's is not written. The plan's content must agree with the
        // transcript that will be shown (no words <=> no-speech).
        let transcriptsThere = try db.tableExists("recording_transcript")
        let existingText = transcriptsThere ? try db.prepare("SELECT text FROM recording_transcript WHERE sha256 = ? AND origin = 'machine' AND model = ?") : nil
        var machine: [String: RecordingImporter.Transcript] = [:]
        for r in rows {
            let t = try RecordingImporter.readTranscript(folder: transcripts, origin: "machine", audio: r.sha, expect: r.transcriptSha, line: r.line)
            var shown = t.text
            if let existingText {
                existingText.bind(1, r.sha).bind(2, t.model)
                if try existingText.step() { shown = existingText.string(0) ?? "" }
                existingText.reset()
            }
            guard (shown.isEmpty ? "no-speech" : "speech") == r.content else {
                throw ArchiveError("plan line \(r.line): content '\(r.content)' disagrees with the transcript (\(shown.isEmpty ? "no words" : "words")); nothing written")
            }
            machine[r.sha] = t
        }

        var stats = VoiceMessageImportStats()
        var entries: [(row: Row, decision: String, newMedia: Int, transcript: String)] = []
        var sourceID: Int64?
        let tablesThere = try db.tableExists("voice_message")

        func body() throws {
            if !dryRun {
                try ensureTables(db)
                let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
                ins.bind(1, sourceKind).bind(2, origin ?? url.path).bind(3, key).bind(4, planBytes).bind(5, Int64(Date().timeIntervalSince1970))
                try ins.run()
                sourceID = db.lastInsertRowID
            }
            let existing = (tablesThere || !dryRun) ? try db.prepare("SELECT play_sha256, duration_s, content FROM voice_message WHERE sha256 = ?") : nil
            let insMedia = try db.prepare("INSERT INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
            let insRow = dryRun ? nil : try db.prepare("INSERT INTO voice_message(sha256, play_sha256, duration_s, content, source_id) VALUES (?,?,?,?,?)")
            let haveTranscript = (transcriptsThere || !dryRun)
                ? try db.prepare("SELECT text, segments, model_version, engine, made_at FROM recording_transcript WHERE sha256 = ? AND origin = 'machine' AND model = ?") : nil
            let insTranscript = dryRun ? nil : try db.prepare("""
                INSERT INTO recording_transcript(sha256, origin, model, model_version, engine, made_at, text, segments, source_id) VALUES (?,'machine',?,?,?,?,?,?,?)
                """)
            var plannedMedia = Set<String>()

            func ensureMedia(_ sha: String, line: Int) throws -> Bool {
                let f = files[sha]!
                mediaRow.bind(1, sha)
                if try mediaRow.step() {
                    let bytes = mediaRow.int(0), path = mediaRow.string(1) ?? ""
                    mediaRow.reset()
                    guard bytes == f.bytes, path == f.target else {
                        throw ArchiveError("plan line \(line): media \(sha) is recorded with \(bytes) bytes at \(path), the plan says \(f.bytes) at \(f.target); nothing written")
                    }
                    return false
                }
                mediaRow.reset()
                guard plannedMedia.insert(sha).inserted else { return false }
                stats.newMediaRows += 1; stats.newMediaBytes += f.bytes
                if !dryRun { insMedia.bind(1, sha).bind(2, f.target).bind(3, f.bytes).bind(4, RecordingImporter.opt(f.mime)); try insMedia.run() }
                return true
            }

            func ensureTranscript(_ t: RecordingImporter.Transcript, sha: String, line: Int) throws -> String {
                if let haveTranscript {
                    haveTranscript.bind(1, sha).bind(2, t.model)
                    if try haveTranscript.step() {
                        let same = haveTranscript.string(0) == t.text && haveTranscript.string(1) == t.segments && haveTranscript.string(2) == t.version
                            && haveTranscript.string(3) == t.engine && haveTranscript.string(4) == t.madeAt
                        haveTranscript.reset()
                        stats.transcriptsAlready += 1
                        // another run of the same model over the same bytes (a recording's): the transcript already there stays
                        return same ? "already-there" : "kept-existing"
                    }
                    haveTranscript.reset()
                }
                stats.transcripts += 1
                if let insTranscript {
                    insTranscript.bind(1, sha).bind(2, t.model).bind(3, t.version).bind(4, t.engine).bind(5, t.madeAt).bind(6, t.text).bind(7, t.segments).bind(8, sourceID!)
                    try insTranscript.run()
                }
                return "new"
            }

            for r in rows {
                stats.planRows += 1
                let t = machine[r.sha]!
                if let existing {
                    existing.bind(1, r.sha)
                    if try existing.step() {
                        let same = existing.string(0) == r.playSha && abs(existing.double(1) - r.duration) < 0.005 && existing.string(2) == r.content
                        existing.reset()
                        guard same else { throw ArchiveError("plan line \(r.line): \(r.sha) is in voice_message with other values; nothing written") }
                        stats.alreadyThere += 1
                        let tr = try ensureTranscript(t, sha: r.sha, line: r.line)
                        entries.append((r, "already-there", 0, tr))
                        continue
                    }
                    existing.reset()
                }
                var newMedia = 0
                if r.playSha != r.sha, try ensureMedia(r.playSha, line: r.line) { newMedia += 1 }
                if let insRow {
                    insRow.bind(1, r.sha).bind(2, r.playSha).bind(3, r.duration).bind(4, r.content).bind(5, sourceID!)
                    try insRow.run()
                }
                let tr = try ensureTranscript(t, sha: r.sha, line: r.line)
                stats.written += 1
                if r.content == "speech" { stats.withWords += 1 } else { stats.noWords += 1 }
                if r.playSha != r.sha { stats.playableCopies += 1 }
                stats.messages += messagesOf[r.sha] ?? 0
                entries.append((r, "new", newMedia, tr))
            }
            if !dryRun {
                try rebuildIndex(db)
                // a transcript is shared by every row of the same audio: a recording of the same bytes searches it too
                try RecordingImporter.rebuildIndex(db)
                stats.totalRows = Int(try db.scalarInt("SELECT count(*) FROM voice_message"))
                let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
                up.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sourceID!)
                try up.run()
                try ImportLedger.save(db, sourceID: sourceID!, body: ledgerText(entries, messagesOf: messagesOf))
            }
        }
        if dryRun { try body() } else { try db.transaction { try body() } }
        if let ledger {
            if let sourceID, let saved = try ImportLedger.load(db, sourceID: sourceID) { try ImportLedger.publish(saved, to: ledger) }
            else { try ImportLedger.publish(ledgerText(entries, messagesOf: messagesOf), to: ledger) }
        }
        return VoiceMessageImportReport(status: .imported, sourceID: sourceID, stats: stats)
    }

    static func ledgerText(_ entries: [(row: Row, decision: String, newMedia: Int, transcript: String)], messagesOf: [String: Int]) -> String {
        var out = [ledgerHeader]
        for e in entries {
            let r = e.row
            out.append([r.rid, r.sha, e.decision, r.playSha, String(e.newMedia), e.transcript, r.content, String(messagesOf[r.sha] ?? 0)]
                .map(RecordingImporter.clean).joined(separator: "\t"))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The search index: one row per voice message with words, its machine transcripts (one per model, joined) as one document.
    /// Rebuilt by either importer, since both write `recording_transcript`.
    public static func rebuildIndex(_ db: Database) throws {
        guard try db.tableExists("voice_message_fts") else { return }
        try db.exec("DELETE FROM voice_message_fts")
        try db.exec("""
            INSERT INTO voice_message_fts(body, ref)
            SELECT b.body, b.sha256 FROM (
                SELECT v.sha256, (SELECT group_concat(x.text, char(10)) FROM (SELECT t.text FROM recording_transcript t
                                  WHERE t.sha256 = v.sha256 AND t.origin = 'machine' AND t.text <> '' ORDER BY t.id) x) AS body
                FROM voice_message v) b
            WHERE b.body IS NOT NULL
            """)
    }
}
