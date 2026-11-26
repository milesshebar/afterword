import Testing
import Foundation
@testable import ArchiveCore

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

/// Voicemails and voice memos: the plan importer, the reader and the web routes. Synthetic data only: the "audio" is a few
/// made-up bytes (nothing decodes it), the transcripts are invented sentences.
enum RecordingFixtures {
    static let alice = "+12125550111", bob = "+12125550122"
    static let t0: Int64 = 1_450_000_000_000
    static let columns = ["rid", "kind", "label", "source_key", "ts_ms", "dated_by", "duration_s", "title", "address", "callback", "name", "heard", "deleted",
                          "flags", "memo_uuid", "content", "sha256", "bytes", "mime", "target_path", "play_sha256", "play_bytes", "play_mime",
                          "play_target_path", "source_path", "note", "transcript_sha256"]

    struct Audio { var sha: String, bytes: Int, target: String, mime: String }

    /// Puts `text`'s bytes into the archive's media store under their own content address (as the copy step does before an import).
    @discardableResult static func place(_ text: String, ext: String, mime: String, in root: ArchiveRoot) throws -> Audio {
        let data = Data(text.utf8)
        let sha = data.withUnsafeBytes { Hashing.sha256Hex($0) }
        let rel = "media/\(sha.prefix(2))/\(sha).\(ext)"
        let url = root.resolve(relativePath: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return Audio(sha: sha, bytes: data.count, target: rel, mime: mime)
    }

    /// Writes a machine transcript JSON for an audio file and returns the JSON's sha256.
    static func transcript(_ text: String, audio: String, in folder: URL, origin: String = "machine", model: String = "test/parakeet") throws -> String {
        let obj: [String: Any] = ["sha256": audio, "model": model, "model_revision": "rev1", "engine": "parakeet-mlx", "engine_version": "0.5.1",
                                  "created_at": "2026-11-23T08:00:00Z", "text": text,
                                  "segments": text.isEmpty ? [] : [["start": 0.0, "end": 1.5, "text": text]]]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let dir = folder.appendingPathComponent(origin).appendingPathComponent(String(audio.prefix(2)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(audio + ".json"))
        return data.withUnsafeBytes { Hashing.sha256Hex($0) }
    }

    static func row(_ v: [String: String]) -> String { columns.map { v[$0] ?? "" }.joined(separator: "\t") }

    /// A voicemail row whose playable file is `play` (an AAC copy) or the audio itself.
    static func voicemail(rid: String, label: String, key: String, ts: Int64?, datedBy: String = "database", dur: Double, address: String = "", name: String = "",
                          audio: Audio?, play: Audio? = nil, transcript: String = "", heard: String = "1", extra: [String: String] = [:]) -> String {
        var v = ["rid": rid, "kind": "voicemail", "label": label, "source_key": key, "ts_ms": ts.map(String.init) ?? "", "dated_by": ts == nil ? "" : datedBy,
                 "duration_s": String(dur), "address": address, "name": name, "heard": heard, "deleted": "0", "flags": "3", "transcript_sha256": transcript]
        if let a = audio {
            let p = play ?? a
            v.merge(["sha256": a.sha, "bytes": String(a.bytes), "mime": a.mime, "target_path": a.target, "play_sha256": p.sha, "play_bytes": String(p.bytes),
                     "play_mime": p.mime, "play_target_path": p.target]) { _, n in n }
        }
        v.merge(extra) { _, n in n }
        return row(v)
    }

    static func memo(rid: String, label: String, key: String, ts: Int64?, datedBy: String = "database", dur: Double, title: String = "", uuid: String = "",
                     audio: Audio?, transcript: String = "", extra: [String: String] = [:]) -> String {
        var v = ["rid": rid, "kind": "memo", "label": label, "source_key": key, "ts_ms": ts.map(String.init) ?? "", "dated_by": ts == nil ? "" : datedBy,
                 "duration_s": String(dur), "title": title, "memo_uuid": uuid, "transcript_sha256": transcript]
        if let a = audio {
            v.merge(["sha256": a.sha, "bytes": String(a.bytes), "mime": a.mime, "target_path": a.target, "play_sha256": a.sha, "play_bytes": String(a.bytes),
                     "play_mime": a.mime, "play_target_path": a.target]) { _, n in n }
        }
        v.merge(extra) { _, n in n }
        return row(v)
    }

    static func plan(_ rows: [String], in dir: URL, name: String = "recordings.tsv") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (columns.joined(separator: "\t") + "\n" + rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An archive that knows Alice (ten texts, a name) and Bob (one text), like the calls fixture.
    static func archive() throws -> TestArchive {
        let t = try TestArchive()
        try t.db.transaction {
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('test', 'x', 'seed', 0, 0)")
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "test")
            for i in 0..<10 {
                _ = try w.add(MessageRecord(participants: [alice], sender: i % 2 == 0 ? alice : nil, tsMs: t0 + Int64(i) * 60_000, isFromMe: i % 2 == 1,
                                            service: "sms", body: "m\(i)"))
            }
            _ = try w.add(MessageRecord(participants: [bob], sender: bob, tsMs: t0 + 5_000, isFromMe: false, service: "sms", body: "bob"))
            try t.db.exec("INSERT INTO contact_name(handle_id, name, origin, priority) SELECT id, 'Alice Example', 'test', 10 FROM handle WHERE normalized = '\(alice)'")
        }
        return t
    }

    /// The base plan: a voicemail from Alice (AMR with an AAC copy), one from a number the archive does not know, one export that carries
    /// only Alice's name, and two memos (one with no audio in the source).
    static func basePlan(_ t: TestArchive, transcripts: URL) throws -> (url: URL, amr: Audio, aac: Audio, memo: Audio) {
        let amr = try place("amr-bytes-voicemail-1", ext: "amr", mime: "audio/amr", in: t.root)
        let aac = try place("aac-copy-of-voicemail-1", ext: "m4a", mime: "audio/mp4", in: t.root)
        let other = try place("amr-bytes-voicemail-2", ext: "amr", mime: "audio/amr", in: t.root)
        let otherPlay = try place("aac-copy-of-voicemail-2", ext: "m4a", mime: "audio/mp4", in: t.root)
        let export = try place("m4a-export-voicemail", ext: "m4a", mime: "audio/mp4", in: t.root)
        let memoAudio = try place("m4a-memo-kitchen", ext: "m4a", mime: "audio/mp4", in: t.root)
        let tr1 = try transcript("hey it is alice calling about the lighthouse", audio: amr.sha, in: transcripts)
        let tr2 = try transcript("", audio: other.sha, in: transcripts)                       // the model heard nothing
        let tr3 = try transcript("remember to water the ferns", audio: memoAudio.sha, in: transcripts)
        let rows = [
            voicemail(rid: "r1", label: "vm-phone-2016", key: "rowid:1", ts: t0 + 150_000, dur: 21, address: "(212) 555-0111", audio: amr, play: aac, transcript: tr1),
            voicemail(rid: "r2", label: "vm-phone-2016", key: "rowid:2", ts: t0 + 900_000, dur: 4, address: "+12125550199", audio: other, play: otherPlay, transcript: tr2, heard: "0",
                      extra: ["content": "no-speech"]),
            voicemail(rid: "r3", label: "vm-export-2020-21", key: "file:Voicemail - x - Alice Example.amr", ts: t0 + 86_400_000, datedBy: "file-name", dur: 9, name: "Alice Example",
                      audio: export, heard: ""),
            memo(rid: "r4", label: "memo-voicememos-2026-11", key: "uuid:AAAA", ts: t0 + 200_000, dur: 62.5, title: "Kitchen", uuid: "AAAA", audio: memoAudio, transcript: tr3),
            memo(rid: "r5", label: "memo-voicememos-2026-11", key: "uuid:BBBB", ts: t0 + 400_000, dur: 30, title: "Porch", uuid: "BBBB", audio: nil,
                 extra: ["note": "0-byte placeholder: the audio is in iCloud only"]),
        ]
        return (try plan(rows, in: t.dir), amr, aac, memoAudio)
    }
}

@Suite struct RecordingImportTests {
    typealias F = RecordingFixtures

    @Test func importsVoicemailsAndMemosTiesCallersAndIsIdempotent() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try F.basePlan(t, transcripts: tr)
        let handlesBefore = try q(t.db, "SELECT count(*) FROM handle")
        let ledger = t.dir.appendingPathComponent("ledger.tsv")
        let r = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root, ledger: ledger)
        #expect(r.status == .imported)
        let s = r.stats
        #expect(s.planRows == 5 && s.written == 5 && s.alreadyThere == 0 && s.voicemails == 3 && s.memos == 2)
        #expect(s.withAudio == 4 && s.withoutAudio == 1)
        #expect(s.newMediaRows == 6)                     // two AMR files with their AAC copies, the export, the memo
        #expect(s.transcripts == 3 && s.canonical == 5 && s.duplicates == 0)
        #expect(try q(t.db, "SELECT count(*) FROM handle") == handlesBefore)                   // no handle for the unknown number
        // Alice's voicemail is tied to her handle and thread by its number; the export by its name; the unknown number to nothing
        let aliceH = try q(t.db, "SELECT id FROM handle WHERE normalized = '\(F.alice)'")
        #expect(try q(t.db, "SELECT handle_id FROM recording WHERE source_key = 'rowid:1'") == aliceH)
        #expect(try qs(t.db, "SELECT address FROM recording WHERE source_key = 'rowid:1'") == F.alice)   // stored normalized
        #expect(try q(t.db, "SELECT thread_id IS NOT NULL FROM recording WHERE source_key = 'rowid:1'") == 1)
        #expect(try q(t.db, "SELECT handle_id FROM recording WHERE source_label = 'vm-export-2020-21'") == aliceH)
        #expect(try q(t.db, "SELECT handle_id IS NULL AND thread_id IS NULL FROM recording WHERE source_key = 'rowid:2'") == 1)
        #expect(s.linkedToHandle == 2 && s.linkedToThread == 2)
        // the playable copy is its own media row; a file browsers play is its own playable file
        #expect(try qs(t.db, "SELECT play_sha256 FROM recording WHERE source_key = 'rowid:1'") == p.aac.sha)
        #expect(try q(t.db, "SELECT sha256 = play_sha256 FROM recording WHERE source_key = 'uuid:AAAA'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM media WHERE sha256 IN ('\(p.amr.sha)', '\(p.aac.sha)', '\(p.memo.sha)')") == 3)
        #expect(try q(t.db, "SELECT sha256 IS NULL AND play_sha256 IS NULL FROM recording WHERE source_key = 'uuid:BBBB'") == 1)
        // transcripts are keyed by the audio, with the model that made them; an empty one is kept as "heard nothing"
        #expect(try qs(t.db, "SELECT model || '|' || model_version || '|' || engine FROM recording_transcript WHERE sha256 = '\(p.amr.sha)'") == "test/parakeet|rev1|parakeet-mlx 0.5.1")
        #expect(try q(t.db, "SELECT count(*) FROM recording_transcript WHERE text = ''") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM recording_fts WHERE recording_fts MATCH 'lighthouse'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM recording_fts WHERE recording_fts MATCH 'kitchen'") == 1)   // a memo's title is searchable
        // the ledger: one line per plan row, each "new", each its own canonical row
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }
        #expect(lines.count == 6 && lines[0][0] == "rid" && lines.dropFirst().allSatisfy { $0[4] == "new" && $0[5] == $0[13] })
        #expect(try q(t.db, "SELECT count(*) FROM source WHERE kind = 'recordings-plan'") == 1)

