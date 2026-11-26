import Testing
import Foundation
@testable import ArchiveCore

/// `<PREFIX>_SOURCE_PRIORITY`: an archive whose call and recording labels predate the built-in convention keeps its own winners.
@Suite struct SourcePriorityTests {
    func file(_ json: String) -> URL {
        let url = Fixtures.tempDir("priority").appendingPathComponent("priority.json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Labels chosen before the convention (device names, no `phone-` prefix), with one log added after the table was built.
    static let legacy = SourcePriority(calls: ["handset-2026", "mac", "handset15", "laptop", "android-xml", "messenger"],
                                       callsAddedLater: ["laptop-restored-2021"],
                                       recordings: ["memo-library-2026-11", "vm-handset-2026", "vm-handset15-2024"])

    @Test func noVariableMeansTheBuiltInLists() throws {
        #expect(try SourcePriority.fromEnvironment([:]) == .builtIn)
        #expect(try SourcePriority.fromEnvironment([SourcePriority.environmentKey: ""]) == .builtIn)
        #expect(SourcePriority.builtIn.calls == CallImporter.priority && SourcePriority.builtIn.recordings == RecordingImporter.priority)
        #expect(SourcePriority.builtIn.callsAddedLater.isEmpty)
    }

    @Test func aFileReplacesOnlyTheListsItNames() throws {
        let url = file(#"{"calls": ["handset-2026", "mac"], "calls_added_later": ["laptop-restored-2021"]}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let p = try SourcePriority.fromEnvironment([SourcePriority.environmentKey: url.path])
        #expect(p.calls == ["handset-2026", "mac"])
        #expect(p.callsAddedLater == ["laptop-restored-2021"])
        #expect(p.recordings == RecordingImporter.priority)
    }

    @Test func aBadFileIsRefusedNotIgnored() throws {
        for bad in [#"["mac"]"#, #"{"call": ["mac"]}"#, #"{"calls": "mac"}"#, #"{"calls": ["mac", ""]}"#, #"{"recordings": ["a", "a"]}"#, "not json"] {
            let url = file(bad)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(throws: ArchiveError.self) { try SourcePriority.load(from: url) }
        }
        #expect(throws: ArchiveError.self) { try SourcePriority.fromEnvironment([SourcePriority.environmentKey: "/nonexistent/priority.json"]) }
    }

    @Test func legacyListsRankInTheirOwnOrder() {
        let p = Self.legacy
        let order = ["handset-2026", "mac", "handset15", "laptop", "android-xml", "messenger", "unlisted", "late-mac-2020", "laptop-restored-2021"]
        let ranks = order.map { CallImporter.rank($0, using: p) }
        #expect(ranks == ranks.sorted() && Set(ranks).count == ranks.count)
        // an added-later label that starts like a listed one (`laptop-...`) still ranks last, not with `laptop`
        #expect(CallImporter.rank("laptop-restored-2021", using: p) > CallImporter.rank("laptop", using: p))
        // with the built-in lists the same labels mostly match nothing
        #expect(CallImporter.rank("handset-2026") == SourceRank.unmatched)
        let rec = ["memo-library-2026-11", "vm-handset-2026", "vm-handset15-2024", "memo-itunes"].map { RecordingImporter.rank($0, using: p) }
        #expect(rec == rec.sorted() && Set(rec).count == rec.count)
    }

    /// End to end: the same call in three legacy logs; the configured list picks the winner the built-in convention would not.
    @Test func callsImportUsesTheConfiguredWinner() throws {
        let rows: [CallFixtures.Row] = [
            ("mac", "UID-1", "+12125550111", "", CallFixtures.t0, 120, "out", "answered", "phone"),
            ("handset-2026", "UID-1", "+12125550111", "", CallFixtures.t0, 120, "out", "answered", "phone"),
            ("laptop-restored-2021", "UID-1", "+12125550111", "", CallFixtures.t0, 120, "out", "answered", "phone"),
        ]
        for (priority, winner) in [(Self.legacy, "handset-2026"), (SourcePriority.builtIn, "mac")] {
            let t = try TestArchive(); defer { t.cleanup() }
            let dir = CallFixtures.tsv(rows); defer { try? FileManager.default.removeItem(at: dir) }
            let s = try CallImporter.importExport(at: dir, into: t.db, priority: priority).stats
            #expect(s.canonical == 1 && s.duplicates == 2)
            #expect(try t.db.scalarString("SELECT source_label FROM call WHERE canonical_id IS NULL") == winner)
        }
    }
}
