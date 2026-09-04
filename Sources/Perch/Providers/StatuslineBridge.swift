import Foundation
import PerchKit

/// Reads live session facts that Claude Code publishes only to its status line.
///
/// Rate limits and the real context-window size arrive as
/// `anthropic-ratelimit-unified-*` response headers and are never written to
/// the session log, so they cannot be recovered by parsing `.jsonl` at all.
/// Claude Code does expose them — as documented JSON on stdin to a `statusLine`
/// command — so Perch installs a tiny writer script that snapshots that JSON
/// per session, and reads the snapshots here.
///
/// See https://code.claude.com/docs/en/statusline for the schema.
struct StatuslineSnapshot: Decodable {
    struct ContextWindow: Decodable {
        var total_input_tokens: Int?
        var total_output_tokens: Int?
        var context_window_size: Int?
        var used_percentage: Double?
    }

    struct Window: Decodable {
        var used_percentage: Double
        var resets_at: Double?
    }

    /// Decoded as an open map rather than three fixed fields.
    ///
    /// The public schema documents `five_hour`, `seven_day` and `spend_limit`,
    /// but accounts on some plans also receive per-model weekly buckets
    /// (`seven_day_opus` and friends) that the docs do not list. Hardcoding the
    /// documented three silently drops those, which is the same class of bug as
    /// showing one Codex bucket and hiding the rest.
    typealias RateLimits = [String: Window]

    struct Cost: Decodable {
        var total_cost_usd: Double?
        var total_duration_ms: Double?
        var total_lines_added: Int?
        var total_lines_removed: Int?
    }

    struct Model: Decodable {
        var id: String?
        var display_name: String?
    }

    var session_id: String?
    var model: Model?
    var context_window: ContextWindow?
    var rate_limits: RateLimits?
    var cost: Cost?
    var exceeds_200k_tokens: Bool?

    /// Quota windows in the shape Perch displays, shortest first.
    /// Staleness is handled by `StatuslineStore`, which withholds old snapshots
    /// entirely rather than letting last hour's percentages reach the UI.
    var windows: [RateLimitWindow] { windows(observedAt: nil) }

    /// Windows, tagged with when the reading was taken so the UI can caption
    /// an ageing one rather than passing it off as current.
    func windows(observedAt: Date?) -> [RateLimitWindow] {
        guard let rate_limits else { return [] }

        return rate_limits.compactMap { key, window -> RateLimitWindow? in
            // "Claude Code drops a window once its resets_at time passes."
            // A window that has already reset shows last period's usage, so it
            // must disappear rather than linger at a stale percentage.
            if let resets = window.resets_at, resets <= Date().timeIntervalSince1970 {
                return nil
            }
            let (name, minutes, bucket) = Self.describe(key)
            return RateLimitWindow(
                name: name,
                usedFraction: window.used_percentage / 100,
                windowMinutes: minutes,
                resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) },
                bucket: bucket,
                observedAt: observedAt
            )
        }
        .sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
    }

    /// Turn a rate-limit key into a label, window length and bucket.
    /// Unknown keys are humanised rather than dropped.
    static func describe(_ key: String) -> (name: String, minutes: Int?, bucket: String) {
        switch key {
        case "five_hour": return ("5h", 300, "Subscription")
        case "seven_day": return ("7d", 10_080, "Subscription")
        case "spend_limit": return ("Spend", nil, "Spend limit")
        default:
            // e.g. `seven_day_opus` → a weekly window in an "Opus" bucket.
            if key.hasPrefix("seven_day_") {
                let model = key.dropFirst("seven_day_".count)
                return ("7d", 10_080, model.capitalized)
            }
            if key.hasPrefix("five_hour_") {
                let model = key.dropFirst("five_hour_".count)
                return ("5h", 300, model.capitalized)
            }
            return (key.replacingOccurrences(of: "_", with: " "), nil, "Subscription")
        }
    }
}

