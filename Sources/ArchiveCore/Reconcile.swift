import Foundation

/// Maintenance passes over an archive that was imported before a dedup rule existed. Imports apply the same rules as they
/// run; this applies them to rows already stored, without re-reading any source file.
public enum Reconciler {
    public struct Report: Sendable {
        public var examined = 0          // non-iPhone canonical rows looked at
        public var linked = 0            // of those, folded under an iPhone canonical
        public var movedDuplicates = 0   // rows that already pointed at a folded row and now follow it
    }

    /// Links canonical Android rows to the iPhone row they are a flattened copy of when the texts differ only by emoji (the
    /// transfer tool that turned late-2016 iMessages into SMS dropped them; an emoji-only message became an empty one).
    /// Same thread, same direction, within 2 s, and the iPhone row is not already the copy of another Android row.
    public static func relinkEmojiStrippedCopies(db: Database, progress: ((Int) -> Void)? = nil) throws -> Report {
        var report = Report()
        let rows = try db.prepare("""
            SELECT m.id, m.thread_id, m.ts_ms, m.is_from_me, m.body, m.content_hash, m.att_hash FROM message m
            JOIN source s ON s.id = m.source_id
            WHERE m.canonical_id IS NULL AND s.kind NOT LIKE 'ios%' ORDER BY m.id
            """)
        let cand = try db.prepare("""
            SELECT c.id, c.content_hash, c.body, c.ts_ms FROM message c JOIN source cs ON cs.id = c.source_id
            WHERE c.thread_id = ? AND c.ts_ms BETWEEN ? AND ? AND c.is_from_me = ? AND c.canonical_id IS NULL AND cs.kind LIKE 'ios%'
              AND NOT EXISTS (SELECT 1 FROM message d JOIN source ds ON ds.id = d.source_id
                              WHERE d.canonical_id = c.id AND ds.kind NOT LIKE 'ios%')
            """)
        let move = try db.prepare("UPDATE message SET canonical_id = ? WHERE id = ? OR canonical_id = ?")
        let moved = try db.prepare("SELECT count(*) FROM message WHERE canonical_id = ?")
        var claimed = Set<Int64>()
        try db.transaction {
            while try rows.step() {
                report.examined += 1
                if report.examined % 20_000 == 0 { progress?(report.examined) }
                let id = rows.int(0), thread = rows.int(1), ts = rows.int(2), mine = rows.int(3)
                let hash = rows.int(5)
                let stripped = Hashing.strippedBodyHash(rows.string(4))
                var best: (id: Int64, dt: Int64)?
                cand.bind(1, thread).bind(2, ts - 2000).bind(3, ts + 2000).bind(4, mine)
                while try cand.step() {
                    let cid = cand.int(0)
                    if claimed.contains(cid) { continue }
                    let same = cand.int(1) == hash || Hashing.strippedBodyHash(cand.string(2)) == stripped
                    if !same { continue }
                    let dt = abs(cand.int(3) - ts)
                    if best == nil || dt < best!.dt { best = (cid, dt) }
                }
                cand.reset()
                guard let b = best else { continue }
                claimed.insert(b.id)
                moved.bind(1, id)
                if try moved.step() { report.movedDuplicates += Int(moved.int(0)) }
                moved.reset()
                move.bind(1, b.id).bind(2, id).bind(3, id)
                try move.run()
                report.linked += 1
            }
        }
        return report
    }
}

