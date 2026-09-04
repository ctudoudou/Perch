import SwiftUI
import PerchKit

/// The dashboard: headline tiles and an activity heatmap, or a per-model
/// breakdown, over a selectable range.
struct StatsView: View {
    let store: SessionStore

    enum Mode: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .overview
    @State private var range: StatsBuilder.Range = .all

    private var sessions: [AgentSession] {
        StatsBuilder.filter(store.visibleSessions, range: range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            controls
            switch mode {
            case .overview: overview
            case .models: ModelChart(sessions: sessions)
            }
        }
        .padding(10)
        .animation(.snappy(duration: 0.18), value: mode)
        .animation(.snappy(duration: 0.18), value: range)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            segmented(Mode.allCases, selection: $mode) { $0.rawValue }
            Spacer()
            segmented(StatsBuilder.Range.allCases, selection: $range) { $0.rawValue }
        }
    }

    /// Small pill selector, styled for the dark panel rather than using the
    /// system control, which renders almost invisibly here.
    private func segmented<T: Hashable & Identifiable>(
        _ options: [T],
        selection: Binding<T>,
        label: @escaping (T) -> String
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection.wrappedValue == option
                Button { selection.wrappedValue = option } label: {
                    Text(label(option))
                        .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Palette.primary : Palette.label)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(isSelected ? 0.14 : 0))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.05)))
    }

    private var overview: some View {
        let summary = StatsBuilder.summary(sessions)
        return VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                spacing: 6
            ) {
                StatTile(label: "Sessions", value: "\(summary.sessions)")
                StatTile(label: "Messages", value: "\(summary.messages)")
                StatTile(label: "Total tokens", value: Format.tokens(summary.totalTokens))
                StatTile(label: "Active days", value: "\(summary.activeDays)")
                StatTile(label: "Current streak", value: "\(summary.currentStreak)d")
                StatTile(label: "Longest streak", value: "\(summary.longestStreak)d")
                StatTile(label: "Peak hour", value: summary.peakHour.map(Format.hour) ?? "—")
                StatTile(label: "Top model", value: summary.favoriteModel ?? "—")
            }
            Heatmap(grid: StatsBuilder.heatmap(sessions))
            if summary.totalTokens > 0 {
                Text(Format.comparison(summary.totalTokens))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.label)
            }
        }
    }
}

/// One headline number.
struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
    }
}

/// Daily activity as a week-by-weekday grid.
struct Heatmap: View {
    let grid: [[Int]]

    private var peak: Int {
        grid.flatMap { $0 }.max() ?? 0
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(grid.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colour(for: value))
                            .frame(height: 9)
                    }
                }
            }
        }
    }

    /// Log-scaled, so a single huge day does not wash out every other one.
    private func colour(for value: Int) -> Color {
        guard value > 0, peak > 0 else { return .white.opacity(0.06) }
        let level = log1p(Double(value)) / log1p(Double(peak))
        return Color.accentColor.opacity(0.25 + 0.75 * level)
    }
}

/// Stacked daily bars plus a per-model legend with shares.
struct ModelChart: View {
    let sessions: [AgentSession]

    private var models: [ModelStat] { StatsBuilder.models(sessions) }
    private var days: [DayStat] { Array(StatsBuilder.days(sessions).suffix(14)) }

    /// Stable colour per model, assigned by rank so the legend and bars agree.
    private var palette: [String: Color] {
        let colours: [Color] = [.blue, .indigo, .teal, .purple, .orange, .pink]
        return Dictionary(
            uniqueKeysWithValues: models.enumerated().map {
                ($0.element.model, colours[$0.offset % colours.count])
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if days.isEmpty {
                Text("No activity in this range")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.label)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                chart
                legend
            }
        }
    }

    private var peak: Int { days.map(\.tokens).max() ?? 1 }

    private var chart: some View {
        HStack(alignment: .bottom, spacing: 5) {
            // Axis labels, so the bars carry a scale rather than being decorative.
            VStack(alignment: .trailing, spacing: 0) {
                Text(Format.tokens(peak))
                Spacer()
                Text(Format.tokens(peak / 2))
                Spacer()
                Text("0")
            }
            .font(.system(size: 7.5, design: .rounded))
            .foregroundStyle(Palette.label)
            .frame(width: 30, height: 96)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days, id: \.day) { day in
                    VStack(spacing: 3) {
                        stackedBar(for: day)
                        Text(Format.shortDay(day.day))
                            .font(.system(size: 7))
                            .foregroundStyle(Palette.label)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    // Cap the width so one or two active days produce readable
                    // bars rather than a single block spanning the panel.
                    .frame(maxWidth: 56)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stackedBar(for day: DayStat) -> some View {
        let height = 96.0 * (peak > 0 ? Double(day.tokens) / Double(peak) : 0)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(models) { model in
                let share = day.tokens > 0
                    ? Double(day.byModel[model.model] ?? 0) / Double(day.tokens)
                    : 0
                if share > 0 {
                    Rectangle()
                        .fill(palette[model.model] ?? .gray)
                        .frame(height: max(1, height * share))
                }
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var legend: some View {
        VStack(spacing: 4) {
            ForEach(models.prefix(5)) { model in
                let share = models.reduce(0) { $0 + $1.total } > 0
                    ? Double(model.total) / Double(models.reduce(0) { $0 + $1.total })
                    : 0
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette[model.model] ?? .gray)
                        .frame(width: 7, height: 7)
                    Text(model.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Format.tokens(model.input)) in · \(Format.tokens(model.output)) out")
                        .font(.system(size: 8.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.label)
                        .lineLimit(1)
                    Text(String(format: "%.1f%%", share * 100))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }
}
