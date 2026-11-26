import Testing
import Foundation
@testable import ArchiveCore

// Stage B: the person layer. Synthetic archives only (invented names, 555-01xx numbers).

private let day: Int64 = 86_400_000
private let t0 = MetaFixtures.ms("2015-01-01T00:00:00Z")

/// Builds a synthetic archive thread by thread.
final class PeopleBuilder {
    let t: TestArchive
    private var n = 0
    init(_ t: TestArchive) { self.t = t }

    func writer(_ kind: String = "android-xml") throws -> ArchiveWriter {
        n += 1
        let ins = try t.db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES (?, ?, ?, 0, 0)")
        ins.bind(1, kind).bind(2, "synthetic-\(n)").bind(3, "sha-\(n)-\(kind)")
        try ins.run()
        return try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: kind)
    }

    /// A phone/iMessage thread: `count` messages from `start`, `step` ms apart, alternating direction and cycling `services`.
    func phone(_ number: String, name: String?, count: Int, start: Int64 = t0, step: Int64 = day, services: [String] = ["imessage", "sms"],
               origin: String = ContactOrigin.androidXML, priority: Int = ContactPriority.androidXML, tag: String = "p") throws {
        let w = try writer()
        try t.db.transaction {
            for i in 0..<count {
                let mine = i % 2 == 1
                try w.add(MessageRecord(participants: [number], sender: mine ? nil : number, tsMs: start + Int64(i) * step, isFromMe: mine,
                                        service: services[i % services.count], body: "\(tag) \(number.suffix(4)) m\(i)"))
            }
            if let name { try w.noteName(forRaw: number, name: name, origin: origin, priority: priority) }
        }
    }

    /// A Messenger or Instagram thread.
    func meta(_ service: MetaService, name: String, count: Int, start: Int64 = t0, step: Int64 = day, origin: String = "inbox",
              username: String? = nil, possibleUsername: String? = nil, tag: String = "m") throws {
        let w = try writer(service.sourceKind)
        let h = service == .messenger ? ServiceHandle.facebook(name: name) : ServiceHandle.instagram(name: name)
        try t.db.transaction {
            for i in 0..<count {
                let mine = i % 2 == 1
                var r = MessageRecord(participants: [], sender: nil, tsMs: start + Int64(i) * step, isFromMe: mine, service: service.rawValue,
                                      body: "\(tag) \(name.prefix(3)) m\(i)")
                r.participantHandles = [h]
                r.senderHandle = mine ? nil : h
                try w.add(r)
            }
            try w.noteName(service: h, name: name, origin: service.nameOrigin, priority: 10)
            // an inferred real username, as `archivectl ig-usernames` stores it: high shows as @user, low as "possible @user"
            if let u = username ?? possibleUsername {
                let ins = try t.db.prepare("INSERT OR REPLACE INTO handle_username(handle_id, username, confidence, method) VALUES (?,?,?,?)")
                ins.bind(1, try w.handleID(service: h)).bind(2, u).bind(3, username != nil ? "high" : "low").bind(4, "test")
                try ins.run()
            }
            let up = try t.db.prepare("UPDATE thread SET service = ?, origin = ?, hidden = ? WHERE key = ?")
            up.bind(1, service.rawValue).bind(2, origin).bind(3, origin == "filtered" || origin == "requests").bind(4, h.normalized)
            try up.run()
        }
    }

    func index(_ overrides: OverrideSet = OverrideSet()) throws -> PeopleIndex {
        try ArchiveReader(root: t.root).people(overrides: overrides)
    }
}

private func personNamed(_ index: PeopleIndex, _ name: String) -> Person? {
    index.persons.values.first { $0.name == name }
}

@Suite struct NameMatchingTests {
    @Test func foldingIgnoresCaseDiacriticsPunctuationAndSpacing() {
        #expect(NameMatching.fold("José  García") == NameMatching.fold("jose garcia"))
        #expect(NameMatching.fold("José García") == NameMatching.fold("JOSE\u{0301} GARCI\u{0301}A"))        // composed vs decomposed
        #expect(NameMatching.fold("Sinéad O\u{2019}Connor") == "sinead oconnor")
        #expect(NameMatching.fold("Anne-Marie  Smith Jr.") == "anne marie smith jr")
        #expect(NameMatching.fold("Alice Demo \u{1F338}") == "alice demo")
        #expect(NameMatching.fold("Ｆｕｌｌ Ｗｉｄｔｈ") == "full width")
    }

