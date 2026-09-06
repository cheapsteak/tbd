import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Park and wake against a **real** holder and a **real** job.
///
/// The scripted suites state the rules; this one proves them against the
/// kernel's own answers, because the property the soak is for is not a return
/// value: it is that the process is actually gone when the row says parked, and
/// actually running when the row says awake. Nothing but a real pid can say
/// either.
///
/// Tier 3, and every rule the holder fixtures carry applies here: a scratch
/// `TBD_HOME` under the run root the wrapper reclaims, rc-free `/bin/sh` jobs, a
/// pinned `SHELL` and `PATH` so no developer profile and no real agent binary is
/// ever reached, bounded waits everywhere, and a teardown that kills the holder
/// AND the job — holder death is deliberately not child death.
@Suite(.serialized)
struct HolderHibernationLiveTests {

    /// The park's whole point, against a job that cannot cooperate.
    ///
    /// `while :; do sleep 1; done` never reads its terminal, so the polite
    /// `/exit` cannot possibly work and the escalation is what has to end it.
    /// That is deliberately the harder half: a test whose job exited on `/exit`
    /// would pass without the escalation ever running.
    @Test func parkEndsTheJobAndClearsTheRow() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let childPID = try #require(terminal.childPID)
        let holderPID = try #require(terminal.holderPID)

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .ok, "park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(parked.claudeSessionID == HibernationFixture.sessionID)
        // A parked row names no processes. These three move together: a pid
        // without its start time is a pid nothing may signal, and either one
        // left behind points the reaper at a number the kernel has recycled.
        #expect(parked.holderPID == nil)
        #expect(parked.childPID == nil)
        #expect(parked.holderChildStartedAt == nil)

        // The invariant, asked of the kernel rather than of the row. ESRCH is
        // the only answer that means gone: EPERM would mean alive and owned by
        // somebody else, which on a shared box is a real possibility for a
        // recycled pid.
        // `errno` is captured on the next line rather than read inside the
        // expectation: the message is an autoclosure, evaluated only on
        // failure, by which time any intervening libc call has clobbered it.
        let signalled = kill(childPID, 0)
        let signalErrno = errno
        #expect(signalled == -1 && signalErrno == ESRCH,
                "the job survived a park that reported .ok (kill returned \(signalled), errno \(signalErrno))")
        #expect(!holderProcessIsAlive(holderPID), "the holder outlived the park")
        #expect(await fixture.registry.reader(for: terminal.id) == nil,
                "the daemon is still draining a pty for a parked session")
    }

    /// Wake after that park: a fresh holder, a fresh job, and a row that names
    /// both and is no longer parked.
    ///
    /// The command the wake builds is `claude --resume …`, and nothing here
    /// runs it: `WorktreeLifecycle.holderLaunch` hands it to the registry's
    /// pinned `SHELL`, which is a two-line script that ignores its argv. That
    /// is the same lever `HolderSpawnGateTests` uses, and it is what keeps a
    /// live-process test off both the developer's login shell and a real agent.
    @Test func wakeStartsAFreshHolderAndUnparksTheRow() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()

        #expect(await fixture.coordinator.manualHibernate(terminalID: terminal.id) == .ok)

        let result = await fixture.coordinator.wake(terminalID: terminal.id)
        #expect(result == .ok, "wake refused: \(result)")

        let woken = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!woken.isParked)
        let holderPID = try #require(woken.holderPID, "the woken row records no holder")
        let childPID = try #require(woken.childPID, "the woken row records no child")
        #expect(holderPID != childPID, "one pid was recorded twice")
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        // The identity anchor for the NEW child. Without it the reaper would
        // measure this process against a row created before the park and read
        // it as a stranger.
        let startedAt = try #require(
            woken.holderChildStartedAt, "the woken row records no child start time")
        #expect(abs(startedAt.timeIntervalSince(Date())) < 300)
        #expect(await fixture.registry.reader(for: terminal.id) != nil,
                "nothing is draining the woken session's pty")

        // Tear the woken session down through the same door the delete path
        // uses, so neither the holder nor its job outlives the test.
        _ = await fixture.registry.abandon(terminal: woken)
        _ = await pollUntil("the woken job to be reclaimed") {
            !holderProcessIsAlive(childPID)
        }
        // Row-driven teardown must not signal these numbers afterwards: they
        // are free now, and the next process to take one is somebody else's.
        try await fixture.db.terminals.setHolderProcess(
            id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
    }

    /// The gate's OFF branch, on the same live fixture: the park is refused by
    /// name and the job is still there afterwards.
    ///
    /// Asserting on the surviving pid is what makes this a test of the gate
    /// rather than of a string — a refusal that had already written `/exit` or
    /// killed the job would return the same value.
    @Test func withTheFlagOffTheParkIsRefusedAndTheJobSurvives() async throws {
        let fixture = try await HibernationFixture.make(holderHibernationEnabled: false)
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let childPID = try #require(terminal.childPID)

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .notEligible(reason: HibernationCoordinator.holderTransportRefusal))

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!after.isParked, "a refused park still parked the row")
        #expect(after.childPID == childPID, "a refused park still cleared the row's pids")
        #expect(holderProcessIsAlive(childPID), "a refused park still ended the job")

        // And the wake half of the same gate, on a row parked out of band.
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: HibernationFixture.sessionID, reason: .manual)
        #expect(await fixture.coordinator.wake(terminalID: terminal.id) == .holderTransport)
        #expect(holderProcessIsAlive(childPID))
    }
}

// MARK: - Fixture

