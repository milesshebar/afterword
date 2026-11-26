import Foundation

public struct ChatDBImportStats: Codable, Equatable, Sendable {
    public var snapshotSHA256 = ""
    public var until: String?                 // inclusive day, in LocalZone; nil = everything
    public var untilEndMs: Int64?             // exclusive end of the cutoff (midnight after `until`, in the import's zone)
    public var sinceEndMs: Int64?             // an earlier chat.db import already covered everything before this
    public var since: String?                 // --since: the resume point given by hand (inclusive day, in the import's zone) instead of the automatic one
    public var skipKnown: Bool?               // --skip-known: a row whose guid the archive holds from any source is counted, not stored again
    public var knownElsewhere = 0             // ... rows skipped that way
    public var messagesParsed = 0             // rows read from the message table
    public var afterCutoff = 0                // rows (incl. tapbacks) dated after the cutoff: left for a later run
    public var coveredEarlier = 0             // rows dated before an earlier chat.db import's cutoff, or with a guid it already stored
    public var inserted = 0                   // new canonical rows
    public var duplicates = 0                 // rows linked to a canonical row from another source (kept)
    public var guidMatches = 0                // ... of which matched by iMessage guid (the rest by the content-hash rule)
    public var reactionsImported = 0
    public var reactionsAlreadyThere = 0      // the same tapback was already on the target (an iPhone backup brought it)
    public var reactionsSkipped = 0           // target not in the archive, or an unknown tapback type
    public var unsent = 0                     // retracted messages, stored as kind 'unsent' notes
    public var edited = 0                     // edited messages: the final text, with note "edited"
    public var emptySkipped = 0               // no text and no attachments (group renames, joins, app balloons, ...)
    public var orphansSkipped = 0             // no chat and no handle
    public var invalidSkipped = 0             // no usable date
    public var attachmentsReferenced = 0
    public var attachmentsStored = 0
    public var attachmentsMissing = 0         // not on this Mac (Messages in iCloud offloaded them) or outside the attachments folder
    public var offloadedNotes = 0             // messages carrying the placeholder note for missing attachments
    public var mediaBytes = 0
    public var mediaNewBytes = 0
    public var mediaNewFiles = 0
    public var groupChats = 0                 // chats with 2+ other members that contributed a message
    public var groupTitles = 0                // group threads given the chat's display name
    public var addOnly: Bool?                 // --add-only: nothing that existed before is changed (see importChatDB)
    public var heldMatches = 0                // --add-only: rows matching an existing row by the writer's duplicate rule: not written
    public var heldByList = 0                 // --add-only: guids on the hold list: not written
    public var reactionsOnOldRowsLeftOut = 0  // --add-only: tapbacks (and removals) aimed at a row that existed before: left out
    public var seconds = 0.0
}

