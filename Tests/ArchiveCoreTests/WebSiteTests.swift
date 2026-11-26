import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ArchiveCore

// The read-only web app over a small demo archive (fake people, 555-01xx numbers, generated pictures): the gate, the JSON
// routes, paging continuity, search, media with Range, thumbnails, static files, and one streamed round trip over a socket.

private final class WebFixture {
    let dir: URL
    let root: ArchiveRoot
    let web: URL
    let cache: URL
    let service: WebService
    init() throws {
        dir = Fixtures.tempDir("web")
        root = ArchiveRoot(url: dir.appendingPathComponent("archive"))
        try DemoSeed.seed(root: root, options: DemoSeed.Options(scale: 0.02))
        web = dir.appendingPathComponent("web"); cache = dir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<!doctype html><title>t</title>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: web.appendingPathComponent("app.js"))
        service = try WebService(root: root)
    }
    func site(_ gate: WebSite.Gate = WebSite.Gate()) -> WebSite { WebSite(service: service, gate: gate, webRoot: web, cacheRoot: cache) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func get(_ path: String, query: [String: String] = [:], headers: [String: String] = [:], peer: String = "127.0.0.1", api: Bool = true) -> HTTPRequest {
    var h = ["Host": "127.0.0.1:8452"]
    if api { h["X-Requested-With"] = WebSite.requestedWith }
    for (k, v) in headers { h[k] = v }
    return HTTPRequest(method: "GET", path: path, query: query, headers: h, peer: peer)
}

private func json(_ r: HTTPResponse) -> Any? { try? JSONSerialization.jsonObject(with: r.body) }
private func dict(_ r: HTTPResponse) -> [String: Any] { (json(r) as? [String: Any]) ?? [:] }
private func list(_ r: HTTPResponse) -> [[String: Any]] { (json(r) as? [[String: Any]]) ?? [] }
private func messages(_ r: HTTPResponse) -> [[String: Any]] { (dict(r)["messages"] as? [[String: Any]]) ?? [] }

@Suite(.serialized) struct WebSiteTests {
    @Test func gateChecksPeerHostKeyLoginAndTheApiHeader() throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let open = f.site()
        #expect(open.handle(get("/healthz", api: false)).status == 200)
        #expect(open.handle(get("/api/overview")).status == 200)
        #expect(open.handle(get("/api/overview", api: false)).status == 403)                            // no X-Requested-With
        #expect(open.handle(get("/healthz", peer: "172.16.5.208", api: false)).status == 403)        // loopback only by default
        #expect(open.handle(get("/healthz", headers: ["Host": "evil.example"], api: false)).status == 403)
        #expect(open.handle(HTTPRequest(method: "POST", path: "/api/overview", headers: ["Host": "127.0.0.1", "X-Requested-With": WebSite.requestedWith])).status == 405)

        var g = WebSite.Gate(); g.hosts = ["archive.example.org"]; g.peers = ["172.16.5."]; g.key = "s3cret"
        let proxied = f.site(g)
        #expect(proxied.handle(get("/healthz", headers: ["Host": "archive.example.org"], peer: "172.16.5.208", api: false)).status == 403)   // no key
        #expect(proxied.handle(get("/healthz", headers: ["Host": "archive.example.org", "X-Archive-Key": "s3cret"], peer: "172.16.5.208", api: false)).status == 200)
        #expect(proxied.handle(get("/healthz", headers: ["Host": "archive.example.org", "X-Archive-Key": "s3cret"], peer: "10.0.0.9", api: false)).status == 403)   // peer outside the prefix
        #expect(proxied.handle(get("/healthz", headers: ["Host": "other.example.org", "X-Archive-Key": "s3cret"], peer: "172.16.5.208", api: false)).status == 403)
        #expect(proxied.handle(get("/healthz", api: false)).status == 200)                                 // loopback needs no key (docker healthcheck)

        var t = WebSite.Gate(); t.hosts = ["mac.example.net"]; t.logins = ["owner@example.com"]
        let tailscale = f.site(t)
        #expect(tailscale.handle(get("/healthz", headers: ["Host": "mac.example.net"], api: false)).status == 403)
        #expect(tailscale.handle(get("/healthz", headers: ["Host": "mac.example.net", "Tailscale-User-Login": "Owner@example.com"], api: false)).status == 200)
        #expect(tailscale.handle(get("/healthz", headers: ["Host": "mac.example.net", "Tailscale-User-Login": "other@example.com"], api: false)).status == 403)

        var a = WebSite.Gate(); a.anyPeer = true
        #expect(f.site(a).handle(get("/healthz", peer: "172.17.0.1", api: false)).status == 403)              // no key: loopback only
        let testKey = String(repeating: "k", count: 30)
        a.key = testKey
        #expect(f.site(a).handle(get("/healthz", headers: ["X-Archive-Key": testKey], peer: "172.17.0.1", api: false)).status == 200)
    }

    @Test func overviewPeopleAndPersonDetail() throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let site = f.site()
        let o = dict(site.handle(get("/api/overview")))
        #expect((o["messages"] as? Int ?? 0) > 1000 && o["demo"] as? Bool == true && (o["people"] as? Int ?? 0) > 10 && (o["groups"] as? Int ?? 0) >= 1)
        #expect(((o["months"] as? [[String: Any]]) ?? []).count > 50)
        let p = dict(site.handle(get("/api/people")))
        let people = p["people"] as? [[String: Any]] ?? []
        let groups = p["groups"] as? [[String: Any]] ?? []
        #expect(people.count > 10 && groups.count >= 1)
        let lastTs = people.compactMap { $0["lastTs"] as? Int }
        #expect(lastTs == lastTs.sorted(by: >))                                                   // most recent first
        let first = try #require(people.first)
        #expect((first["name"] as? String)?.isEmpty == false && (first["messages"] as? Int ?? 0) > 0 && !((first["services"] as? [String: Int]) ?? [:]).isEmpty)
        #expect(groups.allSatisfy { ($0["title"] as? String)?.isEmpty == false })
        let id = try #require(first["id"] as? Int)
        let d = dict(site.handle(get("/api/person/\(id)")))
        #expect(d["name"] as? String == first["name"] as? String)
        #expect(((d["handles"] as? [[String: Any]]) ?? []).count >= 1 && ((d["threads"] as? [[String: Any]]) ?? []).count >= 1)
        #expect(((d["months"] as? [[String: Any]]) ?? []).count >= 1)
        #expect(site.handle(get("/api/person/999999")).status == 404)
        let gid = try #require(groups.first?["id"] as? Int)
        let t = dict(site.handle(get("/api/thread/\(gid)")))
        #expect(t["isGroup"] as? Bool == true && ((t["members"] as? [String]) ?? []).count >= 2)
    }

    @Test func pagingIsContinuousAndAroundCentresTheMessage() throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let site = f.site()
        let people = dict(site.handle(get("/api/people")))["people"] as? [[String: Any]] ?? []
        let busiest = try #require(people.max { ($0["messages"] as? Int ?? 0) < ($1["messages"] as? Int ?? 0) })
        let pid = String(busiest["id"] as? Int ?? 0)
        let latest = messages(site.handle(get("/api/messages", query: ["person": pid, "limit": "20"])))
        #expect(latest.count == 20)
        let ts = latest.map { $0["ts"] as? Int ?? 0 }
        #expect(ts == ts.sorted())                                                                 // oldest first within a page
        let first = latest[0]
        let older = messages(site.handle(get("/api/messages", query: ["person": pid, "mode": "before", "ts": String(first["ts"] as? Int ?? 0), "id": String(first["id"] as? Int ?? 0), "limit": "20"])))
        #expect(older.count == 20)
        #expect((older.last?["ts"] as? Int ?? 0) <= (first["ts"] as? Int ?? 0))
        #expect(Set(older.map { $0["id"] as? Int ?? 0 }).isDisjoint(with: latest.map { $0["id"] as? Int ?? 0 }))
        let newer = messages(site.handle(get("/api/messages", query: ["person": pid, "mode": "after", "ts": String(older.last?["ts"] as? Int ?? 0), "id": String(older.last?["id"] as? Int ?? 0), "limit": "20"])))
        #expect(newer.map { $0["id"] as? Int ?? 0 } == latest.map { $0["id"] as? Int ?? 0 })      // after(the page before) == the page
        let mid = older[10]
        let around = dict(site.handle(get("/api/messages", query: ["person": pid, "mode": "around", "id": String(mid["id"] as? Int ?? 0), "side": "5"])))
        let rows = around["messages"] as? [[String: Any]] ?? []
        #expect(rows.count == 11 && around["at"] as? Int == 5 && (rows[5]["id"] as? Int) == (mid["id"] as? Int))
        let byDate = dict(site.handle(get("/api/messages", query: ["person": pid, "mode": "around", "ts": String(mid["ts"] as? Int ?? 0), "side": "3"])))
        #expect((byDate["messages"] as? [[String: Any]])?.count == 7)
        #expect(site.handle(get("/api/messages", query: ["person": pid, "mode": "before"])).status == 400)
        #expect(site.handle(get("/api/messages", query: ["mode": "latest"])).status == 400)
        #expect(site.handle(get("/api/messages", query: ["person": "999999"])).status == 404)
        // a service filter narrows the scope and is honoured by paging
        let services = (busiest["services"] as? [String: Int]) ?? [:]
        if let one = services.keys.sorted().first {
            let only = messages(site.handle(get("/api/messages", query: ["person": pid, "services": one, "limit": "50"])))
            #expect(!only.isEmpty && only.allSatisfy { $0["service"] as? String == one })
        }
        // rows carry what the page draws
        #expect(latest.allSatisfy { $0["service"] != nil && $0["me"] != nil && $0["attachments"] != nil && $0["reactions"] != nil })
    }

    @Test func searchFindsTextAndSaysWhere() throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let site = f.site()
        let hits = list(site.handle(get("/api/search", query: ["q": "pizza"])))
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { ($0["snippet"] as? String)?.contains("\u{1}") == true && ($0["where"] as? String)?.isEmpty == false })
        let pid = try #require(hits.compactMap { $0["person"] as? Int }.first)
        let scoped = list(site.handle(get("/api/search", query: ["q": "pizza", "person": String(pid), "order": "newest"])))
        #expect(!scoped.isEmpty && scoped.allSatisfy { $0["person"] as? Int == pid })
        let ts = scoped.map { $0["ts"] as? Int ?? 0 }
        #expect(ts == ts.sorted(by: >))
        #expect(site.handle(get("/api/search")).status == 400)
        #expect(list(site.handle(get("/api/search", query: ["q": "\"\""]))).isEmpty)
    }

    @Test func mediaIsServedByHashWithRangesAndThumbnailsAreCached() throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let site = f.site()
        let people = dict(site.handle(get("/api/people")))["people"] as? [[String: Any]] ?? []
        var sha: String?
        for p in people {
            let rows = messages(site.handle(get("/api/messages", query: ["person": String(p["id"] as? Int ?? 0), "limit": "200"])))
            if let a = rows.flatMap({ ($0["attachments"] as? [[String: Any]]) ?? [] }).first(where: { $0["kind"] as? String == "image" }) { sha = a["sha"] as? String; break }
        }
        let hash = try #require(sha)
        let full = site.handle(get("/media/\(hash)", api: false))
        #expect(full.status == 200 && full.headers["Accept-Ranges"] == "bytes" && full.headers["Content-Type"] == "image/png")
        let size = try #require(full.file?.length)
        #expect(size > 100 && full.headers["Cache-Control"]?.contains("immutable") == true)
        let part = site.handle(get("/media/\(hash)", headers: ["Range": "bytes=0-9"], api: false))
        #expect(part.status == 206 && part.file?.offset == 0 && part.file?.length == 10 && part.headers["Content-Range"] == "bytes 0-9/\(size)")
        let tail = site.handle(get("/media/\(hash)", headers: ["Range": "bytes=-5"], api: false))
        #expect(tail.status == 206 && tail.file?.offset == size - 5 && tail.file?.length == 5)
        let open = site.handle(get("/media/\(hash)", headers: ["Range": "bytes=100-"], api: false))
        #expect(open.status == 206 && open.file?.offset == 100 && open.file?.length == size - 100)
        let bad = site.handle(get("/media/\(hash)", headers: ["Range": "bytes=\(size + 10)-"], api: false))
        #expect(bad.status == 416 && bad.headers["Content-Range"] == "bytes */\(size)")
        #expect(site.handle(get("/media/\(hash)", headers: ["Range": "bytes=0-9,20-29"], api: false)).status == 200)   // multiple ranges: whole file
        #expect(site.handle(get("/media/" + String(repeating: "0", count: 64), api: false)).status == 404)
        #expect(site.handle(get("/media/../archive.sqlite", api: false)).status == 404)
        #expect(site.handle(get("/media/\(hash.uppercased())", api: false)).status == 400)
        #expect(site.handle(get("/media/x", api: false)).status == 400)
        #expect(throws: WebError.self) { try WebSite.range("bytes=5-3", size: 10) }

        let thumb = site.handle(get("/thumb/\(hash)/480", api: false))
        #expect(thumb.status == 200 && thumb.headers["Content-Type"] == "image/jpeg" && (thumb.file?.length ?? 0) > 100)
        let cached = f.cache.appendingPathComponent("thumbs/480/\(hash.prefix(2))/\(hash).jpg")
        #expect(FileManager.default.fileExists(atPath: cached.path))
        let data = try Data(contentsOf: cached)
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))                                              // JPEG magic
        #expect(site.handle(get("/thumb/\(hash)/480", api: false)).file?.length == Int64(data.count))   // served from the cache
        #expect(site.handle(get("/thumb/\(hash)/123", api: false)).status == 404)
        #expect(site.handle(get("/thumb/" + String(repeating: "0", count: 64) + "/480", api: false)).status == 404)
    }

    @Test func staticFilesComeOnlyFromTheWebFolder() throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let site = f.site()
        let index = site.handle(get("/", api: false))
        #expect(index.status == 200 && index.headers["Content-Type"]?.hasPrefix("text/html") == true && index.headers["Content-Security-Policy"]?.contains("default-src 'self'") == true)
        #expect(site.handle(get("/index.html", api: false)).status == 200)
        let js = site.handle(get("/app.js", api: false))
        #expect(js.status == 200 && js.headers["Content-Type"]?.hasPrefix("text/javascript") == true)
        let etag = try #require(js.headers["ETag"])
        #expect(js.headers["Cache-Control"] == "no-cache")
        let again = site.handle(get("/app.js", headers: ["If-None-Match": etag], api: false))
        #expect(again.status == 304 && again.body.isEmpty && again.headers["ETag"] == etag)
        #expect(site.handle(get("/app.js", headers: ["If-None-Match": "\"other\""], api: false)).status == 200)
        #expect(site.handle(get("/missing.css", api: false)).status == 404)
        #expect(site.handle(get("/../Package.swift", api: false)).status == 404)
        #expect(site.handle(get("/.hidden", api: false)).status == 404)
        #expect(site.handle(get("/app.js/extra", api: false)).status == 404)
        #expect(WebSite(service: f.service, gate: WebSite.Gate(), webRoot: nil, cacheRoot: nil).handle(get("/", api: false)).status == 404)
    }

    @Test func rangedMediaStreamsOverASocket() async throws {
        let f = try WebFixture(); defer { f.cleanup() }
        let site = f.site()
        let server = HTTPServer(host: "127.0.0.1", port: 0) { site.handle($0) }
        try server.start(); defer { server.stop() }
        let people = dict(site.handle(get("/api/people")))["people"] as? [[String: Any]] ?? []
        var found: (String, URL)?
        for p in people {
            let rows = messages(site.handle(get("/api/messages", query: ["person": String(p["id"] as? Int ?? 0), "limit": "200"])))
            if let a = rows.flatMap({ ($0["attachments"] as? [[String: Any]]) ?? [] }).first(where: { $0["kind"] as? String == "image" }),
               let sha = a["sha"] as? String, let m = try f.service.mediaFile(sha256: sha) { found = (sha, m.url); break }
        }
        let (sha, url) = try #require(found)
        let bytes = try Data(contentsOf: url)
        // No URL cache: the first answer is cacheable for a year, and a cached copy would stand in for the HEAD below.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/media/\(sha)")!)
        let (whole, resp) = try await session.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200 && whole == bytes)
        req.setValue("bytes=10-29", forHTTPHeaderField: "Range")
        let (part, presp) = try await session.data(for: req)
        #expect((presp as? HTTPURLResponse)?.statusCode == 206 && part == bytes[10..<30])
        var head = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/media/\(sha)")!)
        head.httpMethod = "HEAD"
        let (none, hresp) = try await session.data(for: head)
        #expect((hresp as? HTTPURLResponse)?.statusCode == 200)
        #expect(none.isEmpty)
        #expect((hresp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == String(bytes.count))
    }
}

