import Clocks
import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The **inventory direction** of the holder reconciler: the holder is gone and
/// the session row is still there
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
/// "Reconciliation").
///
/// `HolderReconcileExemptionTests` covers the other half — a holder row this
/// daemon knows nothing about must survive the tmux sweep untouched — and the
/// two suites are deliberately separate: that one asserts an exemption, this
/// one asserts the judgement the exemption was holding a place for.
///
/// **Tier 2, and that is checked rather than assumed.** Nothing here spawns a
/// `TBDHolder`: the "holder is gone" fixture is a rendezvous directory with no
/// socket in it, which is exactly what a holder that died leaves behind, and
/// the classification tests drive the production classifier with a pinned
/// answer. Only a fixture that spawns a real holder is tier 3
/// (`HolderReaderTestSupport.swift`), so the plan's path is right this time.
@Suite("Holder rows the sweep may judge")
struct HolderReconcileInventoryTests {

    // MARK: - Fixture

    /// A rendezvous root with nothing listening in it — a holder that died.
    ///
    /// Short on purpose: the socket path derived under it is handed to
    /// `connect(2)`, and `sun_path` is 104 bytes.
    private func vanishedHolderEnvironment() -> [String: String] {
        ["TBD_HOME": "/tmp/tbdrec-\(UUID().uuidString.prefix(8).lowercased())"]
    }

