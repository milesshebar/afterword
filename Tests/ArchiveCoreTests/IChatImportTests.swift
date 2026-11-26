import Testing
import Foundation
@testable import ArchiveCore

/// Synthetic `.ichat` transcripts (555-01xx numbers, invented text), archived under the real class names (InstantMessage, Presentity, and
/// an NSFont attribute this process cannot decode).
@objc(MATestPresentity) final class TPres: NSObject, NSCoding {
    let id: String, service: String, login: String
    init(_ id: String, _ service: String, login: String = "") { self.id = id; self.service = service; self.login = login }
    func encode(with c: NSCoder) { c.encode(id, forKey: "ID"); c.encode(service, forKey: "ServiceName"); c.encode(login, forKey: "ServiceLoginID") }
    required init?(coder: NSCoder) { nil }
}
@objc(MATestFont) final class TFont: NSObject, NSCoding {
    override init() {}
    func encode(with c: NSCoder) { c.encode("Helvetica", forKey: "NSName") }
    required init?(coder: NSCoder) { nil }
}
@objc(MATestMessage) final class TMsg: NSObject, NSCoding {
    let sender: TPres?, time: Date?, text: String, guid: String, flags: Int64
    init(_ sender: TPres?, _ secs: Double?, _ text: String, _ guid: String, me: Bool, aim: Bool = false) {
        self.sender = sender; time = secs.map { Date(timeIntervalSinceReferenceDate: $0) }; self.text = text; self.guid = guid
        flags = aim ? (me ? 5 : 4097) : (me ? 1_085_445 : 1_060_865)
    }
    func encode(with c: NSCoder) {
        if let sender { c.encode(sender, forKey: "Sender") }; if let time { c.encode(time as NSDate, forKey: "Time") }; if !guid.isEmpty { c.encode(guid, forKey: "GUID") }; c.encode(flags, forKey: "Flags")
        c.encode(NSAttributedString(string: text, attributes: [NSAttributedString.Key("NSFont"): TFont()]), forKey: "MessageText")
        c.encode(false, forKey: "IsInvitation")
    }
    required init?(coder: NSCoder) { nil }
}

enum IChatFixtures {
    static let t0: Double = 600_000_000
    static func write(_ dir: URL, _ name: String, service: String, room: String = "", _ pres: [TPres], _ msgs: [TMsg]) throws {
        let a = NSKeyedArchiver(requiringSecureCoding: false)
        a.setClassName("InstantMessage", for: TMsg.self)
        a.setClassName("Presentity", for: TPres.self)
        a.setClassName("NSFont", for: TFont.self)
        let meta: NSDictionary = ["Service": service, "ChatRoom": room, "Participants": ["x", "y"] as NSArray, "PresentityIDs": [] as NSArray]
        a.encode(meta, forKey: "metadata")
        a.encode(["", "", NSMutableArray(array: msgs), NSMutableArray(array: pres)] as NSArray, forKey: "root")
        a.finishEncoding()
        let f = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try a.encodedData.write(to: f)
    }

