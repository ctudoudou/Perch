import Foundation
import PerchKit

/// Runs a third-party plugin executable and parses its stdout as session JSON.
///
/// The process is sandboxed only by convention — it runs with the user's
/// privileges — so plugins are loaded exclusively from the user's own
/// Application Support directory, never downloaded or auto-installed.
struct ExternalPluginProvider: AgentProvider {
    let manifest: PluginManifest
    let directory: URL

    var id: String { manifest.id }
    var displayName: String { manifest.displayName }

    var appearance: ProviderAppearance {
        ProviderAppearance(
            symbolName: manifest.symbol,
            accent: Self.parseHex(manifest.accentHex) ?? (0.55, 0.55, 0.55)
        )
    }

    enum PluginError: LocalizedError {
        case timedOut(String)
        case nonZeroExit(String, Int32)
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case let .timedOut(id): "Plugin \(id) timed out"
            case let .nonZeroExit(id, code): "Plugin \(id) exited with code \(code)"
            case let .badOutput(id): "Plugin \(id) produced unreadable output"
            }
        }
    }

    func isAvailable() -> Bool {
        if let required = manifest.availabilityPath {
            let expanded = (required as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return false }
        }
        return FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false))
    }

    private var executableURL: URL {
        manifest.command.hasPrefix("/")
            ? URL(fileURLWithPath: manifest.command)
            : directory.appending(path: manifest.command)
    }

    func fetchSessions() async throws -> [AgentSession] {
        let output = try await runProbe()
        guard let data = output.data(using: .utf8), !data.isEmpty else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payloads = try decoder.decode([PluginSessionPayload].self, from: data)
            return payloads.map { $0.materialize(providerID: manifest.id) }
        } catch {
            throw PluginError.badOutput(manifest.id)
        }
    }

    private func runProbe() async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = manifest.arguments ?? []
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        let timeout = min(max(manifest.timeout ?? 5, 1), 30)
        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        defer { deadline.cancel() }

        // Drain before waiting: a plugin writing more than the pipe buffer would
        // otherwise block forever on a full pipe while we wait for it to exit.
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            throw PluginError.timedOut(manifest.id)
        }
        guard process.terminationStatus == 0 else {
            throw PluginError.nonZeroExit(manifest.id, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseHex(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Discovers plugin directories under Application Support.
enum PluginLoader {
    static var pluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Perch/Plugins", directoryHint: .isDirectory)
    }

    static func discover() -> [ExternalPluginProvider] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { directory in
            let manifestURL = directory.appending(path: "plugin.json")
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
            else { return nil }
            return ExternalPluginProvider(manifest: manifest, directory: directory)
        }
    }
}
