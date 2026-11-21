import DaemonTestSupport
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

// Nested under TBDHomeSerialized: `isolateTBDHome()` mutates the process-global
// `TBD_HOME` env var to isolate hook resolution and the runtime/presession
// marker directory from the developer's real ~/tbd. See
// TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// The transport gate as the pre-session hook tab asks it, plus the two places
/// a hook tab's *transport* changes what the lifecycle does to it: the liveness
/// probe that decides `.paneKilled`, and the teardown.
///
/// A real holder needs a `TBDHolder` binary, so the gate's branches are reached
/// the way `TerminalCreateTransportGateTests` reaches them — the holder spawn
/// double (the tab lands), a registry that cannot spawn (refused), and a
/// spawner whose executable does not exist (the holder path is taken, and
/// fails). The probe and the teardown are asserted against holder ROWS, which
/// need no live process at all.
@Suite("Hook-tab transport gate")
struct HookTabTransportGateTests {

    /// A spawner whose executable is not there. The registry built on it
    /// reports `canSpawn`, so the gate takes the holder path; the spawn then
    /// fails at `posix_spawn`, before any holder exists.
    private static func unspawnableSpawner() -> HolderSpawner {
        HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
    }

    /// A signaller for which no pid is ever alive.
    ///
    /// Its whole job is to make one assertion discriminate: a descriptor that
    /// recorded no child pid must answer "still there" on the row alone, and
    /// stating the alternative as "every pid this could be asked about is dead"
    /// leaves the probe nowhere else to get a yes from.
    private struct AlwaysDeadProcessSignaller: ProcessSignaller {
        func isAlive(_ pid: Int32) -> Bool { false }
        func terminate(_ pid: Int32) {}
        func forceKill(_ pid: Int32) {}
        func commandLine(_ pid: Int32) -> String? { nil }
        func stat(_ pid: Int32) -> String? { nil }
        func startTime(_ pid: Int32) -> Date? { nil }
    }