    /// An archive with alice's 1:1 thread holding G-1, and the transcripts folder.
    static func setup() throws -> (TestArchive, URL) {
        let t = try TestArchive()
        try t.db.transaction {
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('macos-chatdb', 'x', 'seed', 0, 0)")
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "macos-chatdb")
            _ = try w.add(MessageRecord(participants: ["+12125550111"], sender: "+12125550111", tsMs: (Int64(t0) + 978_307_200) * 1000, isFromMe: false,
                                        service: "imessage", body: "held one", sourceKey: "ios:G-1"))
        }
        let dir = t.dir.appendingPathComponent("Archive")
        let me = TPres("owner@example.com", "iMessage"), alice = TPres("+12125550111", "iMessage"), bob = TPres("+12125550122", "iMessage")
        let carol = TPres("+12125550133", "iMessage")
        try write(dir, "2019-01-01/Alice on 2019-01-01.ichat", service: "iMessage", [me, alice], [
            TMsg(alice, t0, "held one", "G-1", me: false),
            TMsg(alice, t0 + 60, "new from alice", "G-2", me: false),
            TMsg(me, t0 + 120, "new from me", "G-3", me: true),
            TMsg(me, t0 + 130, "\u{FFFC}", "G-4", me: true),
            TMsg(carol, t0 + 140, "carol is not in this thread", "G-9", me: false),
        ])
        try write(dir, "2019-01-02/Alice again.ichat", service: "iMessage", [me, alice], [TMsg(alice, t0 + 60, "new from alice", "G-2", me: false)])
        try write(dir, "2019-02-01/Bob.ichat", service: "iMessage", [me, bob], [
            TMsg(bob, t0 + 5000, "hi from bob", "G-5", me: false), TMsg(me, t0 + 5060, "on hold", "G-6", me: true),
            TMsg(me, t0 + 5070, "hi bob", "G-7", me: true),
        ])
        try write(dir, "2019-03-01/Group.ichat", service: "iMessage", room: "chat777", [me, alice, bob], [TMsg(bob, t0 + 9000, "group hello", "G-8", me: false)])
        let mine = TPres("owner@example.com", "AIM", login: "owner@example.com"), buddy = TPres("Cool Buddy", "AIM", login: "owner@example.com")
        try write(dir, "aim/Cool Buddy on 2012-01-10.ichat", service: "AIM", [buddy, mine], [
            TMsg(buddy, 347_946_403, "sup", "A-1", me: false, aim: true), TMsg(mine, 347_946_410, "not much", "A-2", me: true, aim: true),
            TMsg(nil, 347_946_420, "an iChat notice with no sender", "A-3", me: false, aim: true),
        ])
        try "not a plist".write(to: dir.appendingPathComponent("2019-04-01/broken.ichat").createdParent(), atomically: true, encoding: .utf8)
        return (t, dir)
    }
}

extension URL {
    func createdParent() throws -> URL { try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true); return self }
}