    @Test func onlyWholeFullNamesAreMatchable() {
        #expect(NameMatching.isFullName("alice demo"))
        #expect(!NameMatching.isFullName("alice"))
        #expect(!NameMatching.isFullName("alice 2"))                // a digit is not a second name
        #expect(!NameMatching.isFullName("facebook user"))
        #expect(!NameMatching.isFullName("unknown contact"))
        #expect(!NameMatching.isFullName(""))
        #expect(NameMatching.compact("Casey_Quinn.Art") == "caseyquinnart")
    }
}

@Suite struct PeopleMatchingTests {
    @Test func onePersonAcrossSMSiMessageMessengerAndInstagram() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        // the iPhone address book spells the name with an accent; Messenger and Instagram use plain spelling in other case
        try b.phone("(212) 555-0111", name: "Ålice Demo", count: 10, origin: ContactOrigin.iphoneAddressBook, priority: ContactPriority.iphoneAddressBook)
        try b.meta(.messenger, name: "alice DEMO", count: 6, start: t0 + 400 * day)
        try b.meta(.instagram, name: "Alice  Demo", count: 4, start: t0 + 800 * day, username: "alice_demo_x")
        try b.phone("(212) 555-0122", name: "Ben Sample", count: 3)          // an unrelated person
        let r = try PeopleStore.rematch(db: t.db)
        #expect(r.handles == 4 && r.persons == 2 && r.linkedPersons == 1 && r.linkedHandles == 3 && r.ambiguousNames == 0)

        let idx = try b.index()
        let alice = try #require(personNamed(idx, "Ålice Demo"))           // the higher-priority (address book) spelling wins
        #expect(idx.source == .stored)
        #expect(alice.handles.count == 3)
        #expect(Set(alice.handles.compactMap(\.service)) == [.messenger, .instagram])
        #expect(alice.handles.allSatisfy { $0.origin == "auto" && $0.confidence >= 0.9 })
        #expect(alice.threadIDs.count == 3)
        #expect(alice.messages == 20)
        #expect(alice.id == alice.handles.map(\.handleID).min())
        #expect(personNamed(idx, "Ben Sample")?.handles.count == 1)

        // the stored tables agree
        #expect(try t.db.scalarInt("SELECT count(*) FROM person") == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM person_handle WHERE person_id = \(alice.id)") == 3)
        #expect(try t.db.scalarInt("SELECT handle_count FROM person WHERE id = \(alice.id)") == 3)

