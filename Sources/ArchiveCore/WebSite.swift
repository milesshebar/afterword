import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// The HTTP face of the read-only web app: the gate every request passes, JSON routes over `WebService`, the static page,
/// content-addressed media with HTTP Range, and cached thumbnails. Pure request -> response (tested without a socket).
///
/// Deployment shape: the server runs next to the archive (for example in a container on a NAS); a reverse proxy
/// terminates TLS for the public name and adds the shared key header. On a Mac it can also sit behind `tailscale serve` with
/// the login allowlist, like the review site.
public final class WebSite: @unchecked Sendable {
    public static let requestedWith = "archive-web"
    public static let keyHeader = "x-archive-key"
    public static let thumbSizes: Set<Int> = [480, 1600]

    public struct Gate: Sendable {
        /// Exact host names the site may be reached by (besides loopback names).
        public var hosts: [String] = []
        /// Tailscale logins allowed when a request comes through a proxy (`Tailscale-User-Login`).
        public var logins: [String] = []
        /// Peer addresses (exact, or a prefix ending in ".") allowed besides loopback; empty = loopback only unless `anyPeer`.
        public var peers: [String] = []
        /// With the server bound to every interface in a container, the port mapping is the boundary: accept any peer.
        public var anyPeer = false
        /// A shared secret the reverse proxy adds as `X-Archive-Key`; required from every non-loopback peer when set.
        public var key: String?
        public init() {}
    }

    private let service: WebService
    private let gate: Gate
    private let hosts: Set<String>
    private let logins: Set<String>
    private let webRoot: URL?
    private let cacheRoot: URL?
    private let thumbSlots = DispatchSemaphore(value: 2)

    public init(service: WebService, gate: Gate = Gate(), webRoot: URL? = nil, cacheRoot: URL? = nil) {
        self.service = service; self.gate = gate
        hosts = Set(gate.hosts.map { ReviewSite.hostName($0) })
        logins = Set(gate.logins.map { $0.lowercased() })
        self.webRoot = webRoot; self.cacheRoot = cacheRoot
    }

    private static let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

    // MARK: startup checks

    /// The example key in secrets/app.env.example: never accepted.
    public static let placeholderKey = "change-me-to-a-long-random-string"
    public static let minimumKeyLength = 24

    /// The key from its environment variable: empty or blank means no key.
    public static func key(fromEnvironmentValue v: String?) -> String? {
        guard let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return v
    }

    /// Why a key is not good enough, or nil.
    public static func keyProblem(_ k: String) -> String? {
        if k.count < minimumKeyLength { return "the key must be at least \(minimumKeyLength) characters" }
        if k == placeholderKey || k.lowercased().contains("change-me") { return "the key is still the example placeholder" }
        return nil
    }

    /// The gate `serve-web` refuses to start with, as the reason, or nil. Any bind other than loopback needs a real key whatever the
    /// host flags (the key, not the Host header, is what keeps other machines out), plus an explicit peer rule. A Tailscale login
    /// allowlist is honored only on a loopback bind (behind `tailscale serve`): anywhere else the login header is whatever the
    /// client sends. On loopback, a proxied host name needs a key or a login allowlist.
    public static func startupProblem(bind: String, gate: Gate, keyEnv: String = "ARCHIVE_WEB_KEY") -> String? {
        if let k = gate.key, let why = keyProblem(k) { return "$\(keyEnv): \(why)" }
        if !loopbackNames.contains(bind) {
            if !gate.logins.isEmpty { return "--allow-login works only with --bind 127.0.0.1 behind tailscale serve: on \(bind) any client can send the login header" }
            if gate.key == nil { return "--bind \(bind) needs a shared key in $\(keyEnv) (at least \(minimumKeyLength) characters), whatever the host flags" }
            if !gate.anyPeer && gate.peers.isEmpty { return "--bind \(bind) needs --allow-peer <ip or prefix.> or --any-peer" }
        } else if !gate.hosts.isEmpty && gate.logins.isEmpty && gate.key == nil {
            return "--allow-host without --allow-login or a key in $\(keyEnv): behind a proxy everyone who can reach it would be let in"
        }
        return nil
    }

    /// Equal strings, compared without stopping at the first difference.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }

    func hostAllowed(_ hostPort: String) -> Bool {
        let h = ReviewSite.hostName(hostPort)
        return Self.loopbackNames.contains(h) || hosts.contains(h)
    }

