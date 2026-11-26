import Foundation

/// A post or a comment as the views show it (the CLI, the web app, the Mac app). "Mine" is `byMe`, never a missing author: a
/// post can have no author handle and still not be the owner's (a page's photo he was tagged in).
public struct PostItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { (isComment ? "c" : "p") + String(rowID) }
    public var rowID: Int64
    public var isComment: Bool
    public var ts: Int64
    public var precision: String            // second | minute
    public var basis: String                 // posted | uploaded | tagged (a comment: posted)
    public var platform: String              // facebook | instagram
    public var account: String               // the export's account (a separate account is not the owner's)
    public var kind: String                  // the post's kind; "comment" for a comment
    public var byMe: Bool
    public var author: String?               // the printed name (or @username); nil only when byMe or when the export names nobody
    public var authorHandle: Int64?
    public var target: String?               // whose timeline (a person), or the post a comment is on ("X's post")
    public var targetText: String?           // a group, album or page
    public var body: String?
    public var context: String?
    public var link: String?
    public var place: String?
    public var postID: Int64?                // a comment's post, when the export names it
    public var postBody: String?             // that post's text, shortened
    public var onMe: Bool                    // a comment on the owner's own post
    public var externalID: String?
    public var snippet: String?              // search only: the match with U+0001 / U+0002 around the words
}

/// One line of a list: a post or comment, or consecutive album photos of one album and one day folded into one line that expands
/// ("Album name: N photos"), so thousands of photo rows do not bury the written posts.
public struct PostEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { album.map { "a:\($0)|\(day ?? "")|\(items.first?.rowID ?? 0)" } ?? (items.first?.id ?? "") }
    public var album: String?                 // set for a folded album line
    public var day: String?                   // yyyy-MM-dd of the album line, in the list's time zone
    public var items: [PostItem]              // one item, or the album's photos (newest first, as listed)
    public var count: Int { items.count }
    public init(album: String?, day: String?, items: [PostItem]) { self.album = album; self.day = day; self.items = items }
}

/// What a list of posts and comments is restricted to; every part set must hold.
public struct PostsFilter: Sendable, Equatable {
    public var handles: [Int64]?          // a person's handles (their posts, posts on their timeline, comments by them or on their posts)
    public var mineOnly = false           // the owner's own: by_me, never a missing author
    public var fromMs: Int64?, toMs: Int64?   // inclusive span
    public init(handles: [Int64]? = nil, mineOnly: Bool = false, fromMs: Int64? = nil, toMs: Int64? = nil) {
        self.handles = handles; self.mineOnly = mineOnly; self.fromMs = fromMs; self.toMs = toMs
    }
}

public enum PostsOrder: String, Sendable { case best, newest, oldest }

/// A page boundary: the last item of the previous page, as (ts, "p<id>" or "c<id>").
public struct PostCursor: Sendable, Equatable {
    public var ts: Int64, isComment: Bool, rowID: Int64
    public var id: String { (isComment ? "c" : "p") + String(rowID) }
    public init(ts: Int64, isComment: Bool, rowID: Int64) { self.ts = ts; self.isComment = isComment; self.rowID = rowID }
    public init?(ts: Int64, id: String) {
        guard let f = id.first, f == "p" || f == "c", let r = Int64(id.dropFirst()) else { return nil }
        self.init(ts: ts, isComment: f == "c", rowID: r)
    }
    public init(_ item: PostItem) { self.init(ts: item.ts, isComment: item.isComment, rowID: item.rowID) }
}

extension ArchiveReader {
    /// Whether the archive has the post tables (an archive made by an older version has none; every call below returns nothing then).
    public func postsAvailable() throws -> Bool { try locked { try db.tableExists("post") && db.tableExists("post_comment") } }

