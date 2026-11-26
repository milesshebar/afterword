import Foundation

/// The 2011-12 Skype history of the old Mac: `~/Library/Application Support/Skype/<account>/main.db` (Skype 5 for Mac), an SQLite
/// file with `Messages`, `Chats`, `Contacts`, `Accounts` and `Calls`.
///
/// Mapping:
/// - people are `sk:<skype name>` handles, named from the display name written on their messages (most used), then the Contacts table;
/// - a chat (`Messages.chatname`) is a thread: 1:1 when the others in it are one person, a group otherwise (keyed by members plus the
///   chat name, so two groups with the same members stay apart); several chats with one person are one 1:1 thread;
/// - `type 61` text, `60` emote (`/me ...`), `50` contact-request text and `68` file transfers (the file itself is not in main.db: the
///   line names it) become messages. Everything else in `Messages` is an event with no text of its own: call start/end (`30`/`39`, the
///   `Calls` table is the call importer's), members joining/leaving/listed (`4`, `10`, `13`, `100`), contact added/removed (`51`, `53`).
///   Those are counted by type in the stats and not stored, so `parsed = messages + events` always adds up;
/// - the body is the plain text of `body_xml` (smileys keep their text, links keep their address, entities decoded);
/// - times are Unix seconds (UTC).
public struct SkypeImportStats: Codable, Equatable, Sendable {
    public var parsed = 0                  // rows in Messages
    public var textMessages = 0            // type 61
    public var emotes = 0                  // 60
    public var contactRequests = 0         // 50
    public var fileTransfers = 0           // 68
    public var eventsSkipped = 0           // rows that are events, by type in eventsByType
    public var eventsByType: [String: Int] = [:]
    public var inserted = 0                // canonical rows written
    public var duplicates = 0              // linked to an earlier copy (kept)
    public var noChatSkipped = 0           // messages in a chat with nobody but me and no partner on record
    public var emptySkipped = 0
    public var chats = 0, groups = 0, dms = 0
    public var people = 0
    public var smileysKept = 0, linksKept = 0
    public var firstTsMs: Int64?, lastTsMs: Int64?
    public var seconds = 0.0
}

public struct SkypeImportReport: Sendable {
    public enum Status: Sendable { case imported, alreadyImported }
    public var status: Status
    public var account: String?
    public var stats: SkypeImportStats
}

public enum SkypeImporter {
    public static let sourceKind = "skype-main-db"
    public static let nameOrigin = "skype-main-db"
    /// `Messages.type` values that carry a person's words.
    static let messageTypes: Set<Int64> = [61, 60, 50, 68]

    /// Is `url` a Skype 5 `main.db` (SQLite with Messages, Chats and Accounts, and a Skype-style `chatname` column)?
    public static func isSkypeDB(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "db",
              let db = try? Database(path: url.path, readOnly: true, immutable: true) else { return false }
        return ((try? db.tableExists("Messages")) ?? false) && ((try? db.tableExists("Accounts")) ?? false)
            && ((try? db.hasColumn("Messages", "body_xml")) ?? false) && ((try? db.hasColumn("Messages", "chatname")) ?? false)
    }