/// Locates and reads the snapshots the helper writes.
///
/// A value type holding its own directory, deliberately not a global: tests
/// construct their own store pointed at a temporary directory. An earlier
/// version exposed a mutable static path, a test wrote a fixture into the real
/// one, and Perch then displayed that fixture's invented percentages as
/// though they were live quota.
struct StatuslineStore: Sendable {
    var directory: URL

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Perch/Statusline", directoryHint: .isDirectory)

    /// The store Perch itself uses.
    static let shared = StatuslineStore(directory: defaultDirectory)

    var helperURL: URL {
        directory.appending(path: "perch-statusline.sh")
    }

    /// How long a snapshot is kept at all.
    ///
    /// Deliberately generous. The status line only runs while Claude Code is
    /// rendering one, so a short cutoff meant quota disappeared minutes after
    /// the last session ended — the tool was still installed, still had an
    /// allowance, and Perch simply went blank. Readings are kept and captioned
    /// with their age instead; a window past its own reset is dropped
    /// separately, which is what actually makes a reading meaningless.
    static let freshness: TimeInterval = 12 * 3600

    /// Snapshot for a session, when one was written recently enough to trust.
    func snapshot(sessionID: String) -> StatuslineSnapshot? {
        read(directory.appending(path: "\(sessionID).json"))?.snapshot
    }

    /// Newest trustworthy snapshot from any session. Quota is account-wide, so
    /// whichever session reported it most recently describes the account.
    func newestSnapshot() -> StatuslineSnapshot? {
        newest()?.snapshot
    }

    /// When the newest snapshot was written, for showing the user how current
    /// the numbers are.
    func newestObservedAt() -> Date? {
        newest()?.observedAt
    }

