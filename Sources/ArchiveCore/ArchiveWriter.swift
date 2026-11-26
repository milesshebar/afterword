import Foundation

public struct AttachmentRecord: Sendable {
    public var mime: String?
    public var filename: String?
    public var sha256: String
    public var relativePath: String
    public var bytes: Int
}

public struct ReactionRecord: Sendable {
    public var emoji: String
    public var actor: ServiceHandle?       // nil with byMe: the owner
    public var byMe: Bool
    public init(emoji: String, actor: ServiceHandle?, byMe: Bool) { self.emoji = emoji; self.actor = actor; self.byMe = byMe }
}

/// A source-independent message, ready for the archive. Handles are raw spellings; the writer normalizes them.
public struct MessageRecord: Sendable {
    public var participants: [String]      // everyone but me, raw spellings
    public var sender: String?             // raw; nil = me
    public var tsMs: Int64
    public var isFromMe: Bool
    public var service: String             // sms | mms | imessage
    public var body: String?
    public var subject: String?
    public var sourceKey: String?
    public var attachments: [AttachmentRecord]
    /// Messenger / Instagram: people are service handles, not phone numbers. When `participantHandles` is non-empty it is used
    /// instead of `participants`, and `senderHandle` instead of `sender`.
    public var participantHandles: [ServiceHandle] = []
    public var senderHandle: ServiceHandle?
    /// NULL for an ordinary message; `system` | `call` | `unsent` with the readable line in `note` (and `body` nil).
    public var kind: String?
    public var note: String?
    public var reactions: [ReactionRecord] = []
    public init(participants: [String], sender: String?, tsMs: Int64, isFromMe: Bool, service: String,
                body: String? = nil, subject: String? = nil, sourceKey: String? = nil, attachments: [AttachmentRecord] = []) {
        self.participants = participants; self.sender = sender; self.tsMs = tsMs; self.isFromMe = isFromMe
        self.service = service; self.body = body; self.subject = subject; self.sourceKey = sourceKey
        self.attachments = attachments
    }
}

/// Where a contact name came from. A higher priority wins at view time.
public enum ContactOrigin {
    public static let contactsApp = "contacts-app"
    public static let iphoneAddressBook = "iphone-addressbook"
    public static let androidXML = "android-xml"
}
public enum ContactPriority {
    public static let contactsApp = 30
    public static let iphoneAddressBook = 20
    public static let androidXML = 10
}

/// Which source wins as the canonical copy of a duplicate group: lower is better.
public enum SourceTier {
    public static let modernIOS = 0
    public static let legacyIOS = 1
    public static let other = 2
}

public enum WriteOutcome { case inserted, duplicate }

/// Inserts messages for one source, resolving threads/handles and applying the dedup rules.
/// Must be used inside a transaction owned by the caller.
public final class ArchiveWriter {
    let db: Database
    public let sourceID: Int64
    public let sourceKind: String
    public let sourceTier: Int
    private let checkDuplicates: Bool

    private var normalizedByID: [Int64: String] = [:]
    private var handleCache: [String: Int64?] = [:]      // raw -> handle id (nil = placeholder / me)
    private var handleByNormalized: [String: Int64] = [:]
    private var threadCache: [String: Int64] = [:]
    private var seenNames = Set<String>()
    private var claimed = Set<Int64>()          // duplicate groups (root row ids) already matched in this import

    private let insHandle: Statement, selHandle: Statement
    private let insThread: Statement, selThread: Statement, insMember: Statement
    private let insMessage: Statement, insAttachment: Statement, insMedia: Statement, selMedia: Statement
    private let insName: Statement, insReaction: Statement
    private let selByKey: Statement, selByTime: Statement
    private let selRankInfo: Statement, repoint: Statement

    public private(set) var knownMedia: [String: String] = [:]   // sha -> path (lazy)

