import Testing
import Foundation
@testable import ArchiveCore

/// Synthetic Last.fm pages (invented artists and tracks), shaped like user.getRecentTracks with extended=1.
enum LastfmFixtures {
    static func track(_ artist: String, _ name: String, uts: Int?, album: String = "Demo Album", loved: Bool = false, nowPlaying: Bool = false) -> [String: Any] {
        var t: [String: Any] = [
            "artist": ["name": artist, "mbid": "a-\(artist)", "url": "x"],
            "name": name, "mbid": "", "loved": loved ? "1" : "0",
            "album": ["#text": album, "mbid": ""],
        ]
        if let uts { t["date"] = ["uts": String(uts), "#text": "x"] }
        if nowPlaying { t["@attr"] = ["nowplaying": "true"] }
        return t
    }

    static func write(dir: URL, user: String = "demo_user", to: Int = 1_700_000_000, pages: [[[String: Any]]], playcount: Int,
                      loves: [(String, String)] = []) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = pages.reduce(0) { $0 + $1.filter { $0["date"] != nil }.count }
        try JSONSerialization.data(withJSONObject: ["user": user, "to": to, "totalPages": pages.count, "total": total])
            .write(to: dir.appendingPathComponent("pull.json"))
        try JSONSerialization.data(withJSONObject: ["user": ["name": user, "playcount": String(playcount)]])
            .write(to: dir.appendingPathComponent("info.json"))
        for (i, tracks) in pages.enumerated() {
            let page: [String: Any] = ["recenttracks": ["track": tracks, "@attr": ["page": String(i + 1), "totalPages": String(pages.count)]]]
            try JSONSerialization.data(withJSONObject: page).write(to: dir.appendingPathComponent(String(format: "page-%05d.json", i + 1)))
        }
        if !loves.isEmpty {
            let l = loves.map { ["artist": $0.0, "title": $0.1, "loved_at": "1600000000"] }
            try JSONSerialization.data(withJSONObject: ["loves": l]).write(to: dir.appendingPathComponent("loves.json"))
        }
    }
}

@Suite struct LastfmImportTests {
    @Test func importsScrobblesSkipsNowPlayingJoinsLovesAndIsIdempotent() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = t.dir.appendingPathComponent("lastfm-1")
        try LastfmFixtures.write(dir: dir, pages: [
            [LastfmFixtures.track("Demo Band", "Song A", uts: nil, nowPlaying: true),
             LastfmFixtures.track("Demo Band", "Song A", uts: 1_600_000_300, loved: true),
             LastfmFixtures.track("Other Act", "Song B", uts: 1_600_000_200)],
            [LastfmFixtures.track("Demo Band", "Song C", uts: 1_500_000_100),
             LastfmFixtures.track("other act", "song b", uts: 1_500_000_000),      // an earlier play of the loved track, other case
             LastfmFixtures.track("Old Import", "Undated", uts: 2)],                 // Last.fm's placeholder time for a dateless play
        ], playcount: 5, loves: [("Other Act", "Song B"), ("Nobody", "Never Played")])
        #expect(LastfmImporter.isPullFolder(dir))
        let s = try LastfmImporter.importPull(at: dir, into: t.db)
        #expect(s.parsed == 5 && s.inserted == 5 && s.nowPlayingSkipped == 1 && s.reportedPlaycount == 5 && s.placeholderDated == 1)
        #expect(s.lovedFromAPI == 1 && s.lovesInFile == 2 && s.lovesMatched == 1)
        #expect(s.rowsMarkedLoved == 3)                              // Song A (API) + both plays of Song B (loves list)
        #expect(try t.db.scalarInt("SELECT count(*) FROM listen") == 5)
        #expect(try t.db.scalarString("SELECT album FROM listen WHERE track = 'Song C'") == "Demo Album")
        #expect(try t.db.scalarString("SELECT artist_mbid FROM listen WHERE track = 'Song C'") == "a-Demo Band")
        #expect(try t.db.scalarInt("SELECT ts_ms FROM listen WHERE track = 'Song C'") == 1_500_000_100_000)

        let again = try LastfmImporter.importPull(at: dir, into: t.db)
        #expect(again.inserted == 0 && again.alreadyThere == 5)
        #expect(try t.db.scalarInt("SELECT count(*) FROM source WHERE kind = 'lastfm'") == 1)

        // a later pull overlapping the first adds only the new scrobble
        let dir2 = t.dir.appendingPathComponent("lastfm-2")
        try LastfmFixtures.write(dir: dir2, to: 1_700_000_500, pages: [
            [LastfmFixtures.track("New Act", "Song D", uts: 1_650_000_000),
             LastfmFixtures.track("Demo Band", "Song A", uts: 1_600_000_300, loved: true)],
        ], playcount: 5)
        let later = try LastfmImporter.importPull(at: dir2, into: t.db)
        #expect(later.inserted == 1 && later.alreadyThere == 1)
        let sum = try #require(try LastfmImporter.summary(t.db))
        #expect(sum.rows == 6 && sum.undated == 1 && sum.byYear.map(\.0) == [2017, 2020, 2022])
    }

    @Test func archiveWithoutListensHasNoSummaryAndAFolderWithoutPagesIsNotAPull() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        #expect(try LastfmImporter.summary(t.db) == nil)
        #expect(!LastfmImporter.isPullFolder(t.dir))
    }
}
