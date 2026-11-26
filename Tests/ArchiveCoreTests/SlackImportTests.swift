import Testing
import Foundation
@testable import ArchiveCore

/// Synthetic Slack desktop saves in the real layout (invented people, ids and text): `<dir>/https_app.slack.com_0.indexeddb.blob/1/<xx>/<hex>`,
/// each a Blink envelope (ff 14) around a V8 serialization of a Redux state with one workspace.
enum SlackFixtures {
    /// A minimal V8 serializer (version 13, the version Slack's 2021 saves carry) for the values the saves use.
    indirect enum J { case s(String), i(Int), d(Double), b(Bool), null, a([J]), o([(String, J)]) }

    static func varint(_ v: UInt64, _ out: inout [UInt8]) { var v = v; repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0 }
    static func enc(_ j: J, _ out: inout [UInt8]) {
        switch j {
        case .s(let s):
            if s.unicodeScalars.allSatisfy({ $0.value < 0x100 }) { out.append(0x22); varint(UInt64(s.unicodeScalars.count), &out); out += s.unicodeScalars.map { UInt8($0.value) } }
            else { let u = Array(s.utf16); out.append(0x63); varint(UInt64(u.count * 2), &out); for c in u { out.append(UInt8(c & 0xff)); out.append(UInt8(c >> 8)) } }
        case .i(let i): out.append(0x49); let z = UInt32(bitPattern: Int32(i)); varint(UInt64((z << 1) ^ UInt32(bitPattern: Int32(i) >> 31)), &out)
        case .d(let d): out.append(0x4e); withUnsafeBytes(of: d.bitPattern.littleEndian) { out += $0 }
        case .b(let b): out.append(b ? 0x54 : 0x46)
        case .null: out.append(0x30)
        case .a(let a): out.append(0x41); varint(UInt64(a.count), &out); for x in a { enc(x, &out) }; out.append(0x24); varint(0, &out); varint(UInt64(a.count), &out)
        case .o(let o): out.append(0x6f); for (k, v) in o { enc(.s(k), &out); enc(v, &out) }; out.append(0x7b); varint(UInt64(o.count), &out)
        }
    }
    static func blob(_ j: J) -> Data { var out: [UInt8] = [0xff, 0x14, 0xff, 0x0d]; enc(j, &out); return Data(out) }
    /// The envelope of the 2024 saves: Blink 21 (`ff 15`, a trailer-offset tag and 12 bytes), then V8 wire version 15.
    static func blob2024(_ j: J) -> Data { var out: [UInt8] = [0xff, 0x15, 0xfe] + [UInt8](repeating: 0, count: 12) + [0xff, 0x0f]; enc(j, &out); return Data(out) }

    static let team = "TTEAM0001", me = "UME000001", ann = "UANN00001", bo = "UBO000001", cy = "UCY000001", bot = "BBOT00001"
    static let general = "CGEN00001", dmAnn = "DANN00001", group = "GMP000001"
    static let t0 = 1_608_352_978

    static func member(_ id: String, _ name: String, isSelf: Bool = false) -> (String, J) {
        (id, .o([("id", .s(id)), ("real_name", .s(name)), ("name", .s(name.lowercased())), ("is_self", .b(isSelf)), ("profile", .o([("display_name", .s(name))]))]))
    }
    static func msg(_ ts: String, _ cid: String, user: String? = nil, text: String, extra: [(String, J)] = []) -> (String, J) {
        var f: [(String, J)] = [("type", .s("message")), ("ts", .s(ts)), ("channel", .s(cid)), ("text", .s(text)), ("_rxn_key", .s("message-\(ts)-\(cid)"))]
        if let user { f.append(("user", .s(user))) }
        return (ts, .o(f + extra))
    }
    static func ts(_ dt: Int, _ frac: String = "000100") -> String { "\(t0 + dt).\(frac)" }

    /// One save. `wrap`: the channels/members/reactions tables as `{internalUseOnlyByIdMap, meta}` (some real saves do this).
    /// `teams`: the save's teams table (default: the one test workspace); `top`: more top-level keys (`selfTeamIds`).
    static func save(messages: [(String, [(String, J)])], reactions: [(String, J)] = [], wrap: Bool = false, members: [(String, J)]? = nil, selfID: String = me,
                     extraFiles: [(String, J)] = [], teams: [(String, String)] = [(team, "Test Works")], top: [(String, J)] = []) -> J {
        func t(_ x: [(String, J)]) -> J { wrap ? .o([("internalUseOnlyByIdMap", .o(x)), ("meta", .o([("isIdObjectMapReducer", .b(true))]))]) : .o(x) }
        let mem = members ?? [member(me, "Owner Test", isSelf: true), member(ann, "Ann Example"), member(bo, "Bo Sample"), member(cy, "Cy Person")]
        return .o(top + [
            ("bootData", .o([("user_id", .s(selfID)), ("feature_x", .b(true))])),
            ("teams", .o(teams.map { ($0.0, .o([("id", .s($0.0)), ("name", .s($0.1))])) })),
            ("members", t(mem)),
            ("bots", .o([(bot, .o([("id", .s(bot)), ("name", .s("Drive Bot"))]))])),
            ("channels", t([
                (general, .o([("id", .s(general)), ("name", .s("general")), ("is_channel", .b(true)), ("is_member", .b(true))])),
                (dmAnn, .o([("id", .s(dmAnn)), ("is_im", .b(true)), ("user", .s(ann))])),
                (group, .o([("id", .s(group)), ("name", .s("mpdm-x")), ("is_mpim", .b(true)), ("members", .a([.s(me), .s(bo), .s(cy)]))])),
            ])),
            ("files", .o([
                ("FIMG00001", .o([("id", .s("FIMG00001")), ("title", .s("frame.png")), ("pretty_type", .s("PNG")), ("mode", .s("hosted"))])),
                ("FEXT00001", .o([("id", .s("FEXT00001")), ("title", .s("cut.mp3")), ("pretty_type", .s("MP3")), ("mode", .s("external")), ("is_external", .b(true)),
                                  ("external_type", .s("dropbox")), ("external_url", .s("https://www.dropbox.com/s/x/cut.mp3"))])),
                ("FDEL00001", .o([("id", .s("FDEL00001")), ("mode", .s("tombstone"))])),
            ] + extraFiles)),
            ("messages", .o(messages.map { ($0.0, .o($0.1)) })),
            ("reactions", t(reactions)),
        ])
    }

