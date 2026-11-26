import Testing
import Foundation
@testable import ArchiveCore

// A synthetic WhatsApp ChatStorage.sqlite: invented people (+1 555 numbers), the real Core Data table and column names.

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum WhatsAppFixtures {
    static let meJID = "15550000001@s.whatsapp.net"
    static let erin = "15550000002@s.whatsapp.net"
    static let sam = "15550000003@s.whatsapp.net"
    static let grp = "120363000000000001@g.us"

    /// Container folder: `ChatStorage.sqlite` plus `Message/Media/<jid>/a/b/photo.jpg`. `extra` adds rows
    /// (pk, type, fromMe, date, session, fromJID, toJID, groupMember, stanza, text).
    static func container(extra: [(Int, Int, Int, Double, Int, String?, String?, Int?, String, String?)] = []) -> URL {
        let dir = Fixtures.tempDir("wa")
        let media = dir.appendingPathComponent("Message/Media/\(erin)/a/b")
        try! FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try! Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: media.appendingPathComponent("photo.jpg"))
        let db = try! Database(path: dir.appendingPathComponent("ChatStorage.sqlite").path)
        try! db.exec("""
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZSESSIONTYPE INTEGER, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR);
            CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEMBERJID VARCHAR, ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR);
            CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPUSHNAME VARCHAR);
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZMESSAGETYPE INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP, ZCHATSESSION INTEGER,
                                     ZFROMJID VARCHAR, ZTOJID VARCHAR, ZGROUPMEMBER INTEGER, ZSTANZAID VARCHAR, ZTEXT VARCHAR);
            CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZTITLE VARCHAR, ZMEDIALOCALPATH VARCHAR, ZVCARDNAME VARCHAR,
                                       ZLATITUDE FLOAT, ZLONGITUDE FLOAT);
            INSERT INTO ZWACHATSESSION VALUES (1, 3, '0@status', 'WhatsApp'), (2, 0, '\(erin)', 'Erin Example'), (3, 1, '\(grp)', 'Test Trip'),
                                              (4, 0, '15550000004@s.whatsapp.net', '+1 (555) 000-0004'), (5, 2, 'status@broadcast', NULL);
            INSERT INTO ZWAGROUPMEMBER VALUES (1, 3, '\(erin)', NULL, NULL), (2, 3, '\(sam)', 'Sam Sample', 'Sam'), (3, 3, '\(meJID)', NULL, NULL);
            INSERT INTO ZWAPROFILEPUSHNAME VALUES (1, '\(erin)', 'Erin Push'), (2, '15550000004@s.whatsapp.net', 'Dana Push');
            """)
        // base: 1 = 2001-01-01 + 1e9 s ~ 2032? no: use small Core Data seconds so dates are 2022
        let t0 = 660_000_000.0   // 2021-12-01 in Core Data seconds
        var rows: [(Int, Int, Int, Double, Int, String?, String?, Int?, String, String?)] = [
            (1, 0, 0, t0 + 1, 2, erin, meJID, nil, "S1", "hi from erin"),
            (2, 0, 1, t0 + 2, 2, nil, erin, nil, "S2", "hi back"),
            (3, 7, 0, t0 + 3, 2, erin, meJID, nil, "S3", "https://example.invalid/story"),
            (4, 1, 0, t0 + 4, 2, erin, meJID, nil, "S4", nil),                  // photo with a caption and a file
            (5, 1, 0, t0 + 5, 2, erin, meJID, nil, "S5", nil),                  // photo, no caption, file missing
            (6, 14, 0, t0 + 6, 2, erin, meJID, nil, "S6", nil),                 // deleted
            (7, 4, 0, t0 + 7, 2, erin, meJID, nil, "S7", nil),                  // contact card
            (8, 5, 0, t0 + 8, 2, erin, meJID, nil, "S8", nil),                  // location
            (9, 0, 0, t0 + 9, 3, grp, nil, 2, "S9", "group hello"),
            (10, 0, 1, t0 + 10, 3, nil, nil, nil, "S10", "me in the group"),
            (11, 0, 0, t0 + 11, 3, grp, nil, 1, "S11", "from erin in group"),
            (12, 6, 0, t0 + 12, 3, grp, nil, 2, "S12", nil),                    // group event: no text, no media
            (13, 12, 0, t0 + 13, 2, erin, nil, nil, "S13", nil),                // status update: no text, no media
            (14, 0, 0, t0 + 14, 4, "15550000004@s.whatsapp.net", meJID, nil, "S14", "unsaved number"),
            (15, 0, 0, t0 + 15, 1, "0@status", nil, nil, "S15", "WhatsApp notice"),   // the status chat: not a conversation
            (16, 0, 0, t0 + 16, 5, "status@broadcast", nil, nil, "S16", "broadcast"),
        ]
        rows += extra
        let ins = try! db.prepare("INSERT INTO ZWAMESSAGE VALUES (?,?,?,?,?,?,?,?,?,?)")
        for r in rows {
            ins.bind(1, r.0).bind(2, r.1).bind(3, r.2).bind(4, r.3).bind(5, r.4).bind(6, r.5).bind(7, r.6).bind(8, r.7.map { Int64($0) }).bind(9, r.8).bind(10, r.9)
            try! ins.run()
        }
        try! db.exec("""
            INSERT INTO ZWAMEDIAITEM VALUES (1, 4, 'look at this', 'Media/\(erin)/a/b/photo.jpg', NULL, NULL, NULL),
                                            (2, 5, NULL, 'Media/\(erin)/a/b/gone.jpg', NULL, NULL, NULL),
                                            (3, 7, NULL, NULL, 'Marco Example', NULL, NULL),
                                            (4, 8, NULL, NULL, NULL, 48.8566, 2.3522);
            """)
        return dir
    }
}

