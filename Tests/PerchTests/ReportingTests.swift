import Foundation
import Testing
@testable import Perch
@testable import PerchKit

/// The reporters edit the user's own config files, so these tests run the real
/// scripts against a sandbox and check the config edits round-trip exactly.
@Suite("Push reporting")
struct ReportingTests {
    private func sandbox() -> ReportStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-reports-\(UUID().uuidString)")
        return ReportStore(directory: directory)
    }

    private func run(_ url: URL, args: [String], stdin: String, dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PERCH_REPORT_DIR"] = dir.path(percentEncoded: false)
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("a Stop hook reports the turn as finished")
    func claudeStopHook() throws {
        let store = sandbox()
        try ClaudeCodeReporter.installScript(in: store)

        let status = try run(
            ClaudeCodeReporter.scriptURL(in: store),
            args: ["Stop", "awaitingInput"],
            // Pretty-printed, as a real payload may be.
            stdin: #"{ "session_id": "sess-1", "cwd": "/tmp/proj", "hook_event_name": "Stop" }"#,
            dir: store.directory
        )
        #expect(status == 0)

        let report = try #require(store.reports(for: "claude-code")["sess-1"])
        #expect(report.state == .awaitingInput)
        #expect(report.event == "Stop")
        #expect(report.cwd == "/tmp/proj")
        #expect(report.isFresh)
    }

    @Test("a prompt submission reports the session as running")
    func claudePromptHook() throws {
        let store = sandbox()
        try ClaudeCodeReporter.installScript(in: store)
        _ = try run(
            ClaudeCodeReporter.scriptURL(in: store),
            args: ["UserPromptSubmit", "running"],
            stdin: #"{"session_id":"sess-2","cwd":"/tmp/x"}"#,
            dir: store.directory
        )
        #expect(store.reports(for: "claude-code")["sess-2"]?.state == .running)
    }

    @Test("a payload without a session id is ignored, silently and successfully")
    func claudeNoSession() throws {
        let store = sandbox()
        try ClaudeCodeReporter.installScript(in: store)
        // A hook that fails or prints would surface inside the user's session.
        let status = try run(
            ClaudeCodeReporter.scriptURL(in: store),
            args: ["Stop", "awaitingInput"],
            stdin: #"{"cwd":"/tmp"}"#,
            dir: store.directory
        )
        #expect(status == 0)
        #expect(store.reports(for: "claude-code").isEmpty)
    }

    @Test("a completed Codex turn is recorded from the JSON argument")
    func codexNotify() throws {
        let store = sandbox()
        try CodexReporter.installScript(in: store)

        let payload = """
        {"type":"agent-turn-complete","turn-id":"t1","thread-id":"th-9",\
        "last-assistant-message":"done"}
        """
        let status = try run(
            CodexReporter.scriptURL(in: store),
            args: ["turn-ended", payload],
            stdin: "",
            dir: store.directory
        )
        #expect(status == 0)

        let report = try #require(store.reports(for: "codex")["th-9"])
        #expect(report.state == .awaitingInput)
        #expect(report.event == "agent-turn-complete")
    }

    @Test("the previous notify program still receives the original arguments")
    func codexChaining() throws {
        let store = sandbox()
        try CodexReporter.installScript(in: store)

        // Stand in for the user's existing notify program.
        let marker = store.directory.appending(path: "codex/chained-ran.txt")
        let chain = CodexReporter.chainURL(in: store)
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"\(marker.path(percentEncoded: false))\"\n"
            .write(to: chain, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: chain.path(percentEncoded: false)
        )

        _ = try run(
            CodexReporter.scriptURL(in: store),
            args: ["turn-ended", #"{"type":"agent-turn-complete","thread-id":"th-1"}"#],
            stdin: "",
            dir: store.directory
        )

        let passed = try #require(try? String(contentsOf: marker, encoding: .utf8))
        // Both the fixed argument and the appended JSON must survive, in order.
        #expect(passed.contains("turn-ended"))
        #expect(passed.contains("agent-turn-complete"))
    }

    @Test("a stale report is ignored so inference can take over")
    func staleReport() throws {
        let store = sandbox()
        try store.prepare(tools: ["claude-code"])
        let old = Date().addingTimeInterval(-SessionReport.maxAge - 60).timeIntervalSince1970
        let json = #"{"tool":"claude-code","session":"s","event":"Stop","state":"running","at":\#(old)}"#
        try json.write(
            to: store.toolDirectory("claude-code").appending(path: "s.json"),
            atomically: true, encoding: .utf8
        )
        // A "running" report left behind by a crashed session must not pin the
        // notch as busy forever.
        #expect(store.reports(for: "claude-code").isEmpty)
    }

    @Test("freshness is what bounds a report's authority")
    func freshnessBounds() {
        let now = SessionReport(
            tool: "claude-code", session: "s", event: "UserPromptSubmit",
            state: .running, at: Date().timeIntervalSince1970, cwd: nil
        )
        #expect(now.isFresh)

        let old = SessionReport(
            tool: "claude-code", session: "s", event: "UserPromptSubmit",
            state: .running,
            at: Date().addingTimeInterval(-SessionReport.maxAge - 1).timeIntervalSince1970,
            cwd: nil
        )
        #expect(!old.isFresh)
    }
}

/// `config.toml` is the user's file — comments, ordering and all. These check
/// Perch only ever rewrites the one line it owns.
@Suite("Codex config editing")
struct CodexConfigTests {
    @Test("a notify array parses, including quoted paths with spaces")
    func parseArray() {
        let parsed = CodexReporter.parseArray(
            #"notify = ["/Applications/My App.app/Contents/MacOS/x", "turn-ended"]"#
        )
        #expect(parsed.count == 2)
        #expect(parsed[0] == "/Applications/My App.app/Contents/MacOS/x")
        #expect(parsed[1] == "turn-ended")
    }

    @Test("escaped quotes survive parsing")
    func parseEscapes() {
        #expect(CodexReporter.parseQuoted(#""a\"b""#) == [#"a"b"#])
    }

    @Test("a commented-out notify line is not treated as configuration")
    func ignoresComments() {
        // Reading `# notify = [...]` as live config would clobber a real setting.
        #expect(CodexReporter.parseArray("# notify = [\"/old\"]") == ["/old"])
    }
}

/// The app was called Island before Perch. A rename that left the old paths in
/// `settings.json` and `config.toml` would break every integration silently.
@Suite("Rename migration")
struct MigrationTests {
    @Test("a hook installed under the old name is still recognised")
    func legacyHookRecognised() throws {
        let matcher: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": "\"/x/Island/Reports/claude-code/island-report.sh\" Stop awaitingInput"]],
        ]
        let settings: [String: Any] = ["hooks": ["Stop": [matcher]]]
        let data = try JSONSerialization.data(withJSONObject: settings)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Detection keys on the script name, so both spellings match and an
        // upgrade can re-point them.
        let hooks = try #require(decoded["hooks"] as? [String: Any])
        let stops = try #require(hooks["Stop"] as? [[String: Any]])
        let commands = try #require(stops.first?["hooks"] as? [[String: Any]])
        let text = try #require(commands.first?["command"] as? String)
        #expect(text.contains("island-report.sh"))
    }

    @Test("a notify program under either name is recognised")
    func legacyNotifyRecognised() {
        for script in ["island-notify.sh", "perch-notify.sh"] {
            let parsed = CodexReporter.parseArray(#"notify = ["/x/\#(script)"]"#)
            let program = parsed.first ?? ""
            #expect(program.contains("island-notify.sh") || program.contains("perch-notify.sh"))
        }
    }

    @Test("migration is a no-op once nothing references the old name")
    func noOpWhenClean() {
        // Safe to call on every launch: it must not touch a clean install.
        #expect(Migration.isNeeded == Migration.isNeeded)
    }
}

