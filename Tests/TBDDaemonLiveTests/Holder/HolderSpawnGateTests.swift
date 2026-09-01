import Clocks
import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The gate that decides which transport a new session is born onto, and the
/// read that renders it afterwards.
///
/// Both branches, because `pty_holder_enabled` is a behaviour-gating
/// conditional. The two that carry the most weight are not the happy paths:
///
///   - `terminalOutputReadsTheHolderEmulator` asserts that `capture-pane` was
///     **never called**. A handler that rendered the emulator *and* captured a
///     pane would satisfy every assertion about the returned text while still
///     shelling out to a tmux server the holder transport exists to avoid.
///   - `flagFlipDoesNotMigrateRunningSessions` flips the flag off under a live
///     session. The flag gates spawning, not servicing: a running holder owns a
///     pty that already exists, and no preference can un-own it.
///
/// Every holder here runs a **controlled** program, never the developer's login
/// shell or a real agent. The lever is the registry's `environment`: it is the
/// daemon's own environment in production — which is exactly what the tmux path
/// reads `$SHELL` from, through the server it started — so pinning it here
/// pins the shell the production composition picks, without touching the
/// production composition.
@Suite(.serialized)
struct HolderSpawnGateTests {

    // MARK: - The gate

    /// Flag off: today's behaviour, unchanged, and no rendezvous anywhere.
    ///
    /// The socket assertion is the one that would catch a gate that spawned a
    /// holder *and* a window: the row would still read `.tmux`, and only the
    /// absence of the rendezvous says nothing was started behind it.
    @Test func flagOffSpawnsOntoTmux() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .tmux)
        #expect(!primary.tmuxWindowID.isEmpty, "a tmux session was created with no window")
        #expect(primary.holderPID == nil)
        #expect(primary.childPID == nil)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: primary.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created for a tmux-transport session")

        // The unchanged half of the setup-hook decision: with the flag off the
        // Setup tab is created whether or not the repo has a hook, exactly as
        // it always has been.
        #expect(created.count == 2)
        #expect(created[1].label == TerminalLabel.setup)
    }

    /// Flag on: a real holder, a real job, and a row that names both.
    ///
    /// `holderPID` and `childPID` are asserted separately and both are checked
    /// for liveness, because holder death is deliberately not child death — a
    /// row that recorded one pid twice would look fine here and be unable to
    /// reclaim anything later.
    @Test func flagOnSpawnsOntoHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .holder)
        let holderPID = try #require(primary.holderPID)
        let childPID = try #require(primary.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(primary.tmuxWindowID.isEmpty)
        #expect(primary.tmuxPaneID.isEmpty)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: primary.id, environment: fixture.environment)
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "no holder rendezvous at \(socketPath) for a holder-transport session")

        // The other half of the setup-hook decision: this repo has no setup
        // hook, so on the holder path no tmux server is started for a bare
        // shell — and no `new-window` was ever issued.
        #expect(created.count == 1)
        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the holder path created a tmux window: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the holder path started a tmux server: \(issued)")
    }

    /// Flag on, registry present, but nothing to spawn with: the create still
    /// succeeds, on tmux.
    ///
    /// This is the shape a real daemon has whenever its `TBDHolder` binary is
    /// missing — an upgrade that moved it, a partial build — because
    /// `Daemon.swift` builds the registry regardless: adoption of an
    /// already-running holder needs no executable, and a user whose sessions are
    /// live must not lose them. So the gate cannot read "registry present" as
    /// "can spawn". If it does, `spawn` throws `holderExecutableUnavailable`
    /// with nothing catching it and the whole worktree create fails — a flag
    /// that is merely on takes the user's ability to open a worktree away.
    @Test func missingHolderBinaryFallsBackToTmuxInsteadOfFailingTheCreate() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true, spawnerAvailable: false)
        defer { fixture.tearDown() }

        #expect(
            fixture.registry.canSpawn == false,
            "the fixture did not reproduce a registry with no spawner")

        let created = try await fixture.spawnPrimaryTerminals()

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .tmux)
        #expect(!primary.tmuxWindowID.isEmpty)
        #expect(primary.holderPID == nil)
        #expect(primary.childPID == nil)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: primary.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created by a registry that cannot spawn")

        // And the fallback is the tmux path *whole*, not a half-taken holder
        // path: the Setup tab is created unconditionally there, exactly as with
        // the flag off.
        #expect(created.count == 2)
        #expect(created[1].label == TerminalLabel.setup)
    }

    // MARK: - The read

    /// `terminal.output` on a holder row renders the daemon's emulator, and
    /// `capture-pane` is never reached.
    ///
    /// The negative half is asserted two ways on purpose. The call counter
    /// catches a handler that captured a pane and threw the result away; the
    /// poisoned capture text catches one that captured a pane and *returned*
    /// it, which a counter alone would report as a pass if the count assertion
    /// were ever relaxed.
    @Test func terminalOutputReadsTheHolderEmulator() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let terminalID = created[0].id

        let output = try await pollUntil("the job's output to reach the daemon's emulator") {
            let text = try await fixture.terminalOutput(terminalID: terminalID)
            return text.contains("GATE-OK")
        }
        let rendered = try await fixture.terminalOutput(terminalID: terminalID)
        #expect(output, "rendered: \(rendered.debugDescription)")
        #expect(!rendered.contains(GateFixture.poisonedPaneText))
        #expect(
            fixture.capturePaneCalls() == 0,
            "terminal.output shelled out to tmux capture-pane for a holder session")
    }

    /// A tmux row still reads through `capture-pane`.
    ///
    /// The branch's other arm: without this, a read that always rendered the
    /// emulator (or always answered "no reader") would pass every assertion
    /// above.
    @Test func terminalOutputStillCapturesPanesForTmuxSessions() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let rendered = try await fixture.terminalOutput(terminalID: created[0].id)

        #expect(rendered.contains(GateFixture.poisonedPaneText))
        #expect(fixture.capturePaneCalls() == 1)
    }

    // MARK: - The flag gates spawning, not servicing

    /// Flipping the flag off does not migrate a session that is already
    /// running.
    ///
    /// Its pty exists, its job is attached to it, and a preference cannot undo
    /// either. So the row must still read `.holder` and must still serve its
    /// screen — and a *new* session created afterwards must land on tmux, which
    /// is what proves the flip took effect at all rather than being ignored.
    @Test func flagFlipDoesNotMigrateRunningSessions() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let terminalID = created[0].id
        let served = try await pollUntil("the holder session's first output") {
            try await fixture.terminalOutput(terminalID: terminalID).contains("GATE-OK")
        }
        #expect(served)

        try await fixture.db.config.setPtyHolderEnabled(false)

        let afterFlip = try #require(try await fixture.db.terminals.get(id: terminalID))
        #expect(afterFlip.transport == .holder, "flipping the flag migrated a live session")
        #expect(afterFlip.holderPID != nil)
        let stillServed = try await fixture.terminalOutput(terminalID: terminalID)
        #expect(
            stillServed.contains("GATE-OK"),
            "a live holder session stopped serving output when the flag went off")
        #expect(fixture.capturePaneCalls() == 0)

        // And the flip is not a no-op: the next session lands on tmux.
        let second = try await fixture.spawnPrimaryTerminals()
        let secondPrimary = try #require(try await fixture.db.terminals.get(id: second[0].id))
        #expect(secondPrimary.transport == .tmux)
    }

    // MARK: - What the holder path deliberately does NOT do

    /// Session recapture is scheduled for a tmux primary and not for a holder
    /// one.
    ///
    /// Recapture reads a tmux pane's process, and a holder row's `paneID` is
    /// empty by construction, so scheduling it there polls a coordinate that
    /// can never resolve — and, worse, would then write whatever it *did* find
    /// onto the holder row.
    ///
    /// **Both arms run in one test, in this order, and that is the whole
    /// instrument.** The negative alone would pass just as well against a
    /// recapture that never fires for anybody. The holder session is created
    /// first, and the probe's clock is immediate, so a recapture armed for it
    /// would have recorded its pane before the tmux control's did; observing
    /// the control's write is therefore proof that the holder's absence is real
    /// and not merely early. The pane list is asserted whole rather than
    /// searched, so a holder pane appearing alongside the tmux one still fails.
    @Test func recaptureIsScheduledForTmuxSessionsAndNotForHolderOnes() async throws {
        let recapture = RecaptureProbe()
        let fixture = try await GateFixture.make(flagEnabled: true, recapture: recapture)
        defer { fixture.tearDown() }

        let holderCreated = try await fixture.spawnClaudePrimaryTerminals(
            carryover: ConversationCarryover(
                sourceSessionID: "HOLDER-SOURCE", notesSeed: "# carried\n"))
        let holderID = holderCreated[0].id
        let holderRow = try #require(try await fixture.db.terminals.get(id: holderID))
        #expect(holderRow.transport == .holder)
        #expect(holderRow.tmuxPaneID.isEmpty)

        try await fixture.db.config.setPtyHolderEnabled(false)
        let tmuxCreated = try await fixture.spawnClaudePrimaryTerminals(
            carryover: ConversationCarryover(
                sourceSessionID: "TMUX-SOURCE", notesSeed: "# carried\n"))
        let tmuxID = tmuxCreated[0].id
        let tmuxRow = try #require(try await fixture.db.terminals.get(id: tmuxID))
        #expect(tmuxRow.transport == .tmux)

        // The control. Its scheduler runs on virtual time, so this waits only
        // for the recapture task to be *scheduled*, not for a delay to elapse.
        // The deadline is a hang-catcher sized against the fast parallel pass,
        // where a runnable task can sit behind thousands of others — the
        // suite's 20 s default timed out on a box at load average 30 with the
        // capture never having run. It costs a passing run nothing.
        let landed = try await pollUntil(
            "the tmux session's recapture to write", timeout: 90
        ) {
            try await fixture.db.terminals.get(id: tmuxID)?.claudeSessionID
                == RecaptureProbe.detectedSessionID
        }
        #expect(landed)
        #expect(recapture.panes == [tmuxRow.tmuxPaneID])

        let holderAfter = try #require(try await fixture.db.terminals.get(id: holderID))
        #expect(
            holderAfter.claudeSessionID == "HOLDER-SOURCE",
            """
            recapture ran against a holder session and overwrote its session ID \
            with \(holderAfter.claudeSessionID ?? "nil")
            """)
    }

    /// Archived-session restores stay on tmux even when the primary is a
    /// holder — and the holder path starts the tmux server they need.
    ///
    /// Milestone A soaks exactly one holder per worktree, so the extra restored
    /// sessions are tmux windows. That is only sound if the server exists: the
    /// holder path skips the eager `ensureServer` the tmux path does, so the
    /// restore loop must ask for one itself. The `new-session` assertion is
    /// what holds it to that — a restore issued into a server nobody started
    /// would still produce a row here and fail only in production.
    @Test func archivedSessionRestoresStayOnTmuxUnderAHolderPrimary() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnClaudePrimaryTerminals(
            archivedClaudeSessions: ["ARCHIVED-PRIMARY", "ARCHIVED-RESTORED"])

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .holder, "the primary did not take the holder path")
        #expect(primary.claudeSessionID == "ARCHIVED-PRIMARY")

        let restored = try #require(
            try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
                .first { $0.claudeSessionID == "ARCHIVED-RESTORED" },
            "the second archived session was never restored")
        #expect(
            restored.transport == .tmux,
            "an archived-session restore was put on the holder transport")
        #expect(!restored.tmuxWindowID.isEmpty)
        #expect(!restored.tmuxPaneID.isEmpty)
        #expect(restored.holderPID == nil)
        #expect(restored.childPID == nil)

        let issued = fixture.tmuxCommands()
        #expect(
            issued.contains(where: { $0.contains("new-session") }),
            "the restore ran without the holder path ever starting a tmux server: \(issued)")
        #expect(
            issued.contains(where: {
                $0.contains("new-window") && $0.contains("--resume ARCHIVED-RESTORED")
            }),
            "no tmux window was created to resume the archived session: \(issued)")
    }
}

