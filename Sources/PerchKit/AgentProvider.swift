import Foundation

/// Visual identity for a provider, used in the notch and the expanded panel.
public struct ProviderAppearance: Sendable {
    /// SF Symbol name shown next to the provider's sessions.
    public var symbolName: String
    /// Accent color as sRGB components in 0...1.
    public var accent: (red: Double, green: Double, blue: Double)

    public init(symbolName: String, accent: (red: Double, green: Double, blue: Double)) {
        self.symbolName = symbolName
        self.accent = accent
    }
}

/// Implemented by anything that can report AI agent sessions.
///
/// Providers are polled by the coordinator; they do not push. A provider should
/// be cheap to call repeatedly — cache aggressively and return quickly.
public protocol AgentProvider: Sendable {
    /// Stable, unique, lowercase identifier, e.g. `claude-code`.
    var id: String { get }
    /// Human-readable name shown in the UI.
    var displayName: String { get }
    var appearance: ProviderAppearance { get }

    /// Whether this provider has anything to watch on this machine. A provider
    /// that returns `false` is skipped entirely and costs nothing.
    func isAvailable() -> Bool

    /// Current sessions. Called on a background actor at the poll interval.
    /// Throwing marks the provider as errored for that cycle without affecting others.
    func fetchSessions() async throws -> [AgentSession]

    /// Sessions going back to `since`, reduced to what statistics need.
    ///
    /// Separate from `fetchSessions` because the two have opposite constraints:
    /// the task list wants full detail over a few hours, history wants months
    /// of coverage cheaply. A provider that cannot answer cheaply should return
    /// what it can rather than reading gigabytes.
    func fetchHistory(since: Date) async throws -> [SessionSummary]

    /// Quota windows for the account this tool is signed into.
    ///
    /// Deliberately separate from sessions: an allowance belongs to the account
    /// and is worth showing even when nothing has run recently. Attaching it to
    /// a session meant that once the last session aged out of view, the tool
    /// vanished from the Usage tab entirely — despite being installed,
    /// configured, and perfectly able to answer.
    func accountQuota() async -> [RateLimitWindow]
}

public extension AgentProvider {
    func isAvailable() -> Bool { true }
    /// Most tools publish no quota at all.
    func accountQuota() async -> [RateLimitWindow] { [] }

    /// By default a provider has no history beyond what it is already showing.
    func fetchHistory(since: Date) async throws -> [SessionSummary] {
        try await fetchSessions().map(\.summary)
    }
}
