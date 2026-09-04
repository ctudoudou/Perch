import Foundation
import Testing
@testable import Perch
@testable import PerchKit

/// The status line is the only supported source for Claude Code's rate limits
/// and true context-window size — both arrive as API response headers and are
/// never written to the session log.
/// Schema: https://code.claude.com/docs/en/statusline
@Suite("Statusline bridge")
struct StatuslineTests {
    /// The documented payload shape. Reset times are relative so the windows
    /// stay live: a window whose `resets_at` has passed is deliberately dropped.
    private var payload: String {
        let fiveHour = Int(Date().addingTimeInterval(3_420).timeIntervalSince1970)
        let sevenDay = Int(Date().addingTimeInterval(47_820).timeIntervalSince1970)
        return """
    {
      "session_id": "abc-123",
      "model": { "id": "claude-opus-5", "display_name": "Opus 5" },
      "context_window": {
        "total_input_tokens": 324500,
        "total_output_tokens": 1200,
        "context_window_size": 1000000,
        "used_percentage": 32
      },
      "cost": { "total_cost_usd": 1.234, "total_duration_ms": 45000 },
      "exceeds_200k_tokens": true,
      "rate_limits": {
        "five_hour": { "used_percentage": 72, "resets_at": \(fiveHour) },
        "seven_day": { "used_percentage": 11, "resets_at": \(sevenDay) }
      }
    }
    """
    }

    private func decode() throws -> StatuslineSnapshot {
        try JSONDecoder().decode(
            StatuslineSnapshot.self, from: Data(payload.utf8)
        )
    }

    @Test("the documented payload decodes")
    func decodes() throws {
        let snapshot = try decode()
        #expect(snapshot.session_id == "abc-123")
        #expect(snapshot.model?.id == "claude-opus-5")
        // The real window, not a guess: this is what the 200k hardcode got wrong.
        #expect(snapshot.context_window?.context_window_size == 1_000_000)
        #expect(snapshot.context_window?.total_input_tokens == 324_500)
        #expect(snapshot.cost?.total_cost_usd == 1.234)
        #expect(snapshot.exceeds_200k_tokens == true)
    }

    @Test("rate limits become windows, shortest first")
    func windows() throws {
        let windows = try decode().windows
        #expect(windows.count == 2)
        #expect(windows[0].name == "5h")
        #expect(abs(windows[0].usedFraction - 0.72) < 0.001)
        #expect(abs(windows[0].remainingFraction - 0.28) < 0.001)
        #expect(windows[1].name == "7d")
        #expect(abs(windows[1].usedFraction - 0.11) < 0.001)
        // Both belong to the subscription bucket, not a per-model one.
        #expect(windows.allSatisfy { $0.bucket == "Subscription" })
    }

    @Test("a payload with no rate limits yields no windows")
    func absentLimits() throws {
        // Limits are absent for API-key, Bedrock and Vertex sessions, and
        // before the first API response. That must read as "unknown", never as
        // a fabricated 0%.
        let snapshot = try JSONDecoder().decode(
            StatuslineSnapshot.self,
            from: Data(#"{"session_id":"x"}"#.utf8)
        )
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.context_window?.context_window_size == nil)
    }

    @Test("a spend limit over 100% stays visible as over")
    func overspend() throws {
        let snapshot = try JSONDecoder().decode(
            StatuslineSnapshot.self,
            from: Data(#"{"rate_limits":{"spend_limit":{"used_percentage":118}}}"#.utf8)
        )
        let window = try #require(snapshot.windows.first)
        #expect(window.usedFraction > 1)
        #expect(window.remainingFraction == 0)
    }

    @Test("the helper snapshots stdin by session id, compact or pretty")
    func helperRoundTrip() throws {
        // Never touch the real snapshot directory. A previous version of this
        // test installed into the production path and left a fixture there;
        // Perch read it back and displayed its invented percentages as live
        // quota, which is exactly the bug this suite exists to prevent.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-statusline-\(UUID().uuidString)")
        let store = StatuslineStore(directory: sandbox)
        try store.installHelper()

        let process = Process()
        process.executableURL = store.helperURL
        var environment = ProcessInfo.processInfo.environment
        environment["PERCH_STATUSLINE_DIR"] = sandbox.path(percentEncoded: false)
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let snapshot = try #require(
            store.snapshot(sessionID: "abc-123"),
            "helper did not write a snapshot for the pretty-printed payload"
        )
        #expect(snapshot.context_window?.context_window_size == 1_000_000)
        #expect(snapshot.windows.count == 2)
        // The payload above is pretty-printed with spaces after the colons,
        // which an earlier regex silently failed to match — it filed every
        // session under "unknown" and Perch saw no data at all.
        #expect(snapshot.session_id == "abc-123")
    }
}

