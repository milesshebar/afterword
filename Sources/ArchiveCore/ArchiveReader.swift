import Foundation

// Read-side API for the app (and tests). Everything here reads canonical rows only (`canonical_id IS NULL`), the
// same set the UI shows. The reader opens the archive read-only; it never writes.

public struct ThreadMember: Sendable, Hashable {
    public var handleID: Int64
    public var normalized: String
    public var raw: String
    /// Best archive-side name (highest `contact_name.priority`), if any.
    public var archiveName: String?
}

public struct ConversationSummary: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var isGroup: Bool
    public var storedTitle: String?
    public var members: [ThreadMember]
    public var messageCount: Int
    public var lastTsMs: Int64
    public var preview: String?
    /// Source kinds that contributed canonical rows (`android-xml`, `ios-backup`, `messenger-thread`, ...).
    public var sourceKinds: [String]
    /// Canonical messages per service (SMS and MMS rows count as SMS).
    public var serviceCounts: [ServiceKey: Int] = [:]
    /// `messenger` | `instagram` for Meta threads; nil for SMS / iMessage threads.
    public var service: String?
    /// Meta folder the thread came from (inbox, archived, e2ee, filtered, requests).
    public var origin: String?
    /// Filtered threads and message requests: off by default in the list.
    public var hidden = false
    public var services: [ServiceKey] { serviceCounts.filter { $0.value > 0 }.keys.sorted() }
}

public struct ReactionInfo: Sendable, Hashable {
    public var emoji: String
    public var byMe: Bool
    public var actorNormalized: String?
    public var actorArchiveName: String?
}

/// Which messages a view shows: the canonical messages of these threads (one thread, or all of a person's 1:1 threads),
/// optionally limited to some services. Messages are ordered by `(ts_ms, id)` across the threads.
public struct MessageScope: Sendable, Hashable {
    public var threadIDs: [Int64]
    public var services: Set<ServiceKey>?
    public init(threads: [Int64], services: Set<ServiceKey>? = nil) { threadIDs = threads.sorted(); self.services = services }
    public init(thread: Int64) { threadIDs = [thread]; services = nil }
    var serviceFiltered: Bool { if let s = services { return s.count < ServiceKey.allCases.count }; return false }
}

public struct AttachmentInfo: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var mime: String?
    public var filename: String?
    public var mediaPath: String          // root-relative
    public var bytes: Int64
    public var sha256: String
    public var isImage: Bool { (mime ?? "").lowercased().hasPrefix("image/") }
    public var isVideo: Bool { (mime ?? "").lowercased().hasPrefix("video/") }
    public var isAudio: Bool { (mime ?? "").lowercased().hasPrefix("audio/") }
}

public struct MessageRow: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var threadID: Int64
    public var tsMs: Int64
    public var isFromMe: Bool
    public var service: String
    public var body: String?
    public var subject: String?
    public var senderHandleID: Int64?
    public var senderNormalized: String?
    public var senderRaw: String?
    public var senderArchiveName: String?
    public var attachments: [AttachmentInfo]
    /// nil for an ordinary message; `system` | `call` | `unsent` (the readable line is `note`; `body` is nil).
    public var kind: String? = nil
    public var note: String? = nil
    public var reactions: [ReactionInfo] = []
    public var serviceKey: ServiceKey { ServiceKey.of(messageService: service) }
}

/// A position in a thread. Messages are ordered by `(ts_ms, id)`.
public struct MessageKey: Sendable, Hashable {
    public var tsMs: Int64
    public var id: Int64
    public init(tsMs: Int64, id: Int64) { self.tsMs = tsMs; self.id = id }
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public var id: Int64 { messageID }
    public var messageID: Int64
    public var threadID: Int64
    public var tsMs: Int64
    public var isFromMe: Bool
    public var senderNormalized: String?
    public var senderArchiveName: String?
    public var service: String = "sms"
    /// Snippet text with match boundaries marked by U+0001 (start) and U+0002 (end).
    public var snippet: String
    /// The words matched the machine transcript of the message's voice message, not its text (the snippet is from the transcript).
    public var isVoice: Bool = false

