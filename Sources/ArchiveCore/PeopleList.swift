import Foundation

/// One row of the by-person list: a person with the totals over their 1:1 conversations.
public struct PersonRow: Sendable, Identifiable, Hashable {
    public var id: Int64 { person.id }
    public var person: Person
    /// The person's threads that have messages in the list's range and are not hidden (unless hidden ones were asked for).
    public var threadIDs: [Int64]
    public var messageCount: Int
    public var lastTsMs: Int64
    public var preview: String?
    public var serviceCounts: [ServiceKey: Int]
    /// Threads in `threadIDs` that are hidden by default (filtered threads, message requests).
    public var hiddenThreads: Int
    public var services: [ServiceKey] { serviceCounts.filter { $0.value > 0 }.keys.sorted() }
}

public struct ListRoll: Sendable {
    public var people: [PersonRow]
    /// Group threads, each its own row.
    public var groups: [ConversationSummary]
    /// 1:1 threads whose handle is not in the person index (cannot happen with a fresh index; shown as plain threads).
    public var orphans: [ConversationSummary]
}

public enum PeopleList {
    /// Rolls per-thread summaries up to people. Group threads stay separate rows. Hidden Meta threads and people hidden
    /// by the user are left out unless `includeHidden`.
    public static func roll(conversations: [ConversationSummary], index: PeopleIndex, includeHidden: Bool) -> ListRoll {
        var rows: [Int64: PersonRow] = [:]
        var previewTs: [Int64: Int64] = [:]
        var groups: [ConversationSummary] = [], orphans: [ConversationSummary] = []
        for c in conversations {
            if c.hidden && !includeHidden { continue }
            if c.isGroup { groups.append(c); continue }
            guard let pid = index.personOfThread[c.id], let person = index.persons[pid] else { orphans.append(c); continue }
            if person.hidden && !includeHidden { continue }
            var r = rows[pid] ?? PersonRow(person: person, threadIDs: [], messageCount: 0, lastTsMs: Int64.min, preview: nil, serviceCounts: [:], hiddenThreads: 0)
            r.threadIDs.append(c.id)
            r.messageCount += c.messageCount
            if c.hidden { r.hiddenThreads += 1 }
            for (k, v) in c.serviceCounts { r.serviceCounts[k, default: 0] += v }
            if c.lastTsMs >= r.lastTsMs { r.lastTsMs = c.lastTsMs }
            if c.lastTsMs >= (previewTs[pid] ?? Int64.min) { previewTs[pid] = c.lastTsMs; r.preview = c.preview }
            rows[pid] = r
        }
        for k in rows.keys { rows[k]!.threadIDs.sort() }
        return ListRoll(people: Array(rows.values), groups: groups, orphans: orphans)
    }
}
