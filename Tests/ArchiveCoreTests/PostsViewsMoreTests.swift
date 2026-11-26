import Testing
import Foundation
@testable import ArchiveCore

/// Posts views, more edge cases.
@Suite struct PostsViewsMoreTests {
    /// A NUL (or another control character) in a search reached FTS as an unterminated phrase and answered 500,
    /// in posts search and in message search (they share the quoted-term helper).
    @Test func f2ControlCharactersNeverReachFTS() throws {
        #expect(ArchiveReader.ftsQuery("a\u{0}") == "\"a\"*")
        #expect(ArchiveReader.ftsQuery("bir\u{0}thday") == "\"birthday\"*")
        #expect(ArchiveReader.ftsQuery("\u{0}") == nil)
        #expect(ArchiveReader.ftsQuery("happy\u{7}\u{1b} birthday\u{7f}") == "\"happy\" \"birthday\"*")
        for q in ["a\u{0}", "\u{0}", "birth\u{0}day", "x\u{1}\u{2}", "\u{0}\u{0}\""] {
            #expect(!(ArchiveReader.ftsQuery(q) ?? "").unicodeScalars.contains { $0.properties.generalCategory == .control })
        }
    }

    @Test func f2SearchWithANulAnswersNormallyOnBothEndpoints() throws {
        let (t, site, _, _) = try PostsWebEdgeTests().site(); defer { t.cleanup() }
        let web = PostsWebEdgeTests()
        for path in ["/api/posts/search", "/api/search"] {
            for q in ["a\u{0}", "\u{0}", "birth\u{0}day", "happy\u{1b}"] {
                let r = web.get(site, path, ["q": q])
                #expect(r.status == 200, "\(path) q=\(q.debugDescription) answered \(r.status)")
            }
        }
        // the NUL is dropped, the rest still matches
        let hits = try JSONSerialization.jsonObject(with: web.get(site, "/api/posts/search", ["q": "birth\u{0}day"]).body) as? [[String: Any]] ?? []
        #expect(hits.contains { ($0["body"] as? String)?.contains("birthday") == true })
        let reader = try ArchiveReader(root: t.root)
        #expect((try? reader.search("a\u{0}", scope: nil)) != nil)
        #expect((try? reader.searchPosts("a\u{0}")) != nil)
    }
}

/// A value an async stand-in waits for until the test hands it over, so a test fixes the order in which loads complete.
final class Handover<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<T, Never>] = []
    func wait() async -> T { await withCheckedContinuation { c in lock.withLock { waiting.append(c) } } }
    var count: Int { lock.withLock { waiting.count } }
    /// Hands `v` to the `i`th of those waiting now (0 = the one that started waiting first).
    func give(_ v: T, to i: Int) { let c: CheckedContinuation<T, Never>? = lock.withLock { i < waiting.count ? waiting.remove(at: i) : nil }; c?.resume(returning: v) }
    func give(_ v: T) { let first: CheckedContinuation<T, Never>? = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }; first?.resume(returning: v) }
}

@MainActor func until(_ what: @MainActor () -> Bool) async {
    for _ in 0..<2_000 where !what() { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
}

@MainActor @Suite struct PersonPostsLoaderTests {
    nonisolated static func items(_ n: Int, ts: Int64 = 1_400_000_000_000) -> [PostItem] {
        (0..<n).map { i in PostItem(rowID: Int64(100 - i), isComment: false, ts: ts - Int64(i) * 1000, precision: "second", basis: "posted", platform: "facebook",
                                     account: "facebook:someone", kind: "status", byMe: false, onMe: false) }
    }

    /// B selected (A's total still on screen, so the toggle shows), Posts turned on, B's page arrives, then B's count:
    /// the count updates the total and leaves the toggle and the loaded page alone.
    @Test func f1ACountArrivingAfterPostsWasTurnedOnKeepsTheToggleAndThePage() async throws {
        let counts = Handover<Int>()
        let source = PersonPostsLoader.Source(count: { _ in await counts.wait() }, page: { _, n, _ in Self.items(3) })
        let l = PersonPostsLoader(pageSize: 500)
        l.open(person: 1, handles: [10], source: source)
        await until { counts.count == 1 }; counts.give(5); await l.settle()
        #expect(l.state.total == 5 && l.state.toggleVisible)

        l.open(person: 2, handles: [20], source: source)
        #expect(l.state.toggleVisible && !l.state.showPosts && l.state.loaded == 0)
        l.setShowPosts(true)
        await until { l.state.loaded == 3 }
        #expect(l.state.showPosts && l.state.loaded == 3)
        await until { counts.count == 1 }; counts.give(3); await l.settle()
        #expect(l.state.showPosts, "the count switched Posts off")
        #expect(l.state.loaded == 3, "the count dropped the loaded page")
        #expect(l.state.total == 3 && !l.state.canLoadMore)
    }

    /// The count says the person has none after all (Posts was turned on on the previous person's total): Posts goes off.
    @Test func f1ACountOfZeroAfterPostsWasTurnedOnHidesThem() async throws {
        let counts = Handover<Int>()
        let source = PersonPostsLoader.Source(count: { _ in await counts.wait() }, page: { _, _, _ in [] })
        let l = PersonPostsLoader(pageSize: 500)
        l.open(person: 1, handles: [10], source: source)
        await until { counts.count == 1 }; counts.give(5); await l.settle()
        l.open(person: 2, handles: [20], source: source)
        l.setShowPosts(true)
        await until { counts.count == 1 }; counts.give(0); await l.settle()
        #expect(!l.state.showPosts && !l.state.toggleVisible && l.state.loaded == 0)
    }

    /// A, then B, then A again: the first opening's count arrives last and is not the open person's (any more).
    @Test func f1AStaleCountFromAnEarlierOpeningIsIgnored() async throws {
        let counts = Handover<Int>()
        let source = PersonPostsLoader.Source(count: { _ in await counts.wait() }, page: { _, _, _ in Self.items(2) })
        let l = PersonPostsLoader(pageSize: 500)
        l.open(person: 1, handles: [10], source: source)      // count 1 waits
        await until { counts.count == 1 }
        l.open(person: 2, handles: [20], source: source)      // count 2 waits
        l.open(person: 1, handles: [10], source: source)      // count 3 waits
        await until { counts.count == 3 }
        counts.give(2, to: 2)                                 // the open opening's count (the last asked for) arrives first,
        await until { l.state.total == 2 }
        counts.give(7, to: 1)                                 // then B's,
        counts.give(99, to: 0)                                // then the first opening of A's, stale
        await l.settle()
        #expect(l.state.total == 2, "a stale count of an earlier opening replaced the open one's")
        l.setShowPosts(true); await l.settle()
        #expect(l.state.showPosts && l.state.loaded == 2 && !l.state.canLoadMore)
    }
}