    static let postSelect = """
        SELECT p.id, 0, p.ts_ms, p.ts_precision, p.ts_basis, p.platform, p.account, p.kind, p.by_me,
               CASE WHEN ah.normalized LIKE 'ig:@%' THEN '@' || substr(ah.normalized, 5) ELSE coalesce(p.author_name, ah.raw) END,
               p.author_handle_id,
               CASE WHEN th.normalized LIKE 'ig:@%' THEN '@' || substr(th.normalized, 5) ELSE coalesce(p.target_name, th.raw) END,
               p.target_text, p.body, p.context, p.link, p.place, NULL, NULL, 0, p.external_id
        FROM post p LEFT JOIN handle ah ON ah.id = p.author_handle_id LEFT JOIN handle th ON th.id = p.target_handle_id
        """
    static let commentSelect = """
        SELECT c.id, 1, c.ts_ms, c.ts_precision, 'posted', c.platform, c.account, 'comment', c.by_me,
               CASE WHEN ah.normalized LIKE 'ig:@%' THEN '@' || substr(ah.normalized, 5) ELSE coalesce(c.author_name, ah.raw) END,
               c.author_handle_id,
               CASE WHEN oh.normalized LIKE 'ig:@%' THEN '@' || substr(oh.normalized, 5)
                    ELSE coalesce(c.on_name, oh.raw, CASE WHEN pp.by_me = 1 THEN NULL ELSE pp.author_name END) END,
               pp.target_text, c.body, c.context, NULL, NULL, c.post_id, substr(pp.body, 1, 140), c.on_me OR coalesce(pp.by_me, 0), NULL
        FROM post_comment c LEFT JOIN handle ah ON ah.id = c.author_handle_id LEFT JOIN handle oh ON oh.id = c.on_handle_id
             LEFT JOIN post pp ON pp.id = c.post_id
        """

    func postItem(_ st: Statement, snippet: Bool = false) -> PostItem {
        PostItem(rowID: st.int(0), isComment: st.int(1) == 1, ts: st.int(2), precision: st.string(3) ?? "second", basis: st.string(4) ?? "posted",
                 platform: st.string(5) ?? "", account: st.string(6) ?? "", kind: st.string(7) ?? "", byMe: st.int(8) == 1,
                 author: st.string(9), authorHandle: st.optInt(10), target: st.string(11), targetText: st.string(12), body: st.string(13),
                 context: st.string(14), link: st.string(15), place: st.string(16), postID: st.optInt(17), postBody: st.string(18),
                 onMe: st.int(19) == 1, externalID: st.string(20), snippet: snippet ? st.string(21) : nil)
    }

    /// A person's posts and comments, newest first: posts they wrote or that are on their timeline, comments they wrote, comments on
    /// their posts (the owner's and others'). `before` is the last item of the previous page.
    public func posts(handles: [Int64], limit: Int = 200, before: (ts: Int64, id: String)? = nil, mineOnly: Bool = false) throws -> [PostItem] {
        guard !handles.isEmpty || mineOnly else { return [] }
        return try posts(filter: PostsFilter(handles: handles.isEmpty ? nil : handles, mineOnly: mineOnly), limit: limit, before: before.flatMap { PostCursor(ts: $0.ts, id: $0.id) })
    }

    /// Every post and comment of one span (a day in the viewer's zone), newest first.
    public func posts(from startMs: Int64, to endMs: Int64, limit: Int = 2000) throws -> [PostItem] {
        try posts(filter: PostsFilter(fromMs: startMs, toMs: endMs - 1), limit: limit)
    }

    /// Posts and comments matching every part of the filter, newest first, in pages: the cursor is part of the SQL, ordered by
    /// (time, posts before comments, row id) both in SQL and here, so rows that share a timestamp are never skipped.
    public func posts(filter: PostsFilter, limit: Int = 200, before: PostCursor? = nil) throws -> [PostItem] {
        let n = Self.clampLimit(limit)
        guard n > 0, try postsAvailable() else { return [] }
        if let h = filter.handles, h.isEmpty { return [] }
        return try locked {
            var out: [PostItem] = []
            for comment in [false, true] {
                var sql = (comment ? Self.commentSelect : Self.postSelect) + " WHERE " + filterSQL(filter, comment: comment)
                if let c = before {
                    let a = comment ? "c" : "p"
                    // after (ts, kind, id) in the order ts DESC, kind ASC (post 0, comment 1), id DESC
                    if comment {
                        sql += " AND (\(a).ts_ms < \(c.ts) OR (\(a).ts_ms = \(c.ts) AND (\(c.isComment ? "\(a).id < \(c.rowID)" : "1"))))"
                    } else {
                        sql += " AND (\(a).ts_ms < \(c.ts) OR (\(a).ts_ms = \(c.ts) AND \(c.isComment ? "0" : "\(a).id < \(c.rowID)")))"
                    }
                }
                sql += comment ? " ORDER BY c.ts_ms DESC, c.id DESC LIMIT \(n)" : " ORDER BY p.ts_ms DESC, p.id DESC LIMIT \(n)"
                let st = try db.prepare(sql)
                while try st.step() { out.append(postItem(st)) }
            }
            out.sort(by: Self.newestFirst)
            return Array(out.prefix(n))
        }
    }

