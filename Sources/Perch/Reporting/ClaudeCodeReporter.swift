import Foundation

/// Installs Claude Code hooks that push session state to Perch.
///
/// Claude Code's own lifecycle events are the only accurate source of task
/// state. Perch's log parsing has to infer "running" from a file's
/// modification time, which cannot distinguish a model that is thinking from
/// one that finished thirty seconds ago. A hook fires *at* the transition and
/// says which one it was.
///
/// Event → state mapping (see https://code.claude.com/docs/en/hooks):
///   SessionStart      → the session exists but has done nothing yet
///   UserPromptSubmit  → running; the user just handed over a turn
///   Stop              → awaitingInput; the turn ended normally
///   Notification      → awaitingApproval; Claude Code is blocked on the user
///   SessionEnd        → completed
enum ClaudeCodeReporter {
    static let tool = "claude-code"

    /// Events Perch subscribes to, with the state each implies and the
    /// notification types it applies to.
    ///
    /// `Notification` covers far more than "blocked on the user" — it also
    /// fires on `idle_prompt`, which happens *while a turn is still running*.
    /// Subscribing to all of it made Perch mark a busy session as waiting, and
    /// the completion alert then announced a task that had not finished. The
    /// matcher narrows it to the types that really do block.
    static let events: [(event: String, state: String, matcher: String)] = [
        ("SessionStart", "awaitingInput", ""),
        ("UserPromptSubmit", "running", ""),
        ("Stop", "awaitingInput", ""),
        ("Notification", "awaitingApproval", "permission_prompt|agent_needs_input"),
        ("SessionEnd", "completed", ""),
    ]

    static func scriptURL(in store: ReportStore) -> URL {
        store.toolDirectory(tool).appending(path: "perch-report.sh")
    }

    /// Write the hook script. It takes the event name as its only argument and
    /// reads the hook payload on stdin.
    static func installScript(in store: ReportStore) throws {
        try store.prepare(tools: [tool])
        let url = scriptURL(in: store)
        let script = #"""
        #!/bin/bash
        # Installed by Perch. Claude Code runs this on lifecycle events and
        # pipes the hook payload on stdin; Perch reads the result to show
        # accurate task state instead of guessing from file timestamps.
        # Removing the hooks from settings.json disables it cleanly.
        event="$1"
        state="$2"
        dir="${PERCH_REPORT_DIR:-$HOME/Library/Application Support/Perch/Reports}/claude-code"
        mkdir -p "$dir"

        payload=$(cat)

        # jq when available; a tolerant sed fallback keeps the hook working on a
        # machine without it. Both accept whitespace after the colon.
        field() {
          if command -v jq >/dev/null 2>&1; then
            printf '%s' "$payload" | jq -r --arg k "$1" '.[$k] // empty'
          else
            printf '%s' "$payload" \
              | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
              | head -1
          fi
        }

        session=$(field session_id)
        [ -z "$session" ] && exit 0
        cwd=$(field cwd)

        tmp="$dir/$session.json.tmp"
        printf '{"tool":"claude-code","session":"%s","event":"%s","state":"%s","at":%s,"cwd":"%s"}\n' \
          "$session" "$event" "$state" "$(date +%s)" "$cwd" > "$tmp"
        mv "$tmp" "$dir/$session.json"

        # Hooks must stay silent and succeed: a non-zero exit or stray output
        # would surface inside the user's session.
        exit 0
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    /// Add Perch's hooks to `settings.json`, leaving any existing hooks in place.
    static func install(in store: ReportStore = .shared) throws {
        try installScript(in: store)
        let path = scriptURL(in: store).path(percentEncoded: false)

        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, state, matcher) in events {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            // Replace only Perch's own entry so a user's hooks for the same
            // event survive untouched.
            matchers.removeAll { isPerchMatcher($0) }
            matchers.append([
                "matcher": matcher,
                "hooks": [[
                    "type": "command",
                    "command": "\"\(path)\" \(event) \(state)",
                ]],
            ])
            hooks[event] = matchers
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// Remove only Perch's hooks.
    static func uninstall(in store: ReportStore = .shared) throws {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for (event, _, _) in events {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            matchers.removeAll { isPerchMatcher($0) }
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: scriptURL(in: store))
    }

    /// Hooks belonging to this app under either name.
    static var isInstalledUnderAnyName: Bool {
        guard
            let hooks = readSettings()["hooks"] as? [String: Any],
            let matchers = hooks["Stop"] as? [[String: Any]]
        else { return false }
        return matchers.contains { matcher in
            guard let commands = matcher["hooks"] as? [[String: Any]] else { return false }
            return commands.contains { command in
                let text = (command["command"] as? String) ?? ""
                return text.contains("perch-report.sh") || text.contains("island-report.sh")
            }
        }
    }

    static func isInstalled(in store: ReportStore = .shared) -> Bool {
        guard
            let hooks = readSettings()["hooks"] as? [String: Any],
            let matchers = hooks["Stop"] as? [[String: Any]]
        else { return false }
        return matchers.contains(where: isPerchMatcher)
    }

    /// Perch's entries are identified by the script they invoke, so a user's
    /// hooks are never mistaken for ours.
    private static func isPerchMatcher(_ matcher: [String: Any]) -> Bool {
        guard let commands = matcher["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { command in
            let text = (command["command"] as? String) ?? ""
            // Both spellings: an entry left by the app's previous name is still
            // ours, and must be replaced rather than left beside the new one.
            // Missing this appended a second hook per event and left the old
            // one pointing at a script that no longer existed, so every event
            // ran a missing file.
            return text.contains("perch-report.sh") || text.contains("island-report.sh")
        }
    }

    private static func readSettings() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
