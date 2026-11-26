import Foundation

// Read side of voice messages on threads (VoiceMessageImporter): the machine transcript and playable copy of an attachment's audio,
// keyed by the audio's sha256. Read-only; an archive without the tables reads as having none.

/// What the archive holds beside one voice message's audio: what a browser plays, its length, and the machine transcript(s).
public struct VoiceMessageInfo: Sendable, Hashable {
    public var sha256: String
    public var playSha256: String
    public var playMime: String?
    public var durationS: Double
    /// speech | no-speech
    public var content: String?
    public var transcripts: [RecordingTranscript] = []
}

extension ArchiveReader {
    /// The voice-message search over `voice_message_fts`, shaped like the message search's own query (ArchiveReader.search binds the words,
    /// a limit and an offset): one row per canonical message carrying the matched audio.
    static func voiceSearchSQL(scopeSQL: String, orderBy: String) -> String {
        """
        SELECT m.id, m.thread_id, m.ts_ms, m.is_from_me, h.normalized,
               (SELECT name FROM contact_name c WHERE c.handle_id = h.id ORDER BY priority DESC, name LIMIT 1),
               snippet(voice_message_fts, 0, char(1), char(2), '…', 16), m.service, voice_message_fts.rank AS rank
        FROM voice_message_fts JOIN attachment a ON a.sha256 = voice_message_fts.ref JOIN message m ON m.id = a.message_id
        LEFT JOIN handle h ON h.id = m.sender_handle_id
        WHERE voice_message_fts MATCH ? AND m.canonical_id IS NULL\(scopeSQL)
        \(orderBy) LIMIT ? OFFSET ?
        """
    }

    /// True when the archive has transcribed voice messages.
    public func hasVoiceMessages() throws -> Bool {
        try locked { try db.tableExists("voice_message") }
    }

    /// The voice-message rows of these audio files (attachment sha256s), with their transcripts; files without a row are absent.
    public func voiceMessages(shas: Set<String>, segments: Bool = false) throws -> [String: VoiceMessageInfo] {
        guard !shas.isEmpty else { return [:] }
        return try locked {
            guard try db.tableExists("voice_message") else { return [:] }
            var out: [String: VoiceMessageInfo] = [:]
            let list = Array(shas)
            // in slices, so a page with many attachments never exceeds SQLite's variable limit
            for start in stride(from: 0, to: list.count, by: 500) {
                let part = list[start..<min(start + 500, list.count)]
                let marks = part.map { _ in "?" }.joined(separator: ",")
                let st = try db.prepare("""
                    SELECT v.sha256, v.play_sha256, (SELECT m.mime FROM media m WHERE m.sha256 = v.play_sha256), v.duration_s, v.content
                    FROM voice_message v WHERE v.sha256 IN (\(marks))
                    """)
                var i: Int32 = 1
                for s in part { st.bind(i, s); i += 1 }
                while try st.step() {
                    let sha = st.string(0) ?? ""
                    out[sha] = VoiceMessageInfo(sha256: sha, playSha256: st.string(1) ?? sha, playMime: st.string(2), durationS: st.double(3), content: st.string(4))
                }
                let tr = try db.prepare("""
                    SELECT sha256, origin, model, model_version, engine, text, \(segments ? "segments" : "NULL") FROM recording_transcript
                    WHERE sha256 IN (\(marks)) ORDER BY origin = 'machine' DESC, id
                    """)
                i = 1
                for s in part { tr.bind(i, s); i += 1 }
                while try tr.step() {
                    let sha = tr.string(0) ?? ""
                    guard out[sha] != nil else { continue }
                    out[sha]!.transcripts.append(RecordingTranscript(origin: tr.string(1) ?? "machine", model: tr.string(2) ?? "", modelVersion: tr.string(3),
                                                                     engine: tr.string(4), text: tr.string(5) ?? "", segments: tr.string(6)))
                }
            }
            return out
        }
    }

    /// The newest canonical message carrying a voice message with words (the Mac app's snapshot opens it), or nil.
    public func newestVoiceMessage() throws -> (messageID: Int64, threadID: Int64)? {
        try locked {
            guard try db.tableExists("voice_message") else { return nil }
            let st = try db.prepare("""
                SELECT m.id, m.thread_id FROM voice_message v JOIN attachment a ON a.sha256 = v.sha256 JOIN message m ON m.id = a.message_id
                WHERE m.canonical_id IS NULL AND v.content = 'speech' ORDER BY m.ts_ms DESC LIMIT 1
                """)
            return try st.step() ? (st.int(0), st.int(1)) : nil
        }
    }

    /// Transcribed voice messages (distinct audio files) and their total length.
    public func voiceMessageCounts() throws -> (files: Int, seconds: Double) {
        try locked {
            guard try db.tableExists("voice_message") else { return (0, 0) }
            let st = try db.prepare("SELECT count(*), coalesce(sum(duration_s), 0) FROM voice_message")
            guard try st.step() else { return (0, 0) }
            return (Int(st.int(0)), st.double(1))
        }
    }

    /// The stored playable copy of a voice message (the attachment's own file is served as an attachment), for `/media/<sha256>`.
    public func voiceMessageMedia(sha256: String) throws -> AttachmentInfo? {
        try locked {
            guard try db.tableExists("voice_message") else { return nil }
            let st = try db.prepare("""
                SELECT m.mime, m.path, m.bytes FROM voice_message v JOIN media m ON m.sha256 = v.play_sha256 WHERE v.play_sha256 = ? LIMIT 1
                """)
            st.bind(1, sha256)
            guard try st.step() else { return nil }
            let path = st.string(1) ?? ""
            return AttachmentInfo(id: 0, mime: st.string(0), filename: "voice-message.\((path as NSString).pathExtension)", mediaPath: path, bytes: st.int(2), sha256: sha256)
        }
    }
}