    /// The list order: newest first; at one timestamp posts before comments, then the higher row id first.
    public static func newestFirst(_ a: PostItem, _ b: PostItem) -> Bool {
        if a.ts != b.ts { return a.ts > b.ts }
        if a.isComment != b.isComment { return !a.isComment }
        return a.rowID > b.rowID
    }

    static func clampLimit(_ n: Int) -> Int { max(0, min(n, 100_000)) }

    func filterSQL(_ f: PostsFilter, comment: Bool) -> String {
        var w: [String] = []
        if let h = f.handles {
            let ids = h.map(String.init).joined(separator: ",")
            w.append(comment ? "(c.author_handle_id IN (\(ids)) OR c.on_handle_id IN (\(ids)) OR pp.author_handle_id IN (\(ids)))"
                             : "(p.author_handle_id IN (\(ids)) OR p.target_handle_id IN (\(ids)))")
        }
        let a = comment ? "c" : "p"
        if f.mineOnly { w.append("\(a).by_me = 1") }
        if let from = f.fromMs { w.append("\(a).ts_ms >= \(from)") }
        if let to = f.toMs { w.append("\(a).ts_ms <= \(to)") }
        return w.isEmpty ? "1" : w.joined(separator: " AND ")
    }

    /// How many posts and comments `posts(filter:)` would list (for a person page's header).
    public func postCount(filter: PostsFilter) throws -> Int {
        guard try postsAvailable() else { return 0 }
        if let h = filter.handles, h.isEmpty { return 0 }
        return try locked {
            Int(try db.scalarInt("SELECT count(*) FROM post p WHERE " + filterSQL(filter, comment: false))
              + (try db.scalarInt("SELECT count(*) FROM post_comment c LEFT JOIN post pp ON pp.id = c.post_id WHERE " + filterSQL(filter, comment: true))))
        }
    }

    public func postCount(handles: [Int64]) throws -> Int {
        handles.isEmpty ? 0 : try postCount(filter: PostsFilter(handles: handles))
    }

    /// Full-text search over post and comment text (post_fts), within the filter (a person, the owner's own, a span), best match,
    /// newest or oldest first.
    public func searchPosts(_ text: String, filter: PostsFilter = PostsFilter(), order: PostsOrder = .best, limit: Int = 100, offset: Int = 0) throws -> [PostItem] {
        let n = Self.clampLimit(limit)
        guard n > 0, try postsAvailable(), try locked({ try db.tableExists("post_fts") }), let q = Self.ftsQuery(text) else { return [] }
        if let h = filter.handles, h.isEmpty { return [] }
        return try locked {
            let st = try db.prepare("SELECT ref, snippet(post_fts, 0, char(1), char(2), '…', 16) FROM post_fts WHERE post_fts MATCH ? ORDER BY rank")
            st.bind(1, q)
            var refs: [(String, String)] = []
            while try st.step() { refs.append((st.string(0) ?? "", st.string(1) ?? "")) }
            let onePost = try db.prepare(Self.postSelect + " WHERE p.id = ? AND " + filterSQL(filter, comment: false))
            let oneComment = try db.prepare(Self.commentSelect + " WHERE c.id = ? AND " + filterSQL(filter, comment: true))
            var out: [PostItem] = []
            for (ref, snip) in refs {
                guard let id = Int64(ref.dropFirst(2)) else { continue }
                let one = ref.hasPrefix("p:") ? onePost : oneComment
                one.reset(); one.bind(1, id)
                if try one.step() { var it = postItem(one); it.snippet = snip; out.append(it) }
            }
            switch order {
            case .best: break
            case .newest: out.sort(by: Self.newestFirst)
            case .oldest: out.sort { Self.newestFirst($1, $0) }
            }
            return Array(out.dropFirst(max(0, offset)).prefix(n))
        }
    }

    /// Folds consecutive album photos of one album and one day (in `zone`) into one entry; everything else stays one entry each.
    public static func groupAlbums(_ items: [PostItem], zone: TimeZone = .current) -> [PostEntry] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        func day(_ ts: Int64) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ts) / 1000))
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        var out: [PostEntry] = []
        for it in items {
            let isAlbum = !it.isComment && it.kind == "album-photo"
            if isAlbum, let last = out.last, last.album != nil || (last.items.count == 1 && !last.items[0].isComment && last.items[0].kind == "album-photo"),
               (last.items[0].targetText ?? "") == (it.targetText ?? ""), day(last.items[0].ts) == day(it.ts) {
                var e = out.removeLast()
                e.album = it.targetText ?? "Album"
                e.day = day(it.ts)
                e.items.append(it)
                out.append(e)
            } else {
                out.append(PostEntry(album: nil, day: nil, items: [it]))
            }
        }
        return out
    }
}
