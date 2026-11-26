import Foundation
#if canImport(Darwin)
import Darwin
private let sockStream = SOCK_STREAM
private let shutReadWrite = SHUT_RDWR, shutWrite = SHUT_WR
#else
import Glibc
private let sockStream = Int32(SOCK_STREAM.rawValue)
private let shutReadWrite = Int32(SHUT_RDWR), shutWrite = Int32(SHUT_WR)
#endif

/// A minimal HTTP/1.1 server on BSD sockets (no dependencies): one request per connection (`Connection: close`), small bodies,
/// bound to a loopback address. Enough for the review site behind `tailscale serve`; not a general web server.

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lower-cased names.
    public var headers: [String: String]
    public var body: Data
    /// Dotted address of the connecting socket ("127.0.0.1" for a local proxy such as `tailscale serve`).
    public var peer: String

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(), peer: String = "127.0.0.1") {
        self.method = method; self.path = path; self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body; self.peer = peer
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// A body served straight from a file at send time (media, which can be hundreds of MB): `length` bytes from `offset`.
public struct FileRange: Sendable {
    public var url: URL
    public var offset: Int64
    public var length: Int64
    public init(url: URL, offset: Int64, length: Int64) { self.url = url; self.offset = offset; self.length = length }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// When set, the body is streamed from this file and `body` is ignored.
    public var file: FileRange?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), file: FileRange? = nil) {
        self.status = status; self.headers = headers; self.body = body; self.file = file
    }

    public static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(s.utf8))
    }
    public static func html(_ s: String) -> HTTPResponse { text(s, type: "text/html; charset=utf-8") }
    public static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }
    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let obj = try? JSONSerialization.data(withJSONObject: ["error": message])
        return .json(obj ?? Data("{\"error\":\"error\"}".utf8), status: status)
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 204: return "No Content"; case 400: return "Bad Request"; case 403: return "Forbidden"
        case 206: return "Partial Content"; case 304: return "Not Modified"; case 404: return "Not Found"; case 416: return "Range Not Satisfiable"; case 408: return "Request Timeout"; case 405: return "Method Not Allowed"; case 409: return "Conflict"; case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"; case 500: return "Internal Server Error"; case 503: return "Service Unavailable"; default: return "Status"
        }
    }

    func serialized(head: Bool) -> Data {
        var h = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(file?.length ?? Int64(body.count))
        all["Connection"] = "close"
        all["Cache-Control"] = all["Cache-Control"] ?? "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        all["Referrer-Policy"] = "no-referrer"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var d = Data(h.utf8)
        if !head, file == nil { d.append(body) }
        return d
    }
}

public enum HTTPParse {
    public static let maxHeaderBytes = 32 * 1024
    public static let maxBodyBytes = 256 * 1024

    public enum Failure: Error { case malformed, headersTooLarge, bodyTooLarge }

    /// Splits a query string on `&` and `=` and percent-decodes each part; text that is not valid percent-encoding is kept as sent.
    /// (Assigning to `URLComponents.percentEncodedQuery` traps on bad escapes such as `%zz`, so it is never used.)
    public static func parseQuery(_ q: String) -> [String: String] {
        func decode(_ t: Substring) -> String {
            let raw = String(t)
            return raw.removingPercentEncoding ?? raw
        }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            out[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }

    /// Parses the head (everything before the blank line) into a request without a body.
    public static func parseHead(_ head: String, peer: String) throws -> (HTTPRequest, contentLength: Int) {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw Failure.malformed }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = parseQuery(String(target[target.index(after: q)...]))
        }
        path = path.removingPercentEncoding ?? path
        guard path.hasPrefix("/") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() where !l.isEmpty {
            guard let c = l.firstIndex(of: ":") else { throw Failure.malformed }
            headers[l[..<c].lowercased().trimmingCharacters(in: .whitespaces)] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { throw Failure.malformed }       // "abc" or "-1" is a bad request, not an empty body
            length = n
        }
        if length > maxBodyBytes { throw Failure.bodyTooLarge }
        if headers["transfer-encoding"] != nil { throw Failure.malformed }
        return (HTTPRequest(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers, peer: peer), length)
    }
}

public final class HTTPServer: @unchecked Sendable {
    public let host: String
    private let requestedPort: UInt16
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false
    public private(set) var port: UInt16 = 0
    /// At most this many connections are served at once; the next one is answered 503 and closed. A slow client therefore can
    /// occupy a slot for `requestDeadline` seconds at most, and never starves the shared system thread pool.
    public static let maxConnections = 16
    public static let defaultDeadline: TimeInterval = 10
    public let requestDeadline: TimeInterval
    private let slots = DispatchSemaphore(value: HTTPServer.maxConnections)
    private let workers = DispatchQueue(label: "review-serve", qos: .userInitiated, attributes: .concurrent)

    private let bindAnywhere: Bool

    /// `host` must be a loopback IPv4 address unless `bindAnywhere` is set (the web app inside its container, where the
    /// container's port mapping is the boundary and the site's own peer/key checks gate the requests).
    public init(host: String = "127.0.0.1", port: UInt16, requestDeadline: TimeInterval = HTTPServer.defaultDeadline, bindAnywhere: Bool = false,
                handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.host = host; self.requestedPort = port; self.handler = handler; self.requestDeadline = requestDeadline; self.bindAnywhere = bindAnywhere
    }

