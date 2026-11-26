import Testing
import Foundation
@testable import ArchiveCore

// Real Instagram usernames inferred from an export's follower lists and story links. Synthetic names and usernames only.

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

/// An Instagram export with the follower lists and the owner's profile page, plus one folder per thread.
private struct IGExport {
    let dir = Fixtures.tempDir("igu")
    var ex: URL { dir.appendingPathComponent("export") }
    static let ig = "your_instagram_activity"

    func list(_ file: String, _ users: [String]) {
        let d = ex.appendingPathComponent("connections/followers_and_following")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let rows = users.map { "<div class=\"pam\"><a target=\"_blank\" href=\"https://www.instagram.com/\($0)\">\($0)</a><div>Jan 01, 2020 1:00 pm</div></div>" }.joined()
        try! "<html><body>\(rows)</body></html>".write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func owner(_ username: String) {
        let d = ex.appendingPathComponent("personal_information/personal_information")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try! "<html><body><table><tr><td class=\"_2pin\">Username<div><div>\(username)</div></div></td></tr></table></body></html>"
            .write(to: d.appendingPathComponent("personal_information.html"), atomically: true, encoding: .utf8)
    }

    /// A 1:1 thread titled `name`; `stories` are story owners whose links appear in it.
    func thread(_ name: String, id: String, stories: [String] = [], category: String = "inbox", t: String = "Jan 05, 2019 3:20 pm") {
        var msgs: [MetaFixtures.Msg] = [.init(sender: "Test Me", text: "hi", time: t)]
        for (i, s) in stories.enumerated() {
            msgs.append(.init(sender: i % 2 == 0 ? name : "Test Me", text: "shared a story", time: t, shareLink: "https://instagram.com/stories/\(s)/17\(i)"))
        }
        msgs.append(.init(sender: name, text: "hello", time: t))
        MetaFixtures.writeThread(root: ex, activity: Self.ig, category: category, folder: Self.slug(name) + "_" + id,
                                 pages: [MetaFixtures.igPage(title: name, msgs)])
    }

    func group(_ names: [String], id: String) {
        let msgs = names.map { MetaFixtures.Msg(sender: $0, text: "yo", time: "Jan 06, 2019 9:00 am") }
        MetaFixtures.writeThread(root: ex, activity: Self.ig, folder: "group_" + id, pages: [MetaFixtures.igPage(title: "Participants: " + names.joined(separator: ", "), msgs)])
    }

    static func slug(_ name: String) -> String { InstagramUsernames.normalize(name) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// Imports an export into a fresh archive and returns what `handle_username` holds, keyed by display name.
private func usernames(_ t: TestArchive) throws -> [String: String] {
    var out: [String: String] = [:]
    let st = try t.db.prepare("""
        SELECT h.raw, u.username, u.confidence, u.method FROM handle_username u JOIN handle h ON h.id = u.handle_id ORDER BY h.raw
        """)
    while try st.step() { out[st.string(0) ?? ""] = "\(st.string(1) ?? "")|\(st.string(2) ?? "")|\(st.string(3) ?? "")" }
    return out
}

@Suite struct InstagramUsernameResolverTests {
    @Test func normalizationKeepsOnlyLatinLettersAndDigits() {
        #expect(InstagramUsernames.normalize("José Núñez") == "josenunez")
        #expect(InstagramUsernames.normalize("a.b_c-9 D") == "abc9d")
        #expect(InstagramUsernames.normalize("Ｆｕｌｌ") == "full")
        #expect(InstagramUsernames.normalize("\u{5C71}\u{7530}") == "")
    }

    private let pool = IGUsernamePool(["dana.ford", "parkeli", "miras", "nquest", "the_rae_ollie_shop", "samreed", "sam_reed", "zephyrwolf",
                                       "marigold.testvoa", "noise_one", "noise.two", "loufrost", "lou_frost", "kate.k"])

    @Test func exactTitleAndNameCombinationsAreHigh() {
        #expect(InstagramUsernames.resolve(name: "Dana Ford", storyOwners: [], pool: pool) == IGUsernameMatch(username: "dana.ford", confidence: .high, method: "title-exact"))
        #expect(InstagramUsernames.resolve(name: "Eli Park", storyOwners: [], pool: pool)?.method == "name-first-last")     // last + first
        #expect(InstagramUsernames.resolve(name: "Mira Stone", storyOwners: [], pool: pool)?.method == "name-initial")      // first + last initial
        #expect(InstagramUsernames.resolve(name: "Noel Quest", storyOwners: [], pool: pool)?.method == "name-initial")      // first initial + last
        #expect(InstagramUsernames.resolve(name: "Mira Stone", storyOwners: [], pool: pool)?.confidence == .high)
    }

    @Test func accentsAndCaseDoNotMatter() {
        let p = IGUsernamePool(["andres.penafixture"])
        #expect(InstagramUsernames.resolve(name: "ANDRÉS  Peñafixture", storyOwners: [], pool: p)?.username == "andres.penafixture")
    }

    @Test func aStoryThatAgreesConfirmsAndOneThatContradictsIsFlaggedButTheNameMatchStands() {
        let agree = InstagramUsernames.resolve(name: "Dana Ford", storyOwners: ["dana.ford"], pool: pool)
        #expect(agree?.method == "title-exact+story" && agree?.confidence == .high)
        let clash = InstagramUsernames.resolve(name: "Dana Ford", storyOwners: ["somebody_else"], pool: pool)
        #expect(clash?.username == "dana.ford" && clash?.method == "title-exact+story-conflict" && clash?.confidence == .high)
        // two different story owners say nothing
        #expect(InstagramUsernames.resolve(name: "Dana Ford", storyOwners: ["a_one", "b_two"], pool: pool)?.method == "title-exact")
    }

    @Test func aLoneStoryOwnerStandsAloneWhenTheNameMatchesNothing() {
        let m = InstagramUsernames.resolve(name: "Kit Moon", storyOwners: ["moonbeam_k"], pool: pool)
        #expect(m == IGUsernameMatch(username: "moonbeam_k", confidence: .high, method: "story"))
        #expect(InstagramUsernames.resolve(name: "Kit Moon", storyOwners: ["a", "b"], pool: pool) == nil)
    }

    @Test func aLoneStoryOwnerNeedsToBeListedOrOverlapTheName() {
        // not in the pool and unrelated to the name: a third party's story, never claimed
        #expect(InstagramUsernames.resolve(name: "Kit Moon", storyOwners: ["totally_other"], pool: pool) == nil)
        // in the pool: stands alone
        let listed = InstagramUsernames.resolve(name: "Kit Moon", storyOwners: ["noise_one"], pool: pool)
        #expect(listed == IGUsernameMatch(username: "noise_one", confidence: .high, method: "story"))
    }

    @Test func aShortSingleNameEqualToAUsernameIsOnlyLowUnlessAStoryAgrees() {
        let p = IGUsernamePool(["mike", "jonathan", "mike2020"])
        #expect(InstagramUsernames.resolve(name: "Mike", storyOwners: [], pool: p) == IGUsernameMatch(username: "mike", confidence: .low, method: "low-short-name"))
        #expect(InstagramUsernames.resolve(name: "Mike", storyOwners: ["mike"], pool: p)?.confidence == .high)
        // longer than six letters, or with digits: still high
        #expect(InstagramUsernames.resolve(name: "Jonathan", storyOwners: [], pool: p)?.confidence == .high)
        #expect(InstagramUsernames.resolve(name: "Mike2020", storyOwners: [], pool: p)?.confidence == .high)
    }

    @Test func aUsernameHighOnTwoHandlesIsDroppedFromAllAndALowShadowedByAHighGoesToo() {
        func m(_ u: String, _ c: IGConfidence) -> IGUsernameMatch { IGUsernameMatch(username: u, confidence: c, method: "t") }
        let r = InstagramUsernames.reconcile([(1, m("dup", .high)), (2, m("dup", .high)), (3, m("dup", .low)),
                                              (4, m("solo", .high)), (5, m("solo", .low)), (6, m("fine", .low)), (7, m("fine", .low))])
        #expect(r.duplicateHighDropped == 3)      // two highs and the low sharing the username
        #expect(r.lowDroppedForHigh == 1)
        #expect(r.kept.map { $0.0 } == [4, 6, 7])      // dup gone everywhere; the low "solo" goes; lows alone are left
    }

    @Test func ambiguousNamesGiveNothingUnlessAStoryOwnerIsAmongTheCandidates() {
        // samreed and sam_reed spell the same letters: two usernames, so no claim (and no low guess either)
        #expect(InstagramUsernames.resolve(name: "Sam Reed", storyOwners: [], pool: pool) == nil)
        #expect(InstagramUsernames.resolve(name: "Sam Reed", storyOwners: ["stranger"], pool: pool) == nil)
        let m = InstagramUsernames.resolve(name: "Lou Frost", storyOwners: ["lou_frost"], pool: pool)
        #expect(m == IGUsernameMatch(username: "lou_frost", confidence: .high, method: "story-among-names"))
    }

    @Test func lowTiersAreCautiousAndNeverHigh() {
        #expect(InstagramUsernames.resolve(name: "Rae Ollie", storyOwners: [], pool: pool) == IGUsernameMatch(username: "the_rae_ollie_shop", confidence: .low, method: "low-contains-names"))
        #expect(InstagramUsernames.resolve(name: "Zephyr", storyOwners: [], pool: pool) == IGUsernameMatch(username: "zephyrwolf", confidence: .low, method: "low-unique-prefix"))
        let fuzzy = InstagramUsernames.resolve(name: "Marigold Testova", storyOwners: [], pool: pool)
        #expect(fuzzy?.username == "marigold.testvoa" && fuzzy?.confidence == .low && fuzzy?.method == "low-fuzzy")
        // last name (4+ letters) and the first initial
        let p = IGUsernamePool(["rfixturelli92", "other.thing"])
        #expect(InstagramUsernames.resolve(name: "Robin Fixturelli", storyOwners: [], pool: p)?.method == "low-last-name-initial")
        // two usernames fit the same tier: nothing
        let two = IGUsernamePool(["xx_vera_lund_1", "vera.lund.yy"])
        #expect(InstagramUsernames.resolve(name: "Vera Lund", storyOwners: [], pool: two) == nil)
        // a prefix must be unique
        #expect(InstagramUsernames.resolve(name: "Zephyr", storyOwners: [], pool: IGUsernamePool(["zephyrwolf", "zephyrfox"])) == nil)
    }

    @Test func fuzzyNeedsAClearMarginAndPlaceholdersAndEmptyNamesGetNothing() {
        let near = IGUsernamePool(["marigoldtestvoa", "marigoldtestvaa"])
        #expect(InstagramUsernames.resolve(name: "Marigold Testova", storyOwners: [], pool: near) == nil)      // two equally close
        #expect(InstagramUsernames.resolve(name: "Instagram User", storyOwners: ["someone"], pool: pool) == nil)
        #expect(InstagramUsernames.resolve(name: "Unknown", storyOwners: [], pool: pool) == nil)
        #expect(InstagramUsernames.resolve(name: "\u{5C71}\u{7530}", storyOwners: [], pool: pool) == nil)
    }

    @Test func shortNamesCannotMatchTinyShapes() {
        let p = IGUsernamePool(["ab", "jo", "joe"])
        #expect(InstagramUsernames.resolve(name: "Jo", storyOwners: [], pool: p) == nil)                       // under 3 letters
    }

    @Test func profileLinksAreReadFromHrefsOnly() {
        #expect(InstagramUsernames.username(fromHref: "https://www.instagram.com/some.user") == "some.user")
        #expect(InstagramUsernames.username(fromHref: "https://www.instagram.com/_u/other_user/") == "other_user")
        #expect(InstagramUsernames.username(fromHref: "https://www.instagram.com/p/AbC123/") == nil)
        #expect(InstagramUsernames.username(fromHref: "https://www.instagram.com/stories/x/1") == nil)
        #expect(InstagramUsernames.username(fromHref: "https://example.com/some.user") == nil)
        #expect(InstagramUsernames.storyOwner("https://instagram.com/stories/Someone.Else/1783?x=1") == "someone.else")
        #expect(InstagramUsernames.storyOwner("https://www.instagram.com/stories/highlights/99") == nil)
    }
}

@Suite struct InstagramUsernameImportTests {
    /// Every case the task names, in one export.
    private func fixture() -> IGExport {
        let x = IGExport()
        x.owner("testme")
        x.list("followers_1.html", ["dana.ford", "parkeli", "miras", "nquest", "avalane", "benhart", "the_rae_ollie_shop", "samreed", "sam_reed",
                                    "loufrost", "lou_frost", "gilnash", "noise_one", "zephyrwolf"])
        x.list("following.html", ["dana.ford", "noise_two"])                       // repeated entries are one username
        x.thread("Dana Ford", id: "100000000000001")                                // exact
        x.thread("Eli Park", id: "100000000000002")                                 // last + first
        x.thread("Mira Stone", id: "100000000000003")                               // first + last initial
        x.thread("Noel Quest", id: "100000000000004")                               // first initial + last
        x.thread("Ava Lane", id: "100000000000005", stories: ["avalane", "testme"])  // story agrees; the owner's own story is ignored
        x.thread("Ben Hart", id: "100000000000006", stories: ["somebody_else"])      // story contradicts: name wins, flagged
        x.thread("Kit Moon", id: "100000000000007", stories: ["moonbeam_k"])         // story alone
        x.thread("Rae Ollie", id: "100000000000008")                                 // low
        x.thread("Sam Reed", id: "100000000000009")                                  // ambiguous: none
        x.thread("Lou Frost", id: "100000000000010", stories: ["lou_frost"])          // ambiguous, settled by the story
        x.thread("Zephyr", id: "100000000000011")                                    // low prefix
        x.thread("Instagram User", id: "100000000000012", stories: ["someone"], category: "archived_threads")   // deleted account
        x.thread("Quiet Person", id: "100000000000013")                               // nothing at all
        x.group(["Gil Nash", "Hana Cole"], id: "100000000000014")                      // each sender on their own
        return x
    }

    @Test func everyCaseAtImportTime() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let x = fixture(); defer { x.cleanup() }
        let r = try MetaImporter.importExport(at: x.ex, service: .instagram, into: t.db, root: t.root)
        let rep = try #require(r.usernames)
        let u = try usernames(t)
        #expect(u["Dana Ford"] == "dana.ford|high|title-exact")
        #expect(u["Eli Park"] == "parkeli|high|name-first-last")
        #expect(u["Mira Stone"] == "miras|high|name-initial")
        #expect(u["Noel Quest"] == "nquest|high|name-initial")
        #expect(u["Ava Lane"] == "avalane|high|title-exact+story")
        #expect(u["Ben Hart"] == "benhart|high|title-exact+story-conflict")
        #expect(u["Kit Moon"] == "moonbeam_k|high|story")
        #expect(u["Rae Ollie"] == "the_rae_ollie_shop|low|low-contains-names")
        #expect(u["Sam Reed"] == nil)
        #expect(u["Lou Frost"] == "lou_frost|high|story-among-names")
        #expect(u["Zephyr"] == "zephyrwolf|low|low-unique-prefix")
        #expect(u["Instagram User"] == nil && u["Quiet Person"] == nil && u["Hana Cole"] == nil)
        #expect(u["Gil Nash"] == "gilnash|high|title-exact")
        // report: 9 high and 2 low, 3 none out of 14 named handles; the deleted account is a placeholder (no identity)
        #expect(rep.high == 9 && rep.low == 2 && rep.none == 3 && rep.placeholders == 1)
        #expect(rep.storyConflicts == 1 && rep.selfUsername && rep.poolUsernames == 15)
        #expect(rep.written && rep.byMethod["high:story"] == 1 && rep.byMethod["low:low-unique-prefix"] == 1)
        // the folder slug is never a username
        #expect(try q(t.db, "SELECT count(*) FROM contact_name WHERE origin = 'instagram-username'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM handle_username WHERE username LIKE '%quietperson%'") == 0)
    }

    @Test func aStoryOwnerSharedAcrossTwoPeopleIsNobodysUsername() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let x = IGExport(); defer { x.cleanup() }
        x.owner("testme")
        x.list("followers_1.html", ["shared_account", "ivy.lark", "ivylarks"])
        x.thread("Cleo Marsh", id: "100000000000001", stories: ["shared_account"])
        x.thread("Dex Orr", id: "100000000000002", stories: ["shared_account"])
        x.thread("Fay Wynn", id: "100000000000003", stories: ["fay_wynn_x"])       // lone, overlaps the name: kept
        _ = try MetaImporter.importExport(at: x.ex, service: .instagram, into: t.db, root: t.root)
        let u = try usernames(t)
        #expect(u["Cleo Marsh"] == nil && u["Dex Orr"] == nil)
        #expect(u["Fay Wynn"] == "fay_wynn_x|high|story")
    }

    @Test func aUsernameHighOnTwoPeopleIsDroppedAtImport() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let x = IGExport(); defer { x.cleanup() }
        x.owner("testme")
        x.list("followers_1.html", ["gus.holt", "hal.moss"])
        // two different display names that spell the same username
        x.thread("Gus Holt", id: "100000000000001")
        x.thread("Holt Gus", id: "100000000000002")
        x.thread("Hal Moss", id: "100000000000003")
        let r = try MetaImporter.importExport(at: x.ex, service: .instagram, into: t.db, root: t.root)
        let u = try usernames(t)
        #expect(u["Hal Moss"] == "hal.moss|high|title-exact")
        #expect(u.values.filter { $0.hasPrefix("gus.holt") }.isEmpty)
        #expect(try #require(r.usernames).duplicateHighDropped == 2)
    }