@Suite("Quota buckets")
struct QuotaBucketTests {
    @Test("Codex tags each window with the bucket it describes")
    func bucketTagging() {
        let spark = CodexProvider.parseRateLimits([
            "limit_id": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark",
            "primary": ["used_percent": 0.0, "window_minutes": 300],
        ])
        #expect(spark.first?.bucket == "GPT-5.3-Codex-Spark")

        let general = CodexProvider.parseRateLimits([
            "limit_id": "codex",
            "primary": ["used_percent": 26.0, "window_minutes": 10080],
        ])
        #expect(general.first?.bucket == "General")
    }

    @Test("buckets from different sessions are merged, not overwritten")
    @MainActor
    func mergeAcrossSessions() {
        func session(_ id: String, _ limits: [RateLimitWindow], minutesAgo: Int) -> AgentSession {
            AgentSession(
                providerID: "codex", nativeID: id, title: "t", state: .completed,
                startedAt: .distantPast,
                updatedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)),
                rateLimits: limits
            )
        }

        // A Spark session sitting at 0% must not hide the general bucket at 26%,
        // which is exactly what taking only the newest session's limits did.
        let sparkNewer = session("a", [
            RateLimitWindow(name: "5h", usedFraction: 0, windowMinutes: 300,
                            bucket: "GPT-5.3-Codex-Spark"),
        ], minutesAgo: 1)
        let generalOlder = session("b", [
            RateLimitWindow(name: "7d", usedFraction: 0.26, windowMinutes: 10080,
                            bucket: "General"),
        ], minutesAgo: 90)

        let merged = SessionStore.mergeLimits([sparkNewer, generalOlder])
        #expect(merged.count == 2)
        // General first, so the allowance that matters most is on top.
        #expect(merged[0].bucket == "General")
        #expect(abs(merged[0].usedFraction - 0.26) < 0.001)
        #expect(merged[1].bucket == "GPT-5.3-Codex-Spark")
    }

    @Test("the freshest report of a given window wins")
    @MainActor
    func freshestWins() {
        func session(_ used: Double, minutesAgo: Int) -> AgentSession {
            AgentSession(
                providerID: "codex", nativeID: "\(minutesAgo)", title: "t", state: .completed,
                startedAt: .distantPast,
                updatedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)),
                rateLimits: [RateLimitWindow(name: "5h", usedFraction: used,
                                             windowMinutes: 300, bucket: "General")]
            )
        }
        let merged = SessionStore.mergeLimits([session(0.10, minutesAgo: 200), session(0.55, minutesAgo: 2)])
        #expect(merged.count == 1)
        #expect(abs(merged[0].usedFraction - 0.55) < 0.001)
    }
}

