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
        guard case let .completed(status, output, _) = outcome else {
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
        guard case let .completed(status, output, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(!output.contains("COLUMNS=400"))
        #expect(!output.contains("LINES=200"))
    }

    /// The discriminating case named in `ClaudeCloudSpawnOutcome`'s own doc
    /// comment: on a plain pipe stdout and stderr are genuinely separate
    /// descriptors, so `output` must carry stdout ALONE — stderr chatter on
    /// an otherwise-successful call must never land where `send` parses
    /// strict JSON.
    @Test func spawnExcludesStderrFromOutputOnAPipedRun() async throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let spawner = BoundedProcessClaudeSpawner(executable: "/bin/sh")
        let outcome = try await spawner.spawn(
            ClaudeCloudSpawnRequest(
                arguments: ["-c", "printf 'out'; printf 'err' 1>&2"],
                workingDirectory: tmp,
                usesPseudoTerminal: false,
                timeout: 5))
        guard case let .completed(status, output, stderr) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(output == "out")
        #expect(stderr == "err")
    }

    /// The pty side of the same pair: the two streams genuinely merge onto
    /// one descriptor there, so `output` keeps carrying both — matching
    /// `create`, which depends on that merge and is otherwise unaffected by
    /// this task's fix.
    @Test func spawnMergesStderrIntoOutputOnAPseudoTerminalRun() async throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let spawner = BoundedProcessClaudeSpawner(executable: "/bin/sh")
        let outcome = try await spawner.spawn(
            ClaudeCloudSpawnRequest(
                arguments: ["-c", "printf 'out'; printf 'err' 1>&2"],
                workingDirectory: tmp,
                usesPseudoTerminal: true,
                timeout: 5))
        guard case let .completed(status, output, stderr) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(output.contains("out"))
        #expect(output.contains("err"))
        #expect(stderr.isEmpty)
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
        #expect(describe.capabilities.sorted() == ["attach", "send"])
        // Each absence is a fact about the surface, not an unimplemented verb.
        #expect(!describe.capabilities.contains("stop"))
        #expect(!describe.capabilities.contains("log"))
        #expect(!describe.capabilities.contains("transcript"))
        #expect(!describe.capabilities.contains("events"))
        // `land`/`archive`/`unarchive` are a DIFFERENT kind of absence than
        // the four above: `run` does implement a case for each (see
        // `anUnwiredDeclaredVerbFailsAsAContractBug`), but a later slice of
        // this feature owns re-adding the capability string together with a
        // real implementation. Declaring them now would offer the app an
        // action that always fails.
        #expect(!describe.capabilities.contains("land"))
        #expect(!describe.capabilities.contains("archive"))
        #expect(!describe.capabilities.contains("unarchive"))
        #expect(describe.createParams.map(\.name) == ["repo", "branch", "prompt", "environment"])
        #expect(describe.createParams.first(where: { $0.name == "repo" })?.required == true)
        #expect(describe.createParams.first(where: { $0.name == "prompt" })?.required == true)
        // `environment` is typed `string`, not `enum`: `describe` answers
        // offline and the set of configured cloud environments is knowable
        // only from the account.
        #expect(describe.createParams.first(where: { $0.name == "environment" })?.type == "string")
        #expect(describe.createParams.first(where: { $0.name == "prompt" })?.type == "text")
    }

    /// Not (yet) a declared capability — see the note in
    /// `describeIsStaticOfflineAndSpawnsNothing` — but `run` still refuses to
    /// exit 0 with nothing if one of these verbs is reached anyway (a stale
    /// capability cache, a call that skips the capability check). A later
    /// slice fills these arms in together with re-declaring each capability.
    @Test func anUnwiredUndeclaredVerbFailsAsAContractBug() async throws {
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

    /// The regression this pins: a capability `describe` declares must be a
    /// verb `run` actually answers, never `not_implemented`. Before this
    /// finding was fixed, `ClaudeCloudDescribe` declared `land`/`archive`/
    /// `unarchive` while `run` answered all three with `not_implemented` —
    /// this iterates the REAL declared list, `ClaudeCloudDescribe.capabilities`,
    /// rather than a hand-picked one, so a future capability declared ahead of
    /// its implementation fails this test instead of only failing silently
    /// for a user.
    ///
    /// `attach` is exercised too, even though it is never dispatched through
    /// `run` in production (the contract's TTY passthrough is exec'd directly
    /// on the pane, not through this JSON stdin/stdout path) — `run`'s
    /// `default` arm answers an undeclared-verb `invalid_params`, which is
    /// still correctly NOT `not_implemented`, so the assertion holds without
    /// having to special-case it.
    @Test func everyDeclaredCapabilityIsNotAnsweredAsNotImplemented() async throws {
        let db = try TBDDatabase(inMemory: true)
        for capability in ClaudeCloudDescribe.capabilities {
            let needsSend = capability == "send"
            let spawner = FakeClaudeSpawner(
                outcomes: needsSend ? [.completed(status: 0, output: sendOK, stderr: "")] : [])
            let result = try await invoker(db: db, spawner: spawner).run(
                config(), verb: [capability, "s"],
                stdin: needsSend ? Data("hi\r".utf8) : nil,
                timeout: 30, contractVersion: 2)
            #expect(
                result.decodedError?.code != "not_implemented",
                "declared capability '\(capability)' is not implemented by run()")
        }
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

    // MARK: - create

    private func createBody(
        repo: String = "acme/api", branch: String? = "fix-ci",
        environment: String? = nil,
        prompt: String = "add a probe", key: String = "tbd-1"
    ) -> Data {
        var params: [String: String] = ["repo": repo, "prompt": prompt]
        if let branch { params["branch"] = branch }
        if let environment { params["environment"] = environment }
        let body: [String: Any] = ["params": params, "idempotency_key": key]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func seedRepo(_ db: TBDDatabase) async throws {
        _ = try await db.repos.create(
            path: "/tmp/api", displayName: "api", defaultBranch: "main",
            remoteURL: "https://github.com/acme/api")
    }

    private let successOutput = """
        Created cloud session: Add probe pong reply
        View: https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA?from=cli&m=0
        Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA
        """

    @Test func createSpawnsOnAPseudoTerminalInTheRepoCheckoutAndReturnsTheSession() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)

        #expect(result.exitCode == 0)
        let request = try #require(spawner.requestsSnapshot().first)
        #expect(request.arguments == ["--cloud", "add a probe"])
        #expect(request.workingDirectory == "/tmp/api")
        // Non-negotiable: the CLI refuses `--cloud` creation on a pipe, so a
        // piped spawn does not degrade — it never works.
        #expect(request.usesPseudoTerminal)

        let session = try result.decoded(RemoteSessionPayload.self)
        #expect(session.id == "session_01AAAAAAAAAAAAAAAAAAAAAA")
        // The name comes from the VENDOR's server-derived summary…
        #expect(session.title == "Add probe pong reply")
        // …never from what was submitted.
        #expect(session.title != "add a probe")
        // The ledger knows a session was created; it does not know whether it
        // lives, and the contract forbids guessing.
        #expect(session.state == .unknown)
        #expect(session.agentState == .unknown)
        #expect(session.meta?["repo"] == "acme/api")
        #expect(session.meta?["branch"] == "fix-ci")
    }

    @Test func createWritesTheLedgerRowBeforeResolvingIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        _ = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        let row = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(row.idempotencyKey == "tbd-1")
        #expect(row.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(row.sessionID == "session_01AAAAAAAAAAAAAAAAAAAAAA")
        #expect(row.title == "Add probe pong reply")
        #expect(row.repoKey == "acme/api")
        #expect(row.repoPath == "/tmp/api")
        #expect(row.branch == "fix-ci")
        #expect(row.archived == false)
    }

    /// An unreadable id costs the lane its identity, so it fails LOUDLY as a
    /// contract bug — and the pending row it left behind is what keeps that
    /// failure from being silent.
    @Test func anUnreadableSessionIDFailsTheCreateAndLeavesThePendingRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: "Something went sideways", stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 2)
        #expect(result.failureClass == .contractBug)
        #expect(result.decodedError?.message.contains("Something went sideways") == true)
        let row = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(row.state == ClaudeCloudLedgerState.pending.rawValue)
        #expect(row.sessionID == nil)
    }

    @Test func conflictingSessionIDsAlsoFailAsAContractBug() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: """
                Created cloud session: two
                View: https://claude.ai/code/session_01AAA?from=cli
                Resume with: claude --teleport session_01BBB
                """, stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.failureClass == .contractBug)
        #expect(try await db.claudeCloudSessions.rows().first?.state
            == ClaudeCloudLedgerState.pending.rawValue)
    }

    /// The opposite posture, and the pair that discriminates: an unreadable
    /// TITLE must never fail a create that produced a readable id.
    @Test func anUnreadableTitleStillSucceedsAndNamesTheRowFromItsID() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output:
                "Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA", stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 0)
        let session = try result.decoded(RemoteSessionPayload.self)
        #expect(session.id == "session_01AAAAAAAAAAAAAAAAAAAAAA")
        #expect(session.title == nil)
        #expect(try await db.claudeCloudSessions.rows().first?.title == nil)
    }

    /// The single same-key retry must find the row it already wrote, keeping
    /// the original timestamp — the failure window is measured from the
    /// create, not from the retry. And it must NOT spawn `claude --cloud` a
    /// second time: finding 4. Only ONE outcome is scripted, so if the fix
    /// regresses and `create` spawns again on the replay, `FakeClaudeSpawner`
    /// crashes on its exhausted script — the spawn-count assertion below is
    /// what would have caught it even if the script had a second outcome to
    /// consume, which is exactly what the old two-outcome version of this
    /// test hid.
    @Test func replayingTheSameIdempotencyKeyReusesTheSameLedgerRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: successOutput, stderr: ""),
        ])
        let inv = invoker(db: db, spawner: spawner)
        let first = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        let second = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
        #expect(spawner.requestsSnapshot().count == 1)
        #expect(second.exitCode == 0)
        let firstSession = try first.decoded(RemoteSessionPayload.self)
        let secondSession = try second.decoded(RemoteSessionPayload.self)
        #expect(secondSession.id == firstSession.id)
    }

    /// The decision this design makes for a replay of a STILL-PENDING key
    /// (finding 4's "live" case): there is no discovery to check whether the
    /// first attempt's spawn already started a real cloud session, so a
    /// replay refuses to spawn a second one rather than guess — a retried
    /// timeout that actually succeeded must never become two live sessions
    /// this ledger can never reconcile. The failure is transient (exit 3):
    /// once `list`'s `pendingFailureWindow` gives up on the row, the SAME key
    /// is free to spawn fresh (see `aPendingRowFlipsToFailedOnlyOnceThePendingWindowHasElapsed`
    /// for that half).
    @Test func replayingAStillPendingKeyRefusesToSpawnAgain() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: "fix-ci", environment: nil, paramsJSON: "{}",
            now: Date(timeIntervalSince1970: 1_000_000))
        let spawner = FakeClaudeSpawner(outcomes: [])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 3)
        #expect(result.failureClass == .transient)
        #expect(spawner.requestsSnapshot().isEmpty)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    /// The other half of that decision: a key that already reached `failed`
    /// (the pending window gave up with no session ever recorded) is treated
    /// as a fresh attempt and IS allowed to spawn, reusing the same row.
    @Test func replayingAFailedKeySpawnsFreshAndReusesTheRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: "fix-ci", environment: nil, paramsJSON: "{}",
            now: Date(timeIntervalSince1970: 1_000_000))
        try await db.claudeCloudSessions.markFailed(ids: [row.id])
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: successOutput, stderr: ""),
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 0)
        #expect(spawner.requestsSnapshot().count == 1)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
        #expect(try await db.claudeCloudSessions.rows().first?.id == row.id)
        #expect(try await db.claudeCloudSessions.rows().first?.state
            == ClaudeCloudLedgerState.resolved.rawValue)
    }

    @Test func aNonZeroVendorExitIsAPermanentFailureCarryingItsOutput() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 1, output: "Error: not logged in", stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.failureClass == .permanent)
        #expect(result.decodedError?.message.contains("not logged in") == true)
        // The ledger row written before the spawn is the record of what was
        // asked for; a permanent vendor failure must leave it exactly where
        // it was, not resolved and not deleted.
        #expect(try await db.claudeCloudSessions.rows().first?.state
            == ClaudeCloudLedgerState.pending.rawValue)
    }

    /// A timeout is thrown, not synthesized, because the handler's single
    /// same-key retry is armed by `ProviderRunError` — and that retry is
    /// exactly what the pending ledger row exists to make safe.
    @Test func aSpawnTimeoutThrowsSoTheHandlerCanRetryTheSameKey() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.timedOut])
        await #expect(throws: ProviderRunError.self) {
            _ = try await invoker(db: db, spawner: spawner).run(
                config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        }
        #expect(try await db.claudeCloudSessions.rows().first?.state
            == ClaudeCloudLedgerState.pending.rawValue)
    }

    @Test func anUnregisteredRepositoryIsRefusedBeforeAnythingIsSpawned() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(repo: "acme/unknown"),
            timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.decodedError?.code == "not_found")
        #expect(spawner.requestsSnapshot().isEmpty)
        #expect(try await db.claudeCloudSessions.rows().isEmpty)
    }

    @Test func aBlankPromptIsRefusedBeforeAnythingIsSpawned() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(prompt: "   "),
            timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 2)
        #expect(result.decodedError?.code == "invalid_params")
        #expect(spawner.requestsSnapshot().isEmpty)
        // A refusal this early must not even write the pending row — nothing
        // was validated enough yet to be worth recording.
        #expect(try await db.claudeCloudSessions.rows().isEmpty)
    }

    /// The measured CLI surface exposes no flag for either, so they are
    /// RECORDED and reported rather than submitted. Do not invent flags.
    @Test func branchAndEnvironmentAreRecordedNotPassedToTheCLI() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        _ = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        let request = try #require(spawner.requestsSnapshot().first)
        #expect(!request.arguments.contains("fix-ci"))
        #expect(!request.arguments.contains(where: { $0.hasPrefix("--branch") }))
        #expect(try await db.claudeCloudSessions.rows().first?.branch == "fix-ci")
    }

    /// `environment` is persisted on the ledger row exactly like `branch`
    /// (per `ClaudeCloudCreate`'s own doc comment); it must also reach the
    /// wire payload's `meta`, or a value that safely round-trips through the
    /// database is invisible to every caller for the rest of this slice —
    /// `list` answers from the ledger alone and has no discovery to re-supply
    /// it with later.
    @Test func createIncludesEnvironmentInMetaWhenSupplied() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"],
            stdin: createBody(environment: "prod"), timeout: 60, contractVersion: 2)
        let session = try result.decoded(RemoteSessionPayload.self)
        #expect(session.meta?["environment"] == "prod")
        #expect(try await db.claudeCloudSessions.rows().first?.environment == "prod")
    }

    /// The pairing negative: no environment supplied must mean no
    /// `"environment"` key at all, not an empty-string placeholder — `meta`
    /// is inspected by presence, mirroring how `branch`'s absence is already
    /// covered.
    @Test func createOmitsEnvironmentFromMetaWhenNotSupplied() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        let session = try result.decoded(RemoteSessionPayload.self)
        #expect(session.meta?["environment"] == nil)
    }

    /// The pairing negative for `branch`: an absent branch must produce a
    /// `meta` with no `"branch"` key, not a stored empty string — the
    /// omission path in the `meta` construction (`if let branch { … }`) had
    /// no test exercising `branch == nil` at all.
    @Test func createOmitsBranchFromMetaWhenNotSupplied() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"],
            stdin: createBody(branch: nil), timeout: 60, contractVersion: 2)
        let session = try result.decoded(RemoteSessionPayload.self)
        #expect(session.meta?["branch"] == nil)
        #expect(try await db.claudeCloudSessions.rows().first?.branch == nil)
    }

    /// `run`'s `timeout` parameter must actually reach the spawn request —
    /// today it happens to work only because the sole production caller also
    /// hardcodes 60, so a caller-supplied value that DIFFERS from 60 is the
    /// only assertion that discriminates real wiring from that coincidence.
    @Test func createThreadsTheCallersTimeoutIntoTheSpawnRequest() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        _ = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 137, contractVersion: 2)
        let request = try #require(spawner.requestsSnapshot().first)
        #expect(request.timeout == 137)
    }

    // MARK: - list

    private func listSessions(_ result: ProviderResult) throws -> [[String: Any]] {
        let object = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        return try #require(object["sessions"] as? [[String: Any]])
    }

    private func listEnvelope(_ result: ProviderResult) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }

    /// Permanently `complete: false`, by construction and not by care. The
    /// ledger is a record of what THIS machine started and never a claim
    /// about the account's inventory — no supported interface enumerates one.
    /// A provider that never claims completeness cannot cause a false
    /// retirement however wrong its view is.
    @Test func listIsAlwaysIncompleteEvenWhenEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let result = try await invoker(db: db, spawner: FakeClaudeSpawner(outcomes: [])).run(
            config(), verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 0)
        #expect(try listEnvelope(result)["complete"] as? Bool == false)
        #expect(try listSessions(result).isEmpty)
    }

    @Test func listNeverSpawnsTheVendorCLI() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let inv = invoker(db: db, spawner: spawner)
        _ = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        _ = try await inv.run(config(), verb: ["list"], stdin: nil,
                              timeout: 30, contractVersion: 2)
        // Exactly the one create spawn; `list` reads the ledger and nothing
        // else, so there is no discovery call to make.
        #expect(spawner.requestsSnapshot().count == 1)
    }

    @Test func aResolvedRowIsListedUnknownOnBothAxesCarryingItsRepoAndTitle() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let inv = invoker(db: db, spawner: spawner)
        _ = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        let sessions = try listSessions(
            try await inv.run(config(), verb: ["list"], stdin: nil,
                              timeout: 30, contractVersion: 2))
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session["id"] as? String == "session_01AAAAAAAAAAAAAAAAAAAAAA")
        #expect(session["title"] as? String == "Add probe pong reply")
        #expect(session["state"] as? String == "unknown")
        #expect(session["agent_state"] as? String == "unknown")
        let meta = try #require(session["meta"] as? [String: String])
        #expect(meta["repo"] == "acme/api")
        #expect(meta["branch"] == "fix-ci")
    }

    /// **`archived` is emitted EXPLICITLY on every session, `false` included.**
    /// The wire field is three-valued: absent means "no claim made" and moves
    /// no row, which is what stops a provider with no archiving concept from
    /// dragging archived rows back into the active list every minute. Omitting
    /// it when unarchived would mean TBD never observes the `false`
    /// transition, and unarchiving through this ledger would not return the
    /// row to the active list at all. Asserting on the RAW JSON is what
    /// discriminates — a decoded `Bool?` would read `nil` and `false` alike
    /// through `isArchived`.
    @Test func listEmitsArchivedExplicitlyEvenWhenFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let inv = invoker(db: db, spawner: spawner)
        _ = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        let session = try #require(try listSessions(
            try await inv.run(config(), verb: ["list"], stdin: nil,
                              timeout: 30, contractVersion: 2)).first)
        #expect(session.keys.contains("archived"), "the field must be PRESENT, not omitted")
        #expect(session["archived"] as? Bool == false)
    }

    /// The contract requires archived sessions to stay enumerated: one
    /// filtered out of successive snapshots is indistinguishable from a
    /// deleted one, and would be silently marked gone.
    @Test func anArchivedLedgerRowStaysEnumeratedWithItsFlagSet() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let inv = invoker(db: db, spawner: spawner)
        _ = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "UPDATE claude_cloud_session SET archived = 1")
        }
        let sessions = try listSessions(
            try await inv.run(config(), verb: ["list"], stdin: nil,
                              timeout: 30, contractVersion: 2))
        #expect(sessions.count == 1)
        #expect(sessions.first?["archived"] as? Bool == true)
    }

    /// A row with no session id names no session, so there is nothing to
    /// list. It is still retained, and still visible as an unresolved create.
    @Test func pendingAndFailedRowsAreNotListed() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "k", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1_000_000))
        let result = try await invoker(db: db, spawner: FakeClaudeSpawner(outcomes: [])).run(
            config(), verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)
        #expect(try listSessions(result).isEmpty)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    /// A create whose output could not be read stays `pending` through the
    /// window and only then becomes `failed` — retained either way.
    @Test func aPendingRowFlipsToFailedOnlyOnceThePendingWindowHasElapsed() async throws {
        let db = try TBDDatabase(inMemory: true)
        let created = Date(timeIntervalSince1970: 1_000_000)
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "k", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: created)

        _ = try await invoker(
            db: db, spawner: FakeClaudeSpawner(outcomes: []),
            now: { created.addingTimeInterval(599) }
        ).run(config(), verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)
        #expect(try await db.claudeCloudSessions.rows().first?.state
            == ClaudeCloudLedgerState.pending.rawValue)

        _ = try await invoker(
            db: db, spawner: FakeClaudeSpawner(outcomes: []),
            now: { created.addingTimeInterval(601) }
        ).run(config(), verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)
        let row = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(row.state == ClaudeCloudLedgerState.failed.rawValue)
        // Retained: the record of a create that may have started a real
        // session outlives the judgement that it did not.
        #expect(row.idempotencyKey == "k")
    }

    // MARK: - send

    private let sendOK = #"{"ok":true,"session_id":"session_01AAA","url":"https://claude.ai/code/session_01AAA"}"#

    /// The contract's `send` takes stdin bytes destined for a terminal and
    /// requires the caller to append `\r` when it means Enter. A session with
    /// no terminal takes that trailing submit gesture off and treats the rest
    /// as ONE message — so interior newlines stay one multi-line message
    /// rather than becoming several.
    @Test func theSubmitGestureIsStrippedAndInteriorNewlinesSurvive() {
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data("hello\r".utf8)) == "hello")
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data("hello\n".utf8)) == "hello")
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data("hello".utf8)) == "hello")
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data("one\ntwo\r".utf8)) == "one\ntwo")
        // Exactly ONE trailing terminator, so a deliberate blank last line
        // survives the strip.
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data("one\n\n".utf8)) == "one\n")
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data("\r".utf8)) == nil)
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data()) == nil)
    }

    @Test func sendPostsOneMessageOnAPipeAndReportsSuccess() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: sendOK, stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("try again\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 0)
        let request = try #require(spawner.requestsSnapshot().first)
        #expect(request.arguments
            == ["-p", "try again", "--cloud", "session_01AAA", "--output-format", "json"])
        // `--print` is explicitly a NON-interactive invocation and returns
        // JSON on an ordinary pipe. A pty here would merge stderr into that
        // JSON.
        #expect(request.usesPseudoTerminal == false)
        // The contract's `send` answers `{}`; exit 0 means the bytes were
        // handed to the transport, not that the agent acted on them.
        #expect(try JSONSerialization.jsonObject(with: result.stdout) is [String: Any])
    }

    /// The fix this round of findings exists for: incidental stderr chatter
    /// on an otherwise-successful pipe invocation must never break the
    /// strict JSON parse `send` runs against `output` alone.
    @Test func stderrChatterOnASuccessfulSendDoesNotBreakTheParse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: sendOK, stderr: "warning: something incidental\n")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 0)
    }

    /// The non-zero-exit branch — named in the review brief's own
    /// "check with particular care" list as one of the four cases a `send`
    /// implementation must distinguish from success, and the one the brief's
    /// own Step 1 test list omitted.
    @Test func aNonZeroSendExitIsAPermanentFailureCarryingWhatArrived() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 1, output: "Error: not logged in", stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.failureClass == .permanent)
        #expect(result.decodedError?.message.contains("not logged in") == true)
    }

    /// `ok` plus a `session_id` matching the id sent is the success
    /// condition — a reply about a DIFFERENT session is not a success.
    @Test func aMismatchedSessionIDInTheReplyIsAFailure() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: #"{"ok":true,"session_id":"session_01ZZZ"}"#, stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.decodedError?.message.contains("session_01ZZZ") == true)
    }

    @Test func anOkFalseReplyIsAFailure() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: #"{"ok":false,"session_id":"session_01AAA"}"#, stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 1)
    }

    /// Distinct from `ok:false`: the key is entirely ABSENT from the reply.
    /// `ClaudeCloudSendReply.ok` is `Bool?`, so a missing key must fail the
    /// `reply.ok == true` guard exactly like an explicit `false` — this pins
    /// that the decode's optionality, not a value comparison, is what makes
    /// that so.
    @Test func aReplyWithNoOkKeyAtAllIsAFailure() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: #"{"session_id":"session_01AAA"}"#, stderr: "")
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 1)
    }

    @Test func unparseableSendOutputIsAFailureCarryingWhatArrived() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: "not json", stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.decodedError?.message.contains("not json") == true)
    }

    @Test func anEmptyMessageIsRefusedBeforeAnythingIsSpawned() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 2)
        #expect(result.decodedError?.code == "invalid_params")
        #expect(spawner.requestsSnapshot().isEmpty)
    }

    @Test func aSendTimeoutIsTransientRatherThanPermanent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [.timedOut])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 3)
        #expect(result.failureClass == .transient)
    }

    /// Finding 8 (Minor): `send` used to hardcode `timeout: 30` instead of
    /// threading `run`'s caller-supplied timeout the way `create` already
    /// does. It worked today only because the sole production caller ALSO
    /// hardcodes 30 — so, matching `createThreadsTheCallersTimeoutIntoTheSpawnRequest`,
    /// a value that differs from both 30 and 60 is the only assertion that
    /// discriminates real wiring from that coincidence.
    @Test func sendThreadsTheCallersTimeoutIntoTheSpawnRequest() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: sendOK, stderr: "")])
        _ = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 91, contractVersion: 2)
        let request = try #require(spawner.requestsSnapshot().first)
        #expect(request.timeout == 91)
    }

    // MARK: - findings fixed in this pass

    /// Finding 1 (CRITICAL): the session-id cross-check used to scan the
    /// ENTIRE output, including the vendor's title line — and that line is
    /// the vendor's own server-derived summary of the user's PROMPT. A
    /// prompt that happens to mention a `session_`-shaped token (a filename,
    /// here) produced a second, spurious match and failed a create that had
    /// actually succeeded, permanently orphaning the real cloud session —
    /// there is no discovery to recover it by any other means.
    ///
    /// Confirmed failing against the pre-fix implementation: with the id scan
    /// running over the whole blob, this exact title yields
    /// `.conflictingSessionIDs(["session_01AAAAAAAAAAAAAAAAAAAAAA", "session_store"])`
    /// (the regex has no `_` in its character class, so it matches
    /// `session_store` out of `session_store_test.py` and stops there) — the
    /// create fails as a `contract_bug` even though `claude --cloud`
    /// succeeded. Restricting the scan to the `View:` and `Resume with:`
    /// lines — the two structurally-typed witnesses — is the fix: only the
    /// real id appears on either, so there is exactly one distinct match.
    @Test func aTitleThatEchoesAPromptMentioningASessionIDDoesNotFailTheCreate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let output = """
            Created cloud session: Fix the flake in session_store_test.py
            View: https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA?from=cli&m=0
            Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA
            """
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: output, stderr: "")])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"],
            stdin: createBody(prompt: "fix the flake in session_store_test.py"),
            timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 0)
        #expect(result.failureClass == nil)
        let session = try result.decoded(RemoteSessionPayload.self)
        #expect(session.id == "session_01AAAAAAAAAAAAAAAAAAAAAA")
        #expect(session.title == "Fix the flake in session_store_test.py")
        let row = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(row.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(row.sessionID == "session_01AAAAAAAAAAAAAAAAAAAAAA")
    }

    /// Finding 2: `list` used to omit `environment` from `meta` while
    /// `create` included it, so a value that safely round-tripped through the
    /// database vanished from every caller after the very next poll, with no
    /// discovery to ever re-supply it. `createIncludesEnvironmentInMetaWhenSupplied`
    /// pins the `create` half; this is the `list` counterpart the review
    /// found missing.
    @Test func listIncludesEnvironmentInMetaWhenPresentOnTheRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput, stderr: "")])
        let inv = invoker(db: db, spawner: spawner)
        _ = try await inv.run(config(), verb: ["create"],
                              stdin: createBody(environment: "prod"), timeout: 60, contractVersion: 2)
        let session = try #require(try listSessions(
            try await inv.run(config(), verb: ["list"], stdin: nil,
                              timeout: 30, contractVersion: 2)).first)
        let meta = try #require(session["meta"] as? [String: String])
        #expect(meta["environment"] == "prod")
    }

    /// Finding 5: nothing pinned that `send`'s failure message carries the
    /// vendor's STDERR. `send` runs on a pipe, where a CLI writes its errors
    /// to stderr — but both existing failure tests
    /// (`aNonZeroSendExitIsAPermanentFailureCarryingWhatArrived`,
    /// `unparseableSendOutputIsAFailureCarryingWhatArrived`) put the error
    /// text in `output` and leave `stderr` empty, so deleting `+ stderr` from
    /// the diagnostic — the tempting "simplification" right after the
    /// stdout/stderr-split fix landed, since `output` is what gets parsed —
    /// would stay green and leave a logged-out user with
    /// `claude -p --cloud exited 1: ` and nothing after the colon.
    @Test func aNonZeroSendExitCarriesVendorStderrEvenWhenOutputIsEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 1, output: "", stderr: "Error: not logged in"),
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["send", "session_01AAA"], stdin: Data("hi\r".utf8),
            timeout: 30, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.failureClass == .permanent)
        #expect(result.decodedError?.message.contains("not logged in") == true)
    }

    /// Finding 6 (Minor): a non-zero `create` exit used to always report
    /// `.noSessionID` — claiming "printed no session id" even when the id was
    /// sitting right there in the quoted evidence — and discarded it instead
    /// of recording it, orphaning a session that was genuinely created before
    /// some later step made the verb exit non-zero. The fix parses first and
    /// records a readable id even though the verb still reports failure.
    @Test func aNonZeroCreateExitThatStillPrintedASessionIDRecordsItRatherThanOrphaningIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 1, output: successOutput, stderr: ""),
        ])
        let result = try await invoker(db: db, spawner: spawner).run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(result.exitCode == 1)
        #expect(result.failureClass == .permanent)
        #expect(result.decodedError?.message.contains("session_01AAAAAAAAAAAAAAAAAAAAAA") == true)
        #expect(result.decodedError?.message.contains("printed no session id") == false)
        let row = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(row.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(row.sessionID == "session_01AAAAAAAAAAAAAAAAAAAAAA")
    }

    /// Finding 7 (Minor): `"\r\n"` is ONE `Character` (grapheme cluster) in
    /// Swift, distinct from both `"\r"` and `"\n"` — the same trap the title
    /// parser (`ClaudeCloudCreateOutputParser.title(fromOutput:)`) was
    /// already bitten by and fixed for. Built by explicit concatenation, not
    /// a triple-quoted literal: Swift's multiline string literals normalize
    /// to bare `\n`, so a literal could never construct a real CRLF to catch
    /// this regression.
    @Test func theSubmitGestureStripsATrailingCRLFAsOneGrapheme() {
        let crlf = "hello" + "\r\n"
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data(crlf.utf8)) == "hello")
        // Interior CRLF must still survive, exactly like interior `\n` does.
        let interiorAndTrailing = "one" + "\r\n" + "two" + "\r\n"
        #expect(ClaudeCloudSendPayload.message(fromStdin: Data(interiorAndTrailing.utf8))
            == "one" + "\r\n" + "two")
    }

    /// Two replays of a key the pending window already gave up on must
    /// produce exactly ONE spawn.
    ///
    /// The gate is what makes this discriminating rather than lucky: it holds
    /// the first spawn open, so the second `create` provably does its own
    /// claim while the first is still in flight. Two bare concurrent calls
    /// need not interleave at all, and would pass against the very race this
    /// exists to catch.
    ///
    /// Asserted on the SPAWN count, not the row count: the unique index on
    /// `idempotencyKey` keeps the ledger at one row either way, so a row-count
    /// assertion is exactly the one that cannot see this bug. A second spawn
    /// starts a second real cloud session, and with no discovery to reconcile
    /// the two, whichever `resolve` lands second overwrites the first id.
    @Test func twoConcurrentReplaysOfAFailedKeySpawnOnlyOnce() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: "fix-ci", environment: nil, paramsJSON: "{}",
            now: Date(timeIntervalSince1970: 1_000_000))
        try await db.claudeCloudSessions.markFailed(ids: [row.id])

        let gate = SpawnGate()
        let spawner = GatedClaudeSpawner(
            gate: gate, outcome: .completed(status: 0, output: successOutput, stderr: ""))
        let inv = gatedInvoker(db: db, spawner: spawner)

        async let firstResult = inv.run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        // Resumes only once the first spawn is genuinely under way.
        await gate.waitUntilEntered()
        let second = try await inv.run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        await gate.release()
        let first = try await firstResult

        #expect(spawner.requestsSnapshot().count == 1)
        #expect(first.exitCode == 0)
        #expect(second.exitCode == 3)
        #expect(second.failureClass == .transient)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    /// The bug `claimForSpawn`'s own doc comment claims not to have: a
    /// reclaim UPDATE that rewrote `state` back to `pending` but left
    /// `createdAt` alone left the pending-failure window still measuring
    /// from the ORIGINAL attempt's timestamp, so a `list()` poll landing
    /// after that original window — but well inside a fresh one — re-failed
    /// a row whose reclaiming spawn was still genuinely in flight. A further
    /// replay then read `failed` again and reclaimed AND SPAWNED a second
    /// time: the exact double-spawn hazard `claimForSpawn` exists to close.
    ///
    /// The gate is what makes this discriminating rather than lucky: it
    /// holds the reclaiming spawn open, so the `list()` poll and the third
    /// replay both provably land while that spawn is still running, not
    /// after it quietly finished.
    @Test func aReclaimSurvivesAListPollBeforeItResolves() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)

        let originalCreatedAt = Date(timeIntervalSince1970: 1_000_000)
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: "fix-ci", environment: nil, paramsJSON: "{}", now: originalCreatedAt)

        // Age the row past the pending window so a `list()` marks it
        // `failed` — the precondition a reclaim needs to observe.
        let markFailedAt = originalCreatedAt.addingTimeInterval(601)
        _ = try await invoker(
            db: db, spawner: FakeClaudeSpawner(outcomes: []), now: { markFailedAt }
        ).run(config(), verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)
        #expect(try await db.claudeCloudSessions.rows().first?.state
            == ClaudeCloudLedgerState.failed.rawValue)

        // Reclaim: a same-key `create` replay standing in for a spawn
        // genuinely in flight. `reclaimAt` is what a correct reclaim stamps
        // as the row's NEW `createdAt`.
        let reclaimAt = markFailedAt
        let gate = SpawnGate()
        let spawner = GatedClaudeSpawner(
            gate: gate, outcome: .completed(status: 0, output: successOutput, stderr: ""))
        let reclaimInvoker = ClaudeCloudInvoker(db: db, spawner: spawner, now: { reclaimAt })

        async let reclaimResult = reclaimInvoker.run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        // Resumes only once the reclaim's spawn is genuinely under way, so
        // the poll below races a real in-flight spawn rather than a
        // completed one.
        await gate.waitUntilEntered()

        // The discriminating poll. `pollAt` is chosen so the two readings of
        // "how old is this row" disagree: 300s elapsed measured from
        // `reclaimAt` (INSIDE the 600s window — a correct reclaim keeps the
        // row `pending`), but 901s elapsed measured from the untouched
        // `originalCreatedAt` (OUTSIDE the window — the bug re-fails the row
        // here, while the reclaiming spawn is still running).
        let pollAt = reclaimAt.addingTimeInterval(300)
        _ = try await invoker(
            db: db, spawner: FakeClaudeSpawner(outcomes: []), now: { pollAt }
        ).run(config(), verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)
        let polled = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(polled.state == ClaudeCloudLedgerState.pending.rawValue)

        // The consequence: with the row correctly still `pending`, a THIRD
        // replay of the same key must be refused rather than spawning a
        // second real cloud session. Reuses the SAME gated spawner so its
        // request count is the discriminator — the unique index on
        // `idempotencyKey` pins the ROW count at one either way, which is
        // exactly why a row-count assertion cannot see this class of bug.
        let thirdInvoker = ClaudeCloudInvoker(db: db, spawner: spawner, now: { pollAt })
        let thirdResult = try await thirdInvoker.run(
            config(), verb: ["create"], stdin: createBody(), timeout: 60, contractVersion: 2)
        #expect(thirdResult.exitCode == 3)
        #expect(thirdResult.decodedError?.code == "in_progress")
        #expect(spawner.requestsSnapshot().count == 1)

        await gate.release()
        let reclaimed = try await reclaimResult
        #expect(reclaimed.exitCode == 0)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    private func gatedInvoker(
        db: TBDDatabase, spawner: GatedClaudeSpawner,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) }
    ) -> ClaudeCloudInvoker {
        ClaudeCloudInvoker(db: db, spawner: spawner, now: now)
    }
}

/// Lets a test hold one spawn open and observe that it started.
actor SpawnGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releasedFlag = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releasedFlag = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }

    func waitUntilReleased() async {
        if releasedFlag { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

/// Records every spawn and parks the FIRST one until the test releases it, so
/// a concurrency test can put a second caller through its claim while the
/// first is provably still spawning.
final class GatedClaudeSpawner: ClaudeCloudSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ClaudeCloudSpawnRequest] = []
    private let gate: SpawnGate
    private let outcome: ClaudeCloudSpawnOutcome

    init(gate: SpawnGate, outcome: ClaudeCloudSpawnOutcome) {
        self.gate = gate
        self.outcome = outcome
    }

    func spawn(_ request: ClaudeCloudSpawnRequest) async throws -> ClaudeCloudSpawnOutcome {
        if record(request) {
            await gate.markEntered()
            await gate.waitUntilReleased()
        }
        return outcome
    }

    /// Synchronous so the NSLock critical section is not taken from an async
    /// context. Returns whether this was the first spawn.
    private func record(_ request: ClaudeCloudSpawnRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.count == 1
    }

    func requestsSnapshot() -> [ClaudeCloudSpawnRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
