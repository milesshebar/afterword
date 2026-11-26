import Testing
import Foundation
@testable import ArchiveCore

@Suite struct PostsReaderTests {
    /// An archive with Ann (fb:ann example, a Messenger person), her post on the owner's wall with comments, the owner's comment on her post
    /// (2025 style, "Ann Example's post"), the owner's album photos on one day, and a page photo he was tagged in with no owner named.
    func archive() throws -> (TestArchive, Int64) {
        let t = try PostsImportTests().seeded()
        let f = PostFixtures.self
        let day: Int64 = 1_300_000_000_000
        var tagged = f.post("tg", author: nil, ts: day + 9_000_000, body: nil, kind: "tagged-photo", dkey: "a|tg", basis: "tagged")
        tagged["by_me"] = false
        var mine = f.comment("mc", parent: nil, author: nil, ts: day + 5_000_000, body: "love this", precision: "second", dkey: "a|mc", on: "Ann Example")
        mine["by_me"] = true
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-test"), [
            f.post("w", author: "Ann Example", ts: day, body: "happy birthday max", dkey: "a|w"),
            f.comment("w:c0", parent: "w", author: nil, ts: day + 60_000, body: "thank you ann", dkey: "a|w|c0"),
            f.comment("w:c1", parent: "w", author: "Carl New", ts: day + 120_000, body: "me too", dkey: "a|w|c1"),
            mine,
            f.post("a1", author: nil, ts: day + 3_600_000, body: "IMG_1", kind: "album-photo", dkey: "a|a1", ext: "1", basis: "uploaded"),
            f.post("a2", author: nil, ts: day + 3_610_000, body: nil, kind: "album-photo", dkey: "a|a2", ext: "2", basis: "uploaded"),
            f.post("a3", author: nil, ts: day + 3_620_000, body: nil, kind: "album-photo", dkey: "a|a3", ext: "3", basis: "uploaded"),
            f.post("s", author: nil, ts: day + 7_200_000, body: "a status of mine", kind: "status", dkey: "a|s"),
            tagged,
        ].map { r in var r = r; if r["kind"] as? String == "album-photo" { r["target_text"] = "Mobile Uploads" }; return r },
            in: t.dir, name: "r.jsonl"), into: t.db)
        let ann = try t.db.scalarInt("SELECT id FROM handle WHERE normalized = 'fb:ann example'")
        return (t, ann)
    }

    @Test func aPersonsPostsAndComments() throws {
        let (t, ann) = try archive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        #expect(try r.postsAvailable())
        let items = try r.posts(handles: [ann])
        // her post, the two comments on it (the owner's and Carl's), the owner's comment on "Ann Example's post"; not his album or status
        #expect(Set(items.map { $0.body ?? "" }) == ["happy birthday max", "thank you ann", "me too", "love this"])
        let mine = items.filter { $0.byMe }
        #expect(Set(mine.map { $0.body ?? "" }) == ["thank you ann", "love this"])
        #expect(items.first { $0.body == "love this" }?.target == "Ann Example")
        #expect(items.map { $0.ts } == items.map { $0.ts }.sorted(by: >))
        // paging
        let first = try r.posts(handles: [ann], limit: 2)
        let rest = try r.posts(handles: [ann], limit: 10, before: (first.last!.ts, first.last!.id))
        #expect(first.count == 2 && rest.count == 2 && Set(first.map(\.id)).isDisjoint(with: Set(rest.map(\.id))))
    }

    @Test func mineIsByMeNeverAMissingAuthor() throws {
        let (t, _) = try archive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        let mine = try r.posts(handles: [], mineOnly: true)
        #expect(!mine.contains { $0.kind == "tagged-photo" })          // no author, but not the owner's
        #expect(mine.allSatisfy { $0.byMe })
        let day = try r.posts(from: 1_300_000_000_000, to: 1_300_000_000_000 + 86_400_000)
        let tagged = day.first { $0.kind == "tagged-photo" }
        #expect(tagged != nil && tagged!.byMe == false && tagged!.author == nil && tagged!.basis == "tagged")
    }

    @Test func albumPhotosOfOneAlbumAndDayFoldIntoOneLine() throws {
        let (t, _) = try archive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        let items = try r.posts(from: 1_300_000_000_000, to: 1_300_000_000_000 + 86_400_000)
        let entries = ArchiveReader.groupAlbums(items, zone: TimeZone(identifier: "America/New_York")!)
        let albums = entries.filter { $0.album != nil }
        #expect(albums.count == 1 && albums[0].count == 3 && albums[0].album == "Mobile Uploads")
        #expect(entries.count == items.count - 2)
        // search still finds each caption
        #expect(try r.searchPosts("IMG_1").map { $0.externalID } == ["1"])
        let hits = try r.searchPosts("birthday")
        #expect(hits.count == 1 && hits[0].snippet?.contains("\u{1}birthday\u{2}") == true)
    }

    @Test func anArchiveWithoutPostTablesHasNoPosts() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        #expect(try !r.postsAvailable())
        #expect(try r.posts(handles: [1]).isEmpty && r.searchPosts("x").isEmpty)
    }
}

@Suite struct PostsWebTests {
    @Test func personPageAndSearchServePostsAndComments() throws {
        let (t, ann) = try PostsReaderTests().archive(); defer { t.cleanup() }
        _ = try PeopleStore.rematch(db: t.db)
        let service = try WebService(root: t.root)
        let site = WebSite(service: service, gate: WebSite.Gate(), webRoot: t.dir, cacheRoot: t.dir.appendingPathComponent("cache"))
        func get(_ path: String, _ q: [String: String] = [:]) -> HTTPResponse {
            site.handle(HTTPRequest(method: "GET", path: path, query: q, headers: ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith], peer: "127.0.0.1"))
        }
        let people = try service.people().people
        let pid = try #require(people.first { $0.name.lowercased().contains("ann") }?.id, "people: \(people.map(\.name))")
        let detail = try JSONSerialization.jsonObject(with: get("/api/person/\(pid)").body) as? [String: Any]
        #expect(detail?["posts"] as? Int == 4)
        let r = get("/api/posts", ["person": "\(pid)", "tz": "-300"])
        #expect(r.status == 200)
        let page = try JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        let entries = page?["entries"] as? [[String: Any]] ?? []
        #expect(entries.count == 4)
        let mine = entries.compactMap { ($0["items"] as? [[String: Any]])?.first }.filter { $0["byMe"] as? Bool == true }
        #expect(mine.count == 2)
        let s = try JSONSerialization.jsonObject(with: get("/api/posts/search", ["q": "birthday"]).body) as? [[String: Any]]
        #expect(s?.count == 1 && s?.first?["isComment"] as? Bool == false)
        #expect(get("/api/posts", [:]).status == 400)
        _ = ann
    }
}