/// Guards the specific failures the user reported: Codex showing a per-model
/// bucket's 0% as though it were the general allowance, and Claude Code showing
/// no limits at all.
@Suite("Quota fidelity")
@MainActor
struct QuotaFidelityTests {
    /// Every quota bucket present in recent Codex logs, read independently.
    private func codexBuckets() -> [String: Double] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [:] }

        let cutoff = Date().addingTimeInterval(-8 * 3600)
        var newest: [String: (used: Double, at: Date)] = [:]

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                modified > cutoff,
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for line in text.split(separator: "\n") where line.contains("rate_limits") {
                guard
                    let data = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let payload = object["payload"] as? [String: Any],
                    let limits = payload["rate_limits"] as? [String: Any]
                else { continue }

                let id = limits["limit_id"] as? String ?? "?"
                let bucket = limits["limit_name"] as? String
                    ?? (id == "codex" ? "General" : id)
                for key in ["primary", "secondary"] {
                    guard
                        let window = limits[key] as? [String: Any],
                        let used = window["used_percent"] as? Double
                    else { continue }
                    let composite = "\(bucket)|\(key)"
                    if let existing = newest[composite], existing.at >= modified { continue }
                    newest[composite] = (used, modified)
                }
            }
        }
        return newest.mapValues(\.used)
    }

    @Test("Codex quota matches what Codex itself reports")
    func codexQuotaMatchesProtocol() async {
        // Ground truth straight from the app-server protocol, independent of
        // Perch's client: `account/rateLimits/read` returns every bucket, live.
        guard let truth = await Self.protocolRateLimits() else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()
        // The live read is warmed in the background; give it a cycle to land.
        try? await Task.sleep(for: .seconds(12))
        await store.refresh()

        guard
            let codex = store.providerUsage.first(where: { $0.providerID == "codex" }),
            !codex.limits.isEmpty
        else { return }

        for (bucket, used) in truth {
            guard let shown = codex.limits.first(where: { $0.bucket == bucket }) else {
                Issue.record("bucket \(bucket) missing from \(codex.limits.map(\.bucket))")
                continue
            }
            #expect(abs(shown.usedFraction * 100 - used) < 1.5,
                    "\(bucket): showed \(shown.usedFraction * 100)%, Codex says \(used)%")
        }
    }

    /// Call the protocol directly for the primary window of each bucket.
    static func protocolRateLimits() async -> [String: Double]? {
        guard let executable = CodexAppServer.locateExecutable() else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }

        for request in [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"perch-test","title":"t","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#,
        ] {
            input.fileHandleForWriting.write(Data((request + "\n").utf8))
        }

        var buffer = Data()
        var found: [String: Double]?
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, found == nil {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { if !process.isRunning { break }; continue }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex ..< index])
                buffer.removeSubrange(buffer.startIndex ... index)
                guard
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    (object["id"] as? Int) == 1,
                    let result = object["result"] as? [String: Any],
                    let byId = result["rateLimitsByLimitId"] as? [String: Any]
                else { continue }

                var buckets: [String: Double] = [:]
                for (_, value) in byId {
                    guard let snapshot = value as? [String: Any] else { continue }
                    let name = (snapshot["limitName"] as? String)
                        ?? ((snapshot["limitId"] as? String) == "codex" ? "General" : nil)
                        ?? "General"
                    if let primary = snapshot["primary"] as? [String: Any],
                       let used = primary["usedPercent"] as? Double {
                        buckets[name] = used
                    }
                }
                found = buckets
                break
            }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return found
    }

    @Test("the log fallback still parses bucket percentages correctly")
    func percentagesMatch() async {
        let truth = codexBuckets()
        guard !truth.isEmpty else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        guard let codex = store.providerUsage.first(where: { $0.providerID == "codex" })
        else { return }

        // Only meaningful while the live read is unavailable; when Codex
        // answers, its numbers replace these by design.
        guard await Self.protocolRateLimits() == nil else { return }
        for window in codex.limits {
            let key = "\(window.bucket ?? "")|\(window.windowMinutes == 300 ? "primary" : "secondary")"
            guard let expected = truth[key] else { continue }
            #expect(abs(window.usedFraction * 100 - expected) < 1.0,
                    "\(key): showed \(window.usedFraction * 100)%, logs say \(expected)%")
        }
    }

    @Test("Claude Code limits appear once the status line is feeding data")
    func claudeLimitsPresent() async {
        let statusline = StatuslineStore.shared
        guard statusline.hasData, statusline.newestSnapshot()?.rate_limits != nil
        else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        guard let claude = store.providerUsage.first(where: { $0.providerID == "claude-code" })
        else { return }
        // Previously always empty: these never appear in session logs.
        #expect(!claude.limits.isEmpty)
    }

    @Test("the context window comes from the status line, not a guess")
    func contextWindowIsReported() async {
        guard let reported = StatuslineStore.shared.newestSnapshot()?
            .context_window?.context_window_size else { return }

        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore(settings: settings)
        await store.refresh()

        let windows = Set(store.allSessions
            .filter { $0.providerID == "claude-code" }
            .compactMap(\.usage.contextWindow))
        #expect(windows.contains(reported), "\(windows) does not include reported \(reported)")
    }
}

