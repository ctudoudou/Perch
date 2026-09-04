import AppKit
import PerchKit

/// Brings the user to the app that owns a session when they click it.
enum SessionActivator {
    @MainActor
    static func activate(_ session: AgentSession) {
        guard let target = session.target else {
            revealWorkingDirectory(session)
            return
        }

        switch target {
        case let .processIdentifier(pid):
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
            } else {
                revealWorkingDirectory(session)
            }

        case let .bundleIdentifier(bundleID):
            // Prefer an already-running instance so we activate rather than relaunch.
            if let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first {
                running.activate(options: [.activateAllWindows])
            } else if let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                revealWorkingDirectory(session)
            }

        case let .url(url):
            NSWorkspace.shared.open(url)

        case let .revealFile(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Last resort: show the user where the work is happening.
    @MainActor
    private static func revealWorkingDirectory(_ session: AgentSession) {
        guard let directory = session.workingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
