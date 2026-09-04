import Foundation
import Testing
@testable import Perch
@testable import PerchKit

@Suite("Usage aggregation")
struct UsageTests {
    @Test("Codex rate limits decode into windows, shortest first")
    func rateLimitParsing() {
        let raw: [String: Any] = [
            "primary": [
                "used_percent": 42.5,
                "window_minutes": 300,
                "resets_at": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            ],
            "secondary": [
                "used_percent": 8.0,
                "window_minutes": 10080,
                "resets_at": Int(Date().addingTimeInterval(86400).timeIntervalSince1970),
            ],
        ]
        let windows = CodexProvider.parseRateLimits(raw)
        #expect(windows.count == 2)
        // Shortest window first, so the one likeliest to bite is shown on top.
        #expect(windows[0].name == "5h")
        #expect(windows[1].name == "7d")
        #expect(abs(windows[0].usedFraction - 0.425) < 0.001)
        #expect(abs(windows[0].remainingFraction - 0.575) < 0.001)
        #expect(windows[0].timeRemaining ?? 0 > 3000)
    }

    @Test("window labels read naturally")
    func windowLabels() {
        #expect(CodexProvider.windowLabel(300) == "5h")
        #expect(CodexProvider.windowLabel(10080) == "7d")
        #expect(CodexProvider.windowLabel(45) == "45m")
    }

    @Test("a lapsed reset time reports no time remaining")
    func expiredWindow() {
        let window = RateLimitWindow(
            name: "5h", usedFraction: 0.5,
            resetsAt: Date().addingTimeInterval(-60)
        )
        #expect(window.timeRemaining == nil)
    }

    @Test("a window may legitimately exceed its cap, but never go negative")
    func clamping() {
        // Spend limits run past 100% once exceeded, and lower-priority work can
        // push a 5-hour window past its cap, so over-use must stay visible.
        #expect(RateLimitWindow(name: "x", usedFraction: 1.7).usedFraction == 1.7)
        #expect(RateLimitWindow(name: "x", usedFraction: 1.7).remainingFraction == 0)
        #expect(RateLimitWindow(name: "x", usedFraction: -0.2).usedFraction == 0)
    }

    @Test("token usage adds across sessions but context does not")
    func usageAddition() {
        let a = TokenUsage(input: 10, output: 5, cacheRead: 100,
                           contextWindow: 200_000, contextUsed: 50_000)
        let b = TokenUsage(input: 20, output: 7, cacheRead: 200,
                           contextWindow: 200_000, contextUsed: 60_000)
        let sum = a + b
        #expect(sum.input == 30)
        #expect(sum.output == 12)
        #expect(sum.cacheRead == 300)
        // Cache is a share of input, not extra volume: total is in+out only.
        #expect(sum.total == 42)
        #expect(sum.cached == 300)
        // Context belongs to one session; a combined "110k of 200k" would be a
        // number that does not describe anything real.
        #expect(sum.contextWindow == nil)
        #expect(sum.contextUsed == nil)
        #expect(sum.contextFraction == nil)
    }

    @Test("provider rollups group, total and rank by spend")
    @MainActor
    func providerRollup() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        let rollups = store.providerUsage
        // Ranked by spend, so the costliest tool is first.
        for (lhs, rhs) in zip(rollups, rollups.dropFirst()) {
            #expect(lhs.usage.total >= rhs.usage.total)
        }
        // A rollup covers every session of that provider — subagents included,
        // because their tokens are real spend even though they get no row.
        for rollup in rollups {
            let expected = store.allSessions
                .filter { $0.providerID == rollup.providerID }
                .reduce(0) { $0 + $1.usage.total }
            #expect(rollup.usage.total == expected)
            #expect(rollup.sessionCount > 0)
        }
        #expect(store.totalUsage.total == store.allSessions.reduce(0) { $0 + $1.usage.total })

        // Hidden subagents must never reduce the totals: this is the bug where
        // 98.8% of a day's Codex spend silently vanished from the Usage tab.
        #expect(store.totalUsage.total >= store.visibleSessions.reduce(0) { $0 + $1.usage.total })
    }

    @Test("disabled providers are not polled")
    @MainActor
    func disabledProviderIsSkipped() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        guard !store.visibleSessions.isEmpty,
              let victim = store.knownProviders.first else { return }

        settings.setEnabled(false, for: victim.id)
        store.reloadProviders()
        await store.refresh()

        #expect(!store.visibleSessions.contains { $0.providerID == victim.id })
        // Still listed, so Settings can offer it back.
        #expect(store.knownProviders.contains { $0.id == victim.id })
    }
}

