import Foundation

/// The 2011 Facebook "Download Your Information" export:
/// `<root>/README.txt` ("Downloaded by <name> (...) on <date>") and `<root>/html/messages.html`:
///
///     div.thread > div.message[.reply] > span.profile ("A" or "A to B"; span.page when a Facebook Page sent it), span.time ("May 10, 2011 at 9:42 pm"),
///                                         div.msgbody (optional div.subject first; <BR> = newline)
///
/// Only messages the archive does not already hold are written (the 2025 Meta export holds most of them, at second
/// precision; it lacks the opening message of many 2009-2011 conversations and some one-message conversations):
/// - held = a canonical Messenger row within 90 s of the printed minute, same direction, the same text by letters and
///   digits (case-folded), or the same first 30 of them;
/// - times are printed to the minute with no zone. They are read in `zone` (`--zone`; default this machine's zone, or
///   `<PREFIX>_TIME_ZONE`). The export printed times in the account's own zone, and in the one export checked a fixed offset
///   (UTC-04:00 all year, no DST) matched the archive far better than the named zone did, so compare a dry run under both
///   (for example `--zone America/New_York` and `--zone UTC-04:00`) before importing. The minute precision and the
///   rule are recorded in the source's stats_json and in `meta` (`fb-dyi-2011.time_rule`);
/// - a missing message goes into the archive thread that holds the rest of its conversation (found through the
///   conversation's held messages, `ArchiveWriter.threadOverride`); a conversation with nothing held gets the thread a
///   Meta import would key it to (`fb:<folded name>` handles; a group adds `dyi2011-t<n>` to its key);
/// - messages with no text (photo or link only in the original) are not written, only counted;
/// - Wall posts and comments (`html/wall.html`) are not read: the archive has no table for them.
/// Idempotent: the source row is keyed by the sha256 of messages.html, and a re-run would find every written row held.
public struct FacebookDYI2011Stats: Codable, Equatable, Sendable {
    public var conversations = 0
    public var parsed = 0
    public var held = 0                 // already in the archive (skipped)
    public var heldTextDiffers = 0      // held by the 30-character prefix rule (skipped)
    public var emptySkipped = 0         // no text: not written
    public var badTime = 0
    public var inserted = 0
    public var duplicates = 0           // linked by ArchiveWriter's own rule (expected 0)
    public var intoExistingThreads = 0  // messages written into a thread that existed before this import
    public var intoNewThreads = 0       // messages written into a thread this import created
    public var newThreads = 0
    public var newHandles = 0
    public var unplaced = 0             // from me with no recipient anywhere in the conversation
    public var ambiguousThread = 0      // its conversation's held messages point at two archive threads equally: left out
    public var weakEvidence = 0         // candidates exist but establish no thread (one short match, a shared first name, a single deactivated account): left out, listed
    public var senderUnresolved = 0     // a new incoming message in a group whose sender cannot be resolved to a member: left out, listed
    public var duplicateInExport = 0    // the same message carried by two export conversations: written once
    public var openerTimeUnknown = 0    // a conversation's first message printed with a reply's time and not found in the archive: left out, listed
    public var heldLateOpeners = 0      // first messages printed with a reply's time, found in the archive before the first reply
    public var precision = "minute (printed hh:mm)"
    public var firstTsMs: Int64?, lastTsMs: Int64?
}

public struct FacebookDYI2011Report: Sendable {
    public enum Status: Sendable { case imported, alreadyImported, dryRun }
    public var status: Status
    public var me: String
    public var stats: FacebookDYI2011Stats
    /// (message index "t<thread>m<message>", reason) for every message not written: empty, unplaced.
    public var leftOut: [(String, String)] = []
}

public enum FacebookDYI2011Importer {
    public static let kind = "fb-dyi-2011"

