import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ArchiveCore

/// A connected loopback socket for the raw HTTP tests (Darwin and Glibc spell the constants differently).
func connectLoopback(port: UInt16) -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    var addr = sockaddr_in()
    signal(SIGPIPE, SIG_IGN)
    #endif
    addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if rc != 0 { close(fd); return -1 }
    return fd
}

// The review site: suggestion scoring, rejections and undo in people.sqlite, the service over a synthetic archive, the HTTP
// handler (no socket) and one loopback round trip. Synthetic names and 555-01xx numbers only.

private let day: Int64 = 86_400_000
private let base = MetaFixtures.ms("2015-01-01T00:00:00Z")

private func form(_ s: String) -> NameForm { NameForm(s)! }

private func prof(_ id: Int64, _ names: [String], phone: Int = 0, messenger: Bool = false, instagram: Bool = false, usernames: [String] = [],
                  messages: Int = 100, co: Set<Int64> = [], keys: [String]? = nil, from: Int64 = base, to: Int64 = base + 400 * day,
                  groups: Int = 1, hidden: Bool = false) -> SuggestionProfile {
    SuggestionProfile(id: id, names: names, usernames: usernames, phoneHandles: phone, hasMessenger: messenger, hasInstagram: instagram,
                      messages: messages, firstTsMs: from, lastTsMs: to, handleKeys: keys ?? ["h\(id)"], coMembers: co, groupCount: groups, hidden: hidden)
}

@Suite struct NameComparisonTests {
    @Test func sameWordsInAnyOrderAndAccentsAndCase() {
        #expect(MatchSuggester.compare(form("Zhang Wei"), form("wei ZHANG"))?.score ?? 0 >= 0.9)
        #expect(MatchSuggester.compare(form("Zoë Müller"), form("zoe muller"))?.score == 1.0)
    }

    @Test func nicknamesAndShortForms() {
        let nick = MatchSuggester.compare(form("Alexander Demo"), form("Alex Demo"))
        #expect(nick != nil && nick!.score >= 0.85 && nick!.reason.contains("nickname"))
        #expect(MatchSuggester.compare(form("Kate Placeholder"), form("Katherine Placeholder"))?.score ?? 0 >= 0.85)
        #expect(MatchSuggester.compare(form("Will Sample"), form("William Sample"))?.score ?? 0 >= 0.85)
        #expect(MatchSuggester.compare(form("Mike Quinn"), form("Michael Quinn"))?.score ?? 0 >= 0.85)
        // a short form that is not in the table still matches by prefix, a little lower
        let prefix = MatchSuggester.compare(form("Christoph Demo"), form("Christophe Demo"))
        #expect(prefix != nil && prefix!.score < 0.85 && prefix!.score >= 0.7)
        // different first names never match
        #expect(MatchSuggester.compare(form("Alice Demo"), form("Bob Demo")) == nil)
    }

    @Test func middleNamesInitialsAndSuffixes() {
        let dropped = MatchSuggester.compare(form("Alice Marie Demo"), form("Alice Demo"))
        #expect(dropped != nil && dropped!.score >= 0.9 && dropped!.reason.contains("middle name dropped"))
        #expect(MatchSuggester.compare(form("Alice Marie Demo"), form("Alice Rose Demo"))!.score < 0.9)    // two different middles
        let initial = MatchSuggester.compare(form("A. Demo"), form("Alice Demo"))
        #expect(initial != nil && initial!.score < 0.85 && initial!.score >= 0.6)
        #expect(MatchSuggester.compare(form("Alice Demo Jr."), form("Alice Demo"))?.score == 1.0)
    }

    @Test func hyphenatedSurnamesAndSwappedNames() {
        let hy = MatchSuggester.compare(form("Anne Smith-Jones"), form("Anne Smith"))
        #expect(hy != nil && hy!.score >= 0.8 && hy!.reason.contains("surname"))
        #expect(MatchSuggester.compare(form("Smith Anne"), form("Anne Smith"))?.score ?? 0 >= 0.9)
    }

    @Test func firstNameOnlyIsWeakAndEmojiOrGenericNamesAreIgnored() {
        let weak = MatchSuggester.compare(form("Alex"), form("Alex Demo"))
        #expect(weak != nil && weak!.score <= 0.30)
        #expect(MatchSuggester.compare(form("Alex"), form("Bob Demo")) == nil)
        #expect(NameForm("Facebook User") == nil && NameForm("(Unknown)") == nil && NameForm("null") == nil)
        #expect(NameForm("Alice Demo \u{1F338}")?.tokens == ["alice", "demo"])
    }

    @Test func instagramUsernamesAgainstNames() {
        #expect(MatchSuggester.usernameScore("alice_demo_92", form("Alice Demo"))?.score == 0.6)
        #expect(MatchSuggester.usernameScore("ademo", form("Alice Demo"))?.score == 0.5)
        #expect(MatchSuggester.usernameScore("alice.d", form("Alice Demo"))?.score == 0.35)          // first name + last initial, as whole tokens
        #expect(MatchSuggester.usernameScore("alice_d92", form("Alice Demo"))?.score == 0.35)
        #expect(MatchSuggester.usernameScore("alicedpics", form("Alice Demo"))?.score == 0.20)        // only a substring: the first name, nothing more
        #expect(MatchSuggester.usernameScore("lex.demo", form("Alexander Demo"))?.score == 0.6)      // nickname variant inside the username
        #expect(MatchSuggester.usernameScore("zzzz", form("Alice Demo")) == nil)
        #expect(MatchSuggester.usernameScore("abc", form("Alice Demo")) == nil)                       // too short to mean anything
    }
}

