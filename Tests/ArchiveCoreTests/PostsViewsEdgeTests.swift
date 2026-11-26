import Testing
import Foundation
@testable import ArchiveCore

/// Posts views: one test per edge case where the logic is testable.
@Suite struct PostsViewsEdgeTests {
    /// Ann's handle, with 14 posts and 3 comments at one timestamp, and posts numbered past 9 so string and numeric ids disagree.
    func ties() throws -> (TestArchive, Int64) {
        let t = try PostsImportTests().seeded()
        let f = PostFixtures.self
        let ts: Int64 = 1_466_098_371_000
        var recs: [[String: Any]] = []
        for i in 0..<14 { recs.append(f.post("p\(i)", author: "Ann Example", ts: ts, body: "same second \(i)", precision: "second", dkey: "t|p\(i)")) }
        for i in 0..<3 { recs.append(f.comment("p0:c\(i)", parent: "p0", author: "Ann Example", ts: ts, body: "comment \(i)", precision: "second", dkey: "t|c\(i)")) }
        recs.append(f.post("old", author: "Ann Example", ts: ts - 86_400_000, body: "a day before second", precision: "second", dkey: "t|old"))
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-ties"), recs, in: t.dir, name: "t.jsonl"), into: t.db)
        return (t, try t.db.scalarInt("SELECT id FROM handle WHERE normalized = 'fb:ann example'"))
    }

    @Test func f1PagingThroughTimestampTiesReturnsEveryRowOnce() throws {
        let (t, ann) = try ties(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        let all = try r.posts(handles: [ann], limit: 1000)
        #expect(all.count == 18)
        var seen: [String] = []
        var before: (ts: Int64, id: String)? = nil
        for _ in 0..<40 {
            let page = try r.posts(handles: [ann], limit: 2, before: before)
            if page.isEmpty { break }
            seen += page.map(\.id)
            before = (page.last!.ts, page.last!.id)
        }
        #expect(seen.count == 18 && Set(seen).count == 18)
        #expect(seen == all.map(\.id))
    }

    @Test func f2SearchDayAndPersonFiltersCombine() throws {
        let (t, ann) = try ties(); defer { t.cleanup() }
        let f = PostFixtures.self
        var mine = f.post("m", author: nil, ts: 1_466_098_371_000 + 5_000, body: "same second mine", precision: "second", dkey: "t|m")
        mine["by_me"] = true
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-more"), [mine], in: t.dir, name: "m.jsonl"), into: t.db)
        let r = try ArchiveReader(root: t.root)
        // search + mine: only the owner's own
        let m = try r.searchPosts("same second", filter: PostsFilter(mineOnly: true))
        #expect(m.map(\.body) == ["same second mine"])
        // search + person
        #expect(try r.searchPosts("same second", filter: PostsFilter(handles: [ann])).count == 14)
        // search + day: nothing a day before
        let day = PostsFilter(fromMs: 1_466_098_371_000 - 86_400_000, toMs: 1_466_098_371_000 - 1)
        #expect(try r.searchPosts("day", filter: day).map(\.body) == ["a day before second"])
        #expect(try r.searchPosts("same", filter: day).isEmpty)
        #expect(try r.searchPosts("second", filter: PostsFilter(handles: [ann], fromMs: day.fromMs, toMs: day.toMs)).count == 1)
        // person + day
        #expect(try r.posts(filter: PostsFilter(handles: [ann], fromMs: day.fromMs, toMs: day.toMs)).map(\.body) == ["a day before second"])
        // the CLI parses every combination and refuses nonsense
        let q = try PostsCLIQuery.parse(["--mine", "--search", "birthday", "--day", "2011-03-13"]).get()
        #expect(q.mine && q.search == "birthday" && q.day == "2011-03-13")
        #expect(throws: (any Error).self) { try PostsCLIQuery.parse(["--search"]).get() }
        #expect(throws: (any Error).self) { try PostsCLIQuery.parse([]).get() }
    }

    @Test func f3f7PersonPostsStateResetsAndPages() throws {
        var s = PersonPostsState(pageSize: 2)
        s.showPosts = true
        s.personChanged(total: 0)                               // a person with no posts: back to messages, toggle hidden
        #expect(!s.showPosts && !s.toggleVisible)
        s.personChanged(total: 5)
        #expect(!s.showPosts && s.toggleVisible && s.total == 5)
        s.showPosts = true
        let item = { (i: Int64) in PostItem(rowID: i, isComment: false, ts: 1_000 - i, precision: "second", basis: "posted", platform: "facebook",
                                           account: "facebook:owner", kind: "status", byMe: true, author: nil, authorHandle: nil, target: nil,
                                           targetText: nil, body: "\(i)", context: nil, link: nil, place: nil, postID: nil, postBody: nil, onMe: false,
                                           externalID: nil, snippet: nil) }
        s.received([item(1), item(2)])
        #expect(s.canLoadMore && s.loaded == 2 && s.cursor?.id == "p2")
        s.received([item(3), item(4)])
        s.received([item(5)])                                   // a short page: the end
        #expect(!s.canLoadMore && s.loaded == 5 && s.total == 5)
        #expect(s.entries(zone: .gmt).count == 5)
    }

    @Test func f6ADayEndsAtTheNextLocalMidnight() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let spring = try #require(PostsCLIQuery.dayRange("2026-03-08", zone: ny))
        #expect(spring.to - spring.from == 23 * 3_600_000)
        let fall = try #require(PostsCLIQuery.dayRange("2026-11-01", zone: ny))
        #expect(fall.to - fall.from == 25 * 3_600_000)
        #expect(PostsCLIQuery.dayRange("2026-13-40", zone: ny) == nil)
    }

