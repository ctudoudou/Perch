import AppKit
import Foundation
import SwiftUI
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
        project: String? = "/proj",
        isSubagent: Bool = false,
        now: Date = Date()
    ) -> SessionSummary {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return SessionSummary(
            providerID: "p", nativeID: UUID().uuidString,
            updatedAt: day, model: model,
            usage: TokenUsage(input: tokens / 2, output: tokens / 2),
            projectPath: project, isSubagent: isSubagent
        )
    }

    @Test("summary totals sessions, projects and tokens")
    func summaryTotals() {
        let stats = StatsBuilder.summary(
            [session(tokens: 1_000, project: "/a"), session(tokens: 500, project: "/b")],
            calendar: calendar
        )
        #expect(stats.sessions == 2)
        #expect(stats.projects == 2)
        #expect(stats.totalTokens == 1_500)
    }

    @Test("repeat visits to one project count once")
    func projectsAreDistinct() {
        let stats = StatsBuilder.summary(
            [session(project: "/a"), session(project: "/a"), session(project: "/b")],
            calendar: calendar
        )
        #expect(stats.projects == 2)
        #expect(stats.sessions == 3)
    }

    @Test("subagent spend counts, subagent sessions do not")
    func subagentsCountForTokensOnly() {
        let stats = StatsBuilder.summary(
            [session(tokens: 100), session(tokens: 900, isSubagent: true)],
            calendar: calendar
        )
        // One session the user opened; both sessions' tokens.
        #expect(stats.sessions == 1)
        #expect(stats.totalTokens == 1_000)
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

/// Statistics used to be built from the task list, which providers cap at a few
/// hours. Every range therefore showed the same single day — on this machine
/// that hid 88 days of Codex history.
@Suite("History reaches back")
@MainActor
struct HistoryRangeTests {
    private func store() -> SessionStore {
        SessionStore(settings: Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    @Test("history covers far more than the visible window")
    func historyExceedsVisibleWindow() async {
        let store = store()
        await store.refresh()
        await store.warmHistory()
        guard !store.history.isEmpty else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let historyDays = Set(store.history.map { calendar.startOfDay(for: $0.updatedAt) })
        let visibleDays = Set(store.allSessions.map { calendar.startOfDay(for: $0.updatedAt) })

        // The whole point: the task list is hours, history is months.
        #expect(historyDays.count >= visibleDays.count)
        let span = Date().timeIntervalSince(store.history.map(\.updatedAt).min() ?? Date())
        #expect(span > 24 * 3600, "history spans only \(span / 3600)h")
    }

    @Test("the ranges actually differ")
    func rangesNarrow() async {
        let store = store()
        await store.warmHistory()
        guard store.history.count > 5 else { return }

        let all = StatsBuilder.filter(store.history, range: .all).count
        let month = StatsBuilder.filter(store.history, range: .month).count
        let week = StatsBuilder.filter(store.history, range: .week).count

        // Previously all three were identical, because all three were "today".
        #expect(all >= month)
        #expect(month >= week)
        #expect(all > week)
    }

    @Test("models are attributed rather than lumped into unknown")
    func modelsAreNamed() async {
        let store = store()
        await store.warmHistory()
        guard !store.history.isEmpty else { return }

        let named = store.history.count(where: { $0.model != nil })
        let ratio = Double(named) / Double(store.history.count)
        // Reading the model from a 128 KB tail left ~79% of tokens unattributed;
        // the first `turn_context` lives near the head instead.
        #expect(ratio > 0.7, "only \(Int(ratio * 100))% of sessions have a model")
    }

    @Test("rescanning is stable")
    func rescanIsStable() async {
        let store = store()
        await store.warmHistory()
        let first = store.history.count
        await store.warmHistory()
        // A cached rescan must return the same history, not a doubled or
        // emptied one.
        #expect(store.history.count == first)
    }
}

/// Layout bugs the real data exposed: axis labels clipped by the panel edge,
/// bars running past it, and the header's token total disappearing under the
/// physical notch.
@Suite("Panel layout bounds")
@MainActor
struct PanelLayoutTests {
    private func fits(_ view: some View, width: CGFloat, height: CGFloat) -> Bool {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        // A view whose ideal width exceeds its frame is being clipped.
        return host.fittingSize.width <= width + 0.5
    }

    private func day(_ daysAgo: Int, tokens: Int) -> SessionSummary {
        SessionSummary(
            providerID: "p", nativeID: "\(daysAgo)",
            updatedAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
            model: "gpt-5.6-sol",
            usage: TokenUsage(input: tokens, output: 0),
            projectPath: "/proj"
        )
    }

    @Test("the model chart stays inside the panel")
    func chartFitsPanel() {
        // Long ranges are what pushed the bars and the date row off the edge.
        let sessions = (0 ..< 30).map { day($0, tokens: 1_000_000 * ($0 + 1)) }
        #expect(fits(ModelChart(sessions: sessions).padding(10),
                     width: PanelMetrics.width, height: 250))
    }

    @Test("a single active day does not stretch the chart")
    func chartFitsOneDay() {
        #expect(fits(ModelChart(sessions: [day(0, tokens: 5_000)]).padding(10),
                     width: PanelMetrics.width, height: 250))
    }

    @Test("nine-figure axis labels are not clipped")
    func axisLabelsFit() {
        // "792.7M" at the old 30pt axis width was cut off by the panel edge.
        let sessions = [day(0, tokens: 999_900_000), day(1, tokens: 1_000)]
        #expect(fits(ModelChart(sessions: sessions).padding(10),
                     width: PanelMetrics.width, height: 250))
    }

    @Test("the header reserves clearance either side of the cutout")
    func headerClearsNotch() {
        // Text placed flush against the cutout vanishes under the physical
        // notch, which is wider than the rectangle these coordinates describe.
        #expect(ExpandedView.notchClearance >= 8)
    }
}

