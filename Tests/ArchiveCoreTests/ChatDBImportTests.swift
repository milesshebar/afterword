import Testing
import Foundation
@testable import ArchiveCore

/// Synthetic macOS chat.db snapshots (555-01xx numbers, invented text); nothing here is real data.
enum ChatDBFixtures {
    /// The iPhone's modern schema plus the macOS-only columns the importer reads when present.
    static func make(at url: URL, _ setup: (Database) throws -> Void) throws {
        let db = try Database(path: url.path)
        for s in IOSFixtures.modernSchema { try db.exec(s) }
        try db.exec("ALTER TABLE message ADD COLUMN associated_message_emoji TEXT")
        try db.exec("ALTER TABLE message ADD COLUMN date_retracted INTEGER DEFAULT 0")
        try db.exec("ALTER TABLE message ADD COLUMN date_edited INTEGER DEFAULT 0")
        try setup(db)
        try db.exec("PRAGMA journal_mode = DELETE")
    }

    static let t: Int64 = 1_640_995_200                 // 2022-01-01 00:00:00 UTC (2021-12-31 19:00 New York)
    static let photo = Data(Fixtures.blob(11, count: 2500))

    /// One 1:1 chat with alice, one named group with alice and bob, one SMS chat with carol; rows on both sides of 2022-03-31.
    static func standard(dir: URL) throws -> (db: URL, attachments: URL) {
        let atts = dir.appendingPathComponent("Attachments")
        let photoURL = atts.appendingPathComponent("ab/11/AGUID1/IMG_0001.HEIC")
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try photo.write(to: photoURL)
        let url = dir.appendingPathComponent("chat.db")
        let ns = IOSFixtures.appleNS
        // 2022-03-31 23:30 New York = 2022-04-01 03:30 UTC (inside); 2022-04-01 00:30 New York = 04:30 UTC (outside).
        let lastIn: Int64 = 1_648_783_800, firstOut: Int64 = 1_648_787_400
        let blob = IOSFixtures.hex(IOSFixtures.attributedBody("only in attributedBody"))
        try make(at: url) { db in
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage'), ('bob@example.com','iMessage'), ('+12125550133','SMS');
                INSERT INTO chat(guid, style, chat_identifier, service_name, display_name) VALUES
                    ('iMessage;-;+12125550111', 45, '+12125550111', 'iMessage', NULL),
                    ('iMessage;+;chat9', 43, 'chat9', 'iMessage', 'Weekend Pod'),
                    ('SMS;-;+12125550133', 45, '+12125550133', 'SMS', NULL);
                INSERT INTO chat_handle_join VALUES (1,1), (2,1), (2,2), (3,3);
                INSERT INTO message(guid, text, attributedBody, handle_id, service, date, is_from_me, associated_message_type, associated_message_guid,
                                    associated_message_emoji, date_retracted, date_edited) VALUES
                    ('M-1', 'hi alice', NULL, 1, 'iMessage', \(ns(t)), 1, 0, NULL, NULL, 0, 0),
                    ('M-2', NULL, \(blob), 1, 'iMessage', \(ns(t + 60)), 0, 0, NULL, NULL, 0, 0),
                    ('M-3', char(65532), NULL, 1, 'iMessage', \(ns(t + 120)), 0, 0, NULL, NULL, 0, 0),
                    ('M-4', 'look at these', NULL, 1, 'iMessage', \(ns(t + 180)), 1, 0, NULL, NULL, 0, 0),
                    ('M-5', NULL, NULL, 1, 'iMessage', \(ns(t + 240)), 1, 2000, 'p:0/M-2', NULL, 0, 0),
                    ('M-6', NULL, NULL, 1, 'iMessage', \(ns(t + 250)), 0, 2006, 'bp:M-1', '🥹', 0, 0),
                    ('M-7', 'group hello', NULL, 2, 'iMessage', \(ns(t + 300)), 0, 0, NULL, NULL, 0, 0),
                    ('M-8', NULL, NULL, 0, 'iMessage', \(ns(t + 360)), 1, 0, NULL, NULL, \(ns(t + 400)), \(ns(t + 400))),
                    ('M-9', 'fixed typo', NULL, 2, 'iMessage', \(ns(t + 420)), 0, 0, NULL, NULL, 0, \(ns(t + 430))),
                    ('M-10', NULL, NULL, 0, 'iMessage', \(ns(t + 480)), 1, 0, NULL, NULL, 0, 0),
                    ('M-11', 'sms from carol', NULL, 3, 'SMS', \(ns(lastIn)), 0, 0, NULL, NULL, 0, 0),
                    ('M-12', 'after the cutoff', NULL, 3, 'SMS', \(ns(firstOut)), 0, 0, NULL, NULL, 0, 0),
                    ('M-13', NULL, NULL, 3, 'SMS', \(ns(firstOut + 10)), 1, 2001, 'p:0/M-11', NULL, 0, 0);
                INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(1,6),(2,7),(2,8),(2,9),(2,10),(3,11),(3,12),(3,13);
                INSERT INTO attachment(guid, filename, mime_type, transfer_name, total_bytes) VALUES
                    ('A1', '~/Library/Messages/Attachments/ab/11/AGUID1/IMG_0001.HEIC', 'image/heic', 'IMG_0001.HEIC', 2500),
                    ('A2', '~/Library/Messages/Attachments/cd/22/AGUID2/IMG_0002.HEIC', 'image/heic', 'IMG_0002.HEIC', 9000),
                    ('A3', '~/Library/Messages/Attachments/ef/33/AGUID3/video.mov', 'video/quicktime', 'video.mov', 9000);
                INSERT INTO message_attachment_join VALUES (3,1), (4,2), (4,3);
                """)
        }
        return (url, atts)
    }
}

extension TestArchive {
    @discardableResult
    func importChatDB(_ url: URL, until: String?, attachments: URL) throws -> ChatDBImportReport {
        try MacChatDBImporter.importChatDB(at: url, into: db, root: root, zone: .newYork, until: until, attachmentsRoot: attachments)
    }
}

@Suite struct ChatDBImportTests {
    @Test func cutoffIsTheEndOfTheDayInNewYork() throws {
        #expect(try MacChatDBImporter.endOfDayMs("2022-03-31", zone: .newYork) == 1_648_785_600_000)      // 2022-04-01 04:00 UTC (EDT)
        #expect(try MacChatDBImporter.endOfDayMs("2021-12-31", zone: .newYork) == 1_640_995_200_000 + 5 * 3_600_000)   // EST
        #expect(throws: (any Error).self) { try MacChatDBImporter.endOfDayMs("March 2022") }
    }

    @Test func detectsAChatDBFile() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try ChatDBFixtures.standard(dir: dir)
        #expect(MacChatDBImporter.isChatDB(url))
        let other = dir.appendingPathComponent("other.db")
        _ = try Database(path: other.path).exec("CREATE TABLE x (a)")
        #expect(!MacChatDBImporter.isChatDB(other))
    }

    @Test func importsTextGroupsTapbacksAttachmentsAndStopsAtTheCutoff() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        let r = try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        let s = r.stats
        #expect(r.status == .imported)
        #expect(s.messagesParsed == 13)
        #expect(s.afterCutoff == 2)                         // M-12 and its tapback M-13
        #expect(s.inserted == 8)                            // M-1..4 (M-3 photo only), M-7..9, M-11
        #expect(s.emptySkipped == 1)                        // M-10
        #expect(s.reactionsImported == 2)                   // ❤️ on M-2 and the iOS 17 emoji tapback on M-1
        #expect(s.unsent == 1 && s.edited == 1)
        #expect(s.attachmentsReferenced == 3 && s.attachmentsStored == 1 && s.attachmentsMissing == 2 && s.offloadedNotes == 1)
        #expect(s.groupChats == 1 && s.groupTitles == 1)

        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = 'ios:M-2'") == "only in attributedBody")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:M-3' AND body IS NULL") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.source_key = 'ios:M-3'") == 1)
        let note = try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-4'") ?? ""
        #expect(note.contains("2 attachments not on this Mac") && note.contains("IMG_0002.HEIC") && note.contains("video.mov"))
        #expect(try t.db.scalarString("SELECT kind FROM message WHERE source_key = 'ios:M-8'") == "unsent")
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'ios:M-9'") == "edited")
        #expect(try t.db.scalarString("SELECT service FROM message WHERE source_key = 'ios:M-11'") == "sms")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:M-12'") == 0)
        #expect(try t.db.scalarString("SELECT title FROM thread WHERE is_group = 1") == "Weekend Pod")
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread_member tm JOIN thread th ON th.id = tm.thread_id WHERE th.is_group = 1") == 2)
        #expect(try t.db.scalarString("SELECT group_concat(emoji, '') FROM (SELECT emoji FROM reaction ORDER BY emoji)")?.count == 2)
        let groupSender = try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.source_key = 'ios:M-7'")
        #expect(groupSender == "bob@example.com")

        // Same snapshot, same cutoff: nothing to do.
        #expect(try t.importChatDB(url, until: "2022-03-31", attachments: atts).status == .alreadyImported)
        // A later cutoff adds only what came after the first one, including the tapback on a message imported earlier.
        let later = try t.importChatDB(url, until: "2022-04-30", attachments: atts).stats
        #expect(later.inserted == 1 && later.reactionsImported == 1 && later.afterCutoff == 0)
        #expect(later.coveredEarlier == 11)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NOT NULL") == 0)
    }

    @Test func rowsAnIPhoneBackupAlreadyHasAreLinkedByGuidAndTapbacksAreNotDoubled() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let ns = IOSFixtures.appleNS
        let base = ChatDBFixtures.t
        let fx = BackupFixture(under: t.dir)
        fx.addSMSDatabase(nested: true) { db in
            for s in IOSFixtures.modernSchema { try db.exec(s) }
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage');
                INSERT INTO chat(guid, style) VALUES ('c1', 45);
                INSERT INTO chat_handle_join VALUES (1,1);
                INSERT INTO message(guid, text, handle_id, service, date, is_from_me, associated_message_type, associated_message_guid) VALUES
                    ('M-1', 'hi alice', 1, 'iMessage', \(ns(base)), 1, 0, NULL),
                    ('T-1', NULL, 1, 'iMessage', \(ns(base + 30)), 0, 2003, 'p:0/M-1');
                INSERT INTO chat_message_join VALUES (1,1),(1,2);
                """)
        }
        fx.writeManifestDB()
        try t.importBackup(fx)