@Suite("Context window inference")
struct ContextWindowTests {
    @Test("an explicit 1m marker selects the extended window")
    func explicitMarker() {
        #expect(ClaudeCodeProvider.inferContextWindow(
            model: "claude-opus-5[1m]", observedResident: 1_000
        ) == 1_000_000)
    }

    @Test("resident usage above the standard window proves the extended tier")
    func inferredFromUsage() {
        // Real case: a bare `claude-opus-5` holding 245k. Clamping this to a
        // 200k window showed a permanently pinned 100% gauge.
        #expect(ClaudeCodeProvider.inferContextWindow(
            model: "claude-opus-5", observedResident: 245_025
        ) == 1_000_000)
    }

    @Test("ordinary sessions keep the standard window")
    func standardWindow() {
        #expect(ClaudeCodeProvider.inferContextWindow(
            model: "claude-opus-5", observedResident: 120_000
        ) == 200_000)
        #expect(ClaudeCodeProvider.inferContextWindow(
            model: nil, observedResident: 0
        ) == 200_000)
    }

    @Test("the gauge never reports over 100% on real sessions")
    @MainActor
    func gaugeStaysInRange() async throws {
        let provider = ClaudeCodeProvider(visibilityWindow: 90 * 24 * 3600)
        try #require(provider.isAvailable())
        for session in try await provider.fetchSessions() {
            guard let fraction = session.usage.contextFraction else { continue }
            #expect(fraction >= 0 && fraction <= 1)
            // And a session over the standard window must not read as exactly
            // full, which is what the old clamp produced.
            if let used = session.usage.contextUsed, used > 200_000 {
                #expect(fraction < 1.0)
            }
        }
    }
}

@Suite("Token accounting")
struct TokenAccountingTests {
    @Test("total counts each token exactly once")
    func noDoubleCounting() {
        // Codex's own invariant: input_tokens + output_tokens == total_tokens,
        // with cached_input_tokens being a *subset* of input. Treating cache as
        // additional volume inflated Codex sessions by roughly 2×.
        let usage = TokenUsage(
            input: 36_855, output: 276, cacheRead: 35_584, cacheWrite: 0
        )
        #expect(usage.total == 37_131)
        #expect(usage.cached == 35_584)
        #expect(usage.cached < usage.input)
    }

    @Test("live sessions satisfy the invariant")
    @MainActor
    func liveSessionsConsistent() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        for session in store.visibleSessions {
            let usage = session.usage
            #expect(usage.total == usage.input + usage.output)
            // Cache can never exceed the input it is a part of.
            #expect(usage.cached <= usage.input)
        }
    }
}