        // the list rolls the three threads into one row with all four services
        let reader = try ArchiveReader(root: t.root)
        let roll = PeopleList.roll(conversations: try reader.conversations(), index: idx, includeHidden: false)
        let row = try #require(roll.people.first { $0.id == alice.id })
        #expect(roll.people.count == 2 && roll.groups.isEmpty && roll.orphans.isEmpty)
        #expect(row.messageCount == 20 && row.threadIDs.count == 3)
        #expect(row.services == [.imessage, .sms, .messenger, .instagram])
        #expect(row.lastTsMs == t0 + 800 * day + 3 * day)
    }

    @Test func firstNamesAndNicknamesNeverLink() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0131", name: "Alice", count: 5)               // first name only
        try b.meta(.messenger, name: "Alice Demo", count: 5)
        try b.phone("212-555-0132", name: "Bob Demo", count: 5)            // a nickname of...
        try b.meta(.messenger, name: "Robert Demo", count: 5)
        try b.phone("212-555-0133", name: "Mom", count: 5)
        try b.meta(.instagram, name: "Mom", count: 5)                      // a one-word name on both sides
        let r = try PeopleStore.rematch(db: t.db)
        #expect(r.linkedPersons == 0 && r.persons == 6 && r.ambiguousNames == 0)
    }

    @Test func twoBusyNumbersWithOneNameAreAmbiguousAndLeftUnlinked() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        // two different people named Sam Duplicate, both texting daily through the same 60 days
        try b.phone("212-555-0141", name: "Sam Duplicate", count: 60, tag: "sam1")
        try b.phone("917-555-0142", name: "Sam Duplicate", count: 60, tag: "sam2")
        try b.meta(.messenger, name: "Sam Duplicate", count: 8)
        // a person who changed numbers: same name, eras that do not overlap, so one person
        try b.phone("212-555-0151", name: "Pat Lee", count: 40, start: t0, tag: "pat1")
        try b.phone("646-555-0152", name: "Pat Lee", count: 40, start: t0 + 400 * day, tag: "pat2")
        try b.meta(.instagram, name: "Pat Lee", count: 3)
        let r = try PeopleStore.rematch(db: t.db)
        #expect(r.ambiguousNames == 1 && r.ambiguousHandles == 3)
        #expect(r.linkedPersons == 1 && r.linkedHandles == 3)               // only Pat Lee
        let idx = try b.index()
        #expect(idx.ambiguous.map(\.key) == ["sam duplicate"] && idx.ambiguous[0].handleIDs.count == 3)
        #expect(idx.persons.values.filter { $0.name == "Sam Duplicate" }.count == 3)
        #expect(idx.persons.values.filter { $0.name == "Sam Duplicate" }.allSatisfy { $0.handles.count == 1 })
        let pat = try #require(personNamed(idx, "Pat Lee"))
        #expect(pat.handles.count == 3 && pat.handles.allSatisfy { $0.reason == "name-phones" || $0.reason == "name" })

        // the user can resolve it: the Messenger Sam is the one on the first number.
        let ov = try PeopleOverrides(root: t.root)
        let sams = idx.persons.values.filter { $0.name == "Sam Duplicate" }
        let first = try #require(sams.first { $0.handles[0].raw.contains("0141") || $0.handles[0].normalized == "+12125550141" })
        let msgr = try #require(sams.first { $0.handles[0].service == .messenger })
        try PeopleActions.merge([first.id, msgr.id], in: idx, overrides: ov)
        let fixed = try b.index(PeopleOverrides.read(root: t.root))
        #expect(fixed.persons.values.filter { $0.name == "Sam Duplicate" }.map { $0.handles.count }.sorted() == [1, 2])
    }

    @Test func instagramUsernameMatchesOnlyAUniqueFullName() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0161", name: "Casey Quinn", count: 5)
        try b.meta(.instagram, name: "caseyquinn", count: 5, username: "caseyquinn")      // no full name in the export, a username
        try b.meta(.instagram, name: "morgan", count: 5, username: "morgan")              // nothing to match
        try b.meta(.instagram, name: "q", count: 5, username: "q")                        // too short to trust
        try b.phone("212-555-0162", name: "Dana Fox", count: 5)
        try b.phone("917-555-0163", name: "Dana Fox", count: 50, tag: "d2")
        try b.phone("917-555-0164", name: "Dana Fox", count: 50, tag: "d3")               // ambiguous: two busy Dana Foxes
        try b.meta(.instagram, name: "danafox", count: 5, username: "danafox")
        let r = try PeopleStore.rematch(db: t.db)
        #expect(r.ambiguousNames == 1)
        let idx = try b.index()
        let casey = try #require(personNamed(idx, "Casey Quinn"))
        #expect(casey.handles.count == 2 && casey.handles.contains { $0.reason == "ig-username" && $0.confidence <= 0.6 })
        #expect(idx.persons.values.first { $0.handles.contains { $0.raw == "morgan" } }?.handles.count == 1)
        #expect(idx.persons.values.first { $0.handles.contains { $0.raw == "danafox" } }?.handles.count == 1)    // the ambiguous name stays unlinked
        #expect(idx.persons.values.filter { $0.name == "Dana Fox" }.allSatisfy { $0.handles.count == 1 })
    }

    @Test func deactivatedAccountPlaceholdersAndGroupsAreNeverMatched() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        let w = try b.writer(MetaService.messenger.sourceKind)
        try t.db.transaction {
            // two deactivated accounts: per-thread placeholder handles named "Facebook user"
            for k in 1...2 {
                let h = ServiceHandle.facebook(name: "Facebook user", unique: "t\(k)")
                var r = MessageRecord(participants: [], sender: nil, tsMs: t0 + Int64(k) * day, isFromMe: false, service: "messenger", body: "ghost \(k)")
                r.participantHandles = [h]; r.senderHandle = h
                try w.add(r)
                try w.noteName(service: h, name: "Facebook user", origin: "messenger-export", priority: 10)
            }
            // a group of two people who each also have their own 1:1
            let a = ServiceHandle.facebook(name: "Gina Group"), c = ServiceHandle.facebook(name: "Hal Group")
            var g = MessageRecord(participants: [], sender: nil, tsMs: t0, isFromMe: false, service: "messenger", body: "group hello")
            g.participantHandles = [a, c]; g.senderHandle = a
            try w.add(g)
            try w.noteName(service: a, name: "Gina Group", origin: "messenger-export", priority: 10)
            try w.noteName(service: c, name: "Hal Group", origin: "messenger-export", priority: 10)
        }
        let r = try PeopleStore.rematch(db: t.db)
        #expect(r.handles == 2 && r.persons == 2 && r.linkedPersons == 0)        // the ghosts; group-only members have no 1:1
        let idx = try b.index()
        #expect(idx.persons.count == 2)
    }

    @Test func rematchIsIdempotentAndEndToEndThroughTheImporters() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        // an Android export names the number; a Messenger export and an Instagram export carry the same full name
        try t.importXML(Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: 1_500_000_000_000, type: 1, body: "hello", name: "Alice Demo"),
                                       Fixtures.sms(address: Fixtures.alice, date: 1_500_000_100_000, type: 2, body: "hi back", name: "Alice Demo")]), name: "sms.xml")
        for (service, activity, folder) in [(MetaService.messenger, "your_facebook_activity", "alicedemo_100"), (.instagram, "your_instagram_activity", "alicedemo_200")] {
            let ex = Fixtures.tempDir("pe"); defer { try? FileManager.default.removeItem(at: ex) }
            let page = service == .messenger
                ? MetaFixtures.fbPage(title: "Alice Demo", generatedBy: "Test Me", [.init(sender: "Alice Demo", text: "from meta", time: "Jan 05, 2019 3:22:15 pm")])
                : MetaFixtures.igPage(title: "alicedemo", [.init(sender: "Alice Demo", text: "from ig", time: "Jan 05, 2019 3:22 pm"), .init(sender: "Test Me", text: "mine", time: "Jan 05, 2019 3:23 pm")])
            MetaFixtures.writeThread(root: ex, activity: activity, folder: folder, pages: [page])
            _ = try MetaImporter.importExport(at: ex, service: service, into: t.db, root: t.root, options: MetaImportOptions(me: "Test Me"))
        }
        let a = try PeopleStore.rematch(db: t.db)
        let rowsA = try t.db.scalarString("SELECT group_concat(person_id || ':' || handle_id || ':' || reason, ',') FROM (SELECT * FROM person_handle ORDER BY handle_id)")
        let b = try PeopleStore.rematch(db: t.db)
        let rowsB = try t.db.scalarString("SELECT group_concat(person_id || ':' || handle_id || ':' || reason, ',') FROM (SELECT * FROM person_handle ORDER BY handle_id)")
        #expect(a.linkedPersons == 1 && a.linkedHandles == 3 && a.persons == 1)
        #expect(rowsA == rowsB && a.persons == b.persons)
        #expect(try ArchiveVerifier.run(db: t.db, root: t.root).passed)
    }
}

