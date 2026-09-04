import Foundation
import Testing
@testable import Perch
@testable import PerchKit

@Suite("Completion alerts")
@MainActor
struct NotificationTests {
    private func makeSettings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func session(_ id: String, _ state: SessionState) -> AgentSession {
        AgentSession(
            providerID: "p", nativeID: id, title: "t", state: state,
            startedAt: .distantPast, updatedAt: Date()
        )
    }

    @Test("the first poll is a baseline and alerts on nothing")
    func firstPollIsSilent() {
        let notifier = CompletionNotifier(settings: makeSettings())
        // Otherwise every launch would replay every finished task at once.
        let finished = notifier.process([session("a", .completed), session("b", .awaitingInput)])
        #expect(finished.isEmpty)
    }

    @Test("running to finished fires exactly once, after confirmation")
    func firesOnTransition() {
        let notifier = CompletionNotifier(settings: makeSettings())
        notifier.process([session("a", .running)])

        // The edge arms the alert; the confirming poll fires it.
        #expect(notifier.process([session("a", .completed)]).isEmpty)
        #expect(notifier.process([session("a", .completed)]).count == 1)

        // The state has not changed again, so no further alerts.
        #expect(notifier.process([session("a", .completed)]).isEmpty)
    }

    @Test("staying active does not fire")
    func noAlertWhileWorking() {
        let notifier = CompletionNotifier(settings: makeSettings())
        notifier.process([session("a", .running)])
        #expect(notifier.process([session("a", .running)]).isEmpty)
    }

    @Test("awaiting input counts as finished")
    func awaitingInputFires() {
        let notifier = CompletionNotifier(settings: makeSettings())
        notifier.process([session("a", .running)])
        notifier.process([session("a", .awaitingInput)])
        #expect(notifier.process([session("a", .awaitingInput)]).count == 1)
    }

    @Test("failure fires too")
    func failureFires() {
        let notifier = CompletionNotifier(settings: makeSettings())
        notifier.process([session("a", .running)])
        notifier.process([session("a", .failed)])
        #expect(notifier.process([session("a", .failed)]).count == 1)
    }

    @Test("a finished session flashes, then stops")
    func flashIsTracked() async {
        let settings = makeSettings()
        settings.notifyVisual = true
        let notifier = CompletionNotifier(settings: settings)
        notifier.process([session("a", .running)])
        notifier.process([session("a", .completed)])
        notifier.process([session("a", .completed)])
        #expect(notifier.flashing.contains("p:a"))
    }

    @Test("visual alerts can be switched off")
    func flashRespectsSetting() {
        let settings = makeSettings()
        settings.notifyVisual = false
        let notifier = CompletionNotifier(settings: settings)
        notifier.process([session("a", .running)])
        notifier.process([session("a", .completed)])
        notifier.process([session("a", .completed)])
        #expect(notifier.flashing.isEmpty)
    }

    @Test("a session that disappears is forgotten so it can alert again")
    func forgetsAgedOut() {
        let notifier = CompletionNotifier(settings: makeSettings())
        notifier.process([session("a", .running)])
        // Session ages out of the window entirely.
        notifier.process([])
        // It comes back already running, then finishes: that is a fresh alert.
        notifier.process([session("a", .running)])
        notifier.process([session("a", .completed)])
        #expect(notifier.process([session("a", .completed)]).count == 1)
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    private func makeSettings() -> (Settings, UserDefaults) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return (Settings(defaults: defaults), defaults)
    }

    @Test("alerts default to on")
    func defaults() {
        let (settings, _) = makeSettings()
        #expect(settings.notifyVisual)
        #expect(settings.notifyBanner)
        #expect(settings.notifySound == .glass)
        #expect(settings.visibilityHours == 8)
        #expect(!settings.showSubagents)
    }

    @Test("choices survive a restart")
    func persistence() {
        let (settings, defaults) = makeSettings()
        settings.notifyVisual = false
        settings.notifySound = .ping
        settings.visibilityHours = 24
        settings.setEnabled(false, for: "codex")

        let reloaded = Settings(defaults: defaults)
        #expect(!reloaded.notifyVisual)
        #expect(reloaded.notifySound == .ping)
        #expect(reloaded.visibilityHours == 24)
        #expect(!reloaded.isEnabled("codex"))
    }

    @Test("unknown providers are enabled by default")
    func newProvidersAppear() {
        let (settings, _) = makeSettings()
        // Stored as a disabled-list, so a newly installed plugin is visible
        // rather than silently absent.
        #expect(settings.isEnabled("brand-new-plugin"))
    }

    @Test("disabling then re-enabling round-trips")
    func toggleRoundTrip() {
        let (settings, _) = makeSettings()
        settings.setEnabled(false, for: "claude-code")
        #expect(!settings.isEnabled("claude-code"))
        settings.setEnabled(true, for: "claude-code")
        #expect(settings.isEnabled("claude-code"))
        #expect(settings.disabledProviders.isEmpty)
    }
}