// MARK: - Recapture probe

/// The scheduler the create path is given in place of the real one, and the
/// record of every pane it was asked about.
///
/// Two things it deliberately does not do. It never reaches
/// `ClaudeStateDetector`, which would read a session file at a **process-wide**
/// path (`$TBD_CLAUDE_HOST_HOME/sessions/<pane pid>.json`, and a dry-run pane
/// PID is always `0`) — a file every other create-path suite's recapture would
/// read too, which is a cross-suite coupling, not a fixture. And it runs on
/// `ImmediateClock`, so the branch is asserted without waiting out the
/// production five seconds.
private final class RecaptureProbe: @unchecked Sendable {
    static let detectedSessionID = "RECAPTURED-BY-THE-PROBE"

    private let lock = NSLock()
    private var recorded: [String] = []

    /// The panes recapture was scheduled against, in order.
    var panes: [String] {
        lock.withLock { recorded }
    }

    func scheduler(db: TBDDatabase, tmux: TmuxManager) -> SessionRecaptureScheduler {
        SessionRecaptureScheduler(
            db: db,
            tmux: tmux,
            // `withLock` rather than `lock()`/`unlock()`: this closure is
            // `async`, where the unscoped pair is unavailable.
            captureSessionID: { [self] _, paneID in
                lock.withLock { recorded.append(paneID) }
                return Self.detectedSessionID
            },
            clock: ImmediateClock())
    }
}

