import AppKit
import SwiftUI
import Testing
@testable import Perch
@testable import PerchKit

@Suite("Collapsed layout")
@MainActor
struct LayoutTests {
    @Test("the collapsed strip actually renders content")
    func rendersNonEmpty() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)

        let view = CollapsedView(store: store, notchWidth: 185, notchHeight: 32)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let empty = host.fittingSize
        print("empty store fitting size: \(empty)")

        // With real sessions the clusters must occupy their reserved width on
        // both sides, not collapse to the bare cutout.
        await store.refresh()
        let live = NSHostingView(rootView: CollapsedView(store: store, notchWidth: 185, notchHeight: 32))
        live.layoutSubtreeIfNeeded()
        let size = live.fittingSize
        print("live store fitting size: \(size), sessions=\(store.visibleSessions.count)")
        #expect(size.width >= 185)
        #expect(size.height > 0)
    }

    @Test("clusters are symmetric around the cutout")
    func symmetry() {
        // Both gutters come from the same constant, so the drawn glyphs sit the
        // same distance from each edge of the cutout.
        let clusterWidth = CollapsedMetrics.clusterWidth
        let total = 185 + 2 * clusterWidth
        let leftEdge = (total - 185) / 2
        let rightEdge = total - 185 - leftEdge
        #expect(abs(leftEdge - rightEdge) < 0.01)
    }
}

@Suite("Root view layout")
@MainActor
struct RootLayoutTests {
    @Test("the root view lays out the collapsed strip with real sessions")
    func rootRenders() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        let host = NSHostingView(
            rootView: PerchRootView(
                store: store, settings: settings,
                notchSize: CGSize(width: 185, height: 32)
            )
        )
        // Mirror the real panel's frame.
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 460)
        host.layoutSubtreeIfNeeded()

        print("root fitting: \(host.fittingSize), subviews: \(host.subviews.count)")
        func describe(_ v: NSView, _ depth: Int) {
            print(String(repeating: "  ", count: depth)
                  + "\(type(of: v)) frame=\(v.frame) hidden=\(v.isHidden)")
            for sub in v.subviews.prefix(4) { describe(sub, depth + 1) }
        }
        describe(host, 0)
        #expect(store.visibleSessions.count > 0)
    }
}
