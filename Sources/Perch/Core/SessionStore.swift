import Foundation
import Observation
import PerchKit

/// Polls every provider and publishes a merged, sorted session list.
///
/// Polling adapts to what is happening: fast while something is running, slow
/// when everything is idle, so the app is invisible in Activity Monitor when
/// there is nothing to watch.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    /// Providers that threw on the last cycle, with the reason. Surfaced in the panel.
    private(set) var providerErrors: [String: String] = [:]
    /// Account-level quota per provider, refreshed alongside sessions.
    private(set) var accountQuota: [String: [RateLimitWindow]] = [:]

    /// Long-range history for the Stats tab.
    ///
    /// Kept apart from `sessions`, which is bounded to a few hours for the task
    /// list. Statistics were previously built from that same list, so "All
    /// time" only ever meant "the last eight hours" — on this machine that hid
    /// 88 days of Codex history behind a single day.
    private(set) var history: [SessionSummary] = []

    /// How far back statistics reach.
    static let historyWindow: TimeInterval = 365 * 24 * 3600
    /// History changes slowly and costs real disk reads, so it is refreshed on
    /// its own schedule rather than on every two-second poll.
    static let historyInterval: TimeInterval = 5 * 60

    private var lastHistoryRefresh: Date?
    private var historyTask: Task<Void, Never>?
    private(set) var lastRefresh: Date?

    /// What the task list and wall show: real user-started sessions.
    ///
    /// Subagents are excluded here — one request can spawn a dozen — but they
    /// stay in `sessions`, so every usage total still counts their spend.
    var visibleSessions: [AgentSession] {
        settings.showSubagents ? sessions : sessions.filter { !$0.isSubagent }
    }

    /// Everything parsed, subagents included. This is the basis for all usage
    /// and statistics: hiding a row must never hide its cost.
    var allSessions: [AgentSession] { sessions }

    var activeCount: Int { visibleSessions.count(where: { $0.state.isActive }) }
    var attentionCount: Int { visibleSessions.count(where: { $0.state.needsAttention }) }

    /// What the collapsed notch should convey at a glance.
    var summaryState: SessionState? {
        if visibleSessions.contains(where: { $0.state == .failed }) { return .failed }
        if activeCount > 0 { return .running }
        if attentionCount > 0 { return .awaitingInput }
        return visibleSessions.isEmpty ? nil : .completed
    }

    /// Every provider found on this machine, including ones the user disabled —
    /// the Settings tab needs to list those in order to re-enable them.
    private(set) var knownProviders: [ProviderInfo] = []

    private var providers: [any AgentProvider] = []
    private var pollTask: Task<Void, Never>?

    private let activeInterval: Duration = .seconds(2)
    private let idleInterval: Duration = .seconds(10)

    private let settings: Settings
    let notifier: CompletionNotifier

    init(settings: Settings) {
        self.settings = settings
        notifier = CompletionNotifier(settings: settings)
        reloadProviders()
    }

    /// Rebuild the provider list, picking up newly installed plugins and any
    /// change to which providers the user wants watched.
    func reloadProviders() {
        let hours = settings.visibilityHours * 3600
        let builtIns: [any AgentProvider] = [
            ClaudeCodeProvider(visibilityWindow: hours),
            CodexProvider(visibilityWindow: hours),
        ]
        let external: [any AgentProvider] = PluginLoader.discover()
        let available = (builtIns + external).filter { $0.isAvailable() }

        knownProviders = available.map {
            ProviderInfo(id: $0.id, displayName: $0.displayName, appearance: $0.appearance)
        }
        // Disabled providers are not polled at all, so switching one off also
        // stops the disk reads it would have done.
        providers = available.filter { settings.isEnabled($0.id) }
    }

    /// Test seam: run against a fixed provider list instead of discovery.
    func useProvidersForTesting(_ list: [any AgentProvider]) {
        providers = list
        knownProviders = list.map {
            ProviderInfo(id: $0.id, displayName: $0.displayName, appearance: $0.appearance)
        }
    }

    func provider(for session: AgentSession) -> (any AgentProvider)? {
        providers.first { $0.id == session.providerID }
    }

    func start() {
        // Pushed events arrive through the filesystem, so watching the report
        // directories turns a hook firing into an immediate refresh rather than
        // something the next poll happens to notice.
        ReportStore.shared.startWatching(
            tools: [ClaudeCodeReporter.tool, CodexReporter.tool]
        ) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }

        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.activeCount > 0 ? self.activeInterval : self.idleInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        ReportStore.shared.stopWatching()
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let snapshot = providers

        // Providers are independent; one hanging on disk must not stall the others.
        let results = await withTaskGroup(
            of: (String, Result<[AgentSession], Error>).self
        ) { group in
            for provider in snapshot {
                group.addTask {
                    do {
                        return (provider.id, .success(try await provider.fetchSessions()))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            var collected: [(String, Result<[AgentSession], Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var merged: [AgentSession] = []
        var errors: [String: String] = [:]
        for (providerID, result) in results {
            switch result {
            case let .success(list): merged.append(contentsOf: list)
            case let .failure(error): errors[providerID] = error.localizedDescription
            }
        }

        for tool in [ClaudeCodeReporter.tool, CodexReporter.tool] {
            let live = Set(merged.filter { $0.providerID == tool }.map(\.nativeID))
            ReportStore.shared.prune(tool: tool, keeping: live)
        }

        // Quota is asked for separately from sessions, so a tool with nothing
        // running still reports its allowance.
        var quota: [String: [RateLimitWindow]] = [:]
        await withTaskGroup(of: (String, [RateLimitWindow]).self) { group in
            for provider in snapshot {
                group.addTask { (provider.id, await provider.accountQuota()) }
            }
            for await (id, windows) in group where !windows.isEmpty {
                quota[id] = windows
            }
        }
        accountQuota = quota
        refreshHistoryIfDue()

        let sorted = merged.sorted(by: Self.displayOrder)
        notifier.process(sorted.filter { !$0.isSubagent })
        sessions = sorted
        providerErrors = errors
        lastRefresh = Date()
    }

    /// Kick off a history scan when one is due, without making the caller wait.
    private func refreshHistoryIfDue() {
        guard historyTask == nil else { return }
        if let last = lastHistoryRefresh,
           Date().timeIntervalSince(last) < Self.historyInterval { return }

        let snapshot = providers
        let since = Date().addingTimeInterval(-Self.historyWindow)
        historyTask = Task { [weak self] in
            var gathered: [SessionSummary] = []
            for provider in snapshot {
                guard let summaries = try? await provider.fetchHistory(since: since) else { continue }
                gathered.append(contentsOf: summaries)
            }
            await MainActor.run {
                guard let self else { return }
                self.history = gathered.sorted { $0.updatedAt < $1.updatedAt }
                self.lastHistoryRefresh = Date()
                self.historyTask = nil
            }
        }
    }

    /// Force a history scan and wait for it. For tests and first paint.
    func warmHistory() async {
        lastHistoryRefresh = nil
        refreshHistoryIfDue()
        await historyTask?.value
    }

    /// Per-provider rollups for the Usage tab.
    ///
    /// Every watched provider gets a card, even with no sessions in the visible
    /// window: the tool is installed and its allowance is still real, so hiding
    /// it just because nothing ran in the last few hours loses information the
    /// user came to the tab for.
    var providerUsage: [ProviderUsage] {
        let grouped = Dictionary(grouping: allSessions, by: \.providerID)
        return knownProviders.compactMap { info in
            let group = grouped[info.id] ?? []
            var total = TokenUsage()
            for session in group { total += session.usage }
            // An account can have several independent quota buckets and each
            // session only ever reports the one its own model draws from, so
            // taking the newest session's limits hid every other bucket.
            // Quota is account-wide, so merge across *all* of the provider's
            // sessions — subagents included, since a general-bucket session may
            // well be a subagent and would otherwise never be seen.
            // Quota comes from the provider itself, not from a session.
            let limits = accountQuota[info.id] ?? []
            // A provider with neither usage nor quota has nothing to say.
            guard !group.isEmpty || !limits.isEmpty else { return nil }

            return ProviderUsage(
                providerID: info.id,
                displayName: info.displayName,
                // Count only sessions the user started; subagent spend is
                // folded into the totals but is not a session they opened.
                sessionCount: group.count(where: { !$0.isSubagent }),
                activeCount: group.count(where: { $0.state.isActive }),
                usage: total,
                limits: limits,
                visibilityHours: settings.visibilityHours
            )
        }
        .sorted { $0.usage.total > $1.usage.total }
    }

    /// Freshest report of each distinct quota window across a provider's
    /// sessions, keyed by bucket and window so different buckets coexist.
    /// Pure, so providers can use it off the main actor.
    nonisolated static func mergeLimits(_ sessions: [AgentSession]) -> [RateLimitWindow] {
        var newest: [String: (window: RateLimitWindow, seen: Date)] = [:]
        for session in sessions {
            for window in session.rateLimits {
                let key = "\(window.bucket ?? "")|\(window.name)"
                if let existing = newest[key], existing.seen >= session.updatedAt { continue }
                newest[key] = (window, session.updatedAt)
            }
        }
        return newest.values
            .map(\.window)
            .sorted {
                // General allowance first, then per-model buckets; shortest
                // window first within each, since that is what bites soonest.
                let (lhsBucket, rhsBucket) = ($0.bucket ?? "", $1.bucket ?? "")
                if lhsBucket != rhsBucket {
                    if lhsBucket == "General" { return true }
                    if rhsBucket == "General" { return false }
                    return lhsBucket < rhsBucket
                }
                return ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0)
            }
    }

    /// Grand total across every watched provider.
    var totalUsage: TokenUsage {
        var total = TokenUsage()
        for session in allSessions { total += session.usage }
        return total
    }

    /// Attention first, then live work, then newest — the order a glance wants.
    /// Pure comparator: deliberately not actor-isolated so it can be used from
    /// sorting contexts and tested directly.
    nonisolated static func displayOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        func rank(_ state: SessionState) -> Int {
            switch state {
            case .failed: 0
            case .awaitingApproval: 1
            case .awaitingInput: 2
            case .running: 3
            case .completed: 4
            }
        }
        let (l, r) = (rank(lhs.state), rank(rhs.state))
        if l != r { return l < r }
        return lhs.updatedAt > rhs.updatedAt
    }
}

/// Identity of a discovered provider, kept separate from the provider itself so
/// the Settings tab can list disabled ones without holding a live instance.
struct ProviderInfo: Identifiable, Sendable {
    var id: String
    var displayName: String
    var appearance: ProviderAppearance
}
