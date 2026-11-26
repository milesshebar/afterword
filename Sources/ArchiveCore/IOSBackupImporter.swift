import Foundation

public struct BackupImportStats: Codable, Equatable, Sendable {
    public var schema = ""                    // modern | legacy
    public var manifestFormat = ""            // db | mbdb
    public var messagesParsed = 0             // rows read from the message table
    public var inserted = 0                   // new canonical rows
    public var duplicates = 0                 // rows linked to a canonical row from another source (kept)
    public var reactionsSkipped = 0           // tapbacks (associated_message_type 2000-3999) whose target message is not in the archive
    public var reactionsImported = 0          // tapbacks stored as reactions on their target (3000-3999 remove one)
    public var emptySkipped = 0               // no text and no attachments (group renames, joins, ...)
    public var orphansSkipped = 0             // no chat and no handle: nobody to attach the message to
    public var invalidSkipped = 0             // no usable date
    public var groupSendCollapsed = 0         // iOS 5 sent group SMS stored once per recipient, folded into one
    public var attachmentsReferenced = 0      // attachment rows joined to imported messages
    public var attachmentsInManifest = 0      // found through the manifest (file may still be absent on disk)
    public var attachmentsInline = 0          // legacy MMS parts stored inside sms.db itself
    public var attachmentsStored = 0          // copied (or already present) in the media store and linked
    public var attachmentsMissing = 0         // referenced but not in the manifest, or listed but absent on disk
    public var mediaBytes = 0
    public var mediaNewBytes = 0
    public var mediaNewFiles = 0
    public var contactPeople = 0
    public var contactNames = 0               // name rows written for phone numbers and emails
    public var contactsNote: String?          // why contacts were not imported, if they were not
    public var seconds = 0.0
}

public struct BackupImportReport: Sendable {
    public var status: ImportReport.Status
    public var path: String
    public var sha256: String
    public var sourceID: Int64
    public var stats: BackupImportStats
}

/// Epoch handling for sms.db, which mixes four conventions across schema generations.
public enum IOSDates {
    public static let appleEpochOffsetSeconds: Int64 = 978_307_200

    /// iOS 10 stores Apple-epoch seconds; iOS 11+ (and chat.db) stores Apple-epoch nanoseconds. Told apart by
    /// magnitude: nanoseconds since 2001 pass 1e11 within two minutes, while seconds stay below 1e11 until year 5000.
    public static func modernToUnixMs(_ v: Int64) -> Int64? {
        if v <= 0 { return nil }
        if v >= 100_000_000_000 { return v / 1_000_000 + appleEpochOffsetSeconds * 1000 }
        return (v + appleEpochOffsetSeconds) * 1000
    }

    /// iOS 5: SMS rows (is_madrid = 0) carry Unix seconds, iMessage rows (is_madrid = 1) Apple-epoch seconds.
    public static func legacyToUnixMs(_ v: Int64, isMadrid: Bool) -> Int64? {
        if v <= 0 { return nil }
        if v >= 100_000_000_000 { return modernToUnixMs(v) }       // defensively: ns or ms never appear in iOS 5
        return isMadrid ? (v + appleEpochOffsetSeconds) * 1000 : v * 1000
    }
}

/// Imports an unencrypted iPhone backup folder: sms.db (modern iOS 10+ or legacy iOS 5 schema), its attachments
/// resolved through the manifest into the media store, and the backup's AddressBook as contact names. The whole backup
/// is one transaction and one `source` row keyed by the SHA-256 of sms.db (so identical snapshots import once).
public enum IOSBackupImporter {
    public static let kind = "ios-backup"
    public static let smsDomain = "HomeDomain"
    public static let smsPath = "Library/SMS/sms.db"
    public static let addressBookPath = "Library/AddressBook/AddressBook.sqlitedb"

    public static func isBackupFolder(_ url: URL) -> Bool { BackupManifest.isBackupFolder(url) }

    public static func importBackup(at folder: URL, into db: Database, root: ArchiveRoot, origin: String? = nil,
                                    progress: ((ImportProgress) -> Void)? = nil) throws -> BackupImportReport {
        let manifest = try BackupManifest(folder: folder)
        guard let smsURL = manifest.fileURL(domain: smsDomain, path: smsPath) else {
            throw ArchiveError("\(folder.path): sms.db (\(BackupManifest.fileID(domain: smsDomain, path: smsPath))) is not in this backup")
        }
        return try run(manifest: manifest, contacts: manifest, smsURL: smsURL, displayPath: folder.path, into: db, root: root, origin: origin, progress: progress)
    }