    public init(db: Database, sourceID: Int64, sourceKind: String, sourceTier: Int? = nil) throws {
        self.db = db; self.sourceID = sourceID; self.sourceKind = sourceKind
        self.sourceTier = sourceTier ?? (sourceKind.hasPrefix("ios") ? SourceTier.modernIOS : SourceTier.other)
        checkDuplicates = try db.scalarInt("SELECT count(*) FROM source WHERE id != \(sourceID)") > 0
        insHandle = try db.prepare("INSERT INTO handle(raw, normalized, kind) VALUES (?,?,?)")
        selHandle = try db.prepare("SELECT id FROM handle WHERE normalized = ?")
        insThread = try db.prepare("INSERT INTO thread(key, is_group, title) VALUES (?,?,NULL)")
        selThread = try db.prepare("SELECT id FROM thread WHERE key = ?")
        insMember = try db.prepare("INSERT OR IGNORE INTO thread_member(thread_id, handle_id) VALUES (?,?)")
        insMessage = try db.prepare("""
            INSERT INTO message(thread_id, sender_handle_id, ts_ms, is_from_me, service, body, subject, source_id,
                                source_key, canonical_id, content_hash, att_hash, kind, note)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        insReaction = try db.prepare("INSERT INTO reaction(message_id, emoji, actor_handle_id, by_me) VALUES (?,?,?,?)")
        insAttachment = try db.prepare("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (?,?,?,?,?,?)")
        insMedia = try db.prepare("INSERT OR IGNORE INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
        selMedia = try db.prepare("SELECT path FROM media WHERE sha256 = ?")
        insName = try db.prepare("INSERT OR IGNORE INTO contact_name(handle_id, name, origin, priority) VALUES (?,?,?,?)")
        selByKey = try db.prepare("SELECT id, canonical_id FROM message WHERE source_key = ? AND source_id != ?")
        selByTime = try db.prepare("""
            SELECT id, canonical_id, content_hash, att_hash, ts_ms, source_key, body, sender_handle_id FROM message
            WHERE thread_id = ? AND ts_ms BETWEEN ? AND ? AND is_from_me = ? AND source_id != ?
            """)
        selRankInfo = try db.prepare("""
            SELECT s.kind, m.source_id, (SELECT count(*) FROM attachment a WHERE a.message_id = m.id), s.stats_json
            FROM message m JOIN source s ON s.id = m.source_id WHERE m.id = ?
            """)
        repoint = try db.prepare("UPDATE message SET canonical_id = ? WHERE id = ? OR canonical_id = ?")
    }

    // MARK: handles, threads, names

    func handleID(raw: String) throws -> Int64? {
        if let cached = handleCache[raw] { return cached }
        guard let n = HandleNormalizer.normalize(raw) else { handleCache[raw] = .some(nil); return nil }
        if let id = handleByNormalized[n.normalized] { handleCache[raw] = id; return id }
        selHandle.bind(1, n.normalized)
        var id: Int64
        if try selHandle.step() { id = selHandle.int(0); selHandle.reset() }
        else {
            selHandle.reset()
            insHandle.bind(1, raw).bind(2, n.normalized).bind(3, n.kind.rawValue)
            try insHandle.run()
            id = db.lastInsertRowID
        }
        handleByNormalized[n.normalized] = id
        normalizedByID[id] = n.normalized
        handleCache[raw] = id
        return id
    }

    /// Records a display name carried by the source (the XML `contact_name`). Ignores blanks and "(Unknown)".
    public func noteName(forRaw raw: String, name: String, origin: String = ContactOrigin.androidXML, priority: Int = ContactPriority.androidXML) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == "(Unknown)" || n == "null" { return }
        guard let hid = try handleID(raw: raw) else { return }
        let k = "\(hid)\u{1}\(origin)\u{1}\(n)"
        if seenNames.contains(k) { return }
        seenNames.insert(k)
        insName.bind(1, hid).bind(2, n).bind(3, origin).bind(4, priority)
        try insName.run()
    }

    /// Handle row for a Messenger / Instagram person (created on first use).
    public func handleID(service h: ServiceHandle) throws -> Int64 {
        if let id = handleByNormalized[h.normalized] { return id }
        selHandle.bind(1, h.normalized)
        var id: Int64
        if try selHandle.step() { id = selHandle.int(0); selHandle.reset() }
        else {
            selHandle.reset()
            insHandle.bind(1, h.raw).bind(2, h.normalized).bind(3, h.kind.rawValue)
            try insHandle.run()
            id = db.lastInsertRowID
        }
        handleByNormalized[h.normalized] = id
        normalizedByID[id] = h.normalized
        return id
    }

    /// Records a display name for a service handle (`origin` such as `messenger-export`, `instagram-username`).
    public func noteName(service h: ServiceHandle, name: String, origin: String, priority: Int) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return }
        let hid = try handleID(service: h)
        let k = "\(hid)\u{1}\(origin)\u{1}\(n)"
        if seenNames.contains(k) { return }
        seenNames.insert(k)
        insName.bind(1, hid).bind(2, n).bind(3, origin).bind(4, priority)
        try insName.run()
    }

    /// Row id and thread of the message most recently written by `add`.
    public private(set) var lastThreadID: Int64 = 0
    /// When set, group threads (more than one other participant) are keyed by participants plus this suffix, so two
    /// group chats with the same members stay separate threads (Meta importers pass the thread folder's id).
    public var groupKeySuffix: String?
    /// With `groupKeySuffix`: the thread's `service` value (Meta importers: messenger | instagram). A chat whose participant set no
    /// longer matches any key (a member renamed or deactivated, joined or left between two exports) is still the same chat when an
    /// earlier import stored a thread of this service, group or one-to-one alike, with this folder id as its `external_id`: `add`
    /// then writes into that thread and adds the new participants as members, instead of opening a second thread and storing every
    /// message twice.
    public var groupExternalService: String?
    /// When set, `add` writes into this existing thread and does not resolve participants (the 2011 Facebook export's
    /// importer uses it to put a missing first message into the thread the archive already holds for that conversation).
    public var threadOverride: Int64?
    /// When true, `add` never links a row to an existing one: the caller has already decided it is new (the 2011 export's
    /// importer, whose own matching consumed the archive rows it found).
    public var skipDuplicateCheck = false
    /// When true (`import --add-only`), a record that matches an existing row is held: nothing is written, no existing row is
    /// re-pointed, and `lastHeldID` names the existing duplicate group's canonical row.
    public var holdMatches = false
    /// When set, `add` writes into the thread with this key (created on first use, `is_group` from `threadKeyIsGroup`) and adds the
    /// record's participants to it as members (new ones join an existing thread). Telegram keys a chat by its own peer id this way.
    public var threadKey: String?
    public var threadKeyIsGroup = true
    /// When true, a content match must also have the same sender (a group where two people send the same words a second apart).
    public var matchRequiresSameSender = false
    /// The row `add` wrote last (nil when it held the record), and the existing row it held the record against.
    public private(set) var lastMessageID: Int64?
    public private(set) var lastHeldID: Int64?
    /// The held row carries a different iMessage guid (a content copy, not the same message by id).
    public private(set) var lastHeldOtherGuid = false

    private func threadID(for handles: [(id: Int64, normalized: String)]) throws -> Int64 {
        var key = ThreadKey.key(for: handles.map { $0.normalized })
        if let suffix = groupKeySuffix, handles.count > 1 { key += "|" + suffix }
        if let t = threadCache[key] { return t }
        selThread.bind(1, key)
        if try selThread.step() {
            let t = selThread.int(0); selThread.reset(); threadCache[key] = t; return t
        }
        selThread.reset()
        if let suffix = groupKeySuffix, let service = groupExternalService {
            let byExt = try db.prepare("SELECT id FROM thread WHERE external_id = ? AND service = ? AND is_group = ? ORDER BY id LIMIT 1")
            byExt.bind(1, suffix).bind(2, service).bind(3, handles.count > 1)
            defer { byExt.reset() }
            if try byExt.step() {
                let t = byExt.int(0)
                for h in handles { insMember.bind(1, t).bind(2, h.id); try insMember.run() }
                threadCache[key] = t
                return t
            }
        }
        insThread.bind(1, key).bind(2, handles.count > 1)
        try insThread.run()
        let t = db.lastInsertRowID
        for h in handles { insMember.bind(1, t).bind(2, h.id); try insMember.run() }
        threadCache[key] = t
        return t
    }

    private func threadID(key: String, members: [(id: Int64, normalized: String)]) throws -> Int64 {
        var t: Int64
        if let c = threadCache[key] { t = c }
        else {
            selThread.bind(1, key)
            if try selThread.step() { t = selThread.int(0); selThread.reset() }
            else {
                selThread.reset()
                insThread.bind(1, key).bind(2, threadKeyIsGroup)
                try insThread.run()
                t = db.lastInsertRowID
            }
            threadCache[key] = t
        }
        for h in members { insMember.bind(1, t).bind(2, h.id); try insMember.run() }
        return t
    }

    // MARK: dedup

    private struct Rank: Comparable {
        let tier: Int, noAtt: Int, source: Int64
        static func < (a: Rank, b: Rank) -> Bool { (a.tier, a.noAtt, a.source) < (b.tier, b.noAtt, b.source) }
    }

    private func rank(ofExisting id: Int64) throws -> Rank {
        selRankInfo.bind(1, id)
        defer { selRankInfo.reset() }
        guard try selRankInfo.step() else { return Rank(tier: SourceTier.other, noAtt: 1, source: .max) }
        let kind = selRankInfo.string(0) ?? ""
        var tier = SourceTier.other
        if kind.hasPrefix("ios") || kind == MacChatDBImporter.kind { tier = (selRankInfo.string(3) ?? "").contains("\"schema\":\"legacy\"") ? SourceTier.legacyIOS : SourceTier.modernIOS }
        return Rank(tier: tier, noAtt: selRankInfo.int(2) > 0 ? 0 : 1, source: selRankInfo.int(1))
    }

    /// Finds an existing row from an earlier source that this message duplicates.
    private func findMatch(thread: Int64, rec: MessageRecord, senderID: Int64?, contentHash: Int64, attHash: Int64?, bodyEmpty: Bool, strippedHash: Int64) throws -> (id: Int64, canonical: Int64?, otherGuid: Bool)? {
        if let key = rec.sourceKey {
            selByKey.bind(1, key).bind(2, sourceID)
            defer { selByKey.reset() }
            while try selByKey.step() {
                let id = selByKey.int(0)
                let group = selByKey.optInt(1) ?? id
                if !claimed.contains(group) { return (id, selByKey.optInt(1), false) }
            }
        }
        selByTime.bind(1, thread).bind(2, rec.tsMs - 2000).bind(3, rec.tsMs + 2000).bind(4, rec.isFromMe).bind(5, sourceID)
        defer { selByTime.reset() }
        var best: (id: Int64, canonical: Int64?, dt: Int64, exact: Bool, otherGuid: Bool)?
        while try selByTime.step() {
            let id = selByTime.int(0)
            // Holding (add-only) never uses a row up: two snapshot rows that both look like one archive row are both held;
            // linking still pairs each archive row with one new row.
            if !holdMatches, claimed.contains(selByTime.optInt(1) ?? id) { continue }
            if matchRequiresSameSender, selByTime.optInt(7) != senderID { continue }
            // Two different iMessage guids are two different messages, however close their clocks. Not when holding: another Mac's
            // copy of a relayed SMS, for one, carries a guid of its own; the ledger lists those holds apart.
            var otherGuid = false
            if let mine = rec.sourceKey, mine.hasPrefix("ios:"), let theirs = selByTime.string(5), theirs.hasPrefix("ios:"), theirs != mine {
                if !holdMatches { continue }
                otherGuid = true
            }
            var exact = true
            let same: Bool
            if bodyEmpty, attHash != nil { same = selByTime.optInt(3) == attHash }
            else if selByTime.int(2) == contentHash { same = true }
            else if Hashing.strippedBodyHash(selByTime.string(6)) == strippedHash { same = true; exact = false }   // emoji-stripped copy
            else { same = false }
            if !same { continue }
            let dt = abs(selByTime.int(4) - rec.tsMs)
            // An exact text match always beats an emoji-tolerant one; then the closest clock wins.
            if best == nil || (exact && !best!.exact) || (exact == best!.exact && dt < best!.dt) { best = (id, selByTime.optInt(1), dt, exact, otherGuid) }
        }
        return best.map { ($0.id, $0.canonical, $0.otherGuid) }
    }

    // MARK: writing

    @discardableResult
    public func add(_ rec: MessageRecord) throws -> WriteOutcome {
        var members: [(id: Int64, normalized: String)] = []
        var seen = Set<Int64>()
        if threadOverride != nil {
            // the thread is given: nothing to resolve
        } else if rec.participantHandles.isEmpty {
            for raw in rec.participants {
                guard let id = try handleID(raw: raw), seen.insert(id).inserted else { continue }
                members.append((id, handleNormalized(id)))
            }
        } else {
            for h in rec.participantHandles {
                let id = try handleID(service: h)
                guard seen.insert(id).inserted else { continue }
                members.append((id, h.normalized))
            }
        }
        let thread: Int64
        if let o = threadOverride { thread = o }
        else if let k = threadKey { thread = try threadID(key: k, members: members) }
        else { thread = try threadID(for: members) }
        var senderID: Int64? = nil
        if !rec.isFromMe {
            if let h = rec.senderHandle { senderID = try handleID(service: h) }
            else if let s = rec.sender { senderID = try handleID(raw: s) }
        }

        // Note-only rows (system lines, calls) hash their note, so two different lines in the same second never look alike.
        let body = Hashing.normalizedBody(rec.body ?? rec.note)
        let contentHash = Hashing.fnv1a(body)
        let attHash = Hashing.attachmentHash(rec.attachments.map { $0.sha256 })

        var canonicalForNew: Int64? = nil
        var flipFrom: Int64? = nil
        lastMessageID = nil; lastHeldID = nil; lastHeldOtherGuid = false
        if checkDuplicates, !skipDuplicateCheck,
           let m = try findMatch(thread: thread, rec: rec, senderID: senderID, contentHash: contentHash, attHash: attHash, bodyEmpty: body.isEmpty,
                                 strippedHash: Hashing.strippedBodyHash(rec.body ?? rec.note)) {
            let existingCanonical = m.canonical ?? m.id
            if holdMatches {
                lastHeldID = existingCanonical
                lastHeldOtherGuid = m.otherGuid
                lastThreadID = thread
                return .duplicate
            }
            claimed.insert(existingCanonical)
            let newRank = Rank(tier: sourceTier, noAtt: rec.attachments.isEmpty ? 1 : 0, source: sourceID)
            if newRank < (try rank(ofExisting: existingCanonical)) { flipFrom = existingCanonical }
            else { canonicalForNew = existingCanonical }
        }

        insMessage.bind(1, thread).bind(2, senderID).bind(3, rec.tsMs).bind(4, rec.isFromMe).bind(5, rec.service)
            .bind(6, rec.body).bind(7, rec.subject).bind(8, sourceID).bind(9, rec.sourceKey).bind(10, canonicalForNew)
            .bind(11, contentHash).bind(12, attHash).bind(13, rec.kind).bind(14, rec.note)
        try insMessage.run()
        let mid = db.lastInsertRowID
        lastThreadID = thread
        lastMessageID = mid
        for r in rec.reactions {
            var actor: Int64? = nil
            if !r.byMe, let a = r.actor { actor = try handleID(service: a) }
            insReaction.bind(1, mid).bind(2, r.emoji).bind(3, actor).bind(4, r.byMe)
            try insReaction.run()
        }
        if let old = flipFrom {
            // The new row outranks the existing canonical: it takes over the whole duplicate group.
            repoint.bind(1, mid).bind(2, old).bind(3, old)
            try repoint.run()
            claimed.insert(mid)
        }
        for a in rec.attachments {
            insMedia.bind(1, a.sha256).bind(2, a.relativePath).bind(3, a.bytes).bind(4, a.mime)
            try insMedia.run()
            insAttachment.bind(1, mid).bind(2, a.mime).bind(3, a.filename).bind(4, a.relativePath).bind(5, a.bytes).bind(6, a.sha256)
            try insAttachment.run()
        }
        return canonicalForNew == nil && flipFrom == nil ? .inserted : .duplicate
    }

    private func handleNormalized(_ id: Int64) -> String { normalizedByID[id] ?? "\(id)" }

    /// Path already recorded for this media hash, if any.
    /// An iMessage tapback (or its removal) on the message whose source key is `targetSourceKey` (`ios:<guid>`), following the
    /// target to its canonical row. Returns false when the target is not in the archive.
    @discardableResult
    public func addTapback(targetSourceKey: String, emoji: String, actorRaw: String?, byMe: Bool, removal: Bool) throws -> Bool {
        let find = try db.prepare("SELECT coalesce(canonical_id, id) FROM message WHERE source_key = ? ORDER BY id LIMIT 1")
        find.bind(1, targetSourceKey)
        guard try find.step() else { find.reset(); return false }
        let target = find.int(0)
        find.reset()
        let actor: Int64? = byMe ? nil : try actorRaw.flatMap { try handleID(raw: $0) }
        if removal {
            let del = try db.prepare("""
                DELETE FROM reaction WHERE rowid = (SELECT rowid FROM reaction WHERE message_id = ?1 AND emoji = ?2
                  AND by_me = ?3 AND actor_handle_id IS ?4 ORDER BY rowid DESC LIMIT 1)
                """)
            del.bind(1, target).bind(2, emoji).bind(3, byMe).bind(4, actor)
            try del.run()
        } else {
            insReaction.bind(1, target).bind(2, emoji).bind(3, actor).bind(4, byMe)
            try insReaction.run()
        }
        return true
    }

    public func existingMediaPath(sha256: String) -> String? {
        if let p = knownMedia[sha256] { return p }
        selMedia.bind(1, sha256)
        defer { selMedia.reset() }
        if (try? selMedia.step()) == true, let p = selMedia.string(0) { knownMedia[sha256] = p; return p }
        return nil
    }
}