    /// Writes saves as blob numbers 2, 3, ... under the real folder layout; returns the IndexedDB folder.
    static func write(_ saves: [J], to dir: URL, extraFiles: [(Int, Data)] = []) throws -> URL {
        let idb = dir.appendingPathComponent("IndexedDB")
        let blobDir = idb.appendingPathComponent("https_app.slack.com_0.indexeddb.blob/1/00")
        try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: idb.appendingPathComponent("https_app.slack.com_0.indexeddb.leveldb"), withIntermediateDirectories: true)
        try Data("leveldb".utf8).write(to: idb.appendingPathComponent("https_app.slack.com_0.indexeddb.leveldb/000003.log"))
        for (i, s) in saves.enumerated() { try blob(s).write(to: blobDir.appendingPathComponent(String(i + 2, radix: 16))) }
        for (n, d) in extraFiles { try d.write(to: blobDir.appendingPathComponent(String(n, radix: 16))) }
        return idb
    }

    /// Two overlapping saves: the second edits a message, adds reactions, and carries a newer message; a truncated third blob.
    static func cache(dir: URL) throws -> URL {
        let s1 = save(messages: [
            (general, [
                msg(ts(0), general, user: ann, text: "<@\(ann)> has joined the channel", extra: [("subtype", .s("channel_join"))]),
                msg(ts(10), general, user: ann, text: "first draft"),
                msg(ts(20), general, user: me, text: "see <https://example.com/a|the cut> &amp; <#\(general)|general>, <@\(ann)>"),
                msg(ts(30), general, user: bo, text: "", extra: [("files", .a([.s("FIMG00001")])), ("upload", .b(true))]),
                msg(ts(40), general, user: ann, text: "in a thread", extra: [("thread_ts", .s(ts(20))), ("_hidden_reply", .b(true))]),
            ]),
            (dmAnn, [
                msg(ts(100), dmAnn, user: ann, text: "hi Owner"),
                msg(ts(110), dmAnn, user: me, text: "hey Ann", extra: [("files", .a([.s("FEXT00001"), .s("FDEL00001")]))]),
                msg(ts(120), dmAnn, text: "Only visible to you", extra: [("subtype", .s("bot_message")), ("bot_id", .s(bot)), ("is_ephemeral", .b(true))]),
                msg(ts(130), dmAnn, text: "", extra: [("_hidden_stub", .b(true)), ("no_display", .b(true)), ("is_ephemeral", .b(true))]),
            ]),
        ])
        let s2 = save(messages: [
            (general, [
                msg(ts(10), general, user: ann, text: "final words", extra: [("edited", .o([("user", .s(ann)), ("ts", .s(ts(15)))]))]),
                msg(ts(20), general, user: me, text: "see <https://example.com/a|the cut> &amp; <#\(general)|general>, <@\(ann)>"),
            ]),
            (group, [
                msg(ts(200), group, user: cy, text: "日本 group hello 😀"),
                msg(ts(210), group, text: "Ann shared a file", extra: [("subtype", .s("bot_message")), ("bot_id", .s(bot)), ("username", .s("Drive Bot"))]),
                msg(ts(220), group, user: "UGONE0001", text: "from someone the save has no member record for"),
            ]),
        ], reactions: [
            ("message-\(ts(20))-\(general)", .a([.o([("name", .s("+1::skin-tone-3")), ("users", .a([.s(ann), .s(me)])), ("count", .i(2))]),
                                               .o([("name", .s("partyparrot")), ("users", .a([.s(bo)])), ("count", .i(1))])])),
        ], wrap: true)
        return try write([s1, s2], to: dir, extraFiles: [(4, Data(blob(s1).prefix(40)))])
    }
}

@Suite struct SlackImportTests {
    // MARK: the V8 reader

