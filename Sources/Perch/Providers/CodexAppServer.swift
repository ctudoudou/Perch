import Foundation
import PerchKit

/// Queries Codex for its live quota through the app-server protocol.
///
/// Rate limits scraped from rollout logs are whatever the last session happened
/// to observe — often hours stale, and only ever for the one bucket that
/// session's model drew from. Codex exposes the real thing: `codex app-server`
/// speaks JSON-RPC on stdio, and `account/rateLimits/read` returns every bucket
/// at once, current as of the call.
///
/// The protocol is discoverable rather than guessed — `codex app-server
/// generate-json-schema` emits the full contract, including
/// `AccountRateLimitsUpdatedNotification` and the `RateLimitWindow` shape used
/// here.
struct CodexAppServer: Sendable {
    /// Live quota is re-read at most this often: each read spawns a process, so
    /// it must not run on the UI's two-second poll.
    static let refreshInterval: TimeInterval = 90
    /// A single read is abandoned after this long rather than hanging a refresh.
    static let timeout: TimeInterval = 20

    private let executable: URL?

    init(executable: URL? = CodexAppServer.locateExecutable()) {
        self.executable = executable
    }

    var isAvailable: Bool { executable != nil }

    /// Homebrew, a manual install, or wherever `codex` happens to live.
    static func locateExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".local/bin/codex").path(percentEncoded: false),
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return which("codex")
    }

    private static func which(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Response shape

    private struct Window: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: Double?
    }

    private struct Snapshot: Decodable {
        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
    }

    private struct Result: Decodable {
        var rateLimits: Snapshot?
        /// Every bucket the account has, keyed by its id. This is what makes a
        /// per-model bucket visible alongside the general allowance.
        var rateLimitsByLimitId: [String: Snapshot]?
    }

    /// Read every quota window Codex reports. Returns `nil` when Codex is not
    /// installed or did not answer, so the caller can fall back rather than
    /// display a fabricated zero.
    func readRateLimits() async -> [RateLimitWindow]? {
        guard let executable else { return nil }
        guard let result = await request(executable: executable) else { return nil }

        // Prefer the keyed map: it carries every bucket. The bare `rateLimits`
        // is only the currently-limiting one, and would hide the others.
        let snapshots = result.rateLimitsByLimitId.map { Array($0.values) }
            ?? result.rateLimits.map { [$0] }
            ?? []

        var windows: [RateLimitWindow] = []
        for snapshot in snapshots {
            let bucket = snapshot.limitName
                ?? (snapshot.limitId == "codex" ? "General" : snapshot.limitId)
                ?? "General"
            for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
                // A window whose reset has passed describes the period before
                // this one; showing it would misstate what is left.
                if let resets = window.resetsAt, resets <= Date().timeIntervalSince1970 {
                    continue
                }
                windows.append(
                    RateLimitWindow(
                        name: window.windowDurationMins.map(CodexProvider.windowLabel) ?? "Window",
                        usedFraction: window.usedPercent / 100,
                        windowMinutes: window.windowDurationMins,
                        resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                        bucket: bucket
                    )
                )
            }
        }
        // General allowance first, then per-model buckets; shortest window
        // first within each, since that is the one that bites soonest.
        return windows.sorted {
            let (lhs, rhs) = ($0.bucket ?? "", $1.bucket ?? "")
            if lhs != rhs {
                if lhs == "General" { return true }
                if rhs == "General" { return false }
                return lhs < rhs
            }
            return ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0)
        }
    }

    /// Run one request/response against a short-lived app-server.
    ///
    /// A fresh process per read, rather than a long-lived daemon: Perch must
    /// not leave a Codex server running, and the read is infrequent enough that
    /// the spawn cost does not matter.
    private func request(executable: URL) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(executable: executable))
            }
        }
    }

    private static func runBlocking(executable: URL) -> Result? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }

        // The server expects an initialize handshake before it will answer.
        let requests = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"perch","title":"Perch","version":"0.1.0"}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#,
        ]
        for request in requests {
            input.fileHandleForWriting.write(Data((request + "\n").utf8))
        }

        // Read until the answer to id 1 arrives, the process exits, or we give up.
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var result: Result?

        while Date() < deadline, result == nil {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                guard process.isRunning else { break }
                continue
            }
            buffer.append(chunk)

            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex ..< index])
                buffer.removeSubrange(buffer.startIndex ... index)
                if let decoded = decodeResult(line) {
                    result = decoded
                    break
                }
            }
        }

        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // The server is a child process; reap it so it cannot linger.
        process.waitUntilExit()
        return result
    }

    /// A JSON-RPC line is ours only if it answers request id 1.
    private static func decodeResult(_ line: Data) -> Result? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            (object["id"] as? Int) == 1,
            let payload = object["result"],
            let data = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }
}