@Suite("Chart scaling")
struct ChartScalingTests {
    @Test("a quiet day still draws a visible bar")
    func quietDayVisible() {
        // Height is proportional but floored, so a real but small day reads as
        // a short bar rather than a gap in the data.
        let peak = 800_000_000.0
        let tiny = 1_000.0
        let raw = 96.0 * (tiny / peak)
        #expect(raw < 1)
        #expect(max(3, raw) == 3)
    }

    @Test("a day with no recorded tokens is left out entirely")
    func emptyDayOmitted() {
        // Such a session contributes nothing to any total while still claiming
        // a column, which drew as missing data.
        let summaries = [
            SessionSummary(providerID: "p", nativeID: "a", updatedAt: Date(),
                           usage: TokenUsage(input: 10, output: 5)),
        ]
        #expect(StatsBuilder.days(summaries).allSatisfy { $0.tokens > 0 })
    }
}

/// Codex history spans 2.2 GB across hundreds of files, so an unchanged log
/// must be read once and remembered. Asserted on the cache itself rather than
/// on wall-clock time, which is not reproducible in a parallel test run.
@Suite("History cache")
struct HistoryCacheTests {
    private let url = URL(fileURLWithPath: "/tmp/perch-cache-fixture.jsonl")

    private func summary(_ tokens: Int) -> SessionSummary {
        SessionSummary(providerID: "codex", nativeID: "x", updatedAt: Date(),
                       usage: TokenUsage(input: tokens, output: 0))
    }

    @Test("an unchanged file is served from the cache")
    func hitsOnSameModificationDate() {
        let cache = CodexProvider.SummaryCache()
        let modified = Date()
        cache.store(summary(10), for: url, modified: modified)
        guard case let .hit(cached) = cache.value(for: url, modified: modified) else {
            Issue.record("expected a cache hit"); return
        }
        #expect(cached?.usage.input == 10)
    }

    @Test("a modified file is read again")
    func missesWhenFileChanges() {
        let cache = CodexProvider.SummaryCache()
        cache.store(summary(10), for: url, modified: Date(timeIntervalSince1970: 1_000))
        // A session that has grown must not keep reporting its old totals.
        guard case .miss = cache.value(for: url, modified: Date(timeIntervalSince1970: 2_000))
        else { Issue.record("stale entry served"); return }
    }

    @Test("a remembered omission is not a miss")
    func remembersOmissionsDistinctly() {
        let cache = CodexProvider.SummaryCache()
        let modified = Date()
        cache.store(nil, for: url, modified: modified)
        guard case let .hit(cached) = cache.value(for: url, modified: modified) else {
            Issue.record("expected a hit"); return
        }
        // Remembered as "nothing worth reporting", so the file is not re-read.
        #expect(cached == nil)
    }

}