@Suite struct SuggesterTests {
    @Test func nicknameReorderedAndUsernameCandidatesAreProposedWithReasons() {
        let profiles = [
            prof(1, ["Alex Demo"], messenger: true, messages: 900),                 // Messenger-only, biggest
            prof(2, ["Alexander Demo"], phone: 1),                                   // nickname
            prof(3, ["Wei Zhang"], instagram: true, messages: 500),
            prof(4, ["Zhang Wei"], phone: 1),                                        // reordered
            prof(5, ["Cq"], instagram: true, usernames: ["casey_quinn_art"], messages: 300),
            prof(6, ["Casey Quinn"], phone: 1),                                      // username tokens
            prof(7, ["Dana Other"], phone: 1),                                       // nothing in common
        ]
        let out = MatchSuggester.suggest(profiles: profiles).filter { $0.queue == .crossService }
        #expect(out.map(\.sourceID) == [1, 3, 5])                                     // biggest message count first
        #expect(out[0].candidates.first?.personID == 2 && out[0].candidates[0].reasons.contains { $0.contains("nickname") })
        #expect(out[1].candidates.first?.personID == 4)
        #expect(out[2].candidates.first?.personID == 6 && out[2].candidates[0].reasons.contains { $0.contains("Instagram username") })
        #expect(out.allSatisfy { !$0.candidates.contains { $0.personID == 7 } })
        #expect(out.allSatisfy { $0.candidates.allSatisfy { $0.score >= 0.4 && $0.score <= 1.0 } })
        // candidates are best first
        #expect(zip(out[0].candidates, out[0].candidates.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test func sharedGroupMembersRaiseAndCanCarryAWeakNameMatch() {
        // Meta person 1 (first name only on the phone side) has three group-mates who are also group-mates of candidate 2; candidate 3 shares none
        let friends: Set<Int64> = [10, 11, 12]
        let profiles = [
            prof(1, ["Jordan Vale"], messenger: true, messages: 400, co: friends),
            prof(2, ["Jordan"], phone: 1, co: friends),
            prof(3, ["Jordan"], phone: 1),
        ] + friends.map { prof($0, ["Friend \($0)"], phone: 1, co: [1, 2], groups: 2) }
        let out = MatchSuggester.suggest(profiles: profiles).first { $0.queue == .crossService && $0.sourceID == 1 }
        let c2 = out?.candidates.first { $0.personID == 2 }, c3 = out?.candidates.first { $0.personID == 3 }
        #expect(c2 != nil && c2!.sharedGroupPeople == 3 && c2!.reasons.contains { $0.contains("group chats with both") })
        #expect(out?.candidates.first?.personID == 2)
        if let c3 { #expect(c2!.score > c3.score) }                                 // evidence of shared groups outranks a bare first-name match
    }

    @Test func aBareFirstNameAloneIsNotEnough() {
        let out = MatchSuggester.suggest(profiles: [prof(1, ["Jordan Vale"], messenger: true), prof(2, ["Jordan"], phone: 1), prof(3, ["Jordan"], phone: 1)])
        #expect(out.filter { $0.queue == .crossService }.isEmpty)                    // two Jordans: no uniqueness bonus, no groups
    }

    @Test func peopleAlreadyLinkedAcrossServicesAreNeverSources() {
        let profiles = [
            prof(1, ["Alice Demo"], phone: 1, messenger: true, messages: 900),     // already one person with a number
            prof(2, ["Alice Marie Demo"], instagram: true, messages: 300),
        ]
        let out = MatchSuggester.suggest(profiles: profiles).filter { $0.queue == .crossService }
        #expect(out.map(\.sourceID) == [2])                                          // 1 is a candidate, never a card
        #expect(out[0].candidates.first?.personID == 1)
    }

    @Test func candidatesAlreadyHoldingTheSameServiceAreSkipped() {
        let profiles = [
            prof(1, ["Alice Demo"], messenger: true, messages: 900),
            prof(2, ["Alice Marie Demo"], phone: 1, messenger: true),                // has a Messenger handle of its own: a different Alice
        ]
        #expect(MatchSuggester.suggest(profiles: profiles).filter { $0.queue == .crossService }.isEmpty)
    }

    @Test func rejectionsAreRespectedForEitherDirectionAndAnyHandle() {
        let profiles = [
            prof(1, ["Alex Demo"], messenger: true, messages: 900, keys: ["fb:alex demo"]),
            prof(2, ["Alexander Demo"], phone: 1, keys: ["+12125550111", "+12125550112"]),
        ]
        #expect(MatchSuggester.suggest(profiles: profiles).count == 1)
        let rejected: Set<String> = [MatchSuggester.rejectionKey("+12125550112", "fb:alex demo")]       // stored the other way round, other number
        #expect(MatchSuggester.suggest(profiles: profiles, rejectedPairs: rejected).isEmpty)
    }

    @Test func hiddenPeopleAreLeftOut() {
        let profiles = [prof(1, ["Alex Demo"], messenger: true), prof(2, ["Alexander Demo"], phone: 1, hidden: true)]
        #expect(MatchSuggester.suggest(profiles: profiles).isEmpty)
    }

    @Test func twoMetaOnlyPeopleAreOfferedOnceFromTheBusierSide() {
        let profiles = [
            prof(1, ["Alice Marie Demo"], messenger: true, messages: 900),
            prof(2, ["Alice Demo"], instagram: true, messages: 300),
        ]
        let out = MatchSuggester.suggest(profiles: profiles).filter { $0.queue == .crossService }
        #expect(out.count == 1 && out[0].sourceID == 1 && out[0].candidates[0].personID == 2)
    }

    @Test func peopleWhoShareAGroupChatArePenalizedAsProbablyDifferent() {
        let together: [SuggestionProfile] = [
            prof(1, ["Alex Demo"], messenger: true, messages: 900, co: [2]),
            prof(2, ["Alexander Demo"], phone: 1, co: [1]),
        ]
        let apart: [SuggestionProfile] = [prof(1, ["Alex Demo"], messenger: true, messages: 900), prof(2, ["Alexander Demo"], phone: 1)]
        #expect(MatchSuggester.suggest(profiles: together).isEmpty)
        #expect(MatchSuggester.suggest(profiles: apart).count == 1)
    }

    @Test func overlapAndVolumeNeverCreateASuggestionOnTheirOwn() {
        let profiles = [prof(1, ["Pat Quill"], messenger: true, messages: 500), prof(2, ["Robin Hale"], phone: 1, messages: 500)]
        #expect(MatchSuggester.suggest(profiles: profiles).isEmpty)
    }

    @Test func duplicateQueueFindsChangedNumbersAndNicknames() {
        let profiles = [
            prof(1, ["Alexander Demo"], phone: 1, messages: 800, from: base, to: base + 300 * day),
            prof(2, ["Alex Demo"], phone: 1, messages: 200, from: base + 400 * day, to: base + 600 * day),
            prof(3, ["Casey Fox"], phone: 1),
            prof(4, ["Casey"], phone: 1),                                            // first name only: not a duplicate
        ]
        let dups = MatchSuggester.suggest(profiles: profiles).filter { $0.queue == .duplicates }
        #expect(dups.count == 1 && dups[0].sourceID == 1 && dups[0].candidates.map(\.personID) == [2])
        // rejection removes it
        let rej: Set<String> = [MatchSuggester.rejectionKey("h1", "h2")]
        #expect(MatchSuggester.suggest(profiles: profiles, rejectedPairs: rej).filter { $0.queue == .duplicates }.isEmpty)
    }

    @Test func aNameAloneNeverReachesStrongAndAmbiguousPairsLoseScore() {
        let named = [prof(1, ["Alice Marie Demo"], messenger: true, messages: 500), prof(2, ["Alice Demo"], phone: 1, messages: 400)]
        let top = MatchSuggester.suggest(profiles: named).first { $0.queue == .crossService }?.candidates.first
        #expect(top != nil && top!.score < 0.80 && top!.score >= 0.55)                // middle name dropped, identical otherwise: "likely"
        let withUser = [prof(1, ["Alice Demo"], instagram: true, usernames: ["alice_demo_92"], messages: 500), prof(2, ["Alice Demo"], phone: 1, messages: 400)]
        #expect(MatchSuggester.suggest(profiles: withUser).first { $0.queue == .crossService }?.candidates.first?.score ?? 0 >= 0.80)   // name + username: strong
        let twin = [prof(1, ["Alex Demo"], phone: 1, messages: 500), prof(2, ["Alexander Demo"], phone: 1, messages: 400)]
        let plain = MatchSuggester.suggest(profiles: twin).first { $0.queue == .duplicates }?.candidates.first?.score
        let amb = MatchSuggester.suggest(profiles: twin, ambiguousPairs: [MatchSuggester.personPairKey(1, 2)]).first { $0.queue == .duplicates }?.candidates.first?.score
        #expect(plain != nil && amb != nil && amb! < plain! && amb! <= plain! - 0.05)
    }

    @Test func ambiguousPairsGetAWarning() {
        let profiles = [prof(1, ["Sam Poole"], phone: 1, messages: 500), prof(2, ["Sam Poole"], phone: 1, messages: 400)]
        let out = MatchSuggester.suggest(profiles: profiles, ambiguousPairs: [MatchSuggester.personPairKey(1, 2)]).filter { $0.queue == .duplicates }
        #expect(out.count == 1 && out[0].candidates[0].reasons.contains { $0.contains("two busy numbers") })
    }
}

@Suite struct PeopleOverridesV1Tests {
    @Test func migrationAddsTablesKeepsCorrectionsBacksUpOnceAndIsIdempotent() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir)
        // a version-0 file as the app wrote it before: the four tables, one correction
        do {
            let old = try Database(path: PeopleOverrides.fileURL(root: root).path)
            try PeopleOverrides.createSchema(old)
            try old.exec("INSERT INTO link(a, b, at) VALUES ('+1212555a', '+1212555b', 1)")
            #expect(try old.userVersion() == 0)
        }
        let o = try PeopleOverrides(root: root)
        #expect(try o.read().links == [["+1212555a", "+1212555b"]])
        let backup = PeopleOverrides.fileURL(root: root).appendingPathExtension("pre-v1")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let backedUp = try Database(path: backup.path, readOnly: true)
        #expect(try backedUp.scalarInt("SELECT count(*) FROM link") == 1)
        #expect(try backedUp.tableExists("reject") == false)

        let again = try PeopleOverrides(root: root)                                   // idempotent; keeps the first backup
        #expect(try again.read().links.count == 1)
        let db = try Database(path: PeopleOverrides.fileURL(root: root).path, readOnly: true)
        #expect(try db.userVersion() == PeopleOverrides.schemaVersion)
        #expect(try db.tableExists("reject") && db.tableExists("decision"))
    }

    @Test func aNewerFileIsRefused() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir)
        do { let d = try Database(path: PeopleOverrides.fileURL(root: root).path); try d.setUserVersion(99) }
        #expect(throws: ArchiveError.self) { _ = try PeopleOverrides(root: root) }
    }

    @Test func rejectionsRoundTripAndTheDecisionLogUndoesLinks() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir)
        let o = try PeopleOverrides(root: root)
        let fresh = try o.reject(["a", "b"], ["c"])
        #expect(fresh == [["a", "c"], ["b", "c"]])
        #expect(try o.reject(["a"], ["c"]).isEmpty)                                     // already stored: nothing new
        #expect(PeopleOverrides.readRejections(root: root) == [MatchSuggester.rejectionKey("a", "c"), MatchSuggester.rejectionKey("b", "c")])
        try o.removeRejections(fresh)
        #expect(PeopleOverrides.readRejections(root: root).isEmpty)

        let links = try o.mergeReturningNew(["x"], with: ["y"])
        #expect(links == [["x", "y"]])
        #expect(try o.mergeReturningNew(["x"], with: ["y", "z"]) == [["x", "z"]])
        try o.removeLinks([["x", "z"]])
        #expect(try o.read().links == [["x", "y"]])

        let id = try o.logDecision(kind: "merge", label: "m", payload: ["links": links])
        #expect(try o.decisionCount(kind: "merge") == 1)
        try o.markUndone(id)
        #expect(try o.decisionCount(kind: "merge") == 0)
        #expect(try o.decisions(limit: 5).first?.undone == true)
    }
}

/// A synthetic archive for the service: people with numbers, Meta-only people, and group chats that tie them together.
private struct ReviewFixture {
    let t: TestArchive
    let b: PeopleBuilder

    init() throws {
        t = try TestArchive()
        b = PeopleBuilder(t)
        // numbers
        try b.phone("(212) 555-0111", name: "Alexander Demo", count: 40, start: base)
        try b.phone("(212) 555-0122", name: "Kate Placeholder", count: 20, start: base)
        try b.phone("(212) 555-0133", name: "Dana Other", count: 10, start: base)
        try b.phone("(212) 555-0144", name: "Pat Friend", count: 6, start: base)
        try b.phone("(212) 555-0155", name: "Lee Friend", count: 6, start: base)
        // Meta-only people
        try b.meta(.messenger, name: "Alex Demo", count: 60, start: base + 500 * day)
        try b.meta(.instagram, name: "Katherine Placeholder", count: 12, start: base + 500 * day, username: "kate_placeholder_x")
        try b.meta(.messenger, name: "Mx Stranger", count: 8, start: base + 500 * day)
        _ = try PeopleStore.rematch(db: t.db)
    }