    public init(messageID: Int64, threadID: Int64, tsMs: Int64, isFromMe: Bool, senderNormalized: String? = nil, senderArchiveName: String? = nil,
                service: String = "sms", snippet: String, isVoice: Bool = false) {
        self.messageID = messageID; self.threadID = threadID; self.tsMs = tsMs; self.isFromMe = isFromMe; self.senderNormalized = senderNormalized
        self.senderArchiveName = senderArchiveName; self.service = service; self.snippet = snippet; self.isVoice = isVoice
    }
}

public enum SearchOrder: String, Sendable { case bestMatch, newest, oldest }

public struct MonthCount: Sendable, Hashable, Identifiable {
    public var year: Int
    public var month: Int
    public var count: Int
    public var id: Int { year * 12 + month - 1 }
    public init(year: Int, month: Int, count: Int) { self.year = year; self.month = month; self.count = count }
}

public struct ArchiveOverview: Sendable {
    public var messages: Int
    public var threads: Int
    public var firstTsMs: Int64?
    public var lastTsMs: Int64?
    public var isDemo: Bool
}

public final class ArchiveReader: @unchecked Sendable {
    public let root: ArchiveRoot
    let db: Database
    private let lock = NSLock()
    private var cache: [String: Statement] = [:]

    /// `PRAGMA user_version` of the archive as opened. A read-only open never migrates, so an archive from before
    /// stage A (v4) or stage B (v5) opens with the columns it has: the reader guards every newer column and table.
    public let schemaVersion: Int
    private let hasKind: Bool, hasThreadMeta: Bool, hasReactions: Bool
    private var threadServiceCache: [Int64: String?]?

    public init(root: ArchiveRoot, assumeNetwork: Bool? = nil) throws {
        self.root = root
        db = try Schema.openArchive(root: root, readOnly: true, assumeNetwork: assumeNetwork)
        let v = try db.userVersion()
        if v > Schema.currentVersion { throw ArchiveError("archive schema v\(v) is newer than this build") }
        schemaVersion = v
        hasKind = try db.hasColumn("message", "kind")
        hasThreadMeta = try db.hasColumn("thread", "hidden")
        hasReactions = try db.tableExists("reaction")
    }