    @Test func rerunningNeverChangesHandleIdentityOrAMappingTheUserMade() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let x = fixture(); defer { x.cleanup() }
        _ = try MetaImporter.importExport(at: x.ex, service: .instagram, into: t.db, root: t.root)
        func handles() throws -> [String] {
            let st = try t.db.prepare("SELECT id || '|' || raw || '|' || normalized || '|' || kind FROM handle ORDER BY id")
            var out: [String] = []
            while try st.step() { out.append(st.string(0) ?? "") }
            return out
        }
        // a user's correction, keyed by handle spelling
        let o = try PeopleOverrides(root: t.root)
        try o.merge(["ig:dana ford"], with: ["ig:eli park"])
        try o.rename(["ig:kit moon"], to: "Kit M")
        let overridesBefore = PeopleOverrides.read(root: t.root)
        let before = try handles()
        let peopleBytes = try Data(contentsOf: PeopleOverrides.fileURL(root: t.root))

        // a later export knows more usernames; the recompute replaces the table, nothing else
        x.list("close_friends.html", ["quiet.person"])
        let again = try InstagramUsernames.apply(exportRoot: x.ex, into: t.db)
        #expect(try usernames(t)["Quiet Person"] == "quiet.person|high|title-exact")
        #expect(again.high == 10)
        #expect(try handles() == before)
        #expect(PeopleOverrides.read(root: t.root) == overridesBefore)
        #expect(try Data(contentsOf: PeopleOverrides.fileURL(root: t.root)) == peopleBytes)       // people.sqlite untouched, byte for byte
        // and an idempotent second run
        _ = try InstagramUsernames.apply(exportRoot: x.ex, into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM handle_username") == 12)
        // a dry run changes nothing
        x.list("recent_follow_requests.html", ["quiet.person2"])
        let dry = try InstagramUsernames.apply(exportRoot: x.ex, into: t.db, write: false)
        #expect(!dry.written)
        #expect(try q(t.db, "SELECT count(*) FROM handle_username") == 12)
    }