/// `archivectl reclassify`: applies the importers' system-line and tapback rules to rows already stored, with no re-import.
/// Idempotent: a row it rewrote no longer matches. Runs in one transaction, so a failure leaves the archive as it was.
public enum Reclassifier {
    public struct Report: Sendable {
        public var igExamined = 0
        public var igTranslated = 0, igFallback = 0
        public var igByKind: [String: Int] = [:]
        public var twinsHidden = 0, twinsKept = 0     // 'X liked a message' lines that duplicate a real heart under a bubble / the rest
        public var tapbackExamined = 0
        public var tapbackResolved = 0           // reaction rows inserted
        public var tapbackRemovalsApplied = 0    // "Removed a …": a matching reaction deleted
        public var tapbackRemovalsNoMatch = 0    // resolved, but there was no reaction to remove (the text row is still hidden)
        public var tapbackUnresolved = 0         // quote not found: kept visible as a system line
        public var unresolvedByService: [String: Int] = [:]
    }

    public static func run(db: Database, dryRun: Bool = false) throws -> Report {
        var report = Report()
        try db.exec("SAVEPOINT reclassify")
        do {
            try instagram(db: db, report: &report)
            try tapbacks(db: db, report: &report)
            try likeTwins(db: db, report: &report)
            try db.exec(dryRun ? "ROLLBACK TO reclassify" : "RELEASE reclassify")
            if dryRun { try db.exec("RELEASE reclassify") }
        } catch {
            try? db.exec("ROLLBACK TO reclassify")
            try? db.exec("RELEASE reclassify")
            throw error
        }
        return report
    }

    // MARK: Instagram's Burmese system lines

