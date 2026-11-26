import Testing
import Foundation
@testable import ArchiveCore

// MARK: normalization

@Suite struct NormalizationTests {
    @Test func usPhonesBecomeE164() {
        for raw in ["(212) 555-0111", "212-555-0111", "2125550111", "12125550111", "+1 212 555 0111", "+12125550111", "1 (212) 555-0111"] {
            #expect(HandleNormalizer.normalize(raw)?.normalized == "+12125550111", "\(raw)")
        }
        #expect(HandleNormalizer.normalize("+44 20 7946 0958")?.normalized == "+442079460958")
        #expect(HandleNormalizer.normalize("011 44 20 7946 0958")?.normalized == "+442079460958")
    }
    @Test func shortCodesAndEmailsStayRaw() {
        #expect(HandleNormalizer.normalize("22000") == NormalizedHandle(normalized: "22000", kind: .short))
        #expect(HandleNormalizer.normalize("Someone@Example.COM") == NormalizedHandle(normalized: "someone@example.com", kind: .email))
        #expect(HandleNormalizer.normalize("ACME-BANK")?.kind == .other)
    }
    @Test func placeholdersAreMe() {
        for raw in ["", "null", "insert-address-token", "(Unknown)"] { #expect(HandleNormalizer.normalize(raw) == nil) }
    }
    @Test func threadKeyIsOrderIndependent() {
        #expect(ThreadKey.key(for: ["+2", "+1", "+3"]) == ThreadKey.key(for: ["+3", "+2", "+1", "+1"]))
        #expect(ThreadKey.key(for: []) == "unknown")
    }
}

// MARK: root + schema

@Suite struct RootTests {
    @Test func resolutionOrder() {
        let env = [ArchiveRoot.environmentKey: "/tmp/from-env"]
        #expect(ArchiveRoot.resolve(flag: "/tmp/from-flag", environment: env).url.path == "/tmp/from-flag")
        #expect(ArchiveRoot.resolve(flag: nil, environment: env).url.path == "/tmp/from-env")
        #expect(ArchiveRoot.resolve(flag: nil, environment: [:]).url == ArchiveRoot.defaultURL.standardizedFileURL)
        #expect(ArchiveRoot.defaultURL.path.hasSuffix("Library/Application Support/" + Product.supportFolder))
    }
    @Test func schemaMigratesAndUsesWALWithFTS() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        #expect(try t.db.userVersion() == Schema.currentVersion)
        #expect(try t.db.scalarString("PRAGMA journal_mode") == "wal")
        #expect(try t.db.scalarInt("PRAGMA foreign_keys") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='message_fts'") == 1)
        // reopening is a no-op migration
        let again = try Schema.openArchive(root: t.root)
        #expect(try again.userVersion() == Schema.currentVersion)
    }
}

// MARK: XML scanning

@Suite struct ScannerTests {
    @Test func surrogatePairReferencesFold() {
        func dec(_ s: String) -> String { Array(s.utf8).withUnsafeBufferPointer { XMLText.decode($0) } }
        #expect(dec("hi &#55357;&#56832;!") == "hi \u{1F600}!")
        #expect(dec("&#xD83D;&#xDE00;") == "\u{1F600}")
        #expect(dec("&#128512;") == "\u{1F600}")
        #expect(dec("a &lt;b&gt; &amp; &quot;c&quot; &apos;d&apos;") == "a <b> & \"c\" 'd'")
        #expect(dec("lone &#55357; high") == "lone \u{FFFD} high")
        #expect(dec("nul &#0; ref") == "nul \u{FFFD} ref")
        #expect(dec("bare & ampersand") == "bare & ampersand")
        // CESU-8 (surrogates encoded as two 3-byte sequences)
        let cesu: [UInt8] = [0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80]
        #expect(cesu.withUnsafeBufferPointer { XMLText.decode($0) } == "\u{1F600}")
    }

    final class Collector: XMLScannerDelegate {
        var events: [String] = []
        func startElement(_ name: UnsafeBufferPointer<UInt8>, attributes: [XMLAttribute], selfClosing: Bool) throws {
            events.append("<" + String(decoding: name, as: UTF8.self) + attributes.map { " \(String(decoding: $0.name, as: UTF8.self))=\($0.string)" }.joined() + (selfClosing ? "/" : "") + ">")
        }
        func endElement(_ name: UnsafeBufferPointer<UInt8>) throws { events.append("</" + String(decoding: name, as: UTF8.self) + ">") }
    }