    func service() throws -> ReviewService { try ReviewService(root: t.root) }
    func cleanup() { t.cleanup() }
}

@Suite struct ReviewServiceTests {
    private func handleID(_ f: ReviewFixture, _ normalized: String) throws -> Int64 {
        try f.t.db.scalarInt("SELECT id FROM handle WHERE normalized = '\(normalized)'")
    }

    @Test func queueListsTheBiggestMetaPersonFirstWithCandidatesAndProgress() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let st = s.state(queue: .crossService)
        #expect(st.progress.remaining == 2 && st.progress.merges == 0 && st.progress.reviewed == 0)
        let card = try #require(st.card)
        #expect(card.source.name == "Alex Demo" && card.source.messages == 60)
        #expect(card.source.services.map(\.key) == ["messenger"])
        let top = try #require(card.candidates.first)
        #expect(top.person.name == "Alexander Demo" && top.label == "likely" && top.reasons.contains { $0.contains("nickname") })
        #expect(top.person.phones == ["\u{2022}\u{2022}\u{2022}\u{2022} 0111"])             // masked: last four only
        #expect(top.person.services.map(\.key).contains("imessage") || top.person.services.map(\.key).contains("sms"))
        #expect(st.history.isEmpty)
    }

    @Test func mergeWritesOnlyPeopleSqliteLogsItAndUndoRestores() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try f.t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let archiveBefore = try Data(contentsOf: f.t.root.databaseURL)
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        let id = try s.merge(source: card.source.anchor, target: card.candidates[0].person.anchor)
        // the app's own reading of the overrides sees the merge
        let idx = try ArchiveReader(root: f.t.root).people(overrides: PeopleOverrides.read(root: f.t.root))
        let merged = try #require(idx.persons.values.first { $0.handles.contains { $0.service == .messenger } && $0.handles.count == 2 })
        #expect(merged.name?.hasPrefix("Alex") == true && merged.handles.contains { $0.service == nil })
        let after = s.state(queue: .crossService)
        #expect(after.progress.merges == 1 && after.progress.reviewed == 1 && after.progress.remaining == 1)
        #expect(after.card?.source.name == "Katherine Placeholder")
        #expect(after.history.first?.id == id && after.history.first?.kind == "merge")

        let undone = try s.undo()
        #expect(undone.id == id && undone.undone)
        let idx2 = try ArchiveReader(root: f.t.root).people(overrides: PeopleOverrides.read(root: f.t.root))
        #expect(idx2.persons.values.allSatisfy { $0.handles.count == 1 || $0.handles.contains { $0.service == nil } == false })
        #expect(idx2.persons.values.first { $0.name == "Alexander Demo" }?.handles.count == 1)
        let back = s.state(queue: .crossService)
        #expect(back.progress.merges == 0 && back.progress.remaining == 2 && back.card?.source.name == "Alex Demo")
        #expect(throws: ReviewError.self) { _ = try s.undo(id: id) }                  // already undone
        try f.t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(try Data(contentsOf: f.t.root.databaseURL) == archiveBefore)          // archive.sqlite itself was never written
    }

    @Test func notTheSamePersistsAcrossRestartAndUndoBringsItBack() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        var s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        try s.reject(source: card.source.anchor, targets: [card.candidates[0].person.anchor])
        #expect(s.state(queue: .crossService).card?.source.name == "Katherine Placeholder")
        #expect(s.state(queue: .crossService).progress.rejections == 1)
        s = try f.service()                                                          // a fresh process reads the rejection from people.sqlite
        #expect(s.state(queue: .crossService).progress.remaining == 1)
        try s.undo()
        s = try f.service()
        #expect(s.state(queue: .crossService).progress.remaining == 2)
    }

    @Test func skipHidesForTheSessionOnlyAndRefreshBringsItBack() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        s.skip(source: card.source.anchor)
        let st = s.state(queue: .crossService)
        #expect(st.progress.skipped == 1 && st.card?.source.name == "Katherine Placeholder")
        try s.refresh()
        #expect(s.state(queue: .crossService).card?.source.name == "Alex Demo")
        #expect(try ReviewService(root: f.t.root).state(queue: .crossService).card?.source.name == "Alex Demo")
    }

    @Test func renameIsUndoneToThePreviousName() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        try s.rename(person: card.source.anchor, to: "Alex D.")
        var now = try #require(s.state(queue: .crossService).card)
        #expect(now.source.name == "Alex D." && now.source.renamed)
        try s.rename(person: card.source.anchor, to: "Alex Demo Two")
        try s.undo()
        now = try #require(s.state(queue: .crossService).card)
        #expect(now.source.name == "Alex D.")
        try s.undo()
        now = try #require(s.state(queue: .crossService).card)
        #expect(now.source.name == "Alex Demo" && !now.source.renamed)
    }

    @Test func undoIsLastInFirstOut() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        let first = try s.rename(person: card.source.anchor, to: "Name 0")
        for i in 1...ReviewService.historyLimit { try s.rename(person: card.source.anchor, to: "Name \(i)") }
        let st = s.state(queue: .crossService)
        #expect(st.history.count == ReviewService.historyLimit && st.undoableID == st.history.first?.id)
        let err = #expect(throws: ReviewError.self) { _ = try s.undo(id: first) }
        #expect(err?.status == 409)
        let second = st.history[1].id
        #expect((try? s.undo(id: second)) == nil)                                      // only the newest live one
        try s.undo()
        #expect(s.state(queue: .crossService).card?.source.name == "Name 19")
        // undoing keeps walking back past the twenty shown
        for _ in 0..<ReviewService.historyLimit { try s.undo() }
        #expect(s.state(queue: .crossService).card?.source.name == "Alex Demo")
        #expect(s.state(queue: .crossService).undoableID == nil)
    }

    @Test func undoingAnOlderMergeWhileALaterOneBuildsOnItIsRefused() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let src = try handleID(f, "+12125550144")
        let c1 = try handleID(f, "+12125550155"), c2 = try handleID(f, "+12125550133")
        let m1 = try s.merge(source: src, target: c1)
        let m2 = try s.merge(source: src, target: c2)
        let err = #expect(throws: ReviewError.self) { _ = try s.undo(id: m1) }
        #expect(err?.status == 409)
        // still one person of all three; merging the same pair again is "already the same person"
        let again = #expect(throws: ReviewError.self) { _ = try s.merge(source: src, target: c1) }
        #expect(again?.status == 409)
        try s.undo(id: m2)
        try s.undo(id: m1)
        let idx = try ArchiveReader(root: f.t.root).people(overrides: PeopleOverrides.read(root: f.t.root))
        #expect(idx.persons.values.allSatisfy { $0.handles.count == 1 })
    }

    @Test func pageLoadsNeverOpenAnExistingPeopleFileForWriting() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let app = try PeopleOverrides(root: f.t.root)                                    // the app (or an older build) made the file
        try app.merge(["zz-a"], with: ["zz-b"])
        let url = PeopleOverrides.fileURL(root: f.t.root)
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let s = try f.service()
        _ = s.state(queue: .crossService); _ = s.state(queue: .duplicates); _ = s.search("alex", exclude: nil)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-journal"))
        // a missing file stays missing too
        let g = try ReviewFixture(); defer { g.cleanup() }
        _ = try g.service().state(queue: .crossService)
        #expect(!FileManager.default.fileExists(atPath: PeopleOverrides.fileURL(root: g.t.root).path))
    }

    @Test func changesMadeInTheAppWhileTheServerRunsAreNoticed() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        let anchor = card.source.anchor
        let keys = try f.t.db.prepare("SELECT normalized FROM handle WHERE id = \(anchor)")
        #expect(try keys.step())
        let key = try #require(keys.string(0))
        // the app renames the person after the server loaded
        let app = try PeopleOverrides(root: f.t.root)
        try app.rename([key], to: "Renamed In App")
        #expect(s.state(queue: .crossService).card?.source.name == "Renamed In App")
        // the server's own rename, then the app renames again: undoing the server's rename must not overwrite the app's
        try s.rename(person: anchor, to: "Server Name")
        try app.rename([key], to: "App Again")
        #expect(s.state(queue: .crossService).card?.source.name == "App Again")
        let err = #expect(throws: ReviewError.self) { _ = try s.undo() }
        #expect(err?.status == 409)
        #expect(try app.read().renames[key]?.name == "App Again")
        // a split made in the app is honored by the next merge: the split handle is not joined back
        try app.reset([key])
        let target = try #require(s.state(queue: .crossService).card?.candidates.first?.person.anchor)
        try s.merge(source: anchor, target: target)
        #expect(try app.read().links.count >= 1)
    }

    @Test func aDecisionAndItsUndoRowAreWrittenTogether() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let o = try PeopleOverrides(root: ArchiveRoot(url: dir))
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try o.atomically {
                _ = try o.mergeReturningNew(["a"], with: ["b"])
                _ = try o.logDecision(kind: "merge", label: "m", payload: [:])
                throw Boom()
            }
        }
        #expect(try o.read().links.isEmpty && o.decisions(limit: 5).isEmpty)              // all or nothing
        try o.atomically { _ = try o.mergeReturningNew(["a"], with: ["b"]); _ = try o.logDecision(kind: "merge", label: "m", payload: [:]) }
        #expect(try o.read().links.count == 1 && o.decisions(limit: 5).count == 1)
    }

    @Test func manualMergeWithAnySearchedPerson() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        let hits = s.search("pat fri", exclude: card.source.anchor)
        #expect(hits.map(\.name) == ["Pat Friend"])
        #expect(s.search("alex", exclude: card.source.anchor).allSatisfy { $0.anchor != card.source.anchor })
        #expect(s.search("x", exclude: nil).isEmpty)                                    // too short
        try s.merge(source: card.source.anchor, target: hits[0].anchor)
        #expect(s.search("pat friend", exclude: nil).first?.services.map(\.key).contains("messenger") == true)
    }

    @Test func peekReturnsAtMostTwelveShortTextMessagesInThreeModes() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let w = try f.b.writer()
        try f.t.db.transaction {
            for i in 0..<40 {
                let body = i == 39 ? String(repeating: "word ", count: 60) : (i == 7 ? "   " : "short \(i)")           // one blank body: not text
                try w.add(MessageRecord(participants: ["(212) 555-0166"], sender: i % 2 == 0 ? "(212) 555-0166" : nil, tsMs: base + Int64(i) * day, isFromMe: i % 2 == 1,
                                        service: i % 3 == 0 ? "sms" : "imessage", body: body))
            }
            try w.noteName(forRaw: "(212) 555-0166", name: "Peek Person")
        }
        _ = try PeopleStore.rematch(db: f.t.db)
        let s = try f.service()
        let p = try #require(s.search("peek person", exclude: nil).first)

        let latest = try s.peek(person: p.anchor)
        #expect(latest.mode == "latest" && latest.messages.count == 12 && latest.totalInThread == 40)
        #expect(latest.messages.last!.text.count == ReviewService.peekChars + 1 && latest.messages.last!.text.hasSuffix("\u{2026}"))   // 160 characters and an ellipsis
        #expect(latest.messages.map(\.ts) == latest.messages.map(\.ts).sorted())
        #expect(latest.firstTs == base && latest.lastTs == base + 39 * day)
        #expect(latest.messages.allSatisfy { $0.service == "sms" || $0.service == "imessage" })
        #expect(latest.messages[0].text == "short 28" && latest.messages[10].text == "short 38")

        let earliest = try s.peek(person: p.anchor, mode: .earliest)
        #expect(earliest.messages.count == 12 && earliest.messages[0].text == "short 0")
        #expect(!earliest.messages.contains { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })   // the blank row is skipped (texts 0...12 minus row 7)
        #expect(earliest.messages.map(\.text) == (0...12).filter { $0 != 7 }.map { "short \($0)" })

        let spread = try s.peek(person: p.anchor, mode: .spread)
        #expect(spread.messages.count == 12)
        #expect(spread.messages.first!.text == "short 0" && spread.messages.last!.text.hasPrefix("word "))      // both ends of the thread
        #expect(spread.messages.map(\.ts) == spread.messages.map(\.ts).sorted() && Set(spread.messages.map(\.ts)).count == 12)
        let gaps = zip(spread.messages, spread.messages.dropFirst()).map { ($1.ts - $0.ts) / day }
        #expect(gaps.allSatisfy { $0 >= 2 && $0 <= 5 })                                                           // evenly spaced, not clustered

        #expect(throws: ReviewError.self) { _ = try s.peek(person: 999_999) }
    }

    @Test func duplicateQueueSurfacesTwoNumbersWithNicknameNames() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try f.b.phone("(212) 555-0177", name: "Alex Demo", count: 15, start: base + 600 * day)       // a second number
        _ = try PeopleStore.rematch(db: f.t.db)
        let s = try f.service()
        let st = s.state(queue: .duplicates)
        let card = try #require(st.card)
        #expect(Set([card.source.name, card.candidates[0].person.name]) == ["Alexander Demo", "Alex Demo"])
        try s.merge(source: card.source.anchor, target: card.candidates[0].person.anchor)
        #expect(s.state(queue: .duplicates).card == nil)
    }
}

