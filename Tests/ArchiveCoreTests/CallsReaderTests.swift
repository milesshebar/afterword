import Testing
import Foundation
@testable import ArchiveCore

/// The read side of the `call` table: a call line in each thread at its time and a per-person count,
/// for the Mac app and the web app. Synthetic data only.
@Suite struct CallsReaderTests {
    static let alice = "+12125550111", bob = "+12125550122"
    static let t0: Int64 = 1_600_000_000_000

    /// Alice: 10 SMS a minute apart from t0 and a group with Bob; Bob: one SMS. Calls (canonical unless said):
    ///   1 Alice phone, answered out 125 s, between messages 2 and 3
    ///   2 Alice FaceTime video, missed in, before her first message, stored with no handle (her number reached the archive later)
    ///   3 the same call as 1 from an older log (canonical_id = 1): never shown, never counted
    ///   4 Alice Messenger call, a message line already (message_id set): counted, not shown
    ///   5 Alice phone, at exactly the time of message 6
    ///   6 Bob WhatsApp, answered in, after everything
    ///   7 an unknown number: nobody's
    static func archive() throws -> (TestArchive, aliceThread: Int64, group: Int64) {
        let t = try TestArchive()
        try t.db.transaction {
            try t.db.exec("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('test', 'x', 'seed', 0, 0)")
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "test")
            for i in 0..<10 {
                _ = try w.add(MessageRecord(participants: [alice], sender: i % 2 == 0 ? alice : nil, tsMs: t0 + Int64(i) * 60_000, isFromMe: i % 2 == 1,
                                            service: "sms", body: "m\(i)"))
            }
            _ = try w.add(MessageRecord(participants: [bob], sender: bob, tsMs: t0 + 5_000, isFromMe: false, service: "sms", body: "bob"))
            _ = try w.add(MessageRecord(participants: [alice, bob], sender: bob, tsMs: t0 + 7_000, isFromMe: false, service: "sms", body: "group"))
        }
        try CallImporter.ensureTables(t.db)
        let aliceH = try t.db.scalarInt("SELECT id FROM handle WHERE normalized = '\(alice)'")
        let bobH = try t.db.scalarInt("SELECT id FROM handle WHERE normalized = '\(bob)'")
        let aliceThread = try t.db.scalarInt("SELECT t.id FROM thread t JOIN thread_member tm ON tm.thread_id = t.id WHERE t.is_group = 0 AND tm.handle_id = \(aliceH)")
        let group = try t.db.scalarInt("SELECT id FROM thread WHERE is_group = 1")
        let msg = try t.db.scalarInt("SELECT id FROM message WHERE body = 'm4'")
        try t.db.exec("""
            INSERT INTO call(id, source_id, source_label, handle_id, thread_id, message_id, address, ts_ms, duration_s, direction, outcome, service, dkey, canonical_id) VALUES
              (1, 1, 'phone-2026', \(aliceH), \(aliceThread), NULL, '\(alice)', \(t0 + 150_000), 125, 'out', 'answered', 'phone', 'a', NULL),
              (2, 1, 'mac', NULL, NULL, NULL, '\(alice)', \(t0 - 3_600_000), 0, 'in', 'missed', 'facetime-video', 'b', NULL),
              (3, 1, 'phone-2024', \(aliceH), \(aliceThread), NULL, '\(alice)', \(t0 + 150_000), 125, 'out', 'answered', 'phone', 'c', 1),
              (4, 1, 'messenger', \(aliceH), \(aliceThread), \(msg), 'Alice A', \(t0 + 240_000), 600, 'out', 'answered', 'messenger', 'd', NULL),
              (5, 1, 'phone-2026', \(aliceH), \(aliceThread), NULL, '\(alice)', \(t0 + 300_000), 0, 'out', 'cancelled', 'phone', 'e', NULL),
              (6, 1, 'whatsapp-app', \(bobH), NULL, NULL, '\(bob)', \(t0 + 86_400_000), 3_700, 'in', 'answered', 'whatsapp', 'f', NULL),
              (7, 1, 'phone-2026', NULL, NULL, NULL, '+12125550199', \(t0), 30, 'in', 'answered', 'phone', 'g', NULL)
            """)
        return (t, aliceThread, group)
    }

    @Test func labelsReadLikeACallLog() {
        func row(_ dir: String, _ outcome: String, _ service: String, _ s: Int64 = 0) -> String {
            CallRow(id: 1, tsMs: 0, durationS: s, direction: dir, outcome: outcome, service: service, sourceLabel: "x").label
        }
        #expect(row("out", "answered", "phone", 125) == "Outgoing phone call · 2 min")
        #expect(row("in", "answered", "facetime-video", 3_900) == "Incoming FaceTime video call · 1 h 5 min")
        #expect(row("in", "answered", "whatsapp", 45) == "Incoming WhatsApp call · 45 s")
        #expect(row("in", "answered", "phone") == "Incoming phone call")
        #expect(row("in", "missed", "facetime-audio") == "Missed FaceTime audio call")
        #expect(row("out", "missed", "phone") == "Outgoing phone call, no answer")
        #expect(row("out", "cancelled", "phone") == "Cancelled phone call")
        #expect(row("in", "cancelled", "phone") == "Missed phone call")
        #expect(row("in", "voicemail", "phone") == "Missed phone call (voicemail)")
        #expect(row("in", "declined", "skype") == "Declined Skype call")
        #expect(row("in", "blocked", "phone") == "Blocked phone call")
        #expect(row("in", "answered", "something-new") == "Incoming call")
        var c = CallCount(); #expect(c.summary == nil)
        c.calls = 1; c.seconds = 59; #expect(c.summary == "1 call")
        c.calls = 12; c.seconds = 3_600 * 14; #expect(c.summary == "12 calls · 14 h talked")
        c.seconds = 3_600 * 317 + 16 * 60; #expect(c.summary == "12 calls · 317 h talked")
        c.seconds = 3_900; #expect(c.summary == "12 calls · 1 h 5 min talked")
    }

    @Test func aThreadShowsItsCallsOnceEachAtTheirTime() throws {
        let (t, aliceThread, group) = try Self.archive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        let scope = MessageScope(thread: aliceThread)
        // canonical, not a message line already, by handle or (stored without one) by number; oldest first
        #expect(try r.calls(scope: scope, in: .all).map(\.id) == [2, 1, 5])
        #expect(try r.calls(scope: MessageScope(thread: group), in: .all).isEmpty)              // a group has no call lines
        // a span: closed sides at the window's first and last message, open where it reached an end of the conversation
        #expect(try r.calls(scope: scope, in: CallSpan(lower: Self.t0, upper: Self.t0 + 300_000)).map(\.id) == [1, 5])
        #expect(try r.calls(scope: scope, in: CallSpan(lower: Self.t0, upper: Self.t0 + 300_000, upperInclusive: false)).map(\.id) == [1])
        #expect(try r.calls(scope: scope, in: CallSpan(lower: Self.t0 + 300_000, lowerInclusive: false, upper: nil)).isEmpty)
        #expect(try r.calls(scope: scope, in: CallSpan(lower: nil, upper: Self.t0)).map(\.id) == [2])
        // the limit keeps the calls nearest the window
        #expect(try r.calls(scope: scope, in: CallSpan(lower: nil, upper: Self.t0 + 400_000), limit: 1).map(\.id) == [5])
        #expect(try r.calls(scope: scope, in: CallSpan(lower: Self.t0 - 7_200_000, upper: nil), limit: 1).map(\.id) == [2])
        // a service filter: phone calls go with SMS, FaceTime with iMessage, a Messenger-only view has none
        #expect(try r.calls(scope: MessageScope(threads: [aliceThread], services: [.sms]), in: .all).map(\.id) == [1, 5])
        #expect(try r.calls(scope: MessageScope(threads: [aliceThread], services: [.imessage]), in: .all).map(\.id) == [2])
        #expect(try r.calls(scope: MessageScope(threads: [aliceThread], services: [.messenger]), in: .all).isEmpty)
        #expect(CallSpan.window(firstTs: 5, lastTs: 9, reachedStart: true, reachedEnd: false) == CallSpan(lower: nil, upper: 9))
        #expect(CallSpan.window(firstTs: nil, lastTs: nil, reachedStart: false, reachedEnd: false) == .all)
    }

    @Test func countsArePerHandleAndIncludeMessageLineCalls() throws {
        let (t, aliceThread, group) = try Self.archive(); defer { t.cleanup() }
        let r = try ArchiveReader(root: t.root)
        let aliceH = try t.db.scalarInt("SELECT id FROM handle WHERE normalized = '\(Self.alice)'")
        let byHandle = try r.callCountsByHandle()
        #expect(byHandle[aliceH]?.calls == 4 && byHandle[aliceH]?.answered == 2 && byHandle[aliceH]?.seconds == 725)   // the duplicate is not counted
        #expect(byHandle.values.map(\.calls).reduce(0, +) == 5)                                                        // the unknown number is nobody's
        #expect(try r.callCount(scope: MessageScope(thread: aliceThread)).calls == 4)
        #expect(try r.callCount(scope: MessageScope(thread: group)).calls == 0)
        let empty = try TestArchive(); defer { empty.cleanup() }
        let e = try ArchiveReader(root: empty.root)
        #expect(try !e.hasCalls() && e.callCountsByHandle().isEmpty && e.calls(scope: MessageScope(thread: 1), in: .all).isEmpty)
    }

    @Test func webPagesTileTheCallsAndThePeopleCarryCounts() throws {
        let (t, _, _) = try Self.archive(); defer { t.cleanup() }
        _ = try PeopleStore.rematch(db: t.db)
        let service = try WebService(root: t.root)
        let people = try service.people().people
        let alice = try #require(people.first { $0.threads.count == 1 && $0.messages == 10 })
        let bob = try #require(people.first { $0.messages == 1 })
        #expect(alice.calls == 4 && bob.calls == 1)
        let detail = try service.person(alice.id)
        #expect(detail.calls == 4 && detail.callSeconds == 725)
        let scope = try service.scope(person: alice.id, thread: nil, services: nil)
        // newest page, then older pages to the start: every call exactly once
        var seen: [Int64] = []
        var page = try service.latest(scope: scope, limit: 3)
        seen += page.calls?.map(\.id) ?? []
        while let first = page.messages.first {
            page = try service.before(scope: scope, key: MessageKey(tsMs: first.ts, id: first.id), limit: 3)
            seen += page.calls?.map(\.id) ?? []
            if page.messages.count < 3 { break }
        }
        #expect(seen.sorted() == [1, 2, 5])
        // from the oldest message forward, and around a message in the middle: the same calls, once each
        let oldest = try service.around(scope: scope, message: nil, atOrAfter: 0, side: 2)
        seen = oldest.calls?.map(\.id) ?? []
        var last = try #require(oldest.messages.last)
        while true {
            let p = try service.after(scope: scope, key: MessageKey(tsMs: last.ts, id: last.id), limit: 3)
            seen += p.calls?.map(\.id) ?? []
            guard p.messages.count == 3, let l = p.messages.last else { break }
            last = l
        }
        #expect(seen.sorted() == [1, 2, 5])
        let mid = try service.around(scope: scope, message: nil, atOrAfter: Self.t0 + 300_000, side: 2)
        #expect(mid.calls?.map(\.id) == [5])                       // the window m3...m7 holds only the call at m5's time
        let line = try #require(mid.calls?.first)
        #expect(line.label == "Cancelled phone call" && line.me && line.service == "sms" && line.kind == "phone")
        // a filtered view: FaceTime only with iMessage
        let ft = try service.latest(scope: try service.scope(person: alice.id, thread: nil, services: [.imessage]), limit: 3)
        #expect(ft.messages.isEmpty && ft.calls?.map(\.id) == [2])
        // JSON: the people list leaves the count out when there is none
        let json = String(decoding: try JSONEncoder().encode(service.people()), as: UTF8.self)
        #expect(json.contains("\"calls\":4"))
    }
}
