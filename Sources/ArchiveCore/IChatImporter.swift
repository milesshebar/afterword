import Foundation

public struct IChatImportStats: Codable, Equatable, Sendable {
    public var files = 0
    public var unreadable = 0                  // files that are not an iChat transcript archive
    public var messages = 0                    // InstantMessage objects read
    public var inserted = 0
    public var heldGuid = 0                    // the archive holds the message by its guid (any source)
    public var heldMatches = 0                 // a row matching it by the writer's duplicate rule: not written
    public var heldByList = 0                  // --hold
    public var leftOutEmpty = 0                // no text (an attachment whose file the transcript does not carry)
    public var leftOutNoThread = 0             // nothing places the conversation: no held message, and not a 1:1 with a known other party
    public var leftOutTwoThreads = 0           // the file's held messages sit in more than one archive thread
    public var leftOutSender = 0               // an incoming message whose sender is not a member of the thread the file belongs to
    public var leftOutNoDate = 0               // no usable Time
    public var byService: [String: Int] = [:]  // written rows by service
    public init() {}
}

public struct IChatImportReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64
    public var stats: IChatImportStats
}

/// Saved Messages and iChat transcripts (`*.ichat`: an NSKeyedArchiver archive with a `metadata` dictionary and a `root` array whose
/// messages are `InstantMessage` objects with `Sender` (a `Presentity`: ID, ServiceName, ServiceLoginID), `Time`, `MessageText`, `GUID`,
/// `Flags`). Useful for an older Mac's transcripts holding messages no chat.db has, AIM chats included.
///
/// Always add-only. Direction is `Flags & 4` (from the owner; checked against every held message's `is_from_me`). An iMessage or SMS message
/// carries the chat.db guid (`ios:<GUID>`), so one the archive holds is held by guid; an AIM message is keyed `aim:<GUID>`. A file's other
/// messages go into the thread its held messages already sit in (exactly one, else left out), an incoming sender must be a member of it;
/// a file with no held message is placed only when it is a 1:1 with one other party (AIM: an `aim:` handle, a thread of service `aim`).
/// Messages without text are left out (the transcript does not carry attachment files). One ledger line per message, written to
/// `<ledger>.partial` and renamed after COMMIT. Idempotent: the source key is the folder's file list with each file's SHA-256.
public enum IChatImporter {
    public static let kind = "ichat-transcripts"

    // MARK: reading one transcript

    #if canImport(ObjectiveC)
    @objc(MAIChatPresentity) final class Presentity: NSObject, NSCoding {
        let id: String, service: String, login: String
        init?(coder c: NSCoder) {
            id = (c.decodeObject(forKey: "ID") as? String) ?? ""
            service = (c.decodeObject(forKey: "ServiceName") as? String) ?? ""
            login = (c.decodeObject(forKey: "ServiceLoginID") as? String) ?? ""
        }
        func encode(with c: NSCoder) {}
    }

    @objc(MAIChatInstantMessage) final class Message: NSObject, NSCoding {
        let sender: Presentity?, time: Date?, text: String?, guid: String?, flags: Int64
        init?(coder c: NSCoder) {
            sender = c.decodeObject(forKey: "Sender") as? Presentity
            time = c.decodeObject(forKey: "Time") as? Date
            text = (c.decodeObject(forKey: "MessageText") as? NSAttributedString)?.string
            guid = c.decodeObject(forKey: "GUID") as? String
            flags = c.decodeInt64(forKey: "Flags")
        }
        func encode(with c: NSCoder) {}
    }

    /// Stands in for classes this process does not have (AppKit's NSFont, NSColor, NSParagraphStyle in the text attributes).
    @objc(MAIChatIgnored) final class Ignored: NSObject, NSCoding {
        init?(coder: NSCoder) { super.init() }
        func encode(with c: NSCoder) {}
    }

    final class Delegate: NSObject, NSKeyedUnarchiverDelegate {
        func unarchiver(_ u: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String, originalClasses: [String]) -> AnyClass? { Ignored.self }
    }

