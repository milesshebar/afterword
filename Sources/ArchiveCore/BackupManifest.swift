import Foundation

/// Read-only view of an unencrypted iPhone backup folder: modern `Manifest.db` (iOS 10+) or legacy `Manifest.mbdb`
/// (iOS 5). A backed-up file is stored as `SHA1("<domain>-<relativePath>")`, either flat in the folder (iTunes, iOS 5)
/// or under a two-character subfolder (iOS 10+).
public final class BackupManifest {
    public enum Format: String, Sendable { case db, mbdb, tree }

    public let folder: URL
    public let format: Format
    private var manifestDB: Database?
    private var lookup: Statement?
    private var legacyIDs = Set<String>()
    private var partsIndex: [String: (domain: String, path: String)]?
    public private(set) var entryCount = 0

    public static func detectFormat(_ folder: URL) -> Format? {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("Manifest.db").path) { return .db }
        if fm.fileExists(atPath: folder.appendingPathComponent("Manifest.mbdb").path) { return .mbdb }
        return nil
    }

    public static func isBackupFolder(_ folder: URL) -> Bool { detectFormat(folder) != nil }

    public static func fileID(domain: String, path: String) -> String {
        Hashing.sha1Hex(Data("\(domain)-\(path)".utf8))
    }

    /// A decrypted extract laid out as `<folder>/<domain>/<relativePath>` (what `scripts/iphone-backup-stage.py` writes under
    /// `extracted/<source>/`): no manifest, a file is listed when it exists.
    public init(tree folder: URL) {
        self.folder = folder
        format = .tree
    }

    public init(folder: URL) throws {
        self.folder = folder
        guard let f = Self.detectFormat(folder) else { throw ArchiveError("\(folder.path) is not an iPhone backup (no Manifest.db or Manifest.mbdb)") }
        format = f
        // Encrypted backups cannot be read without the keybag; fail clearly instead of with "not a database".
        let plist = folder.appendingPathComponent("Manifest.plist")
        if let data = try? Data(contentsOf: plist),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           (obj["IsEncrypted"] as? Bool) == true {
            throw ArchiveError("\(folder.path) is an encrypted backup; only unencrypted backups are supported")
        }
        switch f {
        case .db:
            let url = folder.appendingPathComponent("Manifest.db")
            let db: Database
            do { db = try Database(path: url.path, readOnly: true, immutable: true) }
            catch { throw ArchiveError("cannot open \(url.path): \(error)") }
            do {
                lookup = try db.prepare("SELECT flags FROM Files WHERE fileID = ?")
                entryCount = Int(try db.scalarInt("SELECT count(*) FROM Files"))
            } catch { throw ArchiveError("\(url.path) is not a readable Manifest.db (encrypted backup?): \(error)") }
            manifestDB = db
        case .mbdb:
            try parseMBDB(folder.appendingPathComponent("Manifest.mbdb"))
        case .tree: break
        }
    }

    // MARK: lookups

    /// True when the manifest lists a regular file for this domain and path.
    public func contains(domain: String, path: String) -> Bool {
        let id = Self.fileID(domain: domain, path: path)
        switch format {
        case .tree: return FileManager.default.fileExists(atPath: folder.appendingPathComponent(domain).appendingPathComponent(path).path)
        case .mbdb: return legacyIDs.contains(id)
        case .db:
            guard let lookup else { return false }
            lookup.bind(1, id)
            defer { lookup.reset() }
            guard (try? lookup.step()) == true else { return false }
            return lookup.optInt(0) == nil || lookup.int(0) == 1
        }
    }

    /// Location of the backed-up file on disk, or nil when the manifest does not list it or the file is not there.
    public func fileURL(domain: String, path: String) -> URL? {
        guard contains(domain: domain, path: path) else { return nil }
        if format == .tree { return folder.appendingPathComponent(domain).appendingPathComponent(path) }
        return diskURL(fileID: Self.fileID(domain: domain, path: path))
    }

    /// Flat first (iTunes / iOS 5), then under `<xx>/` (iOS 10+).
    public func diskURL(fileID id: String) -> URL? {
        let fm = FileManager.default
        let nested = folder.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
        let flat = folder.appendingPathComponent(id)
        let order = format == .db ? [nested, flat] : [flat, nested]
        return order.first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: iOS 5 MMS parts

    static let partsPrefix = "Library/SMS/Parts/"

    /// iOS 5 stores an MMS part at `Library/SMS/Parts/<group>/<bucket>/<message_id>-<part_id>.<ext>` (plus a `-preview`
    /// sibling); `msg_pieces.content_loc` holds only the original filename, so parts are found by this key instead.
    public func smsPart(messageID: Int64, partID: Int64) -> (domain: String, path: String)? {
        if partsIndex == nil { buildPartsIndex() }
        return partsIndex?["\(messageID)-\(partID)"]
    }

    private func buildPartsIndex() {
        var idx: [String: (domain: String, path: String)] = [:]
        func add(_ domain: String, _ path: String) {
            guard path.hasPrefix(Self.partsPrefix) else { return }
            var name = (path as NSString).lastPathComponent
            if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
            if name.hasSuffix("-preview") { return }
            if idx[name] == nil { idx[name] = (domain, path) }
        }
        switch format {
        case .tree: break
        case .mbdb: for e in legacyParts { add(e.domain, e.path) }
        case .db:
            if let db = manifestDB, let q = try? db.prepare("SELECT domain, relativePath FROM Files WHERE relativePath LIKE 'Library/SMS/Parts/%' AND (flags IS NULL OR flags = 1) ORDER BY relativePath") {
                while (try? q.step()) == true { if let d = q.string(0), let p = q.string(1) { add(d, p) } }
            }
        }
        partsIndex = idx
    }

    private var legacyParts: [(domain: String, path: String)] = []

    // MARK: legacy Manifest.mbdb

    /// Big-endian records: domain, path, linkTarget, dataHash, encKey (uint16 length + bytes, 0xFFFF = empty), then
    /// mode u16, inode u64, uid u32, gid u32, mtime/atime/ctime u32, size u64, protection u8, propCount u8, and
    /// propCount (name, value) string pairs. Only regular files (mode 0x8000) are indexed.
    private func parseMBDB(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let n = data.count
        guard n >= 6, data.prefix(4) == Data("mbdb".utf8) else { throw ArchiveError("\(url.path): not an mbdb file") }
        var p = 6
        func u16() throws -> Int {
            guard p + 2 <= n else { throw ArchiveError("truncated mbdb") }
            defer { p += 2 }
            return Int(data[data.startIndex + p]) << 8 | Int(data[data.startIndex + p + 1])
        }
        func skip(_ k: Int) throws { guard p + k <= n else { throw ArchiveError("truncated mbdb") }; p += k }
        func string() throws -> String {
            let len = try u16()
            if len == 0xFFFF { return "" }
            guard p + len <= n else { throw ArchiveError("truncated mbdb") }
            defer { p += len }
            return String(decoding: data[(data.startIndex + p)..<(data.startIndex + p + len)], as: UTF8.self)
        }
        while p < n {
            let domain = try string()
            let path = try string()
            _ = try string(); _ = try string(); _ = try string()      // linkTarget, dataHash, encKey
            let mode = try u16()
            try skip(8 + 4 + 4 + 4 + 4 + 4 + 8 + 1)                   // inode uid gid mtime atime ctime size protection
            guard p < n else { throw ArchiveError("truncated mbdb") }
            let props = Int(data[data.startIndex + p]); p += 1
            for _ in 0..<props { _ = try string(); _ = try string() }
            if mode & 0xF000 == 0x8000 {
                legacyIDs.insert(Self.fileID(domain: domain, path: path))
                if path.hasPrefix(Self.partsPrefix) { legacyParts.append((domain, path)) }
            }
            entryCount += 1
        }
    }
}