    func peerAllowed(_ peer: String) -> Bool {
        if ReviewSite.isLoopback(peer) || gate.anyPeer { return true }
        return gate.peers.contains { $0.hasSuffix(".") ? peer.hasPrefix($0) : peer == $0 }
    }

    /// nil when the request may proceed, else the refusal.
    func screen(_ req: HTTPRequest) -> HTTPResponse? {
        guard peerAllowed(req.peer) else { return .error(403, "peer not allowed") }
        guard let host = req.header("host") else { return .error(400, "no Host header") }
        guard hostAllowed(host), req.header("x-forwarded-host").map(hostAllowed) ?? true else { return .error(403, "host not allowed") }
        // Every peer other than loopback must send the key; with no key configured, only loopback is served (the Host header,
        // localhost included, is the client's to choose and proves nothing).
        if !ReviewSite.isLoopback(req.peer) {
            guard let key = gate.key else { return .error(403, "no key configured: only loopback peers are served") }
            guard let sent = req.header(Self.keyHeader), Self.constantTimeEquals(sent, key) else { return .error(403, "missing key") }
        }
        if !logins.isEmpty {
            let proxied = req.header("tailscale-user-login") != nil || req.header("x-forwarded-for") != nil || req.header("x-forwarded-host") != nil
                || req.header("x-forwarded-proto") != nil || !Self.loopbackNames.contains(ReviewSite.hostName(host))
            if proxied {
                guard let login = req.header("tailscale-user-login")?.lowercased(), logins.contains(login) else { return .error(403, "not an allowed user") }
            }
        }
        if req.path.hasPrefix("/api/") {
            guard req.header("x-requested-with") == Self.requestedWith else { return .error(403, "missing X-Requested-With") }
        }
        return nil
    }

    // MARK: routing

    private func encode<T: Encodable>(_ v: T, cache: String = "no-store") -> HTTPResponse {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(v) else { return .error(500, "encode failed") }
        var r = HTTPResponse.json(d)
        r.headers["Cache-Control"] = cache
        return r
    }

    private func int64(_ s: String?) -> Int64? { s.flatMap { Int64($0) } }

