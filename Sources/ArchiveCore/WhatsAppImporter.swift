import Foundation

/// WhatsApp for iPhone's `ChatStorage.sqlite` (from an iPhone backup: `AppDomainGroup-group.net.whatsapp.WhatsApp.shared`), a Core Data
/// store: `ZWACHATSESSION` (a chat), `ZWAMESSAGE`, `ZWAMEDIAITEM`, `ZWAGROUPMEMBER`, `ZWAPROFILEPUSHNAME`.
///
/// Mapping:
/// - people are `wa:<jid user part>` handles (a phone number for a person), named from the saved contact name (`ZPARTNERNAME`, unless it is
///   only the number WhatsApp formats), a group's member names, then the push name people chose;
/// - a 1:1 chat (`ZSESSIONTYPE` 0) is a 1:1 thread; a group (1) is a group thread keyed by members plus its JID, titled from `ZPARTNERNAME`;
///   status and broadcast chats (2, 3, 4) are not conversations and are counted, not stored;
/// - text (`ZMESSAGETYPE` 0) and links (7: the address, then the preview title) are messages; a message with a media item is a message
///   whose body is its caption, with the file attached when the backup holds it (`<attachments>/Message/<ZMEDIALOCALPATH>`), and otherwise a
///   system line naming what is missing when there is no caption; contact cards and locations become one-line bodies; revoked messages
///   (14) are `unsent` lines. Rows with no text and no media (group events, status posts, E2E notices) are counted by type, not stored,
///   so `parsed = stored + duplicates + skipped` always adds up;
/// - times are Core Data seconds since 2001-01-01 (UTC), the source key is `whatsapp:<stanza id>`: a later, larger backup of the same phone
///   adds only the messages the earlier one lacked and links the overlap as duplicates.
public struct WhatsAppImportStats: Codable, Equatable, Sendable {
    public var parsed = 0                   // rows in ZWAMESSAGE
    public var inConversations = 0          // in a 1:1 or group chat
    public var otherChatsSkipped = 0        // status / broadcast chats, or no chat
    public var text = 0, links = 0, media = 0, contacts = 0, locations = 0, unsent = 0
    public var eventsSkipped = 0            // no text and no media
    public var eventsByType: [String: Int] = [:]
    public var emptySkipped = 0
    public var inserted = 0                 // canonical rows written
    public var duplicates = 0               // linked to an earlier copy (kept)
    public var chats = 0, groups = 0, dms = 0
    public var people = 0
    public var groupsWithLongMemberLists = 0   // groups whose member list is longer than maxListedMembers: only their writers are people
    public var attachmentsStored = 0, mediaMissing = 0, mediaBytes = 0, mediaNewBytes = 0, mediaNewFiles = 0
    public var firstTsMs: Int64?, lastTsMs: Int64?
    public var meJID: String?
    public var seconds = 0.0
}

public struct WhatsAppImportReport: Sendable {
    public enum Status: Sendable { case imported, alreadyImported }
    public var status: Status
    public var stats: WhatsAppImportStats
}

public enum WhatsAppImporter {
    public static let sourceKind = "whatsapp-chatstorage"
    public static let nameOrigin = "whatsapp-chatstorage"
    static let appleEpoch: Int64 = 978_307_200
    /// A group's member list is used for its people only up to this size (see importMessages).
    static let maxListedMembers = 50

    public static func isChatStorage(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "sqlite",
              let db = try? Database(path: url.path, readOnly: true, immutable: true) else { return false }
        return ((try? db.tableExists("ZWAMESSAGE")) ?? false) && ((try? db.tableExists("ZWACHATSESSION")) ?? false)
    }

