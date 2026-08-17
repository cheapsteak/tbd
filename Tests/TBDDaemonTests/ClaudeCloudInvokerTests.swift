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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
            .completed(status: 0, output: "Something went sideways")
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
                """)
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
                "Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA")
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
    /// create, not from the retry.
    @Test func replayingTheSameIdempotencyKeyReusesTheSameLedgerRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 0, output: successOutput),
            .completed(status: 0, output: successOutput),
        ])
        let inv = invoker(db: db, spawner: spawner)
        _ = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        _ = try await inv.run(config(), verb: ["create"], stdin: createBody(),
                              timeout: 60, contractVersion: 2)
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    @Test func aNonZeroVendorExitIsAPermanentFailureCarryingItsOutput() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await seedRepo(db)
        let spawner = FakeClaudeSpawner(outcomes: [
            .completed(status: 1, output: "Error: not logged in")
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
        let spawner = FakeClaudeSpawner(outcomes: [.completed(status: 0, output: successOutput)])
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
}
