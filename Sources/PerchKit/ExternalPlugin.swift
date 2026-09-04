import Foundation

/// Manifest for an out-of-process plugin, read from `plugin.json` inside a
/// plugin directory. This is the extension path that does not require writing
/// Swift: ship an executable that prints JSON on stdout.
///
/// Layout:
/// ```
/// ~/Library/Application Support/Perch/Plugins/
///   my-agent/
///     plugin.json
///     probe            (any executable)
/// ```
public struct PluginManifest: Codable, Sendable {
    /// Unique provider id.
    public var id: String
    public var displayName: String
    /// SF Symbol name.
    public var symbol: String
    /// Hex accent color, e.g. `#FF8800`.
    public var accentHex: String
    /// Executable to run, relative to the plugin directory (or absolute).
    public var command: String
    /// Arguments passed to the executable.
    public var arguments: [String]?
    /// Seconds before the probe is killed. Defaults to 5, clamped to 1...30.
    public var timeout: Double?
    /// Optional path that must exist for the plugin to be considered available.
    public var availabilityPath: String?

    public init(
        id: String,
        displayName: String,
        symbol: String = "sparkles",
        accentHex: String = "#888888",
        command: String,
        arguments: [String]? = nil,
        timeout: Double? = nil,
        availabilityPath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
        self.accentHex = accentHex
        self.command = command
        self.arguments = arguments
        self.timeout = timeout
        self.availabilityPath = availabilityPath
    }
}

/// What a plugin executable is expected to print on stdout: a JSON array of
/// sessions. Field names match `AgentSession`'s coding keys, but `id` and
/// `providerID` are filled in by Perch, so a plugin only supplies `nativeID`.
public struct PluginSessionPayload: Codable, Sendable {
    public var nativeID: String
    public var title: String
    public var workingDirectory: String?
    public var branch: String?
    public var model: String?
    public var state: SessionState
    public var usage: TokenUsage?
    public var transcript: [TranscriptEntry]?
    public var startedAt: Date?
    public var updatedAt: Date?
    /// One of: `pid:1234`, `bundle:com.example.App`, `url:https://…`, `file:/path`.
    public var target: String?

    public init(nativeID: String, title: String, state: SessionState) {
        self.nativeID = nativeID
        self.title = title
        self.state = state
    }

    /// Convert to a full session, applying the provider's identity.
    public func materialize(providerID: String) -> AgentSession {
        AgentSession(
            providerID: providerID,
            nativeID: nativeID,
            title: title,
            workingDirectory: workingDirectory.map { URL(fileURLWithPath: $0) },
            branch: branch,
            model: model,
            state: state,
            usage: usage ?? .init(),
            transcript: transcript ?? [],
            startedAt: startedAt ?? Date(),
            updatedAt: updatedAt ?? Date(),
            target: Self.parseTarget(target)
        )
    }

    static func parseTarget(_ raw: String?) -> SessionTarget? {
        guard let raw, let separator = raw.firstIndex(of: ":") else { return nil }
        let scheme = String(raw[raw.startIndex ..< separator])
        let value = String(raw[raw.index(after: separator)...])
        switch scheme {
        case "pid":
            guard let pid = pid_t(value) else { return nil }
            return .processIdentifier(pid)
        case "bundle":
            return .bundleIdentifier(value)
        case "url":
            return URL(string: value).map { .url($0) }
        case "file":
            return .revealFile(URL(fileURLWithPath: value))
        default:
            return nil
        }
    }
}