        // the same plan again: already imported, nothing added, the ledger republished from the database
        let before = try q(t.db, "SELECT count(*) FROM recording") + (try q(t.db, "SELECT count(*) FROM media")) + (try q(t.db, "SELECT count(*) FROM recording_transcript"))
        try FileManager.default.removeItem(at: ledger)
        let again = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root, ledger: ledger)
        #expect(again.status == .alreadyImported && again.stats == s)
        #expect(try q(t.db, "SELECT count(*) FROM recording") + (try q(t.db, "SELECT count(*) FROM media")) + (try q(t.db, "SELECT count(*) FROM recording_transcript")) == before)
        #expect(FileManager.default.fileExists(atPath: ledger.path))
        #expect(try q(t.db, "SELECT count(*) FROM source WHERE kind = 'recordings-plan'") == 1)
    }

    @Test func aLaterPlanAddsOnlyWhatIsNewAndASecondSourceFoldsIn() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try F.basePlan(t, transcripts: tr)
        _ = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root)
        // A later phone backup: the same voicemail as rowid:1 under another row id (same bytes), the Porch memo WITH its audio (same Voice
        // Memos id), the Kitchen memo re-encoded (other bytes, same start and length), and one new voicemail.
        let porch = try F.place("m4a-memo-porch-from-the-phone", ext: "m4a", mime: "audio/mp4", in: t.root)
        let kitchen2 = try F.place("m4a-memo-kitchen-reencoded", ext: "m4a", mime: "audio/mp4", in: t.root)
        let fresh = try F.place("m4a-voicemail-new", ext: "m4a", mime: "audio/mp4", in: t.root)
        let trPorch = try F.transcript("the porch light is out", audio: porch.sha, in: tr)
        let rows = [
            F.voicemail(rid: "s1", label: "vm-phone-2026", key: "rowid:77", ts: F.t0 + 150_000, dur: 21, address: F.alice, audio: p.amr, play: p.aac),
            F.memo(rid: "s2", label: "memo-phone-2026", key: "uuid:BBBB", ts: F.t0 + 400_000, dur: 30, title: "Porch", uuid: "BBBB", audio: porch, transcript: trPorch),
            F.memo(rid: "s3", label: "memo-itunes", key: "file:20151213 kitchen.m4a", ts: F.t0 + 201_000, datedBy: "file-name", dur: 62.9, audio: kitchen2),
            F.voicemail(rid: "s4", label: "vm-phone-2026", key: "rowid:78", ts: F.t0 + 5_000_000, dur: 12, address: F.bob, audio: fresh),
            // the base plan's first row again, unchanged: already there
            F.voicemail(rid: "r1", label: "vm-phone-2016", key: "rowid:1", ts: F.t0 + 150_000, dur: 21, address: "(212) 555-0111", audio: p.amr, play: p.aac),
        ]
        let second = try F.plan(rows, in: t.dir, name: "second.tsv")
        let r = try RecordingImporter.run(plan: second, transcripts: tr, into: t.db, root: t.root)
        let s = r.stats
        #expect(r.status == .imported && s.written == 4 && s.alreadyThere == 1)
        #expect(s.newMediaRows == 3 && s.transcripts == 1)
        #expect(s.totalRows == 9 && s.canonical == 6 && s.duplicates == 3)
        // same bytes: the newer phone's row wins by label order, the older row is linked to it, not dropped
        let newVM = try q(t.db, "SELECT id FROM recording WHERE source_key = 'rowid:77'")
        #expect(try q(t.db, "SELECT canonical_id FROM recording WHERE source_key = 'rowid:1'") == newVM)
        #expect(try q(t.db, "SELECT canonical_id IS NULL FROM recording WHERE source_key = 'rowid:77'") == 1)
        // same Voice Memos id: the row that has the audio wins over the library row that had none
        let porchRow = try q(t.db, "SELECT id FROM recording WHERE source_label = 'memo-phone-2026'")
        #expect(try q(t.db, "SELECT canonical_id FROM recording WHERE source_label = 'memo-voicememos-2026-11' AND source_key = 'uuid:BBBB'") == porchRow)
        // other bytes, same start (1 s apart) and length (0.4 s apart): one recording; the library row outranks the iTunes copy
        let kitchen = try q(t.db, "SELECT id FROM recording WHERE source_key = 'uuid:AAAA'")
        #expect(try q(t.db, "SELECT canonical_id FROM recording WHERE source_label = 'memo-itunes'") == kitchen)
        // search follows the canonical rows: the porch memo is found once, through the row that has its audio and transcript
        #expect(try q(t.db, "SELECT count(*) FROM recording_fts") == 6)
        #expect(try q(t.db, "SELECT ref FROM recording_fts WHERE recording_fts MATCH 'porch light'") == porchRow)
        #expect(try q(t.db, "SELECT count(*) FROM recording r WHERE canonical_id IS NOT NULL AND (SELECT canonical_id FROM recording c WHERE c.id = r.canonical_id) IS NOT NULL") == 0)   // flat
        // verify counts a recording's audio and its playable copy as used media, and checks the recording tables
        let v = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(v.passed, "\(v.lines.filter { $0.hasPrefix("FAIL") })")
        #expect(v.lines.contains { $0.contains("recordings: search rows 6 == canonical recordings 6") })
        try t.db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(String(repeating: "e", count: 64))', 'media/ee/x.m4a', 1, NULL)")
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).lines.contains { $0.hasPrefix("FAIL") && $0.contains("no attachment, post, recording or voice message uses") })
    }

    @Test func exportTimesNeverLinkByTime() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let a = try F.place("shared-voicemail-a", ext: "m4a", mime: "audio/mp4", in: t.root)
        let b = try F.place("shared-voicemail-b", ext: "m4a", mime: "audio/mp4", in: t.root)
        // two different voicemails shared out of the phone in the same second, the same length: only their export time is known
        let rows = [F.voicemail(rid: "a", label: "vm-shared-2021-23", key: "file:voicemail-1.m4a", ts: F.t0, datedBy: "export-time", dur: 10, audio: a, heard: ""),
                    F.voicemail(rid: "b", label: "vm-shared-2021-23", key: "file:voicemail-2.m4a", ts: F.t0 + 1_000, datedBy: "export-time", dur: 10, audio: b, heard: "")]
        let r = try RecordingImporter.run(plan: try F.plan(rows, in: t.dir), transcripts: nil, into: t.db, root: t.root)
        #expect(r.stats.canonical == 2 && r.stats.duplicates == 0)
    }

    @Test func aMissingOrChangedFileRefusesTheWholePlan() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try F.basePlan(t, transcripts: tr)
        let sources = try q(t.db, "SELECT count(*) FROM source"), media = try q(t.db, "SELECT count(*) FROM media")
        func nothingWritten() throws {
            #expect(try q(t.db, "SELECT count(*) FROM source") == sources && (try q(t.db, "SELECT count(*) FROM media")) == media)
            #expect(try !t.db.tableExists("recording") || (try q(t.db, "SELECT count(*) FROM recording")) == 0)
        }
        // the playable copy is not in the store
        let aacURL = t.root.resolve(relativePath: p.aac.target)
        let saved = try Data(contentsOf: aacURL)
        try FileManager.default.removeItem(at: aacURL)
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root) }
        try nothingWritten()
        // the same size, other bytes
        try Data(String(repeating: "x", count: saved.count).utf8).write(to: aacURL)
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root) }
        try nothingWritten()
        try saved.write(to: aacURL)
        // a transcript file changed after the plan was written
        let trFile = tr.appendingPathComponent("machine/\(p.memo.sha.prefix(2))/\(p.memo.sha).json")
        let trSaved = try Data(contentsOf: trFile)
        try Data(#"{"model":"test/parakeet","text":"something else"}"#.utf8).write(to: trFile)
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root) }
        try nothingWritten()
        // no transcripts folder at all
        try trSaved.write(to: trFile)
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: p.url, transcripts: nil, into: t.db, root: t.root) }
        try nothingWritten()
        #expect(try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root).stats.written == 5)
    }

    @Test func aDryRunDecidesAsARunAndWritesNothing() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try F.basePlan(t, transcripts: tr)
        let ledger = t.dir.appendingPathComponent("dry.tsv")
        let dry = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root, dryRun: true, ledger: ledger)
        #expect(dry.stats.written == 5 && dry.stats.newMediaRows == 6 && dry.stats.transcripts == 3 && dry.sourceID == nil)
        #expect(try !t.db.tableExists("recording") && (try q(t.db, "SELECT count(*) FROM media")) == 0 && (try q(t.db, "SELECT count(*) FROM source")) == 1)
        #expect(try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").count == 6)
        let real = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root)
        #expect(real.stats.written == dry.stats.written && real.stats.newMediaRows == dry.stats.newMediaRows && real.stats.transcripts == dry.stats.transcripts)
    }

    @Test func aRowThatIsThereWithOtherValuesRefuses() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let memo = try F.place("m4a-memo", ext: "m4a", mime: "audio/mp4", in: t.root)
        _ = try RecordingImporter.run(plan: try F.plan([F.memo(rid: "a", label: "memo-voicememos-2026-11", key: "uuid:X", ts: F.t0, dur: 10, title: "One", uuid: "X", audio: memo)], in: t.dir),
                                      transcripts: nil, into: t.db, root: t.root)
        let changed = try F.plan([F.memo(rid: "a", label: "memo-voicememos-2026-11", key: "uuid:X", ts: F.t0, dur: 10, title: "Renamed", uuid: "X", audio: memo)], in: t.dir, name: "changed.tsv")
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: changed, transcripts: nil, into: t.db, root: t.root) }
        #expect(try qs(t.db, "SELECT title FROM recording") == "One" && (try q(t.db, "SELECT count(*) FROM source WHERE kind = 'recordings-plan'")) == 1)
    }

    @Test func badPlansAreRefusedBeforeAnythingIsRead() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let memo = try F.place("m4a-memo", ext: "m4a", mime: "audio/mp4", in: t.root)
        func refuses(_ rows: [String], _ name: String) throws {
            #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try F.plan(rows, in: t.dir, name: name), transcripts: nil, into: t.db, root: t.root) }
            #expect(try !t.db.tableExists("recording"))
        }
        let good = F.memo(rid: "a", label: "l", key: "k", ts: F.t0, dur: 1, audio: memo)
        try refuses([good, good], "twice.tsv")                                                                    // the same row twice
        try refuses([good.replacingOccurrences(of: "\tmemo\t", with: "\tcall\t")], "kind.tsv")
        try refuses([good.replacingOccurrences(of: memo.target, with: "media/zz/../../etc/passwd")], "path.tsv")    // not the store's own name
        try refuses([F.memo(rid: "a", label: "l", key: "k", ts: F.t0, datedBy: "guess", dur: 1, audio: memo)], "dated.tsv")
        try refuses([F.memo(rid: "a", label: "l", key: "k", ts: nil, dur: 1, audio: nil, extra: ["transcript_sha256": String(repeating: "a", count: 64)])], "noaudio.tsv")
        try refuses([good + "\textra"], "fields.tsv")
    }

    /// Edge cases as tests.
    @Test func aDuplicateRowBringsItsOtherIdentifiersToTheGroup() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let x = try F.place("bytes-x", ext: "m4a", mime: "audio/mp4", in: t.root), y = try F.place("bytes-y", ext: "m4a", mime: "audio/mp4", in: t.root)
        // A (bytes X, id U), B (bytes Y, id U), C (bytes Y, no id), none with a time: one recording, all linked straight to one winner
        let rows = [F.memo(rid: "a", label: "memo-voicememos-2026-11", key: "a", ts: nil, dur: 5, uuid: "U", audio: x),
                    F.memo(rid: "b", label: "memo-itunes", key: "b", ts: nil, dur: 5, uuid: "U", audio: y),
                    F.memo(rid: "c", label: "memo-loose", key: "c", ts: nil, dur: 5, audio: y)]
        let r = try RecordingImporter.run(plan: try F.plan(rows, in: t.dir), transcripts: nil, into: t.db, root: t.root)
        #expect(r.stats.canonical == 1 && r.stats.duplicates == 2)
        let a = try q(t.db, "SELECT id FROM recording WHERE source_key = 'a'")
        #expect(try q(t.db, "SELECT count(*) FROM recording WHERE canonical_id = \(a)") == 2 && (try q(t.db, "SELECT count(*) FROM recording_fts")) == 1)
    }

    @Test func transcriptsMustNameTheirAudioAndAgreeAcrossRows() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let tr = t.dir.appendingPathComponent("transcripts")
        let a = try F.place("audio-a", ext: "m4a", mime: "audio/mp4", in: t.root)
        let good = try F.transcript("the right words", audio: a.sha, in: tr)
        func refuses(_ rows: [String], _ name: String) throws {
            #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try F.plan(rows, in: t.dir, name: name), transcripts: tr, into: t.db, root: t.root) }
            #expect(try !t.db.tableExists("recording"))
        }
        // two rows of the same audio naming different transcript files
        try refuses([F.memo(rid: "a", label: "l", key: "a", ts: nil, dur: 1, audio: a, transcript: good),
                     F.memo(rid: "b", label: "l", key: "b", ts: nil, dur: 1, audio: a, transcript: String(repeating: "b", count: 64))], "two.tsv")
        // a transcript file that does not say which audio it is of, or names it with the wrong type: its own hash is right, it is still refused
        let file = tr.appendingPathComponent("machine/\(a.sha.prefix(2))/\(a.sha).json")
        for body in [#"{"model":"m","text":"words from another recording"}"#, #"{"sha256":123,"model":"m","text":"words from another recording"}"#] {
            try Data(body.utf8).write(to: file)
            let h = Data(body.utf8).withUnsafeBytes { Hashing.sha256Hex($0) }
            try refuses([F.memo(rid: "a", label: "l", key: "a", ts: nil, dur: 1, audio: a, transcript: h)], "untyped.tsv")
        }
    }

    @Test func aSymlinkedMediaFolderIsRefusedAndNeverServed() throws {
        let t = try F.archive(); defer { t.cleanup() }
        // the bytes sit outside the store; the store's two-hex folder is a symlink to them
        let data = Data("outside-bytes".utf8)
        let sha = data.withUnsafeBytes { Hashing.sha256Hex($0) }
        let outside = t.dir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try data.write(to: outside.appendingPathComponent(sha + ".m4a"))
        try FileManager.default.createDirectory(at: t.root.mediaURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: t.root.mediaURL.appendingPathComponent(String(sha.prefix(2))), withDestinationURL: outside)
        let audio = F.Audio(sha: sha, bytes: data.count, target: "media/\(sha.prefix(2))/\(sha).m4a", mime: "audio/mp4")
        #expect(!t.root.mediaContains(relativePath: audio.target))
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try F.plan([F.memo(rid: "a", label: "l", key: "a", ts: nil, dur: 1, audio: audio)], in: t.dir), transcripts: nil, into: t.db, root: t.root) }
        #expect(try !t.db.tableExists("recording"))
        // and a row that names such a path (written some other way) is not served
        try RecordingImporter.ensureTables(t.db)
        try t.db.exec("INSERT INTO media(sha256, path, bytes, mime) VALUES ('\(sha)', '\(audio.target)', \(data.count), 'audio/mp4')")
        try t.db.exec("INSERT INTO recording(kind, source_id, source_label, source_key, duration_s, sha256, play_sha256) VALUES ('memo', 1, 'l', 'a', 1, '\(sha)', '\(sha)')")
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(try WebService(root: t.root).mediaFile(sha256: sha) == nil)
    }

    @Test func wildDurationsAreRefusedAndTheClockNeverTraps() throws {
        let t = try F.archive(); defer { t.cleanup() }
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try F.plan([F.memo(rid: "a", label: "l", key: "a", ts: nil, dur: 1e100, audio: nil)], in: t.dir), transcripts: nil, into: t.db, root: t.root) }
        #expect(RecordingRow.clock(1e100) == "744:00:00" && RecordingRow.clock(-5) == "0:00" && RecordingRow.clock(.nan) == "0:00" && RecordingRow.clock(222) == "3:42")
        #expect(RecordingRow.clock(360_000) == "100:00:00")      // second review: every accepted length reads whole
    }

    /// A voicemail shared out of the Phone app is a re-encoded copy with no time of its own: a later plan can name the phone's own row
    /// it is a copy of, also for a row that is already in the archive (the table of the first import had no `same_as` column).
    @Test func aPlanCanNameTheRowACopyBelongsTo() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let shared = try F.place("aac-shared-copy", ext: "m4a", mime: "audio/mp4", in: t.root)
        let first = try F.plan([F.voicemail(rid: "a", label: "vm-shared-2021-23", key: "file:voicemail-1.m4a", ts: F.t0 + 9_000_000, datedBy: "export-time", dur: 10.2, audio: shared, heard: "")], in: t.dir)
        _ = try RecordingImporter.run(plan: first, transcripts: nil, into: t.db, root: t.root)
        // the state of an archive imported before the column existed
        try t.db.exec("ALTER TABLE recording DROP COLUMN same_as")
        let amr = try F.place("amr-on-the-phone", ext: "amr", mime: "audio/amr", in: t.root), aac = try F.place("aac-of-the-phone-amr", ext: "m4a", mime: "audio/mp4", in: t.root)
        let phone = F.voicemail(rid: "p", label: "vm-phone-2026", key: "rowid:5", ts: F.t0, dur: 10, address: F.alice, audio: amr, play: aac)
        let again = F.voicemail(rid: "a", label: "vm-shared-2021-23", key: "file:voicemail-1.m4a", ts: F.t0 + 9_000_000, datedBy: "export-time", dur: 10.2, audio: shared, heard: "")
        func withSame(_ row: String, _ label: String, _ key: String) -> String { row + "\t" + label + "\t" + key }
        func plan(_ rows: [String], _ name: String) throws -> URL {
            let url = t.dir.appendingPathComponent(name)
            try ((F.columns + ["same_as_label", "same_as_key"]).joined(separator: "\t") + "\n" + rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        // refused: a target nobody has, a target of another kind, a row that is its own copy
        let memo = try F.place("m4a-memo", ext: "m4a", mime: "audio/mp4", in: t.root)
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try plan([withSame(phone, "", ""), withSame(again, "vm-phone-2026", "rowid:99")], "bad1.tsv"), transcripts: nil, into: t.db, root: t.root) }
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try plan([withSame(F.memo(rid: "m", label: "l", key: "k", ts: nil, dur: 1, audio: memo), "", ""), withSame(again, "l", "k")], "bad2.tsv"), transcripts: nil, into: t.db, root: t.root) }
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try plan([withSame(again, "vm-shared-2021-23", "file:voicemail-1.m4a")], "bad3.tsv"), transcripts: nil, into: t.db, root: t.root) }
        #expect(try q(t.db, "SELECT count(*) FROM recording") == 1)
        // a refused plan leaves nothing: no column added, no source, media or transcript row (the ALTER TABLE rolls back with the rest)
        #expect(try !t.db.hasColumn("recording", "same_as") && (try q(t.db, "SELECT count(*) FROM source WHERE kind = 'recordings-plan'")) == 1)
        #expect(try q(t.db, "SELECT count(*) FROM media") == 1 && (try q(t.db, "SELECT count(*) FROM recording_transcript")) == 0)
        // the real second plan: the phone's row is new, the shared row is already there and is tied to it
        let ledger = t.dir.appendingPathComponent("l2.tsv")
        let r = try RecordingImporter.run(plan: try plan([withSame(phone, "", ""), withSame(again, "vm-phone-2026", "rowid:5")], "second.tsv"), transcripts: nil, into: t.db, root: t.root, ledger: ledger)
        #expect(r.stats.written == 1 && r.stats.alreadyThere == 1 && r.stats.canonical == 1 && r.stats.duplicates == 1)
        let phoneID = try q(t.db, "SELECT id FROM recording WHERE source_key = 'rowid:5'")
        #expect(try q(t.db, "SELECT canonical_id FROM recording WHERE source_label = 'vm-shared-2021-23'") == phoneID)     // the phone's own row wins
        #expect(try q(t.db, "SELECT same_as FROM recording WHERE source_label = 'vm-shared-2021-23'") == phoneID)
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }
        #expect(lines[0].last == "same_as" && lines[2][4] == "already-there" && lines[2].last == "\(phoneID)" && lines[1].last == "")
        // the tie survives the next import's re-linking, and a later plan cannot re-tie the row to something else
        let other = try F.place("another-voicemail", ext: "m4a", mime: "audio/mp4", in: t.root)
        let third = try plan([withSame(F.voicemail(rid: "o", label: "vm-phone-2026", key: "rowid:6", ts: F.t0 + 50_000, dur: 3, audio: other), "", "")], "third.tsv")
        #expect(try RecordingImporter.run(plan: third, transcripts: nil, into: t.db, root: t.root).stats.duplicates == 1)
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: try plan([withSame(again, "vm-phone-2026", "rowid:6")], "retie.tsv"), transcripts: nil, into: t.db, root: t.root) }
        #expect(try q(t.db, "SELECT same_as FROM recording WHERE source_label = 'vm-shared-2021-23'") == phoneID)
        // the same refusal in a dry run when the new target is a row this plan would add (it has no id yet)
        let newTarget = try F.place("a-new-target", ext: "m4a", mime: "audio/mp4", in: t.root)
        let retieNew = try plan([withSame(F.voicemail(rid: "n", label: "vm-phone-2026", key: "rowid:7", ts: F.t0 + 90_000, dur: 4, audio: newTarget), "", ""),
                                 withSame(again, "vm-phone-2026", "rowid:7")], "retie-new.tsv")
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: retieNew, transcripts: nil, into: t.db, root: t.root, dryRun: true) }
        #expect(throws: ArchiveError.self) { try RecordingImporter.run(plan: retieNew, transcripts: nil, into: t.db, root: t.root) }
        // a dry run of a same_as plan on an archive that predates the column decides the same and writes nothing
        let t2 = try F.archive(); defer { t2.cleanup() }
        let shared2 = try F.place("aac-shared-copy", ext: "m4a", mime: "audio/mp4", in: t2.root)
        _ = try F.place("amr-on-the-phone", ext: "amr", mime: "audio/amr", in: t2.root); _ = try F.place("aac-of-the-phone-amr", ext: "m4a", mime: "audio/mp4", in: t2.root)
        _ = shared2
        _ = try RecordingImporter.run(plan: first, transcripts: nil, into: t2.db, root: t2.root)
        try t2.db.exec("ALTER TABLE recording DROP COLUMN same_as")
        let dry = try RecordingImporter.run(plan: try plan([withSame(phone, "", ""), withSame(again, "vm-phone-2026", "rowid:5")], "dry.tsv"), transcripts: nil, into: t2.db, root: t2.root, dryRun: true)
        #expect(dry.stats.written == 1 && dry.stats.alreadyThere == 1)
        #expect(try !t2.db.hasColumn("recording", "same_as") && (try q(t2.db, "SELECT count(*) FROM recording")) == 1)
    }

    @Test func aNameAloneTiesOnlyWhenItIsOnePerson() throws {
        let t = try F.archive(); defer { t.cleanup() }
        // "Sam Twin" is the name of two numbers the matcher keeps apart; "Alice Example" is one person; a first name alone never ties
        try t.db.transaction {
            let w = try ArchiveWriter(db: t.db, sourceID: 1, sourceKind: "test")
            for n in ["+12125550131", "+12125550132"] {
                _ = try w.add(MessageRecord(participants: [n], sender: n, tsMs: F.t0, isFromMe: false, service: "sms", body: "hi"))
                try t.db.exec("INSERT INTO contact_name(handle_id, name, origin, priority) SELECT id, 'Sam Twin', 'test', 10 FROM handle WHERE normalized = '\(n)'")
            }
        }
        let a = try F.place("vm-a", ext: "m4a", mime: "audio/mp4", in: t.root), b = try F.place("vm-b", ext: "m4a", mime: "audio/mp4", in: t.root)
        let c = try F.place("vm-c", ext: "m4a", mime: "audio/mp4", in: t.root)
        let rows = [F.voicemail(rid: "a", label: "x", key: "a", ts: F.t0, datedBy: "file-name", dur: 5, name: "Sam Twin", audio: a),
                    F.voicemail(rid: "b", label: "x", key: "b", ts: F.t0 + 60_000, datedBy: "file-name", dur: 6, name: "alice example", audio: b),
                    F.voicemail(rid: "c", label: "x", key: "c", ts: F.t0 + 120_000, datedBy: "file-name", dur: 7, name: "Alice", audio: c)]
        _ = try RecordingImporter.run(plan: try F.plan(rows, in: t.dir), transcripts: nil, into: t.db, root: t.root)
        #expect(try q(t.db, "SELECT handle_id IS NULL FROM recording WHERE source_key = 'a'") == 1)
        #expect(try q(t.db, "SELECT handle_id = (SELECT id FROM handle WHERE normalized = '\(F.alice)') FROM recording WHERE source_key = 'b'") == 1)
        #expect(try q(t.db, "SELECT handle_id IS NULL FROM recording WHERE source_key = 'c'") == 1)
    }
}

