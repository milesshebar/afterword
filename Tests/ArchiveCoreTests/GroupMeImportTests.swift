import Testing
import Foundation
@testable import ArchiveCore

// A synthetic GroupMe export: invented people, invented text, a 4-byte fake image. Shape follows the real account-data export
// (profile/profile.json, one folder per conversation with conversation.json + message.json, gallery/, likes/, poll.json).

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

enum GroupMeFixtures {
    static let me = "1001"

    static func write(_ s: String, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! s.write(to: url, atomically: true, encoding: .utf8)
    }

    static func gmMessage(_ id: Int, _ t: Int, from: String, name: String, text: String?, atts: String = "[]", favs: [String] = [],
                    system: Bool = false) -> String {
        let t2 = text.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" } ?? "null"
        return """
        {"attachments":\(atts),"avatar_url":null,"created_at":\(t),"favorited_by":[\(favs.map { "\"\($0)\"" }.joined(separator: ","))],"group_id":"9001","id":"\(id)","name":"\(name)","sender_id":"\(from)","sender_type":"\(system ? "system" : "user")","source_guid":"g\(id)","system":\(system),"text":\(t2),"hidden":false,"user_id":"\(from)"}
        """
    }

    /// An export folder with one group ("Test Crew", id 9001), one DM with Dana (1004) and a profile for user 1001.
    static func export(galleryHash: String = "abc123") -> URL {
        let ex = Fixtures.tempDir("gmexp")
        write(#"{"id":"1001","name":"Test Me","email":"me@example.invalid"}"#, to: ex.appendingPathComponent("profile/profile.json"))
        write(#"{"id":"9001","group_id":"9001","name":"Test Crew","type":"private","members":[{"user_id":"1001","nickname":"Test Me"},{"user_id":"1002","nickname":"Erin Example"},{"user_id":"1003","nickname":"Sam Sample"}]}"#,
              to: ex.appendingPathComponent("9001/conversation.json"))
        // newest first, like the real file
        let group = [
            gmMessage(105, 1_500_000_500, from: "system", name: "GroupMe", text: "Sam Sample left the group.", system: true),
            gmMessage(104, 1_500_000_400, from: "1004", name: "Old Friend", text: "still here?", favs: []),
            gmMessage(103, 1_500_000_300, from: "1003", name: "Sam Sample", text: nil,
                atts: #"[{"type":"image","url":"https://i.groupme.com/800x600.jpeg.\#(galleryHash)"},{"type":"image","url":"https://i.groupme.com/640x480.jpeg.remote999"}]"#),
            gmMessage(102, 1_500_000_200, from: "1001", name: "Test Me", text: "ok \u{FFFD} sounds good",
                atts: #"[{"type":"emoji","placeholder":"\#u{FFFD}","charmap":[[1,2]]}]"#, favs: ["1002", "1003"]),
            gmMessage(101, 1_500_000_100, from: "1002", name: "Erin Example", text: "movie night? vote",
                atts: #"[{"type":"poll","poll_id":"p1"},{"type":"mentions","loci":[[0,3]],"user_ids":["1003"]}]"#, favs: ["1001"]),
            gmMessage(100, 1_500_000_000, from: "1002", name: "Erin Example", text: "hello crew"),
        ]
        write("[" + group.joined(separator: ",") + "]", to: ex.appendingPathComponent("9001/message.json"))
        write(#"[{"data":{"id":"p1","subject":"Which film?","options":[{"id":"1","title":"Alpha","votes":3},{"id":"2","title":"Beta"}]}}]"#, to: ex.appendingPathComponent("9001/poll.json"))
        let gal = ex.appendingPathComponent("9001/gallery")
        try! FileManager.default.createDirectory(at: gal, withIntermediateDirectories: true)
        try! Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: gal.appendingPathComponent("103_800x600.\(galleryHash).jpeg"))
        write("[]", to: gal.appendingPathComponent("manifest.json"))

        write(#"{"chat":{"created_at":1500001000,"messages_count":2,"other_user":{"id":"1004","name":"Dana Demo"},"updated_at":1500001100}}"#,
              to: ex.appendingPathComponent("1001_1004/conversation.json"))
        let dm = [
            gmMessage(202, 1_500_001_100, from: "1001", name: "Test Me", text: "reply from me"),
            gmMessage(201, 1_500_001_000, from: "1004", name: "Dana Demo", text: "dm hello", favs: ["1001"]),
        ]
        write("[" + dm.joined(separator: ",") + "]", to: ex.appendingPathComponent("1001_1004/message.json"))
        return ex
    }
}

@Suite struct GroupMeImportTests {
    @Test func detectsAnExportButNotOtherFolders() throws {
        let ex = GroupMeFixtures.export(); defer { try? FileManager.default.removeItem(at: ex) }
        #expect(GroupMeImporter.detect(ex))
        #expect(GroupMeImporter.detectAll(ex).count == 1)
        let parent = Fixtures.tempDir("gmparent"); defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.moveItem(at: ex, to: parent.appendingPathComponent("inner"))
        #expect(GroupMeImporter.detect(parent) == false && GroupMeImporter.detectAll(parent).count == 1)
        let empty = Fixtures.tempDir("gmnot"); defer { try? FileManager.default.removeItem(at: empty) }
        #expect(GroupMeImporter.detect(empty) == false)
        // restore so the first defer finds nothing to remove (harmless either way)
    }

    @Test func groupAndDMImportWithPeopleLikesPollsAndMedia() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let ex = GroupMeFixtures.export(); defer { try? FileManager.default.removeItem(at: ex) }
        let r = try GroupMeImporter.importExport(at: ex, into: t.db, root: t.root)
        #expect(r.status == .imported && r.meID == "1001" && r.meName == "Test Me")
        let s = r.stats
        #expect(s.conversations == 2 && s.groups == 1 && s.dms == 1)
        #expect(s.parsed == 8 && s.inserted == 8 && s.duplicates == 0 && s.emptySkipped == 0)
        #expect(s.system == 1 && s.polls == 1 && s.attachmentsStored == 1 && s.remoteLinks == 1 && s.emojiPlaceholders == 1)
        #expect(s.reactions == 4)                                        // 1002, 1003 on 102; 1001 on 101; 1001 on 201
        #expect(s.firstTsMs == 1_500_000_000_000 && s.lastTsMs == 1_500_001_100_000)

        #expect(try qs(t.db, "SELECT DISTINCT service FROM message") == "groupme")
        #expect(try q(t.db, "SELECT count(*) FROM thread") == 2)
        // the group: titled, a group thread, keyed apart from any same-member group; members include the departed sender 1004
        #expect(try qs(t.db, "SELECT title || '/' || is_group || '/' || service || '/' || origin || '/' || external_id FROM thread WHERE is_group = 1") == "Test Crew/1/groupme/group/9001")
        #expect(try q(t.db, "SELECT count(*) FROM thread_member tm JOIN thread t ON t.id = tm.thread_id WHERE t.is_group = 1") == 3)
        #expect(try qs(t.db, "SELECT service || '/' || origin || '/' || external_id FROM thread WHERE is_group = 0") == "groupme/dm/1001_1004")
        // chronological (the file is newest-first), from-me flag by the profile id, no handle for me
        #expect(try qs(t.db, "SELECT body FROM message WHERE thread_id = (SELECT id FROM thread WHERE is_group = 1) ORDER BY id LIMIT 1") == "hello crew")
        #expect(try q(t.db, "SELECT ts_ms FROM message WHERE body = 'hello crew'") == 1_500_000_000_000)
        #expect(try q(t.db, "SELECT is_from_me FROM message WHERE body LIKE 'ok%'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'gm:1001'") == 0)
        #expect(try qs(t.db, "SELECT h.kind FROM handle h WHERE h.normalized = 'gm:1002'") == "groupme-user")
        #expect(try qs(t.db, "SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'hello crew'") == "gm:1002")
        // names: the group nickname, the DM partner's account name
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'gm:1002'") == "Erin Example")
        #expect(try qs(t.db, "SELECT c.name FROM contact_name c JOIN handle h ON h.id = c.handle_id WHERE h.normalized = 'gm:1004' AND c.name = 'Dana Demo'") == "Dana Demo")
        #expect(try qs(t.db, "SELECT DISTINCT origin FROM contact_name") == "groupme-export")
        // the emoji-pack placeholder is gone, polls render as text, mentions add nothing
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'ok%'") == "ok  sounds good")
        #expect(try qs(t.db, "SELECT body FROM message WHERE body LIKE 'movie%'") == "movie night? vote\nPoll: Which film? — Alpha (3), Beta (0)")
        // system line
        #expect(try qs(t.db, "SELECT kind || ':' || note FROM message WHERE kind = 'system'") == "system:Sam Sample left the group.")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE kind = 'system' AND sender_handle_id IS NOT NULL") == 0)
        // likes are ❤️ reactions, mine flagged by_me
        #expect(try qs(t.db, "SELECT DISTINCT emoji FROM reaction") == "❤️")
        #expect(try q(t.db, "SELECT count(*) FROM reaction WHERE by_me = 1") == 2)
        #expect(try q(t.db, "SELECT count(*) FROM reaction r JOIN message m ON m.id = r.message_id WHERE m.body LIKE 'ok%' AND r.actor_handle_id IS NOT NULL") == 2)
        // the downloaded image is stored once; the one that is not in the export stays as its URL
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == 1)
        #expect(try qs(t.db, "SELECT mime FROM attachment") == "image/jpeg")
        #expect(try qs(t.db, "SELECT body FROM message WHERE id = (SELECT message_id FROM attachment)") == "https://i.groupme.com/640x480.jpeg.remote999")
        #expect(try q(t.db, "SELECT count(*) FROM media") == 1)
        // sources and idempotence
        #expect(try q(t.db, "SELECT count(*) FROM source WHERE kind = 'groupme-export'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM source WHERE kind = 'groupme-thread'") == 2)
        #expect(try qs(t.db, "SELECT value FROM meta WHERE key = 'groupme.me'") == "Test Me")
        #expect(try q(t.db, "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'crew'") == 1)
        let again = try GroupMeImporter.importExport(at: ex, into: t.db, root: t.root)
        #expect(again.status == .alreadyImported && again.stats.inserted == 8)
        #expect(try q(t.db, "SELECT count(*) FROM message") == 8)
        let v = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(v.passed, "\(v.lines)")
    }

    @Test func aChangedConversationIsImportedAgainWithItsOverlapLinkedAsDuplicates() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let ex = GroupMeFixtures.export(); defer { try? FileManager.default.removeItem(at: ex) }
        _ = try GroupMeImporter.importExport(at: ex, into: t.db, root: t.root)
        // a newer export of the DM: one more message
        let f = ex.appendingPathComponent("1001_1004/message.json")
        var s = try String(contentsOf: f, encoding: .utf8)
        s = "[" + GroupMeFixtures.gmMessage(203, 1_500_002_000, from: "1004", name: "Dana Demo", text: "later") + "," + s.dropFirst()
        try s.write(to: f, atomically: true, encoding: .utf8)
        let r = try GroupMeImporter.importExport(at: ex, into: t.db, root: t.root)
        #expect(r.status == .imported && r.stats.foldersImported == 1 && r.stats.foldersSkipped == 1)
        #expect(r.stats.inserted == 1 && r.stats.duplicates == 2)
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE canonical_id IS NULL") == 9)
    }

    @Test func serviceKeyAndPersonMatchingKnowGroupMe() throws {
        #expect(ServiceKey.of(messageService: "groupme") == .groupme)
        #expect(ServiceKey.groupme.messageServices == ["groupme"])
        // a GroupMe person and a phone contact with the same full name become one person
        let a = MatchHandle(id: 1, normalized: "+15550001111", kind: "phone", names: [NameEntry(name: "Erin Example", priority: 10, origin: "android-xml")])
        let b = MatchHandle(id: 2, normalized: "gm:1002", kind: "groupme-user", names: [NameEntry(name: "Erin Example", priority: 10, origin: "groupme-export")])
        let r = PeopleMatcher.run(handles: [a, b], coexist: { _, _ in false })
        #expect(r.groups.count == 1 && r.groups[0].handleIDs == [1, 2])
        #expect(b.isGroupMe && !b.isPhoneLike)
    }
}

@Suite struct GroupMeMediaTests {
    @Test func fetchedMediaIsAttachedTheUrlLineRemovedAndProvenanceKept() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let ex = GroupMeFixtures.export(); defer { try? FileManager.default.removeItem(at: ex) }
        _ = try GroupMeImporter.importExport(at: ex, into: t.db, root: t.root)
        // message 103 has the stored gallery image and, on its own line, the remote one
        let remote = "https://i.groupme.com/640x480.jpeg.remote999"
        let dir = Fixtures.tempDir("gmfetch"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9])
        let sha = bytes.withUnsafeBytes { Hashing.sha256Hex($0) }
        try bytes.write(to: dir.appendingPathComponent(sha))
        let gone = "https://i.groupme.com/1x1.jpeg.gone"
        let log = """
        {"url":"\(remote)","status":"ok","ctype":"image/jpeg","bytes":\(bytes.count),"sha256":"\(sha)","file":"\(dir.appendingPathComponent(sha).path)"}
        {"url":"\(gone)","status":"gone","code":403}
        """
        try log.write(to: dir.appendingPathComponent("results.jsonl"), atomically: true, encoding: .utf8)
        let before = try q(t.db, "SELECT count(*) FROM attachment")
        let s = try GroupMeMedia.attach(fetchedDir: dir, into: t.db, root: t.root)
        #expect(s.urls == 2 && s.ok == 1 && s.gone == 1 && s.attached == 1 && s.bodiesEmptied == 1 && s.rejected == 0 && s.newFiles == 1)
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == before + 1)
        #expect(try qs(t.db, "SELECT filename FROM attachment WHERE sha256 = '\(sha)'") == remote)
        #expect(try qs(t.db, "SELECT mime FROM attachment WHERE sha256 = '\(sha)'") == "image/jpeg")
        #expect(try q(t.db, "SELECT count(*) FROM message WHERE body LIKE '%remote999%'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'remote999'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.id = (SELECT message_id FROM attachment WHERE sha256 = '\(sha)') AND m.body IS NULL") == 2)
        let again = try GroupMeMedia.attach(fetchedDir: dir, into: t.db, root: t.root)
        #expect(again.attached == 0 && again.urlsNotInArchive == 1)
        #expect(try q(t.db, "SELECT count(*) FROM attachment") == before + 1)
        let v = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(v.passed, "\(v.lines)")
        // a file that does not match its log line is rejected, not attached
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent(sha))
        let bad = try GroupMeMedia.attach(fetchedDir: dir, into: t.db, root: t.root)
        #expect(bad.attached == 0)
    }
}
