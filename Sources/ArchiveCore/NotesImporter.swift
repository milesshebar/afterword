import Foundation
#if canImport(Compression)
import Compression
#endif

/// Apple Notes from an iPhone backup's `NoteStore.sqlite` (a decrypted extract) as an additive, source-tagged table `note`
/// (`CREATE TABLE IF NOT EXISTS`, no schema version bump). Read-only on the extract. **Notes are private**: they live in the local
/// archive (which already holds the messages) and nowhere else; the stats print counts only.
///
/// One row per `ICNote` (entity 12): title, snippet, folder, account, created/modified times, the flags (deleted, password-protected) and
/// the body text. The body is `ZICNOTEDATA.ZDATA`, gzip over a protobuf (Document -> Note -> text); the text is decoded here. Password-protected
/// notes keep their title and times and have no body (their data is encrypted); notes whose data cannot be decoded are counted. Attachments
/// (drawings, scans, images) are not stored: the body holds the object-replacement character where they sit. Idempotent: the same file
/// imports once, and a later backup adds only notes whose identifier is not in the table.
public enum NotesImporter {
    public static let kind = "ios-notes"
    static let appleEpoch: Int64 = 978_307_200

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS note (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES source(id),
            source_label TEXT NOT NULL,
            uid TEXT,                          -- the note's identifier (UUID)
            title TEXT,
            snippet TEXT,
            folder TEXT,
            account TEXT,
            created_ms INTEGER,
            modified_ms INTEGER,
            deleted INTEGER NOT NULL DEFAULT 0,       -- in Recently Deleted
            locked INTEGER NOT NULL DEFAULT 0,        -- password protected: no body
            body TEXT,                                 -- the text (NULL when locked or undecodable)
            dkey TEXT NOT NULL UNIQUE
        )
        """,
        "CREATE INDEX IF NOT EXISTS note_modified ON note(modified_ms)",
    ]

    public struct Report: Sendable, Codable, Equatable {
        public var label = ""
        public var alreadyImported = false
        public var notes = 0, inserted = 0, alreadyThere = 0
        public var withBody = 0, locked = 0, deleted = 0, undecodable = 0, noData = 0
        public var bodyChars = 0
        public var folders = 0
        public var firstTsMs: Int64?, lastTsMs: Int64?       // modified times
        public var byYear: [String: Int] = [:]               // by modification year
    }

    public static func ensureTables(_ db: Database) throws { for s in tableSQL { try db.exec(s) } }

    /// `path`: `NoteStore.sqlite`, or the folder `extracted/notes` / `AppDomainGroup-group.com.apple.notes`.
    public static func importNotes(at path: URL, label: String, into db: Database, origin: String? = nil) throws -> Report {
        var url = path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
            let a = path.appendingPathComponent("NoteStore.sqlite")
            url = FileManager.default.fileExists(atPath: a.path) ? a : path.appendingPathComponent("AppDomainGroup-group.com.apple.notes/NoteStore.sqlite")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError("no NoteStore.sqlite at \(url.path)") }
        try ensureTables(db)
        let (sha, size) = try Hashing.sha256Hex(ofFile: url)
        let seen = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, sha)
        if try seen.step() {
            var r = seen.string(0).flatMap { try? JSONDecoder().decode(Report.self, from: Data($0.utf8)) } ?? Report()
            r.alreadyImported = true
            seen.reset()
            return r
        }
        seen.reset()
        var report = Report()
        report.label = label
        let ns = try Database(path: url.path, readOnly: true, immutable: true)
        // Entity numbers differ between iOS versions: find the note and account/folder entities by name.
        let noteEnt = try ns.scalarInt("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote'")
        let q = try ns.prepare("""
            SELECT n.Z_PK, n.ZIDENTIFIER, n.ZTITLE1, n.ZSNIPPET, f.ZTITLE2, a.ZNAME, n.ZCREATIONDATE1, n.ZMODIFICATIONDATE1,
                   coalesce(n.ZMARKEDFORDELETION, 0), coalesce(n.ZISPASSWORDPROTECTED, 0), d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = n.ZACCOUNT4
            LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
            WHERE n.Z_ENT = \(noteEnt) ORDER BY n.Z_PK
            """)
        func ms(_ v: Double) -> Int64 { (Int64(v) + appleEpoch) * 1000 }
        var folders = Set<String>()
        try db.transaction {
            let src = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            src.bind(1, kind).bind(2, origin ?? url.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try src.run()
            let sid = db.lastInsertRowID
            let ins = try db.prepare("""
                INSERT OR IGNORE INTO note(source_id, source_label, uid, title, snippet, folder, account, created_ms, modified_ms, deleted, locked, body, dkey)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            while try q.step() {
                report.notes += 1
                let uid = q.string(1)
                let locked = q.int(9) != 0, deleted = q.int(8) != 0
                var body: String?
                if !locked {
                    if let data = q.blob(10), !data.isEmpty {
                        body = decodeBody(data)
                        if body == nil { report.undecodable += 1 }
                    } else { report.noData += 1 }
                }
                let modified: Int64? = q.isNull(7) ? nil : ms(q.double(7))
                ins.bind(1, sid).bind(2, label).bind(3, uid).bind(4, q.string(2)).bind(5, q.string(3)).bind(6, q.string(4)).bind(7, q.string(5))
                    .bind(8, q.isNull(6) ? nil : ms(q.double(6))).bind(9, modified).bind(10, deleted).bind(11, locked).bind(12, body)
                    .bind(13, uid ?? "pk:\(q.int(0))")
                try ins.run()
                if db.changes == 0 { report.alreadyThere += 1; continue }
                report.inserted += 1
                if locked { report.locked += 1 }
                if deleted { report.deleted += 1 }
                if let b = body { report.withBody += 1; report.bodyChars += b.count }
                if let f = q.string(4) { folders.insert(f) }
                if let m = modified {
                    report.firstTsMs = min(report.firstTsMs ?? m, m); report.lastTsMs = max(report.lastTsMs ?? m, m)
                    report.byYear[String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(m) / 1000)).prefix(4)), default: 0] += 1
                }
            }
            q.reset()
            report.folders = folders.count
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(report), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return report
    }

    // MARK: body

    /// gzip -> protobuf (field 2 Document -> field 3 Note -> field 2 text). nil when it is not that shape.
    static func decodeBody(_ data: Data) -> String? {
        guard let raw = gunzip(data) else { return nil }
        guard let doc = field(raw, 2), let note = field(doc, 3), let text = field(note, 2) else { return nil }
        return String(data: text, encoding: .utf8)
    }

    /// First length-delimited field `number` at the top level of a protobuf message.
    static func field(_ data: Data, _ number: Int) -> Data? {
        let b = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let x = b[i]; i += 1
                v |= UInt64(x & 0x7F) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let tag = varint() else { return nil }
            let num = Int(tag >> 3), wire = Int(tag & 7)
            switch wire {
            case 0: guard varint() != nil else { return nil }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), i + Int(len) <= b.count else { return nil }
                if num == number { return Data(b[i..<(i + Int(len))]) }
                i += Int(len)
            default: return nil
            }
        }
        return nil
    }

    /// Apple's Compression framework inflates the note data. There is no such module on Linux (the web app's container builds there):
    /// Notes are only ever imported on the Mac, so off-Apple platforms return nil (every body counts as undecodable) and still compile.
    static func gunzip(_ data: Data) -> Data? {
    #if canImport(Compression)
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        var start = 10
        let flags = b[3]
        if flags & 4 != 0 { guard start + 2 <= b.count else { return nil }; start += 2 + Int(b[start]) + Int(b[start + 1]) << 8 }
        if flags & 8 != 0 { while start < b.count, b[start] != 0 { start += 1 }; start += 1 }
        if flags & 16 != 0 { while start < b.count, b[start] != 0 { start += 1 }; start += 1 }
        if flags & 2 != 0 { start += 2 }
        guard start < b.count - 8 else { return nil }
        let deflated = Array(b[start..<(b.count - 8)])
        // ISIZE (the last 4 bytes, little endian) sizes the output; capped so a bad file cannot ask for gigabytes.
        let isize = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        let cap = min(max(isize, 64), 64 << 20)
        var out = [UInt8](repeating: 0, count: cap)
        let n = deflated.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, cap, src.baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? Data(out[0..<n]) : nil
    #else
        return nil
    #endif
    }

    public static func summary(_ db: Database) throws -> (rows: Int, withBody: Int, first: Int64?, last: Int64?)? {
        guard try db.tableExists("note") else { return nil }
        let q = try db.prepare("SELECT count(*), sum(body IS NOT NULL), min(modified_ms), max(modified_ms) FROM note")
        defer { q.reset() }
        guard try q.step() else { return nil }
        return (Int(q.int(0)), Int(q.int(1)), q.optInt(2), q.optInt(3))
    }
}

