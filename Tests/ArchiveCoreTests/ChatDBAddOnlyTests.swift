import Testing
import Foundation
@testable import ArchiveCore

/// `--add-only` (chat.db snapshots from other Macs): a snapshot from another Mac may add rows the archive lacks and
/// nothing else. No row that existed before changes (no canonical flip onto an older copy, no tapback added to or removed
/// from an old message, no title given to an old thread), a row that matches an existing one is held (not written), a guid
/// on the hold list is left out, and every chat.db row gets one ledger line. Synthetic data only (555-01xx numbers).
@Suite struct ChatDBAddOnlyTests {
    /// The archive before: the standard snapshot up to 2022-03-31 (M-1 .. M-11) plus an Android SMS from carol that the new
    /// snapshot also holds under a guid of its own (M-21). The other Mac's snapshot then adds: M-20 (new, carol), M-21 (the
    /// Android copy), M-22 (on the hold list), T-20 (a tapback on the old M-1), T-21 (removes the old ❤️ on M-2), T-22 (a tapback
    /// on the new M-20), and a new group chat with alice and carol under the old group's display name.
    func scenario() throws -> (t: TestArchive, other: URL, atts: URL) {
        let t = try TestArchive()
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        let base = ChatDBFixtures.t
        let androidMs = (base + 900) * 1000
        try t.importXML(Fixtures.file([Fixtures.sms(address: Fixtures.carol, date: androidMs, type: 1, body: "the android copy")]), name: "sms-old.xml")
        // The old group thread has no title yet, so a title update on it would show.
        try t.db.exec("UPDATE thread SET title = NULL WHERE is_group = 1")

        let otherDir = t.dir.appendingPathComponent("other"); try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let (other, _) = try ChatDBFixtures.standard(dir: otherDir)
        let ns = IOSFixtures.appleNS
        let w = try Database(path: other.path)
        try w.exec("""
            INSERT INTO chat(guid, style, chat_identifier, service_name, display_name) VALUES ('iMessage;+;chat10', 43, 'chat10', 'iMessage', 'New Pod');
            INSERT INTO chat_handle_join VALUES (4,1), (4,3);
            INSERT INTO message(guid, text, handle_id, service, date, is_from_me, associated_message_type, associated_message_guid) VALUES
                ('M-20', 'new from carol', 3, 'SMS', \(ns(base + 800)), 0, 0, NULL),
                ('M-21', 'the android copy', 3, 'SMS', \(ns(base + 900)), 0, 0, NULL),
                ('M-22', 'held by the list', 3, 'SMS', \(ns(base + 950)), 0, 0, NULL),
                ('T-20', NULL, 1, 'iMessage', \(ns(base + 1000)), 0, 2001, 'p:0/M-1'),
                ('T-21', NULL, 1, 'iMessage', \(ns(base + 1010)), 1, 3000, 'p:0/M-2'),
                ('T-22', NULL, 3, 'SMS', \(ns(base + 1020)), 1, 2000, 'p:0/M-20'),
                ('M-23', 'new group hello', 1, 'iMessage', \(ns(base + 1100)), 0, 0, NULL);
            """)
        try w.exec("INSERT INTO chat_message_join SELECT 3, ROWID FROM message WHERE guid IN ('M-20','M-21','M-22','T-22')")
        try w.exec("INSERT INTO chat_message_join SELECT 1, ROWID FROM message WHERE guid IN ('T-20','T-21')")
        try w.exec("INSERT INTO chat_message_join SELECT 4, ROWID FROM message WHERE guid = 'M-23'")
        return (t, other, atts)
    }

    func fingerprint(_ db: Database, maxMessage: Int64) throws -> [String] {
        var out: [String] = []
        for q in ["SELECT id, thread_id, sender_handle_id, ts_ms, is_from_me, service, body, source_id, source_key, canonical_id, kind, note FROM message WHERE id <= \(maxMessage) ORDER BY id",
                  "SELECT message_id, emoji, actor_handle_id, by_me FROM reaction ORDER BY rowid",
                  "SELECT id, key, is_group, title FROM thread ORDER BY id"] {
            let st = try db.prepare(q)
            while try st.step() { out.append((0..<12).map { st.string($0) ?? "∅" }.joined(separator: "|")) }
        }
        return out
    }