    func stmt(_ sql: String) throws -> Statement {
        if let s = cache[sql] { s.reset(); return s }
        if cache.count > 300 { cache.removeAll() }      // person views build one statement per thread set
        let s = try db.prepare(sql)
        cache[sql] = s
        return s
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: overview

    public func overview() throws -> ArchiveOverview {
        try locked {
            let st = try stmt("SELECT count(*), min(ts_ms), max(ts_ms) FROM message WHERE canonical_id IS NULL")
            _ = try st.step()
            let n = Int(st.int(0)), lo = st.optInt(1), hi = st.optInt(2)
            st.reset()
            let threads = Int(try db.scalarInt("SELECT count(*) FROM thread"))
            var demo = false
            if try db.tableExists("meta") { demo = try db.scalarString("SELECT value FROM meta WHERE key = 'demo'") == "1" }
            return ArchiveOverview(messages: n, threads: threads, firstTsMs: lo, lastTsMs: hi, isDemo: demo)
        }
    }

    // MARK: people

    /// The effective person mapping: stored automatic matches (or, for an archive that has none yet, matches computed on
    /// the spot) with `overrides` applied. `extraNames` (normalized handle -> name, for example from Contacts.app) are
    /// treated as top-priority names and force a fresh computation.
    public func people(overrides: OverrideSet = OverrideSet(), extraNames: [String: String] = [:]) throws -> PeopleIndex {
        try locked { try PeopleStore.index(db: db, overrides: overrides, extraNames: extraNames) }
    }

    // MARK: conversations

    /// Conversations that have canonical messages (optionally only within `range`, in which case counts, last date and
    /// preview are for that range). Hidden Meta threads (filtered, message requests) are left out unless asked for.
    public func conversations(range: ClosedRange<Int64>? = nil, includeHidden: Bool = false) throws -> [ConversationSummary] {
        try locked {
            let lo = range?.lowerBound ?? Int64.min, hi = range?.upperBound ?? Int64.max
            var out: [Int64: ConversationSummary] = [:]

            let meta = hasThreadMeta ? "t.service, t.origin, t.hidden" : "NULL, NULL, 0"
            let agg = try stmt("""
                SELECT m.thread_id, count(*), max(m.ts_ms), t.is_group, t.title, \(meta)
                FROM message m JOIN thread t ON t.id = m.thread_id
                WHERE m.canonical_id IS NULL AND m.ts_ms BETWEEN ? AND ?
                GROUP BY m.thread_id
                """)
            agg.bind(1, lo).bind(2, hi)
            while try agg.step() {
                let id = agg.int(0)
                let hidden = agg.int(7) != 0
                if hidden && !includeHidden { continue }
                var c = ConversationSummary(id: id, isGroup: agg.int(3) != 0, storedTitle: agg.string(4), members: [],
                                            messageCount: Int(agg.int(1)), lastTsMs: agg.int(2), preview: nil, sourceKinds: [])
                c.service = agg.string(5); c.origin = agg.string(6); c.hidden = hidden
                out[id] = c
            }
            agg.reset()

            let kinds = try stmt("""
                SELECT m.thread_id, s.kind, m.service, count(*) FROM message m JOIN source s ON s.id = m.source_id
                WHERE m.canonical_id IS NULL AND m.ts_ms BETWEEN ? AND ? GROUP BY m.thread_id, s.kind, m.service
                """)
            kinds.bind(1, lo).bind(2, hi)
            while try kinds.step() {
                let t = kinds.int(0)
                guard out[t] != nil else { continue }
                let k = kinds.string(1) ?? ""
                if !out[t]!.sourceKinds.contains(k) { out[t]!.sourceKinds.append(k) }
                out[t]!.serviceCounts[ServiceKey.of(messageService: kinds.string(2) ?? "sms"), default: 0] += Int(kinds.int(3))
            }
            kinds.reset()

            let mem = try stmt("""
                SELECT tm.thread_id, h.id, h.normalized, h.raw,
                       (SELECT name FROM contact_name c WHERE c.handle_id = h.id ORDER BY priority DESC, name LIMIT 1)
                FROM thread_member tm JOIN handle h ON h.id = tm.handle_id ORDER BY tm.thread_id, h.id
                """)
            while try mem.step() {
                let t = mem.int(0)
                guard out[t] != nil else { continue }
                out[t]!.members.append(ThreadMember(handleID: mem.int(1), normalized: mem.string(2) ?? "", raw: mem.string(3) ?? "", archiveName: mem.string(4)))
            }
            mem.reset()

            let note = hasKind ? "m.note" : "NULL"
            let prev = try stmt("""
                SELECT m.body, (SELECT count(*) FROM attachment a WHERE a.message_id = m.id), (SELECT mime FROM attachment a WHERE a.message_id = m.id LIMIT 1), \(note)
                FROM message m WHERE m.thread_id = ? AND m.canonical_id IS NULL AND m.ts_ms BETWEEN ? AND ?
                ORDER BY m.ts_ms DESC, m.id DESC LIMIT 1
                """)
            for id in out.keys {
                prev.bind(1, id).bind(2, lo).bind(3, hi)
                if try prev.step() {
                    let body = prev.string(0)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !body.isEmpty { out[id]!.preview = body }
                    else if prev.int(1) > 0 { out[id]!.preview = Self.attachmentLabel(mime: prev.string(2)) }
                    else if let n = prev.string(3), !n.isEmpty { out[id]!.preview = n }
                }
                prev.reset()
            }
            return Array(out.values)
        }
    }

    static func attachmentLabel(mime: String?) -> String {
        let m = (mime ?? "").lowercased()
        if m.hasPrefix("image/") { return "Photo" }
        if m.hasPrefix("video/") { return "Video" }
        if m.hasPrefix("audio/") { return "Audio" }
        return "Attachment"
    }

    // MARK: scopes

    /// Service of each thread (nil for SMS / iMessage threads and for archives from before Meta imports).
    private func threadServices() throws -> [Int64: String?] {
        if let c = threadServiceCache { return c }
        var m: [Int64: String?] = [:]
        if hasThreadMeta {
            let st = try db.prepare("SELECT id, service FROM thread")
            while try st.step() { m[st.int(0)] = st.string(1) }
        }
        threadServiceCache = m
        return m
    }

    /// Threads of the scope that can contain a message of one of its services (a Messenger-only filter skips every phone thread).
    private func relevantThreads(_ scope: MessageScope) throws -> [Int64] {
        guard scope.serviceFiltered, let services = scope.services, hasThreadMeta else { return scope.threadIDs }
        let wantsMeta = services.contains(.messenger) || services.contains(.instagram) || services.contains(.groupme) || services.contains(.skype) || services.contains(.whatsapp) || services.contains(.snapchat) || services.contains(.aim) || services.contains(.telegram) || services.contains(.slack)
        let wantsPhone = services.contains(.sms) || services.contains(.imessage)
        let ts = try threadServices()
        return scope.threadIDs.filter { t in
            let s = ts[t] ?? nil
            if let s { return services.contains(ServiceKey.of(messageService: s)) && wantsMeta }
            return wantsPhone
        }
    }

    private func serviceClause(_ scope: MessageScope) -> String {
        guard scope.serviceFiltered, let services = scope.services else { return "" }
        let list = services.flatMap(\.messageServices).sorted().map { "'\($0)'" }.joined(separator: ",")
        return list.isEmpty ? " AND 0" : " AND m.service IN (\(list))"
    }

    // MARK: message paging

    private var messageSelect: String {
        """
        SELECT m.id, m.thread_id, m.ts_ms, m.is_from_me, m.service, m.body, m.subject, m.sender_handle_id,
               h.normalized, h.raw,
               (SELECT name FROM contact_name c WHERE c.handle_id = h.id ORDER BY priority DESC, name LIMIT 1),
               \(hasKind ? "m.kind, m.note" : "NULL, NULL")
        FROM message m LEFT JOIN handle h ON h.id = m.sender_handle_id
        """
    }

    private func readMessages(_ st: Statement) throws -> [MessageRow] {
        var rows: [MessageRow] = []
        while try st.step() {
            rows.append(MessageRow(id: st.int(0), threadID: st.int(1), tsMs: st.int(2), isFromMe: st.int(3) != 0,
                                   service: st.string(4) ?? "sms", body: st.string(5), subject: st.string(6),
                                   senderHandleID: st.optInt(7), senderNormalized: st.string(8), senderRaw: st.string(9),
                                   senderArchiveName: st.string(10), attachments: [], kind: st.string(11), note: st.string(12)))
        }
        st.reset()
        try attachAttachments(&rows)
        try attachReactions(&rows)
        return rows
    }

    private func attachAttachments(_ rows: inout [MessageRow]) throws {
        guard !rows.isEmpty else { return }
        var byID: [Int64: Int] = [:]
        for (i, r) in rows.enumerated() { byID[r.id] = i }
        // Rows of one page are close in id space only by luck; an IN list of integers is exact.
        let ids = rows.map { String($0.id) }.joined(separator: ",")
        let st = try db.prepare("SELECT message_id, id, mime, filename, media_path, bytes, sha256 FROM attachment WHERE message_id IN (\(ids)) ORDER BY message_id, id")
        while try st.step() {
            if let i = byID[st.int(0)] {
                rows[i].attachments.append(AttachmentInfo(id: st.int(1), mime: st.string(2), filename: st.string(3),
                                                          mediaPath: st.string(4) ?? "", bytes: st.int(5), sha256: st.string(6) ?? ""))
            }
        }
    }

    private func attachReactions(_ rows: inout [MessageRow]) throws {
        guard hasReactions, !rows.isEmpty else { return }
        var byID: [Int64: Int] = [:]
        for (i, r) in rows.enumerated() { byID[r.id] = i }
        let ids = rows.map { String($0.id) }.joined(separator: ",")
        let st = try db.prepare("""
            SELECT r.message_id, r.emoji, r.by_me, h.normalized,
                   (SELECT name FROM contact_name c WHERE c.handle_id = h.id ORDER BY priority DESC, name LIMIT 1)
            FROM reaction r LEFT JOIN handle h ON h.id = r.actor_handle_id WHERE r.message_id IN (\(ids)) ORDER BY r.rowid
            """)
        while try st.step() {
            if let i = byID[st.int(0)] {
                rows[i].reactions.append(ReactionInfo(emoji: st.string(1) ?? "", byMe: st.int(2) != 0, actorNormalized: st.string(3), actorArchiveName: st.string(4)))
            }
        }
    }

    /// One page of canonical messages of a scope. Several threads are merged by `(ts_ms, id)` with one indexed,
    /// limited arm per thread (a k-way merge in SQL), so the cost is `limit` rows per thread however long the timeline is.
    private func page(_ scope: MessageScope, cond: String, newestFirst: Bool, limit: Int, bind: (Statement) -> Void = { _ in }) throws -> [MessageRow] {
        let threads = try relevantThreads(scope)
        guard !threads.isEmpty else { return [] }
        let order = newestFirst ? "ORDER BY m.ts_ms DESC, m.id DESC" : "ORDER BY m.ts_ms, m.id"
        // One arm per thread, or per (thread, service) when filtering, so each arm walks an index in order.
        var arms: [String] = []
        let values: [String?] = scope.serviceFiltered ? (scope.services ?? []).flatMap(\.messageServices).sorted() : [nil]
        for t in threads { for v in values {
            let svc = v.map { " AND m.service = '\($0)'" } ?? ""
            arms.append("\(messageSelect) WHERE m.thread_id = \(t) AND m.canonical_id IS NULL\(svc)\(cond) \(order) LIMIT ?1")
        } }
        let sql: String
        if arms.count == 1 { sql = arms[0] }
        else {
            sql = arms.map { "SELECT * FROM (\($0))" }.joined(separator: " UNION ALL ")
                + " " + (newestFirst ? "ORDER BY ts_ms DESC, id DESC" : "ORDER BY ts_ms, id") + " LIMIT ?1"
        }
        let st = try stmt(sql)
        st.bind(1, limit)
        bind(st)
        let rows = try readMessages(st)
        return newestFirst ? rows.reversed() : rows
    }

    /// The newest `limit` messages, oldest first.
    public func latest(scope: MessageScope, limit: Int) throws -> [MessageRow] {
        try locked { try page(scope, cond: "", newestFirst: true, limit: limit) }
    }

    /// Up to `limit` messages strictly older than `key`, oldest first.
    public func before(scope: MessageScope, key: MessageKey, limit: Int) throws -> [MessageRow] {
        try locked {
            try page(scope, cond: " AND m.ts_ms <= ?2 AND (m.ts_ms < ?2 OR m.id < ?3)", newestFirst: true, limit: limit) { $0.bind(2, key.tsMs).bind(3, key.id) }
        }
    }

    /// Up to `limit` messages strictly newer than `key`, oldest first.
    public func after(scope: MessageScope, key: MessageKey, limit: Int) throws -> [MessageRow] {
        try locked {
            try page(scope, cond: " AND m.ts_ms >= ?2 AND (m.ts_ms > ?2 OR m.id > ?3)", newestFirst: false, limit: limit) { $0.bind(2, key.tsMs).bind(3, key.id) }
        }
    }

    /// A window centred on `key`: `before` older messages, the message itself, `after` newer ones.
    public func around(scope: MessageScope, key: MessageKey, before n: Int, after m: Int) throws -> [MessageRow] {
        let older = try before(scope: scope, key: key, limit: n)
        let at = try locked { () -> [MessageRow] in
            let st = try stmt(messageSelect + " WHERE m.id = ? AND m.canonical_id IS NULL")
            st.bind(1, key.id)
            return try readMessages(st).filter { scope.threadIDs.contains($0.threadID) }
        }
        let newer = try after(scope: scope, key: key, limit: m)
        return older + at + newer
    }

    /// The first message at or after `tsMs`; the last message if there is none later; nil for an empty scope.
    public func firstMessage(scope: MessageScope, atOrAfter tsMs: Int64) throws -> MessageKey? {
        try locked {
            let rows = try page(scope, cond: " AND m.ts_ms >= ?2", newestFirst: false, limit: 1) { $0.bind(2, tsMs) }
            if let r = rows.first { return MessageKey(tsMs: r.tsMs, id: r.id) }
            let last = try page(scope, cond: "", newestFirst: true, limit: 1)
            return last.first.map { MessageKey(tsMs: $0.tsMs, id: $0.id) }
        }
    }

    // single-thread conveniences (the v1 API)

    public func latest(thread: Int64, limit: Int) throws -> [MessageRow] { try latest(scope: MessageScope(thread: thread), limit: limit) }
    public func before(thread: Int64, key: MessageKey, limit: Int) throws -> [MessageRow] { try before(scope: MessageScope(thread: thread), key: key, limit: limit) }
    public func after(thread: Int64, key: MessageKey, limit: Int) throws -> [MessageRow] { try after(scope: MessageScope(thread: thread), key: key, limit: limit) }
    public func around(thread: Int64, key: MessageKey, before n: Int, after m: Int) throws -> [MessageRow] {
        try around(scope: MessageScope(thread: thread), key: key, before: n, after: m)
    }
    public func firstMessage(thread: Int64, atOrAfter tsMs: Int64) throws -> MessageKey? { try firstMessage(scope: MessageScope(thread: thread), atOrAfter: tsMs) }

    /// An attachment by content hash: the stored file (same path for every message that carries these bytes), or nil when the
    /// archive holds no such attachment. The web app serves media only through this lookup, never from a path parameter.
    public func attachment(sha256: String) throws -> AttachmentInfo? {
        try locked {
            let st = try stmt("SELECT id, mime, filename, media_path, bytes, sha256 FROM attachment WHERE sha256 = ? ORDER BY id LIMIT 1")
            st.bind(1, sha256)
            defer { st.reset() }
            guard try st.step() else { return nil }
            return AttachmentInfo(id: st.int(0), mime: st.string(1), filename: st.string(2), mediaPath: st.string(3) ?? "", bytes: st.int(4), sha256: st.string(5) ?? "")
        }
    }

    /// The key of a message, or nil if it does not exist (or is a duplicate row).
    public func key(ofMessage id: Int64) throws -> (thread: Int64, key: MessageKey)? {
        try locked {
            let st = try stmt("SELECT thread_id, ts_ms FROM message WHERE id = ? AND canonical_id IS NULL")
            st.bind(1, id)
            defer { st.reset() }
            return try st.step() ? (st.int(0), MessageKey(tsMs: st.int(1), id: id)) : nil
        }
    }

    /// Canonical message count of one thread.
    public func messageCount(thread: Int64) throws -> Int {
        try locked {
            let st = try stmt("SELECT count(*) FROM message WHERE thread_id = ? AND canonical_id IS NULL")
            st.bind(1, thread)
            defer { st.reset() }
            return try st.step() ? Int(st.int(0)) : 0
        }
    }

    /// Canonical message count of a scope.
    public func messageCount(scope: MessageScope) throws -> Int {
        try locked {
            let threads = try relevantThreads(scope)
            guard !threads.isEmpty else { return 0 }
            let sql = "SELECT count(*) FROM message m WHERE m.thread_id IN (\(threads.map(String.init).joined(separator: ","))) AND m.canonical_id IS NULL\(serviceClause(scope))"
            let st = try stmt(sql)
            defer { st.reset() }
            return try st.step() ? Int(st.int(0)) : 0
        }
    }

    /// Which text messages of a thread `textSample` picks.
    public enum SampleMode: String, Sendable, CaseIterable { case latest, earliest, spread }

    /// Up to `limit` text-only messages of one thread (a body, no system/call row), oldest first: the newest, the oldest, or
    /// evenly spread across all of the thread's text messages. Also the number of text messages in the thread. Attachments are
    /// not looked at.
    public func textSample(thread: Int64, mode: SampleMode, limit: Int) throws -> (rows: [MessageRow], textCount: Int) {
        try locked {
            let textCond = "m.thread_id = ?1 AND m.canonical_id IS NULL AND m.body IS NOT NULL AND trim(m.body) <> ''" + (hasKind ? " AND m.kind IS NULL" : "")
            let cnt = try stmt("SELECT count(*) FROM message m WHERE \(textCond)")
            cnt.bind(1, thread)
            let total = try cnt.step() ? Int(cnt.int(0)) : 0
            cnt.reset()
            guard total > 0, limit > 0 else { return ([], total) }
            func fetch(order: String, limit: Int, offset: Int) throws -> [MessageRow] {
                let st = try stmt("\(messageSelect) WHERE \(textCond) ORDER BY m.ts_ms \(order), m.id \(order) LIMIT ?2 OFFSET ?3")
                st.bind(1, thread).bind(2, limit).bind(3, offset)
                return try readMessages(st)
            }
            switch mode {
            case .latest: return (try fetch(order: "DESC", limit: limit, offset: 0).reversed(), total)
            case .earliest: return (try fetch(order: "ASC", limit: limit, offset: 0), total)
            case .spread:
                if total <= limit { return (try fetch(order: "ASC", limit: limit, offset: 0), total) }
                var rows: [MessageRow] = []
                for i in 0..<limit {
                    let offset = limit == 1 ? 0 : i * (total - 1) / (limit - 1)
                    rows += try fetch(order: "ASC", limit: 1, offset: offset)
                }
                return (rows, total)
            }
        }
    }

    /// Timestamps of the first and last canonical message of a thread.
    public func messageRange(thread: Int64) throws -> (first: Int64, last: Int64)? {
        try locked {
            let st = try stmt("SELECT min(ts_ms), max(ts_ms) FROM message WHERE thread_id = ? AND canonical_id IS NULL")
            st.bind(1, thread)
            defer { st.reset() }
            guard try st.step(), let lo = st.optInt(0), let hi = st.optInt(1) else { return nil }
            return (lo, hi)
        }
    }

    /// Newest-first ids of messages in a thread that carry an attachment of the given MIME prefix (for example "image/").
    public func messagesWithAttachments(thread: Int64, mimePrefix: String, limit: Int) throws -> [Int64] {
        try locked {
            let st = try stmt("""
                SELECT m.id FROM message m WHERE m.thread_id = ? AND m.canonical_id IS NULL
                AND EXISTS (SELECT 1 FROM attachment a WHERE a.message_id = m.id AND a.mime LIKE ? || '%')
                ORDER BY m.ts_ms DESC, m.id DESC LIMIT ?
                """)
            st.bind(1, thread).bind(2, mimePrefix).bind(3, limit)
            var out: [Int64] = []
            while try st.step() { out.append(st.int(0)) }
            st.reset()
            return out
        }
    }

    // MARK: coverage

    /// Canonical messages per calendar month (local time), optionally for one thread.
    public func monthCounts(thread: Int64? = nil) throws -> [MonthCount] {
        try locked {
            let sql = """
                SELECT CAST(strftime('%Y', ts_ms / 1000, 'unixepoch', 'localtime') AS INTEGER) y,
                       CAST(strftime('%m', ts_ms / 1000, 'unixepoch', 'localtime') AS INTEGER) mo, count(*)
                FROM message WHERE canonical_id IS NULL \(thread == nil ? "" : "AND thread_id = ?") GROUP BY y, mo ORDER BY y, mo
                """
            let st = try stmt(sql)
            if let thread { st.bind(1, thread) }
            var out: [MonthCount] = []
            while try st.step() { out.append(MonthCount(year: Int(st.int(0)), month: Int(st.int(1)), count: Int(st.int(2)))) }
            st.reset()
            return out
        }
    }

    /// Messages per month within a scope (a person's threads, optionally one service).
    public func monthCounts(scope: MessageScope) throws -> [MonthCount] {
        try locked {
            let threads = try relevantThreads(scope)
            guard !threads.isEmpty else { return [] }
            let sql = """
                SELECT CAST(strftime('%Y', ts_ms / 1000, 'unixepoch', 'localtime') AS INTEGER) y,
                       CAST(strftime('%m', ts_ms / 1000, 'unixepoch', 'localtime') AS INTEGER) mo, count(*)
                FROM message m WHERE m.canonical_id IS NULL AND m.thread_id IN (\(threads.map(String.init).joined(separator: ",")))\(serviceClause(scope))
                GROUP BY y, mo ORDER BY y, mo
                """
            let st = try stmt(sql)
            var out: [MonthCount] = []
            while try st.step() { out.append(MonthCount(year: Int(st.int(0)), month: Int(st.int(1)), count: Int(st.int(2)))) }
            st.reset()
            return out
        }
    }

    // MARK: search

    /// Turns what a person typed into a safe FTS5 query: every word is a quoted phrase (so operators and punctuation
    /// are literal), the last word is a prefix match so results appear while typing. Control characters are dropped first
    ///: a NUL ended the bound text early, leaving FTS an unterminated phrase and the web search a 500.
    public static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { w -> String in
            String(String.UnicodeScalarView(w.unicodeScalars.filter { $0 != "\"" && $0.properties.generalCategory != .control }))
        }.filter { w in w.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        guard !words.isEmpty else { return nil }
        var parts = words.map { "\"\($0)\"" }
        parts[parts.count - 1] += "*"
        return parts.joined(separator: " ")
    }

    public func search(_ text: String, thread: Int64? = nil, order: SearchOrder = .bestMatch, limit: Int = 200, offset: Int = 0) throws -> [SearchHit] {
        try search(text, scope: thread.map { MessageScope(thread: $0) }, order: order, limit: limit, offset: offset)
    }

    /// Full-text search, everywhere (`scope` nil) or within a scope's threads and services. Voice messages count as their messages: a
    /// message whose audio's machine transcript matches is a hit (`isVoice`, the snippet from the transcript), merged with the text hits in
    /// the same order (best match: FTS5 rank of either index, then the message id; newest; oldest).
    ///
    /// Paging stays consistent: a message is represented once, by its text hit when its text
    /// matches and by its voice hit only otherwise, whatever page is asked; the voice hits (a few hundred files at most) are read whole and
    /// one per message, the text hits from the top to offset + limit, and the page is cut from the merge.
    public func search(_ text: String, scope: MessageScope?, order: SearchOrder = .bestMatch, limit: Int = 200, offset: Int = 0) throws -> [SearchHit] {
        guard let q = Self.ftsQuery(text) else { return [] }
        return try locked {
            let orderBy: String
            switch order {
            case .bestMatch: orderBy = "ORDER BY rank, m.id"
            case .newest: orderBy = "ORDER BY m.ts_ms DESC, m.id DESC"
            case .oldest: orderBy = "ORDER BY m.ts_ms, m.id"
            }
            var scopeSQL = ""
            if let scope {
                let threads = try relevantThreads(scope)
                if threads.isEmpty { return [] }
                scopeSQL = " AND m.thread_id IN (\(threads.map(String.init).joined(separator: ",")))" + serviceClause(scope)
            }
            let voice = try db.tableExists("voice_message_fts")
            let sql = """
                SELECT m.id, m.thread_id, m.ts_ms, m.is_from_me, h.normalized,
                       (SELECT name FROM contact_name c WHERE c.handle_id = h.id ORDER BY priority DESC, name LIMIT 1),
                       snippet(message_fts, 0, char(1), char(2), '…', 16), m.service, rank
                FROM message_fts JOIN message m ON m.id = message_fts.rowid LEFT JOIN handle h ON h.id = m.sender_handle_id
                WHERE message_fts MATCH ? AND m.canonical_id IS NULL\(scopeSQL)
                \(orderBy) LIMIT ? OFFSET ?
                """
            func read(_ query: String, n: Int, skip: Int, isVoice: Bool) throws -> [(hit: SearchHit, rank: Double)] {
                let st = try stmt(query)
                defer { st.reset() }
                st.bind(1, q)
                st.bind(2, n)
                st.bind(3, skip)
                var out: [(hit: SearchHit, rank: Double)] = []
                while try st.step() {
                    var hit = SearchHit(messageID: st.int(0), threadID: st.int(1), tsMs: st.int(2), isFromMe: st.int(3) != 0,
                                        senderNormalized: st.string(4), senderArchiveName: st.string(5), snippet: st.string(6) ?? "")
                    hit.service = st.string(7) ?? "sms"
                    hit.isVoice = isVoice
                    out.append((hit, st.double(8)))
                }
                return out
            }
            guard voice else { return try read(sql, n: limit, skip: offset, isVoice: false).map(\.hit) }
            // voice hits: every one, the best per message, minus the messages whose text matches too
            var best: [Int64: (hit: SearchHit, rank: Double)] = [:]
            for v in try read(Self.voiceSearchSQL(scopeSQL: scopeSQL, orderBy: orderBy), n: -1, skip: 0, isVoice: true) {
                if let have = best[v.hit.messageID], have.rank <= v.rank { continue }
                best[v.hit.messageID] = v
            }
            if !best.isEmpty {
                let ids = best.keys.map(String.init).joined(separator: ",")
                let st = try stmt("SELECT rowid FROM message_fts WHERE message_fts MATCH ? AND rowid IN (\(ids))")
                defer { st.reset() }
                st.bind(1, q)
                while try st.step() { best[st.int(0)] = nil }
            }
            var out = try read(sql, n: limit + offset, skip: 0, isVoice: false) + Array(best.values)
            out.sort { a, b in
                switch order {
                case .bestMatch: return a.rank != b.rank ? a.rank < b.rank : a.hit.messageID < b.hit.messageID
                case .newest: return a.hit.tsMs != b.hit.tsMs ? a.hit.tsMs > b.hit.tsMs : a.hit.messageID > b.hit.messageID
                case .oldest: return a.hit.tsMs != b.hit.tsMs ? a.hit.tsMs < b.hit.tsMs : a.hit.messageID < b.hit.messageID
                }
            }
            return Array(out.dropFirst(offset).prefix(limit).map(\.hit))
        }
    }
}
