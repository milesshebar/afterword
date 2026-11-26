import Foundation

/// One attribute of the element currently being delivered. The buffers point into the scanner's read buffer and are
/// valid only for the duration of the callback.
public struct XMLAttribute {
    public let name: UnsafeBufferPointer<UInt8>
    public let value: UnsafeBufferPointer<UInt8>

    public func nameIs(_ s: StaticString) -> Bool {
        name.count == s.utf8CodeUnitCount && memcmp(name.baseAddress!, s.utf8Start, name.count) == 0
    }

    /// The value with entities resolved (including UTF-16 surrogate-pair character references).
    public var string: String { XMLText.decode(value) }
    public var isEmpty: Bool { value.count == 0 }
}

public protocol XMLScannerDelegate: AnyObject {
    func startElement(_ name: UnsafeBufferPointer<UInt8>, attributes: [XMLAttribute], selfClosing: Bool) throws
    func endElement(_ name: UnsafeBufferPointer<UInt8>) throws
}

/// A forgiving streaming XML tokenizer, written for SMS Backup & Restore files: a 1+ GB file made of tens of
/// thousands of elements, some with multi-megabyte base64 attributes. It never builds a tree, holds only the current
/// tag in memory, ignores text nodes, comments, processing instructions and DOCTYPEs, and decodes entities itself so
/// illegal-but-common input (surrogate-pair character references, control-character references) does not abort it.
public final class XMLScanner {
    private var buf: UnsafeMutablePointer<UInt8>
    private var cap: Int
    private var start = 0
    private var end = 0
    private var eof = false
    private let fd: Int32
    private var attrs: [XMLAttribute] = []
    public private(set) var bytesRead: Int64 = 0
    public private(set) var peakBufferBytes = 0
    private let chunk: Int

