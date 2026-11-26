import Foundation

/// Facebook and Instagram posts and comments.
///
/// Input is a *records file* written by `scripts/posts_read.py` (one per export): a JSON header line, then one JSON line per record
/// (`post`, `comment`, or `skip`). The reader decides what a record is and when it happened; this importer decides people, overlaps
/// with exports imported earlier, and rows.
///
/// Tables are additive and created here (`CREATE TABLE IF NOT EXISTS`), like `call` and `listen`: a schema version bump would make the
/// deployed web app refuse the archive. Nothing in an existing table changes; new rows go only into `handle` (people never seen before,
/// no thread), `contact_name` (their printed name), `source` (one per run) and `import_ledger`. There is no likes table: likes and
/// reactions are counted by the reader and ledgered as left out.
///
/// Decisions per record, all ledgered (one TSV row per record, no text, a hash of it):
/// - `new`: written.
/// - `held`: the same record is already a row: by its dkey (a re-read), or by the overlap rule against another export's row:
///   same platform, same author (both the owner, or the same handle), time windows that overlap (a minute-precision time covers its whole
///   printed minute), and text equal three ways (whitespace removed; letters and digits with "<3" read as a heart; one a prefix of the
///   other at 20+ characters), or one side with no text (a 2011 app post's text that 2025 dropped), or the same external id (a photo's
///   Facebook id). Exactly one candidate: held with that row's id. Never written twice, never updated.
/// - `left-out`: the reader's skips (likes, empty records, a post whose printed time is not its own and its comments), a comment whose
///   post was left out, a duplicate inside the export, or two or more overlap candidates with nothing to decide between them
///   (`ambiguous-overlap`, listed for the manager, never written).
///
/// People: a Facebook name -> `fb:<folded name>` (the Messenger import's handles); an Instagram username -> the `ig:` handle whose
/// high-confidence username (`handle_username`) it is, else `ig:@<username>`; an Instagram display name -> `ig:<folded name>`.
/// A name never seen gets a handle of its own and no thread. Placeholders ("Facebook User") get no handle (the printed name is kept).
public enum PostsImporter {
    public static let sourceKindPrefix = "posts-"

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS post (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES source(id),
            platform TEXT NOT NULL,                       -- facebook | instagram
            account TEXT NOT NULL,                        -- the export's own account: facebook:me, instagram:<username>
            kind TEXT NOT NULL,                           -- wall-post, status, link, photo, album-photo, video, group-post, tagged-photo, story, reel, ...
            by_me INTEGER NOT NULL,                       -- 1 = the owner; "mine" is by_me, never a NULL author_handle_id (an unknown owner has none too)
            author_handle_id INTEGER REFERENCES handle(id),
            author_name TEXT,                             -- the name as the export prints it
            target_handle_id INTEGER REFERENCES handle(id), -- whose timeline or photo, when a person
            target_name TEXT,
            target_text TEXT,                             -- a group, album or page name
            ts_ms INTEGER NOT NULL,                       -- Unix ms UTC; the start of the printed minute for minute precision
            ts_precision TEXT NOT NULL,                   -- second | minute
            ts_basis TEXT NOT NULL,                       -- posted | uploaded | tagged (tagged: when the owner was tagged, not when it was posted)
            body TEXT,
            context TEXT,                                 -- the export's header line ("<owner> shared a link.")
            link TEXT,
            place TEXT,
            external_id TEXT,                             -- a photo's Facebook id, an Instagram media id
            dkey TEXT NOT NULL UNIQUE
        )
        """,
        "CREATE INDEX IF NOT EXISTS post_ts ON post(ts_ms)",
        "CREATE INDEX IF NOT EXISTS post_author ON post(author_handle_id, ts_ms)",
        "CREATE INDEX IF NOT EXISTS post_target ON post(target_handle_id, ts_ms)",
        "CREATE INDEX IF NOT EXISTS post_external ON post(platform, external_id) WHERE external_id IS NOT NULL",
        """
        CREATE TABLE IF NOT EXISTS post_comment (
            id INTEGER PRIMARY KEY,
            post_id INTEGER REFERENCES post(id),          -- NULL when the export names only "X's post"
            parent_comment_id INTEGER REFERENCES post_comment(id),
            source_id INTEGER NOT NULL REFERENCES source(id),
            platform TEXT NOT NULL,
            account TEXT NOT NULL,
            by_me INTEGER NOT NULL,
            author_handle_id INTEGER REFERENCES handle(id),
            author_name TEXT,
            on_handle_id INTEGER REFERENCES handle(id),   -- the X of "commented on X's post"
            on_name TEXT,
            on_me INTEGER NOT NULL DEFAULT 0,             -- 1 = "commented on his own post"
            ts_ms INTEGER NOT NULL,
            ts_precision TEXT NOT NULL,
            body TEXT,
            context TEXT,
            dkey TEXT NOT NULL UNIQUE
        )
        """,
        "CREATE INDEX IF NOT EXISTS post_comment_post ON post_comment(post_id)",
        "CREATE INDEX IF NOT EXISTS post_comment_ts ON post_comment(ts_ms)",
        "CREATE INDEX IF NOT EXISTS post_comment_author ON post_comment(author_handle_id, ts_ms)",
        "CREATE INDEX IF NOT EXISTS post_comment_on ON post_comment(on_handle_id, ts_ms)",
        """
        CREATE TABLE IF NOT EXISTS post_media (
            post_id INTEGER NOT NULL REFERENCES post(id),
            ordinal INTEGER NOT NULL,
            sha256 TEXT REFERENCES media(sha256),         -- a copy in the archive's media store, or
            photoprism_uid TEXT,                          -- a link to the PhotoPrism photo with the same bytes
            photoprism_sha1 TEXT,
            filename TEXT, mime TEXT, bytes INTEGER,
            export_path TEXT,                             -- where the file is in the export
            PRIMARY KEY (post_id, ordinal)
        ) WITHOUT ROWID
        """,
        "CREATE VIRTUAL TABLE IF NOT EXISTS post_fts USING fts5(body, ref UNINDEXED, tokenize='unicode61 remove_diacritics 2')",
    ]

    public static func ensureTables(_ db: Database) throws { for s in tableSQL { try db.exec(s) } }

    public struct Stats: Codable, Equatable, Sendable {
        public var records = 0
        public var postsWritten = 0, commentsWritten = 0, held = 0, leftOut = 0, newHandles = 0
        public var leftOutByReason: [String: Int] = [:]
        public var heldByRule: [String: Int] = [:]
        public var firstTsMs: Int64?, lastTsMs: Int64?
    }

    public struct Report: Sendable {
        public enum Status: Sendable { case imported, alreadyImported }
        public var status: Status
        public var stats: Stats
        public var newHandles: [String] = []        // normalized, in the order created
    }

    // MARK: records

    struct Head {
        var export: String, platform: String, account: String, me: String, timeRule: String
        var files: [[String: Any]]
    }

    struct Record {
        var line: Int
        var raw: [String: Any]
        var rid: String { raw["rid"] as? String ?? "" }
        var type: String { raw["type"] as? String ?? "" }
        func s(_ k: String) -> String? { (raw[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func b(_ k: String) -> Bool { raw[k] as? Bool ?? false }
        var ts: Int64? { (raw["ts_ms"] as? NSNumber)?.int64Value }
    }

    static func read(_ url: URL) throws -> (Head, [Record], sha: String, bytes: Int64) {
        let data = try Data(contentsOf: url)
        let sha = data.withUnsafeBytes { Hashing.sha256Hex($0) }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw ArchiveError("\(url.path): empty records file") }
        func obj(_ s: Substring, _ n: Int) throws -> [String: Any] {
            guard let o = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { throw ArchiveError("line \(n): not an object") }
            return o
        }
        let h = try obj(lines.removeFirst(), 1)
        guard let export = h["export"] as? String, let platform = h["platform"] as? String, let account = h["account"] as? String,
              platform == "facebook" || platform == "instagram" else { throw ArchiveError("\(url.path): header needs export, platform (facebook|instagram), account") }
        let head = Head(export: export, platform: platform, account: account, me: h["me"] as? String ?? "",
                        timeRule: h["time_rule"] as? String ?? "", files: h["files"] as? [[String: Any]] ?? [])
        var recs: [Record] = []
        var rids = Set<String>()
        for (i, l) in lines.enumerated() {
            let r = Record(line: i + 2, raw: try obj(l, i + 2))
            guard ["post", "comment", "skip"].contains(r.type), !r.rid.isEmpty else { throw ArchiveError("line \(r.line): needs rid and type post|comment|skip") }
            guard rids.insert(r.rid).inserted else { throw ArchiveError("line \(r.line): rid \(r.rid) repeats") }
            if r.type != "skip" {
                guard r.ts != nil, r.s("dkey") != nil, ["second", "minute"].contains(r.s("precision") ?? "") else {
                    throw ArchiveError("line \(r.line) (\(r.rid)): a post or comment needs ts_ms, precision second|minute and dkey")
                }
                if r.type == "post", r.s("kind") == nil { throw ArchiveError("line \(r.line) (\(r.rid)): a post needs a kind") }
            }
            recs.append(r)
        }
        // a comment's parent must be a post of this file, written before it
        var postRids = Set<String>()
        for r in recs {
            if r.type == "post" || (r.type == "skip" && r.s("what") != "comment" && r.s("what") != "like-line") { postRids.insert(r.rid) }
            if r.type == "comment", let p = r.s("parent"), !postRids.contains(p) {
                throw ArchiveError("line \(r.line) (\(r.rid)): parent \(p) is not a post earlier in this file")
            }
        }
        return (head, recs, sha, Int64(data.count))
    }

    // MARK: text rule

    /// The three-way text rule.
    static func whitespaceKey(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace } }
    static func alnumKey(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "<3", with: "\u{2665}").precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "\u{2665}" }))
    }
    static func sameText(_ a: String, _ b: String) -> Bool {
        if whitespaceKey(a) == whitespaceKey(b) { return true }
        let x = alnumKey(a), y = alnumKey(b)
        if !x.isEmpty && x == y { return true }
        return x.count >= 20 && y.count >= 20 && (x.hasPrefix(y) || y.hasPrefix(x))
    }
    /// One text is the other's beginning, whole words: "noted." and "noted. see you then" (letters and digits compared).
    static func isWordPrefix(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.folding(options: [.caseInsensitive], locale: nil).unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.count < y.count ? Array(y.prefix(x.count)) == x : Array(x.prefix(y.count)) == y
    }

    static func textHash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        return String(Data(alnumKey(s).utf8).withUnsafeBytes { Hashing.sha256Hex($0) }.prefix(16))
    }
    static func width(_ precision: String) -> Int64 { precision == "minute" ? 60_000 : 1_000 }

    // MARK: ledger

    public static let ledgerHeader = ["rid", "type", "kind", "file", "ts_ms", "ts_utc", "precision", "basis", "author", "where",
                                      "decision", "reason", "existing_id", "written_id", "dkey", "text_hash", "author_handle", "new_handles", "same_as", "note"].joined(separator: "\t")

    struct LedgerRow {
        var cols: [String]
        mutating func set(_ i: Int, _ v: String) { cols[i] = v }
        var line: String { cols.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
    }
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    // MARK: import

    public static func importRecords(at url: URL, into db: Database, dryRun: Bool = false, ledger: URL? = nil) throws -> Report {
        let (head, recs, sha, bytes) = try read(url)
        let kind = sourceKindPrefix + head.export
        // already imported: same records file
        if try db.tableExists("source") {
            let st = try db.prepare("SELECT id FROM source WHERE sha256 = ?")
            st.bind(1, sha)
            if try st.step() {
                let sid = st.int(0); st.reset()
                if let ledger, let body = try ImportLedger.load(db, sourceID: sid) { try ImportLedger.publish(body, to: ledger) }
                var s = Stats(); s.records = recs.count
                return Report(status: .alreadyImported, stats: s)
            }
            st.reset()
        }
        if !dryRun { try ensureTables(db) }

        var stats = Stats(); stats.records = recs.count
        var report = Report(status: .imported, stats: stats)
        var rows: [LedgerRow] = []

        // people
        let hasUsernames = try db.tableExists("handle_username")
        let selHandle = try db.prepare("SELECT id FROM handle WHERE normalized = ?")
        let selUser = hasUsernames ? try db.prepare("SELECT handle_id FROM handle_username WHERE lower(username) = lower(?) AND confidence = 'high'") : nil
        var handleCache: [String: Int64] = [:]           // normalized -> id (existing or created in this run)
        var plannedNew: [String: (raw: String, kind: String)] = [:]
        var newOrder: [String] = []
        /// (normalized, raw, kind) a name resolves to, nil for a placeholder.
        func resolve(_ name: String?, ns: String) throws -> (normalized: String, raw: String, kind: String)? {
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            switch ns {
            case "ig-user":
                let u = name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
                if let selUser {
                    selUser.bind(1, u)
                    var ids: [Int64] = []
                    while try selUser.step() { ids.append(selUser.int(0)) }
                    selUser.reset()
                    if ids.count == 1 {
                        let n = try db.scalarString("SELECT normalized FROM handle WHERE id = \(ids[0])") ?? ""
                        handleCache[n] = ids[0]
                        return (n, name, HandleKind.instagramUser.rawValue)
                    }
                }
                return ("ig:@" + u, "@" + u, HandleKind.instagramUser.rawValue)
            case "ig-name":
                let h = ServiceHandle.instagram(name: name)
                return (h.normalized, h.raw, h.kind.rawValue)
            default:
                let f = ServiceHandle.foldName(name)
                if FacebookDYI2011Importer.isPlaceholder(f) { return nil }
                let h = ServiceHandle.facebook(name: name)
                return (h.normalized, h.raw, h.kind.rawValue)
            }
        }
        func handleID(_ r: (normalized: String, raw: String, kind: String)?, created: inout [String]) throws -> Int64? {
            guard let r else { return nil }
            if let id = handleCache[r.normalized] { return id }
            selHandle.bind(1, r.normalized)
            defer { selHandle.reset() }
            if try selHandle.step() { let id = selHandle.int(0); handleCache[r.normalized] = id; return id }
            if plannedNew[r.normalized] == nil { plannedNew[r.normalized] = (r.raw, r.kind); newOrder.append(r.normalized) }
            created.append(r.normalized)
            if dryRun {                                   // a placeholder id for the decision only
                let fake = -Int64(newOrder.firstIndex(of: r.normalized)! + 1)
                handleCache[r.normalized] = fake
                return fake
            }
            let ins = try db.prepare("INSERT INTO handle(raw, normalized, kind) VALUES (?,?,?)")
            ins.bind(1, r.raw).bind(2, r.normalized).bind(3, r.kind)
            try ins.run()
            let id = db.lastInsertRowID
            let name = try db.prepare("INSERT OR IGNORE INTO contact_name(handle_id, name, origin, priority) VALUES (?,?,?,?)")
            name.bind(1, id).bind(2, r.raw).bind(3, head.platform + "-posts").bind(4, ContactPriority.androidXML)
            try name.run()
            handleCache[r.normalized] = id
            return id
        }

        // overlap candidates from rows of other runs
        /// Whose post a comment is on, as far as it is known: the post's author (the owner, a handle, or a name with no handle yet).
        enum Owner: Equatable { case unknown, me, handle(Int64), unmatchedName(String) }
        /// Every component of the folded full name, short ones included ("Dana Wu" is not
        /// "Dana Et"), in order.
        func nameComponents(_ name: String) -> String {
            var n = ServiceHandle.foldName(name)
            for p in ["fb:", "ig:@", "ig:"] where n.hasPrefix(p) { n = String(n.dropFirst(p.count)); break }
            if let h = n.firstIndex(of: "#") { n = String(n[..<h]) }
            return n.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        }
        func fullName(_ o: Owner) throws -> String? {
            switch o {
            case .handle(let id):
                guard id > 0, let n = try db.scalarString("SELECT normalized FROM handle WHERE id = \(id)") else { return nil }
                return nameComponents(n)
            case .unmatchedName(let n): return nameComponents(n)
            default: return nil
            }
        }
        /// Owners agree when both are the owner, the same handle, or the same full name (folded, every component); unknown agrees with
        /// anything. A shared word, such as a first name, never makes two owners agree: a
        /// rename is accepted only in the deferred pass, with evidence (people rename themselves between 2011 and 2025).
        func ownersAgree(_ a: Owner, _ b: Owner) throws -> Bool {
            if a == .unknown || b == .unknown || a == b { return true }
            if a == .me || b == .me { return false }
            guard let x = try fullName(a), let y = try fullName(b), !x.isEmpty else { return false }
            return x == y
        }
        var claimed: [String: Set<Int64>] = [:]       // earlier rows already held by a record of this run, per table
        // the owner of every post this run writes (or, in a dry run, plans), so a dry run decides exactly as the run does
        //
        var plannedOwner: [Int64: Owner] = [:]
        func postOwner(_ postID: Int64?) throws -> Owner {
            guard let postID else { return .unknown }
            if let o = plannedOwner[postID] { return o }
            guard postID > 0 else { return .unknown }
            let st = try db.prepare("SELECT by_me, author_handle_id FROM post WHERE id = ?")
            st.bind(1, postID)
            guard try st.step() else { return .unknown }
            if st.int(0) == 1 { return .me }
            return st.optInt(1).map { .handle($0) } ?? .unknown
        }
        /// A comment's parent post and owner; the overlap rule never holds a comment against one on a different post:
        /// when both posts are known they must be the same row, and when a post is known on one side and
        /// only its owner ("X's post") on the other, the owners must agree.
        struct CommentSide { var post: Int64?; var owner: Owner }
        func candidates(table: String, sid: Int64, platform: String, byMe: Bool, author: Int64?, ts: Int64, w: Int64, body: String?, external: String?,
                        comment: CommentSide? = nil) throws -> [Int64] {
            try candidatesWithRule(table: table, sid: sid, platform: platform, byMe: byMe, author: author, ts: ts, w: w, body: body,
                                   external: external, comment: comment).map { $0.id }
        }
        /// The candidates and the rule that made each one: text (the three-way rule), empty (one side has no text), external-id.
        func candidatesWithRule(table: String, sid: Int64, platform: String, byMe: Bool, author: Int64?, ts: Int64, w: Int64, body: String?, external: String?,
                                comment: CommentSide? = nil, ignoreOwner: Bool = false) throws -> [(id: Int64, rule: String)] {
            guard try db.tableExists(table) else { return [] }
            var out: [(id: Int64, rule: String)] = []
            let st = try db.prepare("""
                SELECT id, ts_ms, ts_precision, body, by_me, author_handle_id\(table == "post" ? ", external_id, NULL, NULL, NULL" : ", NULL, post_id, on_handle_id, on_me") FROM \(table)
                WHERE platform = ? AND source_id != ? AND ts_ms BETWEEN ? AND ?
                """)
            st.bind(1, platform).bind(2, sid).bind(3, ts - 60_000).bind(4, ts + w)
            let taken = claimed[table] ?? []
            while try st.step() {
                if taken.contains(st.int(0)) { continue }                            // each earlier row is held by one record only
                // two photos with different Facebook ids are two photos, whatever their time and caption
                if table == "post", let external, let oExt = st.string(6), oExt != external { continue }
                let ots = st.int(1), ow = width(st.string(2) ?? "second")
                guard ots < ts + w, ts < ots + ow else { continue }                   // windows overlap
                let oByMe = st.int(4) == 1, oAuthor = st.optInt(5)
                guard oByMe == byMe, byMe || (author != nil && oAuthor == author) else { continue }
                let ob = st.string(3) ?? ""
                let mine = body ?? ""
                // the 2011 export prints a shared link's title and description after the post's own text; 2025 prints the text
                // alone ("noted." / "noted. see you then"): one text starting with the other, word for word
                let prefix = table == "post" && !ob.isEmpty && !mine.isEmpty && !sameText(ob, mine) && isWordPrefix(ob, mine)
                guard ob.isEmpty || mine.isEmpty || sameText(ob, mine) || prefix else { continue }
                if let comment {
                    let oPost = st.optInt(7)
                    let oOwner: Owner = oPost != nil ? try postOwner(oPost) : (st.int(9) == 1 ? .me : (st.optInt(8).map { .handle($0) } ?? .unknown))
                    if let p = comment.post, let oPost, p != oPost { continue }
                    if !ignoreOwner, !(try ownersAgree(comment.owner, oOwner)) { continue }
                }
                out.append((st.int(0), (ob.isEmpty || mine.isEmpty) ? "empty" : (prefix ? "prefix" : "text")))
            }
            if let external, table == "post" {
                let e = try db.prepare("SELECT id FROM post WHERE platform = ? AND external_id = ? AND source_id != ?")
                e.bind(1, platform).bind(2, external).bind(3, sid)
                var byID: [(id: Int64, rule: String)] = []
                while try e.step() { if !taken.contains(e.int(0)) { byID.append((e.int(0), "external-id")) } }
                if !byID.isEmpty { return byID }                                      // the same Facebook id decides
            }
            return out
        }
        /// The row already holding this dkey, and whether it is this record: the same text (exactly), time, author and, for a
        /// comment, the same post. A dkey alone never decides.
        func byDkey(_ table: String, _ dkey: String, body: String?, ts: Int64, byMe: Bool, author: Int64?, parent: Int64??) throws -> (id: Int64, same: Bool)? {
            guard try db.tableExists(table) else { return nil }
            let st = try db.prepare("SELECT id, body, ts_ms, by_me, author_handle_id\(table == "post_comment" ? ", post_id" : ", NULL") FROM \(table) WHERE dkey = ?")
            st.bind(1, dkey)
            guard try st.step() else { return nil }
            var same = (st.string(1) ?? "") == (body ?? "") && st.int(2) == ts && (st.int(3) == 1) == byMe && st.optInt(4) == author
            if let parent { same = same && st.optInt(5) == parent }
            return (st.int(0), same)
        }

        func run(sid: Int64) throws {
            var postID: [String: Int64] = [:]            // rid -> decided post id (written or held)
            var leftPosts = Set<String>()
            var commentID: [String: Int64] = [:]
            var seenDkeys = Set<String>()
            var nextFake: Int64 = 1
            let insPost = dryRun ? nil : try db.prepare("""
                INSERT INTO post(source_id, platform, account, kind, by_me, author_handle_id, author_name, target_handle_id, target_name,
                                 target_text, ts_ms, ts_precision, ts_basis, body, context, link, place, external_id, dkey)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            let insComment = dryRun ? nil : try db.prepare("""
                INSERT INTO post_comment(post_id, parent_comment_id, source_id, platform, account, by_me, author_handle_id, author_name,
                                         on_handle_id, on_name, ts_ms, ts_precision, body, context, dkey, on_me)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            let insFTS = dryRun ? nil : try db.prepare("INSERT INTO post_fts(rowid, body, ref) VALUES (NULL, ?, ?)")

            var deferred: [(r: Record, rowIndex: Int, author: Int64?, n: Int)] = []
            var deferredComments: [(r: Record, rowIndex: Int, author: Int64?, side: CommentSide?)] = []
            let parentRids = Set(recs.compactMap { $0.type == "comment" ? $0.s("parent") : nil })
            /// Writes a post record as new (or plans it, in a dry run); returns its id.
            func writePost(_ r: Record, authorID: Int64?, created: inout [String]) throws -> Int64 {
                let ts = r.ts!, byMe = r.b("by_me"), body = r.s("body")
                let otherName = r.s("target")
                let otherID = try handleID(try resolve(otherName, ns: r.s("target_ns") ?? "fb-name"), created: &created)
                var written: Int64 = 0
                if dryRun { written = -nextFake; nextFake += 1 }
                else if let st = insPost {
                    st.bind(1, sid).bind(2, head.platform).bind(3, head.account).bind(4, r.s("kind")!).bind(5, byMe)
                    st.bind(6, authorID).bind(7, r.s("author")).bind(8, otherID).bind(9, otherName).bind(10, r.s("target_text"))
                    st.bind(11, ts).bind(12, r.s("precision")!).bind(13, r.s("basis") ?? "posted").bind(14, body).bind(15, r.s("context"))
                    st.bind(16, r.s("link")).bind(17, r.s("place")).bind(18, r.s("external_id")).bind(19, r.s("dkey")!)
                    try st.run(); written = db.lastInsertRowID
                }
                if let fts = insFTS, let body, !body.isEmpty { fts.bind(1, body).bind(2, "p:\(written)"); try fts.run() }
                postID[r.rid] = written; stats.postsWritten += 1
                plannedOwner[written] = byMe ? .me : (authorID.map { .handle($0) } ?? .unknown)
                stats.firstTsMs = min(stats.firstTsMs ?? ts, ts); stats.lastTsMs = max(stats.lastTsMs ?? ts, ts)
                return written
            }
            /// Writes a parentless comment record as new (or plans it); returns its id.
            func writeComment(_ r: Record, authorID: Int64?, created: inout [String]) throws -> Int64 {
                let ts = r.ts!, body = r.s("body")
                let otherName = r.s("on")
                let otherID = try handleID(try resolve(otherName, ns: r.s("on_ns") ?? "fb-name"), created: &created)
                var written: Int64 = 0
                if dryRun { written = -nextFake; nextFake += 1 }
                else if let st = insComment {
                    st.bind(1, r.s("parent").flatMap { postID[$0] }).bind(2, nil as Int64?).bind(3, sid).bind(4, head.platform).bind(5, head.account)
                    st.bind(6, r.b("by_me")).bind(7, authorID).bind(8, r.s("author")).bind(9, otherID).bind(10, otherName).bind(11, ts)
                    st.bind(12, r.s("precision")!).bind(13, body).bind(14, r.s("context")).bind(15, r.s("dkey")!).bind(16, r.b("on_me"))
                    try st.run(); written = db.lastInsertRowID
                }
                if let fts = insFTS, let body, !body.isEmpty { fts.bind(1, body).bind(2, "c:\(written)"); try fts.run() }
                commentID[r.rid] = written; stats.commentsWritten += 1
                stats.firstTsMs = min(stats.firstTsMs ?? ts, ts); stats.lastTsMs = max(stats.lastTsMs ?? ts, ts)
                return written
            }
            for r in recs {
                let fileIdx = (r.raw["file"] as? NSNumber).map { "\($0.intValue)" } ?? ""
                let ts = r.ts
                var row = LedgerRow(cols: [r.rid, r.type, r.s("kind") ?? r.s("what") ?? "", fileIdx, ts.map { "\($0)" } ?? "",
                                           ts.map { iso.string(from: Date(timeIntervalSince1970: Double($0) / 1000)) } ?? "",
                                           r.s("precision") ?? "", r.s("basis") ?? "",
                                           r.b("by_me") ? "(me)" : (r.s("author") ?? ""),
                                           r.s("target") ?? r.s("target_text") ?? r.s("on") ?? r.s("parent") ?? "",
                                           "", "", "", "", r.s("dkey") ?? "", textHash(r.s("body")), "", "", r.s("same_as") ?? "",
                                           r.s("note") ?? r.s("near_match") ?? ""])
                func leave(_ reason: String) {
                    row.set(10, "left-out"); row.set(11, reason)
                    stats.leftOut += 1; stats.leftOutByReason[reason, default: 0] += 1
                }
                func hold(_ id: Int64, _ rule: String) {
                    row.set(10, "held"); row.set(11, rule); row.set(12, "\(id)")
                    stats.held += 1; stats.heldByRule[rule, default: 0] += 1
                }
                var created: [String] = []
                defer { row.set(17, created.joined(separator: ";")); rows.append(row) }
                if r.type == "skip" {
                    if r.s("what") != "comment" && r.s("what") != "like-line" { leftPosts.insert(r.rid) }
                    leave(r.s("reason") ?? "skipped")
                    continue
                }
                let dkey = r.s("dkey")!
                let table = r.type == "post" ? "post" : "post_comment"
                if !seenDkeys.insert(dkey).inserted {
                    if r.type == "post" { leftPosts.insert(r.rid) }
                    leave("duplicate-in-export"); continue
                }
                if r.type == "comment", let p = r.s("parent"), leftPosts.contains(p) { leave("parent-left-out"); continue }
                let byMe = r.b("by_me")
                let authorID = byMe ? nil : try handleID(try resolve(r.s("author"), ns: r.s("author_ns") ?? "fb-name"), created: &created)
                row.set(16, authorID.map { "\($0)" } ?? "")
                let precision = r.s("precision")!, w = width(precision), body = r.s("body")
                let parentArg: Int64?? = r.type == "comment" ? .some(r.s("parent").flatMap { postID[$0] }) : .none
                if let found = try byDkey(table, dkey, body: body, ts: ts!, byMe: byMe, author: authorID, parent: parentArg) {
                    if found.same {
                        hold(found.id, "same-dkey"); claimed[table, default: []].insert(found.id)
                        if r.type == "post" { postID[r.rid] = found.id } else { commentID[r.rid] = found.id }
                    } else {
                        if r.type == "post" { leftPosts.insert(r.rid) }
                        leave("dkey-conflict"); row.set(12, "\(found.id)")
                    }
                    continue
                }
                var side: CommentSide?
                if r.type == "comment" {
                    let parent = r.s("parent").flatMap { postID[$0] }
                    var owner: Owner = try postOwner(parent)
                    // "replied to X's comment" names the comment's author, not the post's owner
                    if owner == .unknown && !(parent == nil && r.b("reply")) {
                        if r.b("on_me") { owner = .me }
                        else if let on = try resolve(r.s("on"), ns: r.s("on_ns") ?? "fb-name") {
                            if let id = handleCache[on.normalized], id > 0 { owner = .handle(id) }
                            else {
                                selHandle.bind(1, on.normalized)
                                owner = try selHandle.step() ? .handle(selHandle.int(0)) : .unmatchedName(on.normalized)
                                selHandle.reset()
                            }
                        }
                    }
                    side = CommentSide(post: parent, owner: owner)
                }
                let candRules = try candidatesWithRule(table: table, sid: sid, platform: head.platform, byMe: byMe, author: authorID, ts: ts!, w: w, body: body,
                                           external: r.type == "post" ? r.s("external_id") : nil, comment: side)
                let cands = candRules.map { $0.id }
                // a post matched only because one side has no text is decided after every other record (gate 2: a 2025 photo post
                // with no text must not take the 2011 photo that the 2025 album copy matches by its Facebook id)
                if !cands.isEmpty, r.type == "post", candRules.allSatisfy({ $0.rule == "empty" || $0.rule == "prefix" }), !parentRids.contains(r.rid) {
                    deferred.append((r, rows.count, authorID, cands.count))
                    row.set(10, "(deferred)")
                    continue
                }
                // a comment of the owner's whose only candidates are on a post whose owner's name shares no word with the one 2025
                // names (a rename such as "Ya Ma" / "Jin Lee"): decided after every other record, from what is still unclaimed
                if cands.isEmpty, r.type == "comment", side?.post == nil,
                   !(try candidatesWithRule(table: table, sid: sid, platform: head.platform, byMe: byMe, author: authorID, ts: ts!, w: w, body: body,
                                            external: nil, comment: side, ignoreOwner: true)).isEmpty {
                    deferredComments.append((r, rows.count, authorID, side))
                    row.set(10, "(deferred)")
                    continue
                }
                if cands.count == 1 {
                    hold(cands[0], "overlap-" + candRules[0].rule); claimed[table, default: []].insert(cands[0])
                    if r.type == "post" { postID[r.rid] = cands[0] } else { commentID[r.rid] = cands[0] }
                    continue
                }
                // several posts of the owner's in one minute, matched only because one side has no text (2011's app posts that the
                // 2025 export prints without text): decided after every other record, paired one to one in time order
                if cands.count > 1 {
                    if r.type == "post" { leftPosts.insert(r.rid) }
                    leave("ambiguous-overlap"); row.set(12, cands.map { "\($0)" }.joined(separator: ";")); continue
                }
                // new
                let ns = r.s(r.type == "post" ? "target_ns" : "on_ns") ?? "fb-name"
                let otherName = r.s(r.type == "post" ? "target" : "on")
                let otherID = try handleID(try resolve(otherName, ns: ns), created: &created)
                var written: Int64
                if dryRun { written = -nextFake; nextFake += 1 }
                else if r.type == "post", let st = insPost {
                    st.bind(1, sid).bind(2, head.platform).bind(3, head.account).bind(4, r.s("kind")!).bind(5, byMe)
                    st.bind(6, authorID).bind(7, r.s("author")).bind(8, otherID).bind(9, otherName).bind(10, r.s("target_text"))
                    st.bind(11, ts!).bind(12, precision).bind(13, r.s("basis") ?? "posted").bind(14, body).bind(15, r.s("context"))
                    st.bind(16, r.s("link")).bind(17, r.s("place")).bind(18, r.s("external_id")).bind(19, dkey)
                    try st.run(); written = db.lastInsertRowID
                } else if let st = insComment {
                    let parent = r.s("parent").flatMap { postID[$0] }
                    let parentComment = r.s("parent_comment").flatMap { commentID[$0] }
                    st.bind(1, parent).bind(2, parentComment).bind(3, sid).bind(4, head.platform).bind(5, head.account).bind(6, byMe)
                    st.bind(7, authorID).bind(8, r.s("author")).bind(9, otherID).bind(10, otherName).bind(11, ts!).bind(12, precision)
                    st.bind(13, body).bind(14, r.s("context")).bind(15, dkey).bind(16, r.b("on_me"))
                    try st.run(); written = db.lastInsertRowID
                } else { written = 0 }
                if let fts = insFTS, let body, !body.isEmpty {
                    fts.bind(1, body).bind(2, (r.type == "post" ? "p:" : "c:") + "\(written)")
                    try fts.run()
                }
                if r.type == "post" {
                    postID[r.rid] = written; stats.postsWritten += 1
                    plannedOwner[written] = byMe ? .me : (authorID.map { .handle($0) } ?? .unknown)
                } else { commentID[r.rid] = written; stats.commentsWritten += 1 }
                row.set(10, "new"); row.set(13, dryRun ? "(new)" : "\(written)")
                stats.firstTsMs = min(stats.firstTsMs ?? ts!, ts!); stats.lastTsMs = max(stats.lastTsMs ?? ts!, ts!)
            }
            // the deferred posts, in time order: each takes the earliest unclaimed earlier row of its minute; none left: new
            for d in deferred.sorted(by: { ($0.r.ts!, $0.rowIndex) < ($1.r.ts!, $1.rowIndex) }) {
                let r = d.r
                let c = try candidatesWithRule(table: "post", sid: sid, platform: head.platform, byMe: r.b("by_me"), author: d.author, ts: r.ts!,
                                               w: width(r.s("precision")!), body: r.s("body"), external: r.s("external_id"))
                // a text that begins the other one beats one side having no text; then time order
                let best = c.contains { $0.rule == "prefix" || $0.rule == "text" } ? c.filter { $0.rule != "empty" } : c
                var ordered: [(id: Int64, ts: Int64, rule: String)] = []
                for x in best {
                    let t = try db.scalarInt("SELECT ts_ms FROM post WHERE id = \(x.id)")
                    ordered.append((x.id, t, x.rule))
                }
                ordered.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
                var row = rows[d.rowIndex]
                if let first = ordered.first {
                    let base = first.rule == "empty" ? "overlap-empty" : "overlap-\(first.rule)"
                    let rule = best.count == 1 ? base : base + "-paired"
                    row.set(10, "held"); row.set(11, rule); row.set(12, "\(first.id)")
                    row.set(19, best.count == 1 ? (first.rule == "empty" ? "the only unclaimed post of its minute (one side has no text)"
                                                                         : "the only unclaimed post of its minute that begins with this text, or this with it")
                                                : "paired in time order with one of \(best.count) unclaimed posts of that minute (of \(d.n) at first)")
                    stats.held += 1; stats.heldByRule[rule, default: 0] += 1
                    claimed["post", default: []].insert(first.id)
                    postID[r.rid] = first.id
                } else {
                    var created: [String] = []
                    let written = try writePost(r, authorID: d.author, created: &created)
                    row.set(10, "new"); row.set(13, dryRun ? "(new)" : "\(written)")
                    row.set(17, ([row.cols[17]] + created).filter { !$0.isEmpty }.joined(separator: ";"))
                    row.set(19, "no unclaimed post left in its minute")
                }
                rows[d.rowIndex] = row
            }
            // deferred comments: a match across a rename is accepted only with evidence that the two names are one person: a text of
            // 20+ letters and digits, or two or more comments matched between the same two owners; otherwise the comment is new
            struct Proposal { var d: (r: Record, rowIndex: Int, author: Int64?, side: CommentSide?); var cand: Int64?; var key: String; var long: Bool; var n: Int }
            var proposals: [Proposal] = []
            for d in deferredComments.sorted(by: { ($0.r.ts!, $0.rowIndex) < ($1.r.ts!, $1.rowIndex) }) {
                let r = d.r
                let c = try candidatesWithRule(table: "post_comment", sid: sid, platform: head.platform, byMe: r.b("by_me"), author: d.author, ts: r.ts!,
                                               w: width(r.s("precision")!), body: r.s("body"), external: nil, comment: d.side, ignoreOwner: true)
                    .filter { !(claimed["post_comment"] ?? []).contains($0.id) }
                var key = "", cand: Int64? = nil
                if c.count == 1 {
                    cand = c[0].id
                    let pid = try db.scalarString("SELECT post_id FROM post_comment WHERE id = \(c[0].id)").flatMap { Int64($0) }
                    key = "\(try postOwner(pid))|\(d.side?.owner ?? .unknown)"
                }
                proposals.append(Proposal(d: d, cand: cand, key: key, long: alnumKey(r.s("body") ?? "").count >= 20, n: c.count))
            }
            // evidence counts distinct earlier comments, so one comment printed twice is not two pieces of evidence
            var support: [String: (long: Bool, n: Int)] = [:]
            var seenCands: [String: Set<Int64>] = [:]
            for p in proposals {
                guard let cand = p.cand else { continue }
                let v = support[p.key] ?? (false, 0)
                let fresh = seenCands[p.key, default: []].insert(cand).inserted
                support[p.key] = (v.long || p.long, v.n + (fresh ? 1 : 0))
            }
            for p in proposals {
                let r = p.d.r
                var row = rows[p.d.rowIndex]
                if let cand = p.cand, let sup = support[p.key], sup.long || sup.n >= 2, !(claimed["post_comment"] ?? []).contains(cand) {
                    row.set(10, "held"); row.set(11, "overlap-text-owner-renamed"); row.set(12, "\(cand)")
                    row.set(19, "the only unclaimed comment with this text in its minute; the post's owner has another name here (\(sup.n) such comment(s)\(sup.long ? ", one of 20+ letters" : ""))")
                    stats.held += 1; stats.heldByRule["overlap-text-owner-renamed", default: 0] += 1
                    claimed["post_comment", default: []].insert(cand)
                } else if p.n > 1 {
                    row.set(10, "left-out"); row.set(11, "ambiguous-overlap")
                    stats.leftOut += 1; stats.leftOutByReason["ambiguous-overlap", default: 0] += 1
                } else {
                    var created: [String] = []
                    let written = try writeComment(r, authorID: p.d.author, created: &created)
                    row.set(10, "new"); row.set(13, dryRun ? "(new)" : "\(written)")
                    row.set(17, ([row.cols[17]] + created).filter { !$0.isEmpty }.joined(separator: ";"))
                    row.set(19, p.cand == nil ? "its candidates were claimed by other records"
                                              : "same text in its minute on a post whose owner has another name, without evidence of a rename (near-match)")
                }
                rows[p.d.rowIndex] = row
            }
        }

        func ledgerBody() -> String { ([ledgerHeader] + rows.map { $0.line }).joined(separator: "\n") + "\n" }

        if dryRun {
            try run(sid: -1)
            stats.newHandles = newOrder.count
            report.stats = stats
            report.newHandles = newOrder
            if let ledger { try ImportLedger.publish(ledgerBody(), to: ledger) }
            return report
        }
        try db.transaction {
            let origins = head.files.compactMap { $0["origin"] as? String }
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, origins.count == 1 ? origins[0] : "\(head.export): \(origins.count) files (records \(url.lastPathComponent))")
            ins.bind(3, sha).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            try run(sid: sid)
            stats.newHandles = newOrder.count
            // the time rule is written once per export and never replaced: a different rule for an export already
            // imported is an error, and the whole import rolls back
            let key = "\(kind).time_rule"
            let old = try db.prepare("SELECT value FROM meta WHERE key = ?")
            old.bind(1, key)
            if try old.step() {
                let v = old.string(0) ?? ""; old.reset()
                guard v == head.timeRule else {
                    throw ArchiveError("meta \(key) is already \"\(v)\"; this records file says \"\(head.timeRule)\". Existing rows never change: nothing was imported.")
                }
            } else {
                old.reset()
                let meta = try db.prepare("INSERT INTO meta(key, value) VALUES (?, ?)")
                meta.bind(1, key).bind(2, head.timeRule)
                try meta.run()
            }
            var statsDict = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats))) as? [String: Any] ?? [:]
            statsDict["files"] = head.files
            let st = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONSerialization.data(withJSONObject: statsDict, options: [.sortedKeys]), as: UTF8.self)).bind(2, sid)
            try st.run()
            try ImportLedger.save(db, sourceID: sid, body: ledgerBody())
        }
        report.stats = stats
        report.newHandles = newOrder
        if let ledger { try ImportLedger.publish(ledgerBody(), to: ledger) }
        return report
    }
}
