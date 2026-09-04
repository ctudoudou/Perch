import SwiftUI
import PerchKit

extension ProviderAppearance {
    var color: Color {
        Color(.sRGB, red: accent.red, green: accent.green, blue: accent.blue)
    }
}

extension SessionState {
    var tint: Color {
        switch self {
        case .running: .cyan
        case .awaitingInput: .yellow
        case .awaitingApproval: .orange
        case .completed: .green
        case .failed: .red
        }
    }

    var label: String {
        switch self {
        case .running: "Working"
        case .awaitingInput: "Your turn"
        case .awaitingApproval: "Needs approval"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "circle.dotted"
        case .awaitingInput: "arrow.turn.down.left"
        case .awaitingApproval: "hand.raised.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum Format {
    /// Compact token counts: 1_234 → "1.2k", 1_234_567 → "1.2M".
    static func tokens(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: "%.1fk", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    static func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 5 { return "now" }
        return duration(elapsed) + " ago"
    }
}


/// The notch panel is always dark, whatever the system appearance is set to,
/// so SwiftUI's `.secondary` / `.tertiary` hierarchy styles resolve against the
/// wrong background and come out nearly invisible. These are explicit instead.
enum Palette {
    /// Primary content on the dark panel.
    static let primary = Color.white.opacity(0.95)
    /// Supporting values that should still read easily.
    static let secondary = Color.white.opacity(0.62)
    /// Field labels and de-emphasised metadata.
    static let label = Color.white.opacity(0.45)
    /// Row background, and the panel fill itself.
    static let panel = Color(white: 0.055)
}

extension Format {
    /// 22 → "10 PM".
    static func hour(_ hour: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(suffix)"
    }

    /// "Sep 4" — compact enough for an axis label.
    static func shortDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    /// A human yardstick for an otherwise abstract token count.
    static func comparison(_ tokens: Int) -> String {
        // ~170k tokens for the novel, a familiar unit of "a lot of text".
        let novels = Double(tokens) / 170_000
        if novels >= 1 {
            return String(format: "About %.0f× the text of a novel.", novels)
        }
        return String(format: "About %.0f%% of a novel's text.", novels * 100)
    }
}

extension Format {
    /// Spend, as reported by the tool. Small amounts keep cents visible.
    static func money(_ usd: Double) -> String {
        usd < 10
            ? String(format: "$%.2f", usd)
            : String(format: "$%.0f", usd)
    }
}
