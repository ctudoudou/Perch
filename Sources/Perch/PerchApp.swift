import AppKit
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The notch panel is managed directly by the delegate; the menu bar item
        // is the only conventional UI surface.
        MenuBarExtra("Perch", systemImage: "rectangle.topthird.inset.filled") {
            MenuBarContent(store: delegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var store = SessionStore(settings: settings)
    private lazy var controller = PerchController(store: store, settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, and the app never takes focus.
        NSApp.setActivationPolicy(.accessory)
        // Re-point anything the previous name left behind before anything reads it.
        Migration.run()
        store.notifier.requestAuthorizationIfNeeded()
        CompletionNotifier.registerCategories()
        store.start()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        controller.stop()
    }
}

struct MenuBarContent: View {
    let store: SessionStore

    var body: some View {
        if store.visibleSessions.isEmpty {
            Text("No active sessions")
        } else {
            ForEach(store.visibleSessions) { session in
                // Titles come from user prompts and can be arbitrarily long;
                // an unclamped menu item stretches the whole menu off-screen.
                Button("\(session.state.label) — \(session.title.condensed(to: 44))") {
                    SessionActivator.activate(session)
                }
            }
        }

        Divider()

        Button("Refresh Now") {
            Task { await store.refresh() }
        }
        Button("Reload Plugins") {
            store.reloadProviders()
            Task { await store.refresh() }
        }
        if !StatuslineStore.shared.isInstalled {
            Button("Enable Claude Code Limits…") {
                try? StatuslineStore.shared.installHelper()
                try? StatuslineStore.shared.configureClaudeCode()
                Task { await store.refresh() }
            }
        }
        Button("Open Plugins Folder") {
            let directory = PluginLoader.pluginsDirectory
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(directory)
        }

        Divider()

        Button("Quit Perch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