/// The container mounts the archive read-only: an unwritable root opens `immutable` after `prepare-move`, and is refused before it.
@Suite(.serialized) struct ReadOnlyRootTests {
    @Test func unwritableRootOpensImmutableOnlyWhenPrepared() throws {
        let dir = Fixtures.tempDir("ro"); defer { chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir)
        try DemoSeed.seed(root: root, options: DemoSeed.Options(scale: 0.01))          // leaves a WAL-mode archive, side files included
        #expect(!root.isReadOnlyLocation && !root.opensImmutable)
        let before = try ArchiveReader(root: root).overview().messages
        // verify opens read-write but must leave a prepared copy's journal mode alone
        _ = try Relocation.prepareForMove(root: root)
        _ = try Schema.openArchive(root: root, preserveJournalMode: true)
        #expect(try Database(path: root.databaseURL.path, readOnly: true).scalarString("PRAGMA journal_mode") == "delete")
        _ = try Schema.openArchive(root: root)                                          // an ordinary read-write open puts WAL back
        #expect(try Database(path: root.databaseURL.path, readOnly: true).scalarString("PRAGMA journal_mode") == "wal")
        guard getuid() != 0 else { return }                                             // root ignores directory modes (the Linux test container)
        chmod(dir.path, 0o555)
        #expect(root.isReadOnlyLocation && root.opensImmutable)
        #expect(throws: ArchiveError.self) { try ArchiveReader(root: root) }            // WAL state + immutable would read stale: refused
        chmod(dir.path, 0o755)
        _ = try Relocation.prepareForMove(root: root)
        chmod(dir.path, 0o555)
        let reader = try ArchiveReader(root: root)
        #expect(try reader.overview().messages == before)
        #expect(try WebService(root: root).people().people.count > 0)                   // people.sqlite (absent here) and the archive, both read-only
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive.sqlite-wal").path))
    }
}