@Suite struct ReviewSiteTests {
    private func get(_ site: ReviewSite, _ path: String, query: [String: String] = [:], headers: [String: String] = [:], peer: String = "127.0.0.1") -> HTTPResponse {
        var h = ["Host": "127.0.0.1:8097", "X-Requested-With": ReviewSite.requestedWith]
        for (k, v) in headers { h[k] = v }
        return site.handle(HTTPRequest(method: "GET", path: path, query: query, headers: h, peer: peer))
    }
    private func post(_ site: ReviewSite, _ path: String, _ body: [String: Any], headers: [String: String] = [:], peer: String = "127.0.0.1") -> HTTPResponse {
        var h = ["Host": "127.0.0.1:8097", "X-Requested-With": ReviewSite.requestedWith, "Content-Type": "application/json"]
        for (k, v) in headers { h[k] = v }
        return site.handle(HTTPRequest(method: "POST", path: path, headers: h, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), peer: peer))
    }
    private func json(_ r: HTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:] }

    @Test func pageIsSelfContainedWithRelativeUrls() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let site = ReviewSite(service: try f.service())
        let r = site.handle(HTTPRequest(method: "GET", path: "/", headers: ["Host": "127.0.0.1:8097"]))
        let html = String(decoding: r.body, as: UTF8.self)
        #expect(r.status == 200 && r.headers["Content-Type"]?.hasPrefix("text/html") == true)
        #expect(html.contains("viewport") && html.contains("prefers-color-scheme: dark") && html.contains("archive-review"))
        #expect(!html.contains("http://") && !html.contains("https://") && !html.contains("localhost") && !html.contains("127.0.0.1"))
        #expect(!html.contains("src=\"/") && !html.contains("fetch(\"/") && !html.contains("innerHTML"))
        #expect(html.contains("api/state"))                                              // relative, no leading slash
    }

    @Test func csrfHostAndPeerChecks() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let site = ReviewSite(service: try f.service(), extraHosts: ["mac.example.net"], allowedLogins: ["owner@example.org"])
        let me = ["Tailscale-User-Login": "Owner@Example.org"]
        #expect(get(site, "/api/state").status == 200)                                      // direct local request: no login needed
        #expect(site.handle(HTTPRequest(method: "GET", path: "/api/state", headers: ["Host": "127.0.0.1"])).status == 403)       // no custom header
        #expect(post(site, "/api/skip", ["source": 1], headers: ["X-Requested-With": "xhr"]).status == 403)
        #expect(get(site, "/api/state", peer: "172.16.5.9").status == 403)                  // not loopback
        #expect(get(site, "/api/state", peer: "203.0.113.7").status == 403)
        #expect(get(site, "/api/state", headers: ["Host": "evil.example"]).status == 403)    // DNS rebinding
        #expect(get(site, "/api/state", headers: ["Host": "127.0.0.1:8097", "X-Forwarded-Host": "evil.example"]).status == 403)
        #expect(get(site, "/api/state", headers: ["Host": "mac.example.net:8451"].merging(me) { a, _ in a }).status == 200)               // via tailscale serve
        #expect(get(site, "/api/state", headers: ["Host": "127.0.0.1:8097", "X-Forwarded-Host": "mac.example.net"].merging(me) { a, _ in a }).status == 200)
        // no wildcard: another name in the same domain is refused, even with a good login
        #expect(get(site, "/api/state", headers: ["Host": "attacker.example.net"].merging(me) { a, _ in a }).status == 403)
        // identity: a proxied request without the login header, or with another person's, is refused
        #expect(get(site, "/api/state", headers: ["Host": "mac.example.net"]).status == 403)
        #expect(get(site, "/api/state", headers: ["Host": "mac.example.net", "Tailscale-User-Login": "other@example.org"]).status == 403)
        #expect(get(site, "/api/state", headers: ["Host": "127.0.0.1:8097", "X-Forwarded-For": "203.0.113.9"]).status == 403)    // proxied but anonymous
        #expect(post(site, "/api/skip", ["source": 1], headers: ["Origin": "https://evil.example"]).status == 403)
        #expect(post(site, "/api/skip", ["source": 1], headers: ["Origin": "https://mac.example.net:8451"].merging(me) { a, _ in a }).status == 200)
        #expect(site.handle(HTTPRequest(method: "DELETE", path: "/api/state", headers: ["Host": "127.0.0.1", "X-Requested-With": "archive-review"])).status == 405)
        #expect(get(site, "/nope").status == 404)
        #expect(ReviewSite(service: try f.service(), extraHosts: ["review.example.org"]).handle(
            HTTPRequest(method: "GET", path: "/api/state", headers: ["Host": "review.example.org", "X-Requested-With": "archive-review"])).status == 200)
    }

    @Test func mergeRejectUndoRenameSearchPeekOverJSON() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let site = ReviewSite(service: try f.service())
        let st = json(get(site, "/api/state", query: ["queue": "cross"]))
        let card = try #require(st["card"] as? [String: Any])
        let src = try #require((card["source"] as? [String: Any])?["anchor"] as? Int)
        let cand = try #require(((card["candidates"] as? [[String: Any]])?.first?["person"] as? [String: Any])?["anchor"] as? Int)

        let peek = json(get(site, "/api/peek", query: ["person": String(src)]))
        #expect((peek["messages"] as? [Any])?.count == 12 && peek["mode"] as? String == "latest")

        let merged = json(post(site, "/api/merge", ["source": src, "target": cand, "queue": "cross"]))
        #expect((merged["progress"] as? [String: Any])?["merges"] as? Int == 1)
        #expect(post(site, "/api/merge", ["source": src, "target": src]).status == 409)       // already one person now
        #expect(post(site, "/api/merge", ["source": 999_999, "target": cand]).status == 404)
        #expect(post(site, "/api/merge", ["source": src]).status == 400)

        let undone = json(post(site, "/api/undo", [:]))
        #expect((undone["progress"] as? [String: Any])?["merges"] as? Int == 0)

        let renamed = json(post(site, "/api/rename", ["person": src, "name": "Inline Name"]))
        #expect(((renamed["card"] as? [String: Any])?["source"] as? [String: Any])?["name"] as? String == "Inline Name")
        let rej = json(post(site, "/api/reject", ["source": src, "targets": [cand]]))
        #expect((rej["progress"] as? [String: Any])?["rejections"] as? Int == 1)

        let hits = try JSONSerialization.jsonObject(with: get(site, "/api/search", query: ["q": "kate", "exclude": String(src)]).body) as? [[String: Any]]
        #expect(hits?.first?["name"] as? String == "Kate Placeholder")
        #expect(json(post(site, "/api/refresh", [:]))["history"] != nil)
    }

    @Test func requestParsing() throws {
        let (req, len) = try HTTPParse.parseHead("POST /api/merge?queue=dups&q=a%20b HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\nX-Requested-With: archive-review", peer: "127.0.0.1")
        #expect(req.method == "POST" && req.path == "/api/merge" && req.query["queue"] == "dups" && req.query["q"] == "a b" && len == 12)
        #expect(req.header("x-requested-with") == "archive-review")
        #expect(throws: HTTPParse.Failure.self) { _ = try HTTPParse.parseHead("GET nothing HTTP/1.1\r\nHost: x", peer: "") }
        #expect(throws: HTTPParse.Failure.self) { _ = try HTTPParse.parseHead("GET / HTTP/1.1\r\nContent-Length: 99999999", peer: "") }
        #expect(throws: HTTPParse.Failure.self) { _ = try HTTPParse.parseHead("POST / HTTP/1.1\r\nTransfer-Encoding: chunked", peer: "") }
        #expect(throws: HTTPParse.Failure.self) { _ = try HTTPParse.parseHead("POST / HTTP/1.1\r\nContent-Length: abc", peer: "") }
        #expect(throws: HTTPParse.Failure.self) { _ = try HTTPParse.parseHead("POST / HTTP/1.1\r\nContent-Length: -5", peer: "") }
    }

    @Test func badPercentEscapesInTheQueryNeverCrash() throws {
        for q in ["q=%zz", "q=%", "q=%E0%A4", "%zz=1&q=%2", "q=a%20b&&x", "=", "q"] {
            let (req, _) = try HTTPParse.parseHead("GET /api/search?\(q) HTTP/1.1\r\nHost: x", peer: "127.0.0.1")
            #expect(req.path == "/api/search")
            _ = req.query
        }
        #expect(HTTPParse.parseQuery("q=%zz")["q"] == "%zz")                                // undecodable: kept as sent
        #expect(HTTPParse.parseQuery("q=%")["q"] == "%")
        #expect(HTTPParse.parseQuery("q=%E0%A4")["q"] == "%E0%A4")
        #expect(HTTPParse.parseQuery("q=a%20b&exclude=7")["q"] == "a b" && HTTPParse.parseQuery("q=a%20b&exclude=7")["exclude"] == "7")
        #expect(HTTPParse.parseQuery("flag")["flag"] == "")
        #expect(try HTTPParse.parseHead("GET /x%zz HTTP/1.1\r\nHost: x", peer: "").0.path == "/x%zz")
    }

    @Test func loopbackServerRoundTripAndRefusesNonLoopbackBind() async throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let site = ReviewSite(service: try f.service())
        let server = HTTPServer(host: "127.0.0.1", port: 0) { site.handle($0) }
        try server.start(); defer { server.stop() }
        #expect(server.port > 0)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/state?queue=cross")!)
        req.setValue(ReviewSite.requestedWith, forHTTPHeaderField: "X-Requested-With")
        let (data, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["card"] != nil)
        var bad = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/state")!)
        bad.httpMethod = "POST"
        bad.httpBody = Data("{}".utf8)
        let (_, badResp) = try await URLSession.shared.data(for: bad)
        #expect((badResp as? HTTPURLResponse)?.statusCode == 403)                         // POST without the custom header
        #expect(throws: ArchiveError.self) { try HTTPServer(host: "0.0.0.0", port: 0) { _ in .text("x") }.start() }
        #expect(throws: ArchiveError.self) { try HTTPServer(host: "172.16.5.5", port: 0) { _ in .text("x") }.start() }
    }

    /// One raw HTTP exchange on a fresh loopback connection: sends `bytes`, returns everything read until close (or "" on timeout).
    private func raw(_ port: UInt16, _ bytes: Data, keepOpen: Bool = false) -> String {
        let fd = connectLoopback(port: port)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var tv = timeval(tv_sec: 15, tv_usec: 0)      // generous: on a loaded box the server thread may wait seconds for a core
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count { let w = write(fd, raw.baseAddress! + off, min(raw.count - off, 16384)); if w <= 0 { break }; off += w }
        }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &chunk, chunk.count); if n <= 0 { break }; out.append(chunk, count: n) }
        return String(decoding: out, as: UTF8.self)
    }

    private func request(_ line: String, extra: String = "", body: Data = Data()) -> Data {
        Data(("\(line) HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Requested-With: archive-review\r\n\(extra)\r\n").utf8) + body
    }

    @Test func malformedRequestsGetAnswersAndNeverKillTheServer() async throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        let site = ReviewSite(service: try f.service())
        let server = HTTPServer(host: "127.0.0.1", port: 0) { site.handle($0) }
        try server.start(); defer { server.stop() }
        let port = server.port
        for q in ["%zz", "%", "%E0%A4", "a%2"] {
            let r = raw(port, request("GET /api/search?q=\(q)"))
            #expect(r.hasPrefix("HTTP/1.1 200"))
        }
        #expect(raw(port, request("POST /api/skip", extra: "Content-Length: abc\r\n")).hasPrefix("HTTP/1.1 400"))
        // a 400 KB body is answered 413 (not a reset connection)
        let big = Data(repeating: 0x61, count: 400_000)
        #expect(raw(port, request("POST /api/skip", extra: "Content-Length: 400000\r\n", body: big)).hasPrefix("HTTP/1.1 413"))
        #expect(raw(port, request("GET /healthz")).hasPrefix("HTTP/1.1 200"))
    }

    @Test func slowAndIdleConnectionsAreCutOffAndTheCapAnswers503() async throws {
        let site = ReviewSite(service: try ReviewFixture().service())
        // A 5 s deadline, not 1 s: on a loaded 4-core box (a small server running the whole suite) the process can be starved for
        // longer than a second between filling the slots and sending the next request, and the slots would already be free.
        let server = HTTPServer(host: "127.0.0.1", port: 0, requestDeadline: 5) { site.handle($0) }
        try server.start(); defer { server.stop() }
        let port = server.port
        // fill every slot with half-sent requests
        var idle: [Int32] = []
        for _ in 0..<HTTPServer.maxConnections {
            let fd = connectLoopback(port: port)
            _ = write(fd, "GET /healthz HTT", 16)
            idle.append(fd)
        }
        defer { idle.forEach { close($0) } }
        let filled = Date()
        try await Task.sleep(nanoseconds: 300_000_000)
        // Resuming after the sleep needs a free thread on the cooperative pool; on a loaded 4-core box running the whole
        // suite that can take longer than the deadline, after which the slots are free again and 503 cannot be observed.
        // The cap is asserted only when the request went out while the slots were still held; the cut-off always is.
        let sent = Date()
        let answer = raw(port, request("GET /healthz"))
        if sent.timeIntervalSince(filled) < 4 { #expect(answer.hasPrefix("HTTP/1.1 503"), "over the cap: refused at once") }
        try await Task.sleep(nanoseconds: 5_500_000_000)                              // the deadline frees the slots
        #expect(raw(port, request("GET /healthz")).hasPrefix("HTTP/1.1 200"))
    }
}

