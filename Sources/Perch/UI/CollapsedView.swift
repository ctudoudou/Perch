import SwiftUI
import PerchKit

/// What sits on the notch when nothing is expanded: two small clusters hugging
/// the physical cutout, so the notch itself stays visually empty.
///
/// The two clusters have different widths, so they cannot be laid out as one
/// centred `HStack` — that centres the *combined* assembly and lets the wider
/// side push the notch spacer off the real cutout. Instead each cluster is
/// positioned independently against the window's centre line, which is where
/// the physical notch actually is.
struct CollapsedView: View {
    let store: SessionStore
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Gap between the cutout edge and the nearest glyph.
    private let gutter: CGFloat = 9

    var body: some View {
        // Each cluster gets an identical fixed width and is aligned toward the
        // cutout. Using `maxWidth: .infinity` instead makes each side as wide as
        // the *window* allows, so the two sides end up different widths and the
        // whole assembly reads as shifted — which is what it did.
        HStack(spacing: 0) {
            leadingCluster
                .frame(width: CollapsedMetrics.clusterWidth - gutter, alignment: .trailing)
                .padding(.trailing, gutter)

            // The physical cutout. Nothing may be drawn here.
            Color.clear.frame(width: notchWidth)

            trailingCluster
                .frame(width: CollapsedMetrics.clusterWidth - gutter, alignment: .leading)
                .padding(.leading, gutter)
        }
        .frame(height: notchHeight)
        // The left cluster carries more ink (a dot *and* a numeral) than the
        // right, so geometric centring still reads as left-leaning. Nudge the
        // whole strip right to correct the perceived centre.
        .offset(x: CollapsedMetrics.opticalOffset)
    }

    @ViewBuilder
    private var leadingCluster: some View {
        if let state = store.summaryState {
            HStack(spacing: 5) {
                StateIndicator(state: state)
                if store.activeCount > 0 {
                    Text("\(store.activeCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    @ViewBuilder
    private var trailingCluster: some View {
        // One badge per tool with sessions, capped so a busy machine cannot
        // push the cluster past the screen edge.
        let badges = providerBadges.prefix(3)
        if !badges.isEmpty {
            HStack(spacing: 5) {
                ForEach(badges, id: \.providerID) { badge in
                    ProviderBadge(badge: badge)
                }
            }
            .transition(.opacity)
        }
    }

    /// Per-tool summary for the collapsed badges.
    private var providerBadges: [ProviderBadgeModel] {
        var order: [String] = []
        var grouped: [String: [AgentSession]] = [:]
        for session in store.visibleSessions {
            if grouped[session.providerID] == nil { order.append(session.providerID) }
            grouped[session.providerID, default: []].append(session)
        }
        return order.compactMap { providerID in
            guard let group = grouped[providerID] else { return nil }
            return ProviderBadgeModel(
                providerID: providerID,
                appearance: store.provider(forID: providerID)?.appearance,
                count: group.count,
                isActive: group.contains { $0.state.isActive },
                needsAttention: group.contains { $0.state.needsAttention }
            )
        }
        // Busiest first, so the capped list keeps what matters.
        .sorted { ($0.isActive ? 1 : 0, $0.count) > ($1.isActive ? 1 : 0, $1.count) }
    }
}

struct ProviderBadgeModel {
    var providerID: String
    var appearance: ProviderAppearance?
    var count: Int
    var isActive: Bool
    var needsAttention: Bool
}

/// A tool's glyph with its session count, tinted by whether it is working.
///
/// The bare glyph gave no sense of how much each tool was doing; the count and
/// the active tint make the cluster readable at a glance.
struct ProviderBadge: View {
    let badge: ProviderBadgeModel

    private var tint: Color {
        badge.appearance?.color ?? .secondary
    }

    var body: some View {
        HStack(spacing: 2.5) {
            Image(systemName: badge.appearance?.symbolName ?? "sparkles")
                .font(.system(size: 9, weight: .semibold))
            if badge.count > 1 {
                Text("\(badge.count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(badge.isActive ? tint : tint.opacity(0.55))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(tint.opacity(badge.isActive ? 0.18 : 0.09))
        )
        .overlay(alignment: .topTrailing) {
            // A tool waiting on the user gets a dot, so attention is visible
            // without expanding the panel.
            if badge.needsAttention {
                Circle()
                    .fill(.yellow)
                    .frame(width: 3.5, height: 3.5)
                    .offset(x: 1.5, y: -1)
            }
        }
        .help("\(badge.count) session(s)")
    }
}

/// The pulsing status glyph. Only the running state animates — a static badge
/// in the corner of the eye is far less distracting when nothing is happening.
struct StateIndicator: View {
    let state: SessionState
    @State private var pulsing = false

    var body: some View {
        Group {
            if state == .running {
                Circle()
                    .fill(state.tint)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.35 : 1)
                    .animation(
                        .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .onAppear { pulsing = true }
            } else {
                Image(systemName: state.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(state.tint)
            }
        }
        .accessibilityLabel(state.label)
    }
}

extension SessionStore {
    func provider(forID id: String) -> (any AgentProvider)? {
        visibleSessions.first { $0.providerID == id }.flatMap { provider(for: $0) }
    }

    func hasActiveSession(providerID: String) -> Bool {
        visibleSessions.contains { $0.providerID == providerID && $0.state.isActive }
    }
}
