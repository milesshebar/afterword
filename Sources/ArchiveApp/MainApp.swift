import SwiftUI
import AppKit
import ArchiveCore

/// Command-line options the app understands (everything else is left to AppKit):
///   --archive <dir>            open this archive root instead of the saved one
///   --snapshot <outdir>        headless: render the main views to PNGs with ImageRenderer, print a report, exit
///   --query <text>             search term for the snapshot's search view (default "pizza")
enum Launch {
    static func value(after flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var archiveFlag: String? { value(after: "--archive") }
    static var snapshotDir: String? { value(after: "--snapshot") }
}

@main
enum Launcher {
    static func main() {
        if let dir = Launch.snapshotDir {
            MainActor.assumeIsolated { SnapshotRunner.start(outDir: dir) }
        } else {
            MainApp.main()
        }
    }
}

struct MainApp: App {
    let model = AppModel(root: AppModel.initialRoot(flag: Launch.archiveFlag))
    let recordings = RecordingsModel()

    var body: some Scene {
        Window(Product.name, id: "main") {
            RootView()
                .environment(model)
                .task {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    Updater.shared.start()
                    await model.load()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reloadIfArchiveChanged() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Reload Archive") { model.reload() }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(automatic: false) }
                Button("Install Update and Relaunch") { Updater.shared.installStaged(relaunch: true) }.disabled(Updater.shared.staged == nil)
            }
        }
        // Notes and Calendar: listed in the Window menu (and the main window's toolbar), each over the main window's archive.
        Window("Notes", id: "notes") {
            NotesWindow().environment(model)
        }
        .defaultSize(width: 980, height: 680)
        .keyboardShortcut("n", modifiers: [.command, .option])
        Window("Calendar", id: "calendar") {
            CalendarWindow().environment(model)
        }
        .defaultSize(width: 760, height: 720)
        .keyboardShortcut("k", modifiers: [.command, .option])
        // Voicemails, voice memos and recorded meetings by date, with search.
        Window("Recordings", id: "recordings") {
            RecordingsWindow(model: recordings).environment(model)
        }
        .defaultSize(width: 1040, height: 720)
        .keyboardShortcut("r", modifiers: [.command, .option])
        Settings {
            SettingsView().environment(model)
        }
    }
}