// MARK: tuning rules (username shapes, name conflicts, hub bias)

@Suite struct TuningRuleTests {
    private func cross(_ profiles: [SuggestionProfile], trace: SuggestionTrace? = nil) -> [Suggestion] {
        var o = SuggestionOptions()
        o.trace = trace
        return MatchSuggester.suggest(profiles: profiles, options: o).filter { $0.queue == .crossService }
    }

    @Test func usernameShapesNeedTheWholeUsernameOrAWholeTokenNeverASubstring() {
        // Three false-positive shapes: the letters sit inside a longer word.
        #expect(MatchSuggester.usernameScore("helinfixture", form("E. Lin")) == nil)
        #expect(MatchSuggester.usernameScore("thehornfixture", form("El Horn")) == nil)
        #expect(MatchSuggester.usernameScore("evazoqq", form("Amelia Zoq")) == nil)
        // They did match before (substring), which is what the rule removes.
        #expect(MatchSuggester.usernameScore("helinfixture", form("E. Lin"), substringShapes: true)?.score == 0.50)
        #expect(MatchSuggester.usernameScore("thehornfixture", form("El Horn"), substringShapes: true)?.score == 0.50)
        #expect(MatchSuggester.usernameScore("evazoqq", form("Amelia Zoq"), substringShapes: true)?.score == 0.50)
        // Whole username, with digits, dots and underscores stripped, or a whole token of it, still match.
        #expect(MatchSuggester.usernameScore("elin", form("E. Lin"))?.score == 0.50)
        #expect(MatchSuggester.usernameScore("e.lin", form("E. Lin"))?.score == 0.50)
        #expect(MatchSuggester.usernameScore("_elin_92", form("E. Lin"))?.score == 0.50)
        #expect(MatchSuggester.usernameScore("the.elin.shop", form("E. Lin"))?.score == 0.50)
        #expect(MatchSuggester.usernameScore("e.lin.studio", form("E. Lin"))?.score == 0.50)             // adjacent tokens "e" + "lin" join to "elin"
        #expect(MatchSuggester.usernameScore("elin92shop", form("E. Lin"))?.score == 0.50)               // digits split tokens: elin / shop
        #expect(MatchSuggester.usernameScore("lin.studio.e", form("E. Lin")) == nil)                     // not adjacent in the right order
        // Short first and last names must not hide inside longer words.
        #expect(MatchSuggester.usernameScore("joannaleezz", form("Ann Lee")) == nil)
        #expect(MatchSuggester.usernameScore("brandonkimzzz", form("Don Kim")) == nil)
        #expect(MatchSuggester.usernameScore("ann.lee.photo", form("Ann Lee"))?.score == 0.60)
        #expect(MatchSuggester.usernameScore("annlee92", form("Ann Lee"))?.score == 0.60)
        #expect(MatchSuggester.usernameScore("sadiefakebrookphoto", form("Sadie Fakebrook"))?.score == 0.60)
        #expect(MatchSuggester.usernameScore("azoq1990", form("Amelia Zoq"))?.score == 0.50)
        // First name + last initial: a token of the username, not the middle of a word.
        #expect(MatchSuggester.usernameScore("johnnyxyz", form("John Xavier"))?.score == 0.20)          // first name only
        #expect(MatchSuggester.usernameScore("john.x", form("John Xavier"))?.score == 0.35)
        #expect(MatchSuggester.usernameScore("johnx92", form("John Xavier"))?.score == 0.35)
        #expect(MatchSuggester.usernameScore("fan_johnx_pics", form("John Xavier"))?.score == 0.35)
    }