@Suite struct IChatImportTests {
    @Test func readsTranscriptsPlacesThemAndChangesNoOldRow() throws {
        let (t, dir) = try IChatFixtures.setup(); defer { t.cleanup() }
        let oldRow = try t.db.scalarString("SELECT id || thread_id || body || source_key FROM message")
        let threadsBefore = try t.db.scalarInt("SELECT count(*) FROM thread")
        let ledger = t.dir.appendingPathComponent("ledger.tsv")
        let r = try IChatImporter.importTranscripts(at: dir, into: t.db, root: t.root, origin: "host:/x/Archive", holdKeys: ["ios:G-6"], ledger: ledger)
        let s = r.stats
        #expect(r.status == .imported)
        #expect(s.files == 6 && s.unreadable == 1 && s.messages == 13)
        // G-2, G-3 (alice's thread), G-5, G-7 (bob, a new 1:1), A-1, A-2 (AIM) written; G-1 and the second G-2 held by guid.
        #expect(s.inserted == 6 && s.heldGuid == 2)
        #expect(s.leftOutEmpty == 1 && s.leftOutSender == 2 && s.leftOutNoThread == 1 && s.heldByList == 1)   // G-9 (not a member) and A-3 (no sender)
        #expect(s.byService == ["imessage": 4, "aim": 2])
        #expect(try t.db.scalarString("SELECT id || thread_id || body || source_key FROM message WHERE source_key = 'ios:G-1'") == oldRow)
        let alice = try t.db.scalarInt("SELECT thread_id FROM message WHERE source_key = 'ios:G-1'")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE thread_id = \(alice)") == 3)
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.source_key = 'ios:G-2'") == "+12125550111")
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE source_key = 'ios:G-3'") == 1)
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE source_key = 'ios:G-3'") == (Int64(IChatFixtures.t0) + 120 + 978_307_200) * 1000)
        // AIM: its own service, handle and thread.
        #expect(try t.db.scalarString("SELECT t.service || '|' || t.origin FROM thread t JOIN message m ON m.thread_id = t.id WHERE m.source_key = 'aim:A-1'") == "aim|dm")
        #expect(try t.db.scalarString("SELECT h.normalized || '|' || h.kind FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.source_key = 'aim:A-1'") == "aim:coolbuddy|aim-user")
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE source_key = 'aim:A-2'") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread") == threadsBefore + 2)
        #expect(try t.db.scalarString("SELECT path FROM source WHERE kind = 'ichat-transcripts'") == "host:/x/Archive")
        // The ledger: one line per message (plus the unreadable file), the written ids are the database's.
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(lines.count == 14)
        #expect(lines.contains { $0[1] == "A-3" && $0[6] == "left-out-no-sender" })
        let written = Set(lines.compactMap { $0[6] == "new" ? Int64($0[9]) : nil })
        var inDB = Set<Int64>()
        let st = try t.db.prepare("SELECT id FROM message WHERE source_id = \(r.sourceID)")
        while try st.step() { inDB.insert(st.int(0)) }
        #expect(written == inDB && written.count == 6)
        #expect(lines.contains { $0[1] == "G-9" && $0[6] == "left-out-sender-not-member" })
        #expect(lines.contains { $0[1] == "G-8" && $0[6] == "left-out-no-thread" })
        #expect(lines.contains { $0[0].hasSuffix("broken.ichat") && $0[6] == "left-out-unreadable-file" })
        // Again: nothing.
        #expect(try IChatImporter.importTranscripts(at: dir, into: t.db, root: t.root, holdKeys: ["ios:G-6"]).status == .alreadyImported)
    }

    @Test func aimIsAServiceOfItsOwn() {
        #expect(ServiceKey.of(messageService: "aim") == .aim && ServiceKey.aim.label == "AIM")
        #expect(ServiceHandle.aim(screenName: "Cool Buddy").normalized == "aim:coolbuddy")
    }

    // MARK: edge cases

    /// A message without a guid gets no source key (content rules only, never held as another guid-less message);
    /// the one other party is counted after normalizing (two spellings of one address are one person); a message without a date is left out.
    @Test func guidlessDatelessAndTwoSpellingsOfOneParty() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = t.dir.appendingPathComponent("A")
        let me = TPres("owner@example.com", "iMessage"), a1 = TPres("Dana@Example.com", "iMessage"), a2 = TPres("dana@example.com", "iMessage")
        try IChatFixtures.write(dir, "x/one.ichat", service: "iMessage", [me, a1, a2], [
            TMsg(a1, IChatFixtures.t0, "no guid here", "", me: false),
            TMsg(a2, IChatFixtures.t0 + 10, "second spelling", "Q-2", me: false),
            TMsg(me, nil, "no date", "Q-3", me: true),
        ])
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let s = try IChatImporter.importTranscripts(at: dir, into: t.db, root: t.root, ledger: ledger).stats
        #expect(s.inserted == 2 && s.leftOutNoThread == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE body = 'no guid here' AND source_key IS NULL") == 1)
        #expect(try t.db.scalarInt("SELECT count(DISTINCT thread_id) FROM message") == 1)
        #expect(try String(contentsOf: ledger, encoding: .utf8).contains("left-out-no-date"))
        // Another transcript with a different guid-less message is not held against the first one.
        let dir2 = t.dir.appendingPathComponent("B")
        try IChatFixtures.write(dir2, "y/two.ichat", service: "iMessage", [me, a1], [
            TMsg(a1, IChatFixtures.t0 + 5000, "another one without a guid", "", me: false), TMsg(me, IChatFixtures.t0 + 5010, "ok", "", me: true),
        ])
        let s2 = try IChatImporter.importTranscripts(at: dir2, into: t.db, root: t.root).stats
        #expect(s2.inserted == 2 && s2.heldGuid == 0 && s2.heldMatches == 0)
    }

    /// The ledger is stored with the import; a retry of imported transcripts writes it again from the database.
    @Test func theLedgerCanBeWrittenAgainFromTheDatabase() throws {
        let (t, dir) = try IChatFixtures.setup(); defer { t.cleanup() }
        let ledger = t.dir.appendingPathComponent("ledger.tsv")
        _ = try IChatImporter.importTranscripts(at: dir, into: t.db, root: t.root, ledger: ledger)
        let first = try String(contentsOf: ledger, encoding: .utf8)
        try FileManager.default.removeItem(at: ledger)
        let again = try IChatImporter.importTranscripts(at: dir, into: t.db, root: t.root, ledger: ledger)
        #expect(again.status == .alreadyImported)
        #expect(try String(contentsOf: ledger, encoding: .utf8) == first)
    }
}
