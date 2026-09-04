import Foundation
import PerchKit

/// A state report pushed by a tool, rather than inferred by Perch.
///
/// Perch's log parsing can only ever guess at task state — it reads file
/// timestamps and the shape of the last record. Both Claude Code and Codex can
/// instead *tell* Perch what happened, through their own extension points
/// (hooks and `notify`). A report is that telling: authoritative, timestamped,
/// and written at the moment the event occurred.
struct SessionReport: Codable, Sendable {
    /// Provider id this belongs to, e.g. `claude-code`.
    var tool: String
    /// The tool's own session identifier.
    var session: String
    /// The tool's event name, kept verbatim for diagnostics.
    var event: String
    /// Normalised state at the moment of the event.
    var state: SessionState
    /// Unix seconds when the reporter ran.
    var at: Double
    var cwd: String?

    var timestamp: Date { Date(timeIntervalSince1970: at) }

    /// How long a report stays authoritative.
    ///
    /// Terminal states are safe to trust for a long time — nothing contradicts
    /// "this session ended". A `running` report is riskier: if the tool crashed
    /// before it could report the end, the session would look busy forever, so
    /// it gets a tighter bound. Within that bound it is trusted outright — the
    /// point of an event is that it holds until the next event, not until a
    /// timer guesses otherwise.
    static let maxAge: TimeInterval = 6 * 3600
    static let maxAgeWhileRunning: TimeInterval = 2 * 3600

    var isFresh: Bool {
        let limit = state.isActive ? Self.maxAgeWhileRunning : Self.maxAge
        return Date().timeIntervalSince(timestamp) < limit
    }

}

/// Reads the reports that tools push, and notifies when they change.
///
/// The transport is deliberately the filesystem: a hook is a short-lived
/// process that must not block on a socket handshake, reports survive Perch
/// being closed, and nothing is lost if Perch starts late. Perch watches the
/// directory, so updates still arrive the moment they are written.
final class ReportStore: @unchecked Sendable {
    static let shared = ReportStore(directory: defaultDirectory)

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Perch/Reports", directoryHint: .isDirectory)

    let directory: URL

    private var watchers: [DispatchSourceFileSystemObject] = []
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    func toolDirectory(_ tool: String) -> URL {
        directory.appending(path: tool, directoryHint: .isDirectory)
    }

    /// Every fresh report for a tool, keyed by session id.
    func reports(for tool: String) -> [String: SessionReport] {
        let toolDirectory = toolDirectory(tool)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: toolDirectory, includingPropertiesForKeys: nil
        ) else { return [:] }

        var result: [String: SessionReport] = [:]
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let report = try? JSONDecoder().decode(SessionReport.self, from: data),
                report.isFresh
            else { continue }
            // Keep the newest report per session; a tool may write several.
            if let existing = result[report.session], existing.at >= report.at { continue }
            result[report.session] = report
        }
        return result
    }

    /// Ensure the directory tree exists so reporters never race on mkdir.
    func prepare(tools: [String]) throws {
        for tool in tools {
            try FileManager.default.createDirectory(
                at: toolDirectory(tool), withIntermediateDirectories: true
            )
        }
    }

    /// Call `onChange` whenever a report lands. Watching the directories means
    /// a pushed event reaches the UI immediately rather than at the next poll.
    func startWatching(tools: [String], onChange: @escaping @Sendable () -> Void) {
        stopWatching()
        try? prepare(tools: tools)

        lock.lock()
        defer { lock.unlock() }

        for tool in tools {
            let path = toolDirectory(tool).path(percentEncoded: false)
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib],
                queue: .main
            )
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    func stopWatching() {
        lock.lock()
        defer { lock.unlock() }
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
    }

    /// Drop reports for sessions that no longer exist, so the directory does not
    /// grow without bound.
    func prune(tool: String, keeping live: Set<String>) {
        let toolDirectory = toolDirectory(tool)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: toolDirectory, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            let session = file.deletingPathExtension().lastPathComponent
            guard !live.contains(session) else { continue }
            guard
                let data = try? Data(contentsOf: file),
                let report = try? JSONDecoder().decode(SessionReport.self, from: data),
                !report.isFresh
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
