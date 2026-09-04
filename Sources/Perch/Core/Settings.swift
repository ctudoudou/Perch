import AppKit
import Observation
import SwiftUI

/// Which panel the expanded view is showing.
enum PanelTab: String, CaseIterable, Identifiable, Codable {
    case tasks
    case usage
    case stats
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .usage: "Usage"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .tasks: "list.bullet"
        case .usage: "chart.bar.fill"
        case .stats: "chart.xyaxis.line"
        case .settings: "gearshape.fill"
        }
    }

    /// Only the first three are reachable from the tab strip; settings has its
    /// own affordance so it does not compete with the everyday views.
    static var primary: [PanelTab] { [.tasks, .usage, .stats] }
}

/// Sound played when a task finishes. Values are macOS system sounds, so no
/// audio assets need shipping.
enum CompletionSound: String, CaseIterable, Identifiable, Codable {
    case none
    case glass = "Glass"
    case ping = "Ping"
    case pop = "Pop"
    case hero = "Hero"
    case submarine = "Submarine"

    var id: String { rawValue }

    var title: String { self == .none ? "None" : rawValue }

    func play() {
        guard self != .none, let sound = NSSound(named: rawValue) else { return }
        sound.play()
    }
}

/// User preferences, persisted to `UserDefaults`.
///
/// Everything here is observable, so toggling a setting updates the panel and
/// the notch immediately without a restart.
@MainActor
@Observable
final class Settings {
    /// Providers the user has explicitly switched off. Stored as a disabled-list
    /// rather than an enabled-list so a newly installed plugin appears by
    /// default instead of being silently invisible.
    var disabledProviders: Set<String> {
        didSet { defaults.set(Array(disabledProviders), forKey: Keys.disabledProviders) }
    }

    var notifySound: CompletionSound {
        didSet { defaults.set(notifySound.rawValue, forKey: Keys.notifySound) }
    }

    /// Flash the notch when a task completes.
    var notifyVisual: Bool {
        didSet { defaults.set(notifyVisual, forKey: Keys.notifyVisual) }
    }

    /// Post a system notification when a task completes.
    var notifyBanner: Bool {
        didSet { defaults.set(notifyBanner, forKey: Keys.notifyBanner) }
    }

    /// Hide sessions whose last activity is older than this many hours.
    var visibilityHours: Double {
        didSet { defaults.set(visibilityHours, forKey: Keys.visibilityHours) }
    }

    /// Show Codex subagent rollouts as their own rows.
    var showSubagents: Bool {
        didSet { defaults.set(showSubagents, forKey: Keys.showSubagents) }
    }

    /// Whether the user has been offered the Claude Code status-line helper.
    /// Asked once; declining is remembered.
    var statuslinePromptSeen: Bool {
        didSet { defaults.set(statuslinePromptSeen, forKey: Keys.statuslinePromptSeen) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let disabledProviders = "perch.disabledProviders"
        static let notifySound = "perch.notifySound"
        static let notifyVisual = "perch.notifyVisual"
        static let notifyBanner = "perch.notifyBanner"
        static let visibilityHours = "perch.visibilityHours"
        static let showSubagents = "perch.showSubagents"
        static let statuslinePromptSeen = "perch.statuslinePromptSeen"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledProviders = Set(defaults.stringArray(forKey: Keys.disabledProviders) ?? [])
        notifySound = defaults.string(forKey: Keys.notifySound)
            .flatMap(CompletionSound.init) ?? .glass
        // Alerts are on by default, as requested; `object(forKey:)` distinguishes
        // "never set" from an explicit false.
        notifyVisual = defaults.object(forKey: Keys.notifyVisual) as? Bool ?? true
        notifyBanner = defaults.object(forKey: Keys.notifyBanner) as? Bool ?? true
        visibilityHours = defaults.object(forKey: Keys.visibilityHours) as? Double ?? 8
        showSubagents = defaults.object(forKey: Keys.showSubagents) as? Bool ?? false
        statuslinePromptSeen = defaults.bool(forKey: Keys.statuslinePromptSeen)
    }

    func isEnabled(_ providerID: String) -> Bool {
        !disabledProviders.contains(providerID)
    }

    func setEnabled(_ enabled: Bool, for providerID: String) {
        if enabled {
            disabledProviders.remove(providerID)
        } else {
            disabledProviders.insert(providerID)
        }
    }
}
