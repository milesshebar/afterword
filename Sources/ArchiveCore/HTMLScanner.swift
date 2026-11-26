import Foundation

/// The handful of tags the Meta exports are read through. Everything else is `.other`.
public enum HTMLTag: UInt8, Sendable {
    case div, span, a, img, video, audio, ul, li, br, title, style, script, other
}

/// The attributes the importers look at, as slices of the file buffer (no allocation per element).
public struct HTMLAttrs {
    public var cls: UnsafeBufferPointer<UInt8>?
    public var src: UnsafeBufferPointer<UInt8>?
    public var href: UnsafeBufferPointer<UInt8>?
    public var width: UnsafeBufferPointer<UInt8>?
}

public protocol HTMLScannerDelegate: AnyObject {
    /// `selfClosing` is true for void elements (`br`, `img`, `meta`...) and `<x />`: no `endTag` follows.
    func startTag(_ tag: HTMLTag, attrs: HTMLAttrs, selfClosing: Bool)
    func endTag(_ tag: HTMLTag)
    /// Raw text between tags (entities not decoded; use `HTMLEntities.decode`).
    func text(_ bytes: UnsafeBufferPointer<UInt8>)
}

/// A small tolerant tag scanner for the HTML that Meta's "Download your information" writes. Not a browser parser:
/// no tree, no error recovery beyond skipping what it cannot read, comments / doctype / `<style>` / `<script>` bodies
/// are skipped. Files are modest (the largest message file is a few MB), so the whole file is one buffer.
public enum HTMLScanner {
    static let voidTags: Set<String> = ["br", "img", "meta", "link", "base", "hr", "input", "source", "wbr", "col", "area", "embed", "param", "track"]

    public static func scan(_ buf: UnsafeBufferPointer<UInt8>, delegate: HTMLScannerDelegate) {
        let n = buf.count
        var i = 0
        while i < n {
            // text up to the next '<'
            var j = i
            while j < n && buf[j] != 0x3C { j += 1 }
            if j > i { delegate.text(UnsafeBufferPointer(rebasing: buf[i..<j])) }
            if j >= n { break }
            i = j
            // buf[i] == '<'
            if i + 1 >= n { break }
            let c = buf[i + 1]
            if c == 0x21 { // <! comment or doctype
                if i + 3 < n, buf[i + 2] == 0x2D, buf[i + 3] == 0x2D {
                    var k = i + 4
                    while k + 2 < n && !(buf[k] == 0x2D && buf[k + 1] == 0x2D && buf[k + 2] == 0x3E) { k += 1 }
                    i = min(n, k + 3)
                } else {
                    var k = i + 2
                    while k < n && buf[k] != 0x3E { k += 1 }
                    i = min(n, k + 1)
                }
                continue
            }
            if c == 0x3F { // <? ... >
                var k = i + 2
                while k < n && buf[k] != 0x3E { k += 1 }
                i = min(n, k + 1)
                continue
            }
            let closing = c == 0x2F
            var k = i + (closing ? 2 : 1)
            // a '<' not followed by a letter is text
            if k >= n || !isNameStart(buf[k]) {
                delegate.text(UnsafeBufferPointer(rebasing: buf[i..<(i + 1)]))
                i += 1
                continue
            }
            let nameStart = k
            while k < n && isNameChar(buf[k]) { k += 1 }
            let nameBytes = UnsafeBufferPointer(rebasing: buf[nameStart..<k])
            let tag = classify(nameBytes)
            if closing {
                while k < n && buf[k] != 0x3E { k += 1 }
                i = min(n, k + 1)
                delegate.endTag(tag)
                continue
            }
            // attributes
            var attrs = HTMLAttrs()
            var selfClosing = false
            while k < n {
                while k < n && isSpace(buf[k]) { k += 1 }
                if k >= n { break }
                let ch = buf[k]
                if ch == 0x3E { k += 1; break }
                if ch == 0x2F { selfClosing = true; k += 1; continue }
                let an = k
                while k < n && !isSpace(buf[k]) && buf[k] != 0x3D && buf[k] != 0x3E && buf[k] != 0x2F { k += 1 }
                if k == an { k += 1; continue }
                let aname = UnsafeBufferPointer(rebasing: buf[an..<k])
                while k < n && isSpace(buf[k]) { k += 1 }
                var value: UnsafeBufferPointer<UInt8>?
                if k < n && buf[k] == 0x3D {
                    k += 1
                    while k < n && isSpace(buf[k]) { k += 1 }
                    if k < n && (buf[k] == 0x22 || buf[k] == 0x27) {
                        let q = buf[k]; k += 1
                        let vs = k
                        while k < n && buf[k] != q { k += 1 }
                        value = UnsafeBufferPointer(rebasing: buf[vs..<min(k, n)])
                        k = min(n, k + 1)
                    } else {
                        let vs = k
                        while k < n && !isSpace(buf[k]) && buf[k] != 0x3E { k += 1 }
                        value = UnsafeBufferPointer(rebasing: buf[vs..<k])
                    }
                }
                if let value {
                    if eq(aname, "class") { attrs.cls = value }
                    else if eq(aname, "src") { attrs.src = value }
                    else if eq(aname, "href") { attrs.href = value }
                    else if eq(aname, "width") { attrs.width = value }
                }
            }
            i = k
            let isVoid = tag == .br || tag == .img || voidTags.contains(String(decoding: nameBytes, as: UTF8.self).lowercased())
            delegate.startTag(tag, attrs: attrs, selfClosing: selfClosing || isVoid)
            if tag == .style || tag == .script, !(selfClosing) {
                // raw-text element: skip to its closing tag
                let want: StaticString = tag == .style ? "</style" : "</script"
                var m = i
                let wl = want.utf8CodeUnitCount
                outer: while m + wl <= n {
                    if buf[m] == 0x3C, buf[m + 1] == 0x2F {
                        var same = true
                        for t in 0..<wl where lower(buf[m + t]) != want.utf8Start[t] { same = false; break }
                        if same { break outer }
                    }
                    m += 1
                }
                var e = min(m, n)
                while e < n && buf[e] != 0x3E { e += 1 }
                i = min(n, e + 1)
                delegate.endTag(tag)
            }
        }
    }

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }
    @inline(__always) static func isNameStart(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
    @inline(__always) static func isNameChar(_ b: UInt8) -> Bool {
        isNameStart(b) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x3A || b == 0x5F
    }
    @inline(__always) static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 32 : b }

    @inline(__always) static func eq(_ s: UnsafeBufferPointer<UInt8>, _ lit: StaticString) -> Bool {
        guard s.count == lit.utf8CodeUnitCount else { return false }
        for i in 0..<s.count where lower(s[i]) != lit.utf8Start[i] { return false }
        return true
    }

    static func classify(_ n: UnsafeBufferPointer<UInt8>) -> HTMLTag {
        switch n.count {
        case 1: return eq(n, "a") ? .a : .other
        case 2:
            if eq(n, "br") { return .br }
            if eq(n, "ul") { return .ul }
            if eq(n, "li") { return .li }
            return .other
        case 3:
            if eq(n, "div") { return .div }
            if eq(n, "img") { return .img }
            return .other
        case 4: return eq(n, "span") ? .span : .other
        case 5:
            if eq(n, "video") { return .video }
            if eq(n, "audio") { return .audio }
            if eq(n, "title") { return .title }
            if eq(n, "style") { return .style }
            return .other
        case 6: return eq(n, "script") ? .script : .other
        default: return .other
        }
    }
}

