import Testing
import Foundation
@testable import ArchiveCore

/// A synthetic Telegram Postbox store in the 2020 layout (invented people and text): t2 peers and t7 messages, encoded the way Postbox
/// writes them.
enum PostboxFixtures {
    struct Enc {
        var d = Data()
        mutating func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        mutating func key(_ k: String) { d.append(UInt8(k.utf8.count)); d.append(contentsOf: Array(k.utf8)) }
        mutating func string(_ k: String, _ v: String) { key(k); d.append(4); le(Int32(v.utf8.count)); d.append(contentsOf: Array(v.utf8)) }
        mutating func int32(_ k: String, _ v: Int32) { key(k); d.append(0); le(v) }
        mutating func int64(_ k: String, _ v: Int64) { key(k); d.append(1); le(v) }
        mutating func bytes(_ k: String, _ v: Data) { key(k); d.append(10); le(Int32(v.count)); d.append(v) }
        mutating func object(_ k: String, hash: Int32, _ inner: Data) { key(k); d.append(5); le(hash); le(Int32(inner.count)); d.append(inner) }
    }
    static let me: Int64 = 100, alice: Int64 = 101, bob: Int64 = 102
    static let group: Int64 = (2 << 32) | 500, channel: Int64 = (2 << 32) | 600, service: Int64 = 777_000
    static let t0: Int32 = 1_594_667_000

    static func peer(_ fields: (inout Enc) -> Void) -> Data {
        var inner = Enc(); fields(&inner)
        var outer = Enc(); outer.object("_", hash: 1, inner.d); return outer.d
    }
    static func key(_ peer: Int64, _ ts: Int32, _ id: Int32) -> Data {
        var d = Data()
        withUnsafeBytes(of: peer.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: ts.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0).bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: id.bigEndian) { d.append(contentsOf: $0) }
        return d
    }
    /// media: (hash, fields) objects stored under "_"
    static func message(incoming: Bool, author: Int64?, text: String, forwardFrom: Int64? = nil, media: [(Int32, Data)] = [],
                        referencedMedia: [(Int32, Int64)] = []) -> Data {
        var e = Enc()
        e.d.append(0); e.le(UInt32(1)); e.le(UInt32(1)); e.d.append(0)            // type, stable id, version, no data flags
        e.le(UInt32(incoming ? 4 : 0)); e.le(UInt32(0))                            // flags, tags
        if let f = forwardFrom { e.d.append(1); e.le(f); e.le(Int32(t0 - 100)) } else { e.d.append(0) }
        if let a = author { e.d.append(1); e.le(a) } else { e.d.append(0) }
        e.le(Int32(text.utf8.count)); e.d.append(contentsOf: Array(text.utf8))
        e.le(Int32(1)); var attr = Enc(); attr.object("_", hash: 987_966_334, { var p = Enc(); p.int32("p", 0); return p.d }()); e.le(Int32(attr.d.count)); e.d.append(attr.d)
        e.le(Int32(media.count))
        for (h, f) in media { var m = Enc(); m.object("_", hash: h, f); e.le(Int32(m.d.count)); e.d.append(m.d) }
        e.le(Int32(referencedMedia.count))
        for (ns, id) in referencedMedia { e.le(ns); e.le(id) }
        return e.d
    }
    static func added(_ ids: [Int64]) -> Data {
        var b = Data(); withUnsafeBytes(of: Int32(ids.count).littleEndian) { b.append(contentsOf: $0) }
        for i in ids { withUnsafeBytes(of: i.littleEndian) { b.append(contentsOf: $0) } }
        var e = Enc(); e.int32("_rawValue", 2); e.bytes("peerIds", b); return e.d
    }

    static func store(dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("db_sqlite")
        let db = try Database(path: url.path)
        try db.exec("CREATE TABLE t2 (key INTEGER PRIMARY KEY, value BLOB); CREATE TABLE t7 (key BLOB, value BLOB)")
        let p = try db.prepare("INSERT INTO t2 VALUES (?, ?)")
        for (id, fields) in [(me, { (e: inout Enc) in e.string("fn", "Owner"); e.string("ln", "T") }),
                             (alice, { (e: inout Enc) in e.string("fn", "Alice"); e.string("ln", "A") }),
                             (bob, { (e: inout Enc) in e.string("fn", "Bob") }),
                             (group, { (e: inout Enc) in e.string("t", "Event Chat"); e.int32("i.t", 1) }),
                             (channel, { (e: inout Enc) in e.string("t", "Event"); e.int32("i.t", 0) }),
                             (service, { (e: inout Enc) in e.string("fn", "Telegram") })] as [(Int64, (inout Enc) -> Void)] {
            p.bind(1, id).bindBlob(2, peer(fields)); try p.run()
        }
        let m = try db.prepare("INSERT INTO t7 VALUES (?, ?)")
        func put(_ k: Data, _ v: Data) throws { m.bindBlob(1, k).bindBlob(2, v); try m.run() }
        try put(key(group, t0, 1), message(incoming: true, author: alice, text: "", media: [(TelegramPostboxImporter.mediaAction, added([alice]))]))
        try put(key(group, t0 + 10, 2), message(incoming: true, author: alice, text: "", media: [(TelegramPostboxImporter.mediaAction, added([bob]))]))
        try put(key(group, t0 + 20, 3), message(incoming: true, author: alice, text: "hello all"))
        try put(key(group, t0 + 30, 4), message(incoming: false, author: me, text: "hi from me"))
        try put(key(group, t0 + 40, 5), message(incoming: true, author: bob, text: "", media: [(TelegramPostboxImporter.mediaImage, Data())]))
        try put(key(group, t0 + 50, 6), message(incoming: true, author: bob, text: "passed along", forwardFrom: 999))
        try put(key(group, t0 + 60, 7), message(incoming: true, author: bob, text: "   "))
        try put(key(channel, t0, 1), message(incoming: true, author: channel, text: "a broadcast post"))
        try put(key(service, t0, 1), message(incoming: true, author: service, text: "Login code: 00000"))
        try put(key(channel, t0 + 5, 2), Data([0, 1, 2]))
        return url
    }
}

