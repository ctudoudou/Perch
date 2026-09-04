import AppKit
import PerchKit
import UserNotifications

/// Watches session state across polls and alerts when work finishes.
///
/// The signal is a *transition*, not a state: a session that is already
/// finished when Perch launches must not fire, or every restart would replay
/// every completed task at once.
@MainActor
final class CompletionNotifier {
    /// Sessions that just finished and should flash in the notch.
    private(set) var flashing: Set<AgentSession.ID> = []

    private var lastStates: [AgentSession.ID: SessionState] = [:]
    /// Sessions seen to have finished, awaiting confirmation on the next poll.
    ///
    /// A single momentary reading must never alert. State can flicker for a
    /// beat — a log goes quiet during a slow tool call, a report lands a
    /// fraction late — and an alert fired on one sample is an alert the user
    /// cannot un-hear. Requiring the same finished state twice in a row costs
    /// one poll of latency and removes the whole class of false positives.
    private var pendingFinish: Set<AgentSession.ID> = []
    /// True until the first poll has been recorded, so the initial snapshot is
    /// treated as a baseline rather than as a burst of completions.
    private var isPrimed = false
    private var flashTasks: [AgentSession.ID: Task<Void, Never>] = [:]

    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    /// Ask for banner permission once. Declining is fine — sound and the visual
    /// flash work regardless.
    func requestAuthorizationIfNeeded() {
        guard settings.notifyBanner, Self.canPostBanners else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `UNUserNotificationCenter` traps rather than failing when the running
    /// binary has no bundle identifier — a plain executable, or a test host.
    /// Sound and the visual flash still work in that case.
    static let canPostBanners = Bundle.main.bundleIdentifier != nil

    /// Feed the latest poll. Returns the sessions that transitioned to finished.
    @discardableResult
    func process(_ sessions: [AgentSession]) -> [AgentSession] {
        var finished: [AgentSession] = []

        for session in sessions {
            let previous = lastStates[session.id]
            lastStates[session.id] = session.state

            guard isPrimed, let previous else { continue }

            guard session.state.isFinished else {
                // Running, or blocked on a prompt: either way not finished, so
                // anything we were about to announce was premature.
                pendingFinish.remove(session.id)
                continue
            }

            if !previous.isFinished {
                // The live→settled edge only *arms* the alert. Nothing fires
                // yet, so a one-poll flicker cannot reach the user.
                pendingFinish.insert(session.id)
            } else if pendingFinish.remove(session.id) != nil {
                // Still settled a poll later: the edge was real.
                finished.append(session)
            }
        }

        // Forget sessions that aged out, so a returning id can alert again.
        let live = Set(sessions.map(\.id))
        lastStates = lastStates.filter { live.contains($0.key) }
        pendingFinish = pendingFinish.filter { live.contains($0) }

        isPrimed = true
        for session in finished { alert(for: session) }
        return finished
    }

    private func alert(for session: AgentSession) {
        settings.notifySound.play()

        if settings.notifyVisual {
            flash(session.id)
        }

        if settings.notifyBanner, Self.canPostBanners {
            postBanner(for: session)
        }
    }

    /// Briefly mark the session so the notch can pulse.
    private func flash(_ id: AgentSession.ID) {
        flashTasks[id]?.cancel()
        flashing.insert(id)
        flashTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.flashing.remove(id)
            self?.flashTasks[id] = nil
        }
    }

    /// Notification category carrying an action, which is what keeps macOS
    /// from sliding the notification away on its own.
    private static let categoryIdentifier = "perch.completion"

    /// Register the category once. A notification with actions is presented as
    /// an alert that waits for the user, rather than a banner that disappears —
    /// provided the user has not forced Banner style for Perch in
    /// System Settings, which no API can override.
    static func registerCategories() {
        guard canPostBanners else { return }
        let open = UNNotificationAction(
            identifier: "perch.open",
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func postBanner(for session: AgentSession) {
        let content = UNMutableNotificationContent()
        content.title = session.state == .failed ? "Task failed" : "Task complete"
        content.subtitle = session.title
        content.categoryIdentifier = Self.categoryIdentifier
        // Time-sensitive notifications stay on screen and pierce Focus, which
        // is the closest an app can get to "persistent" on its own.
        content.interruptionLevel = .timeSensitive
        // A stable thread keeps repeated completions grouped rather than
        // stacking into a wall of separate alerts.
        content.threadIdentifier = session.providerID
        if let project = session.projectName {
            content.body = "\(project) · \(Format.tokens(session.usage.total)) tokens"
        }
        // The sound is played directly so it fires even when banners are denied.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "perch.\(session.id).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Test seam: pretend the baseline poll already happened.
    func prime(with states: [AgentSession.ID: SessionState]) {
        lastStates = states
        isPrimed = true
    }
}