    private static func instagram(db: Database, report: inout Report) throws {
        let rows = try db.prepare("""
            SELECT m.id, m.is_from_me, m.body, m.note, m.kind, h.raw
            FROM message m JOIN thread t ON t.id = m.thread_id LEFT JOIN handle h ON h.id = m.sender_handle_id
            WHERE t.service = 'instagram' AND (m.body GLOB '*[က-႟]*' OR m.note GLOB '*[က-႟]*') ORDER BY m.id
            """)
        struct Fix { var id: Int64; var kind: String; var note: String }
        var fixes: [Fix] = []
        while try rows.step() {
            report.igExamined += 1
            let text = rows.string(2) ?? rows.string(3) ?? ""
            var line = text
            // A call row caught by its duration already has the Burmese line plus " (3:04)"; keep the span.
            var suffix = ""
            if rows.string(2) == nil, rows.string(4) == "call", text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
                suffix = String(text[open.lowerBound...]); line = String(text[..<open.lowerBound])
            }
            let sender = rows.int(1) != 0 ? nil : rows.string(5)
            guard let t = InstagramSystemLines.translate(line, actor: sender, isMe: rows.int(1) != 0) else { continue }
            if t.fallback { report.igFallback += 1 } else { report.igTranslated += 1 }
            report.igByKind[t.kind, default: 0] += 1
            fixes.append(Fix(id: rows.int(0), kind: t.kind, note: t.note + suffix))
        }
        let up = try db.prepare("UPDATE message SET kind = ?, note = ?, body = NULL WHERE id = ?")
        for f in fixes { up.bind(1, f.kind).bind(2, f.note).bind(3, f.id); try up.run() }
    }

    // MARK: Instagram like lines that repeat a real reaction

    /// Instagram writes both the heart under the liked message (imported as a `reaction` row) and a pointer-less "X liked a message" /
    /// "X reacted ❤️ to your message" line. Per thread and person, as many lines as there are real reactions by them are hidden
    /// (earliest first; the lines are identical, so which ones is arbitrary): demoted to the nearest earlier visible message
    /// with `kind = 'like-twin'`, text kept. Lines beyond the reaction count stay visible. Idempotent: hidden twins count toward the total.
    private static func likeTwins(db: Database, report: inout Report) throws {
        let lines = try db.prepare("""
            SELECT m.id, m.thread_id, CASE WHEN m.is_from_me THEN -1 ELSE m.sender_handle_id END, m.kind FROM message m
            JOIN thread t ON t.id = m.thread_id
            WHERE t.service = 'instagram' AND ((m.kind = 'system' AND m.canonical_id IS NULL AND (m.note LIKE '% liked a message' OR m.note LIKE '% reacted % to your message'))
                                              OR m.kind = 'like-twin')
            ORDER BY m.thread_id, m.ts_ms, m.id
            """)
        var byActor: [String: [(id: Int64, hidden: Bool)]] = [:]
        var keys: [String] = []
        var threadOf: [Int64: Int64] = [:]
        while try lines.step() {
            let k = "\(lines.int(1))|\(lines.optInt(2).map(String.init) ?? "nil")"
            if byActor[k] == nil { keys.append(k) }
            byActor[k, default: []].append((lines.int(0), lines.string(3) == "like-twin"))
            threadOf[lines.int(0)] = lines.int(1)
        }
        let count = try db.prepare("""
            SELECT count(*) FROM reaction r JOIN message m ON m.id = r.message_id
            WHERE m.thread_id = ?1 AND ((?2 = -1 AND r.by_me = 1) OR (?2 <> -1 AND r.actor_handle_id = ?2))
            """)
        let anchor = try db.prepare("""
            SELECT id FROM message WHERE thread_id = ?1 AND canonical_id IS NULL AND ts_ms <= ?2 AND id <> ?3
              AND kind IS NULL ORDER BY ts_ms DESC, id DESC LIMIT 1
            """)
        let tsOf = try db.prepare("SELECT ts_ms FROM message WHERE id = ?")
        let hide = try db.prepare("UPDATE message SET kind = 'like-twin', canonical_id = ? WHERE id = ?")
        let follow = try db.prepare("UPDATE message SET canonical_id = ? WHERE canonical_id = ?")
        for k in keys {
            let parts = k.split(separator: "|").map(String.init)
            guard let thread = Int64(parts[0]), parts[1] != "nil", let actor = Int64(parts[1]) else {
                report.twinsKept += byActor[k]!.filter { !$0.hidden }.count; continue
            }
            count.bind(1, thread).bind(2, actor)
            _ = try count.step(); let reactions = Int(count.int(0)); count.reset()
            let all = byActor[k]!
            var toHide = max(0, min(all.count, reactions) - all.filter { $0.hidden }.count)
            for l in all where !l.hidden {
                if toHide == 0 { report.twinsKept += 1; continue }
                tsOf.bind(1, l.id); _ = try tsOf.step(); let ts = tsOf.int(0); tsOf.reset()
                anchor.bind(1, thread).bind(2, ts).bind(3, l.id)
                guard try anchor.step() else { anchor.reset(); report.twinsKept += 1; continue }
                let target = anchor.int(0); anchor.reset()
                follow.bind(1, target).bind(2, l.id); try follow.run()
                hide.bind(1, target).bind(2, l.id); try hide.run()
                report.twinsHidden += 1; toHide -= 1
            }
        }
    }

    // MARK: Apple tapbacks stored as text

    private static func tapbacks(db: Database, report: inout Report) throws {
        let cand = try db.prepare("""
            SELECT m.id, m.thread_id, m.ts_ms, m.is_from_me, m.sender_handle_id, m.body, m.service FROM message m
            JOIN thread t ON t.id = m.thread_id
            WHERE t.service IS NULL AND m.canonical_id IS NULL AND m.kind IS NULL AND m.body IS NOT NULL
              AND (m.body LIKE 'Loved %' OR m.body LIKE 'Liked %' OR m.body LIKE 'Disliked %' OR m.body LIKE 'Laughed at %'
                   OR m.body LIKE 'Emphasized %' OR m.body LIKE 'Questioned %' OR m.body LIKE 'Removed a%from %')
            ORDER BY m.ts_ms, m.id
            """)
        struct Cand { var id: Int64; var thread: Int64; var ts: Int64; var mine: Bool; var sender: Int64?; var tb: Tapback; var body: String; var service: String }
        var list: [Cand] = []
        while try cand.step() {
            guard let tb = Tapback.parse(cand.string(5)) else { continue }
            list.append(Cand(id: cand.int(0), thread: cand.int(1), ts: cand.int(2), mine: cand.int(3) != 0, sender: cand.optInt(4),
                             tb: tb, body: cand.string(5) ?? "", service: cand.string(6) ?? ""))
        }
        report.tapbackExamined = list.count

        // Nearest earlier canonical message in the same thread: exact trim(body), else whitespace-collapsed / truncated ("…").
        let exact = try db.prepare("""
            SELECT id FROM message WHERE thread_id = ?1 AND canonical_id IS NULL AND kind IS NULL AND ts_ms <= ?2 AND id <> ?3
              AND trim(body) = ?4 ORDER BY ts_ms DESC, id DESC LIMIT 1
            """)
        let earlier = try db.prepare("""
            SELECT id, body FROM message WHERE thread_id = ?1 AND canonical_id IS NULL AND kind IS NULL AND body IS NOT NULL AND ts_ms <= ?2 AND id <> ?3
            ORDER BY ts_ms DESC, id DESC LIMIT 3000
            """)
        let insReaction = try db.prepare("INSERT INTO reaction(message_id, emoji, actor_handle_id, by_me) VALUES (?,?,?,?)")
        let delReaction = try db.prepare("""
            DELETE FROM reaction WHERE rowid = (SELECT rowid FROM reaction WHERE message_id = ?1 AND emoji = ?2
              AND by_me = ?3 AND actor_handle_id IS ?4 ORDER BY rowid DESC LIMIT 1)
            """)
        let hide = try db.prepare("UPDATE message SET kind = 'reaction', canonical_id = ? WHERE id = ?")
        let follow = try db.prepare("UPDATE message SET canonical_id = ? WHERE canonical_id = ?")   // its own provenance copies follow it
        let sys = try db.prepare("UPDATE message SET kind = 'system', note = ?, body = NULL WHERE id = ?")

        func resolve(_ c: Cand) throws -> Int64? {
            exact.bind(1, c.thread).bind(2, c.ts).bind(3, c.id).bind(4, c.tb.quote.trimmingCharacters(in: .whitespacesAndNewlines))
            if try exact.step() { let id = exact.int(0); exact.reset(); return id }
            exact.reset()
            var want = Tapback.collapse(c.tb.quote)
            let truncated = want.hasSuffix("…")
            if truncated { want = String(want.dropLast()).trimmingCharacters(in: .whitespaces) }
            guard !want.isEmpty else { return nil }
            earlier.bind(1, c.thread).bind(2, c.ts).bind(3, c.id)
            defer { earlier.reset() }
            while try earlier.step() {
                let b = Tapback.collapse(earlier.string(1) ?? "")
                if b == want || (truncated && b.hasPrefix(want)) { return earlier.int(0) }
            }
            return nil
        }

        for c in list {
            guard let target = try resolve(c) else {
                report.tapbackUnresolved += 1
                report.unresolvedByService[c.service, default: 0] += 1
                sys.bind(1, c.body).bind(2, c.id); try sys.run()
                continue
            }
            let actor: Int64? = c.mine ? nil : c.sender
            if c.tb.removal {
                delReaction.bind(1, target).bind(2, c.tb.emoji).bind(3, c.mine).bind(4, actor)
                try delReaction.run()
                if db.changes > 0 { report.tapbackRemovalsApplied += 1 } else { report.tapbackRemovalsNoMatch += 1 }
            } else {
                insReaction.bind(1, target).bind(2, c.tb.emoji).bind(3, actor).bind(4, c.mine)
                try insReaction.run()
                report.tapbackResolved += 1
            }
            // Hidden like a provenance duplicate (canonical_id -> the message it reacts to): every reader already skips those rows,
            // and the body stays so the original text is never lost.
            follow.bind(1, target).bind(2, c.id); try follow.run()
            hide.bind(1, target).bind(2, c.id); try hide.run()
        }
    }
}
