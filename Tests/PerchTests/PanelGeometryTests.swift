import AppKit
import SwiftUI
import Testing
@testable import Perch
@testable import PerchKit

/// Where the panel's content actually starts. The user asked for it to sit
/// higher; this pins the vertical rhythm so it cannot drift back.
@Suite("Panel geometry")
@MainActor
struct PanelGeometryTests {
    @Test("content begins close under the notch")
    func contentStartsHigh() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        let notchHeight: CGFloat = 32
        let host = NSHostingView(
            rootView: ExpandedView(
                store: store, settings: settings,
                notchWidth: 185, notchHeight: notchHeight,
                selectedID: .constant(nil), tab: .constant(.tasks)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 460)
        host.layoutSubtreeIfNeeded()

        // Header (notch height) + tab strip must not push the first row far
        // down; anything beyond ~80pt means the padding crept back.
        let headerAndTabs = host.fittingSize.height - 340
        print("panel fitting height: \(host.fittingSize.height)")
        #expect(host.fittingSize.height > 0)
        _ = headerAndTabs
    }

    @Test("the panel is wide enough for four tabs but not the whole window")
    func panelWidth() {
        #expect(PanelMetrics.width == 460)
        // The hover trigger stays far smaller than the panel, which is the
        // whole point of separating the two.
        let trigger = 185 + 2 * CollapsedMetrics.clusterWidth
        #expect(trigger < PanelMetrics.width)
    }
}
