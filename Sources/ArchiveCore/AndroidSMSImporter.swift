import Foundation

public struct ImportStats: Codable, Equatable, Sendable {
    public var smsParsed = 0
    public var mmsParsed = 0
    public var inserted = 0            // new canonical rows
    public var duplicates = 0          // rows linked to a canonical row (kept for provenance)
    public var skippedInvalid = 0
    public var attachments = 0
    public var mediaBytes = 0          // bytes of attachment payloads seen
    public var mediaNewBytes = 0       // bytes actually written to the media store
    public var mediaNewFiles = 0
    public var smilParts = 0           // layout parts skipped
    public var seconds = 0.0
    public var peakScanBufferBytes = 0
    public var messagesParsed: Int { smsParsed + mmsParsed }
}

public struct ImportReport: Sendable {
    public enum Status: Sendable { case imported, alreadyImported }
    public var status: Status
    public var path: String
    public var sha256: String
    public var sourceID: Int64
    public var stats: ImportStats
}

public struct ImportProgress: Sendable {
    public var bytesRead: Int64
    public var totalBytes: Int64
    public var messages: Int
}

/// Imports an SMS Backup & Restore XML export. Streaming: the file is scanned once in 4 MB chunks, media payloads are
/// decoded straight into the content-addressed store, and the whole source is one transaction (an interrupted import
/// leaves nothing behind but unreferenced media files).
public enum AndroidSMSImporter {
    public static let kind = "android-xml"