    /// The newest quota reading from *any* session that actually has one.
    ///
    /// Limits describe the account, not the session, and a snapshot only
    /// carries them once that session has had an API response — a session that
    /// has just started reports `rate_limits: null`. Taking limits from the
    /// newest snapshot regardless would therefore blank out perfectly good
    /// numbers the moment a new session appeared.
    func newestWindows() -> [RateLimitWindow] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read($0) }
            .sorted { $0.observedAt > $1.observedAt }
            .lazy
            .map { $0.snapshot.windows(observedAt: $0.observedAt) }
            .first { !$0.isEmpty } ?? []
    }

    private func newest() -> (snapshot: StatuslineSnapshot, observedAt: Date)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read($0) }
            .max { $0.observedAt < $1.observedAt }
    }

    private func read(_ url: URL) -> (snapshot: StatuslineSnapshot, observedAt: Date)? {
        guard
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
            Date().timeIntervalSince(modified) < Self.freshness,
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(StatuslineSnapshot.self, from: data)
        else { return nil }
        return (snapshot, modified)
    }

    /// Wrap a path for a shell so spaces survive.
    ///
    /// Single quotes are literal in POSIX shells, so only an embedded single
    /// quote needs special handling.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Why quota is missing, in the user's terms.
    ///
    /// Limits reach Perch only through a rendered status line, and only once
    /// that session has had an API response. Hosts that draw their own chrome
    /// may never invoke the command at all.
    var explanation: String {
        if !isInstalled {
            return "Enable the status-line helper in Settings to show limits."
        }
        if hasData {
            return "Waiting for a fresh reading."
        }
        return "Limits arrive with Claude Code's status line, which only some hosts render. Run `claude` in Terminal once and they appear here."
    }

    /// Claude Code's user settings, where the status line is configured.
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/settings.json")

    /// True when a status line is configured that belongs to this app under
    /// either its current or its former name, so an upgrade can re-point it.
    var isInstalledUnderAnyName: Bool {
        guard
            let data = try? Data(contentsOf: Self.settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let line = settings["statusLine"] as? [String: Any],
            let command = line["command"] as? String
        else { return false }
        return command.contains("perch-statusline.sh") || command.contains("island-statusline.sh")
    }

    /// Whether the helper is installed and has produced anything.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path(percentEncoded: false))
    }

    /// True only when a *fresh* snapshot exists. A directory full of stale files
    /// is not data.
    var hasData: Bool {
        newest() != nil
    }

    /// Point Claude Code's settings at the helper, preserving any status line
    /// the user already had by chaining to it rather than replacing it.
    func configureClaudeCode() throws {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        let helperPath = helperURL.path(percentEncoded: false)
        if let current = settings["statusLine"] as? [String: Any],
           let command = current["command"] as? String,
           command != helperPath,
           command != Self.shellQuoted(helperPath) {
            // Preserve the user's own status line: the helper execs it after
            // taking its snapshot, so their display is unchanged.
            let preserved = directory.appending(path: "user-statusline")
            let shim = "#!/bin/bash\nexec \(command)\n"
            try? shim.write(to: preserved, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: preserved.path(percentEncoded: false)
            )
        }

        // `refreshInterval` re-runs the command on a timer as well as on
        // events. The docs recommend it exactly for externally-sourced data:
        // without it the event triggers go quiet while a session sits idle and
        // Perch's snapshot silently ages out of its freshness window.
        settings["statusLine"] = [
            "type": "command",
            // Quoted: the command is run through a shell, and Perch's own
            // path contains spaces ("Application Support"). Unquoted, the
            // shell split it and the helper never ran at all — which is why
            // quota stayed empty even in sessions that do render a status line.
            "command": Self.shellQuoted(helperPath),
            "refreshInterval": 60,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: Self.settingsURL, options: .atomic)
    }

    /// Remove the helper and restore whatever status line was there before.
    func uninstall() throws {
        guard
            let data = try? Data(contentsOf: Self.settingsURL),
            var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let preserved = directory.appending(path: "user-statusline")
        if let restored = try? String(contentsOf: preserved, encoding: .utf8),
           let command = restored
               .split(separator: "\n")
               .first(where: { $0.hasPrefix("exec ") })?
               .dropFirst(5) {
            settings["statusLine"] = ["type": "command", "command": String(command)]
            try? FileManager.default.removeItem(at: preserved)
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        let updated = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: Self.settingsURL, options: .atomic)
        try? FileManager.default.removeItem(at: helperURL)
    }

    /// Write the helper script. It is deliberately trivial: snapshot stdin to a
    /// per-session file, then print nothing, so a user who already has a status
    /// line keeps theirs by chaining to it.
    func installHelper() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # Installed by Perch (https://github.com/…) to read Claude Code's
        # documented status-line JSON, which carries rate limits and the real
        # context-window size. Those arrive as API response headers and are
        # never written to session logs, so this is the only supported way to
        # see them. Removing this file simply stops Perch showing quota.
        input=$(cat)
        # PERCH_STATUSLINE_DIR lets Perch's own tests exercise this exact
        # script without writing into the user's real snapshot directory.
        dir="${PERCH_STATUSLINE_DIR:-$HOME/Library/Application Support/Perch/Statusline}"
        mkdir -p "$dir"
        # Tolerate whitespace after the colon: the payload is not guaranteed to
        # be compact JSON. Prefer jq when available, and fall back to sed so the
        # helper still works on a machine without it.
        if command -v jq >/dev/null 2>&1; then
          id=$(printf '%s' "$input" | jq -r '.session_id // empty')
        else
          id=$(printf '%s' "$input" \\
            | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' \\
            | head -1)
        fi
        [ -z "$id" ] && id="unknown"
        printf '%s' "$input" > "$dir/$id.json.tmp" && mv "$dir/$id.json.tmp" "$dir/$id.json"

        # Chain to a user status line if one was configured before Perch.
        if [ -x "$dir/user-statusline" ]; then
          printf '%s' "$input" | "$dir/user-statusline"
        fi
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path(percentEncoded: false)
        )
    }
}
