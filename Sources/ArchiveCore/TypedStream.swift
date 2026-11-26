import Foundation

/// Extracts the plain text from an `attributedBody` blob (an `NSArchiver` "typedstream" holding an NSAttributedString).
///
/// Foundation's `NSUnarchiver` can decode these, but it signals corrupt data with an Objective-C exception that Swift
/// cannot catch, and real backups contain truncated blobs. So the runtime path reads the stream's string payload
/// directly (the tests check it against `NSUnarchiver` on blobs produced by `NSArchiver`).
///
/// Layout around the text: `... "NSString" 01 <94|95> 84 01 '+' <length> <utf-8 bytes> ...` where the length is one
/// byte below 0x80, or 0x81 + uint16 LE, or 0x82 + uint32 LE.
public enum TypedStream {
    public static func attributedBodyText(_ blob: [UInt8]) -> String? {
        let n = blob.count
        guard n > 16 else { return nil }
        let markers: [[UInt8]] = [Array("NSString".utf8), Array("NSMutableString".utf8)]
        var at: Int? = nil
        for m in markers {
            if let i = find(m, in: blob), at == nil || i < at! { at = i + m.count }
        }
        guard var p = at else { return nil }
        // Skip the class chain (NSMutableString -> NSString) up to the '+' (C string) tag; no class name contains 0x2B.
        let limit = min(n, p + 40)
        while p < limit, blob[p] != 0x2B { p += 1 }
        guard p < limit, blob[p] == 0x2B else { return nil }
        p += 1
        guard p < n else { return nil }
        var len: Int
        switch blob[p] {
        case 0x81:
            guard p + 3 <= n else { return nil }
            len = Int(blob[p + 1]) | Int(blob[p + 2]) << 8; p += 3
        case 0x82:
            guard p + 5 <= n else { return nil }
            len = Int(blob[p + 1]) | Int(blob[p + 2]) << 8 | Int(blob[p + 3]) << 16 | Int(blob[p + 4]) << 24; p += 5
        case let b where b < 0x80:
            len = Int(b); p += 1
        default:
            return nil
        }
        guard len > 0, p + len <= n else { return nil }
        return String(decoding: blob[p..<(p + len)], as: UTF8.self)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        let m = needle.count
        guard hay.count >= m else { return nil }
        let first = needle[0]
        var i = 0
        let end = hay.count - m
        while i <= end {
            if hay[i] == first {
                var k = 1
                while k < m, hay[i + k] == needle[k] { k += 1 }
                if k == m { return i }
            }
            i += 1
        }
        return nil
    }
}