    public static func importFile(at url: URL, into db: Database, root: ArchiveRoot, origin: String? = nil, scanChunkSize: Int = 4 << 20,
                                  progress: ((ImportProgress) -> Void)? = nil) throws -> ImportReport {
        let t0 = Date()
        let (sha, size) = try Hashing.sha256Hex(ofFile: url)
        let st = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        st.bind(1, sha)
        if try st.step() {
            let stats = st.string(1).flatMap { try? JSONDecoder().decode(ImportStats.self, from: Data($0.utf8)) } ?? ImportStats()
            return ImportReport(status: .alreadyImported, path: url.path, sha256: sha, sourceID: st.int(0), stats: stats)
        }
        st.reset()

        let store = MediaStore(root: root)
        var report: ImportReport!
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origin ?? url.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind)
            let handler = Handler(writer: writer, store: store, total: size, progress: progress)
            let scanner = try XMLScanner(fileURL: url, chunkSize: scanChunkSize)
            handler.scanner = scanner
            try scanner.scan(delegate: handler)
            var stats = handler.stats
            stats.seconds = Date().timeIntervalSince(t0)
            stats.peakScanBufferBytes = scanner.peakBufferBytes
            let json = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, json).bind(2, sid)
            try up.run()
            report = ImportReport(status: .imported, path: origin ?? url.path, sha256: sha, sourceID: sid, stats: stats)
        }
        return report
    }

    // MARK: SAX handler

    private final class Handler: XMLScannerDelegate {
        let writer: ArchiveWriter
        let store: MediaStore
        let total: Int64
        let progress: ((ImportProgress) -> Void)?
        weak var scanner: XMLScanner?
        var stats = ImportStats()
        var lastProgress = Date()

        // Current <mms> under construction.
        var inMMS = false
        var mms = MMS()

        struct MMS {
            var address = "", date: Int64 = 0, msgBox = 1, mID = "", trID = "", sub: String?, contactName = ""
            var texts: [String] = []
            var attachments: [AttachmentRecord] = []
            var addrs: [(address: String, type: Int)] = []
            var valid = true
        }

        init(writer: ArchiveWriter, store: MediaStore, total: Int64, progress: ((ImportProgress) -> Void)?) {
            self.writer = writer; self.store = store; self.total = total; self.progress = progress
        }

        @inline(__always) func eq(_ n: UnsafeBufferPointer<UInt8>, _ s: StaticString) -> Bool {
            n.count == s.utf8CodeUnitCount && memcmp(n.baseAddress!, s.utf8Start, n.count) == 0
        }

        func startElement(_ name: UnsafeBufferPointer<UInt8>, attributes: [XMLAttribute], selfClosing: Bool) throws {
            if eq(name, "sms") { try handleSMS(attributes) }
            else if eq(name, "mms") { inMMS = true; mms = MMS(); readMMSHeader(attributes) }
            else if eq(name, "part"), inMMS { try handlePart(attributes) }
            else if eq(name, "addr"), inMMS { handleAddr(attributes) }
        }

        func endElement(_ name: UnsafeBufferPointer<UInt8>) throws {
            if eq(name, "mms"), inMMS { inMMS = false; try finishMMS() }
        }

        static func clean(_ s: String?) -> String? {
            guard let s, !s.isEmpty, s != "null" else { return nil }
            return s
        }

        static func timestamp(_ s: String) -> Int64? {
            guard let v = Int64(s), v > 0 else { return nil }
            return v < 100_000_000_000 ? v * 1000 : v     // seconds sneaked in
        }

        func tick() {
            guard let progress, (stats.smsParsed + stats.mmsParsed) % 4000 == 0 else { return }
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 1 {
                lastProgress = now
                progress(ImportProgress(bytesRead: scanner?.bytesRead ?? 0, totalBytes: total, messages: stats.messagesParsed))
            }
        }

        func handleSMS(_ attrs: [XMLAttribute]) throws {
            stats.smsParsed += 1
            var address = "", date = "", type = "1", body: String? = nil, subject: String? = nil, contact = ""
            for a in attrs {
                if a.nameIs("address") { address = a.string }
                else if a.nameIs("date") { date = a.string }
                else if a.nameIs("type") { type = a.string }
                else if a.nameIs("body") { body = a.string }
                else if a.nameIs("subject") { subject = Self.clean(a.string) }
                else if a.nameIs("contact_name") { contact = a.string }
            }
            guard let ts = Self.timestamp(date) else { stats.skippedInvalid += 1; return }
            let fromMe = type != "1"
            let rec = MessageRecord(participants: [address], sender: fromMe ? nil : address, tsMs: ts, isFromMe: fromMe,
                                    service: "sms", body: body, subject: subject)
            try writer.noteName(forRaw: address, name: contact)
            try record(rec)
            tick()
        }

        func record(_ rec: MessageRecord) throws {
            switch try writer.add(rec) {
            case .inserted: stats.inserted += 1
            case .duplicate: stats.duplicates += 1
            }
        }

        func readMMSHeader(_ attrs: [XMLAttribute]) {
            var mid = "", tr = ""
            for a in attrs {
                if a.nameIs("address") { mms.address = a.string }
                else if a.nameIs("date") { if let t = Self.timestamp(a.string) { mms.date = t } else { mms.valid = false } }
                else if a.nameIs("msg_box") { mms.msgBox = Int(a.string) ?? 1 }
                else if a.nameIs("m_id") { mid = a.string }
                else if a.nameIs("tr_id") { tr = a.string }
                else if a.nameIs("sub") { mms.sub = Self.clean(a.string) }
                else if a.nameIs("contact_name") { mms.contactName = a.string }
            }
            mms.mID = mid; mms.trID = tr
        }

        func handleAddr(_ attrs: [XMLAttribute]) {
            var address = "", type = 0
            for a in attrs {
                if a.nameIs("address") { address = a.string }
                else if a.nameIs("type") { type = Int(a.string) ?? 0 }
            }
            mms.addrs.append((address, type))
        }

        func handlePart(_ attrs: [XMLAttribute]) throws {
            var seq = "0", ct = "", name: String?, fn: String?, cl: String?, text: String?
            var data: UnsafeBufferPointer<UInt8>? = nil
            for a in attrs {
                if a.nameIs("data") { if !a.isEmpty { data = a.value } }
                else if a.nameIs("seq") { seq = a.string }
                else if a.nameIs("ct") { ct = a.string }
                else if a.nameIs("name") { name = Self.clean(a.string) }
                else if a.nameIs("fn") { fn = Self.clean(a.string) }
                else if a.nameIs("cl") { cl = Self.clean(a.string) }
                else if a.nameIs("text") { text = a.string }
            }
            let lct = ct.lowercased()
            if seq == "-1" || lct == "application/smil" { stats.smilParts += 1; return }
            if lct.hasPrefix("text/plain") {
                if let text, !text.isEmpty, text != "null" { mms.texts.append(text); return }
                if let data {
                    let bytes = Base64Fast.decode(data)
                    mms.texts.append(String(decoding: bytes, as: UTF8.self))
                }
                return
            }
            guard let data else { return }
            let bytes = Base64Fast.decode(data)
            if bytes.isEmpty { return }
            let filename = fn ?? name ?? cl
            let stored = try bytes.withUnsafeBytes {
                try store.store($0, mime: ct.isEmpty ? nil : ct, filename: filename, lookup: { writer.existingMediaPath(sha256: $0) })
            }
            stats.attachments += 1
            stats.mediaBytes += stored.bytes
            if stored.wasNew { stats.mediaNewBytes += stored.bytes; stats.mediaNewFiles += 1 }
            mms.attachments.append(AttachmentRecord(mime: ct.isEmpty ? nil : ct, filename: filename, sha256: stored.sha256,
                                                    relativePath: stored.relativePath, bytes: stored.bytes))
        }

        func finishMMS() throws {
            stats.mmsParsed += 1
            guard mms.valid, mms.date > 0 else { stats.skippedInvalid += 1; return }
            // `address` lists the other participants ("a~b~c"); the <addr> list also contains me.
            var others = mms.address.split(separator: "~").map { String($0) }
            if others.isEmpty { others = mms.addrs.filter { $0.type == 137 || $0.type == 151 }.map { $0.address } }
            let fromMe = mms.msgBox != 1
            var sender: String? = nil
            if !fromMe {
                sender = mms.addrs.first(where: { $0.type == 137 })?.address ?? others.first
            }
            var key: String? = nil
            if let m = Self.clean(mms.mID) { key = "mms:m:" + m }
            else if let t = Self.clean(mms.trID) { key = "mms:t:" + t }
            let body = mms.texts.isEmpty ? nil : mms.texts.joined(separator: "\n")
            let rec = MessageRecord(participants: others, sender: sender, tsMs: mms.date, isFromMe: fromMe, service: "mms",
                                    body: body, subject: mms.sub, sourceKey: key, attachments: mms.attachments)
            if others.count == 1 { try writer.noteName(forRaw: others[0], name: mms.contactName) }
            try record(rec)
            tick()
        }
    }
}
