import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Scriptable stand-in for the vendor CLI. **No test in this file, or any
/// other, may invoke a real `claude` binary** — every vendor call goes
/// through `ClaudeCloudSpawning`.
final class FakeClaudeSpawner: ClaudeCloudSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<ClaudeCloudSpawnOutcome, any Error>]
    private(set) var requests: [ClaudeCloudSpawnRequest] = []

    init(outcomes: [ClaudeCloudSpawnOutcome]) {
        self.script = outcomes.map { .success($0) }
    }

    init(results: [Result<ClaudeCloudSpawnOutcome, any Error>]) {
        self.script = results
    }

    func spawn(_ request: ClaudeCloudSpawnRequest) async throws -> ClaudeCloudSpawnOutcome {
        try pop(request)
    }

    /// Synchronous so the NSLock critical section is not taken from an async
    /// context (recent Foundation marks `NSLock.lock` unavailable there).
    private func pop(_ request: ClaudeCloudSpawnRequest) throws -> ClaudeCloudSpawnOutcome {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        precondition(!script.isEmpty, "FakeClaudeSpawner script exhausted for \(request.arguments)")
        return try script.removeFirst().get()
    }

    func requestsSnapshot() -> [ClaudeCloudSpawnRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

// Tier 1 + Tier 2: the two `invocationEnvironment` tests are pure over
// injected values (no subprocess, no filesystem); the two `spawn(_:)` tests
// spawn short-lived local processes (`/usr/bin/env`) this suite fully
// controls, with generous (5s) timeouts against near-instant children — no
// deadline-racing test belongs in this file. `.timedOut`-outcome coverage
// lives in `Tests/TBDDaemonLiveTests/ClaudeCloudSpawnerTimeoutTests.swift`
// (Tier 3), per `Tests/CLAUDE.md`'s "spawns a child racing a deadline" rule.
@Suite("ClaudeCloudInvoker")
struct ClaudeCloudInvokerTests {
    /// The pty is a capture surface at 400x200, but the child still formats
    /// to whatever width it is TOLD, so the width must be pinned rather than
    /// inherited from whatever the daemon happened to be launched with.
    @Test func aPseudoTerminalSpawnPinsTermAndGeometry() {
        let env = BoundedProcessClaudeSpawner.invocationEnvironment(
            base: ["PATH": "/usr/bin", "COLUMNS": "80", "TERM": "dumb"],
            usesPseudoTerminal: true)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLUMNS"] == "400")
        #expect(env["LINES"] == "200")
        // The rest of the login environment survives: `runBoundedProcess`
        // REPLACES the environment wholesale, so a partial dict would hand the
        // child no PATH at all.
        #expect(env["PATH"] == "/usr/bin")
    }

    /// The discriminating half: a piped spawn must NOT be handed a terminal's
    /// vocabulary, or `send`'s JSON could arrive decorated.
    @Test func aPipedSpawnLeavesTheGeometryAlone() {
        let env = BoundedProcessClaudeSpawner.invocationEnvironment(
            base: ["PATH": "/usr/bin", "COLUMNS": "80"], usesPseudoTerminal: false)
        #expect(env["COLUMNS"] == "80")
        #expect(env["LINES"] == nil)
        #expect(env["PATH"] == "/usr/bin")
    }

    /// End-to-end over the real `spawn(_:)` implementation, not just the pure
    /// helper: proves the production conformance actually wires
    /// `usesPseudoTerminal` through to `runBoundedProcess`'s `stdio`
    /// parameter and that the pinned values reach a REAL child's environment
    /// — using `/usr/bin/env` so no vendor binary is touched. No `setenv`:
    /// this repo's test suites keep the ambient process environment alone
    /// (see `BoundedProcessRunnerTests.swift`'s file comment and the
    /// injection-seam precedent throughout `Tests/TBDDaemonTests`) because
    /// `setenv` is a process-wide mutation that races every suite running
    /// concurrently in the same test binary. The pure-function tests above
    /// already cover override-vs-inherit with an explicit conflicting `base`
    /// dict; this test covers the wiring the pure tests cannot reach.
    @Test func spawnPinsGeometryOnARealPseudoTerminalRun() async throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let spawner = BoundedProcessClaudeSpawner(executable: "/usr/bin/env")
        let outcome = try await spawner.spawn(
            ClaudeCloudSpawnRequest(
                arguments: [],
                workingDirectory: tmp,
                usesPseudoTerminal: true,
                timeout: 5))
        guard case let .completed(status, output) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(output.contains("TERM=xterm-256color"))
        #expect(output.contains("COLUMNS=400"))
        #expect(output.contains("LINES=200"))
    }

    /// A piped spawn must not gain a pty's vocabulary — proves the request
    /// flag actually reaches `runBoundedProcess`'s `stdio` parameter, not
    /// just the pure environment helper. No realistic ambient test
    /// environment carries `COLUMNS=400`/`LINES=200` on its own (unlike
    /// `TERM`, which a real dev/CI shell may legitimately already set to
    /// `xterm-256color` — passthrough, not pinning — so that key is not
    /// asserted here), so their absence is a meaningful negative.
    @Test func spawnLeavesGeometryAloneOnAPipedRun() async throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let spawner = BoundedProcessClaudeSpawner(executable: "/usr/bin/env")
        let outcome = try await spawner.spawn(
            ClaudeCloudSpawnRequest(
                arguments: [],
                workingDirectory: tmp,
                usesPseudoTerminal: false,
                timeout: 5))
        guard case let .completed(status, output) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(!output.contains("COLUMNS=400"))
        #expect(!output.contains("LINES=200"))
    }
}