    /// Bytes from Node 22's own `v8.serialize` (V8 wire version 15) with the Blink envelope: every tag the reader claims to read.
    static let nodeFixtureFull = "ff14ff0f6f490e2205736576656e220561736369692205706c61696e22056c6174696e2204636166e9220374776f630ae5652c6720003dd800de2203696e74495322036269674e000000000000f041220364626c4e000000000000f83f220174542201664622016e302201755f220361727241034902220374776f6f2205746872656549067b0124000322067370617273656107490a2204666976654001072205686f6c6579610349004902490449064002032204726566316f22016b22067368617265647b012204726566325e0522036d61703b22016149023a022203736574272201782c0122046461746544000047ed9467774222066e65737465646f2211313630383335323937382e3033323830306f220274732211313630383335323937382e30333238303022047465787422086869203c4055313e7b027b012202626e5a10d20a1feb8ca954ab7b15"
    @Test func readsNodesOwnSerialization() throws {
        // Generated by Node 22: `ff 14` + v8.serialize({ascii:"plain", latin:"café", two:"日本 😀", int:-42, big:2**32, dbl:1.5, t:true, f:false,
        // n:null, u:undefined, arr:[1,"two",{three:3}], sparse (length 7, [5]="five"), holey:[1,,3], ref1/ref2: one shared object {k:"shared"},
        // map:new Map([["a",1]]), set:new Set(["x"]), date:new Date(1608352978032), nested:{"1608352978.032800":{ts, text:"hi <@U1>"}},
        // 7:"seven", bn:12345678901234567890n}).
        let hex = Self.nodeFixtureFull
        var bytes = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let v = try V8Deserializer.readIndexedDBValue(bytes)
        #expect(v["ascii"]?.string == "plain" && v["latin"]?.string == "café" && v["two"]?.string == "日本 😀")
        #expect(v["int"]?.number == -42 && v["big"]?.number == 4_294_967_296 && v["dbl"]?.number == 1.5)
        #expect(v["t"]?.bool == true && v["f"]?.bool == false && v["n"] == .null && v["u"] == .undefined)
        #expect(v["arr"]?.array?.count == 3 && v["arr"]?.array?[2]["three"]?.number == 3)
        #expect(v["sparse"]?.array?.count == 7 && v["sparse"]?.array?[5].string == "five" && v["sparse"]?.array?[0] == .undefined)
        #expect(v["holey"]?.array == [.number(1), .undefined, .number(3)])
        #expect(v["ref1"] == v["ref2"] && v["ref2"]?["k"]?.string == "shared")
        #expect(v["map"] == .map([.string("a"): .number(1)]) && v["set"] == .set([.string("x")]) && v["date"] == .date(1_608_352_978_032))
        #expect(v["nested"]?["1608352978.032800"]?["text"]?.string == "hi <@U1>")
        #expect(v["7"]?.string == "seven" && v["bn"]?.string == "12345678901234567890")
    }

    @Test func refusesWhatItDoesNotKnowAndTruncatedSaves() throws {
        #expect(throws: (any Error).self) { try V8Deserializer.readIndexedDBValue(Data([0xff, 0x14, 0xff, 0x0d, 0x5c, 0x01])) }   // host object
        let full = SlackFixtures.blob(SlackFixtures.save(messages: []))
        #expect(throws: (any Error).self) { try V8Deserializer.readIndexedDBValue(full.prefix(full.count - 3)) }
        #expect(throws: (any Error).self) { try V8Deserializer.readIndexedDBValue(Data([0x00, 0x14])) }
        #expect(try V8Deserializer.readIndexedDBValue(full)["bootData"]?["user_id"]?.string == SlackFixtures.me)
    }

    // MARK: edge casescorrupt input throws, never traps

    static func hex(_ h: String) -> Data {
        var d = Data(); var i = h.startIndex
        while i < h.endIndex { let j = h.index(i, offsetBy: 2); d.append(UInt8(h[i..<j], radix: 16)!); i = j }
        return d
    }

    /// A corrupt string length (beyond Int, or offset + length overflowing) is an error, not a trap.
    @Test func corruptLengthsThrow() {
        #expect(throws: (any Error).self) { try V8Deserializer.readV8(Self.hex("ff0d22ffffffffffffffffff01")) }
        #expect(throws: (any Error).self) { try V8Deserializer.readV8(Self.hex("ff0d22ffffffffffffffff7f")) }
        #expect(throws: (any Error).self) { try V8Deserializer.readIndexedDBValue(Self.hex("ff14ff0d22ffffffffffffffffff01")) }
        #expect(throws: (any Error).self) { try V8Deserializer.readV8(Self.hex("ff0d41ffffffffffffffffff01")) }
    }

    /// Nesting deeper than the bound is an error, not a stack overflow.
    @Test func deepNestingThrows() {
        let n = 20_000
        let h = "ff0d" + String(repeating: "4101", count: n) + "30" + String(repeating: "240001", count: n)
        #expect(throws: (any Error).self) { try V8Deserializer.readV8(Self.hex(h)) }
        let ok = "ff0d" + String(repeating: "4101", count: 60) + "30" + String(repeating: "240001", count: 60)
        #expect((try? V8Deserializer.readV8(Self.hex(ok))) != nil)
    }

    /// A view of an ArrayBuffer met earlier (a back-reference followed by a view tag), as Node writes it.
    @Test func viewOfAnEarlierBuffer() throws {
        // v8.Serializer: {buffer: b, view: new Uint8Array(b), after: "ok"} with b = ArrayBuffer [1,2,3,4] (Node 22).
        let v = try V8Deserializer.readV8(Self.hex("ff0f6f22066275666665724204010203042204766965775e0156420004002205616674657222026f6b7b03"))
        #expect(v["buffer"] == .bytes(Data([1, 2, 3, 4])) && v["view"] == .bytes(Data([1, 2, 3, 4])) && v["after"]?.string == "ok")
    }

    /// A numeric ts out of range is a bad ts (left out and ledgered), not a trap.
    @Test func outOfRangeTsIsBad() throws {
        #expect(SlackCacheImporter.tsMs("9223372036854775807.000000") == nil)
        #expect(SlackCacheImporter.tsMs("92233720368547758.000000") == nil)
        let t = try TestArchive(); defer { t.cleanup() }
        let s = SlackFixtures.save(messages: [(SlackFixtures.general, [
            SlackFixtures.msg("9223372036854775807.000000", SlackFixtures.general, user: SlackFixtures.ann, text: "bad clock"),
            SlackFixtures.msg(SlackFixtures.ts(1), SlackFixtures.general, user: SlackFixtures.ann, text: "good clock"),
        ])])
        let idb = try SlackFixtures.write([s], to: t.dir)
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let r = try SlackCacheImporter.importCache(at: idb, into: t.db, ledger: ledger)
        #expect(r.stats.inserted == 1)
        #expect(try String(contentsOf: ledger, encoding: .utf8).contains("\tleft-out-bad-ts\t"))
    }

    // MARK: the importer

    static func ids(_ db: Database, _ sql: String) throws -> [Int64] {
        let st = try db.prepare(sql); var out: [Int64] = []
        while try st.step() { out.append(st.int(0)) }
        return out
    }