@Suite("Usage reflects reality")
@MainActor
struct UsageFidelityTests {
    /// Ground truth read straight from the Codex rollout logs, independent of
    /// any Perch parsing code, so this catches a regression in the parser
    /// itself rather than just checking Perch against itself.
    private func codexGroundTruth() -> (total: Int, contextWindows: Set<Int>) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return (0, []) }

        let cutoff = Date().addingTimeInterval(-8 * 3600)
        var total = 0
        var windows: Set<Int> = []

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                modified > cutoff,
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            var last: Int?
            var isInternal = false
            for line in text.split(separator: "\n") {
                guard
                    let data = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let payload = object["payload"] as? [String: Any]
                else { continue }

                if let model = payload["model"] as? String,
                   model.contains("auto-review") || model.contains("mini-latest") {
                    isInternal = true
                }
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any] else { continue }
                if let window = info["model_context_window"] as? Int { windows.insert(window) }
                if let usage = info["total_token_usage"] as? [String: Any],
                   let value = usage["total_tokens"] as? Int {
                    last = value
                }
            }
            if !isInternal, let last { total += last }
        }
        return (total, windows)
    }

    @Test("the Usage tab's Codex total matches the logs")
    func codexTotalMatchesLogs() async {
        // Nothing to compare against when Codex has not run recently.
        let truth = codexGroundTruth()
        guard truth.total > 0 else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        guard let codex = store.providerUsage.first(where: { $0.providerID == "codex" }) else {
            return
        }
        // Perch's own arithmetic must land on the number the tool recorded.
        // A few percent of drift is allowed for logs written mid-read.
        let drift = abs(Double(codex.usage.total - truth.total)) / Double(truth.total)
        #expect(drift < 0.05, "Codex total \(codex.usage.total) vs logs \(truth.total)")
    }

    @Test("Codex context windows come from the logs, never a guess")
    func codexContextWindowIsReported() async {
        let truth = codexGroundTruth()
        guard let reported = truth.contextWindows.first else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        for session in store.allSessions where session.providerID == "codex" {
            guard let window = session.usage.contextWindow else { continue }
            // 258400, not a hardcoded round number.
            #expect(truth.contextWindows.contains(window),
                    "window \(window) is not one the logs reported \(truth.contextWindows)")
        }
        #expect(reported > 0)
    }

    @Test("every displayed session carries real parsed usage")
    func noSyntheticNumbers() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        for session in store.allSessions {
            // Usage is only guaranteed where the model actually answered.
            // A session with user turns but no assistant reply — an auth
            // failure, or one killed mid-turn — legitimately has none, and
            // asserting otherwise tests the machine's history, not the parser.
            if session.transcript.contains(where: { $0.role == .assistant }) {
                #expect(session.usage.total > 0, "\(session.providerID) has no usage")
            }
            #expect(session.usage.total == session.usage.input + session.usage.output)
            #expect(session.usage.cached <= session.usage.input)
        }
    }
}

@Suite("Claude Code usage fidelity")
@MainActor
struct ClaudeUsageFidelityTests {
    /// Sum every assistant *response* in every recent log, independently of
    /// Perch's parser.
    ///
    /// Deduplicated by `(message.id, requestId)`: Claude Code writes one
    /// `assistant` record per content block and every copy repeats the whole
    /// response's usage. An earlier version of this helper summed them all and
    /// so "confirmed" a total that was 1.84× too high — the check and the code
    /// shared the same misunderstanding.
    private func groundTruth() -> Int {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        let cutoff = Date().addingTimeInterval(-8 * 3600)
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return 0 }

        var total = 0
        var counted: Set<String> = []
        for project in projects {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard
                    let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate,
                    modified > cutoff,
                    let text = try? String(contentsOf: file, encoding: .utf8)
                else { continue }

                for line in text.split(separator: "\n") {
                    guard
                        let data = line.data(using: .utf8),
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        object["type"] as? String == "assistant",
                        let message = object["message"] as? [String: Any],
                        let usage = message["usage"] as? [String: Any]
                    else { continue }

                    let id = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
                    guard counted.insert(id).inserted else { continue }

                    let fresh = usage["input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let output = usage["output_tokens"] as? Int ?? 0
                    total += fresh + cacheRead + cacheWrite + output
                }
            }
        }
        return total
    }

    @Test("the Usage tab's Claude Code total matches the logs")
    func matchesLogs() async {
        let truth = groundTruth()
        guard truth > 0 else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        guard let claude = store.providerUsage.first(where: { $0.providerID == "claude-code" })
        else { return }

        // The live session grows while the test runs, so allow modest drift —
        // but nothing like the ~98% gap a tail-only read produced.
        let drift = abs(Double(claude.usage.total - truth)) / Double(truth)
        #expect(drift < 0.10, "Perch \(claude.usage.total) vs logs \(truth)")
    }

    @Test("polling repeatedly does not inflate the total")
    func ledgerDoesNotDoubleCount() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)

        await store.refresh()
        let first = store.providerUsage
            .first(where: { $0.providerID == "claude-code" })?.usage.total ?? 0
        await store.refresh()
        await store.refresh()
        let third = store.providerUsage
            .first(where: { $0.providerID == "claude-code" })?.usage.total ?? 0

        guard first > 0 else { return }
        // The incremental ledger must add only newly appended bytes. Re-reading
        // a file from offset zero on every poll would multiply the total.
        let growth = Double(third - first) / Double(first)
        #expect(growth < 0.05, "total grew \(first) → \(third) across polls")
    }
}

