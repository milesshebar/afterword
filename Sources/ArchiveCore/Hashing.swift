import Foundation
#if canImport(CryptoKit)
import CryptoKit
private typealias FileHasher = SHA256
#else
private typealias FileHasher = SHA256Pure
#endif

public enum Hashing {
    public static func sha256Hex(_ bytes: UnsafeRawBufferPointer) -> String {
        var h = FileHasher()
        h.update(bufferPointer: bytes)
        return hex(h.finalize())
    }

    /// SHA-1 hex (only for iPhone-backup file ids, which are defined that way).
    public static func sha1Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return hex(Insecure.SHA1.hash(data: data))
        #else
        var h = SHA1Pure()
        data.withUnsafeBytes { h.update(bufferPointer: $0) }
        return hex(h.finalize())
        #endif
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let table = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for b in digest { out.append(table[Int(b >> 4)]); out.append(table[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// SHA-256 of a file, streamed in 4 MB chunks through one reusable buffer (no Foundation Data churn).
    public static func sha256Hex(ofFile url: URL) throws -> (hex: String, bytes: Int64) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ArchiveError("cannot read \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let size = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        var hasher = FileHasher()
        var total: Int64 = 0
        while true {
            let n = read(fd, buf, size)
            if n < 0 { if errno == EINTR { continue }; throw ArchiveError("read failed: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            total += Int64(n)
        }
        return (hex(hasher.finalize()), total)
    }

    /// FNV-1a 64-bit over UTF-8, as a signed Int64 for SQLite.
    public static func fnv1a(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        var s = s
        s.withUTF8 { for b in $0 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return Int64(bitPattern: h)
    }

    /// Body normalization for dedup: unify newlines, trim edges.
    public static func normalizedBody(_ body: String?) -> String {
        guard let body else { return "" }
        return body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Body normalization for the emoji-tolerant dedup fallback. The transfer tool that flattened late-2016 iMessages into
    /// Android SMS dropped every emoji (an emoji-only message became an empty one), so those copies never hash equal to the
    /// iPhone row. Emoji, joiners, variation selectors and object-replacement characters are removed and whitespace runs
    /// collapsed before hashing.
    public static func strippedBodyHash(_ body: String?) -> Int64 {
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for u in normalizedBody(body).unicodeScalars {
            let v = u.value
            if v == 0x200D || (0xFE00...0xFE0F).contains(v) || v == 0xFFFC || (0x1F3FB...0x1F3FF).contains(v) || (0xE0020...0xE007F).contains(v) { continue }
            if u.properties.isEmojiPresentation || (u.properties.isEmoji && v > 0xFF) { continue }
            if u.properties.isWhitespace { if !lastSpace { out.append(" "); lastSpace = true }; continue }
            out.append(u); lastSpace = false
        }
        var str = String(out)
        while str.last == " " { str.removeLast() }
        return fnv1a(str)
    }

    public static func attachmentHash(_ shas: [String]) -> Int64? {
        shas.isEmpty ? nil : fnv1a(shas.sorted().joined(separator: ","))
    }
}