/// Guards the failure the user hit: Perch displaying numbers that were not
/// live readings from their Claude Code.
@Suite("Snapshot freshness")
struct SnapshotFreshnessTests {
    /// Run a body against an isolated snapshot directory.
    private func sandboxed(_ body: (URL, StatuslineStore) throws -> Void) rethrows {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-fresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        // A local store, so parallel tests cannot clobber one another and the
        // real directory is never in play.
        try body(sandbox, StatuslineStore(directory: sandbox))
    }

    private func write(_ json: String, to directory: URL, name: String, age: TimeInterval) throws {
        let url = directory.appending(path: name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func payload(fiveHourUsed: Int) -> String {
        let resets = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        return """
        {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":\(fiveHourUsed),"resets_at":\(resets)}}}
        """
    }

    @Test("an hour-old snapshot is kept, but marked as not current")
    func staleIsKeptAndMarked() throws {
        try sandboxed { directory, store in
            // Claude Code's status line cannot refresh itself once a session
            // ends, so discarding this made quota disappear minutes later —
            // with the tool still installed and still holding an allowance.
            // It is kept and captioned with its age instead.
            try write(payload(fiveHourUsed: 72), to: directory, name: "s.json", age: 3_600)
            #expect(store.snapshot(sessionID: "s") != nil)
            #expect(store.hasData)

            let window = try #require(store.newestWindows().first)
            #expect(abs(window.usedFraction - 0.72) < 0.001)
            #expect(!window.isCurrent)
        }
    }

    @Test("a snapshot beyond the keep window is finally dropped")
    func ancientIsDropped() throws {
        try sandboxed { directory, store in
            try write(payload(fiveHourUsed: 72), to: directory, name: "s.json", age: 13 * 3_600)
            #expect(store.newestSnapshot() == nil)
            #expect(!store.hasData)
        }
    }

    @Test("a recent snapshot is used")
    func freshIsUsed() throws {
        try sandboxed { directory, store in
            try write(payload(fiveHourUsed: 72), to: directory, name: "s.json", age: 30)
            let snapshot = try #require(store.snapshot(sessionID: "s"))
            #expect(snapshot.windows.first?.usedFraction == 0.72)
            #expect(store.hasData)
        }
    }

    @Test("the newest of several snapshots wins")
    func newestWins() throws {
        try sandboxed { directory, store in
            try write(payload(fiveHourUsed: 10), to: directory, name: "old.json", age: 300)
            try write(payload(fiveHourUsed: 64), to: directory, name: "new.json", age: 10)
            let snapshot = try #require(store.newestSnapshot())
            #expect(snapshot.windows.first?.usedFraction == 0.64)
        }
    }

    @Test("a window past its reset time disappears")
    func expiredWindowDropped() throws {
        try sandboxed { directory, store in
            let past = Int(Date().addingTimeInterval(-60).timeIntervalSince1970)
            let future = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
            try write("""
            {"session_id":"s","rate_limits":{
              "five_hour":{"used_percentage":99,"resets_at":\(past)},
              "seven_day":{"used_percentage":40,"resets_at":\(future)}
            }}
            """, to: directory, name: "s.json", age: 5)

            let windows = try #require(store.snapshot(sessionID: "s")).windows
            // The exhausted 5-hour window has reset; showing 99% would be a lie.
            #expect(windows.count == 1)
            #expect(windows[0].name == "7d")
        }
    }

    @Test("the production directory is the default and untouched by tests")
    func productionPathIsDefault() {
        #expect(StatuslineStore.shared.directory == StatuslineStore.defaultDirectory)
        #expect(StatuslineStore.defaultDirectory.path.contains("Application Support/Perch/Statusline"))
    }

    @Test("no test fixture is left in the real snapshot directory")
    func noFixturePollution() {
        // The reported bug: a test wrote a fixture into the production path and
        // Perch displayed its invented percentages as live quota.
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: StatuslineStore.defaultDirectory.path(percentEncoded: false)
        )) ?? []
        for name in files where name.hasSuffix(".json") {
            let url = StatuslineStore.defaultDirectory.appending(path: name)
            guard
                let data = try? Data(contentsOf: url),
                let snapshot = try? JSONDecoder().decode(StatuslineSnapshot.self, from: data)
            else { continue }
            #expect(snapshot.session_id != "abc-123", "test fixture found at \(url.path)")
        }
    }
}

