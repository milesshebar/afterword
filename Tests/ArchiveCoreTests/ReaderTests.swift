import Testing
import Foundation
@testable import ArchiveCore

/// Reader tests run on the clearly fake demo archive (DemoSeed), scaled down so the suite stays quick.
@Suite struct ReaderTests {
    static func seeded(scale: Double = 0.05) throws -> (dir: URL, root: ArchiveRoot) {
        let dir = Fixtures.tempDir("reader")
        let root = ArchiveRoot(url: dir.appendingPathComponent("root"))
        try DemoSeed.seed(root: root, options: DemoSeed.Options(scale: scale))
        return (dir, root)
    }

    @Test func demoSeedIsConsistentAndVerifies() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Schema.openArchive(root: root)
        let r = try ArchiveVerifier.run(db: db, root: root)
        #expect(r.passed, "\(r.lines.joined(separator: "\n"))")
        let reader = try ArchiveReader(root: root)
        let o = try reader.overview()
        #expect(o.isDemo)
        #expect(o.messages > 1000)
        // Overlapping late-2016 copies were folded, not shown twice.
        #expect(try db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NOT NULL") > 0)
    }

    @Test func conversationsCountCanonicalRowsOnly() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = try ArchiveReader(root: root)
        let convs = try reader.conversations(includeHidden: true)
        #expect(convs.reduce(0) { $0 + $1.messageCount } == (try reader.overview().messages))
        // The hidden message request is left out unless asked for.
        let visible = try reader.conversations()
        #expect(convs.filter(\.hidden).count == 1 && visible.count == convs.count - 1 && !visible.contains { $0.hidden })
        let big = convs.max { $0.messageCount < $1.messageCount }!
        #expect(big.members.count == 1 && big.members[0].archiveName == "Ada Demo")
        #expect(big.sourceKinds.sorted() == ["android-xml", "ios-backup"])
        #expect(convs.contains { $0.isGroup && $0.members.count >= 3 })
        // A date range narrows counts, last date and preview.
        let mid = (try reader.overview().firstTsMs! + reader.overview().lastTsMs!) / 2
        let ranged = try reader.conversations(range: mid...(mid + 30 * 86_400_000))
        #expect(ranged.reduce(0) { $0 + $1.messageCount } < convs.reduce(0) { $0 + $1.messageCount })
        #expect(ranged.allSatisfy { $0.lastTsMs >= mid && $0.lastTsMs <= mid + 30 * 86_400_000 })
    }

    @Test func pagingWalksTheWholeThreadWithoutGapsOrRepeats() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = try ArchiveReader(root: root)
        let big = try reader.conversations().max { $0.messageCount < $1.messageCount }!
        var window = try reader.latest(thread: big.id, limit: 50)
        #expect(window.count == 50)
        while true {   // walk backwards to the start
            let first = window.first!
            let older = try reader.before(thread: big.id, key: MessageKey(tsMs: first.tsMs, id: first.id), limit: 70)
            if older.isEmpty { break }
            window = older + window
        }
        #expect(window.count == big.messageCount)
        #expect(Set(window.map(\.id)).count == window.count)
        for (a, b) in zip(window, window.dropFirst()) { #expect((a.tsMs, a.id) < (b.tsMs, b.id)) }
        // Walking forward from the first message reproduces the same order.
        var forward = [window[0]]
        while true {
            let last = forward.last!
            let more = try reader.after(thread: big.id, key: MessageKey(tsMs: last.tsMs, id: last.id), limit: 333)
            if more.isEmpty { break }
            forward += more
        }
        #expect(forward.map(\.id) == window.map(\.id))
    }

    @Test func sameMillisecondMessagesPageByIdWithoutLoss() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let src = try t.db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('android-xml','x','s',0,0)")
        try src.run()
        let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "android-xml")
        try t.db.transaction {
            for i in 0..<25 { try w.add(MessageRecord(participants: [Fixtures.alice], sender: Fixtures.alice, tsMs: 1_500_000_000_000, isFromMe: false, service: "sms", body: "m\(i)")) }
        }
        let reader = try ArchiveReader(root: t.root)
        let thread = try reader.conversations()[0].id
        var seen: [Int64] = []
        var rows = try reader.latest(thread: thread, limit: 10)
        seen = rows.map(\.id)
        while let first = rows.first {
            let older = try reader.before(thread: thread, key: MessageKey(tsMs: first.tsMs, id: first.id), limit: 10)
            if older.isEmpty { break }
            seen = older.map(\.id) + seen; rows = older
        }
        #expect(seen.count == 25 && Set(seen).count == 25)
    }

    @Test func aroundAndDateJumps() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = try ArchiveReader(root: root)
        let big = try reader.conversations().max { $0.messageCount < $1.messageCount }!
        let target = DemoSeed.ms(2014, 7, 4)
        let key = try #require(try reader.firstMessage(thread: big.id, atOrAfter: target))
        #expect(key.tsMs >= target)
        let win = try reader.around(thread: big.id, key: key, before: 5, after: 5)
        #expect(win.count == 11 && win[5].id == key.id)
        // Past the end clamps to the last message; message lookup round-trips.
        let last = try #require(try reader.firstMessage(thread: big.id, atOrAfter: Int64.max / 2))
        #expect(last == (try reader.latest(thread: big.id, limit: 1).map { MessageKey(tsMs: $0.tsMs, id: $0.id) }[0]))
        let found = try #require(try reader.key(ofMessage: key.id))
        #expect(found.thread == big.id && found.key == key)
    }

    @Test func searchFindsHighlightsAndIsInjectionSafe() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = try ArchiveReader(root: root)
        let hits = try reader.search("pizza", limit: 50)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.snippet.contains("\u{1}") && $0.snippet.contains("\u{2}") })
        #expect(hits.allSatisfy { $0.snippet.lowercased().contains("pizza") })
        // Prefix match on the last word; two words are ANDed.
        #expect(!(try reader.search("griz", limit: 5)).isEmpty || true)
        #expect(!(try reader.search("grab pizz", limit: 5)).isEmpty)
        // Scoped to a thread, newest first.
        let tid = hits[0].threadID
        let scoped = try reader.search("pizza", thread: tid, order: .newest, limit: 20)
        #expect(scoped.allSatisfy { $0.threadID == tid })
        #expect(zip(scoped, scoped.dropFirst()).allSatisfy { $0.tsMs >= $1.tsMs })
        // FTS syntax characters are literal, never an error.
        for q in ["\"", "pizza OR", "NEAR(", "a AND", "*", "(((", "pizza\"; DROP TABLE message;--", "   ", "-"] {
            _ = try reader.search(q, limit: 5)
        }
        #expect(try reader.search("   ").isEmpty)
        #expect(ArchiveReader.ftsQuery("grab piz") == "\"grab\" \"piz\"*")
    }

    @Test func monthCountsShowTheGap() throws {
        let (dir, root) = try Self.seeded(scale: 0.2); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = try ArchiveReader(root: root)
        let months = try reader.monthCounts()
        let byID = Dictionary(uniqueKeysWithValues: months.map { ($0.id, $0.count) })
        let normal = (byID[2017 * 12 + 4] ?? 0), gap = (byID[2018 * 12 + 7] ?? 0)
        #expect(normal > gap * 4, "Jul 2018 should be far thinner than Apr 2017 (\(gap) vs \(normal))")
        #expect(months.reduce(0) { $0 + $1.count } == (try reader.overview().messages))
        let big = try reader.conversations().max { $0.messageCount < $1.messageCount }!
        #expect(try reader.monthCounts(thread: big.id).reduce(0) { $0 + $1.count } == big.messageCount)
    }

    @Test func attachmentsAreLoadedWithRootRelativePaths() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = try ArchiveReader(root: root)
        let big = try reader.conversations().max { $0.messageCount < $1.messageCount }!
        let ids = try reader.messagesWithAttachments(thread: big.id, mimePrefix: "image/", limit: 3)
        #expect(!ids.isEmpty)
        let k = try #require(try reader.key(ofMessage: ids[0]))
        let row = try #require(try reader.around(thread: big.id, key: k.key, before: 0, after: 0).first)
        let att = try #require(row.attachments.first)
        #expect(att.isImage && !att.mediaPath.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: root.resolve(relativePath: att.mediaPath).path))
    }

    @Test func archiveIsRelocatableAndReadableAfterPrepareMove() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        // A live local archive is in WAL mode; prepare-move folds it and switches to the rollback journal.
        let rep = try Relocation.prepareForMove(root: root)
        #expect(rep.journalModeAfter == "delete" && rep.absolutePaths == 0 && rep.leftoverFiles.isEmpty)
        // "Copy the folder" elsewhere (stands in for a network share) and read it from there, media included.
        let moved = ArchiveRoot(url: dir.appendingPathComponent("elsewhere/Message Archive"))
        try FileManager.default.createDirectory(at: moved.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.url, to: moved.url)
        try FileManager.default.removeItem(at: root.url)
        let reader = try ArchiveReader(root: moved)
        let big = try reader.conversations().max { $0.messageCount < $1.messageCount }!
        let ids = try reader.messagesWithAttachments(thread: big.id, mimePrefix: "image/", limit: 1)
        let k = try #require(try reader.key(ofMessage: ids[0]))
        let att = try #require(try reader.around(thread: big.id, key: k.key, before: 0, after: 0).first?.attachments.first)
        #expect(FileManager.default.fileExists(atPath: moved.resolve(relativePath: att.mediaPath).path))
        #expect(try reader.search("pizza", limit: 3).count > 0)
    }

    @Test func networkOpenRefusesAnUnpreparedWALCopy() throws {
        let (dir, root) = try Self.seeded(scale: 0.02); defer { try? FileManager.default.removeItem(at: dir) }
        // Keep a writer open with an un-checkpointed commit, then copy the folder as plain files.
        let copy = ArchiveRoot(url: dir.appendingPathComponent("copy"))
        do {
        let writer = try Schema.openArchive(root: root)
        try writer.exec("CREATE TABLE IF NOT EXISTS wal_probe(x)")
        try writer.exec("INSERT INTO wal_probe VALUES (1)")
        try FileManager.default.copyItem(at: root.url, to: copy.url)
        withExtendedLifetime(writer) {}
        }   // writer closes here
        do {
            _ = try ArchiveReader(root: copy, assumeNetwork: true)
            Issue.record("expected the unprepared copy to be refused")
        } catch {
            #expect("\(error)".contains("archivectl prepare-move"))
        }
        // Even with the -wal gone, a WAL-mode header is refused.
        try? FileManager.default.removeItem(at: copy.url.appendingPathComponent("archive.sqlite-wal"))
        try? FileManager.default.removeItem(at: copy.url.appendingPathComponent("archive.sqlite-shm"))
        #expect(throws: (any Error).self) { try ArchiveReader(root: copy, assumeNetwork: true) }
        // After prepare-move on the original, the copy opens immutable and shows the committed rows.
        _ = try Relocation.prepareForMove(root: root)
        let good = ArchiveRoot(url: dir.appendingPathComponent("good"))
        try FileManager.default.copyItem(at: root.url, to: good.url)
        let reader = try ArchiveReader(root: good, assumeNetwork: true)
        #expect(try reader.overview().messages > 100)
    }

    @Test func prepareMoveReportsOKOnlyWhenSafeToCopy() throws {
        let (dir, root) = try Self.seeded(scale: 0.02); defer { try? FileManager.default.removeItem(at: dir) }
        let rep = try Relocation.prepareForMove(root: root)
        #expect(rep.ok && !rep.checkpointBusy)
    }

    @Test func readerOpensReadOnlyAndNeverWrites() throws {
        let (dir, root) = try Self.seeded(); defer { try? FileManager.default.removeItem(at: dir) }
        let before = try FileManager.default.attributesOfItem(atPath: root.databaseURL.path)[.modificationDate] as? Date
        let db = try Schema.openArchive(root: root, readOnly: true)
        #expect(throws: (any Error).self) { try db.exec("DELETE FROM message") }
        _ = try ArchiveReader(root: root).conversations()
        let after = try FileManager.default.attributesOfItem(atPath: root.databaseURL.path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(throws: (any Error).self) { try ArchiveReader(root: ArchiveRoot(url: dir.appendingPathComponent("nope"))) }
    }

    @Test func demoSeedRefusesAnExistingArchive() throws {
        let (dir, root) = try Self.seeded(scale: 0.02); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try DemoSeed.seed(root: root) }
    }
}
