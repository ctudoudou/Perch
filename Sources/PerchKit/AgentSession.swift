import Foundation

/// Lifecycle state of a single agent session, normalized across tools.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    /// The agent is actively producing output right now.
    case running
    /// The agent finished its turn and is waiting for the user.
    case awaitingInput
    /// The agent stopped because it needs an approval decision.
    case awaitingApproval
    /// The turn ended normally and nothing is pending.
    case completed
    /// The turn ended in an error.
    case failed

    /// Whether this state should make the notch show live activity.
    public var isActive: Bool {
        self == .running
    }

    /// Whether reaching this state means the work is over.
    ///
    /// Deliberately excludes `awaitingApproval`: a session blocked on a
    /// permission prompt is mid-task, not finished, and announcing it as
    /// complete is both wrong and startling. It still needs attention — that is
    /// what `needsAttention` is for — but it does not ring the completion bell.
    public var isFinished: Bool {
        switch self {
        case .completed, .awaitingInput, .failed: true
        case .running, .awaitingApproval: false
        }
    }

    /// Whether the user is being blocked on.
    public var needsAttention: Bool {
        self == .awaitingInput || self == .awaitingApproval || self == .failed
    }
}

/// Token accounting for a session. All fields are cumulative for the session
/// unless the provider documents otherwise.
public struct TokenUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int
    /// Model context window, when the provider reports one. Drives the context gauge.
    public var contextWindow: Int?
    /// Tokens currently resident in the context window, if the provider tracks it
    /// separately from the cumulative totals.
    public var contextUsed: Int?
    /// Spend in USD, when the tool reports its own figure.
    ///
    /// Preferred over anything Perch could derive from token counts: pricing
    /// varies by model, tier and cache state, so a locally computed cost would
    /// be a guess dressed up as a number.
    public var costUSD: Double?

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        contextWindow: Int? = nil,
        contextUsed: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.contextWindow = contextWindow
        self.contextUsed = contextUsed
        self.costUSD = costUSD
    }

    /// Every token that passed through the model, counted once.
    ///
    /// Providers disagree on whether cached input is *part of* `input` or
    /// additional to it, so `cacheRead`/`cacheWrite` are always stored as a
    /// breakdown of `input` — never as extra volume on top of it. Adding them
    /// here would double-count every provider that reports the way Codex does
    /// (`input_tokens + output_tokens == total_tokens`).
    public var total: Int {
        input + output
    }

    /// Portion of `input` that was served from cache. Useful on its own, but
    /// never added to `total`.
    public var cached: Int {
        cacheRead + cacheWrite
    }

    /// Fraction of the context window in use, when known.
    public var contextFraction: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        let used = contextUsed ?? (input + output)
        return min(1.0, Double(used) / Double(contextWindow))
    }
}

/// How to bring the user to the session when they click it.
public enum SessionTarget: Codable, Sendable, Hashable {
    /// Activate an already-running process.
    case processIdentifier(pid_t)
    /// Launch or activate a bundled app.
    case bundleIdentifier(String)
    /// Open a URL (deep link into a desktop app, or a web console).
    case url(URL)
    /// Reveal a file in Finder — the fallback when nothing better exists.
    case revealFile(URL)
}

/// One agent session as the UI understands it.
public struct AgentSession: Identifiable, Codable, Sendable, Hashable {
    /// Stable across refreshes: `providerID:nativeID`.
    public var id: String
    /// Which provider produced this.
    public var providerID: String
    /// Provider's own session identifier.
    public var nativeID: String
    /// Short label for the notch — usually a task title.
    public var title: String
    /// Working directory, when the session is tied to one.
    public var workingDirectory: URL?
    /// Git branch, when known.
    public var branch: String?
    /// Model identifier, e.g. `claude-opus-5`.
    public var model: String?
    public var state: SessionState
    public var usage: TokenUsage
    /// Last few conversation turns, newest last. Shown in the expanded panel.
    public var transcript: [TranscriptEntry]
    /// When the session was first seen.
    public var startedAt: Date
    /// Last time anything changed.
    public var updatedAt: Date
    /// Where clicking should take the user.
    public var target: SessionTarget?
    /// Quota windows the provider reports for the account, when it publishes
    /// any. These describe the account, not this session, so the UI shows the
    /// newest value rather than summing them.
    public var rateLimits: [RateLimitWindow]
    /// A session spawned by another session rather than started by the user.
    ///
    /// Subagents are hidden from the task list — one request can spawn a dozen
    /// and they would flood it — but their tokens are real spend and must still
    /// count toward every usage total.
    public var isSubagent: Bool

    public init(
        providerID: String,
        nativeID: String,
        title: String,
        workingDirectory: URL? = nil,
        branch: String? = nil,
        model: String? = nil,
        state: SessionState,
        usage: TokenUsage = .init(),
        transcript: [TranscriptEntry] = [],
        startedAt: Date,
        updatedAt: Date,
        target: SessionTarget? = nil,
        rateLimits: [RateLimitWindow] = [],
        isSubagent: Bool = false
    ) {
        self.id = "\(providerID):\(nativeID)"
        self.providerID = providerID
        self.nativeID = nativeID
        self.title = title
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.model = model
        self.state = state
        self.usage = usage
        self.transcript = transcript
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.target = target
        self.rateLimits = rateLimits
        self.isSubagent = isSubagent
    }

    /// How long the session has been going.
    public var duration: TimeInterval {
        updatedAt.timeIntervalSince(startedAt)
    }

    /// Directory basename, for compact display.
    public var projectName: String? {
        workingDirectory?.lastPathComponent
    }
}

/// A single conversation turn, trimmed for display.
public struct TranscriptEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
    }

    public var id: String
    public var role: Role
    /// Already truncated by the provider; the UI does not re-trim.
    public var text: String
    public var timestamp: Date

    public init(id: String = UUID().uuidString, role: Role, text: String, timestamp: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
