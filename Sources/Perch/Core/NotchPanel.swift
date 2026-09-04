import AppKit
import SwiftUI

/// Borderless panel that floats over the menu bar and follows the active space.
///
/// It is deliberately not key-capable by default: the notch should never steal
/// focus from whatever the user is typing in.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        // Above the menu bar, so the panel can overlap it when expanded.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        animationBehavior = .none
    }

    /// The panel must be able to become key, otherwise SwiftUI buttons and tap
    /// gestures inside it never receive clicks. `.nonactivatingPanel` keeps the
    /// owning app from being activated, so focus is not stolen from the app the
    /// user is actually working in.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts a click even while the app is inactive.
///
/// Without this, the first click on the panel is swallowed as an
/// activation click and the user has to click twice.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor @preconcurrency required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}
