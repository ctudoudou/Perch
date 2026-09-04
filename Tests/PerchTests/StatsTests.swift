import Foundation
import Testing
@testable import Perch
@testable import PerchKit

@Suite("Stats aggregation")
struct StatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func session(
        model: String? = "claude-opus-5",
        tokens: Int = 1_000,
        daysAgo: Int = 0,
        messages: Int = 2,
        now: Date = Date()
    ) -> AgentSession {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return AgentSession(
            providerID: "p", nativeID: UUID().uuidString, title: "t",
            model: model, state: .completed,
            usage: TokenUsage(input: tokens / 2, output: tokens / 2),
            transcript: (0 ..< messages).map {
                .init(role: .user, text: "m\($0)", timestamp: day)
            },
            startedAt: day, updatedAt: day
        )
    }

    @Test("summary totals sessions, messages and tokens")
    func summaryTotals() {
        let stats = StatsBuilder.summary(
            [session(tokens: 1_000, messages: 3), session(tokens: 500, messages: 2)],
            calendar: calendar
        )
        #expect(stats.sessions == 2)
        #expect(stats.messages == 5)
        #expect(stats.totalTokens == 1_500)
    }

    @Test("consecutive days form a streak")
    func streakCounting() {
        let now = Date()
        let days = Set([0, 1, 2].map {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: -$0, to: now)!)
        })
        let (current, longest) = StatsBuilder.streaks(days: days, calendar: calendar, now: now)
        #expect(current == 3)
        #expect(longest == 3)
    }

    @Test("a gap breaks the current streak but not the longest")
    func brokenStreak() {
        let now = Date()
        // Active 5, 6, 7 days ago, then nothing since.
        let days = Set([5, 6, 7].map {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: -$0, to: now)!)
        })
        let (current, longest) = StatsBuilder.streaks(days: days, calendar: calendar, now: now)
        #expect(current == 0)
        #expect(longest == 3)
    }

    @Test("a streak that ended yesterday still counts as current")
    func yesterdayCounts() {
        let now = Date()
        let days = Set([1, 2].map {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: -$0, to: now)!)
        })
        // The user may simply not have started today yet.
        #expect(StatsBuilder.streaks(days: days, calendar: calendar, now: now).current == 2)
    }

    @Test("no activity yields empty streaks rather than crashing")
    func emptyStreaks() {
        let (current, longest) = StatsBuilder.streaks(days: [], calendar: calendar)
        #expect(current == 0)
        #expect(longest == 0)
    }

    @Test("models roll up and rank by spend")
    func modelRollup() {
        let models = StatsBuilder.models([
            session(model: "claude-opus-5", tokens: 100),
            session(model: "claude-sonnet-5", tokens: 900),
            session(model: "claude-opus-5", tokens: 100),
        ])
        #expect(models.count == 2)
        #expect(models[0].model == "claude-sonnet-5")
        #expect(models[0].total == 900)
        #expect(models[1].total == 200)
        #expect(models[1].sessions == 2)
    }

    @Test("model names are humanised")
    func modelNaming() {
        #expect(ModelStat(model: "claude-sonnet-5", input: 0, output: 0, sessions: 0)
            .displayName == "Sonnet 5")
        #expect(ModelStat(model: "claude-opus-5[1m]", input: 0, output: 0, sessions: 0)
            .displayName == "Opus 5")
    }

    @Test("range filtering excludes older sessions")
    func rangeFilter() {
        let now = Date()
        let all = [session(daysAgo: 1, now: now), session(daysAgo: 40, now: now)]
        #expect(StatsBuilder.filter(all, range: .all, now: now).count == 2)
        #expect(StatsBuilder.filter(all, range: .month, now: now).count == 1)
        #expect(StatsBuilder.filter(all, range: .week, now: now).count == 1)
    }

    @Test("the heatmap grid is always the full shape")
    func heatmapShape() {
        let grid = StatsBuilder.heatmap([session()], weeks: 20, calendar: calendar)
        #expect(grid.count == 7)
        #expect(grid.allSatisfy { $0.count == 20 })
        // Today's activity must land somewhere in the grid.
        #expect(grid.flatMap { $0 }.contains { $0 > 0 })
    }

    @Test("daily buckets merge sessions from the same day")
    func dailyBuckets() {
        let now = Date()
        let days = StatsBuilder.days(
            [session(tokens: 100, daysAgo: 0, now: now),
             session(tokens: 300, daysAgo: 0, now: now),
             session(tokens: 50, daysAgo: 3, now: now)],
            calendar: calendar
        )
        #expect(days.count == 2)
        #expect(days.last?.tokens == 400)
        #expect(days.last?.sessions == 2)
        // Oldest first, so a chart reads left to right.
        #expect(days[0].day < days[1].day)
    }

    @Test("peak hour is weighted by tokens, not session count")
    func peakHourWeighting() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 22))!
        let early = calendar.date(byAdding: .hour, value: -12, to: now)!

        var big = session(tokens: 100_000, now: now)
        big.updatedAt = now
        var small1 = session(tokens: 10, now: now); small1.updatedAt = early
        var small2 = session(tokens: 10, now: now); small2.updatedAt = early

        // Two small sessions at 10 AM must not outrank one huge one at 10 PM.
        let stats = StatsBuilder.summary([big, small1, small2], calendar: calendar, now: now)
        #expect(stats.peakHour == 22)
    }
}
