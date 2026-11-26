import SwiftUI
import QuickLook
import ArchiveCore

struct DaySeparator: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 18).padding(.bottom, 6)
    }
}

/// A system line in the timeline: someone was added, a call ended, a message was unsent.
struct SystemNoteRow: View {
    let row: MessageRow
    var body: some View {
        HStack(spacing: 5) {
            if row.kind == "call" { Image(systemName: "phone.fill").font(.system(size: 9)) }
            Text(row.note ?? "").italic(row.kind == "unsent")
        }
        .font(.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6).padding(.horizontal, 30)
        .help(Fmt.fullDate(row.tsMs))
    }
}

/// A call from the call logs (phone, FaceTime, WhatsApp, Skype) at its time in a 1:1 timeline. Messenger, Instagram and GroupMe calls
/// are messages already (SystemNoteRow).
struct CallLineRow: View {
    let call: CallRow
    let showTime: Bool
    var body: some View {
        VStack(spacing: 2) {
            if showTime { Text(Fmt.time(call.tsMs)).font(.caption2).foregroundStyle(.tertiary).padding(.top, 6) }
            HStack(spacing: 5) {
                Image(systemName: call.service.hasPrefix("facetime-video") ? "video.fill" : "phone.fill").font(.system(size: 9))
                Text(call.label)
            }
            .font(.caption)
            .foregroundStyle(missed ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6).padding(.horizontal, 30)
        .help(Fmt.fullDate(call.tsMs))
    }
    private var missed: Bool { !call.isFromMe && call.outcome != "answered" }
}

/// Tapbacks and Messenger / Instagram reactions under a bubble, grouped by emoji.
struct ReactionsView: View {
    @Environment(AppModel.self) private var app
    let reactions: [ReactionInfo]
    var body: some View {
        let groups = Dictionary(grouping: reactions, by: \.emoji)
        HStack(spacing: 4) {
            ForEach(groups.keys.sorted(), id: \.self) { emoji in
                let who = groups[emoji] ?? []
                HStack(spacing: 2) {
                    Text(emoji).font(.system(size: 11))
                    if who.count > 1 { Text("\(who.count)").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .help(who.map { $0.byMe ? "You" : app.senderName(normalized: $0.actorNormalized, archiveName: $0.actorArchiveName) }.joined(separator: ", "))
            }
        }
    }
}

struct MessageBubbleRow: View {
    @Environment(AppModel.self) private var app
    let model: ThreadModel
    let row: MessageRow
    let showSender: Bool
    let showTime: Bool
    let tight: Bool

    private var bodyText: String? {
        guard let b = row.body?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return nil }
        return b
    }
    private var mine: Color { row.serviceKey.tint }
    private var highlighted: Bool { model.highlightID == row.id }
    /// Merged timelines tag each message with its service.
    private var tag: ServiceTag? { model.isMerged ? ServiceTag(service: row.serviceKey) : nil }

    var body: some View {
        if row.kind != nil, bodyText == nil, row.attachments.isEmpty { SystemNoteRow(row: row) } else { bubble }
    }

    private var bubble: some View {
        VStack(alignment: row.isFromMe ? .trailing : .leading, spacing: 2) {
            if showTime {
                Text(Fmt.time(row.tsMs))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6).padding(.bottom, 2)
            }
            if showSender {
                Text(app.senderName(normalized: row.senderNormalized, archiveName: row.senderArchiveName))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            ForEach(row.attachments) { att in
                AttachmentView(model: model, message: row, attachment: att, tag: tag)
            }
            if let text = bodyText {
                HStack(spacing: 0) {
                    if row.isFromMe { Spacer(minLength: 90); if let tag { tag } }
                    VStack(alignment: .leading, spacing: 2) {
                        if let s = row.subject, !s.isEmpty, s != "null" { Text(s).fontWeight(.semibold) }
                        Text(text)
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(row.isFromMe ? Color.white : Color.primary)
                    .background(row.isFromMe ? mine : Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    if !row.isFromMe { if let tag { tag }; Spacer(minLength: 90) }
                }
                .help(Fmt.fullDate(row.tsMs))
                .contextMenu {
                    Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    Text(Fmt.fullDate(row.tsMs) + (model.isMerged ? " · " + row.serviceKey.label : ""))
                }
            }
            if !row.reactions.isEmpty { ReactionsView(reactions: row.reactions).padding(.horizontal, 8) }
        }
        .frame(maxWidth: .infinity, alignment: row.isFromMe ? .trailing : .leading)
        .padding(.top, tight ? 0 : 5)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(highlighted ? Color.yellow.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.4), value: highlighted)
    }
}

struct AttachmentView: View {
    let model: ThreadModel
    let message: MessageRow
    let attachment: AttachmentInfo
    var tag: ServiceTag?

    var body: some View {
        HStack(spacing: 0) {
            if message.isFromMe { Spacer(minLength: 90); if let tag { tag } }
            if attachment.isAudio, let info = model.voice[attachment.sha256] {
                // a voice message: its player and machine transcript (the file itself still opens from the context menu)
                VoiceMessageView(model: model, attachment: attachment, info: info, mine: message.isFromMe)
                    .contextMenu { Button("Open the Original File") { model.quickLook(attachment, in: message) } }
            } else {
                Button { model.quickLook(attachment, in: message) } label: {
                    if attachment.isImage { ThumbnailView(attachment: attachment) } else { FileChip(attachment: attachment) }
                }
                .buttonStyle(.plain)
                .help(attachment.filename ?? attachment.mime ?? "Attachment")
            }
            if !message.isFromMe { if let tag { tag }; Spacer(minLength: 90) }
        }
    }
}

struct ThumbnailView: View {
    let attachment: AttachmentInfo
    // The macOS 27 SDK in the Command Line Tools makes @State a macro whose plugin only ships with Xcode, so state is
    // declared with the State struct directly (exactly what the wrapper expands to).
    private var _image = State<NSImage?>(initialValue: nil)
    private var _failed = State(initialValue: false)
    private var image: NSImage? { get { _image.wrappedValue } nonmutating set { _image.wrappedValue = newValue } }
    private var failed: Bool { get { _failed.wrappedValue } nonmutating set { _failed.wrappedValue = newValue } }

    init(attachment: AttachmentInfo) {
        self.attachment = attachment
        _image = State<NSImage?>(initialValue: Thumbnails.shared.cached(attachment.sha256))
    }

    var body: some View {
        ZStack {
            Color.primary.opacity(0.07)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title2)
                    Text("Image not available").font(.caption2)
                }.foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 230, height: 172)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: attachment.sha256) {
            if image == nil {
                let img = await Thumbnails.shared.load(attachment)
                image = img
                failed = img == nil
            }
        }
        .accessibilityLabel("Photo")
    }
}

struct FileChip: View {
    let attachment: AttachmentInfo

    private var symbol: String {
        if attachment.isVideo { return "film" }
        if attachment.isAudio { return "waveform" }
        switch (attachment.mime ?? "").lowercased() {
        case "application/pdf": return "doc.richtext"
        case "text/x-vcard", "text/vcard": return "person.crop.rectangle"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename ?? (attachment.mime ?? "Attachment")).lineLimit(1).truncationMode(.middle)
                Text(Fmt.bytes(attachment.bytes) + " · click to preview").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
