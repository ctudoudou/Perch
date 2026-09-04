import AppKit
import SwiftUI

/// Owns the notch panel and keeps it on the right screen.
@MainActor
final class PerchController {
    private let store: SessionStore
    private let settings: Settings
    private var panel: NotchPanel?
    private var screenObserver: (any NSObjectProtocol)?

    /// Room below the notch for the expanded panel.
    private let expandedHeight: CGFloat = 460
    private let expandedWidth: CGFloat = PanelMetrics.width + 40

    init(store: SessionStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        install()
        // Docking, resolution changes and display sleep all reshape the screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        panel?.orderOut(nil)
        panel = nil
    }

    /// Build or reposition the panel for the current screen.
    private func install() {
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let anchor = screen.islandAnchor
        let notchSize = CGSize(width: anchor.width, height: anchor.height)

        let frame = NSRect(
            x: screen.frame.midX - expandedWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )

        let root = PerchRootView(store: store, settings: settings, notchSize: notchSize)
        let hosting = FirstMouseHostingView(rootView: root)

        if let panel {
            panel.setFrame(frame, display: true)
            panel.contentView = hosting
        } else {
            let panel = NotchPanel(contentRect: frame)
            panel.contentView = hosting
            panel.orderFrontRegardless()
            self.panel = panel
        }
    }
}