    @Test func aSubstringUsernameDoesNotCreateACard() {
        // Source names are one word, so only the username can relate them.
        let bad = cross([prof(1, ["Moonbeam"], instagram: true, usernames: ["helinfixture"], messages: 300), prof(2, ["E. Lin"], phone: 1)])
        #expect(bad.isEmpty)
        let good = cross([prof(1, ["Moonbeam"], instagram: true, usernames: ["elin_studio"], messages: 300), prof(2, ["E. Lin"], phone: 1)])
        #expect(good.count == 1 && good[0].candidates[0].personID == 2 && good[0].candidates[0].reasons.contains { $0.contains("first initial + last name") })
    }

    @Test func conflictingFirstOrLastNamesDropTheCandidateUnlessTheUsernameIsTheWholeName() {
        // Six shared group-mates would carry a card all by themselves; only the conflict rule keeps these pairs apart.
        let mates: [Int64] = [10, 11, 12, 13, 14, 15]
        func run(_ src: [String], _ cand: [String], users: [String] = [], trace: SuggestionTrace? = nil) -> [Suggestion] {
            cross([prof(1, src, instagram: true, usernames: users, messages: 300, co: Set(mates)), prof(2, cand, phone: 1, co: Set(mates))]
                  + mates.map { prof($0, ["Mate \($0 - 9) Fixturo"], phone: 1, co: [1, 2], groups: 2) }, trace: trace)
        }
        func has(_ s: [Suggestion]) -> Bool { s.contains { $0.sourceID == 1 && $0.candidates.contains { $0.personID == 2 } } }

        #expect(has(run(["Abel Qi"], ["Abel Qi"])))                                   // control: same person
        let trace = SuggestionTrace()
        #expect(!has(run(["Abel Qi"], ["Avis Qi"], trace: trace)))                      // different first names
        #expect(trace.dropped[SuggestionTrace.conflictRule] == 1 && trace.rulesByCard[SuggestionTrace.cardKey(.crossService, 1)] == [SuggestionTrace.conflictRule])
        #expect(has(run(["Abel Qi"], ["Abel Yoon"])))                                   // same first name, other last name: kept on six mates, as a possibility only
        #expect(has(run(["Alex Xu"], ["Alexander Xu"])))                                // nickname: not a conflict
        #expect(has(run(["A. Qi"], ["Avis Qi"])))                                       // an initial is not a different name
        #expect(has(run(["Anne Smith-Jones"], ["Anne Smith"])))                         // hyphenated surname
        #expect(has(run(["Qi Abel"], ["Abel Qi"])))                                     // reordered
        #expect(has(run(["Abel"], ["Avis Qi"])))                                        // no last name on one side: nothing to conflict
        // The username spelling the candidate's whole name overrides the conflict; a longer username does not.
        #expect(has(run(["Abel Qi"], ["Avis Qi"], users: ["avis_qi_92"])))
        #expect(!has(run(["Abel Qi"], ["Avis Qi"], users: ["avis.qi.studio"])))         // a two-letter surname is not found inside a longer username
        #expect(has(run(["Adam Fixturo"], ["Anya Fixturo"], users: ["anya.fixturo.studio"])))   // first and last name inside the username: also enough
        #expect(!has(run(["Abel Qi"], ["Avis Qi"], users: ["avis.studio"])))
        // The mirror: the username sits on the candidate and spells the candidate's own name. That says nothing about the source.
        func runMirrored(_ src: [String], _ cand: [String], users: [String]) -> [Suggestion] {
            cross([prof(1, src, messenger: true, messages: 300, co: Set(mates)), prof(2, cand, instagram: true, usernames: users, co: Set(mates))]
                  + mates.map { prof($0, ["Mate \($0 - 9) Fixturo"], phone: 1, co: [1, 2], groups: 2) })
        }
        #expect(!has(runMirrored(["Abel Qi"], ["Avis Qi"], users: ["avisqi"])))
        #expect(!has(runMirrored(["Abel Qi"], ["Avis Qi"], users: ["avis_qi_92"])))
        #expect(has(runMirrored(["Avis Qi"], ["Abel Qi"], users: ["avisqi"])))        // the username spells the source's name: one person
        // A display name that is only a last initial fits the full surname.
        #expect(has(run(["Sadie M"], ["Sadie Fakebrook"], users: ["sadiem.photo"])))
        #expect(has(run(["Sadie M."], ["Sadie Fakebrook"])))
        // A descriptive display name with a full-name username.
        #expect(has(run(["Sadie Travels"], ["Sadie Fakebrook"], users: ["sadiefakebrookphoto"])))
        // A changed surname: same first name, different last name.
        let married = run(["Jane Doe"], ["Jane Smith"])                                   // six shared mates: distinctive
        #expect(has(married))
        let top = married.first { $0.sourceID == 1 }!.candidates.first { $0.personID == 2 }!
        #expect(top.score <= 0.54 && ReviewService.label(top.score) == "possible" && top.reasons.contains { $0.contains("last names differ") })
        #expect(has(run(["Jane Doe"], ["Jane Smith"], users: ["janesmithphoto"])))
        #expect(!has(cross([prof(1, ["Jane Doe"], messenger: true, messages: 300, co: [10]), prof(2, ["Jane Smith"], phone: 1, co: [10]),
                            prof(10, ["Mate Fixturo"], phone: 1, co: [1, 2], groups: 2)])))   // one mate and no username: not enough
        #expect(!has(run(["Jane Doe"], ["Janet Smith"])))                                 // different first names still conflict
        // Either spelling of a person may be the compatible one.
        #expect(has(run(["Abel Qi", "Abi Quill"], ["Abel Qi"])))
    }

    @Test func hubGroupMatesCountForLittleAndNeedANameOrDistinctiveEvidence() {
        #expect(MatchSuggester.mateWeight(coMembers: 5) == 1.0)
        #expect(MatchSuggester.mateWeight(coMembers: 300) < 0.08)
        #expect(MatchSuggester.mateWeight(coMembers: 30) > MatchSuggester.mateWeight(coMembers: 60))
        let hubCo = Set((1000..<1400).map(Int64.init)).union([1, 2])                   // a person in group chats with hundreds of people
        let hub = prof(100, ["Hub Person"], phone: 1, co: hubCo, groups: 60)

        // Only the hub is shared: no card, even though it is a group-mate of both.
        #expect(cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: [100]), prof(2, ["Zed Quill"], phone: 1, co: [100]), hub]).isEmpty)
        // Five hubs shared: counted as five full group-mates before (each is in only one group chat), nearly nothing now.
        let hubs: [Int64] = [100, 101, 102, 103, 104]
        let hubProfiles = hubs.map { prof($0, ["Hub \($0) Person"], phone: 1, co: hubCo, groups: 1) }
        let trace = SuggestionTrace()
        let viaHubs = cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: Set(hubs)), prof(2, ["Zed Quill"], phone: 1, co: Set(hubs))] + hubProfiles, trace: trace)
        #expect(viaHubs.isEmpty)
        #expect(trace.dropped[SuggestionTrace.hubRule] == 1 && trace.rulesByCard[SuggestionTrace.cardKey(.crossService, 1)] == [SuggestionTrace.hubRule])

        // A name relation keeps a candidate even when the hub is the only group evidence.
        let named = cross([prof(1, ["Zed Quill"], messenger: true, messages: 300, co: [100]), prof(2, ["Zed Quill"], phone: 1, co: [100]), hub])
        #expect(named.count == 1 && named[0].candidates[0].personID == 2)

        // Five ordinary mates in common are distinctive: shown with no name relation, but only as "possible".
        let five: [Int64] = [20, 21, 22, 23, 24]
        func mates(for cands: [Int64]) -> [SuggestionProfile] { five.map { prof($0, ["Mate \($0) Fixturo"], phone: 1, co: Set([1] + cands), groups: 2) } }
        let one = cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: Set(five + [100])), prof(2, ["Zed Quill"], phone: 1, co: [100]),
                         prof(3, ["Wren Hale"], phone: 1, co: Set(five)), hub] + mates(for: [3]))
        #expect(one.count == 1 && one[0].candidates.map(\.personID) == [3])             // the hub-only candidate 2 is gone
        let top = one[0].candidates[0]
        #expect(top.groupOnly && top.score <= 0.54 && ReviewService.label(top.score) == "possible")
        #expect(top.reasons.contains { $0.contains("only evidence") })

        // Two candidates with the same group evidence: neither clearly beats the other, so neither is shown.
        let tie = cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: Set(five)), prof(3, ["Wren Hale"], phone: 1, co: Set(five)),
                         prof(4, ["Rue Park"], phone: 1, co: Set(five))] + mates(for: [3, 4]))
        #expect(tie.isEmpty)
        // 5 against 4 is not a clear margin either; 5 against 2 is (and the 2 is below the floor on its own).
        let close = cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: Set(five)), prof(3, ["Wren Hale"], phone: 1, co: Set(five)),
                           prof(4, ["Rue Park"], phone: 1, co: Set(five.prefix(4)))] + five.map { prof($0, ["Mate \($0) Fixturo"], phone: 1, co: $0 < 24 ? [1, 3, 4] : [1, 3], groups: 2) })
        #expect(close.isEmpty)
        let clear = cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: Set(five)), prof(3, ["Wren Hale"], phone: 1, co: Set(five)),
                           prof(4, ["Rue Park"], phone: 1, co: Set(five.prefix(2)))] + five.map { prof($0, ["Mate \($0) Fixturo"], phone: 1, co: $0 < 22 ? [1, 3, 4] : [1, 3], groups: 2) })
        #expect(clear.count == 1 && clear[0].candidates.map(\.personID) == [3])

        // The same few sociable people as the candidate for everybody: a candidate who knows hundreds is discounted too.
        let social = prof(3, ["Wren Hale"], phone: 1, co: Set(five).union((2000..<2300).map(Int64.init)))
        #expect(cross([prof(1, ["Moonbeam"], messenger: true, messages: 300, co: Set(five)), social] + mates(for: [3])).isEmpty)
    }
}

