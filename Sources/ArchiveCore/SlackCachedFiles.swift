import Foundation

/// Slack files found in Slack's own HTTP disk cache (Chromium "simple cache", `Slack/Cache/<hash>_0`) attached to the Slack messages
/// `slack-import` wrote. Three steps, each a command:
///
/// 1. `plan`: every files.slack.com entry is read and tied to its messages by the file id in its URL, never by a name: the URL's
///    `T<team>-F<file>` must be a file Slack recorded in the saves and the whole URL must be that file's own address (`url_private`
///    or its `/download/` form for a full file, one of its `thumb_*` URLs for a thumbnail). A full file must be complete (HTTP 200,
///    body length = Content-Length = Slack's recorded size, CRC, no range pieces, no content encoding). The type comes from the bytes
///    (magic numbers); a full file whose bytes are not Slack's recorded type, or a thumbnail that is not an image, is left out. Per
///    file one copy: the full file when there is one, else the largest current thumbnail; it is attached to every canonical
///    `slack-cache` message whose (newest) file list holds the id. The plan lists every entry (left-out ones with the reason), the
///    note of each target message before and after, the archive's fingerprint and a digest of the target messages.
/// 2. `extract`: each planned body is written as a file (the entry re-hashed first; offset and length from the plan), with a
///    ledger, and the copy list (staged path, media path, sha256, bytes) for copying the files into the media store.
/// 3. `attach`: every file must be in the media store at its path with its sha256 (all or nothing, before the transaction); inside
///    BEGIN IMMEDIATE the fingerprint and the target digest must be unchanged and every target a canonical slack-cache row; then
///    media and attachment rows are added, `att_hash` and the note of the target set (a file-only row becomes a message with an
///    attachment). Nothing else changes. The plan file's sha256 keys the source, so a second run adds nothing.
public enum SlackCachedFiles {
    public static let kind = "slack-cache-files"

    // MARK: Chromium simple cache entries

    public struct CacheEntry: Sendable {
        public var url: String
        public var bodyOffset: Int, bodyLength: Int
        public var status: Int?, contentLength: Int?, contentType: String?, contentEncoding: String?
        public var crcOK: Bool
        public var crcPresent: Bool                 // the EOF record's CRC flag: without it nothing proves the body whole
    }

    static let entryMagic: UInt64 = 0xfcfb6d1ba7725c30, eofMagic: UInt64 = 0xf4fa6f45970d41d8

    static func le<T: FixedWidthInteger>(_ d: Data, _ at: Int, _: T.Type) -> T? {
        let n = MemoryLayout<T>.size
        guard at >= 0, at + n <= d.count else { return nil }
        var v: T = 0
        for i in 0..<n { v |= T(d[d.startIndex + at + i]) << (8 * i) }
        return v
    }