    public func start() throws {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #else
        // Linux has no SO_NOSIGPIPE; a peer that goes away mid-write raises SIGPIPE for the whole process instead, so ignore
        // it once here (write then fails with EPIPE, which the loop below treats as "stop sending").
        signal(SIGPIPE, SIG_IGN)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw ArchiveError("bad bind address \(host)") }
        guard bindAnywhere || (addr.sin_addr.s_addr & 0xFF) == 127 else { throw ArchiveError("refusing to bind \(host): this server listens on loopback only") }
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw ArchiveError("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { let e = String(cString: strerror(errno)); close(fd); throw ArchiveError("cannot bind \(host):\(requestedPort): \(e)") }
        guard listen(fd, 64) == 0 else { let e = String(cString: strerror(errno)); close(fd); throw ArchiveError("listen: \(e)") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "review-accept"
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        if listenFD >= 0 { shutdown(listenFD, shutReadWrite); close(listenFD); listenFD = -1 }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            var peerAddr = sockaddr_in()
            var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peerAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &plen) } }
            if c < 0 { if isStopped { return }; if errno == EINTR || errno == ECONNABORTED { continue }; return }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, &peerAddr.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            let peer = String(cString: ip)
            guard slots.wait(timeout: .now()) == .success else {
                Self.noSigpipe(c)
                Self.write(c, HTTPResponse.error(503, "busy").serialized(head: false))
                close(c)
                continue
            }
            workers.async { [handler, slots, requestDeadline] in
                Self.serve(fd: c, peer: peer, deadline: requestDeadline, handler: handler)
                slots.signal()
            }
        }
    }

    /// Reads at most one chunk, waiting no longer than the request's total deadline (not per chunk, so a trickle of bytes cannot
    /// hold a slot). Returns the byte count, or <= 0 on EOF, error or deadline.
    private static func readBefore(_ deadline: Date, fd: Int32, into chunk: inout [UInt8]) -> Int {
        let ms = Int32(max(0, min(Double(Int32.max), deadline.timeIntervalSinceNow * 1000)))
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, ms)
        if r <= 0 { return -1 }
        return read(fd, &chunk, chunk.count)
    }

    private static func serve(fd: Int32, peer: String, deadline total: TimeInterval, handler: (HTTPRequest) -> HTTPResponse) {
        defer { close(fd) }
        noSigpipe(fd)
        var tv = timeval(tv_sec: max(1, Int(total)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(total)

        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        func send(_ r: HTTPResponse, head: Bool = false) {
            Self.write(fd, r.serialized(head: head))
            if !head, let f = r.file { Self.stream(f, to: fd) }
        }
        while headEnd == nil {
            let n = readBefore(deadline, fd: fd, into: &chunk)
            if n <= 0 { return }
            buf.append(chunk, count: n)
            headEnd = buf.range(of: sep)
            if headEnd == nil, buf.count > HTTPParse.maxHeaderBytes { send(HTTPResponse.error(431, "headers too large")); return }
        }
        guard let end = headEnd, let headText = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else { send(HTTPResponse.error(400, "bad request")); return }
        do {
            var (req, length) = try HTTPParse.parseHead(headText, peer: peer)
            var body = Data(buf[end.upperBound...])
            while body.count < length {
                let n = readBefore(deadline, fd: fd, into: &chunk)
                if n <= 0 { return }
                body.append(chunk, count: n)
            }
            req.body = body.prefix(length)
            send(handler(req), head: req.method == "HEAD")
        } catch HTTPParse.Failure.bodyTooLarge {
            // Answer, stop sending, then read and discard what the client is still uploading (up to a limit), so it sees the 413
            // instead of a reset connection.
            send(HTTPResponse.error(413, "body too large"))
            shutdown(fd, shutWrite)
            var drained = 0
            while drained < 4 * HTTPParse.maxBodyBytes {
                let n = readBefore(deadline, fd: fd, into: &chunk)
                if n <= 0 { break }
                drained += n
            }
        } catch {
            send(HTTPResponse.error(400, "bad request"))
        }
    }

    /// Copies `range` of the file to the socket in 256 KB reads; stops quietly when the peer goes away.
    private static func stream(_ range: FileRange, to fd: Int32) {
        let src = open(range.url.path, O_RDONLY)
        guard src >= 0 else { return }
        defer { close(src) }
        guard lseek(src, off_t(range.offset), SEEK_SET) == off_t(range.offset) else { return }
        let size = 256 << 10
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        var left = range.length
        while left > 0 {
            let n = read(src, buf, Int(min(Int64(size), left)))
            if n < 0 { if errno == EINTR { continue }; return }
            if n == 0 { return }
            var off = 0
            while off < n {
                #if canImport(Darwin)
                let w = Darwin.write(fd, buf + off, n - off)
                #else
                let w = Glibc.write(fd, buf + off, n - off)
                #endif
                if w <= 0 { return }
                off += w
            }
            left -= Int64(n)
        }
    }

    private static func noSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func write(_ fd: Int32, _ d: Data) {
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                #if canImport(Darwin)
                let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                #else
                let w = Glibc.write(fd, raw.baseAddress! + off, raw.count - off)
                #endif
                if w <= 0 { return }
                off += w
            }
        }
    }
}
