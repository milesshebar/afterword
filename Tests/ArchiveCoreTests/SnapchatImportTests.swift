import Testing
import Foundation
@testable import ArchiveCore

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum SnapchatFixtures {
    static func msg(from: String, type: String, content: String, micros: Int64, sender: Bool, title: String? = nil, ids: String = "") -> String {
        let t = title.map { "\"\($0)\"" } ?? "null"
        return "{\"From\":\"\(from)\",\"Media Type\":\"\(type)\",\"Created\":\"2017-01-01 00:00:00 UTC\",\"Content\":\"\(content)\",\"Conversation Title\":\(t),\"IsSender\":\(sender),\"Created(microseconds)\":\(micros),\"IsSaved\":true,\"Media IDs\":\"\(ids)\"}"
    }

    static func export() -> URL {
        let d = Fixtures.tempDir("snap")
        try! FileManager.default.createDirectory(at: d.appendingPathComponent("json"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: d.appendingPathComponent("chat_media"), withIntermediateDirectories: true)
        let base: Int64 = 1_483_228_800_000              // 2017-01-01 00:00:00 UTC; the export's "microseconds" field is really milliseconds
        let chats = """
        {"erin_ex":[\(msg(from: "erin_ex", type: "TEXT", content: "hey there", micros: base + 1_000, sender: false)),
                    \(msg(from: "testme", type: "TEXT", content: "hi back", micros: base + 2_000, sender: true)),
                    \(msg(from: "erin_ex", type: "MEDIA", content: "", micros: base + 3_000, sender: false, ids: "b~AAA111")),
                    \(msg(from: "erin_ex", type: "MEDIA", content: "", micros: base + 4_000, sender: false, ids: "b~MISSING")),
                    \(msg(from: "erin_ex", type: "STICKER", content: "", micros: base + 5_000, sender: false)),
                    \(msg(from: "erin_ex", type: "SHARE", content: "", micros: base + 6_000, sender: false)),
                    \(msg(from: "erin_ex", type: "TEXT", content: "", micros: base + 7_000, sender: false))],
         "a8822042-fe6c-3d1b-af5a-98361733cbca":[\(msg(from: "sam_s", type: "TEXT", content: "group hello", micros: base + 8_000, sender: false, title: "Test Crew")),
                    \(msg(from: "testme", type: "TEXT", content: "me in the group", micros: base + 9_000, sender: true, title: "Test Crew")),
                    \(msg(from: "erin_ex", type: "TEXT", content: "erin in the group", micros: base + 10_000, sender: false, title: "Test Crew"))]}
        """
        try! chats.write(to: d.appendingPathComponent("json/chat_history.json"), atomically: true, encoding: .utf8)
        let friends = """
        {"Friends":[{"Username":"erin_ex","Display Name":"Erin Example","Creation Timestamp":"2015-07-01 03:51:18 UTC","Last Modified Timestamp":"2015-07-02 00:00:00 UTC","Source":"added by added me back"},
                    {"Username":"nobody_chat","Display Name":"","Creation Timestamp":"2016-01-01 00:00:00 UTC","Last Modified Timestamp":"2016-01-01 00:00:00 UTC","Source":"added by unknown"}],
         "Deleted Friends":[{"Username":"gone_g","Display Name":"Gone G","Creation Timestamp":"2014-09-27 01:01:29 UTC","Last Modified Timestamp":"2014-09-27 01:01:29 UTC","Source":"added by unknown"}],
         "Friend Requests Sent":[],"Blocked Users":[{"Username":"blk","Display Name":"","Creation Timestamp":"2017-02-10 16:06:43 UTC","Last Modified Timestamp":"2017-02-10 16:06:43 UTC","Source":"added by unknown"}]}
        """
        try! friends.write(to: d.appendingPathComponent("json/friends.json"), atomically: true, encoding: .utf8)
        try! "{\"Basic Information\":{\"Username\":\"testme\",\"Name\":\"Test Me\"}}".write(to: d.appendingPathComponent("json/account.json"), atomically: true, encoding: .utf8)
        try! Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: d.appendingPathComponent("chat_media/2017-01-01_b~AAA111.jpg"))
        try! Data([1]).write(to: d.appendingPathComponent("chat_media/2017-01-01_metadata~zip-1.unknown"))
        return d
    }
}