    public init(fileURL: URL, chunkSize: Int = 4 << 20) throws {
        fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw ArchiveError("cannot open \(fileURL.path): \(String(cString: strerror(errno)))") }
        #if canImport(Darwin)
        _ = fcntl(fd, F_RDAHEAD, 1)
        #endif
        chunk = chunkSize
        cap = chunkSize * 2
        buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        attrs.reserveCapacity(64)
    }

    deinit { close(fd); buf.deallocate() }

    /// Reads more bytes, keeping the unconsumed region [start, end). `atLeast` forces large attributes to grow the
    /// buffer geometrically instead of re-reading in small steps.
    private func fill(atLeast: Int) throws {
        if eof { return }
        if start > 0 {
            if end > start { memmove(buf, buf + start, end - start) }
            end -= start
            start = 0
        }
        let want = max(chunk, atLeast)
        if cap - end < want {
            var newCap = cap
            while newCap - end < want { newCap *= 2 }
            let nb = UnsafeMutablePointer<UInt8>.allocate(capacity: newCap)
            if end > 0 { memcpy(nb, buf, end) }
            buf.deallocate()
            buf = nb
            cap = newCap
        }
        var got = 0
        while got < want {
            let n = read(fd, buf + end + got, min(want - got, cap - end - got))
            if n < 0 { if errno == EINTR { continue }; throw ArchiveError("read failed: \(String(cString: strerror(errno)))") }
            if n == 0 { eof = true; break }
            got += n
        }
        end += got
        bytesRead += Int64(got)
        peakBufferBytes = max(peakBufferBytes, cap)
    }

    private enum TagResult { case ok, needMore }

    public func scan(delegate: XMLScannerDelegate) throws {
        try fill(atLeast: 0)
        while true {
            // Find the next '<'.
            var lt: UnsafeMutableRawPointer? = nil
            while true {
                if end > start { lt = memchr(buf + start, 0x3C, end - start) }
                if lt != nil { break }
                start = end
                if eof { return }
                try fill(atLeast: 0)
                if end == start && eof { return }
            }
            start = buf.distance(to: lt!.assumingMemoryBound(to: UInt8.self))

            // Make sure the whole construct is buffered; parse it; on shortage fetch more and retry.
            var need = 1
            while true {
                let r = try parseConstruct(delegate: delegate, need: &need)
                if r == .ok { break }
                if eof { throw ArchiveError("unexpected end of XML near byte \(bytesRead)") }
                try fill(atLeast: max(need, end - start))
            }
        }
    }

    /// Parses one construct at `start`. On success advances `start` past it.
    private func parseConstruct(delegate: XMLScannerDelegate, need: inout Int) throws -> TagResult {
        let avail = end - start
        if avail < 2 { need = 2; return .needMore }
        let p = buf + start
        let c1 = p[1]
        if c1 == 0x21 { // <! : comment, CDATA, DOCTYPE
            if avail < 4 { need = 4; return .needMore }
            if p[2] == 0x2D && p[3] == 0x2D { return skip(until: [0x2D, 0x2D, 0x3E], need: &need) }
            if avail >= 9, p[2] == 0x5B { return skip(until: [0x5D, 0x5D, 0x3E], need: &need) }
            return skip(until: [0x3E], need: &need)
        }
        if c1 == 0x3F { return skip(until: [0x3F, 0x3E], need: &need) } // <? ... ?>
        if c1 == 0x2F { // </name>
            guard let gt = memchr(p, 0x3E, avail) else { need = avail + 1; return .needMore }
            let gtOff = p.distance(to: gt.assumingMemoryBound(to: UInt8.self))
            var nameEnd = 2
            while nameEnd < gtOff, !isSpace(p[nameEnd]) { nameEnd += 1 }
            try delegate.endElement(UnsafeBufferPointer(start: p + 2, count: nameEnd - 2))
            start += gtOff + 1
            return .ok
        }
        // <name attr="v" ... > or />
        var i = 1
        while i < avail, !isSpace(p[i]), p[i] != 0x3E, p[i] != 0x2F { i += 1 }
        if i >= avail { need = avail + 1; return .needMore }
        let nameBuf = UnsafeBufferPointer(start: p + 1, count: i - 1)
        attrs.removeAll(keepingCapacity: true)
        var selfClosing = false
        while true {
            while i < avail, isSpace(p[i]) { i += 1 }
            if i >= avail { need = avail + 1; return .needMore }
            let c = p[i]
            if c == 0x3E { i += 1; break }
            if c == 0x2F {
                if i + 1 >= avail { need = avail + 1; return .needMore }
                if p[i + 1] == 0x3E { selfClosing = true; i += 2; break }
                i += 1; continue
            }
            let ns = i
            while i < avail, p[i] != 0x3D, !isSpace(p[i]), p[i] != 0x3E, p[i] != 0x2F { i += 1 }
            let ne = i
            while i < avail, isSpace(p[i]) { i += 1 }
            if i >= avail { need = avail + 1; return .needMore }
            if p[i] != 0x3D {
                // Attribute without a value: record it empty.
                attrs.append(XMLAttribute(name: UnsafeBufferPointer(start: p + ns, count: ne - ns),
                                          value: UnsafeBufferPointer(start: p + ne, count: 0)))
                continue
            }
            i += 1
            while i < avail, isSpace(p[i]) { i += 1 }
            if i >= avail { need = avail + 1; return .needMore }
            let q = p[i]
            guard q == 0x22 || q == 0x27 else { throw ArchiveError("malformed attribute near byte \(bytesRead)") }
            i += 1
            guard let close = memchr(p + i, Int32(q), avail - i) else { need = avail + 1; return .needMore }
            let ve = p.distance(to: close.assumingMemoryBound(to: UInt8.self))
            attrs.append(XMLAttribute(name: UnsafeBufferPointer(start: p + ns, count: ne - ns),
                                      value: UnsafeBufferPointer(start: p + i, count: ve - i)))
            i = ve + 1
        }
        try delegate.startElement(nameBuf, attributes: attrs, selfClosing: selfClosing)
        if selfClosing { try delegate.endElement(nameBuf) }
        start += i
        return .ok
    }

    private func skip(until term: [UInt8], need: inout Int) -> TagResult {
        let avail = end - start
        let p = buf + start
        let first = Int32(term[0])
        var off = 2
        while off < avail {
            guard let hit = memchr(p + off, first, avail - off) else { break }
            let h = p.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            if h + term.count <= avail {
                var match = true
                for k in 1..<term.count where p[h + k] != term[k] { match = false; break }
                if match { start += h + term.count; return .ok }
                off = h + 1
            } else { break }
        }
        need = avail + 1
        return .needMore
    }

    @inline(__always) private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }
}

/// Entity and encoding repair for attribute values.
public enum XMLText {
    public static func decode(_ v: UnsafeBufferPointer<UInt8>) -> String {
        guard v.count > 0, let base = v.baseAddress else { return "" }
        let hasAmp = memchr(base, 0x26, v.count) != nil
        let hasED = memchr(base, 0xED, v.count) != nil
        if !hasAmp && !hasED { return String(decoding: v, as: UTF8.self) }
        return decodeSlow(v)
    }