/// The user saw "task complete" while work was still running. Two causes: a
/// pushed `running` report was being discarded mid-turn, and a single momentary
/// reading was enough to fire.
@Suite("Alert debounce")
@MainActor
struct AlertDebounceTests {
    private func makeNotifier() -> CompletionNotifier {
        CompletionNotifier(settings: Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    private func session(_ state: SessionState) -> AgentSession {
        AgentSession(
            providerID: "p", nativeID: "a", title: "t", state: state,
            startedAt: .distantPast, updatedAt: Date()
        )
    }

    @Test("a single flicker to finished does not alert")
    func flickerIsSuppressed() {
        let notifier = makeNotifier()
        notifier.process([session(.running)])

        // One poll misreads the session as finished…
        #expect(notifier.process([session(.completed)]).isEmpty)
        // …and the next shows it working again. Nothing should have fired.
        #expect(notifier.process([session(.running)]).isEmpty)
        #expect(notifier.flashing.isEmpty)
    }

    @Test("a genuine finish still alerts, one poll later")
    func realFinishAlerts() {
        let notifier = makeNotifier()
        notifier.process([session(.running)])

        #expect(notifier.process([session(.completed)]).isEmpty)
        let fired = notifier.process([session(.completed)])
        #expect(fired.count == 1)
    }

    @Test("a confirmed finish alerts exactly once")
    func firesOnce() {
        let notifier = makeNotifier()
        notifier.process([session(.running)])
        notifier.process([session(.completed)])
        #expect(notifier.process([session(.completed)]).count == 1)
        // Staying finished must not keep alerting.
        #expect(notifier.process([session(.completed)]).isEmpty)
        #expect(notifier.process([session(.completed)]).isEmpty)
    }

    @Test("resuming work re-arms for the next real finish")
    func rearms() {
        let notifier = makeNotifier()
        notifier.process([session(.running)])
        notifier.process([session(.completed)])
        #expect(notifier.process([session(.completed)]).count == 1)

        notifier.process([session(.running)])
        notifier.process([session(.awaitingInput)])
        #expect(notifier.process([session(.awaitingInput)]).count == 1)
    }
}

/// A `running` report must not be discarded just because the log kept growing.
@Suite("Report authority")
struct ReportAuthorityTests {
    @Test("a running report expires sooner than a terminal one")
    func runningExpiresSooner() {
        let at = Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970
        let running = SessionReport(
            tool: "t", session: "s", event: "UserPromptSubmit",
            state: .running, at: at, cwd: nil
        )
        let ended = SessionReport(
            tool: "t", session: "s", event: "SessionEnd",
            state: .completed, at: at, cwd: nil
        )
        // Three hours in: a crashed "running" is no longer believable, but
        // "this ended" is still perfectly true.
        #expect(!running.isFresh)
        #expect(ended.isFresh)
    }

    @Test("a recent running report stays fresh through a long turn")
    func longTurnStaysRunning() {
        let report = SessionReport(
            tool: "t", session: "s", event: "UserPromptSubmit", state: .running,
            at: Date().addingTimeInterval(-25 * 60).timeIntervalSince1970, cwd: nil
        )
        // 25 minutes into a slow turn the session is still running.
        #expect(report.isFresh)
    }
}

/// The user heard the completion sound while a task was still running. The
/// cause was the `Notification` hook: it fires on `idle_prompt` mid-turn, and
/// any state that was not `running` counted as finished.
@Suite("Attention is not completion")
@MainActor
struct AttentionStateTests {
    private func session(_ state: SessionState) -> AgentSession {
        AgentSession(
            providerID: "p", nativeID: "a", title: "t", state: state,
            startedAt: .distantPast, updatedAt: Date()
        )
    }

    @Test("awaiting approval never rings the completion bell")
    func approvalDoesNotAlert() {
        let notifier = CompletionNotifier(
            settings: Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        notifier.process([session(.running)])
        // Blocked on a permission prompt: mid-task, not finished.
        #expect(notifier.process([session(.awaitingApproval)]).isEmpty)
        #expect(notifier.process([session(.awaitingApproval)]).isEmpty)
        #expect(notifier.flashing.isEmpty)
    }

    @Test("work resuming after an approval still alerts on the real finish")
    func finishAfterApproval() {
        let notifier = CompletionNotifier(
            settings: Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        notifier.process([session(.running)])
        notifier.process([session(.awaitingApproval)])
        notifier.process([session(.running)])
        notifier.process([session(.awaitingInput)])
        #expect(notifier.process([session(.awaitingInput)]).count == 1)
    }

    @Test("only genuine end states count as finished")
    func finishedStates() {
        #expect(SessionState.completed.isFinished)
        #expect(SessionState.awaitingInput.isFinished)
        #expect(SessionState.failed.isFinished)
        #expect(!SessionState.running.isFinished)
        // The one that caused the false alarms.
        #expect(!SessionState.awaitingApproval.isFinished)
        // It still deserves attention, just not a completion sound.
        #expect(SessionState.awaitingApproval.needsAttention)
    }

    @Test("the Notification hook is scoped to blocking types only")
    func notificationMatcherIsNarrow() {
        let notification = ClaudeCodeReporter.events.first { $0.event == "Notification" }
        let matcher = try! #require(notification?.matcher)
        // `idle_prompt` fires while a turn is still running and must not match.
        #expect(!matcher.contains("idle_prompt"))
        #expect(matcher.contains("permission_prompt"))
    }
}
