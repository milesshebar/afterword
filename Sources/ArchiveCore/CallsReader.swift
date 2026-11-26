import Foundation

// Read side of the `call` table (CallImporter): the call lines a timeline shows at their time, and a call count per person.
// Read-only, like the rest of ArchiveReader; an archive without the table reads as having no calls.
//
// Which calls: canonical rows only (`canonical_id IS NULL`, one row per call however many logs hold it). A call belongs to a handle by
// its `handle_id`, or, when the import found no handle (the number reached the archive later), by its address matching a handle's
// normalized form now (about one call in twelve on a real archive). A timeline's calls are those of the handles of its 1:1
// threads; a group thread has none. Messenger, Instagram and GroupMe calls are already lines in their threads (`message.kind = 'call'`,
// the call row's `message_id`), so the timeline leaves them out, and the count includes them.

/// One call as a timeline line.
public struct CallRow: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var tsMs: Int64
    public var durationS: Int64
    /// `in` | `out`
    public var direction: String
    /// answered | missed | declined | voicemail | blocked | cancelled
    public var outcome: String
    /// phone | facetime-audio | facetime-video | whatsapp | skype | viber | google-voice | google-meet | other-app ...
    public var service: String
    /// The log the winning row came from (iphone-2026, mac, android-xml ...).
    public var sourceLabel: String
    public var isFromMe: Bool { direction == "out" }

    public init(id: Int64, tsMs: Int64, durationS: Int64, direction: String, outcome: String, service: String, sourceLabel: String) {
        self.id = id; self.tsMs = tsMs; self.durationS = durationS; self.direction = direction; self.outcome = outcome
        self.service = service; self.sourceLabel = sourceLabel
    }

    /// The message service whose filter chip shows this call (phone calls with SMS, FaceTime with iMessage); nil = only when unfiltered.
    public var serviceKey: ServiceKey? { Self.serviceKey(callService: service) }

    /// The call services that have a chip (the rest show only in an unfiltered timeline).
    public static let knownServices = ["phone", "google-voice", "facetime-audio", "facetime-video", "whatsapp", "skype", "messenger", "instagram", "groupme"]

    public static func serviceKey(callService s: String) -> ServiceKey? {
        switch s {
        case "phone", "google-voice": return .sms
        case "facetime-audio", "facetime-video": return .imessage
        case "whatsapp": return .whatsapp
        case "skype": return .skype
        case "messenger": return .messenger
        case "instagram": return .instagram
        case "groupme": return .groupme
        default: return nil
        }
    }

    /// "phone call", "FaceTime video call", "WhatsApp call" ...
    public var noun: String {
        switch service {
        case "phone": return "phone call"
        case "facetime-audio": return "FaceTime audio call"
        case "facetime-video": return "FaceTime video call"
        case "whatsapp": return "WhatsApp call"
        case "skype": return "Skype call"
        case "viber": return "Viber call"
        case "google-voice": return "Google Voice call"
        case "google-meet": return "Google Meet call"
        case "messenger": return "Messenger call"
        case "instagram": return "Instagram call"
        case "groupme": return "GroupMe call"
        default: return "call"
        }
    }

    /// The line the apps show: "Outgoing phone call · 12 min", "Missed FaceTime video call", "Outgoing WhatsApp call, no answer".
    public var label: String {
        let n = noun
        switch outcome {
        case "answered":
            let head = (isFromMe ? "Outgoing " : "Incoming ") + n
            return durationS > 0 ? head + " · " + Self.duration(durationS) : head
        case "missed":
            return isFromMe ? "Outgoing \(n), no answer" : "Missed \(n)"
        case "declined": return isFromMe ? "Outgoing \(n), declined" : "Declined \(n)"
        case "voicemail": return "Missed \(n) (voicemail)"
        case "blocked": return "Blocked \(n)"
        case "cancelled": return isFromMe ? "Cancelled \(n)" : "Missed \(n)"
        default: return (isFromMe ? "Outgoing " : "Incoming ") + n
        }
    }

    /// 45 s, 12 min, 1 h 5 min.
    public static func duration(_ s: Int64) -> String {
        if s < 60 { return "\(s) s" }
        let m = (s + 30) / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

/// Calls with someone: how many (every service, Messenger and Instagram included), how many were answered, and time talked.
public struct CallCount: Sendable, Hashable {
    public var calls = 0
    public var answered = 0
    public var seconds: Int64 = 0
    public var firstTsMs: Int64?
    public var lastTsMs: Int64?
    public init() {}

    public mutating func add(_ o: CallCount) {
        calls += o.calls; answered += o.answered; seconds += o.seconds
        if let f = o.firstTsMs { firstTsMs = min(firstTsMs ?? f, f) }
        if let l = o.lastTsMs { lastTsMs = max(lastTsMs ?? l, l) }
    }

    /// The total over some handles of a per-handle table.
    public static func sum(_ handles: some Sequence<Int64>, in byHandle: [Int64: CallCount]) -> CallCount {
        var c = CallCount()
        for h in Set(handles) { if let x = byHandle[h] { c.add(x) } }
        return c
    }

    /// "56 calls", "56 calls · 14 h talked" (nil for none).
    public var summary: String? {
        guard calls > 0 else { return nil }
        let head = calls == 1 ? "1 call" : "\(calls.formatted()) calls"
        if seconds < 60 { return head }
        // ten hours or more: whole hours ("317 h talked", not "317 h 16 min")
        let talked = seconds >= 36_000 ? "\((seconds + 1_800) / 3_600) h" : CallRow.duration(seconds)
        return head + " · " + talked + " talked"
    }
}

/// The time span of a timeline's calls. nil = open on that side.
public struct CallSpan: Sendable, Hashable {
    public var lower: Int64?
    public var lowerInclusive: Bool
    public var upper: Int64?
    public var upperInclusive: Bool
    public init(lower: Int64?, lowerInclusive: Bool = true, upper: Int64?, upperInclusive: Bool = true) {
        self.lower = lower; self.lowerInclusive = lowerInclusive; self.upper = upper; self.upperInclusive = upperInclusive
    }
    public static let all = CallSpan(lower: nil, upper: nil)

    /// The span a window of messages covers: from its first to its last message, open on a side whose end of the conversation it reached
    /// (calls before the first message or after the last one belong to the edge windows). An empty window covers everything.
    public static func window(firstTs: Int64?, lastTs: Int64?, reachedStart: Bool, reachedEnd: Bool) -> CallSpan {
        guard let firstTs, let lastTs else { return .all }
        return CallSpan(lower: reachedStart ? nil : firstTs, upper: reachedEnd ? nil : lastTs)
    }

    public func contains(_ ts: Int64) -> Bool {
        if let l = lower, lowerInclusive ? ts < l : ts <= l { return false }
        if let u = upper, upperInclusive ? ts > u : ts >= u { return false }
        return true
    }
}

extension ArchiveReader {
    /// True when the archive has the call table (and so calls to show).
    public func hasCalls() throws -> Bool {
        try locked { try db.tableExists("call") }
    }

    /// Calls per handle (canonical rows; a call with no stored handle counts for the handle its address matches now).
    public func callCountsByHandle() throws -> [Int64: CallCount] {
        try locked {
            guard try db.tableExists("call") else { return [:] }
            let st = try stmt("""
                SELECT coalesce(c.handle_id, h.id) AS hid, count(*), sum(c.outcome = 'answered'), coalesce(sum(c.duration_s), 0), min(c.ts_ms), max(c.ts_ms)
                FROM call c LEFT JOIN handle h ON c.handle_id IS NULL AND h.normalized = c.address
                WHERE c.canonical_id IS NULL GROUP BY hid
                """)
            var out: [Int64: CallCount] = [:]
            while try st.step() {
                guard let h = st.optInt(0) else { continue }
                var c = CallCount()
                c.calls = Int(st.int(1)); c.answered = Int(st.int(2)); c.seconds = st.int(3); c.firstTsMs = st.optInt(4); c.lastTsMs = st.optInt(5)
                out[h] = c
            }
            st.reset()
            return out
        }
    }

    /// The handles whose calls a scope shows: the members of its 1:1 threads (a group thread has none).
    public func callHandles(scope: MessageScope) throws -> [(id: Int64, normalized: String)] {
        try locked { try callHandlesLocked(scope) }
    }

    private func callHandlesLocked(_ scope: MessageScope) throws -> [(id: Int64, normalized: String)] {
        guard !scope.threadIDs.isEmpty else { return [] }
        let ids = scope.threadIDs.map(String.init).joined(separator: ",")
        let st = try stmt("""
            SELECT DISTINCT h.id, h.normalized FROM thread t JOIN thread_member tm ON tm.thread_id = t.id JOIN handle h ON h.id = tm.handle_id
            WHERE t.id IN (\(ids)) AND t.is_group = 0 ORDER BY h.id
            """)
        var out: [(Int64, String)] = []
        while try st.step() { out.append((st.int(0), st.string(1) ?? "")) }
        st.reset()
        return out
    }

    /// The call lines of a scope within `span`, oldest first: canonical calls with the scope's 1:1 handles, not already a message line
    /// (Messenger, Instagram, GroupMe). With a service filter, only calls whose chip is on (phone calls with SMS, FaceTime with iMessage).
    /// At most `limit` (the ones nearest the closed side of the span; the newest when it is open on both).
    public func calls(scope: MessageScope, in span: CallSpan, limit: Int = 2000) throws -> [CallRow] {
        try locked {
            guard try db.tableExists("call") else { return [] }
            let handles = try callHandlesLocked(scope)
            guard !handles.isEmpty else { return [] }
            var cond = "c.canonical_id IS NULL AND c.message_id IS NULL"
            cond += " AND (c.handle_id IN (\(handles.map { String($0.id) }.joined(separator: ",")))"
            cond += " OR (c.handle_id IS NULL AND c.address IN (\(handles.map { _ in "?" }.joined(separator: ",")))))"
            if scope.serviceFiltered, let filter = scope.services {
                let allowed = CallRow.knownServices.filter { CallRow.serviceKey(callService: $0).map(filter.contains) ?? false }
                cond += allowed.isEmpty ? " AND 0" : " AND c.service IN (\(allowed.map { "'\($0)'" }.joined(separator: ",")))"
            }
            if span.lower != nil { cond += span.lowerInclusive ? " AND c.ts_ms >= ?" : " AND c.ts_ms > ?" }
            if span.upper != nil { cond += span.upperInclusive ? " AND c.ts_ms <= ?" : " AND c.ts_ms < ?" }
            // Keep the calls next to the window's messages when the limit bites: walk away from the closed side.
            let newestFirst = span.lower == nil
            let sql = """
                SELECT c.id, c.ts_ms, c.duration_s, c.direction, c.outcome, c.service, c.source_label FROM call c WHERE \(cond)
                ORDER BY c.ts_ms \(newestFirst ? "DESC" : "ASC"), c.id \(newestFirst ? "DESC" : "ASC") LIMIT \(max(0, limit))
                """
            let st = try db.prepare(sql)   // not cached: one statement per handle count and span shape is cheap and rare
            var i: Int32 = 1
            for h in handles { st.bind(i, h.normalized); i += 1 }
            if let l = span.lower { st.bind(i, l); i += 1 }
            if let u = span.upper { st.bind(i, u); i += 1 }
            var rows: [CallRow] = []
            while try st.step() {
                rows.append(CallRow(id: st.int(0), tsMs: st.int(1), durationS: st.int(2), direction: st.string(3) ?? "in", outcome: st.string(4) ?? "answered",
                                service: st.string(5) ?? "phone", sourceLabel: st.string(6) ?? ""))
            }
            return newestFirst ? rows.reversed() : rows
        }
    }

    /// Calls with the handles of a scope's 1:1 threads, every service (the header's count).
    public func callCount(scope: MessageScope) throws -> CallCount {
        let handles = try callHandles(scope: scope).map(\.id)
        return CallCount.sum(handles, in: try callCountsByHandle())
    }
}