// MARK: richer context, the Who's-this queue, "No match"

private let crewNames = ["Ada", "Bea", "Cal", "Dev", "Eli", "Fay", "Gus", "Hal"].map { $0 + " Crewe" }
private func crewPhone(_ i: Int) -> String { "(212) 555-02\(10 + i)" }

/// The review fixture plus eight shared friends (each with a number and a Messenger account of the same name), a Messenger group that holds the
/// friends and Alex Demo, and four titled phone groups that hold the friends and Alexander Demo. Hal sits in one more big group.
private func addCrew(_ f: ReviewFixture) throws {
    for (i, n) in crewNames.enumerated() {
        try f.b.phone(crewPhone(i), name: n, count: 2, start: base)
        try f.b.meta(.messenger, name: n, count: 2, start: base)
    }
    func group(_ title: String, phones: [String] = [], metas: [ServiceHandle] = []) throws {
        let w = try f.b.writer()
        w.groupKeySuffix = "g-\(title)"
        try f.t.db.transaction {
            var r = MessageRecord(participants: phones, sender: phones.first, tsMs: base + 900 * day, isFromMe: false, service: metas.isEmpty ? "sms" : "messenger", body: "hello \(title)")
            if !metas.isEmpty { r.participantHandles = metas; r.senderHandle = metas.first }
            try w.add(r)
            let up = try f.t.db.prepare("UPDATE thread SET title = ? WHERE id = ?")
            up.bind(1, title).bind(2, w.lastThreadID)
            try up.run()
        }
    }
    try group("Synthetic Crew", metas: crewNames.map { ServiceHandle.facebook(name: $0) } + [ServiceHandle.facebook(name: "Alex Demo")])
    try group("Phone Crew", phones: (0..<8).map(crewPhone) + ["(212) 555-0111"])
    for t in ["Extra One", "Extra Two", "Extra Three"] { try group(t, phones: [crewPhone(0), crewPhone(1), "(212) 555-0111"]) }
    try group("Big Hal", phones: [crewPhone(7)] + (31...35).map { "(212) 555-02\($0)" })
    _ = try PeopleStore.rematch(db: f.t.db)
}

@Suite struct ReviewContextTests {
    @Test func theCardNamesSharedGroupMatesMostDistinctiveFirstAndTheThreadsOnEachSide() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addCrew(f)
        let s = try f.service()
        let card = try #require(s.state(queue: .crossService).card)
        #expect(card.source.name == "Alex Demo")
        let top = try #require(card.candidates.first)
        #expect(top.person.name == "Alexander Demo")
        // Eight shared friends; six are named. Hal is in another big group, so he is the least distinctive; Gus ties with the rest and sorts last.
        #expect(top.context.totalMates == 8)
        #expect(top.context.mates == Array(crewNames.prefix(6)))
        #expect(top.context.sourceThreads == ["Synthetic Crew"])
        #expect(top.context.candidateThreads.count == ReviewService.maxThreads && top.context.candidateThreads[0] == "Phone Crew")
        #expect(Set(top.context.candidateThreads).isSubset(of: ["Phone Crew", "Extra One", "Extra Two", "Extra Three"]))
        #expect(top.sharedGroups == 8)
        // the CLI/JSON form carries it too
        let enc = try JSONEncoder().encode(card)
        #expect(String(decoding: enc, as: UTF8.self).contains("\"candidateThreads\""))
    }

    @Test func peekAndContextStayOnDemandAndNameNothingElse() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addCrew(f)
        let site = ReviewSite(service: try f.service())
        let h = ["Host": "127.0.0.1:8097", "X-Requested-With": ReviewSite.requestedWith]
        let st = try #require(try JSONSerialization.jsonObject(with: site.handle(HTTPRequest(method: "GET", path: "/api/state", query: ["queue": "cross"], headers: h, peer: "127.0.0.1")).body) as? [String: Any])
        let src = try #require(((st["card"] as? [String: Any])?["source"] as? [String: Any])?["anchor"] as? Int)
        // state alone carries no message text
        let raw = String(decoding: site.handle(HTTPRequest(method: "GET", path: "/api/state", query: ["queue": "cross"], headers: h, peer: "127.0.0.1")).body, as: UTF8.self)
        #expect(!raw.contains("m0") && !raw.contains("\"text\""))
        for mode in ["latest", "earliest", "spread"] {
            let r = site.handle(HTTPRequest(method: "GET", path: "/api/peek", query: ["person": String(src), "mode": mode], headers: h, peer: "127.0.0.1"))
            let j = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
            #expect(r.status == 200 && j["mode"] as? String == mode && (j["messages"] as? [Any])?.count == 12 && j["firstTs"] != nil && j["totalInThread"] as? Int == 60)
        }
        #expect(site.handle(HTTPRequest(method: "GET", path: "/api/peek", query: ["person": String(src), "mode": "bogus"], headers: h, peer: "127.0.0.1")).status == 400)
    }
}

private func addLoners(_ f: ReviewFixture) throws {
    try f.b.meta(.messenger, name: "Zed Loner", count: 30, start: base + 700 * day)
    try f.b.meta(.instagram, name: "Ivy Pair", count: 15, start: base + 700 * day)
    try f.b.meta(.messenger, name: "Wren Tiny", count: 14, start: base + 700 * day)           // under 15 messages: not asked about
    _ = try PeopleStore.rematch(db: f.t.db)
}

@Suite struct WhosThisQueueTests {
    private func handleID(_ f: ReviewFixture, _ normalized: String) throws -> Int64 {
        try f.t.db.scalarInt("SELECT id FROM handle WHERE normalized = '\(normalized)'")
    }
    private func tables(_ url: URL) throws -> [String] {
        let db = try Database(path: url.path, readOnly: true)
        let st = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        var out: [String] = []
        while try st.step() { out.append(st.string(0) ?? "") }
        return out
    }

