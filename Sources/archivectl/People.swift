import Foundation
import ArchiveCore

private func personMix(_ p: Person) -> String {
    var parts = Set<String>()
    for h in p.handles { parts.insert(h.service?.label ?? "phone") }
    return parts.sorted().joined(separator: "+")
}

/// `archivectl people ...`: the by-person grouping and the user's corrections to it.
func runPeople(args rest: [String], root: ArchiveRoot) throws {
    var args = rest
    let subs = ["list", "show", "match", "merge", "split", "rename", "hide", "unhide", "reset"]
    let sub = args.first.flatMap { subs.contains($0) ? $0 : nil } ?? "list"
    if args.first == sub { args.removeFirst() }
    func intArgs() -> [Int64] { args.compactMap { Int64($0) } }

    if sub == "match" {
        let db = try Schema.openArchive(root: root)
        let r = try PeopleStore.rematch(db: db)
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        print("people: \(r.handles) handles with a 1:1 conversation -> \(r.persons) people; \(r.linkedPersons) matched across \(r.linkedHandles) handles; \(r.ambiguousNames) ambiguous names (\(r.ambiguousHandles) handles) left unlinked")
        return
    }

    let reader = try ArchiveReader(root: root)
    var index = try reader.people(overrides: PeopleOverrides.read(root: root))

    func writable() throws -> PeopleOverrides { try PeopleOverrides(root: root) }
    func reload() throws { index = try reader.people(overrides: PeopleOverrides.read(root: root)) }
    func show(_ p: Person) {
        print("person \(p.id): \(p.name ?? "(no name)")\(p.renamedTo != nil ? " [renamed]" : "")\(p.hidden ? " [hidden]" : "")  \(p.messages) messages")
        for h in p.handles {
            print("  handle \(h.handleID)  \(h.service?.label ?? "phone/email")  \(h.origin) \(String(format: "%.2f", h.confidence)) \(h.reason)  \(h.messages) messages  \(h.name ?? "-")  \(h.raw)")
        }
    }

    switch sub {
    case "list":
        let limit = args.firstIndex(of: "--limit").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 50
        let persons = index.persons.values.sorted { $0.messages > $1.messages }
        let multi = persons.filter { $0.handles.count > 1 }
        var sizes: [Int: Int] = [:]
        for p in multi { sizes[p.handles.count, default: 0] += 1 }
        var mixes: [String: Int] = [:]
        for p in multi { mixes[personMix(p), default: 0] += 1 }
        let o = index.overrides
        let sizeText = sizes.sorted { $0.key < $1.key }.map { "\($0.value) of \($0.key)" }.joined(separator: ", ")
        let mixText = mixes.isEmpty ? "none" : mixes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("archive: \(root.url.path)   schema v\(reader.schemaVersion)   matches: \(index.source.rawValue)")
        print("handles with a 1:1 conversation: \(index.personOfHandle.count)")
        print("people: \(persons.count)   single-handle \(persons.count - multi.count)   multi-handle \(multi.count) (\(sizeText))")
        print("multi-handle by services: \(mixText)")
        print("corrections (people.sqlite): \(o.links.count) links, \(o.detached.count) split handles, \(o.renames.count) renamed handles, \(o.hidden.count) hidden handles")
        print("ambiguous names (never linked): \(index.ambiguous.count) (\(index.ambiguous.reduce(0) { $0 + $1.handleIDs.count }) handles)")
        if args.contains("--names") {
            print("multi-handle people, most messages first (up to \(limit)):")
            for p in multi.prefix(limit) { print("  \(p.id)\t\(personMix(p))\t\(p.messages)\t\(p.name ?? "(no name)")") }
        }
        if args.contains("--ambiguous") {
            print("ambiguous names:")
            for a in index.ambiguous.prefix(limit) {
                print("  \(a.key)\t" + a.handleIDs.map { h in index.person(ofHandle: h).map { "person \($0.id)" } ?? "handle \(h)" }.joined(separator: ", "))
            }
        }
    case "show":
        guard let id = intArgs().first, let p = index.persons[id] else { eprint("no such person (ids come from `people list --names`)"); exit(2) }
        show(p)
    case "merge":
        let ids = intArgs()
        guard ids.count >= 2, ids.allSatisfy({ index.persons[$0] != nil }) else { eprint("usage: people merge <id> <id>...  (ids from `people list --names`)"); exit(2) }
        let result = try PeopleActions.merge(ids, in: index, overrides: try writable())
        try reload()
        if let r = result, let p = index.persons[r] { show(p) }
    case "split":
        let ids = intArgs()
        guard ids.count >= 2, let p = index.persons[ids[0]] else { eprint("usage: people split <person id> <handle id>...  (handle ids from `people show <id>`)"); exit(2) }
        guard let r = try PeopleActions.split(person: p.id, handleIDs: Array(ids.dropFirst()), in: index, overrides: try writable()) else {
            eprint("nothing to split: name handles of that person, and leave at least one behind"); exit(2)
        }
        try reload()
        for id in [r.stays, r.splitOff] { if let q = index.persons[id] { show(q) } }
    case "rename":
        guard let id = args.first.flatMap({ Int64($0) }), index.persons[id] != nil else { eprint("usage: people rename <id> <name...>"); exit(2) }
        let name = args.dropFirst().joined(separator: " ")
        try PeopleActions.rename(person: id, to: name, in: index, overrides: try writable())
        try reload()
        if let p = index.persons[id] { show(p) }
    case "hide", "unhide":
        guard let id = intArgs().first, index.persons[id] != nil else { eprint("usage: people \(sub) <id>"); exit(2) }
        try PeopleActions.setHidden(person: id, sub == "hide", in: index, overrides: try writable())
        try reload()
        if let p = index.persons[id] { show(p) }
    case "reset":
        guard let id = intArgs().first, index.persons[id] != nil else { eprint("usage: people reset <id>"); exit(2) }
        try PeopleActions.reset(person: id, in: index, overrides: try writable())
        try reload()
        if let p = index.persons[id] { show(p) }
    default:
        eprint("unknown people command")
        exit(2)
    }
}
