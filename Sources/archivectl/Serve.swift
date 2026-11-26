import Foundation
import ArchiveCore

/// `archivectl serve`: the review site on 127.0.0.1.
func runServe(args rest: [String], root: ArchiveRoot) throws {
    var args = rest
    var port: UInt16 = 8097
    var hosts: [String] = []
    var logins: [String] = []
    while let i = args.firstIndex(where: { $0 == "--port" || $0 == "--allow-host" || $0 == "--allow-login" }) {
        guard i + 1 < args.count else { eprint("\(args[i]) needs a value"); exit(2) }
        if args[i] == "--port" {
            guard let p = UInt16(args[i + 1]) else { eprint("--port needs a number"); exit(2) }
            port = p
        } else if args[i] == "--allow-host" { hosts.append(args[i + 1]) }
        else { logins.append(args[i + 1]) }
        args.removeSubrange(i...(i + 1))
    }
    if !hosts.isEmpty && logins.isEmpty { eprint("--allow-host needs at least one --allow-login <tailscale login>: behind tailscale serve everyone on the node's share list would otherwise be let in"); exit(2) }
    eprint("loading \(root.url.path) ...")
    let service = try ReviewService(root: root)
    let site = ReviewSite(service: service, extraHosts: hosts, allowedLogins: logins)
    let server = HTTPServer(host: "127.0.0.1", port: port) { site.handle($0) }
    try server.start()
    let sum = service.queueSummary()
    print("review site: http://127.0.0.1:\(server.port)/   (ready in \(String(format: "%.1f", service.lastRefreshSeconds)) s)")
    print("queues: \(service.suggestionCount[.crossService] ?? 0) Messenger/Instagram suggestions, \(service.suggestionCount[.duplicates] ?? 0) duplicate suggestions (\(sum.total) cards)")
    print("loopback only; decisions are written to \(PeopleOverrides.fileURL(root: root).path). Behind tailscale serve, open the proxied URL. Ctrl-C stops it.")
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()
}

/// `archivectl suggest`: numbers only, so it is safe to paste.
func runSuggest(args: [String], root: ArchiveRoot) throws {
    let service = try ReviewService(root: root)
    if args.contains("--cards") {
        // Names and usernames (private): for local use only, never commit or paste the output anywhere public.
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let all = service.remainingCards(.crossService) + service.remainingCards(.duplicates) + service.remainingCards(.whos)
        print(String(decoding: try enc.encode(all), as: UTF8.self))
        return
    }
    let cross = service.queueSummary().cross
    func bucket(_ s: Double) -> String { s >= 0.9 ? "0.90-1.00" : s >= 0.8 ? "0.80-0.89" : s >= 0.7 ? "0.70-0.79" : s >= 0.6 ? "0.60-0.69" : s >= 0.5 ? "0.50-0.59" : "0.40-0.49" }
    var dist: [String: Int] = [:]
    for s in cross { dist[bucket(s.topScore), default: 0] += 1 }
    let withGroups = cross.filter { $0.candidates.first?.sharedGroupPeople ?? 0 > 0 }.count
    let anyGroups = cross.filter { $0.candidates.contains { $0.sharedGroupPeople > 0 } }.count
    print("computed in \(String(format: "%.1f", service.lastRefreshSeconds)) s")
    print("Messenger/Instagram queue: \(cross.count) suggestions; duplicates queue: \(service.suggestionCount[.duplicates] ?? 0); who's-this queue: \(service.suggestionCount[.whos] ?? 0)")
    print("top-score distribution: " + dist.sorted { $0.key > $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    print("with shared-group evidence: top candidate \(withGroups), any candidate \(anyGroups)")
    let counts = cross.map { $0.candidates.count }
    var kinds: [String: Int] = [:]
    for s in cross { if let top = s.candidates.first { for r in top.reasons {
        // reason kind only: drop anything in parentheses (it can carry names) and counts
        var k = r.split(separator: "(").first.map(String.init) ?? r
        k = String(k.filter { !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        kinds[k, default: 0] += 1
    } } }
    print("reasons on the top candidate:")
    for (k, n) in kinds.sorted(by: { $0.value > $1.value }) { print("  \(n)  \(k)") }
    var labels: [String: Int] = [:]
    for s in cross { labels[ReviewService.label(s.topScore), default: 0] += 1 }
    print("top label: " + ["strong", "likely", "possible"].map { "\($0) \(labels[$0] ?? 0)" }.joined(separator: ", "))
    print("group-evidence-only top candidates: \(cross.filter { $0.candidates.first?.groupOnly == true }.count)")
    let t = service.tuning
    print("tuning rules (candidates removed): " + (t.droppedByRule.isEmpty ? "none" : t.droppedByRule.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: "; ")))
    print("cards that lost a candidate: \(t.cardsWithDrops) (\(t.cardsLost) lost every candidate and left the queue" + (t.cardsLostByRule.isEmpty ? "" : ": " + t.cardsLostByRule.sorted { $0.key < $1.key }.map { "\($0.value) by \($0.key)" }.joined(separator: "; ")) + ")")
    print("candidates per suggestion: mean \(String(format: "%.2f", Double(counts.reduce(0, +)) / Double(max(1, counts.count)))), max \(counts.max() ?? 0)")
}
