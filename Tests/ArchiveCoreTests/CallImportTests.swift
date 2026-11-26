import Testing
import Foundation
@testable import ArchiveCore

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum CallFixtures {
    static let header = "source\tsource_key\taddress\tname\tts\tduration\tdirection\toutcome\tservice\n"
    typealias Row = (source: String, key: String, address: String, name: String, ts: Int, dur: Int, dir: String, outcome: String, service: String)

    static func tsv(_ rows: [Row], extraLines: [String] = []) -> URL {
        let dir = Fixtures.tempDir("calls")
        var s = header
        for r in rows { s += "\(r.source)\t\(r.key)\t\(r.address)\t\(r.name)\t\(r.ts)\t\(r.dur)\t\(r.dir)\t\(r.outcome)\t\(r.service)\n" }
        for l in extraLines { s += l + "\n" }
        try! s.write(to: dir.appendingPathComponent("calls.tsv"), atomically: true, encoding: .utf8)
        try! "source\tdescription\tfiles\trows\nmac\tthis Mac\tCallHistory.storedata=abc\t1\n".write(to: dir.appendingPathComponent("sources.tsv"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The base set: a call the Mac and the phone backup both hold (same unique id), the same call without an id in an older log (number +
    /// time), an Android call, a WhatsApp and a Skype call, and a call two years after the last phone log.
    static let t0 = 1_600_000_000
    static let rows: [Row] = [
        ("phone-2026", "UID-1", "(212) 555-0111", "Alice A", t0, 120, "out", "answered", "phone"),
        ("mac", "UID-1", "+12125550111", "", t0, 120, "out", "answered", "phone"),                          // same call, same id
        ("phone-2024", "", "212-555-0111", "", t0 + 1, 119, "out", "answered", "phone"),                      // same call, no id, 1 s off
        ("phone-2026", "UID-2", "+12125550122", "", t0 + 5000, 0, "in", "missed", "phone"),
        ("android-xml", "", "+12125550133", "Carol C", t0 - 3_000_000, 60, "in", "answered", "phone"),
        ("whatsapp-app", "WA-1", "15550000002", "", t0 + 9000, 30, "in", "answered", "whatsapp"),
        ("skype-2011", "skype:me:7", "erin.ex", "Erin", t0 + 100, 40, "out", "answered", "skype"),
        ("mac", "UID-9", "+12125550111", "", t0 + 200 * 86_400, 10, "in", "answered", "facetime-audio"),   // 200 days after the last phone log
    ]
}

@Suite struct CallImportTests {
    /// An archive that already knows Alice's number and a thread with her, so handles and threads link without being created.
    func archiveWithAlice() throws -> TestArchive {
        let t = try TestArchive()
        try t.db.transaction {
            let ins = try t.db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('test', 'x', 'seed', 0, 0)")
            try ins.run()
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "test")
            _ = try w.add(MessageRecord(participants: ["+12125550111"], sender: "+12125550111", tsMs: 1_000, isFromMe: false, service: "sms", body: "hi"))
        }
        return t
    }

    @Test func dedupesAcrossLogsKeepsEverySourceAndLinksKnownHandles() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let dir = CallFixtures.tsv(CallFixtures.rows); defer { try? FileManager.default.removeItem(at: dir) }
        let handlesBefore = try q(t.db, "SELECT count(*) FROM handle")
        let r = try CallImporter.importExport(at: dir, into: t.db)
        #expect(r.status == .imported)
        let s = r.stats
        #expect(s.rows == 8 && s.totalRows == 8 && s.bad == 0)
        // three rows are the same call: the newest phone's own log wins, the Mac row and the older log's row are linked, not dropped
        #expect(s.canonical == 6 && s.duplicates == 2)
        #expect(try q(t.db, "SELECT count(*) FROM call") == 8)
        #expect(try qs(t.db, "SELECT source_label FROM call WHERE source_key = 'UID-1' AND canonical_id IS NULL") == "phone-2026")
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE canonical_id IS NOT NULL AND source_label IN ('mac', 'phone-2024') AND duration_s >= 119") == 2)
        // per source: rows and canonical
        #expect(s.perSource["mac"]?.rows == 2 && s.perSource["mac"]?.canonical == 1 && s.perSource["mac"]?.duplicates == 1)
        #expect(s.perSource["phone-2024"]?.rows == 1 && s.perSource["phone-2024"]?.canonical == 0)
        #expect(s.perSource["phone-2026"]?.rows == 2 && s.perSource["phone-2026"]?.canonical == 2)
        #expect(s.perSource["android-xml"]?.rows == 1 && s.perSource["skype-2011"]?.rows == 1 && s.perSource["whatsapp-app"]?.rows == 1)
        #expect(try q(t.db, "SELECT count(*) FROM call_source") == 6)
        #expect(try qs(t.db, "SELECT description FROM call_source WHERE label = 'mac'") == "this Mac")
        // numbers are normalized the way handles are; known handles and their 1:1 thread link, nothing new is created
        #expect(try qs(t.db, "SELECT DISTINCT address FROM call WHERE source_key = 'UID-1' OR source_label = 'phone-2024'") == "+12125550111")
        #expect(try qs(t.db, "SELECT address FROM call WHERE source_label = 'whatsapp-app'") == "wa:15550000002")
        #expect(try qs(t.db, "SELECT address FROM call WHERE source_label = 'skype-2011'") == "sk:erin.ex")
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE handle_id IS NOT NULL AND thread_id IS NOT NULL") == 4)   // the 3 Alice calls + her FaceTime
        #expect(try q(t.db, "SELECT count(*) FROM handle") == handlesBefore)
        #expect(try qs(t.db, "SELECT name FROM call WHERE source_label = 'android-xml'") == "Carol C")
        // the Android call is 35 days before the first iPhone call (no gap); the FaceTime call 200 days after the first (199 after the last phone call) is one
        #expect(s.gaps.count == 1 && s.gaps[0].hasSuffix("(199 days)"))
    }

    @Test func twoCallsInOneLogAreNotMergedEvenIfTheyLookAlike() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let t0 = CallFixtures.t0
        let dir = CallFixtures.tsv([
            ("mac", "A", "+12125550111", "", t0, 0, "in", "missed", "phone"),
            ("mac", "B", "+12125550111", "", t0 + 1, 0, "in", "missed", "phone"),       // a redial a second later: its own call
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try CallImporter.importExport(at: dir, into: t.db).stats
        #expect(s.totalRows == 2 && s.canonical == 2 && s.duplicates == 0)
    }

    @Test func rerunIsSkippedAndAnOverlappingExportAddsOnlyNewRows() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let dir = CallFixtures.tsv(CallFixtures.rows); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CallImporter.importExport(at: dir, into: t.db)
        #expect(try CallImporter.importExport(at: dir, into: t.db).status == .alreadyImported)
        #expect(try q(t.db, "SELECT count(*) FROM call") == 8)
        let more = CallFixtures.tsv(CallFixtures.rows + [("mac", "UID-10", "+12125550111", "", CallFixtures.t0 + 300 * 86_400, 5, "out", "answered", "phone")])
        defer { try? FileManager.default.removeItem(at: more) }
        let r2 = try CallImporter.importExport(at: more, into: t.db)
        #expect(r2.status == .imported && r2.stats.rows == 1 && r2.stats.alreadyThere == 8)
        #expect(r2.stats.totalRows == 9 && r2.stats.canonical == 7)
    }

    /// A Mac's log (`mac-old`) added on top of an existing import: a call a phone backup already holds links to it
    /// (same unique id), calls inside the old hole are new and canonical and split it, and a rerun adds nothing.
    @Test func macBookProLogLinksToThePhoneAndFillsTheHole() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let day = 86_400, base = 1_500_000_000
        let first = CallFixtures.tsv([
            ("android-xml", "", "+12125550133", "", base, 60, "in", "answered", "phone"),
            ("phone-2023", "U-11", "+12125550111", "", base + 1000 * day, 60, "out", "answered", "phone"),
        ])
        defer { try? FileManager.default.removeItem(at: first) }
        #expect(try CallImporter.importExport(at: first, into: t.db).stats.gaps.count == 1)
        let mbp = CallFixtures.tsv([
            ("mac-old", "U-11", "+12125550111", "", base + 1000 * day, 60, "out", "answered", "phone"),      // the phone's call, via iCloud
            ("mac-old", "U-M1", "+12125550111", "", base + 500 * day, 300, "in", "answered", "facetime-video"), // in the hole
            ("mac-old", "U-M2", "+12125550133", "", base + 900 * day, 0, "in", "missed", "phone"),
        ])
        defer { try? FileManager.default.removeItem(at: mbp) }
        let s = try CallImporter.importExport(at: mbp, into: t.db).stats
        #expect(s.rows == 3 && s.totalRows == 5)
        #expect(s.perSource["mac-old"]?.rows == 3 && s.perSource["mac-old"]?.canonical == 2 && s.perSource["mac-old"]?.duplicates == 1)
        #expect(try qs(t.db, "SELECT source_label FROM call WHERE source_key = 'U-11' AND canonical_id IS NULL") == "phone-2023")
        // the 1,000-day hole is split by the two Mac calls (days 500 and 900) into 500, 400 and 100 days
        #expect(s.gaps.count == 3 && s.gaps[0].hasSuffix("(500 days)") && s.gaps[2].hasSuffix("(100 days)"))
        #expect(try q(t.db, "SELECT max(days) FROM call_gap") == 500)
        #expect(try qs(t.db, "SELECT value FROM meta WHERE key = 'calls.hole'")?.contains("500 days") == true)
        #expect(try CallImporter.importExport(at: mbp, into: t.db).status == .alreadyImported)
    }

    /// A late log (`late-mac-2021`) is added after the others: it links to calls the table already holds
    /// (by unique id, or by number and time) and never re-points an existing row, even an Android row it would outrank as `mac-2021`.
    @Test func aLogAddedLaterNeverTakesOverExistingRows() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let base = 1_500_000_000
        let first = CallFixtures.tsv([
            ("android-xml", "", "+12125550133", "", base, 60, "in", "answered", "phone"),
            ("phone-2016", "U-6", "+12125550111", "", base + 5000, 30, "out", "answered", "phone"),
        ])
        defer { try? FileManager.default.removeItem(at: first) }
        _ = try CallImporter.importExport(at: first, into: t.db)
        let before = try q(t.db, "SELECT count(*) FROM call WHERE canonical_id IS NULL")
        let later = CallFixtures.tsv([
            ("late-mac-2021", "U-A", "+12125550133", "", base + 1, 60, "in", "answered", "phone"),     // the Android call
            ("late-mac-2021", "U-6", "+12125550111", "", base + 5000, 30, "out", "answered", "phone"), // the older phone's call
            ("late-mac-2021", "U-N", "+12125550111", "", base + 9000, 0, "in", "missed", "phone"),     // new
        ])
        defer { try? FileManager.default.removeItem(at: later) }
        let s = try CallImporter.importExport(at: later, into: t.db).stats
        #expect(s.rows == 3)
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE source_label IN ('android-xml', 'phone-2016') AND canonical_id IS NOT NULL") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE canonical_id IS NULL") == before + 1)
        #expect(s.perSource["late-mac-2021"]?.canonical == 1 && s.perSource["late-mac-2021"]?.duplicates == 2)
        #expect(CallImporter.rank("late-mac-2021") > CallImporter.rank("an-unlisted-log"))
    }

    /// A second calls-import must add nothing: the message-calls pass that runs after every calls.tsv used to leave an empty
    /// `calls-from-messages` source row each time even when it found no new call line.
    @Test func aMessageCallsPassThatAddsNothingLeavesNoSourceRow() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let dir = CallFixtures.tsv(CallFixtures.rows); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CallImporter.importExport(at: dir, into: t.db)
        _ = try CallImporter.importMessageCalls(into: t.db)
        let sources = try q(t.db, "SELECT count(*) FROM source")
        let again = try CallImporter.importMessageCalls(into: t.db)
        #expect(again.rows == 0)
        #expect(try q(t.db, "SELECT count(*) FROM source") == sources)
        #expect(try q(t.db, "SELECT count(*) FROM call") == 8)
    }

    /// A log added later ranks after every existing log, listed in `priority` or not.
    @Test func aLogAddedLaterRanksAfterUnlistedLogsToo() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let base = 1_500_000_000
        let first = CallFixtures.tsv([("some-new-log", "", "+12125550133", "", base, 60, "in", "answered", "phone")])
        defer { try? FileManager.default.removeItem(at: first) }
        _ = try CallImporter.importExport(at: first, into: t.db)
        let later = CallFixtures.tsv([("late-mac-2021", "U-A", "+12125550133", "", base + 1, 60, "in", "answered", "phone")])
        defer { try? FileManager.default.removeItem(at: later) }
        _ = try CallImporter.importExport(at: later, into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE source_label = 'some-new-log' AND canonical_id IS NULL") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE source_label = 'late-mac-2021' AND canonical_id IS NOT NULL") == 1)
    }

    @Test func badRowsAreCountedNotStored() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let dir = CallFixtures.tsv([CallFixtures.rows[0]], extraLines: ["mac\tK\t+1212\t\tnotatime\t5\tin\tmissed\tphone", "mac\tK2\t+1212\t\t0\t5\tin\tmissed\tphone", "short\tline"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CallImporter.importExport(at: dir, into: t.db)
        #expect(r.stats.rows == 1 && r.stats.bad == 3)
    }

    @Test func gapsInThePhoneRecordAreRecorded() throws {
        let t = try archiveWithAlice(); defer { t.cleanup() }
        let day = 86_400, base = 1_500_000_000
        let rows: [CallFixtures.Row] = [
            ("android-xml", "", "+12125550133", "", base, 60, "in", "answered", "phone"),
            ("android-xml", "", "+12125550133", "", base + 30 * day, 60, "in", "answered", "phone"),        // 30 days: not a gap
            ("phone-2024", "K1", "+12125550133", "", base + 1000 * day, 60, "in", "answered", "phone"),       // 970 days: the hole
            ("whatsapp-app", "W1", "15550000002", "", base + 500 * day, 60, "in", "answered", "whatsapp"),  // WhatsApp does not fill a phone gap
        ]
        let dir = CallFixtures.tsv(rows); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try CallImporter.importExport(at: dir, into: t.db).stats
        #expect(s.gaps.count == 1 && s.gaps[0].hasSuffix("(970 days)"))
        #expect(try q(t.db, "SELECT count(*) FROM call_gap") == 1 && (try q(t.db, "SELECT days FROM call_gap")) == 970)
        #expect(try qs(t.db, "SELECT value FROM meta WHERE key = 'calls.hole'")?.contains("970 days") == true)
    }

    @Test func messengerAndInstagramCallLinesBecomeCallRows() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.db.transaction {
            try t.db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('meta', 'x', 'seed', 0, 0)").run()
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "meta")
            func call(_ ts: Int64, _ fromMe: Bool, _ note: String, _ svc: String) throws {
                var r = MessageRecord(participants: [], sender: nil, tsMs: ts, isFromMe: fromMe, service: svc)
                r.participantHandles = [svc == "messenger" ? ServiceHandle.facebook(name: "Dana Demo") : ServiceHandle.instagram(name: "dana")]
                if !fromMe { r.senderHandle = r.participantHandles[0] }
                r.kind = "call"; r.note = note
                _ = try w.add(r)
            }
            try call(1_000_000, false, "The video call ended. (Duration: 29 minutes)", "messenger")
            try call(2_000_000, true, "A contact missed your video call.", "messenger")
            try call(3_000_000, false, "You missed a call from Dana.", "messenger")
            try call(4_000_000, true, "Audio call ended", "instagram")
            try call(5_000_000, true, "You started an audio call", "instagram")
            try t.db.exec("UPDATE thread SET service = 'messenger' WHERE key LIKE 'fb:%'")
            try t.db.exec("UPDATE thread SET service = 'instagram' WHERE key LIKE 'ig:%'")
        }
        let s = try CallImporter.importMessageCalls(into: t.db)
        #expect(s.rows == 5 && s.totalRows == 5 && s.canonical == 5)
        #expect(s.perSource["messenger"]?.rows == 3 && s.perSource["instagram"]?.rows == 2)
        #expect(try qs(t.db, "SELECT direction || outcome || duration_s FROM call WHERE ts_ms = 1000000") == "inanswered1740")
        #expect(try qs(t.db, "SELECT direction || outcome FROM call WHERE ts_ms = 2000000") == "outmissed")
        #expect(try qs(t.db, "SELECT direction || outcome FROM call WHERE ts_ms = 3000000") == "inmissed")
        #expect(try qs(t.db, "SELECT outcome FROM call WHERE ts_ms = 4000000") == "answered")
        #expect(try qs(t.db, "SELECT outcome FROM call WHERE ts_ms = 5000000") == "cancelled")
        #expect(try q(t.db, "SELECT count(*) FROM call WHERE message_id IS NOT NULL AND handle_id IS NOT NULL AND thread_id IS NOT NULL") == 5)
        // the call lines stay messages, and a rerun adds nothing
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE kind = 'call'") == 5)
        let again = try CallImporter.importMessageCalls(into: t.db)
        #expect(again.rows == 0 && again.alreadyThere == 5 && again.totalRows == 5)
    }

    @Test func durationsAreParsedFromTheNoteText() {
        #expect(CallImporter.durationSeconds(in: "The video call ended. (Duration: 29 minutes)") == 1740)
        #expect(CallImporter.durationSeconds(in: "Video call ended (Duration: 22 seconds)") == 22)
        #expect(CallImporter.durationSeconds(in: "x (Duration: 1 hour)") == 3600)
        #expect(CallImporter.durationSeconds(in: "You missed a video call") == 0)
    }
}