@Suite struct PeopleOverrideTests {
    @Test func correctionsSurviveRematchAndReimport() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0171", name: "Alice Demo", count: 10)
        try b.meta(.messenger, name: "Alice Demo", count: 10, start: t0 + 300 * day)
        try b.phone("212-555-0172", name: "Bob Sample", count: 10)
        try b.meta(.messenger, name: "Zed Unrelated", count: 10)
        try PeopleStore.rematch(db: t.db)
        var idx = try b.index()
        #expect(idx.persons.count == 3)
        let ov = try PeopleOverrides(root: t.root)

        // split Messenger off Alice (it was the wrong Alice Demo), merge Bob with Zed, rename Bob's person, hide nobody
        let alice = try #require(personNamed(idx, "Alice Demo"))
        let msgr = try #require(alice.handles.first { $0.service == .messenger })
        let split = try PeopleActions.split(person: alice.id, handleIDs: [msgr.handleID], in: idx, overrides: ov)
        #expect(split != nil)
        idx = try b.index(try ov.read())
        #expect(idx.persons.count == 4)
        let bob = try #require(personNamed(idx, "Bob Sample")), zed = try #require(personNamed(idx, "Zed Unrelated"))
        let merged = try #require(try PeopleActions.merge([bob.id, zed.id], in: idx, overrides: ov))
        idx = try b.index(try ov.read())
        try PeopleActions.rename(person: merged, to: "Robert Sample", in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        #expect(idx.persons.count == 3 && idx.persons[merged]?.name == "Robert Sample" && idx.persons[merged]?.handles.count == 2)
        #expect(idx.persons[merged]?.handles.allSatisfy { $0.origin == "manual" } == true)
        let before = Dictionary(uniqueKeysWithValues: idx.persons.values.map { ($0.handles.map(\.normalized).sorted(), $0.name) })

        // re-run the automatic matching: it wants Alice and her Messenger together again, but the correction stands
        try PeopleStore.rematch(db: t.db)
        idx = try b.index(PeopleOverrides.read(root: t.root))
        let after = Dictionary(uniqueKeysWithValues: idx.persons.values.map { ($0.handles.map(\.normalized).sorted(), $0.name) })
        #expect(before == after)
        #expect(idx.persons.values.filter { $0.name == "Alice Demo" }.count == 2)

        // re-import: Alice gets an Instagram thread later. It joins her phone number (the auto rule), not the split-off Messenger.
        try b.meta(.instagram, name: "Alice Demo", count: 4, start: t0 + 900 * day)
        try PeopleStore.rematch(db: t.db)
        idx = try b.index(PeopleOverrides.read(root: t.root))
        let phoneAlice = try #require(idx.persons.values.first { $0.handles.contains { $0.kind == "phone" && $0.normalized == "+12125550171" } })
        #expect(phoneAlice.handles.count == 2 && phoneAlice.handles.contains { $0.service == .instagram })
        #expect(!phoneAlice.handles.contains { $0.service == .messenger })

        // reset forgets the split: back to the automatic grouping
        let lonely = try #require(idx.persons.values.first { $0.handles.count == 1 && $0.handles[0].service == .messenger && $0.handles[0].raw == "Alice Demo" })
        try PeopleActions.reset(person: lonely.id, in: idx, overrides: ov)
        idx = try b.index(PeopleOverrides.read(root: t.root))
        #expect(idx.persons.values.first { $0.handles.contains { $0.normalized == "+12125550171" } }?.handles.count == 3)
    }