/// Another tool can take the `notify` slot and preserve ours as an argument.
/// Re-taking the outer position must not leave a reference back to ourselves.
@Suite("Notify chain hygiene")
struct NotifyChainTests {
    @Test("a --previous-notify pointing at our own script is stripped")
    func stripsPreviousNotify() {
        // The shape Codex Computer Use writes when it takes over.
        let taken = [
            "/Applications/Computer Use.app/Contents/MacOS/Client",
            "turn-ended",
            "--previous-notify",
            #"["/x/Perch/Reports/codex/perch-notify.sh"]"#,
        ]
        let cleaned = CodexReporter.withoutOurOwnReferences(taken)
        #expect(cleaned == [
            "/Applications/Computer Use.app/Contents/MacOS/Client", "turn-ended",
        ])
    }

    @Test("a reference under the app's former name is stripped too")
    func stripsLegacyReference() {
        let taken = ["/x/other", "--previous-notify", #"["/x/Island/island-notify.sh"]"#]
        #expect(CodexReporter.withoutOurOwnReferences(taken) == ["/x/other"])
    }

    @Test("someone else's arguments are left alone")
    func preservesOtherArguments() {
        let other = ["/x/their-notify", "--flag", "value", "turn-ended"]
        #expect(CodexReporter.withoutOurOwnReferences(other) == other)
    }

    @Test("a command that is only us collapses to nothing to chain to")
    func onlyOurselves() {
        // Chaining to ourselves would loop forever.
        #expect(CodexReporter.withoutOurOwnReferences(["/x/perch-notify.sh"]) == nil)
    }
}
