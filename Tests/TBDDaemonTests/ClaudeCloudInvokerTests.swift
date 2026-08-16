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

    // MARK: - describe

    private func invoker(
        db: TBDDatabase, spawner: FakeClaudeSpawner,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) }
    ) -> ClaudeCloudInvoker {
        ClaudeCloudInvoker(db: db, spawner: spawner, now: now)
    }

    private func config() -> RemoteProviderConfig {
        RemoteProviderConfig(name: ClaudeCloudProvider.name, exec: "/opt/acme/claude")
    }

    /// `describe` is static and OFFLINE, and its answer does not vary with
    /// the account — including for `attach`, which is declared because the
    /// provider implements it. Whether a given account may USE it is a
    /// separate runtime question.
    @Test func describeIsStaticOfflineAndSpawnsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["describe"], stdin: nil, timeout: 10, contractVersion: 2)
        #expect(result.exitCode == 0)
        #expect(spawner.requestsSnapshot().isEmpty, "describe must touch no process at all")
        let describe = try result.decoded(ProviderDescribe.self)
        #expect(describe.name == ClaudeCloudProvider.name)
        // `[2]` ALONE: nothing exposed terminates a running cloud session, so
        // the provider cannot implement `stop`, which major 1 requires.
        #expect(describe.contractVersions == [2])
        #expect(describe.capabilities.sorted()
            == ["archive", "attach", "land", "send", "unarchive"])
        // Each absence is a fact about the surface, not an unimplemented verb.
        #expect(!describe.capabilities.contains("stop"))
        #expect(!describe.capabilities.contains("log"))
        #expect(!describe.capabilities.contains("transcript"))
        #expect(!describe.capabilities.contains("events"))
        #expect(describe.createParams.map(\.name) == ["repo", "branch", "prompt", "environment"])
        #expect(describe.createParams.first(where: { $0.name == "repo" })?.required == true)
        #expect(describe.createParams.first(where: { $0.name == "prompt" })?.required == true)
        // `environment` is typed `string`, not `enum`: `describe` answers
        // offline and the set of configured cloud environments is knowable
        // only from the account.
        #expect(describe.createParams.first(where: { $0.name == "environment" })?.type == "string")
        #expect(describe.createParams.first(where: { $0.name == "prompt" })?.type == "text")
    }

    /// A declared capability whose verb is not wired yet must say so as a
    /// contract error rather than exiting 0 with nothing — these arms are
    /// filled in by the archive and land steps of the same delivery.
    @Test func anUnwiredDeclaredVerbFailsAsAContractBug() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [])
        for verb in [["archive", "s"], ["unarchive", "s"], ["land", "s"]] {
            let result = try await invoker(db: db, spawner: spawner).run(
                config(), verb: verb, stdin: nil, timeout: 30, contractVersion: 2)
            #expect(result.exitCode == 2)
            #expect(result.failureClass == .contractBug)
            #expect(result.decodedError?.code == "not_implemented")
        }
        #expect(spawner.requestsSnapshot().isEmpty)
    }

    /// An undeclared verb is a caller bug — the contract forbids invoking one
    /// — and must be reported as such rather than silently succeeding.
    @Test func anUndeclaredVerbIsAContractError() async throws {
        let db = try TBDDatabase(inMemory: true)
        let result = try await invoker(db: db, spawner: FakeClaudeSpawner(outcomes: [])).run(
            config(), verb: ["stop", "s"], stdin: nil, timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 2)
        #expect(result.failureClass == .contractBug)
    }
}
