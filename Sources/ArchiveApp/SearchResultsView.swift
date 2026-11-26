import SwiftUI
import ArchiveCore

enum Snippet {
    /// Builds a highlighted string from FTS5 snippet text, where matches are wrapped in U+0001 ... U+0002.
    static func attributed(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var inMatch = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            if inMatch {
                piece.backgroundColor = Color.yellow.opacity(0.45)
                piece.font = .callout.weight(.semibold)
            }
            out.append(piece)
            buffer = ""
        }
        for ch in raw.replacingOccurrences(of: "\n", with: " ") {
            if ch == "\u{1}" { flush(); inMatch = true }
            else if ch == "\u{2}" { flush(); inMatch = false }
            else { buffer.append(ch) }
        }
        flush()
        return out
    }
}

struct SearchHitRow: View {
    @Environment(AppModel.self) private var app
    let hit: SearchHit
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.title(forThread: hit.threadID)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.listDate(hit.tsMs)).font(.caption).foregroundStyle(.secondary)
            }
            if hit.isVoice {
                Label("Voice message · machine transcript, not verified", systemImage: "waveform").font(.caption2).foregroundStyle(.secondary)
            }
            Text(Snippet.attributed(hit.snippet)).font(.callout).lineLimit(3)
            Text((hit.isFromMe ? "You" : app.senderName(normalized: hit.senderNormalized, archiveName: hit.senderArchiveName)) + " · " + Fmt.fullDate(hit.tsMs) + " · " + ServiceKey.of(messageService: hit.service).label)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isSnapshot { Text("Order: \(app.searchOrder == .bestMatch ? "Best match" : app.searchOrder == .newest ? "Newest" : "Oldest") ⌄").font(.caption) }
                    else {
                        Picker("Order", selection: $app.searchOrder) {
                            Text("Best match").tag(SearchOrder.bestMatch)
                            Text("Newest").tag(SearchOrder.newest)
                            Text("Oldest").tag(SearchOrder.oldest)
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    }
                }
                if isSnapshot { Text("Scope: \(app.searchScope.rawValue)").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    Picker("Scope", selection: $app.searchScope) {
                        ForEach(SearchScope.allCases.filter { $0 != .thread || app.selection != nil }) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            results
        }
    }

    private var statusLine: String {
        if app.searchScope == .posts {
            if app.searchRunning && app.postHits.isEmpty { return "Searching…" }
            let n = app.postHits.count
            return n == 0 ? "No posts or comments match" : "\(n)\(n >= app.searchHitLimit ? "+" : "") post\(n == 1 ? "" : "s") and comments"
        }
        if app.searchRunning && app.searchHits.isEmpty { return "Searching…" }
        let n = app.searchHits.count
        if n == 0 { return "No messages match" }
        let more = n >= 200 ? "+" : ""
        return "\(n)\(more) message\(n == 1 ? "" : "s") · \(String(format: "%.0f", app.searchSeconds * 1000)) ms"
    }

    @ViewBuilder private var results: some View {
        if app.searchScope == .posts {
            List {
                ForEach(app.postHits) { PostRow(item: $0) }
                if app.postHits.count >= app.searchHitLimit {
                    Button("Show 200 more results") { app.loadMoreHits() }.buttonStyle(.link).frame(maxWidth: .infinity)
                }
            }
            .listStyle(.sidebar)
        } else if isSnapshot {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(app.searchHits.prefix(9)) { h in
                            SearchHitRow(hit: h).padding(.horizontal, 10)
                                .background(h.messageID == app.selectedHitID ? Color.accentColor.opacity(0.22) : .clear)
                            Divider().padding(.leading, 10)
                        }
                    }
                }
                .clipped()
        } else {
            List(selection: Binding(get: { app.selectedHitID }, set: { id in
                if let id, let hit = app.searchHits.first(where: { $0.messageID == id }) { app.open(hit: hit) }
            })) {
                ForEach(app.searchHits) { h in SearchHitRow(hit: h).tag(h.messageID as Int64?) }
                if app.searchHits.count >= app.searchHitLimit {
                    Button("Show 200 more results") { app.loadMoreHits() }.buttonStyle(.link).frame(maxWidth: .infinity)
                }
            }
            .listStyle(.sidebar)
        }
    }
}