    /// A decrypted extract made by `scripts/iphone-backup-stage.py` (`extracted/sms/<Domain>/<path>`, attachments beside sms.db).
    /// Contacts are not read from it (`extracted/addressbook` is a separate tree; see `importAddressBook`).
    public static func importExtractedTree(sms folder: URL, into db: Database, root: ArchiveRoot, origin: String? = nil,
                                           progress: ((ImportProgress) -> Void)? = nil) throws -> BackupImportReport {
        let manifest = BackupManifest(tree: folder)
        guard let smsURL = manifest.fileURL(domain: smsDomain, path: smsPath) else {
            throw ArchiveError("\(folder.path): no HomeDomain/Library/SMS/sms.db in this extract")
        }
        return try run(manifest: manifest, contacts: nil, smsURL: smsURL, displayPath: folder.path, into: db, root: root, origin: origin, progress: progress)
    }

    static func run(manifest: BackupManifest, contacts: BackupManifest?, smsURL: URL, displayPath: String, into db: Database, root: ArchiveRoot,
                    origin: String?, progress: ((ImportProgress) -> Void)?) throws -> BackupImportReport {
        let t0 = Date()
        let folder = URL(fileURLWithPath: displayPath)
        let (sha, size) = try Hashing.sha256Hex(ofFile: smsURL)
        let st = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        st.bind(1, sha)
        if try st.step() {
            let stats = st.string(1).flatMap { try? JSONDecoder().decode(BackupImportStats.self, from: Data($0.utf8)) } ?? BackupImportStats()
            return BackupImportReport(status: .alreadyImported, path: folder.path, sha256: sha, sourceID: st.int(0), stats: stats)
        }
        st.reset()

        let sms = try Database(path: smsURL.path, readOnly: true, immutable: true)
        let store = MediaStore(root: root)
        var report: BackupImportReport!
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origin ?? folder.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let modern = try sms.tableExists("chat_message_join")
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind, sourceTier: modern ? SourceTier.modernIOS : SourceTier.legacyIOS)
            var stats = BackupImportStats()
            stats.manifestFormat = manifest.format.rawValue
            let ctx = Context(writer: writer, store: store, manifest: manifest, progress: progress)

            if modern {
                stats.schema = "modern"
                try ModernReader(sms: sms, ctx: ctx).run(&stats)
            } else if try sms.tableExists("msg_group") {
                stats.schema = "legacy"
                try LegacyReader(sms: sms, ctx: ctx).run(&stats)
            } else {
                throw ArchiveError("sms.db has neither the modern (chat_message_join) nor the legacy (msg_group) tables")
            }
            if let contacts { try importContacts(manifest: contacts, writer: writer, stats: &stats) } else { stats.contactsNote = "contacts not read from this extract" }

