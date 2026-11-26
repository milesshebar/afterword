import Foundation

/// Stores names from the Mac's Contacts (the `AddressBook-v22.abcddb` stores under
/// `~/Library/Application Support/AddressBook/Sources`) for handles already in the archive.
///
/// Read-only on Contacts: each store is copied with its `-wal`/`-shm` into a temporary folder and only the copy is opened.
/// Matching is by the archive's own normalization (phones to E.164, emails lowercased); a value with no handle in the
/// archive is ignored, so this never creates handles. Names are stored in `contact_name` with origin `<label>`
/// (`macos-contacts-YYYY-MM-DD`) at priority 25: above an old iPhone backup's AddressBook, below the app's live Contacts
/// lookup. A later run replaces every earlier `macos-contacts*` origin, which is how the names are refreshed.
public enum MacContactsImporter {
    public static let kind = "macos-contacts"
    public static let priority = 25
    public static let storeName = "AddressBook-v22.abcddb"
    public static var defaultSourcesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AddressBook/Sources")
    }

    public static func defaultLabel(now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = LocalZone.current()
        f.dateFormat = "yyyy-MM-dd"
        return kind + "-" + f.string(from: now)
    }

    public struct Report: Sendable {
        public var label = ""
        public var stores = 0
        public var namedCards = 0              // cards with a usable name
        public var values = 0                  // phone numbers + emails on named cards
        public var valuesMatched = 0           // of those, the ones that are an archive handle
        public var handlesNamed = 0            // distinct handles given a name by this run
        public var handlesNewlyNamed = 0       // of those, handles that had no other stored name
        public var handlesWithSeveralNames = 0 // a handle on two cards with different names (all kept; view picks one)
        public var namesStored = 0
        public var previousNamesRemoved = 0    // earlier macos-contacts* rows replaced
        public var dryRun = false
    }

    /// The stores under `root`: `root` itself if it holds one, else each subfolder that does.
    public static func stores(under root: URL) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(storeName).path) { return [root.appendingPathComponent(storeName)] }
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.map { $0.appendingPathComponent(storeName) }.filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    /// (name, value) pairs from one store, read from a temporary copy.
    static func readStore(_ store: URL, scratch: URL, report: inout Report) throws -> [(name: String, value: String)] {
        let fm = FileManager.default
        let dir = scratch.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: store.path + suffix)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dir.appendingPathComponent(storeName + suffix)) }
        }
        let db = try Database(path: dir.appendingPathComponent(storeName).path, readOnly: true)
        func clean(_ s: String?) -> String? { s?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        var names: [Int64: String] = [:]
        let p = try db.prepare("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD")
        while try p.step() {
            let person = [clean(p.string(1)), clean(p.string(2))].compactMap { $0 }.joined(separator: " ")
            if let name = person.nilIfEmpty ?? clean(p.string(3)) ?? clean(p.string(4)) { names[p.int(0)] = name }
        }
        report.namedCards += names.count
        var out: [(String, String)] = []
        for sql in ["SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER", "SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"] {
            let st = try db.prepare(sql)
            while try st.step() {
                guard let name = names[st.int(0)], let v = clean(st.string(1)) else { continue }
                out.append((name, v))
            }
        }
        report.values += out.count
        return out
    }

    public static func importContacts(from root: URL, into db: Database, label: String? = nil, dryRun: Bool = false) throws -> Report {
        var r = Report()
        r.label = label ?? defaultLabel()
        r.dryRun = dryRun
        guard r.label.hasPrefix(kind) else { throw ArchiveError("the label must start with \(kind)") }
        let found = stores(under: root)
        guard !found.isEmpty else { throw ArchiveError("no \(storeName) at or under \(root.path)") }
        r.stores = found.count
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("macos-contacts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var pairs: [(String, String)] = []
        for s in found { pairs += try readStore(s, scratch: scratch, report: &r) }

        // Existing handles only: normalized -> id.
        var handles: [String: Int64] = [:]
        let hs = try db.prepare("SELECT id, normalized FROM handle")
        while try hs.step() { handles[hs.string(1) ?? ""] = hs.int(0) }
        var named: [Int64: Set<String>] = [:]
        for (name, value) in pairs {
            guard let n = HandleNormalizer.normalize(value), let hid = handles[n.normalized] else { continue }
            r.valuesMatched += 1
            named[hid, default: []].insert(name)
        }
        r.handlesNamed = named.count
        r.handlesWithSeveralNames = named.values.filter { $0.count > 1 }.count
        r.namesStored = named.values.reduce(0) { $0 + $1.count }
        var hadName = Set<Int64>()
        let hn = try db.prepare("SELECT DISTINCT handle_id FROM contact_name WHERE origin NOT LIKE 'macos-contacts%'")
        while try hn.step() { hadName.insert(hn.int(0)) }
        r.handlesNewlyNamed = named.keys.filter { !hadName.contains($0) }.count
        r.previousNamesRemoved = Int(try db.scalarInt("SELECT count(*) FROM contact_name WHERE origin LIKE 'macos-contacts%'"))
        if dryRun { return r }

        var rows: [(Int64, String)] = []
        for hid in named.keys.sorted() { for name in named[hid]!.sorted() { rows.append((hid, name)) } }
        let lines: [String] = rows.map { "\($0.0)\u{1}\($0.1)" }
        let digest = Hashing.sha1Hex(Data((r.label + "\n" + lines.joined(separator: "\n")).utf8))
        try db.transaction {
            try db.exec("DELETE FROM contact_name WHERE origin LIKE 'macos-contacts%'")
            try db.exec("DELETE FROM source WHERE kind = '\(kind)'")
            let src = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,?)")
            let stats = "{\"stores\":\(r.stores),\"named_cards\":\(r.namedCards),\"values\":\(r.values),\"handles_named\":\(r.handlesNamed),\"names\":\(r.namesStored)}"
            src.bind(1, kind).bind(2, r.label).bind(3, "\(kind):\(digest)").bind(4, Int64(0))
                .bind(5, Int64(Date().timeIntervalSince1970)).bind(6, stats)
            try src.run()
            let ins = try db.prepare("INSERT OR IGNORE INTO contact_name(handle_id, name, origin, priority) VALUES (?,?,?,?)")
            for (hid, name) in rows {
                ins.bind(1, hid).bind(2, name).bind(3, r.label).bind(4, priority)
                try ins.run()
            }
        }
        return r
    }
}
