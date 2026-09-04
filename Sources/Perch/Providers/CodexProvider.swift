import Foundation
import PerchKit

/// Reads Codex rollout logs from `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Unlike Claude Code, Codex writes explicit lifecycle events, so state comes
/// straight from the log rather than being inferred:
///   - `task_started` without a matching `task_complete`  → running
///   - `task_complete`                                    → awaitingInput (fresh) / completed
///   - `turn_aborted` / error                             → failed
///
/// Token usage comes from `event_msg/token_count`, whose `total_token_usage`
/// is already cumulative — it is assigned, never summed.
struct CodexProvider: AgentProvider {
    let id = "codex"
    let displayName = "Codex"
    let appearance = ProviderAppearance(
        symbolName: "chevron.left.forwardslash.chevron.right",
        accent: (red: 0.42, green: 0.75, blue: 0.55)
    )

    private let livenessWindow: TimeInterval = 300
    private let visibilityWindow: TimeInterval
    private let root: URL
    /// Turn events Codex pushed through its `notify` program.
    private let reports: ReportStore
    /// Live quota, read from Codex itself rather than scraped from old logs.
    private let quota: LiveQuotaCache
    /// Subagent rollouts are collapsed into their parent rather than listed
    /// separately; a single request can spawn many and they would flood the notch.
    private let includeSubagents: Bool

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions", directoryHint: .isDirectory),
        visibilityWindow: TimeInterval = 8 * 3600,
        includeSubagents: Bool = false,
        reports: ReportStore = .shared,
        quota: LiveQuotaCache? = nil
    ) {
        self.root = root
        self.visibilityWindow = visibilityWindow
        self.includeSubagents = includeSubagents
        self.reports = reports
        let server = CodexAppServer()
        self.quota = quota ?? LiveQuotaCache(interval: CodexAppServer.refreshInterval) {
            await server.readRateLimits()
        }
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: root.path(percentEncoded: false))
    }

    func fetchSessions() async throws -> [AgentSession] {
        let cutoff = Date().addingTimeInterval(-visibilityWindow)
        let pushed = reports.reports(for: Self.reportTool)
        var sessions = recentLogs(since: cutoff)
            .compactMap { parse(log: $0.url, modified: $0.modified, reports: pushed) }

        // Internal machinery is not a task and not the user's spend, so those
        // sessions are dropped. Their *quota* report is still valid though —
        // it describes the account — and the general `codex` allowance is often
        // only ever reported by an auto-review session, so harvest limits
        // before discarding them or that bucket is never seen at all.
        var salvagedLimits: [RateLimitWindow] = []
        sessions.removeAll { parsed in
            let isInternal = parsed.session.model.map(Self.internalModels.contains) ?? false
            if isInternal { salvagedLimits.append(contentsOf: parsed.session.rateLimits) }
            return isInternal
        }

        var result = sessions.map(\.session)

        // Attach to the newest session so the store's merge sees them; they are
        // account-wide, so which session carries them does not matter.
        if !salvagedLimits.isEmpty,
           let newest = result.indices.max(by: { result[$0].updatedAt < result[$1].updatedAt }) {
            result[newest].rateLimits.append(contentsOf: salvagedLimits)
        }
        return result
    }

    /// Rollouts live under a date hierarchy, so only the last couple of day
    /// directories need scanning even though the tree is large.
    private func recentLogs(since cutoff: Date) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                modified > cutoff
            else { continue }
            results.append((url, modified))
        }
        return results
    }

    private struct Parsed {
        var session: AgentSession
        var isSubagent: Bool
    }

    /// Live quota, straight from Codex. Independent of whether any session has
    /// run recently — the allowance exists either way.
    func accountQuota() async -> [RateLimitWindow] {
        let live = await quota.current()
        if !live.isEmpty { return live }
        // Fall back to whatever the most recent logs recorded, which is at
        // least a real observation even if it is not current.
        let cutoff = Date().addingTimeInterval(-visibilityWindow)
        let scraped = recentLogs(since: cutoff)
            .compactMap { parse(log: $0.url, modified: $0.modified) }
            .map(\.session)
        return SessionStore.mergeLimits(scraped)
    }

    static let reportTool = CodexReporter.tool

    private func parse(
        log url: URL,
        modified: Date,
        reports: [String: SessionReport] = [:]
    ) -> Parsed? {
        let records = JSONLReader.tailObjects(of: url)
        guard !records.isEmpty else { return nil }

        // `session_meta` is the first record and embeds the full system prompt,
        // so on any non-trivial session it sits far outside the tail window.
        // Read it from the head instead — this is where cwd and subagent status live.
        var meta: [String: Any]?
        if let head = JSONLReader.firstObject(of: url),
           head.string("type") == "session_meta" {
            meta = head.dict("payload")
        }
        // `turn_context` carries the model but is written early, so on a long
        // session it sits outside the tail window and the model reads as
        // unknown. Recover it from the head as a fallback.
        let headModel = JSONLReader.firstMatch(of: url, limit: 40) {
            $0.string("type") == "turn_context"
        }?.dict("payload")?.string("model")

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd: URL?
        var model: String?
        var usage = TokenUsage()
        var transcript: [TranscriptEntry] = []
        var startedAt: Date?
        var isSubagent = false
        var openTurns = Set<String>()
        var sawFailure = false
        var lastAgentMessage: String?
        var firstUserMessage: String?
        var rateLimits: [RateLimitWindow] = []

        if let meta {
            sessionID = meta.string("id") ?? sessionID
            if let path = meta.string("cwd") { cwd = URL(fileURLWithPath: path) }
            if meta.string("thread_source") == "subagent" { isSubagent = true }
            startedAt = Timestamps.parse(meta.string("timestamp"))
        }

        for record in records {
            let stamp = Timestamps.parse(record.string("timestamp"))
            let outerType = record.string("type")
            guard let payload = record.dict("payload") else { continue }

            switch outerType {
            case "session_meta":
                sessionID = payload.string("id") ?? sessionID
                if let path = payload.string("cwd") { cwd = URL(fileURLWithPath: path) }
                if payload.string("thread_source") == "subagent" { isSubagent = true }
                startedAt = Timestamps.parse(payload.string("timestamp")) ?? stamp

            case "turn_context":
                // The newest turn_context wins: a session can switch models
                // mid-run and the latest one is what is actually in use.
                model = payload.string("model") ?? model

            case "event_msg":
                switch payload.string("type") {
                case "task_started":
                    if let turn = payload.string("turn_id") { openTurns.insert(turn) }
                    if let window = payload.int("model_context_window") {
                        usage.contextWindow = window
                    }
                    startedAt = startedAt ?? stamp

                case "task_complete":
                    if let turn = payload.string("turn_id") { openTurns.remove(turn) }
                    if let message = payload.string("last_agent_message") {
                        lastAgentMessage = message
                    }

                case "turn_aborted", "error", "stream_error":
                    sawFailure = true
                    openTurns.removeAll()

                case "token_count":
                    // Quota windows describe the account and are refreshed on
                    // every token_count, so the newest record wins.
                    if let limits = payload.dict("rate_limits") {
                        rateLimits = Self.parseRateLimits(limits)
                    }
                    // Cumulative for the session — assign, do not accumulate.
                    if let info = payload.dict("info") {
                        if let total = info.dict("total_token_usage") {
                            usage.input = total.int("input_tokens") ?? usage.input
                            usage.output = total.int("output_tokens") ?? usage.output
                            usage.cacheRead = total.int("cached_input_tokens") ?? usage.cacheRead
                            usage.cacheWrite = total.int("cache_write_input_tokens") ?? usage.cacheWrite
                            usage.reasoning = total.int("reasoning_output_tokens") ?? usage.reasoning
                        }
                        if let window = info.int("model_context_window") {
                            usage.contextWindow = window
                        }
                        // The most recent request is what actually occupies context.
                        if let last = info.dict("last_token_usage") {
                            usage.contextUsed = last.int("total_tokens")
                        }
                    }

                default:
                    break
                }

            case "response_item":
                if let entry = transcriptEntry(from: payload, timestamp: stamp) {
                    if entry.role == .user, firstUserMessage == nil {
                        firstUserMessage = entry.text
                    }
                    transcript.append(entry)
                }

            default:
                break
            }
        }

        // Prefer a model seen in the tail (the current one); fall back to the
        // session's opening turn_context.
        model = model ?? headModel

        // Codex notifies only on turn completion, so a later `task_started` in
        // the log means a new turn began after the report and the report is
        // superseded. Otherwise the report stands.
        let report = reports[sessionID]
        let startedSinceReport = !openTurns.isEmpty
            && (report.map { modified > $0.timestamp } ?? false)
        let state: SessionState
        if let report, report.isFresh, !startedSinceReport {
            state = report.state
        } else {
            state = resolveState(
                openTurns: openTurns,
                failed: sawFailure,
                modified: modified
            )
        }

        // The user's own request describes the task; the last agent message is a
        // result summary and makes a confusing label ("DONE Commit: abc123…").
        let title = firstUserMessage?.condensed(to: 60)
            ?? transcript.first(where: { $0.role == .user })?.text.condensed(to: 60)
            ?? lastAgentMessage?.condensed(to: 60)
            ?? cwd?.lastPathComponent
            ?? "Session"

        let session = AgentSession(
            providerID: id,
            nativeID: sessionID,
            title: title,
            workingDirectory: cwd,
            model: model,
            state: state,
            usage: usage,
            transcript: Array(transcript.suffix(6)),
            startedAt: startedAt ?? modified,
            updatedAt: modified,
            target: .bundleIdentifier("com.openai.codex"),
            rateLimits: rateLimits,
            isSubagent: isSubagent
        )
        return Parsed(session: session, isSubagent: isSubagent)
    }

    private func transcriptEntry(from payload: [String: Any], timestamp: Date?) -> TranscriptEntry? {
        let kind = payload.string("type")
        let role: TranscriptEntry.Role
        var text: String?

        switch kind {
        case "message":
            // `role` distinguishes the user's turn from a replayed assistant turn.
            role = payload.string("role") == "user" ? .user : .assistant
            if let blocks = payload.array("content") as? [[String: Any]] {
                text = blocks.compactMap { $0.string("text") }.joined(separator: " ")
            } else {
                text = payload.string("content")
            }
            // Codex injects synthetic context blocks as user-role messages. They
            // are not something the user typed and make terrible titles.
            if role == .user, let raw = text, Self.isSynthetic(raw) { return nil }

        case "agent_message":
            role = .assistant
            text = payload.string("text") ?? payload.string("message")

        case "custom_tool_call", "function_call", "local_shell_call":
            role = .tool
            text = payload.string("name").map { "→ \($0)" }

        default:
            return nil
        }

        guard let condensed = text?.condensed(to: 220), !condensed.isEmpty else { return nil }
        return TranscriptEntry(role: role, text: condensed, timestamp: timestamp ?? Date())
    }

    /// Codex publishes a primary (short) and secondary (long) quota window.
    /// `used_percent` is 0...100 and `resets_at` is a Unix timestamp.
    ///
    /// Crucially, an account has **several independent quota buckets** —
    /// a general one (`limit_id: codex`) plus per-model ones such as
    /// `GPT-5.3-Codex-Spark`. Each session reports only the bucket that its own
    /// model draws from, so showing whichever session happened to be newest
    /// displays a bucket the user was not asking about: a Spark session sitting
    /// at 0% hid a general bucket that was 26% consumed.
    static func parseRateLimits(_ raw: [String: Any]) -> [RateLimitWindow] {
        // `limit_name` is the human bucket ("GPT-5.3-Codex-Spark"); `limit_id`
        // is its stable key, and plain "codex" is the general allowance.
        let id = raw.string("limit_id")
        let bucket = raw.string("limit_name")
            ?? (id == "codex" ? "General" : id?.capitalized)
            ?? "General"

        var windows: [RateLimitWindow] = []
        for key in ["primary", "secondary"] {
            guard
                let entry = raw.dict(key),
                let percent = entry["used_percent"] as? Double
            else { continue }
            // A window past its reset describes the previous period. Perch
            // was showing a 5-hour window whose reset had already passed.
            if let resets = entry.int("resets_at"),
               TimeInterval(resets) <= Date().timeIntervalSince1970 {
                continue
            }
            let minutes = entry.int("window_minutes")
            windows.append(
                RateLimitWindow(
                    name: minutes.map(Self.windowLabel) ?? key.capitalized,
                    usedFraction: percent / 100,
                    windowMinutes: minutes,
                    resetsAt: entry.int("resets_at").map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    bucket: bucket
                )
            )
        }
        return windows.sorted { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
    }

    /// Turn a window length into something readable: 300 → "5h", 10080 → "7d".
    static func windowLabel(_ minutes: Int) -> String {
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// XML-ish envelopes Codex injects into the user role.
    private static let syntheticPrefixes = [
        "<environment_context>",
        "<user_instructions>",
        "<system_reminder>",
        "<editor_context>",
        "## My request for Codex:",
    ]

    static func isSynthetic(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return syntheticPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// Internal Codex machinery that runs alongside a user task rather than
    /// being one. Surfacing these would double-count every session.
    private static let internalModels: Set<String> = [
        "codex-auto-review",
        "codex-mini-latest",
    ]

    private func resolveState(openTurns: Set<String>, failed: Bool, modified: Date) -> SessionState {
        if failed { return .failed }
        let isFresh = Date().timeIntervalSince(modified) < livenessWindow

        if !openTurns.isEmpty {
            // A turn that never closed and went quiet means the process died
            // rather than that it is still thinking.
            return isFresh ? .running : .failed
        }
        return isFresh ? .awaitingInput : .completed
    }
}
