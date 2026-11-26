import AppKit
import CryptoKit
import Foundation
import Security
import ArchiveCore

// An optional self-updater, off unless an update server is set (`defaults write <bundle id> updateServer <url>`, or the
// <PREFIX>_UPDATE_SERVER environment variable; nothing is ever fetched otherwise). The server is this project's own web app
// (`archivectl serve-web`): scripts/release-app.sh publishes signed builds into the archive folder's app-releases/, served at
// /api/app/release (manifest) and /api/app/release/<build>/archive (zip), behind the same gate as every other page.
//
// When (with a server set): 20 s after launch, every 2 hours, on wake (automatic checks at most every 10 min), and from "Check for Updates…".
// What a build must pass, each failure recorded (never retried; a new build has a new number):
// 1. newer than the running build (never a downgrade);
// 2. the zip's size and sha256 equal the manifest's;
// 3. unzipped, exactly one <executable>.app whose identifier is ours and CFBundleVersion is the manifest's build;
// 4. a valid signature under strict validation satisfying the running app's own designated requirement, and a designated requirement
//    identical to it (same identifier, same certificate leaf). A running app that is not certificate-signed updates nothing.
// Install: the app is a reader someone may be in the middle of, so a verified build is installed when the app quits (the bundle is
// renamed aside and the new one moved in; both renames), or at once from "Install Update and Relaunch". Only when the running bundle
// is ~/Applications/<executable>.app. The archive and its settings live outside the bundle and survive.

struct AppRelease: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let sha256: String
    let size: Int
    let published_at: String?
    let commit: String?
}

/// A CFBundleVersion as a build number: digits only; anything else is nil (the running build then counts as 0).
func buildNumber(_ s: String?) -> Int? {
    guard let s, !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(s)
}

struct UpdaterState: Codable, Equatable, Sendable {
    var lastCheck: Date?
    var lastResult: String?
    var refused: [Int: String] = [:]
    func shouldCheck(at now: Date, automatic: Bool, minGap: TimeInterval = 600) -> Bool {
        guard automatic, let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= minGap
    }
    mutating func refuse(_ build: Int, _ reason: String) {
        refused[build] = reason
        for old in refused.keys.sorted().dropLast(20) { refused[old] = nil }
    }
}

