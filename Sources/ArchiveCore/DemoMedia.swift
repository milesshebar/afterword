import Foundation

/// Placeholder media for the demo archive written without Apple frameworks: an uncompressed (zlib "stored") PNG and a
/// one-page PDF. `DemoSeed` uses these on Linux; macOS draws its own with CoreGraphics. Both are plain, valid files.
enum DemoMedia {
    /// An RGB gradient with a translucent disc, `width` x `height`, as a PNG. Deterministic for a seed.
    static func png(seed: Int, width: Int = 640, height: Int = 480) -> Data {
        func hsb(_ h: Double, _ s: Double, _ b: Double) -> (Double, Double, Double) {
            let i = Int(h * 6), f = h * 6 - Double(i), p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
            switch i % 6 { case 0: return (b, t, p); case 1: return (q, b, p); case 2: return (p, b, t); case 3: return (p, q, b); case 4: return (t, p, b); default: return (b, p, q) }
        }
        func color(_ k: Int) -> (Double, Double, Double) { hsb(Double((seed * 47 + k * 120) % 360) / 360, 0.55, 0.9) }
        let c0 = color(0), c1 = color(1), c2 = color(2)
        let cx = Double(width / 8 * (1 + seed % 3) + height / 4), cy = Double(height / 6 + height / 4), r = Double(height / 4)
        var raw = [UInt8](); raw.reserveCapacity(height * (1 + width * 3))
        for y in 0..<height {
            raw.append(0)   // filter: none
            for x in 0..<width {
                let t = Double(x + y) / Double(width + height)
                var rgb = (c0.0 + (c1.0 - c0.0) * t, c0.1 + (c1.1 - c0.1) * t, c0.2 + (c1.2 - c0.2) * t)
                let dx = Double(x) - cx, dy = Double(height - y) - cy
                if dx * dx + dy * dy <= r * r { rgb = (rgb.0 * 0.65 + c2.0 * 0.35, rgb.1 * 0.65 + c2.1 * 0.35, rgb.2 * 0.65 + c2.2 * 0.35) }
                raw.append(UInt8(max(0, min(255, rgb.0 * 255)))); raw.append(UInt8(max(0, min(255, rgb.1 * 255)))); raw.append(UInt8(max(0, min(255, rgb.2 * 255))))
            }
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr += be32(UInt32(width)); ihdr += be32(UInt32(height)); ihdr += [8, 2, 0, 0, 0]
        out.append(chunk("IHDR", ihdr))
        out.append(chunk("IDAT", zlibStored(raw)))
        out.append(chunk("IEND", []))
        return out
    }

    /// One page, Helvetica, "Demo itinerary (fake)".
    static func pdf() -> Data {
        let content = "BT /F1 24 Tf 40 150 Td (Demo itinerary \\(fake\\)) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var s = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(s.utf8.count)
            s += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = s.utf8.count
        s += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { s += String(format: "%010d 00000 n \n", o) }
        s += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(s.utf8)
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    private static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        var d = Data(be32(UInt32(body.count)))
        let typed = Array(type.utf8) + body
        d.append(contentsOf: typed)
        d.append(contentsOf: be32(crc32(typed)))
        return d
    }

    /// zlib stream of stored (uncompressed) deflate blocks: valid everywhere, no compressor needed.
    private static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var off = 0
        repeat {
            let n = min(65535, bytes.count - off)
            let last = off + n >= bytes.count
            out.append(last ? 1 : 0)
            out.append(UInt8(n & 0xff)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xff)); out.append(UInt8((~n >> 8) & 0xff))
            out.append(contentsOf: bytes[off..<(off + n)])
            off += n
        } while off < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for x in bytes { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        out += be32(b << 16 | a)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