@Suite struct WhatsAppImportTests {
    @Test func detectsAChatStorageOnly() throws {
        let c = WhatsAppFixtures.container(); defer { try? FileManager.default.removeItem(at: c) }
        #expect(WhatsAppImporter.isChatStorage(c.appendingPathComponent("ChatStorage.sqlite")))
        #expect(WhatsAppImporter.isChatStorage(c.appendingPathComponent("Message/Media")) == false)
    }

    @Test func importsChatsPeopleAndKindsWithACountThatAddsUp() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let c = WhatsAppFixtures.container(); defer { try? FileManager.default.removeItem(at: c) }
        let r = try WhatsAppImporter.importChatStorage(at: c.appendingPathComponent("ChatStorage.sqlite"), into: t.db, root: t.root, attachments: c)
        #expect(r.status == .imported)
        let s = r.stats
        #expect(s.parsed == 16 && s.meJID == "15550000001")
        // every row accounted for
        #expect(s.otherChatsSkipped == 2 && s.eventsSkipped == 2 && s.eventsByType == ["6": 1, "12": 1] && s.emptySkipped == 0)
        #expect(s.inserted == 12 && s.duplicates == 0)
        #expect(s.parsed == s.inserted + s.duplicates + s.otherChatsSkipped + s.eventsSkipped + s.emptySkipped)
        #expect(s.text == 6 && s.links == 1 && s.media == 2 && s.contacts == 1 && s.locations == 1 && s.unsent == 1)
        #expect(s.attachmentsStored == 1 && s.mediaMissing == 1)
        #expect(s.chats == 3 && s.groups == 1 && s.dms == 2 && s.people == 3)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE service = 'whatsapp' AND canonical_id IS NULL") == 12)
        #expect(try qs(t.db, "SELECT DISTINCT service FROM message") == "whatsapp")

