import Foundation

/// Names from an iPhone backup's `AddressBook.sqlitedb` (a decrypted extract, `extracted/addressbook/HomeDomain/Library/AddressBook/`)
/// stored in `contact_name` for handles **already in the archive**: a value with no handle is ignored, so this never creates handles
/// (the same rule as `MacContactsImporter`). Origin `iphone-addressbook-<label>`, priority 20 (the old backups' AddressBook priority:
/// below the Mac's Contacts, above Android `contact_name`s). Idempotent by the database's SHA-256: the same file imports once.
public enum IOSAddressBookImporter {
    public static let kind = "ios-addressbook"

    public struct Report: Sendable, Codable, Equatable {
        public var label = ""
        public var alreadyImported = false
        public var cards = 0, namedCards = 0
        public var values = 0                  // phone numbers and emails on named cards
        public var valuesMatched = 0           // of those, the ones that are an archive handle
        public var handlesNamed = 0            // distinct handles given a name by this run
        public var handlesNewlyNamed = 0       // of those, handles that had no stored name at all before
        public var phoneHandlesNewlyNamed = 0  // of the newly named, phone-number handles (bare numbers)
        public var namesStored = 0             // contact_name rows added
        public var handlesWithoutAnyNameBefore = 0, handlesWithoutAnyNameAfter = 0
    }

    /// `path`: the `AddressBook.sqlitedb` file, or a folder that holds `HomeDomain/Library/AddressBook/AddressBook.sqlitedb`.
    public static func importAddressBook(at path: URL, label: String, into db: Database) throws -> Report {
        var url = path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
            url = path.appendingPathComponent("HomeDomain/Library/AddressBook/AddressBook.sqlitedb")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError("no AddressBook.sqlitedb at \(url.path)") }
        var report = Report()
        report.label = label
        let origin = "iphone-addressbook-" + label
        let (sha, size) = try Hashing.sha256Hex(ofFile: url)
        let seen = try db.prepare("SELECT stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, sha)
        if try seen.step() {
            var r = seen.string(0).flatMap { try? JSONDecoder().decode(Report.self, from: Data($0.utf8)) } ?? report
            r.alreadyImported = true
            seen.reset()
            return r
        }
        seen.reset()

        let ab = try Database(path: url.path, readOnly: true, immutable: true)
        var names: [Int64: String] = [:]
        let p = try ab.prepare("SELECT ROWID, First, Last, Organization, Nickname FROM ABPerson")
        while try p.step() {
            report.cards += 1
            let person = [p.string(1), p.string(2)].compactMap { $0?.trimmingCharacters(in: .whitespaces).nilIfEmpty }.joined(separator: " ")
            let name = person.nilIfEmpty ?? p.string(3)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? p.string(4)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            if let name { names[p.int(0)] = name }
        }
        report.namedCards = names.count

        try db.transaction {
            var handles: [String: Int64] = [:], kinds: [Int64: String] = [:]
            let hs = try db.prepare("SELECT id, normalized, kind FROM handle")
            while try hs.step() { if let n = hs.string(1) { handles[n] = hs.int(0); kinds[hs.int(0)] = hs.string(2) ?? "" } }
            hs.reset()
            var named = Set<Int64>()
            let nm = try db.prepare("SELECT DISTINCT handle_id FROM contact_name")
            while try nm.step() { named.insert(nm.int(0)) }
            nm.reset()
            report.handlesWithoutAnyNameBefore = handles.count - named.count
            let ins = try db.prepare("INSERT OR IGNORE INTO contact_name(handle_id, name, origin, priority) VALUES (?,?,?,?)")
            var touched = Set<Int64>()
            let mv = try ab.prepare("SELECT record_id, value FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL ORDER BY UID")
            while try mv.step() {
                guard let name = names[mv.int(0)], let value = mv.string(1) else { continue }
                report.values += 1
                guard let n = HandleNormalizer.normalize(value)?.normalized, let hid = handles[n] else { continue }
                report.valuesMatched += 1
                ins.bind(1, hid).bind(2, name).bind(3, origin).bind(4, ContactPriority.iphoneAddressBook)
                try ins.run()
                if db.changes > 0 { report.namesStored += 1 }
                touched.insert(hid)
            }
            report.handlesNamed = touched.count
            let fresh = touched.subtracting(named)
            report.handlesNewlyNamed = fresh.count
            report.phoneHandlesNewlyNamed = fresh.filter { kinds[$0] == HandleKind.phone.rawValue }.count
            report.handlesWithoutAnyNameAfter = report.handlesWithoutAnyNameBefore - fresh.count

            let src = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,?)")
            src.bind(1, kind).bind(2, url.path).bind(3, sha).bind(4, size).bind(5, Int64(Date().timeIntervalSince1970))
                .bind(6, String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            try src.run()
        }
        return report
    }
}
