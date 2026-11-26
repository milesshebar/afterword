import Foundation

// Read side of the `recording` tables (RecordingImporter): voicemails as lines in their caller's timeline, every voicemail and voice
// memo by date, and a search over the transcripts. Read-only; an archive without the tables reads as having no recordings.
//
// Which rows: canonical only (one row per recording however many sources hold it). A voicemail belongs to a handle by its `handle_id`,
// or, when the import found no handle (the number reached the archive later), by its address matching a handle's normalized form now:
// the same rule as calls (CallsReader).

/// A transcript of a recording's audio. `origin` is `machine` (made on the Mac by `model`) or `apple` (the phone's own voicemail
/// transcription); either way it is a machine transcript, never anyone's verified words.
public struct RecordingTranscript: Sendable, Hashable {
    public var origin: String
    public var model: String
    public var modelVersion: String?
    public var engine: String?
    public var text: String
    /// JSON `[{start, end, text}]` (seconds), when the model gave timings.
    public var segments: String?
}

/// One voicemail, voice memo or recorded meeting.
public struct RecordingRow: Sendable, Identifiable, Hashable {
    public var id: Int64
    /// `voicemail` | `memo` | `meeting`
    public var kind: String
    public var tsMs: Int64?
    /// database | audio-tag | file-name | export-time | file-time
    public var datedBy: String?
    public var durationS: Double
    public var title: String?
    public var handleID: Int64?
    public var threadID: Int64?
    public var address: String?
    public var name: String?
    public var heard: Bool?
    public var deleted: Bool?
    /// speech | no-speech | music | noise
    public var content: String?
    public var sha256: String?
    public var playSha256: String?
    public var playMime: String?
    public var note: String?
    public var sourceLabel: String
    /// A meeting's saved chat (Zoom's chat file, plain text), in the media store.
    public var chatSha256: String? = nil
    public var transcripts: [RecordingTranscript] = []
    /// A search hit's snippet, with U+0001 / U+0002 around the matched words.
    public var snippet: String?

    public var isVoicemail: Bool { kind == "voicemail" }
    public var isMeeting: Bool { kind == "meeting" }
    /// True when the time is the recording's own; false when it is only when a file was exported or written (an upper bound).
    public var timeIsOwn: Bool { RecordingImporter.ownTimes.contains(datedBy ?? "") }

    /// 0:07, 3:42, 1:02:05.
    public static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(min(max(seconds, 0), RecordingImporter.maxDuration).rounded()) : 0   // never trap on a wild value
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

public struct RecordingCounts: Sendable, Hashable {
    public var voicemails = 0
    public var memos = 0
    public var meetings = 0
    public var seconds = 0.0
    public init() {}
}

extension ArchiveReader {
    /// True when the archive has the recording tables.
    public func hasRecordings() throws -> Bool {
        try locked { try db.tableExists("recording") }
    }

    static let recordingColumns = """
        r.id, r.kind, r.ts_ms, r.dated_by, r.duration_s, r.title, r.handle_id, r.thread_id, r.address, r.name, r.heard, r.deleted, r.content,
        r.sha256, r.play_sha256, (SELECT m.mime FROM media m WHERE m.sha256 = r.play_sha256), r.note, r.source_label
        """

    /// The columns, with a meeting's chat when the table has the column (an archive imported by an older version has not).
    func recordingColumnsSQL() throws -> String {
        Self.recordingColumns + (try db.hasColumn("recording", "chat_sha256") ? ", r.chat_sha256" : ", NULL")
    }

    private func recordingRow(_ st: Statement) -> RecordingRow {
        RecordingRow(id: st.int(0), kind: st.string(1) ?? "memo", tsMs: st.optInt(2), datedBy: st.string(3), durationS: st.double(4), title: st.string(5),
                     handleID: st.optInt(6), threadID: st.optInt(7), address: st.string(8), name: st.string(9), heard: st.optInt(10).map { $0 != 0 },
                     deleted: st.optInt(11).map { $0 != 0 }, content: st.string(12), sha256: st.string(13), playSha256: st.string(14),
                     playMime: st.string(15), note: st.string(16), sourceLabel: st.string(17) ?? "", chatSha256: st.string(18))
    }