@Suite struct SnapchatImportTests {
    @Test func detectsAnExportFolderOnly() throws {
        let e = SnapchatFixtures.export(); defer { try? FileManager.default.removeItem(at: e) }
        #expect(SnapchatImporter.detect(e))
        let other = Fixtures.tempDir("notsnap"); defer { try? FileManager.default.removeItem(at: other) }
        #expect(SnapchatImporter.detect(other) == false)
    }

    @Test func importsChatsMediaGroupsAndFriendDates() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let e = SnapchatFixtures.export(); defer { try? FileManager.default.removeItem(at: e) }
        let r = try SnapchatImporter.importExport(at: e, into: t.db, root: t.root)
        #expect(r.status == .imported)
        let s = r.stats
        #expect(s.me == "testme" && s.threads == 2 && s.groups == 1 && s.dms == 1)
        #expect(s.parsed == 10 && s.inserted == 9 && s.emptySkipped == 1 && s.duplicates == 0)
        #expect(s.parsed == s.inserted + s.duplicates + s.emptySkipped)
        #expect(s.text == 6 && s.media == 2 && s.stickers == 1 && s.shares == 1)
        #expect(s.attachmentsStored == 1 && s.mediaMissing == 1)
        #expect(s.byYear == ["2017": 9] && s.people == 2)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE service = 'snapchat' AND canonical_id IS NULL") == 9)
        // handles, names, direction
        #expect(try qs(t.db, "SELECT kind FROM handle WHERE normalized = 'sn:erin_ex'") == "snapchat-user")
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'sn:testme'") == 0)
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'sn:erin_ex'") == "Erin Example")
        #expect(try q(t.db, "SELECT is_from_me FROM message WHERE body = 'hi back'") == 1)
        #expect(try qs(t.db, "SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'group hello'") == "sn:sam_s")
        // threads: a 1:1 and a titled group with its two writers
        #expect(try qs(t.db, "SELECT title || '/' || origin FROM thread WHERE is_group = 1") == "Test Crew/group")
        #expect(try q(t.db, "SELECT count(*) FROM thread_member tm JOIN thread t ON t.id = tm.thread_id WHERE t.is_group = 1") == 2)
        #expect(try qs(t.db, "SELECT origin FROM thread WHERE is_group = 0") == "dm")
        // media linked by id; the missing snap, sticker and share are system lines; the empty text is skipped
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == 1 && (try qs(t.db, "SELECT mime FROM attachment")) == "image/jpeg")
        #expect(try qs(t.db, "SELECT group_concat(note, '|') FROM (SELECT note FROM message WHERE kind = 'system' ORDER BY ts_ms)") == "(snap not in the export)|(sticker)|(shared a Snapchat item)")
        // time: Created(microseconds)
        #expect(try q(t.db, "SELECT ts_ms FROM message WHERE body = 'hey there'") == 1_483_228_801_000)
        #expect(s.firstTsMs == 1_483_228_801_000 && s.lastTsMs == 1_483_228_810_000)
        // friends.json dates: one row per person per list; linked only to handles the archive has
        #expect(s.friendDates == ["friend": 2, "deleted": 1, "blocked": 1])
        #expect(try q(t.db, "SELECT count(*) FROM contact_date") == 4)
        #expect(try q(t.db, "SELECT created_ms FROM contact_date WHERE username = 'erin_ex'") == 1_435_722_678_000)
        #expect(try q(t.db, "SELECT count(*) FROM contact_date WHERE handle_id IS NOT NULL") == 1)
        #expect(try qs(t.db, "SELECT how FROM contact_date WHERE username = 'erin_ex'") == "added by added me back")
        // rerun is skipped
        #expect(try SnapchatImporter.importExport(at: e, into: t.db, root: t.root).status == .alreadyImported)
        #expect(try q(t.db, "SELECT count(*) FROM message") == 9)
    }
}
