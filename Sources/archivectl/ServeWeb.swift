import Foundation
import ArchiveCore

/// `archivectl serve-web`: the read-only web app (JSON API, media, the static page).
func runServeWeb(args rest: [String], root: ArchiveRoot) throws {
    var args = rest
    var port: UInt16 = 8452
    var bind = "127.0.0.1"
    var gate = WebSite.Gate()
    var web: String?
    var cache: String?
    var keyEnv = "ARCHIVE_WEB_KEY"
    let flags = ["--port", "--bind", "--allow-host", "--allow-login", "--allow-peer", "--web", "--cache", "--key-env"]
    while let i = args.firstIndex(where: { flags.contains($0) }) {
        guard i + 1 < args.count else { eprint("\(args[i]) needs a value"); exit(2) }
        let v = args[i + 1]
        switch args[i] {
        case "--port": guard let p = UInt16(v) else { eprint("--port needs a number"); exit(2) }; port = p
        case "--bind": bind = v
        case "--allow-host": gate.hosts.append(v)
        case "--allow-login": gate.logins.append(v)
        case "--allow-peer": gate.peers.append(v)
        case "--web": web = v
        case "--cache": cache = v
        default: keyEnv = v
        }
        args.removeSubrange(i...(i + 1))
    }
    if args.contains("--any-peer") { gate.anyPeer = true; args.removeAll { $0 == "--any-peer" } }
    if let extra = args.first { eprint("unknown option: \(extra)"); exit(2) }
    gate.key = WebSite.key(fromEnvironmentValue: ProcessInfo.processInfo.environment[keyEnv])
    if let why = WebSite.startupProblem(bind: bind, gate: gate, keyEnv: keyEnv) { eprint("refusing to start: \(why)"); exit(2) }
    let anywhere = bind != "127.0.0.1"

    // The web folder: --web, else web/ next to the archivectl binary's package root, else ./web.
    let fm = FileManager.default
    var webURL: URL?
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for cand in [web.map { URL(fileURLWithPath: $0, isDirectory: true) },
                 exe.deletingLastPathComponent().appendingPathComponent("web", isDirectory: true),
                 exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web", isDirectory: true),
                 URL(fileURLWithPath: "web", isDirectory: true)].compactMap({ $0 }) {
        if fm.fileExists(atPath: cand.appendingPathComponent("index.html").path) { webURL = cand; break }
    }
    guard let webURL else { eprint("no web folder with index.html found; pass --web <dir>"); exit(2) }
    let cacheURL = cache.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(Product.executable + "-web", isDirectory: true)
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(Product.executable + "-web", isDirectory: true)
    try fm.createDirectory(at: cacheURL, withIntermediateDirectories: true)

    eprint("loading \(root.url.path) ...")
    let service = try WebService(root: root)
    let site = WebSite(service: service, gate: gate, webRoot: webURL, cacheRoot: cacheURL)
    let server = HTTPServer(host: bind, port: port, bindAnywhere: anywhere) { site.handle($0) }
    try server.start()
    let o = try service.overview()
    print("web app: http://\(bind):\(server.port)/   (\(o.messages) messages, \(o.people) people, \(o.groups) groups; ready in \(String(format: "%.1f", service.lastRefreshSeconds)) s)")
    print("web \(webURL.path); thumbnails \(cacheURL.path); gate: hosts \(gate.hosts), logins \(gate.logins.count), peers \(gate.anyPeer ? "any" : gate.peers.isEmpty ? "loopback" : gate.peers.joined(separator: ",")), key \(gate.key == nil ? "none" : "set")")
    print("read-only: archive.sqlite and people.sqlite are never written. Ctrl-C stops it.")
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()
}