    /// Fills in the transcripts of rows that have audio (the Mac's own transcript first, then the phone's).
    private func withTranscripts(_ rows: [RecordingRow], segments: Bool) throws -> [RecordingRow] {
        let shas = Set(rows.compactMap(\.sha256))
        guard !shas.isEmpty else { return rows }
        var bySha: [String: [RecordingTranscript]] = [:]
        let st = try db.prepare("""
            SELECT sha256, origin, model, model_version, engine, text, \(segments ? "segments" : "NULL") FROM recording_transcript
            WHERE sha256 IN (\(shas.map { _ in "?" }.joined(separator: ","))) ORDER BY origin = 'machine' DESC, id
            """)
        var i: Int32 = 1
        for s in shas { st.bind(i, s); i += 1 }
        while try st.step() {
            bySha[st.string(0) ?? "", default: []].append(RecordingTranscript(origin: st.string(1) ?? "machine", model: st.string(2) ?? "", modelVersion: st.string(3),
                                                                             engine: st.string(4), text: st.string(5) ?? "", segments: st.string(6)))
        }
        return rows.map { r in
            var r = r
            if let s = r.sha256 { r.transcripts = bySha[s] ?? [] }
            return r
        }
    }

    /// Canonical voicemails and memos per kind, and their total length.
    public func recordingCounts() throws -> RecordingCounts {
        try locked {
            var c = RecordingCounts()
            guard try db.tableExists("recording") else { return c }
            let st = try db.prepare("SELECT kind, count(*), coalesce(sum(duration_s), 0) FROM recording WHERE canonical_id IS NULL GROUP BY kind")
            while try st.step() {
                switch st.string(0) {
                case "voicemail": c.voicemails = Int(st.int(1))
                case "meeting": c.meetings = Int(st.int(1))
                default: c.memos += Int(st.int(1))
                }
                c.seconds += st.double(2)
            }
            return c
        }
    }

    /// Voicemails per handle (canonical rows; one with no stored handle counts for the handle its address matches now).
    public func voicemailCountsByHandle() throws -> [Int64: Int] {
        try locked {
            guard try db.tableExists("recording") else { return [:] }
            let st = try db.prepare("""
                SELECT coalesce(r.handle_id, h.id) AS hid, count(*) FROM recording r LEFT JOIN handle h ON r.handle_id IS NULL AND h.normalized = r.address
                WHERE r.canonical_id IS NULL AND r.kind = 'voicemail' GROUP BY hid
                """)
            var out: [Int64: Int] = [:]
            while try st.step() { if let h = st.optInt(0) { out[h] = Int(st.int(1)) } }
            return out
        }
    }

    /// The voicemails of a scope within `span`, oldest first: canonical voicemails left by the scope's 1:1 handles that have a time.
    /// With a service filter they show with SMS (a voicemail is a phone call that was not answered).
    public func voicemails(scope: MessageScope, in span: CallSpan, limit: Int = 500) throws -> [RecordingRow] {
        let handles = try callHandles(scope: scope)
        return try locked {
            guard try db.tableExists("recording"), !handles.isEmpty else { return [] }
            if scope.serviceFiltered, let filter = scope.services, !filter.contains(.sms) { return [] }
            var cond = "r.canonical_id IS NULL AND r.kind = 'voicemail' AND r.ts_ms IS NOT NULL"
            cond += " AND (r.handle_id IN (\(handles.map { String($0.id) }.joined(separator: ",")))"
            cond += " OR (r.handle_id IS NULL AND r.address IN (\(handles.map { _ in "?" }.joined(separator: ",")))))"
            if span.lower != nil { cond += span.lowerInclusive ? " AND r.ts_ms >= ?" : " AND r.ts_ms > ?" }
            if span.upper != nil { cond += span.upperInclusive ? " AND r.ts_ms <= ?" : " AND r.ts_ms < ?" }
            let newestFirst = span.lower == nil
            let st = try db.prepare("""
                SELECT \(try recordingColumnsSQL()) FROM recording r WHERE \(cond)
                ORDER BY r.ts_ms \(newestFirst ? "DESC" : "ASC"), r.id \(newestFirst ? "DESC" : "ASC") LIMIT \(max(0, limit))
                """)
            var i: Int32 = 1
            for h in handles { st.bind(i, h.normalized); i += 1 }
            if let l = span.lower { st.bind(i, l); i += 1 }
            if let u = span.upper { st.bind(i, u); i += 1 }
            var rows: [RecordingRow] = []
            while try st.step() { rows.append(recordingRow(st)) }
            return try withTranscripts(newestFirst ? rows.reversed() : rows, segments: false)
        }
    }

