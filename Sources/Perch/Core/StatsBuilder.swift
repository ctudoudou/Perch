import Foundation
import PerchKit

/// Per-model rollup for the model breakdown chart.
struct ModelStat: Identifiable, Sendable {
    var id: String { model }
    var model: String
    var input: Int
    var output: Int
    var sessions: Int

    var total: Int { input + output }

    /// Trim provider prefixes and version noise: `claude-sonnet-5` → `Sonnet 5`.
    var displayName: String {
        var name = model
        for prefix in ["claude-", "gpt-", "openai/", "anthropic/"] {
            if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        }
        name = name.replacingOccurrences(of: "[1m]", with: "")
        return name
            .split(separator: "-")
            .map { $0.count <= 2 ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }
}

/// One day's activity, for the heatmap and the daily chart.
struct DayStat: Identifiable, Sendable {
    var id: Date { day }
    var day: Date
    var tokens: Int
    var sessions: Int
    /// Tokens split by model, so a stacked bar can be drawn.
    var byModel: [String: Int]
}

/// Headline numbers shown as tiles.
struct StatsSummary: Sendable {
    var sessions = 0
    /// Distinct working directories touched in the range.
    ///
    /// Replaces a message count, which cannot be gathered honestly: Codex
    /// rollouts run to hundreds of megabytes, so counting their records means
    /// reading gigabytes, and a tile that silently covered only one of the two
    /// tools would be worse than no tile.
    var projects = 0
    var totalTokens = 0
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    /// Hour of day (0...23) with the most tokens, when there is any activity.
    var peakHour: Int?
    var favoriteModel: String?
}

/// Rolls sessions up into the numbers the Stats tab draws.
///
/// Everything is derived from the sessions already in memory, so no extra disk
/// reads happen when the user switches tabs.
enum StatsBuilder {
    /// Window the stats cover.
    enum Range: String, CaseIterable, Identifiable {
        case all = "All"
        case month = "30d"
        case week = "7d"

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .all: nil
            case .month: 30
            case .week: 7
            }
        }
    }

    static func filter(_ sessions: [SessionSummary], range: Range, now: Date = Date()) -> [SessionSummary] {
        guard let days = range.days else { return sessions }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return sessions.filter { $0.updatedAt >= cutoff }
    }

    static func summary(
        _ sessions: [SessionSummary],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> StatsSummary {
        var stats = StatsSummary()
        // Machine-spawned sessions are real spend but not something the user
        // opened, so they count for tokens and not for the session tally.
        stats.sessions = sessions.count(where: { !$0.isSubagent })
        stats.projects = Set(sessions.compactMap(\.projectPath)).count
        stats.totalTokens = sessions.reduce(0) { $0 + $1.usage.total }

        let days = Set(sessions.map { calendar.startOfDay(for: $0.updatedAt) })
        stats.activeDays = days.count
        (stats.currentStreak, stats.longestStreak) =
            streaks(days: days, calendar: calendar, now: now)

        // Weight the peak hour by tokens rather than session count, so one
        // enormous session does not read the same as one trivial one.
        var byHour: [Int: Int] = [:]
        for session in sessions {
            byHour[calendar.component(.hour, from: session.updatedAt), default: 0]
                += session.usage.total
        }
        stats.peakHour = byHour.max { $0.value < $1.value }?.key

        stats.favoriteModel = models(sessions).max { $0.total < $1.total }?.displayName
        return stats
    }

    /// Current run of consecutive active days, and the longest such run.
    static func streaks(
        days: Set<Date>,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let sorted = days.sorted()

        var longest = 1
        var run = 1
        for (previous, day) in zip(sorted, sorted.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            run = gap == 1 ? run + 1 : 1
            longest = max(longest, run)
        }

        // The current streak counts back from today, and tolerates a streak that
        // ended yesterday — the user may simply not have started yet today.
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = today
        if !days.contains(today) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) else { return (0, longest) }
            cursor = yesterday
        }
        while days.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    static func models(_ sessions: [SessionSummary]) -> [ModelStat] {
        var byModel: [String: ModelStat] = [:]
        for session in sessions {
            let key = session.model ?? "unknown"
            var stat = byModel[key] ?? ModelStat(model: key, input: 0, output: 0, sessions: 0)
            // `input` already accounts for cached tokens; adding them again
            // would inflate every model's share.
            stat.input += session.usage.input
            stat.output += session.usage.output
            stat.sessions += 1
            byModel[key] = stat
        }
        return byModel.values.sorted { $0.total > $1.total }
    }

    static func days(
        _ sessions: [SessionSummary],
        calendar: Calendar = .current
    ) -> [DayStat] {
        var byDay: [Date: DayStat] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.updatedAt)
            var stat = byDay[day] ?? DayStat(day: day, tokens: 0, sessions: 0, byModel: [:])
            stat.tokens += session.usage.total
            stat.sessions += 1
            stat.byModel[session.model ?? "unknown", default: 0] += session.usage.total
            byDay[day] = stat
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// A fixed-length grid of daily totals ending today, for the heatmap.
    static func heatmap(
        _ sessions: [SessionSummary],
        weeks: Int = 20,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [[Int]] {
        let totals = Dictionary(
            days(sessions, calendar: calendar).map { ($0.day, $0.tokens) },
            uniquingKeysWith: +
        )
        let today = calendar.startOfDay(for: now)
        // Columns are weeks, rows are weekdays, matching the familiar layout.
        var grid = Array(repeating: Array(repeating: 0, count: weeks), count: 7)
        for column in 0 ..< weeks {
            for row in 0 ..< 7 {
                let offset = (weeks - 1 - column) * 7 + (6 - row)
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                grid[row][column] = totals[day] ?? 0
            }
        }
        return grid
    }
}
