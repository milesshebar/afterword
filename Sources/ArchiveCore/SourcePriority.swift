import Foundation

/// Which source labels win a duplicate group in the call and recording tables. The built-in lists (`CallImporter.priority`,
/// `RecordingImporter.priority`) follow a label convention (`phone-2024`, `mac-...`, `vm-phone-...`). An archive whose labels
/// were chosen before that convention, or follow their own, names a JSON file in `<PREFIX>_SOURCE_PRIORITY` instead:
///
///     {"calls": ["phone-2026", "mac", "phone-2019"], "calls_added_later": ["mac-restored-2021"], "recordings": ["vm-phone-2026"]}
///
/// Every key is optional; a missing list keeps the built-in one (`calls_added_later` defaults to none). Entries match the way the
/// built-in prefixes do (a label equal to an entry, or starting with `<entry>-`); earlier entries win. A `calls_added_later` entry
/// ranks after every other log, listed or not, `late-` labels included, in the order listed. Every import re-links the whole table,
/// so the file must stay the same from one import to the next. archivectl reads the file before it opens the archive, so an
/// unreadable or malformed file stops the import before anything is written; the library itself never reads the environment.
public struct SourcePriority: Equatable, Sendable {
    public var calls: [String]
    public var callsAddedLater: [String]
    public var recordings: [String]

    public init(calls: [String] = CallImporter.priority, callsAddedLater: [String] = [], recordings: [String] = RecordingImporter.priority) {
        self.calls = calls
        self.callsAddedLater = callsAddedLater
        self.recordings = recordings
    }

    public static let builtIn = SourcePriority()

    public static var environmentKey: String { Product.environmentPrefix + "_SOURCE_PRIORITY" }

    static let keys: Set<String> = ["calls", "calls_added_later", "recordings"]

    public static func load(from url: URL) throws -> SourcePriority {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ArchiveError("cannot read the source priority file \(url.path): \(error.localizedDescription)") }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ArchiveError("\(url.path): not a JSON object")
        }
        if let unknown = Set(obj.keys).subtracting(keys).sorted().first {
            throw ArchiveError("\(url.path): unknown key \"\(unknown)\" (allowed: \(keys.sorted().joined(separator: ", ")))")
        }
        func list(_ key: String) throws -> [String]? {
            guard let v = obj[key] else { return nil }
            guard let a = v as? [String] else { throw ArchiveError("\(url.path): \"\(key)\" must be a list of labels") }
            if a.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { throw ArchiveError("\(url.path): \"\(key)\" holds an empty label") }
            if Set(a).count != a.count { throw ArchiveError("\(url.path): \"\(key)\" lists a label twice") }
            return a
        }
        var p = SourcePriority()
        if let a = try list("calls") { p.calls = a }
        if let a = try list("calls_added_later") { p.callsAddedLater = a }
        if let a = try list("recordings") { p.recordings = a }
        return p
    }

    /// The file named by `<PREFIX>_SOURCE_PRIORITY`, else the built-in lists.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SourcePriority {
        guard let path = environment[environmentKey], !path.isEmpty else { return .builtIn }
        return try load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
}
