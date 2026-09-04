import SwiftUI
import PerchKit

/// Swaps between the collapsed clusters and the expanded panel on hover.
///
/// The hosting window is always the full expanded size, but only the drawn
/// content may be hoverable. An earlier version put `.contentShape(.rect)` on
/// the full-size frame, which made the entire 460×460 window a hover target —
/// moving the pointer anywhere near the middle of the screen opened the panel.
/// The hit region is now confined to the actual content.
struct PerchRootView: View {
    let store: SessionStore
    let settings: Settings
    let notchSize: CGSize

    @State private var isExpanded = false
    @State private var selectedID: AgentSession.ID?
    @State private var tab: PanelTab = .tasks
    /// Debounces the collapse so a pointer crossing a gap does not flicker.
    @State private var collapseTask: Task<Void, Never>?

    /// Extra height below the notch strip, so the pointer does not have to sit
    /// exactly on the cutout to open the panel.
    private let hoverPadding: CGFloat = 6
    /// Once open, the panel keeps a margin of hover around itself. Moving the
    /// pointer from the notch down into the panel otherwise crosses a dead gap
    /// and the panel closes under the cursor.
    private let expandedSlop: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                ExpandedView(
                    store: store,
                    settings: settings,
                    notchWidth: notchSize.width,
                    notchHeight: notchSize.height,
                    selectedID: $selectedID,
                    tab: $tab
                )
                // The panel plus a small margin stays hoverable, so travelling
                // from the notch into the panel never crosses a dead gap.
                .padding(expandedSlop)
                .contentShape(.rect)
                .onHover(perform: handleHover)
                .padding(-expandedSlop)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                // The trigger is confined to the notch strip plus the clusters
                // beside it, rather than the full window width — hovering
                // anywhere near mid-screen must not open the panel.
                CollapsedView(
                    store: store,
                    notchWidth: notchSize.width,
                    notchHeight: notchSize.height
                )
                .frame(width: triggerWidth, height: notchSize.height + hoverPadding)
                .contentShape(.rect)
                .onHover(perform: handleHover)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.26, extraBounce: 0.08), value: isExpanded)
    }

    /// The collapsed hit target: the cutout plus a fixed gutter either side.
    /// Deliberately independent of the window width.
    private var triggerWidth: CGFloat {
        notchSize.width + 2 * CollapsedMetrics.clusterWidth
    }

    private func handleHover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            isExpanded = true
        } else {
            collapseTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                isExpanded = false
                selectedID = nil
            }
        }
    }
}

enum PanelMetrics {
    /// Expanded panel width. Wide enough for the four-tab strip and the stats
    /// grid without the window itself becoming a large hover target — the
    /// trigger is sized independently.
    static let width: CGFloat = 460
}

enum CollapsedMetrics {
    /// Width reserved either side of the cutout for a status cluster. Sets both
    /// the collapsed layout and the hover trigger, so they cannot drift apart.
    static let clusterWidth: CGFloat = 76

    /// Rightward nudge applied to the collapsed strip. Geometric centring is
    /// exact, but the left cluster is visually heavier, so the strip reads as
    /// shifted left without this.
    static let opticalOffset: CGFloat = 6
}
