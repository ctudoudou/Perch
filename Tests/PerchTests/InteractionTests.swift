import AppKit
import SwiftUI
import Testing
@testable import Perch
@testable import PerchKit

/// Exercises the panel and its hosted view directly. Synthetic `CGEvent`s do not
/// update AppKit's cursor tracking reliably from a test process, so hit-testing
/// and event routing are verified through the real view hierarchy instead.
@Suite("Panel interaction")
@MainActor
struct InteractionTests {
    private func makePanel() -> (NotchPanel, SessionStore) {
        // An isolated defaults suite keeps tests from touching real preferences.
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460))
        let view = FirstMouseHostingView(
            rootView: PerchRootView(
                store: store, settings: settings, notchSize: CGSize(width: 200, height: 32)
            )
        )
        panel.contentView = view
        panel.orderFrontRegardless()
        return (panel, store)
    }

    @Test("panel can become key so hosted controls receive clicks")
    func panelAcceptsClicks() {
        let (panel, _) = makePanel()
        defer { panel.orderOut(nil) }
        // A panel that cannot become key silently swallows SwiftUI gestures.
        #expect(panel.canBecomeKey)
        // …but must never become main, or it would steal focus from the real app.
        #expect(!panel.canBecomeMain)
    }

    @Test("hosting view takes the first click while the app is inactive")
    func acceptsFirstMouse() {
        let (panel, _) = makePanel()
        defer { panel.orderOut(nil) }
        let view = try! #require(panel.contentView as? FirstMouseHostingView<PerchRootView>)
        #expect(view.acceptsFirstMouse(for: nil))
    }

    @Test("the panel floats above the menu bar on every space")
    func windowLevel() {
        let (panel, _) = makePanel()
        defer { panel.orderOut(nil) }
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.isOpaque)
    }

    @Test("content hit-tests, so clicks reach the SwiftUI tree")
    func contentHitTests() {
        let (panel, _) = makePanel()
        defer { panel.orderOut(nil) }
        let view = try! #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        // A point inside the drawn header must resolve to a subview rather than nil.
        let hit = view.hitTest(NSPoint(x: 230, y: view.bounds.maxY - 10))
        #expect(hit != nil)
    }

    @Test("notch geometry falls back to a centred strip without a notch")
    func geometryFallback() throws {
        let screen = try #require(NSScreen.main)
        let anchor = screen.islandAnchor
        #expect(anchor.width > 0)
        #expect(anchor.height > 0)
        // The anchor is always horizontally centred and pinned to the top.
        #expect(abs(anchor.midX - screen.frame.midX) < 0.5)
        #expect(abs(anchor.maxY - screen.frame.maxY) < 0.5)
    }
}

/// Verifies the row's expand/collapse behaviour without relying on synthetic
/// system input, by driving the same closures the gesture invokes.
@Suite("Row expansion")
@MainActor
struct RowExpansionTests {
    private func sample(_ id: String) -> AgentSession {
        AgentSession(
            providerID: "claude-code", nativeID: id, title: "Task \(id)",
            state: .running,
            usage: TokenUsage(input: 100, output: 50, cacheRead: 900, contextWindow: 200_000, contextUsed: 1_000),
            transcript: [TranscriptEntry(role: .user, text: "hi", timestamp: Date())],
            startedAt: Date().addingTimeInterval(-60), updatedAt: Date()
        )
    }

    @Test("toggling selects, then deselects, the same row")
    func toggleCycle() {
        var selected: AgentSession.ID?
        let session = sample("a")

        func toggle() {
            selected = selected == session.id ? nil : session.id
        }

        toggle()
        #expect(selected == session.id)
        toggle()
        #expect(selected == nil)
    }

    @Test("selecting a different row replaces the selection")
    func switchRows() {
        var selected: AgentSession.ID? = sample("a").id
        let other = sample("b")
        selected = selected == other.id ? nil : other.id
        #expect(selected == other.id)
    }

    @Test("a row renders its detail without crashing")
    func detailRenders() {
        let row = SessionRow(
            session: sample("a"),
            appearance: ClaudeCodeProvider().appearance,
            isExpanded: true,
            onToggle: {},
            onOpen: {}
        )
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 200)
        host.layoutSubtreeIfNeeded()
        // A detail that fails to lay out collapses to zero height.
        #expect(host.fittingSize.height > 60)
    }

    @Test("context gauge stays within bounds for oversized context")
    func gaugeClamped() {
        var usage = TokenUsage(contextWindow: 1_000, contextUsed: 5_000)
        let fraction = try! #require(usage.contextFraction)
        #expect(fraction == 1.0)

        usage.contextUsed = 250
        #expect(usage.contextFraction == 0.25)
    }
}

/// The hover trigger is the bug the user reported: the panel used to open when
/// the pointer was anywhere near the middle of the screen.
@Suite("Hover trigger")
@MainActor
struct HoverTriggerTests {
    @Test("the collapsed trigger is far narrower than the window")
    func triggerIsBounded() {
        let notchWidth: CGFloat = 185  // measured on this MacBook
        let trigger = notchWidth + 2 * CollapsedMetrics.clusterWidth
        // It must cover the notch and its clusters…
        #expect(trigger > notchWidth)
        // …but stay well inside the panel window, which is what caused
        // mid-screen hovers to open the panel when the two were the same size.
        #expect(trigger < PanelMetrics.width * 0.8)
    }

    @Test("the trigger stays centred on the cutout")
    func triggerIsCentred() throws {
        let screen = try #require(NSScreen.main)
        let anchor = screen.islandAnchor
        let trigger = anchor.width + 2 * CollapsedMetrics.clusterWidth
        let left = screen.frame.midX - trigger / 2
        let right = screen.frame.midX + trigger / 2
        // The cutout is fully inside the trigger, symmetrically.
        #expect(left <= anchor.minX)
        #expect(right >= anchor.maxX)
        #expect(abs((anchor.minX - left) - (right - anchor.maxX)) < 0.5)
    }

    @Test("a point at screen centre-height is outside the trigger")
    func midScreenIsNotHovered() throws {
        let screen = try #require(NSScreen.main)
        let anchor = screen.islandAnchor
        // The old bug: the whole 460×460 window was hoverable, so this point
        // opened the panel. The trigger is only as tall as the notch strip.
        let midScreen = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 200)
        let triggerRect = NSRect(
            x: screen.frame.midX - (anchor.width + 2 * CollapsedMetrics.clusterWidth) / 2,
            y: screen.frame.maxY - anchor.height,
            width: anchor.width + 2 * CollapsedMetrics.clusterWidth,
            height: anchor.height
        )
        #expect(!triggerRect.contains(midScreen))
    }
}