    @Test func tokenizesAcrossTinyChunksAndAwkwardSyntax() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "A", count: 100_000)
        let xml = "<?xml version='1.0'?><!-- a > comment --><root a='1>2' b=\"x\"><c d=\"\(big)\"/><e/>text<![CDATA[ <ignored> ]]></root>"
        let f = Fixtures.write(xml, to: dir, name: "a.xml")
        for chunk in [7, 64, 4096, 1 << 20] {
            let c = Collector()
            try XMLScanner(fileURL: f, chunkSize: chunk).scan(delegate: c)
            #expect(c.events == ["<root a=1>2 b=x>", "<c d=\(big)/>", "</c>", "<e/>", "</e>", "</root>"], "chunk \(chunk)")
        }
    }

    @Test func truncatedFileThrows() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = Fixtures.write("<a><b x=\"unterminated", to: dir, name: "t.xml")
        #expect(throws: (any Error).self) { try XMLScanner(fileURL: f).scan(delegate: Collector()) }
    }

    @Test func base64DecodesIgnoringWhitespace() {
        let bytes = Fixtures.blob(9, count: 1000)
        var b64 = Data(bytes).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        b64 = b64.replacingOccurrences(of: "\n", with: "\n  ")
        #expect(Array(b64.utf8).withUnsafeBufferPointer { Base64Fast.decode($0) } == bytes)
    }
}

// MARK: importer