    @Test func oldFolderSlugAliasesAreRemovedAndTheMigrationStartsEmpty() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let x = IGExport(); defer { x.cleanup() }
        x.owner("testme")
        x.thread("Alice Ex", id: "100000000000001")
        x.thread("Bob Ex", id: "100000000000002")
        _ = try MetaImporter.importExport(at: x.ex, service: .instagram, into: t.db, root: t.root)
        // an archive from before: the slug stored as a "username" alias
        let hid = try q(t.db, "SELECT id FROM handle WHERE normalized = 'ig:alice ex'")
        try t.db.exec("INSERT INTO contact_name(handle_id, name, origin, priority) VALUES (\(hid), 'aliceex', 'instagram-username', 5)")
        let r = try InstagramUsernames.apply(exportRoot: x.ex, into: t.db)
        #expect(r.legacyAliasesRemoved == 1)
        #expect(try q(t.db, "SELECT count(*) FROM contact_name WHERE origin = 'instagram-username'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM contact_name WHERE handle_id = \(hid)") == 1)     // the display name stays
        #expect(try q(t.db, "SELECT count(*) FROM handle_username") == 0)
    }

    @Test func aV6ArchiveMigratesAdditively() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.db.exec("DROP TABLE handle_username")
        try t.db.setUserVersion(6)
        try Schema.migrate(t.db)
        #expect(try t.db.userVersion() == Schema.currentVersion)
        #expect(try t.db.tableExists("handle_username"))
    }
}