/// A database, a worktree, a real `HolderRegistry` with a real spawner, and a
/// coordinator wired to both — assembled the way `Daemon.swift` assembles them.
private final class HibernationFixture {
    /// The session id the row carries and the wake resumes. Never reaches a
    /// real Claude: the pinned shell ignores the argv it is handed.
    static let sessionID = "sess-holder-hibernation"

    /// A job that cannot cooperate with `/exit`: it never reads its terminal,
    /// so the polite poll must fail and the escalation must be what ends it.
    private static let uncooperativeJob = "while :; do sleep 1; done"

    let db: TBDDatabase
    let registry: HolderRegistry
    let coordinator: HibernationCoordinator
    let environment: [String: String]
    let worktree: Worktree
    private let home: String
    private let tempDir: URL
    private var torndown = false

    /// A short scratch root under the run root `scripts/test.sh` reclaims: the
    /// rendezvous socket lives under it and `sun_path` is 104 bytes, so a deeper
    /// root fails the bind rather than the assertion.
    private static func scratchHome() -> String {
        fencedScratchRoot(prefix: "tbdhib")
    }

    /// The stand-in login shell the WAKE spawn runs. It ignores the
    /// `-i -l -c <command>` argv the production composition hands it, which is
    /// the point: the resumed "agent" is a controlled two-line program.
    private static func writeGateShell(in home: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = "\(home)/gate-shell"
        try """
        #!/bin/sh
        printf 'WOKE-OK\\n'
        exec sleep 30
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    static func make(holderHibernationEnabled: Bool = true) async throws -> HibernationFixture {
        let home = scratchHome()
        let shell = try writeGateShell(in: home)
        let environment = [
            "TBD_HOME": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": shell,
        ]

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setHolderHibernationEnabled(holderHibernationEnabled)

        let executable = try #require(
            HolderProcessFixture.locateExecutable(),
            "TBDHolder must be built beside the test bundle")
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: HolderSpawner(executableURL: executable))

        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))

        let coordinator = HibernationCoordinator(
            db: db,
            // Dry-run and never reached: both branches under test fork away
            // from tmux before the first call. A recorder is not needed here —
            // `HolderTmuxAssumptionGateTests` asserts the "no tmux was touched"
            // half without spawning anything.
            tmux: TmuxManager(dryRun: true),
            // The profile/host stores the wake preamble seeds folder trust and
            // resolves a projects root through, kept inside this fixture's own
            // scratch root.
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: URL(fileURLWithPath: home)
                    .appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: URL(fileURLWithPath: home)
                    .appendingPathComponent("claude", isDirectory: true)),
            // Two attempts at 100 ms is the polite window; the job cannot use
            // it, so the run pays 200 ms to reach the escalation rather than
            // the shipped three seconds. The escalation budget is generous by
            // contrast — it is a real `SIGKILL` leaving a real process table on
            // a machine that may be loaded, and a short budget there would fail
            // this test for scheduling rather than for behaviour.
            exitPollAttempts: 2,
            exitPollInterval: .milliseconds(100),
            holderEscalationAttempts: 100,
            actuationLog: makeTestActuationLog())
        await coordinator.setHolderRegistry(registry)

        return HibernationFixture(
            db: db, registry: registry, coordinator: coordinator, environment: environment,
            worktree: worktree, home: home, tempDir: tempDir)
    }

    private init(
        db: TBDDatabase, registry: HolderRegistry, coordinator: HibernationCoordinator,
        environment: [String: String], worktree: Worktree, home: String, tempDir: URL
    ) {
        self.db = db
        self.registry = registry
        self.coordinator = coordinator
        self.environment = environment
        self.worktree = worktree
        self.home = home
        self.tempDir = tempDir
    }

    /// A real holder supervising a real job, plus the row that names both —
    /// created in the order `WorktreeLifecycle+Create` creates them, so the
    /// registry has adopted the session before anything reads its screen.
    func spawnHolderRow() async throws -> Terminal {
        let terminalID = UUID()
        let handle = try await registry.spawn(
            terminalID: terminalID,
            launch: HolderLaunchRequest(
                executable: "/bin/sh",
                arguments: ["-c", Self.uncooperativeJob],
                workingDirectory: "/tmp",
                environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                columns: 80,
                rows: 24))
        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktree.id,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: TerminalLabel.claudeCode,
            claudeSessionID: Self.sessionID,
            kind: .claude,
            transport: .holder,
            holderPID: handle.holderPID,
            childPID: handle.childPID,
            holderChildStartedAt: Date())
        return try #require(try await db.terminals.get(id: terminalID))
    }

    /// Kills whatever the ROWS still name, then clears the scratch roots.
    ///
    /// Reading the rows rather than a list of everything ever spawned is the
    /// safety property: a park clears the pids off its row precisely because
    /// those processes are gone, and a teardown working from a remembered list
    /// would signal numbers the kernel has already handed to somebody else — on
    /// a box running dozens of agent sessions, to somebody else's work.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        for row in (try? blockingTerminals()) ?? [] where row.transport == .holder {
            if let holderPID = row.holderPID, holderPID > 1 {
                kill(holderPID, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(holderPID, &ignored, 0)
            }
            if let childPID = row.childPID, childPID > 1, holderProcessIsAlive(childPID) {
                kill(childPID, SIGKILL)
            }
        }
        // Whatever a reader is still draining is named only by the registry, so
        // release them all. Detached because teardown is not async.
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        try? FileManager.default.removeItem(atPath: home)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Reads the terminal rows from a non-async `tearDown`. Bounded, and a
    /// timeout simply means the sweep above has nothing to kill by pid — the
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
