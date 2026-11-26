import Testing
import Foundation
@testable import ArchiveCore

private func q(_ db: Database, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }
private func qs(_ db: Database, _ sql: String) throws -> String? { try db.scalarString(sql) }

/// Records files are what `scripts/posts_read.py` writes; these are synthetic (invented names and text).
enum PostFixtures {
    static func head(_ export: String, platform: String = "facebook", account: String = "facebook:owner") -> [String: Any] {
        ["export": export, "platform": platform, "account": account, "me": "Casey Keeper", "time_rule": "test",
         "reader": "test", "files": [["path": "/x/\(export).html", "origin": "test:\(export)", "sha256": String(repeating: "a", count: 64), "bytes": 1]]]
    }
    static func post(_ rid: String, author: String?, ts: Int64, body: String?, precision: String = "minute", kind: String = "wall-post",
                     dkey: String? = nil, ns: String = "fb-name", target: String? = nil, ext: String? = nil, basis: String = "posted") -> [String: Any] {
        var r: [String: Any] = ["rid": rid, "file": 0, "type": "post", "kind": kind, "author_ns": ns, "by_me": author == nil,
                                "ts_ms": ts, "precision": precision, "basis": basis, "dkey": dkey ?? "t|\(rid)", "target_ns": ns]
        if let author { r["author"] = author }
        if let body { r["body"] = body }
        if let target { r["target"] = target }
        if let ext { r["external_id"] = ext }
        return r
    }
    static func comment(_ rid: String, parent: String?, author: String?, ts: Int64, body: String?, precision: String = "minute",
                        dkey: String? = nil, ns: String = "fb-name", on: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["rid": rid, "file": 0, "type": "comment", "author_ns": ns, "by_me": author == nil, "ts_ms": ts,
                                "precision": precision, "dkey": dkey ?? "t|\(rid)", "on_ns": ns, "reply": false]
        if let parent { r["parent"] = parent }
        if let author { r["author"] = author }
        if let body { r["body"] = body }
        if let on { r["on"] = on }
        return r
    }
    static func skip(_ rid: String, what: String, reason: String, parent: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["rid": rid, "file": 0, "type": "skip", "what": what, "reason": reason]
        if let parent { r["parent"] = parent }
        return r
    }
    static func write(_ head: [String: Any], _ recs: [[String: Any]], in dir: URL, name: String) -> URL {
        var s = ""
        for o in [head] + recs { s += String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) + "\n" }
        let u = dir.appendingPathComponent(name)
        try! s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    static let t0: Int64 = 1_300_000_000_000      // 2011-03-13
}

