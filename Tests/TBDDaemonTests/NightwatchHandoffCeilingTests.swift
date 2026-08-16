import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2. The desk's handoff ceiling is three quarters of the context window
/// **its own session** resolved, and the only report of that window is the
/// statusline capture TBD's tee publishes for desk sessions.
///
/// Two halves have to line up across a language boundary for that to work: the
/// Python has to look where the Swift writes, and it has to take the same field
/// out of the payload. Neither is checked by anything else — a capture the
/// script cannot find is indistinguishable, from inside the script, from a
/// session that never reported a window, so a drift would silently put every
/// desk on the fallback forever. So the agreement is asserted by pointing the
/// script at a capture written through `TBDConstants` and asking what ceiling
/// it resolved.
@Suite("Nightwatch handoff ceiling reads the session's own window")
struct NightwatchHandoffCeilingTests {

    /// What the shipped `handoff.py` resolves for one session key.
    private struct Answer {
        let capturePath: String
        let window: Int?
        let ceiling: Int
        let provenance: String
        let fallback: Int
    }

    /// Loads the installed `handoff.py` as a module and calls into it. Its
    /// `--selftest` proves the arithmetic against captures it wrote itself;
    /// only this proves it against a capture path TBD built.
    private static let driver = """
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("nightwatch_handoff", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ceiling, provenance = mod.resolve_ceiling(sys.argv[2])
    print(json.dumps({"path": mod.statusline_capture_path(sys.argv[2]),
                      "window": mod.observed_window(sys.argv[2]),
                      "ceiling": ceiling,
                      "provenance": provenance,
                      "fallback": mod.FALLBACK_THRESHOLD}))
    """

    /// Runs the driver with `TBD_HOME` in the child's environment — the
    /// injection seam, so no test in this process mutates its own environment.
    private func ask(handoffPath: String, sessionKey: String, tbdHome: String) throws -> Answer {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", Self.driver, handoffPath, sessionKey]
        var env = ProcessInfo.processInfo.environment
        env["TBD_HOME"] = tbdHome
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "handoff.py driver failed:\n\(stderr)")
        let object = try JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        let root = try #require(object, "handoff.py driver printed no JSON. stderr:\n\(stderr)")
        return Answer(
            capturePath: try #require(root["path"] as? String),
            window: root["window"] as? Int,
            ceiling: try #require(root["ceiling"] as? Int),
            provenance: try #require(root["provenance"] as? String),
            fallback: try #require(root["fallback"] as? Int)
        )
    }

    /// A scratch `TBD_HOME` with the plugin written into it, plus the path of
    /// the installed `handoff.py`.
    private func fixture() throws -> (home: URL, handoff: String) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-handoff-ceiling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try PluginDirWriter(applicationSupportRoot: home.path).writePlugin()
        return (home, home.appendingPathComponent(
            "TBD/plugin/skills/nightwatch/scripts/handoff.py").path)
    }

    private func publish(window: Int, forKey key: String, home: URL) throws {
        let path = TBDConstants.statuslineCapturePath(
            sessionKey: key, environment: ["TBD_HOME": home.path])
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let payload = try JSONSerialization.data(
            withJSONObject: ["context_window": ["context_window_size": window]])
        try payload.write(to: URL(fileURLWithPath: path))
    }

    @Test("The script looks exactly where TBDConstants publishes, sanitizing identically")
    func capturePathAgrees() throws {
        let (home, handoff) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }

        // A terminal id is a UUID, but the sanitizer is what makes that safe, so
        // the agreement is asserted on a key that actually exercises it.
        for key in [UUID().uuidString, "a/b .c", "T-1_2"] {
            let answer = try ask(handoffPath: handoff, sessionKey: key, tbdHome: home.path)
            #expect(answer.capturePath == TBDConstants.statuslineCapturePath(
                sessionKey: key, environment: ["TBD_HOME": home.path]),
                    "handoff.py builds a different capture path than TBDConstants for \(key)")
        }
    }

    @Test("A desk on a real window gets three quarters of THAT window, and is told so")
    func ceilingFollowsTheObservedWindow() throws {
        let (home, handoff) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = UUID().uuidString

        for (window, expected) in [(1_000_000, 750_000), (200_000, 150_000)] {
            try publish(window: window, forKey: key, home: home)
            let answer = try ask(handoffPath: handoff, sessionKey: key, tbdHome: home.path)
            #expect(answer.window == window)
            #expect(answer.ceiling == expected,
                    "a \(window)-token desk got a ceiling of \(answer.ceiling)")
            #expect(answer.provenance.contains("OBSERVED"),
                    "the ceiling does not say the window was observed: \(answer.provenance)")
        }
    }

    /// With no capture the ceiling stays where the desk has been running it. A
    /// smaller guess is the measured failure — a 200k-derived ceiling forced a
    /// relay roughly every two hours on a large window — and the output has to
    /// admit the number is a guess, since nothing here measured anything.
    @Test("No capture keeps the fallback ceiling, labeled as a guess")
    func noCaptureFallsBackAndSaysSo() throws {
        let (home, handoff) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }

        let answer = try ask(handoffPath: handoff, sessionKey: UUID().uuidString, tbdHome: home.path)

        #expect(answer.window == nil)
        #expect(answer.fallback == 600_000)
        #expect(answer.ceiling == 600_000, "the no-capture ceiling moved off 600k")
        #expect(answer.provenance.contains("NOT observed"),
                "a fallback ceiling reads as though something measured it: \(answer.provenance)")
    }

    /// Every unreadable shape is "no capture", and none of them raises: this
    /// code runs on the path that keeps a shift alive, so a malformed payload
    /// may cost the ceiling its precision but never the ceiling itself.
    @Test("An unreadable capture falls back rather than raising", arguments: [
        "{not json",
        #"{"context_window":{}}"#,
        #"{"context_window":{"context_window_size":0}}"#,
        #"{"context_window":{"context_window_size":-5}}"#,
        #"{"context_window":{"context_window_size":"1m"}}"#,
        "[]"
    ])
    func malformedCaptureFallsBack(payload: String) throws {
        let (home, handoff) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = UUID().uuidString
        let path = TBDConstants.statuslineCapturePath(
            sessionKey: key, environment: ["TBD_HOME": home.path])
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: URL(fileURLWithPath: path))

        let answer = try ask(handoffPath: handoff, sessionKey: key, tbdHome: home.path)

        #expect(answer.window == nil, "\(payload) was read as a window")
        #expect(answer.ceiling == answer.fallback)
    }
}