/// Undocumented windows must survive. Some plans receive per-model weekly
/// buckets (`seven_day_opus` and friends) that the public schema does not list;
/// decoding only the documented three silently dropped them.
@Suite("Open-ended rate limit decoding")
struct OpenRateLimitTests {
    private func decode(_ json: String) throws -> [RateLimitWindow] {
        try JSONDecoder().decode(StatuslineSnapshot.self, from: Data(json.utf8)).windows
    }

    @Test("per-model weekly buckets are surfaced and labelled")
    func perModelBuckets() throws {
        let future = Int(Date().addingTimeInterval(9_000).timeIntervalSince1970)
        let windows = try decode("""
        {"rate_limits":{
          "five_hour":{"used_percentage":40,"resets_at":\(future)},
          "seven_day":{"used_percentage":12,"resets_at":\(future)},
          "seven_day_opus":{"used_percentage":88,"resets_at":\(future)}
        }}
        """)
        #expect(windows.count == 3)
        let opus = try #require(windows.first { $0.bucket == "Opus" })
        #expect(opus.name == "7d")
        #expect(abs(opus.usedFraction - 0.88) < 0.001)
    }

    @Test("an entirely unknown window is still shown, never dropped")
    func unknownWindow() throws {
        let future = Int(Date().addingTimeInterval(600).timeIntervalSince1970)
        let windows = try decode(
            #"{"rate_limits":{"some_future_window":{"used_percentage":5,"resets_at":\#(future)}}}"#
        )
        #expect(windows.count == 1)
        #expect(windows[0].name == "some future window")
    }

    @Test("windows are ordered shortest first")
    func ordering() throws {
        let future = Int(Date().addingTimeInterval(9_000).timeIntervalSince1970)
        let windows = try decode("""
        {"rate_limits":{
          "seven_day":{"used_percentage":12,"resets_at":\(future)},
          "five_hour":{"used_percentage":40,"resets_at":\(future)}
        }}
        """)
        // The window that bites soonest comes first.
        #expect(windows.first?.name == "5h")
    }
}

