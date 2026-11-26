import Testing
import Foundation
@testable import ArchiveCore

// The web app's access gate fails closed, and attachments cannot script the app's origin.

private func req(_ path: String, host: String = "127.0.0.1:8452", headers: [String: String] = [:], peer: String = "127.0.0.1") -> HTTPRequest {
    var h = ["Host": host]
    for (k, v) in headers { h[k] = v }
    return HTTPRequest(method: "GET", path: path, query: [:], headers: h, peer: peer)
}

private let goodKey = String(repeating: "k", count: 30)   // long enough, plainly not a secret

@Suite struct WebGateStartupTests {
    private func gate(hosts: [String] = [], logins: [String] = [], peers: [String] = [], anyPeer: Bool = false, key: String? = nil) -> WebSite.Gate {
        var g = WebSite.Gate(); g.hosts = hosts; g.logins = logins; g.peers = peers; g.anyPeer = anyPeer; g.key = key
        return g
    }

    @Test func loopbackWithNothingIsFine() {
        #expect(WebSite.startupProblem(bind: "127.0.0.1", gate: gate()) == nil)
    }

    @Test func anyNonLoopbackBindNeedsAKeyWhateverTheHostFlags() {
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(anyPeer: true)) != nil)                       // no --allow-host: still refused
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(peers: ["10.1.2."])) != nil)
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(hosts: ["archive.example.org"], anyPeer: true)) != nil)
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(anyPeer: true, key: goodKey)) == nil)
    }

    @Test func aNonLoopbackBindStillNeedsAPeerRule() {
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(key: goodKey)) != nil)
    }

    @Test func shortOrPlaceholderKeysAreRefused() {
        #expect(WebSite.keyProblem("short") != nil)
        #expect(WebSite.keyProblem(WebSite.placeholderKey) != nil)
        #expect(WebSite.keyProblem("CHANGE-ME-please-to-something-long") != nil)
        #expect(WebSite.keyProblem(goodKey) == nil)
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(anyPeer: true, key: WebSite.placeholderKey)) != nil)
        #expect(WebSite.startupProblem(bind: "127.0.0.1", gate: gate(hosts: ["a.example.org"], key: "short")) != nil)
    }

    @Test func anEmptyKeyIsAMissingKey() {
        #expect(WebSite.key(fromEnvironmentValue: "") == nil)
        #expect(WebSite.key(fromEnvironmentValue: "   ") == nil)
        #expect(WebSite.key(fromEnvironmentValue: goodKey) == goodKey)
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(anyPeer: true, key: WebSite.key(fromEnvironmentValue: ""))) != nil)
    }

    @Test func loginAllowlistsOnlyOnALoopbackBind() {
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(logins: ["owner@example.com"], anyPeer: true)) != nil)
        #expect(WebSite.startupProblem(bind: "0.0.0.0", gate: gate(logins: ["owner@example.com"], anyPeer: true, key: goodKey)) != nil)
        #expect(WebSite.startupProblem(bind: "127.0.0.1", gate: gate(hosts: ["mac.example.net"], logins: ["owner@example.com"])) == nil)
    }

    @Test func aProxiedHostOnLoopbackStillNeedsACredential() {
        #expect(WebSite.startupProblem(bind: "127.0.0.1", gate: gate(hosts: ["archive.example.org"])) != nil)
        #expect(WebSite.startupProblem(bind: "127.0.0.1", gate: gate(hosts: ["archive.example.org"], key: goodKey)) == nil)
    }

    @Test func keysCompareInConstantTimeAndExactly() {
        #expect(WebSite.constantTimeEquals(goodKey, goodKey))
        #expect(!WebSite.constantTimeEquals(goodKey, goodKey + "x"))
        #expect(!WebSite.constantTimeEquals(goodKey, String(goodKey.dropLast()) + "Y"))
        #expect(!WebSite.constantTimeEquals("", goodKey))
    }
}

@Suite(.serialized) struct WebGateRequestTests {
    let dir: URL
    let service: WebService
    init() throws {
        dir = Fixtures.tempDir("webgate")
        let root = ArchiveRoot(url: dir.appendingPathComponent("archive"))
        try DemoSeed.seed(root: root, options: DemoSeed.Options(scale: 0.02))
        service = try WebService(root: root)
    }

