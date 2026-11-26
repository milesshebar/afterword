import Foundation

/// Voicemails and voice memos: a voicemail someone left for the owner, or a recording they made
/// himself, with its audio in the media store and a machine transcript beside it.
///
/// Input is a plan (`recordings.tsv`, made by your own survey of the recordings found) plus a folder of transcript JSON
/// files. One plan row per recording per source; nothing is deduplicated in the plan, so every row keeps the find it came from
/// (`source_label`) and that source's own id (`source_key`).
///
/// The tables are additive and created here (`CREATE TABLE IF NOT EXISTS`), not by a numbered migration, like `call` and `post`: a schema
/// version bump would make the deployed web app (an older build) refuse the archive; older readers ignore these tables.
///
/// Audio: the source's own file is stored content-addressed (`sha256`), copied into the media store beforehand, outside this command (the
/// store may be a NAS folder, which the Mac mounts read-only). `play_sha256` names what a browser plays: the same file, or, for a format
/// browsers do not play (AMR voicemail), an AAC copy made on the Mac at planning time. Before anything is written every file the plan names
/// is read whole from the media store and must have the plan's size and sha256; any failure refuses the whole plan.
///
/// Transcripts belong to the audio, not to a row: `recording_transcript` is keyed by the audio's sha256, the origin (`machine`, or
/// `apple` for a transcription the phone made itself) and the model. A transcript is a machine transcript and is stored and shown as one.
///
/// Dedupe: rows that are the same recording are linked, never dropped (`canonical_id` is NULL on the row that wins). The same audio bytes;
/// the same Voice Memos unique id; or the same kind, starting within 2 s and the same length (within 2 s for a voicemail, 1 s for a memo),
/// when both rows are dated by something that is the recording's own time (not an export or file time); or a plan row naming the row
/// it is a copy of (`same_as_label` + `same_as_key`, stored in `same_as`: an exported voicemail that was re-encoded and carries no time,
/// matched to the phone's own row by the plan builder). The winner is a row that has
/// audio over one that has none, then the label earliest in `priority`, then the older row. Every import re-links the whole table, so a
/// later source (another phone backup) folds into the rows already there, and can supply audio an earlier source lacked.
///
/// A voicemail is tied to its caller the way a call is: `handle_id` and `thread_id` only when the archive already knows the number and has
/// a 1:1 thread with it; no handle is created for a voicemail-only number. An export that carries only a name is tied to that name's
/// handle when the name belongs to exactly one person.
///
/// Idempotent: a plan already imported (by its sha256) is "already imported"; a row is keyed by (source label, source key), so another
/// plan that overlaps adds only new rows, and a row that is there with different values refuses the plan.
public struct RecordingImportStats: Codable, Equatable, Sendable {
    public var planRows = 0
    public var written = 0
    public var alreadyThere = 0
    public var voicemails = 0, memos = 0                 // of the rows written this run
    public var meetings: Int?                            // (optional: stats saved before the kind existed decode without it)
    public var withAudio = 0, withoutAudio = 0           // of the rows written this run
    public var newMediaRows = 0
    public var newMediaBytes: Int64 = 0
    public var transcripts = 0, transcriptsAlready = 0
    public var linkedToHandle = 0, linkedToThread = 0    // of the rows written this run
    public var perLabel: [String: Int] = [:]             // rows written this run, by source label
    public var totalRows = 0, canonical = 0, duplicates = 0   // in the table after this run
}

public struct RecordingImportReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64?
    public var stats: RecordingImportStats
}

