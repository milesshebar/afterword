import Testing
import Foundation
@testable import ArchiveCore

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

/// Voice messages on threads and recorded meetings. Synthetic data only: the "audio" is a few made-up bytes, the transcripts
/// invented sentences.
enum VoiceFixtures {
    typealias F = RecordingFixtures
    static let columns = ["rid", "sha256", "bytes", "target_path", "play_sha256", "play_bytes", "play_mime", "play_target_path", "duration_s", "content",
                          "transcript_sha256", "class", "service", "first_message"]

    /// Attaches a placed file to Alice's message `i` (a canonical message of the fixture archive) with its media row, as an import would.
    static func attach(_ a: F.Audio, toMessage i: Int, in t: TestArchive, mime: String = "audio/x-caf", name: String = "Audio Message.caf") throws {
        let mid = try q(t.db, "SELECT id FROM message WHERE body = 'm\(i)' AND canonical_id IS NULL")
        try t.db.exec("INSERT OR IGNORE INTO media(sha256, path, bytes, mime) VALUES ('\(a.sha)', '\(a.target)', \(a.bytes), '\(mime)')")
        try t.db.exec("""
            INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (\(mid), '\(mime)', '\(name)', '\(a.target)', \(a.bytes), '\(a.sha)')
            """)
    }

    static func row(rid: String, audio: F.Audio, play: F.Audio? = nil, dur: Double, content: String, transcript: String) -> String {
        let p = play ?? audio
        let v = ["rid": rid, "sha256": audio.sha, "bytes": String(audio.bytes), "target_path": audio.target, "play_sha256": p.sha, "play_bytes": String(p.bytes),
                 "play_mime": "audio/mp4", "play_target_path": p.target, "duration_s": String(dur), "content": content, "transcript_sha256": transcript,
                 "class": "voice message or memo", "service": "imessage", "first_message": "1"]
        return columns.map { v[$0] ?? "" }.joined(separator: "\t")
    }

    static func plan(_ rows: [String], in dir: URL, name: String = "voice-messages.tsv") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (columns.joined(separator: "\t") + "\n" + rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Two voice messages on Alice's thread: a CAF one with an AAC copy (words), an M4A one that is its own playable file (no words).
    static func base(_ t: TestArchive, transcripts: URL) throws -> (url: URL, caf: F.Audio, aac: F.Audio, m4a: F.Audio) {
        let caf = try F.place("caf-opus-voice-message-1", ext: "caf", mime: "audio/x-caf", in: t.root)
        let aac = try F.place("aac-copy-of-voice-message-1", ext: "m4a", mime: "audio/mp4", in: t.root)
        let m4a = try F.place("m4a-voice-memo-shared", ext: "m4a", mime: "audio/x-m4a", in: t.root)
        try attach(caf, toMessage: 2, in: t)
        try attach(m4a, toMessage: 4, in: t, mime: "audio/x-m4a", name: "123 Main St.m4a")
        let tr1 = try F.transcript("meet me at the observatory at nine", audio: caf.sha, in: transcripts)
        let tr2 = try F.transcript("", audio: m4a.sha, in: transcripts)
        let rows = [row(rid: "v1", audio: caf, play: aac, dur: 7.5, content: "speech", transcript: tr1),
                    row(rid: "v2", audio: m4a, dur: 12, content: "no-speech", transcript: tr2)]
        return (try plan(rows, in: t.dir), caf, aac, m4a)
    }
}

@Suite(.serialized) struct VoiceMessageTests {
    typealias F = RecordingFixtures
    typealias V = VoiceFixtures

