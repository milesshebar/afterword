import Foundation

public struct TelegramImportStats: Codable, Equatable, Sendable {
    public var rows = 0                        // rows of the message table (t7) read
    public var unparsed = 0                    // rows whose value could not be read
    public var notSelected = 0                 // rows of chats not named with --chat
    public var inserted = 0                    // written rows (messages and system lines)
    public var text = 0, system = 0, mediaWithoutFile = 0, forwarded = 0
    public var heldMatches = 0, heldByList = 0, heldKnown = 0
    public var empty = 0                       // nothing to show at all
    public var threads = 0, people = 0
    public init() {}
}

public struct TelegramImportReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64
    public var stats: TelegramImportStats
}

/// Telegram for macOS (the "Telegram" App Store app, `ru.keepcoder.Telegram`) keeps each account in a Postbox store:
/// `postbox/db/db_sqlite`, unencrypted in 2020, tables `t<N>` of (key, value) blobs.
///
/// What is read: peers (`t2`: key = peer id, value = a PostboxDecoder object under "_": users with `fn`/`ln`/`un`, channels with `t` and
/// `i.t` 0 broadcast / 1 group) and messages (`t7`: key = peer id Int64, timestamp Int32, namespace Int32, id Int32, big-endian; value =
/// Postbox's intermediate message: type, stable id and version, data flags and their optional fields, flags (4 = incoming), tags, forward
/// info, author, text, attributes, embedded media, referenced media). Times are the key's Unix seconds (UTC).
///
/// Only the chats named in `chats` are imported (for example a discussion group, not a broadcast channel or
/// the login-code chat); every row of the table gets a ledger line. One thread per chat (service `telegram`, the chat's title, keyed by the
/// chat's peer id), members = the people who wrote in it; the owner is the author of the outgoing rows. Text is a message; a photo or video
/// without text is a row with a note (the file is not attached: the media cache stays staged); an "added members" action is a system line
/// with the names. Add-only (`holdMatches`), a hold list of source keys (`tg:<peer>:<namespace>:<id>`), the ledger renamed after COMMIT.
public enum TelegramPostboxImporter {
    public static let kind = "telegram-postbox"

    // MARK: PostboxDecoder

    enum Value { case int32(Int32), int64(Int64), bool(Bool), double(Double), string(String), object(Int32, [String: Value]),
                      int32s([Int32]), int64s([Int64]), objects([(Int32, [String: Value])]), bytes(Data), null, strings([String]) }

