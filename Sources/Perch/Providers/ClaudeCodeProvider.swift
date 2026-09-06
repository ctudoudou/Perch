import Foundation
import PerchKit

/// Reads Claude Code session logs from `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`.
///
/// Claude Code does not write explicit task lifecycle events, so state is
/// inferred from the last record plus file freshness:
///   - last record is an `assistant` message with `stop_reason == "tool_use"`,
///     and the file was touched recently  → running
///   - last record is a `user` message, recently touched                → running
///   - last record is an `assistant` message that stopped normally      → awaitingInput
///   - nothing written for a while                                      → completed
struct ClaudeCodeProvider: AgentProvider {
    /// Shared across refreshes so each log's bytes are parsed once.
    private let ledger: UsageLedger
    /// Source of rate limits and the true context-window size.
    private let statusline: StatuslineStore
    /// State the tool pushed, which outranks anything Perch can infer.
    private let reports: ReportStore

    let id = "claude-code"
    let displayName = "Claude Code"
    let appearance = ProviderAppearance(
        symbolName: "asterisk",
        accent: (red: 0.85, green: 0.47, blue: 0.30)
    )

    /// How long a log may stay quiet before inference stops calling it live.
    ///
    /// A single tool call can run for many minutes without writing anything, so
    /// a short window mistook slow work for a finished turn. Only used when no
    /// pushed report is available.
    private let livenessWindow: TimeInterval = 300
    /// Sessions untouched for longer than this are not shown at all.
    private let visibilityWindow: TimeInterval
    private let root: URL

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory),
        visibilityWindow: TimeInterval = 8 * 3600,
        ledger: UsageLedger = UsageLedger(),
        statusline: StatuslineStore = .shared,
        reports: ReportStore = .shared
    ) {
        self.root = root
        self.visibilityWindow = visibilityWindow
        self.ledger = ledger
        self.statusline = statusline
        self.reports = reports
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: root.path(percentEncoded: false))
    }

    func fetchSessions() async throws -> [AgentSession] {
        let cutoff = Date().addingTimeInterval(-visibilityWindow)
        let logs = recentLogs(since: cutoff)
        ledger.prune(keeping: Set(logs.map(\.url)))
        let pushed = reports.reports(for: Self.reportTool)
        return logs.compactMap { parse(log: $0.url, modified: $0.modified, reports: pushed) }
    }

    /// Every `.jsonl` under the projects root modified since `cutoff`.
    private func recentLogs(since cutoff: Date) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(URL, Date)] = []
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard
                    let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate,
                    modified > cutoff
                else { continue }
                results.append((file, modified))
            }
        }
        return results
    }

    /// Wrappers Claude Code injects into the user role.
    ///
    /// A slash command's output comes back as a `user` record wrapped in tags.
    /// It is not something the user typed, and taking it as a session title
    /// produced entries like "<local-command-stdout>Login successful".
    /// Tag families Claude Code uses for machine-generated user records.
    /// Matched by family rather than by exact tag, so a wrapper this list has
    /// never seen — `<local-command-caveat>` was the one that got through —
    /// is still recognised.
    static let syntheticTagPrefixes = [
        "<local-command-",
        "<command-",
        "<system-",
        "<user-prompt-",
        "<bash-",
    ]

    static func isSynthetic(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }
        // Only when the tag actually closes, so prose that merely opens with a
        // "<" is left alone.
        guard let close = trimmed.firstIndex(of: ">") else { return false }
        let tag = trimmed[trimmed.startIndex ... close]
        return syntheticTagPrefixes.contains { tag.hasPrefix($0) }
    }

    /// Claude Code records a `<synthetic>` model for turns that never reached
    /// the API — an auth failure, for instance. They carry no usage and are not
    /// work the user did, so they are not sessions worth showing.
    static let syntheticModel = "<synthetic>"

    /// Quota reported by whichever session last rendered a status line.
    func accountQuota() async -> [RateLimitWindow] {
        statusline.newestWindows()
    }

    /// History over a long range.
    ///
    /// Claude Code's logs are far smaller than Codex's, and the ledger already
    /// caches each file's totals by byte offset, so a full pass costs nothing
    /// after the first.
    func fetchHistory(since: Date) async throws -> [SessionSummary] {
        recentLogs(since: since).compactMap { summarise(log: $0.url, modified: $0.modified) }
    }

    private func summarise(log url: URL, modified: Date) -> SessionSummary? {
        let usage = ledger.update(url) { record in
            guard record.string("type") == "assistant",
                  let id = record.dict("message")?.string("id") else { return nil }
            return "\(id)|\(record.string("requestId") ?? "")"
        } accumulate: { total, record in
            guard record.string("type") == "assistant",
                  let u = record.dict("message")?.dict("usage") else { return }
            let fresh = u.int("input_tokens") ?? 0
            let cacheRead = u.int("cache_read_input_tokens") ?? 0
            let cacheWrite = u.int("cache_creation_input_tokens") ?? 0
            total.input += fresh + cacheRead + cacheWrite
            total.output += u.int("output_tokens") ?? 0
            total.cacheRead += cacheRead
            total.cacheWrite += cacheWrite
            total.reasoning += u.dict("output_tokens_details")?.int("thinking_tokens") ?? 0
        }

        // A session that never got a reply is not work the user did.
        guard usage.total > 0 else { return nil }

        var model: String?
        var project: String?
        for record in JSONLReader.tailObjects(of: url) {
            if let cwd = record.string("cwd") { project = cwd }
            if record.string("type") == "assistant",
               let value = record.dict("message")?.string("model") {
                model = value
            }
        }
        if model == Self.syntheticModel { return nil }

        return SessionSummary(
            providerID: id,
            nativeID: url.deletingPathExtension().lastPathComponent,
            updatedAt: modified,
            model: model,
            usage: usage,
            projectPath: project
        )
    }

    static let reportTool = ClaudeCodeReporter.tool

    private func parse(
        log url: URL,
        modified: Date,
        reports: [String: SessionReport] = [:]
    ) -> AgentSession? {
        let records = JSONLReader.tailObjects(of: url)
        guard !records.isEmpty else { return nil }

        let sessionID = url.deletingPathExtension().lastPathComponent
        var title: String?
        var cwd: URL?
        var branch: String?
        var model: String?
        // Cumulative spend must come from every record in the file. The tail
        // read below covers only the last fraction of a multi-megabyte log —
        // summing that alone under-reported this session by ~98%.
        var usage = ledger.update(url) { record in
            // One API response can be written as several `assistant` records,
            // one per content block, each repeating the full usage. Identify
            // the response so it is only counted once.
            guard record.string("type") == "assistant",
                  let id = record.dict("message")?.string("id") else { return nil }
            return "\(id)|\(record.string("requestId") ?? "")"
        } accumulate: { total, record in
            guard record.string("type") == "assistant",
                  let u = record.dict("message")?.dict("usage") else { return }
            let fresh = u.int("input_tokens") ?? 0
            let cacheRead = u.int("cache_read_input_tokens") ?? 0
            let cacheWrite = u.int("cache_creation_input_tokens") ?? 0
            // Anthropic reports cache alongside input, so real input is the sum.
            total.input += fresh + cacheRead + cacheWrite
            total.output += u.int("output_tokens") ?? 0
            total.cacheRead += cacheRead
            total.cacheWrite += cacheWrite
            total.reasoning += u.dict("output_tokens_details")?.int("thinking_tokens") ?? 0
        }
        var transcript: [TranscriptEntry] = []
        var lastConversational: [String: Any]?
        var earliest = modified

        for record in records {
            let type = record.string("type")

            // Titles: an explicit custom title wins over the generated one.
            if type == "custom-title", let t = record.string("customTitle") {
                title = t
            } else if type == "ai-title", title == nil, let t = record.string("title") {
                title = t
            }

            if let stamp = Timestamps.parse(record.string("timestamp")), stamp < earliest {
                earliest = stamp
            }
            if let path = record.string("cwd") { cwd = URL(fileURLWithPath: path) }
            // "HEAD" means detached; showing it as a branch name is misleading.
            if let b = record.string("gitBranch"), !b.isEmpty, b != "HEAD" { branch = b }

            guard let type, type == "user" || type == "assistant" else { continue }
            lastConversational = record

            guard let message = record.dict("message") else { continue }
            if type == "assistant" {
                model = message.string("model") ?? model
                // Usage is per-request, so the newest record carries the live totals
                // for the context window; the cumulative spend is the sum.
                // Only the newest request describes what is resident in the
                // context window; the cumulative totals come from the ledger.
                if let u = message.dict("usage") {
                    usage.contextUsed = (u.int("input_tokens") ?? 0)
                        + (u.int("cache_read_input_tokens") ?? 0)
                        + (u.int("cache_creation_input_tokens") ?? 0)
                }
            }

            if let entry = transcriptEntry(from: record, type: type) {
                transcript.append(entry)
            }
        }

        // Claude Code publishes the real context window and the account's quota
        // only to its status line, never to the session log. Prefer that when
        // Perch's helper has captured it; fall back to inference otherwise.
        var rateLimits: [RateLimitWindow] = []
        if let snapshot = statusline.snapshot(sessionID: sessionID) {
            usage.contextWindow = snapshot.context_window?.context_window_size
                ?? Self.inferContextWindow(model: model, observedResident: usage.contextUsed ?? 0)
            // The status line reports what is actually resident right now,
            // which is more reliable than reconstructing it from the last record.
            if let live = snapshot.context_window,
               let input = live.total_input_tokens {
                usage.contextUsed = input + (live.total_output_tokens ?? 0)
            }
            // Quota is account-wide, so it comes from whichever session last
            // reported any — not only from this session's own snapshot.
            rateLimits = statusline.newestWindows()
            model = snapshot.model?.id ?? model
            // Claude Code's own cost figure, rather than one derived from tokens.
            usage.costUSD = snapshot.cost?.total_cost_usd
        } else {
            usage.contextWindow = Self.inferContextWindow(
                model: model,
                observedResident: usage.contextUsed ?? 0
            )
            // Quota is account-wide, so any session's snapshot describes it.
            rateLimits = statusline.newestWindows()
        }

        // A session that never received a response is not a task: no model
        // answered, nothing was spent, and its only content is what the user
        // typed before it failed or was interrupted.
        let answered = transcript.contains { $0.role == .assistant }
        if usage.total == 0, !answered || model == Self.syntheticModel { return nil }

        // A pushed hook event beats inference outright: it was written at the
        // transition and says which transition it was, so it holds until the
        // next event rather than until a timer expires.
        //
        // An earlier version also required the report to be newer than the log's
        // modification time. That is wrong: a long turn keeps writing, so the
        // log overtakes the report and inference took back over mid-turn —
        // seeing a quiet log during a slow tool call and calling it "completed",
        // which fired a spurious "task finished" alert while work was ongoing.
        let report = reports[sessionID]
        let state = report?.isFresh == true
            ? report!.state
            : inferState(last: lastConversational, modified: modified)
        let fallbackTitle = transcript.last(where: { $0.role == .user })?.text
            ?? cwd?.lastPathComponent
            ?? "Session"

        return AgentSession(
            providerID: id,
            nativeID: sessionID,
            title: (title ?? fallbackTitle).condensed(to: 60),
            workingDirectory: cwd,
            branch: branch,
            model: model,
            state: state,
            usage: usage,
            transcript: Array(transcript.suffix(6)),
            startedAt: earliest,
            updatedAt: modified,
            target: .bundleIdentifier("com.anthropic.claudefordesktop"),
            rateLimits: rateLimits
        )
    }

    private func transcriptEntry(from record: [String: Any], type: String) -> TranscriptEntry? {
        guard let message = record.dict("message") else { return nil }
        let text: String

        // `content` is either a plain string or an array of typed blocks.
        if let plain = message.string("content") {
            text = plain
        } else if let blocks = message.array("content") as? [[String: Any]] {
            let pieces = blocks.compactMap { block -> String? in
                switch block.string("type") {
                case "text": return block.string("text")
                case "tool_use": return block.string("name").map { "→ \($0)" }
                case "thinking": return nil
                default: return nil
                }
            }
            text = pieces.joined(separator: " ")
        } else {
            return nil
        }

        let trimmed = text.condensed(to: 220)
        guard !trimmed.isEmpty else { return nil }
        if type == "user", Self.isSynthetic(trimmed) { return nil }

        return TranscriptEntry(
            id: record.string("uuid") ?? UUID().uuidString,
            role: type == "user" ? .user : .assistant,
            text: trimmed,
            timestamp: Timestamps.parse(record.string("timestamp")) ?? Date()
        )
    }

    private func inferState(last: [String: Any]?, modified: Date) -> SessionState {
        let isFresh = Date().timeIntervalSince(modified) < livenessWindow
        guard let last, let type = last.string("type") else {
            return isFresh ? .running : .completed
        }

        if type == "user" {
            // The user's turn was just written; the model is about to answer.
            return isFresh ? .running : .completed
        }

        let stopReason = last.dict("message")?.string("stop_reason")
        switch stopReason {
        case "tool_use":
            // Mid-turn: the model called a tool and the result has not landed yet.
            return isFresh ? .running : .completed
        case "end_turn", "stop_sequence":
            return isFresh ? .awaitingInput : .completed
        case "max_tokens", "refusal":
            return .failed
        default:
            return isFresh ? .running : .completed
        }
    }

    static let defaultContextWindow = 200_000
    static let extendedContextWindow = 1_000_000

    /// Pick the window that can actually contain what was observed.
    ///
    /// The `[1m]` suffix appears on some model strings, but not all — a session
    /// on the extended tier often reports a bare `claude-opus-5`. Rather than
    /// clamping the gauge to a wrong 100%, treat resident usage that exceeds the
    /// standard window as proof the extended one is in use.
    static func inferContextWindow(model: String?, observedResident: Int) -> Int {
        if let model, model.contains("[1m]") { return extendedContextWindow }
        if observedResident > defaultContextWindow { return extendedContextWindow }
        return defaultContextWindow
    }
}
