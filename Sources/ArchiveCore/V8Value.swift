import Foundation

/// A value read from V8's structured-clone wire format (`v8::ValueSerializer`), as Chromium's IndexedDB stores it: a Blink envelope
/// (`ff <blink version>`, and from Blink version 21 a trailer-offset tag) and then V8's own header (`ff <v8 version>`) and one value.
/// Slack's desktop app (2020-21) saved its Redux state this way; Node's `v8.deserialize` reads the same bytes after the envelope.
///
/// Read: undefined, null, booleans, int32 / uint32 / double / BigInt (as a decimal string), one-byte (Latin-1), two-byte (UTF-16LE)
/// and UTF-8 strings, objects (keys as strings: numeric keys print as JavaScript prints them), dense and sparse arrays (holes read
/// as undefined), Date, wrapped primitives, RegExp (its source), Map, Set, ArrayBuffer and views (bytes), back-references to an
/// earlier object, padding and the object-count check. Anything else (host objects, Wasm, errors, shared buffers) is an error, so a
/// value this reader does not know is never silently misread.
public indirect enum V8Value: Equatable, Sendable {
    case undefined, null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([V8Value])
    case object([String: V8Value])
    case date(Double)
    case map([V8Value: V8Value])
    case set([V8Value])
    case bytes(Data)

    public subscript(_ key: String) -> V8Value? { if case .object(let o) = self { return o[key] }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var object: [String: V8Value]? { if case .object(let o) = self { return o }; return nil }
    public var array: [V8Value]? { if case .array(let a) = self { return a }; return nil }
    /// A string that is not empty.
    public var text: String? { if case .string(let s) = self, !s.isEmpty { return s }; return nil }
}

extension V8Value: Hashable {
    public func hash(into h: inout Hasher) {
        switch self {
        case .string(let s): h.combine(0); h.combine(s)
        case .number(let n): h.combine(1); h.combine(n)
        case .bool(let b): h.combine(2); h.combine(b)
        default: h.combine(3)
        }
    }
}

public enum V8Deserializer {
    public struct Failure: Error, CustomStringConvertible {
        public let offset: Int, reason: String
        public var description: String { "V8 value: \(reason) at byte \(offset)" }
    }

    /// Reads one Chromium IndexedDB value: the Blink envelope, then the V8 value.
    public static func readIndexedDBValue(_ data: Data) throws -> V8Value {
        var r = Reader(data: [UInt8](data))
        guard try r.u8() == 0xFF else { throw r.fail("no Blink envelope (first byte is not ff)") }
        let blink = try r.varint()
        if blink >= 21 {
            // Blink 21+: a trailer-offset tag (0xfe), the trailer's offset (8 bytes) and size (4 bytes).
            guard try r.u8() == 0xFE else { throw r.fail("Blink \(blink) without its trailer-offset tag") }
            r.o += 12
        }
        return try readV8(&r)
    }

    /// Reads a bare V8 serialization (`ff <version>` and one value), as Node's `v8.serialize` writes it.
    public static func readV8(_ data: Data) throws -> V8Value {
        var r = Reader(data: [UInt8](data))
        return try readV8(&r)
    }

    static func readV8(_ r: inout Reader) throws -> V8Value {
        guard try r.u8() == 0xFF else { throw r.fail("no V8 header") }
        let version = try r.varint()
        guard version >= 13 else { throw r.fail("V8 serialization version \(version) is older than this reader") }
        r.version = version
        let v = try r.value()
        return v
    }

    struct Reader {
        let data: [UInt8]
        var o = 0
        var objects: [Int: V8Value] = [:]     // by id, for back-references
        var nextID = 0
        var version: UInt64 = 13
        var depth = 0
        /// Deeper nesting than this is refused (a corrupt save must not overflow the stack; the real Slack saves nest at most 18 deep).
        static let maxDepth = 64

        func fail(_ s: String) -> Failure { Failure(offset: o, reason: s) }

        mutating func u8() throws -> UInt8 {
            guard o < data.count else { throw fail("ends early") }
            defer { o += 1 }
            return data[o]
        }

        mutating func varint() throws -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                let b = try u8()
                if shift < 64 { v |= UInt64(b & 0x7F) << shift }
                if b & 0x80 == 0 { return v }
                shift += 7
                if shift > 70 { throw fail("varint too long") }
            }
        }

        /// A length or count from a varint: refused when it cannot be an Int or is more than `limit` (by default the bytes left,
        /// since each counted item takes at least one byte).
        mutating func count(limit: Int? = nil) throws -> Int {
            let v = try varint()
            let cap = limit ?? (data.count - o)
            guard v <= UInt64(max(0, cap)) else { throw fail("length \(v) is more than \(cap)") }
            return Int(v)
        }

        mutating func zigzag32() throws -> Int32 {
            let u = UInt32(truncatingIfNeeded: try varint())
            return Int32(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
        }

        mutating func double() throws -> Double {
            guard o + 8 <= data.count else { throw fail("ends early in a double") }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(data[o + i]) << (8 * UInt64(i)) }
            o += 8
            return Double(bitPattern: bits)
        }

        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, n <= data.count - o else { throw fail("ends early in \(n) bytes") }
            defer { o += n }
            return data[o..<(o + n)]
        }

        mutating func latin1() throws -> String {
            let b = try bytes(try count())
            return String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
        }

        mutating func utf16() throws -> String {
            let n = try count()
            guard n % 2 == 0 else { throw fail("two-byte string of odd length") }
            let b = try bytes(n)
            var units: [UInt16] = []
            units.reserveCapacity(n / 2)
            var i = b.startIndex
            while i < b.endIndex { units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }

        mutating func utf8() throws -> String { String(decoding: try bytes(try count()), as: UTF8.self) }

        /// JavaScript's own printing of a number used as a property key (integers without a fraction).
        static func keyString(_ d: Double) -> String {
            if d == d.rounded(), abs(d) < 1e21 { return String(Int64(d)) }
            return String(d)
        }

        mutating func key() throws -> String {
            switch try value() {
            case .string(let s): return s
            case .number(let d): return Reader.keyString(d)
            default: throw fail("object key that is not a string or a number")
            }
        }

        mutating func reserve() -> Int { defer { nextID += 1 }; return nextID }

        /// Properties until `end`, then the property count that must match.
        mutating func properties(end: UInt8, into dict: inout [String: V8Value]) throws -> Int {
            var n = 0
            while true {
                try skipPadding()
                guard o < data.count else { throw fail("ends early in an object") }
                if data[o] == end { o += 1; break }
                let k = try key()
                dict[k] = try value()
                n += 1
            }
            let count = try varint()
            guard count == UInt64(n) else { throw fail("object says \(count) properties, read \(n)") }
            return n
        }

        mutating func skipPadding() throws {
            while o < data.count, data[o] == 0x00 { o += 1 }
        }

        mutating func value() throws -> V8Value {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Reader.maxDepth else { throw fail("nested deeper than \(Reader.maxDepth)") }
            try skipPadding()
            let tag = try u8()
            switch tag {
            case 0x5F: return .undefined                    // _
            case 0x30: return .null                         // 0
            case 0x54: return .bool(true)                   // T
            case 0x46: return .bool(false)                  // F
            case 0x49: return .number(Double(try zigzag32()))   // I
            case 0x55: return .number(Double(UInt32(truncatingIfNeeded: try varint())))   // U
            case 0x4E: return .number(try double())        // N
            case 0x5A: return .string(try bigint())         // Z
            case 0x22: return .string(try latin1())         // "
            case 0x63: return .string(try utf16())          // c
            case 0x53: return .string(try utf8())           // S
            case 0x5E:                                      // ^ back-reference
                let id = try varint()
                guard id < UInt64(Int.max), let v = objects[Int(id)] else { throw fail("reference to object \(id) before it is complete") }
                // A view of a buffer met earlier: the reference is followed by the view tag.
                if case .bytes(let b) = v {
                    try skipPadding()
                    if o < data.count, data[o] == 0x56 { return try view(b) }
                }
                return v
            // Containers each in a function of their own: the recursive frame stays small (a debug build's test thread has 512 KB).
            case 0x6F: return try jsObject()                // o object
            case 0x41: return try denseArray()              // A dense array
            case 0x61: return try sparseArray()             // a sparse array
            case 0x44:                                      // D date
                let id = reserve(); let v = V8Value.date(try double()); objects[id] = v; return v
            case 0x79, 0x78:                                // y / x: Boolean objects
                let id = reserve(); let v = V8Value.bool(tag == 0x79); objects[id] = v; return v
            case 0x6E:                                      // n: Number object
                let id = reserve(); let v = V8Value.number(try double()); objects[id] = v; return v
            case 0x7A:                                      // z: BigInt object
                let id = reserve(); let v = V8Value.string(try bigint()); objects[id] = v; return v
            case 0x73:                                      // s: String object
                let id = reserve(); let v = try value(); objects[id] = v; return v
            case 0x52:                                      // R regexp: source string, flags
                let id = reserve(); let v = try value(); _ = try varint(); objects[id] = v; return v
            case 0x3B: return try jsMap()                   // ; Map
            case 0x27: return try jsSet()                   // ' Set
            case 0x42:                                      // B ArrayBuffer, maybe followed by a view
                let id = reserve()
                let b = Data(try bytes(try count()))
                objects[id] = .bytes(b)
                try skipPadding()
                if o < data.count, data[o] == 0x56 { return try view(b) }
                return .bytes(b)
            case 0x76:                                      // v: object-count check
                _ = try varint(); return try value()
            default:
                throw Failure(offset: o - 1, reason: String(format: "tag 0x%02x not read", tag))
            }
        }

        @inline(never) mutating func jsObject() throws -> V8Value {
            let id = reserve()
            var d: [String: V8Value] = [:]
            _ = try properties(end: 0x7B, into: &d)     // {
            objects[id] = .object(d)
            return .object(d)
        }

        @inline(never) mutating func denseArray() throws -> V8Value {
            let id = reserve()
            let n = try count()
            var a: [V8Value] = []
            a.reserveCapacity(min(n, 1 << 20))
            for _ in 0..<n {
                try skipPadding()
                if o < data.count, data[o] == 0x2D { o += 1; a.append(.undefined) } // - hole
                else { a.append(try value()) }
            }
            var extra: [String: V8Value] = [:]
            _ = try properties(end: 0x24, into: &extra) // $ (extra named properties are dropped)
            guard try varint() == UInt64(n) else { throw fail("dense array length mismatch") }
            objects[id] = .array(a)
            return .array(a)
        }

        @inline(never) mutating func sparseArray() throws -> V8Value {
            let id = reserve()
            let n = try count(limit: 1 << 32)
            var d: [String: V8Value] = [:]
            _ = try properties(end: 0x40, into: &d)     // @
            guard try varint() == UInt64(n) else { throw fail("sparse array length mismatch") }
            var a = [V8Value](repeating: .undefined, count: min(n, 1 << 24))
            for (k, v) in d { if let i = Int(k), i >= 0, i < a.count { a[i] = v } }
            objects[id] = .array(a)
            return .array(a)
        }

        @inline(never) mutating func jsMap() throws -> V8Value {
            let id = reserve()
            var m: [V8Value: V8Value] = [:], n = 0
            while true {
                try skipPadding()
                guard o < data.count else { throw fail("ends early in a Map") }
                if data[o] == 0x3A { o += 1; break }    // :
                let k = try value(); m[k] = try value(); n += 2
            }
            guard try varint() == UInt64(n) else { throw fail("Map length mismatch") }
            objects[id] = .map(m)
            return .map(m)
        }

        @inline(never) mutating func jsSet() throws -> V8Value {
            let id = reserve()
            var s: [V8Value] = []
            while true {
                try skipPadding()
                guard o < data.count else { throw fail("ends early in a Set") }
                if data[o] == 0x2C { o += 1; break }    // ,
                s.append(try value())
            }
            guard try varint() == UInt64(s.count) else { throw fail("Set length mismatch") }
            objects[id] = .set(s)
            return .set(s)
        }

        /// V (view): subtag, byte offset, byte length (and, from V8 14, flags): the bytes of the buffer it views.
        mutating func view(_ buffer: Data) throws -> V8Value {
            o += 1
            _ = try u8()
            let off = try count(limit: buffer.count), len = try count(limit: buffer.count)
            if version >= 14 { _ = try varint() }           // flags (V8 wire version 14 and later)
            let id = reserve()
            guard off <= buffer.count - len else { throw fail("view outside its buffer") }
            let v = V8Value.bytes(buffer.subdata(in: off..<(off + len)))
            objects[id] = v
            return v
        }

        /// BigInt: a bitfield (sign in bit 0, byte length in the rest) and little-endian digits; printed as a decimal string.
        mutating func bigint() throws -> String {
            let bits = try varint()
            let negative = bits & 1 == 1
            guard bits >> 1 <= UInt64(data.count - o) else { throw fail("BigInt longer than the data") }
            let b = try bytes(Int(bits >> 1))
            var digits: [UInt32] = [0]                      // base 1e9, little-endian
            for byte in b.reversed() {
                var carry = UInt64(byte)
                for i in 0..<digits.count {
                    let v = UInt64(digits[i]) * 256 + carry
                    digits[i] = UInt32(v % 1_000_000_000); carry = v / 1_000_000_000
                }
                while carry > 0 { digits.append(UInt32(carry % 1_000_000_000)); carry /= 1_000_000_000 }
            }
            var s = String(digits.last!)
            for d in digits.dropLast().reversed() { s += String(repeating: "0", count: 9 - String(d).count) + String(d) }
            return (negative && s != "0" ? "-" : "") + s
        }
    }
}