@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let every: TimeInterval = 2 * 3600
    static let launchDelay: TimeInterval = 20

    private(set) var state: UpdaterState
    private(set) var checking = false
    private(set) var staged: (release: AppRelease, app: URL, dir: URL)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    private var currentBuild: Int { buildNumber(build) ?? 0 }

    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(Product.supportFolder)-app/updater.json")
    }
    static var installURL: URL {
        let dir = ProcessInfo.processInfo.environment[Product.environmentPrefix + "_APPLICATIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return dir.appendingPathComponent(Product.executable + ".app")
    }
    /// The web app the builds come from: `defaults write <bundle id> updateServer <url>`, else `<PREFIX>_UPDATE_SERVER`.
    /// nil (the default, or anything but an https URL) turns the updater off: no timer, no request.
    static var server: URL? {
        let text = UserDefaults.standard.string(forKey: "updateServer")
            ?? ProcessInfo.processInfo.environment[Product.environmentPrefix + "_UPDATE_SERVER"]
        guard let text, !text.isEmpty, let url = URL(string: text), url.scheme == "https" else { return nil }   // https only
        return url
    }
    static var enabled: Bool { server != nil }

    init() {
        state = (try? JSONDecoder().decode(UpdaterState.self, from: Data(contentsOf: Self.stateURL))) ?? UpdaterState()
    }

    var versionLine: String { "\(Product.name) \(version) (\(build))" }
    var statusLine: String {
        if Self.server == nil { return "Updates: off (no update server set)" }
        if checking { return "Updates: checking…" }
        if let r = staged?.release { return "Updates: \(r.version) (\(r.build)) verified, installs when the app quits" }
        let when = state.lastCheck.map { "checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "not checked yet"
        return "Updates: \(when)" + (state.lastResult.map { ", \($0)" } ?? "")
    }

    func start() {
        guard !started, Self.enabled else { return }
        started = true
        Timer.scheduledTimer(withTimeInterval: Self.launchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(automatic: false) }
        }
        let t = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(automatic: true) }
        }
        t.tolerance = 300
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(automatic: true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installStaged(relaunch: false) }
        }
    }

    private func finish(_ result: String, refusing: (Int, String)? = nil) {
        state.lastCheck = Date()
        state.lastResult = result
        if let (b, why) = refusing { state.refuse(b, why) }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: Self.stateURL, options: .atomic) }
        checking = false
    }

    func check(automatic: Bool) {
        guard !checking, staged == nil, state.shouldCheck(at: Date(), automatic: automatic) else { return }
        guard let server = Self.server else { finish("off: no update server set"); return }
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let target = Self.installURL.resolvingSymlinksInPath().standardizedFileURL
        guard here == target else { finish("off: running from \(here.path), not \(target.path)"); return }
        checking = true
        let current = currentBuild, refused = state.refused
        Task.detached {
            let outcome = await Self.fetchAndVerify(server: server, current: current, refused: refused, near: target)
            await MainActor.run { self.handle(outcome) }
        }
    }

    private enum Outcome: Sendable {
        case done(String)
        case refused(build: Int, reason: String)
        case ready(AppRelease, app: URL, dir: URL)
    }

    private func handle(_ o: Outcome) {
        switch o {
        case .done(let t): finish(t)
        case .refused(let b, let why):
            NSLog("%@ updater: build %d refused: %@", Product.name, b, why)
            finish("build \(b) refused: \(why)", refusing: (b, why))
        case .ready(let r, let app, let dir):
            staged = (r, app, dir)
            finish("\(r.version) (\(r.build)) verified")
        }
    }

    // MARK: off the main thread

    private nonisolated static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.setValue("archive-web", forHTTPHeaderField: "X-Requested-With")   // the web app's API gate (WebSite.requestedWith)
        return r
    }

    private nonisolated static func fetchAndVerify(server: URL, current: Int, refused: [Int: String], near target: URL) async -> Outcome {
        let release: AppRelease
        do {
            let (data, resp) = try await URLSession.shared.data(for: request(server.appendingPathComponent("api/app/release")))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .done("no release published") }
            guard status == 200 else { return .done("check failed: HTTP \(status)") }
            release = try JSONDecoder().decode(AppRelease.self, from: data)
        } catch { return .done("check failed: \(error.localizedDescription)") }
        guard release.build > current else { return .done("up to date") }
        if let why = refused[release.build] { return .done("build \(release.build) refused earlier: \(why)") }
        guard let (_, own) = ownRequirement() else { return .done("off: this app's own signature cannot be read") }
        guard own.contains("certificate leaf") else { return .done("off: this build is not certificate-signed; install a signed build by hand") }
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true) else {
            return .done("check failed: no staging folder next to \(target.path)")
        }
        let zip = dir.appendingPathComponent("\(Product.executable)-\(release.build).zip")
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: request(server.appendingPathComponent("api/app/release/\(release.build)/archive")))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { try? fm.removeItem(at: dir); return .done("download failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            try fm.moveItem(at: tmp, to: zip)
        } catch { try? fm.removeItem(at: dir); return .done("download failed: \(error.localizedDescription)") }
        guard let size = (try? fm.attributesOfItem(atPath: zip.path))?[.size] as? Int, let digest = try? sha256Hex(zip) else {
            try? fm.removeItem(at: dir); return .done("check failed: the download is unreadable")
        }
        guard size == release.size else { try? fm.removeItem(at: dir); return .refused(build: release.build, reason: "size \(size) is not the published \(release.size)") }
        guard digest == release.sha256.lowercased() else { try? fm.removeItem(at: dir); return .refused(build: release.build, reason: "sha256 differs from the published one") }
        let out = dir.appendingPathComponent("unzipped")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { try? fm.removeItem(at: dir); return .done("check failed: unzip: \(error)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let items = try? fm.contentsOfDirectory(atPath: out.path) else { try? fm.removeItem(at: dir); return .done("check failed: unzip") }
        let bundleName = Product.executable + ".app"
        guard items == [bundleName] else { try? fm.removeItem(at: dir); return .refused(build: release.build, reason: "the zip holds \(items), not \(bundleName) alone") }
        let app = out.appendingPathComponent(bundleName)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { try? fm.removeItem(at: dir); return .refused(build: release.build, reason: "another bundle identifier") }
        guard buildNumber(info?["CFBundleVersion"] as? String) == release.build else { try? fm.removeItem(at: dir); return .refused(build: release.build, reason: "the bundle's build is not the published one") }
        if let why = signatureProblem(app) { try? fm.removeItem(at: dir); return .refused(build: release.build, reason: why) }
        try? fm.removeItem(at: zip)
        return .ready(release, app: app, dir: dir)
    }

    private nonisolated static func sha256Hex(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func ownRequirement() -> (SecRequirement, String)? {
        var code: SecCode?, staticCode: SecStaticCode?, req: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { return nil }
        return (req, text as String)
    }

    /// Strict validation against the running app's requirement, and an identical designated requirement; nil when it passes.
    nonisolated static func signatureProblem(_ app: URL) -> String? {
        guard let (req, ownText) = ownRequirement() else { return "this app's own signature cannot be read" }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return "the new bundle's signature cannot be read" }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var err: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &err)
        if status != errSecSuccess { return "the signature does not pass (\(err?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"))" }
        var newReq: SecRequirement?, newText: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &newReq) == errSecSuccess, let newReq,
              SecRequirementCopyString(newReq, [], &newText) == errSecSuccess, let newText else { return "the new bundle's designated requirement cannot be read" }
        return newText as String == ownText ? nil : "designated requirement differs: \(newText)"
    }

    // MARK: install

    /// Swaps the verified build in (at quit, or now with a relaunch): one atomic exchange of the two bundles (`renamex_np` with
    /// RENAME_SWAP, same volume), so ~/Applications/<executable>.app is never missing, then the displaced bundle is removed. Never over
    /// a build that is as new or newer (another install got there first: scripts/install-app.sh, or a second copy of the app). This
    /// process keeps its open files; the next launch runs the new build.
    func installStaged(relaunch: Bool) {
        guard let (release, app, dir) = staged else { return }
        staged = nil
        let fm = FileManager.default, target = Self.installURL
        let installed = buildNumber(NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String) ?? 0
        guard installed < release.build else {
            try? fm.removeItem(at: dir)
            finish("build \(installed) is already installed; \(release.build) not installed over it")
            return
        }
        guard Self.signatureProblem(app) == nil, renamex_np(app.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            let e = String(cString: strerror(errno))
            try? fm.removeItem(at: dir)
            finish("install of \(release.build) failed, will retry: \(e)")
            return
        }
        // `app` now holds the old bundle; the new one is in place, checked once more where it landed
        if let why = Self.signatureProblem(target) {
            let back = renamex_np(app.path, target.path, UInt32(RENAME_SWAP)) == 0
            NSLog("%@ updater: build %d failed its check in place (%@); old bundle %@", Product.name, release.build, why, back ? "restored" : "NOT restored, it is at \(app.path)")
            if back { try? fm.removeItem(at: dir) }
            finish("build \(release.build) refused after install: \(why)" + (back ? "" : "; the previous bundle is at \(app.path)"), refusing: (release.build, why))
            return
        }
        try? fm.removeItem(at: dir)
        finish("installed \(release.version) (\(release.build))")
        NSLog("%@ updater: installed build %d", Product.name, release.build)
        guard relaunch else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"", "relaunch", String(getpid()), target.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
