import Testing
import Foundation
@testable import ArchiveCore

/// The Mac app's published builds through the web app: the manifest and a build's zip from app-releases/, nothing else.
@Suite(.serialized) struct AppReleaseRouteTests {
    @Test func servesTheManifestAndAZipByBuildNumberOnly() throws {
        let t = try RecordingFixtures.archive(); defer { t.cleanup() }
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let site = WebSite(service: try WebService(root: t.root))
        func get(_ path: String, _ headers: [String: String] = [:]) -> HTTPResponse {
            var h = ["Host": "127.0.0.1:8452", "X-Requested-With": WebSite.requestedWith]
            for (k, v) in headers { h[k] = v }
            return site.handle(HTTPRequest(method: "GET", path: path, query: [:], headers: h, peer: "127.0.0.1"))
        }
        #expect(get("/api/app/release").status == 404)                        // nothing published
        let dir = t.root.url.appendingPathComponent(WebSite.releasesDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"version": "1.0.7", "build": 20261124040000, "sha256": "ab", "size": 3}"#.write(to: dir.appendingPathComponent("latest.json"), atomically: true, encoding: .utf8)
        try Data("zip".utf8).write(to: dir.appendingPathComponent("\(Product.executable)-20261124040000.zip"))
        let m = get("/api/app/release")
        let manifest = try JSONSerialization.jsonObject(with: m.body) as? [String: Any]
        #expect(m.status == 200 && manifest?["build"] as? Int == 20261124040000)
        let z = get("/api/app/release/20261124040000/archive")
        #expect(z.status == 200 && z.headers["Content-Type"] == "application/zip" && z.file?.length == 3)
        #expect(get("/api/app/release/2026112404000/archive").status == 404)   // no such build
        #expect(get("/api/app/release/..%2Flatest/archive").status == 404)     // only digits
        #expect(get("/api/app/release/abc/archive").status == 404)
        #expect(get("/api/app/release", ["X-Requested-With": "x"]).status == 403)
        try "not json".write(to: dir.appendingPathComponent("latest.json"), atomically: true, encoding: .utf8)
        #expect(get("/api/app/release").status == 404)
    }
}
