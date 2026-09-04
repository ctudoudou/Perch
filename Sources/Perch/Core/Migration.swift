import Foundation

/// Moves an earlier install's on-disk state to the current name.
///
/// The app was called Island before it was called Perch. Its support directory,
/// helper scripts and the paths written into `~/.claude/settings.json` and
/// `~/.codex/config.toml` all carried the old name, so a rename alone would
/// leave those configs pointing at files that no longer exist — the
/// integrations would fail silently, which is the worst way for them to fail.
enum Migration {
    private static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Island", directoryHint: .isDirectory)
    }

    private static var currentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Perch", directoryHint: .isDirectory)
    }

    /// Whether anything from the old name is still on disk or referenced.
    static var isNeeded: Bool {
        FileManager.default.fileExists(atPath: legacyDirectory.path(percentEncoded: false))
            || configuredPathsMentionLegacy
    }

    private static var configuredPathsMentionLegacy: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [".claude/settings.json", ".codex/config.toml"] {
            guard let text = try? String(contentsOf: home.appending(path: path), encoding: .utf8)
            else { continue }
            if text.contains("Application Support/Island") { return true }
        }
        return false
    }

    /// Re-point every integration at the new location.
    ///
    /// Reinstalling is deliberate rather than rewriting the paths in place: the
    /// installers already know how to preserve a user's own hooks and notify
    /// program, so reusing them keeps that guarantee instead of duplicating it.
    static func run() {
        guard isNeeded else { return }

        // Carry over captured snapshots so quota does not blank out on upgrade.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: legacyDirectory.path(percentEncoded: false)) {
            try? fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
            for name in ["Statusline", "Reports"] {
                let source = legacyDirectory.appending(path: name)
                let destination = currentDirectory.appending(path: name)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)),
                      !fileManager.fileExists(atPath: destination.path(percentEncoded: false))
                else { continue }
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        // Rewrite the configs by reinstalling only what was already enabled.
        if StatuslineStore.shared.isInstalledUnderAnyName {
            try? StatuslineStore.shared.installHelper()
            try? StatuslineStore.shared.configureClaudeCode()
        }
        if ClaudeCodeReporter.isInstalledUnderAnyName {
            try? ClaudeCodeReporter.install()
        }
        if CodexReporter.isInstalledUnderAnyName {
            try? CodexReporter.install()
        }

        // Only remove the old tree once nothing points into it.
        if !configuredPathsMentionLegacy {
            try? fileManager.removeItem(at: legacyDirectory)
        }
    }
}
