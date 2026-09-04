import SwiftUI
import PerchKit

/// Aggregate token spend: a grand total, then a card per provider with its
/// quota windows and how long until they reset.
struct UsageView: View {
    let store: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                grandTotal
                ForEach(store.providerUsage) { usage in
                    ProviderUsageCard(usage: usage)
                }
                if store.providerUsage.isEmpty {
                    Text("No usage recorded yet")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.label)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(10)
        }
        .scrollIndicators(.never)
    }

    private var grandTotal: some View {
        let total = store.totalUsage
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(total.total))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primary)
                Text("tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.label)
                Spacer()
                // Cost is only known for sessions that reported a status line,
                // so a zero here means "not reported", not "free".
                if let cost = store.totalUsage.costUSD, cost > 0 {
                    Text(Format.money(cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                Text("\(store.visibleSessions.count) sessions")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Palette.secondary)
            }
            // Proportions read better than four more numbers.
            UsageBar(usage: total)
            TokenBreakdown(usage: total)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }
}

/// Stacked proportions of input / output / cache within a total.
struct UsageBar: View {
    let usage: TokenUsage

    /// Input is split into its cached and fresh parts, then output. Cache is a
    /// share *within* input — never an extra segment, which would double-count —
    /// but showing it matters: it is usually the overwhelming majority, and a
    /// bar that reads as solid "input" hides that entirely.
    private var segments: [(Color, Int)] {
        [
            (Color.teal, min(usage.cached, usage.input)),
            (Color.blue, max(0, usage.input - usage.cached)),
            (Color.purple, usage.output),
        ].filter { $0.1 > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let fraction = usage.total > 0
                        ? Double(segment.1) / Double(usage.total)
                        : 0
                    Rectangle()
                        .fill(segment.0)
                        // Never let a real but tiny segment vanish entirely.
                        .frame(width: max(1.5, proxy.size.width * fraction))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }
}

/// One provider's rollup, including quota windows when the tool reports them.
struct ProviderUsageCard: View {
    let usage: ProviderUsage

    /// Quota windows grouped by the allowance they describe, order preserved.
    private var bucketed: [(name: String, windows: [RateLimitWindow])] {
        var order: [String] = []
        var groups: [String: [RateLimitWindow]] = [:]
        for window in usage.limits {
            let key = window.bucket ?? "General"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(window)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(usage.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                if usage.activeCount > 0 {
                    Text("\(usage.activeCount) active")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                // A zero is not a reading. When nothing ran in the window the
                // card is here for the quota below, and "0" only invites the
                // question of what broke.
                if let cost = usage.usage.costUSD, cost > 0 {
                    Text(Format.money(cost))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                if usage.usage.total > 0 {
                    Text(Format.tokens(usage.usage.total))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.primary)
                }
            }

            if usage.usage.total > 0 {
                UsageBar(usage: usage.usage)
                TokenBreakdown(usage: usage.usage)
            } else {
                // The tool is installed and its allowance is real; there just
                // has not been any activity inside the visible window. Saying so
                // beats an empty bar and a row of zeroes.
                Text("No activity in the last \(Int(usage.visibilityHours))h")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.label)
            }

            if usage.limits.isEmpty {
                // Absent quota means "not reported", never "unlimited" or 0%.
                VStack(alignment: .leading, spacing: 2) {
                    Text("No quota reported")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.label)
                    if usage.providerID == "claude-code" {
                        Text(ClaudeQuotaHint.current)
                            .font(.system(size: 8.5))
                            .foregroundStyle(Palette.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // An account can hold several independent allowances, so each
                // bucket is labelled: a per-model bucket at 0% says nothing
                // about the general one.
                ForEach(Array(bucketed.enumerated()), id: \.offset) { _, group in
                    HStack(spacing: 5) {
                        if bucketed.count > 1 || group.name != "General" {
                            Text(group.name)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.label)
                        }
                        Spacer(minLength: 0)
                        // An ageing reading is still useful — usage only grows
                        // within a window, so it is a floor — but it must say
                        // so rather than look live.
                        if let stale = group.windows.first, !stale.isCurrent,
                           let age = stale.age {
                            Label("\(Format.duration(age)) ago", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 8))
                                .foregroundStyle(Palette.label)
                        }
                    }
                    .padding(.top, 1)
                    ForEach(group.windows, id: \.name) { limit in
                        QuotaRow(limit: limit)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}

/// Explains *why* Claude Code quota is missing, so an empty panel is never
/// mistaken for "no limits" or, worse, for stale numbers being current.
enum ClaudeQuotaHint {
    static var current: String {
        let store = StatuslineStore.shared
        if !store.isInstalled {
            return "Enable the status-line helper in Settings — limits arrive as API response headers and are never written to session logs."
        }
        if store.hasData { return "" }
        return "Helper installed, waiting for a Claude Code session to report. The status line runs in terminal sessions; it does not run in every host."
    }
}

/// A single quota window: how much is left and when it resets.
struct QuotaRow: View {
    let limit: RateLimitWindow

    private var tint: Color {
        switch limit.usedFraction {
        case ..<0.6: .green
        case ..<0.85: .yellow
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(limit.name)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                Text("\(Int(limit.remainingFraction * 100))% left")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Spacer()
                if let remaining = limit.timeRemaining {
                    Label(Format.duration(remaining), systemImage: "arrow.clockwise")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Palette.label)
                } else {
                    Text("resets soon")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.label)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(2, proxy.size.width * limit.usedFraction))
                }
            }
            .frame(height: 3)
        }
    }
}