    /// Every canonical recording, newest first (those with no time last), one page: `before` is the last row of the previous page.
    /// `kind` nil = both.
    public func recordings(kind: String? = nil, before: (ts: Int64, id: Int64)? = nil, limit: Int = 50) throws -> [RecordingRow] {
        try locked {
            guard try db.tableExists("recording") else { return [] }
            var cond = "r.canonical_id IS NULL"
            if kind != nil { cond += " AND r.kind = ?" }
            if before != nil { cond += " AND (coalesce(r.ts_ms, 0) < ? OR (coalesce(r.ts_ms, 0) = ? AND r.id < ?))" }
            let st = try db.prepare("SELECT \(try recordingColumnsSQL()) FROM recording r WHERE \(cond) ORDER BY coalesce(r.ts_ms, 0) DESC, r.id DESC LIMIT \(max(0, limit))")
            var i: Int32 = 1
            if let kind { st.bind(i, kind); i += 1 }
            if let b = before { st.bind(i, b.ts).bind(i + 1, b.ts).bind(i + 2, b.id) }
            var rows: [RecordingRow] = []
            while try st.step() { rows.append(recordingRow(st)) }
            return try withTranscripts(rows, segments: false)
        }
    }

    /// One recording with its transcripts and their timings. A duplicate row's id answers with the row that won.
    public func recording(id: Int64) throws -> RecordingRow? {
        try locked {
            guard try db.tableExists("recording") else { return nil }
            let st = try db.prepare("SELECT \(try recordingColumnsSQL()) FROM recording r WHERE r.id = (SELECT coalesce(canonical_id, id) FROM recording WHERE id = ?)")
            st.bind(1, id)
            guard try st.step() else { return nil }
            return try withTranscripts([recordingRow(st)], segments: true).first
        }
    }

    /// Recordings whose transcript, title or caller's name match the words, best match first (or newest / oldest).
    public func searchRecordings(_ text: String, kind: String? = nil, order: SearchOrder = .bestMatch, limit: Int = 50, offset: Int = 0) throws -> [RecordingRow] {
        guard let match = ArchiveReader.ftsQuery(text) else { return [] }
        return try locked {
            guard try db.tableExists("recording_fts") else { return [] }
            let by: String
            switch order {
            case .newest: by = "coalesce(r.ts_ms, 0) DESC, r.id DESC"
            case .oldest: by = "coalesce(r.ts_ms, 0) ASC, r.id ASC"
            default: by = "bm25(recording_fts), coalesce(r.ts_ms, 0) DESC"
            }
            let st = try db.prepare("""
                SELECT \(try recordingColumnsSQL()), snippet(recording_fts, 0, char(1), char(2), '…', 24), snippet(recording_fts, 1, char(1), char(2), '…', 12)
                FROM recording_fts JOIN recording r ON r.id = recording_fts.ref
                WHERE recording_fts MATCH ? AND r.canonical_id IS NULL \(kind != nil ? "AND r.kind = ?" : "")
                ORDER BY \(by) LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
                """)
            st.bind(1, match)
            if let kind { st.bind(2, kind) }
            var rows: [RecordingRow] = []
            while try st.step() {
                var r = recordingRow(st)
                let body = st.string(19) ?? "", title = st.string(20) ?? ""
                r.snippet = body.contains("\u{1}") ? body : (title.contains("\u{1}") ? title : body)
                rows.append(r)
            }
            return try withTranscripts(rows, segments: false)
        }
    }

    /// The stored file of a recording's audio (its own file or its playable copy) or of a meeting's saved chat, for `/media/<sha256>`.
    public func recordingMedia(sha256: String) throws -> AttachmentInfo? {
        try locked {
            guard try db.tableExists("recording") else { return nil }
            let chat = try db.hasColumn("recording", "chat_sha256") ? " OR r.chat_sha256 = ?1" : ""
            let st = try db.prepare("""
                SELECT r.id, m.mime, m.path, m.bytes FROM recording r JOIN media m ON m.sha256 = ?1
                WHERE r.sha256 = ?1 OR r.play_sha256 = ?1\(chat) ORDER BY r.id LIMIT 1
                """)
            st.bind(1, sha256)
            guard try st.step() else { return nil }
            let path = st.string(2) ?? ""
            return AttachmentInfo(id: st.int(0), mime: st.string(1), filename: "recording-\(st.int(0)).\((path as NSString).pathExtension)", mediaPath: path,
                                  bytes: st.int(3), sha256: sha256)
        }
    }
}