    #else
    // Linux (the web app's container builds archivectl there): the transcripts are NSKeyedArchiver files with Objective-C class
    // names, which only the Mac can unarchive. The types exist so the importer compiles; reading a transcript is refused.
    final class Presentity { let id = "", service = "", login = "" }
    final class Message { let sender: Presentity? = nil, time: Date? = nil, text: String? = nil, guid: String? = nil, flags: Int64 = 0 }
    #endif

    struct Transcript {
        var service: String                    // metadata Service: iMessage | SMS | AIM ...
        var chatRoom: String?
        var messages: [Message]
        var presentities: [Presentity]
    }

    static func read(_ data: Data) throws -> Transcript {
        #if !canImport(ObjectiveC)
        throw ArchiveError("iChat transcripts can only be read on a Mac (NSKeyedArchiver with Objective-C class names)")
        #else
        let u = try NSKeyedUnarchiver(forReadingFrom: data)
        u.requiresSecureCoding = false
        let delegate = Delegate()
        u.delegate = delegate
        u.setClass(Message.self, forClassName: "InstantMessage")
        u.setClass(Presentity.self, forClassName: "Presentity")
        defer { u.finishDecoding() }
        let meta = u.decodeObject(forKey: "metadata") as? NSDictionary
        guard let root = u.decodeObject(forKey: "root") as? NSArray else { throw ArchiveError("not an iChat transcript (no root)") }
        var messages: [Message] = [], presentities: [Presentity] = []
        for part in root {
            guard let arr = part as? NSArray else { continue }
            for o in arr {
                if let m = o as? Message { messages.append(m) }
                if let p = o as? Presentity { presentities.append(p) }
            }
        }
        for m in messages { if let s = m.sender, !presentities.contains(where: { $0 === s }) { presentities.append(s) } }
        let room = (meta?["ChatRoom"] as? String)?.trimmingCharacters(in: .whitespaces)
        return Transcript(service: (meta?["Service"] as? String) ?? messages.first?.sender?.service ?? "",
                          chatRoom: room?.isEmpty == false ? room : nil, messages: messages, presentities: presentities)
        #endif
    }

    static func service(_ s: String) -> String {
        switch s.lowercased() { case "imessage": return "imessage"; case "sms", "rcs": return "sms"; case "aim", "jabber": return s.lowercased(); default: return s.lowercased() }
    }

    // MARK: import

