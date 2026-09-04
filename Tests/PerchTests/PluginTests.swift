import Foundation
import Testing
@testable import Perch
@testable import PerchKit

/// The plugin contract is the extension point third parties depend on, so it is
/// exercised against a real executable rather than mocked.
@Suite("External plugins")
struct PluginTests {
    private func install(script: String, manifest: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "island-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let probe = directory.appending(path: "probe.sh")
        try script.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        try manifest.write(
            to: directory.appending(path: "plugin.json"), atomically: true, encoding: .utf8
        )
        return directory
    }

    private let manifest = """
    {"id":"demo","displayName":"Demo","symbol":"star","accentHex":"#FF8800",
     "command":"probe.sh","timeout":5}
    """

    private func provider(at directory: URL) throws -> ExternalPluginProvider {
        let data = try Data(contentsOf: directory.appending(path: "plugin.json"))
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
        return ExternalPluginProvider(manifest: decoded, directory: directory)
    }

    @Test("a well-behaved plugin's sessions are adopted")
    func happyPath() async throws {
        let payload = """
        [{"nativeID":"s1","title":"Build the thing","state":"running",
          "model":"demo-1","workingDirectory":"/tmp/proj",
          "usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"contextWindow":1000},
          "target":"bundle:com.example.App"}]
        """
        let directory = try install(
            script: "#!/bin/sh\ncat <<'JSON'\n\(payload)\nJSON\n",
            manifest: manifest
        )
        let plugin = try provider(at: directory)
        #expect(plugin.isAvailable())

        let sessions = try await plugin.fetchSessions()
        let session = try #require(sessions.first)
        #expect(session.id == "demo:s1")
        #expect(session.providerID == "demo")
        #expect(session.state == .running)
        #expect(session.usage.total == 15)
        #expect(session.target == .bundleIdentifier("com.example.App"))
        #expect(session.workingDirectory?.lastPathComponent == "proj")
    }

    @Test("a plugin that exits non-zero surfaces an error instead of sessions")
    func failingPlugin() async throws {
        let directory = try install(script: "#!/bin/sh\nexit 3\n", manifest: manifest)
        let plugin = try provider(at: directory)
        await #expect(throws: ExternalPluginProvider.PluginError.self) {
            _ = try await plugin.fetchSessions()
        }
    }

    @Test("garbage output is rejected rather than crashing the poll")
    func badOutput() async throws {
        let directory = try install(script: "#!/bin/sh\necho 'not json'\n", manifest: manifest)
        let plugin = try provider(at: directory)
        await #expect(throws: ExternalPluginProvider.PluginError.self) {
            _ = try await plugin.fetchSessions()
        }
    }

    @Test("a hanging plugin is killed at its timeout")
    func timeout() async throws {
        let slow = """
        {"id":"slow","displayName":"Slow","symbol":"star","accentHex":"#FFF",
         "command":"probe.sh","timeout":1}
        """
        let directory = try install(script: "#!/bin/sh\nsleep 30\n", manifest: slow)
        let plugin = try provider(at: directory)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try? await plugin.fetchSessions()
        }
        // Must give up near its own timeout, not hang the whole poll cycle.
        #expect(elapsed < .seconds(10))
    }

    @Test("a plugin whose availability path is absent is skipped")
    func availabilityGate() throws {
        let gated = """
        {"id":"gated","displayName":"Gated","symbol":"star","accentHex":"#FFF",
         "command":"probe.sh","availabilityPath":"/nonexistent/island/path"}
        """
        let directory = try install(script: "#!/bin/sh\necho '[]'\n", manifest: gated)
        #expect(try provider(at: directory).isAvailable() == false)
    }

    @Test("hex accents decode, and malformed ones fall back")
    func hexParsing() {
        let parsed = try! #require(ExternalPluginProvider.parseHex("#4285F4"))
        #expect(abs(parsed.red - 0.259) < 0.01)
        #expect(abs(parsed.green - 0.522) < 0.01)
        #expect(abs(parsed.blue - 0.957) < 0.01)
        #expect(ExternalPluginProvider.parseHex("nope") == nil)
    }
}
