import SwiftUI
import PerchKit

/// The hover panel: every session with its state, token breakdown and the last
/// few conversation turns.
struct ExpandedView: View {
    let store: SessionStore
    let settings: Settings
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @Binding var selectedID: AgentSession.ID?
    @Binding var tab: PanelTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabStrip
            Divider().opacity(0.15)

            switch tab {
            case .tasks: taskList
            case .usage: UsageView(store: store).frame(maxHeight: 360)
            case .stats:
                ScrollView { StatsView(store: store) }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 380)
            case .settings:
                SettingsView(store: store, settings: settings).frame(maxHeight: 360)
            }

            if !store.providerErrors.isEmpty {
                errorFooter
            }
        }
        .frame(width: PanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelBackground())
        .animation(.snappy(duration: 0.2), value: tab)
    }

    /// Switches between the panel's views. Settings sits apart on the right so
    /// it does not compete with the three everyday views.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.primary) { candidate in
                tabButton(candidate)
            }
            Spacer()
            tabButton(.settings, showsTitle: false)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 5)
    }

    private func tabButton(_ candidate: PanelTab, showsTitle: Bool = true) -> some View {
        let isSelected = tab == candidate
        return Button {
            tab = candidate
        } label: {
            HStack(spacing: 4) {
                Image(systemName: candidate.symbol)
                    .font(.system(size: 9, weight: .semibold))
                if showsTitle {
                    Text(candidate.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? Palette.primary : Palette.label)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(isSelected ? 0.12 : 0))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var taskList: some View {
            if store.visibleSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.visibleSessions) { session in
                            SessionRow(
                                session: session,
                                appearance: store.provider(for: session)?.appearance,
                                isExpanded: selectedID == session.id,
                                isFlashing: store.notifier.flashing.contains(session.id),
                                onToggle: {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedID = selectedID == session.id ? nil : session.id
                                    }
                                },
                                onOpen: { SessionActivator.activate(session) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
    }

    /// The header straddles the physical cutout: the notch is centred in the
    /// panel, so content is split into a left and a right gutter with the
    /// cutout's full width reserved between them. Anything drawn in the middle
    /// would be invisible.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                if store.activeCount > 0 {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("\(store.activeCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.cyan)
                }
            }
            .frame(maxWidth: .infinity)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 5) {
                Text(totalTokens)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                Text("tok")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.label)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        // Match the menubar strip exactly. Reserving more than the cutout's own
        // height pushes every row down for no reason.
        .frame(height: notchHeight)
        .padding(.horizontal, 10)
    }

    private var totalTokens: String {
        Format.tokens(store.visibleSessions.reduce(0) { $0 + $1.usage.total })
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(Palette.label)
            Text("No active sessions")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var errorFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.providerErrors.sorted(by: { $0.key < $1.key }), id: \.key) { id, message in
                Label("\(id): \(message)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }
}

/// Rounded dark backdrop that visually continues the notch downward.
///
/// The fill is fully opaque: the panel sits over arbitrary app content, and any
/// translucency lets that content bleed through and makes the rows unreadable.
struct PanelBackground: View {
    /// How far the shadow may spread sideways and below.
    private let spread: CGFloat = 26

    var body: some View {
        shape
            .fill(Color(white: 0.055))
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            // The shadow is clipped to start exactly at the panel's top edge.
            //
            // The panel hangs off the notch, so anything drawn above it lands on
            // the menu bar. A blur spreads in every direction and reaches
            // further than its nominal radius, so offsetting it downward was not
            // enough — a grey band still smeared across the menu bar either side
            // of the cutout. Clipping removes it geometrically while leaving the
            // sides and bottom free to cast normally.
            .compositingGroup()
            .clipShape(DownwardShadowClip(spread: spread))
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0
        )
    }
}

/// A clip that keeps the top edge exact while allowing the shadow room to
/// spread to the sides and below.
private struct DownwardShadowClip: Shape {
    let spread: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            CGRect(
                x: rect.minX - spread,
                y: rect.minY,
                width: rect.width + spread * 2,
                height: rect.height + spread
            )
        )
    }
}

