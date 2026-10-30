import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// `HibernationCoordinator.moveRunningShellToHolder` — the one path that moves
/// a session with nothing to resume, by stopping its program and starting a
/// fresh login shell on a holder in the same working directory.
/// (`docs/specs/2026-10-11-holder-transport-migration-design.md`)
///
/// Four steps in a fixed order — refuse, kill, spawn, write once — and what
/// these tests prove is the order and the two states a failure may land in:
/// the row untouched with its program still running, or the row untouched with
/// its window dead. Nothing may leave a row naming a transport its live
/// process is not on.
///
/// The spawn goes through `HolderSpawnOracle`, the coordinator's test seam for
/// it, because a real spawn means a real `TBDHolder`, a real pty and a real
/// handshake — none of which belong in the fast pass, and none of which this
/// composition's decisions depend on. The seam also makes the launch request
/// observable, which is the only way to assert what the replacement shell was
/// actually asked to be. The one branch that does NOT use the seam is the
/// production refusal: a registry that cannot spawn must refuse before
/// anything is touched, and that is asserted against the real registry.
@Suite("Moving a running shell to the pty holder")
struct RunningShellTransportMoveTests {

    // MARK: - Fixture

    /// Every launch the oracle was handed, and every abandon it was asked for.
    private actor SpawnRecorder {
        private(set) var launches: [(terminalID: UUID, launch: HolderLaunchRequest)] = []
        private(set) var abandons: [(terminalID: UUID, handle: HolderHandle)] = []

        func recordLaunch(_ id: UUID, _ launch: HolderLaunchRequest) {
            launches.append((terminalID: id, launch: launch))
        }

        func recordAbandon(_ id: UUID, _ handle: HolderHandle) {
            abandons.append((terminalID: id, handle: handle))
        }
    }