@Suite struct InstagramUsernameDisplayTests {
    @Test func theSuggesterCountsRealUsernamesFullyAndPossibleOnesAtReducedWeight() {
        func score(_ high: [String], _ low: [String]) -> Double {
            let a = SuggestionProfile(id: 1, names: ["Moonbeam"], usernames: high, possibleUsernames: low, hasInstagram: true, messages: 300)
            let b = SuggestionProfile(id: 2, names: ["Anna Lee"], phoneHandles: 1, messages: 300)
            return MatchSuggester.suggest(profiles: [a, b]).first { $0.queue == .crossService }?.candidates.first?.score ?? 0
        }
        let real = score(["anna.lee.photo"], []), possible = score([], ["anna.lee.photo"])
        #expect(real > possible && possible >= 0.0)
        #expect(score([], []) == 0)
        // 0.60 for the shape, 0.36 once weighted: still above the cutoff so the card shows, labelled as the weaker evidence
        let a = SuggestionProfile(id: 1, names: ["Moonbeam"], possibleUsernames: ["anna.lee.photo"], hasInstagram: true, messages: 300)
        let b = SuggestionProfile(id: 2, names: ["Anna Lee"], phoneHandles: 1, messages: 300)
        let out = MatchSuggester.suggest(profiles: [a, b], options: { var o = SuggestionOptions(); o.minScore = 0.30; return o }())
        let reasons = out.first?.candidates.first?.reasons ?? []
        #expect(reasons.contains { $0.hasPrefix("possible Instagram username") })
    }

