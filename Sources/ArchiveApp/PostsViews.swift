import SwiftUI
import ArchiveCore

/// One post or comment: who (the owner by by_me, never by a missing author), where, when (a tag time says so), the text.
struct PostRow: View {
    let item: PostItem
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.listDate(item.ts)).font(.caption).foregroundStyle(.secondary)
            }
            if let s = item.snippet { Text(Snippet.attributed(s)).font(.callout).lineLimit(4) }
            else if let b = item.body, !b.isEmpty { Text(b).font(.callout).lineLimit(6).textSelection(.enabled) }
            else { Text(item.context ?? item.link ?? "(\(item.kind))").font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            if item.isComment, let pb = item.postBody, !pb.isEmpty {
                Text("on: " + pb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(footer).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    static func who(_ it: PostItem) -> String {
        if it.byMe { return "You" }
        return it.author ?? "Someone (not named)"
    }

    private var headline: String {
        let who = Self.who(item)
        if item.isComment {
            if item.onMe { return "\(who) commented on your post" }
            return item.target.map { "\(who) commented on \($0)'s post" } ?? "\(who) commented"
        }
        if let t = item.target { return "\(who) → \(t)" }
        return who
    }

    private var footer: String {
        var parts = [item.platform == "instagram" ? "Instagram" : "Facebook", item.isComment ? "comment" : item.kind]
        if let g = item.targetText { parts.append(g) }
        parts.append(Fmt.fullDate(item.ts) + (item.basis == "tagged" ? " (when you were tagged)" : ""))
        return parts.joined(separator: " · ")
    }
}

/// A list line: one post or comment, or an album's photos of one day folded into one line that expands.
struct PostEntryRow: View {
    let entry: PostEntry
    var body: some View {
        if let album = entry.album {
            DisclosureGroup {
                ForEach(entry.items) { PostRow(item: $0) }
            } label: {
                HStack {
                    Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
                    Text("\(album): \(entry.count) photos").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(entry.day ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let it = entry.items.first {
            PostRow(item: it)
        }
    }
}

/// A person's posts and comments, newest first (the person page's "Posts and comments").
struct PersonPostsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.personPosts.isEmpty {
            Text(app.personPostCount == 0 ? "No posts or comments with this person" : "Loading posts…")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(app.personPosts) { PostEntryRow(entry: $0) }
                if app.postsState.canLoadMore {
                    Button("Show more (\(app.postsState.loaded.formatted()) of \((app.postsState.total ?? 0).formatted()))") { app.loadMorePersonPosts() }
                        .buttonStyle(.link).frame(maxWidth: .infinity)
                }
            }
            .listStyle(.inset)
        }
    }
}
