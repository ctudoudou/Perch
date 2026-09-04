import Foundation
import Testing
@testable import Perch
@testable import PerchKit

/// These run against the real logs on this machine. They assert on invariants
/// that must hold for any parse, not on specific session contents.
@Suite("Live provider parsing")
struct ProviderSmokeTests {
    @Test("Claude Code sessions parse with coherent fields")
    func claudeCode() async throws {
        let provider = ClaudeCodeProvider(visibilityWindow: 90 * 24 * 3600)
        try #require(provider.isAvailable())

        let sessions = try await provider.fetchSessions()
        try #require(!sessions.isEmpty, "expected at least one Claude Code session on disk")

        for session in sessions {
            #expect(!session.title.isEmpty)
            #expect(session.id == "claude-code:\(session.nativeID)")
            #expect(session.usage.total >= 0)
            #expect(session.startedAt <= session.updatedAt)
            if let fraction = session.usage.contextFraction {
                #expect(fraction >= 0 && fraction <= 1)
            }
        }
    }

    @Test("Codex sessions parse with coherent fields")
    func codex() async throws {
        let provider = CodexProvider(visibilityWindow: 90 * 24 * 3600)
        try #require(provider.isAvailable())

        let sessions = try await provider.fetchSessions()
        try #require(!sessions.isEmpty, "expected at least one Codex session on disk")

        for session in sessions {
            #expect(!session.title.isEmpty)
            #expect(session.usage.total >= 0)
            #expect(session.startedAt <= session.updatedAt)
        }
    }
}