    @Test func f8SearchOrderIsHonored() throws {
        let (t, _) = try ties(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        let newest = try r.searchPosts("second", order: .newest)
        let oldest = try r.searchPosts("second", order: .oldest)
        #expect(newest.count == 15 && newest.first?.body?.hasPrefix("same second") == true && oldest.first?.body == "a day before second")
        #expect(newest.map(\.ts) == newest.map(\.ts).sorted(by: >))
    }

    @Test func f9LimitsAreValidated() throws {
        let (t, ann) = try ties(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        #expect(try r.posts(handles: [ann], limit: -1).isEmpty)
        #expect(try r.posts(handles: [ann], limit: Int.max).count == 18)
        #expect(throws: (any Error).self) { try PostsCLIQuery.parse(["--mine", "--limit", "-1"]).get() }
        #expect(throws: (any Error).self) { try PostsCLIQuery.parse(["--mine", "--limit", "9223372036854775807"]).get() }
        #expect(try PostsCLIQuery.parse(["--mine", "--limit", "500"]).get().limit == 500)
    }
}

@Suite struct PostsWebEdgeTests {
    func site() throws -> (TestArchive, WebSite, WebService, Int64) {
        let (t, _) = try PostsReaderTests().archive()
        _ = try PeopleStore.rematch(db: t.db)
        let service = try WebService(root: t.root)
        let site = WebSite(service: service, gate: WebSite.Gate(), webRoot: t.dir, cacheRoot: t.dir.appendingPathComponent("cache"))
        let pid = try #require(try service.people().people.first { $0.name.lowercased().contains("ann") }?.id)
        return (t, site, service, pid)
    }
    func get(_ site: WebSite, _ path: String, _ q: [String: String] = [:], headers: [String: String]? = nil, peer: String = "127.0.0.1") -> HTTPResponse {
        site.handle(HTTPRequest(method: "GET", path: path, query: q, headers: headers ?? ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith], peer: peer))
    }

    @Test func f4PostsSearchHonorsThePersonScope() throws {
        let (t, site, _, pid) = try site(); defer { t.cleanup() }
        // "m" matches "max" (Ann's post), "me" (a comment on it) and "mine" (the owner's own status, nothing to do with Ann)
        let everywhere = try JSONSerialization.jsonObject(with: get(site, "/api/posts/search", ["q": "m"]).body) as? [[String: Any]] ?? []
        let inAnn = try JSONSerialization.jsonObject(with: get(site, "/api/posts/search", ["q": "m", "person": "\(pid)"]).body) as? [[String: Any]] ?? []
        #expect(everywhere.count == 3 && inAnn.count == 2 && !inAnn.contains { $0["body"] as? String == "a status of mine" })
        #expect(get(site, "/api/posts/search", ["q": "x", "person": "999999"]).status == 404)
    }

    @Test func f5AlbumsFoldByTheViewersZoneAtEachRowsDate() throws {
        let t = try PostsImportTests().seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        // June 30 23:30 EDT and July 1 00:30 EDT: two days in New York, one day at a fixed -05:00
        let a = Int64(1_782_876_600_000), b = a + 3_600_000
        var r1 = f.post("a", author: "Ann Example", ts: a, body: nil, precision: "second", kind: "album-photo", dkey: "z|a", ext: "1", basis: "uploaded")
        var r2 = f.post("b", author: "Ann Example", ts: b, body: nil, precision: "second", kind: "album-photo", dkey: "z|b", ext: "2", basis: "uploaded")
        r1["target_text"] = "Summer"; r2["target_text"] = "Summer"
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-z"), [r1, r2], in: t.dir, name: "z.jsonl"), into: t.db)
        _ = try PeopleStore.rematch(db: t.db)
        let service = try WebService(root: t.root)
        let site = WebSite(service: service, gate: WebSite.Gate(), webRoot: t.dir, cacheRoot: t.dir)
        let pid = try #require(try service.people().people.first { $0.name.lowercased().contains("ann") }?.id)
        func entries(_ q: [String: String]) throws -> [[String: Any]] {
            (try JSONSerialization.jsonObject(with: get(site, "/api/posts", q.merging(["person": "\(pid)"]) { a, _ in a }).body) as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        }
        #expect(try entries(["zone": "America/New_York"]).count == 2)      // two local days: two lines
        #expect(try entries(["tz": "-300"]).count == 1)                    // a fixed offset (old pages) folds them
        #expect(get(site, "/api/posts", ["person": "\(pid)", "zone": "Not/AZone"]).status == 200)   // an unknown zone falls back, never fails
    }

    @Test func postsEndpointsSitBehindTheSameGateAndLimits() throws {
        let (t, site, _, pid) = try site(); defer { t.cleanup() }
        for path in ["/api/posts", "/api/posts/search"] {
            let q = path.hasSuffix("search") ? ["q": "birthday"] : ["person": "\(pid)"]
            #expect(get(site, path, q, headers: ["Host": "127.0.0.1"]).status == 403)                                   // no X-Requested-With
            #expect(get(site, path, q, peer: "172.16.5.208").status == 403)                                             // not loopback, not allowed
            #expect(get(site, path, q, headers: ["Host": "evil.example", "X-Requested-With": WebSite.requestedWith]).status == 403)
            #expect(site.handle(HTTPRequest(method: "POST", path: path, query: q, headers: ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith], peer: "127.0.0.1")).status == 405)
        }
        var g = WebSite.Gate(); g.peers = ["172.16.5."]; g.key = "k"
        let keyed = WebSite(service: try WebService(root: t.root), gate: g, webRoot: t.dir, cacheRoot: t.dir)
        #expect(keyed.handle(HTTPRequest(method: "GET", path: "/api/posts", query: ["person": "\(pid)"], headers: ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith], peer: "172.16.5.208")).status == 403)
        #expect(keyed.handle(HTTPRequest(method: "GET", path: "/api/posts", query: ["person": "\(pid)"], headers: ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith, "X-Archive-Key": "k"], peer: "172.16.5.208")).status == 200)
        // a huge limit is clamped like every other list
        let r = get(site, "/api/posts/search", ["q": "m", "limit": "1000000"])
        let n = ((try JSONSerialization.jsonObject(with: r.body)) as? [[String: Any]])?.count ?? -1
        #expect(r.status == 200 && n >= 0 && n <= WebService.searchLimit)
        #expect(get(site, "/api/posts", ["person": "\(pid)", "limit": "-5"]).status == 200)
    }
}
