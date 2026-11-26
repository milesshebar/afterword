import Foundation

/// Pure-Swift SHA-256 and SHA-1, for the Linux build (CryptoKit is Apple-only and the package takes no third-party
/// dependency). macOS keeps CryptoKit; `DigestTests` checks these against the published vectors, and against CryptoKit
/// where it exists. Speed is not a goal: on Linux nothing hashes media (imports run on the Mac).
struct SHA256Pure {
    private var h: [UInt32] = [0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    init() {}

    mutating func update(bufferPointer bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        var i = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, bytes.count)
            pending.append(contentsOf: bytes[0..<take])
            i = take
            if pending.count == 64 {
                let block = pending
                block.withUnsafeBytes { compress($0, at: 0) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= bytes.count { compress(bytes, at: i); i += 64 }
        if i < bytes.count { pending.append(contentsOf: bytes[i...]) }
    }

    func finalize() -> [UInt8] {
        var copy = self
        var tail = copy.pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = copy.length &* 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        tail.withUnsafeBytes { raw in var off = 0; while off < raw.count { copy.compress(raw, at: off); off += 64 } }
        var out = [UInt8](); out.reserveCapacity(32)
        for v in copy.h { out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff)) }
        return out
    }

    private mutating func compress(_ p: UnsafeRawBufferPointer, at off: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            let b = off + t * 4
            w[t] = UInt32(p[b]) << 24 | UInt32(p[b + 1]) << 16 | UInt32(p[b + 2]) << 8 | UInt32(p[b + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ Self.k[t] &+ w[t]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}

struct SHA1Pure {
    private var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    init() {}

    mutating func update(bufferPointer bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        var i = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, bytes.count)
            pending.append(contentsOf: bytes[0..<take])
            i = take
            if pending.count == 64 {
                let block = pending
                block.withUnsafeBytes { compress($0, at: 0) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= bytes.count { compress(bytes, at: i); i += 64 }
        if i < bytes.count { pending.append(contentsOf: bytes[i...]) }
    }

    func finalize() -> [UInt8] {
        var copy = self
        var tail = copy.pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = copy.length &* 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        tail.withUnsafeBytes { raw in var off = 0; while off < raw.count { copy.compress(raw, at: off); off += 64 } }
        var out = [UInt8](); out.reserveCapacity(20)
        for v in copy.h { out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff)) }
        return out
    }

    private mutating func compress(_ p: UnsafeRawBufferPointer, at off: Int) {
        var w = [UInt32](repeating: 0, count: 80)
        for t in 0..<16 {
            let b = off + t * 4
            w[t] = UInt32(p[b]) << 24 | UInt32(p[b + 1]) << 16 | UInt32(p[b + 2]) << 8 | UInt32(p[b + 3])
        }
        for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
        for t in 0..<80 {
            let f: UInt32, k: UInt32
            switch t {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
            default: f = b ^ c ^ d; k = 0xCA62_C1D6
            }
            let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
            e = d; d = c; c = rotl(b, 30); b = a; a = temp
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
    }
}

@inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
@inline(__always) private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