public enum RecordingImporter {
    public static let sourceKind = "recordings-plan"
    /// Who wins a duplicate group, after "has audio": earlier is better. Source labels are matched by prefix, so the plan's labels
    /// follow a convention: `memo-voicememos-...` (a Voice Memos library), `vm-phone-...` / `memo-phone-...` (a phone's own voicemail
    /// or Voice Memos database, from a backup) outrank exports and loose files; within one prefix the label naming the later year
    /// wins; a label matching no prefix ranks last (`SourceRank`).
    public static let priority = ["memo-voicememos", "vm-phone", "memo-phone"]
    /// `using` replaces the built-in list (`SourcePriority`, from `<PREFIX>_SOURCE_PRIORITY`).
    static func rank(_ label: String, using p: SourcePriority = .builtIn) -> Int { SourceRank.rank(label, prefixes: p.recordings) }
    /// A time that is the recording's own (the others are when a file was exported or last written).
    static let ownTimes: Set<String> = ["database", "audio-tag", "file-name"]
    static let datedBy: Set<String> = ["database", "audio-tag", "file-name", "export-time", "file-time"]
    static let contents: Set<String> = ["speech", "no-speech", "music", "noise"]
    /// voicemail (left for the owner), memo (the owner's own recording), meeting (a recorded call or meeting with several people, such as
    /// a saved video call)
    public static let kinds: Set<String> = ["voicemail", "memo", "meeting"]
    /// A recording's length in seconds is at most a month (a wild value must not reach the views).
    static let maxDuration = 2_678_400.0

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS recording (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,                                   -- voicemail | memo | meeting (a recorded call or meeting: Zoom)
            source_id INTEGER NOT NULL REFERENCES source(id),     -- the import (one row per plan)
            source_label TEXT NOT NULL,                           -- the find this row came from: vm-iphone6-2016, memo-voicememos-2026-11 ...
            source_key TEXT NOT NULL,                             -- the source's own id: rowid:<n>, uuid:<Voice Memos id>, file:<name>
            ts_ms INTEGER,                                        -- when it was left / recorded, Unix ms UTC; NULL = unknown
            dated_by TEXT,                                        -- database | audio-tag | file-name | export-time | file-time
            duration_s REAL NOT NULL DEFAULT 0,
            title TEXT,                                           -- a memo's title (Voice Memos names a recording after the place)
            handle_id INTEGER REFERENCES handle(id),              -- voicemail: the caller, when the archive already knows the number; never created here
            thread_id INTEGER REFERENCES thread(id),              -- that person's 1:1 thread, when there is one
            address TEXT,                                         -- voicemail: the caller's normalized number; NULL = withheld or not in the source
            callback TEXT,                                        -- voicemail: the callback number the source recorded, when it differs
            name TEXT,                                            -- voicemail: a name the source itself carried (an export's file name)
            heard INTEGER,                                        -- voicemail: 1 heard, 0 not, NULL = the source does not say
            deleted INTEGER,                                      -- 1 = in the phone's deleted list at backup time; NULL = the source does not say
            flags INTEGER,                                        -- voicemail: the source's raw flags
            memo_uuid TEXT,                                       -- Voice Memos' own unique id
            content TEXT,                                         -- speech | no-speech | music | noise (what the audio is; NULL = not judged)
            sha256 TEXT REFERENCES media(sha256),                 -- the source's own audio file; NULL = the source holds the row but no audio
            play_sha256 TEXT REFERENCES media(sha256),            -- what a browser plays: the same file, or an AAC copy of an AMR voicemail
            source_path TEXT,                                     -- where the file was found
            note TEXT,
            canonical_id INTEGER REFERENCES recording(id),        -- NULL = canonical; else the copy of the same recording that wins
            same_as INTEGER REFERENCES recording(id),             -- a row a plan says this one is a copy of (joins their duplicate group)
            chat_sha256 TEXT REFERENCES media(sha256)             -- a meeting's saved chat (Zoom's own chat file), when the recording has one
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS recording_key ON recording(source_label, source_key)",
        "CREATE INDEX IF NOT EXISTS recording_ts ON recording(ts_ms)",
        "CREATE INDEX IF NOT EXISTS recording_handle ON recording(handle_id, ts_ms)",
        "CREATE INDEX IF NOT EXISTS recording_sha ON recording(sha256)",
        """
        CREATE TABLE IF NOT EXISTS recording_transcript (
            id INTEGER PRIMARY KEY,
            sha256 TEXT NOT NULL,                                 -- the audio this is a transcript of (recording.sha256)
            origin TEXT NOT NULL,                                 -- machine | apple
            model TEXT NOT NULL,                                  -- mlx-community/parakeet-tdt-0.6b-v3 ...; 'apple-voicemail' for the phone's own
            model_version TEXT,                                   -- the model's revision
            engine TEXT,                                          -- parakeet-mlx 0.5.1 ...
            made_at TEXT,                                         -- when the transcript was made (ISO 8601 UTC)
            text TEXT NOT NULL,                                   -- '' = the model heard no speech
            segments TEXT,                                        -- JSON [{start, end, text}] in seconds
            source_id INTEGER NOT NULL REFERENCES source(id),
            UNIQUE (sha256, origin, model)
        )
        """,
        "CREATE VIRTUAL TABLE IF NOT EXISTS recording_fts USING fts5(body, title, ref UNINDEXED, tokenize='unicode61 remove_diacritics 2')",
    ]

    public static func ensureTables(_ db: Database) throws {
        for s in tableSQL { try db.exec(s) }
        // a table made before `same_as` existed gets the column; additive, older readers never name it
        if !(try db.hasColumn("recording", "same_as")) { try db.exec("ALTER TABLE recording ADD COLUMN same_as INTEGER REFERENCES recording(id)") }
        // and `chat_sha256` (a meeting's saved chat)
        if !(try db.hasColumn("recording", "chat_sha256")) { try db.exec("ALTER TABLE recording ADD COLUMN chat_sha256 TEXT REFERENCES media(sha256)") }
    }

    static let ledgerHeader = "rid\tkind\tlabel\tsource_key\tdecision\trecording_id\tts_ms\tsha256\tplay_sha256\tnew_media\ttranscript\thandle_id\tthread_id\tcanonical_id\tsame_as"

    // MARK: plan

    struct Row {
        var line: Int
        var rid = "", kind = "", label = "", key = "", datedBy = "", title = "", address = "", callback = "", name = "", memoUUID = "", content = ""
        var sha = "", mime = "", target = "", playSha = "", playMime = "", playTarget = "", sourcePath = "", note = "", transcriptSha = "", appleSha = ""
        var sameLabel = "", sameKey = ""
        var chatSha = "", chatTarget = ""
        var chatBytes: Int64 = 0
        var ts: Int64?, heard: Int64?, deleted: Int64?, flags: Int64?
        var duration = 0.0
        var bytes: Int64 = 0, playBytes: Int64 = 0
    }

    struct Transcript { var model: String, version: String?, engine: String?, madeAt: String?, text: String, segments: String? }