extension NotesImporter {
    public static let v7Kind = "macos-notes-v7"

    /// The Mac's local Notes store from before iCloud Notes (`~/Library/Containers/com.apple.Notes/Data/Library/Notes/NotesV7.storedata`,
    /// Core Data with HTML bodies; an older Mac's 2012-15 notes). Take a snapshot with its WAL folded in first: it is opened
    /// immutable. Add-only into `note`: a note is held (not stored) when the table already has its uid, the same title created within a minute,
    /// or the same text (all whitespace removed); nothing already in the table changes. Idempotent by the file's SHA-256.
    public static func importNotesV7(at url: URL, label: String, into db: Database, origin: String? = nil) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError("no NotesV7.storedata at \(url.path)") }
        try ensureTables(db)
        let (sha, size) = try Hashing.sha256Hex(ofFile: url)
        let seen = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, sha)
        if try seen.step() {
            var r = seen.string(0).flatMap { try? JSONDecoder().decode(Report.self, from: Data($0.utf8)) } ?? Report()
            r.alreadyImported = true
            seen.reset()
            return r
        }
        seen.reset()
        var report = Report()
        report.label = label
        let ns = try Database(path: url.path, readOnly: true, immutable: true)
        guard try ns.tableExists("ZNOTEBODY") else { throw ArchiveError("\(url.path) is not a NotesV7 store") }
        func squash(_ s: String?) -> String { (s ?? "").filter { !$0.isWhitespace } }
        var uids = Set<String>(), texts = Set<String>(), titled: [String: [Int64]] = [:]
        let k = try db.prepare("SELECT uid, title, created_ms, body FROM note")
        while try k.step() {
            if let u = k.string(0) { uids.insert(u) }
            if let t = k.string(1), let c = k.optInt(2) { titled[t, default: []].append(c) }
            let b = squash(k.string(3)); if !b.isEmpty { texts.insert(b) }
        }
        let q = try ns.prepare("""
            SELECT n.Z_PK, n.ZUNIVERSALLYUNIQUEID, n.ZTITLE, f.ZNAME, n.ZDATECREATED, n.ZDATEEDITED, b.ZHTMLSTRING
            FROM ZNOTE n LEFT JOIN ZNOTEBODY b ON b.Z_PK = n.ZBODY LEFT JOIN ZFOLDER f ON f.Z_PK = n.ZFOLDER ORDER BY n.Z_PK
            """)
        func ms(_ v: Double) -> Int64 { (Int64(v) + appleEpoch) * 1000 }
        var folders = Set<String>()
        try db.transaction {
            let src = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            src.bind(1, v7Kind).bind(2, origin ?? url.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
            try src.run()
            let sid = db.lastInsertRowID
            let ins = try db.prepare("""
                INSERT INTO note(source_id, source_label, uid, title, snippet, folder, account, created_ms, modified_ms, deleted, locked, body, dkey)
                VALUES (?,?,?,?,?,?,NULL,?,?,0,0,?,?)
                """)
            while try q.step() {
                report.notes += 1
                let uid = v7UUID(q.blob(1)) ?? q.string(1)?.nilIfEmpty
                let title = q.string(2)
                let created: Int64? = q.isNull(4) ? nil : ms(q.double(4))
                let modified: Int64? = q.isNull(5) ? nil : ms(q.double(5))
                let body = q.string(6).map(htmlText)
                let sameTitle = title.flatMap { titled[$0] }.map { cs in cs.contains { c in created.map { abs($0 - c) <= 60_000 } ?? false } } ?? false
                if (uid.map(uids.contains) ?? false) || sameTitle || (!squash(body).isEmpty && texts.contains(squash(body))) {
                    report.alreadyThere += 1; continue
                }
                let snippet = body.map { String($0.split(separator: "\n").dropFirst().joined(separator: " ").prefix(100)) }?.nilIfEmpty
                ins.bind(1, sid).bind(2, label).bind(3, uid).bind(4, title).bind(5, snippet).bind(6, q.string(3))
                    .bind(7, created).bind(8, modified).bind(9, body).bind(10, "\(label)|v7:\(uid ?? "pk:\(q.int(0))")")
                try ins.run()
                // What was just written holds later copies in the same store too.
                if let uid { uids.insert(uid) }
                if let title, let created { titled[title, default: []].append(created) }
                if !squash(body).isEmpty { texts.insert(squash(body)) }
                report.inserted += 1
                if let b = body { report.withBody += 1; report.bodyChars += b.count } else { report.noData += 1 }
                if let f = q.string(3) { folders.insert(f) }
                if let m = modified {
                    report.firstTsMs = min(report.firstTsMs ?? m, m); report.lastTsMs = max(report.lastTsMs ?? m, m)
                    report.byYear[String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(m) / 1000)).prefix(4)), default: 0] += 1
                }
            }
            q.reset()
            report.folders = folders.count
            let up = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            up.bind(1, String(decoding: try JSONEncoder().encode(report), as: UTF8.self)).bind(2, sid)
            try up.run()
        }
        return report
    }

    /// A NotesV7 note id: an NSKeyedArchiver blob of an NSUUID (it holds NULs, so read as text every id is "bplist00"). The UUID string,
    /// or nil when the column is not such a blob.
    static func v7UUID(_ data: Data?) -> String? {
        guard let data, data.starts(with: Data("bplist".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for case let o as [String: Any] in objects {
            if let b = o["NS.uuidbytes"] as? Data, b.count == 16 {
                let u = b.withUnsafeBytes { p in UUID(uuid: p.loadUnaligned(as: uuid_t.self)) }
                return u.uuidString
            }
        }
        return nil
    }

    /// `&#233;`, `&#x1F600;` and the HTML 4 named references (`&eacute;`, `&mdash;`, `&nbsp;` as a plain space) become their characters, in
    /// one pass, so `&amp;amp;` stays `&amp;`; anything else is left as written.
    static func decodeCharacterReferences(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(40).firstIndex(of: ";") {
                let name = s[s.index(after: i)..<semi]
                var scalar: Unicode.Scalar?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { scalar = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
                else if name.hasPrefix("#") { scalar = UInt32(name.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init) }
                else if let v = htmlEntities[String(name)] { scalar = Unicode.Scalar(v == 160 ? 32 : v) }
                if let scalar { out.unicodeScalars.append(scalar); i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    /// HTML 4's named character references (from Python's html.entities.name2codepoint).
    static let htmlEntities: [String: UInt32] = ["AElig": 198, "Aacute": 193, "Acirc": 194, "Agrave": 192, "Alpha": 913, "Aring": 197, "Atilde": 195, "Auml": 196, "Beta": 914, "Ccedil": 199, "Chi": 935, "Dagger": 8225, "Delta": 916, "ETH": 208, "Eacute": 201, "Ecirc": 202, "Egrave": 200, "Epsilon": 917, "Eta": 919, "Euml": 203, "Gamma": 915, "Iacute": 205, "Icirc": 206, "Igrave": 204, "Iota": 921, "Iuml": 207, "Kappa": 922, "Lambda": 923, "Mu": 924, "Ntilde": 209, "Nu": 925, "OElig": 338, "Oacute": 211, "Ocirc": 212, "Ograve": 210, "Omega": 937, "Omicron": 927, "Oslash": 216, "Otilde": 213, "Ouml": 214, "Phi": 934, "Pi": 928, "Prime": 8243, "Psi": 936, "Rho": 929, "Scaron": 352, "Sigma": 931, "THORN": 222, "Tau": 932, "Theta": 920, "Uacute": 218, "Ucirc": 219, "Ugrave": 217, "Upsilon": 933, "Uuml": 220, "Xi": 926, "Yacute": 221, "Yuml": 376, "Zeta": 918, "aacute": 225, "acirc": 226, "acute": 180, "aelig": 230, "agrave": 224, "alefsym": 8501, "alpha": 945, "amp": 38, "and": 8743, "ang": 8736, "aring": 229, "asymp": 8776, "atilde": 227, "auml": 228, "bdquo": 8222, "beta": 946, "brvbar": 166, "bull": 8226, "cap": 8745, "ccedil": 231, "cedil": 184, "cent": 162, "chi": 967, "circ": 710, "clubs": 9827, "cong": 8773, "copy": 169, "crarr": 8629, "cup": 8746, "curren": 164, "dArr": 8659, "dagger": 8224, "darr": 8595, "deg": 176, "delta": 948, "diams": 9830, "divide": 247, "eacute": 233, "ecirc": 234, "egrave": 232, "empty": 8709, "emsp": 8195, "ensp": 8194, "epsilon": 949, "equiv": 8801, "eta": 951, "eth": 240, "euml": 235, "euro": 8364, "exist": 8707, "fnof": 402, "forall": 8704, "frac12": 189, "frac14": 188, "frac34": 190, "frasl": 8260, "gamma": 947, "ge": 8805, "gt": 62, "hArr": 8660, "harr": 8596, "hearts": 9829, "hellip": 8230, "iacute": 237, "icirc": 238, "iexcl": 161, "igrave": 236, "image": 8465, "infin": 8734, "int": 8747, "iota": 953, "iquest": 191, "isin": 8712, "iuml": 239, "kappa": 954, "lArr": 8656, "lambda": 955, "lang": 9001, "laquo": 171, "larr": 8592, "lceil": 8968, "ldquo": 8220, "le": 8804, "lfloor": 8970, "lowast": 8727, "loz": 9674, "lrm": 8206, "lsaquo": 8249, "lsquo": 8216, "lt": 60, "macr": 175, "mdash": 8212, "micro": 181, "middot": 183, "minus": 8722, "mu": 956, "nabla": 8711, "nbsp": 160, "ndash": 8211, "ne": 8800, "ni": 8715, "not": 172, "notin": 8713, "nsub": 8836, "ntilde": 241, "nu": 957, "oacute": 243, "ocirc": 244, "oelig": 339, "ograve": 242, "oline": 8254, "omega": 969, "omicron": 959, "oplus": 8853, "or": 8744, "ordf": 170, "ordm": 186, "oslash": 248, "otilde": 245, "otimes": 8855, "ouml": 246, "para": 182, "part": 8706, "permil": 8240, "perp": 8869, "phi": 966, "pi": 960, "piv": 982, "plusmn": 177, "pound": 163, "prime": 8242, "prod": 8719, "prop": 8733, "psi": 968, "quot": 34, "rArr": 8658, "radic": 8730, "rang": 9002, "raquo": 187, "rarr": 8594, "rceil": 8969, "rdquo": 8221, "real": 8476, "reg": 174, "rfloor": 8971, "rho": 961, "rlm": 8207, "rsaquo": 8250, "rsquo": 8217, "sbquo": 8218, "scaron": 353, "sdot": 8901, "sect": 167, "shy": 173, "sigma": 963, "sigmaf": 962, "sim": 8764, "spades": 9824, "sub": 8834, "sube": 8838, "sum": 8721, "sup": 8835, "sup1": 185, "sup2": 178, "sup3": 179, "supe": 8839, "szlig": 223, "tau": 964, "there4": 8756, "theta": 952, "thetasym": 977, "thinsp": 8201, "thorn": 254, "tilde": 732, "times": 215, "trade": 8482, "uArr": 8657, "uacute": 250, "uarr": 8593, "ucirc": 251, "ugrave": 249, "uml": 168, "upsih": 978, "upsilon": 965, "uuml": 252, "weierp": 8472, "xi": 958, "yacute": 253, "yen": 165, "yuml": 255, "zeta": 950, "zwj": 8205, "zwnj": 8204]

    /// The text of an old Notes body: one line per `<div>` / `<br>` / `<p>`, tags dropped, the common entities decoded.
    static func htmlText(_ html: String) -> String {
        var s = html
        for (pat, rep) in [("(?i)<br\\s*/?>", "\n"), ("(?i)</(div|p|li|h[1-6])>", "\n"), ("<[^>]*>", "")] {
            s = s.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        s = decodeCharacterReferences(s)
        // <div>x</div><div><br></div> renders as x, an empty line; the closing tag after a <br> adds no second break.
        s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