    @Test func importsTranscriptsBesideTheMessagesAndIsIdempotent() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try V.base(t, transcripts: tr)
        let messagesBefore = try q(t.db, "SELECT count(*) || '|' || (SELECT count(*) FROM attachment) FROM message")
        let ledger = t.dir.appendingPathComponent("ledger.tsv")
        // a dry run writes nothing
        let dry = try VoiceMessageImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root, dryRun: true)
        #expect(dry.stats.written == 2 && dry.stats.newMediaRows == 1)
        #expect(try q(t.db, "SELECT count(*) FROM sqlite_master WHERE name = 'voice_message'") == 0)
        let r = try VoiceMessageImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root, ledger: ledger)
        #expect(r.status == .imported)
        #expect(r.stats.written == 2 && r.stats.withWords == 1 && r.stats.noWords == 1 && r.stats.playableCopies == 1)
        #expect(r.stats.newMediaRows == 1 && r.stats.transcripts == 2 && r.stats.messages == 2 && r.stats.totalRows == 2)
        // the messages stay the messages
        #expect(try q(t.db, "SELECT count(*) || '|' || (SELECT count(*) FROM attachment) FROM message") == messagesBefore)
        #expect(try qs(t.db, "SELECT play_sha256 FROM voice_message WHERE sha256 = '\(p.caf.sha)'") == p.aac.sha)
        #expect(try qs(t.db, "SELECT model FROM recording_transcript WHERE sha256 = '\(p.caf.sha)' AND origin = 'machine'") == "test/parakeet")
        #expect(try q(t.db, "SELECT count(*) FROM voice_message_fts") == 1)            // the one with words
        #expect(try q(t.db, "SELECT count(*) FROM source WHERE kind = 'voice-messages-plan'") == 1)
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3 && lines[1].contains("\tnew\t"))
        // verify accepts a transcript of a voice message's audio (not a recording's) and the new media row
        let report = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(!report.lines.contains { $0.hasPrefix("FAIL") && ($0.contains("transcript") || $0.contains("voice") || $0.contains("unreferenced")) })
        // the same plan again: already imported
        let again = try VoiceMessageImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root)
        #expect(again.status == .alreadyImported && again.stats == r.stats)
        // an overlapping plan (another hash): the row is already there, nothing new
        let tr1 = try F.transcript("meet me at the observatory at nine", audio: p.caf.sha, in: tr)
        let p2 = try V.plan([V.row(rid: "w1", audio: p.caf, play: p.aac, dur: 7.5, content: "speech", transcript: tr1)], in: t.dir, name: "second.tsv")
        let r2 = try VoiceMessageImporter.run(plan: p2, transcripts: tr, into: t.db, root: t.root)
        #expect(r2.stats.written == 0 && r2.stats.alreadyThere == 1 && r2.stats.transcriptsAlready == 1)
    }

    @Test func refusesWhatIsNotAnAttachmentOrDoesNotHash() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try V.base(t, transcripts: tr)
        // audio no message carries
        let loose = try F.place("loose-audio-no-message", ext: "caf", mime: "audio/x-caf", in: t.root)
        try t.db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(loose.sha)', '\(loose.target)', \(loose.bytes), 'audio/x-caf')")
        let trL = try F.transcript("words", audio: loose.sha, in: tr)
        let bad1 = try V.plan([V.row(rid: "x", audio: loose, dur: 1, content: "speech", transcript: trL)], in: t.dir, name: "bad1.tsv")
        #expect(throws: (any Error).self) { try VoiceMessageImporter.run(plan: bad1, transcripts: tr, into: t.db, root: t.root) }
        // content that disagrees with the transcript
        let tr1 = try F.transcript("meet me at the observatory at nine", audio: p.caf.sha, in: tr)
        let bad2 = try V.plan([V.row(rid: "x", audio: p.caf, play: p.aac, dur: 7.5, content: "no-speech", transcript: tr1)], in: t.dir, name: "bad2.tsv")
        #expect(throws: (any Error).self) { try VoiceMessageImporter.run(plan: bad2, transcripts: tr, into: t.db, root: t.root) }
        // a playable copy that is not in the store as planned
        try FileManager.default.removeItem(at: t.root.resolve(relativePath: p.aac.target))
        #expect(throws: (any Error).self) { try VoiceMessageImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root) }
        #expect(try q(t.db, "SELECT count(*) FROM sqlite_master WHERE name = 'voice_message'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM source WHERE kind = 'voice-messages-plan'") == 0)
    }

    @Test func messagesCarryTheTranscriptAndSearchFindsTheMessage() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try V.base(t, transcripts: tr)
        _ = try VoiceMessageImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root)
        _ = try PeopleStore.rematch(db: t.db)
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let reader = try ArchiveReader(root: t.root)
        // search: the message whose audio says the words is a hit, marked as a voice hit; text hits still come
        let hits = try reader.search("observatory", scope: nil)
        let m2 = try q(t.db, "SELECT id FROM message WHERE body = 'm2' AND canonical_id IS NULL")
        #expect(hits.count == 1 && hits[0].messageID == m2 && hits[0].isVoice && hits[0].snippet.contains("\u{1}observatory\u{2}"))
        #expect(try reader.search("m3", scope: nil).allSatisfy { !$0.isVoice })
        // a text hit and a voice hit for the same word merge in the asked order, and page across both lists
        try t.db.transaction {
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('test', 'y', 'seed2', 0, 0)")
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "test")
            _ = try w.add(MessageRecord(participants: [F.bob], sender: F.bob, tsMs: F.t0 + 3_600_000, isFromMe: false, service: "sms", body: "observatory tour"))
        }
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let r2 = try ArchiveReader(root: t.root)
        let newest = try r2.search("observatory", scope: nil, order: .newest)
        #expect(newest.count == 2 && !newest[0].isVoice && newest[1].isVoice)
        let oldest = try r2.search("observatory", scope: nil, order: .oldest)
        #expect(oldest.map(\.messageID) == newest.reversed().map(\.messageID))
        #expect(try r2.search("observatory", scope: nil, order: .oldest, limit: 1, offset: 1).map(\.messageID) == [newest[0].messageID])
        // the web: the attachment plays its copy and carries the transcript; /api/voice gives the timings; the copy is served
        let site = WebSite(service: try WebService(root: t.root))
        func get(_ path: String, _ query: [String: String] = [:]) -> HTTPRequest {
            HTTPRequest(method: "GET", path: path, query: query, headers: ["Host": "127.0.0.1:8452", "X-Requested-With": WebSite.requestedWith], peer: "127.0.0.1")
        }
        let aliceThread = try q(t.db, "SELECT thread_id FROM message WHERE id = \(m2)")
        let page = (try JSONSerialization.jsonObject(with: site.handle(get("/api/messages", ["thread": "\(aliceThread)", "limit": "40"])).body)) as? [String: Any] ?? [:]
        let atts = (page["messages"] as? [[String: Any]] ?? []).flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
        let caf = atts.first { $0["sha"] as? String == p.caf.sha }
        #expect(caf?["play"] as? String == p.aac.sha && caf?["duration"] as? Double == 7.5)
        let t0 = (caf?["transcripts"] as? [[String: Any]])?.first
        #expect(t0?["text"] as? String == "meet me at the observatory at nine" && t0?["origin"] as? String == "machine" && t0?["segments"] == nil)
        let m4a = atts.first { $0["sha"] as? String == p.m4a.sha }
        #expect(m4a?["play"] as? String == p.m4a.sha && ((m4a?["transcripts"] as? [[String: Any]])?.first?["text"] as? String) == "")
        let one = (try JSONSerialization.jsonObject(with: site.handle(get("/api/voice/\(p.caf.sha)")).body)) as? [[String: Any]] ?? []
        #expect(one.count == 1 && one[0]["model"] as? String == "test/parakeet" && (one[0]["segments"] as? [[String: Any]])?.count == 1)
        #expect(site.handle(get("/api/voice/\(String(repeating: "a", count: 64))")).status == 404)
        #expect(site.handle(get("/api/voice/nothex")).status == 400)
        #expect(site.handle(get("/media/\(p.aac.sha)")).status == 200)
        let sh = (try JSONSerialization.jsonObject(with: site.handle(get("/api/search", ["q": "observatory", "order": "oldest"])).body)) as? [[String: Any]] ?? []
        #expect(sh.count == 2 && sh[0]["voice"] as? Bool == true && sh[1]["voice"] == nil)
    }

    @Test func aMeetingWithItsChatGoesInAsItsOwnKind() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let video = try F.place("mp4-zoom-meeting-video", ext: "mp4", mime: "video/mp4", in: t.root)
        let sound = try F.place("m4a-zoom-meeting-sound", ext: "m4a", mime: "audio/mp4", in: t.root)
        let chat = try F.place("00:02:45\tSomeone:\tMay I speak next?\n", ext: "txt", mime: "text/plain", in: t.root)
        let trv = try F.transcript("thank you all for coming today", audio: video.sha, in: tr)
        var cols = F.columns + ["chat_sha256", "chat_bytes", "chat_target_path"]
        func line(_ v: [String: String]) -> String { cols.map { v[$0] ?? "" }.joined(separator: "\t") }
        let v: [String: String] = ["rid": "m1", "kind": "meeting", "label": "meeting-zoom-test", "source_key": "file:a.mp4", "ts_ms": String(F.t0), "dated_by": "file-name",
                                   "duration_s": "4663.4", "title": "A team meeting (Zoom)", "content": "speech", "sha256": video.sha, "bytes": String(video.bytes),
                                   "mime": "video/mp4", "target_path": video.target, "play_sha256": sound.sha, "play_bytes": String(sound.bytes), "play_mime": "audio/mp4",
                                   "play_target_path": sound.target, "note": "speakers not attributed", "transcript_sha256": trv, "chat_sha256": chat.sha,
                                   "chat_bytes": String(chat.bytes), "chat_target_path": chat.target]
        let url = t.dir.appendingPathComponent("meetings.tsv")
        try (cols.joined(separator: "\t") + "\n" + line(v) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let r = try RecordingImporter.run(plan: url, transcripts: tr, into: t.db, root: t.root)
        #expect(r.status == .imported && r.stats.meetings == 1 && r.stats.memos == 0 && r.stats.newMediaRows == 3)
        #expect(try qs(t.db, "SELECT chat_sha256 FROM recording WHERE kind = 'meeting'") == chat.sha)
        let report = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(!report.lines.contains { $0.hasPrefix("FAIL") && $0.contains("unreferenced") })
        let reader = try ArchiveReader(root: t.root)
        #expect(try reader.recordingCounts().meetings == 1)
        let row = try reader.recordings(kind: "meeting").first
        #expect(row?.chatSha256 == chat.sha && row?.isMeeting == true && row?.transcripts.first?.text == "thank you all for coming today")
        #expect(try reader.recordingMedia(sha256: chat.sha) != nil)
        // only a meeting has a chat; a chat needs all three columns
        var bad = v; bad["kind"] = "memo"; bad["rid"] = "m2"; bad["source_key"] = "file:b.mp4"
        try (cols.joined(separator: "\t") + "\n" + line(bad) + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try RecordingImporter.run(plan: url, transcripts: tr, into: t.db, root: t.root) }
        cols.removeLast()
        try (cols.joined(separator: "\t") + "\n" + line(v) + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try RecordingImporter.run(plan: url, transcripts: tr, into: t.db, root: t.root) }
        // the web lists it under its own kind with its chat
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let site = WebSite(service: try WebService(root: t.root))
        let req = HTTPRequest(method: "GET", path: "/api/recordings", query: ["kind": "meeting"], headers: ["Host": "127.0.0.1:8452", "X-Requested-With": WebSite.requestedWith], peer: "127.0.0.1")
        let page = (try JSONSerialization.jsonObject(with: site.handle(req).body)) as? [String: Any] ?? [:]
        let rows = page["recordings"] as? [[String: Any]] ?? []
        #expect(rows.count == 1 && rows[0]["chat"] as? String == chat.sha && rows[0]["audio"] as? String == sound.sha && page["meetings"] as? Int == 1)
        let chatReq = HTTPRequest(method: "GET", path: "/media/\(chat.sha)", query: [:], headers: ["Host": "127.0.0.1:8452"], peer: "127.0.0.1")
        #expect(site.handle(chatReq).headers["Content-Type"] == "text/plain; charset=utf-8")      // shown, not downloaded
    }

    /// One hit per message whatever the page, a message represented by its text hit when its text matches, a dry
    /// run that never replaces a ledger, a transcript shared with a recording (kept, and searchable from both), several models in one row.
    @Test func searchAndPagingEdgeCasesHold() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        // m1 carries two voice messages that both say "harbor"; m3 one; m5's text and its voice message both say it ("harbor" is added to m5's body)
        let a = try F.place("voice-a", ext: "caf", mime: "audio/x-caf", in: t.root), b = try F.place("voice-b", ext: "caf", mime: "audio/x-caf", in: t.root)
        let c = try F.place("voice-c", ext: "caf", mime: "audio/x-caf", in: t.root), d = try F.place("voice-d", ext: "caf", mime: "audio/x-caf", in: t.root)
        try V.attach(a, toMessage: 1, in: t); try V.attach(b, toMessage: 1, in: t); try V.attach(c, toMessage: 3, in: t); try V.attach(d, toMessage: 5, in: t)
        try t.db.exec("UPDATE message SET body = 'm5 harbor' WHERE body = 'm5'")
        try t.db.exec("INSERT INTO message_fts(message_fts) VALUES ('rebuild')")
        // d is also a memo's audio, transcribed by the same model when it was imported as a recording
        let memoTr = try F.transcript("the harbor at dawn", audio: d.sha, in: tr)
        _ = try RecordingImporter.run(plan: try F.plan([F.memo(rid: "r1", label: "memo-voicememos-2026-11", key: "uuid:D", ts: F.t0, dur: 3, title: "Pier", uuid: "D", audio: d, transcript: memoTr)], in: t.dir),
                                      transcripts: tr, into: t.db, root: t.root)
        let trs = try [a, b, c].map { try F.transcript("harbor lights \($0.sha.prefix(4))", audio: $0.sha, in: tr) }
        let dAgain = try F.transcript("harbor at dawn, again", audio: d.sha, in: tr)     // another run of the same model: the memo's stays
        let rows = [V.row(rid: "a", audio: a, dur: 1, content: "speech", transcript: trs[0]), V.row(rid: "b", audio: b, dur: 1, content: "speech", transcript: trs[1]),
                    V.row(rid: "c", audio: c, dur: 1, content: "speech", transcript: trs[2]), V.row(rid: "d", audio: d, dur: 3, content: "speech", transcript: dAgain)]
        let plan = try V.plan(rows, in: t.dir)
        let ledger = t.dir.appendingPathComponent("dry-ledger.tsv")
        try "keep me".write(to: ledger, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try VoiceMessageImporter.run(plan: plan, transcripts: tr, into: t.db, root: t.root, dryRun: true, ledger: ledger) }
        #expect(try String(contentsOf: ledger, encoding: .utf8) == "keep me")
        let r = try VoiceMessageImporter.run(plan: plan, transcripts: tr, into: t.db, root: t.root)
        #expect(r.stats.written == 4 && r.stats.transcripts == 3 && r.stats.transcriptsAlready == 1)
        #expect(try qs(t.db, "SELECT text FROM recording_transcript WHERE sha256 = '\(d.sha)'") == "the harbor at dawn")
        // a second model's transcript of a: one search row holding both, and the verifier content
        let other = try F.transcript("harbour lights", audio: a.sha, in: tr, model: "test/whisper")
        let p2 = try V.plan([V.row(rid: "a2", audio: a, dur: 1, content: "speech", transcript: other)], in: t.dir, name: "second.tsv")
        _ = try VoiceMessageImporter.run(plan: p2, transcripts: tr, into: t.db, root: t.root)
        #expect(try q(t.db, "SELECT count(*) FROM voice_message_fts WHERE ref = '\(a.sha)'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM voice_message_fts WHERE voice_message_fts MATCH 'harbour'") == 1)
        #expect(!(try ArchiveVerifier.run(db: t.db, root: t.root)).lines.contains { $0.hasPrefix("FAIL") && $0.contains("voice") })
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let reader = try ArchiveReader(root: t.root)
        let m1 = try q(t.db, "SELECT id FROM message WHERE body = 'm1'"), m3 = try q(t.db, "SELECT id FROM message WHERE body = 'm3'")
        let m5 = try q(t.db, "SELECT id FROM message WHERE body = 'm5 harbor'")
        for order in [SearchOrder.bestMatch, .newest, .oldest] {
            let all = try reader.search("harbor", scope: nil, order: order)
            #expect(all.count == 3 && Set(all.map(\.messageID)) == [m1, m3, m5])
            #expect(all.first { $0.messageID == m5 }?.isVoice == false)            // its text matches: the text hit represents it
            let paged = try (0..<3).flatMap { try reader.search("harbor", scope: nil, order: order, limit: 1, offset: $0) }
            #expect(paged.map(\.messageID) == all.map(\.messageID))
        }
        // the memo shares d's bytes: the recordings' search finds it by the words of its (kept) transcript
        #expect(try reader.searchRecordings("dawn").count == 1)
    }
}