    static func isHex(_ s: String, _ n: Int) -> Bool { s.utf8.count == n && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) } }

    static func storeName(_ sha: String, _ target: String) -> Bool {
        let ext = (target as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            && target == "\(ArchiveRoot.mediaDirName)/\(sha.prefix(2))/\(sha).\(ext)"
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
        let c = try (rid: col("rid"), kind: col("kind"), label: col("label"), key: col("source_key"), ts: col("ts_ms"), datedBy: col("dated_by"),
                     duration: col("duration_s"), title: col("title"), address: col("address"), callback: col("callback"), name: col("name"),
                     heard: col("heard"), deleted: col("deleted"), flags: col("flags"), uuid: col("memo_uuid"), content: col("content"))
        let m = try (sha: col("sha256"), bytes: col("bytes"), mime: col("mime"), target: col("target_path"), playSha: col("play_sha256"),
                     playBytes: col("play_bytes"), playMime: col("play_mime"), playTarget: col("play_target_path"), path: col("source_path"),
                     note: col("note"), transcript: col("transcript_sha256"))
        let apple = header.firstIndex(of: "apple_transcript_sha256")
        let sameLabel = header.firstIndex(of: "same_as_label"), sameKey = header.firstIndex(of: "same_as_key")
        let chat = (sha: header.firstIndex(of: "chat_sha256"), bytes: header.firstIndex(of: "chat_bytes"), target: header.firstIndex(of: "chat_target_path"))
        guard (chat.sha == nil) == (chat.bytes == nil), (chat.sha == nil) == (chat.target == nil) else {
            throw ArchiveError("the plan names a chat file without all of chat_sha256, chat_bytes and chat_target_path")
        }
        var out: [Row] = []
        var keys = Set<String>(), rids = Set<String>()
        for (i, line) in lines.enumerated() {
            let f = line.components(separatedBy: "\t")
            let n = i + 2
            func bad(_ why: String) -> ArchiveError { ArchiveError("plan line \(n): \(why); nothing written") }
            guard f.count == header.count else { throw bad("\(f.count) fields, the header has \(header.count)") }
            func optInt(_ s: String, _ what: String) throws -> Int64? {
                if s.isEmpty { return nil }
                guard let v = Int64(s) else { throw bad("\(what) '\(s)' is not a number") }
                return v
            }
            var r = Row(line: n)
            r.rid = f[c.rid]; r.kind = f[c.kind]; r.label = f[c.label]; r.key = f[c.key]; r.datedBy = f[c.datedBy]; r.title = f[c.title]
            r.address = f[c.address]; r.callback = f[c.callback]; r.name = f[c.name]; r.memoUUID = f[c.uuid]; r.content = f[c.content]
            r.sha = f[m.sha]; r.mime = f[m.mime]; r.target = f[m.target]; r.playSha = f[m.playSha]; r.playMime = f[m.playMime]
            r.playTarget = f[m.playTarget]; r.sourcePath = f[m.path]; r.note = f[m.note]; r.transcriptSha = f[m.transcript]
            r.appleSha = apple.map { f[$0] } ?? ""
            r.sameLabel = sameLabel.map { f[$0] } ?? ""; r.sameKey = sameKey.map { f[$0] } ?? ""
            guard r.sameLabel.isEmpty == r.sameKey.isEmpty else { throw bad("same_as needs both a label and a source key") }
            guard r.sameLabel.isEmpty || !(r.sameLabel == f[c.label] && r.sameKey == f[c.key]) else { throw bad("a row cannot be a copy of itself") }
            guard kinds.contains(r.kind) else { throw bad("kind '\(r.kind)' is not voicemail, memo or meeting") }
            if let cs = chat.sha, let cb = chat.bytes, let ct = chat.target, !f[cs].isEmpty || !f[cb].isEmpty || !f[ct].isEmpty {
                guard r.kind == "meeting" else { throw bad("only a meeting has a saved chat") }
                guard isHex(f[cs], 64), let b = Int64(f[cb]), b > 0, storeName(f[cs], f[ct]) else { throw bad("the chat needs its sha256, its size and the store's own path for it") }
                r.chatSha = f[cs]; r.chatBytes = b; r.chatTarget = f[ct]
            }
            guard !r.rid.isEmpty, !r.label.isEmpty, !r.key.isEmpty else { throw bad("a row needs a rid, a label and a source key") }
            guard rids.insert(r.rid).inserted else { throw bad("rid \(r.rid) is named twice") }
            guard keys.insert(r.label + "\u{1}" + r.key).inserted else { throw bad("\(r.label) / \(r.key) is named twice") }
            r.ts = try optInt(f[c.ts], "ts_ms")
            if let ts = r.ts {
                guard ts > 0, datedBy.contains(r.datedBy) else { throw bad("a time needs a positive ts_ms and a known dated_by") }
            } else {
                guard r.datedBy.isEmpty else { throw bad("dated_by without a time") }
            }
            guard let d = Double(f[c.duration].isEmpty ? "0" : f[c.duration]), d >= 0, d <= maxDuration else { throw bad("duration_s '\(f[c.duration])'") }
            r.duration = d
            r.heard = try optInt(f[c.heard], "heard"); r.deleted = try optInt(f[c.deleted], "deleted"); r.flags = try optInt(f[c.flags], "flags")
            guard r.heard.map({ $0 == 0 || $0 == 1 }) ?? true, r.deleted.map({ $0 == 0 || $0 == 1 }) ?? true else { throw bad("heard and deleted are 0, 1 or empty") }
            guard r.content.isEmpty || contents.contains(r.content) else { throw bad("content '\(r.content)'") }
            if r.sha.isEmpty {
                guard f[m.bytes].isEmpty, r.target.isEmpty, r.playSha.isEmpty, f[m.playBytes].isEmpty, r.playTarget.isEmpty, r.transcriptSha.isEmpty, r.appleSha.isEmpty else {
                    throw bad("a row without audio names a file, a size or a transcript")
                }
            } else {
                guard isHex(r.sha, 64), let b = Int64(f[m.bytes]), b > 0, storeName(r.sha, r.target) else { throw bad("the audio needs its sha256, its size and the store's own path for it") }
                r.bytes = b
                guard isHex(r.playSha, 64), let pb = Int64(f[m.playBytes]), pb > 0, storeName(r.playSha, r.playTarget) else {
                    throw bad("the audio needs a playable file (its own, or a copy): sha256, size and the store's own path")
                }
                r.playBytes = pb
                if r.playSha == r.sha { guard pb == b, r.playTarget == r.target else { throw bad("the playable file is the audio itself but its size or path differ") } }
                guard r.transcriptSha.isEmpty || isHex(r.transcriptSha, 64), r.appleSha.isEmpty || isHex(r.appleSha, 64) else { throw bad("a transcript is named by the sha256 of its JSON file") }
            }
            out.append(r)
        }
        return out
    }

    /// `<folder>/<origin>/<xx>/<audio sha256>.json`, hashing to the plan's value: {model, model_revision, engine, engine_version, created_at, text, segments}.
    static func readTranscript(folder: URL?, origin: String, audio: String, expect: String, line: Int) throws -> Transcript {
        guard let folder else { throw ArchiveError("plan line \(line) names a transcript and no --transcripts folder was given; nothing written") }
        let file = folder.appendingPathComponent(origin).appendingPathComponent(String(audio.prefix(2))).appendingPathComponent(audio + ".json")
        guard let data = FileManager.default.contents(atPath: file.path) else { throw ArchiveError("plan line \(line): no transcript file \(origin)/\(audio.prefix(2))/\(audio).json; nothing written") }
        let hash = data.withUnsafeBytes { Hashing.sha256Hex($0) }
        guard hash == expect else { throw ArchiveError("plan line \(line): the transcript file hashes to \(hash), the plan says \(expect); nothing written") }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = j["text"] as? String, let model = j["model"] as? String, !model.isEmpty else {
            throw ArchiveError("plan line \(line): the transcript file is not {model, text, ...}; nothing written")
        }
        // the file must say which audio it is a transcript of: hashing the JSON proves its bytes, not what it describes
        guard let of = j["sha256"] as? String, of == audio else { throw ArchiveError("plan line \(line): the transcript file does not name this audio file's sha256; nothing written") }
        var segments: String?
        if let s = j["segments"] as? [[String: Any]], !s.isEmpty {
            let slim: [[String: Any]] = s.compactMap { seg in
                guard let t = seg["text"] as? String, let a = (seg["start"] as? NSNumber)?.doubleValue, let b = (seg["end"] as? NSNumber)?.doubleValue else { return nil }
                return ["start": a, "end": b, "text": t]
            }
            if let d = try? JSONSerialization.data(withJSONObject: slim, options: [.sortedKeys]) { segments = String(decoding: d, as: UTF8.self) }
        }
        let engine = [j["engine"] as? String, j["engine_version"] as? String].compactMap { $0 }.joined(separator: " ")
        return Transcript(model: model, version: j["model_revision"] as? String, engine: engine.isEmpty ? nil : engine, madeAt: j["created_at"] as? String,
                          text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments)
    }

    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    static func opt(_ s: String) -> String? { s.isEmpty ? nil : s }

    // MARK: caller lookup

    /// Existing handles and 1:1 threads only (never created here), as for calls; a name alone links when it belongs to one person.
    struct Callers {
        let base: CallImporter.Lookup
        let byName: Statement
        let personOf: Statement?
        let busiest: Statement

        init(_ db: Database) throws {
            base = try CallImporter.Lookup(db)
            byName = try db.prepare("""
                SELECT DISTINCT h.id FROM contact_name c JOIN handle h ON h.id = c.handle_id
                WHERE c.name = ? COLLATE NOCASE AND h.kind IN ('phone', 'email') ORDER BY h.id
                """)
            personOf = try db.tableExists("person_handle") ? db.prepare("SELECT person_id FROM person_handle WHERE handle_id = ?") : nil
            busiest = try db.prepare("SELECT count(*) FROM message WHERE thread_id = ? AND canonical_id IS NULL")
        }

        func handle(address: String?, name: String?) throws -> (handle: Int64?, thread: Int64?) {
            if let address, let h = base.handle[address] { return (h, base.thread[h]) }
            guard address == nil, let name, name.split(separator: " ").count >= 2 else { return (nil, nil) }
            byName.bind(1, name)
            var ids: [Int64] = []
            while try byName.step() { ids.append(byName.int(0)) }
            byName.reset()
            guard !ids.isEmpty else { return (nil, nil) }
            if ids.count > 1 {
                // several numbers under the name: only when the automatic matching holds them all as one person
                guard let personOf else { return (nil, nil) }
                var persons = Set<Int64>()
                for id in ids {
                    personOf.bind(1, id)
                    guard try personOf.step() else { personOf.reset(); return (nil, nil) }
                    persons.insert(personOf.int(0)); personOf.reset()
                }
                guard persons.count == 1 else { return (nil, nil) }
            }
            // the number with the busiest 1:1 thread (ties: the smallest handle id)
            var best: (id: Int64, n: Int64)?
            for id in ids {
                var n: Int64 = -1
                if let t = base.thread[id] { busiest.bind(1, t); if try busiest.step() { n = busiest.int(0) }; busiest.reset() }
                if best == nil || n > best!.n { best = (id, n) }
            }
            return (best!.id, base.thread[best!.id])
        }
    }

    // MARK: import

    /// `priority` replaces the built-in ranking (archivectl passes `SourcePriority.fromEnvironment()`).
    public static func run(plan url: URL, transcripts: URL?, into db: Database, root: ArchiveRoot, dryRun: Bool = false, ledger: URL? = nil,
                           origin: String? = nil, priority: SourcePriority = .builtIn) throws -> RecordingImportReport {
        let rows = try readPlan(url)
        let (planSHA, planBytes) = try Hashing.sha256Hex(ofFile: url)
        let key = "recordings-plan:" + planSHA
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let id = seen.int(0)
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(RecordingImportStats.self, from: Data($0.utf8)) } ?? RecordingImportStats()
            seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return RecordingImportReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()

        // Every file the plan names, whole: present at its target, the plan's size and sha256. One sha256 has one size and one path in the plan.
        var files: [String: (target: String, bytes: Int64, mime: String, line: Int)] = [:]
        for r in rows where !r.sha.isEmpty || !r.chatSha.isEmpty {
            var named = r.sha.isEmpty ? [] : [(r.sha, r.target, r.bytes, r.mime), (r.playSha, r.playTarget, r.playBytes, r.playMime)]
            if !r.chatSha.isEmpty { named.append((r.chatSha, r.chatTarget, r.chatBytes, "text/plain; charset=utf-8")) }
            for (sha, target, bytes, mime) in named {
                if let have = files[sha] {
                    guard have.target == target, have.bytes == bytes else { throw ArchiveError("plan line \(r.line): \(sha) is named with two sizes or paths; nothing written") }
                } else { files[sha] = (target, bytes, mime, r.line) }
            }
        }
        var missing = 0, wrongSize = 0, wrongHash = 0, first: Int?
        for (sha, f) in files.sorted(by: { $0.value.line < $1.value.line }) {
            let file = root.resolve(relativePath: f.target)
            guard root.mediaContains(relativePath: f.target) else {
                throw ArchiveError("plan line \(f.line): \(f.target) leads outside the media folder (a symlink on the way); nothing written")
            }
            guard let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value else { missing += 1; first = first ?? f.line; continue }
            guard size == f.bytes else { wrongSize += 1; first = first ?? f.line; continue }
            if try Hashing.sha256Hex(ofFile: file).hex != sha { wrongHash += 1; first = first ?? f.line }
        }
        guard missing == 0, wrongSize == 0, wrongHash == 0 else {
            throw ArchiveError("not every audio file is in the media store as planned: \(missing) missing, \(wrongSize) of another size, \(wrongHash) with another sha256 (first: plan line \(first!)); nothing written")
        }
        // Every transcript the plan names, read and checked against the plan's hash.
        // Rows of the same audio must name the same transcript file (each distinct file is then read and hashed once).
        var machine: [String: Transcript] = [:], apple: [String: Transcript] = [:]
        var named: [String: String] = [:]
        for r in rows {
            for (origin, expect) in [("machine", r.transcriptSha), ("apple", r.appleSha)] where !expect.isEmpty {
                let k = origin + "|" + r.sha
                if let have = named[k] {
                    guard have == expect else { throw ArchiveError("plan line \(r.line): another row names a different \(origin) transcript for the same audio \(r.sha); nothing written") }
                    continue
                }
                named[k] = expect
                let t = try readTranscript(folder: transcripts, origin: origin, audio: r.sha, expect: expect, line: r.line)
                if origin == "machine" { machine[r.sha] = t } else { apple[r.sha] = t }
            }
        }

        var stats = RecordingImportStats()
        var entries: [(row: Row, decision: String, id: Int64?, newMedia: Int, transcript: String, handle: Int64?, thread: Int64?)] = []
        var sourceID: Int64?
        var sameAs: [String: Int64] = [:]            // rid -> the id of the row it is a copy of (this plan's same_as rows)
        let tablesThere = try db.tableExists("recording")

        func body() throws {
            if !dryRun {
                try ensureTables(db)
                let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
                ins.bind(1, sourceKind).bind(2, origin ?? url.path).bind(3, key).bind(4, planBytes).bind(5, Int64(Date().timeIntervalSince1970))
                try ins.run()
                sourceID = db.lastInsertRowID
            }
            let readable = tablesThere || !dryRun
            let hasChat = try readable && db.hasColumn("recording", "chat_sha256")
            let callers = try Callers(db)
            let existing = readable ? try db.prepare("""
                SELECT id, kind, ts_ms, dated_by, duration_s, title, address, callback, name, heard, deleted, flags, memo_uuid, content, sha256, play_sha256,
                       source_path, note, handle_id, thread_id, \(hasChat ? "chat_sha256" : "NULL") FROM recording WHERE source_label = ? AND source_key = ?
                """) : nil
            let mediaRow = try db.prepare("SELECT bytes, path FROM media WHERE sha256 = ?")
            let insMedia = try db.prepare("INSERT INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
            let insRow = dryRun ? nil : try db.prepare("""
                INSERT INTO recording(kind, source_id, source_label, source_key, ts_ms, dated_by, duration_s, title, handle_id, thread_id, address, callback,
                                      name, heard, deleted, flags, memo_uuid, content, sha256, play_sha256, source_path, note, chat_sha256)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            let haveTranscript = readable ? try db.prepare("SELECT text, segments, model_version, engine, made_at FROM recording_transcript WHERE sha256 = ? AND origin = ? AND model = ?") : nil
            let insTranscript = dryRun ? nil : try db.prepare("""
                INSERT INTO recording_transcript(sha256, origin, model, model_version, engine, made_at, text, segments, source_id) VALUES (?,?,?,?,?,?,?,?,?)
                """)
            var plannedMedia = Set<String>(), plannedTranscripts = Set<String>()

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
                if !dryRun { insMedia.bind(1, sha).bind(2, f.target).bind(3, f.bytes).bind(4, opt(f.mime)); try insMedia.run() }
                return true
            }

            /// "new", "shared" (the same audio earlier in this plan), "already-there" (in the archive before this plan), or throws when a
            /// different transcript of the same audio by the same model is there.
            func ensureTranscript(_ t: Transcript, sha: String, origin: String, line: Int) throws -> String {
                let planned = sha + "|" + origin + "|" + t.model
                if plannedTranscripts.contains(planned) { return "shared" }
                if let haveTranscript {
                    haveTranscript.bind(1, sha).bind(2, origin).bind(3, t.model)
                    if try haveTranscript.step() {
                        let same = haveTranscript.string(0) == t.text && haveTranscript.string(1) == t.segments && haveTranscript.string(2) == t.version
                            && haveTranscript.string(3) == t.engine && haveTranscript.string(4) == t.madeAt
                        haveTranscript.reset()
                        guard same else { throw ArchiveError("plan line \(line): a different \(origin) transcript of \(sha) by \(t.model) is already there; nothing written") }
                        stats.transcriptsAlready += 1
                        return "already-there"
                    }
                    haveTranscript.reset()
                }
                plannedTranscripts.insert(planned)
                stats.transcripts += 1
                if let insTranscript {
                    insTranscript.bind(1, sha).bind(2, origin).bind(3, t.model).bind(4, t.version).bind(5, t.engine).bind(6, t.madeAt).bind(7, t.text)
                        .bind(8, t.segments).bind(9, sourceID!)
                    try insTranscript.run()
                }
                return "new"
            }

            for r in rows {
                stats.planRows += 1
                let address: String? = r.kind == "voicemail" ? opt(r.address).flatMap { HandleNormalizer.normalize($0)?.normalized } : nil
                let callback: String? = opt(r.callback).flatMap { HandleNormalizer.normalize($0)?.normalized }.flatMap { $0 == address ? nil : $0 }
                let link = r.kind == "voicemail" ? try callers.handle(address: address, name: opt(r.name)) : (nil, nil)
                if let existing {
                    existing.bind(1, r.label).bind(2, r.key)
                    if try existing.step() {
                        let id = existing.int(0)
                        let same = existing.string(1) == r.kind && existing.optInt(2) == r.ts && existing.string(3) == opt(r.datedBy)
                            && abs(existing.double(4) - r.duration) < 0.005 && existing.string(5) == opt(r.title) && existing.string(6) == address
                            && existing.string(7) == callback && existing.string(8) == opt(r.name) && existing.optInt(9) == r.heard
                            && existing.optInt(10) == r.deleted && existing.optInt(11) == r.flags && existing.string(12) == opt(r.memoUUID)
                            && existing.string(13) == opt(r.content) && existing.string(14) == opt(r.sha) && existing.string(15) == opt(r.playSha)
                            && existing.string(16) == opt(r.sourcePath) && existing.string(17) == opt(r.note) && existing.string(20) == opt(r.chatSha)
                        let h = existing.optInt(18), t = existing.optInt(19)
                        existing.reset()
                        guard same else { throw ArchiveError("plan line \(r.line): \(r.label) / \(r.key) is in the archive with other values; nothing written") }
                        stats.alreadyThere += 1
                        var tr = "none"
                        if let t = machine[r.sha], !r.transcriptSha.isEmpty { tr = try ensureTranscript(t, sha: r.sha, origin: "machine", line: r.line) }
                        if let t = apple[r.sha], !r.appleSha.isEmpty { _ = try ensureTranscript(t, sha: r.sha, origin: "apple", line: r.line) }
                        entries.append((r, "already-there", id, 0, tr, h, t))
                        continue
                    }
                    existing.reset()
                }
                var newMedia = 0
                if !r.sha.isEmpty {
                    if try ensureMedia(r.sha, line: r.line) { newMedia += 1 }
                    if r.playSha != r.sha, try ensureMedia(r.playSha, line: r.line) { newMedia += 1 }
                }
                if !r.chatSha.isEmpty, try ensureMedia(r.chatSha, line: r.line) { newMedia += 1 }
                var id: Int64?
                if let insRow {
                    insRow.bind(1, r.kind).bind(2, sourceID!).bind(3, r.label).bind(4, r.key).bind(5, r.ts).bind(6, opt(r.datedBy)).bind(7, r.duration)
                        .bind(8, opt(r.title)).bind(9, link.0).bind(10, link.1).bind(11, address).bind(12, callback).bind(13, opt(r.name))
                        .bind(14, r.heard).bind(15, r.deleted).bind(16, r.flags).bind(17, opt(r.memoUUID)).bind(18, opt(r.content))
                        .bind(19, opt(r.sha)).bind(20, opt(r.playSha)).bind(21, opt(r.sourcePath)).bind(22, opt(r.note)).bind(23, opt(r.chatSha))
                    try insRow.run()
                    id = db.lastInsertRowID
                }
                var tr = "none"
                if let t = machine[r.sha], !r.transcriptSha.isEmpty { tr = try ensureTranscript(t, sha: r.sha, origin: "machine", line: r.line) }
                if let t = apple[r.sha], !r.appleSha.isEmpty { _ = try ensureTranscript(t, sha: r.sha, origin: "apple", line: r.line) }
                stats.written += 1
                stats.perLabel[r.label, default: 0] += 1
                if r.kind == "voicemail" { stats.voicemails += 1 } else if r.kind == "meeting" { stats.meetings = (stats.meetings ?? 0) + 1 } else { stats.memos += 1 }
                if r.sha.isEmpty { stats.withoutAudio += 1 } else { stats.withAudio += 1 }
                if link.0 != nil { stats.linkedToHandle += 1 }
                if link.1 != nil { stats.linkedToThread += 1 }
                entries.append((r, "new", id, newMedia, tr, link.0, link.1))
            }
            // Rows a plan names as copies of another row: the target must be a row of the same kind, in the archive or in this plan.
            var kinds: [String: (id: Int64?, kind: String)] = [:]
            for e in entries { kinds[e.row.label + "\u{1}" + e.row.key] = (e.id, e.row.kind) }
            let target = readable ? try db.prepare("SELECT id, kind FROM recording WHERE source_label = ? AND source_key = ?") : nil
            let hasSameAs = try readable && db.hasColumn("recording", "same_as")
            let setSame = dryRun ? nil : try db.prepare("UPDATE recording SET same_as = ?1 WHERE id = ?2 AND (same_as IS NULL OR same_as = ?1)")
            let current = hasSameAs ? try db.prepare("SELECT same_as FROM recording WHERE id = ?") : nil
            for e in entries where !e.row.sameLabel.isEmpty {
                let r = e.row
                var found: (id: Int64?, kind: String)? = kinds[r.sameLabel + "\u{1}" + r.sameKey]
                if found == nil, let target {
                    target.bind(1, r.sameLabel).bind(2, r.sameKey)
                    if try target.step() { found = (target.int(0), target.string(1) ?? "") }
                    target.reset()
                }
                guard let t = found else { throw ArchiveError("plan line \(r.line): same_as names \(r.sameLabel) / \(r.sameKey), which is neither in the archive nor in this plan; nothing written") }
                guard t.kind == r.kind else { throw ArchiveError("plan line \(r.line): same_as names a \(t.kind), this row is a \(r.kind); nothing written") }
                // A row already tied to another row is not re-tied by a later plan. Checked whether or not the target has an id yet:
                // in a dry run a target that this plan adds has none, and a tie that exists can never be to it (review of 9a54f47).
                if let id = e.id, let current {
                    current.bind(1, id)
                    let have: Int64? = try current.step() ? current.optInt(0) : nil
                    current.reset()
                    if let have, have != t.id { throw ArchiveError("plan line \(r.line): \(r.label) / \(r.key) is already recorded as a copy of another row; nothing written") }
                }
                if let id = e.id, let tid = t.id {
                    if let setSame { setSame.bind(1, tid).bind(2, id); try setSame.run() }
                    sameAs[r.rid] = tid
                }
            }
            if !dryRun {
                try finish(db, priority: priority)
                stats.totalRows = Int(try db.scalarInt("SELECT count(*) FROM recording"))
                stats.canonical = Int(try db.scalarInt("SELECT count(*) FROM recording WHERE canonical_id IS NULL"))
                stats.duplicates = stats.totalRows - stats.canonical
                let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
                up.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sourceID!)
                try up.run()
                try ImportLedger.save(db, sourceID: sourceID!, body: try ledgerText(entries, db: db, sameAs: sameAs))
            }
        }
        if dryRun { try body() } else { try db.transaction { try body() } }
        if let ledger {
            if let sourceID, let saved = try ImportLedger.load(db, sourceID: sourceID) { try ImportLedger.publish(saved, to: ledger) }
            else { try ImportLedger.publish(try ledgerText(entries, db: nil, sameAs: sameAs), to: ledger) }
        }
        return RecordingImportReport(status: .imported, sourceID: sourceID, stats: stats)
    }

    /// One line per plan row; `canonical_id` is the row that wins its duplicate group after this run's linking (itself when it wins).
    static func ledgerText(_ entries: [(row: Row, decision: String, id: Int64?, newMedia: Int, transcript: String, handle: Int64?, thread: Int64?)],
                           db: Database?, sameAs: [String: Int64] = [:]) throws -> String {
        var canonical: [Int64: Int64] = [:]
        if let db {
            let q = try db.prepare("SELECT id, coalesce(canonical_id, id) FROM recording")
            while try q.step() { canonical[q.int(0)] = q.int(1) }
            q.reset()
        }
        var out = [ledgerHeader]
        for e in entries {
            let r = e.row
            let fields: [String] = [r.rid, r.kind, r.label, r.key, e.decision, e.id.map(String.init) ?? "", r.ts.map(String.init) ?? "", r.sha, r.playSha,
                                    String(e.newMedia), e.transcript, e.handle.map(String.init) ?? "", e.thread.map(String.init) ?? "",
                                    e.id.flatMap { canonical[$0] }.map(String.init) ?? "", sameAs[r.rid].map(String.init) ?? ""]
            out.append(fields.map(clean).joined(separator: "\t"))
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: linking and search index

    /// Re-links duplicates over the whole table and rebuilds the search index from the canonical rows.
    static func finish(_ db: Database, priority: SourcePriority = .builtIn) throws {
        try db.exec("UPDATE recording SET canonical_id = NULL")
        struct R { var id: Int64, kind: String, label: String, ts: Int64?, own: Bool, dur: Double, sha: String?, uuid: String?, sameAs: Int64? }
        let q = try db.prepare("SELECT id, kind, source_label, ts_ms, dated_by, duration_s, sha256, memo_uuid, same_as FROM recording")
        var all: [R] = []
        while try q.step() {
            all.append(R(id: q.int(0), kind: q.string(1) ?? "", label: q.string(2) ?? "", ts: q.optInt(3), own: ownTimes.contains(q.string(4) ?? ""),
                         dur: q.double(5), sha: q.string(6), uuid: q.string(7), sameAs: q.optInt(8)))
        }
        q.reset()
        // Groups: rows joined by any shared identifier (the same bytes, the same Voice Memos id) or by the time rule, transitively, so
        // a row that is itself a duplicate still brings its other identifiers to the group.
        var parent = Array(all.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }
        var bySha: [String: Int] = [:], byUUID: [String: Int] = [:]
        for (i, r) in all.enumerated() {
            if let s = r.sha { if let j = bySha[s] { union(j, i) } else { bySha[s] = i } }
            if let u = r.uuid { if let j = byUUID[u] { union(j, i) } else { byUUID[u] = i } }
        }
        let indexOf = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
        for (i, r) in all.enumerated() { if let t = r.sameAs, let j = indexOf[t], all[j].kind == r.kind { union(j, i) } }
        for kind in Set(all.map(\.kind)) {
            let timed = all.indices.filter { all[$0].kind == kind && all[$0].own && all[$0].ts != nil }.sorted { all[$0].ts! < all[$1].ts! }
            let tolerance = kind == "voicemail" ? 2.0 : 1.0
            for (n, i) in timed.enumerated() {
                var m = n + 1
                while m < timed.count, all[timed[m]].ts! - all[i].ts! <= 2000 {
                    if abs(all[timed[m]].dur - all[i].dur) <= tolerance { union(i, timed[m]) }
                    m += 1
                }
            }
        }
        // The winner of a group: has audio, then the label's rank, then the older row; every other member points straight at it.
        var members: [Int: [Int]] = [:]
        for i in all.indices { members[find(i), default: []].append(i) }
        var dup: [(Int64, Int64)] = []
        for group in members.values where group.count > 1 {
            let w = group.min { a, b in
                let ka = (all[a].sha == nil ? 1 : 0, rank(all[a].label, using: priority), all[a].id), kb = (all[b].sha == nil ? 1 : 0, rank(all[b].label, using: priority), all[b].id)
                return ka < kb
            }!
            for i in group where i != w { dup.append((all[i].id, all[w].id)) }
        }
        dup.sort { $0.0 < $1.0 }
        let up = try db.prepare("UPDATE recording SET canonical_id = ? WHERE id = ?")
        for (id, w) in dup { up.bind(1, w).bind(2, id); try up.run() }

        try rebuildIndex(db)
        // voice messages share recording_transcript: a transcript this import added for the same bytes reaches their search too
        try VoiceMessageImporter.rebuildIndex(db)
    }

    /// Search: one row per canonical recording that has words (its transcripts) or a title or a caller's name.
    static func rebuildIndex(_ db: Database) throws {
        guard try db.tableExists("recording_fts") else { return }
        try db.exec("DELETE FROM recording_fts")
        try db.exec("""
            INSERT INTO recording_fts(body, title, ref)
            SELECT coalesce((SELECT group_concat(x.text, char(10)) FROM (SELECT t.text FROM recording_transcript t WHERE t.sha256 = r.sha256 ORDER BY t.id) x), ''),
                   trim(coalesce(r.title, '') || ' ' || coalesce(r.name, '')), r.id
            FROM recording r WHERE r.canonical_id IS NULL
            """)
    }
}