@Suite struct RecordingsReaderTests {
    typealias F = RecordingFixtures

    static func imported() throws -> (TestArchive, ArchiveReader, amr: F.Audio, aac: F.Audio) {
        let t = try F.archive()
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try F.basePlan(t, transcripts: tr)
        _ = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root)
        // a voicemail whose number reached the archive only later: stored with no handle, found by its address
        try t.db.exec("UPDATE recording SET handle_id = NULL, thread_id = NULL WHERE source_key = 'rowid:1'")
        return (t, try ArchiveReader(root: t.root), p.amr, p.aac)
    }

    @Test func anArchiveWithoutTheTablesHasNoRecordings() throws {
        let t = try F.archive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        #expect(try !r.hasRecordings() && r.recordings().isEmpty && r.recordingCounts() == RecordingCounts() && r.voicemailCountsByHandle().isEmpty)
        #expect(try r.searchRecordings("anything").isEmpty && r.recording(id: 1) == nil && r.recordingMedia(sha256: String(repeating: "a", count: 64)) == nil)
        #expect(try r.voicemails(scope: MessageScope(thread: 1), in: .all).isEmpty)
    }

    @Test func aVoicemailSitsInItsCallersTimelineAtItsTime() throws {
        let (t, r, amr, aac) = try Self.imported(); defer { t.cleanup() }
        let aliceThread = try t.db.scalarInt("SELECT t.id FROM thread t JOIN thread_member tm ON tm.thread_id = t.id JOIN handle h ON h.id = tm.handle_id WHERE h.normalized = '\(F.alice)'")
        let scope = MessageScope(thread: aliceThread)
        let all = try r.voicemails(scope: scope, in: .all)
        #expect(all.map(\.tsMs) == [F.t0 + 150_000, F.t0 + 86_400_000])          // by address, and the export tied by her name; oldest first
        #expect(all[0].sha256 == amr.sha && all[0].playSha256 == aac.sha && all[0].playMime == "audio/mp4" && all[0].heard == true)
        #expect(all[0].transcripts.map(\.text) == ["hey it is alice calling about the lighthouse"] && all[0].transcripts[0].origin == "machine")
        #expect(all[1].heard == nil && all[1].transcripts.isEmpty && all[1].timeIsOwn)
        // the spans of the message pages decide which page carries it
        #expect(try r.voicemails(scope: scope, in: CallSpan(lower: F.t0, upper: F.t0 + 200_000)).count == 1)
        #expect(try r.voicemails(scope: scope, in: CallSpan(lower: F.t0 + 150_000, lowerInclusive: false, upper: nil)).count == 1)
        // a voicemail is a phone call: it shows with SMS, not under another service's filter
        #expect(try r.voicemails(scope: MessageScope(threads: [aliceThread], services: [.sms]), in: .all).count == 2)
        #expect(try r.voicemails(scope: MessageScope(threads: [aliceThread], services: [.messenger]), in: .all).isEmpty)
        let bobThread = try t.db.scalarInt("SELECT t.id FROM thread t JOIN thread_member tm ON tm.thread_id = t.id JOIN handle h ON h.id = tm.handle_id WHERE h.normalized = '\(F.bob)'")
        #expect(try r.voicemails(scope: MessageScope(thread: bobThread), in: .all).isEmpty)
        let aliceH = try t.db.scalarInt("SELECT id FROM handle WHERE normalized = '\(F.alice)'")
        #expect(try r.voicemailCountsByHandle() == [aliceH: 2])
    }

    @Test func theListPagesNewestFirstAndSearchReadsTranscripts() throws {
        let (t, r, _, aac) = try Self.imported(); defer { t.cleanup() }
        let c = try r.recordingCounts()
        #expect(c.voicemails == 3 && c.memos == 2 && c.seconds == 21 + 4 + 9 + 62.5 + 30)
        let first = try r.recordings(limit: 2)
        #expect(first.map(\.tsMs) == [F.t0 + 86_400_000, F.t0 + 900_000])
        let rest = try r.recordings(before: (first[1].tsMs!, first[1].id), limit: 10)
        #expect(rest.map(\.tsMs) == [F.t0 + 400_000, F.t0 + 200_000, F.t0 + 150_000])
        #expect(try r.recordings(kind: "memo").map(\.title) == ["Porch", "Kitchen"])
        #expect(try r.recordings(kind: "memo")[0].sha256 == nil)                       // listed even though the source held no audio
        let hits = try r.searchRecordings("lighthouse")
        #expect(hits.count == 1 && hits[0].isVoicemail && hits[0].snippet?.contains("\u{1}lighthouse\u{2}") == true)
        #expect(try r.searchRecordings("ferns", kind: "voicemail").isEmpty && r.searchRecordings("ferns", kind: "memo").count == 1)
        #expect(try r.searchRecordings("kitchen").first?.snippet?.contains("\u{1}Kitchen\u{2}") == true)    // a title match shows the title
        // one recording, with the timings
        let one = try #require(try r.recording(id: hits[0].id))
        #expect(one.transcripts[0].segments?.contains("\"start\":0") == true)
        // the audio is served by either hash; a hash no recording names is not
        #expect(try r.recordingMedia(sha256: aac.sha)?.mediaPath == aac.target && r.recordingMedia(sha256: aac.sha)?.isAudio == true)
        #expect(try r.recordingMedia(sha256: String(repeating: "0", count: 64)) == nil)
    }
}