    private static func decodeSlow(_ v: UnsafeBufferPointer<UInt8>) -> String {
        var out = [UInt8]()
        out.reserveCapacity(v.count)
        var i = 0
        let n = v.count
        func append(scalar: UInt32) {
            let s = Unicode.Scalar(scalar) ?? "\u{FFFD}"
            out.append(contentsOf: Array(String(Character(s)).utf8))
        }
        /// Parse "&#...;" at index j; returns (code unit, next index) or nil.
        func charRef(at j: Int) -> (UInt32, Int)? {
            guard j + 3 < n, v[j] == 0x26, v[j + 1] == 0x23 else { return nil }
            var k = j + 2
            var val: UInt32 = 0
            var digits = 0
            if v[k] == 0x78 || v[k] == 0x58 {
                k += 1
                while k < n, digits < 8 {
                    let c = v[k]
                    let d: UInt32
                    switch c {
                    case 0x30...0x39: d = UInt32(c - 0x30)
                    case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                    case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                    default: d = 99
                    }
                    if d == 99 { break }
                    val = val &* 16 &+ d; digits += 1; k += 1
                }
            } else {
                while k < n, digits < 9, v[k] >= 0x30, v[k] <= 0x39 { val = val &* 10 &+ UInt32(v[k] - 0x30); digits += 1; k += 1 }
            }
            guard digits > 0, k < n, v[k] == 0x3B else { return nil }
            return (val, k + 1)
        }
        while i < n {
            let b = v[i]
            if b == 0x26 {
                if let (code, next) = charRef(at: i) {
                    i = next
                    if code >= 0xD800 && code <= 0xDBFF {
                        if let (low, next2) = charRef(at: i), low >= 0xDC00 && low <= 0xDFFF {
                            append(scalar: 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00))
                            i = next2
                        } else { append(scalar: 0xFFFD) }
                    } else if code >= 0xDC00 && code <= 0xDFFF || code == 0 || code > 0x10FFFF {
                        append(scalar: 0xFFFD)
                    } else {
                        append(scalar: code)
                    }
                    continue
                }
                // Named entities.
                func has(_ s: StaticString) -> Bool {
                    let c = s.utf8CodeUnitCount
                    return i + c <= n && memcmp(v.baseAddress! + i, s.utf8Start, c) == 0
                }
                if has("&amp;") { out.append(0x26); i += 5; continue }
                if has("&lt;") { out.append(0x3C); i += 4; continue }
                if has("&gt;") { out.append(0x3E); i += 4; continue }
                if has("&quot;") { out.append(0x22); i += 6; continue }
                if has("&apos;") { out.append(0x27); i += 6; continue }
                out.append(b); i += 1
            } else if b == 0xED, i + 5 < n, v[i + 1] >= 0xA0, v[i + 1] <= 0xAF, v[i + 3] == 0xED, v[i + 4] >= 0xB0, v[i + 4] <= 0xBF {
                // CESU-8: a UTF-16 surrogate pair encoded as two 3-byte sequences.
                let hi = (UInt32(v[i] & 0x0F) << 12) | (UInt32(v[i + 1] & 0x3F) << 6) | UInt32(v[i + 2] & 0x3F)
                let lo = (UInt32(v[i + 3] & 0x0F) << 12) | (UInt32(v[i + 4] & 0x3F) << 6) | UInt32(v[i + 5] & 0x3F)
                append(scalar: 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00))
                i += 6
            } else {
                out.append(b); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Base64 decoding straight from an attribute buffer; ignores whitespace and any other non-alphabet bytes.
public enum Base64Fast {
    private static let table: [UInt8] = {
        var t = [UInt8](repeating: 255, count: 256)
        for (i, c) in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8).enumerated() { t[Int(c)] = UInt8(i) }
        t[Int(UInt8(ascii: "-"))] = 62; t[Int(UInt8(ascii: "_"))] = 63   // url-safe variants
        return t
    }()

    /// `entityEncoded` values (containing '&') are first run through the entity decoder.
    public static func decode(_ v: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        if v.count > 0, let base = v.baseAddress, memchr(base, 0x26, v.count) != nil {
            let s = XMLText.decode(v)
            return Array(s.utf8).withUnsafeBufferPointer { decodeRaw($0) }
        }
        return decodeRaw(v)
    }

    static func decodeRaw(_ v: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(v.count / 4 * 3 + 3)
        var acc: UInt32 = 0
        var nbits = 0
        table.withUnsafeBufferPointer { t in
            for c in v {
                let d = t[Int(c)]
                if d == 255 { continue }
                acc = (acc << 6) | UInt32(d)
                nbits += 6
                if nbits >= 8 {
                    nbits -= 8
                    out.append(UInt8(truncatingIfNeeded: acc >> UInt32(nbits)))
                    acc &= (1 << UInt32(nbits)) - 1
                }
            }
        }
        return out
    }
}