    @Test func aPersonCarriesRealAndPossibleUsernamesAndTheReviewSiteShowsThemApart() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.meta(.instagram, name: "Dana Ford", count: 20, username: "dana.ford")
        try b.meta(.instagram, name: "Rae Ollie", count: 20, possibleUsername: "the_rae_ollie_shop")
        try b.meta(.instagram, name: "Quiet Person", count: 20)
        _ = try PeopleStore.rematch(db: t.db)
        let idx = try b.index()
        let dana = try #require(idx.persons.values.first { $0.name == "Dana Ford" })
        let rae = try #require(idx.persons.values.first { $0.name == "Rae Ollie" })
        let quiet = try #require(idx.persons.values.first { $0.name == "Quiet Person" })
        #expect(dana.usernames == ["dana.ford"] && dana.possibleUsernames.isEmpty)
        #expect(rae.usernames.isEmpty && rae.possibleUsernames == ["the_rae_ollie_shop"])
        #expect(quiet.usernames.isEmpty && quiet.possibleUsernames.isEmpty)

        let s = try ReviewService(root: t.root)
        let hits = s.search("ollie", exclude: nil)
        #expect(hits.first?.usernames == [] && hits.first?.possibleUsernames == ["the_rae_ollie_shop"])
        let byUser = s.search("dana.ford", exclude: nil)
        #expect(byUser.first?.usernames == ["dana.ford"] && byUser.first?.possibleUsernames == [])
        // the page renders "@user" for a real one and "possible @user" (weaker) for a possible one
        #expect(ReviewPage.html.contains("possible @") && ReviewPage.html.contains("alt weak"))

        // a server picks up newly written usernames on refresh
        let hid = try t.db.scalarInt("SELECT id FROM handle WHERE normalized = 'ig:quiet person'")
        try t.db.exec("INSERT INTO handle_username(handle_id, username, confidence, method) VALUES (\(hid), 'quiet.p', 'high', 'test')")
        try s.refresh()
        #expect(s.search("quiet", exclude: nil).first?.usernames == ["quiet.p"])
    }

    @Test func anArchiveBeforeV7StillReadsWithNoUsernames() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let b = PeopleBuilder(t)
        try b.meta(.instagram, name: "Dana Ford", count: 20)
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try t.db.exec("DROP TABLE handle_username")        // what a v6 archive looks like to a read-only open
        let idx = try b.index()
        let dana = try #require(idx.persons.values.first { $0.name == "Dana Ford" })
        #expect(dana.usernames.isEmpty && dana.possibleUsernames.isEmpty)
    }
}
