import Foundation

/// Installs a Codex `notify` program that pushes turn state to Perch.
///
/// Codex invokes a single configured program and appends one JSON argument
/// describing the event. The payload for a finished turn looks like:
///
///     {"type":"agent-turn-complete","turn-id":"…","thread-id":"…",
///      "input-messages":[…],"last-assistant-message":"…"}
///
/// Only one `notify` program can be configured, so Perch must *chain*: it
/// records the event and then execs whatever was configured before, with the
/// original arguments. Replacing an existing notify program outright would
/// silently break whatever depended on it.
enum CodexReporter {
    static let tool = "codex"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")
    }

    static func scriptURL(in store: ReportStore) -> URL {
        store.toolDirectory(tool).appending(path: "perch-notify.sh")
    }

    /// Where the previously configured notify command is preserved.
    static func chainURL(in store: ReportStore) -> URL {
        store.toolDirectory(tool).appending(path: "chained-notify")
    }

    static func installScript(in store: ReportStore) throws {
        try store.prepare(tools: [tool])
        let url = scriptURL(in: store)
        let script = #"""
        #!/bin/bash
        # Installed by Perch. Codex runs this on turn events, appending one
        # JSON argument. Perch records the event, then hands the same
        # arguments to whatever notify program was configured beforehand.
        dir="${PERCH_REPORT_DIR:-$HOME/Library/Application Support/Perch/Reports}/codex"
        mkdir -p "$dir"

        # The JSON payload is the final argument.
        payload="${!#}"

        field() {
          if command -v jq >/dev/null 2>&1; then
            printf '%s' "$payload" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
          else
            printf '%s' "$payload" \
              | /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
              | head -1
          fi
        }

        kind=$(field type)
        thread=$(field thread-id)

        if [ -n "$thread" ]; then
          # `agent-turn-complete` is the only event Codex emits today, and it
          # means the turn finished and the user is up.
          case "$kind" in
            agent-turn-complete) state="awaitingInput" ;;
            *)                   state="running" ;;
          esac
          tmp="$dir/$thread.json.tmp"
          printf '{"tool":"codex","session":"%s","event":"%s","state":"%s","at":%s}\n' \
            "$thread" "${kind:-unknown}" "$state" "$(date +%s)" > "$tmp"
          mv "$tmp" "$dir/$thread.json"
        fi

        # Hand off to the notify program Perch replaced, if there was one.
        chain="$dir/chained-notify"
        if [ -x "$chain" ]; then
          exec "$chain" "$@"
        fi
        exit 0
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    /// The `notify = [...]` array currently in config.toml, if any.
    static func currentNotify() -> [String]? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        guard let line = notifyLine(in: text) else { return nil }
        return parseArray(line)
    }

    /// Point Codex at Perch's script, preserving the previous program in a
    /// chain shim so it keeps receiving the same events and arguments.
    static func install(in store: ReportStore = .shared) throws {
        try installScript(in: store)
        let path = scriptURL(in: store).path(percentEncoded: false)

        if let existing = Self.withoutOurOwnReferences(currentNotify()),
           let program = existing.first, program != path {
            // Preserve the program *and* its fixed arguments; Codex appends the
            // JSON after them, so the shim must replay them in order.
            let quoted = existing.map { "\"\($0)\"" }.joined(separator: " ")
            let shim = "#!/bin/bash\n# Preserved by Perch; restored on uninstall.\nexec \(quoted) \"$@\"\n"
            let chain = chainURL(in: store)
            try shim.write(to: chain, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: chain.path(percentEncoded: false)
            )
        }

        try setNotify(to: [path])
    }

    /// Strip references to our own script from a notify command.
    ///
    /// Another tool may take the `notify` slot and preserve the previous
    /// program as an argument — Codex Computer Use records it as
    /// `--previous-notify '["…"]'`. When Perch re-takes the outer position,
    /// leaving that argument in place would either loop back into Perch or, if
    /// the path is from an older install, point at a script that no longer
    /// exists.
    static func withoutOurOwnReferences(_ command: [String]?) -> [String]? {
        guard let command, !command.isEmpty else { return command }
        var result: [String] = []
        var index = command.startIndex
        while index < command.endIndex {
            let argument = command[index]
            let isFlagForUs = argument == "--previous-notify"
                && command.index(after: index) < command.endIndex
                && mentionsOurScript(command[command.index(after: index)])
            if isFlagForUs {
                index = command.index(index, offsetBy: 2)
                continue
            }
            if mentionsOurScript(argument) {
                index = command.index(after: index)
                continue
            }
            result.append(argument)
            index = command.index(after: index)
        }
        return result.isEmpty ? nil : result
    }

    private static func mentionsOurScript(_ text: String) -> Bool {
        text.contains("perch-notify.sh") || text.contains("island-notify.sh")
    }

    static func uninstall(in store: ReportStore = .shared) throws {
        // Restore the original array from the shim, rather than guessing.
        if let shim = try? String(contentsOf: chainURL(in: store), encoding: .utf8),
           let line = shim.split(separator: "\n").first(where: { $0.hasPrefix("exec ") }) {
            let restored = parseQuoted(String(line.dropFirst(5)))
                .filter { $0 != "$@" }
            if !restored.isEmpty {
                try setNotify(to: restored)
                try? FileManager.default.removeItem(at: chainURL(in: store))
                try? FileManager.default.removeItem(at: scriptURL(in: store))
                return
            }
        }
        try removeNotify()
        try? FileManager.default.removeItem(at: scriptURL(in: store))
    }

    /// A notify program belonging to this app under either name.
    static var isInstalledUnderAnyName: Bool {
        guard let program = currentNotify()?.first else { return false }
        return program.contains("perch-notify.sh") || program.contains("island-notify.sh")
    }

    static func isInstalled(in store: ReportStore = .shared) -> Bool {
        currentNotify()?.first == scriptURL(in: store).path(percentEncoded: false)
    }

    // MARK: - config.toml editing
    //
    // Edited line-wise rather than through a TOML library: config.toml is the
    // user's file, full of comments and ordering they chose, and a re-serialised
    // document would silently discard all of it.

    private static func notifyLine(in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("notify") && trimmed.contains("=")
                    && !trimmed.hasPrefix("#")
            }
    }

    private static func setNotify(to values: [String]) throws {
        let encoded = values
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")
        try replaceNotify(with: "notify = [\(encoded)]")
    }

    private static func removeNotify() throws {
        try replaceNotify(with: nil)
    }

    private static func replaceNotify(with replacement: String?) throws {
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let index = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("notify") && trimmed.contains("=") && !trimmed.hasPrefix("#")
        }) {
            if let replacement {
                lines[index] = replacement
            } else {
                lines.remove(at: index)
            }
        } else if let replacement {
            // `notify` is a root key, so it must precede the first table header
            // or TOML would read it as belonging to that table.
            let insertAt = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(replacement, at: insertAt)
        }

        try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Parse `notify = ["a", "b"]` into its elements.
    static func parseArray(_ line: String) -> [String] {
        guard
            let open = line.firstIndex(of: "["),
            let close = line.lastIndex(of: "]"),
            open < close
        else { return [] }
        return parseQuoted(String(line[line.index(after: open) ..< close]))
    }

    /// Pull double-quoted items out of a fragment, honouring backslash escapes.
    static func parseQuoted(_ fragment: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in fragment {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                if inQuotes { items.append(current); current = "" }
                inQuotes.toggle()
            } else if inQuotes {
                current.append(character)
            }
        }
        return items
    }
}
