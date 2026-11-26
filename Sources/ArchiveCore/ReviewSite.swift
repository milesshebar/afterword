import Foundation

/// The HTTP face of the review service: routing, the CSRF and host checks, JSON in and out. Pure request -> response, so it
/// is tested without a socket. Everything it serves uses relative URLs, so it works behind a reverse proxy (`tailscale serve`).
public final class ReviewSite: @unchecked Sendable {
    /// The value every /api request must carry in `X-Requested-With` (a custom header forces a CORS preflight, which this
    /// server never grants, so another web page cannot drive it from the browser).
    public static let requestedWith = "archive-review"

    private let service: ReviewService
    private let extraHosts: Set<String>
    private let allowedLogins: Set<String>

    /// `extraHosts` are exact machine names the site may be reached by (the `tailscale serve` name); there is no wildcard.
    /// `allowedLogins` are the Tailscale logins (the `Tailscale-User-Login` header `tailscale serve` adds) that may use it. With
    /// any login configured, every request that came through a proxy must carry one of them; only a direct local request (no
    /// forwarding headers, loopback Host) is exempt.
    public init(service: ReviewService, extraHosts: [String] = [], allowedLogins: [String] = []) {
        self.service = service
        self.extraHosts = Set(extraHosts.map { Self.hostName($0) })
        self.allowedLogins = Set(allowedLogins.map { $0.lowercased() })
    }

    private static let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

    // MARK: checks

    public static func isLoopback(_ peer: String) -> Bool {
        peer == "::1" || peer.hasPrefix("127.") || peer == "localhost"
    }

    /// Host without its port ("[::1]:8097" -> "[::1]").
    static func hostName(_ hostPort: String) -> String {
        let h = hostPort.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") { return String(h[...close]) }
        return h.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? h
    }

    func hostAllowed(_ hostPort: String) -> Bool {
        let h = Self.hostName(hostPort)
        return Self.loopbackNames.contains(h) || extraHosts.contains(h)
    }

    /// nil when the request may proceed, else the refusal.
    func screen(_ req: HTTPRequest) -> HTTPResponse? {
        // A reverse proxy on this machine connects from loopback; anything else is refused outright.
        guard Self.isLoopback(req.peer) else { return .error(403, "loopback peers only") }
        guard let host = req.header("host") else { return .error(400, "no Host header") }
        guard hostAllowed(host), req.header("x-forwarded-host").map(hostAllowed) ?? true else { return .error(403, "host not allowed") }
        if !allowedLogins.isEmpty {
            let proxied = req.header("tailscale-user-login") != nil || req.header("x-forwarded-for") != nil || req.header("x-forwarded-host") != nil
                || req.header("x-forwarded-proto") != nil || !Self.loopbackNames.contains(Self.hostName(host))
            if proxied {
                guard let login = req.header("tailscale-user-login")?.lowercased(), allowedLogins.contains(login) else { return .error(403, "not an allowed user") }
            }
        }
        if req.path.hasPrefix("/api/") || req.method == "POST" {
            guard req.header("x-requested-with") == Self.requestedWith else { return .error(403, "missing X-Requested-With") }
        }
        // A POST that names its origin must come from this site: an origin that is loopback, a tailnet name or a configured
        // host. (Behind `tailscale serve` the Host header may be rewritten to the loopback address, so the origin is checked
        // against the allowed names rather than only against Host.)
        if req.method == "POST", let origin = req.header("origin"), origin != "null" {
            guard let host = URL(string: origin)?.host, hostAllowed(host) else { return .error(403, "cross-origin request refused") }
        }
        return nil
    }

    // MARK: handling

    private func queue(_ req: HTTPRequest, _ body: [String: Any]? = nil) -> SuggestionQueue {
        SuggestionQueue(rawValue: (body?["queue"] as? String) ?? req.query["queue"] ?? "cross") ?? .crossService
    }

    private func encode<T: Encodable>(_ v: T) -> HTTPResponse {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(v) else { return .error(500, "encode failed") }
        return .json(d)
    }

    private func jsonBody(_ req: HTTPRequest) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
    }

    private func int(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        if let refusal = screen(req) { return refusal }
        guard ["GET", "HEAD", "POST"].contains(req.method) else { return .error(405, "method not allowed") }
        do {
            switch (req.method == "HEAD" ? "GET" : req.method, req.path) {
            case ("GET", "/"), ("GET", "/index.html"):
                return .html(ReviewPage.html)
            case ("GET", "/favicon.ico"):
                return HTTPResponse(status: 204)
            case ("GET", "/healthz"):
                return .text("ok\n")
            case ("GET", "/api/state"):
                return encode(service.state(queue: queue(req)))
            case ("GET", "/api/search"):
                return encode(service.search(req.query["q"] ?? "", exclude: req.query["exclude"].flatMap { Int64($0) }))
            case ("GET", "/api/peek"):
                guard let p = req.query["person"].flatMap({ Int64($0) }) else { throw ReviewError(400, "person required") }
                let mode = req.query["mode"].map { ArchiveReader.SampleMode(rawValue: $0) } ?? .latest
                guard let mode else { throw ReviewError(400, "mode must be latest, earliest or spread") }
                return encode(try service.peek(person: p, mode: mode))
            case ("POST", "/api/merge"):
                guard let b = jsonBody(req), let s = int(b["source"]), let t = int(b["target"]) else { throw ReviewError(400, "source and target required") }
                try service.merge(source: s, target: t)
                return encode(service.state(queue: queue(req, b)))
            case ("POST", "/api/reject"):
                guard let b = jsonBody(req), let s = int(b["source"]), let ts = (b["targets"] as? [Any])?.compactMap(int), !ts.isEmpty else { throw ReviewError(400, "source and targets required") }
                try service.reject(source: s, targets: ts)
                return encode(service.state(queue: queue(req, b)))
            case ("POST", "/api/nomatch"):
                guard let b = jsonBody(req), let s = int(b["source"]) else { throw ReviewError(400, "source required") }
                try service.noMatch(source: s)
                return encode(service.state(queue: queue(req, b)))
            case ("POST", "/api/skip"):
                guard let b = jsonBody(req), let s = int(b["source"]) else { throw ReviewError(400, "source required") }
                service.skip(source: s)
                return encode(service.state(queue: queue(req, b)))
            case ("POST", "/api/rename"):
                guard let b = jsonBody(req), let p = int(b["person"]), let name = b["name"] as? String else { throw ReviewError(400, "person and name required") }
                try service.rename(person: p, to: name)
                return encode(service.state(queue: queue(req, b)))
            case ("POST", "/api/undo"):
                let b = jsonBody(req)
                try service.undo(id: b.flatMap { int($0["id"]) })
                return encode(service.state(queue: queue(req, b)))
            case ("POST", "/api/refresh"):
                try service.refresh()
                return encode(service.state(queue: queue(req, jsonBody(req))))
            default:
                return .error(404, "not found")
            }
        } catch let e as ReviewError {
            return .error(e.status, e.description)
        } catch {
            // Details (SQL text, file paths) stay in the local log, never in the response.
            FileHandle.standardError.write(Data("review: \(req.method) \(req.path) failed: \(error)\n".utf8))
            return .error(500, "internal error")
        }
    }
}