    @Test func importsEachMessageOnceFromItsNewestSave() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let idb = try SlackFixtures.cache(dir: t.dir)
        let ledger = t.dir.appendingPathComponent("slack.tsv")
        let r = try SlackCacheImporter.importCache(at: idb, into: t.db, origin: "host:/x/IndexedDB", ledger: ledger)
        let s = r.stats
        #expect(s.saves == 2 && s.unreadableSaves == 1 && s.distinct == 12 && s.versions == 14)
        #expect(s.inserted == 10 && s.leftOutEphemeral == 2 && s.edited == 1 && s.editedTextDiffers == 1 && s.threadReplies == 1 && s.bot == 1 && s.system == 1)
        let sk = { (cid: String, dt: Int) in "slack:\(SlackFixtures.team):\(cid):\(SlackFixtures.ts(dt))" }
        // One row per message; the edited one carries the newest text.
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = '\(sk(SlackFixtures.general, 20))'") == 1)
        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = '\(sk(SlackFixtures.general, 10))'") == "final words")
        // Time from the ts, exactly (no floating point): .000100 -> +0 ms.
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE source_key = '\(sk(SlackFixtures.general, 10))'") == Int64(SlackFixtures.t0 + 10) * 1000)
        // Markup made readable; from me = the save's own signed-in user.
        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = '\(sk(SlackFixtures.general, 20))'") == "see the cut (https://example.com/a) & #general, @Ann Example")
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE source_key = '\(sk(SlackFixtures.general, 20))' AND sender_handle_id IS NULL") == 1)
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.source_key = '\(sk(SlackFixtures.dmAnn, 100))'") == "slack:\(SlackFixtures.team):\(SlackFixtures.ann)")
        // System lines say what they are; files are noted, never attached.
        #expect(try t.db.scalarString("SELECT kind || '|' || note FROM message WHERE source_key = '\(sk(SlackFixtures.general, 0))'") == "system|Slack: Ann Example joined #general")
        #expect(try t.db.scalarString("SELECT kind || '|' || note FROM message WHERE source_key = '\(sk(SlackFixtures.general, 30))'") == "system|(PNG “frame.png” not attached (the Slack cache keeps no copy))")
        #expect(try t.db.scalarString("SELECT body || '|' || note FROM message WHERE source_key = '\(sk(SlackFixtures.dmAnn, 110))'")
                == "hey Ann|a link to MP3 “cut.mp3” on dropbox: https://www.dropbox.com/s/x/cut.mp3; a file since deleted from Slack")
        #expect(try t.db.scalarString("SELECT kind || '|' || note FROM message WHERE source_key = '\(sk(SlackFixtures.group, 210))'") == "system|Slack app message from Drive Bot: Ann shared a file")
        #expect(try t.db.scalarString("SELECT note FROM message WHERE source_key = '\(sk(SlackFixtures.general, 40))'")?.hasPrefix("a reply in the thread of the message of 2020-12-19T04:43:18Z") == true)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 0)
        // Ephemeral notices are left out.
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key IN ('\(sk(SlackFixtures.dmAnn, 120))', '\(sk(SlackFixtures.dmAnn, 130))')") == 0)
        // Reactions with who reacted, from the newest save; a skin tone kept, a custom emoji as :name:.
        let rx = try t.db.scalarString("""
            SELECT group_concat(x, ',') FROM (SELECT r.emoji || '/' || r.by_me || '/' || coalesce(h.normalized, '-') AS x FROM reaction r JOIN message m ON m.id = r.message_id
            LEFT JOIN handle h ON h.id = r.actor_handle_id WHERE m.source_key = '\(sk(SlackFixtures.general, 20))' ORDER BY 1)
            """)
        #expect(rx == ":partyparrot:/0/slack:\(SlackFixtures.team):\(SlackFixtures.bo),👍🏼/0/slack:\(SlackFixtures.team):\(SlackFixtures.ann),👍🏼/1/-")
        // Threads: one per conversation, keyed by workspace and conversation id, titled.
        let titles = try t.db.scalarString("SELECT group_concat(x, ' | ') FROM (SELECT key || '=' || service || '/' || origin || '/' || is_group || '/' || title AS x FROM thread WHERE service = 'slack' ORDER BY key)")
        #expect(titles == "slack:\(SlackFixtures.team):\(SlackFixtures.general)=slack/channel/1/#general · Test Works Slack | slack:\(SlackFixtures.team):\(SlackFixtures.dmAnn)=slack/dm/0/Ann Example · Test Works Slack | slack:\(SlackFixtures.team):\(SlackFixtures.group)=slack/group/1/Bo Sample, Cy Person · Test Works Slack")
        // Every incoming sender is a member of its thread; a group DM's members are its listed members and whoever wrote.
        #expect(try t.db.scalarInt("""
            SELECT count(*) FROM message m WHERE m.service = 'slack' AND m.is_from_me = 0
            AND NOT EXISTS (SELECT 1 FROM thread_member tm WHERE tm.thread_id = m.thread_id AND tm.handle_id = m.sender_handle_id)
            """) == 0)
        #expect(try t.db.scalarString("SELECT raw FROM handle WHERE normalized = 'slack:\(SlackFixtures.team):UGONE0001'") == "Slack user UGONE0001")
        #expect(try t.db.scalarString("SELECT name FROM contact_name cn JOIN handle h ON h.id = cn.handle_id WHERE h.normalized = 'slack:\(SlackFixtures.team):\(SlackFixtures.cy)'") == "Cy Person")
        // The ledger: one line per distinct message and one per unreadable save.
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(lines.count == 13)
        #expect(Dictionary(grouping: lines, by: { $0[9] }).mapValues(\.count) == ["new": 10, "left-out-ephemeral": 2, "left-out-unreadable-save": 1])
        #expect(Set(lines.filter { $0[9] == "new" }.compactMap { Int64($0[10]) }) == Set(try Self.ids(t.db, "SELECT id FROM message WHERE service = 'slack'")))
        #expect(lines.first { $0[4] == SlackFixtures.ts(10) }?[13] == "edited-text-differs")
        #expect(lines.first { $0[4] == SlackFixtures.ts(40) }?[14] == SlackFixtures.ts(20))
        // A second run adds nothing.
        let before = try t.db.scalarInt("SELECT count(*) FROM message")
        #expect(try SlackCacheImporter.importCache(at: idb, into: t.db).status == .alreadyImported)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == before)
    }

    /// Another snapshot of the same cache (one more save) imports only messages it has not seen: the ts is the key.
    @Test func aSecondSnapshotAddsOnlyNewMessages() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let idb = try SlackFixtures.cache(dir: t.dir.appendingPathComponent("a"))
        _ = try SlackCacheImporter.importCache(at: idb, into: t.db)
        let n = try t.db.scalarInt("SELECT count(*) FROM message")
        let s3 = SlackFixtures.save(messages: [(SlackFixtures.general, [
            SlackFixtures.msg(SlackFixtures.ts(10), SlackFixtures.general, user: SlackFixtures.ann, text: "final words, edited again"),
            SlackFixtures.msg(SlackFixtures.ts(500), SlackFixtures.general, user: SlackFixtures.bo, text: "a later message"),
        ])])
        try SlackFixtures.blob(s3).write(to: idb.appendingPathComponent("https_app.slack.com_0.indexeddb.blob/1/00/10"))
        let r = try SlackCacheImporter.importCache(at: idb, into: t.db)
        #expect(r.status == .imported && r.stats.inserted == 1 && r.stats.heldKnown == 10)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == n + 1)
        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = 'slack:\(SlackFixtures.team):\(SlackFixtures.general):\(SlackFixtures.ts(10))'") == "final words")
    }

    /// "From me" is proven from the save, not a name: the signed-in user must be the member marked is_self.
    @Test func meMustBeTheSignedInSelfMember() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let bad = SlackFixtures.save(messages: [], selfID: SlackFixtures.ann)
        let idb = try SlackFixtures.write([bad], to: t.dir)
        #expect(throws: (any Error).self) { try SlackCacheImporter.importCache(at: idb, into: t.db) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'slack-cache'") == 0)
    }

    // MARK: saves that list several workspaces (2022 on)

    static let other = "TOTHER001", outside = "TOUT00001", meOther = "UME000002", pat = "UPAT00001"
    static func selfTeam(_ id: String) -> (String, SlackFixtures.J) { ("selfTeamIds", .o([("teamId", .s(id))])) }
    static func memberOf(_ id: String, _ name: String, team: String, isSelf: Bool = false) -> (String, SlackFixtures.J) {
        (id, .o([("id", .s(id)), ("team_id", .s(team)), ("real_name", .s(name)), ("name", .s(name.lowercased())), ("is_self", .b(isSelf))]))
    }

    /// A save's own workspace is `selfTeamIds.teamId`, whatever else its teams table lists (the client's other workspaces, the
    /// teams of Slack Connect people); its messages are keyed under that workspace and "from me" is that save's signed-in user.
    @Test func aSaveListingSeveralWorkspacesBelongsToItsOwn() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        // Workspace 1, also listing workspace 2 and an outside team whose person wrote in a shared DM.
        let s1 = F.save(messages: [(F.dmAnn, [F.msg(F.ts(1), F.dmAnn, user: Self.pat, text: "from outside"), F.msg(F.ts(2), F.dmAnn, user: F.me, text: "from me")])],
                        members: [Self.memberOf(F.me, "Owner Test", team: F.team, isSelf: true), Self.memberOf(Self.pat, "Pat Outside", team: Self.outside)],
                        teams: [(Self.other, "Other Co"), (F.team, "Test Works"), (Self.outside, "Outside Inc")], top: [Self.selfTeam(F.team)])
        // Workspace 2 in the same store, signed in as another user id, in the 2024 envelope.
        let s2 = F.save(messages: [(F.general, [F.msg(F.ts(3), F.general, user: Self.meOther, text: "mine in the other"), F.msg(F.ts(4), F.general, user: F.ann, text: "theirs")])],
                        members: [Self.memberOf(Self.meOther, "Owner Test", team: Self.other, isSelf: true), Self.memberOf(F.ann, "Ann Example", team: Self.other)],
                        selfID: Self.meOther, teams: [(F.team, "Test Works"), (Self.other, "Other Co")], top: [Self.selfTeam(Self.other)])
        let idb = try F.write([s1], to: t.dir, extraFiles: [(9, Data(F.blob2024(s2)))])
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let r = try SlackCacheImporter.importCache(at: idb, into: t.db, ledger: ledger)
        #expect(r.stats.saves == 2 && r.stats.unreadableSaves == 0 && r.stats.savesOtherWorkspace == 0 && r.stats.inserted == 4)
        let rows = try t.db.scalarString("SELECT group_concat(x, ' | ') FROM (SELECT source_key || '=' || is_from_me AS x FROM message WHERE service = 'slack' ORDER BY source_key)")
        #expect(rows == "slack:\(Self.other):\(F.general):\(F.ts(3))=1 | slack:\(Self.other):\(F.general):\(F.ts(4))=0 | slack:\(F.team):\(F.dmAnn):\(F.ts(1))=0 | slack:\(F.team):\(F.dmAnn):\(F.ts(2))=1")
        let titles = try t.db.scalarString("SELECT group_concat(x, ' | ') FROM (SELECT key || '=' || title AS x FROM thread WHERE service = 'slack' ORDER BY key)")
        #expect(titles == "slack:\(Self.other):\(F.general)=#general · Other Co Slack | slack:\(F.team):\(F.dmAnn)=Slack DM \(F.dmAnn) · Test Works Slack")
        // The outside person is a handle of the workspace the conversation is in.
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'from outside'") == "slack:\(F.team):\(Self.pat)")
    }

    /// `workspaces` names what to import: the saves of any other workspace are ledgered and add nothing, and the choice is part of
    /// the source's identity (the same folder with another choice is another import, held by key where it overlaps).
    @Test func onlyTheNamedWorkspacesAreImported() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        let s1 = F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.ann, text: "kept")])], top: [Self.selfTeam(F.team)])
        let s2 = F.save(messages: [(F.general, [F.msg(F.ts(2), F.general, user: F.ann, text: "a community's chatter")])],
                        members: [Self.memberOf(Self.meOther, "Owner", team: Self.other, isSelf: true)], selfID: Self.meOther,
                        teams: [(Self.other, "Other Co"), (F.team, "Test Works")], top: [Self.selfTeam(Self.other)])
        let idb = try F.write([s1, s2], to: t.dir)
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let r = try SlackCacheImporter.importCache(at: idb, into: t.db, workspaces: [F.team], ledger: ledger)
        #expect(r.stats.saves == 1 && r.stats.savesOtherWorkspace == 1 && r.stats.unreadableSaves == 0 && r.stats.inserted == 1 && r.stats.distinct == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key LIKE 'slack:\(Self.other):%'") == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread WHERE key LIKE 'slack:\(Self.other):%'") == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM handle WHERE normalized LIKE 'slack:\(Self.other):%'") == 0)
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(lines.map { $0[9] }.sorted() == ["left-out-workspace-not-chosen", "new"])
        #expect(lines.first { $0[9] == "left-out-workspace-not-chosen" }?[1] == Self.other)
        // The same choice again: already imported. Every workspace afterwards: the first one's message is held, the other's is new.
        #expect(try SlackCacheImporter.importCache(at: idb, into: t.db, workspaces: [F.team]).status == .alreadyImported)
        let all = try SlackCacheImporter.importCache(at: idb, into: t.db)
        #expect(all.status == .imported && all.stats.inserted == 1 && all.stats.heldKnown == 1 && all.stats.savesOtherWorkspace == 0)
    }

    /// A save that lists several workspaces and does not say which is its own is not guessed at; one whose signed-in member
    /// belongs to another workspace than the save's stops the import.
    @Test func aSaveWhoseWorkspaceIsNotProvenIsNotImported() throws {
        let F = SlackFixtures.self
        let t = try TestArchive(); defer { t.cleanup() }
        let unclear = F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.ann, text: "whose?")])], teams: [(F.team, "Test Works"), (Self.other, "Other Co")])
        let missing = F.save(messages: [(F.general, [F.msg(F.ts(2), F.general, user: F.ann, text: "whose?")])], top: [Self.selfTeam("TNOWHERE1")])
        let good = F.save(messages: [(F.general, [F.msg(F.ts(3), F.general, user: F.ann, text: "fine")])])
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let r = try SlackCacheImporter.importCache(at: try F.write([unclear, missing, good], to: t.dir), into: t.db, ledger: ledger)
        #expect(r.stats.saves == 1 && r.stats.unreadableSaves == 2 && r.stats.inserted == 1)
        let text = try String(contentsOf: ledger, encoding: .utf8)
        #expect(text.contains("a save with 2 workspaces and no selfTeamIds.teamId") && text.contains("own workspace TNOWHERE1 is not in its teams table"))

        let t2 = try TestArchive(); defer { t2.cleanup() }
        let wrongHome = F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.ann, text: "x")])],
                               members: [Self.memberOf(F.me, "Owner Test", team: Self.other, isSelf: true)],
                               teams: [(F.team, "Test Works"), (Self.other, "Other Co")], top: [Self.selfTeam(F.team)])
        #expect(throws: (any Error).self) { try SlackCacheImporter.importCache(at: try F.write([wrongHome], to: t2.dir), into: t2.db) }
        #expect(try t2.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'slack-cache'") == 0)
    }

    // MARK: edge cases

    /// A selfTeamIds that is there but names no workspace is not treated as absent, even with one team listed; and a
    /// signed-in member whose team_id is not an id stops the import like one of another workspace.
    @Test func aMalformedSelfTeamIdsIsNotAbsent() throws {
        let F = SlackFixtures.self
        let msgs: [(String, [(String, SlackFixtures.J)])] = [(F.general, [F.msg(F.ts(1), F.general, user: F.ann, text: "x")])]
        for (i, bad) in [SlackFixtures.J.i(42), .o([("teamId", .i(42))]), .o([("teamId", .s(""))]), .o([]), .s("TTEAM0001")].enumerated() {
            let t = try TestArchive(); defer { t.cleanup() }
            let ledger = t.dir.appendingPathComponent("l.tsv")
            let good = F.save(messages: [(F.general, [F.msg(F.ts(2), F.general, user: F.ann, text: "fine")])])
            let r = try SlackCacheImporter.importCache(at: try F.write([F.save(messages: msgs, top: [("selfTeamIds", bad)]), good], to: t.dir), into: t.db, ledger: ledger)
            #expect(r.stats.saves == 1 && r.stats.unreadableSaves == 1 && r.stats.inserted == 1, "case \(i)")
            #expect(try String(contentsOf: ledger, encoding: .utf8).contains("a save whose selfTeamIds names no workspace"), "case \(i)")
        }
        // A null selfTeamIds is absent: the one team listed is the save's.
        let t = try TestArchive(); defer { t.cleanup() }
        #expect(try SlackCacheImporter.importCache(at: try F.write([F.save(messages: msgs, top: [("selfTeamIds", .null)])], to: t.dir), into: t.db).stats.inserted == 1)
        // The signed-in member's team_id must be the save's workspace when it is there at all.
        for badHome in [SlackFixtures.J.i(7), .s("")] {
            let t2 = try TestArchive(); defer { t2.cleanup() }
            let me: (String, SlackFixtures.J) = (F.me, .o([("id", .s(F.me)), ("team_id", badHome), ("real_name", .s("Owner Test")), ("is_self", .b(true))]))
            #expect(throws: (any Error).self) { try SlackCacheImporter.importCache(at: try F.write([F.save(messages: msgs, members: [me])], to: t2.dir), into: t2.db) }
            #expect(try t2.db.scalarInt("SELECT count(*) FROM message") == 0)
        }
    }

    /// A save of a workspace that was not named cannot stop the import of the named one, whatever is wrong inside it.
    @Test func aBrokenSaveOfAnotherWorkspaceDoesNotStopTheChosenOne() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        let mine = F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.ann, text: "kept")])], top: [Self.selfTeam(F.team)])
        // The other workspace's save: its signed-in member belongs elsewhere and is not the bootData user.
        let broken = F.save(messages: [(F.general, [F.msg(F.ts(2), F.general, user: F.ann, text: "not wanted")])],
                            members: [Self.memberOf(F.ann, "Ann Example", team: Self.outside, isSelf: true)], selfID: Self.meOther,
                            teams: [(Self.other, "Other Co")], top: [Self.selfTeam(Self.other)])
        let idb = try F.write([mine, broken], to: t.dir)
        let ledger = t.dir.appendingPathComponent("l.tsv")
        let r = try SlackCacheImporter.importCache(at: idb, into: t.db, workspaces: [F.team], ledger: ledger)
        #expect(r.stats.inserted == 1 && r.stats.savesOtherWorkspace == 1 && r.stats.unreadableSaves == 0)
        #expect(try String(contentsOf: ledger, encoding: .utf8).contains("\tleft-out-workspace-not-chosen\t"))
        // Without the choice the same folder stops, and writes nothing more.
        let n = try t.db.scalarInt("SELECT count(*) FROM message")
        #expect(throws: (any Error).self) { try SlackCacheImporter.importCache(at: idb, into: t.db) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == n)
    }

    /// A workspace is named by a team id; a name with a comma (which would read as two ids in the source's identity),
    /// a blank or a lowercase id is refused before anything is read or written.
    @Test func workspaceNamesMustBeTeamIDs() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        let idb = try F.write([F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.ann, text: "x")])])], to: t.dir)
        for bad in ["TA,TB", "", "T", "tteam0001", "T TEAM", "UTEAM0001", "TÉAM"] {
            #expect(throws: (any Error).self, "\(bad)") { try SlackCacheImporter.importCache(at: idb, into: t.db, workspaces: [bad]) }
        }
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'slack-cache'") == 0)
        #expect(SlackCacheImporter.isTeamID("T0EXAMPLE1") && SlackCacheImporter.isTeamID("T9SAMPLE2") && !SlackCacheImporter.isTeamID("T-1"))
    }

    /// Two workspaces with the same conversation id and ts stay two messages, each in its own workspace's
    /// thread with its own direction; and stats stored before `savesOtherWorkspace` existed still decode.
    @Test func theSameConversationAndTsInTwoWorkspacesAreTwoMessages() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        let s1 = F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.me, text: "in the first")])], top: [Self.selfTeam(F.team)])
        let s2 = F.save(messages: [(F.general, [F.msg(F.ts(1), F.general, user: F.me, text: "in the second")])],
                        members: [Self.memberOf(Self.meOther, "Owner Test", team: Self.other, isSelf: true), Self.memberOf(F.me, "Someone Else", team: Self.other)],
                        selfID: Self.meOther, teams: [(F.team, "Test Works"), (Self.other, "Other Co")], top: [Self.selfTeam(Self.other)])
        let r = try SlackCacheImporter.importCache(at: try F.write([s1, s2], to: t.dir), into: t.db)
        #expect(r.stats.inserted == 2 && r.stats.distinct == 2 && r.stats.threads == 2)
        let rows = try t.db.scalarString("""
            SELECT group_concat(x, ' | ') FROM (SELECT m.source_key || '=' || th.key || '/' || m.is_from_me || '/' || m.body AS x
            FROM message m JOIN thread th ON th.id = m.thread_id WHERE m.service = 'slack' ORDER BY m.source_key)
            """)
        #expect(rows == "slack:\(Self.other):\(F.general):\(F.ts(1))=slack:\(Self.other):\(F.general)/0/in the second | slack:\(F.team):\(F.general):\(F.ts(1))=slack:\(F.team):\(F.general)/1/in the first")
        let old = #"{"saves":105,"unreadableSaves":10,"versions":28205,"distinct":7811,"inserted":7807,"text":7510,"system":31,"bot":104,"filesNoted":389,"threadReplies":11,"edited":154,"editedTextDiffers":1,"reactions":787,"leftOutEphemeral":4,"leftOutDeleted":0,"leftOutEmpty":0,"leftOutBadTs":0,"heldKnown":0,"threads":88,"people":187}"#
        let st = try JSONDecoder().decode(SlackImportStats.self, from: Data(old.utf8))
        #expect(st.inserted == 7807 && st.saves == 105 && st.savesOtherWorkspace == nil)
    }

    /// A later snapshot whose saves change messages the archive holds (an edit, a reaction, a new name for
    /// the person) leaves every row that was there as it was, in every table; only new rows are added.
    @Test func anOverlappingSnapshotLeavesEveryOldRowAsItWas() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        _ = try SlackCacheImporter.importCache(at: try F.cache(dir: t.dir.appendingPathComponent("a")), into: t.db)
        func dump(_ table: String, _ order: String) throws -> [String] {
            let info = try t.db.prepare("PRAGMA table_info(\(table))"); var cols: [String] = []
            while try info.step() { cols.append(info.string(1)!) }
            let st = try t.db.prepare("SELECT \(cols.map { "quote(\($0))" }.joined(separator: " || '|' || ")) FROM \(table) ORDER BY \(order)"); var out: [String] = []
            while try st.step() { out.append(st.string(0) ?? "") }
            return out
        }
        let tables = [("message", "id"), ("thread", "id"), ("thread_member", "thread_id, handle_id"), ("handle", "id"), ("contact_name", "handle_id, origin, name"),
                      ("reaction", "rowid"), ("attachment", "rowid"), ("source", "id")]
        var before: [String: [String]] = [:]
        for (tb, o) in tables { before[tb] = try dump(tb, o) }
        #expect(before["message"]!.count == 10 && before["reaction"]!.count == 3)
        // The later snapshot: the edited message edited again, a reaction on an old message, Ann renamed, and one new message.
        let later = F.save(messages: [(F.general, [
            F.msg(F.ts(10), F.general, user: F.ann, text: "final words, changed later"),
            F.msg(F.ts(20), F.general, user: F.me, text: "rewritten"),
            F.msg(F.ts(900), F.general, user: F.ann, text: "new in the later snapshot"),
        ])], reactions: [("message-\(F.ts(10))-\(F.general)", .a([.o([("name", .s("heart")), ("users", .a([.s(F.bo)])), ("count", .i(1))])]))],
           members: [F.member(F.me, "Owner Test", isSelf: true), F.member(F.ann, "Ann Renamed"), F.member(F.bo, "Bo Sample"), F.member(F.cy, "Cy Person")])
        let r = try SlackCacheImporter.importCache(at: try F.write([later], to: t.dir.appendingPathComponent("b")), into: t.db)
        #expect(r.status == .imported && r.stats.inserted == 1 && r.stats.heldKnown == 2)
        for (tb, o) in tables {
            let after = Set(try dump(tb, o))
            #expect(before[tb]!.allSatisfy { after.contains($0) }, "old rows of \(tb) changed")
        }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == Int64(before["message"]!.count + 1))
        #expect(try t.db.scalarInt("SELECT count(*) FROM reaction") == Int64(before["reaction"]!.count))
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread") == Int64(before["thread"]!.count))
    }

    /// A huddle (a call) is a message with no text and a room id: a system line, not an empty message left out.
    @Test func aHuddleIsASystemLine() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let F = SlackFixtures.self
        let s = F.save(messages: [(F.dmAnn, [
            F.msg(F.ts(1), F.dmAnn, user: F.ann, text: "", extra: [("room_id", .s("R0000001")), ("no_notifications", .b(true))]),
            F.msg(F.ts(2), F.dmAnn, user: F.me, text: "", extra: [("room_id", .s("R0000002"))]),
            F.msg(F.ts(3), F.dmAnn, user: F.ann, text: ""),
        ])])
        let r = try SlackCacheImporter.importCache(at: try F.write([s], to: t.dir), into: t.db)
        #expect(r.stats.inserted == 2 && r.stats.system == 2 && r.stats.leftOutEmpty == 1 && r.stats.text == 0)
        let notes = try t.db.scalarString("SELECT group_concat(x, ' | ') FROM (SELECT kind || '/' || is_from_me || '/' || note AS x FROM message WHERE service = 'slack' ORDER BY ts_ms)")
        #expect(notes == "system/0/Slack: Ann Example started a huddle | system/1/Slack: You started a huddle")
    }

    /// A failure part-way leaves nothing: one transaction.
    @Test func aFailedRunLeavesNothing() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let idb = try SlackFixtures.cache(dir: t.dir)
        let before = try t.db.scalarInt("SELECT count(*) FROM message")
        try t.db.exec("CREATE TRIGGER stop_slack BEFORE INSERT ON message WHEN new.source_key LIKE 'slack:%:\(SlackFixtures.group):%' BEGIN SELECT RAISE(ABORT, 'stop'); END")
        #expect(throws: (any Error).self) { try SlackCacheImporter.importCache(at: idb, into: t.db) }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == before)
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'slack-cache'") == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread WHERE key LIKE 'slack:%'") == 0)
    }

    @Test func markupTimesAndEmoji() {
        let r = SlackCacheImporter.render("<!here> <mailto:a@b.co|a@b.co> <tel:555|555> <https://x.y/z> <http://ex.com|ex.com> <!subteam^S1|@editors> &lt;3",
                                          user: { _ in nil }, channel: { _ in nil })
        #expect(r == "@here a@b.co 555 https://x.y/z ex.com @editors <3")
        #expect(SlackCacheImporter.tsMs("1608352978.032800") == 1_608_352_978_032 && SlackCacheImporter.tsMs("1608352978") == 1_608_352_978_000)
        #expect(SlackCacheImporter.tsMs("x") == nil && SlackCacheImporter.tsMs("1.2.3") == nil)
        #expect(SlackCacheImporter.emojiText("+1") == "👍" && SlackCacheImporter.emojiText("heart") == "❤️" && SlackCacheImporter.emojiText("yas") == ":yas:")
        #expect(SlackCacheImporter.emojiText("raised_hands::skin-tone-2") == "🙌🏻")
    }

    @Test func slackIsAServiceOfItsOwn() {
        #expect(ServiceKey.of(messageService: "slack") == .slack && ServiceKey.slack.label == "Slack")
        #expect(ServiceHandle.slack(team: "T1", userID: "U1", name: "x").normalized == "slack:T1:U1")
    }
}