    @Test func splittingTheBridgeOfAMergeLeavesTheRestJoined() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0181", name: "Ann One", count: 5)
        try b.phone("212-555-0182", name: "Bea Two", count: 5)
        try b.phone("212-555-0183", name: "Cy Three", count: 5)
        try b.phone("212-555-0184", name: "Di Four", count: 5)
        try PeopleStore.rematch(db: t.db)
        let ov = try PeopleOverrides(root: t.root)
        var idx = try b.index()
        let ids = idx.persons.values.sorted { $0.id < $1.id }.map(\.id)
        try PeopleActions.merge([ids[0], ids[1]], in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        let ab = try #require(idx.persons.values.first { $0.handles.count == 2 })
        try PeopleActions.merge([ab.id, idx.person(normalized: "+12125550183")!.id, idx.person(normalized: "+12125550184")!.id], in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        let all = try #require(idx.persons.values.first { $0.handles.count == 4 })
        // take the first handle out: the other three stay one person; the split-off handle is alone
        _ = try PeopleActions.split(person: all.id, handleIDs: [all.handles[0].handleID], in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        #expect(idx.persons.count == 2 && idx.persons.values.map { $0.handles.count }.sorted() == [1, 3])
        // splitting everything off is refused
        let three = try #require(idx.persons.values.first { $0.handles.count == 3 })
        #expect(try PeopleActions.split(person: three.id, handleIDs: three.handles.map(\.handleID), in: idx, overrides: ov) == nil)
        // two handles split off together stay one person
        _ = try PeopleActions.split(person: three.id, handleIDs: [three.handles[0].handleID, three.handles[1].handleID], in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        #expect(idx.persons.values.map { $0.handles.count }.sorted() == [1, 1, 2])
    }

    @Test func hidingAPersonRemovesThemFromTheListUnlessAskedFor() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0191", name: "Hide Me", count: 4)
        try b.phone("212-555-0192", name: "Keep Me", count: 4)
        try PeopleStore.rematch(db: t.db)
        let ov = try PeopleOverrides(root: t.root)
        var idx = try b.index()
        try PeopleActions.setHidden(person: personNamed(idx, "Hide Me")!.id, true, in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        let reader = try ArchiveReader(root: t.root)
        let convs = try reader.conversations()
        #expect(PeopleList.roll(conversations: convs, index: idx, includeHidden: false).people.map { $0.person.name } == ["Keep Me"])
        #expect(PeopleList.roll(conversations: convs, index: idx, includeHidden: true).people.count == 2)
        try PeopleActions.setHidden(person: personNamed(idx, "Hide Me")!.id, false, in: idx, overrides: ov)
        #expect(PeopleList.roll(conversations: convs, index: try b.index(try ov.read()), includeHidden: false).people.count == 2)
    }

    @Test func correctionsNeverTouchTheArchiveDatabase() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0201", name: "Una Same", count: 4)
        try b.meta(.messenger, name: "Una Same", count: 4)
        try PeopleStore.rematch(db: t.db)
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let before = try Data(contentsOf: t.root.databaseURL)
        let ov = try PeopleOverrides(root: t.root)
        var idx = try b.index()
        let una = try #require(personNamed(idx, "Una Same"))
        _ = try PeopleActions.split(person: una.id, handleIDs: [una.handles[1].handleID], in: idx, overrides: ov)
        idx = try b.index(try ov.read())
        try PeopleActions.rename(person: idx.persons.values.first!.id, to: "Someone Else", in: idx, overrides: ov)
        #expect(try Data(contentsOf: t.root.databaseURL) == before)
        #expect(FileManager.default.fileExists(atPath: PeopleOverrides.fileURL(root: t.root).path))
        #expect(PeopleOverrides.read(root: t.root).count > 0)
        // a fresh handle on the file sees the same thing; an absent file reads as empty
        #expect(PeopleOverrides.read(root: ArchiveRoot(url: t.dir.appendingPathComponent("nowhere"))).isEmpty)
    }
}

@Suite struct PersonTimelineTests {
    /// Alice has three threads whose messages interleave in time, with ties across threads.
    static func alice(_ t: TestArchive) throws -> (b: PeopleBuilder, scope: MessageScope, expected: [Int64]) {
        let b = PeopleBuilder(t)
        try b.phone("212-555-0211", name: "Alice Demo", count: 70, start: t0, step: 3 * day, tag: "a")
        try b.meta(.messenger, name: "Alice Demo", count: 90, start: t0 + day, step: 2 * day, tag: "b")
        try b.meta(.instagram, name: "Alice Demo", count: 40, start: t0, step: 5 * day, tag: "c")       // same instants as the phone thread at times
        try PeopleStore.rematch(db: t.db)
        let idx = try b.index()
        let p = try #require(personNamed(idx, "Alice Demo"))
        #expect(p.threadIDs.count == 3)
        let rows = try t.db.prepare("SELECT id FROM message WHERE canonical_id IS NULL ORDER BY ts_ms, id")
        var ids: [Int64] = []
        while try rows.step() { ids.append(rows.int(0)) }
        return (b, MessageScope(threads: p.threadIDs), ids)
    }

    @Test func pagingAcrossThreadsEqualsTheSortedUnion() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (_, scope, expected) = try Self.alice(t)
        let reader = try ArchiveReader(root: t.root)
        #expect(expected.count == 200)
        #expect(try reader.messageCount(scope: scope) == 200)
        // backwards from the newest, in awkward page sizes
        for pageSize in [1, 7, 33, 500] {
            var window = try reader.latest(scope: scope, limit: pageSize)
            #expect(window.count == min(pageSize, 200))
            while let first = window.first {
                let older = try reader.before(scope: scope, key: MessageKey(tsMs: first.tsMs, id: first.id), limit: pageSize)
                if older.isEmpty { break }
                window = older + window
            }
            #expect(window.map(\.id) == expected, "backwards, page \(pageSize)")
        }
        // forwards from the first
        var forward = Array(try reader.after(scope: scope, key: MessageKey(tsMs: 0, id: 0), limit: 11))
        while let last = forward.last {
            let more = try reader.after(scope: scope, key: MessageKey(tsMs: last.tsMs, id: last.id), limit: 11)
            if more.isEmpty { break }
            forward += more
        }
        #expect(forward.map(\.id) == expected)
        // every message knows its thread and service
        #expect(Set(forward.map(\.threadID)).count == 3)
        #expect(Set(forward.map(\.serviceKey)) == [.imessage, .sms, .messenger, .instagram])
    }

    @Test func jumpsAndWindowsWorkAcrossThreads() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (_, scope, expected) = try Self.alice(t)
        let reader = try ArchiveReader(root: t.root)
        let mid = expected[100]
        let k = try #require(try reader.key(ofMessage: mid))
        let win = try reader.around(scope: scope, key: k.key, before: 5, after: 5)
        #expect(win.map(\.id) == Array(expected[95...105]))
        // first message at or after a date, and the last message when the date is past the end
        let at = try #require(try reader.firstMessage(scope: scope, atOrAfter: t0 + 100 * day))
        #expect(at.tsMs >= t0 + 100 * day)
        let rows = try reader.latest(scope: scope, limit: 200)
        #expect(rows.first { $0.tsMs >= t0 + 100 * day }?.id == at.id)
        let past = try #require(try reader.firstMessage(scope: scope, atOrAfter: t0 + 100_000 * day))
        #expect(past.id == expected.last)
        // a message outside the scope is not returned as the centre
        let other = MessageScope(threads: [scope.threadIDs[0]])
        let outside = rows.first { $0.threadID != scope.threadIDs[0] }!
        #expect(try reader.around(scope: other, key: MessageKey(tsMs: outside.tsMs, id: outside.id), before: 1, after: 1).allSatisfy { $0.threadID == scope.threadIDs[0] })
        #expect(try reader.latest(scope: MessageScope(threads: []), limit: 5).isEmpty)
    }