    struct Reader {
        let d: Data; var o: Int
        init(_ d: Data) { self.d = d; o = d.startIndex }
        var atEnd: Bool { o >= d.endIndex }
        mutating func need(_ n: Int) throws { guard n >= 0, o + n <= d.endIndex else { throw ArchiveError("Postbox value ends early") } }
        mutating func u8() throws -> UInt8 { try need(1); defer { o += 1 }; return d[o] }
        mutating func le<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try need(MemoryLayout<T>.size)
            var v: T = 0
            for i in 0..<MemoryLayout<T>.size { v |= T(truncatingIfNeeded: d[o + i]) << (8 * i) }
            o += MemoryLayout<T>.size
            return v
        }
        mutating func bytes(_ n: Int) throws -> Data { try need(n); defer { o += n }; return d.subdata(in: o..<(o + n)) }
        mutating func blob() throws -> Data { let n = Int(try le(Int32.self)); return try bytes(n) }
    }

    /// One PostboxEncoder object: key length (UInt8), key, value type, value; until the data ends.
    static func decodeObject(_ data: Data) throws -> [String: Value] {
        var r = Reader(data), out: [String: Value] = [:]
        while !r.atEnd {
            let kl = Int(try r.u8())
            let key = String(decoding: try r.bytes(kl), as: UTF8.self)
            out[key] = try value(&r, type: try r.u8())
        }
        return out
    }

    static func value(_ r: inout Reader, type t: UInt8) throws -> Value {
        switch t {
        case 0: return .int32(try r.le(Int32.self))
        case 1: return .int64(try r.le(Int64.self))
        case 2: return .bool(try r.u8() != 0)
        case 3: return .double(Double(bitPattern: try r.le(UInt64.self)))
        case 4: return .string(String(decoding: try r.blob(), as: UTF8.self))
        // An object's type is known from its hash even when its own fields use a type this reader skips (they are left empty).
        case 5: let h = try r.le(Int32.self); let b = try r.blob(); return .object(h, (try? decodeObject(b)) ?? [:])
        case 6: let n = Int(try r.le(Int32.self)); return .int32s(try (0..<max(0, n)).map { _ in try r.le(Int32.self) })
        case 7: let n = Int(try r.le(Int32.self)); return .int64s(try (0..<max(0, n)).map { _ in try r.le(Int64.self) })
        case 8:
            let n = Int(try r.le(Int32.self))
            return .objects(try (0..<max(0, n)).map { _ in let h = try r.le(Int32.self); return (h, try decodeObject(try r.blob())) })
        case 10: return .bytes(try r.blob())
        case 11: return .null
        case 12: let n = Int(try r.le(Int32.self)); return .strings(try (0..<max(0, n)).map { _ in String(decoding: try r.blob(), as: UTF8.self) })
        default: throw ArchiveError("Postbox value type \(t) not read")
        }
    }

    static func string(_ o: [String: Value], _ k: String) -> String? { if case .string(let s)? = o[k] { return s.isEmpty ? nil : s }; return nil }
    static func int(_ o: [String: Value], _ k: String) -> Int64? {
        switch o[k] { case .int32(let v)?: return Int64(v); case .int64(let v)?: return v; default: return nil }
    }

    // MARK: messages

    struct Message {
        var peer: Int64, ts: Int32, namespace: Int32, id: Int32
        var incoming: Bool, forwarded: Bool, author: Int64?, text: String
        var media: [(hash: Int32, fields: [String: Value])]
        var referenced: [(namespace: Int32, id: Int64)]
        var referencedMedia: Int { referenced.count }
    }

    /// Type hashes of the embedded media seen in the 2020 store (Postbox's own coding ids).
    static let mediaAction: Int32 = -1_132_984_447, mediaImage: Int32 = -1_951_522_668, mediaFile: Int32 = 665_733_176

    static func readMessage(key: Data, value: Data) throws -> Message {
        guard key.count == 20 else { throw ArchiveError("message key of \(key.count) bytes") }
        func be32(_ at: Int) -> Int32 { Int32(bitPattern: key[key.startIndex + at..<key.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }) }
        let peer = Int64(bitPattern: key[key.startIndex..<key.startIndex + 8].reduce(0) { $0 << 8 | UInt64($1) })
        var r = Reader(value)
        _ = try r.u8(); _ = try r.le(UInt32.self); _ = try r.le(UInt32.self)
        let df = try r.u8()
        if df & 1 != 0 { _ = try r.le(Int64.self) }
        if df & 2 != 0 { _ = try r.le(UInt32.self) }
        if df & 4 != 0 { _ = try r.le(Int64.self) }
        if df & 8 != 0 { _ = try r.le(UInt32.self) }
        if df & 16 != 0 { _ = try r.le(UInt32.self) }
        if df & 32 != 0 { _ = try r.le(Int64.self) }
        let flags = try r.le(UInt32.self)
        _ = try r.le(UInt32.self)
        let ff = try r.u8()                                  // forward info: the byte is its own flag set
        if ff != 0 {
            _ = try r.le(Int64.self); _ = try r.le(Int32.self)
            if ff & 2 != 0 { _ = try r.le(Int64.self) }
            if ff & 4 != 0 { _ = try r.le(Int64.self); _ = try r.le(Int32.self); _ = try r.le(Int32.self) }
            if ff & 8 != 0 { _ = try r.blob() }
            if ff & 16 != 0 { _ = try r.blob() }
            if ff & 32 != 0 { _ = try r.le(Int32.self) }
        }
        let author: Int64? = try r.u8() != 0 ? try r.le(Int64.self) : nil
        let text = String(decoding: try r.blob(), as: UTF8.self)
        let na = Int(try r.le(Int32.self))
        for _ in 0..<max(0, na) { _ = try r.blob() }
        let nm = Int(try r.le(Int32.self))
        var media: [(Int32, [String: Value])] = []
        for _ in 0..<max(0, nm) {
            let o = try decodeObject(try r.blob())
            if case .object(let h, let f)? = o["_"] { media.append((h, f)) }
        }
        let nr = Int(try r.le(Int32.self))
        var refs: [(Int32, Int64)] = []
        for _ in 0..<max(0, nr) { refs.append((try r.le(Int32.self), try r.le(Int64.self))) }
        return Message(peer: peer, ts: be32(8), namespace: be32(12), id: be32(16), incoming: flags & 4 != 0, forwarded: ff != 0,
                       author: author, text: text, media: media, referenced: refs)
    }

    /// A chat by its full Postbox peer id: `<namespace>:<id>` (2:1196887755 is a channel or supergroup) or the 64-bit value itself.
    public static func parseChat(_ s: String) -> Int64? {
        let p = s.split(separator: ":")
        if p.count == 2, let ns = Int64(p[0]), let id = Int64(p[1]), (0...0xffff_ffff).contains(id) { return ns << 32 | id }
        return Int64(s)
    }

    /// TelegramMediaActionType raw values (TelegramCore's own enum).
    static func actionLine(_ raw: Int64?, actor: String, actorIsYou: Bool, added: [Int64], author: Int64?, title: String?, name: (Int64) -> String) -> String {
        switch raw {
        case 2? where !added.isEmpty:
            return added == [author ?? -1] ? "\(actor) joined the group" : "\(actor) added " + added.map(name).joined(separator: ", ")
        case 2?: return "\(actor): a Telegram service message (members added)"
        case 3? where !added.isEmpty:
            return added == [author ?? -1] ? "\(actor) left the group" : "\(actor) removed " + added.map(name).joined(separator: ", ")
        case 1?: return "\(actor) created the group" + (title.map { " “\($0)”" } ?? "")
        case 4?: return "\(actor) changed the group photo"
        case 5? where title != nil: return "\(actor) renamed the group to “\(title!)”"
        case 6?: return "\(actor) pinned a message"
        case 7?: return "\(actor) joined the group by its invite link"
        default: return "\(actor): a Telegram service message (type \(raw.map(String.init) ?? "unknown"))"
        }
    }

    /// What a TelegramMediaFile is, from its attributes (`at`, each with discriminator `t`: 0 file name, 1 sticker, 2 image size,
    /// 3 animated, 4 video, 5 audio) and its mime type.
    static func fileKind(_ f: [String: Value]) -> String {
        var kinds = Set<Int64>(), voice = false
        if case .objects(let list)? = f["at"] {
            for (_, a) in list {
                if let t = int(a, "t") { kinds.insert(t) }
                if int(a, "t") == 5, case .bool(true)? = a["iv"] { voice = true }
            }
        }
        let mime = string(f, "mt") ?? ""
        if kinds.contains(1) { return "sticker" }
        if kinds.contains(3) { return "animation" }
        if kinds.contains(5) || mime.hasPrefix("audio/") { return voice ? "voice message" : "audio" }
        if kinds.contains(4) || mime.hasPrefix("video/") { return "video" }
        if mime.hasPrefix("image/") { return "image" }
        return "document"
    }

    // MARK: import

    public static func importStore(at url: URL, chats: Set<Int64>, into db: Database, root: ArchiveRoot, origin: String? = nil,
                                   holdKeys: Set<String> = [], ledger: URL? = nil) throws -> TelegramImportReport {
        let (sha, bytes) = try Hashing.sha256Hex(ofFile: url)
        let key = "\(sha):chats=\(chats.sorted().map(String.init).joined(separator: ","))"
            + (holdKeys.isEmpty ? "" : ":hold=\(holdKeys.count)/\(String(UInt64(bitPattern: Hashing.fnv1a(holdKeys.sorted().joined(separator: "\n"))), radix: 16))")
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(TelegramImportStats.self, from: Data($0.utf8)) } ?? TelegramImportStats()
            let id = seen.int(0); seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return TelegramImportReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()
        let store = try Database(path: url.path, readOnly: true, immutable: true)
        guard try store.tableExists("t2"), try store.tableExists("t7") else { throw ArchiveError("\(url.path) is not a Telegram Postbox store") }
        var peers: [Int64: [String: Value]] = [:]
        let p = try store.prepare("SELECT key, value FROM t2")
        while try p.step() {
            guard let v = p.blob(1), let o = try? decodeObject(v), case .object(_, let f)? = o["_"] else { continue }
            peers[p.int(0)] = f
        }
        // A referenced (forwarded) media item lives in the media table t6: key = namespace Int32 + id Int64 (big-endian), value = a byte,
        // an Int32 length and the PostboxEncoder object.
        let mediaLookup = try store.tableExists("t6") ? try store.prepare("SELECT value FROM t6 WHERE key = ?") : nil
        func referencedKind(_ ref: (namespace: Int32, id: Int64)) -> String? {
            guard let st = mediaLookup else { return nil }
            var k = Data()
            withUnsafeBytes(of: ref.namespace.bigEndian) { k.append(contentsOf: $0) }
            withUnsafeBytes(of: ref.id.bigEndian) { k.append(contentsOf: $0) }
            st.bindBlob(1, k)
            defer { st.reset() }
            // A byte, the object's length (Int32), the object; the store may keep more bytes after it.
            guard (try? st.step()) == true, let v = st.blob(0), v.count > 5 else { return nil }
            var r = Reader(v); _ = try? r.u8()
            guard let n = try? r.le(Int32.self), n > 0, let body = try? r.bytes(Int(n)),
                  let o = try? decodeObject(body), case .object(let h, let f)? = o["_"] else { return nil }
            return h == mediaImage ? "photo" : h == mediaFile ? fileKind(f) : nil
        }
        func name(_ id: Int64) -> String? {
            guard let f = peers[id] else { return nil }
            let n = [string(f, "fn"), string(f, "ln")].compactMap { $0 }.joined(separator: " ")
            return n.isEmpty ? (string(f, "t") ?? string(f, "un")) : n
        }
        var rows: [(Message?, Data)] = []
        let q = try store.prepare("SELECT key, value FROM t7")
        while try q.step() {
            guard let k = q.blob(0), let v = q.blob(1) else { continue }
            rows.append(((try? readMessage(key: k, value: v)), k))
        }
        rows.sort { a, b in (a.0?.peer ?? 0, a.0?.ts ?? 0, a.0?.id ?? 0) < (b.0?.peer ?? 0, b.0?.ts ?? 0, b.0?.id ?? 0) }

        var out = ["source_file\tchat\tnamespace\tid\tts_ms\tts_utc\tdirection\tdecision\twritten_message_id\tthread_id\tnote"]
        let iso = ISO8601DateFormatter()
        func peerLabel(_ p: Int64) -> String { "\(p >> 32):\(p & 0xffff_ffff)" }
        var stats = TelegramImportStats()
        var report: TelegramImportReport!
        let threadsBefore = try db.scalarInt("SELECT coalesce(max(id), 0) FROM thread")
        let known = try db.prepare("SELECT coalesce(canonical_id, id) FROM message WHERE source_key = ? LIMIT 1")
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origin ?? url.path).bind(3, key).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind, sourceTier: SourceTier.other)
            writer.holdMatches = true
            writer.matchRequiresSameSender = true        // distinct Telegram ids are distinct messages; a match needs the same sender
            // Per selected chat: the owner is the author of its outgoing rows; the members are everyone else who wrote.
            var me: [Int64: Int64] = [:], members: [Int64: [Int64]] = [:]
            for case let (m?, _) in rows where chats.contains(m.peer) {
                if !m.incoming, let a = m.author { me[m.peer] = a }
            }
            for case let (m?, _) in rows where me[m.peer] != nil {
                if let a = m.author, a != me[m.peer], !(members[m.peer]?.contains(a) ?? false) { members[m.peer, default: []].append(a) }
            }
            func handle(_ id: Int64) -> ServiceHandle { ServiceHandle.telegram(userID: id & 0xffff_ffff, name: name(id) ?? "Telegram user \(id & 0xffff_ffff)") }
            var threadOf: [Int64: Int64] = [:]
            for (m, k) in rows {
                stats.rows += 1
                guard let m else {
                    stats.unparsed += 1
                    let peer = Int64(bitPattern: k.prefix(8).reduce(0) { $0 << 8 | UInt64($1) })
                    out.append([origin ?? url.path, peerLabel(peer), "", "", "", "", "", "left-out-unparsed", "", "", ""].joined(separator: "\t"))
                    continue
                }
                let ts = Int64(m.ts) * 1000
                func log(_ decision: String, written: Int64? = nil, thread: Int64? = nil, note: String = "") {
                    out.append([origin ?? url.path, peerLabel(m.peer), "\(m.namespace)", "\(m.id)", "\(ts)", iso.string(from: Date(timeIntervalSince1970: Double(m.ts))),
                                m.incoming ? "in" : "out", decision, written.map(String.init) ?? "", thread.map(String.init) ?? "", note].joined(separator: "\t"))
                }
                guard let mine = me[m.peer] else {
                    stats.notSelected += 1
                    log(chats.contains(m.peer) ? "left-out-no-outgoing-row-to-name-owner" : "left-out-chat-not-selected"); continue
                }
                let sourceKey = "tg:\(m.peer):\(m.namespace):\(m.id)"
                if holdKeys.contains(sourceKey) { stats.heldByList += 1; log("left-out-hold-list"); continue }
                known.bind(1, sourceKey)
                if try known.step() { let a = known.int(0); known.reset(); stats.heldKnown += 1; log("held-source-key", note: "archive row \(a)"); continue }
                known.reset()
                let others = (members[m.peer] ?? []).map(handle)
                var rec = MessageRecord(participants: [], sender: nil, tsMs: ts, isFromMe: m.author == mine || !m.incoming, service: "telegram")
                rec.sourceKey = sourceKey
                rec.participantHandles = others.isEmpty ? [ServiceHandle.telegram(userID: m.peer & 0xffff_ffff, name: name(m.peer) ?? "Telegram chat")] : others
                if !rec.isFromMe, let a = m.author { rec.senderHandle = handle(a) }
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var line = ""
                if let action = m.media.first(where: { $0.hash == mediaAction }) {
                    var added: [Int64] = []
                    if case .bytes(let b)? = action.fields["peerIds"] {
                        var r = Reader(b)
                        if let n = try? r.le(Int32.self) { for _ in 0..<max(0, Int(n)) { if let id = try? r.le(Int64.self) { added.append(id) } } }
                    }
                    let actor = rec.isFromMe ? "You" : (m.author.flatMap(name) ?? "Someone")
                    // The action's own type decides the line; a join is written only when it adds its own author.
                    line = actionLine(int(action.fields, "_rawValue"), actor: actor, actorIsYou: rec.isFromMe, added: added, author: m.author,
                                      title: string(action.fields, "title"), name: { $0 == mine ? "you" : (name($0) ?? "someone") })
                    rec.kind = "system"; rec.note = line; stats.system += 1
                } else if let media = m.media.first {
                    // A file says what it is from its own attributes.
                    let what = media.hash == mediaImage ? "photo" : media.hash == mediaFile ? fileKind(media.fields) : "attachment"
                    line = "(\(what) not attached: its file stays in the staged Telegram cache)"
                    if text.isEmpty { rec.kind = "system" }
                    rec.note = line; stats.mediaWithoutFile += 1
                } else if text.isEmpty, let ref = m.referenced.first {
                    let what = referencedKind(ref) ?? "media"
                    line = "(forwarded \(what) not attached: its file stays in the staged Telegram cache)"
                    rec.kind = "system"; rec.note = line; stats.mediaWithoutFile += 1
                }
                if !text.isEmpty { rec.body = text; stats.text += 1 }
                if m.forwarded { stats.forwarded += 1; if rec.note == nil { rec.note = "forwarded" } }
                if rec.body == nil && rec.note == nil { stats.empty += 1; log("left-out-empty"); continue }
                // The thread is the chat, keyed by its peer id; members join as they are seen.
                writer.threadKey = "telegram:\(m.peer)"
                writer.threadKeyIsGroup = (m.peer >> 32) != 0
                switch try writer.add(rec) {
                case .inserted:
                    stats.inserted += 1
                    threadOf[m.peer] = writer.lastThreadID
                    log("new", written: writer.lastMessageID, thread: writer.lastThreadID, note: rec.kind == "system" ? "system line" : (rec.note ?? ""))
                case .duplicate:
                    stats.heldMatches += 1
                    log(writer.lastHeldOtherGuid ? "held-match-other-guid" : "held-match", thread: writer.lastThreadID, note: "archive row \(writer.lastHeldID ?? 0)")
                }
            }
            // Names, and the threads this run created: service, title, the chat's id.
            for (chat, list) in members {
                for a in list { if let n = name(a) { try writer.noteName(service: handle(a), name: n, origin: "telegram", priority: ContactPriority.androidXML) } }
                stats.people += list.count
                _ = chat
            }
            let up = try db.prepare("UPDATE thread SET service = 'telegram', origin = 'group', title = coalesce(title, ?), external_id = coalesce(external_id, ?) WHERE id = ? AND id > ?")
            for (chat, thread) in threadOf {
                up.bind(1, peers[chat].flatMap { string($0, "t") }).bind(2, "tg:\(chat)").bind(3, thread).bind(4, threadsBefore)
                try up.run()
                stats.threads += 1
            }
            let st = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try st.run()
            try ImportLedger.save(db, sourceID: sid, body: out.joined(separator: "\n") + "\n")
            report = TelegramImportReport(status: .imported, sourceID: sid, stats: stats)
        }
        // Published after COMMIT from the stored copy; if this fails, a retry (already imported) publishes it again.
        if let ledger, let body = try ImportLedger.load(db, sourceID: report.sourceID) { try ImportLedger.publish(body, to: ledger) }
        return report
    }
}