/// Quota describes the account, not one session — and a session that has just
/// started reports `rate_limits: null` until its first API response.
@Suite("Account-wide quota")
struct AccountQuotaTests {
    private func store(_ files: [(name: String, json: String)]) throws -> StatuslineStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try file.json.write(
                to: directory.appending(path: "\(file.name).json"),
                atomically: true, encoding: .utf8
            )
        }
        return StatuslineStore(directory: directory)
    }

    private var future: Int { Int(Date().addingTimeInterval(3_600).timeIntervalSince1970) }

    @Test("a newer session without limits does not blank out the reading")
    func newSessionDoesNotBlank() throws {
        let withLimits = """
        {"session_id":"old","rate_limits":{"five_hour":{"used_percentage":74,"resets_at":\(future)}}}
        """
        // A session that just started: no API response yet, so no limits.
        let withoutLimits = #"{"session_id":"new"}"#

        let store = try store([("old", withLimits), ("new", withoutLimits)])
        // Make "new" the newest file.
        let newURL = store.directory.appending(path: "new.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: newURL.path(percentEncoded: false)
        )

        let windows = store.newestWindows()
        #expect(windows.count == 1)
        #expect(abs(windows[0].usedFraction - 0.74) < 0.001)
    }

    @Test("with no reading anywhere, quota is empty rather than invented")
    func noReading() throws {
        let store = try store([("a", #"{"session_id":"a"}"#)])
        #expect(store.newestWindows().isEmpty)
    }

    @Test("the freshest of several readings wins")
    func freshestWins() throws {
        let older = """
        {"session_id":"a","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":\(future)}}}
        """
        let newer = """
        {"session_id":"b","rate_limits":{"five_hour":{"used_percentage":74,"resets_at":\(future)}}}
        """
        let store = try store([("a", older), ("b", newer)])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: store.directory.appending(path: "a.json").path(percentEncoded: false)
        )
        let windows = store.newestWindows()
        #expect(abs(windows.first!.usedFraction - 0.74) < 0.001)
    }

    @Test("a path with spaces is quoted for the shell")
    func quoting() {
        // Unquoted, the shell split "Application Support" and the helper never
        // ran — which is why quota stayed empty in every session.
        let quoted = StatuslineStore.shellQuoted("/a b/c.sh")
        #expect(quoted == "'/a b/c.sh'")
        #expect(StatuslineStore.shellQuoted("/it's/x.sh").contains(#"'\''"#))
    }
}

/// Claude Code's quota cannot refresh itself — the status line only runs while
/// a session renders one. Discarding the reading when it aged made quota
/// vanish minutes after the last session, which read as a bug.
@Suite("Quota persistence")
struct QuotaPersistenceTests {
    private func store(observedMinutesAgo: Double, json: String) throws -> StatuslineStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "s.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-observedMinutesAgo * 60)],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return StatuslineStore(directory: directory)
    }

    private var future: Int { Int(Date().addingTimeInterval(7_200).timeIntervalSince1970) }

    private func payload() -> String {
        """
        {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":74,"resets_at":\(future)}}}
        """
    }

    @Test("an hour-old reading is kept, not discarded")
    func oldReadingSurvives() throws {
        let store = try store(observedMinutesAgo: 60, json: payload())
        let windows = store.newestWindows()
        #expect(windows.count == 1)
        #expect(abs(windows[0].usedFraction - 0.74) < 0.001)
    }

    @Test("an old reading is marked as not current, with its age")
    func ageIsReported() throws {
        let store = try store(observedMinutesAgo: 60, json: payload())
        let window = try #require(store.newestWindows().first)
        #expect(!window.isCurrent)
        let age = try #require(window.age)
        // Roughly an hour; the UI captions this rather than hiding the number.
        #expect(age > 55 * 60 && age < 65 * 60)
    }

    @Test("a reading from moments ago counts as current")
    func freshReadingIsCurrent() throws {
        let store = try store(observedMinutesAgo: 0.2, json: payload())
        let window = try #require(store.newestWindows().first)
        #expect(window.isCurrent)
    }

    @Test("a window past its own reset is dropped however fresh the file")
    func expiredWindowStillDropped() throws {
        let past = Int(Date().addingTimeInterval(-60).timeIntervalSince1970)
        let store = try store(
            observedMinutesAgo: 0.1,
            json: #"{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":74,"resets_at":\#(past)}}}"#
        )
        // Expiry, not file age, is what makes a percentage meaningless.
        #expect(store.newestWindows().isEmpty)
    }

    @Test("a reading beyond the keep window is finally let go")
    func veryOldReadingDropped() throws {
        let store = try store(observedMinutesAgo: 13 * 60, json: payload())
        #expect(store.newestWindows().isEmpty)
    }
}
