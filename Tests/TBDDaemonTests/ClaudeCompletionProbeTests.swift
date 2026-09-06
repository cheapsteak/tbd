import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The completions probe: what it runs, what it reads, and what it does when the
/// binary does not answer.
///
/// The command line is asserted rather than trusted, because every flag on it
/// closes a measured side effect (hooks running and leaving `session-env/`
/// directories, an authenticated connectors request, real MCP servers leaking
/// processes and writing logs into the user's Library folder). A silently
/// dropped flag would reintroduce one with nothing going red.
///
/// Tier 3 for the two `run` cases — they spawn a real script and race a real
/// deadline. Keep those in `Tests/TBDDaemonLiveTests` if the suite's runtime
/// there is materially better; the pure cases stay here.
@Suite("ClaudeCompletionProbe")
struct ClaudeCompletionProbeTests {

    // MARK: - The command line

    @Test func theArgumentsAreTheMeasuredOnes() {
        let args = ClaudeCompletionProbe.arguments(mcpConfigPath: "/tmp/mcp.json")
        #expect(args == [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--strict-mcp-config",
            "--mcp-config", "/tmp/mcp.json",
            "--settings", ClaudeCompletionProbe.settingsOverlay,
        ])
    }

    /// Each of these closes a measured side effect. Asserted by name so a
    /// refactor cannot drop one silently.
    @Test func everySideEffectSuppressorIsPresent() {
        let args = ClaudeCompletionProbe.arguments(mcpConfigPath: "/tmp/mcp.json")
        #expect(args.contains("--strict-mcp-config"))
        #expect(ClaudeCompletionProbe.settingsOverlay.contains("disableAllHooks"))
        #expect(ClaudeCompletionProbe.settingsOverlay.contains("disableClaudeAiConnectors"))
        #expect(ClaudeCompletionProbe.emptyMCPConfig == #"{"mcpServers":{}}"#)
    }

    @Test func theRequestLineIsOneNewlineTerminatedControlRequest() {
        let line = ClaudeCompletionProbe.initializeRequestLine
        #expect(line.hasSuffix("\n"))
        #expect(line.contains(#""subtype":"initialize""#))
        #expect(line.contains(#""request_id":"r1""#))
    }

    // MARK: - Decoding the response

    @Test func itDecodesTheMeasuredEnvelope() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let decoded = try #require(ClaudeCompletionProbe.decode(responseLine: data))

        #expect(decoded.commands.count == 3)
        #expect(decoded.commands[0].name == "compact")
        #expect(decoded.commands[1].aliases == ["review"])
        #expect(decoded.commands[2].name == "superpowers:brainstorming")
        #expect(decoded.agents.map(\.name) == ["Explore", "claude"])
    }

    /// The envelope carries a dozen keys this build does not model, and a newer
    /// Claude Code will add more. Adding a key must never break the decode.
    @Test func unknownKeysAreIgnored() throws {
        let json = """
            {"type":"control_response","response":{"subtype":"success",\
            "request_id":"r1","response":{"commands":[{"name":"x","description":"d",\
            "somethingNew":42}],"agents":[],"aBrandNewTopLevelKey":true}}}
            """
        let decoded = try #require(
            ClaudeCompletionProbe.decode(responseLine: Data(json.utf8)))
        #expect(decoded.commands.map(\.name) == ["x"])
    }

    @Test func aNonSuccessResponseIsNotAnInventory() {
        let json = """
            {"type":"control_response","response":{"subtype":"error",\
            "request_id":"r1","error":"nope"}}
            """
        #expect(ClaudeCompletionProbe.decode(responseLine: Data(json.utf8)) == nil)
    }

    /// The init frame headless mode also emits must never be mistaken for the
    /// answer: it appears only after a real, billed message and carries names
    /// without descriptions.
    @Test func anInitFrameIsNotAnInventory() {
        let json = #"{"type":"system","subtype":"init","slash_commands":["compact"]}"#
        #expect(ClaudeCompletionProbe.decode(responseLine: Data(json.utf8)) == nil)
    }

    @Test func garbageIsNotAnInventory() {
        #expect(ClaudeCompletionProbe.decode(responseLine: Data("not json".utf8)) == nil)
        #expect(ClaudeCompletionProbe.decode(responseLine: Data()) == nil)
    }

    // MARK: - Running a fake executable

    @Test func itReadsTheResponseFromAFakeExecutable() async throws {
        let fake = try Self.makeFakeExecutable(emitting: try Data(contentsOf: Self.fixtureURL))
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }

        let outcome = try await ClaudeCompletionProbe.run(
            executablePath: fake.path,
            workingDirectory: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin"])

        #expect(outcome.commands.map(\.name) == ["compact", "code-review", "superpowers:brainstorming"])
        #expect(outcome.agents.count == 2)
    }

    /// A hung probe is killed. Without the kill, a wedged Claude Code holds a
    /// process and a pipe for as long as the daemon lives.
    @Test func aHangingExecutableIsKilledAtTheDeadline() async throws {
        let fake = try Self.makeFakeExecutable(emitting: nil, sleepSeconds: 60)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }

        let started = Date()
        await #expect(throws: ClaudeCompletionProbe.ProbeError.timedOut) {
            try await ClaudeCompletionProbe.run(
                executablePath: fake.path,
                workingDirectory: NSTemporaryDirectory(),
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .milliseconds(300))
        }
        #expect(Date().timeIntervalSince(started) < 10,
                "the probe must not outlive its deadline by an order of magnitude")
    }

    // MARK: - Fixtures

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CompletionProbe/initialize-response.json")
    }

    /// A shell script standing in for `claude`: it drains stdin, optionally
    /// sleeps, and optionally prints one canned response line.
    private static func makeFakeExecutable(
        emitting response: Data?, sleepSeconds: Int = 0
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-probe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        var body = "#!/bin/sh\ncat > /dev/null\n"
        if sleepSeconds > 0 { body += "sleep \(sleepSeconds)\n" }
        if let response {
            let line = String(decoding: response, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "'", with: "'\\''")
            body += "printf '%s\\n' '\(line)'\n"
        }
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