    public static func importDB(at url: URL, into db: Database, root: ArchiveRoot, origin: String? = nil) throws -> SkypeImportReport {
        let t0 = Date()
        let (hash, bytes) = try Hashing.sha256Hex(ofFile: url)
        let sel = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        sel.bind(1, hash)
        if try sel.step() {
            let st = sel.string(0).flatMap { try? JSONDecoder().decode(SkypeImportStats.self, from: Data($0.utf8)) } ?? SkypeImportStats()
            sel.reset()
            return SkypeImportReport(status: .alreadyImported, account: nil, stats: st)
        }
        sel.reset()

        let src = try Database(path: url.path, readOnly: true, immutable: true)
        guard let me = try src.scalarString("SELECT skypename FROM Accounts LIMIT 1")?.lowercased(), !me.isEmpty else {
            throw ArchiveError("Skype main.db: no account in the Accounts table")
        }
        var stats = SkypeImportStats()
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, sourceKind).bind(2, origin ?? url.path).bind(3, hash).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            try importMessages(src: src, me: me, sourceID: sid, into: db, stats: &stats)
            stats.seconds = Date().timeIntervalSince(t0)
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return SkypeImportReport(status: .imported, account: me, stats: stats)
    }

    // MARK: messages

    struct Row {
        var id: Int64, ts: Int64, type: Int64
        var chat: String, author: String, display: String, partner: String, body: String?
    }

    static func importMessages(src: Database, me: String, sourceID: Int64, into db: Database, stats: inout SkypeImportStats) throws {
        // Everything first (2k rows), so a chat's members are known before its first message is written.
        let q = try src.prepare("""
            SELECT id, coalesce(timestamp, 0), type, coalesce(chatname, ''), lower(coalesce(author, '')), coalesce(from_dispname, ''),
                   lower(coalesce(dialog_partner, '')), body_xml FROM Messages ORDER BY timestamp, id
            """)
        var rows: [Row] = []
        while try q.step() {
            rows.append(Row(id: q.int(0), ts: q.int(1), type: q.int(2), chat: q.string(3) ?? "", author: q.string(4) ?? "",
                            display: q.string(5) ?? "", partner: q.string(6) ?? "", body: q.string(7)))
        }
        q.reset()
        stats.parsed = rows.count

        // Chats: members = authors, dialog partners, the ids in the chat name and the Chats table's participants, minus me.
        var members: [String: [String]] = [:]
        func addMember(_ chat: String, _ id: String) {
            let id = id.lowercased()
            guard !id.isEmpty, id != me, id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) == nil else { return }
            if !(members[chat] ?? []).contains(id) { members[chat, default: []].append(id) }
        }
        for r in rows where messageTypes.contains(r.type) {
            addMember(r.chat, r.author); addMember(r.chat, r.partner)
            // "#a/$b;hash": a and b are the two ends of a chat that began as a 1:1; a group's second part is a hash.
            if r.chat.hasPrefix("#"), let slash = r.chat.firstIndex(of: "/") {
                addMember(r.chat, String(r.chat[r.chat.index(after: r.chat.startIndex)..<slash]))
                var tail = String(r.chat[r.chat.index(after: slash)...])
                if tail.hasPrefix("$") { tail.removeFirst() }
                addMember(r.chat, String(tail.split(separator: ";").first ?? ""))
            }
        }
        let chatsQ = try src.prepare("SELECT name, coalesce(participants, ''), coalesce(friendlyname, ''), coalesce(topic, '') FROM Chats")
        var chatTitle: [String: String] = [:]
        while try chatsQ.step() {
            guard let name = chatsQ.string(0), members[name] != nil else { continue }
            for p in (chatsQ.string(1) ?? "").split(whereSeparator: { $0 == " " || $0 == ";" }) { addMember(name, String(p)) }
            let t = (chatsQ.string(3) ?? "").isEmpty ? (chatsQ.string(2) ?? "") : (chatsQ.string(3) ?? "")
            if !t.isEmpty { chatTitle[name] = t }
        }
        chatsQ.reset()

        // Display names: most used on a message, then the Contacts table.
        var nameCount: [String: [String: Int]] = [:]
        for r in rows where !r.display.isEmpty && r.author != me { nameCount[r.author, default: [:]][r.display, default: 0] += 1 }
        var contactName: [String: String] = [:]
        let cq = try src.prepare("SELECT lower(skypename), coalesce(fullname, ''), coalesce(displayname, '') FROM Contacts")
        while try cq.step() {
            guard let sk = cq.string(0), !sk.isEmpty else { continue }
            let full = cq.string(1) ?? "", disp = cq.string(2) ?? ""
            contactName[sk] = !full.isEmpty ? full : disp
        }
        cq.reset()
        func displayName(_ id: String) -> String {
            let used = (nameCount[id] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
            if let used { return used }
            if let c = contactName[id], !c.isEmpty { return c }
            return id
        }
        func handle(_ id: String) -> ServiceHandle { ServiceHandle.skype(skypeName: id, name: displayName(id)) }

        let writer = try ArchiveWriter(db: db, sourceID: sourceID, sourceKind: sourceKind)
        var threadChats: [Int64: (chat: String, isGroup: Bool)] = [:]
        var seenChats = Set<String>(), seenPeople = Set<String>()
        var firstTs: Int64?, lastTs: Int64?
        for r in rows {
            guard messageTypes.contains(r.type) else {
                stats.eventsSkipped += 1; stats.eventsByType[String(r.type), default: 0] += 1
                continue
            }
            switch r.type {
            case 61: stats.textMessages += 1
            case 60: stats.emotes += 1
            case 50: stats.contactRequests += 1
            default: stats.fileTransfers += 1
            }
            let others = members[r.chat] ?? []
            guard !others.isEmpty else { stats.noChatSkipped += 1; continue }
            let isGroup = others.count > 1
            let (body, smileys, links) = plainText(r)
            guard let body, !body.isEmpty else { stats.emptySkipped += 1; continue }
            stats.smileysKept += smileys; stats.linksKept += links
            let isMe = r.author == me
            var rec = MessageRecord(participants: [], sender: nil, tsMs: r.ts * 1000, isFromMe: isMe, service: "skype",
                                    body: body, subject: nil, sourceKey: "skype:\(me):\(r.id)", attachments: [])
            rec.participantHandles = others.map(handle)
            if !isMe, !r.author.isEmpty { rec.senderHandle = handle(r.author) }
            writer.groupKeySuffix = isGroup ? "sk-" + r.chat : nil
            switch try writer.add(rec) {
            case .inserted: stats.inserted += 1
            case .duplicate: stats.duplicates += 1
            }
            if writer.lastThreadID != 0 { threadChats[writer.lastThreadID] = (r.chat, isGroup) }
            if seenChats.insert(r.chat).inserted { stats.chats += 1; if isGroup { stats.groups += 1 } else { stats.dms += 1 } }
            for o in others { seenPeople.insert(o) }
            firstTs = min(firstTs ?? rec.tsMs, rec.tsMs); lastTs = max(lastTs ?? rec.tsMs, rec.tsMs)
        }
        stats.people = seenPeople.count
        stats.firstTsMs = firstTs; stats.lastTsMs = lastTs

        for id in seenPeople.sorted() {
            let n = displayName(id)
            if n != id { try writer.noteName(service: handle(id), name: n, origin: nameOrigin, priority: ContactPriority.androidXML) }
        }
        let sel = try db.prepare("SELECT title, is_group FROM thread WHERE id = ?")
        let up = try db.prepare("UPDATE thread SET service = 'skype', origin = ?, hidden = 0, external_id = COALESCE(external_id, ?), title = ? WHERE id = ?")
        for (tid, info) in threadChats.sorted(by: { $0.key < $1.key }) {
            sel.bind(1, tid)
            _ = try sel.step()
            let oldTitle = sel.string(0)
            sel.reset()
            let title = (oldTitle == nil && info.isGroup) ? chatTitle[info.chat] : oldTitle
            up.bind(1, info.isGroup ? "group" : "dm").bind(2, info.chat).bind(3, title).bind(4, tid)
            try up.run()
        }
    }

    // MARK: body text

    /// The readable body of a Skype message row, plus how many smileys and links it held.
    static func plainText(_ r: Row) -> (String?, Int, Int) {
        guard let xml = r.body, !xml.isEmpty else { return (nil, 0, 0) }
        if r.type == 68 {
            // sent file "x.png"<files><file size="74523">x.png</file></files>  ->  (file sent: x.png, 73 KB; the file is not in the Skype database)
            var names: [String] = []
            var rest = Substring(xml)
            while let a = rest.range(of: "<file "), let b = rest.range(of: "</file>", range: a.upperBound..<rest.endIndex),
                  let close = rest[a.upperBound..<b.lowerBound].firstIndex(of: ">") {
                names.append(decodeEntities(String(rest[rest.index(after: close)..<b.lowerBound])))
                rest = rest[b.upperBound...]
            }
            guard !names.isEmpty else { return (strip(xml).0, 0, 0) }
            return ("(file sent: " + names.joined(separator: ", ") + "; the file is not in the Skype database)", 0, 0)
        }
        let (text, smileys, links) = strip(xml)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return (nil, smileys, links) }
        return (r.type == 60 ? "/me " + t : t, smileys, links)
    }

    /// Tags out, entities decoded. `<ss type="smile">:)</ss>` keeps `:)`; `<a href="u">label</a>` keeps the label, or `u` when the label is empty.
    static func strip(_ xml: String) -> (String, Int, Int) {
        var out = "", smileys = 0, links = 0
        var i = xml.startIndex
        var pendingHref: String?
        var linkLabel = ""
        var inLink = false
        while i < xml.endIndex {
            if xml[i] == "<", let end = xml[i...].firstIndex(of: ">") {
                let tag = String(xml[xml.index(after: i)..<end])
                if tag.hasPrefix("ss ") || tag == "ss" { smileys += 1 }
                else if tag.hasPrefix("a ") {
                    inLink = true; linkLabel = ""; links += 1
                    if let r = tag.range(of: "href=\""), let e = tag[r.upperBound...].firstIndex(of: "\"") { pendingHref = decodeEntities(String(tag[r.upperBound..<e])) } else { pendingHref = nil }
                } else if tag == "/a" {
                    inLink = false
                    if linkLabel.isEmpty, let h = pendingHref { out += h }
                    pendingHref = nil
                }
                i = xml.index(after: end)
                continue
            }
            // A run of text up to the next tag.
            let next = xml[i...].firstIndex(of: "<") ?? xml.endIndex
            let chunk = decodeEntities(String(xml[i..<next]))
            out += chunk
            if inLink { linkLabel += chunk }
            i = next
        }
        return (out, smileys, links)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