    @Test func addOnlyChangesNoOldRowAndLedgersEveryRow() throws {
        let (t, other, atts) = try scenario(); defer { t.cleanup() }
        let maxBefore = try t.db.scalarInt("SELECT max(id) FROM message")
        let threadsBefore = try t.db.scalarInt("SELECT max(id) FROM thread")
        let before = try fingerprint(t.db, maxMessage: maxBefore)
        let ledger = t.dir.appendingPathComponent("ledger.tsv")
        let r = try MacChatDBImporter.importChatDB(at: other, into: t.db, root: t.root, zone: .newYork, until: "2022-04-30", since: "2021-12-01",
                                                   skipKnown: true, attachmentsRoot: atts, addOnly: true,
                                                   holdKeys: ["ios:M-22"], ledger: ledger)
        let s = r.stats
        #expect(s.addOnly == true)
        // Old rows: every message, reaction and thread line from before is still there unchanged (a change or a delete
        // would remove its line).
        let after = try fingerprint(t.db, maxMessage: maxBefore)
        #expect(before.allSatisfy { after.contains($0) }, "a pre-existing row changed")
        // Written: M-20, M-23, M-12 (after the old cutoff). Held: M-21 (the Android copy). Left out: M-22 (the hold list).
        #expect(s.inserted == 3)
        #expect(s.heldMatches == 1 && s.heldByList == 1 && s.duplicates == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key IN ('ios:M-21','ios:M-22')") == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE id > \(maxBefore) AND canonical_id IS NOT NULL") == 0)
        // Tapbacks: only the one on the new M-20 is added; the old M-1 gets nothing new and M-2 keeps its ❤️.
        #expect(s.reactionsImported == 1)
        #expect(s.reactionsOnOldRowsLeftOut == 5)           // T-20, T-21 and the snapshot's own M-5, M-6, M-13
        #expect(try t.db.scalarInt("SELECT count(*) FROM reaction r JOIN message m ON m.id = r.message_id WHERE m.source_key = 'ios:M-20'") == 1)
        // The new group thread gets its chat name; the old group thread stays untitled.
        #expect(try t.db.scalarString("SELECT title FROM thread WHERE id = (SELECT thread_id FROM message WHERE source_key = 'ios:M-23')") == "New Pod")
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread WHERE id <= \(threadsBefore) AND title IS NOT NULL") == 0)

        // The ledger: one line per chat.db row, with the decision and the archive or written row.
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(header.starts(with: ["source_file", "chat_rowid", "guid", "ts_ms", "ts_utc", "direction", "chat_id", "members", "decision"]))
        let rows = lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows.count == s.messagesParsed)
        func row(_ guid: String) -> [String: String]? {
            rows.first { $0[2] == guid }.map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        }
        let written20 = try t.db.scalarInt("SELECT id FROM message WHERE source_key = 'ios:M-20'")
        #expect(row("M-20")?["decision"] == "new" && row("M-20")?["written_message_id"] == "\(written20)")
        let android = try t.db.scalarInt("SELECT id FROM message WHERE body = 'the android copy'")
        #expect(row("M-21")?["decision"] == "held-match" && row("M-21")?["archive_message_id"] == "\(android)")
        #expect(row("M-22")?["decision"] == "left-out-hold-list")
        let old1 = try t.db.scalarInt("SELECT id FROM message WHERE source_key = 'ios:M-1'")
        #expect(row("M-1")?["decision"] == "held-guid" && row("M-1")?["archive_message_id"] == "\(old1)")
        #expect(row("T-20")?["decision"] == "left-out-tapback-on-old-row")
        #expect(row("T-21")?["decision"] == "left-out-tapback-on-old-row")
        #expect(row("T-22")?["decision"] == "tapback-added" && row("T-22")?["archive_message_id"] == "\(written20)")
        #expect(row("M-10")?["decision"] == "left-out-empty")
        #expect(rows.allSatisfy { !$0[8].isEmpty })