    @Test func serviceFilterNarrowsEveryQuery() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let (b, scope, expected) = try Self.alice(t)
        _ = b
        let reader = try ArchiveReader(root: t.root)
        for (services, want) in [([ServiceKey.messenger], ["messenger"]), ([.instagram], ["instagram"]), ([.sms], ["sms", "mms"]),
                                 ([.imessage], ["imessage"]), ([.sms, .imessage], ["sms", "imessage", "mms"]), ([.messenger, .instagram], ["messenger", "instagram"])] {
            let s = MessageScope(threads: scope.threadIDs, services: Set(services))
            var all: [MessageRow] = []
            var window = try reader.latest(scope: s, limit: 30)
            all = window
            while let first = window.first {
                let older = try reader.before(scope: s, key: MessageKey(tsMs: first.tsMs, id: first.id), limit: 30)
                if older.isEmpty { break }
                all = older + all; window = older
            }
            #expect(all.allSatisfy { want.contains($0.service) }, "\(services)")
            #expect(all.count == (try reader.messageCount(scope: s)))
            #expect(all.map(\.id) == expected.filter { id in all.contains { $0.id == id } })           // still in order
            #expect(try reader.monthCounts(scope: s).reduce(0) { $0 + $1.count } == all.count)
        }
        // every service on is the same as no filter
        let everything = MessageScope(threads: scope.threadIDs, services: Set(ServiceKey.allCases))
        #expect(try reader.messageCount(scope: everything) == 200)
        // the month strip over the whole scope adds up
        #expect(try reader.monthCounts(scope: scope).reduce(0) { $0 + $1.count } == 200)
    }

    @Test func searchRunsWithinAPersonsThreadsAndServices() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0221", name: "Una Same", count: 6, tag: "pizzaparty")
        try b.meta(.messenger, name: "Una Same", count: 6, start: t0 + 50 * day, tag: "pizzaparty")
        try b.phone("212-555-0222", name: "Other Person", count: 6, tag: "pizzaparty")
        try PeopleStore.rematch(db: t.db)
        let idx = try b.index()
        let una = try #require(personNamed(idx, "Una Same"))
        let reader = try ArchiveReader(root: t.root)
        let everywhere = try reader.search("pizzaparty")
        #expect(everywhere.count == 18)
        let scope = MessageScope(threads: una.threadIDs)
        let mine = try reader.search("pizzaparty", scope: scope)
        #expect(mine.count == 12 && Set(mine.map(\.threadID)) == Set(una.threadIDs))
        let msgrOnly = try reader.search("pizzaparty", scope: MessageScope(threads: una.threadIDs, services: [.messenger]))
        #expect(msgrOnly.count == 6 && msgrOnly.allSatisfy { $0.service == "messenger" })
        #expect(try reader.search("pizzaparty", scope: MessageScope(threads: [])).isEmpty)
        // single-thread search keeps working
        #expect(try reader.search("pizzaparty", thread: una.threadIDs[0]).count == 6)
    }

    @Test func hiddenThreadsStayOutOfTheListAndOutOfPersonsUnlessAskedFor() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0231", name: "Vee Real", count: 5)
        try b.meta(.messenger, name: "Vee Real", count: 5, origin: "requests", tag: "req")             // a message request from the same name
        try b.meta(.messenger, name: "Only Requested", count: 5, origin: "filtered")
        try PeopleStore.rematch(db: t.db)
        let idx = try b.index()
        let reader = try ArchiveReader(root: t.root)
        let visible = PeopleList.roll(conversations: try reader.conversations(), index: idx, includeHidden: false)
        #expect(visible.people.map { $0.person.name } == ["Vee Real"] && visible.people[0].threadIDs.count == 1 && visible.people[0].messageCount == 5)
        let all = PeopleList.roll(conversations: try reader.conversations(includeHidden: true), index: idx, includeHidden: true)
        #expect(all.people.count == 2)
        let vee = try #require(all.people.first { $0.person.name == "Vee Real" })
        #expect(vee.threadIDs.count == 2 && vee.messageCount == 10 && vee.hiddenThreads == 1)
        #expect(all.people.first { $0.person.name == "Only Requested" }?.hiddenThreads == 1)
    }

    @Test func groupThreadsStayTheirOwnRows() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.phone("212-555-0241", name: "Gil Group", count: 5)
        let w = try b.writer()
        try t.db.transaction {
            for i in 0..<4 {
                try w.add(MessageRecord(participants: ["212-555-0241", "212-555-0242"], sender: "212-555-0242", tsMs: t0 + Int64(i) * day, isFromMe: false, service: "mms", body: "group \(i)"))
            }
        }
        try PeopleStore.rematch(db: t.db)
        let reader = try ArchiveReader(root: t.root)
        let roll = PeopleList.roll(conversations: try reader.conversations(), index: try b.index(), includeHidden: false)
        #expect(roll.groups.count == 1 && roll.groups[0].messageCount == 4)
        #expect(roll.people.count == 1 && roll.people[0].messageCount == 5)
    }
}