    private func registry(environment: [String: String]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: UUID().uuidString),
            environment: environment,
            listTerminals: { [] })
    }

    /// Dry-run tmux with every window reported dead — the state a holder row
    /// produces against a real server, since `windowExists("")` cannot succeed.
    private func deadWindowTmux() -> TmuxManager {
        TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
    }

    private func seedRepo(db: TBDDatabase, at repoPath: String) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoPath))
        return (repo, main)
    }

    /// A signaller for which every pid named here is gone. The production one
    /// would run `kill(pid, 0)` against the developer's live process table,
    /// where a fixture pid may well name somebody's real process.
    private func deadJobs(_ pids: [Int32]) -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        for pid in pids {
            signaller.behaviors[pid] = FakeProcessSignaller.Behavior(aliveInitially: false)
        }
        return signaller
    }

    private func makeLifecycle(
        db: TBDDatabase, signaller: ProcessSignaller, registry: HolderRegistry?,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> WorktreeLifecycle {
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: deadWindowTmux(), hooks: HookResolver(),
            processSignaller: signaller, clock: clock)
        lifecycle.holderRegistry = registry
        return lifecycle
    }

    /// Opts the fixture into the arm under test.
    ///
    /// `holder_row_reconcile_enabled` ships OFF, so every test that expects a
    /// judgement has to make the gesture a soak participant makes. The one test
    /// that does not call this is the one asserting the shipped default.
    private func enableTheHolderArm(_ db: TBDDatabase) async throws {
        try await db.config.setHolderRowReconcileEnabled(true)
    }

    private func description(
        owner: HolderOwnerToken, status: HolderChildStatus, childPID: Int32 = 4243
    ) -> HolderChildDescription {
        HolderChildDescription(
            childPID: childPID,
            ttyName: "/dev/ttys009",
            status: status,
            launch: HolderLaunchRequest(
                executable: "/bin/sh", arguments: ["-c", "true"], workingDirectory: "/tmp",
                environment: [:], columns: 80, rows: 24),
            owner: owner)
    }

    // MARK: - The sweep

    @Test("a holder-backed row whose holder is gone is deleted, never parked")
    func vanishedHolderRowsAreDeleted() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await enableTheHolderArm(db)
        let lifecycle = makeLifecycle(
            db: db,
            signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        // **The park is withheld on purpose.** `HibernationCoordinator.wake`
        // refuses `transport == .holder` before its "wake any parked row"
        // branch and this sweep skips parked rows, so a parked holder row could
        // never be woken and never be re-judged — while the app's focus-wake
        // selects exactly `isParked && isClaudeResumable && hibernateReason !=
        // .manual` and would fire a failing wake RPC on every focus of the
        // worktree, forever.
        #expect(
            try await db.terminals.get(id: claude.id) == nil,
            "a holder-backed resumable Claude row was parked instead of deleted; a parked holder row is unwakeable and re-fires focus-wake forever")
        #expect(
            try await db.terminals.get(id: shell.id) == nil,
            "a holder-backed shell row whose holder is gone was left in the inventory")
    }

    /// The gate's off branch, which is the shipped default: the arm judges
    /// nothing and moves nothing, exactly as the old transport exemption did.
    ///
    /// Deliberately the same fixture as the test above — the only difference is
    /// the gesture — so a gate that stopped being read shows up as two tests
    /// asserting opposite outcomes on identical input.
    @Test("with its gate off the holder arm leaves every row alone")
    func theShippedDefaultJudgesNothing() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        #expect(
            try await db.config.get().holderRowReconcileEnabled == false,
            "this test asserts the shipped default; it must not have been touched")
        let lifecycle = makeLifecycle(
            db: db,
            signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let survivingClaude = try #require(
            try await db.terminals.get(id: claude.id),
            "the holder arm deleted a row with its gate off")
        #expect(
            survivingClaude.hibernatedAt == nil,
            "the holder arm parked a row with its gate off")
        #expect(
            try await db.terminals.get(id: shell.id) != nil,
            "the holder arm deleted a row with its gate off")
    }

    @Test("a holder-backed row whose job is still running is left alone")
    func aLiveJobKeepsItsRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        // The holder is gone by the same fixture as above; only the job's
        // liveness differs, which is the fact under test.
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4243] = FakeProcessSignaller.Behavior(aliveInitially: true)
        signaller.behaviors[4245] = FakeProcessSignaller.Behavior(aliveInitially: true)
        try await enableTheHolderArm(db)
        let lifecycle = makeLifecycle(
            db: db, signaller: signaller,
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let survivingClaude = try #require(
            try await db.terminals.get(id: claude.id),
            "the sweep deleted the row that is the only record of a running job's pid")
        #expect(
            survivingClaude.hibernatedAt == nil,
            "the sweep parked a row whose job is still running")
        #expect(
            try await db.terminals.get(id: shell.id) != nil,
            "the sweep deleted the row that is the only record of a running job's pid")
    }

    // MARK: - The classification

    @Test("nothing at the rendezvous is an exit nobody observed, never a clean one")
    func absenceIsStatusUnknown() async throws {
        let owner = HolderOwnerToken(rawValue: "owner-a")
        for code in [ENOENT, ECONNREFUSED] {
            let verdict = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
                throw HolderClient.Error.cannotConnect(path: "/tmp/gone.sock", errno: code)
            }
            #expect(verdict == .sessionOver(.exitedStatusUnknown))
            #expect(
                verdict != .sessionOver(.exited(code: 0)),
                "an exit nobody observed was reported as a clean exit")
        }
    }

    @Test("a rejected connection is terminal in both directions")
    func aRejectionIsNeverAnExit() async {
        let verdict = await WorktreeLifecycle.holderRowVerdict(
            expecting: HolderOwnerToken(rawValue: "owner-a")
        ) {
            throw HolderClient.Error.rejected(version: 1)
        }
        #expect(
            verdict == .keep(reason: "rejected"),
            "a live holder serving somebody else was read as a dead one")
    }

    @Test("a round trip that merely failed establishes nothing")
    func anUnreadableAnswerKeeps() async {
        let owner = HolderOwnerToken(rawValue: "owner-a")
        // EMFILE describes THIS process failing to open a connection, and says
        // nothing whatever about the child.
        let unreachable = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            throw HolderClient.Error.cannotConnect(path: "/tmp/busy.sock", errno: EMFILE)
        }
        #expect(unreachable == .keep(reason: "unestablished"))

        let hungUp = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            throw HolderClient.Error.peerClosed
        }
        #expect(hungUp == .keep(reason: "unestablished"))
    }

    @Test("a holder that answers decides the row by what it says")
    func adescribedHolderDecidesTheRow() async {
        let owner = HolderOwnerToken(rawValue: "owner-a")

        let alive = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            description(owner: owner, status: .alive)
        }
        #expect(alive == .keep(reason: "alive"))

        let exited = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            description(owner: owner, status: .exited(code: 3))
        }
        #expect(
            exited == .sessionOver(.exited(code: 3)),
            "a real exit code was not carried through")

        let foreign = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            description(owner: HolderOwnerToken(rawValue: "owner-b"), status: .exitedStatusUnknown)
        }
        #expect(
            foreign == .keep(reason: "foreign-owner"),
            "another installation's holder was allowed to decide one of our rows")
    }

    // MARK: - The probe that asks nothing

    /// A row this daemon has never taken the master of is probed by
    /// *connecting*, not by describing, and absence still establishes the same
    /// fact through the same errno rules.
    ///
    /// The reason the arm cannot describe such a row: a holder winds itself
    /// down the moment an answer carrying the terminal status reaches a client,
    /// so a `describe` before the hand-over would end the holder and take the
    /// output the job wrote and nobody read with it.
    @Test("a connect-only probe reads absence exactly as the describing one does")
    func aConnectProbeReadsAbsenceTheSameWay() async {
        for code in [ENOENT, ECONNREFUSED] {
            let verdict = await WorktreeLifecycle.holderListenerVerdict {
                throw HolderClient.Error.cannotConnect(path: "/tmp/gone.sock", errno: code)
            }
            #expect(
                verdict == .sessionOver(.exitedStatusUnknown),
                "errno \(code) at the rendezvous did not read as an exit nobody observed")
        }
    }

    /// A connection that succeeds establishes that *something* is bound and
    /// accepting, and deliberately nothing else — not whose it is and not what
    /// its child is doing, because asking either is what would destroy the
    /// screen.
    @Test("a connection that succeeds keeps the row and claims nothing more")
    func aReachableRendezvousKeeps() async {
        let verdict = await WorktreeLifecycle.holderListenerVerdict {}
        #expect(
            verdict == .keep(reason: "listening"),
            "a reachable rendezvous did not keep its row")
    }

    /// Everything that is not evidence of absence keeps, with its reason
    /// preserved for the soak — the same split the describing verdict makes.
    @Test("a connect that merely failed establishes nothing")
    func anUnreachableRendezvousKeeps() async {
        let unreachable = await WorktreeLifecycle.holderListenerVerdict {
            throw HolderClient.Error.cannotConnect(path: "/tmp/busy.sock", errno: EMFILE)
        }
        #expect(unreachable == .keep(reason: "unestablished"))

        let refused = await WorktreeLifecycle.holderListenerVerdict {
            throw HolderClient.Error.rejected(version: 1)
        }
        #expect(
            refused == .keep(reason: "rejected"),
            "a live holder serving somebody else was read as a dead one")
    }

    // MARK: - The phase budget

    /// **A per-probe timeout is not a bound on the phase.** This arm runs
    /// inside `performStartupReconciliation`, before the daemon binds its
    /// socket and while it holds a tmux server resource lock, and it is serial
    /// — so N rows cost N times the per-probe budget, which is the failure
    /// `HolderRegistry.adoptAllBudget` exists to prevent. A pass that has spent
    /// its budget keeps every row it has not reached, which costs nothing: this
    /// sweep asks once and the next reconcile is the retry.
    @Test("a pass that has spent its budget stops probing and keeps", .clockDriven)
    func aSpentBudgetKeepsTheRestOfThePass() async throws {
        let registry = registry(environment: vanishedHolderEnvironment())
        let db = try TBDDatabase(inMemory: true)
        var lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        lifecycle.holderRegistry = registry

        // Virtual time, so "spent" is reached by construction rather than by
        // waiting on a real five seconds: `advanceWhenSuspended` waits until
        // the budget's timer has actually registered its sleep before moving
        // the clock past it.
        let clock = TestClock()
        await lifecycle.holderProbeBudget.begin(.seconds(5), clock: clock)
        await clock.advanceWhenSuspended(by: .seconds(5))
        var spent = false
        for _ in 0..<500 where !spent {
            spent = await lifecycle.holderProbeBudget.isSpent
            if !spent { await Task.yield() }
        }
        #expect(spent, "the budget's timer never fired after its whole budget elapsed")

        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder)
        let verdict = await lifecycle.holderRowVerdict(for: terminal)
        #expect(
            verdict == .keep(reason: "phase-budget-spent"),
            """
            a pass past its budget kept probing rendezvous sockets before the \
            daemon's own was bound: \(String(describing: verdict))
            """)
        await lifecycle.holderProbeBudget.end()
    }

    /// The other polarity: a fresh budget probes. Without this, a budget that
    /// was always spent would pass the test above and silently disable the arm.
    @Test("a pass inside its budget still probes")
    func aFreshBudgetStillProbes() async throws {
        let registry = registry(environment: vanishedHolderEnvironment())
        let db = try TBDDatabase(inMemory: true)
        var lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        lifecycle.holderRegistry = registry
        await lifecycle.holderProbeBudget.begin(.seconds(5), clock: ContinuousClock())
        defer { Task { [budget = lifecycle.holderProbeBudget] in await budget.end() } }

        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder)
        #expect(
            await lifecycle.holderRowVerdict(for: terminal)
                == .sessionOver(.exitedStatusUnknown),
            "a pass inside its budget did not reach the rendezvous")
    }

    // MARK: - Where a remembered status may come from

    /// A rendezvous with a socket bound and listening that nobody ever accepts
    /// on: a holder that is **alive but wedged**. `connect(2)` completes into
    /// the backlog, the hand-over request goes out, and the receive times out.
    ///
    /// The caller owns the returned descriptor.
    private func wedgedHolderRendezvous(for sessionID: UUID, home: String) throws -> Int32 {
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: sessionID, environment: ["TBD_HOME": home])
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // Room for both connections the test opens — the adoption's and the
        // sweep's. Nothing accepts either, so a backlog of one would make the
        // sweep's connect fail with `ECONNREFUSED`, which is the one errno that
        // means "gone" — the fixture would then be testing a saturated queue
        // rather than a wedged holder.
        let fd = try #require(
            HolderRendezvousFixture.bind(at: socketPath, listening: true, backlog: 16),
            "could not bind a listening rendezvous at \(socketPath)")
        return fd
    }

    private func holderRow() -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder)
    }

    /// Gate 4 short-circuits on a remembered status **without probing**, and
    /// then `deleteTerminalAndTab` runs — which leaves a still-living holder
    /// rowless for `RowlessHolderCollector` to `SIGKILL`. So what may be
    /// remembered is the whole safety of that gate, and a receive timeout is
    /// neither an answer from a holder nor evidence of its absence.
    ///
    /// Real sockets rather than an injected error, because the fact under test
    /// is which failures the *production* adoption path brands, and a fixture
    /// that threw a chosen error would be asserting the classifier that the
    /// path was free not to consult.
    @Test("an adoption that only timed out remembers nothing about the session")
    func aWedgedHolderIsNeverRememberedAsExited() async throws {
        let home = "/tmp/tbdwedge-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }

        let terminal = holderRow()
        let fd = try wedgedHolderRendezvous(for: terminal.id, home: home)
        defer { close(fd) }

        let registry = registry(environment: ["TBD_HOME": home])
        await registry.adoptRemaining([terminal])

        #expect(
            await registry.lastKnownStatus(for: terminal.id) == nil,
            """
            a holder that was merely slow to answer was remembered as exited; gate 4 would \
            then delete its row and its tab with no probe, and RowlessHolderCollector would \
            SIGKILL the live job and the live holder behind it
            """)

        // The whole chain, not just the branding: the sweep must reach its own
        // probe and read the listener that is still there.
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, signaller: FakeProcessSignaller(), registry: registry)
        let verdict = await lifecycle.holderRowVerdict(for: terminal)
        #expect(
            verdict == .keep(reason: "listening"),
            """
            the sweep judged a live-but-wedged holder's row on a status that came from a \
            timeout: \(String(describing: verdict))
            """)
    }

    /// The other polarity, and the case the branding exists for: a rendezvous
    /// with nothing bound at it. Without this, an adoption that remembered
    /// nothing at all would pass the test above and silently cost the sweep the
    /// no-round-trip answer it is built on.
    @Test("an adoption that found nothing bound still remembers an uncollected exit")
    func anAbsentHolderIsStillRememberedAsExited() async throws {
        let home = "/tmp/tbdgone-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: home) }

        let terminal = holderRow()
        let registry = registry(environment: ["TBD_HOME": home])
        await registry.adoptRemaining([terminal])

        #expect(
            await registry.lastKnownStatus(for: terminal.id) == .exitedStatusUnknown,
            """
            nothing was bound at the rendezvous, which is the one observation that establishes \
            the holder is gone, and the adoption forgot it
            """)
    }

    // MARK: - The budget the production pass arms

    /// **The bracket in `reconcileTerminals` is the untested line, not the
    /// budget actor.** A test that calls `begin` itself stays green with both
    /// the `begin` and the `end` deleted from production, while the whole
    /// pre-bind bound silently disappears — so this one runs the real pass and
    /// watches the lifecycle's own clock be asked for the budget.
    @Test("the reconcile pass itself arms the phase budget, on the lifecycle's own clock")
    func theProductionPassArmsThePhaseBudget() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await enableTheHolderArm(db)
        let clock = SleepRecordingClock()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()), clock: clock)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        // The pass really did the work the budget bounds, so a recorded sleep
        // is not a sleep from some other pass that judged nothing.
        #expect(try await db.terminals.get(id: claude.id) == nil)
        #expect(try await db.terminals.get(id: shell.id) == nil)

        // The budget's timer is its own task, so it can reach the clock a hop
        // or two after the pass that armed it has already cancelled it.
        let sleeps = await clock.settledSleeps()
        let requested = try #require(
            sleeps.first,
            """
            the reconcile pass never asked the lifecycle's clock for a budget: the whole \
            pre-bind bound on this serial arm is gone
            """)
        #expect(
            requested <= WorktreeLifecycle.holderPhaseBudget
                && requested > WorktreeLifecycle.holderPhaseBudget - .milliseconds(500),
            """
            the pass armed a budget of \(requested) rather than \
            \(WorktreeLifecycle.holderPhaseBudget)
            """)
    }

    /// The gate's off branch: with the arm disabled there is no probing to
    /// bound, so no budget is armed at all and no timer task is left running.
    @Test("with its gate off the reconcile pass arms no budget")
    func theShippedDefaultArmsNoPhaseBudget() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        #expect(
            try await db.config.get().holderRowReconcileEnabled == false,
            "this test asserts the shipped default; it must not have been touched")
        let clock = SleepRecordingClock()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]),
            registry: registry(environment: vanishedHolderEnvironment()), clock: clock)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        _ = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4242, childPID: 4243)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        #expect(
            await clock.settledSleeps().isEmpty,
            "the holder arm armed its phase budget with its own gate off")
    }

    // MARK: - What the deletion says about itself

    /// The two deletions are different events and the log must not conflate
    /// them. A holder-transport Claude row *has* a session to preserve; what it
    /// does not have is a park it could be woken from.
    @Test("a withheld park says so rather than claiming there was no session")
    func theDeletionRationaleNamesTheWithheldPark() {
        let holderClaude = Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder)
        #expect(
            WorktreeLifecycle.deletionRationale(for: holderClaude)
                == "its Claude session is not resumable from a park on the holder transport")

        let holderShell = Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder)
        #expect(WorktreeLifecycle.deletionRationale(for: holderShell) == "no session to preserve")
    }
}

/// A clock that records the duration of every sleep asked of it and otherwise
/// behaves exactly like the production one.
///
/// **It records the request, not a firing.** The pass under test finishes in
/// milliseconds and cancels its own budget timer, so a test that waited for the
/// budget to elapse would be measuring the clock rather than the bracket.
private final class SleepRecordingClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock()
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    var requestedSleeps: [Duration] {
        lock.withLock { recorded }
    }

    /// The recorded sleeps once the budget timer has had a chance to reach this
    /// clock, bounded so a missing bracket fails rather than hangs.
    func settledSleeps() async -> [Duration] {
        for _ in 0..<500 {
            if !requestedSleeps.isEmpty { break }
            await Task.yield()
        }
        return requestedSleeps
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let requested = base.now.duration(to: deadline)
        lock.withLock { recorded.append(requested) }
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}