/// Claude Code writes one `assistant` record per content block, each repeating
/// the *entire* response's usage. Counting each record inflated real totals on
/// this machine by 1.84×.
@Suite("Response deduplication")
struct ResponseDedupTests {
    @Test("a response repeated across records is counted once")
    func countsOnce() throws {
        let ledger = UsageLedger()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dedup-\(UUID().uuidString).jsonl")

        // Three records, one API response — exactly what a real log contains.
        let record = """
        {"type":"assistant","requestId":"req_1","message":{"id":"msg_1",\
        "usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}}
        """
        try Array(repeating: record, count: 3)
            .joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = ledger.update(url) { object in
            guard let message = object["message"] as? [String: Any],
                  let id = message["id"] as? String else { return nil }
            return "\(id)|\(object["requestId"] as? String ?? "")"
        } accumulate: { total, object in
            guard let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            else { return }
            total.input += (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            total.output += usage["output_tokens"] as? Int ?? 0
        }

        #expect(usage.input == 110)
        #expect(usage.output == 5)
    }

    @Test("distinct responses still accumulate")
    func distinctResponsesAdd() throws {
        let ledger = UsageLedger()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dedup2-\(UUID().uuidString).jsonl")

        let lines = (1 ... 3).map { index in
            """
            {"type":"assistant","requestId":"req_\(index)","message":{"id":"msg_\(index)",\
            "usage":{"input_tokens":10,"output_tokens":5}}}
            """
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = ledger.update(url) { object in
            (object["message"] as? [String: Any])?["id"] as? String
        } accumulate: { total, object in
            guard let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            else { return }
            total.input += usage["input_tokens"] as? Int ?? 0
            total.output += usage["output_tokens"] as? Int ?? 0
        }

        #expect(usage.input == 30)
        #expect(usage.output == 15)
    }
}

/// An installed, configured tool should appear in Usage whether or not it
/// happens to have run recently. Attaching quota to a session meant Codex
/// vanished entirely once its last session aged past the visibility window.
@Suite("Quota outlives sessions")
@MainActor
struct AccountQuotaLifetimeTests {
    /// A provider that reports quota but never any sessions.
    private struct QuietProvider: AgentProvider {
        let id = "quiet"
        let displayName = "Quiet Tool"
        let appearance = ProviderAppearance(symbolName: "moon", accent: (0.5, 0.5, 0.5))
        func fetchSessions() async throws -> [AgentSession] { [] }
        func accountQuota() async -> [RateLimitWindow] {
            [RateLimitWindow(name: "7d", usedFraction: 0.49, windowMinutes: 10_080,
                             resetsAt: Date().addingTimeInterval(86_400), bucket: "General")]
        }
    }

    /// A provider with neither.
    private struct SilentProvider: AgentProvider {
        let id = "silent"
        let displayName = "Silent Tool"
        let appearance = ProviderAppearance(symbolName: "moon", accent: (0.5, 0.5, 0.5))
        func fetchSessions() async throws -> [AgentSession] { [] }
    }

    @Test("a provider with quota but no sessions still gets a card")
    func quotaWithoutSessions() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        store.useProvidersForTesting([QuietProvider()])
        await store.refresh()

        let card = try! #require(store.providerUsage.first { $0.providerID == "quiet" })
        #expect(card.usage.total == 0)
        #expect(card.sessionCount == 0)
        // The allowance is the whole point of the card.
        #expect(card.limits.count == 1)
        #expect(abs(card.limits[0].remainingFraction - 0.51) < 0.001)
    }

    @Test("a provider with neither usage nor quota is omitted")
    func nothingToSay() async {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        store.useProvidersForTesting([SilentProvider()])
        await store.refresh()
        #expect(!store.providerUsage.contains { $0.providerID == "silent" })
    }

    @Test("Codex reports quota even with no recent sessions")
    func codexQuotaSurvivesIdle() async {
        let provider = CodexProvider()
        guard provider.isAvailable() else { return }
        let quota = await provider.accountQuota()
        guard !quota.isEmpty else { return }
        // Whatever the session history, the allowance is answerable.
        #expect(quota.allSatisfy { $0.usedFraction >= 0 })
        #expect(quota.contains { $0.bucket != nil })
    }
}