@Suite struct TelegramImportTests {
    @Test func importsOnlyTheChosenChatAsOneThreadAndLedgersEveryRow() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let url = try PostboxFixtures.store(dir: t.dir)
        let ledger = t.dir.appendingPathComponent("tg.tsv")
        let r = try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root, origin: "host:/x/db_sqlite", ledger: ledger)
        let s = r.stats
        #expect(s.rows == 10 && s.unparsed == 1 && s.notSelected == 2)
        #expect(s.inserted == 6 && s.empty == 1 && s.system == 2 && s.mediaWithoutFile == 1 && s.text == 3 && s.forwarded == 1)
        let thread = try t.db.scalarInt("SELECT thread_id FROM message WHERE source_key = 'tg:\(PostboxFixtures.group):0:3'")
        #expect(try t.db.scalarString("SELECT service || '|' || origin || '|' || title || '|' || external_id FROM thread WHERE id = \(thread)") == "telegram|group|Event Chat|tg:\(PostboxFixtures.group)")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE thread_id = \(thread)") == 6)
        #expect(try t.db.scalarString("SELECT group_concat(h.normalized, ',') FROM (SELECT h.normalized FROM thread_member tm JOIN handle h ON h.id = tm.handle_id WHERE tm.thread_id = \(thread) ORDER BY 1) h") == "tg:101,tg:102")
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE body = 'hi from me'") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE body = 'hi from me' AND sender_handle_id IS NULL") == 1)
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'hello all'") == "tg:101")
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'tg:\(PostboxFixtures.group):0:1'") == "Alice A joined the group")
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = 'tg:\(PostboxFixtures.group):0:2'") == "Alice A added Bob")
        #expect(try t.db.scalarString("SELECT kind || '|' || note FROM message WHERE source_key = 'tg:\(PostboxFixtures.group):0:5'")?.hasPrefix("system|(photo not attached") == true)
        #expect(try t.db.scalarString("SELECT note FROM message WHERE body = 'passed along'") == "forwarded")
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE body = 'hello all'") == Int64(PostboxFixtures.t0 + 20) * 1000)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE body LIKE '%broadcast%' OR body LIKE 'Login code%'") == 0)
        #expect(try t.db.scalarString("SELECT name FROM contact_name cn JOIN handle h ON h.id = cn.handle_id WHERE h.normalized = 'tg:101'") == "Alice A")
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(lines.count == 10)
        #expect(Set(lines.map { $0[7] }) == ["new", "left-out-empty", "left-out-chat-not-selected", "left-out-unparsed"])
        #expect(lines.filter { $0[7] == "new" }.compactMap { Int64($0[8]) }.count == 6)
        #expect(try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root).status == .alreadyImported)
    }

    @Test func telegramIsAServiceOfItsOwn() {
        #expect(ServiceKey.of(messageService: "telegram") == .telegram && ServiceKey.telegram.label == "Telegram")
        #expect(ServiceHandle.telegram(userID: 42, name: "x").normalized == "tg:42")
    }

    // MARK: edge cases

    static func extraStore(_ dir: URL, name: String, _ fill: (Database) throws -> Void) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try PostboxFixtures.store(dir: dir.appendingPathComponent("base-" + name).created()), to: url)
        try fill(try Database(path: url.path))
        return url
    }
    static func put(_ db: Database, _ k: Data, _ v: Data) throws { let m = try db.prepare("INSERT INTO t7 VALUES (?, ?)"); m.bindBlob(1, k).bindBlob(2, v); try m.run() }
    static func addPeer(_ db: Database, _ id: Int64, _ fields: (inout PostboxFixtures.Enc) -> Void) throws {
        let p = try db.prepare("INSERT INTO t2 VALUES (?, ?)"); p.bind(1, id).bindBlob(2, PostboxFixtures.peer(fields)); try p.run()
    }

    /// The chat is chosen by its full peer id; a user peer with the same low 32 bits is another chat.
    @Test func chatsAreChosenByTheFullPeerID() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let url = try Self.extraStore(t.dir, name: "s2") { db in
            try Self.addPeer(db, 500) { $0.string("fn", "Same Low Bits") }
            try Self.put(db, PostboxFixtures.key(500, PostboxFixtures.t0 + 70, 1), PostboxFixtures.message(incoming: true, author: 500, text: "a 1:1 chat, not the group"))
            try Self.put(db, PostboxFixtures.key(500, PostboxFixtures.t0 + 71, 2), PostboxFixtures.message(incoming: false, author: PostboxFixtures.me, text: "my reply there"))
        }
        let s = try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root).stats
        #expect(s.inserted == 6 && s.notSelected == 4)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE body = 'a 1:1 chat, not the group'") == 0)
        // A bare number is a full peer id: 500 is the user chat 0:500 only, not the group 2:500 that shares its low 32 bits.
        let t2 = try TestArchive(); defer { t2.cleanup() }
        let only = try TelegramPostboxImporter.importStore(at: url, chats: [500], into: t2.db, root: t2.root).stats
        #expect(only.inserted == 2)
        #expect(try TelegramPostboxImporter.parseChat("2:500") == PostboxFixtures.group && TelegramPostboxImporter.parseChat("\(PostboxFixtures.group)") == PostboxFixtures.group)
    }

    /// The thread is the chat (keyed by its peer id): a later snapshot with a new author lands in the same thread, and two chats
    /// whose only other author is the same person stay two threads.
    @Test func theThreadIsKeyedByTheChat() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let first = try PostboxFixtures.store(dir: t.dir.appendingPathComponent("a").created())
        _ = try TelegramPostboxImporter.importStore(at: first, chats: [PostboxFixtures.group], into: t.db, root: t.root)
        let later = try Self.extraStore(t.dir, name: "s3") { db in
            try Self.addPeer(db, 103) { $0.string("fn", "Carol") }
            try Self.put(db, PostboxFixtures.key(PostboxFixtures.group, PostboxFixtures.t0 + 90, 8), PostboxFixtures.message(incoming: true, author: 103, text: "carol arrives"))
            let other: Int64 = (2 << 32) | 501
            try Self.addPeer(db, other) { $0.string("t", "Other Chat"); $0.int32("i.t", 1) }
            try Self.put(db, PostboxFixtures.key(other, PostboxFixtures.t0 + 95, 1), PostboxFixtures.message(incoming: true, author: PostboxFixtures.alice, text: "alice elsewhere"))
            try Self.put(db, PostboxFixtures.key(other, PostboxFixtures.t0 + 96, 2), PostboxFixtures.message(incoming: false, author: PostboxFixtures.me, text: "me elsewhere"))
        }
        let s = try TelegramPostboxImporter.importStore(at: later, chats: [PostboxFixtures.group, (2 << 32) | 501], into: t.db, root: t.root).stats
        #expect(s.inserted == 3)                                   // carol's row and the other chat's two; the first six are held by key
        let g = try t.db.scalarInt("SELECT thread_id FROM message WHERE body = 'hello all'")
        #expect(try t.db.scalarInt("SELECT thread_id FROM message WHERE body = 'carol arrives'") == g)
        #expect(try t.db.scalarInt("SELECT thread_id FROM message WHERE body = 'alice elsewhere'") != g)
        #expect(try t.db.scalarString("SELECT key FROM thread WHERE id = \(g)") == "telegram:\(PostboxFixtures.group)")
    }

    /// A row with its own Telegram id is not held as someone else's identical text a second earlier.
    @Test func sameTextFromAnotherSenderIsNotADuplicate() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let first = try PostboxFixtures.store(dir: t.dir.appendingPathComponent("a").created())
        _ = try TelegramPostboxImporter.importStore(at: first, chats: [PostboxFixtures.group], into: t.db, root: t.root)
        let later = try Self.extraStore(t.dir, name: "s5") { db in
            try Self.put(db, PostboxFixtures.key(PostboxFixtures.group, PostboxFixtures.t0 + 21, 9), PostboxFixtures.message(incoming: true, author: PostboxFixtures.bob, text: "hello all"))
        }
        let s = try TelegramPostboxImporter.importStore(at: later, chats: [PostboxFixtures.group], into: t.db, root: t.root).stats
        #expect(s.inserted == 1 && s.heldMatches == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE body = 'hello all'") == 2)
    }

    /// Actions say what they are; nothing is called a join unless the action adds its own author.
    @Test func actionsSayWhatTheyAre() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        func action(_ raw: Int32, _ peers: [Int64]?, title: String? = nil) -> Data {
            var e = PostboxFixtures.Enc(); e.int32("_rawValue", raw)
            if let peers { var b = Data(); withUnsafeBytes(of: Int32(peers.count).littleEndian) { b.append(contentsOf: $0) }; for p in peers { withUnsafeBytes(of: p.littleEndian) { b.append(contentsOf: $0) } }; e.bytes("peerIds", b) }
            if let title { e.string("title", title) }
            return e.d
        }
        let url = try Self.extraStore(t.dir, name: "s6") { db in
            let g = PostboxFixtures.group, a = PostboxFixtures.alice
            try Self.put(db, PostboxFixtures.key(g, PostboxFixtures.t0 + 100, 20), PostboxFixtures.message(incoming: true, author: a, text: "", media: [(TelegramPostboxImporter.mediaAction, action(2, []))]))
            try Self.put(db, PostboxFixtures.key(g, PostboxFixtures.t0 + 101, 21), PostboxFixtures.message(incoming: true, author: a, text: "", media: [(TelegramPostboxImporter.mediaAction, action(3, [a]))]))
            try Self.put(db, PostboxFixtures.key(g, PostboxFixtures.t0 + 102, 22), PostboxFixtures.message(incoming: true, author: a, text: "", media: [(TelegramPostboxImporter.mediaAction, action(5, nil, title: "New Name"))]))
            try Self.put(db, PostboxFixtures.key(g, PostboxFixtures.t0 + 103, 23), PostboxFixtures.message(incoming: true, author: a, text: "", media: [(TelegramPostboxImporter.mediaAction, action(99, nil))]))
        }
        _ = try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root)
        func note(_ id: Int) throws -> String? { try t.db.scalarString("SELECT note FROM message WHERE source_key = 'tg:\(PostboxFixtures.group):0:\(id)'") }
        #expect(try note(20) == "Alice A: a Telegram service message (members added)")
        #expect(try note(21) == "Alice A left the group")
        #expect(try note(22) == "Alice A renamed the group to “New Name”")
        #expect(try note(23) == "Alice A: a Telegram service message (type 99)")
        #expect(try note(1) == "Alice A joined the group")
    }

    /// A file is labelled by its own attributes; a referenced media item is looked up in the media table.
    @Test func filesAreLabelledByTheirAttributes() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        func file(_ mime: String, _ attrs: [Int32]) -> Data {
            var e = PostboxFixtures.Enc(); e.string("mt", mime)
            e.key("at"); e.d.append(8); e.le(Int32(attrs.count))
            for a in attrs { var x = PostboxFixtures.Enc(); x.int32("t", a); e.le(Int32(1922378215)); e.le(Int32(x.d.count)); e.d.append(x.d) }
            return e.d
        }
        let url = try Self.extraStore(t.dir, name: "s7") { db in
            let g = PostboxFixtures.group, b = PostboxFixtures.bob
            for (i, (m, a)) in [("video/mp4", [0, 4]), ("video/mp4", [3, 4]), ("image/webp", [1]), ("audio/ogg", [5]), ("application/pdf", [0])].enumerated() {
                try Self.put(db, PostboxFixtures.key(g, PostboxFixtures.t0 + 200 + Int32(i), Int32(30 + i)), PostboxFixtures.message(incoming: true, author: b, text: "", media: [(TelegramPostboxImporter.mediaFile, file(m, a.map(Int32.init)))]))
            }
            try db.exec("CREATE TABLE t6 (key BLOB, value BLOB)")
            var mk = Data(); withUnsafeBytes(of: Int32(0).bigEndian) { mk.append(contentsOf: $0) }; withUnsafeBytes(of: Int64(777).bigEndian) { mk.append(contentsOf: $0) }
            var obj = PostboxFixtures.Enc(); obj.object("_", hash: TelegramPostboxImporter.mediaImage, Data())
            var mv = Data([0]); withUnsafeBytes(of: Int32(obj.d.count).littleEndian) { mv.append(contentsOf: $0) }; mv.append(obj.d)
            mv.append(contentsOf: [0, 0, 0, 0])                    // the real store's values carry 4 more bytes after the object
            let st = try db.prepare("INSERT INTO t6 VALUES (?, ?)"); st.bindBlob(1, mk).bindBlob(2, mv); try st.run()
            try Self.put(db, PostboxFixtures.key(g, PostboxFixtures.t0 + 300, 40), PostboxFixtures.message(incoming: true, author: b, text: "", forwardFrom: 9, referencedMedia: [(0, 777)]))
        }
        _ = try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root)
        func note(_ id: Int) throws -> String { try t.db.scalarString("SELECT note FROM message WHERE source_key = 'tg:\(PostboxFixtures.group):0:\(id)'") ?? "" }
        #expect(try note(30).hasPrefix("(video not attached") && note(31).hasPrefix("(animation not attached") && note(32).hasPrefix("(sticker not attached"))
        #expect(try note(33).hasPrefix("(audio not attached") && note(34).hasPrefix("(document not attached") && note(40).hasPrefix("(forwarded photo not attached"))
    }

    /// The real store's photo objects hold field types this reader does not decode (an object dictionary, type 9): the object's type
    /// must still be known (a forwarded photo once came out as "media").
    @Test func anObjectWithUnreadFieldsKeepsItsType() throws {
        var inner = PostboxFixtures.Enc(); inner.key("d"); inner.d.append(9); inner.le(Int32(0))      // an empty ObjectDictionary
        var outer = PostboxFixtures.Enc(); outer.object("_", hash: TelegramPostboxImporter.mediaImage, inner.d)
        let o = try TelegramPostboxImporter.decodeObject(outer.d)
        guard case .object(let h, _)? = o["_"] else { Issue.record("no object"); return }
        #expect(h == TelegramPostboxImporter.mediaImage)
    }

    /// The ledger is stored with the import; a retry of an imported store writes it again from the database.
    @Test func theLedgerCanBeWrittenAgainFromTheDatabase() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let url = try PostboxFixtures.store(dir: t.dir)
        let ledger = t.dir.appendingPathComponent("tg.tsv")
        _ = try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root, ledger: ledger)
        let first = try String(contentsOf: ledger, encoding: .utf8)
        try FileManager.default.removeItem(at: ledger)
        let again = try TelegramPostboxImporter.importStore(at: url, chats: [PostboxFixtures.group], into: t.db, root: t.root, ledger: ledger)
        #expect(again.status == .alreadyImported)
        #expect(try String(contentsOf: ledger, encoding: .utf8) == first)
    }
}

extension URL {
    func created() throws -> URL { try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true); return self }
}
