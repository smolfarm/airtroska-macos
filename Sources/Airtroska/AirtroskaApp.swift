import SwiftUI
import AppKit

/// Channel between "files arrived from outside" (Finder Open With, dock drop, File ▸ Open…)
/// and ContentView, which owns the playlist. Publishing handles the launch race: if files
/// arrive before the view exists, `onReceive` still gets the current value on subscribe.
final class OpenedFiles: ObservableObject {
    static let shared = OpenedFiles()
    @Published var urls: [URL] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder "Open With", dock-icon drops, and `open -a Airtroska file.mkv`.
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenedFiles.shared.urls.append(contentsOf: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AirtroskaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Self.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }

    static func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Media.openPanelTypes
        panel.message = "Choose videos to convert and AirPlay (several files become a playlist)"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            OpenedFiles.shared.urls.append(contentsOf: panel.urls)
        }
    }
}
