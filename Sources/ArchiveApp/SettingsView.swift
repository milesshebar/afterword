import SwiftUI
import ArchiveCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // ImageRenderer cannot draw a grouped Form, so the snapshot lays the same sections out in plain stacks.
            VStack(alignment: .leading, spacing: 14) {
                Text("Archive").font(.headline)
                archiveSection
                Divider()
                Text("Contacts").font(.headline)
                contactsSection
            }
            .padding(20).frame(width: 560, alignment: .leading)
        } else {
            Form {
                Section("Archive") { archiveSection }
                Section("Contacts") { contactsSection }
                Section("Updates") {
                    LabeledContent("Version") { Text(Updater.shared.versionLine).foregroundStyle(.secondary) }
                    Text(Updater.shared.statusLine).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check for Updates") { Updater.shared.check(automatic: false) }
                        if Updater.shared.staged != nil { Button("Install Update and Relaunch") { Updater.shared.installStaged(relaunch: true) } }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var archiveSection: some View {
        Group {
                LabeledContent("Folder") {
                    Text(app.root.url.path).font(.callout.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .trailing)
                }
                LabeledContent("Status") { Text(statusText).foregroundStyle(statusColor) }
                if isSnapshot {
                    Text("[ Choose Folder… ]  [ Use Default Location ]  [ Reload ]  [ Show in Finder ]").font(.caption)
                } else { HStack {
                    Button("Choose Folder…") { if let u = ArchiveChooser.pick() { app.setRoot(u) } }
                    Button("Use Default Location") { app.setRoot(nil) }
                        .disabled(app.root.url.standardizedFileURL == ArchiveRoot.defaultURL.standardizedFileURL)
                    Button("Reload") { app.reload() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.root.url]) }
                } }
                Text("The whole folder (archive.sqlite and media/) can live anywhere, including a mounted network share. Everything inside is stored relative to it, so moving it is copy the folder, then choose it here. The archive is only ever opened read-only by this app.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var contactsSection: some View {
        Group {
                LabeledContent("Access") { Text(contactsText).foregroundStyle(.secondary) }
                if !isSnapshot { HStack {
                    if app.contacts.access == .notDetermined {
                        Button("Allow Access to Contacts…") { Task { await app.contacts.requestAccess(); await app.refreshContacts() } }
                            .disabled(!ContactsResolver.canPrompt)
                    }
                    if app.contacts.access == .authorized { Button("Reload Contacts") { Task { await app.refreshContacts() } } }
                    if app.contacts.access == .denied {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
                        }
                    }
                } }
                Text("Names are looked up in the Contacts app each time they are shown and never copied into the archive. Without access, names come from the iPhone address book and the Android export.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch app.phase {
        case .loading: return "Opening…"
        case .ready:
            let o = app.overview
            var s = "\((o?.messages ?? 0).formatted()) messages in \((o?.threads ?? 0).formatted()) conversations"
            if app.isNetworkRoot { s += " · network volume (read-only, thumbnails cached locally)" }
            return s
        case .missing(let t), .failed(let t): return t
        }
    }
    private var statusColor: Color { if case .ready = app.phase { return .secondary } else { return .red } }

    private var contactsText: String {
        switch app.contacts.access {
        case .authorized: return "Allowed · \(app.contacts.contactCount.formatted()) contacts, \(app.contacts.names.count.formatted()) numbers and emails"
        case .notDetermined: return ContactsResolver.canPrompt ? "Not asked yet" : "Not available when running unbundled (use scripts/bundle.sh)"
        case .denied: return "Denied in System Settings"
        case .restricted: return "Restricted"
        case .unavailable: return "Unavailable"
        }
    }
}