extension ChatDBImportStats {
    /// Every field optional on the way in: stats written by an older build (before a counter existed) must still decode, or an
    /// import would treat that source's cutoff as unknown.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotSHA256 = try c.decodeIfPresent(String.self, forKey: .snapshotSHA256) ?? ""
        until = try c.decodeIfPresent(String.self, forKey: .until)
        untilEndMs = try c.decodeIfPresent(Int64.self, forKey: .untilEndMs)
        sinceEndMs = try c.decodeIfPresent(Int64.self, forKey: .sinceEndMs)
        since = try c.decodeIfPresent(String.self, forKey: .since)
        skipKnown = try c.decodeIfPresent(Bool.self, forKey: .skipKnown)
        knownElsewhere = try c.decodeIfPresent(Int.self, forKey: .knownElsewhere) ?? 0
        messagesParsed = try c.decodeIfPresent(Int.self, forKey: .messagesParsed) ?? 0
        afterCutoff = try c.decodeIfPresent(Int.self, forKey: .afterCutoff) ?? 0
        coveredEarlier = try c.decodeIfPresent(Int.self, forKey: .coveredEarlier) ?? 0
        inserted = try c.decodeIfPresent(Int.self, forKey: .inserted) ?? 0
        duplicates = try c.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0
        guidMatches = try c.decodeIfPresent(Int.self, forKey: .guidMatches) ?? 0
        reactionsImported = try c.decodeIfPresent(Int.self, forKey: .reactionsImported) ?? 0
        reactionsAlreadyThere = try c.decodeIfPresent(Int.self, forKey: .reactionsAlreadyThere) ?? 0
        reactionsSkipped = try c.decodeIfPresent(Int.self, forKey: .reactionsSkipped) ?? 0
        unsent = try c.decodeIfPresent(Int.self, forKey: .unsent) ?? 0
        edited = try c.decodeIfPresent(Int.self, forKey: .edited) ?? 0
        emptySkipped = try c.decodeIfPresent(Int.self, forKey: .emptySkipped) ?? 0
        orphansSkipped = try c.decodeIfPresent(Int.self, forKey: .orphansSkipped) ?? 0
        invalidSkipped = try c.decodeIfPresent(Int.self, forKey: .invalidSkipped) ?? 0
        attachmentsReferenced = try c.decodeIfPresent(Int.self, forKey: .attachmentsReferenced) ?? 0
        attachmentsStored = try c.decodeIfPresent(Int.self, forKey: .attachmentsStored) ?? 0
        attachmentsMissing = try c.decodeIfPresent(Int.self, forKey: .attachmentsMissing) ?? 0
        offloadedNotes = try c.decodeIfPresent(Int.self, forKey: .offloadedNotes) ?? 0
        mediaBytes = try c.decodeIfPresent(Int.self, forKey: .mediaBytes) ?? 0
        mediaNewBytes = try c.decodeIfPresent(Int.self, forKey: .mediaNewBytes) ?? 0
        mediaNewFiles = try c.decodeIfPresent(Int.self, forKey: .mediaNewFiles) ?? 0
        groupChats = try c.decodeIfPresent(Int.self, forKey: .groupChats) ?? 0
        groupTitles = try c.decodeIfPresent(Int.self, forKey: .groupTitles) ?? 0
        addOnly = try c.decodeIfPresent(Bool.self, forKey: .addOnly)
        heldMatches = try c.decodeIfPresent(Int.self, forKey: .heldMatches) ?? 0
        heldByList = try c.decodeIfPresent(Int.self, forKey: .heldByList) ?? 0
        reactionsOnOldRowsLeftOut = try c.decodeIfPresent(Int.self, forKey: .reactionsOnOldRowsLeftOut) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0.0
    }
}

public struct ChatDBImportReport: Sendable {
    public var status: ImportReport.Status
    public var path: String
    public var sha256: String
    public var sourceID: Int64
    public var stats: ChatDBImportStats
}

/// Imports a snapshot of the Mac's Messages database (`~/Library/Messages/chat.db`, Messages in iCloud). Same schema family
/// as the iPhone's modern sms.db: handles, chats and their members, text or attributedBody, tapbacks, attachments. Attachments
/// are read from the Messages attachments folder by the path the row records; missing files (offloaded to iCloud) are counted
/// and leave a placeholder note. A cutoff (`until`, inclusive, in `LocalZone`) limits the import; a later run with a later
/// cutoff picks up where the last chat.db import ended.
public enum MacChatDBImporter {
    public static let kind = "macos-chatdb"
    public static let defaultAttachmentsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Messages/Attachments")
    static let storedAttachmentsPrefix = "~/Library/Messages/Attachments/"

    /// A chat.db-shaped file: has `chat_message_join` and `message.guid`, and is not an iPhone backup folder.
    public static func isChatDB(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "db",
              let db = try? Database(path: url.path, readOnly: true, immutable: true) else { return false }
        return ((try? db.tableExists("chat_message_join")) ?? false) && ((try? db.hasColumn("message", "guid")) ?? false)
            && ((try? db.tableExists("chat")) ?? false)
    }

