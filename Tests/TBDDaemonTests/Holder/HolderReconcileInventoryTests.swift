import Darwin
import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

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

    private func seedRepo(db: TBDDatabase, at repoPath: String) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: TmuxServerName.forRepoPath(repoPath))
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
        clock: any Clock<Duration> = ContinuousClock(),
        subscriptions: StateSubscriptionManager? = nil
    ) -> WorktreeLifecycle {
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            subscriptions: subscriptions,
            processSignaller: signaller,
            // Every tmux server reads as gone — the answer a holder row's worktree
            // gets from a real socket, since a server that was never started has
            // none — so a holder row that reached the tmux arm would be reclaimed.
            leftoverTmuxProbe: .absent,
            clock: clock)
        lifecycle.holderRegistry = registry
        return lifecycle
    }

    /// Opts the fixture into the arm under test.
    ///
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

    /// A finished resumable Claude row is PARKED rather than deleted, exactly
    /// as the tmux arm parks its equivalent — every transport has a wake path,
    /// so a park is worth having on every transport. The shell row is still
    /// deleted because there is nothing about it to preserve.
    @Test("a resumable holder row is parked instead of deleted")
    func aResumableHolderRowIsParked() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db,
            signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        // With a start time, as a spawned row has, so the park below has one
        // to clear.
        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243,
            holderChildStartedAt: Self.endedJobStartedAt)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog())

        let parked = try #require(
            try await db.terminals.get(id: claude.id),
            "a resumable holder row was deleted instead of parked")
        #expect(parked.isParked)
        #expect(parked.hibernateReason == .recovery)
        #expect(parked.claudeSessionID == "sess-holder", "the session id must survive the park")
        // A parked holder row names no processes: the holder and its job are
        // already gone, and pids left on the row point every identity check at
        // numbers the kernel has recycled.
        #expect(parked.holderPID == nil)
        #expect(parked.childPID == nil)
        #expect(parked.holderChildStartedAt == nil)

        #expect(
            try await db.terminals.get(id: shell.id) == nil,
            "a holder-backed shell row has no session to preserve and must still be deleted")
    }

    /// **The arm runs unconditionally.** No gesture is made against the config
    /// row here — the singleton stands exactly as `Database` seeds it — and the
    /// arm still judges both rows. An arm that had grown a gate of its own
    /// would leave them untouched and fail this.
    @Test("the holder arm judges rows with no config gesture at all")
    func theHolderArmJudgesWithNoConfigGesture() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
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
            actuationLog: makeTestActuationLog())

        let parked = try #require(
            try await db.terminals.get(id: claude.id),
            "the holder arm did not judge a resumable row on an untouched config")
        #expect(
            parked.isParked,
            "the holder arm left a finished resumable row awake on an untouched config")
        #expect(
            try await db.terminals.get(id: shell.id) == nil,
            "the holder arm did not judge a shell row on an untouched config")
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
            actuationLog: makeTestActuationLog())

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

    @Test("an identified Codex holder row parks with its launch metadata")
    func anIdentifiedCodexHolderRowParks() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let codex = try await seedRecoveryTerminal(db: db, worktreeID: main.id, transport: .holder)
        let unidentified = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "", kind: .codex,
            transport: .holder, holderPID: 4244, childPID: 4245)
        let logPath = tempDir.appendingPathComponent("recovery.jsonl").path
        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: ActuationLog(path: logPath))
        try await expectRecoveryPark(db: db, before: codex, logPath: logPath)
        #expect(try await db.terminals.get(id: unidentified.id) == nil)
    }

    @Test("unknown holder ownership leaves identified Codex unchanged")
    func unknownHolderOwnershipKeepsCodex() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: nil)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let codex = try await seedRecoveryTerminal(db: db, worktreeID: main.id, transport: .holder)
        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog())
        #expect(try await db.terminals.get(id: codex.id) == codex)
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
        // waiting on a real five seconds. The budget's timer is its own
        // unstructured task, so its sleep registers a scheduling hop after
        // `begin` returns: the event-driven clock signals that arming instead
        // of polling for it with megaYield probes, which starve under the
        // saturated fast pass. Advancing promises only that the sleeper was
        // resumed, not that the timer has run `expire()`, so the flag is then
        // awaited rather than sampled.
        let clock = EventDrivenTestClock()
        await lifecycle.holderProbeBudget.begin(.seconds(5), clock: clock)
        try await clock.requireAdvanceWhenArmed(by: .seconds(5))
        let started = ContinuousClock.now
        let spent = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await lifecycle.holderProbeBudget.isSpent
        }
        if spent == .cancelled { return }
        if spent == .timedOut {
            Issue.record(BudgetNeverSpent(elapsed: ContinuousClock.now - started))
        }

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

    private struct BudgetNeverSpent: Error, CustomStringConvertible {
        let elapsed: Duration
        var description: String {
            """
            the budget's timer was resumed past its whole budget, but isSpent was \
            still false after \(elapsed)
            """
        }
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

    /// The first sleep the phase budget's timer asked of `clock`.
    ///
    /// Waited for, not sampled: the timer is its own unstructured task, so it
    /// reaches the clock a scheduling hop after the pass that armed it, which
    /// may already have returned — and under the fast parallel pass one hop
    /// can take tens of seconds. Nil when the wait ended without a sleep:
    /// after recording `NoBudgetSleep` on a timeout, and silently on
    /// cancellation, which belongs to whatever cancelled the test.
    ///
    /// The diagnostic reports the sleeps the poll's final probe read, not a
    /// fresh read after it: a timer that registers just after that probe
    /// would otherwise report one sleep for a wait that saw none.
    private func firstBudgetSleep(
        on clock: SleepRecordingClock, missing: String
    ) async -> Duration? {
        let started = ContinuousClock.now
        var observed: [Duration] = []
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            observed = clock.requestedSleeps
            return !observed.isEmpty
        }
        switch outcome {
        case .satisfied:
            return observed.first
        case .cancelled:
            return nil
        case .timedOut:
            Issue.record(NoBudgetSleep(
                finding: missing, elapsed: ContinuousClock.now - started,
                sleeps: observed.count))
            return nil
        }
    }

    private struct NoBudgetSleep: Error, CustomStringConvertible {
        let finding: String
        let elapsed: Duration
        let sleeps: Int
        var description: String {
            "\(finding) — \(sleeps) sleep(s) requested of the clock after \(elapsed)"
        }
    }

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
            actuationLog: makeTestActuationLog())

        // The pass really did the work the budget bounds, so a recorded sleep
        // is not a sleep from some other pass that judged nothing.
        #expect(try await db.terminals.get(id: claude.id)?.isParked == true)
        #expect(try await db.terminals.get(id: shell.id) == nil)

        // The budget's timer is its own task, so it can reach the clock a hop
        // or two after the pass that armed it has already cancelled it.
        guard let requested = await firstBudgetSleep(
            on: clock,
            missing: """
                the reconcile pass never asked the lifecycle's clock for a budget: the whole \
                pre-bind bound on this serial arm is gone
                """)
        else { return }
        #expect(
            requested <= WorktreeLifecycle.holderPhaseBudget
                && requested > WorktreeLifecycle.holderPhaseBudget - .milliseconds(500),
            """
            the pass armed a budget of \(requested) rather than \
            \(WorktreeLifecycle.holderPhaseBudget)
            """)
    }

    /// The budget is armed on every pass, with no config gesture: the arm it
    /// bounds runs unconditionally, so a pass that armed nothing would leave
    /// this serial arm unbounded before the daemon's socket is bound.
    @Test("the reconcile pass arms the budget with no config gesture at all")
    func theProductionPassArmsTheBudgetUnconditionally() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let clock = SleepRecordingClock()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]),
            registry: registry(environment: vanishedHolderEnvironment()), clock: clock)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4242, childPID: 4243)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: shell.id) == nil)
        _ = await firstBudgetSleep(
            on: clock, missing: "the reconcile pass armed no phase budget on an untouched config")
    }

    // MARK: - Overlapping passes share one budget

    /// Passes overlap in production — the hourly scratch pass and the reaper's
    /// hand-back both make their first run as the daemon starts — so a pass
    /// that ends while another is still running must not take the bound off
    /// the other. And once the last pass ends, the next one starts a fresh
    /// clock rather than inheriting a spent one.
    @Test("a pass that ends inside another leaves the other's budget running", .clockDriven)
    func anInnerPassLeavesTheOuterBudgetRunning() async throws {
        let budget = HolderProbeBudget()
        let clock = EventDrivenTestClock()
        await budget.begin(.seconds(5), clock: clock)
        await budget.begin(.seconds(5), clock: clock)
        await budget.end()

        // The outer pass's timer is still armed, and firing it spends the
        // budget the outer pass is still running under.
        try await clock.requireAdvanceWhenArmed(by: .seconds(5))
        let started = ContinuousClock.now
        let spent = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await budget.isSpent
        }
        if spent == .cancelled { return }
        if spent == .timedOut {
            Issue.record(BudgetNeverSpent(elapsed: ContinuousClock.now - started))
        }

        await budget.end()
        await budget.begin(.seconds(5), clock: clock)
        #expect(
            await budget.isSpent == false,
            "a pass begun after every pass had ended inherited the last one's spent budget")
        await budget.end()
    }

    /// A timer's sleep can return a moment before the last pass's `end`
    /// cancels it: too late for the cancel to stop it, but before its expiry
    /// reaches the budget. By the time that expiry lands, a new pass may have
    /// begun on a clock of its own, and the stale expiry must not spend it —
    /// that pass would keep every row it reaches without probing one.
    ///
    /// The held clock stands in for that moment: its sleep ignores the cancel
    /// and returns only when the test releases it, after the new pass began.
    /// Joining the old timer then proves its expiry has run before the flag
    /// is read, so the negative needs no window.
    @Test("an expiry from an ended pass's clock does not spend a later pass", .clockDriven)
    func aStaleExpiryDoesNotSpendALaterPass() async throws {
        let budget = HolderProbeBudget()
        let held = HeldSleepClock()
        await budget.begin(.seconds(5), clock: held)
        let staleTimer = try #require(await budget.timerForTesting)
        await budget.end()

        // The later pass's own clock, which nothing advances: only the stale
        // expiry could spend this pass.
        await budget.begin(.seconds(5), clock: EventDrivenTestClock())
        held.release()
        await staleTimer.value

        #expect(
            await budget.isSpent == false,
            "the expiry of a clock whose pass had ended spent the pass begun after it")
        await budget.end()
    }

    // MARK: - The reaper's hand-back

    /// The incident's shape: a Claude row whose holder (4242) and job (4243)
    /// are gone, which the startup pass kept because the job was mid-exit
    /// when it looked.
    ///
    /// It carries the job's start time, as every spawned holder row does, so
    /// a park that left it on the row would show. Nothing the hand-back or the
    /// sweep decides reads it: the verdict asks only whether the pid is alive,
    /// and the disposal's compare-and-set compares pids, not start times.
    ///
    /// Read back after the insert, so a later comparison against the stored
    /// row compares like with like.
    private func seedEndedClaudeRow(db: TBDDatabase, worktreeID: UUID) async throws -> Terminal {
        let created = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243,
            holderChildStartedAt: Self.endedJobStartedAt)
        return try #require(try await db.terminals.get(id: created.id))
    }

    /// When the ended rows' job started: a whole second, so it survives the
    /// database's date encoding unchanged.
    private static let endedJobStartedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func actuationRows(at path: String) throws -> [ActuationRow] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(ActuationRow.self, from: Data($0.utf8)) }
    }

    private func handBack(
        _ terminal: Terminal, to lifecycle: WorktreeLifecycle,
        holderPID: Int32? = 4242, childPID: Int32? = 4243,
        actuationLog: ActuationLog = makeTestActuationLog()
    ) async -> HolderRowVerdict? {
        await lifecycle.reconcileHolderRowAfterJobGone(
            terminalID: terminal.id, expectedHolderPID: holderPID,
            expectedChildPID: childPID, actuationLog: actuationLog)
    }

    /// The gap the hand-back closes. The adoption that followed the startup
    /// pass remembered the session as ended with an unknown status, the job is
    /// gone now, and the row is parked exactly as the startup pass would have
    /// parked it — reason, session, cleared pids and the actuation record.
    @Test("a handed-back row whose job is gone is parked for recovery")
    func aHandedBackRowIsParked() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        // The nil start time asserted after the park proves a clear only if
        // the row had one to clear.
        try #require(claude.holderChildStartedAt != nil)
        await registry.recordStatusForTesting(
            .exitedStatusUnknown, for: claude.id, fromAbsentRendezvous: true)
        let logPath = tempDir.appendingPathComponent("handback.jsonl").path

        let verdict = await handBack(
            claude, to: lifecycle, actuationLog: ActuationLog(path: logPath))

        #expect(verdict == .sessionOver(.exitedStatusUnknown))
        let parked = try #require(
            try await db.terminals.get(id: claude.id),
            "a resumable handed-back row was deleted instead of parked")
        #expect(parked.isParked)
        #expect(parked.hibernatedAt != nil)
        #expect(parked.hibernateReason == .recovery)
        #expect(parked.claudeSessionID == "sess-holder", "the session id must survive the park")
        #expect(parked.holderPID == nil)
        #expect(parked.childPID == nil)
        #expect(parked.holderChildStartedAt == nil)
        #expect(parked.sessionIncarnationID != claude.sessionIncarnationID)

        let rows = try actuationRows(at: logPath)
        let request = try #require(rows.first { $0.kind == .hibernate })
        #expect(request.actor == .daemon(rail: ActuationRail.reconcile))
        #expect(request.target == .local(worktree: main.id, terminal: claude.id))
        #expect(rows.contains { $0.confirms == request.id && $0.result == .synchronous(.dispatched) })
    }

    /// Parity with the startup pass's other fork: a row with nothing to resume
    /// is deleted with its tab. Through the probe this time — nothing is
    /// remembered about the session, and the rendezvous is empty.
    @Test("a handed-back row with no session to resume is deleted with its tab")
    func aHandedBackShellRowIsDeleted() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4242, childPID: 4243)
        try await db.tabs.setLabel(tabID: shell.id, worktreeID: main.id, label: "acme shell")

        let verdict = await handBack(shell, to: lifecycle)

        #expect(verdict == .sessionOver(.exitedStatusUnknown))
        #expect(try await db.terminals.get(id: shell.id) == nil)
        let tabIDs = try await db.tabs.listForWorktree(worktreeID: main.id).map(\.id)
        #expect(!tabIDs.contains(shell.id), "the row was deleted and its tab left behind")
    }

    /// The reaper read the job as gone, but the verdict's own last gate reads
    /// it again — and a job running now keeps its row, which is the only
    /// record of its pid.
    @Test("a handed-back row whose job is running again by the verdict's read is kept")
    func aHandedBackRowWithALiveJobIsKept() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4243] = FakeProcessSignaller.Behavior(aliveInitially: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let lifecycle = makeLifecycle(db: db, signaller: signaller, registry: registry)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        await registry.recordStatusForTesting(.exitedStatusUnknown, for: claude.id)

        let verdict = await handBack(claude, to: lifecycle)

        #expect(verdict == .keep(reason: "job-still-running"))
        #expect(try await db.terminals.get(id: claude.id) == claude)
    }

    /// A viewer owning the pty ends the questioning here as it does in the
    /// sweep: the hand-back asks the sweep's verdict, gates and all.
    @Test("a handed-back row a viewer holds is kept")
    func aHandedBackRowAViewerHoldsIsKept() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        await registry.recordStatusForTesting(.exitedStatusUnknown, for: claude.id)
        await registry.recordViewerClaimForTesting(
            terminalID: claude.id, generation: 1, owner: nil)

        let verdict = await handBack(claude, to: lifecycle)

        #expect(verdict == .keep(reason: "viewer-attached"))
        #expect(try await db.terminals.get(id: claude.id) == claude)
    }

    /// A row that is already parked is exactly what the hand-back would
    /// produce, and judging it again would stamp a second park over the first.
    /// It still names its pids here — the shape a park whose pid clear failed
    /// leaves — so only the parked gate stands between it and a re-park.
    @Test("a handed-back row that is already parked is left alone")
    func aParkedRowIsLeftAlone() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        try await db.terminals.setHibernated(
            id: claude.id, sessionID: "sess-holder", reason: .manual)
        let parked = try #require(try await db.terminals.get(id: claude.id))
        await registry.recordStatusForTesting(.exitedStatusUnknown, for: claude.id)
        let logPath = tempDir.appendingPathComponent("handback.jsonl").path

        let verdict = await handBack(
            parked, to: lifecycle, actuationLog: ActuationLog(path: logPath))

        #expect(verdict == nil)
        #expect(try await db.terminals.get(id: claude.id) == parked)
        #expect(try actuationRows(at: logPath).isEmpty)
    }

    /// A wake or a respawn between the reaper's read and this one gives the
    /// row a new holder and job. The session those name is running now, and
    /// parking it would let a later wake start a second agent on the same
    /// session id — so a row naming anything but the pids the reaper found
    /// gone is not judged at all.
    @Test("a handed-back row that names a different holder or job is left alone")
    func aRowWithOtherPidsIsLeftAlone() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        await registry.recordStatusForTesting(.exitedStatusUnknown, for: claude.id)
        let logPath = tempDir.appendingPathComponent("handback.jsonl").path
        let log = ActuationLog(path: logPath)

        #expect(await handBack(claude, to: lifecycle, holderPID: 5252, actuationLog: log) == nil)
        #expect(await handBack(claude, to: lifecycle, childPID: 5253, actuationLog: log) == nil)
        #expect(await handBack(claude, to: lifecycle, holderPID: nil, actuationLog: log) == nil)

        #expect(try await db.terminals.get(id: claude.id) == claude)
        #expect(try actuationRows(at: logPath).isEmpty)
    }

    /// Only a holder row has a holder to have found gone. A tmux row naming
    /// the same pids — which a real one never does — would otherwise reach the
    /// holder arm's verdict and be parked on its say.
    @Test("a handed-back row that is not on the holder is left alone")
    func aTmuxRowIsLeftAlone() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let lifecycle = makeLifecycle(db: db, signaller: deadJobs([4243]), registry: registry)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let created = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-tmux",
            kind: .claude, transport: .tmux, holderPID: 4242, childPID: 4243)
        let tmux = try #require(try await db.terminals.get(id: created.id))
        await registry.recordStatusForTesting(.exitedStatusUnknown, for: tmux.id)

        let verdict = await handBack(tmux, to: lifecycle)

        #expect(verdict == nil)
        #expect(try await db.terminals.get(id: tmux.id) == tmux)
    }

    /// A row the reaper read and that has since been closed is nothing to
    /// judge.
    @Test("a handed-back row that is gone is nothing to judge")
    func aGoneRowIsNothingToJudge() async throws {
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let missing = Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4242, childPID: 4243)

        #expect(await handBack(missing, to: lifecycle) == nil)
    }

    /// The hand-back probes under the same phase budget as a pass, on the
    /// lifecycle's own clock — and ends it, so the next pass starts a clock
    /// of its own rather than finding one already running.
    @Test("the hand-back arms the phase budget and ends it")
    func theHandBackArmsAndEndsTheBudget() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let clock = SleepRecordingClock()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]),
            registry: registry(environment: vanishedHolderEnvironment()), clock: clock)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4242, childPID: 4243)

        #expect(await handBack(shell, to: lifecycle) == .sessionOver(.exitedStatusUnknown))
        guard await firstBudgetSleep(
            on: clock, missing: "the hand-back probed a rendezvous with no phase budget armed") != nil
        else { return }

        // A pass begun now starts a clock of its own only if the hand-back
        // ended the one it began.
        await lifecycle.holderProbeBudget.begin(.seconds(5), clock: clock)
        let started = ContinuousClock.now
        var sleepsSeen = 0
        let rearmed = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            sleepsSeen = clock.requestedSleeps.count
            return sleepsSeen >= 2
        }
        // Taken before the cleanup: a second sleep that registers while
        // `end()` is awaited, and the time `end()` takes, are not what the
        // wait saw.
        let waited = ContinuousClock.now - started
        await lifecycle.holderProbeBudget.end()
        if rearmed == .cancelled { return }
        if rearmed == .timedOut {
            Issue.record(BudgetNeverEnded(elapsed: waited, sleeps: sleepsSeen))
        }
    }

    private struct BudgetNeverEnded: Error, CustomStringConvertible {
        let elapsed: Duration
        let sleeps: Int
        var description: String {
            """
            a pass begun after the hand-back returned started no clock of its own after \
            \(elapsed) (\(sleeps) sleep(s) requested): the hand-back left its budget running
            """
        }
    }

    // MARK: - What a disposal announces

    /// A connected app applies a park to its cached row in place, from the
    /// delta every park sends; without it the row reads live until the app
    /// next refetches. The hand-back is the disposal that runs with an app
    /// connected, so it is the one that has to say so.
    @Test("a handed-back row that is parked is announced as parked")
    func aHandedBackParkIsAnnounced() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let registry = registry(environment: vanishedHolderEnvironment())
        let deltas = BroadcastDeltas()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]), registry: registry,
            subscriptions: deltas.manager)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        await registry.recordStatusForTesting(
            .exitedStatusUnknown, for: claude.id, fromAbsentRendezvous: true)

        #expect(await handBack(claude, to: lifecycle) == .sessionOver(.exitedStatusUnknown))

        let parked = try #require(try await db.terminals.get(id: claude.id))
        #expect(deltas.removals(of: claude.id) == 0)
        let announced = deltas.hibernationChanges(of: claude.id)
        #expect(announced.count == 1, "the park was announced \(announced.count) times")
        let park = try #require(announced.first, "the park was never announced to the app")
        #expect(park.worktreeID == main.id)
        #expect(park.hibernated)
        #expect(park.hibernateReason == .recovery)
        #expect(park.keepWarm == parked.keepWarm)
        // The park minted these, and nothing else announces them: a cached
        // row that kept the old incarnation would forward the next session's
        // reports under one the daemon no longer runs.
        #expect(park.sessionIncarnationID == parked.sessionIncarnationID)
        #expect(park.activity?.activityState == .idle)
    }

    /// The other fork: a row deleted with its tab is announced as removed, so
    /// the app drops the tab instead of showing a session that is gone.
    @Test("a handed-back row that is deleted is announced as removed")
    func aHandedBackDeleteIsAnnounced() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let deltas = BroadcastDeltas()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243]),
            registry: registry(environment: vanishedHolderEnvironment()),
            subscriptions: deltas.manager)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4242, childPID: 4243)

        #expect(await handBack(shell, to: lifecycle) == .sessionOver(.exitedStatusUnknown))

        #expect(try await db.terminals.get(id: shell.id) == nil)
        #expect(deltas.removals(of: shell.id) == 1)
        #expect(deltas.hibernationChanges(of: shell.id).isEmpty)
    }

    /// The sweep disposes through the same code, so it announces the same
    /// way. It matters after startup — `repo.add`, `cleanup` and the hourly
    /// scratch pass run with an app connected — and costs nothing at startup,
    /// when nobody is subscribed yet.
    @Test("the sweep announces each row it parks or deletes")
    func theSweepAnnouncesItsDisposals() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let deltas = BroadcastDeltas()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()),
            subscriptions: deltas.manager)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: claude.id)?.isParked == true)
        #expect(deltas.hibernationChanges(of: claude.id).map(\.hibernateReason) == [.recovery])
        #expect(try await db.terminals.get(id: shell.id) == nil)
        #expect(deltas.removals(of: shell.id) == 1)
    }

    /// A write the row refused changed nothing, so it tells the app nothing:
    /// a park or removal announced over a row that was woken onto a new
    /// holder in between would hide a running session. Driven directly,
    /// because neither caller lets a test change the row between its read
    /// and its write.
    @Test("a disposal the row refused announces nothing")
    func aRefusedDisposalAnnouncesNothing() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let deltas = BroadcastDeltas()
        let lifecycle = makeLifecycle(
            db: db, signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()),
            subscriptions: deltas.manager)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        let created = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)
        let shell = try #require(try await db.terminals.get(id: created.id))

        // Both woken onto new holders after the disposal's caller read them.
        try await db.terminals.setHolderProcess(
            id: claude.id, holderPID: 5252, childPID: 5253, startedAt: Date())
        try await db.terminals.setHolderProcess(
            id: shell.id, holderPID: 5254, childPID: 5255, startedAt: Date())

        await lifecycle.disposeOfEndedHolderRow(
            claude, finding: "a stale read", actuationLog: makeTestActuationLog())
        await lifecycle.disposeOfEndedHolderRow(
            shell, finding: "a stale read", actuationLog: makeTestActuationLog())

        #expect(try await db.terminals.get(id: claude.id)?.isParked == false)
        #expect(try await db.terminals.get(id: shell.id) != nil)
        #expect(deltas.all.isEmpty, "a refused disposal broadcast \(deltas.all.count) delta(s)")
    }

    // MARK: - The disposal's compare-and-set

    /// The sweep and the hand-back read a row, probe, and only then write, so
    /// both writes compare against the row as read. These pin the store half:
    /// a row that moved on in between is neither parked nor deleted.
    @Test("an ended holder row is parked or deleted only while it is the row that was read")
    func theDisposalWritesAreCompareAndSet() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let (_, main) = try await seedRepo(db: db, at: repoDir.path)

        // Woken onto a new holder since the read: new pids.
        let claude = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        let read = LiveHolderRowSnapshot(terminal: claude)
        try await db.terminals.setHolderProcess(
            id: claude.id, holderPID: 5252, childPID: 5253, startedAt: Date())
        #expect(try await db.terminals.parkEndedHolderRow(
            id: claude.id, expectedState: read, sessionID: "sess-holder", reason: .recovery) == false)
        #expect(try await db.deleteEndedHolderTerminalAndTab(
            id: claude.id, expectedState: read) == false)
        let woken = try #require(try await db.terminals.get(id: claude.id))
        #expect(!woken.isParked)
        #expect(woken.childPID == 5253)

        // Parked by somebody else since the read.
        let other = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        let otherRead = LiveHolderRowSnapshot(terminal: other)
        try await db.terminals.setHibernated(id: other.id, sessionID: "sess-holder", reason: .manual)
        #expect(try await db.terminals.parkEndedHolderRow(
            id: other.id, expectedState: otherRead, sessionID: "sess-holder", reason: .recovery) == false)
        #expect(try await db.deleteEndedHolderTerminalAndTab(
            id: other.id, expectedState: otherRead) == false)
        #expect(try await db.terminals.get(id: other.id)?.hibernateReason == .manual)

        // Unchanged since the read: both writes go through.
        let unchanged = try await seedEndedClaudeRow(db: db, worktreeID: main.id)
        #expect(try await db.terminals.parkEndedHolderRow(
            id: unchanged.id, expectedState: LiveHolderRowSnapshot(terminal: unchanged),
            sessionID: "sess-holder", reason: .recovery))
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)
        #expect(try await db.deleteEndedHolderTerminalAndTab(
            id: shell.id, expectedState: LiveHolderRowSnapshot(terminal: shell)))
        #expect(try await db.terminals.get(id: shell.id) == nil)

        // Gone since the read.
        #expect(try await db.terminals.parkEndedHolderRow(
            id: shell.id, expectedState: LiveHolderRowSnapshot(terminal: shell),
            sessionID: "sess-holder", reason: .recovery) == false)
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

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let requested = base.now.duration(to: deadline)
        lock.withLock { recorded.append(requested) }
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