@Suite struct PostsImportTests {
    /// An archive with one Messenger person (fb:ann example) and one Instagram person whose username is known with high confidence.
    func seeded() throws -> TestArchive {
        let t = try TestArchive()
        try t.db.transaction {
            let ins = try t.db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at) VALUES ('test', 'x', 'seed', 0, 0)")
            try ins.run()
            let w = try ArchiveWriter(db: t.db, sourceID: t.db.lastInsertRowID, sourceKind: "test")
            var r = MessageRecord(participants: [], sender: nil, tsMs: 1_000, isFromMe: false, service: "messenger", body: "hi")
            r.participantHandles = [ServiceHandle.facebook(name: "Ann Example")]; r.senderHandle = ServiceHandle.facebook(name: "Ann Example")
            _ = try w.add(r)
            var r2 = MessageRecord(participants: [], sender: nil, tsMs: 2_000, isFromMe: false, service: "instagram", body: "yo")
            r2.participantHandles = [ServiceHandle.instagram(name: "Bea Gram")]; r2.senderHandle = ServiceHandle.instagram(name: "Bea Gram")
            _ = try w.add(r2)
            try t.db.exec("CREATE TABLE IF NOT EXISTS handle_username (handle_id INTEGER PRIMARY KEY, username TEXT NOT NULL, confidence TEXT NOT NULL, method TEXT NOT NULL)")
            try t.db.exec("INSERT INTO handle_username SELECT id, 'bea.gram', 'high', 'test' FROM handle WHERE normalized = 'ig:bea gram'")
            try t.db.exec("INSERT INTO handle_username SELECT id, 'lowconf', 'low', 'test' FROM handle WHERE normalized = 'fb:ann example'")
        }
        return t
    }

    func fingerprint(_ db: Database) throws -> [String: String] {
        var out: [String: String] = [:]
        for t in ["message", "thread", "thread_member", "handle", "contact_name", "source", "attachment", "media"] {
            let st = try db.prepare("SELECT * FROM \(t) ORDER BY 1")
            var s = ""
            while try st.step() { for c in 0..<8 { s += (st.string(Int32(c)) ?? "∅") + "|" }; s += "\n" }
            out[t] = s
        }
        return out
    }

    @Test func writesPostsAndCommentsLinkedToPeopleAndLeavesOldRowsAlone() throws {
        let t = try seeded(); defer { t.cleanup() }
        let before = try fingerprint(t.db)
        let handlesBefore = try q(t.db, "SELECT count(*) FROM handle")
        let f = PostFixtures.self
        let url = f.write(f.head("fb-test"), [
            f.post("p1", author: nil, ts: f.t0, body: "my own post"),
            f.comment("p1:c0", parent: "p1", author: "Ann Example", ts: f.t0 + 60_000, body: "nice"),
            f.comment("p1:c1", parent: "p1", author: "Carl New", ts: f.t0 + 120_000, body: "who is this"),
            f.post("p2", author: "Ann Example", ts: f.t0 + 600_000, body: "on your wall"),
            f.skip("p2:like0", what: "like-line", reason: "likes-left-out", parent: "p2"),
        ], in: t.dir, name: "r.jsonl")
        let led = t.dir.appendingPathComponent("ledger.tsv")
        let r = try PostsImporter.importRecords(at: url, into: t.db, ledger: led)
        #expect(r.status == .imported)
        #expect(r.stats.postsWritten == 2 && r.stats.commentsWritten == 2 && r.stats.leftOut == 1 && r.stats.held == 0)
        #expect(try q(t.db, "SELECT count(*) FROM post") == 2)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment") == 2)
        #expect(try q(t.db, "SELECT count(*) FROM post WHERE by_me = 1 AND author_handle_id IS NULL") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM post p JOIN handle h ON h.id = p.author_handle_id WHERE h.normalized = 'fb:ann example'") == 1)
        // the comment by a new name gets a handle of its own (no thread), the known one reuses Ann's handle
        #expect(try q(t.db, "SELECT count(*) FROM handle") == handlesBefore + 1)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'fb:carl new'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM thread_member m JOIN handle h ON h.id = m.handle_id WHERE h.normalized = 'fb:carl new'") == 0)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment c JOIN post p ON p.id = c.post_id WHERE p.body = 'my own post'") == 2)
        // no likes table, nothing in reaction
        #expect(try !t.db.tableExists("post_reaction"))
        // full-text search finds a comment
        #expect(try q(t.db, "SELECT count(*) FROM post_fts WHERE post_fts MATCH 'nice'") == 1)
        // old rows: unchanged except the new handle and the new source row, both listed by the fingerprint diff
        let after = try fingerprint(t.db)
        for k in ["message", "thread", "thread_member", "attachment", "media"] { #expect(before[k] == after[k], "\(k) changed") }
        #expect(after["source"]!.hasPrefix(before["source"]!))
        #expect(after["handle"]!.hasPrefix(before["handle"]!))
        // the ledger has one row per record, decisions named
        let lines = try String(contentsOf: led, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 6)
        #expect(lines.filter { $0.contains("\tnew\t") }.count == 4)
        #expect(lines.filter { $0.contains("\tleft-out\tlikes-left-out") }.count == 1)
    }

    @Test func secondRunAndRereadAddNothing() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let recs = [f.post("p1", author: nil, ts: f.t0, body: "x"), f.comment("p1:c0", parent: "p1", author: "Ann Example", ts: f.t0 + 1, body: "y")]
        let u1 = f.write(f.head("fb-test"), recs, in: t.dir, name: "r1.jsonl")
        _ = try PostsImporter.importRecords(at: u1, into: t.db)
        let r2 = try PostsImporter.importRecords(at: u1, into: t.db)
        #expect(r2.status == .alreadyImported)
        // a re-read with a different reader version (another file, same dkeys) holds every record against the rows already there
        var h = f.head("fb-test"); h["reader"] = "test 2"
        let u2 = f.write(h, recs, in: t.dir, name: "r2.jsonl")
        let r3 = try PostsImporter.importRecords(at: u2, into: t.db)
        #expect(r3.status == .imported && r3.stats.postsWritten == 0 && r3.stats.commentsWritten == 0 && r3.stats.held == 2)
        #expect(try q(t.db, "SELECT count(*) FROM post") == 1 && (try q(t.db, "SELECT count(*) FROM post_comment")) == 1)
    }

    @Test func overlapWithAnEarlierExportIsHeldNeverWrittenTwice() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        // export A (minute precision): the owner's post with a friend's comment
        let a = f.write(f.head("fb-a"), [
            f.post("a1", author: nil, ts: f.t0, body: "Going to the beach  today <3", dkey: "a|1"),
            f.comment("a1:c0", parent: "a1", author: "Ann Example", ts: f.t0 + 60_000, body: "have fun", dkey: "a|1|c"),
            f.post("a2", author: nil, ts: f.t0 + 3_600_000, body: "Shared from the video app My Movie", dkey: "a|2"),
            f.post("a3", author: nil, ts: f.t0 + 7_200_000, body: "one", dkey: "a|3"),
            f.post("a4", author: nil, ts: f.t0 + 7_200_000, body: "two", dkey: "a|4"),
        ], in: t.dir, name: "a.jsonl")
        _ = try PostsImporter.importRecords(at: a, into: t.db)
        // export B (seconds): the same post with other whitespace and a heart, the app post with no text, a minute with two
        // candidates and no text to decide, a new post, and the owner's comment that is in B only
        let b = f.write(f.head("fb-b"), [
            f.post("b1", author: nil, ts: f.t0 + 31_000, body: "Going to the beach today ♥", precision: "second", dkey: "b|1"),
            f.post("b2", author: nil, ts: f.t0 + 3_600_000 + 12_000, body: nil, precision: "second", dkey: "b|2"),
            f.post("b3", author: nil, ts: f.t0 + 7_200_000 + 5_000, body: nil, precision: "second", dkey: "b|3"),
            f.post("b4", author: nil, ts: f.t0 + 9_000_000, body: "brand new", precision: "second", dkey: "b|4"),
            f.post("b5", author: nil, ts: f.t0 + 91_000, body: "Going to the beach today ♥", precision: "second", dkey: "b|5"),
        ], in: t.dir, name: "b.jsonl")
        let led = t.dir.appendingPathComponent("b.tsv")
        let r = try PostsImporter.importRecords(at: b, into: t.db, ledger: led)
        // b1 held (same author, inside the printed minute, same text three ways); b2 held (one side empty); b3 has no text and two
        // posts in its minute: paired in time order with one of them (gate 2; until then it was left out as ambiguous);
        // b4 new; b5 is a minute later than a1's printed minute: new
        #expect(r.stats.held == 3 && r.stats.postsWritten == 2 && r.stats.leftOut == 0)
        let text = try String(contentsOf: led, encoding: .utf8)
        #expect(text.contains("\theld\toverlap-empty-paired"))
        #expect(try q(t.db, "SELECT count(*) FROM post WHERE body LIKE 'Going to the beach%'") == 2)
    }

    @Test func commentsOfAHeldPostAttachToTheExistingPost() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let a = f.write(f.head("fb-a"), [f.post("a1", author: nil, ts: f.t0, body: "hello world", dkey: "a|1")], in: t.dir, name: "a.jsonl")
        _ = try PostsImporter.importRecords(at: a, into: t.db)
        let pid = try q(t.db, "SELECT id FROM post")
        let b = f.write(f.head("fb-b"), [
            f.post("b1", author: nil, ts: f.t0 + 10_000, body: "hello world", precision: "second", dkey: "b|1"),
            f.comment("b1:c0", parent: "b1", author: "Ann Example", ts: f.t0 + 70_000, body: "hi back", precision: "second", dkey: "b|1|c"),
        ], in: t.dir, name: "b.jsonl")
        _ = try PostsImporter.importRecords(at: b, into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM post") == 1)
        #expect(try q(t.db, "SELECT post_id FROM post_comment") == pid)
    }

    @Test func commentsOfALeftOutPostAreLeftOutToo() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let u = f.write(f.head("fb-a"), [
            f.skip("w1", what: "wall-post", reason: "time-not-own"),
            f.comment("w1:c0", parent: "w1", author: "Ann Example", ts: f.t0, body: "orphan?"),
        ], in: t.dir, name: "a.jsonl")
        let r = try PostsImporter.importRecords(at: u, into: t.db)
        #expect(r.stats.leftOut == 2 && r.stats.commentsWritten == 0)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment") == 0)
    }

    @Test func instagramUsernamesUseOnlyHighConfidenceMatches() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let u = f.write(f.head("ig-test", platform: "instagram", account: "instagram:owner"), [
            f.comment("c1", parent: nil, author: nil, ts: f.t0, body: "great shot", ns: "ig-user", on: "bea.gram"),
            f.comment("c2", parent: nil, author: nil, ts: f.t0 + 1, body: "lol", ns: "ig-user", on: "lowconf"),
            f.comment("c3", parent: nil, author: nil, ts: f.t0 + 2, body: "again", ns: "ig-user", on: "Bea.Gram"),
        ], in: t.dir, name: "i.jsonl")
        _ = try PostsImporter.importRecords(at: u, into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment c JOIN handle h ON h.id = c.on_handle_id WHERE h.normalized = 'ig:bea gram'") == 2)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized = 'ig:@lowconf'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment WHERE on_handle_id IS NULL") == 0)
    }

    @Test func aSeparateAccountsOwnPostsAreNotTheOwners() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        var p = f.post("s1", author: "other_account", ts: f.t0, body: "an invented story", kind: "story", ns: "ig-user")
        p["by_me"] = false
        let u = f.write(f.head("ig-side", platform: "instagram", account: "instagram:other_account"), [p], in: t.dir, name: "b.jsonl")
        _ = try PostsImporter.importRecords(at: u, into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM post WHERE by_me = 0 AND account = 'instagram:other_account'") == 1)
        #expect(try qs(t.db, "SELECT h.normalized FROM post p JOIN handle h ON h.id = p.author_handle_id") == "ig:@other_account")
    }

    @Test func placeholderNamesGetNoHandle() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let u = f.write(f.head("fb-a"), [f.post("p", author: "Facebook User", ts: f.t0, body: "?")], in: t.dir, name: "a.jsonl")
        _ = try PostsImporter.importRecords(at: u, into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM post WHERE author_handle_id IS NULL AND by_me = 0 AND author_name = 'Facebook User'") == 1)
        #expect(try q(t.db, "SELECT count(*) FROM handle WHERE normalized LIKE 'fb:facebook user%'") == 0)
    }

    @Test func dryRunWritesNothingAndDecidesTheSame() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let recs = [f.post("p1", author: "Dee New", ts: f.t0, body: "x"), f.comment("p1:c0", parent: "p1", author: nil, ts: f.t0 + 1, body: "y")]
        let u = f.write(f.head("fb-a"), recs, in: t.dir, name: "a.jsonl")
        let dl = t.dir.appendingPathComponent("dry.tsv"), rl = t.dir.appendingPathComponent("run.tsv")
        let before = try fingerprint(t.db)
        let d = try PostsImporter.importRecords(at: u, into: t.db, dryRun: true, ledger: dl)
        #expect(try fingerprint(t.db) == before)
        #expect(try !t.db.tableExists("post") || (try q(t.db, "SELECT count(*) FROM post")) == 0)
        let r = try PostsImporter.importRecords(at: u, into: t.db, ledger: rl)
        #expect(d.stats.postsWritten == r.stats.postsWritten && d.stats.commentsWritten == r.stats.commentsWritten && d.stats.newHandles == r.stats.newHandles)
        func decisions(_ u: URL) throws -> [String] {
            try String(contentsOf: u, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).prefix(12).joined(separator: "\t") }
        }
        #expect(try decisions(dl) == decisions(rl))
    }

    @Test func refusesARecordWithoutATimeOrAKnownParent() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        var bad = f.post("p", author: nil, ts: 0, body: "x"); bad.removeValue(forKey: "ts_ms")
        let u = f.write(f.head("fb-a"), [bad], in: t.dir, name: "a.jsonl")
        #expect(throws: (any Error).self) { try PostsImporter.importRecords(at: u, into: t.db) }
        let u2 = f.write(f.head("fb-b"), [f.comment("c", parent: "nope", author: nil, ts: f.t0, body: "x")], in: t.dir, name: "b.jsonl")
        #expect(throws: (any Error).self) { try PostsImporter.importRecords(at: u2, into: t.db) }
        #expect(try !t.db.tableExists("post") || (try q(t.db, "SELECT count(*) FROM post")) == 0)
    }

    // A comment whose post is known is held only against a comment on that same post.
    @Test func reviewF3CommentOverlapRespectsTheKnownPost() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let a = f.write(f.head("fb-a"), [
            f.post("p", author: nil, ts: f.t0, body: "first post", dkey: "a|p"),
            f.comment("p:c0", parent: "p", author: "Ann Example", ts: f.t0 + 60_000, body: "nice", dkey: "a|p|c"),
        ], in: t.dir, name: "a.jsonl")
        _ = try PostsImporter.importRecords(at: a, into: t.db)
        // another export: a different post Q (new), with Ann's "nice" in the same minute: a different comment, written
        let b = f.write(f.head("fb-b"), [
            f.post("q", author: nil, ts: f.t0 + 5 * 86_400_000, body: "a different post", precision: "second", dkey: "b|q"),
            f.comment("q:c0", parent: "q", author: "Ann Example", ts: f.t0 + 60_000, body: "nice", dkey: "b|q|c"),
        ], in: t.dir, name: "b.jsonl")
        let r = try PostsImporter.importRecords(at: b, into: t.db)
        #expect(r.stats.held == 0 && r.stats.commentsWritten == 1)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment WHERE body = 'nice'") == 2)
        // a comment with no post but "on X's post": held only when the earlier comment's post is X's
        var c = f.comment("z", parent: nil, author: nil, ts: f.t0 + 60_000, body: "nice too", precision: "second", dkey: "c|z", on: "Carl New")
        c["by_me"] = true
        let a2 = f.write(f.head("fb-a2"), [
            f.post("p2", author: "Ann Example", ts: f.t0, body: "anns post", dkey: "a2|p"),
            f.comment("p2:c0", parent: "p2", author: nil, ts: f.t0 + 60_000, body: "nice too", dkey: "a2|p|c"),
        ], in: t.dir, name: "a2.jsonl")
        _ = try PostsImporter.importRecords(at: a2, into: t.db)
        let cfile = f.write(f.head("fb-c"), [c], in: t.dir, name: "c.jsonl")
        let rc = try PostsImporter.importRecords(at: cfile, into: t.db)
        #expect(rc.stats.held == 0 && rc.stats.commentsWritten == 1)          // on Carl's post, not Ann's: not the same comment
        c["on"] = "Ann Example"; c["dkey"] = "d|z"
        let dfile = f.write(f.head("fb-d"), [c], in: t.dir, name: "d.jsonl")
        let rd = try PostsImporter.importRecords(at: dfile, into: t.db)
        #expect(rd.stats.held == 1 && rd.stats.commentsWritten == 0)          // on Ann's post: held
    }

    // The meta time-rule row is inserted once and never replaced; a different rule for the same export is an error.
    @Test func reviewF5MetaTimeRuleIsNeverReplaced() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        var h = f.head("fb-a"); h["time_rule"] = "rule one"
        let recs = [f.post("p", author: nil, ts: f.t0, body: "x", dkey: "a|p")]
        _ = try PostsImporter.importRecords(at: f.write(h, recs, in: t.dir, name: "a.jsonl"), into: t.db)
        #expect(try qs(t.db, "SELECT value FROM meta WHERE key = 'posts-fb-a.time_rule'") == "rule one")
        h["reader"] = "test 2"                                                  // a re-read, same rule: fine, meta unchanged
        _ = try PostsImporter.importRecords(at: f.write(h, recs, in: t.dir, name: "b.jsonl"), into: t.db)
        h["time_rule"] = "rule two"
        let sources = try q(t.db, "SELECT count(*) FROM source")
        #expect(throws: (any Error).self) { try PostsImporter.importRecords(at: f.write(h, recs, in: t.dir, name: "c.jsonl"), into: t.db) }
        #expect(try qs(t.db, "SELECT value FROM meta WHERE key = 'posts-fb-a.time_rule'") == "rule one")
        #expect(try q(t.db, "SELECT count(*) FROM source") == sources)
    }

    // A row found by dkey is the same record only when its content agrees.
    @Test func sameDkeyWithOtherContentIsNotHeld() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-a"), [
            f.post("p0", author: nil, ts: f.t0, body: "Go?", dkey: "K"),
            f.comment("p0:c0", parent: "p0", author: "Ann Example", ts: f.t0 + 60_000, body: "first", dkey: "K|c"),
        ], in: t.dir, name: "a.jsonl"), into: t.db)
        var h = f.head("fb-a"); h["reader"] = "re-read"
        let led = t.dir.appendingPathComponent("b.tsv")
        let r = try PostsImporter.importRecords(at: f.write(h, [
            f.post("p0", author: nil, ts: f.t0, body: "Go!", dkey: "K"),                                 // same key, other text
            f.comment("p0:c0", parent: "p0", author: "Ann Example", ts: f.t0 + 660_000, body: "new reply", dkey: "K|c2"),
        ], in: t.dir, name: "b.jsonl"), into: t.db, ledger: led)
        #expect(r.stats.held == 0 && r.stats.postsWritten == 0 && r.stats.commentsWritten == 0 && r.stats.leftOut == 2)
        let text = try String(contentsOf: led, encoding: .utf8)
        #expect(text.contains("\tleft-out\tdkey-conflict") && text.contains("\tleft-out\tparent-left-out"))
        #expect(try q(t.db, "SELECT count(*) FROM post_comment WHERE body = 'new reply'") == 0)
        // a comment whose key is held by a comment on another post is not that comment either
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-c"), [
            f.post("q", author: nil, ts: f.t0 + 9_000_000, body: "other post", dkey: "Q"),
            f.comment("q:c0", parent: "q", author: "Ann Example", ts: f.t0 + 60_000, body: "first", dkey: "K|c"),
        ], in: t.dir, name: "c.jsonl"), into: t.db)
        #expect(try q(t.db, "SELECT count(*) FROM post_comment WHERE body = 'first'") == 1)
    }

    // Dry run = run by construction, also when a comment's owner is a post planned in the same run.
    @Test func dryRunKnowsThePlannedPostsOwner() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        var old = f.comment("o", parent: nil, author: nil, ts: f.t0, body: "nice", precision: "second", dkey: "old|o", on: "Ann Example")
        old["by_me"] = true
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-old"), [old], in: t.dir, name: "o.jsonl"), into: t.db)
        let u = f.write(f.head("fb-new"), [
            f.post("c", author: "Carl New", ts: f.t0 - 86_400_000, body: "carls post", dkey: "new|c"),
            f.comment("c:c0", parent: "c", author: nil, ts: f.t0, body: "nice", dkey: "new|c|c"),
        ], in: t.dir, name: "n.jsonl")
        let dl = t.dir.appendingPathComponent("d.tsv"), rl = t.dir.appendingPathComponent("r.tsv")
        let d = try PostsImporter.importRecords(at: u, into: t.db, dryRun: true, ledger: dl)
        let r = try PostsImporter.importRecords(at: u, into: t.db, ledger: rl)
        #expect(d.stats.held == r.stats.held && d.stats.commentsWritten == r.stats.commentsWritten)
        #expect(r.stats.commentsWritten == 1 && r.stats.held == 0)
        func decisions(_ u: URL) throws -> [String] {
            try String(contentsOf: u, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).prefix(12).joined(separator: "\t") }
        }
        #expect(try decisions(dl) == decisions(rl))
    }

    // The 2025 export against existing 2011 rows: photos by id, renamed owners, each earlier row held once, empty app posts paired.
    @Test func overlapRules() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        let m = f.t0 + 3_600_000                                        // a printed minute
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-2011"), [
            f.post("a1", author: nil, ts: f.t0, body: nil, kind: "album-photo", dkey: "o|a1", ext: "111", basis: "uploaded"),
            f.post("a2", author: nil, ts: f.t0, body: nil, kind: "album-photo", dkey: "o|a2", ext: "222", basis: "uploaded"),
            f.post("w", author: "Anna Middle Testcase", ts: f.t0 + 7_200_000, body: "on your wall", dkey: "o|w"),
            f.comment("w:c0", parent: "w", author: nil, ts: f.t0 + 7_260_000, body: "sure, sounds good", dkey: "o|w|c"),
            f.comment("w:c1", parent: "w", author: nil, ts: f.t0 + 7_320_000, body: "ok", dkey: "o|w|c1"),
            f.post("p1", author: nil, ts: m, body: "Shared from the video app one", dkey: "o|p1"),
            f.post("p2", author: nil, ts: m, body: "Shared from the video app two", dkey: "o|p2"),
            f.post("p3", author: nil, ts: m, body: "Liked on the video app three", dkey: "o|p3"),
        ], in: t.dir, name: "o.jsonl"), into: t.db)
        var c1 = f.comment("c1", parent: nil, author: nil, ts: f.t0 + 7_262_000, body: "sure, sounds good", precision: "second", dkey: "n|c1", on: "Anna Testcase")
        c1["by_me"] = true
        var c2 = c1; c2["rid"] = "c2"; c2["dkey"] = "n|c2"                                      // the same comment printed twice: one is held, one is new
        var c3 = c1; c3["rid"] = "c3"; c3["dkey"] = "n|c3"; c3["body"] = "ok"; c3["ts_ms"] = NSNumber(value: f.t0 + 7_322_000)  // a second comment between the same two owners: the rename's evidence
        let led = t.dir.appendingPathComponent("n.tsv")
        let r = try PostsImporter.importRecords(at: f.write(f.head("fb-2025"), [
            f.post("b2", author: nil, ts: f.t0 + 20_000, body: nil, precision: "second", kind: "album-photo", dkey: "n|b2", ext: "222", basis: "uploaded"),
            f.post("b3", author: nil, ts: f.t0 + 21_000, body: nil, precision: "second", kind: "album-photo", dkey: "n|b3", ext: "333", basis: "uploaded"),
            c1, c2, c3,
            f.post("e1", author: nil, ts: m + 5_000, body: nil, precision: "second", kind: "app-post", dkey: "n|e1"),
            f.post("e2", author: nil, ts: m + 9_000, body: nil, precision: "second", kind: "app-post", dkey: "n|e2"),
        ], in: t.dir, name: "n.jsonl"), into: t.db, ledger: led)
        let text = try String(contentsOf: led, encoding: .utf8)
        func decision(_ rid: String) -> String {
            text.split(separator: "\n").first { $0.hasPrefix(rid + "\t") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false)[10...12].joined(separator: " ") } ?? ""
        }
        #expect(decision("b2").hasPrefix("held overlap-external-id"))           // photo 222, not photo 111 in the same minute
        #expect(decision("b3").hasPrefix("new"))                                // photo 333 is not in 2011
        #expect(decision("c1").hasPrefix("held overlap-text-owner-renamed"))    // Anna renamed: two comments between the same two owners
        #expect(decision("c3").hasPrefix("held overlap-text-owner-renamed"))
        #expect(decision("c2").hasPrefix("new"))                                // the 2011 row is already held by c1
        #expect(decision("e1").hasPrefix("held overlap-empty-paired") && decision("e2").hasPrefix("held overlap-empty-paired"))
        #expect(r.stats.held == 5 && r.stats.postsWritten == 1 && r.stats.commentsWritten == 1 && r.stats.leftOut == 0)
        let e1 = decision("e1").split(separator: " ").last!, e2 = decision("e2").split(separator: " ").last!
        #expect(e1 != e2)
    }

    // a rename is accepted only with evidence (a long text, or two comments between the same two owners); a photo post
    // without text or id never takes the photo that its album copy matches by id.
    @Test func renamesNeedEvidenceAndIdsClaimFirst() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-2011"), [
            f.post("ya", author: "Ya Ma", ts: f.t0, body: "a link", dkey: "o|ya"),
            f.comment("ya:c", parent: "ya", author: nil, ts: f.t0 + 60_000, body: "this invented comment is long enough ok", dkey: "o|ya|c"),
            f.post("lz", author: "Lex Pinecone", ts: f.t0 + 900_000, body: "hey", dkey: "o|lz"),
            f.comment("lz:c1", parent: "lz", author: nil, ts: f.t0 + 960_000, body: "noted!", dkey: "o|lz|c1"),
            f.comment("lz:c2", parent: "lz", author: nil, ts: f.t0 + 960_000, body: "short reply number", dkey: "o|lz|c2"),
            f.post("cr", author: "Cara Sample", ts: f.t0 + 1_800_000, body: "yo", dkey: "o|cr"),
            f.comment("cr:c", parent: "cr", author: nil, ts: f.t0 + 1_860_000, body: ":D", dkey: "o|cr|c"),
            f.post("ph", author: nil, ts: f.t0 + 3_600_000, body: nil, kind: "album-photo", dkey: "o|ph", ext: "999", basis: "uploaded"),
        ], in: t.dir, name: "o.jsonl"), into: t.db)
        func mine(_ rid: String, _ ts: Int64, _ body: String, _ on: String) -> [String: Any] {
            var c = f.comment(rid, parent: nil, author: nil, ts: ts, body: body, precision: "second", dkey: "n|\(rid)", on: on); c["by_me"] = true; return c
        }
        let led = t.dir.appendingPathComponent("n.tsv")
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-2025"), [
            f.post("story", author: nil, ts: f.t0 + 3_630_000, body: nil, precision: "second", kind: "photo", dkey: "n|story"),
            mine("j", f.t0 + 70_000, "this invented comment is long enough ok", "Jin Lee"),
            mine("l1", f.t0 + 961_000, "noted!", "Alexis Fixture"),
            mine("l2", f.t0 + 962_000, "short reply number", "Alexis Fixture"),
            mine("v", f.t0 + 1_861_000, ":D", "Vivi Example"),
            f.post("album", author: nil, ts: f.t0 + 3_600_000 + 8_000, body: nil, precision: "second", kind: "album-photo", dkey: "n|album", ext: "999", basis: "uploaded"),
        ], in: t.dir, name: "n.jsonl"), into: t.db, ledger: led)
        let text = try String(contentsOf: led, encoding: .utf8)
        func decision(_ rid: String) -> String {
            text.split(separator: "\n").first { $0.hasPrefix(rid + "\t") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false)[10...11].joined(separator: " ") } ?? ""
        }
        #expect(decision("j") == "held overlap-text-owner-renamed")       // a long text
        #expect(decision("l1") == "held overlap-text-owner-renamed" && decision("l2") == "held overlap-text-owner-renamed")  // two between the same owners
        #expect(decision("v") == "new ")                                   // one short text: no evidence of a rename
        #expect(decision("album") == "held overlap-external-id")           // the id claims the photo first
        #expect(decision("story") == "new ")                               // the story without text or id does not take it
    }

    // the 2011 export prints a shared link's title after the post's own text; 2025 prints the text alone.
    @Test func linkTextPrefix() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-2011"), [
            f.post("a", author: nil, ts: f.t0, body: "great. An invented follow-up sentence for the test", dkey: "o|a"),
            f.post("b", author: nil, ts: f.t0, body: "pick me None", dkey: "o|b"),
        ], in: t.dir, name: "o.jsonl"), into: t.db)
        let led = t.dir.appendingPathComponent("n.tsv")
        let r = try PostsImporter.importRecords(at: f.write(f.head("fb-2025"), [
            f.post("x", author: nil, ts: f.t0 + 30_000, body: "great.", precision: "second", kind: "app-post", dkey: "n|x"),
            f.post("y", author: nil, ts: f.t0 + 31_000, body: "pick me", precision: "second", kind: "app-post", dkey: "n|y"),
            f.post("z", author: nil, ts: f.t0 + 32_000, body: "pick", precision: "second", kind: "status", dkey: "n|z"),
        ], in: t.dir, name: "n.jsonl"), into: t.db, ledger: led)
        let text = try String(contentsOf: led, encoding: .utf8)
        #expect(r.stats.held == 2 && r.stats.postsWritten == 1)
        #expect(text.contains("x\tpost") && text.split(separator: "\n").first { $0.hasPrefix("x\t") }!.contains("\theld\toverlap-prefix"))
        #expect(text.split(separator: "\n").first { $0.hasPrefix("z\t") }!.contains("\tnew\t"))   // "pick": both rows already claimed
    }

    // A shared first name is not the same owner; a rename needs evidence.
    @Test func firstNameAloneNeverMakesOwnersAgree() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-2011"), [
            f.post("w", author: "Anna Middle Testcase", ts: f.t0, body: "hi", dkey: "o|w"),
            f.comment("w:c", parent: "w", author: nil, ts: f.t0 + 60_000, body: "Yes?", dkey: "o|w|c"),
        ], in: t.dir, name: "o.jsonl"), into: t.db)
        var c = f.comment("n", parent: nil, author: nil, ts: f.t0 + 80_000, body: "Yes?", precision: "second", dkey: "n|c", on: "Anna Smith")
        c["by_me"] = true
        let r = try PostsImporter.importRecords(at: f.write(f.head("fb-2025"), [c], in: t.dir, name: "n.jsonl"), into: t.db)
        #expect(r.stats.held == 0 && r.stats.commentsWritten == 1)
    }

    // A short surname is part of the full name ("Dana Wu" is not "Dana Et").
    @Test func shortNameComponentsCount() throws {
        let t = try seeded(); defer { t.cleanup() }
        let f = PostFixtures.self
        _ = try PostsImporter.importRecords(at: f.write(f.head("fb-2011"), [
            f.post("w", author: "Dana Et", ts: f.t0, body: "hi", dkey: "o|w"),
            f.comment("w:c", parent: "w", author: nil, ts: f.t0 + 60_000, body: "who, sam?", dkey: "o|w|c"),
        ], in: t.dir, name: "o.jsonl"), into: t.db)
        var c = f.comment("n", parent: nil, author: nil, ts: f.t0 + 110_000, body: "who, sam?", precision: "second", dkey: "n|c", on: "Dana Wu")
        c["by_me"] = true
        let r = try PostsImporter.importRecords(at: f.write(f.head("fb-2025"), [c], in: t.dir, name: "n.jsonl"), into: t.db)
        #expect(r.stats.held == 0 && r.stats.commentsWritten == 1)
    }
}
