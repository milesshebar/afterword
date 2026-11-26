import Foundation
import ArchiveCore

/// `archivectl posts`: the posts-and-comments record in the terminal (read-only).
func runPosts(args: [String], root: ArchiveRoot) throws {
    // every filter combines: a person (or a handle) or the owner's own, a day, a search; limits 1-100000
    let q: PostsCLIQuery
    switch PostsCLIQuery.parse(args) {
    case .success(let v): q = v
    case .failure(let e): eprint(e.description); exit(2)
    }
    let reader = try ArchiveReader(root: root)
    guard try reader.postsAvailable() else { print("this archive has no posts yet"); return }
    let zone = TimeZone.current
    var filter = PostsFilter(mineOnly: q.mine)
    if q.person != nil || q.handle != nil {
        var handles: [Int64] = []
        if let person = q.person {
            let idx = try reader.people(overrides: PeopleOverrides.read(root: root))
            guard let p = idx.persons[person] else { eprint("no person \(person) (ids come from `people list --names`)"); exit(1) }
            handles = p.handles.map(\.handleID)
        }
        if let handle = q.handle {
            let db = try Schema.openArchive(root: root, readOnly: true)
            let st = try db.prepare("SELECT id FROM handle WHERE normalized = ?")
            st.bind(1, handle)
            guard try st.step() else { eprint("no handle \(handle)"); exit(1) }
            handles.append(st.int(0))
        }
        filter.handles = handles
    }
    if let day = q.day {
        // a day runs from local midnight to the next local midnight: 23 or 25 hours on a clock-change day
        guard let r = PostsCLIQuery.dayRange(day, zone: zone) else { eprint("--day wants YYYY-MM-DD\n" + PostsCLIQuery.usage); exit(2) }
        filter.fromMs = r.from; filter.toMs = r.to - 1
    }
    let limit = q.limit
    let items = try q.search.map { try reader.searchPosts($0, filter: filter, order: q.order, limit: limit) } ?? reader.posts(filter: filter, limit: limit)
    let search = q.search, expand = q.expand
    let tf = DateFormatter(); tf.dateFormat = "yyyy-MM-dd HH:mm"; tf.timeZone = zone
    func when(_ it: PostItem) -> String {
        tf.string(from: Date(timeIntervalSince1970: Double(it.ts) / 1000)) + (it.basis == "tagged" ? " (tagged)" : "")
    }
    func line(_ it: PostItem) -> String {
        let who = it.byMe ? "Me" : (it.author ?? "(not named)")
        var whereText = ""
        if it.isComment { whereText = it.onMe ? " on my post" : (it.target.map { " on \($0)'s post" } ?? "") }
        else if let t = it.target { whereText = " on \(t)'s timeline" }
        if let g = it.targetText { whereText += " · \(g)" }
        let text = (it.snippet.map { $0.replacingOccurrences(of: "\u{1}", with: "[").replacingOccurrences(of: "\u{2}", with: "]") } ?? it.body ?? it.context ?? it.link ?? "(\(it.kind))")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(when(it))  \(it.platform == "instagram" ? "IG" : "FB") \(it.isComment ? "comment" : it.kind)  \(who)\(whereText): \(text.prefix(160))"
    }
    let entries = (search != nil || expand) ? items.map { PostEntry(album: nil, day: nil, items: [$0]) } : ArchiveReader.groupAlbums(items, zone: zone)
    for e in entries {
        if let album = e.album {
            print("\(e.day ?? "")        FB album  \(album): \(e.count) photos  (--expand to list)")
        } else {
            print(line(e.items[0]))
        }
    }
    print("\(items.count) record(s)\(items.count == limit ? " (limit reached: --limit)" : "")")
}