/// Every delta a lifecycle broadcasts through `manager`, collected from
/// whichever thread broadcast it.
private final class BroadcastDeltas: @unchecked Sendable {
    let manager = StateSubscriptionManager()
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    init() {
        manager.addSubscriber { [weak self] data in
            guard let self else { return false }
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                lock.withLock { deltas.append(delta) }
            }
            return true
        }
    }

    var all: [StateDelta] { lock.withLock { deltas } }

    func hibernationChanges(of terminalID: UUID) -> [TerminalHibernationDelta] {
        all.compactMap {
            guard case .terminalHibernationChanged(let delta) = $0,
                  delta.terminalID == terminalID else { return nil }
            return delta
        }
    }

    func removals(of terminalID: UUID) -> Int {
        all.filter {
            guard case .terminalRemoved(let delta) = $0 else { return false }
            return delta.terminalID == terminalID
        }.count
    }
}

/// A clock whose every sleep returns normally once `release()` is called, and
/// not before — cancelled or not.
///
/// It models a sleep that had already returned when its task was cancelled:
/// the cancel arrives, and the sleeper goes on as if it had not.
private final class HeldSleepClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock()
    private let lock = NSLock()
    private var released = false
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    /// Ends every sleep, those already waiting and any that start later.
    func release() {
        let waiting = lock.withLock {
            released = true
            defer { sleepers = [] }
            return sleepers
        }
        for sleeper in waiting { sleeper.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await withCheckedContinuation { (sleeper: CheckedContinuation<Void, Never>) in
            let alreadyReleased = lock.withLock {
                if released { return true }
                sleepers.append(sleeper)
                return false
            }
            if alreadyReleased { sleeper.resume() }
        }
    }
}
