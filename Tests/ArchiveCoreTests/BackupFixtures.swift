import Foundation
@testable import ArchiveCore

/// Builds synthetic iPhone backup folders at test time. No binary blobs are checked in, and nothing here is real data.
final class BackupFixture {
    let folder: URL
    let scratch: URL
    private(set) var entries: [(domain: String, path: String, id: String)] = []

    init(under dir: URL, name: String = "backup") {
        folder = dir.appendingPathComponent(name, isDirectory: true)
        scratch = dir.appendingPathComponent("scratch-\(name)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// `nested` mirrors iOS 10+ (`<xx>/<id>`); flat mirrors iTunes / iOS 5.
    func addFile(domain: String, path: String, data: Data, nested: Bool, listed: Bool = true, onDisk: Bool = true) {
        let id = BackupManifest.fileID(domain: domain, path: path)
        if onDisk {
            let url = nested ? folder.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id) : folder.appendingPathComponent(id)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! data.write(to: url)
        }
        if listed { entries.append((domain, path, id)) }
    }

    /// Creates an sms.db with `setup`, then files it into the backup as HomeDomain Library/SMS/sms.db.
    func addSMSDatabase(nested: Bool, _ setup: (Database) throws -> Void) {
        let url = scratch.appendingPathComponent("sms-\(UUID().uuidString).db")
        let db = try! Database(path: url.path)
        try! setup(db)
        try! db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        addFile(domain: "HomeDomain", path: "Library/SMS/sms.db", data: try! Data(contentsOf: url), nested: nested)
    }

    func addAddressBook(nested: Bool, _ setup: (Database) throws -> Void) {
        let url = scratch.appendingPathComponent("ab-\(UUID().uuidString).db")
        let db = try! Database(path: url.path)
        try! setup(db)
        addFile(domain: "HomeDomain", path: "Library/AddressBook/AddressBook.sqlitedb", data: try! Data(contentsOf: url), nested: nested)
    }

    func writeManifestDB(encryptedPlist: Bool = false) {
        let url = folder.appendingPathComponent("Manifest.db")
        try? FileManager.default.removeItem(at: url)
        let db = try! Database(path: url.path)
        try! db.exec("CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)")
        try! db.exec("CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)")
        let ins = try! db.prepare("INSERT INTO Files(fileID, domain, relativePath, flags) VALUES (?,?,?,1)")
        for e in entries { ins.bind(1, e.id).bind(2, e.domain).bind(3, e.path); try! ins.run() }
        try! db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        if encryptedPlist { writePlist(encrypted: true) }
    }

    func writePlist(encrypted: Bool) {
        let d = try! PropertyListSerialization.data(fromPropertyList: ["IsEncrypted": encrypted, "Version": "10.0"], format: .binary, options: 0)
        try! d.write(to: folder.appendingPathComponent("Manifest.plist"))
    }

    /// Legacy iOS 5 `Manifest.mbdb`, big-endian records.
    func writeManifestMBDB() {
        var out = Data("mbdb".utf8) + Data([5, 0])
        func str(_ s: String?) {
            guard let s else { out += Data([0xFF, 0xFF]); return }
            let b = Array(s.utf8)
            out += Data([UInt8(b.count >> 8), UInt8(b.count & 0xFF)]) + Data(b)
        }
        func be(_ v: UInt64, _ n: Int) { for i in (0..<n).reversed() { out.append(UInt8((v >> UInt64(8 * i)) & 0xFF)) } }
        for e in entries {
            str(e.domain); str(e.path); str(nil); str(nil); str(nil)
            be(0x81A4, 2); be(1, 8); be(501, 4); be(501, 4); be(0, 4); be(0, 4); be(0, 4); be(100, 8); be(4, 1)
            be(1, 1); str("Foo"); str("bar")                    // one property pair
        }
        // A directory record (mode 0x41ED) that must not be indexed as a file.
        str("HomeDomain"); str("Library/SMS"); str(nil); str(nil); str(nil)
        be(0x41ED, 2); be(2, 8); be(501, 4); be(501, 4); be(0, 4); be(0, 4); be(0, 4); be(0, 8); be(4, 1); be(0, 1)
        try! out.write(to: folder.appendingPathComponent("Manifest.mbdb"))
    }
}

enum IOSFixtures {
    static let modernSchema = [
        "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT)",
        "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, style INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT)",
        """
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL, text TEXT, attributedBody BLOB, handle_id INTEGER DEFAULT 0,
            subject TEXT, service TEXT, date INTEGER, is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
            cache_has_attachments INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, associated_message_guid TEXT)
        """,
        "CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER)",
        "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)",
        "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)",
        "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)",
    ]