    /// Every tmux argv the dry-run manager was handed.
    private final class TmuxArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            argvs.append(argv)
        }
        var all: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return argvs
        }
        func count(_ subcommand: String) -> Int {
            all.filter { $0.contains(subcommand) }.count
        }
    }

    /// The pids the oracle's handle reports. Deliberately far above any pid
    /// darwin will issue, so nothing in these tests can name a real process
    /// even if a future change signalled what it was handed.
    private static let holderPID: Int32 = 1_900_000_001
    private static let childPID: Int32 = 1_900_000_002
    private static let socketPath = "/tmp/tbd-rstm-not-a-real-socket.sock"

    private static var handle: HolderHandle {
        HolderHandle(holderPID: holderPID, childPID: childPID, socketPath: socketPath)
    }

    private struct Fixture {
        let db: TBDDatabase
        let home: String
        let worktree: Worktree
        let tmuxArgv: TmuxArgvRecorder
        let coordinator: HibernationCoordinator
        let spawns: SpawnRecorder

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
        }

        var launches: [(terminalID: UUID, launch: HolderLaunchRequest)] {
            get async { await spawns.launches }
        }

        var abandons: [(terminalID: UUID, handle: HolderHandle)] {
            get async { await spawns.abandons }
        }
    }

    /// `holderRegistryPresent` false wires no registry at all, which is a
    /// daemon that cannot start a holder for a different reason than
    /// `holderSpawnable` false: there is nothing to take the launch's inherited
    /// environment from either, so the move refuses before it reads anything.
    ///
    /// `holderSpawnable` false builds a registry with no spawner — `canSpawn`
    /// is then false and no oracle is wired, which is the production refusal.
    ///
    /// `spawnThrowsAlreadyRegistered` makes the oracle throw the registry's own
    /// "this session already has a holder", which is what the loser of two
    /// concurrent moves of one row meets.
    ///
    /// `spawnThrows` makes the oracle refuse after recording its launch, which
    /// is what a holder that could not be started looks like from here.
    ///
    /// `beforeTheWrite` runs inside the oracle's spawn, i.e. after the kill and
    /// before the one guarded write — the window in which a window-died
    /// recovery can rotate the row's incarnation and take the race.
    /// `panePID` and `paneForegroundPID` drive the busy rail, exactly as they
    /// do in the migrator's own fixture: a foreground pid equal to the pane's
    /// pid is an idle interactive shell (the default — `FakeInspector` answers
    /// with the pane pid when given nil), a different one is something the
    /// person started, and a pane pid of `"0"` is an unreadable one.
    ///
    /// `windowPresence` is what the kill's failure branch probes.
    private static func makeFixture(
        holderRegistryPresent: Bool = true,
        holderSpawnable: Bool = true,
        spawnThrows: Bool = false,
        spawnThrowsAlreadyRegistered: Bool = false,
        paneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)? = nil,
        panePID: String = "4100",
        paneForegroundPID: Int32? = nil,
        killWindowThrows: Bool = false,
        windowPresence: TmuxPresence = .alive,
        beforeTheWrite: (@Sendable (TBDDatabase, UUID) async -> Void)? = nil
    ) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdrstm")
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let tmuxArgv = TmuxArgvRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { tmuxArgv.record($0) },
            dryRunKillWindowError: { _, _ -> Error? in
                guard killWindowThrows else { return nil }
                return TmuxError.timedOut(command: "kill-window", timeout: .seconds(5))
            },
            dryRunPaneSendTarget: paneSendTarget,
            dryRunPanePID: { _, _ in panePID },
            dryRunWindowPresence: { _, _ in windowPresence })

        let repoPath = "\(home)/repo"
        try FileManager.default.createDirectory(
            atPath: repoPath, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let worktreePath = "\(home)/wt"
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: worktreePath, tmuxServer: "tbd-rstm-test")

        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: makeIsolatedConfigDirManager(tag: "running-shell-move"),
            paneProcessInspector: FakeInspector(
                claudePID: nil, foregroundPID: paneForegroundPID),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(tag: "running-shell-move"))
        // The registry is wired in every arm but the one that asserts its
        // absence: its `environment` is what the launch's own shell invocation
        // is resolved from, and it must never be the developer's.
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
            listTerminals: { [] },
            spawner: holderSpawnable
                ? HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
                : nil)
        if holderRegistryPresent { await coordinator.setHolderRegistry(registry) }

        let spawns = SpawnRecorder()
        if holderRegistryPresent, holderSpawnable {
            await coordinator.setHolderSpawnOracle(HolderSpawnOracle(
                spawn: { terminalID, launch in
                    await spawns.recordLaunch(terminalID, launch)
                    await beforeTheWrite?(db, terminalID)
                    if spawnThrowsAlreadyRegistered {
                        throw HolderRegistry.Error.sessionAlreadyRegistered(
                            terminalID: terminalID)
                    }
                    if spawnThrows { throw HolderRegistry.Error.holderExecutableUnavailable }
                    return Self.handle
                },
                abandon: { terminalID, handle in
                    await spawns.recordAbandon(terminalID, handle)
                }))
        }

        return Fixture(
            db: db, home: home, worktree: worktree, tmuxArgv: tmuxArgv,
            coordinator: coordinator, spawns: spawns)
    }

    /// A running tmux row with no conversation to resume: a shell. Pinned and
    /// labelled, because the move must keep both.
    private static func runningShell(_ fixture: Fixture) async throws -> Terminal {
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "acme shell",
            kind: .shell,
            transport: .tmux)
        try await fixture.db.terminals.setPin(id: created.id, pinned: true)
        try await fixture.db.terminals.setActivityState(
            id: created.id, activityState: .idle, source: .derived)
        return try #require(try await fixture.db.terminals.get(id: created.id))
    }

    // MARK: - The move

    @Test("a running shell is restarted on the holder and the row records it")
    func aRunningShellIsRestartedOnTheHolder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .moved)
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "the row did not move")
        // A row that no longer lives in tmux must not carry a window or pane
        // id: a stale pane coordinate is what let daemon keystrokes reach a
        // different session than the one addressed.
        #expect(after.tmuxWindowID.isEmpty && after.tmuxPaneID.isEmpty,
                "the moved row still names a tmux pane")
        #expect(after.holderPID == Self.holderPID)
        #expect(after.childPID == Self.childPID)
        #expect(after.holderChildStartedAt != nil,
                "a pid with no start time is a pid nothing may signal")
        #expect(!after.isParked, "the move parked a row it was supposed to restart")
    }

    /// Only the move's own facts change: the tab a person is looking at keeps
    /// its identity. The `kind` is the one thing that does not follow the tab —
    /// it follows the PROGRAM, and a login shell is what now runs there.
    @Test("the moved row keeps its id, label and pin, and its kind follows the program")
    func theMovedRowKeepsItsIdentity() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.id == row.id)
        // The label is not a display detail: `WorktreeLifecycle+Recovery` and
        // the app's `PrimaryTerminal` both FIND a tab by it, so a hook tab
        // renamed `shell` by this gesture would be found by nothing.
        #expect(after.label == row.label, "the move renamed the tab")
        #expect(after.pinnedAt == row.pinnedAt)
        // Not `== row.kind`, which a shell row makes vacuous: the write states
        // the kind of what is now running, and preserving an agent kind here
        // would mint a row shape that has never existed — holder-backed,
        // agent-kinded, with no session.
        #expect(after.kind == .shell, "the kind did not follow the program")
        #expect(after.worktreeID == row.worktreeID)
    }

    /// The kill is what stops the session's program, and one kill is all it
    /// takes: there is no park, so nothing else in this path touches tmux.
    @Test("the move kills the row's own window exactly once")
    func theMoveKillsTheRowsWindowExactlyOnce() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        #expect(fixture.tmuxArgv.count("kill-window") == 1,
                "the move did not stop the program exactly once: \(fixture.tmuxArgv.all)")
        #expect(fixture.tmuxArgv.all.contains { $0.contains("kill-window") && $0.contains("@7") },
                "a window was killed, but not this row's: \(fixture.tmuxArgv.all)")
    }

    /// "The same working directory" is the worktree's path, which is where a
    /// tmux shell for this row was created too — and the replacement carries
    /// the incarnation the row ends up naming, so a hook from it is
    /// attributable to this process rather than to the one just killed.
    @Test("the launch is a login shell in the worktree, carrying the minted incarnation")
    func theLaunchIsALoginShellInTheWorktree() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        let launches = await fixture.launches
        #expect(launches.count == 1, "the move spawned \(launches.count) holders")
        let launch = try #require(launches.first)
        #expect(launch.terminalID == row.id, "the holder was spawned for another session")
        #expect(launch.launch.workingDirectory == fixture.worktree.localPath,
                "the replacement shell did not start in the worktree")
        // The command the job runs is the last argument of the shell
        // invocation: the exports, then the login shell itself.
        let command = try #require(launch.launch.arguments.last)
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(command.hasSuffix(loginShell),
                "the replacement program is not the login shell: \(command)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        let incarnation = try #require(after.sessionIncarnationID)
        #expect(command.contains("export TBD_TERMINAL_INCARNATION_ID='\(incarnation.uuidString)'"),
                "the replacement shell does not carry the incarnation the row names: \(command)")
        #expect(incarnation != row.sessionIncarnationID,
                "the move left the dead process's incarnation on the row")
        // Both are load-bearing for the same reasons the recreate-as-shell
        // branch gives: `tbd` commands and a hand-launched agent in this shell
        // resolve their worktree and their tab from these two.
        #expect(command.contains("export TBD_WORKTREE_ID='\(fixture.worktree.id.uuidString)'"),
                "the replacement shell would resolve another worktree: \(command)")
        #expect(command.contains("export TBD_TERMINAL_ID='\(row.id.uuidString)'"),
                "the replacement shell would resolve another tab: \(command)")
    }

    /// The dead process's session and activity facts are cleared, so the
    /// replacement's first hook cannot read as a resume of what was killed.
    @Test("the move clears the dead process's activity facts")
    func theMoveClearsTheDeadProcessActivityFacts() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)
        #expect(row.activityState == .idle, "the fixture did not record a prior state")

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.activityState == .unknown,
                "the killed process's activity state outlived it")
        #expect(after.claudeSessionID == nil)
        #expect(after.pendingSessionIncarnationID == nil)
    }

    // MARK: - Refusing before anything is touched

    /// The production branch, with no oracle: a daemon that cannot start a
    /// holder must leave the session the program it has.
    @Test("a registry that cannot spawn refuses and touches nothing")
    func aRegistryThatCannotSpawnRefusesAndTouchesNothing() async throws {
        let fixture = try await Self.makeFixture(holderSpawnable: false)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .refused(
            reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "a refused move stopped the session's program: \(fixture.tmuxArgv.all)")
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a refused move changed the row")
    }

    /// The other half of the same branch: a daemon with no registry at all.
    /// The registry is where the launch's inherited environment comes from, so
    /// a move without one could not compose a launch even if it could spawn.
    @Test("a daemon with no holder registry refuses and touches nothing")
    func aDaemonWithNoHolderRegistryRefusesAndTouchesNothing() async throws {
        let fixture = try await Self.makeFixture(holderRegistryPresent: false)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .refused(
            reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "a refused move stopped the session's program: \(fixture.tmuxArgv.all)")
        #expect(await fixture.launches.isEmpty)
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a refused move changed the row")
    }

    /// The pane-ownership guard, both refusing answers. A tmux server restart
    /// resets window and pane numbering, and several worktrees of one repo
    /// share a server, so this row's coordinate can collide with an unrelated
    /// live terminal's — and a consultation that could not be run is "we do
    /// not know", not "gone".
    @Test(arguments: RefusingPaneAnswer.allCases)
    func aPaneNotProvablyOursRefusesAndTouchesNothing(
        _ refusal: RefusingPaneAnswer
    ) async throws {
        let fixture = try await Self.makeFixture(
            paneSendTarget: { _, _ in try refusal.answer() })
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        guard case .refused(let reason) = outcome else {
            Issue.record("an unverified pane was moved anyway: \(outcome)")
            return
        }
        #expect(reason.contains("Stopping its program would have risked"),
                "the refusal did not name the recycled coordinate: \(reason)")
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the move killed a window it could not prove was this row's: \(fixture.tmuxArgv.all)")
        #expect(await fixture.launches.isEmpty,
                "the move started a holder for a session it had not stopped")
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a refused move changed the row")
    }

    /// The busy rail, and the only one a shell can have: a shell fires no
    /// hooks, so its activity state is never written and the eligibility rails
    /// that skip a busy session can never fire for one. The process table
    /// answers instead, and a fleet-wide run is exactly the case where the
    /// person did not pick this tab.
    ///
    /// `busy`, not `refused`, because it is a state they can change — which is
    /// a different column of a fleet run's report.
    @Test("a pane running something other than its own shell is left alone and named")
    func aPaneRunningSomethingElseIsLeftAloneAndNamed() async throws {
        let fixture = try await Self.makeFixture(
            panePID: "4100", paneForegroundPID: 4242)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .busy(
            reason: HibernationCoordinator.shellMovePaneBusyRefusal(pid: 4242)))
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the move stopped something the person started: \(fixture.tmuxArgv.all)")
        #expect(await fixture.launches.isEmpty, "the move started a holder anyway")
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a busy session's row was changed")
    }

    /// The rail's other two legs, both of which must proceed. A foreground pid
    /// equal to the pane's own is an idle interactive shell — that is the
    /// ordinary case and the one the whole feature exists for. A pane pid tmux
    /// cannot answer for is not evidence that a process is there, so it
    /// proceeds too, exactly as it does for the wake; refusing on it would
    /// strand the row behind a probe failure with no way back.
    @Test(arguments: ["4100", "0"])
    func anIdleOrUnreadablePaneStillMoves(_ panePID: String) async throws {
        let fixture = try await Self.makeFixture(panePID: panePID)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        #expect(try await fixture.db.terminals.get(id: row.id)?.transport == .holder)
    }

    /// A worktree that gives the move no local directory. `getLocal` answers
    /// nil for a row that could not be read AND for a perfectly readable
    /// REMOTE row, which has no filesystem path and no tmux server, so the
    /// refusal has to read sensibly for both — this drives the first.
    @Test("a session whose worktree gives no local directory is refused untouched")
    func aSessionWithNoLocalWorktreeIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var row = try await Self.runningShell(fixture)
        row.worktreeID = UUID()

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .refused(
            reason: HibernationCoordinator.shellMoveWorktreeUnreadableRefusal))
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "a refused move stopped the session's program: \(fixture.tmuxArgv.all)")
        #expect(await fixture.launches.isEmpty)
    }

    /// A window that is already gone is not a failure to stop anything.
    /// `PaneOwnership.owned` covers "pane gone, server positively absent" on
    /// purpose, so a row whose window died before the person reached for this
    /// gesture arrives at the kill and gets an error from it — and must not be
    /// refused over a program that no longer exists.
    @Test("a kill that fails on an already-gone window still moves the session")
    func aKillOnAnAlreadyGoneWindowStillMoves() async throws {
        let fixture = try await Self.makeFixture(
            killWindowThrows: true, windowPresence: .absent)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.holderPID == Self.holderPID)
    }

    /// A kill that tmux would not perform leaves the program running, so
    /// nothing may be started beside it: two live programs for one row is the
    /// one state this path must never produce. Both answers that are not a
    /// positive "no such window" refuse — `.unknown` is "we do not know",
    /// which is a refusal at every site in this family.
    @Test(arguments: [TmuxPresence.alive, TmuxPresence.unknown])
    func aKillTmuxRefusesStartsNothingOnAWindowNotProvablyGone(
        _ presence: TmuxPresence
    ) async throws {
        let fixture = try await Self.makeFixture(
            killWindowThrows: true, windowPresence: presence)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        guard case .refused(let reason) = outcome else {
            Issue.record("a window that could not be stopped was moved anyway: \(outcome)")
            return
        }
        #expect(reason.contains("could not be stopped"),
                "the refusal did not name the failed kill: \(reason)")
        #expect(await fixture.launches.isEmpty,
                "a second program was started beside one that is still running")
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a refused move changed the row")
    }

    // MARK: - Failing after the kill

    /// The first of the two states a failed move lands in: the row untouched,
    /// still naming the window that is now dead. That is the ordinary
    /// window-died state the app's recovery banner already owns, and
    /// `terminal.recreateWindow` can still repair it precisely because the row
    /// has not been rewritten.
    @Test("a spawn that fails leaves the row on tmux with its coordinates intact")
    func aSpawnThatFailsLeavesTheRowOnTmux() async throws {
        let fixture = try await Self.makeFixture(spawnThrows: true)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        guard case .refused(let reason) = outcome else {
            Issue.record("a failed spawn was reported as \(outcome)")
            return
        }
        #expect(reason.contains("starting a holder"),
                "the refusal did not name the failed spawn: \(reason)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "a failed spawn rewrote the row anyway")
        #expect(after.tmuxWindowID == row.tmuxWindowID && after.tmuxPaneID == row.tmuxPaneID,
                "the row lost the coordinates its recovery needs")
        #expect(after.holderPID == nil && after.childPID == nil,
                "the row records processes that were never started")
        #expect(await fixture.abandons.isEmpty,
                "a spawn that never happened was abandoned")
    }

    /// The loser of two concurrent moves of one row. The registry declines the
    /// spawn because the winner already has a holder for this session, and the
    /// spawn-failure message must not be reused for it: its recovery advice —
    /// the row reads as running on tmux with its window gone, and the tab's
    /// window-died recovery repairs it — is false in every particular once the
    /// winner has moved the row.
    @Test("a spawn the registry declines as already-registered says another move won")
    func aSecondConcurrentMoveSaysAnotherMoveWon() async throws {
        let fixture = try await Self.makeFixture(spawnThrowsAlreadyRegistered: true)
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .refused(
            reason: HibernationCoordinator.shellMoveAlreadyMovingRefusal))
        guard case .refused(let reason) = outcome else { return }
        #expect(!reason.contains("window-died recovery"),
                "the loser was given the spawn failure's false recovery advice: \(reason)")
        #expect(await fixture.abandons.isEmpty,
                "a spawn that never happened was abandoned")
    }

    /// The parity guard its sibling retire has. No reachable row shape has
    /// `transport == .tmux` with blank coordinates today, but `kill-window -t
    /// ''` on a server several worktrees share is not a no-op, and a row that
    /// names no window has nothing to stop — so the move carries on to the
    /// replacement shell without asking tmux to kill anything.
    @Test("a row naming no tmux window kills nothing and still moves")
    func aRowNamingNoTmuxWindowKillsNothing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var row = try await Self.runningShell(fixture)
        try await fixture.db.terminals.updateTmuxIDs(id: row.id, windowID: "", paneID: "")
        row = try #require(try await fixture.db.terminals.get(id: row.id))

        #expect(await fixture.coordinator.moveRunningShellToHolder(terminal: row) == .moved)

        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the move asked tmux to kill a window it does not name: \(fixture.tmuxArgv.all)")
        #expect(try await fixture.db.terminals.get(id: row.id)?.transport == .holder)
    }

    /// The second state, and the reason the abandon is not optional: a holder
    /// and a job no row names would be reclaimable by nothing.
    ///
    /// The race is the real one — a window-died recovery recreating the row's
    /// window in the gap between the kill and the write, which rotates the
    /// row's incarnation. The compare-and-set then writes nothing, and the
    /// person keeps the fresh tmux window the recovery gave them.
    @Test("a write that loses its compare-and-set abandons the holder")
    func aWriteThatLosesItsCompareAndSetAbandonsTheHolder() async throws {
        let fixture = try await Self.makeFixture(beforeTheWrite: { db, terminalID in
            guard let current = try? await db.terminals.get(id: terminalID) else { return }
            _ = try? await db.terminals.replaceRecreatedShellWindow(
                id: terminalID,
                expectedIncarnation: TerminalSessionIncarnation(terminal: current),
                windowID: "@9", paneID: "%9", at: Date())
        })
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        let outcome = await fixture.coordinator.moveRunningShellToHolder(terminal: row)

        #expect(outcome == .lostTheRace)
        let abandons = await fixture.abandons
        #expect(abandons.count == 1, "the holder nobody names was not abandoned")
        #expect(abandons.first?.terminalID == row.id)
        #expect(abandons.first?.handle == Self.handle,
                "a handle other than the spawned one was abandoned")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "the write landed on a row that had moved")
        #expect(after.tmuxWindowID == "@9" && after.tmuxPaneID == "%9",
                "the recovery's window was taken from the person anyway")
        #expect(after.holderPID == nil && after.childPID == nil,
                "the row names a holder that was abandoned")
    }

    /// The write's own guard, each clause on its own. Every snapshot below
    /// MATCHES the row it is handed, so each refusal comes from the clause
    /// under test rather than from a stale snapshot standing in for it.
    @Test("the guarded write refuses a parked row and a holder row, matching snapshot and all")
    func theGuardedWriteRefusesEveryStateItMustNot() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)

        // Parked: this write is for a RUNNING row, and the parked path has its
        // own (`setParkedTransport`).
        try await fixture.db.terminals.setHibernated(
            id: row.id, sessionID: "acme-session", reason: .manual)
        let parked = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(try await fixture.db.terminals.moveRunningShellToHolder(
            id: row.id, expectedState: TerminalReplacementSnapshot(terminal: parked),
            incarnationID: UUID(), holderPID: 1, childPID: 2, startedAt: Date()) == nil,
                "a parked row was moved by the running-row write")
        #expect(try await fixture.db.terminals.get(id: row.id) == parked,
                "a refused write changed the row")

        // Awake again, and this time the write lands — which is what makes the
        // refusal above about the park and not about the shape of the call.
        try await fixture.db.terminals.clearHibernated(id: row.id)
        let awake = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(try await fixture.db.terminals.moveRunningShellToHolder(
            id: row.id, expectedState: TerminalReplacementSnapshot(terminal: awake),
            incarnationID: UUID(), holderPID: Self.holderPID, childPID: Self.childPID,
            startedAt: Date()) != nil,
                "an awake row was refused")

        // Already on the holder: nothing to move, and its processes are its own.
        let moved = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(moved.transport == .holder)
        #expect(try await fixture.db.terminals.moveRunningShellToHolder(
            id: row.id, expectedState: TerminalReplacementSnapshot(terminal: moved),
            incarnationID: UUID(), holderPID: 3, childPID: 4, startedAt: Date()) == nil,
                "a holder row was moved again")
        #expect(try await fixture.db.terminals.get(id: row.id)?.holderPID == Self.holderPID,
                "a refused write replaced the live holder's pids")
    }

    /// And a stale snapshot, which is the clause the live race turns on.
    @Test("the guarded write refuses a snapshot the row has moved past")
    func theGuardedWriteRefusesAStaleSnapshot() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.runningShell(fixture)
        let stale = TerminalReplacementSnapshot(terminal: row)

        _ = try await fixture.db.terminals.replaceRecreatedShellWindow(
            id: row.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: row),
            windowID: "@9", paneID: "%9", at: Date())

        #expect(try await fixture.db.terminals.moveRunningShellToHolder(
            id: row.id, expectedState: stale, incarnationID: UUID(),
            holderPID: 1, childPID: 2, startedAt: Date()) == nil,
                "a snapshot the row had moved past was written anyway")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
        #expect(after.tmuxWindowID == "@9", "the recreate's window was overwritten")
    }
}