    @Test func aNonLoopbackPeerWithoutAConfiguredKeyIsRefusedEvenAsLocalhost() {
        defer { try? FileManager.default.removeItem(at: dir) }
        var g = WebSite.Gate(); g.anyPeer = true
        let site = WebSite(service: service, gate: g)
        #expect(site.handle(req("/healthz", host: "localhost", peer: "172.17.0.1")).status == 403)
        #expect(site.handle(req("/healthz", host: "localhost:8452", peer: "10.1.2.3")).status == 403)
        #expect(site.handle(req("/healthz")).status == 200)                                       // loopback (the container healthcheck)
        g.key = goodKey
        let keyed = WebSite(service: service, gate: g)
        #expect(keyed.handle(req("/healthz", host: "localhost", peer: "172.17.0.1")).status == 403)
        #expect(keyed.handle(req("/healthz", host: "localhost", headers: ["X-Archive-Key": goodKey], peer: "172.17.0.1")).status == 200)
        #expect(keyed.handle(req("/healthz", host: "localhost", headers: ["X-Archive-Key": goodKey + "x"], peer: "172.17.0.1")).status == 403)
    }

    @Test func aLoginHeaderFromANonLoopbackPeerIsNoCredential() {
        defer { try? FileManager.default.removeItem(at: dir) }
        var g = WebSite.Gate(); g.anyPeer = true; g.hosts = ["mac.example.net"]; g.logins = ["owner@example.com"]
        let site = WebSite(service: service, gate: g)
        #expect(site.handle(req("/healthz", host: "mac.example.net", headers: ["Tailscale-User-Login": "owner@example.com"], peer: "10.1.2.3")).status == 403)
        #expect(site.handle(req("/healthz", host: "mac.example.net", headers: ["Tailscale-User-Login": "owner@example.com"])).status == 200)
    }
}

@Suite struct MediaTypeSafetyTests {
    @Test func onlyTypesThatCannotRunScriptAreServedInline() {
        for t in ["image/jpeg", "image/png", "image/gif", "image/heic", "video/mp4", "video/quicktime", "audio/mp4", "audio/mpeg", "text/plain; charset=utf-8"] {
            let s = WebSite.servedType(t)
            #expect(s.inline && s.type == t, "\(t)")
        }
        for t in ["text/html", "text/html; charset=utf-8", "image/svg+xml", "application/xhtml+xml", "text/xml", "application/xml",
                  "application/javascript", "text/javascript", "application/pdf", "text/vcard", "application/octet-stream", "image/SVG+XML"] {
            let s = WebSite.servedType(t)
            #expect(!s.inline && s.type == "application/octet-stream", "\(t)")
        }
    }

    @Test func htmlAndSvgAttachmentsDownloadSandboxedAndUnsniffed() throws {
        let dir = Fixtures.tempDir("webmedia"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir.appendingPathComponent("archive"))
        try DemoSeed.seed(root: root, options: DemoSeed.Options(scale: 0.02))
        let db = try Database(path: root.databaseURL.path)
        let sha = try #require(try db.scalarString("SELECT sha256 FROM attachment WHERE sha256 IS NOT NULL AND media_path IS NOT NULL ORDER BY id LIMIT 1"))
        let image = try #require(try db.scalarString("SELECT sha256 FROM attachment WHERE sha256 IS NOT NULL AND media_path IS NOT NULL AND sha256 <> '\(sha)' ORDER BY id LIMIT 1"))
        try db.exec("UPDATE attachment SET mime = 'text/html', filename = 'page.html' WHERE sha256 = '\(sha)'")
        try db.exec("UPDATE attachment SET mime = 'image/png' WHERE sha256 = '\(image)'")
        let site = WebSite(service: try WebService(root: root), cacheRoot: dir.appendingPathComponent("cache"))

        let html = site.handle(req("/media/\(sha)"))
        #expect(html.status == 200)
        #expect(html.headers["Content-Type"] == "application/octet-stream")
        #expect(html.headers["Content-Disposition"]?.hasPrefix("attachment") == true)
        #expect(html.headers["X-Content-Type-Options"] == "nosniff")
        #expect(html.headers["Content-Security-Policy"]?.contains("sandbox") == true)

        let png = site.handle(req("/media/\(image)"))
        #expect(png.status == 200 && png.headers["Content-Type"] == "image/png")
        #expect(png.headers["Content-Disposition"]?.hasPrefix("inline") == true)
        #expect(png.headers["X-Content-Type-Options"] == "nosniff" && png.headers["Content-Security-Policy"]?.contains("sandbox") == true)
    }
}
