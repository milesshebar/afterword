import Foundation

/// The Mac app's person "Posts and comments" state, kept here so it is tested: the toggle resets when
/// another person opens, hides when that person has no posts, and the list pages on with the real total shown.
public struct PersonPostsState: Sendable {
    public let pageSize: Int
    public var showPosts = false
    public private(set) var total: Int?
    public private(set) var items: [PostItem] = []
    /// A page shorter than pageSize arrived: nothing more after it.
    private var exhausted = false
    public init(pageSize: Int = 500) { self.pageSize = pageSize }

    public var toggleVisible: Bool { (total ?? 0) > 0 }
    public var loaded: Int { items.count }
    public var cursor: PostCursor? { items.last.map(PostCursor.init) }
    public var canLoadMore: Bool { !exhausted && (total.map { items.count < $0 } ?? true) }

    /// Another person opened: back to their messages, nothing loaded, their total known.
    public mutating func personChanged(total: Int) {
        showPosts = false
        self.total = total
        items = []
        exhausted = false
    }

    /// The open person's count arrived: the total changes, the toggle and the pages already loaded
    /// stay; only a count of none switches Posts off.
    public mutating func counted(_ total: Int) {
        self.total = total
        if total == 0 { showPosts = false; items = [] }
    }

    /// A page arrived (newest first, after `cursor`).
    public mutating func received(_ page: [PostItem]) {
        items += page
        if page.count < pageSize { exhausted = true }
    }

    public func entries(zone: TimeZone) -> [PostEntry] { ArchiveReader.groupAlbums(items, zone: zone) }
}

/// The Mac app's person posts: which person is open, their count and their pages, loaded in the background. AppModel only
/// forwards to it, so the interleavings (a count or a page arriving after the user acted) are tested here.
@MainActor public final class PersonPostsLoader {
    /// Where counts and pages come from: the archive in the app, controllable stand-ins in tests.
    public struct Source: Sendable {
        public var count: @Sendable ([Int64]) async throws -> Int
        public var page: @Sendable ([Int64], Int, PostCursor?) async throws -> [PostItem]
        public init(count: @escaping @Sendable ([Int64]) async throws -> Int, page: @escaping @Sendable ([Int64], Int, PostCursor?) async throws -> [PostItem]) {
            self.count = count; self.page = page
        }
        public static func archive(_ reader: ArchiveReader) -> Source {
            Source(count: { h in try await Task.detached { try reader.postCount(handles: h) }.value },
                   page: { h, n, c in try await Task.detached { try reader.posts(filter: PostsFilter(handles: h), limit: n, before: c) }.value })
        }
    }

    public private(set) var state: PersonPostsState { didSet { changed?() } }
    /// Called after every change of `state` (AppModel mirrors it into its observed property).
    public var changed: (@MainActor () -> Void)?
    private var person: Int64?
    /// Counts every opening; a count or page started under an earlier one is dropped, even when the same person was reopened.
    private var generation = 0
    private var handles: [Int64] = []
    private var source: Source?
    private var tasks: [Task<Void, Never>] = []

    public init(pageSize: Int = 500) { state = PersonPostsState(pageSize: pageSize) }

    /// A person opened (or none: `person` nil): back to their messages, their total counted so the toggle shows only when
    /// they have posts.
    public func open(person id: Int64?, handles: [Int64], source: Source?) {
        person = id; self.handles = handles; self.source = source
        generation += 1
        guard id != nil, let source else { state.personChanged(total: 0); return }
        state.personChanged(total: state.total ?? 0)
        let g = generation
        tasks.append(Task {
            let n = (try? await source.count(handles)) ?? 0
            if self.generation != g { return }
            self.state.counted(n)
        })
    }

    /// The Posts toggle; turning it on loads the first page.
    public func setShowPosts(_ on: Bool) {
        let was = state.showPosts
        state.showPosts = on
        if on && !was && state.loaded == 0 { loadMore() }
    }

    /// The next page of the open person's posts.
    public func loadMore() {
        guard let source, person != nil else { return }
        let handles = self.handles, cursor = state.cursor, size = state.pageSize, g = generation
        tasks.append(Task {
            let page = (try? await source.page(handles, size, cursor)) ?? []
            if self.generation != g || self.state.cursor != cursor { return }
            self.state.received(page)
        })
    }

    /// Waits for every load started so far.
    public func settle() async {
        while !tasks.isEmpty { let t = tasks; tasks = []; for x in t { await x.value } }
    }
}

/// `archivectl posts` arguments, parsed and checked here so they are tested: every filter combines
/// (a person or the owner's own, a day, a search), a limit is 1 to 100,000, and a day runs from local midnight to the next one.
public struct PostsCLIQuery: Sendable, Equatable {
    public var person: Int64?, handle: String?, mine = false, day: String?, search: String?, limit = 200, expand = false, order: PostsOrder = .best

    public struct UsageError: Error, CustomStringConvertible { public let description: String }
    public static let usage = "usage: archivectl posts [--person <id> | --handle <fb:name...> | --mine] [--day YYYY-MM-DD] [--search <words> [--order best|newest|oldest]] [--limit 1-100000] [--expand]"

    public static func parse(_ args: [String]) -> Result<PostsCLIQuery, UsageError> {
        var q = PostsCLIQuery()
        var i = 0
        func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--expand": q.expand = true; i += 1; continue
            case "--mine": q.mine = true; i += 1; continue
            case "--person", "--handle", "--day", "--search", "--limit", "--order":
                guard let v = value(), !v.hasPrefix("--") || a == "--search" else { return .failure(UsageError(description: "\(a) needs a value\n" + usage)) }
                switch a {
                case "--person":
                    guard let p = Int64(v) else { return .failure(UsageError(description: "--person wants a person id\n" + usage)) }
                    q.person = p
                case "--handle": q.handle = v
                case "--day": q.day = v
                case "--search": q.search = v
                case "--order":
                    guard let o = PostsOrder(rawValue: v) else { return .failure(UsageError(description: "--order is best, newest or oldest\n" + usage)) }
                    q.order = o
                default:
                    guard let n = Int(v), (1...100_000).contains(n) else { return .failure(UsageError(description: "--limit wants 1 to 100000\n" + usage)) }
                    q.limit = n
                }
                i += 2
            default:
                return .failure(UsageError(description: "unknown argument \(a)\n" + usage))
            }
        }
        guard q.person != nil || q.handle != nil || q.mine || q.day != nil || q.search != nil else { return .failure(UsageError(description: usage)) }
        return .success(q)
    }

    /// [local midnight, next local midnight) of a YYYY-MM-DD day in `zone`, in Unix ms (23 or 25 hours on a clock-change day).
    public static func dayRange(_ text: String, zone: TimeZone) -> (from: Int64, to: Int64)? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var dc = DateComponents(); dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        guard dc.isValidDate(in: cal), let start = cal.date(from: dc), let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }
}