@Suite struct PreStageBArchiveTests {
    /// The app opens the archive read-only, so an archive that has not been migrated (the real one is still v4) must still open.
    @Test func aV4ArchiveOpensReadOnlyWithoutMigrating() throws {
        let dir = Fixtures.tempDir("v4"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir.appendingPathComponent("root"))
        try root.createIfNeeded()
        do {
            let db = try Database(path: root.databaseURL.path)
            try db.exec("PRAGMA journal_mode = WAL")
            try Schema.migrate(db, upTo: 4)
            try db.exec("""
                INSERT INTO source(id, kind, path, sha256, bytes, imported_at) VALUES (1, 'android-xml', 'x', 's', 0, 0);
                INSERT INTO handle(id, raw, normalized, kind) VALUES (1, '2125550111', '+12125550111', 'phone'), (2, '2125550112', '+12125550112', 'phone');
                INSERT INTO contact_name(handle_id, name, origin, priority) VALUES (1, 'Old Friend', 'android-xml', 10), (2, 'Old Friend', 'iphone-addressbook', 20);
                INSERT INTO thread(id, key, is_group, title) VALUES (1, '+12125550111', 0, NULL), (2, '+12125550112', 0, NULL);
                INSERT INTO thread_member(thread_id, handle_id) VALUES (1, 1), (2, 2);
                INSERT INTO message(thread_id, sender_handle_id, ts_ms, is_from_me, service, body, source_id, content_hash) VALUES
                    (1, 1, 1000000000000, 0, 'sms', 'first pizza', 1, 1), (1, NULL, 1000000100000, 1, 'sms', 'reply', 1, 2),
                    (2, 2, 1000000200000, 0, 'imessage', 'second', 1, 3);
                """)
            try db.exec("INSERT INTO message_fts(message_fts) VALUES ('rebuild')")
            try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            #expect(try db.userVersion() == 4)
        }
        let reader = try ArchiveReader(root: root)
        #expect(reader.schemaVersion == 4)
        let convs = try reader.conversations()
        #expect(convs.count == 2 && convs.allSatisfy { !$0.hidden && $0.service == nil })
        #expect(convs.first { $0.messageCount == 2 }?.serviceCounts == [.sms: 2])
        // no person tables yet: the grouping is computed on the spot, and both numbers named alike are one person
        let idx = try reader.people()
        #expect(idx.source == .computed && idx.persons.count == 1 && idx.persons.values.first?.name == "Old Friend")
        let scope = MessageScope(threads: idx.persons.values.first!.threadIDs)
        let rows = try reader.latest(scope: scope, limit: 10)
        #expect(rows.map(\.body) == ["first pizza", "reply", "second"] && rows.allSatisfy { $0.kind == nil && $0.reactions.isEmpty })
        #expect(try reader.search("pizza", scope: scope).count == 1)
        #expect(try reader.monthCounts(scope: scope).reduce(0) { $0 + $1.count } == 3)
        // and the file is still v4
        let again = try Database(path: root.databaseURL.path, readOnly: true)
        #expect(try again.userVersion() == 4)
    }
}