    /// `attachments`: the folder that holds `Message/Media/...` (the shared container root), or nil to store no files.
    public static func importChatStorage(at url: URL, into db: Database, root: ArchiveRoot, attachments: URL? = nil,
                                         origin: String? = nil) throws -> WhatsAppImportReport {
        let t0 = Date()
        let (hash, bytes) = try Hashing.sha256Hex(ofFile: url)
        let sel = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        sel.bind(1, hash)
        if try sel.step() {
            let st = sel.string(0).flatMap { try? JSONDecoder().decode(WhatsAppImportStats.self, from: Data($0.utf8)) } ?? WhatsAppImportStats()
            sel.reset()
            return WhatsAppImportReport(status: .alreadyImported, stats: st)
        }
        sel.reset()
        let src = try Database(path: url.path, readOnly: true, immutable: true)
        var stats = WhatsAppImportStats()
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, sourceKind).bind(2, origin ?? url.path).bind(3, hash).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            try importMessages(src: src, sourceID: sid, into: db, root: root, attachments: attachments, stats: &stats)
            stats.seconds = Date().timeIntervalSince(t0)
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return WhatsAppImportReport(status: .imported, stats: stats)
    }

    static func jidUser(_ jid: String?) -> String? {
        guard let jid, let at = jid.firstIndex(of: "@") else { return nil }
        let u = String(jid[..<at])
        return u.isEmpty || u == "0" ? nil : u
    }
    static func isGroupJID(_ jid: String?) -> Bool { jid?.hasSuffix("@g.us") == true }

    /// WhatsApp shows an unsaved number as "+1 (212) 555-0187": that is not a name.
    static func looksLikeNumber(_ s: String) -> Bool {
        let t = s.filter { !$0.isWhitespace && !"+()-.\u{200E}".contains($0) }
        return t.isEmpty || t.allSatisfy(\.isNumber)
    }

    struct Row {
        var pk: Int64, type: Int64, fromMe: Bool, ts: Int64
        var session: Int64?, fromJID: String?, toJID: String?, memberJID: String?, stanza: String
        var text: String?, mediaTitle: String?, mediaPath: String?, vcardName: String?, hasMedia: Bool
        var lat: Double?, lon: Double?
    }

    static func importMessages(src: Database, sourceID: Int64, into db: Database, root: ArchiveRoot, attachments: URL?,
                               stats: inout WhatsAppImportStats) throws {
        // Chats.
        struct Chat { var jid: String; var type: Int64; var name: String? }
        var chats: [Int64: Chat] = [:]
        let cq = try src.prepare("SELECT Z_PK, coalesce(ZSESSIONTYPE, -1), coalesce(ZCONTACTJID, ''), ZPARTNERNAME FROM ZWACHATSESSION")
        while try cq.step() { chats[cq.int(0)] = Chat(jid: cq.string(2) ?? "", type: cq.int(1), name: cq.string(3)) }
        cq.reset()

        // Messages (the media item and the group member joined in; at most one media item per message).
        let mq = try src.prepare("""
            SELECT m.Z_PK, coalesce(m.ZMESSAGETYPE, -1), coalesce(m.ZISFROMME, 0), m.ZMESSAGEDATE, m.ZCHATSESSION, m.ZFROMJID, m.ZTOJID,
                   g.ZMEMBERJID, coalesce(m.ZSTANZAID, ''), m.ZTEXT, mi.ZTITLE, mi.ZMEDIALOCALPATH, mi.ZVCARDNAME, mi.Z_PK IS NOT NULL,
                   mi.ZLATITUDE, mi.ZLONGITUDE
            FROM ZWAMESSAGE m
            LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = (SELECT min(Z_PK) FROM ZWAMEDIAITEM WHERE ZMESSAGE = m.Z_PK)
            ORDER BY m.ZMESSAGEDATE, m.Z_PK
            """)
        var rows: [Row] = []
        while try mq.step() {
            guard !mq.isNull(3) else { stats.parsed += 1; stats.emptySkipped += 1; continue }
            rows.append(Row(pk: mq.int(0), type: mq.int(1), fromMe: mq.int(2) != 0, ts: Int64(mq.double(3)) + appleEpoch, session: mq.optInt(4),
                            fromJID: mq.string(5), toJID: mq.string(6), memberJID: mq.string(7), stanza: mq.string(8) ?? "", text: mq.string(9),
                            mediaTitle: mq.string(10), mediaPath: mq.string(11), vcardName: mq.string(12), hasMedia: mq.int(13) != 0,
                            lat: mq.isNull(14) ? nil : mq.double(14), lon: mq.isNull(15) ? nil : mq.double(15)))
        }
        mq.reset()
        stats.parsed += rows.count

        // My own JID: where received 1:1 messages were addressed.
        var toCount: [String: Int] = [:]
        for r in rows where !r.fromMe { if let u = jidUser(r.toJID), !isGroupJID(r.toJID) { toCount[u, default: 0] += 1 } }
        let me = toCount.max { $0.value < $1.value }?.key
        stats.meJID = me

        // Names.
        var push: [String: String] = [:]
        let pq = try src.prepare("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME WHERE ZPUSHNAME IS NOT NULL AND ZPUSHNAME != ''")
        while try pq.step() { if let u = jidUser(pq.string(0)), let n = pq.string(1) { push[u] = n } }
        pq.reset()
        var memberName: [String: String] = [:]
        var groupMembers: [Int64: [String]] = [:]
        let gq = try src.prepare("SELECT ZCHATSESSION, ZMEMBERJID, coalesce(ZCONTACTNAME, ''), coalesce(ZFIRSTNAME, '') FROM ZWAGROUPMEMBER")
        while try gq.step() {
            guard let sess = Optional(gq.int(0)), let u = jidUser(gq.string(1)), u != me else { continue }
            if !(groupMembers[sess] ?? []).contains(u) { groupMembers[sess, default: []].append(u) }
            let n = gq.string(2) ?? ""
            if !n.isEmpty, !looksLikeNumber(n) { memberName[u] = n }
        }
        gq.reset()
        var chatName: [String: String] = [:]          // 1:1 partner name by jid user
        for c in chats.values where c.type == 0 { if let u = jidUser(c.jid), let n = c.name, !looksLikeNumber(n) { chatName[u] = n } }
        func name(_ u: String) -> String? { chatName[u] ?? memberName[u] ?? push[u] }
        func handle(_ u: String) -> ServiceHandle { ServiceHandle.whatsapp(jidUser: u, name: name(u) ?? "+" + u) }

        // A group's people: everyone who wrote in it, plus its member list when that is small. Community and crypto-pump groups list a
        // thousand members who never wrote; they would become a thousand handles and thread members each, so only their writers count.
        var senders: [Int64: [String]] = [:]
        for r in rows where !r.fromMe {
            guard let sess = r.session, chats[sess]?.type == 1,
                  let u = jidUser(r.memberJID) ?? (isGroupJID(r.fromJID) ? nil : jidUser(r.fromJID)), u != me else { continue }
            if !(senders[sess] ?? []).contains(u) { senders[sess, default: []].append(u) }
        }
        var groupPeople: [Int64: [String]] = [:]
        for (sess, c) in chats where c.type == 1 {
            let members = groupMembers[sess] ?? []
            var people = senders[sess] ?? []
            if members.count <= maxListedMembers { for m in members where !people.contains(m) { people.append(m) } }
            if people.isEmpty { people = Array(members.prefix(maxListedMembers)) }     // only I wrote here: keep my messages in a thread
            groupPeople[sess] = people.sorted()
        }
        stats.groupsWithLongMemberLists = chats.filter { $0.value.type == 1 && (groupMembers[$0.key]?.count ?? 0) > maxListedMembers }.count

        let writer = try ArchiveWriter(db: db, sourceID: sourceID, sourceKind: sourceKind)
        let store = MediaStore(root: root)
        var threadInfo: [Int64: (jid: String, isGroup: Bool, title: String?)] = [:]
        var seenChats = Set<Int64>(), seenPeople = Set<String>()
        var firstTs: Int64?, lastTs: Int64?
        var mediaCache: [String: AttachmentRecord] = [:]

        for r in rows {
            guard let sess = r.session, let chat = chats[sess], chat.type == 0 || chat.type == 1 else { stats.otherChatsSkipped += 1; continue }
            stats.inConversations += 1
            let isGroup = chat.type == 1
            var rec = MessageRecord(participants: [], sender: nil, tsMs: r.ts * 1000, isFromMe: r.fromMe, service: "whatsapp",
                                    body: nil, subject: nil, sourceKey: r.stanza.isEmpty ? nil : "whatsapp:" + r.stanza, attachments: [])
            let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let caption = (r.mediaTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // What is it?
            switch r.type {
            case 14:
                stats.unsent += 1; rec.kind = "unsent"; rec.note = "(message deleted)"
            case 4 where r.hasMedia:
                stats.contacts += 1; rec.body = "Contact: " + ((r.vcardName ?? "").isEmpty ? (caption.isEmpty ? "(card)" : caption) : r.vcardName!)
            case 5 where r.hasMedia:
                stats.locations += 1
                if let la = r.lat, let lo = r.lon, la != 0 || lo != 0 { rec.body = String(format: "Location: %.5f, %.5f", la, lo) + (text.isEmpty ? "" : "\n" + text) }
                else { rec.body = text.isEmpty ? "Location" : "Location: " + text }
            case 7:
                stats.links += 1
                rec.body = [text, caption].filter { !$0.isEmpty }.joined(separator: "\n")
            case 0:
                stats.text += 1; rec.body = text
            default:
                if r.hasMedia {
                    stats.media += 1
                    rec.body = text.isEmpty ? caption : text
                    var stored: AttachmentRecord?
                    if let p = r.mediaPath, !p.isEmpty, let root = attachments {
                        for base in [root.appendingPathComponent("Message"), root] {
                            let f = base.appendingPathComponent(p)
                            if FileManager.default.fileExists(atPath: f.path) {
                                stored = try storeFile(f, store: store, writer: writer, cache: &mediaCache, stats: &stats)
                                break
                            }
                        }
                    }
                    if let a = stored { rec.attachments.append(a); stats.attachmentsStored += 1 }
                    else {
                        stats.mediaMissing += 1
                        if (rec.body ?? "").isEmpty { rec.kind = "system"; rec.note = "(\(mediaLabel(r.type)) not in the backup)"; rec.body = nil }
                    }
                } else if !text.isEmpty {
                    stats.text += 1; rec.body = text
                } else {
                    stats.eventsSkipped += 1; stats.eventsByType[String(r.type), default: 0] += 1
                    continue
                }
            }
            if rec.kind == nil, (rec.body ?? "").isEmpty, rec.attachments.isEmpty { stats.emptySkipped += 1; continue }

            // Who: the chat's people, and who spoke.
            var others: [String] = []
            var sender: String?
            if isGroup {
                others = groupPeople[sess] ?? []
                if !r.fromMe, let u = jidUser(r.memberJID) ?? (isGroupJID(r.fromJID) ? nil : jidUser(r.fromJID)), u != me { sender = u }
            } else if let u = jidUser(chat.jid) { others = [u]; if !r.fromMe { sender = u } }
            guard !others.isEmpty else { stats.otherChatsSkipped += 1; stats.inConversations -= 1; continue }
            rec.participantHandles = others.map(handle)
            if let s = sender, rec.kind == nil || rec.kind == "unsent" || rec.kind == "system" { rec.senderHandle = handle(s) }
            writer.groupKeySuffix = isGroup ? "wa-" + chat.jid : nil
            switch try writer.add(rec) {
            case .inserted: stats.inserted += 1
            case .duplicate: stats.duplicates += 1
            }
            if writer.lastThreadID != 0 { threadInfo[writer.lastThreadID] = (chat.jid, isGroup, chat.name) }
            if seenChats.insert(sess).inserted { stats.chats += 1; if isGroup { stats.groups += 1 } else { stats.dms += 1 } }
            for o in others { seenPeople.insert(o) }
            firstTs = min(firstTs ?? rec.tsMs, rec.tsMs); lastTs = max(lastTs ?? rec.tsMs, rec.tsMs)
        }
        stats.people = seenPeople.count
        stats.firstTsMs = firstTs; stats.lastTsMs = lastTs

        for u in seenPeople.sorted() {
            if let n = name(u) { try writer.noteName(service: handle(u), name: n, origin: nameOrigin, priority: ContactPriority.androidXML) }
        }
        let sel = try db.prepare("SELECT title FROM thread WHERE id = ?")
        let up = try db.prepare("UPDATE thread SET service = 'whatsapp', origin = ?, hidden = 0, external_id = COALESCE(external_id, ?), title = ? WHERE id = ?")
        for (tid, info) in threadInfo.sorted(by: { $0.key < $1.key }) {
            sel.bind(1, tid)
            _ = try sel.step()
            let oldTitle = sel.string(0)
            sel.reset()
            let title = (oldTitle == nil && info.isGroup) ? info.title : oldTitle
            up.bind(1, info.isGroup ? "group" : "dm").bind(2, info.jid).bind(3, title).bind(4, tid)
            try up.run()
        }
    }

    static func mediaLabel(_ type: Int64) -> String {
        switch type {
        case 1: return "photo"
        case 2, 20, 23: return "video"
        case 3: return "voice message"
        case 8: return "document"
        case 11: return "GIF"
        case 15: return "sticker"
        default: return "attachment"
        }
    }

    static func storeFile(_ file: URL, store: MediaStore, writer: ArchiveWriter, cache: inout [String: AttachmentRecord],
                          stats: inout WhatsAppImportStats) throws -> AttachmentRecord? {
        if let c = cache[file.path] { stats.mediaBytes += Int(c.bytes); return c }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let ext = file.pathExtension.lowercased()
        let mime = MetaImporter.mimeByExtension[ext] ?? (ext == "opus" ? "audio/ogg" : "application/octet-stream")
        let stored = try data.withUnsafeBytes { raw in
            try store.store(raw, mime: mime, filename: file.lastPathComponent, lookup: { writer.existingMediaPath(sha256: $0) })
        }
        if stored.wasNew { stats.mediaNewFiles += 1; stats.mediaNewBytes += Int(stored.bytes) }
        stats.mediaBytes += Int(stored.bytes)
        let rec = AttachmentRecord(mime: mime, filename: file.lastPathComponent, sha256: stored.sha256, relativePath: stored.relativePath, bytes: stored.bytes)
        cache[file.path] = rec
        return rec
    }
}