    /// A `--zone` value: an IANA name (with DST) or a fixed offset written `UTC-04:00` / `UTC+5:30` / `UTC`.
    public static func zone(named text: String) -> TimeZone? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.uppercased() == "UTC" { return TimeZone(secondsFromGMT: 0) }
        if t.uppercased().hasPrefix("UTC"), t.count > 3 {
            let rest = t.dropFirst(3), sign: Int = rest.first == "-" ? -1 : rest.first == "+" ? 1 : 0
            guard sign != 0 else { return nil }
            let parts = rest.dropFirst().split(separator: ":")
            guard (1...2).contains(parts.count), let h = Int(parts[0]), (0...14).contains(h) else { return nil }
            let m = parts.count == 2 ? Int(parts[1]) : 0
            guard let m, (0..<60).contains(m) else { return nil }
            return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
        }
        return TimeZone(identifier: t)
    }

    /// How a zone is described in the stats and the `meta` time rule: "fixed UTC-04:00" or "America/New_York with DST".
    public static func describe(_ zone: TimeZone) -> String {
        guard TimeZone(identifier: zone.identifier) == nil || zone.identifier.hasPrefix("GMT") || zone.identifier == "UTC" else { return "\(zone.identifier) with DST" }
        let s = zone.secondsFromGMT(), a = abs(s)
        return String(format: "fixed UTC%@%02d:%02d", s < 0 ? "-" : "+", a / 3600, a % 3600 / 60)
    }

    /// The export root (holding `html/messages.html` in the 2011 layout), given the root, its `html` folder or the file.
    public static func detect(_ url: URL) -> URL? {
        let fm = FileManager.default
        for c in [url, url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()] {
            let m = c.appendingPathComponent("html/messages.html")
            guard fm.fileExists(atPath: m.path), let h = try? FileHandle(forReadingFrom: m) else { continue }
            let head = h.readData(ofLength: 8192); try? h.close()
            if String(decoding: head, as: UTF8.self).contains("tabmessages") { return c }
        }
        return nil
    }

    // MARK: parsing

    public struct Message: Sendable {
        public var thread: Int, index: Int
        public var profiles: [String]       // author, then "to" names
        public var timeText: String
        public var subject: String?
        public var body: String
        public var isReply: Bool
        public var author: String { profiles.first ?? "" }
        public var recipients: [String] { Array(profiles.dropFirst()) }
    }

    final class Reader: HTMLScannerDelegate {
        enum Role { case thread, message, body, nested, subject, other }
        var stack: [Role] = []
        var spanRole: String?        // "profile" | "time"
        var spanText = ""
        var title = "", inTitle = false
        var threadIndex = -1, messageIndex = 0
        var cur: Message?
        var out: [Message] = []

        static func cls(_ a: HTMLAttrs) -> Set<String> {
            guard let c = a.cls else { return [] }
            return Set(String(decoding: c, as: UTF8.self).split(separator: " ").map(String.init))
        }

        func startTag(_ tag: HTMLTag, attrs: HTMLAttrs, selfClosing: Bool) {
            switch tag {
            case .title: inTitle = true
            case .div:
                let c = Self.cls(attrs)
                var role = Role.other
                let inBody = stack.contains(.body)
                if inBody && c.contains("subject") && stack.last == .body { role = .subject; cur?.subject = "" }
                else if inBody { role = .nested; cur?.body += "\n" }      // any other div inside the body is body text
                else if c.contains("thread") { role = .thread; threadIndex += 1; messageIndex = 0 }
                else if c.contains("message") {
                    role = .message
                    cur = Message(thread: threadIndex, index: messageIndex, profiles: [], timeText: "", subject: nil, body: "", isReply: c.contains("reply"))
                    messageIndex += 1
                } else if c.contains("msgbody") { role = .body }
                else if c.contains("subject") { role = .subject; cur?.subject = "" }
                if !selfClosing { stack.append(role) }
            case .span:
                // header spans count only outside the body; inside it every span is body text
                guard !stack.contains(.body) else { break }
                let c = Self.cls(attrs)
                if c.contains("profile") || c.contains("page") { spanRole = "profile"; spanText = "" }   // "page": a Facebook Page's broadcast
                else if c.contains("time") { spanRole = "time"; spanText = "" }
            case .br:
                if stack.last == .body || stack.last == .nested { cur?.body += "\n" }
            default: break
            }
        }

        func endTag(_ tag: HTMLTag) {
            switch tag {
            case .title: inTitle = false
            case .span:
                if let r = spanRole {
                    let t = spanText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if r == "profile" { cur?.profiles.append(t) } else { cur?.timeText = t }
                    spanRole = nil
                }
            case .div:
                guard let r = stack.popLast() else { return }
                if r == .message, let m = cur { out.append(m); cur = nil }
                if r == .nested { cur?.body += "\n" }
            default: break
            }
        }

        func text(_ bytes: UnsafeBufferPointer<UInt8>) {
            let s = HTMLEntities.decode(bytes)
            if inTitle { title += s; return }
            if spanRole != nil { spanText += s; return }
            switch stack.last {
            case .subject?: cur?.subject? += s
            case .body?, .nested?: cur?.body += s
            default: break
            }
        }
    }

    public static func parse(_ data: Data) -> (title: String, messages: [Message]) {
        let r = Reader()
        data.withUnsafeBytes { raw in HTMLScanner.scan(raw.bindMemory(to: UInt8.self), delegate: r) }
        let msgs = r.out.map { m -> Message in
            var m = m
            m.body = m.body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            m.subject = m.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
            return m
        }
        return (r.title.trimmingCharacters(in: .whitespacesAndNewlines), msgs)
    }

    /// "May 10, 2011 at 9:42 pm" in `zone` -> Unix ms.
    public static func unixMs(_ text: String, zone: TimeZone) -> Int64? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        guard let d = f.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// Matching key: NFC, case-folded, letters and digits only (scripts/fb_saved_pages.py norm_text).
    public static func matchKey(_ s: String?) -> String {
        let f = (s ?? "").precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        return String(String.UnicodeScalarView(f.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Second key for a text with no letters or digits (emoji, punctuation): NFC with whitespace removed.
    public static func symbolKey(_ s: String?) -> String {
        String((s ?? "").precomposedStringWithCanonicalMapping.unicodeScalars.filter { !$0.properties.isWhitespace }.map(Character.init))
    }

    /// The key two copies of one message share: letters and digits, else the symbol key; empty only for an empty body.
    static func key(_ s: String?) -> String { let k = matchKey(s); return k.isEmpty ? "\u{1}" + symbolKey(s) : k }

    /// "The same message, text differs": one is the other plus a tail (an appended link, a trailing character), the shorter
    /// at least 20 letters and digits. A shared beginning with different endings is not enough.
    static func tailVariant(_ a: String, _ b: String) -> Bool {
        if a == b || a.hasPrefix("\u{1}") || b.hasPrefix("\u{1}") { return false }
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        return s.count >= 20 && l.hasPrefix(s)
    }

    static func isPlaceholder(_ fold: String) -> Bool { fold == "facebook user" || fold == "unknown" || fold.isEmpty }

    /// Name words (3+ letters) of a folded name or an `fb:` handle; a deactivated account has none and is flagged instead.
    static func nameWords(_ foldOrNormalized: String) -> (words: Set<String>, placeholder: Bool) {
        var n = foldOrNormalized.hasPrefix("fb:") ? String(foldOrNormalized.dropFirst(3)) : foldOrNormalized
        if let h = n.firstIndex(of: "#") { n = String(n[..<h]) }
        if isPlaceholder(n) { return ([], true) }
        // split on anything that is not a letter or digit ("Fixture-Phoenix" holds "phoenix")
        let words = n.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        return (Set(words.filter { $0.count >= 3 }), false)
    }

    // MARK: import

    /// One export message's decision, written to the ledger (`--ledger <file>`, TSV, no message text).
    public struct LedgerRow: Sendable {
        public var conv = 0, msg = 0
        public var participants = ""        // the conversation's people, folded, ";"-joined (never me)
        public var direction = ""           // out | in
        public var sender = ""              // folded export sender
        public var printed = ""             // the printed time
        public var tsMs: Int64 = 0          // start of the printed minute, UTC
        public var contentHash = ""         // sha256 (16 hex) of the normalized body
        public var decision = ""            // held | held-text-differs | new | empty | duplicate-in-export | left-out-ambiguous | left-out-weak-evidence | left-out-sender-unresolved | left-out-opener-time-unknown | bad-time
        public var matchKind = ""           // exact | symbol | tail
        public var archiveMessageID = "", archiveGroupID = "", archiveThreadID = "", archiveSender = "", archivePerson = "", dtSeconds = ""
        public var targetThreadID = "", targetThreadExisted = "", targetMembers = "", writtenMessageID = ""
        public var note = ""
        public static let header = "conv\tmsg\tparticipants\tdirection\tsender\tprinted\tts_ms\tcontent_hash\tdecision\tmatch_kind\tarchive_message_id\tarchive_group_id\tarchive_thread_id\tarchive_sender_handle\tarchive_person_id\tdt_seconds\ttarget_thread_id\ttarget_thread_existed\ttarget_members\twritten_message_id\tnote"
        var line: String {
            [String(conv), String(msg), participants, direction, sender, printed, String(tsMs), contentHash, decision, matchKind,
             archiveMessageID, archiveGroupID, archiveThreadID, archiveSender, archivePerson, dtSeconds,
             targetThreadID, targetThreadExisted, targetMembers, writtenMessageID, note]
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }
    }

    /// Does an export name and an archive handle name the same person? The same folded name, both a deactivated account,
    /// or a shared name word of 3+ letters (accounts renamed since 2011 keep a first or last name).
    /// Full-name agreement: the same folded name, or one name's words (2+ of them) all inside the other's
    /// ("anna testcase" in "anna middle testcase"). A shared first name alone is not enough.
    static func fullName(_ exportFold: String, _ handleNormalized: String) -> Bool {
        var h = handleNormalized.hasPrefix("fb:") ? String(handleNormalized.dropFirst(3)) : handleNormalized
        if let i = h.firstIndex(of: "#") { h = String(h[..<i]) }
        if h == exportFold && !isPlaceholder(h) { return true }
        let a = nameWords(exportFold), b = nameWords(h)
        if a.placeholder || b.placeholder { return false }
        let (s, l) = a.words.count <= b.words.count ? (a.words, b.words) : (b.words, a.words)
        return s.count >= 2 && s.isSubset(of: l)
    }

    static func samePerson(_ exportFold: String, _ handleNormalized: String) -> Bool {
        var h = handleNormalized.hasPrefix("fb:") ? String(handleNormalized.dropFirst(3)) : handleNormalized
        if let i = h.firstIndex(of: "#") { h = String(h[..<i]) }
        if h == exportFold { return true }
        let a = nameWords(exportFold), b = nameWords(h)
        if a.placeholder || b.placeholder { return a.placeholder && b.placeholder }
        return !a.words.isDisjoint(with: b.words)
    }

    /// This importer was built, reviewed (four rounds) and audited against one real 2011 export only, so it runs only with
    /// `allowUnverified` (`--allow-unverified-file`): try `--dry-run` first and read its ledger.

    public static func importExport(at root: URL, into db: Database, allowUnverified: Bool = false, zone: TimeZone = LocalZone.current(),
                                    me meOverride: String? = nil, origin: String? = nil,
                                    dryRun: Bool = false, ledger: URL? = nil) throws -> FacebookDYI2011Report {
        let file = root.appendingPathComponent("html/messages.html")
        let data = try Data(contentsOf: file)
        let sha = data.withUnsafeBytes { Hashing.sha256Hex($0) }
        guard allowUnverified else {
            throw ArchiveError("this importer has been checked against one real export only; run it with --dry-run and read the ledger, then pass --allow-unverified-file to use it")
        }
        let (title, msgs) = parse(data)
        let me = meOverride ?? title.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !me.isEmpty else { throw ArchiveError("cannot tell whose export this is (no \"<name> - Messages\" title); pass --me") }
        let meFold = ServiceHandle.foldName(me)

        let have = try db.prepare("SELECT 1 FROM source WHERE sha256 = ?")
        have.bind(1, sha)
        if try have.step() { have.reset(); return FacebookDYI2011Report(status: .alreadyImported, me: me, stats: FacebookDYI2011Stats()) }
        have.reset()

        var stats = FacebookDYI2011Stats()
        stats.precision = "minute (printed hh:mm), read as \(describe(zone))"
        stats.parsed = msgs.count
        stats.conversations = Set(msgs.map { $0.thread }).count
        var report = FacebookDYI2011Report(status: dryRun ? .dryRun : .imported, me: me, stats: stats)
        let fileTag = "dyi2011-" + sha.prefix(12)      // placeholder people are scoped to this file

        // 1. Per message: time (start of the printed minute), key, direction, sender.
        enum State: Equatable { case held, heldTail, new, empty, badTime, ambiguous, weakEvidence, senderUnresolved, dupInExport, openerTimeUnknown }
        var state = [State](repeating: .new, count: msgs.count)
        var tsOf = [Int64](repeating: 0, count: msgs.count)
        let keyOf = msgs.map { key($0.body) }
        let fromMe = msgs.map { ServiceHandle.foldName($0.author) == meFold }
        let senderFold = msgs.map { ServiceHandle.foldName($0.author) }
        var rows = [LedgerRow](repeating: LedgerRow(), count: msgs.count)
        for (i, m) in msgs.enumerated() {
            rows[i].conv = m.thread; rows[i].msg = m.index
            rows[i].direction = fromMe[i] ? "out" : "in"; rows[i].sender = senderFold[i]; rows[i].printed = m.timeText
            rows[i].contentHash = String(Data(Hashing.normalizedBody(m.body).utf8).withUnsafeBytes { Hashing.sha256Hex($0) }.prefix(16))
            guard let ts = unixMs(m.timeText, zone: zone) else { state[i] = .badTime; stats.badTime += 1; continue }
            tsOf[i] = ts; rows[i].tsMs = ts
            if m.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state[i] = .empty; stats.emptySkipped += 1 }
        }
        var people: [Int: [String]] = [:]
        for m in msgs {
            for n in m.profiles where ServiceHandle.foldName(n) != meFold && !n.isEmpty {
                if !(people[m.thread] ?? []).contains(where: { ServiceHandle.foldName($0) == ServiceHandle.foldName(n) }) { people[m.thread, default: []].append(n) }
            }
        }
        let convs = Dictionary(grouping: msgs.indices, by: { msgs[$0].thread })
        // The 2011 export prints a conversation's first message with a later time: in 54 of its 58 multi-message
        // conversations, the time of one of the replies (47 times the last). Only an opener printed before its first reply
        // has its own time (4 cases, all confirmed by the archive to the second). Any other opener's time is unknown, known
        // only to be no later than the first reply.
        var firstReplyTs: [Int: Int64] = [:]
        for (c, idx) in convs {
            if let m = idx.filter({ msgs[$0].index > 0 && state[$0] != .badTime }).map({ tsOf[$0] }).min() { firstReplyTs[c] = m }
        }
        let openerUnknown: [Bool] = msgs.indices.map { i in
            msgs[i].index == 0 && state[i] != .badTime && (firstReplyTs[msgs[i].thread].map { tsOf[i] >= $0 } ?? false)
        }
        for (c, idx) in convs { let p = (people[c] ?? []).map { ServiceHandle.foldName($0) }.joined(separator: ";"); for i in idx { rows[i].participants = p } }

        // Archive rows near a message: any thread, canonical or a linked duplicate, with sender handle and duplicate group.
        struct Row { let id: Int64, group: Int64, thread: Int64, ts: Int64, fromMe: Bool, sender: String, key: String }
        let near = try db.prepare("""
            SELECT m.id, coalesce(m.canonical_id, m.id), m.thread_id, m.ts_ms, m.is_from_me, coalesce(h.normalized, ''), m.body
            FROM message m LEFT JOIN handle h ON h.id = m.sender_handle_id
            WHERE m.service = 'messenger' AND m.ts_ms BETWEEN ? AND ?
            """)
        func rowsNear(_ ts: Int64) throws -> [Row] {
            near.bind(1, ts - 180_000).bind(2, ts + 150_000)
            var out: [Row] = []
            while try near.step() {
                out.append(Row(id: near.int(0), group: near.int(1), thread: near.int(2), ts: near.int(3), fromMe: near.int(4) != 0,
                               sender: near.string(5) ?? "", key: key(near.string(6))))
            }
            near.reset()
            return out
        }
        /// Seconds from the printed minute [ts, ts + 60 s) to the archive time (0 inside it).
        func dist(_ rowTs: Int64, _ ts: Int64) -> Int64 { rowTs < ts ? ts - rowTs : (rowTs >= ts + 60_000 ? rowTs - (ts + 59_999) : 0) }
        let memberQ = try db.prepare("SELECT h.normalized FROM thread_member tm JOIN handle h ON h.id = tm.handle_id WHERE tm.thread_id = ? ORDER BY h.normalized")
        var memberCache: [Int64: [String]] = [:]
        func members(_ t: Int64) throws -> [String] {
            if let m = memberCache[t] { return m }
            memberQ.bind(1, t); var out: [String] = []
            while try memberQ.step() { out.append(memberQ.string(0) ?? "") }
            memberQ.reset(); memberCache[t] = out; return out
        }
        func textRelation(_ a: String, _ b: String) -> String? {
            if a == b { return a.hasPrefix("\u{1}") ? "symbol" : "exact" }
            return tailVariant(a, b) ? "tail" : nil
        }

        // 2. Each conversation's archive thread. A candidate is an archive row with the same text and direction
        // near the printed minute: within 90 s, or up to 180 s before it for a conversation's first message (the 2011 export
        // printed some openers up to two minutes late; replies always fall inside the minute). A thread is established by:
        //   meta-key      a 1:1 conversation whose person's full name keys an existing Meta thread;
        //   full-name     a candidate whose sender (incoming) or thread member (outgoing) has the export person's full
        //                 name (equal, or one name's words all in the other's, 2+ words), with a long text or inside the minute;
        //   corroborated  two or more of the conversation's messages matching two or more distinct archive messages of that
        //                 thread, one of them long (renamed and deactivated accounts; one archive row never counts twice).
        // Exactly one established thread: placed there. Two or more: left out (ambiguous). None, but candidates exist (one
        // short match, a shared first name, a single deactivated account): left out and listed (weak evidence), never placed
        // and never written as new. No candidate anywhere: new, into the thread the Meta importer would key it to.
        var nearRows: [Int: [Row]] = [:]
        for i in msgs.indices where state[i] == .new && !openerUnknown[i] { nearRows[i] = try rowsNear(tsOf[i]) }
        func within(_ i: Int, _ r: Row) -> Int64? {
            if r.ts < tsOf[i] { let before = tsOf[i] - r.ts; return before <= 90_000 ? before : nil }
            let after = r.ts >= tsOf[i] + 60_000 ? r.ts - (tsOf[i] + 59_999) : 0
            return after <= 90_000 ? after : nil
        }
        struct Cand { let i: Int; let r: Row; let kind: String; let d: Int64 }
        var cands: [Int: [Cand]] = [:]
        for i in msgs.indices where state[i] == .new && !openerUnknown[i] {
            for r in nearRows[i] ?? [] where r.fromMe == fromMe[i] {
                guard let kind = textRelation(r.key, keyOf[i]), let d = within(i, r) else { continue }
                cands[i, default: []].append(Cand(i: i, r: r, kind: kind, d: d))
            }
        }
        func long(_ i: Int) -> Bool { matchKey(msgs[i].body).count >= 12 }
        /// Maximum matching between export messages and archive duplicate groups (Kuhn), edges tried closest first.
        func maxMatching(_ edges: [Cand]) -> [Int: Cand] {
            let byMsg = Dictionary(grouping: edges, by: { $0.i }).mapValues { $0.sorted { ($0.d, $0.r.id) < ($1.d, $1.r.id) } }
            var owner: [Int64: Int] = [:], chosen: [Int: Cand] = [:]
            func augment(_ i: Int, _ seen: inout Set<Int64>) -> Bool {
                for e in byMsg[i] ?? [] where !seen.contains(e.r.group) {
                    seen.insert(e.r.group)
                    if let o = owner[e.r.group] { if !augment(o, &seen) { continue } }
                    owner[e.r.group] = i; chosen[i] = e; return true
                }
                return false
            }
            let order = byMsg.keys.sorted { ((byMsg[$0]!.first!.d), tsOf[$0], $0) < ((byMsg[$1]!.first!.d), tsOf[$1], $1) }
            for i in order { var seen = Set<Int64>(); _ = augment(i, &seen) }
            return chosen
        }
        let byKey = try db.prepare("SELECT id FROM thread WHERE key = ?")
        var threadOf: [Int: Int64] = [:]
        var evidence: [Int: String] = [:]
        for (c, idx) in convs {
            let convPeople = (people[c] ?? []).map { ServiceHandle.foldName($0) }
            let cs = idx.flatMap { cands[$0] ?? [] }
            var strong: [Int64: String] = [:]
            for t in Set(cs.map { $0.r.thread }) {
                let inT = cs.filter { $0.r.thread == t }
                let mem = try members(t)
                let named = inT.contains { e in
                    let agree = fromMe[e.i] ? mem.contains { h in convPeople.contains { fullName($0, h) } } : fullName(senderFold[e.i], e.r.sender)
                    return agree && (long(e.i) || e.d == 0 && e.r.ts >= tsOf[e.i])
                }
                let m = maxMatching(inT)
                if named { strong[t] = "full-name" }
                else if m.count >= 2 && m.keys.contains(where: long) { strong[t] = "corroborated (\(m.count) distinct archive messages)" }
            }
            var keyed: Int64?
            if convPeople.count == 1, !isPlaceholder(convPeople[0]) {
                byKey.bind(1, ThreadKey.key(for: [ServiceHandle.facebook(name: people[c]![0]).normalized]))
                if try byKey.step() { keyed = byKey.int(0) }
                byKey.reset()
            }
            if let k = keyed, strong[k] == nil { strong[k] = "meta-key" + (cs.contains { $0.r.thread == k } ? " + match" : "") }
            if strong.count == 1 { threadOf[c] = strong.first!.key; evidence[c] = strong.first!.value; continue }
            if strong.count > 1 {
                for i in idx where state[i] == .new { state[i] = .ambiguous; stats.ambiguousThread += 1
                    rows[i].note = "established in threads " + strong.keys.sorted().map(String.init).joined(separator: ",") }
                continue
            }
            if !cs.isEmpty {
                // describe the weak evidence: thread, text length class, name relation
                let desc = Set(cs.map { e -> String in
                    let rel: String
                    if fromMe[e.i] { rel = "outgoing" }
                    else if e.r.sender.isEmpty { rel = "unlabeled sender" }
                    else if nameWords(e.r.sender).placeholder { rel = "deactivated account" }
                    else if samePerson(senderFold[e.i], e.r.sender) { rel = "shared name word with " + e.r.sender }
                    else { rel = "other person " + e.r.sender }
                    return "thread \(e.r.thread) \(long(e.i) ? "long" : "short") \(rel) row \(e.r.id)"
                }).sorted().joined(separator: "; ")
                for i in idx where state[i] == .new { state[i] = .weakEvidence; stats.weakEvidence += 1; rows[i].note = "weak evidence: " + desc }
            }
        }

        // 3. Held: per established thread, a maximum matching of export messages to archive duplicate groups,
        // exact text first, then tail variants on what is left; incoming rows need their sender: the one member of a 1:1
        // thread; in a group the full name, a sender mapping corroborated by 2+ distinct archive messages, or elimination with
        // exactly one unmatched person on each side (B3). Each archive group answers once across the whole export.
        var senderMap: [Int: [String: String]] = [:]     // conversation -> export sender -> archive handle (corroborated)
        func eliminated(_ c: Int, _ t: Int64) throws -> (export: String, archive: String)? {
            let convPeople = (people[c] ?? []).map { ServiceHandle.foldName($0) }
            let mem = try members(t)
            let ex = convPeople.filter { p in !mem.contains { fullName(p, $0) } }
            let ar = mem.filter { h in !convPeople.contains { fullName($0, h) } }
            return ex.count == 1 && ar.count == 1 ? (ex[0], ar[0]) : nil
        }
        for (c, idx) in convs {
            guard let t = threadOf[c], try members(t).count > 1 else { continue }
            let inT = idx.flatMap { cands[$0] ?? [] }.filter { $0.r.thread == t && !fromMe[$0.i] && $0.kind != "tail" }
            for (s, es) in Dictionary(grouping: inT, by: { senderFold[$0.i] + "\u{1}" + $0.r.sender }) {
                let m = maxMatching(es)
                if m.count >= 2 && m.keys.contains(where: long) {
                    let parts = s.components(separatedBy: "\u{1}")
                    if senderMap[c]?[parts[0]] == nil { senderMap[c, default: [:]][parts[0]] = parts[1] }
                    else if senderMap[c]![parts[0]] != parts[1] { senderMap[c]![parts[0]] = "" }   // two candidates: none
                }
            }
        }
        func senderOK(_ i: Int, _ sender: String, _ t: Int64) throws -> Bool {
            let mem = try members(t)
            if mem.count == 1 { return true }
            if fullName(senderFold[i], sender) { return true }
            if let m = senderMap[msgs[i].thread]?[senderFold[i]], !m.isEmpty, m == sender { return true }
            if let e = try eliminated(msgs[i].thread, t), e.export == senderFold[i], e.archive == sender { return true }
            return false
        }
        var claimed = Set<Int64>()
        let openerQ = try db.prepare("""
            SELECT m.id, coalesce(m.canonical_id, m.id), m.ts_ms, coalesce(h.normalized, ''), m.body FROM message m
            LEFT JOIN handle h ON h.id = m.sender_handle_id WHERE m.thread_id = ? AND m.is_from_me = ? AND m.ts_ms <= ?
            """)
        let personQ = try db.prepare("SELECT ph.person_id FROM person_handle ph JOIN handle h ON h.id = ph.handle_id WHERE h.normalized = ?")
        for t in Set(threadOf.values).sorted() {
            var edges: [Cand] = []
            for i in msgs.indices where state[i] == .new && threadOf[msgs[i].thread] == t {
                for e in cands[i] ?? [] where e.r.thread == t && !claimed.contains(e.r.group) {
                    if !fromMe[i], !(try senderOK(i, e.r.sender, t)) { continue }
                    edges.append(e)
                }
            }
            for pass in ["exact", "tail"] {
                let m = maxMatching(edges.filter { (pass == "exact") == ($0.kind != "tail") && state[$0.i] == .new && !claimed.contains($0.r.group) })
                for (i, e) in m {
                    claimed.insert(e.r.group)
                    if e.kind == "tail" { state[i] = .heldTail; stats.heldTextDiffers += 1 } else { state[i] = .held; stats.held += 1 }
                    rows[i].matchKind = e.kind
                    rows[i].archiveMessageID = String(e.r.id); rows[i].archiveGroupID = String(e.r.group); rows[i].archiveThreadID = String(e.r.thread)
                    rows[i].archiveSender = e.r.sender.isEmpty ? (fromMe[i] ? "(me)" : "(unlabeled)") : e.r.sender
                    if !e.r.sender.isEmpty { personQ.bind(1, e.r.sender); if try personQ.step() { rows[i].archivePerson = String(personQ.int(0)) }; personQ.reset() }
                    rows[i].dtSeconds = String((e.r.ts - tsOf[i]) / 1000)
                }
            }
            // Openers without their own time: the same normalized text and direction in this thread at any time up to the end of the
            // first reply's printed minute, an unclaimed archive message, the sender as for any held match; the latest such
            // row wins (the one closest before the first reply). The real time difference is recorded.
            for i in msgs.indices where state[i] == .new && openerUnknown[i] && threadOf[msgs[i].thread] == t {
                let limit = firstReplyTs[msgs[i].thread]! + 59_999
                openerQ.bind(1, t).bind(2, fromMe[i]).bind(3, limit)
                var found: [Row] = []
                while try openerQ.step() {
                    found.append(Row(id: openerQ.int(0), group: openerQ.int(1), thread: t, ts: openerQ.int(2), fromMe: fromMe[i],
                                     sender: openerQ.string(3) ?? "", key: key(openerQ.string(4))))
                }
                openerQ.reset()
                var best: (Row, String)?
                // the same text only (or the same emoji/punctuation key): without a time, a tail variant is too loose
                for r in found where !claimed.contains(r.group) && r.key == keyOf[i] {
                    let kind = r.key.hasPrefix("\u{1}") ? "symbol" : "exact"
                    if !fromMe[i], !(try senderOK(i, r.sender, t)) { continue }
                    if best == nil || r.ts > best!.0.ts { best = (r, kind) }
                }
                guard let (r, kind) = best else { continue }
                claimed.insert(r.group); stats.heldLateOpeners += 1
                if kind == "tail" { state[i] = .heldTail; stats.heldTextDiffers += 1 } else { state[i] = .held; stats.held += 1 }
                rows[i].matchKind = kind + " (opener time unknown: matched before the first reply)"
                rows[i].archiveMessageID = String(r.id); rows[i].archiveGroupID = String(r.group); rows[i].archiveThreadID = String(t)
                rows[i].archiveSender = r.sender.isEmpty ? (fromMe[i] ? "(me)" : "(unlabeled)") : r.sender
                if !r.sender.isEmpty { personQ.bind(1, r.sender); if try personQ.step() { rows[i].archivePerson = String(personQ.int(0)) }; personQ.reset() }
                rows[i].dtSeconds = String((r.ts - tsOf[i]) / 1000)
            }
        }
        // An opener without its own time that is still unmatched is never written at a reply's time: left out and listed
        // (a message whose time is unknown is never stored at a guessed time).
        for i in msgs.indices where state[i] == .new && openerUnknown[i] {
            state[i] = .openerTimeUnknown; stats.openerTimeUnknown += 1
            let first = msgs.indices.filter { msgs[$0].thread == msgs[i].thread && msgs[$0].index > 0 }.min { tsOf[$0] < tsOf[$1] }!
            rows[i].note = "opener time unknown: \(matchKey(msgs[i].body).count) letters and digits; thread "
                + (threadOf[msgs[i].thread].map(String.init) ?? "none (new conversation)") + "; first reply printed \(msgs[first].timeText)"
        }

        // 3b. The sender of every new incoming message in an existing thread is decided now, so the dry run shows it: the one
        // member of a 1:1 thread; in a group the member with the full name, the corroborated mapping, or the one member left by
        // elimination. Otherwise the message is left out and listed.
        var senderOf: [Int: String] = [:]
        for i in msgs.indices where state[i] == .new && !fromMe[i] {
            guard let t = threadOf[msgs[i].thread] else { continue }
            let mem = try members(t)
            var h: String?
            if mem.count == 1 { h = mem[0] }
            else if let f = mem.first(where: { fullName(senderFold[i], $0) }) { h = f }
            else if let m = senderMap[msgs[i].thread]?[senderFold[i]], !m.isEmpty, mem.contains(m) { h = m }
            else if let e = try eliminated(msgs[i].thread, t), e.export == senderFold[i] { h = e.archive }
            if let h { senderOf[i] = h } else { state[i] = .senderUnresolved; stats.senderUnresolved += 1; rows[i].note = "sender not resolvable in group thread \(t)" }
        }

        // 3c. One message carried by two export conversations (a broadcast filed twice): written once.
        var firstOf: [String: Int] = [:]
        for i in msgs.indices.sorted(by: { (tsOf[$0], $0) < (tsOf[$1], $1) }) where state[i] == .new {
            let c = msgs[i].thread
            let target: String
            if let t = threadOf[c] { target = "t\(t)" }
            else {
                let ps = (people[c] ?? []).map { ServiceHandle.foldName($0) }.sorted()
                guard ps.count == 1, !isPlaceholder(ps[0]) else { continue }       // groups and placeholders get their own thread
                target = "p:" + ps[0]
            }
            let k = [target, fromMe[i] ? "out" : "in", senderFold[i], keyOf[i], String(tsOf[i])].joined(separator: "\u{1}")
            if let first = firstOf[k] {
                state[i] = .dupInExport; stats.duplicateInExport += 1
                rows[i].note = "same message as t\(msgs[first].thread)m\(msgs[first].index) (another export conversation)"
            } else { firstOf[k] = i }
        }

        for (i, m) in msgs.enumerated() where rows[i].note.isEmpty {
            if let t = threadOf[m.thread] { rows[i].note = "thread \(t) by " + (evidence[m.thread] ?? "?") }
        }
        for (i, m) in msgs.enumerated() {
            let id = "t\(m.thread)m\(m.index)"
            switch state[i] {
            case .held: rows[i].decision = "held"
            case .heldTail: rows[i].decision = "held-text-differs"
            case .new: rows[i].decision = "new"
            case .empty: rows[i].decision = "empty"; report.leftOut.append((id, "no text"))
            case .badTime: rows[i].decision = "bad-time"; report.leftOut.append((id, "unreadable time"))
            case .ambiguous: rows[i].decision = "left-out-ambiguous"; report.leftOut.append((id, "established in two archive threads"))
            case .weakEvidence: rows[i].decision = "left-out-weak-evidence"; report.leftOut.append((id, "weak evidence only"))
            case .senderUnresolved: rows[i].decision = "left-out-sender-unresolved"; report.leftOut.append((id, "group sender not resolvable"))
            case .dupInExport: rows[i].decision = "duplicate-in-export"; report.leftOut.append((id, "same message in another export conversation"))
            case .openerTimeUnknown: rows[i].decision = "left-out-opener-time-unknown"; report.leftOut.append((id, "opener printed with a reply's time, not in the archive"))
            }
        }
        let toWrite = msgs.indices.filter { state[$0] == .new }.sorted { (tsOf[$0], $0) < (tsOf[$1], $1) }

        func person(_ name: String, _ conv: Int) -> ServiceHandle {
            ServiceHandle.facebook(name: name, unique: isPlaceholder(ServiceHandle.foldName(name)) ? "\(fileTag)-t\(conv)" : nil)
        }
        func writeLedger() throws {
            guard let ledger else { return }
            let text = ([LedgerRow.header] + rows.map { $0.line }).joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: ledger)
        }

        if dryRun {
            report.stats = stats
            for i in toWrite {
                if let t = threadOf[msgs[i].thread] {
                    report.stats.intoExistingThreads += 1
                    rows[i].targetThreadID = String(t); rows[i].targetThreadExisted = "yes"; rows[i].targetMembers = try members(t).joined(separator: ";")
                } else {
                    report.stats.intoNewThreads += 1
                    rows[i].targetThreadID = "(new)"; rows[i].targetThreadExisted = "no"
                    rows[i].targetMembers = (people[msgs[i].thread] ?? []).map { person($0, msgs[i].thread).normalized }.sorted().joined(separator: ";")
                }
            }
            try writeLedger()
            return report
        }

        // 4. Write. The writer never links these rows to existing ones: the decisions above are final.
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origin ?? file.path).bind(3, sha).bind(4, Int64(data.count)).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind)
            writer.skipDuplicateCheck = true
            let handleExists = try db.prepare("SELECT 1 FROM handle WHERE normalized = ?")
            func exists(_ v: String) throws -> Bool { handleExists.bind(1, v); defer { handleExists.reset() }; return try handleExists.step() }
            let maxThread = try db.scalarInt("SELECT coalesce(max(id), 0) FROM thread")
            var touchedNew = Set<Int64>()

            for i in toWrite {
                let m = msgs[i], ts = tsOf[i]
                var rec = MessageRecord(participants: [], sender: nil, tsMs: ts, isFromMe: fromMe[i], service: "messenger",
                                        body: m.body, subject: m.subject?.isEmpty == false ? m.subject : nil, sourceKey: nil, attachments: [])
                if let t = threadOf[m.thread] {
                    writer.threadOverride = t
                    writer.groupKeySuffix = nil
                    if !fromMe[i] {
                        guard let h = senderOf[i] else { throw ArchiveError("internal: no sender decided for t\(m.thread)m\(m.index)") }
                        rec.senderHandle = ServiceHandle(kind: .facebookName, normalized: h, raw: m.author)
                    }
                } else {
                    writer.threadOverride = nil
                    let others = people[m.thread] ?? []
                    if others.isEmpty { stats.unplaced += 1; report.leftOut.append(("t\(m.thread)m\(m.index)", "no recipient")); rows[i].decision = "left-out-no-recipient"; continue }
                    rec.participantHandles = others.map { person($0, m.thread) }
                    writer.groupKeySuffix = others.count > 1 ? "\(fileTag)-t\(m.thread)" : nil
                    if !fromMe[i] { rec.senderHandle = person(m.author, m.thread) }
                }
                var fresh: [ServiceHandle] = []
                for h in rec.participantHandles + (rec.senderHandle.map { [$0] } ?? []) where !fresh.contains(h) {
                    if !(try exists(h.normalized)) { fresh.append(h) }
                }
                let existedBefore = writer.threadOverride != nil
                switch try writer.add(rec) {
                case .inserted: stats.inserted += 1
                case .duplicate: stats.duplicates += 1
                }
                rows[i].writtenMessageID = String(db.lastInsertRowID)
                for h in fresh {
                    stats.newHandles += 1
                    try writer.noteName(service: h, name: h.raw, origin: "facebook-dyi-2011", priority: ContactPriority.androidXML)
                }
                let t = writer.lastThreadID
                if t > maxThread { touchedNew.insert(t); stats.intoNewThreads += 1 } else { stats.intoExistingThreads += 1 }
                rows[i].targetThreadID = String(t)
                rows[i].targetThreadExisted = (existedBefore || t <= maxThread) ? "yes" : "no"
                memberCache[t] = nil
                rows[i].targetMembers = try members(t).joined(separator: ";")
                stats.firstTsMs = min(stats.firstTsMs ?? ts, ts); stats.lastTsMs = max(stats.lastTsMs ?? ts, ts)
            }
            stats.newThreads = touchedNew.count
            let up = try db.prepare("UPDATE thread SET service = 'messenger', origin = 'inbox' WHERE id = ?")
            for t in touchedNew { up.bind(1, t); try up.run() }
            let setMeta = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)")
            setMeta.bind(1, "\(kind).time_rule").bind(2, "printed minute, read as \(describe(zone))")
            try setMeta.run()
            let st = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try st.run()
        }
        report.stats = stats
        try writeLedger()
        return report
    }

    public struct PeopleIndexError: Error, CustomStringConvertible {
        public var underlying: String
        public var description: String {
            "the messages are stored, but rebuilding the people index failed: \(underlying). Run the same command again: it skips the import and rebuilds the index."
        }
    }

    /// The import plus the people rematch, as `archivectl fb-dyi-2011-import` runs it. The rematch runs on every
    /// call, also when the export was already imported, so a rerun repairs an index a failed rematch left behind; its failure
    /// is thrown, never swallowed.
    public static func importAndRematch(at root: URL, into db: Database, allowUnverified: Bool = false, zone: TimeZone = LocalZone.current(),
                                        me: String? = nil, origin: String? = nil, ledger: URL? = nil)
        throws -> (import: FacebookDYI2011Report, people: PeopleStore.RematchReport) {
        let r = try importExport(at: root, into: db, allowUnverified: allowUnverified, zone: zone, me: me, origin: origin, ledger: ledger)
        do { return (r, try PeopleStore.rematch(db: db)) }
        catch { throw PeopleIndexError(underlying: "\(error)") }
    }
}