    static let legacySchema = [
        """
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, address TEXT, date INTEGER, text TEXT, flags INTEGER, replace INTEGER, svc_center TEXT,
            group_id INTEGER, association_id INTEGER, version INTEGER, subject TEXT, country TEXT, read INTEGER, madrid_attributedBody BLOB, madrid_handle TEXT,
            madrid_version INTEGER, madrid_guid TEXT, madrid_type INTEGER, madrid_roomname TEXT, madrid_service TEXT, madrid_flags INTEGER, is_madrid INTEGER DEFAULT 0)
        """,
        "CREATE TABLE msg_group (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, type INTEGER, newest_message INTEGER, unread_count INTEGER, hash INTEGER)",
        "CREATE TABLE group_member (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER, address TEXT, country TEXT)",
        "CREATE TABLE msg_pieces (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER, data BLOB, content_type TEXT, content_loc TEXT, preview_part INTEGER, part_id INTEGER)",
        "CREATE TABLE madrid_attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER, filename TEXT, mime_type TEXT)",
    ]

    static func hex(_ d: Data) -> String { "X'" + d.map { String(format: "%02x", $0) }.joined() + "'" }
    static func sqlString(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// A typedstream exactly as Messages writes it (NSArchiver over an attributed string). Where there is no NSArchiver (Linux)
    /// the bytes are assembled by hand from a captured blob; `typedStreamMatchesNSArchiver` proves the template on macOS.
    static func attributedBody(_ text: String, mutable: Bool = true) -> Data {
        #if canImport(Darwin)
        let obj: NSAttributedString = mutable ? NSMutableAttributedString(string: text) : NSAttributedString(string: text)
        return NSArchiver.archivedData(withRootObject: obj)
        #else
        return typedStream(text, mutable: mutable)
        #endif
    }

    /// NSArchiver's output for an (NS)AttributedString holding `text` with no attributes, as captured on macOS 26.
    static func typedStream(_ text: String, mutable: Bool) -> Data {
        func len(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            if n < 0x10000 { return [0x81, UInt8(n & 0xff), UInt8(n >> 8)] }
            return [0x82, UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24)]
        }
        func cls(_ name: String) -> [UInt8] { [UInt8(name.utf8.count)] + Array(name.utf8) }
        var b: [UInt8] = [0x04, 0x0b] + Array("streamtyped".utf8) + [0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
        if mutable {
            b += cls("NSMutableAttributedString") + [0x00, 0x84, 0x84] + cls("NSAttributedString") + [0x00, 0x84, 0x84] + cls("NSObject") + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
            b += cls("NSMutableString") + [0x01, 0x84, 0x84] + cls("NSString") + [0x01, 0x95, 0x84, 0x01, 0x2b]
        } else {
            b += cls("NSAttributedString") + [0x00, 0x84, 0x84] + cls("NSObject") + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
            b += cls("NSString") + [0x01, 0x94, 0x84, 0x01, 0x2b]
        }
        let utf8 = Array(text.utf8)
        b += len(utf8.count) + utf8 + [0x86, 0x84, 0x02, 0x69, 0x49, 0x01] + len(text.utf16.count) + [0x92, 0x84, 0x84, 0x84]
        b += cls("NSDictionary") + [0x00, mutable ? 0x95 : 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86]
        return Data(b)
    }

    /// Apple-epoch seconds for a Unix-seconds instant.
    static func apple(_ unix: Int64) -> Int64 { unix - 978_307_200 }
    static func appleNS(_ unix: Int64) -> Int64 { apple(unix) * 1_000_000_000 }

    static func sha256(_ d: Data) -> String { d.withUnsafeBytes { Hashing.sha256Hex($0) } }
}