        // threads and handles
        #expect(try q(t.db, "SELECT count(*) FROM thread WHERE service = 'whatsapp'") == 3)
        #expect(try qs(t.db, "SELECT title || '/' || origin || '/' || external_id FROM thread WHERE is_group = 1") == "Test Trip/group/120363000000000001@g.us")
        #expect(try q(t.db, "SELECT count(*) FROM thread_member tm JOIN thread t ON t.id = tm.thread_id WHERE t.is_group = 1") == 2)   // Erin, Sam: not me
        #expect(try qs(t.db, "SELECT kind FROM handle WHERE normalized = 'wa:15550000002'") == "whatsapp-user")
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'wa:15550000001'") == 0)
        // names: saved contact name, group member name, push name; a bare number is not a name
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'wa:15550000002'") == "Erin Example")
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'wa:15550000003'") == "Sam Sample")
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'wa:15550000004'") == "Dana Push")
        // direction and sender
        #expect(try q(t.db, "SELECT is_from_me FROM message WHERE body = 'hi back'") == 1)
        #expect(try qs(t.db, "SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'group hello'") == "wa:15550000003")
        #expect(try qs(t.db, "SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'from erin in group'") == "wa:15550000002")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE body = 'me in the group' AND sender_handle_id IS NULL") == 1)
        // kinds
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'look at%'") == "look at this")
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == 1)
        #expect(try qs(t.db, "SELECT mime FROM attachment") == "image/jpeg")
        #expect(try qs(t.db, "SELECT note FROM message WHERE kind = 'system'") == "(photo not in the backup)")
        #expect(try qs(t.db, "SELECT note FROM message WHERE kind = 'unsent'") == "(message deleted)")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'Contact:%'") == "Contact: Marco Example")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'Location:%'") == "Location: 48.85660, 2.35220")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'https://example%'") == "https://example.invalid/story")
        // Core Data time: seconds since 2001-01-01
        #expect(try q(t.db, "SELECT ts_ms FROM message WHERE body = 'hi from erin'") == (660_000_001 + 978_307_200) * 1000)
        #expect(try q(t.db, "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'unsaved'") == 1)
    }

    @Test func rerunSkippedAndALargerLaterBackupAddsOnlyTheNewMessages() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let c = WhatsAppFixtures.container(); defer { try? FileManager.default.removeItem(at: c) }
        let f = c.appendingPathComponent("ChatStorage.sqlite")
        _ = try WhatsAppImporter.importChatStorage(at: f, into: t.db, root: t.root, attachments: c)
        let again = try WhatsAppImporter.importChatStorage(at: f, into: t.db, root: t.root, attachments: c)
        #expect(again.status == .alreadyImported)
        #expect(try q(t.db, "SELECT count(*) FROM message") == 12)
        let c2 = WhatsAppFixtures.container(extra: [(30, 0, 0, 660_000_100, 2, WhatsAppFixtures.erin, WhatsAppFixtures.meJID, nil, "S30", "a newer one")])
        defer { try? FileManager.default.removeItem(at: c2) }
        let r2 = try WhatsAppImporter.importChatStorage(at: c2.appendingPathComponent("ChatStorage.sqlite"), into: t.db, root: t.root, attachments: c2)
        #expect(r2.status == .imported && r2.stats.inserted == 1 && r2.stats.duplicates == 12)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE canonical_id IS NULL") == 13)
        #expect(try q(t.db, "SELECT count(*) FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.canonical_id IS NULL") == 1)
    }

    @Test func aHugeGroupContributesOnlyItsWriters() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let c = WhatsAppFixtures.container(); defer { try? FileManager.default.removeItem(at: c) }
        let f = c.appendingPathComponent("ChatStorage.sqlite")
        let w = try Database(path: f.path)
        try w.exec("INSERT INTO ZWACHATSESSION VALUES (9, 1, '120363999999999999@g.us', 'Big Community'), (10, 1, '120363888888888888@g.us', 'Quiet Big')")
        for i in 0..<60 {
            let jid = "1666000\(String(format: "%04d", i))@s.whatsapp.net"
            try w.exec("INSERT INTO ZWAGROUPMEMBER VALUES (\(1000 + i), 9, '\(jid)', NULL, NULL), (\(2000 + i), 10, '\(jid)', NULL, NULL)")
        }
        try w.exec("""
            INSERT INTO ZWAMESSAGE VALUES (100, 0, 0, 660000200, 9, '120363999999999999@g.us', NULL, 1003, 'B1', 'spam one'),
                                          (101, 0, 0, 660000201, 9, '120363999999999999@g.us', NULL, 1004, 'B2', 'spam two'),
                                          (102, 0, 1, 660000202, 10, NULL, NULL, NULL, 'B3', 'only I wrote here')
            """)
        let r = try WhatsAppImporter.importChatStorage(at: f, into: t.db, root: t.root, attachments: nil)
        #expect(r.stats.groupsWithLongMemberLists == 2)
        #expect(try q(t.db, "SELECT count(*) FROM thread_member tm JOIN thread t ON t.id = tm.thread_id WHERE t.title = 'Big Community'") == 2)   // the 2 writers
        let n = try q(t.db, "SELECT count(*) FROM handle WHERE kind = 'whatsapp-user'")
        #expect(n == 53, "handles: \(n)")      // the fixture's 3 + the quiet group's first 50 (which include the 2 writers)                  // fixture's 3, the 2 writers, the quiet group's first 50
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE body = 'only I wrote here'") == 1)
        #expect(r.stats.parsed == r.stats.inserted + r.stats.duplicates + r.stats.otherChatsSkipped + r.stats.eventsSkipped + r.stats.emptySkipped)
    }

    @Test func withoutAMediaFolderNoFilesAreStored() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let c = WhatsAppFixtures.container(); defer { try? FileManager.default.removeItem(at: c) }
        let r = try WhatsAppImporter.importChatStorage(at: c.appendingPathComponent("ChatStorage.sqlite"), into: t.db, root: t.root, attachments: nil)
        #expect(r.stats.attachmentsStored == 0 && r.stats.mediaMissing == 2)
        // the captioned photo keeps its caption; the uncaptioned one becomes a system line
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE body = 'look at this'") == 1)
    }

    @Test func serviceKeysKnowTheNewServices() {
        #expect(ServiceKey.of(messageService: "skype") == .skype && ServiceKey.of(messageService: "whatsapp") == .whatsapp)
        #expect(ServiceKey.skype.label == "Skype" && ServiceKey.whatsapp.label == "WhatsApp")
        #expect(ServiceKey.whatsapp.messageServices == ["whatsapp"])
        #expect(ServiceKey.allCases.sorted().map(\.rawValue) == ["imessage", "sms", "messenger", "instagram", "groupme", "skype", "whatsapp", "snapchat", "aim", "telegram", "slack"])
    }
}