    /// Exclusive end (unix ms) of the day `yyyy-MM-dd` in `LocalZone`.
    public static func endOfDayMs(_ day: String, zone: TimeZone = LocalZone.current()) throws -> Int64 {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { throw ArchiveError("--until needs YYYY-MM-DD, got \(day)") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = cal.date(byAdding: .day, value: 1, to: start) else { throw ArchiveError("bad date \(day)") }
        return Int64((next.timeIntervalSince1970 * 1000).rounded())
    }

    /// Start (unix ms) of the day `yyyy-MM-dd` in `LocalZone`.
    public static func startOfDayMs(_ day: String, zone: TimeZone = LocalZone.current()) throws -> Int64 {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { throw ArchiveError("--since needs YYYY-MM-DD, got \(day)") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { throw ArchiveError("bad date \(day)") }
        return Int64((start.timeIntervalSince1970 * 1000).rounded())
    }

    /// `until` and `since` are days in `zone` (default `LocalZone`). `since` (inclusive day) replaces the automatic resume point (the latest earlier chat.db cutoff), for a snapshot
    /// from another Mac whose rows before that point the archive may lack; `skipKnown` then keeps it from storing a linked
    /// duplicate of every row the archive already holds (any source, by `ios:<guid>`): those are counted in `knownElsewhere`.
    /// `addOnly` (implies `skipKnown`) adds rows and changes nothing that existed before: a row matching an existing one by the
    /// writer's duplicate rule is held instead of linked (no canonical flip), a tapback or its removal counts only on a row this
    /// run wrote, and only threads this run created get a chat's display name. `holdKeys` (`ios:<guid>`) are left out.
    /// `ledger` gets one tab-separated line per chat.db message row: what was decided and which archive row it names.
    public static func importChatDB(at url: URL, into db: Database, root: ArchiveRoot, zone: TimeZone = LocalZone.current(),
                                    until: String? = nil, since: String? = nil,
                                    skipKnown: Bool = false,
                                    attachmentsRoot: URL = defaultAttachmentsRoot, origin: String? = nil,
                                    addOnly: Bool = false, holdKeys: Set<String> = [], ledger: URL? = nil,
                                    progress: ((ImportProgress) -> Void)? = nil) throws -> ChatDBImportReport {
        let t0 = Date()
        let untilEnd = try until.map { try endOfDayMs($0, zone: zone) }
        let skipKnown = skipKnown || addOnly
        let (sha, size) = try Hashing.sha256Hex(ofFile: url)
        // One source row per (snapshot, cutoff): the same snapshot imported again with a later cutoff adds only the new days.
        let key = since == nil && !skipKnown ? "\(sha):until=\(until ?? "all")"
            : "\(sha):since=\(since ?? "auto")\(skipKnown ? ":skip-known" : "")\(addOnly ? ":add-only" : "")"
              + "\(holdKeys.isEmpty ? "" : ":hold=\(holdKeys.count)/\(String(UInt64(bitPattern: Hashing.fnv1a(holdKeys.sorted().joined(separator: "\n"))), radix: 16))")"
              + ":until=\(until ?? "all")"
        let st = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        st.bind(1, key)
        if try st.step() {
            let stats = st.string(1).flatMap { try? JSONDecoder().decode(ChatDBImportStats.self, from: Data($0.utf8)) } ?? ChatDBImportStats()
            return ChatDBImportReport(status: .alreadyImported, path: url.path, sha256: sha, sourceID: st.int(0), stats: stats)
        }
        st.reset()

        // What earlier chat.db imports covered: everything before the latest cutoff, and every guid they stored.
        var sinceEnd: Int64? = nil
        var earlierSources: [Int64] = []
        let prev = try db.prepare("SELECT id, stats_json FROM source WHERE kind = ?")
        prev.bind(1, kind)
        while try prev.step() {
            earlierSources.append(prev.int(0))
            let s = prev.string(1).flatMap { try? JSONDecoder().decode(ChatDBImportStats.self, from: Data($0.utf8)) }
            // An add-only snapshot is another Mac's history, not this Mac's progress: it moves no resume point.
            if s?.addOnly == true { continue }
            let end = s?.untilEndMs ?? Int64.max
            sinceEnd = max(sinceEnd ?? end, end)
        }
        // Add-only scans its whole snapshot unless told where to start: another Mac's later cutoff must not hide this snapshot's
        // older rows; --skip-known holds what the archive already has.
        if addOnly { sinceEnd = nil }
        if let since { sinceEnd = try startOfDayMs(since, zone: zone) }
        var earlierKeys = Set<String>()
        if skipKnown {
            let k = try db.prepare("SELECT source_key FROM message WHERE source_key LIKE 'ios:%'")
            while try k.step() { if let s = k.string(0) { earlierKeys.insert(s) } }
        } else if !earlierSources.isEmpty {
            let k = try db.prepare("SELECT source_key FROM message WHERE source_id IN (\(earlierSources.map(String.init).joined(separator: ","))) AND source_key IS NOT NULL")
            while try k.step() { if let s = k.string(0) { earlierKeys.insert(s) } }
        }

        let chat = try Database(path: url.path, readOnly: true, immutable: true)
        guard try chat.tableExists("chat_message_join"), try chat.tableExists("chat") else { throw ArchiveError("\(url.path) is not a Messages chat.db") }
        let store = MediaStore(root: root)
        var report: ChatDBImportReport!
        // The ledger is written to `<ledger>.partial` and gets its name only after COMMIT, so it never names rows that a rolled-back
        // import did not leave.
        if let ledger { try? FileManager.default.removeItem(at: ChatDBLedger.partial(ledger)) }
        do { try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origin ?? url.path).bind(3, key).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind, sourceTier: SourceTier.modernIOS)
            var stats = ChatDBImportStats()
            stats.snapshotSHA256 = sha
            stats.until = until
            stats.untilEndMs = untilEnd
            stats.sinceEndMs = sinceEnd
            stats.since = since
            stats.skipKnown = skipKnown ? true : nil
            stats.addOnly = addOnly ? true : nil
            writer.holdMatches = addOnly
            let log = try ledger.map { try ChatDBLedger(url: ChatDBLedger.partial($0), sourceFile: origin ?? url.path, archive: db) }
            var r = Reader(chat: chat, db: db, writer: writer, store: store, attachmentsRoot: attachmentsRoot, sourceID: sid,
                           untilEnd: untilEnd, sinceEnd: sinceEnd, earlierKeys: earlierKeys, skipKnown: skipKnown,
                           addOnly: addOnly, holdKeys: holdKeys, threadsBefore: try db.scalarInt("SELECT coalesce(max(id), 0) FROM thread"),
                           ledger: log, progress: progress)
            try r.run(&stats)
            try log?.close()
            stats.seconds = Date().timeIntervalSince(t0)
            let json = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, json).bind(2, sid)
            try up.run()
            report = ChatDBImportReport(status: .imported, path: origin ?? url.path, sha256: sha, sourceID: sid, stats: stats)
        } } catch {
            if let ledger { try? FileManager.default.removeItem(at: ChatDBLedger.partial(ledger)) }
            throw error
        }
        if let ledger {
            try? FileManager.default.removeItem(at: ledger)
            try FileManager.default.moveItem(at: ChatDBLedger.partial(ledger), to: ledger)
        }
        return report
    }

    /// Where an attachment row's file is on this Mac, or nil when it is not inside the attachments folder.
    static func resolve(stored: String, attachmentsRoot: URL) -> URL? {
        var rel: String?
        if stored.hasPrefix(storedAttachmentsPrefix) { rel = String(stored.dropFirst(storedAttachmentsPrefix.count)) }
        else {
            let expanded = (stored as NSString).expandingTildeInPath
            let rootPath = attachmentsRoot.standardizedFileURL.path + "/"
            let def = defaultAttachmentsRoot.standardizedFileURL.path + "/"
            if expanded.hasPrefix(rootPath) { rel = String(expanded.dropFirst(rootPath.count)) }
            else if expanded.hasPrefix(def) { rel = String(expanded.dropFirst(def.count)) }
        }
        guard let rel, !rel.isEmpty, !rel.split(separator: "/").contains("..") else { return nil }
        return attachmentsRoot.appendingPathComponent(rel)
    }

    private struct Reader {
        let chat: Database
        let db: Database
        let writer: ArchiveWriter
        let store: MediaStore
        let attachmentsRoot: URL
        let sourceID: Int64
        let untilEnd: Int64?
        let sinceEnd: Int64?
        let earlierKeys: Set<String>
        let skipKnown: Bool
        let addOnly: Bool
        let holdKeys: Set<String>
        let threadsBefore: Int64
        let ledger: ChatDBLedger?
        let progress: ((ImportProgress) -> Void)?

        mutating func run(_ stats: inout ChatDBImportStats) throws {
            var handles: [Int64: String] = [:]
            let h = try chat.prepare("SELECT ROWID, id FROM handle")
            while try h.step() { if let id = h.string(1)?.nilIfEmpty { handles[h.int(0)] = id } }
            var chatMembers: [Int64: [String]] = [:]
            let cj = try chat.prepare("SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id")
            while try cj.step() { if let id = handles[cj.int(1)] { chatMembers[cj.int(0), default: []].append(id) } }
            var chatTitles: [Int64: String] = [:]
            if try chat.hasColumn("chat", "display_name") {
                let c = try chat.prepare("SELECT ROWID, display_name FROM chat")
                while try c.step() {
                    if let n = c.string(1)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { chatTitles[c.int(0)] = n }
                }
            }

            func col(_ name: String, _ fallback: String = "NULL") throws -> String { try chat.hasColumn("message", name) ? "m.\(name)" : fallback }
            let total = Int(try chat.scalarInt("SELECT count(*) FROM message"))
            let msgs = try chat.prepare("""
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, m.subject, m.service, m.date, m.is_from_me,
                       \(try col("associated_message_type", "0")),
                       (SELECT chat_id FROM chat_message_join j WHERE j.message_id = m.ROWID ORDER BY chat_id LIMIT 1),
                       \(try col("associated_message_guid")), \(try col("associated_message_emoji")),
                       \(try col("date_retracted", "0")), \(try col("date_edited", "0"))
                FROM message m ORDER BY m.ROWID
                """)
            let atts = try chat.prepare("""
                SELECT a.filename, a.transfer_name, a.mime_type
                FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE j.message_id = ? ORDER BY j.attachment_id
                """)
            let keyElsewhere = try db.prepare("SELECT 1 FROM message WHERE source_key = ? AND source_id != ? LIMIT 1")

            var done = 0
            var lastTick = Date()
            var deferred: [(emoji: String, removal: Bool, target: String, byMe: Bool, actor: String?, row: ChatDBLedger.Row)] = []
            var titles: [Int64: String] = [:]          // archive thread -> chat display name (first seen)
            var groupChats = Set<Int64>()
            while try msgs.step() {
                done += 1
                stats.messagesParsed += 1
                if let progress, done % 2000 == 0, Date().timeIntervalSince(lastTick) >= 1 {
                    lastTick = Date()
                    progress(ImportProgress(bytesRead: Int64(done), totalBytes: Int64(total), messages: done))
                }
                let fromMe = msgs.int(8) != 0
                let chatID = msgs.optInt(10)
                var lrow = ChatDBLedger.Row(rowid: msgs.int(0), guid: msgs.string(1) ?? "", ts: nil, fromMe: fromMe, chatID: chatID,
                                            members: chatID.flatMap { chatMembers[$0]?.count } ?? 0)
                guard let ts = IOSDates.modernToUnixMs(msgs.int(7)) else { stats.invalidSkipped += 1; try ledger?.log(lrow, "left-out-invalid-date"); continue }
                lrow.ts = ts
                if let untilEnd, ts >= untilEnd { stats.afterCutoff += 1; try ledger?.log(lrow, "left-out-after-until"); continue }
                if let sinceEnd, ts < sinceEnd { stats.coveredEarlier += 1; try ledger?.log(lrow, "left-out-before-since"); continue }
                let handleRaw = msgs.optInt(4).flatMap { $0 == 0 ? nil : handles[$0] }
                let assoc = msgs.int(9)
                if assoc >= 2000 && assoc < 4000 {
                    if let g = msgs.string(11), let tb = IOSBackupImporter.tapbackEmoji(assoc, emoji: msgs.string(12)) {
                        deferred.append((tb, assoc >= 3000, "ios:" + IOSBackupImporter.tapbackTarget(g), fromMe, handleRaw, lrow))
                    } else { stats.reactionsSkipped += 1; try ledger?.log(lrow, "left-out-tapback-unknown-type") }
                    continue
                }
                guard let guid = msgs.string(1)?.nilIfEmpty else { stats.invalidSkipped += 1; try ledger?.log(lrow, "left-out-no-guid"); continue }
                let sourceKey = "ios:" + guid
                if earlierKeys.contains(sourceKey) {
                    if skipKnown { stats.knownElsewhere += 1; try ledger?.log(lrow, "held-guid", knownKey: sourceKey) }
                    else { stats.coveredEarlier += 1; try ledger?.log(lrow, "left-out-covered-earlier", knownKey: sourceKey) }
                    continue
                }
                if holdKeys.contains(sourceKey) { stats.heldByList += 1; try ledger?.log(lrow, "left-out-hold-list"); continue }

                var participants: [String] = []
                if let c = chatID, let members = chatMembers[c], !members.isEmpty { participants = members }
                else if let h = handleRaw { participants = [h] }
                if participants.isEmpty { stats.orphansSkipped += 1; try ledger?.log(lrow, "left-out-no-chat-or-handle"); continue }

                var records: [AttachmentRecord] = []
                var missingNames: [String] = []
                var referenced = 0
                atts.bind(1, msgs.int(0))
                while try atts.step() {
                    guard let stored = atts.string(0)?.nilIfEmpty else { continue }
                    referenced += 1
                    stats.attachmentsReferenced += 1
                    let name = atts.string(1)?.nilIfEmpty ?? (stored as NSString).lastPathComponent
                    let mime = atts.string(2)?.nilIfEmpty
                    if let file = MacChatDBImporter.resolve(stored: stored, attachmentsRoot: attachmentsRoot),
                       FileManager.default.fileExists(atPath: file.path),
                       let data = try? Data(contentsOf: file, options: .alwaysMapped) {
                        let s = try data.withUnsafeBytes {
                            try store.store($0, mime: mime, filename: name, lookup: { writer.existingMediaPath(sha256: $0) })
                        }
                        stats.attachmentsStored += 1
                        stats.mediaBytes += s.bytes
                        if s.wasNew { stats.mediaNewBytes += s.bytes; stats.mediaNewFiles += 1 }
                        records.append(AttachmentRecord(mime: mime, filename: name, sha256: s.sha256, relativePath: s.relativePath, bytes: s.bytes))
                    } else {
                        stats.attachmentsMissing += 1
                        missingNames.append(name)
                    }
                }
                atts.reset()

                let retracted = msgs.int(13) > 0
                let body = IOSBackupImporter.decodeBody(text: msgs.string(2), attributedBody: msgs.blob(3))
                if body == nil && referenced == 0 && !retracted { stats.emptySkipped += 1; try ledger?.log(lrow, "left-out-empty"); continue }

                var sender: String? = nil
                if !fromMe { sender = handleRaw ?? (participants.count == 1 ? participants[0] : nil) }
                var service = (msgs.string(6) ?? "").lowercased()
                if service != "imessage" { service = "sms" }            // SMS, RCS (relayed from the iPhone) and blanks
                if service == "sms" && referenced > 0 { service = "mms" }
                var rec = MessageRecord(participants: participants, sender: sender, tsMs: ts, isFromMe: fromMe, service: service,
                                        body: body, subject: msgs.string(5)?.nilIfEmpty, sourceKey: sourceKey, attachments: records)
                if retracted && body == nil && records.isEmpty {
                    rec.kind = "unsent"; rec.note = fromMe ? "You unsent a message" : "Unsent a message"
                    stats.unsent += 1
                } else if !missingNames.isEmpty {
                    let line = "(\(missingNames.count == 1 ? "attachment" : "\(missingNames.count) attachments") not on this Mac, offloaded to iCloud: \(missingNames.joined(separator: ", ")))"
                    if body == nil && records.isEmpty { rec.kind = "system" }
                    rec.note = line
                    stats.offloadedNotes += 1
                } else if msgs.int(14) > 0 {
                    rec.note = "edited"
                    stats.edited += 1
                }

                keyElsewhere.bind(1, sourceKey).bind(2, sourceID)
                let guidElsewhere = try keyElsewhere.step()
                keyElsewhere.reset()
                switch try writer.add(rec) {
                case .inserted:
                    stats.inserted += 1
                    try ledger?.log(lrow, "new", thread: writer.lastThreadID, written: writer.lastMessageID)
                case .duplicate:
                    if let held = writer.lastHeldID {
                        stats.heldMatches += 1
                        try ledger?.log(lrow, writer.lastHeldOtherGuid ? "held-match-other-guid" : "held-match", archive: held, thread: writer.lastThreadID)
                    } else {
                        stats.duplicates += 1
                        if guidElsewhere { stats.guidMatches += 1 }
                        try ledger?.log(lrow, "duplicate-linked", thread: writer.lastThreadID, written: writer.lastMessageID)
                    }
                }
                if participants.count > 1, let c = chatID, writer.lastMessageID != nil {
                    groupChats.insert(c)
                    if let t = chatTitles[c], titles[writer.lastThreadID] == nil { titles[writer.lastThreadID] = t }
                }
            }
            stats.groupChats = groupChats.count

            // Tapbacks in message order once every target is stored; one an iPhone backup already brought is not added twice.
            let find = try db.prepare("SELECT coalesce(canonical_id, id) FROM message WHERE source_key = ? ORDER BY id LIMIT 1")
            let has = try db.prepare("""
                SELECT 1 FROM reaction r JOIN message m ON m.id = r.message_id
                WHERE (m.id = ?1 OR m.canonical_id = ?1) AND r.emoji = ?2 AND r.by_me = ?3 AND r.actor_handle_id IS ?4 LIMIT 1
                """)
            let mine = try db.prepare("SELECT id FROM message WHERE source_key = ? AND source_id = ? LIMIT 1")
            for t in deferred {
                var newTarget: Int64? = nil
                if addOnly {
                    mine.bind(1, t.target).bind(2, sourceID)
                    newTarget = try mine.step() ? mine.int(0) : nil
                    mine.reset()
                    if newTarget == nil {
                        stats.reactionsOnOldRowsLeftOut += 1
                        try ledger?.log(t.row, "left-out-tapback-on-old-row", knownKey: t.target)
                        continue
                    }
                }
                if !t.removal {
                    find.bind(1, t.target)
                    if try find.step() {
                        let target = find.int(0)
                        find.reset()
                        let actor: Int64? = t.byMe ? nil : try t.actor.flatMap { try writer.handleID(raw: $0) }
                        has.bind(1, target).bind(2, t.emoji).bind(3, t.byMe).bind(4, actor)
                        let already = try has.step()
                        has.reset()
                        if already { stats.reactionsAlreadyThere += 1; try ledger?.log(t.row, "held-tapback-already-there", archive: target); continue }
                    } else { find.reset() }
                }
                if try writer.addTapback(targetSourceKey: t.target, emoji: t.emoji, actorRaw: t.actor, byMe: t.byMe, removal: t.removal) {
                    stats.reactionsImported += 1
                    try ledger?.log(t.row, t.removal ? "tapback-removal-applied" : "tapback-added", archive: newTarget, knownKey: newTarget == nil ? t.target : nil)
                } else { stats.reactionsSkipped += 1; try ledger?.log(t.row, "left-out-tapback-target-not-in-archive") }
            }

            let up = try db.prepare("UPDATE thread SET title = ? WHERE id = ? AND title IS NULL AND is_group = 1")
            for (thread, title) in titles where !addOnly || thread > threadsBefore {
                up.bind(1, title).bind(2, thread)
                try up.run()
                if db.changes > 0 { stats.groupTitles += 1 }
            }
        }
    }
}