@Suite struct ImporterTests {
    @Test func plainSMSBothDirections() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let xml = Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_500_000_000_000, type: 1, body: "hello from alice", name: "Alice Example"),
            Fixtures.sms(address: Fixtures.alice, date: 1_500_000_060_000, type: 2, body: "hi alice, it&apos;s me", name: "Alice Example"),
            Fixtures.sms(address: Fixtures.bob, date: 1_500_000_120_000, type: 1, body: "bob here"),
        ])
        let rep = try t.importXML(xml, name: "sms-1.xml")
        #expect(rep.status == .imported)
        #expect(rep.stats.smsParsed == 3 && rep.stats.mmsParsed == 0 && rep.stats.inserted == 3 && rep.stats.duplicates == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 3)
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread") == 2)           // alice and bob
        #expect(try t.db.scalarInt("SELECT count(*) FROM handle") == 2)
        #expect(try t.db.scalarString("SELECT normalized FROM handle ORDER BY id LIMIT 1") == "+12125550111")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE is_from_me = 1 AND sender_handle_id IS NULL") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE is_from_me = 0 AND sender_handle_id IS NOT NULL") == 2)
        #expect(try t.db.scalarString("SELECT body FROM message WHERE is_from_me = 1") == "hi alice, it's me")
        #expect(try t.db.scalarString("SELECT name FROM contact_name") == "Alice Example")   // "(Unknown)" is dropped
        #expect(try t.db.scalarInt("SELECT count(*) FROM message_fts WHERE message_fts MATCH 'alice'") == 2)
    }

    @Test func groupMMSWithAddrsAndSMILSkipped() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let others = "\(Fixtures.alice)~\(Fixtures.bob)"
        let addrs: [(String, Int)] = [(Fixtures.alice, 137), (Fixtures.me, 151), (Fixtures.bob, 151), (Fixtures.carol, 130)]
        let xml = Fixtures.file([
            Fixtures.mms(address: others, date: 1_510_000_000_000, box: 1, mID: "M1", trID: "T1", parts: [Fixtures.textPart("group hello &#55357;&#56832;")], addrs: addrs),
            Fixtures.mms(address: others, date: 1_510_000_100_000, box: 2, mID: "M2", trID: "T2", parts: [Fixtures.textPart("my reply")],
                         addrs: [(Fixtures.me, 137), (Fixtures.alice, 151), (Fixtures.bob, 151)]),
        ])
        let rep = try t.importXML(xml, name: "sms-g.xml")
        #expect(rep.stats.mmsParsed == 2 && rep.stats.inserted == 2 && rep.stats.smilParts == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread") == 1)
        #expect(try t.db.scalarInt("SELECT is_group FROM thread") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM thread_member") == 2)       // me is not a member
        #expect(try t.db.scalarString("SELECT key FROM thread") == "+12125550111|+12125550122")
        #expect(try t.db.scalarString("SELECT body FROM message WHERE is_from_me = 0") == "group hello \u{1F600}")
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id") == "+12125550111")
        #expect(try t.db.scalarString("SELECT source_key FROM message WHERE is_from_me = 0") == "mms:m:M1")
        #expect(try t.db.scalarString("SELECT service FROM message LIMIT 1") == "mms")
    }

    @Test func mediaPartGoesToContentAddressedStore() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let photo = Fixtures.blob(1, count: 5000)
        let xml = Fixtures.file([
            Fixtures.mms(address: Fixtures.alice, date: 1_520_000_000_000, box: 1, mID: "P1", parts: [Fixtures.textPart("look"), Fixtures.dataPart(photo)], addrs: [(Fixtures.alice, 137), (Fixtures.me, 151)]),
            Fixtures.mms(address: Fixtures.bob, date: 1_520_000_500_000, box: 2, mID: "P2", parts: [Fixtures.dataPart(photo)], addrs: [(Fixtures.me, 137), (Fixtures.bob, 151)]),
            Fixtures.mms(address: Fixtures.bob, date: 1_520_000_900_000, box: 2, mID: "P3", parts: [Fixtures.dataPart(Fixtures.blob(2), ct: "video/3gpp", name: "clip.3gp")], addrs: [(Fixtures.me, 137), (Fixtures.bob, 151)]),
        ])
        let rep = try t.importXML(xml, name: "sms-m.xml")
        #expect(rep.stats.attachments == 3)
        #expect(rep.stats.mediaNewFiles == 2)                                        // same photo twice = one file
        #expect(try t.db.scalarInt("SELECT count(*) FROM media") == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 3)
        let rel = try #require(try t.db.scalarString("SELECT media_path FROM attachment WHERE mime = 'image/jpeg' LIMIT 1"))
        #expect(rel.hasPrefix("media/") && rel.hasSuffix(".jpg") && !rel.hasPrefix("/"))
        let stored = try Data(contentsOf: t.root.resolve(relativePath: rel))
        #expect(Array(stored) == photo)
        #expect(rel.contains(Hashing.sha256Hex(photo.withUnsafeBytes { $0 })))
        #expect(try t.db.scalarString("SELECT media_path FROM attachment WHERE mime = 'video/3gpp'")?.hasSuffix(".3gp") == true)
        // text part became the body; media-only message has no body
        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = 'mms:m:P1'") == "look")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'mms:m:P2' AND (body IS NULL OR body = '')") == 1)
    }

    @Test func surrogatePairEmojiReferencesInSMS() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let xml = Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: 1_530_000_000_000, type: 1, body: "party &#55357;&#56832; &#55356;&#57225; done")])
        try t.importXML(xml, name: "sms-e.xml")
        #expect(try t.db.scalarString("SELECT body FROM message") == "party \u{1F600} \u{1F389} done")
    }

    @Test func streamsLargeFileInTinyChunks() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        var items: [String] = []
        for i in 0..<300 { items.append(Fixtures.sms(address: Fixtures.alice, date: 1_540_000_000_000 + Int64(i) * 60_000, type: 1 + (i % 2), body: "msg \(i)")) }
        items.append(Fixtures.mms(address: Fixtures.alice, date: 1_541_000_000_000, box: 1, mID: "BIG", parts: [Fixtures.dataPart(Fixtures.blob(5, count: 300_000))], addrs: [(Fixtures.alice, 137), (Fixtures.me, 151)]))
        let rep = try t.importXML(Fixtures.file(items), name: "sms-big.xml", chunk: 512)
        #expect(rep.stats.smsParsed == 300 && rep.stats.mmsParsed == 1 && rep.stats.attachments == 1)
        #expect(try t.db.scalarInt("SELECT bytes FROM attachment") == 300_000)
    }

    @Test func duplicateAcrossTwoExports() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let photo = Fixtures.blob(3)
        let addrs: [(String, Int)] = [(Fixtures.alice, 137), (Fixtures.me, 151)]
        let shared: [String] = [
            Fixtures.sms(address: Fixtures.alice, date: 1_550_000_000_000, type: 1, body: "same text"),
            Fixtures.sms(address: Fixtures.alice, date: 1_550_000_050_000, type: 2, body: "reply"),
            Fixtures.mms(address: Fixtures.alice, date: 1_550_000_100_000, box: 1, mID: "DUP1", parts: [Fixtures.textPart("pic with key")], addrs: addrs),
            Fixtures.mms(address: Fixtures.alice, date: 1_550_000_200_000, box: 1, parts: [Fixtures.dataPart(photo)], addrs: addrs),       // media-only, no ids
        ]
        // First export has a unique message; second has the same four (slightly shifted clocks) plus a new one.
        let a = Fixtures.file(shared + [Fixtures.sms(address: Fixtures.alice, date: 1_550_000_300_000, type: 1, body: "only in A")])
        let shifted: [String] = [
            Fixtures.sms(address: Fixtures.alice, date: 1_550_000_001_500, type: 1, body: "same text"),     // +1.5 s: within 2 s
            Fixtures.sms(address: Fixtures.alice, date: 1_550_000_050_000, type: 2, body: "reply"),
            Fixtures.mms(address: Fixtures.alice, date: 1_550_000_900_000, box: 1, mID: "DUP1", parts: [Fixtures.textPart("pic with key")], addrs: addrs), // same key, different time
            Fixtures.mms(address: Fixtures.alice, date: 1_550_000_201_000, box: 1, parts: [Fixtures.dataPart(photo)], addrs: addrs),
            Fixtures.sms(address: Fixtures.alice, date: 1_550_000_400_000, type: 1, body: "only in B"),
        ]
        let ra = try t.importXML(a, name: "sms-A.xml")
        let rb = try t.importXML(Fixtures.file(shifted), name: "sms-B.xml")
        #expect(ra.stats.inserted == 5 && ra.stats.duplicates == 0)
        #expect(rb.stats.inserted == 1 && rb.stats.duplicates == 4)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 10)                    // nothing deleted
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 6)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message_fts_docsize") == 6)             // duplicates are not indexed
        // canonical is the earliest source for every group
        #expect(try t.db.scalarInt("SELECT count(*) FROM message m JOIN message c ON c.id = m.canonical_id WHERE m.source_id = 2 AND c.source_id = 1") == 4)
        // the photo is stored once even though two attachment rows reference it
        #expect(try t.db.scalarInt("SELECT count(*) FROM media") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 2)
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).passed)
    }

    @Test func identicalMessagesWithinOneExportAreNotDuplicates() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let one = Fixtures.sms(address: Fixtures.alice, date: 1_560_000_000_000, type: 1, body: "ok")
        let a = Fixtures.file([one, one])                 // two real "ok"s in the same second
        let b = Fixtures.file([one, one, Fixtures.sms(address: Fixtures.alice, date: 1_560_000_900_000, type: 1, body: "later")])
        try t.importXML(a, name: "sms-A.xml")
        let rb = try t.importXML(b, name: "sms-B.xml")
        #expect(rb.stats.duplicates == 2 && rb.stats.inserted == 1)                   // matched pairwise, not collapsed
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 3)
    }

    @Test func differentBodyOrDirectionIsNotADuplicate() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: 1_570_000_000_000, type: 1, body: "x")]), name: "sms-A.xml")
        let rb = try t.importXML(Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_570_000_000_000, type: 2, body: "x"),       // other direction
            Fixtures.sms(address: Fixtures.alice, date: 1_570_000_000_000, type: 1, body: "y"),       // other body
            Fixtures.sms(address: Fixtures.alice, date: 1_570_000_005_000, type: 1, body: "x"),       // 5 s apart
        ]), name: "sms-B.xml")
        #expect(rb.stats.duplicates == 0 && rb.stats.inserted == 3)
    }

    @Test func reimportIsIdempotent() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let xml = Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_580_000_000_000, type: 1, body: "once"),
            Fixtures.mms(address: Fixtures.alice, date: 1_580_000_100_000, box: 1, mID: "I1", parts: [Fixtures.dataPart(Fixtures.blob(7))], addrs: [(Fixtures.alice, 137), (Fixtures.me, 151)]),
        ])
        let first = try t.importXML(xml, name: "sms-I.xml")
        let again = try t.importXML(xml, name: "sms-copy-of-I.xml")     // same bytes under another name
        #expect(first.status == .imported && again.status == .alreadyImported)
        #expect(again.sourceID == first.sourceID && again.stats == first.stats)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM source") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 1)
    }

    @Test func failedImportLeavesNoPartialRows() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        var xml = Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: 1_590_000_000_000, type: 1, body: "will roll back")])
        xml = String(xml.dropLast(40)) + "<sms address=\"unterminated"           // truncated file
        #expect(throws: (any Error).self) { try t.importXML(xml, name: "sms-bad.xml") }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM source") == 0)
    }

    @Test func invalidRowsAreCountedNotInserted() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let bad = "  <sms address=\"\(Fixtures.alice)\" date=\"notanumber\" type=\"1\" body=\"x\" />\n"
        let rep = try t.importXML(Fixtures.file([bad, Fixtures.sms(address: Fixtures.alice, date: 1_600_000_000_000, type: 1, body: "good")]), name: "sms-v.xml")
        #expect(rep.stats.smsParsed == 2 && rep.stats.skippedInvalid == 1 && rep.stats.inserted == 1)
    }
}

