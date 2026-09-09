import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: `isolateTBDHome()` mutates the process-global
// `TBD_HOME` env var to isolate hook resolution and the runtime/presession
// marker directory from the developer's real ~/tbd. See
// TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// The transport gate as the pre-session hook tab asks it, plus the two places
/// a hook tab's *transport* changes what the lifecycle does to it: the liveness
/// probe that decides `.paneKilled`, and the teardown.
///
/// A real holder needs a `TBDHolder` binary, so the flag-on branch is reached
/// the way `TerminalCreateTransportGateTests` reaches it — a registry that
/// cannot spawn (tmux fallback) and a spawner whose executable does not exist
/// (the holder path is taken, and fails). The probe and the teardown are
/// asserted against holder ROWS, which need no live process at all.
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
        func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
        func commandLine(_ pid: Int32) -> String? { nil }
        func stat(_ pid: Int32) -> String? { nil }
        func startTime(_ pid: Int32) -> Date? { nil }
    }

    private static func registry(spawner: HolderSpawner?, home: String) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: [
                "TBD_HOME": home,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/sh",
            ],
            listTerminals: { [] },
            spawner: spawner)
    }

    // MARK: - Spawn

    /// Flag on, nothing to spawn with: the hook tab is created on tmux, the
    /// same fallback every other spawn path takes. A refusal here would block
    /// worktree creation outright.
    @Test("flag on with a registry that cannot spawn puts the hook tab on tmux")
    func flagOnWithoutASpawnerFallsBackToTmux() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try await fx.db.config.setPtyHolderEnabled(true)
        try await installPreSessionHook(repoDir: fx.repoDir)
        let scratch = fencedScratchRoot(prefix: "tbdhtg")
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        var lifecycle = makeLifecycle(db: fx.db)
        lifecycle.holderRegistry = Self.registry(spawner: nil, home: scratch)

        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: fx.worktree, repo: fx.repo, worktreePath: fx.repoDir.path))

        #expect(spawn.transport == .tmux)
        #expect(spawn.holderPID == nil)
        #expect(spawn.childPID == nil)
        #expect(!spawn.windowID.isEmpty)
        let row = try #require(try await fx.db.terminals.get(id: spawn.terminalID))
        #expect(row.transport == .tmux)
        #expect(row.label == TerminalLabel.preSession)
    }

    /// Flag on with a spawner that cannot start anything: the holder path IS
    /// taken — that is what the throw proves — and it fails before any row, so
    /// nothing is left claiming a tab that never opened.
    @Test("a holder hook-tab spawn failure throws and leaves no terminal row")
    func holderSpawnFailureLeavesNoRow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try await fx.db.config.setPtyHolderEnabled(true)
        try await installPreSessionHook(repoDir: fx.repoDir)
        let scratch = fencedScratchRoot(prefix: "tbdhtg")
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let recorder = PreSessionRecordedCommands()
        var lifecycle = makeLifecycle(db: fx.db, recorder: recorder)
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
            thrown != nil,
            "the hook-tab spawn did not take the holder path — it succeeded on tmux instead")

        #expect(try await fx.db.terminals.list(worktreeID: fx.worktree.id).isEmpty)
        #expect(
            !recorder.snapshot().contains { $0.contains("new-window") },
            "a failed holder hook-tab spawn fell through to tmux: \(recorder.snapshot())")
        #expect(
            !recorder.snapshot().contains { $0.contains("new-session") },
            "a holder hook-tab spawn started a tmux server: \(recorder.snapshot())")
    }

    // MARK: - The liveness probe

    private func holderSpawnDescriptor(
        terminalID: UUID, worktreeID: UUID, childPID: Int32?
    ) -> PreSessionSpawn {
        PreSessionSpawn(
            terminalID: terminalID,
            tmuxServer: "tbd-test",
            windowID: "",
            paneID: "",
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
            db: fx.db, timeout: 2, windowIsDead: { _ in false },
            processSignaller: signaller)
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1111, childPID: 9001)

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: terminal.id, worktreeID: fx.worktree.id, childPID: 9001),
            tmuxServer: "tbd-test")

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
            db: fx.db, timeout: 2, windowIsDead: { _ in false },
            processSignaller: signaller)

        // No row is ever created for this terminal id.
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 9002),
            tmuxServer: "tbd-test")

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
            db: fx.db, timeout: 2, windowIsDead: { _ in false },
            processSignaller: signaller)

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 9003),
            tmuxServer: "tbd-test")

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
            db: fx.db, timeout: 0.2, windowIsDead: { _ in false },
            processSignaller: AlwaysDeadProcessSignaller())
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1111)

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: terminal.id, worktreeID: fx.worktree.id, childPID: nil),
            tmuxServer: "tbd-test")

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
            db: fx.db, timeout: 0.2, windowIsDead: { _ in false },
            processSignaller: signaller)
        try fx.db.writerForTests.close()

        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: holderSpawnDescriptor(
                terminalID: UUID(), worktreeID: fx.worktree.id, childPID: 9004),
            tmuxServer: "tbd-test")

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

        let recorder = PreSessionRecordedCommands()
        var lifecycle = makeLifecycle(db: fx.db, recorder: recorder, timeout: 2)
        // Pinned rather than assumed: the branch under test is the one a daemon
        // in mock mode takes, and it must stay reachable if `makeLifecycle`
        // ever starts wiring a registry.
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
        #expect(
            !recorder.snapshot().contains { $0.contains("kill-window") },
            "a holder hook tab was torn down through tmux: \(recorder.snapshot())")
        #expect(
            !recorder.snapshot().contains { $0.contains("new-window") },
            "phase 3 spawned primaries after the row vanished: \(recorder.snapshot())")
    }

    // MARK: - Teardown

    /// A thread-safe tally. The dry-run hooks are `@Sendable` closures called
    /// from whatever executor the teardown happens to be on.
    private final class CaptureCounter: @unchecked Sendable {
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

    /// A lifecycle whose dry-run tmux both records its argv and answers
    /// `capture-pane` with real text — `capturePaneScrollback` returns the
    /// closure's value in dry run and records no argv, so the counter is the
    /// only way to see the call, and non-empty text is what makes a Closed
    /// Terminals row observable at all.
    private static func teardownLifecycle(
        db: TBDDatabase,
        recorder: PreSessionRecordedCommands,
        captureCalls: CaptureCounter
    ) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: { recorder.append($0) },
                dryRunCapturePane: { _, _ in
                    captureCalls.increment()
                    return "hook output\n"
                }),
            hooks: HookResolver())
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

        let recorder = PreSessionRecordedCommands()
        let captureCalls = CaptureCounter()
        let lifecycle = Self.teardownLifecycle(
            db: fx.db, recorder: recorder, captureCalls: captureCalls)
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1111, childPID: 2222)
        try await fx.db.worktrees.setTabOrder(
            worktreeID: fx.worktree.id, tabIDs: [terminal.id])

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree, tmuxServer: "tbd-test",
            terminalID: terminal.id, windowID: "")

        #expect(
            captureCalls.count == 0,
            "a holder hook tab was captured through tmux capture-pane")
        #expect(
            !recorder.snapshot().contains { $0.contains("kill-window") },
            "a holder hook tab was killed through tmux: \(recorder.snapshot())")
        #expect(try await fx.db.terminals.get(id: terminal.id) == nil)
        #expect(try await fx.db.worktrees.getTabOrder(worktreeID: fx.worktree.id).isEmpty)
        #expect(try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).isEmpty,
                "a holder hook tab was written to Closed Terminals")
    }

    /// The tmux arm, unchanged, so a teardown that took the holder branch for
    /// everybody could not pass: a tmux hook tab is still captured and its
    /// window still killed.
    @Test("closing a tmux hook tab still captures and kills its window")
    func tmuxHookTabTeardownIsUnchanged() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        let recorder = PreSessionRecordedCommands()
        let captureCalls = CaptureCounter()
        let lifecycle = Self.teardownLifecycle(
            db: fx.db, recorder: recorder, captureCalls: captureCalls)
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "@hook", tmuxPaneID: "%hook",
            label: TerminalLabel.preSession, kind: .shell)

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree, tmuxServer: "tbd-test",
            terminalID: terminal.id, windowID: "@hook")

        #expect(captureCalls.count == 1)
        #expect(recorder.snapshot().contains {
            $0.contains("kill-window") && $0.contains("@hook")
        })
        #expect(try await fx.db.terminals.get(id: terminal.id) == nil)
        #expect(
            try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).count == 1,
            "a tmux hook tab's scrollback was not preserved for Closed Terminals")
    }
}
}
