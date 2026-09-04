import AppKit

extension NSScreen {
    /// The screen the pointer is on, which is where the notch UI belongs.
    static var withMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    var hasNotch: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// Physical notch bounds, derived from the unobscured areas either side of it.
    var notchFrame: NSRect? {
        guard
            let leftWidth = auxiliaryTopLeftArea?.width,
            let rightWidth = auxiliaryTopRightArea?.width
        else { return nil }

        let height = safeAreaInsets.top
        let width = frame.width - leftWidth - rightWidth
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    var menubarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    /// Notch bounds on notched displays; a synthetic centered strip elsewhere, so
    /// the app still works on external monitors and pre-2021 MacBooks.
    var islandAnchor: NSRect {
        if let notchFrame { return notchFrame }
        let width: CGFloat = 200
        let height = max(menubarHeight, 24)
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }
}
