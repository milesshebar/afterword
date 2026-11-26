import Foundation

/// Content-addressed media store under `<root>/media/<xx>/<sha256>.<ext>`. The same bytes from any number of exports
/// are stored once. Only root-relative paths ever leave this type.
public final class MediaStore {
    public let root: ArchiveRoot
    private var knownDirs = Set<String>()
    private var tmpCounter = 0

    public struct Stored { public let sha256: String; public let relativePath: String; public let bytes: Int; public let wasNew: Bool }

    public init(root: ArchiveRoot) { self.root = root }

    static let mimeExtensions: [String: String] = [
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/gif": "gif", "image/heic": "heic",
        "image/heif": "heif", "image/webp": "webp", "image/bmp": "bmp", "image/tiff": "tiff",
        "video/mp4": "mp4", "video/3gpp": "3gp", "video/3gpp2": "3g2", "video/mpeg": "mpg", "video/quicktime": "mov",
        "audio/amr": "amr", "audio/mp3": "mp3", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac",
        "audio/ogg": "ogg", "audio/3gpp": "3ga", "audio/x-wav": "wav",
        "text/x-vcard": "vcf", "text/vcard": "vcf", "text/x-vcalendar": "ics", "text/plain": "txt",
        "application/pdf": "pdf", "application/vnd.vcard": "vcf",
    ]

    public static func fileExtension(mime: String?, filename: String?) -> String {
        if let m = mime?.lowercased(), let e = mimeExtensions[m] { return e }
        if let f = filename {
            let e = (f as NSString).pathExtension.lowercased()
            if !e.isEmpty, e.count <= 5, e.allSatisfy({ $0.isLetter || $0.isNumber }) { return e }
        }
        return "bin"
    }

    public func relativePath(sha256: String, ext: String) -> String {
        "\(ArchiveRoot.mediaDirName)/\(sha256.prefix(2))/\(sha256).\(ext)"
    }

    /// Stores `bytes` and returns its content address. `lookup` yields the path already recorded for a hash (if any),
    /// so a repeated photo costs one stat and no write.
    public func store(_ bytes: UnsafeRawBufferPointer, mime: String?, filename: String?, lookup: (String) -> String?) throws -> Stored {
        let sha = Hashing.sha256Hex(bytes)
        let existingPath = lookup(sha)
        let rel = existingPath ?? relativePath(sha256: sha, ext: Self.fileExtension(mime: mime, filename: filename))
        let url = root.resolve(relativePath: rel)
        if existingPath != nil, FileManager.default.fileExists(atPath: url.path) {
            return Stored(sha256: sha, relativePath: rel, bytes: bytes.count, wasNew: false)
        }
        let dir = url.deletingLastPathComponent().path
        if !knownDirs.contains(dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            knownDirs.insert(dir)
        }
        if existingPath == nil, FileManager.default.fileExists(atPath: url.path) {
            return Stored(sha256: sha, relativePath: rel, bytes: bytes.count, wasNew: false)
        }
        // Write to a temp name in the same directory, then rename: a crash never leaves a truncated media file.
        tmpCounter += 1
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(getpid())-\(tmpCounter)").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw ArchiveError("cannot create \(tmp): \(String(cString: strerror(errno)))") }
        var off = 0
        while off < bytes.count {
            let n = write(fd, bytes.baseAddress! + off, bytes.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                close(fd); unlink(tmp)
                throw ArchiveError("write failed: \(String(cString: strerror(errno)))")
            }
            off += n
        }
        close(fd)
        guard rename(tmp, url.path) == 0 else { unlink(tmp); throw ArchiveError("rename failed: \(String(cString: strerror(errno)))") }
        return Stored(sha256: sha, relativePath: rel, bytes: bytes.count, wasNew: true)
    }
}