// MARK: - Fixture

/// A worktree, a database, a router and a registry, wired the way the daemon
/// wires them — one registry shared by the spawn path and the read path.
///
/// Three rules it exists to enforce:
///
///   1. **Nothing reaches the developer's `~/tbd`.** Every rendezvous path is
///      derived from an explicit environment dictionary.
///   2. **Nothing runs the developer's shell, or a real agent.** The pinned
///      `SHELL` in that same dictionary is a two-line script.
///   3. **Every holder and every job is killed in teardown.** Holder death is
///      not child death, so both are named.
private final class GateFixture {
    /// What a dry-run `capture-pane` answers. Deliberately a string no holder
    /// emulator could produce, so a read that went through tmux is visible in
    /// the returned text and not only in a counter.
    static let poisonedPaneText = "TMUX-CAPTURE-PANE-WAS-CALLED"

    let db: TBDDatabase
    let router: RPCRouter
    let registry: HolderRegistry
    let environment: [String: String]
    let worktree: Worktree
    let repo: Repo
    private let home: String
    private let tempDir: URL
    private let capturePaneCounter: Counter
    private let recordedCommands: CommandLog
    private var torndown = false

    /// A thread-safe tally. The dry-run hooks are `@Sendable` closures called
    /// from whatever executor the handler happens to be on.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            entries.append(argv.joined(separator: " "))
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    /// A short scratch root: the rendezvous socket lives under it and
    /// `sun_path` is 104 bytes, so a deep `TMPDIR` fails the bind rather than
    /// the assertion.
    private static func scratchHome() -> String {
        "/tmp/tbdg10-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The stand-in login shell. It ignores the `-i -l -c <command>` argv the
    /// production composition hands it, which is the point: the job is a
    /// controlled two-line program instead of whatever the developer's `$SHELL`
    /// would have done with it.
    private static func writeGateShell(in home: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = "\(home)/gate-shell"
        try """
        #!/bin/sh
        printf 'GATE-OK\\n'
        exec sleep 30
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// - Parameter spawnerAvailable: whether the registry is given a
    ///   `HolderSpawner`. `false` is the shape a daemon has when no `TBDHolder`
    ///   binary sits beside it: `Daemon.swift` still builds the registry, so
    ///   the gate sees a non-nil one that cannot start anything.
    static func make(
        flagEnabled: Bool,
        spawnerAvailable: Bool = true,
        recapture: RecaptureProbe? = nil
    ) async throws -> GateFixture {
        let home = scratchHome()
        let shell = try writeGateShell(in: home)
        let environment = [
            "TBD_HOME": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": shell,
        ]

        let capturePaneCounter = Counter()
        let recordedCommands = CommandLog()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { argv in recordedCommands.append(argv) },
            dryRunCapturePane: { _, _ in
                capturePaneCounter.increment()
                return poisonedPaneText
            })

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(flagEnabled)

        let spawner: HolderSpawner?
        if spawnerAvailable {
            let executable = try #require(
                HolderProcessFixture.locateExecutable(),
                "TBDHolder must be built beside the test bundle")
            spawner = HolderSpawner(executableURL: executable)
        } else {
            spawner = nil
        }
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: spawner)

        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))

        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            // The Claude spawn branch below seeds folder trust and resolves a
            // projects root through this manager. Injected at the fixture's own
            // scratch root so neither reaches the developer's store — the seam
            // `Tests/CLAUDE.md` names, rather than a `setenv`.
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: URL(fileURLWithPath: home)
                    .appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: URL(fileURLWithPath: home)
                    .appendingPathComponent("claude", isDirectory: true)))
        lifecycle.holderRegistry = registry
        if let recapture {
            lifecycle.sessionRecaptureFactory = { db, tmux in
                recapture.scheduler(db: db, tmux: tmux)
            }
        }
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            actuationLog: makeTestActuationLog())
        router.holderRegistry = registry

        return GateFixture(
            db: db, router: router, registry: registry, environment: environment,
            worktree: worktree, repo: repo, home: home, tempDir: tempDir,
            capturePaneCounter: capturePaneCounter, recordedCommands: recordedCommands)
    }

    private init(
        db: TBDDatabase, router: RPCRouter, registry: HolderRegistry,
        environment: [String: String], worktree: Worktree, repo: Repo,
        home: String, tempDir: URL,
        capturePaneCounter: Counter, recordedCommands: CommandLog
    ) {
        self.db = db
        self.router = router
        self.registry = registry
        self.environment = environment
        self.worktree = worktree
        self.repo = repo
        self.home = home
        self.tempDir = tempDir
        self.capturePaneCounter = capturePaneCounter
        self.recordedCommands = recordedCommands
    }

    /// The production spawn path, entered exactly as `worktree.create` enters
    /// it. `skipClaude` keeps the primary a plain shell so no agent binary is
    /// consulted; what it actually runs is the pinned `SHELL` above.
    func spawnPrimaryTerminals() async throws -> [(id: UUID, label: String)] {
        try await router.lifecycle.spawnPrimaryTerminals(
            worktree: worktree, repo: repo, skipClaude: true, preSessionTerminalID: nil)
    }

    /// The same production entry point, for the two callers that need the
    /// Claude branch: a conversation carryover (which is what schedules session
    /// recapture) and an archived-session restore.
    func spawnClaudePrimaryTerminals(
        archivedClaudeSessions: [String]? = nil,
        carryover: ConversationCarryover? = nil
    ) async throws -> [(id: UUID, label: String)] {
        try await router.lifecycle.spawnPrimaryTerminals(
            worktree: worktree, repo: repo, skipClaude: false,
            archivedClaudeSessions: archivedClaudeSessions,
            preSessionTerminalID: nil,
            carryover: carryover)
    }

    /// The `terminal.output` RPC, through the router's real handler.
    func terminalOutput(terminalID: UUID, lines: Int? = nil) async throws -> String {
        let params = try JSONEncoder().encode(
            TerminalOutputParams(terminalID: terminalID, lines: lines))
        let response = try await router.handleTerminalOutput(params)
        if let error = response.error {
            Issue.record("terminal.output failed: \(error)")
            return ""
        }
        let result = try #require(response.result)
        return try JSONDecoder()
            .decode(TerminalOutputResult.self, from: Data(result.utf8)).output
    }

    func capturePaneCalls() -> Int { capturePaneCounter.count }
    func tmuxCommands() -> [String] { recordedCommands.all }

    /// Kills every holder this fixture started AND every job those holders
    /// forked, then clears the scratch roots. A test that leaves either behind
    /// leaks a process for the rest of the run — bounded at the job's own
    /// `sleep 30`, but it compounds across runs.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        let rows = (try? blockingTerminals()) ?? []
        for row in rows where row.transport == .holder {
            if let holderPID = row.holderPID, holderPID > 0 {
                kill(holderPID, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(holderPID, &ignored, 0)
            }
            if let childPID = row.childPID, childPID > 0, holderProcessIsAlive(childPID) {
                kill(childPID, SIGKILL)
            }
        }
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        try? FileManager.default.removeItem(atPath: home)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Reads the terminal rows from a non-async `tearDown`. Bounded, and a
    /// timeout simply means the sweep below has nothing to kill by pid — the
    /// suite would rather report that than hang.
    private func blockingTerminals() throws -> [Terminal] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let db = self.db
        Task.detached {
            box.value = try? await db.terminals.list()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return box.value ?? []
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [Terminal]?
    }
}
