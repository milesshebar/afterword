import Foundation

/// Where an archive lives. Everything the archive stores is relative to this directory, so the whole folder can be
/// copied elsewhere (for example an SMB share on a NAS) and opened there unchanged.
public struct ArchiveRoot: Sendable {
    public static var environmentKey: String { Product.environmentPrefix + "_ROOT" }
    public static let databaseName = "archive.sqlite"
    public static let mediaDirName = "media"
    /// A folder elsewhere (another volume, or a network share) that holds the files `media/...` paths name. Set with the file `media-root` in the
    /// archive folder (its first line is an absolute path) or the environment variable; the database keeps its root-relative `media/xx/...`
    /// paths either way, so moving the files never touches the database.
    public static let mediaRootFileName = "media-root"
    public static var mediaRootEnvironmentKey: String { Product.environmentPrefix + "_MEDIA_ROOT" }

    public let url: URL
    /// Where `media/` really is when it is not inside `url`; nil = the default `<url>/media`.
    public let mediaOverride: URL?

    public init(url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.url = url.standardizedFileURL
        var path = environment[Self.mediaRootEnvironmentKey] ?? ""
        if path.isEmpty, let text = try? String(contentsOf: self.url.appendingPathComponent(Self.mediaRootFileName), encoding: .utf8) {
            path = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        mediaOverride = path.isEmpty ? nil : URL(fileURLWithPath: Self.expandTilde(path), isDirectory: true).standardizedFileURL
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Product.supportFolder, isDirectory: true)
    }

    /// Resolution order: explicit `--archive` flag, then `<PREFIX>_ROOT` (`environmentKey`), then the default.
    public static func resolve(flag: String? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> ArchiveRoot {
        if let flag, !flag.isEmpty { return ArchiveRoot(url: URL(fileURLWithPath: expandTilde(flag), isDirectory: true)) }
        if let env = environment[environmentKey], !env.isEmpty {
            return ArchiveRoot(url: URL(fileURLWithPath: expandTilde(env), isDirectory: true))
        }
        return ArchiveRoot(url: defaultURL)
    }

    static func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    public var databaseURL: URL { url.appendingPathComponent(Self.databaseName) }
    public var mediaURL: URL { mediaOverride ?? url.appendingPathComponent(Self.mediaDirName, isDirectory: true) }

    /// Absolute location of a stored root-relative path (`media/...` follows the media root when one is configured).
    public func resolve(relativePath: String) -> URL {
        if let m = mediaOverride, relativePath.hasPrefix(Self.mediaDirName + "/") {
            return m.appendingPathComponent(String(relativePath.dropFirst(Self.mediaDirName.count + 1)))
        }
        return url.appendingPathComponent(relativePath)
    }

    /// True when a stored `media/...` path, with every symlink on the way resolved, is a file inside the media folder itself (also
    /// resolved): a symlinked two-hex folder or file cannot make the store name something outside it.
    public func mediaContains(relativePath: String) -> Bool {
        guard relativePath.hasPrefix(Self.mediaDirName + "/"), !relativePath.contains("..") else { return false }
        let base = mediaURL.resolvingSymlinksInPath().standardizedFileURL.path
        let file = resolve(relativePath: relativePath).resolvingSymlinksInPath().standardizedFileURL.path
        return file.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Why the media store cannot be used right now, or nil. A configured media root on a volume that is not mounted must stop the
    /// archive with a clear message, never silently look empty (or create a stray folder under /Volumes).
    public var mediaProblem: String? {
        guard let m = mediaOverride else { return nil }
        let comps = m.pathComponents
        if comps.count > 2, comps[1] == "Volumes" {
            let volume = "/Volumes/" + comps[2]
            if !FileManager.default.fileExists(atPath: volume) {
                return "The media store is configured at \(m.path), but \(comps[2]) is not mounted. Connect it and try again (or remove \(Self.mediaRootFileName) from \(url.path) to use the media folder inside the archive)."
            }
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: m.path, isDirectory: &isDir) || !isDir.boolValue {
            return "The media store is configured at \(m.path), but that folder does not exist."
        }
        return nil
    }

    public func createIfNeeded() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if mediaOverride != nil {
            if let problem = mediaProblem { throw ArchiveError(problem) }
        } else {
            try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        }
    }

    /// True when this process cannot write into the root folder: a read-only bind mount (the web app's container mounts the
    /// archive `:ro`), a read-only volume, or someone else's folder. Such a root is read the way a network root is: an
    /// `immutable` open after `prepare-move`, because SQLite cannot create its WAL side files there.
    public var isReadOnlyLocation: Bool { access(url.path, W_OK) != 0 }

    /// Read-only opens of this root must be `immutable` (no side files): network volumes and unwritable folders.
    public var opensImmutable: Bool { isOnNetworkVolume || isReadOnlyLocation }

    /// True when the root sits on a network filesystem (smbfs, nfs, afpfs, webdav). SQLite WAL needs shared memory
    /// that network mounts do not provide, so such roots use a rollback journal instead.
    public var isOnNetworkVolume: Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        #if canImport(Darwin)
        var fs = statfs()
        guard statfs(probe.path, &fs) == 0 else { return false }
        let name = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return ["smbfs", "nfs", "afpfs", "webdav", "cifs"].contains(name)
        #else
        // Glibc's Swift module does not expose statfs; the mount table says which filesystem holds the deepest mount point
        // above the path (fields: device, mount point, type; octal escapes for spaces).
        guard let table = try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8) else { return false }
        let path = probe.standardizedFileURL.path
        var best = (len: -1, type: "")
        for line in table.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3 else { continue }
            let mount = String(f[1]).replacingOccurrences(of: "\\040", with: " ")
            if (path == mount || path.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")), mount.count > best.len { best = (mount.count, String(f[2])) }
        }
        let t = best.type
        return ["cifs", "smb3", "smbfs", "nfs", "nfs4", "afpfs", "davfs", "fuse.sshfs", "fuse.davfs2"].contains(t) || t.hasPrefix("fuse.")
        #endif
    }
}