    private static func registry(
        spawner: HolderSpawner?, home: String,
        signaller: any ProcessSignaller = ProductionProcessSignaller()
    ) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: [
                "TBD_HOME": home,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/sh",
            ],
            listTerminals: { [] },
            spawner: spawner,
            signaller: signaller)
    }

    /// The pid the teardown tests' rows record, and the start time they record
    /// beside it. A pid this daemon never spawned and a stamp far in the past:
    /// nothing here may be answered by the real process table.
    private static let jobPID: Int32 = 8802
    private static let jobStartedAt = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Spawn

    /// A registry that can spawn: the hook tab opens on a holder, carrying the
    /// spawn's pids in its descriptor and its row, and tmux is never asked.
    @Test("a registry that can spawn puts the hook tab on a holder")
    func aRegistryThatCanSpawnPutsTheHookTabOnAHolder() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: fx.repoDir)

        let launch = FakeHolderLaunch()
        var lifecycle = makeLifecycle(db: fx.db)
        lifecycle.holderRegistry = makeHolderRegistryDouble(launch: launch)

        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: fx.worktree, repo: fx.repo, worktreePath: fx.repoDir.path))

        let started = try #require(launch.launch(for: spawn.terminalID))
        #expect(spawn.transport == .holder)
        #expect(spawn.holderPID == started.handle.holderPID)
        #expect(spawn.childPID == started.handle.childPID)
        let row = try #require(try await fx.db.terminals.get(id: spawn.terminalID))
        #expect(row.transport == .holder)
        #expect(row.tmuxWindowID.isEmpty)
        #expect(row.label == TerminalLabel.preSession)
    }

    /// Nothing to spawn with: the hook tab is refused with the gate's reason,
    /// before any row or tmux server exists, and worktree creation fails with
    /// the same words.
    @Test("a registry that cannot spawn refuses the hook tab")
    func aRegistryThatCannotSpawnRefusesTheHookTab() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: fx.repoDir)
        let scratch = fencedScratchRoot(prefix: "tbdhtg")
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        var lifecycle = makeLifecycle(db: fx.db)
        lifecycle.holderRegistry = Self.registry(spawner: nil, home: scratch)

        await #expect(throws: TerminalSpawnRefusal.holderUnavailable) {
            _ = try await lifecycle.spawnPreSessionTerminal(
                worktree: fx.worktree, repo: fx.repo, worktreePath: fx.repoDir.path)
        }

        #expect(try await fx.db.terminals.list(worktreeID: fx.worktree.id).isEmpty)
    }

    /// A spawner that cannot start anything: the holder path IS taken — that
    /// is what the throw proves — and it fails before any row, so nothing is
    /// left claiming a tab that never opened.
    @Test("a holder hook-tab spawn failure throws and leaves no terminal row")
    func holderSpawnFailureLeavesNoRow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: fx.repoDir)
        let scratch = fencedScratchRoot(prefix: "tbdhtg")
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        var lifecycle = makeLifecycle(db: fx.db)
        lifecycle.holderRegistry = Self.registry(
            spawner: Self.unspawnableSpawner(), home: scratch)

        var thrown: (any Error)?
        do {
            _ = try await lifecycle.spawnPreSessionTerminal(
                worktree: fx.worktree, repo: fx.repo, worktreePath: fx.repoDir.path)
        } catch {
            thrown = error
        }
        #expect(
            thrown != nil && !(thrown is TerminalSpawnRefusal),
            "the hook-tab spawn did not fail at the holder launch: \(String(describing: thrown))")

        #expect(try await fx.db.terminals.list(worktreeID: fx.worktree.id).isEmpty)
    }

    // MARK: - The liveness probe

    private func holderSpawnDescriptor(
        terminalID: UUID, worktreeID: UUID, childPID: Int32?
    ) -> PreSessionSpawn {
        PreSessionSpawn(
            terminalID: terminalID,
            tmuxServer: "tbd-test",
            markerPath: WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID),
            hookPath: "/dev/null",
            transport: .holder,
            holderPID: 1111,
            childPID: childPID)
    }

    /// The holder analogue of a killed pane, half one: the job is gone. The
    /// row still exists, so nothing else in the wait would notice.
    @Test("a dead holder job reports .paneKilled")
    func deadHolderJobIsPaneKilled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[9001] = .init(aliveInitially: false)
        // A window probe that reports ALIVE: if the wait consulted tmux for a
        // holder tab it would never short-circuit, and this test would hang
        // out to its timeout rather than pass.
        let lifecycle = makeLifecycle(
            db: fx.db, timeout: 2, processSignaller: signaller)
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1111, childPID: 9001)

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: terminal.id, worktreeID: fx.worktree.id, childPID: 9001))

        #expect(outcome == .paneKilled)
    }

    /// Half two: the tab itself is gone. Closing a holder-backed tab deletes
    /// its row, so a row that is no longer there is the holder's "the user
    /// closed it" — even with the job's pid still reporting alive.
    @Test("a deleted holder row reports .paneKilled")
    func deletedHolderRowIsPaneKilled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[9002] = .init(aliveInitially: true)
        let lifecycle = makeLifecycle(
            db: fx.db, timeout: 2, processSignaller: signaller)

        // No row is ever created for this terminal id.
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 9002))

        #expect(outcome == .paneKilled)
    }

    /// The marker-first ordering is transport-independent: a hook that
    /// recorded its exit code wins over both halves of the holder probe, so a
    /// hook that finished and then had its tab closed is not misreported.
    @Test("a marker beats a dead holder job and a missing row")
    func markerBeatsTheHolderProbe() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try writeMarker(worktreeID: fx.worktree.id, exitCode: 0)

        let signaller = FakeProcessSignaller()
        signaller.behaviors[9003] = .init(aliveInitially: false)
        let lifecycle = makeLifecycle(
            db: fx.db, timeout: 2, processSignaller: signaller)

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 9003))

        #expect(outcome == .completed(exitCode: 0))
        #expect(!FileManager.default.fileExists(
            atPath: WorktreeLifecycle.preSessionMarkerPath(worktreeID: fx.worktree.id)))
    }

    /// A spawn that recorded no child pid answers on the row alone.
    ///
    /// `spawnTerminal` always records one, so this is a row a defect would
    /// produce rather than one the product writes — and the safe answer to "is
    /// a tab whose job I cannot name still running" is yes. Reading the missing
    /// pid as a dead job would report `.paneKilled` for every such tab, and
    /// phase 3 would then start the primary agent on a tree the hook had not
    /// finished preparing.
    ///
    /// The wait therefore has to run out its budget for this to pass, which is
    /// what the short timeout buys: nothing here can end it early, and one poll
    /// is enough for the misreading to show.
    @Test("a holder spawn with no child pid keeps waiting instead of reporting a killed pane")
    func holderSpawnWithoutAChildPIDKeepsWaiting() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let lifecycle = makeLifecycle(
            db: fx.db, timeout: 0.2, processSignaller: AlwaysDeadProcessSignaller())
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1111)

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: terminal.id, worktreeID: fx.worktree.id, childPID: nil))

        #expect(outcome == .timedOut)
    }

    /// A liveness read that THREW is not a deleted tab.
    ///
    /// Closing the database connection makes the row read fail rather than
    /// answer nil — the same transient shape
    /// `PreSessionHookTests.dbErrorDuringRowCheckDoesNotTearDownPreSessionWindow`
    /// induces for the worktree-row check one layer up. Only nil means the tab
    /// is gone; an error says nothing about it, and treating it as a deletion
    /// would abandon a hook that is still running.
    @Test("a failed row read keeps the holder wait going")
    func failedRowReadIsNotReadAsAClosedTab() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[9004] = .init(aliveInitially: true)
        let lifecycle = makeLifecycle(
            db: fx.db, timeout: 0.2, processSignaller: signaller)
        try fx.db.writerForTests.close()

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 9004))

        #expect(outcome == .timedOut, "a database error was read as a closed holder tab")
    }

    // MARK: - Abandoning a hook tab whose row is already gone

    /// A holder hook tab left by a daemon with no registry is reported, and
    /// never killed through tmux.
    ///
    /// This is the branch that separates the two transports on the phase-3
    /// bail-out. The tmux arm's whole cleanup is a `kill-window`; issuing one
    /// for a holder tab addresses the empty string, so its absence is the only
    /// observable that says the holder arm was taken. With no registry there is
    /// nothing left to reclaim the holder with — that is a report, not a
    /// crash — and phase 3 must still return without spawning anything into a
    /// worktree that no longer exists.
    @Test("a holder hook tab with no registry is never torn down through tmux")
    func holderHookTabWithoutARegistryIssuesNoKillWindow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        var lifecycle = makeLifecycle(db: fx.db, timeout: 2)
        // `makeLifecycle` wires a registry; the branch under test is the one a
        // lifecycle with none takes.
        lifecycle.holderRegistry = nil

        // The cascade a repo removal performs mid-wait: the worktree row goes,
        // and every terminal row goes with it. The descriptor is what is left.
        try await fx.db.worktrees.delete(id: fx.worktree.id)

        await lifecycle.runPreSessionPhase3(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 2222),
            worktree: fx.worktree, repo: fx.repo,
            worktreePath: fx.repoDir.path,
            skipClaude: true,
            completionAction: .markActive)

        // No assertion that the worktree's terminal rows are empty: the
        // cascade above emptied them before phase 3 ran, and the foreign key
        // would refuse a row for a deleted worktree anyway, so it cannot fail
        // whatever phase 3 does. The `new-window` assertion below is the one
        // the code under test can actually break.
    }

    // MARK: - Teardown

    /// The descriptor a hook tab's spawn would have returned for `terminal`.
    private static func hookDescriptor(of terminal: Terminal) -> PreSessionSpawn {
        PreSessionSpawn(
            terminalID: terminal.id,
            tmuxServer: "tbd-test",
            markerPath: "/dev/null",
            hookPath: "/dev/null",
            transport: terminal.transport,
            holderPID: terminal.holderPID,
            childPID: terminal.childPID,
            childStartedAt: terminal.holderChildStartedAt)
    }

    /// A lifecycle with no holder registry; a test that needs one wires it.
    private static func teardownLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db,
            git: GitManager(),
            hooks: HookResolver(),
            leftoverTmuxProbe: .absent)
    }

    /// A holder hook tab is torn down through the holder, never through tmux.
    ///
    /// Both negatives matter. `capture-pane` would read a pane that is the
    /// empty string, and `kill-window` would address a window id naming
    /// nothing — while the holder, its job and its rendezvous files outlive the
    /// row that is their only record. With no registry wired the teardown can
    /// only report that; the row, tab and order cleanup still has to run, or
    /// the worktree keeps a tab whose terminal is gone.
    @Test("closing a holder hook tab issues no capture-pane and no kill-window")
    func holderHookTabTeardownSkipsTmux() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let lifecycle = Self.teardownLifecycle(
            db: fx.db)
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1111, childPID: 2222)
        try await fx.db.worktrees.setTabOrder(
            worktreeID: fx.worktree.id, tabIDs: [terminal.id])

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree, preSession: Self.hookDescriptor(of: terminal))

        #expect(try await fx.db.terminals.get(id: terminal.id) == nil)
        #expect(try await fx.db.worktrees.getTabOrder(worktreeID: fx.worktree.id).isEmpty)
        // Written through the holder helper, not tmux: an entry, and — with no
        // registry, so no live reader — no capture file.
        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id)
        #expect(entries.map(\.id) == [terminal.id],
                "a holder hook tab's close wrote no Closed Terminals entry")
        #expect(entries.first?.label == TerminalLabel.preSession)
        #expect(!FileManager.default.fileExists(atPath: fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: terminal.id)))
    }

    /// A holder hook tab whose recorded child pid now belongs to somebody else
    /// is torn down without signalling anything.
    ///
    /// The window this closes is real and routine: a hook tab is closed
    /// *because* its hook finished, so its job has usually already exited and
    /// the kernel is free to hand the number out again. The row cleanup still
    /// has to happen — a tab whose terminal is gone must not survive it — and
    /// so does the absence of every tmux gesture, so this discriminates against
    /// both a teardown that kills blind and one that fell into the tmux arm.
    @Test("closing a holder hook tab never signals a recycled child pid")
    func holderHookTabTeardownSkipsARecycledPID() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[Self.jobPID] = .init(aliveInitially: true)
        // Alive, wearing a shell's command line, and started an hour away from
        // the anchor the row recorded: only the start time separates it.
        signaller.cmdlines[Self.jobPID] = "zsh -c make"
        signaller.startTimes[Self.jobPID] = Self.jobStartedAt.addingTimeInterval(3600)

        let scratch = fencedScratchRoot(prefix: "tbdhtg")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        var lifecycle = Self.teardownLifecycle(
            db: fx.db)
        lifecycle.holderRegistry = Self.registry(
            spawner: nil, home: scratch, signaller: signaller)

        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: nil, childPID: Self.jobPID,
            holderChildStartedAt: Self.jobStartedAt)
        try await fx.db.worktrees.setTabOrder(
            worktreeID: fx.worktree.id, tabIDs: [terminal.id])

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree, preSession: Self.hookDescriptor(of: terminal))

        #expect(signaller.killed.isEmpty, "a recycled pid was force-killed by the hook teardown")
        #expect(signaller.terminated.isEmpty, "a recycled pid was signalled by the hook teardown")
        #expect(try await fx.db.terminals.get(id: terminal.id) == nil)
        #expect(try await fx.db.worktrees.getTabOrder(worktreeID: fx.worktree.id).isEmpty)
    }

    /// The other half of the same decision, and the reason the one above is not
    /// simply "never kill anything": a job whose pid still verifies against the
    /// row's recorded start time is reclaimed.
    @Test("closing a holder hook tab force-kills a job that verifies")
    func holderHookTabTeardownKillsAVerifiedJob() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[Self.jobPID] = .init(
            aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        signaller.cmdlines[Self.jobPID] = "/bin/zsh -i -l -c hook"
        signaller.startTimes[Self.jobPID] = Self.jobStartedAt

        let scratch = fencedScratchRoot(prefix: "tbdhtg")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        var lifecycle = Self.teardownLifecycle(
            db: fx.db)
        lifecycle.holderRegistry = Self.registry(
            spawner: nil, home: scratch, signaller: signaller)

        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: nil, childPID: Self.jobPID,
            holderChildStartedAt: Self.jobStartedAt)

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree, preSession: Self.hookDescriptor(of: terminal))

        #expect(signaller.killed == [Self.jobPID])
        #expect(try await fx.db.terminals.get(id: terminal.id) == nil)
    }

    /// A hook tab an earlier build left on tmux is closed without running a
    /// tmux command: nothing is captured, nothing is killed, and — a shell
    /// with no session to resume and no screen to keep — no Closed Terminals
    /// entry is written. The row, tab and order cleanup still runs.
    @Test("closing a tmux hook tab runs no tmux command")
    func tmuxHookTabTeardownRunsNoTmux() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let lifecycle = Self.teardownLifecycle(
            db: fx.db)
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "@hook", tmuxPaneID: "%hook",
            label: TerminalLabel.preSession, kind: .shell)
        try await fx.db.worktrees.setTabOrder(
            worktreeID: fx.worktree.id, tabIDs: [terminal.id])

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree, preSession: Self.hookDescriptor(of: terminal))

        #expect(try await fx.db.terminals.get(id: terminal.id) == nil)
        #expect(try await fx.db.worktrees.getTabOrder(worktreeID: fx.worktree.id).isEmpty)
        #expect(try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).isEmpty)
    }
}
}