            stats.seconds = Date().timeIntervalSince(t0)
            let json = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, json).bind(2, sid)
            try up.run()
            report = BackupImportReport(status: .imported, path: origin ?? folder.path, sha256: sha, sourceID: sid, stats: stats)
        }
        return report
    }

    // MARK: shared plumbing

    final class Context {
        let writer: ArchiveWriter
        let store: MediaStore
        let manifest: BackupManifest
        let progress: ((ImportProgress) -> Void)?
        var lastProgress = Date()
        init(writer: ArchiveWriter, store: MediaStore, manifest: BackupManifest, progress: ((ImportProgress) -> Void)?) {
            self.writer = writer; self.store = store; self.manifest = manifest; self.progress = progress
        }

        func tick(done: Int, total: Int) {
            guard let progress, done % 2000 == 0 else { return }
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 1 {
                lastProgress = now
                progress(ImportProgress(bytesRead: Int64(done), totalBytes: Int64(total), messages: done))
            }
        }

        func record(_ rec: MessageRecord, _ stats: inout BackupImportStats) throws {
            switch try writer.add(rec) {
            case .inserted: stats.inserted += 1
            case .duplicate: stats.duplicates += 1
            }
        }

        /// Maps an attachment path as recorded on the phone (`~/Library/SMS/Attachments/...`) to candidate
        /// (domain, relativePath) pairs, tries them against the manifest, and copies the file into the media store.
        func attach(storedPath: String, filename: String?, mime: String?, inlineData: Data? = nil, part: (messageID: Int64, partID: Int64)? = nil, _ stats: inout BackupImportStats) throws -> AttachmentRecord? {
            stats.attachmentsReferenced += 1
            let name = filename?.nilIfEmpty ?? (storedPath as NSString).lastPathComponent.nilIfEmpty
            if let inlineData, !inlineData.isEmpty {
                stats.attachmentsInline += 1
                return try storeBytes(inlineData, mime: mime, filename: name, &stats)
            }
            let rel = Self.relativePath(fromStored: storedPath)
            var inManifest = false
            var cands = Self.candidates(rel)
            if let part, let hit = manifest.smsPart(messageID: part.messageID, partID: part.partID) { cands.insert((hit.domain, hit.path), at: 0) }
            else if storedPath.isEmpty { cands = [] }
            for (domain, path) in cands {
                guard manifest.contains(domain: domain, path: path) else { continue }
                inManifest = true
                if let url = manifest.fileURL(domain: domain, path: path) {
                    stats.attachmentsInManifest += 1
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    return try storeBytes(data, mime: mime, filename: name, &stats)
                }
            }
            if inManifest { stats.attachmentsInManifest += 1 }
            stats.attachmentsMissing += 1
            return nil
        }

        private func storeBytes(_ data: Data, mime: String?, filename: String?, _ stats: inout BackupImportStats) throws -> AttachmentRecord {
            let stored = try data.withUnsafeBytes {
                try store.store($0, mime: mime, filename: filename, lookup: { writer.existingMediaPath(sha256: $0) })
            }
            stats.attachmentsStored += 1
            stats.mediaBytes += stored.bytes
            if stored.wasNew { stats.mediaNewBytes += stored.bytes; stats.mediaNewFiles += 1 }
            return AttachmentRecord(mime: mime, filename: filename, sha256: stored.sha256, relativePath: stored.relativePath, bytes: stored.bytes)
        }

        static func relativePath(fromStored p: String) -> String {
            for prefix in ["~/", "/var/mobile/", "/private/var/mobile/"] where p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
            return p.hasPrefix("/") ? String(p.dropFirst()) : p
        }

        static func candidates(_ rel: String) -> [(String, String)] {
            var out = [("MediaDomain", rel), ("HomeDomain", rel)]
            if !rel.hasPrefix("Library/") { out += [("MediaDomain", "Library/SMS/Parts/" + rel), ("HomeDomain", "Library/SMS/Parts/" + rel)] }
            return out
        }
    }

    /// Text of an iMessage: the object-replacement characters that stand in for attachments are removed.
    static func cleanBody(_ s: String?) -> String? {
        guard var s, !s.isEmpty else { return nil }
        if s.contains("\u{FFFC}") { s = s.replacingOccurrences(of: "\u{FFFC}", with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func decodeBody(text: String?, attributedBody: Data?) -> String? {
        if let t = cleanBody(text) { return t }
        guard let attributedBody, !attributedBody.isEmpty else { return nil }
        return cleanBody(TypedStream.attributedBodyText([UInt8](attributedBody)))
    }

    /// 2000 love, 2001 like, 2002 dislike, 2003 laugh, 2004 emphasize, 2005 question; 3000-3005 remove the same.
    /// 2006 / 3006 (iOS 17+) carry their own emoji in `associated_message_emoji`, passed as `emoji`.
    static func tapbackEmoji(_ type: Int64, emoji: String? = nil) -> String? {
        switch type % 1000 {
        case 0: return "❤️"
        case 1: return "👍"
        case 2: return "👎"
        case 3: return "😂"
        case 4: return "‼️"
        case 5: return "❓"
        case 6: return emoji?.nilIfEmpty
        default: return nil
        }
    }

    /// The target guid of a tapback: "p:<part>/<guid>" or "bp:<guid>" -> "<guid>".
    static func tapbackTarget(_ g: String) -> String {
        if let slash = g.lastIndex(of: "/") { return String(g[g.index(after: slash)...]) }
        return g.hasPrefix("bp:") ? String(g.dropFirst(3)) : g
    }

    // MARK: modern (iOS 10+)

    private struct ModernReader {
        let sms: Database
        let ctx: Context

        func run(_ stats: inout BackupImportStats) throws {
            var handles: [Int64: String] = [:]
            let h = try sms.prepare("SELECT ROWID, id FROM handle")
            while try h.step() { if let id = h.string(1) { handles[h.int(0)] = id } }
            var chatMembers: [Int64: [String]] = [:]
            let cj = try sms.prepare("SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id")
            while try cj.step() { if let id = handles[cj.int(1)] { chatMembers[cj.int(0), default: []].append(id) } }

            let hasAssoc = try sms.hasColumn("message", "associated_message_type")
            let total = Int(try sms.scalarInt("SELECT count(*) FROM message"))
            let msgs = try sms.prepare("""
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, m.subject, m.service, m.date, m.is_from_me,
                       \(hasAssoc ? "m.associated_message_type" : "0"),
                       (SELECT chat_id FROM chat_message_join j WHERE j.message_id = m.ROWID ORDER BY chat_id LIMIT 1),
                       \(hasAssoc ? "m.associated_message_guid" : "NULL")
                FROM message m ORDER BY m.ROWID
                """)
            let atts = try sms.prepare("""
                SELECT a.filename, a.transfer_name, a.mime_type
                FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE j.message_id = ? ORDER BY j.attachment_id
                """)
            var done = 0
            var deferred: [(emoji: String, removal: Bool, target: String, byMe: Bool, actor: String?)] = []
            while try msgs.step() {
                done += 1
                stats.messagesParsed += 1
                ctx.tick(done: done, total: total)
                let rowid = msgs.int(0)
                let assoc = msgs.int(9)
                if assoc >= 2000 && assoc < 4000 {
                    // Resolved once every message is in: the target's guid is "p:<part>/<guid>" or "bp:<guid>".
                    if let g = msgs.string(11), let tb = Self.tapbackEmoji(assoc) {
                        let guid = g.contains("/") ? String(g[g.index(after: g.lastIndex(of: "/")!)...]) : (g.hasPrefix("bp:") ? String(g.dropFirst(3)) : g)
                        let fromMe = msgs.int(8) != 0
                        deferred.append((tb, assoc >= 3000, "ios:" + guid, fromMe, msgs.optInt(4).flatMap { $0 == 0 ? nil : handles[$0] }))
                    } else { stats.reactionsSkipped += 1 }
                    continue
                }
                guard let ts = IOSDates.modernToUnixMs(msgs.int(7)) else { stats.invalidSkipped += 1; continue }
                let fromMe = msgs.int(8) != 0
                let handleRaw = msgs.optInt(4).flatMap { $0 == 0 ? nil : handles[$0] }
                var participants: [String] = []
                if let chat = msgs.optInt(10), let members = chatMembers[chat], !members.isEmpty { participants = members }
                else if let h = handleRaw { participants = [h] }
                if participants.isEmpty { stats.orphansSkipped += 1; continue }

                var records: [AttachmentRecord] = []
                var referenced = 0
                atts.bind(1, rowid)
                while try atts.step() {
                    guard let stored = atts.string(0) else { continue }
                    referenced += 1
                    if let rec = try ctx.attach(storedPath: stored, filename: atts.string(1), mime: atts.string(2)?.nilIfEmpty, &stats) { records.append(rec) }
                }
                atts.reset()

                let body = decodeBody(text: msgs.string(2), attributedBody: msgs.blob(3))
                if body == nil && referenced == 0 { stats.emptySkipped += 1; continue }

                var sender: String? = nil
                if !fromMe { sender = handleRaw ?? (participants.count == 1 ? participants[0] : nil) }
                var service = (msgs.string(6) ?? "").lowercased()
                if service == "imessage" || service == "sms" {} else if service.isEmpty { service = "sms" }
                if service == "sms" && referenced > 0 { service = "mms" }
                let guid = msgs.string(1)?.nilIfEmpty
                let rec = MessageRecord(participants: participants, sender: sender, tsMs: ts, isFromMe: fromMe, service: service,
                                        body: body, subject: msgs.string(5)?.nilIfEmpty, sourceKey: guid.map { "ios:" + $0 }, attachments: records)
                try ctx.record(rec, &stats)
            }
            // Tapbacks (2000-2005) and their removals (3000-3005) in message order, now that every target is stored.
            for t in deferred {
                if try ctx.writer.addTapback(targetSourceKey: t.target, emoji: t.emoji, actorRaw: t.actor, byMe: t.byMe, removal: t.removal) {
                    stats.reactionsImported += 1
                } else { stats.reactionsSkipped += 1 }
            }
        }

        static func tapbackEmoji(_ type: Int64) -> String? { IOSBackupImporter.tapbackEmoji(type) }
    }

    // MARK: legacy (iOS 5)

    private struct LegacyReader {
        let sms: Database
        let ctx: Context

        func run(_ stats: inout BackupImportStats) throws {
            func col(_ name: String) throws -> String {
                try sms.hasColumn("message", name) ? "m.\(name)" : "NULL"
            }
            var members: [Int64: [String]] = [:]
            if try sms.tableExists("group_member") {
                let g = try sms.prepare("SELECT group_id, address FROM group_member ORDER BY group_id, ROWID")
                while try g.step() { if let a = g.string(1)?.nilIfEmpty { members[g.int(0), default: []].append(a) } }
            }
            let total = Int(try sms.scalarInt("SELECT count(*) FROM message"))
            let msgs = try sms.prepare("""
                SELECT m.ROWID, \(try col("address")), \(try col("date")), \(try col("text")), \(try col("flags")), \(try col("group_id")),
                       \(try col("subject")), \(try col("madrid_attributedBody")), \(try col("madrid_handle")), \(try col("madrid_guid")),
                       \(try col("is_madrid")), \(try col("madrid_flags"))
                FROM message m ORDER BY m.ROWID
                """)
            var pieces: Statement? = nil
            if try sms.tableExists("msg_pieces") {
                func pc(_ n: String) throws -> String { try sms.hasColumn("msg_pieces", n) ? n : "NULL" }
                pieces = try sms.prepare("SELECT \(try pc("content_type")), \(try pc("data")), \(try pc("content_loc")), \(try pc("part_id")) FROM msg_pieces WHERE message_id = ? ORDER BY ROWID")
            }
            var madridAtts: Statement? = nil
            if try sms.tableExists("madrid_attachment"), try sms.hasColumn("madrid_attachment", "message_id"), try sms.hasColumn("madrid_attachment", "filename") {
                let mime = try sms.hasColumn("madrid_attachment", "mime_type") ? "mime_type" : "NULL"
                madridAtts = try sms.prepare("SELECT filename, \(mime) FROM madrid_attachment WHERE message_id = ? ORDER BY ROWID")
            }
            struct Piece { var ct: String; var data: Data?; var loc: String?; var partID: Int64? }
            var sentGroupSeen = Set<String>()
            var done = 0
            while try msgs.step() {
                done += 1
                stats.messagesParsed += 1
                ctx.tick(done: done, total: total)
                let rowid = msgs.int(0)
                let isMadrid = msgs.int(10) != 0
                guard let ts = IOSDates.legacyToUnixMs(msgs.int(2), isMadrid: isMadrid) else { stats.invalidSkipped += 1; continue }
                let address = msgs.string(1)?.nilIfEmpty
                let madridHandle = msgs.string(8)?.nilIfEmpty
                let other = address ?? madridHandle
                var participants: [String] = []
                var inGroup = false
                if let gid = msgs.optInt(5), let m = members[gid], !m.isEmpty { participants = m; inGroup = m.count > 1 }
                else if let o = other { participants = [o] }
                if participants.isEmpty { stats.orphansSkipped += 1; continue }
                // SMS: flags bit 0 = sent (2 received, 3 sent). iMessage rows all have flags 0; their direction is madrid_flags bit 2.
                let fromMe = isMadrid ? (msgs.int(11) & 4) != 0 : (msgs.int(4) & 1) == 1

                var body = decodeBody(text: msgs.string(3), attributedBody: msgs.blob(7))
                var parts: [Piece] = []
                var texts: [String] = []
                if let pieces {
                    pieces.bind(1, rowid)
                    while try pieces.step() {
                        let ct = (pieces.string(0) ?? "").lowercased()
                        let data = pieces.blob(1)
                        let loc = pieces.string(2)?.nilIfEmpty
                        if ct == "application/smil" { continue }
                        if ct.hasPrefix("text/plain") {
                            if let d = data, let t = cleanBody(String(decoding: d, as: UTF8.self)) { texts.append(t) }
                            continue
                        }
                        if data == nil && loc == nil { continue }
                        parts.append(Piece(ct: ct, data: data, loc: loc, partID: pieces.optInt(3)))
                    }
                    pieces.reset()
                    if body == nil, !texts.isEmpty { body = texts.joined(separator: "\n") }
                }
                var madrid: [(path: String, mime: String?)] = []
                if let madridAtts {
                    madridAtts.bind(1, rowid)
                    while try madridAtts.step() { if let f = madridAtts.string(0)?.nilIfEmpty { madrid.append((f, madridAtts.string(1)?.nilIfEmpty)) } }
                    madridAtts.reset()
                }
                let referenced = parts.count + madrid.count
                if body == nil && referenced == 0 { stats.emptySkipped += 1; continue }

                // A sent SMS to a group is stored once per recipient: same group, date and text, different address.
                if !isMadrid && fromMe && inGroup {
                    let key = "\(msgs.int(5))|\(ts)|\(Hashing.normalizedBody(body))|\(parts.compactMap(\.loc).joined(separator: ","))|\(madrid.count)"
                    if !sentGroupSeen.insert(key).inserted { stats.groupSendCollapsed += 1; continue }
                }

                var records: [AttachmentRecord] = []
                for p in parts {
                    let partRef = p.partID.map { (messageID: rowid, partID: $0) }
                    if let rec = try ctx.attach(storedPath: p.loc ?? "", filename: p.loc.map { ($0 as NSString).lastPathComponent },
                                                mime: p.ct.nilIfEmpty, inlineData: p.data, part: partRef, &stats) { records.append(rec) }
                }
                for m in madrid {
                    if let rec = try ctx.attach(storedPath: m.path, filename: nil, mime: m.mime, &stats) { records.append(rec) }
                }

                var sender: String? = nil
                if !fromMe { sender = (isMadrid ? madridHandle ?? address : address ?? madridHandle) ?? (participants.count == 1 ? participants[0] : nil) }
                var service = isMadrid ? "imessage" : "sms"
                if service == "sms" && referenced > 0 { service = "mms" }
                let guid = isMadrid ? msgs.string(9)?.nilIfEmpty : nil
                let rec = MessageRecord(participants: participants, sender: sender, tsMs: ts, isFromMe: fromMe, service: service,
                                        body: body, subject: msgs.string(6)?.nilIfEmpty, sourceKey: guid.map { "ios:" + $0 }, attachments: records)
                try ctx.record(rec, &stats)
            }
        }
    }

    // MARK: contacts

    /// ABPerson + ABMultiValue (property 3 = phone, 4 = email) -> contact_name, origin iphone-addressbook.
    static func importContacts(manifest: BackupManifest, writer: ArchiveWriter, stats: inout BackupImportStats) throws {
        guard let url = manifest.fileURL(domain: "HomeDomain", path: addressBookPath) else {
            stats.contactsNote = "no AddressBook.sqlitedb in this backup"
            return
        }
        do {
            let ab = try Database(path: url.path, readOnly: true, immutable: true)
            var names: [Int64: String] = [:]
            let p = try ab.prepare("SELECT ROWID, First, Last, Organization, Nickname FROM ABPerson")
            while try p.step() {
                let person = [p.string(1), p.string(2)].compactMap { $0?.trimmingCharacters(in: .whitespaces).nilIfEmpty }.joined(separator: " ")
                let name = person.nilIfEmpty ?? p.string(3)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                    ?? p.string(4)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                if let name { names[p.int(0)] = name }
            }
            stats.contactPeople = names.count
            let mv = try ab.prepare("SELECT record_id, value FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL ORDER BY UID")
            while try mv.step() {
                guard let name = names[mv.int(0)], let value = mv.string(1) else { continue }
                try writer.noteName(forRaw: value, name: name, origin: ContactOrigin.iphoneAddressBook, priority: ContactPriority.iphoneAddressBook)
                stats.contactNames += 1
            }
        } catch {
            stats.contactsNote = "AddressBook not imported: \(error)"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