/// The decision ledger of a chat.db import (`import --ledger`): one tab-separated line per chat.db message row.
final class ChatDBLedger {
    struct Row { var rowid: Int64; var guid: String; var ts: Int64?; var fromMe: Bool; var chatID: Int64?; var members: Int }
    static let header = ["source_file", "chat_rowid", "guid", "ts_ms", "ts_utc", "direction", "chat_id", "members", "decision",
                         "archive_message_id", "archive_thread_id", "written_message_id"]
    static func partial(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".partial") }
    private let out: FileHandle
    private let sourceFile: String
    private let byKey: Statement
    private var buffer = ""
    private let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    init(url: URL, sourceFile: String, archive: Database) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        out = try FileHandle(forWritingTo: url)
        self.sourceFile = sourceFile.replacingOccurrences(of: "\t", with: " ")
        byKey = try archive.prepare("SELECT coalesce(canonical_id, id), thread_id FROM message WHERE source_key = ? ORDER BY id LIMIT 1")
        buffer = Self.header.joined(separator: "\t") + "\n"
    }

    /// `knownKey`: look the archive row up by this source key (the row a guid or tapback target names).
    func log(_ r: Row, _ decision: String, archive: Int64? = nil, thread: Int64? = nil, written: Int64? = nil, knownKey: String? = nil) throws {
        var archive = archive, thread = thread
        if let k = knownKey {
            byKey.bind(1, k)
            if try byKey.step() { archive = archive ?? byKey.int(0); thread = thread ?? byKey.int(1) }
            byKey.reset()
        }
        let ts = r.ts.map { iso.string(from: Date(timeIntervalSince1970: Double($0) / 1000)) } ?? ""
        let f: [String] = [sourceFile, "\(r.rowid)", r.guid, r.ts.map(String.init) ?? "", ts, r.fromMe ? "out" : "in",
                           r.chatID.map(String.init) ?? "", "\(r.members)", decision, archive.map(String.init) ?? "",
                           thread.map(String.init) ?? "", written.map(String.init) ?? ""]
        buffer += f.joined(separator: "\t") + "\n"
        if buffer.utf8.count > 1 << 20 { try flush() }
    }

    private func flush() throws { try out.write(contentsOf: Data(buffer.utf8)); buffer = "" }
    func close() throws { try flush(); try out.close() }
}