    @Test func listsMetaOnlyPeopleWithAtLeastFifteenMessagesAndNoSuggestionBiggestFirst() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addLoners(f)
        let s = try f.service()
        let st = s.state(queue: .whos)
        #expect(st.progress.queues == ["cross": 2, "dups": 0, "who": 2] && st.progress.remaining == 2)
        let card = try #require(st.card)
        #expect(card.queue == "who" && card.source.name == "Zed Loner" && card.source.messages == 30 && card.candidates.isEmpty && card.context != nil)
        // the boundary: exactly 15 is in, 14 is out; people with a suggestion (Alex Demo, Katherine) and tiny threads (Mx Stranger) are not here
        let all = s.remainingCards(.whos).compactMap(\.source.name)
        #expect(all == ["Zed Loner", "Ivy Pair"])
        // the other queues are untouched
        #expect(s.state(queue: .crossService).card?.source.name == "Alex Demo")
        #expect(s.suggestionCount[.whos] == 2)
    }

    @Test func aWhosThisCardShowsTheOwnGroupMatesAndThreads() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addCrew(f)
        // Zed sits in a titled Messenger group with three of the friends
        let w = try f.b.writer(); w.groupKeySuffix = "zed"
        try f.t.db.transaction {
            var r = MessageRecord(participants: [], sender: nil, tsMs: base + 800 * day, isFromMe: false, service: "messenger", body: "zed group")
            r.participantHandles = [ServiceHandle.facebook(name: crewNames[0]), ServiceHandle.facebook(name: crewNames[1]), ServiceHandle.facebook(name: crewNames[2]), ServiceHandle.facebook(name: "Zed Loner")]
            r.senderHandle = ServiceHandle.facebook(name: "Zed Loner")
            try w.add(r)
            let up = try f.t.db.prepare("UPDATE thread SET title = ? WHERE id = ?")
            up.bind(1, "Zed's Group").bind(2, w.lastThreadID)
            try up.run()
        }
        try addLoners(f)
        let s = try f.service()
        let card = try #require(s.state(queue: .whos).card)
        #expect(card.source.name == "Zed Loner")
        let ctx = try #require(card.context)
        #expect(ctx.totalMates == 3 && Set(ctx.mates) == Set(crewNames.prefix(3)) && ctx.sourceThreads == ["Zed's Group"])
    }

    @Test func noMatchIsAnUndoableDecisionInTheLogThatKeepsEverythingElseAsItWas() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addLoners(f)
        // the user's existing decisions, made through the same code (a merge, a rejection, a rename)
        var s = try f.service()
        let alex = try #require(s.state(queue: .crossService).card)
        try s.merge(source: alex.source.anchor, target: alex.candidates[0].person.anchor)
        let kat = try #require(s.state(queue: .crossService).card)
        try s.reject(source: kat.source.anchor, targets: [kat.candidates[0].person.anchor])
        try s.rename(person: try handleID(f, "+12125550133"), to: "Dana Renamed")
        let url = PeopleOverrides.fileURL(root: f.t.root)
        let tablesBefore = try tables(url)
        let overridesBefore = PeopleOverrides.read(root: f.t.root), rejectionsBefore = PeopleOverrides.readRejections(root: f.t.root)
        let logBefore = PeopleOverrides.readDecisions(root: f.t.root, limit: 100)
        let mappingBefore = try ArchiveReader(root: f.t.root).people(overrides: overridesBefore).persons.values.map { $0.handles.map(\.normalized).sorted() }.sorted { $0.joined() < $1.joined() }

        s = try f.service()
        let zed = try #require(s.state(queue: .whos).card)
        #expect(zed.source.name == "Zed Loner")
        let id = try s.noMatch(source: zed.source.anchor)
        var st = s.state(queue: .whos)
        #expect(st.card?.source.name == "Ivy Pair" && st.progress.noMatches == 1 && st.progress.queues["who"] == 1)
        #expect(st.history.first?.id == id && st.history.first?.kind == "none" && st.undoableID == id)
        // persisted: a fresh process does not ask again
        s = try f.service()
        #expect(s.state(queue: .whos).card?.source.name == "Ivy Pair" && s.state(queue: .whos).progress.remaining == 1)
        // nothing else moved: same tables (no migration), same corrections, same person mapping, earlier log rows untouched
        #expect(try tables(url) == tablesBefore)
        #expect(PeopleOverrides.read(root: f.t.root) == overridesBefore && PeopleOverrides.readRejections(root: f.t.root) == rejectionsBefore)
        let logMid = PeopleOverrides.readDecisions(root: f.t.root, limit: 100)
        #expect(Array(logMid.dropFirst()) == logBefore && logMid.first?.kind == "none")
        let mappingMid = try ArchiveReader(root: f.t.root).people(overrides: PeopleOverrides.read(root: f.t.root)).persons.values.map { $0.handles.map(\.normalized).sorted() }.sorted { $0.joined() < $1.joined() }
        #expect(mappingMid == mappingBefore)

        // undo brings the person back, and the log reads as before plus one undone row
        try s.undo()
        st = s.state(queue: .whos)
        #expect(st.card?.source.name == "Zed Loner" && st.progress.noMatches == 0 && st.progress.remaining == 2)
        s = try f.service()
        #expect(s.state(queue: .whos).card?.source.name == "Zed Loner")
        let logAfter = PeopleOverrides.readDecisions(root: f.t.root, limit: 100)
        #expect(Array(logAfter.dropFirst()) == logBefore && logAfter.first?.kind == "none" && logAfter.first?.undone == true)
        #expect(PeopleOverrides.read(root: f.t.root) == overridesBefore && PeopleOverrides.readRejections(root: f.t.root) == rejectionsBefore)
    }

    @Test func mergingFromTheQueueLinksAnyoneFoundByManualSearchAndUndoReturnsIt() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addLoners(f)
        let s = try f.service()
        let zed = try #require(s.state(queue: .whos).card)
        let target = try #require(s.search("lee friend", exclude: zed.source.anchor).first)
        let id = try s.merge(source: zed.source.anchor, target: target.anchor)
        var st = s.state(queue: .whos)
        #expect(st.card?.source.name == "Ivy Pair" && st.progress.merges == 1 && st.progress.queues["who"] == 1)
        try s.undo(id: id)
        st = s.state(queue: .whos)
        #expect(st.card?.source.name == "Zed Loner" && st.progress.queues["who"] == 2)
    }

    @Test func peopleLinkedBehindTheQueuesBackOrRejectedBeforeAreNotAsked() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addLoners(f)
        let s = try f.service()
        // somebody with a number cannot be "no match"
        let err = #expect(throws: ReviewError.self) { _ = try s.noMatch(source: try handleID(f, "+12125550144")) }
        #expect(err?.status == 409)
        #expect(throws: ReviewError.self) { _ = try s.noMatch(source: 999_999) }
        // a person the user already said "not the same" about (so a card was seen) does not reappear here after a recompute
        let alex = try #require(s.state(queue: .crossService).card)
        try s.reject(source: alex.source.anchor, targets: alex.candidates.map { $0.person.anchor })
        try s.refresh()
        #expect(!s.remainingCards(.whos).contains { $0.source.name == "Alex Demo" })
        // skipping hides for the session only
        let zed = try #require(s.state(queue: .whos).card)
        s.skip(source: zed.source.anchor)
        #expect(s.state(queue: .whos).card?.source.name == "Ivy Pair")
        try s.refresh()
        #expect(s.state(queue: .whos).card?.source.name == "Zed Loner")
    }

    @Test func onlyTheCardOfARejectLeavesTheQueueNotSomebodyWhoWasJustTheCandidate() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addLoners(f)
        let s = try f.service()
        let zed = try handleID(f, "fb:zed loner"), ivy = try handleID(f, "ig:ivy pair")
        try s.reject(source: zed, targets: [ivy])
        try s.refresh()
        let names = s.remainingCards(.whos).map(\.source.name)
        #expect(!names.contains("Zed Loner") && names.contains("Ivy Pair"))
    }

    @Test func theThirdQueueOverJSONAndThePageHasItsTab() throws {
        let f = try ReviewFixture(); defer { f.cleanup() }
        try addLoners(f)
        let site = ReviewSite(service: try f.service())
        let h = ["Host": "127.0.0.1:8097", "X-Requested-With": ReviewSite.requestedWith, "Content-Type": "application/json"]
        func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any] = [:]) -> (Int, [String: Any]) {
            let r = site.handle(HTTPRequest(method: method, path: path, query: query, headers: h, body: method == "POST" ? ((try? JSONSerialization.data(withJSONObject: body)) ?? Data()) : Data(), peer: "127.0.0.1"))
            return (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
        }
        let (code, st) = call("GET", "/api/state", query: ["queue": "who"])
        let src = try #require(((st["card"] as? [String: Any])?["source"] as? [String: Any])?["anchor"] as? Int)
        #expect(code == 200 && (st["progress"] as? [String: Any])?["queue"] as? String == "who")
        let (c2, after) = call("POST", "/api/nomatch", body: ["source": src, "queue": "who"])
        #expect(c2 == 200 && (after["progress"] as? [String: Any])?["noMatches"] as? Int == 1)
        #expect(call("POST", "/api/nomatch", body: [:]).0 == 400)
        let (_, undone) = call("POST", "/api/undo", body: ["queue": "who"])
        #expect((undone["progress"] as? [String: Any])?["noMatches"] as? Int == 0)
        let page = String(decoding: site.handle(HTTPRequest(method: "GET", path: "/", headers: ["Host": "127.0.0.1:8097"])).body, as: UTF8.self)
        #expect(page.contains("tabWho") && page.contains("api/nomatch") && page.contains("mode=") && !page.contains("innerHTML"))
        // phone layout: short tab labels on narrow screens, and no pick or merge keys advertised on a Who's-this card
        #expect(page.contains("\"Who?\"") && page.contains("who ? null :") && page.contains("white-space:nowrap"))
    }
}
