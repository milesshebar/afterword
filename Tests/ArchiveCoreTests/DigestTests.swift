import Foundation
import Testing
@testable import ArchiveCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif

@Suite("Digests and demo media (Linux build)")
struct DigestTests {
    static func sha256(_ chunks: [[UInt8]]) -> String {
        var h = SHA256Pure()
        for c in chunks { c.withUnsafeBytes { h.update(bufferPointer: $0) } }
        return Hashing.hex(h.finalize())
    }
    static func sha1(_ chunks: [[UInt8]]) -> String {
        var h = SHA1Pure()
        for c in chunks { c.withUnsafeBytes { h.update(bufferPointer: $0) } }
        return Hashing.hex(h.finalize())
    }

    @Test func sha256Vectors() {
        #expect(Self.sha256([[]]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Self.sha256([Array("abc".utf8)]) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Self.sha256([Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)]) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(Self.sha256([[UInt8](repeating: 0x61, count: 1_000_000)]) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func sha1Vectors() {
        #expect(Self.sha1([[]]) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(Self.sha1([Array("abc".utf8)]) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Self.sha1([Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)]) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(Self.sha1([[UInt8](repeating: 0x61, count: 1_000_000)]) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    /// Feeding the bytes in odd-sized pieces (across the 64-byte block boundary, and a chunk bigger than a block) must not change the digest.
    @Test func chunkingIsTransparent() {
        var rng = DemoSeed.RNG(s: 42)
        let bytes = (0..<5000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        var pieces: [[UInt8]] = []
        var i = 0
        while i < bytes.count { let n = min(bytes.count - i, 1 + rng.int(200)); pieces.append(Array(bytes[i..<(i + n)])); i += n }
        #expect(pieces.count > 20)
        #expect(Self.sha256(pieces) == Self.sha256([bytes]))
        #expect(Self.sha1(pieces) == Self.sha1([bytes]))
        #if canImport(CryptoKit)
        #expect(Self.sha256([bytes]) == Hashing.hex(SHA256.hash(data: Data(bytes))))
        #expect(Self.sha1([bytes]) == Hashing.hex(Insecure.SHA1.hash(data: Data(bytes))))
        #endif
        // and the public entry points agree with whichever implementation the platform uses
        #expect(bytes.withUnsafeBytes { Hashing.sha256Hex($0) } == Self.sha256([bytes]))
        #expect(Hashing.sha1Hex(Data(bytes)) == Self.sha1([bytes]))
    }

    @Test func demoPNGIsWellFormed() {
        let png = DemoMedia.png(seed: 3, width: 64, height: 48)
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(String(decoding: png[12..<16], as: UTF8.self) == "IHDR")
        #expect(Array(png[16..<24]) == [0, 0, 0, 64, 0, 0, 0, 48])
        #expect(String(decoding: png.suffix(8).prefix(4), as: UTF8.self) == "IEND")
        #if canImport(ImageIO)
        let src = CGImageSourceCreateWithData(png as CFData, nil)
        let img = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(img?.width == 64 && img?.height == 48)
        #endif
        let pdf = DemoMedia.pdf()
        #expect(pdf.starts(with: Data("%PDF-1.4".utf8)))
        #expect(String(decoding: pdf, as: UTF8.self).contains("startxref"))
    }
}