        // A second run of the same snapshot adds nothing.
        let again = try MacChatDBImporter.importChatDB(at: other, into: t.db, root: t.root, zone: .newYork, until: "2022-04-30", since: "2021-12-01",
                                                       skipKnown: true, attachmentsRoot: atts, addOnly: true, holdKeys: ["ios:M-22"])
        #expect(again.status == .alreadyImported)
    }

    @Test func withoutAddOnlyTheSameSnapshotWouldTouchOldRows() throws {
        // The reason for the mode: the ordinary --since --skip-known run flips the Android row under the new copy and
        // removes the old ❤️ on M-2.
        let (t, other, atts) = try scenario(); defer { t.cleanup() }
        let android = try t.db.scalarInt("SELECT id FROM message WHERE body = 'the android copy'")
        let hearts = try t.db.scalarInt("SELECT count(*) FROM reaction")
        _ = try MacChatDBImporter.importChatDB(at: other, into: t.db, root: t.root, zone: .newYork, until: "2022-04-30", since: "2021-12-01",
                                               skipKnown: true, attachmentsRoot: atts)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE id = \(android) AND canonical_id IS NOT NULL") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM reaction") != hearts)
    }

    // MARK: edge cases

    /// A one-chat snapshot: alice 1:1, rows given as (guid, text, seconds after `t`, from me).
    func snapshot(_ dir: URL, name: String, _ rows: [(String, String, Int64, Bool)]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ns = IOSFixtures.appleNS
        try ChatDBFixtures.make(at: url) { db in
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage');
                INSERT INTO chat(guid, style) VALUES ('c1', 45);
                INSERT INTO chat_handle_join VALUES (1,1);
                """)
            for (g, text, dt, me) in rows {
                try db.exec("INSERT INTO message(guid, text, handle_id, service, date, is_from_me) VALUES ('\(g)', '\(text)', 1, 'iMessage', \(ns(ChatDBFixtures.t + dt)), \(me ? 1 : 0))")
                try db.exec("INSERT INTO chat_message_join VALUES (1, last_insert_rowid())")
            }
        }
        return url
    }

    /// Stats written before the add-only counters existed must still decode, or the resume point becomes "never".
    @Test func statsWrittenBeforeTheAddOnlyCountersStillDecode() throws {
        let old = #"{"snapshotSHA256":"x","until":"2022-03-31","untilEndMs":1648785600000,"knownElsewhere":0,"messagesParsed":3,"afterCutoff":0,"coveredEarlier":0,"inserted":3,"duplicates":0,"guidMatches":0,"reactionsImported":0,"reactionsAlreadyThere":0,"reactionsSkipped":0,"unsent":0,"edited":0,"emptySkipped":0,"orphansSkipped":0,"invalidSkipped":0,"attachmentsReferenced":0,"attachmentsStored":0,"attachmentsMissing":0,"offloadedNotes":0,"mediaBytes":0,"mediaNewBytes":0,"mediaNewFiles":0,"groupChats":0,"groupTitles":0,"seconds":0.1}"#
        let s = try JSONDecoder().decode(ChatDBImportStats.self, from: Data(old.utf8))
        #expect(s.untilEndMs == 1_648_785_600_000 && s.inserted == 3)
        // ... and an ordinary later import resumes after that cutoff instead of skipping everything.
        let t = try TestArchive(); defer { t.cleanup() }
        try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES ('macos-chatdb', 'old', 'old-key', 0, 0, '\(old)')")
        let snap = try snapshot(t.dir, name: "a.db", [("N-1", "after the old cutoff", 100 * 86_400, false)])
        let r = try MacChatDBImporter.importChatDB(at: snap, into: t.db, root: t.root, zone: .newYork, until: "2022-12-31", attachmentsRoot: t.dir)
        #expect(r.stats.inserted == 1)
    }

    /// In add-only, a row with another guid but the same text, time, direction and thread is held, not written.
    @Test func addOnlyHoldsAContentCopyUnderAnotherGuid() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let a = try snapshot(t.dir, name: "a.db", [("G-A", "same words", 0, false)])
        try t.importChatDB(a, until: nil, attachments: t.dir)
        let b = try snapshot(t.dir, name: "b.db", [("G-B", "same words", 1, false)])
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let s = try MacChatDBImporter.importChatDB(at: b, into: t.db, root: t.root, zone: .newYork, since: "2016-01-01", attachmentsRoot: t.dir,
                                                   addOnly: true, ledger: ledger).stats
        #expect(s.inserted == 0 && s.heldMatches == 1)
        let text = try String(contentsOf: ledger, encoding: .utf8)
        #expect(text.contains("\tG-B\t") && text.contains("held-match-other-guid"))
    }

    /// Add-only without --since scans the whole snapshot (skip-known handles what is held); another Mac's later
    /// cutoff must not hide this snapshot's older rows.
    @Test func addOnlyWithoutSinceIgnoresOtherImportsCutoffs() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let a = try snapshot(t.dir, name: "a.db", [("A-1", "late on mac a", 400 * 86_400, false)])
        try t.importChatDB(a, until: "2023-12-31", attachments: t.dir)
        let b = try snapshot(t.dir, name: "b.db", [("B-1", "early on mac b", 0, false), ("A-1", "late on mac a", 400 * 86_400, false)])
        let s = try MacChatDBImporter.importChatDB(at: b, into: t.db, root: t.root, zone: .newYork, attachmentsRoot: t.dir, addOnly: true).stats
        #expect(s.inserted == 1 && s.knownElsewhere == 1 && s.coveredEarlier == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:B-1'") == 1)
    }

    /// Holding does not use up the archive row: a second snapshot row with yet another guid and the same text a
    /// second later is held against the same row too, not written.
    @Test func aHeldMatchDoesNotUseUpItsArchiveRow() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let a = try snapshot(t.dir, name: "a.db", [("G-A", "twice", 0, false)])
        try t.importChatDB(a, until: nil, attachments: t.dir)
        let b = try snapshot(t.dir, name: "b.db", [("G-B", "twice", 0, false), ("G-C", "twice", 1, false)])
        let s = try MacChatDBImporter.importChatDB(at: b, into: t.db, root: t.root, zone: .newYork, since: "2016-01-01", attachmentsRoot: t.dir, addOnly: true).stats
        #expect(s.inserted == 0 && s.heldMatches == 2)
    }

    /// The ledger appears only once the import has committed; a failed import leaves no ledger (and no partial file).
    @Test func aFailedImportLeavesNoLedger() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        // Make storing the one attachment fail inside the transaction: the media folder is read-only.
        let media = t.root.mediaURL
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: media.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: media.path) }
        let ledger = t.dir.appendingPathComponent("ledger.tsv")
        #expect(throws: (any Error).self) {
            try MacChatDBImporter.importChatDB(at: url, into: t.db, root: t.root, zone: .newYork, since: "2016-01-01", attachmentsRoot: atts, addOnly: true, ledger: ledger)
        }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: t.dir.path).filter { $0.hasPrefix("ledger") }
        #expect(left.isEmpty, "ledger files left: \(left)")
    }
}
