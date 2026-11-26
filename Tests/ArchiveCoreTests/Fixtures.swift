import Foundation
@testable import ArchiveCore

/// Synthetic data only: 555-01xx numbers (reserved for fiction) and invented names.
enum Fixtures {
    static let me = "+12125550100"
    static let alice = "(212) 555-0111"      // -> +12125550111
    static let bob = "+12125550122"
    static let carol = "212-555-0133"

    static func tempDir(_ tag: String = "ma") -> URL {
        let base = ProcessInfo.processInfo.environment["MA_TEST_TMP"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let u = base.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func sms(address: String, date: Int64, type: Int, body: String, name: String = "(Unknown)") -> String {
        "  <sms protocol=\"0\" address=\"\(address)\" date=\"\(date)\" type=\"\(type)\" subject=\"null\" body=\"\(body)\" toa=\"null\" sc_toa=\"null\" service_center=\"null\" read=\"1\" status=\"-1\" locked=\"0\" date_sent=\"0\" readable_date=\"x\" contact_name=\"\(name)\" />\n"
    }

    static func mms(address: String, date: Int64, box: Int, mID: String = "null", trID: String = "null",
                    parts: [String], addrs: [(String, Int)]) -> String {
        var s = "  <mms date=\"\(date)\" msg_box=\"\(box)\" address=\"\(address)\" m_id=\"\(mID)\" tr_id=\"\(trID)\" sub=\"null\" text_only=\"0\" readable_date=\"x\" contact_name=\"Group\">\n    <parts>\n"
        s += "      <part seq=\"-1\" ct=\"application/smil\" name=\"null\" text=\"&lt;smil&gt;&lt;head&gt;&lt;layout/&gt;&lt;/head&gt;&lt;/smil&gt;\" />\n"
        for p in parts { s += "      " + p + "\n" }
        s += "    </parts>\n    <addrs>\n"
        for (a, t) in addrs { s += "      <addr address=\"\(a)\" type=\"\(t)\" charset=\"106\" />\n" }
        s += "    </addrs>\n  </mms>\n"
        return s
    }

    static func textPart(_ t: String) -> String { "<part seq=\"0\" ct=\"text/plain\" name=\"null\" chset=\"106\" text=\"\(t)\" />" }
    static func dataPart(_ bytes: [UInt8], ct: String = "image/jpeg", name: String = "img.jpg") -> String {
        "<part seq=\"1\" ct=\"\(ct)\" name=\"\(name)\" fn=\"\(name)\" data=\"\(Data(bytes).base64EncodedString())\" />"
    }

    static func file(_ items: [String], count: Int? = nil) -> String {
        let n = count ?? items.reduce(0) { $0 + ($1.contains("<mms") ? 1 : 1) }
        return "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\n<!--File Created By SMS Backup & Restore (synthetic)-->\n<smses count=\"\(n)\" backup_set=\"x\" backup_date=\"0\" type=\"full\">\n" + items.joined() + "</smses>\n"
    }

    static func write(_ s: String, to dir: URL, name: String) -> URL {
        let u = dir.appendingPathComponent(name)
        try! s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// Deterministic fake "photo" bytes.
    static func blob(_ seed: UInt8, count: Int = 2048) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: Int($0) &* 31 &+ Int(seed)) } }
}

struct TestArchive {
    let dir: URL
    let root: ArchiveRoot
    let db: Database
    init() throws {
        dir = Fixtures.tempDir()
        root = ArchiveRoot(url: dir.appendingPathComponent("root"))
        db = try Schema.openArchive(root: root)
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
    @discardableResult
    func importXML(_ xml: String, name: String, chunk: Int = 4 << 20) throws -> ImportReport {
        let f = Fixtures.write(xml, to: dir, name: name)
        return try AndroidSMSImporter.importFile(at: f, into: db, root: root, scanChunkSize: chunk)
    }
}

extension TimeZone {
    /// The zone the fixtures' day cutoffs and zone-less times were written for, pinned so the suite passes in any local zone.
    static let newYork = TimeZone(identifier: "America/New_York")!
    /// The fixed offset the 2011 Facebook export fixtures were written for.
    static let utcMinus4 = TimeZone(secondsFromGMT: -4 * 3600)!
}
