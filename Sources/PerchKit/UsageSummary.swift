import Foundation

/// A provider's quota window, when the tool reports one.
///
/// Codex publishes real rate limits in its logs; most other tools do not, so
/// this is optional throughout and the UI simply omits what it does not know.
public struct RateLimitWindow: Codable, Sendable, Hashable {
    /// Human label, e.g. "5h" or "Weekly".
    public var name: String
    /// Portion of the allowance consumed, 0...1.
    public var usedFraction: Double
    /// Length of the window.
    public var windowMinutes: Int?
    /// When the allowance next resets.
    public var resetsAt: Date?
    /// When this reading was taken.
    ///
    /// Some sources answer live (Codex), others only report when the tool
    /// happens to render a status line (Claude Code). A reading that cannot
    /// refresh itself must not be silently discarded — that made quota vanish
    /// minutes after the last session — nor silently presented as current. It
    /// is kept, and shown with its age.
    public var observedAt: Date?
    /// Which quota bucket this window belongs to, when a tool has more than one
    /// (Codex reports a general bucket plus per-model buckets like
    /// `GPT-5.3-Codex-Spark`). Showing the wrong bucket's numbers is worse than
    /// showing none, so the bucket travels with the window.
    public var bucket: String?

    public init(
        name: String,
        usedFraction: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        bucket: String? = nil,
        observedAt: Date? = nil
    ) {
        self.name = name
        // A window can legitimately run past its cap, so clamp only the low end
        // for display and keep values above 1 visible as "over".
        self.usedFraction = max(usedFraction, 0)
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.bucket = bucket
        self.observedAt = observedAt
    }

    /// How long ago this reading was taken, when that matters.
    public var age: TimeInterval? {
        observedAt.map { Date().timeIntervalSince($0) }
    }

    /// Readings older than this are worth captioning rather than presenting
    /// as the present.
    public static let freshEnough: TimeInterval = 5 * 60

    public var isCurrent: Bool {
        (age ?? 0) < Self.freshEnough
    }

    /// Portion still available; zero once the window is exhausted.
    public var remainingFraction: Double { max(0, 1 - usedFraction) }

    /// Time until the window resets, or nil once it has passed.
    public var timeRemaining: TimeInterval? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }
}

/// Rolled-up usage for one provider, shown on the Usage tab.
public struct ProviderUsage: Identifiable, Sendable {
    public var id: String { providerID }
    public var providerID: String
    public var displayName: String
    public var sessionCount: Int
    public var activeCount: Int
    public var usage: TokenUsage
    /// Quota windows the provider reports, shortest first.
    public var limits: [RateLimitWindow]
    /// How far back the token totals reach, so the UI can say what "no
    /// activity" is measured against.
    public var visibilityHours: Double

    public init(
        providerID: String,
        displayName: String,
        sessionCount: Int,
        activeCount: Int,
        usage: TokenUsage,
        limits: [RateLimitWindow] = [],
        visibilityHours: Double = 8
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.sessionCount = sessionCount
        self.activeCount = activeCount
        self.usage = usage
        self.limits = limits
        self.visibilityHours = visibilityHours
    }
}

public extension TokenUsage {
    /// Combine two usages, for rolling sessions up into a provider total.
    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning,
            // Context is a property of a single session, so it does not sum.
            contextWindow: nil,
            contextUsed: nil,
            // Cost does sum, but only across sessions that reported one.
            costUSD: [lhs.costUSD, rhs.costUSD].compactMap { $0 }.isEmpty
                ? nil
                : (lhs.costUSD ?? 0) + (rhs.costUSD ?? 0)
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}