        let url = t.dir.appendingPathComponent("chat.db")
        try ChatDBFixtures.make(at: url) { db in
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage');
                INSERT INTO chat(guid, style) VALUES ('c1', 45);
                INSERT INTO chat_handle_join VALUES (1,1);
                INSERT INTO message(guid, text, handle_id, service, date, is_from_me, associated_message_type, associated_message_guid) VALUES
                    ('M-1', 'hi alice', 1, 'iMessage', \(ns(base)), 1, 0, NULL),
                    ('T-1', NULL, 1, 'iMessage', \(ns(base + 30)), 0, 2003, 'p:0/M-1'),
                    ('M-2', 'only on the Mac', 1, 'iMessage', \(ns(base + 60)), 0, 0, NULL);
                INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3);
                """)
        }
        let s = try t.importChatDB(url, until: nil, attachments: t.dir.appendingPathComponent("none")).stats
        #expect(s.inserted == 1 && s.duplicates == 1 && s.guidMatches == 1)
        #expect(s.reactionsAlreadyThere == 1 && s.reactionsImported == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM reaction") == 1)
        #expect(try t.db.scalarInt("SELECT count(DISTINCT thread_id) FROM message") == 1)
    }

    @Test func anotherMacsSnapshotWithSinceAndSkipKnownAddsOnlyWhatIsMissing() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (url, atts) = try ChatDBFixtures.standard(dir: t.dir)
        try t.importChatDB(url, until: "2022-03-31", attachments: atts)
        // The other Mac: the same rows plus one before the cutoff that the first snapshot lacked.
        let otherDir = t.dir.appendingPathComponent("other"); try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let (other, _) = try ChatDBFixtures.standard(dir: otherDir)
        let ns = IOSFixtures.appleNS
        let w = try Database(path: other.path)
        try w.exec("INSERT INTO message(guid, text, handle_id, service, date, is_from_me) VALUES ('M-0', 'only on the other Mac', 1, 'iMessage', \(ns(ChatDBFixtures.t - 60)), 0)")
        try w.exec("INSERT INTO chat_message_join VALUES (1, last_insert_rowid())")
        // Without --since the automatic resume point (after 2022-03-31) hides M-0.
        let s = try MacChatDBImporter.importChatDB(at: other, into: t.db, root: t.root, zone: .newYork, until: "2022-04-30", since: "2021-12-01",
                                                   skipKnown: true, attachmentsRoot: atts).stats
        #expect(s.since == "2021-12-01" && s.skipKnown == true)
        #expect(s.inserted == 2)                            // M-0 and M-12 (after the first cutoff)
        #expect(s.knownElsewhere == 8 && s.duplicates == 0)  // the 8 stored rows of the first import: counted, not stored again
        #expect(s.reactionsImported == 1 && s.reactionsAlreadyThere == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NOT NULL") == 0)
        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = 'ios:M-0'") == "only on the other Mac")
        #expect(try MacChatDBImporter.startOfDayMs("2022-04-01", zone: .newYork) == 1_648_785_600_000)
    }

    @Test func attachmentPathsResolveOnlyInsideTheAttachmentsFolder() {
        let root = URL(fileURLWithPath: "/tmp/atts")
        #expect(MacChatDBImporter.resolve(stored: "~/Library/Messages/Attachments/ab/11/G/x.jpg", attachmentsRoot: root)?.path == "/tmp/atts/ab/11/G/x.jpg")
        #expect(MacChatDBImporter.resolve(stored: "/tmp/atts/cd/x.jpg", attachmentsRoot: root)?.path == "/tmp/atts/cd/x.jpg")
        #expect(MacChatDBImporter.resolve(stored: "~/Library/Messages/Attachments/../../../etc/passwd", attachmentsRoot: root) == nil)
        #expect(MacChatDBImporter.resolve(stored: "/var/folders/xx/sticker.png", attachmentsRoot: root) == nil)
    }
}
