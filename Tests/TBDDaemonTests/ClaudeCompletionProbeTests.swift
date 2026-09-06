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

    /// An empty `argumentHint` is not a hint. It would render as an empty
    /// placeholder — a blank box after the token — so it must arrive as nil.
    /// Fixture command 3 carries `"argumentHint": ""` for exactly this.
    @Test func anEmptyArgumentHintDecodesToNone() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let decoded = try #require(ClaudeCompletionProbe.decode(responseLine: data))
        #expect(decoded.commands[2].name == "superpowers:brainstorming")
        #expect(decoded.commands[2].argumentHint == nil)
    }

    /// The probe writes one request and then reads whatever the binary emits. A
    /// success frame answering a *different* request is somebody else's answer,
    /// so it must not be mistaken for this one's.
    @Test func aSuccessResponseForAnotherRequestIsNotAnInventory() {
        let json = """
            {"type":"control_response","response":{"subtype":"success",\
            "request_id":"r2","response":{"commands":[{"name":"x"}],"agents":[]}}}
            """
        #expect(ClaudeCompletionProbe.decode(responseLine: Data(json.utf8)) == nil)
    }

    /// A command with no `description` is still worth completing: the decode is
    /// lenient by design and an absent description becomes "".
    @Test func aCommandWithoutADescriptionDecodesToAnEmptyOne() throws {
        let json = """
            {"type":"control_response","response":{"subtype":"success",\
            "request_id":"r1","response":{"commands":[{"name":"x"}],"agents":[]}}}
            """
        let decoded = try #require(
            ClaudeCompletionProbe.decode(responseLine: Data(json.utf8)))
        #expect(decoded.commands.map(\.name) == ["x"])
        #expect(decoded.commands[0].description == "")
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
    ///
    /// **Wall clock is the only available witness, so the fixture is sized to
    /// make it discriminate.** `.timedOut` is thrown on BOTH outcomes this test
    /// has to tell apart: the deadline fired and killed the child, and the child
    /// ran to natural completion with the runner's `ContinuousClock` authority
    /// check refusing to call a late exit a success. So asserting on the error
    /// proves nothing here, and elapsed time is what separates them.
    ///
    /// Elapsed time measured from the caller also includes how long the resumed
    /// continuation waits for a cooperative thread, and in the whole-suite
    /// parallel pass that is not small: 39 s and 49 s on two CI runs, while the
    /// same test takes 0.4 s on an idle machine. A 60 s child and a 10 s bound
    /// therefore overlapped the noise and failed with nothing wrong. The child
    /// now sleeps five minutes and the bound is two, so the gap between "killed
    /// at a 300 ms deadline" and "waited the child out" is far wider than any
    /// scheduling delay — and a regression still FAILS at 300 s rather than
    /// hanging the suite.
    @Test func aHangingExecutableIsKilledAtTheDeadline() async throws {
        let fake = try Self.makeFakeExecutable(emitting: nil, sleepSeconds: 300)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }

        let started = Date()
        await #expect(throws: ClaudeCompletionProbe.ProbeError.timedOut) {
            try await ClaudeCompletionProbe.run(
                executablePath: fake.path,
                workingDirectory: NSTemporaryDirectory(),
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .milliseconds(300))
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 120,
                "a 300 ms deadline resolved after \(elapsed) s — the probe waited its child out")
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
        if sleepSeconds > 0 {
            // `exec`, so the sleeping process IS the child the probe spawned.
            // A plain `sleep` leaves the shell as the child: the deadline kills
            // the shell, the forked `sleep` is reparented and runs out its full
            // duration, and every run of this test strands one.
            //
            // Which also means nothing may follow it — `exec` replaces the
            // shell — so a sleeping fixture never emits a response line.
            precondition(
                response == nil,
                "a sleeping fixture cannot also emit: exec replaces the shell")
            body += "exec sleep \(sleepSeconds)\n"
        }
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