    /// `<hash>_0`: header (magic, version, key length, key hash, padding), the key (the URL), stream 1 (the body), its EOF record
    /// (magic, flags, crc32, size), stream 0 (the HTTP response headers), the key's SHA-256 when flag 2 is set, stream 0's EOF record.
    public static func readEntry(_ d: Data) throws -> CacheEntry {
        guard le(d, 0, UInt64.self) == entryMagic, let klen32 = le(d, 12, UInt32.self) else { throw ArchiveError("not a simple cache entry") }
        let klen = Int(klen32)
        guard 24 + klen <= d.count, d.count >= 24 + klen + 48 else { throw ArchiveError("cache entry too short") }
        let url = keyURL(String(decoding: d[(d.startIndex + 24)..<(d.startIndex + 24 + klen)], as: UTF8.self))
        let e0 = d.count - 24
        guard le(d, e0, UInt64.self) == eofMagic, let fl0 = le(d, e0 + 8, UInt32.self), let sz0 = le(d, e0 + 16, UInt32.self) else { throw ArchiveError("no stream 0 EOF record") }
        let end0 = e0 - (fl0 & 2 != 0 ? 32 : 0)
        let start0 = end0 - Int(sz0)
        let e1 = start0 - 24
        guard e1 >= 24 + klen, le(d, e1, UInt64.self) == eofMagic, let fl1 = le(d, e1 + 8, UInt32.self), let crc1 = le(d, e1 + 12, UInt32.self),
              let sz1 = le(d, e1 + 16, UInt32.self) else { throw ArchiveError("no stream 1 EOF record") }
        let bodyLength = e1 - (24 + klen)
        guard bodyLength == Int(sz1) else { throw ArchiveError("stream 1 is \(bodyLength) bytes, its record says \(sz1)") }
        let body = d[(d.startIndex + 24 + klen)..<(d.startIndex + e1)]
        let crcOK = fl1 & 1 == 0 || crc32(body) == crc1
        let crcPresent = fl1 & 1 != 0
        let headers = String(decoding: d[(d.startIndex + start0)..<(d.startIndex + end0)].map { $0 == 0 ? 0x0a : $0 }, as: UTF8.self)
        func header(_ name: String) -> String? {
            for line in headers.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.lowercased().hasPrefix(name.lowercased() + ":") { return String(l.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        var status: Int? = nil
        if let r = headers.range(of: #"HTTP/\d(\.\d)? (\d{3})"#, options: .regularExpression) { status = Int(headers[r].suffix(3)) }
        return CacheEntry(url: url, bodyOffset: 24 + klen, bodyLength: bodyLength, status: status, contentLength: header("content-length").flatMap { Int($0) },
                          contentType: header("content-type").map { String($0.prefix { $0 != ";" }).lowercased() },
                          contentEncoding: header("content-encoding")?.lowercased(), crcOK: crcOK, crcPresent: crcPresent)
    }

    /// The URL of a cache key. Chromium's HTTP cache has prefixed its keys since 2022 with the request's credential mode and upload
    /// id; the 2020-21 cache has the bare URL. Only `1/0/` is taken off: credentials included, no upload body, which is what every
    /// key of the 2022-23 caches carries (4,542 of 4,542). A key with an upload id (the response to a POST), another credential
    /// mode or a network-isolation prefix is returned as it is, and is then not a Slack file address.
    public static func keyURL(_ key: String) -> String {
        guard key.hasPrefix("1/0/http://") || key.hasPrefix("1/0/https://") else { return key }
        return String(key.dropFirst(4))
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32<D: Collection>(_ d: D) -> UInt32 where D.Element == UInt8 {
        var c: UInt32 = 0xffffffff
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }

    /// The type a file's own bytes say it is (magic numbers), with the extension the media store gives it.
    public static func sniff(_ d: Data) -> (mime: String, ext: String)? {
        let b = [UInt8](d.prefix(64))
        func at(_ i: Int, _ s: [UInt8]) -> Bool { b.count >= i + s.count && Array(b[i..<(i + s.count)]) == s }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return ("image/png", "png") }
        if at(0, [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if at(0, Array("GIF87a".utf8)) || at(0, Array("GIF89a".utf8)) { return ("image/gif", "gif") }
        if at(0, Array("%PDF-".utf8)) { return ("application/pdf", "pdf") }
        if at(0, Array("RIFF".utf8)) && at(8, Array("WEBP".utf8)) { return ("image/webp", "webp") }
        if at(0, Array("RIFF".utf8)) && at(8, Array("WAVE".utf8)) { return ("audio/wav", "wav") }
        if at(4, Array("ftyp".utf8)) {
            // ISO-BMFF: the major brand, then the compatible brands, say what it is (an HEIC photo is not a video).
            let size = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            var brands: [String] = []
            var i = 8
            while i + 4 <= min(size, b.count) { if i != 12 { brands.append(String(decoding: b[i..<(i + 4)], as: UTF8.self)) }; i += 4 }
            let major = brands.first ?? ""
            if ["heic", "heix", "heim", "heis", "hevc", "hevx"].contains(major) { return ("image/heic", "heic") }
            if major == "avif" || major == "avis" { return ("image/avif", "avif") }
            if major == "mif1" || major == "msf1" {
                if brands.contains(where: { ["heic", "heix", "hevc", "hevx"].contains($0) }) { return ("image/heic", "heic") }
                if brands.contains("avif") { return ("image/avif", "avif") }
                return ("image/heif", "heif")
            }
            if major == "qt  " { return ("video/quicktime", "mov") }
            return ("video/mp4", "mp4")
        }
        return nil
    }

    static func sameType(_ a: String?, _ b: String) -> Bool {
        guard let a = a?.lowercased() else { return false }
        let norm: (String) -> String = { $0 == "image/jpg" || $0 == "image/pjpeg" ? "image/jpeg" : ($0 == "audio/x-wav" || $0 == "audio/wave" ? "audio/wav" : $0) }
        return norm(a) == norm(b)
    }

    // MARK: the plan

    public struct Row: Sendable, Equatable {
        public var decision: String, reason: String
        public var team: String, fileID: String, kind: String, thumbSize: String
        public var entry: String, entrySHA256: String, bodyOffset: Int, bodyLength: Int
        public var sha256: String, mime: String, ext: String
        public var sourceKey: String, messageID: Int64?
        public var mediaPath: String, mediaPresent: Bool, filename: String
        public var noteBefore: String?, noteAfter: String?
    }
    static let columns = ["decision", "reason", "team", "file_id", "kind", "thumb_size", "cache_entry", "entry_sha256", "body_offset", "body_length",
                          "sha256", "mime", "ext", "message_source_key", "message_id", "media_path", "media_present", "filename", "note_before", "note_after"]

    /// The note text of a file once a copy of it is attached.
    static func attachedNote(_ before: String, full: Bool) -> String {
        let suffix = " not attached (the Slack cache keeps no copy)"
        if before.hasSuffix(suffix) {
            let what = String(before.dropLast(suffix.count))
            return full ? what + " attached from Slack's cache" : what + ": a thumbnail from Slack's cache is attached (the full file was not kept)"
        }
        return before + (full ? " (a copy from Slack's cache is attached)" : " (a thumbnail from Slack's cache is attached)")
    }

    /// An address without its query (both the cache's key and Slack's saved addresses may carry one).
    static func bare(_ u: String) -> String { u.split(separator: "?", maxSplits: 1).first.map(String.init) ?? u }

    static func count(_ hay: String, _ needle: String) -> Int {
        var n = 0, r = hay.startIndex..<hay.endIndex
        while let f = hay.range(of: needle, range: r) { n += 1; r = f.upperBound..<hay.endIndex }
        return n
    }

    struct Candidate {
        var entry: String, entrySHA: String, e: CacheEntry, team: String, fileID: String, full: Bool, thumbSize: String
        var current: Bool, sha: String, mime: String, ext: String, filename: String
    }

    /// Reads the cache entries in `cacheDir` (`<hash>_0`, with `<hash>_s` beside a range entry) and the Slack saves in `indexedDB`,
    /// and plans against the archive. Writes nothing.
    public static func makePlan(cacheDir: URL, indexedDB: URL, db: Database, root: ArchiveRoot) throws -> [Row] {
        let merged = try SlackCacheImporter.merge(try SlackCacheImporter.blobFiles(in: indexedDB))
        // Which messages list each file (their newest copy).
        // Which messages list each file (their newest copy), with the note text the importer wrote for it on that message: the same
        // function on the same file object (the message's inline object when it has one).
        var listing: [String: [String]] = [:]                  // "team|F" -> ["team|conversation|ts"]
        var fragments: [String: String] = [:]                  // "team|conversation|ts|F" -> the note text
        for (k, copies) in merged.copies {
            let newest = copies.max { $0.save < $1.save }!
            let team = String(k.split(separator: "|")[0])
            guard let w = merged.workspaces[team] else { continue }
            for f in newest.message["files"]?.array ?? [] {
                let (id, fo) = SlackCacheImporter.fileObject(f, files: w.files)
                listing["\(team)|\(id)", default: []].append(k)
                fragments["\(k)|\(id)"] = SlackCacheImporter.fileNote(fo, id: id)
            }
        }
        for k in listing.keys { listing[k]!.sort() }
        let names = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).filter { $0.hasSuffix("_0") }.sorted()
        var rows: [Row] = [], cands: [Candidate] = []
        let urlPattern = try NSRegularExpression(pattern: #"^https://files\.slack\.com/files-(pri|tmb)/(T[A-Z0-9]+)-(F[A-Z0-9]+)(-[0-9a-f]+)?/"#)
        func leftOut(_ reason: String, _ entry: String, _ esha: String, team: String = "", file: String = "", kind: String = "", size: String = "", keys: [String] = []) {
            rows.append(Row(decision: "left-out", reason: reason, team: team, fileID: file, kind: kind, thumbSize: size, entry: entry, entrySHA256: esha,
                            bodyOffset: 0, bodyLength: 0, sha256: "", mime: "", ext: "", sourceKey: keys.map { k in "slack:" + k.replacingOccurrences(of: "|", with: ":") }.joined(separator: ";"),
                            messageID: nil, mediaPath: "", mediaPresent: false, filename: "", noteBefore: nil, noteAfter: nil))
        }
        for name in names {
            let entry = String(name.dropLast(2))
            let data = try Data(contentsOf: cacheDir.appendingPathComponent(name))
            let esha = data.withUnsafeBytes { Hashing.sha256Hex($0) }
            guard let e = try? readEntry(data) else { leftOut("unreadable cache entry", entry, esha); continue }
            let ns = e.url as NSString
            guard let m = urlPattern.firstMatch(in: e.url, range: NSRange(location: 0, length: ns.length)) else { continue }   // not a Slack file
            let full = ns.substring(with: m.range(at: 1)) == "pri", team = ns.substring(with: m.range(at: 2)), fid = ns.substring(with: m.range(at: 3))
            let keys = listing["\(team)|\(fid)"] ?? []
            let kindText = full ? "full" : "thumb"
            guard let w = merged.workspaces[team], let fo = w.files[fid] else { leftOut("file id not in Slack's file records", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue }
            if fo["mode"]?.text == "tombstone" || fo["is_tombstoned"]?.bool == true { leftOut("file deleted in Slack (no record to tie the URL to)", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue }
            let u = bare(e.url)
            var thumbSize = "", current = true
            if full {
                let up = bare(fo["url_private"]?.text ?? "")
                guard !up.isEmpty, u == up || u == up.replacingOccurrences(of: "-\(fid)/", with: "-\(fid)/download/") || u == fo["url_private_download"]?.text.map(bare) else {
                    leftOut("URL is not this file's own address", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue
                }
            } else {
                if let (k, _) = fo.first(where: { $0.key.hasPrefix("thumb_") && ($0.value.text.map(bare) == u) }) { thumbSize = String(k.dropFirst(6)) }
                else if fo["is_external"]?.bool == true, u.contains("/files-tmb/\(team)-\(fid)-") {
                    current = false                      // an older rendering of the same file's preview (Slack re-renders Google Drive previews)
                    thumbSize = "older rendering " + ((u as NSString).lastPathComponent.split(separator: "_").last.map { String($0.split(separator: ".").first ?? "") } ?? "")
                } else { leftOut("URL is not one of this file's thumbnail addresses", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue }
            }
            let body = data.subdata(in: e.bodyOffset..<(e.bodyOffset + e.bodyLength))
            let sparse = FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(entry + "_s").path)
            if e.status != 200 { leftOut("HTTP status \(e.status.map(String.init) ?? "unknown") (only part of the file)", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue }
            if sparse || (e.contentLength != nil && e.contentLength != e.bodyLength) { leftOut("partial body", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue }
            // A full file proves it is whole: Content-Length, Slack's recorded size and a verified CRC.
            if full && e.contentLength == nil { leftOut("no Content-Length to prove the body whole", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue }
            if full && !((fo["size"]?.number ?? 0) > 0) { leftOut("Slack records no size to prove the body whole", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue }
            if full && !e.crcPresent { leftOut("no CRC to prove the body whole", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue }
            if !e.crcOK { leftOut("body CRC mismatch", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue }
            if let enc = e.contentEncoding, enc != "identity" { leftOut("content encoding \(enc)", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue }
            guard let t = sniff(body) else { leftOut("bytes of no known type", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue }
            if full {
                if let size = fo["size"]?.number, Int(size) != e.bodyLength {
                    leftOut("body \(e.bodyLength) B but Slack records \(Int(size)) B", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue
                }
                guard sameType(fo["mimetype"]?.text, t.mime) else {
                    leftOut("bytes are \(t.mime), Slack records \(fo["mimetype"]?.text ?? "no type")", entry, esha, team: team, file: fid, kind: kindText, keys: keys); continue
                }
            } else {
                guard t.mime.hasPrefix("image/") else { leftOut("thumbnail bytes are \(t.mime), not an image", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue }
                if let ct = e.contentType, ct.hasPrefix("image/"), !sameType(ct, t.mime) {
                    leftOut("bytes are \(t.mime), the response said \(ct)", entry, esha, team: team, file: fid, kind: kindText, size: thumbSize, keys: keys); continue
                }
            }
            let fname = full ? (fo["name"]?.text ?? (u as NSString).lastPathComponent) : (u as NSString).lastPathComponent
            cands.append(Candidate(entry: entry, entrySHA: esha, e: e, team: team, fileID: fid, full: full, thumbSize: thumbSize, current: current,
                                   sha: body.withUnsafeBytes { Hashing.sha256Hex($0) }, mime: t.mime, ext: t.ext, filename: fname))
        }
        // Per file one copy: the full file, else the current thumbnail with the most bytes, else an older rendering.
        var chosen: [String: Candidate] = [:]
        for c in cands {
            let k = "\(c.team)|\(c.fileID)"
            guard let old = chosen[k] else { chosen[k] = c; continue }
            let better = (c.full ? 1 : 0, c.current ? 1 : 0, c.e.bodyLength, c.entry) > (old.full ? 1 : 0, old.current ? 1 : 0, old.e.bodyLength, old.entry)
            if better { chosen[k] = c }
        }
        let selMsg = try db.prepare("""
            SELECT m.id, m.note FROM message m JOIN source s ON s.id = m.source_id
            WHERE m.source_key = ? AND m.canonical_id IS NULL AND s.kind = 'slack-cache' ORDER BY m.id LIMIT 1
            """)
        let selMedia = try db.prepare("SELECT path FROM media WHERE sha256 = ?")
        var pending: [Int64: [(Int, String, Bool)]] = [:]
        let store = MediaStore(root: root)
        for c in cands {
            let k = "\(c.team)|\(c.fileID)"
            let keys = listing[k] ?? []
            guard chosen[k]?.entry == c.entry else {
                leftOut(chosen[k]!.full && !c.full ? "the full file is attached instead" : "another copy of this file is attached instead", c.entry, c.entrySHA,
                        team: c.team, file: c.fileID, kind: c.full ? "full" : "thumb", size: c.thumbSize, keys: keys); continue
            }
            if keys.isEmpty { leftOut("no cached message lists this file", c.entry, c.entrySHA, team: c.team, file: c.fileID, kind: c.full ? "full" : "thumb", size: c.thumbSize); continue }
            selMedia.bind(1, c.sha)
            let existing = try selMedia.step() ? selMedia.string(0) : nil
            selMedia.reset()
            let path = existing ?? store.relativePath(sha256: c.sha, ext: c.ext)
            for key in keys {
                let fragment = fragments["\(key)|\(c.fileID)"] ?? ""
                let p = key.split(separator: "|").map(String.init)
                let sk = "slack:\(p[0]):\(p[1]):\(p[2])"
                var row = Row(decision: "attach", reason: c.current ? "" : "older rendering of this file's preview", team: c.team, fileID: c.fileID,
                              kind: c.full ? "full" : "thumb", thumbSize: c.thumbSize, entry: c.entry, entrySHA256: c.entrySHA, bodyOffset: c.e.bodyOffset,
                              bodyLength: c.e.bodyLength, sha256: c.sha, mime: c.mime, ext: c.ext, sourceKey: sk, messageID: nil, mediaPath: path,
                              mediaPresent: existing != nil, filename: c.filename, noteBefore: nil, noteAfter: nil)
                selMsg.bind(1, sk)
                guard try selMsg.step() else { selMsg.reset(); row.decision = "left-out"; row.reason = "message not a canonical slack-cache row"; rows.append(row); continue }
                let mid = selMsg.int(0), note = selMsg.string(1)
                selMsg.reset()
                row.messageID = mid
                row.noteBefore = note
                rows.append(row)
                pending[mid, default: []].append((rows.count - 1, fragment, c.full))
            }
        }
        // Per message: each planned file's text in the note becomes its attached text. A text that appears k times (two files with
        // the same title) is rewritten only when exactly k planned files of that message carry it and all are attached the same way
        // (full or thumbnail); otherwise those rows are left out, so the note always reads one way.
        for (_, list) in pending {
            let note = rows[list[0].0].noteBefore ?? ""
            var after = note, ok: [Int] = []
            for (fragment, group) in Dictionary(grouping: list, by: { $0.1 }) {
                if count(note, fragment) == group.count, Set(group.map { $0.2 }).count == 1 {
                    after = after.replacingOccurrences(of: fragment, with: attachedNote(fragment, full: group[0].2))
                    ok += group.map { $0.0 }
                } else {
                    for g in group { rows[g.0].decision = "left-out"; rows[g.0].reason = "the note does not name this file one way" }
                }
            }
            for i in ok { rows[i].noteAfter = after }
        }
        return rows.sorted { ($0.decision, $0.sourceKey, $0.fileID, $0.entry) < ($1.decision, $1.sourceKey, $1.fileID, $1.entry) }
    }

    /// Per distinct target message: id, source key, canonical id, att_hash, note, kind (as `AttachmentPlan.targetDigest` does).
    public static func targetDigest(_ rows: [Row], db: Database) throws -> String {
        let st = try db.prepare("SELECT m.id, m.source_key, m.canonical_id, m.att_hash, m.note, m.kind, s.kind FROM message m JOIN source s ON s.id = m.source_id WHERE m.id = ?")
        var lines: [String] = []
        for id in Set(rows.filter { $0.decision == "attach" }.compactMap(\.messageID)).sorted() {
            st.bind(1, id)
            if try st.step() {
                lines.append([String(st.int(0)), st.string(1) ?? "", st.optInt(2).map(String.init) ?? "", st.optInt(3).map(String.init) ?? "",
                              AttachmentPlan.escape(st.string(4) ?? "\u{0}"), st.string(5) ?? "\u{0}", st.string(6) ?? ""].joined(separator: "|"))
            } else { lines.append("\(id)|missing") }
            st.reset()
        }
        return Data(lines.joined(separator: "\n").utf8).withUnsafeBytes { Hashing.sha256Hex($0) }
    }

    public static func write(_ rows: [Row], to url: URL, db: Database) throws {
        var s = "#archive\t" + (try AttachmentPlan.fingerprint(db)) + "\n#targets\t" + (try targetDigest(rows, db: db)) + "\n" + columns.joined(separator: "\t") + "\n"
        let e = AttachmentPlan.escape
        for r in rows {
            s += [r.decision, e(r.reason), r.team, r.fileID, r.kind, e(r.thumbSize), r.entry, r.entrySHA256, String(r.bodyOffset), String(r.bodyLength),
                  r.sha256, r.mime, r.ext, e(r.sourceKey), r.messageID.map(String.init) ?? "", r.mediaPath, r.mediaPresent ? "1" : "0", e(r.filename),
                  r.noteBefore.map(e) ?? "\\0", r.noteAfter.map(e) ?? "\\0"].joined(separator: "\t") + "\n"
        }
        s += "#rows\t\(rows.count)\n"
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func read(_ url: URL) throws -> (rows: [Row], fingerprint: String, targets: String) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 4, lines[0].hasPrefix("#archive\t"), lines[1].hasPrefix("#targets\t"), lines[2] == columns.joined(separator: "\t"),
              lines.last!.hasPrefix("#rows\t"), let n = Int(lines.last!.dropFirst(6)), n == lines.count - 4 else { throw ArchiveError("\(url.path) is not a whole Slack files plan") }
        let u = AttachmentPlan.unescape
        let rows = try lines[3..<(lines.count - 1)].map { l -> Row in
            let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == columns.count else { throw ArchiveError("plan line with \(f.count) fields") }
            return Row(decision: f[0], reason: u(f[1]), team: f[2], fileID: f[3], kind: f[4], thumbSize: u(f[5]), entry: f[6], entrySHA256: f[7],
                       bodyOffset: Int(f[8]) ?? -1, bodyLength: Int(f[9]) ?? -1, sha256: f[10], mime: f[11], ext: f[12], sourceKey: u(f[13]),
                       messageID: Int64(f[14]), mediaPath: f[15], mediaPresent: f[16] == "1", filename: u(f[17]),
                       noteBefore: f[18] == "\\0" ? nil : u(f[18]), noteAfter: f[19] == "\\0" ? nil : u(f[19]))
        }
        return (rows, String(lines[0].dropFirst(9)), String(lines[1].dropFirst(9)))
    }

    // MARK: extract

    public struct ExtractReport: Sendable { public var files = 0, bytes = 0 }

    /// Writes each distinct planned body as `<out>/<sha256>.<ext>` (the entry re-hashed against the plan first, the body hashed after
    /// slicing), a ledger (entry, entry sha256, offset, length, body sha256, file) and the copy list for copying into the media store.
    public static func extract(plan: URL, cacheDir: URL, out: URL, ledger: URL, copyList: URL) throws -> ExtractReport {
        let (rows, _, _) = try read(plan)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var seen = Set<String>(), led = ["cache_entry\tentry_sha256\tbody_offset\tbody_length\tbody_sha256\tfile"], list: [String] = [], r = ExtractReport()
        for row in rows where row.decision == "attach" && seen.insert(row.sha256).inserted {
            let data = try Data(contentsOf: cacheDir.appendingPathComponent(row.entry + "_0"))
            guard data.withUnsafeBytes({ Hashing.sha256Hex($0) }) == row.entrySHA256 else { throw ArchiveError("cache entry \(row.entry) is not the one planned") }
            guard row.bodyOffset >= 0, row.bodyLength >= 0, row.bodyOffset + row.bodyLength <= data.count else { throw ArchiveError("plan offset outside entry \(row.entry)") }
            let body = data.subdata(in: row.bodyOffset..<(row.bodyOffset + row.bodyLength))
            guard body.withUnsafeBytes({ Hashing.sha256Hex($0) }) == row.sha256 else { throw ArchiveError("body of \(row.entry) is not the planned file") }
            let file = out.appendingPathComponent("\(row.sha256).\(row.ext)")
            if FileManager.default.fileExists(atPath: file.path) {
                guard (try Hashing.sha256Hex(ofFile: file)).hex == row.sha256 else { throw ArchiveError("\(file.path) exists with other content") }
            } else { try body.write(to: file, options: .withoutOverwriting) }
            led.append([row.entry, row.entrySHA256, String(row.bodyOffset), String(row.bodyLength), row.sha256, file.path].joined(separator: "\t"))
            if !row.mediaPresent { list.append([file.path, row.mediaPath, row.sha256, String(row.bodyLength)].joined(separator: "\t")) }
            r.files += 1; r.bytes += row.bodyLength
        }
        try (led.joined(separator: "\n") + "\n").write(to: ledger, atomically: true, encoding: .utf8)
        try (list.isEmpty ? "" : list.joined(separator: "\n") + "\n").write(to: copyList, atomically: true, encoding: .utf8)
        return r
    }

    // MARK: attach

    public struct AttachStats: Codable, Sendable, Equatable {
        public var rows = 0, attached = 0, alreadyThere = 0, leftOut = 0, newFiles = 0, newBytes = 0, notesChanged = 0, fileRowsNowMessages = 0, messages = 0
        public init() {}
    }
    public struct AttachReport: Sendable { public var status: ImportReport.Status; public var sourceID: Int64; public var stats: AttachStats }

    public static func attach(plan url: URL, into db: Database, root: ArchiveRoot, ledger: URL? = nil, origin: String? = nil) throws -> AttachReport {
        let (rows, planFP, planTargets) = try read(url)
        let key = "slack-files-plan:" + (try Hashing.sha256Hex(ofFile: url)).hex
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let id = seen.int(0)
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(AttachStats.self, from: Data($0.utf8)) } ?? AttachStats()
            seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return AttachReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()
        // Every planned file whole in the media store (all or nothing, before the transaction).
        var bad: [String] = [], checked = Set<String>()
        for r in rows where r.decision == "attach" && checked.insert(r.mediaPath).inserted {
            let file = root.resolve(relativePath: r.mediaPath)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { bad.append("missing \(r.mediaPath)"); continue }
            guard size == r.bodyLength else { bad.append("size \(r.mediaPath)"); continue }
            if (try Hashing.sha256Hex(ofFile: file)).hex != r.sha256 { bad.append("sha256 \(r.mediaPath)") }
        }
        guard bad.isEmpty else { throw ArchiveError("not every planned file is in the media store: \(bad.count) (\(bad.prefix(3).joined(separator: ", "))); nothing written") }
        var stats = AttachStats()
        var out = ["message_source_key\tmessage_id\tfile_id\tkind\tsha256\tmedia_path\tdecision\tattachment_id\told_kind\tnew_kind\told_note\tnew_note"]
        let e = AttachmentPlan.escape
        var report: AttachReport!
        try db.transaction {
            let now = try AttachmentPlan.fingerprint(db)
            guard planFP == now else { throw ArchiveError("the plan was made against another archive state (\(planFP)); this archive is \(now): make the plan again") }
            guard try targetDigest(rows, db: db) == planTargets else { throw ArchiveError("a target message changed since the plan was made: make the plan again") }
            let check = try db.prepare("SELECT m.note, m.kind, m.body FROM message m JOIN source s ON s.id = m.source_id WHERE m.id = ? AND m.source_key = ? AND m.canonical_id IS NULL AND s.kind = 'slack-cache'")
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?, ?, ?, 0, ?, NULL)")
            ins.bind(1, kind).bind(2, origin ?? url.path).bind(3, key).bind(4, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let has = try db.prepare("SELECT 1 FROM attachment WHERE message_id = ? AND sha256 = ? LIMIT 1")
            let selMedia = try db.prepare("SELECT 1 FROM media WHERE sha256 = ?")
            let insMedia = try db.prepare("INSERT INTO media(sha256, path, bytes, mime) VALUES (?,?,?,?)")
            let insAtt = try db.prepare("INSERT INTO attachment(message_id, mime, filename, media_path, bytes, sha256) VALUES (?,?,?,?,?,?)")
            let attShas = try db.prepare("SELECT sha256 FROM attachment WHERE message_id = ?")
            let upd = try db.prepare("UPDATE message SET note = ?, kind = ?, att_hash = ? WHERE id = ?")
            var touched: [Int64: (note: String?, kind: String?, newNote: String?, body: String?)] = [:]
            for r in rows {
                stats.rows += 1
                func log(_ d: String, _ aid: Int64? = nil, _ ok: String? = nil, _ nk: String? = nil, _ on: String? = nil, _ nn: String? = nil) {
                    out.append([e(r.sourceKey), r.messageID.map(String.init) ?? "", r.fileID, r.kind == "thumb" ? "thumb \(r.thumbSize)" : r.kind, r.sha256,
                                r.mediaPath, d, aid.map(String.init) ?? "", e(ok ?? ""), e(nk ?? ""), e(on ?? ""), e(nn ?? "")].joined(separator: "\t"))
                }
                guard r.decision == "attach", let mid = r.messageID else { stats.leftOut += 1; log(r.decision + (r.reason.isEmpty ? "" : ": " + r.reason)); continue }
                check.bind(1, mid).bind(2, r.sourceKey)
                guard try check.step() else { check.reset(); throw ArchiveError("plan row \(r.entry): message \(mid) is not the canonical slack-cache row \(r.sourceKey): refused") }
                let note = check.string(0), kind = check.string(1), body = check.string(2)
                check.reset()
                guard note == r.noteBefore || touched[mid] != nil else { throw ArchiveError("message \(mid): the note is not the planned one: refused") }
                has.bind(1, mid).bind(2, r.sha256)
                let already = try has.step(); has.reset()
                if already {
                    // The file is there already (an earlier backfill): the message is still set true below (note, kind, att_hash),
                    // so a note never says "not attached" beside an attached file.
                    stats.alreadyThere += 1
                    if touched[mid] == nil { touched[mid] = (note, kind, r.noteAfter, body) }
                    log("already-attached-note-set", nil, kind, nil, note, r.noteAfter)
                    continue
                }
                selMedia.bind(1, r.sha256)
                let mediaRow = try selMedia.step(); selMedia.reset()
                if !mediaRow {
                    insMedia.bind(1, r.sha256).bind(2, r.mediaPath).bind(3, r.bodyLength).bind(4, r.mime)
                    try insMedia.run()
                    stats.newFiles += 1; stats.newBytes += r.bodyLength
                }
                insAtt.bind(1, mid).bind(2, r.mime).bind(3, r.filename).bind(4, r.mediaPath).bind(5, r.bodyLength).bind(6, r.sha256)
                try insAtt.run()
                stats.attached += 1
                if touched[mid] == nil { touched[mid] = (note, kind, r.noteAfter, body) }
                log("attached", db.lastInsertRowID, kind, nil, note, r.noteAfter)
            }
            // Per message once: att_hash from all its files, the planned note; a file-only row ("(...)" note, no text) becomes a message.
            for (mid, t) in touched.sorted(by: { $0.key < $1.key }) {
                var shas: [String] = []
                attShas.bind(1, mid)
                while try attShas.step() { if let s = attShas.string(0) { shas.append(s) } }
                attShas.reset()
                var newKind = t.kind
                if t.kind == "system", t.body == nil, (t.note ?? "").hasPrefix("(") { newKind = nil; stats.fileRowsNowMessages += 1 }
                upd.bind(1, t.newNote).bind(2, newKind).bind(3, Hashing.attachmentHash(shas)).bind(4, mid)
                try upd.run()
                if t.newNote != t.note { stats.notesChanged += 1 }
                stats.messages += 1
            }
            let st = try db.prepare("UPDATE source SET stats_json = ?, bytes = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, Int64(stats.newBytes)).bind(3, sid)
            try st.run()
            try ImportLedger.save(db, sourceID: sid, body: out.joined(separator: "\n") + "\n")
            report = AttachReport(status: .imported, sourceID: sid, stats: stats)
        }
        if let ledger, let body = try ImportLedger.load(db, sourceID: report.sourceID) { try ImportLedger.publish(body, to: ledger) }
        return report
    }
}
