import Foundation
import PerchKit

/// Holds the last live quota reading so an expensive query does not run on
/// every poll, and a transient failure does not blank the display.
actor LiveQuotaCache {
    private var windows: [RateLimitWindow] = []
    private var lastRead: Date?
    private var inFlight = false

    private let interval: TimeInterval
    private let fetch: @Sendable () async -> [RateLimitWindow]?

    init(interval: TimeInterval, fetch: @escaping @Sendable () async -> [RateLimitWindow]?) {
        self.interval = interval
        self.fetch = fetch
    }

    /// The freshest windows available, refreshing in the background when due.
    ///
    /// Never waits on the network path: the caller gets the cached value
    /// immediately and the refreshed one on a later poll, so a slow query can
    /// never stall a UI refresh.
    func current() -> [RateLimitWindow] {
        if shouldRefresh { Task { await refresh() } }
        return windows
    }

    private var shouldRefresh: Bool {
        guard !inFlight else { return false }
        guard let lastRead else { return true }
        return Date().timeIntervalSince(lastRead) >= interval
    }

    private func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        if let fetched = await fetch() {
            windows = fetched
            lastRead = Date()
        } else {
            // Back off after a failure so a missing tool is not retried in a
            // tight loop; keep showing the last good reading meanwhile.
            lastRead = Date()
        }
    }

    /// Force a read and wait for it. Used by tests and the first refresh.
    func warm() async {
        await refresh()
    }
}