// MARK: writer rules, stats, verify, relocation

@Suite struct ArchiveTests {
    @Test func iPhoneRowOutranksAndroidCopyRegardlessOfImportOrder() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: 1_610_000_000_000, type: 1, body: "flattened imessage")]), name: "sms-A.xml")
        try t.db.transaction {
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-backup', 'x', 'iosfake', 0, 0)")
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "ios-backup")
            let out = try w.add(MessageRecord(participants: [Fixtures.alice], sender: Fixtures.alice, tsMs: 1_610_000_000_800, isFromMe: false,
                                              service: "imessage", body: "flattened imessage"))
            #expect(out == .duplicate)
        }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 2)
        #expect(try t.db.scalarString("SELECT service FROM message WHERE canonical_id IS NULL") == "imessage")   // iPhone row won
        #expect(try t.db.scalarString("SELECT service FROM message WHERE canonical_id IS NOT NULL") == "sms")
        // Only the canonical copy is searchable: the demoted Android row left the index when the iPhone row took over.
        #expect(try t.db.scalarInt("SELECT count(*) FROM message_fts_docsize") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message_fts JOIN message m ON m.id = message_fts.rowid WHERE message_fts MATCH 'flattened' AND m.service = 'imessage'") == 1)
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).passed)
    }

    /// Late-2016 Android copies of iMessages lost their emoji; they must still fold under the iPhone row.
    @Test func emojiStrippedAndroidCopyFoldsUnderIPhoneRow() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_480_000_000_000, type: 1, body: "see you soon "),
            Fixtures.sms(address: Fixtures.alice, date: 1_480_000_100_000, type: 2, body: ""),                  // an emoji-only message, emptied
            Fixtures.sms(address: Fixtures.alice, date: 1_480_000_200_000, type: 1, body: "unrelated"),
        ]), name: "sms-A.xml")
        try t.db.transaction {
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-backup', 'x', 'iosfake', 0, 0)")
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "ios-backup")
            #expect(try w.add(MessageRecord(participants: [Fixtures.alice], sender: Fixtures.alice, tsMs: 1_480_000_000_400, isFromMe: false,
                                            service: "imessage", body: "see you soon \u{1F60E}")) == .duplicate)
            #expect(try w.add(MessageRecord(participants: [Fixtures.alice], sender: nil, tsMs: 1_480_000_100_300, isFromMe: true,
                                            service: "imessage", body: "\u{1F44D}\u{1F3FD}")) == .duplicate)
            // different words are still different messages
            #expect(try w.add(MessageRecord(participants: [Fixtures.alice], sender: Fixtures.alice, tsMs: 1_480_000_200_100, isFromMe: false,
                                            service: "imessage", body: "something else \u{1F60E}")) == .inserted)
        }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 4)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message c WHERE c.canonical_id IS NULL AND c.service = 'imessage' AND EXISTS (SELECT 1 FROM message d WHERE d.canonical_id = c.id)") == 2)
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).passed)
    }

    @Test func relinkFoldsEmojiStrippedCopiesAlreadyStored() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_480_000_000_000, type: 1, body: "see you soon"),
            Fixtures.sms(address: Fixtures.alice, date: 1_480_000_100_000, type: 2, body: ""),
        ]), name: "sms-A.xml")
        try t.db.transaction {
            // an iPhone import by a build that predates the emoji rule: the rows sit side by side, unlinked
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('ios-backup', 'x', 'iosfake', 0, 0)")
            let sid = try t.db.lastInsertRowID
            let thread = try t.db.scalarInt("SELECT thread_id FROM message LIMIT 1")
            for (ts, fromMe, body) in [(1_480_000_000_300, 0, "see you soon \u{1F60E}"), (1_480_000_100_200, 1, "\u{1F44D}")] as [(Int, Int, String)] {
                let st = try t.db.prepare("INSERT INTO message(thread_id, ts_ms, is_from_me, service, body, source_id, content_hash) VALUES (?,?,?,'imessage',?,?,?)")
                st.bind(1, thread).bind(2, ts).bind(3, fromMe).bind(4, body).bind(5, sid).bind(6, Hashing.fnv1a(Hashing.normalizedBody(body)))
                try st.run()
            }
        }
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 4)
        let r = try Reconciler.relinkEmojiStrippedCopies(db: t.db)
        #expect(r.linked == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message_fts_docsize") == 2)
        #expect(try Reconciler.relinkEmojiStrippedCopies(db: t.db).linked == 0)                          // idempotent
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).passed)
    }

    @Test func statsCountBySourceYearAndService() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_483_300_000_000, type: 1, body: "y2017"),   // 2017-01
            Fixtures.sms(address: Fixtures.alice, date: 1_546_400_000_000, type: 2, body: "y2019"),   // 2019-01
            Fixtures.mms(address: Fixtures.alice, date: 1_546_500_000_000, box: 1, mID: "S1", parts: [Fixtures.dataPart(Fixtures.blob(8, count: 100))], addrs: [(Fixtures.alice, 137)]),
        ]), name: "sms-S.xml")
        let s = try ArchiveStats.collect(db: t.db)
        #expect(s.sources.count == 1 && s.canonicalRows == 3 && s.totalRows == 3)
        #expect(s.byYear.map { "\($0.0):\($0.1)" } == ["2017:1", "2019:2"])
        #expect(Dictionary(uniqueKeysWithValues: s.byService) == ["sms": 2, "mms": 1])
        #expect(s.threads == 1 && s.mediaFiles == 1 && s.mediaBytes == 100)
    }

    @Test func verifyCatchesMissingMediaAndStaysFalsePositiveFree() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([
            Fixtures.mms(address: Fixtures.alice, date: 1_620_000_000_000, box: 1, mID: "V1", parts: [Fixtures.dataPart(Fixtures.blob(4))], addrs: [(Fixtures.alice, 137)]),
        ]), name: "sms-V.xml")
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).passed)
        let rel = try #require(try t.db.scalarString("SELECT path FROM media"))
        try FileManager.default.removeItem(at: t.root.resolve(relativePath: rel))
        let r = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(!r.passed && r.lines.contains { $0.hasPrefix("FAIL") && $0.contains("missing") })
    }

    @Test func orphanMediaFileIsReportedNotFatal() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let dir = t.root.mediaURL.appendingPathComponent("ab")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("abstray.jpg"))
        let r = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(r.passed && r.lines.contains { $0.hasPrefix("note") && $0.contains("1 media file") })
    }

    @Test func archiveFolderIsRelocatable() throws {
        // Copy the whole root elsewhere, open it there unchanged.
        let t = try TestArchive(); defer { t.cleanup() }
        let photo = Fixtures.blob(6, count: 777)
        try t.importXML(Fixtures.file([
            Fixtures.sms(address: Fixtures.alice, date: 1_630_000_000_000, type: 1, body: "movable words"),
            Fixtures.mms(address: Fixtures.alice, date: 1_630_000_100_000, box: 1, mID: "R1", parts: [Fixtures.dataPart(photo)], addrs: [(Fixtures.alice, 137)]),
        ]), name: "sms-R.xml")
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let elsewhere = ArchiveRoot(url: t.dir.appendingPathComponent("moved/Message Archive"))
        try FileManager.default.createDirectory(at: elsewhere.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.root.url, to: elsewhere.url)
        let moved = try Schema.openArchive(root: elsewhere)
        #expect(try ArchiveVerifier.run(db: moved, root: elsewhere).passed)
        let rel = try #require(try moved.scalarString("SELECT media_path FROM attachment"))
        #expect(Array(try Data(contentsOf: elsewhere.resolve(relativePath: rel))) == photo)
        #expect(try moved.scalarInt("SELECT count(*) FROM message_fts WHERE message_fts MATCH 'movable'") == 1)
        // and a source file the importer already saw is still recognized there
        let f = t.dir.appendingPathComponent("sms-R.xml")
        #expect(try AndroidSMSImporter.importFile(at: f, into: moved, root: elsewhere).status == .alreadyImported)
        // no stored string anywhere mentions the original location
        #expect(try moved.scalarInt("SELECT count(*) FROM attachment WHERE media_path LIKE '%' || '\(t.dir.lastPathComponent)' || '%'") == 0)
        #expect(try moved.scalarInt("SELECT count(*) FROM media WHERE path LIKE '/%'") == 0)
    }

    @Test func networkVolumeDetectionFallsBackGracefully() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        #expect(t.root.isOnNetworkVolume == false)     // local temp dir; the SMB path switches to journal_mode=DELETE
    }
}
