import Foundation

/// A session reduced to what statistics need.
///
/// Deliberately not an `AgentSession`: the task list is bounded to a few hours
/// and carries transcripts, while history reaches back months and must stay
/// cheap to gather. On this machine the Codex logs alone are over two gigabytes
/// across hundreds of files, one of them 721 MB, so anything that reads whole
/// files is not an option for this path.
public struct SessionSummary: Sendable, Hashable {
    public var providerID: String
    public var nativeID: String
    /// When the session was last active — the basis for every day-bucketed stat.
    public var updatedAt: Date
    public var model: String?
    public var usage: TokenUsage
    /// Working directory, used to count distinct projects.
    public var projectPath: String?
    /// Machine-spawned sessions still cost tokens, but are not something the
    /// user opened, so they are counted for spend and not for session totals.
    public var isSubagent: Bool

    public init(
        providerID: String,
        nativeID: String,
        updatedAt: Date,
        model: String? = nil,
        usage: TokenUsage = .init(),
        projectPath: String? = nil,
        isSubagent: Bool = false
    ) {
        self.providerID = providerID
        self.nativeID = nativeID
        self.updatedAt = updatedAt
        self.model = model
        self.usage = usage
        self.projectPath = projectPath
        self.isSubagent = isSubagent
    }
}

public extension AgentSession {
    /// The live sessions already in memory can answer history questions too.
    var summary: SessionSummary {
        SessionSummary(
            providerID: providerID,
            nativeID: nativeID,
            updatedAt: updatedAt,
            model: model,
            usage: usage,
            projectPath: workingDirectory?.path,
            isSubagent: isSubagent
        )
    }
}