/// Entity decoding for text and attribute values: the five XML entities, `&nbsp;`, and numeric references.
public enum HTMLEntities {
    public static func decode(_ b: UnsafeBufferPointer<UInt8>) -> String {
        var hasAmp = false
        for x in b where x == 0x26 { hasAmp = true; break }
        if !hasAmp { return String(decoding: b, as: UTF8.self) }
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c != 0x26 { out.append(c); i += 1; continue }
            guard var (v, next) = parse(b, at: i) else { out.append(c); i += 1; continue }
            if (0xD800...0xDBFF).contains(v), next < n, b[next] == 0x26, let (lo, next2) = parse(b, at: next), (0xDC00...0xDFFF).contains(lo) {
                v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)   // a pair of surrogate references is one astral character
                next = next2
            }
            if let sc = Unicode.Scalar(v) { out.append(contentsOf: Array(String(sc).utf8)); i = next }
            else { out.append(c); i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The code point of the entity starting at `b[i] == '&'` and the index after its ';'.
    static func parse(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> (UInt32, Int)? {
        let n = b.count
        var j = i + 1
        while j < n && j - i <= 10 && b[j] != 0x3B && b[j] != 0x26 && b[j] != 0x20 { j += 1 }
        guard j < n, b[j] == 0x3B, let v = entity(UnsafeBufferPointer(rebasing: b[(i + 1)..<j])) else { return nil }
        return (v, j + 1)
    }

    static func entity(_ name: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard let f = name.first else { return nil }
        if f == 0x23 { // numeric
            var v: UInt32 = 0
            if name.count >= 2, name[1] == 0x78 || name[1] == 0x58 {
                guard name.count > 2 else { return nil }
                for d in name[2...] {
                    guard let h = hexVal(d) else { return nil }
                    v = v &* 16 &+ UInt32(h)
                    if v > 0x10FFFF { return nil }
                }
            } else {
                guard name.count > 1 else { return nil }
                for d in name[1...] {
                    guard d >= 0x30 && d <= 0x39 else { return nil }
                    v = v &* 10 &+ UInt32(d - 0x30)
                    if v > 0x10FFFF { return nil }
                }
            }
            return v
        }
        switch String(decoding: name, as: UTF8.self) {
        case "amp": return 0x26
        case "lt": return 0x3C
        case "gt": return 0x3E
        case "quot": return 0x22
        case "apos": return 0x27
        case "nbsp": return 0xA0
        default: return nil
        }
    }

    static func hexVal(_ d: UInt8) -> Int? {
        switch d {
        case 0x30...0x39: return Int(d - 0x30)
        case 0x41...0x46: return Int(d - 0x41 + 10)
        case 0x61...0x66: return Int(d - 0x61 + 10)
        default: return nil
        }
    }
}