    private func limit(_ s: String?, default d: Int, max m: Int) -> Int { min(m, max(1, s.flatMap { Int($0) } ?? d)) }

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        if let refusal = screen(req) { return refusal }
        guard ["GET", "HEAD"].contains(req.method) else { return .error(405, "method not allowed") }
        do {
            let parts = req.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            switch (parts.first ?? "", parts.count) {
            case ("", 0):
                return try staticFile("index.html", ifNoneMatch: req.header("if-none-match"))
            case ("healthz", 1):
                return .text("ok\n")
            case ("favicon.ico", 1):
                return HTTPResponse(status: 204)
            case ("api", _):
                return try api(req, parts.dropFirst().map { $0 })
            case ("media", 2):
                return try media(req, sha: parts[1])
            case ("thumb", 3):
                guard let size = Int(parts[2]), Self.thumbSizes.contains(size) else { throw WebError(404, "no such size") }
                return try thumbnail(req, sha: parts[1], size: size)
            default:
                if parts.count == 1 { return try staticFile(parts[0], ifNoneMatch: req.header("if-none-match")) }
                throw WebError(404, "not found")
            }
        } catch let e as WebError {
            return .error(e.status, e.description)
        } catch {
            return .error(500, "\(error)")
        }
    }

    private func api(_ req: HTTPRequest, _ parts: [String]) throws -> HTTPResponse {
        let q = req.query
        switch (parts.first ?? "", parts.count) {
        case ("overview", 1):
            return encode(try service.overview(), cache: "private, max-age=60")
        case ("people", 1):
            return encode(try service.people(), cache: "private, max-age=30")
        case ("person", 2):
            guard let id = int64(parts[1]) else { throw WebError(400, "bad id") }
            return encode(try service.person(id), cache: "private, max-age=60")
        case ("thread", 2):
            guard let id = int64(parts[1]) else { throw WebError(400, "bad id") }
            return encode(try service.thread(id), cache: "private, max-age=60")
        case ("months", 1):
            let scope = try service.scope(person: int64(q["person"]), thread: int64(q["thread"]), services: WebService.services(q["services"]))
            return encode(try service.months(scope: scope), cache: "private, max-age=60")
        case ("messages", 1):
            let scope = try service.scope(person: int64(q["person"]), thread: int64(q["thread"]), services: WebService.services(q["services"]))
            let n = limit(q["limit"], default: 60, max: WebService.pageLimit)
            // the viewer's IANA zone: the page then carries the calendar events of its days (a page without it gets none)
            let zone = q["zone"].flatMap { TimeZone(identifier: $0) }
            switch q["mode"] ?? "latest" {
            case "latest":
                return encode(try service.latest(scope: scope, limit: n, zone: zone))
            case "before", "after":
                guard let ts = int64(q["ts"]), let id = int64(q["id"]) else { throw WebError(400, "ts and id required") }
                let key = MessageKey(tsMs: ts, id: id)
                return encode(q["mode"] == "before" ? try service.before(scope: scope, key: key, limit: n, zone: zone)
                                                    : try service.after(scope: scope, key: key, limit: n, zone: zone))
            case "around":
                let side = limit(q["side"], default: 30, max: WebService.pageLimit / 2)
                return encode(try service.around(scope: scope, message: int64(q["id"]), atOrAfter: int64(q["ts"]), side: side, zone: zone))
            default:
                throw WebError(400, "mode must be latest, before, after or around")
            }
        case ("posts", 1):
            guard let person = int64(q["person"]) else { throw WebError(400, "person required") }
            let n = limit(q["limit"], default: 100, max: WebService.pageLimit)
            var before: (ts: Int64, id: String)?
            if let ts = int64(q["ts"]), let id = q["id"], !id.isEmpty { before = (ts, id) }
            // the viewer's IANA zone ("zone"), so each row's own date decides its day; a fixed offset ("tz", minutes) from older pages
            let zone = q["zone"].flatMap { TimeZone(identifier: $0) }
                ?? q["tz"].flatMap { Int($0) }.flatMap { TimeZone(secondsFromGMT: max(-900, min(900, $0)) * 60) } ?? TimeZone(secondsFromGMT: 0)!
            return encode(try service.posts(person: person, before: before, limit: n, zone: zone))
        case ("posts", 2) where parts[1] == "search":
            guard let text = q["q"], !text.isEmpty else { throw WebError(400, "q required") }
            let n = limit(q["limit"], default: 50, max: WebService.searchLimit)
            let offset = max(0, q["offset"].flatMap { Int($0) } ?? 0)
            let order: PostsOrder = q["order"] == "newest" ? .newest : q["order"] == "oldest" ? .oldest : .best
            return encode(try service.searchPosts(text, person: int64(q["person"]), order: order, limit: n, offset: offset))
        case ("recordings", 1):
            let n = limit(q["limit"], default: 50, max: WebService.pageLimit)
            var before: (ts: Int64, id: Int64)?
            if let ts = int64(q["ts"]), let id = int64(q["id"]) { before = (ts, id) }
            return encode(try service.recordings(kind: try WebService.recordingKind(q["kind"]), before: before, limit: n))
        case ("recordings", 2) where parts[1] == "search":
            guard let text = q["q"], !text.isEmpty else { throw WebError(400, "q required") }
            let n = limit(q["limit"], default: 50, max: WebService.searchLimit)
            let offset = max(0, q["offset"].flatMap { Int($0) } ?? 0)
            let order: SearchOrder = q["order"] == "newest" ? .newest : q["order"] == "oldest" ? .oldest : .bestMatch
            return encode(try service.searchRecordings(text, kind: try WebService.recordingKind(q["kind"]), order: order, limit: n, offset: offset))
        case ("recording", 2):
            guard let id = int64(parts[1]) else { throw WebError(400, "bad id") }
            return encode(try service.recording(id), cache: "private, max-age=60")
        // The Mac app's published builds (scripts/release-app.sh), for its updater: the latest manifest and a build's zip, from the
        // archive folder's app-releases/ (beside archive.sqlite; a container sees it read-only). Behind the same gate as
        // everything else: allowed peers, the key the proxy adds, X-Requested-With.
        case ("app", 2) where parts[1] == "release":
            let url = service.root.url.appendingPathComponent(Self.releasesDir).appendingPathComponent("latest.json")
            guard let data = FileManager.default.contents(atPath: url.path), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw WebError(404, "no release published")
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
        case ("app", 4) where parts[1] == "release" && parts[3] == "archive":
            guard !parts[2].isEmpty, parts[2].count <= 20, parts[2].allSatisfy({ $0.isASCII && $0.isNumber }) else { throw WebError(404, "no such build") }
            let url = service.root.url.appendingPathComponent(Self.releasesDir).appendingPathComponent("\(Product.executable)-\(parts[2]).zip")
            return try fileResponse(req, url: url, type: "application/zip", cache: "no-store")
        case ("voice", 2):
            return encode(try service.voiceMessage(sha256: parts[1]), cache: "private, max-age=60")
        case ("search", 1):
            guard let text = q["q"], !text.isEmpty else { throw WebError(400, "q required") }
            var scope: MessageScope?
            if q["person"] != nil || q["thread"] != nil {
                scope = try service.scope(person: int64(q["person"]), thread: int64(q["thread"]), services: WebService.services(q["services"]))
            }
            let order: SearchOrder = q["order"] == "newest" ? .newest : q["order"] == "oldest" ? .oldest : .bestMatch
            let n = limit(q["limit"], default: 50, max: WebService.searchLimit)
            let offset = max(0, q["offset"].flatMap { Int($0) } ?? 0)
            return encode(try service.search(text, scope: scope, order: order, limit: n, offset: offset))
        default:
            throw WebError(404, "not found")
        }
    }

    /// Where the Mac app's published builds live, inside the archive folder.
    public static let releasesDir = "app-releases"

    // MARK: static files

    static let staticTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "webmanifest": "application/manifest+json", "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon", "txt": "text/plain; charset=utf-8",
    ]

    /// One file straight out of the web folder: a plain name with a known extension, nothing else.
    func staticFile(_ name: String, ifNoneMatch: String? = nil) throws -> HTTPResponse {
        guard let webRoot else { throw WebError(404, "no web folder") }
        guard !name.isEmpty, name.count < 64, !name.hasPrefix("."), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              let ext = name.split(separator: ".").last.map(String.init), let type = Self.staticTypes[ext] else { throw WebError(404, "not found") }
        let url = webRoot.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let data = FileManager.default.contents(atPath: url.path) else { throw WebError(404, "not found") }
        // Revalidated on every load (no-cache + ETag), so a deploy shows up on the next open and the 304 costs nothing.
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let etag = "\"\(data.count)-\(mtime)\""
        var headers = ["Content-Type": type, "Cache-Control": "no-cache", "ETag": etag]
        if ext == "html" {
            headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' blob: data:; media-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        }
        if let ifNoneMatch, ifNoneMatch.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(etag) {
            return HTTPResponse(status: 304, headers: headers)
        }
        return HTTPResponse(status: 200, headers: headers, body: data)
    }

    // MARK: media

    /// Parses one `bytes=` range against a file size: (offset, length), nil when there is no usable header, or throws 416.
    static func range(_ header: String?, size: Int64) throws -> (Int64, Int64)? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.hasPrefix("bytes=") else { return nil }
        let spec = h.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }   // multiple ranges: ignore, send everything
        let a = spec[..<dash], b = spec[spec.index(after: dash)...]
        guard size > 0 else { throw WebError(416, "range not satisfiable") }
        if a.isEmpty {
            guard let n = Int64(b), n > 0 else { throw WebError(416, "range not satisfiable") }
            let len = min(n, size)
            return (size - len, len)
        }
        guard let start = Int64(a), start >= 0 else { throw WebError(416, "range not satisfiable") }
        guard start < size else { throw WebError(416, "range not satisfiable") }
        let end = b.isEmpty ? size - 1 : min(size - 1, Int64(b) ?? (size - 1))
        guard end >= start else { throw WebError(416, "range not satisfiable") }
        return (start, end - start + 1)
    }

    /// Types a browser may render inline from the app's origin: none of them can run script. Everything else is sent as a download.
    static let inlineTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/heic", "image/heif", "image/webp", "video/mp4",
                                           "video/quicktime", "video/3gpp", "audio/mp4", "audio/mpeg", "audio/amr", "audio/aac", "audio/x-m4a",
                                           "audio/wav", "audio/x-wav", "text/plain"]
    /// On every attachment and thumbnail: never sniffed, and a sandbox with no script if one is opened on its own.
    static let mediaSecurityHeaders = ["X-Content-Type-Options": "nosniff",
                                       "Content-Security-Policy": "sandbox; default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'"]

    /// The type an attachment goes out as, and whether it may be shown inline: HTML, SVG, XML, scripts, PDF and anything unknown
    /// become `application/octet-stream` downloads, so a file someone sent can never run as the archive's origin.
    static func servedType(_ type: String) -> (type: String, inline: Bool) {
        let base = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return inlineTypes.contains(base) ? (type, true) : ("application/octet-stream", false)
    }

    private func fileResponse(_ req: HTTPRequest, url: URL, type: String, cache: String, download: String? = nil, untrusted: Bool = false) throws -> HTTPResponse {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = (attrs[.size] as? NSNumber)?.int64Value else { throw WebError(404, "not found") }
        let (sentType, inline) = untrusted ? Self.servedType(type) : (type, true)
        var headers = ["Content-Type": sentType, "Accept-Ranges": "bytes", "Cache-Control": cache]
        if untrusted { headers.merge(Self.mediaSecurityHeaders) { _, b in b } }
        let name = download.map { "; filename=\"\($0.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })\"" } ?? ""
        if download != nil || !inline { headers["Content-Disposition"] = (inline ? "inline" : "attachment") + name }
        do {
            if let (off, len) = try Self.range(req.header("range"), size: size) {
                headers["Content-Range"] = "bytes \(off)-\(off + len - 1)/\(size)"
                return HTTPResponse(status: 206, headers: headers, file: FileRange(url: url, offset: off, length: len))
            }
        } catch let e as WebError where e.status == 416 {
            return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"])
        }
        return HTTPResponse(status: 200, headers: headers, file: FileRange(url: url, offset: 0, length: size))
    }

    static func mediaType(_ a: AttachmentInfo) -> String {
        if let m = a.mime?.lowercased(), m.allSatisfy({ $0.isLetter || $0.isNumber || "/.-+".contains($0) }), m.contains("/") { return m }
        switch (a.mediaPath as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"; case "png": return "image/png"; case "gif": return "image/gif"; case "heic": return "image/heic"
        case "mp4": return "video/mp4"; case "mov": return "video/quicktime"; case "3gp": return "video/3gpp"; case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"; case "amr": return "audio/amr"; case "pdf": return "application/pdf"; case "vcf": return "text/vcard"
        case "txt": return "text/plain; charset=utf-8"   // a meeting's saved Zoom chat
        default: return "application/octet-stream"
        }
    }

    private func media(_ req: HTTPRequest, sha: String) throws -> HTTPResponse {
        guard let (url, info) = try service.mediaFile(sha256: sha) else { throw WebError(404, "no such media") }
        // Content-addressed, so it can be cached forever by the one browser allowed to see it.
        return try fileResponse(req, url: url, type: Self.mediaType(info), cache: "private, max-age=31536000, immutable", download: info.filename, untrusted: true)
    }

    // MARK: thumbnails

    private func thumbnail(_ req: HTTPRequest, sha: String, size: Int) throws -> HTTPResponse {
        guard let cacheRoot else { throw WebError(404, "no thumbnail cache") }
        guard let (src, info) = try service.mediaFile(sha256: sha) else { throw WebError(404, "no such media") }
        guard info.isImage else { throw WebError(404, "not an image") }
        let out = cacheRoot.appendingPathComponent("thumbs/\(size)/\(sha.prefix(2))/\(sha).jpg")
        if !FileManager.default.fileExists(atPath: out.path) {
            thumbSlots.wait(); defer { thumbSlots.signal() }
            if !FileManager.default.fileExists(atPath: out.path) {
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = out.deletingLastPathComponent().appendingPathComponent(".tmp-\(getpid())-\(sha.prefix(8))-\(Int.random(in: 0..<1_000_000)).jpg")
                try Thumbnailer.make(source: src, maxPixel: size, output: tmp)
                guard (try? FileManager.default.moveItem(at: tmp, to: out)) != nil || FileManager.default.fileExists(atPath: out.path) else { throw WebError(500, "thumbnail write failed") }
            }
        }
        return try fileResponse(req, url: out, type: "image/jpeg", cache: "private, max-age=31536000, immutable", untrusted: true)
    }
}

/// Downscaled JPEG renditions: ImageIO on macOS, `vipsthumbnail` (libvips, with libheif for HEIC) on Linux.
public enum Thumbnailer {
    public static func make(source: URL, maxPixel: Int, output: URL) throws {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw WebError(415, "cannot decode image") }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCache: false]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw WebError(415, "cannot decode image") }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else { throw WebError(500, "cannot write thumbnail") }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WebError(500, "cannot write thumbnail") }
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/vipsthumbnail")
        p.arguments = [source.path, "--size", "\(maxPixel)x\(maxPixel)", "-o", output.path + "[Q=82,strip]"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else { throw WebError(415, "cannot decode image") }
        #endif
    }
}
