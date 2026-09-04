import Foundation
import Testing
@testable import Perch
@testable import PerchKit

/// State inference drives the whole notch display, so it is exercised against
/// synthetic logs where the expected answer is unambiguous.
@Suite("State inference")
struct StateInferenceTests {
    /// Build a temp Claude Code project tree containing one session log.
    private func claudeFixture(_ lines: [String], age: TimeInterval) throws -> ClaudeCodeProvider {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-test-\(UUID().uuidString)")
        let project = root.appending(path: "-Users-test-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let log = project.appending(path: "\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: log.path
        )
        return ClaudeCodeProvider(root: root)
    }

    private func assistant(stop: String) -> String {
        """
        {"type":"assistant","timestamp":"2026-09-04T04:00:00.000Z","cwd":"/Users/test/proj",\
        "uuid":"a1","message":{"model":"claude-opus-5","stop_reason":"\(stop)",\
        "usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":100,\
        "cache_creation_input_tokens":5},"content":[{"type":"text","text":"hello"}]}}
        """
    }

    @Test("mid-tool-call on a fresh log reads as running")
    func toolUseIsRunning() async throws {
        let provider = try claudeFixture([assistant(stop: "tool_use")], age: 5)
        let session = try #require(try await provider.fetchSessions().first)
        #expect(session.state == .running)
    }

    @Test("finished turn on a fresh log waits for the user")
    func endTurnAwaitsInput() async throws {
        let provider = try claudeFixture([assistant(stop: "end_turn")], age: 5)
        let session = try #require(try await provider.fetchSessions().first)
        #expect(session.state == .awaitingInput)
    }

    @Test("a stale log is completed regardless of stop reason")
    func staleIsCompleted() async throws {
        let provider = try claudeFixture([assistant(stop: "tool_use")], age: 600)
        let session = try #require(try await provider.fetchSessions().first)
        #expect(session.state == .completed)
    }

    @Test("hitting the token ceiling is a failure")
    func maxTokensFails() async throws {
        let provider = try claudeFixture([assistant(stop: "max_tokens")], age: 5)
        let session = try #require(try await provider.fetchSessions().first)
        #expect(session.state == .failed)
    }

    @Test("usage accumulates across assistant turns")
    func usageAccumulates() async throws {
        let provider = try claudeFixture(
            [assistant(stop: "tool_use"), assistant(stop: "end_turn")],
            age: 5
        )
        let session = try #require(try await provider.fetchSessions().first)
        // Anthropic reports cache alongside input, so input folds all three in:
        // 2 × (10 fresh + 100 cache read + 5 cache write) = 230.
        #expect(session.usage.input == 230)
        #expect(session.usage.output == 40)
        #expect(session.usage.cacheRead == 200)
        #expect(session.usage.cached == 210)
        // Total counts each token once.
        #expect(session.usage.total == 270)
        // Resident context reflects only the newest request, not the sum.
        #expect(session.usage.contextUsed == 115)
    }

    @Test("display order puts failures first and running above done")
    func ordering() {
        func make(_ state: SessionState, _ minutesAgo: Int) -> AgentSession {
            AgentSession(
                providerID: "t", nativeID: "\(state.rawValue)-\(minutesAgo)",
                title: "x", state: state,
                startedAt: .distantPast,
                updatedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
            )
        }
        let sorted = [make(.completed, 1), make(.running, 5), make(.failed, 9), make(.awaitingInput, 2)]
            .sorted(by: SessionStore.displayOrder)
        #expect(sorted.map(\.state) == [.failed, .awaitingInput, .running, .completed])
    }

    @Test("synthetic Codex context blocks are not user turns")
    func syntheticFiltering() {
        #expect(CodexProvider.isSynthetic("<environment_context>\n<cwd>/x</cwd>"))
        #expect(CodexProvider.isSynthetic("  <user_instructions>be nice"))
        #expect(!CodexProvider.isSynthetic("please fix the bug in <main.swift>"))
    }

    @Test("plugin target strings parse into activation targets")
    func targetParsing() {
        #expect(PluginSessionPayload.parseTarget("pid:4242") == .processIdentifier(4242))
        #expect(PluginSessionPayload.parseTarget("bundle:com.x.Y") == .bundleIdentifier("com.x.Y"))
        #expect(PluginSessionPayload.parseTarget("url:https://e.com") == .url(URL(string: "https://e.com")!))
        #expect(PluginSessionPayload.parseTarget("nonsense") == nil)
        #expect(PluginSessionPayload.parseTarget(nil) == nil)
    }

    @Test("token formatting stays compact")
    func formatting() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(1_250) == "1.2k")
        #expect(Format.tokens(3_400_000) == "3.4M")
    }
}

/// Slash-command output comes back as a `user` record wrapped in tags. Taking
/// it as a title produced entries like "<local-command-stdout>Login successful".
@Suite("Synthetic user records")
struct SyntheticUserRecordTests {
    @Test("command output is not treated as something the user typed")
    func filtersCommandOutput() {
        #expect(ClaudeCodeProvider.isSynthetic("<local-command-stdout>Login successful"))
        #expect(ClaudeCodeProvider.isSynthetic("  <command-name>/login"))
        #expect(ClaudeCodeProvider.isSynthetic("<system-reminder>note"))
        // The one that slipped through an exact-match list.
        #expect(ClaudeCodeProvider.isSynthetic("<local-command-caveat>Caveat: …"))
    }

    @Test("a real prompt that merely mentions a tag is kept")
    func keepsRealPrompts() {
        #expect(!ClaudeCodeProvider.isSynthetic("fix the <local-command-stdout> parser"))
        #expect(!ClaudeCodeProvider.isSynthetic("add a README"))
        // Prose that merely opens with an angle bracket is not a wrapper.
        #expect(!ClaudeCodeProvider.isSynthetic("<- what does this arrow mean"))
    }
}
