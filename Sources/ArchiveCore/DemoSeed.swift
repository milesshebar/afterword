import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import CoreText
import ImageIO
#endif

/// Writes a clearly fake archive for QA, the app's `--snapshot`, and tests: invented people ("Ada Demo"), 555-01xx
/// numbers (reserved for fiction), template-built message text, and generated placeholder pictures. Two sources shaped
/// like the real ones (an iPhone-backup era to Sep 2015, then an Android era to Nov 2019 with a near-empty Jun-Sep 2018),
/// including overlapping mid-2015 rows so cross-source dedup is exercised.
public enum DemoSeed {
    public struct Options: Sendable {
        public var bigThreadMessages = 31_000
        public var otherThreads = 24
        public var messagesPerOtherThread = 900
        public var groupThreads = 4
        public var imageEvery = 60
        public init() {}
        public init(scale: Double) {
            bigThreadMessages = max(200, Int(31_000 * scale))
            messagesPerOtherThread = max(30, Int(900 * scale))
            imageEvery = 60
        }
    }

    public struct Summary: Sendable { public var messagesWritten = 0; public var duplicates = 0; public var threads = 0; public var mediaFiles = 0; public var seconds = 0.0 }

    static let people: [(String, String)] = [
        ("Ada Demo", "(212) 555-0101"), ("Ben Sample", "212-555-0102"), ("Cleo Fixture", "+1 212 555 0103"),
        ("Dev Placeholder", "212.555.0104"), ("Eli Mockson", "(212) 555-0105"), ("Fay Testwell", "212-555-0106"),
        ("Gus Synthetic", "(917) 555-0107"), ("Hana Notreal", "917-555-0108"), ("Ivo Fakename", "+1 917 555 0109"),
        ("Jun Imaginary", "(917) 555-0110"), ("Kit Stubbs", "718-555-0111"), ("Lux Dummy", "(718) 555-0112"),
        ("Mo Pretend", "718-555-0113"), ("Nia Specimen", "(646) 555-0114"), ("Oz Faux", "646-555-0115"),
        ("Pia Mockup", "(646) 555-0116"), ("Quin Sandbox", "212-555-0117"), ("Rae Dryrun", "(212) 555-0118"),
        ("Sol Example", "917-555-0119"), ("Tess Harness", "(917) 555-0120"), ("Uma Scaffold", "718-555-0121"),
        ("Vic Testdata", "(718) 555-0122"), ("Wren Lorem", "646-555-0123"), ("Xan Ipsum", "(646) 555-0124"),
        ("Yui Dolor", "212-555-0125"),
    ]
    static let meNumber = "+12125550100"

    static let openers = ["want to", "are you free to", "should we", "can't wait to", "did you remember to", "let's", "i forgot to", "we have to", "i'm going to", "maybe we could"]
    static let things = ["grab pizza", "see the concert", "call the landlord", "pick up the keys", "catch the train", "watch the game", "book the flight", "meet at the airport", "order dumplings", "go to the museum", "walk the dog", "fix the bike", "plan the trip", "bring the camera", "borrow the ladder", "get coffee", "finish the edit", "send the invoice"]
    static let tails = ["tonight", "tomorrow", "this weekend", "after work", "around noon", "before it rains", "on Friday", "later", "next week", "right now", ""]
    static let replies = ["sounds good", "ok", "haha yes", "running late", "be there in ten", "perfect", "no worries", "love that", "can we do thursday instead", "on my way", "thanks!", "see you soon", "yep", "wait what", "lol", "great, talk later"]

    struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; var x = s; x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33; return x }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Int64 {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return Int64(cal.date(from: c)!.timeIntervalSince1970 * 1000)
    }

    static let iosStart = ms(2011, 3, 1), iosEnd = ms(2015, 9, 30, 18)
    static let androidStart = ms(2015, 10, 2), androidEnd = ms(2019, 11, 15)
    static let overlapStart = ms(2015, 7, 1)

    /// Relative message volume by month: slow ramp, summer peaks, and one quiet stretch (Jun-Sep 2018).
    static func monthWeight(_ t: Int64) -> Double {
        let d = Date(timeIntervalSince1970: Double(t) / 1000)
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        var w = 0.5 + Double(y - 2011) * 0.18
        if m == 7 || m == 8 || m == 12 { w *= 1.4 }
        if y == 2018 && (6...9).contains(m) { w *= 0.04 }
        if y == 2018 && m == 5 { w *= 0.4 }
        return w
    }

    #if canImport(CoreGraphics)
    /// Draws a labeled placeholder picture: a gradient with a big "DEMO" mark.
    static func makeImage(seed: Int, width: Int = 640, height: Int = 480) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ k: Int, _ a: CGFloat = 1) -> CGColor {
            let h = CGFloat((seed * 47 + k * 120) % 360) / 360
            let c = NSColorLike.hsb(h, 0.55, 0.9)
            return CGColor(red: c.0, green: c.1, blue: c.2, alpha: a)
        }
        let grad = CGGradient(colorsSpace: cs, colors: [color(0), color(1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(color(2, 0.35))
        ctx.fillEllipse(in: CGRect(x: width / 8 * (1 + seed % 3), y: height / 6, width: height / 2, height: height / 2))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.92)]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "DEMO \(seed)" as CFString, attrs as CFDictionary))
        ctx.textPosition = CGPoint(x: 28, y: 28)
        CTLineDraw(line, ctx)
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func makePDF() -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = CGDataConsumer(data: out)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Demo itinerary (fake)" as CFString, [kCTFontAttributeName: font] as CFDictionary))
        ctx.textPosition = CGPoint(x: 40, y: 150)
        CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        return out as Data
    }

    enum NSColorLike {
        static func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let i = Int(h * 6), f = h * 6 - CGFloat(i), p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
            switch i % 6 { case 0: return (b, t, p); case 1: return (q, b, p); case 2: return (p, b, t); case 3: return (p, q, b); case 4: return (t, p, b); default: return (b, p, q) }
        }
    }
    #else
    /// Without CoreGraphics (Linux): the same gradient-and-disc picture, no text, as an uncompressed PNG.
    static func makeImage(seed: Int, width: Int = 640, height: Int = 480) -> Data { DemoMedia.png(seed: seed, width: width, height: height) }
    static func makePDF() -> Data { DemoMedia.pdf() }
    #endif

    /// Builds the demo archive at `root` (which must not already hold an archive). Deterministic for a given option set.
    @discardableResult
    public static func seed(root: ArchiveRoot, options: Options = Options(), progress: ((String) -> Void)? = nil) throws -> Summary {
        let t0 = Date()
        if FileManager.default.fileExists(atPath: root.databaseURL.path) { throw ArchiveError("\(root.url.path) already holds an archive; demo-seed only writes into an empty folder") }
        let db = try Schema.openArchive(root: root)
        let store = MediaStore(root: root)
        var summary = Summary()
        var rng = RNG(s: 0xD3_0D3_0D3)

        // Prepare media once: 24 pictures, one PDF, one vCard.
        var images: [(Data, String)] = []
        for i in 0..<24 { images.append((makeImage(seed: i + 1), "demo-\(i + 1).png")) }
        let pdf = makePDF()
        let vcard = Data("BEGIN:VCARD\nVERSION:3.0\nFN:Ada Demo (fake)\nTEL:+12125550101\nEND:VCARD\n".utf8)

        func attachmentRecord(_ data: Data, mime: String, filename: String, writer: ArchiveWriter) throws -> AttachmentRecord {
            let st = try data.withUnsafeBytes { try store.store($0, mime: mime, filename: filename, lookup: { writer.existingMediaPath(sha256: $0) }) }
            return AttachmentRecord(mime: mime, filename: filename, sha256: st.sha256, relativePath: st.relativePath, bytes: st.bytes)
        }

        try db.transaction {
            try db.exec("INSERT OR REPLACE INTO meta(key, value) VALUES ('demo', '1')")
            func addSource(_ kind: String, _ path: String, _ n: Int) throws -> Int64 {
                let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
                ins.bind(1, kind).bind(2, path).bind(3, "demo-" + String(repeating: "0", count: 56) + String(format: "%08d", n)).bind(4, 0).bind(5, Int64(Date().timeIntervalSince1970))
                try ins.run()
                return db.lastInsertRowID
            }
            let iosID = try addSource("ios-backup", "demo:iphone-backup", 1)
            let andID = try addSource("android-xml", "demo:sms-demo.xml", 2)
            let ios = try ArchiveWriter(db: db, sourceID: iosID, sourceKind: "ios-backup", sourceTier: SourceTier.modernIOS)
            // Android is written second so the overlap shows up as duplicates of the iPhone rows.
            let and = try ArchiveWriter(db: db, sourceID: andID, sourceKind: "android-xml")

            // Plan the threads: (participants, count, in-group?)
            struct Plan { var members: [Int]; var count: Int; var big: Bool }
            var plans: [Plan] = [Plan(members: [0], count: options.bigThreadMessages, big: true)]
            for i in 0..<options.otherThreads {
                let who = 1 + (i % (people.count - 1))
                let scale = 0.25 + Double((i * 7) % 11) / 8
                plans.append(Plan(members: [who], count: Int(Double(options.messagesPerOtherThread) * scale), big: false))
            }
            for g in 0..<options.groupThreads {
                plans.append(Plan(members: [1 + g, 5 + g, 9 + g] + (g % 2 == 0 ? [13 + g] : []), count: options.messagesPerOtherThread, big: false))
            }

            struct Pending { var rec: MessageRecord; var ios: Bool }
            for (pi, plan) in plans.enumerated() {
                let parts = plan.members.map { people[$0].1 }
                var recs: [MessageRecord] = []
                recs.reserveCapacity(plan.count)
                // Thread era: the first third of the small threads exist only on one side, to vary the badges.
                let eraStart = plan.big || pi % 3 != 1 ? iosStart + Int64(pi) * 86_400_000 * 9 : androidStart
                let eraEnd = plan.big || pi % 4 != 2 ? androidEnd - Int64(pi) * 86_400_000 * 3 : iosEnd
                // Sample timestamps by month weight (rejection sampling) so volume follows the shape and the gap shows.
                var stamps: [Int64] = []
                stamps.reserveCapacity(plan.count)
                var safety = 0
                while stamps.count < plan.count && safety < plan.count * 400 {
                    safety += 1
                    let t = eraStart + Int64(rng.unit() * Double(eraEnd - eraStart))
                    if t > iosEnd && t < androidStart { continue }
                    if rng.unit() * 2.5 < monthWeight(t) { stamps.append(t) }
                }
                stamps.sort()
                // Bursty conversations: nudge consecutive stamps into short runs.
                var i = 0
                while i < stamps.count {
                    let run = 1 + rng.int(8)
                    for k in 1..<max(1, run) where i + k < stamps.count { stamps[i + k] = stamps[i] + Int64(k) * Int64(20_000 + rng.int(240_000)) }
                    i += run
                }
                stamps.sort()
                for (n, t) in stamps.enumerated() {
                    let fromMe = rng.int(100) < 48
                    let sender = plan.members.count > 1 ? parts[rng.int(parts.count)] : parts[0]
                    var body: String
                    if rng.int(100) < 55 { body = replies[rng.int(replies.count)] }
                    else { body = "\(openers[rng.int(openers.count)]) \(things[rng.int(things.count)]) \(tails[rng.int(tails.count)])".trimmingCharacters(in: .whitespaces) }
                    if n % 997 == 0 { body += " (demo #\(n))" }
                    recs.append(MessageRecord(participants: parts, sender: fromMe ? nil : sender, tsMs: t, isFromMe: fromMe,
                                              service: t <= iosEnd ? (rng.int(100) < 85 ? "imessage" : "sms") : (rng.int(100) < 96 ? "sms" : "mms"),
                                              body: body))
                }
                // Attachments: pictures on a sparse subset, a PDF and a vCard each in a few threads.
                for n in stride(from: 5 + pi, to: recs.count, by: options.imageEvery + pi) {
                    recs[n].body = rng.int(3) == 0 ? nil : recs[n].body
                    recs[n].service = recs[n].tsMs <= iosEnd ? "imessage" : "mms"
                    recs[n].attachments = [AttachmentRecord(mime: "image/png", filename: nil, sha256: "pending-\(rng.int(images.count))", relativePath: "", bytes: 0)]
                }
                if recs.count > 40 && pi % 5 == 0 {
                    recs[recs.count / 2].attachments = [AttachmentRecord(mime: "application/pdf", filename: "itinerary.pdf", sha256: "pending-pdf", relativePath: "", bytes: 0)]
                    recs[recs.count / 3].attachments = [AttachmentRecord(mime: "text/x-vcard", filename: "ada-demo.vcf", sha256: "pending-vcf", relativePath: "", bytes: 0)]
                }

                func resolved(_ r: MessageRecord, writer: ArchiveWriter) throws -> MessageRecord {
                    var r = r
                    r.attachments = try r.attachments.map { a in
                        if a.sha256.hasPrefix("pending-") {
                            let key = String(a.sha256.dropFirst("pending-".count))
                            if key == "pdf" { return try attachmentRecord(pdf, mime: "application/pdf", filename: "itinerary.pdf", writer: writer) }
                            if key == "vcf" { return try attachmentRecord(vcard, mime: "text/x-vcard", filename: "ada-demo.vcf", writer: writer) }
                            let img = images[Int(key) ?? 0]
                            return try attachmentRecord(img.0, mime: "image/png", filename: img.1, writer: writer)
                        }
                        return a
                    }
                    return r
                }

                for r in recs {
                    if r.tsMs <= iosEnd {
                        let m = try resolved(r, writer: ios)
                        try ios.add(m); summary.messagesWritten += 1
                        // The Android phone also holds mid-2015 copies (flattened to SMS) of the iPhone rows.
                        if r.tsMs >= overlapStart {
                            var copy = try resolved(r, writer: and)
                            copy.service = "sms"
                            if try and.add(copy) == .duplicate { summary.duplicates += 1 }
                        }
                    } else {
                        let m = try resolved(r, writer: and)
                        try and.add(m); summary.messagesWritten += 1
                    }
                }
                if (pi + 1) % 6 == 0 { progress?("threads \(pi + 1)/\(plans.count), messages \(summary.messagesWritten)") }
            }
            for (name, number) in people {
                try ios.noteName(forRaw: number, name: name, origin: ContactOrigin.iphoneAddressBook, priority: ContactPriority.iphoneAddressBook)
                try and.noteName(forRaw: number, name: name)
            }

            // Messenger and Instagram (stage B): the same fake people have accounts too, so the by-person list has something to merge.
            // Ada Demo (the big SMS/iMessage thread) and Ben Sample appear on both services under their full names; a Messenger-only
            // person stays on her own row; one message request is hidden by default.
            struct MetaPlan { var service: String; var name: String; var count: Int; var origin: String; var from: Int64; var to: Int64 }
            let n = max(30, options.messagesPerOtherThread)
            let metaPlans = [
                MetaPlan(service: "messenger", name: "Ada Demo", count: n * 4 / 9, origin: "inbox", from: ms(2012, 3, 1), to: ms(2018, 11, 1)),
                MetaPlan(service: "instagram", name: "Ada Demo", count: n * 2 / 7, origin: "inbox", from: ms(2015, 2, 1), to: ms(2019, 10, 1)),
                MetaPlan(service: "messenger", name: "Ben Sample", count: n / 6, origin: "inbox", from: ms(2013, 5, 1), to: ms(2017, 6, 1)),
                MetaPlan(service: "messenger", name: "Zed Unmatched", count: max(20, n / 14), origin: "inbox", from: ms(2014, 1, 1), to: ms(2015, 9, 1)),
                MetaPlan(service: "messenger", name: "Quinn Stranger", count: 4, origin: "requests", from: ms(2015, 2, 1), to: ms(2015, 2, 3)),
            ]
            let metaSources = try ["messenger-thread", "instagram-thread"].map { kind -> (String, ArchiveWriter) in
                let sid = try addSource(kind, "demo:\(kind)", kind == "messenger-thread" ? 3 : 4)
                return (kind, try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind))
            }
            for (pi, plan) in metaPlans.enumerated() {
                let writer = plan.service == "messenger" ? metaSources[0].1 : metaSources[1].1
                let handle = plan.service == "messenger" ? ServiceHandle.facebook(name: plan.name) : ServiceHandle.instagram(name: plan.name)
                var stamps: [Int64] = (0..<plan.count).map { _ in plan.from + Int64(rng.unit() * Double(plan.to - plan.from)) }.sorted()
                var i = 0
                while i < stamps.count {   // bursty, like the SMS threads
                    let run = 1 + rng.int(7)
                    for k in 1..<max(1, run) where i + k < stamps.count { stamps[i + k] = stamps[i] + Int64(k) * Int64(15_000 + rng.int(200_000)) }
                    i += run
                }
                stamps.sort()
                for (k, t) in stamps.enumerated() {
                    let fromMe = rng.int(100) < 46
                    var rec = MessageRecord(participants: [], sender: nil, tsMs: t, isFromMe: fromMe, service: plan.service,
                                            body: rng.int(100) < 50 ? replies[rng.int(replies.count)] : "\(openers[rng.int(openers.count)]) \(things[rng.int(things.count)]) \(tails[rng.int(tails.count)])".trimmingCharacters(in: .whitespaces))
                    rec.participantHandles = [handle]
                    rec.senderHandle = fromMe ? nil : handle
                    if k % 53 == 7 { rec.reactions = [ReactionRecord(emoji: "👍", actor: fromMe ? handle : nil, byMe: !fromMe)] }
                    if k % 131 == 3 { rec.body = nil; rec.kind = "system"; rec.note = "\(plan.name) changed the chat colors." }
                    if k % 211 == 5 { rec.body = nil; rec.kind = "call"; rec.note = "Call ended (\(2 + rng.int(40)) minutes)." }
                    try writer.add(rec)
                }
                try writer.noteName(service: handle, name: plan.name, origin: plan.service == "messenger" ? "messenger-export" : "instagram-export", priority: ContactPriority.androidXML)
                let tid = try db.scalarInt("SELECT id FROM thread WHERE key = '\(handle.normalized)'")
                let up = try db.prepare("UPDATE thread SET service = ?, origin = ?, hidden = ?, external_id = ? WHERE id = ?")
                up.bind(1, plan.service).bind(2, plan.origin).bind(3, plan.origin == "requests").bind(4, "demo\(pi)").bind(5, tid)
                try up.run()
            }
        }
        try PeopleStore.rematch(db: db)
        summary.threads = Int(try db.scalarInt("SELECT count(*) FROM thread"))
        summary.mediaFiles = Int(try db.scalarInt("SELECT count(*) FROM media"))
        summary.seconds = Date().timeIntervalSince(t0)
        return summary
    }
}