    public static func importTranscripts(at folder: URL, into db: Database, root: ArchiveRoot, origin: String? = nil,
                                         holdKeys: Set<String> = [], ledger: URL? = nil, marks: [String: String] = [:]) throws -> IChatImportReport {
        var files: [URL] = []
        if folder.pathExtension == "ichat" { files = [folder] }
        else if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.pathExtension == "ichat" { files.append(f) }
        }
        files.sort { $0.path < $1.path }
        guard !files.isEmpty else { throw ArchiveError("no .ichat files under \(folder.path)") }
        let base = folder.pathExtension == "ichat" ? folder.deletingLastPathComponent().path + "/" : folder.standardizedFileURL.path + "/"
        func rel(_ f: URL) -> String { f.standardizedFileURL.path.hasPrefix(base) ? String(f.standardizedFileURL.path.dropFirst(base.count)) : f.lastPathComponent }
        var listing = "", bytes: Int64 = 0
        for f in files { let (h, n) = try Hashing.sha256Hex(ofFile: f); listing += "\(rel(f))\t\(h)\n"; bytes += n }
        let key = "ichat:" + String(UInt64(bitPattern: Hashing.fnv1a(listing)), radix: 16) + "/\(files.count)"
            + (holdKeys.isEmpty ? "" : ":hold=\(holdKeys.count)/\(String(UInt64(bitPattern: Hashing.fnv1a(holdKeys.sorted().joined(separator: "\n"))), radix: 16))")
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(IChatImportStats.self, from: Data($0.utf8)) } ?? IChatImportStats()
            let id = seen.int(0); seen.reset()
            // A retry publishes the ledger the import stored (a failed publication after COMMIT is repaired this way).
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return IChatImportReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()

        // Archive rows by source key, and thread membership, read once.
        let byKey = try db.prepare("SELECT coalesce(m.canonical_id, m.id), (SELECT thread_id FROM message c WHERE c.id = coalesce(m.canonical_id, m.id)), m.is_from_me FROM message m WHERE m.source_key = ? ORDER BY m.id LIMIT 1")
        let isMember = try db.prepare("SELECT 1 FROM thread_member tm JOIN handle h ON h.id = tm.handle_id WHERE tm.thread_id = ? AND h.normalized = ? LIMIT 1")
        let threadsBefore = try db.scalarInt("SELECT coalesce(max(id), 0) FROM thread")
        var out = ["source_file\tguid\tts_ms\tts_utc\tdirection\tservice\tdecision\tarchive_message_id\tarchive_thread_id\twritten_message_id"]
        let iso = ISO8601DateFormatter()
        var stats = IChatImportStats()
        var report: IChatImportReport!
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origin ?? folder.path).bind(3, key).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind, sourceTier: SourceTier.other)
            writer.holdMatches = true
            var aimThreads = Set<Int64>()
            for f in files {
                stats.files += 1
                let t: Transcript
                do { t = try read(try Data(contentsOf: f)) } catch {
                    stats.unreadable += 1
                    out.append([rel(f), "", "", "", "", "", "left-out-unreadable-file", "", "", ""].joined(separator: "\t"))
                    continue
                }
                let fileService = service(t.service)
                let isMe = { (m: Message) -> Bool in m.flags & 4 != 0 }
                // People are compared by their normalized handle: two spellings of one address are one person.
                let aimFile = service(t.service) == "aim"
                func norm(_ id: String) -> String { aimFile ? ServiceHandle.aim(screenName: id).normalized : (HandleNormalizer.normalize(id)?.normalized ?? id.lowercased()) }
                let meIDs = Set(t.messages.filter(isMe).compactMap { $0.sender?.id }.map(norm))
                    .union(t.presentities.filter { !$0.login.isEmpty && norm($0.id) == norm($0.login) }.map { norm($0.id) })
                var rawOf: [String: String] = [:]
                for p in t.presentities where !p.id.isEmpty && !meIDs.contains(norm(p.id)) { rawOf[norm(p.id)] = rawOf[norm(p.id)] ?? p.id }
                let others = Set(rawOf.keys)
                struct Row { var m: Message; var key: String; var ts: Int64; var svc: String; var held: (Int64, Int64, Bool)? }
                var rows: [Row] = []
                for m in t.messages {
                    stats.messages += 1
                    let svc = service(m.sender?.service.isEmpty == false ? m.sender!.service : t.service)
                    let guid = m.guid ?? ""
                    // No guid, no key: such a row is matched by the content rules only and never stands for another.
                    let k = guid.isEmpty ? "" : (svc == "imessage" || svc == "sms" ? "ios:" : svc + ":") + guid
                    var held: (Int64, Int64, Bool)? = nil
                    if !guid.isEmpty {
                        byKey.bind(1, k)
                        if try byKey.step() { held = (byKey.int(0), byKey.int(1), byKey.int(2) != 0) }
                        byKey.reset()
                    }
                    rows.append(Row(m: m, key: k, ts: m.time.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? Int64.min, svc: svc, held: held))
                }
                let threads = Set(rows.compactMap { $0.held?.1 })
                func log(_ r: Row, _ decision: String, archive: Int64? = nil, thread: Int64? = nil, written: Int64? = nil) {
                    let ts = r.ts == Int64.min ? "" : iso.string(from: Date(timeIntervalSince1970: Double(r.ts) / 1000))
                    out.append([rel(f), r.m.guid ?? "", r.ts == Int64.min ? "" : "\(r.ts)", ts, isMe(r.m) ? "out" : "in", r.svc, decision, archive.map(String.init) ?? "",
                                thread.map(String.init) ?? "", written.map(String.init) ?? ""].joined(separator: "\t"))
                }
                for r in rows {
                    if let h = r.held {
                        stats.heldGuid += 1
                        log(r, h.2 == isMe(r.m) ? "held-guid" : "held-guid-DIRECTION-DIFFERS", archive: h.0, thread: h.1); continue
                    }
                    if r.ts == Int64.min { stats.leftOutNoDate += 1; log(r, "left-out-no-date"); continue }
                    if !r.key.isEmpty, holdKeys.contains(r.key) { stats.heldByList += 1; log(r, "left-out-hold-list"); continue }
                    let text = (r.m.text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { stats.leftOutEmpty += 1; log(r, "left-out-empty"); continue }
                    if threads.count > 1 { stats.leftOutTwoThreads += 1; log(r, "left-out-two-threads"); continue }
                    let fromMe = isMe(r.m)
                    // An incoming line with no sender at all is iChat's own notice (offline, could not deliver), not a message.
                    if !fromMe, r.m.sender == nil { stats.leftOutSender += 1; log(r, "left-out-no-sender"); continue }
                    var rec = MessageRecord(participants: [], sender: nil, tsMs: r.ts, isFromMe: fromMe, service: r.svc, body: text, sourceKey: r.key.isEmpty ? nil : r.key)
                    writer.threadOverride = nil
                    if let thread = threads.first {
                        if !fromMe {
                            guard let sid = r.m.sender?.id, let n = r.svc == "aim" ? ServiceHandle.aim(screenName: sid).normalized : HandleNormalizer.normalize(sid)?.normalized else {
                                stats.leftOutSender += 1; log(r, "left-out-sender-unknown", thread: thread); continue
                            }
                            isMember.bind(1, thread).bind(2, n)
                            let member = try isMember.step(); isMember.reset()
                            if !member { stats.leftOutSender += 1; log(r, "left-out-sender-not-member", thread: thread); continue }
                            if r.svc == "aim" { rec.senderHandle = ServiceHandle.aim(screenName: sid) } else { rec.sender = sid }
                        }
                        writer.threadOverride = thread
                    } else if t.chatRoom == nil, others.count == 1, let otherKey = others.first, let other = rawOf[otherKey],
                              r.svc == "aim" || HandleNormalizer.normalize(other) != nil {
                        if !fromMe, r.m.sender.map({ norm($0.id) }) != otherKey { stats.leftOutSender += 1; log(r, "left-out-sender-not-member"); continue }
                        if r.svc == "aim" {
                            rec.participantHandles = [ServiceHandle.aim(screenName: other)]
                            if !fromMe { rec.senderHandle = ServiceHandle.aim(screenName: other) }
                        } else {
                            rec.participants = [other]
                            if !fromMe { rec.sender = other }
                        }
                    } else { stats.leftOutNoThread += 1; log(r, "left-out-no-thread"); continue }
                    switch try writer.add(rec) {
                    case .inserted:
                        stats.inserted += 1; stats.byService[r.svc, default: 0] += 1
                        if r.svc == "aim" { aimThreads.insert(writer.lastThreadID) }
                        log(r, marks[r.key] ?? "new", thread: writer.lastThreadID, written: writer.lastMessageID)
                    case .duplicate:
                        stats.heldMatches += 1
                        log(r, writer.lastHeldOtherGuid ? "held-match-other-guid" : "held-match", archive: writer.lastHeldID, thread: writer.lastThreadID)
                    }
                }
            }
            // AIM threads this run created: mark their service, as the other service importers do.
            let up = try db.prepare("UPDATE thread SET service = 'aim', origin = 'dm' WHERE id = ? AND id > ?")
            for th in aimThreads { up.bind(1, th).bind(2, threadsBefore); try up.run() }
            let st = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try st.run()
            try ImportLedger.save(db, sourceID: sid, body: out.joined(separator: "\n") + "\n")
            report = IChatImportReport(status: .imported, sourceID: sid, stats: stats)
        }
        // Published after COMMIT from the stored copy; if this fails, a retry (already imported) publishes it again.
        if let ledger, let body = try ImportLedger.load(db, sourceID: report.sourceID) { try ImportLedger.publish(body, to: ledger) }
        return report
    }
}
