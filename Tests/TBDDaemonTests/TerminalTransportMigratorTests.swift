import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// `TerminalTransportMigrator` — moving a session from the tmux transport to
/// the pty holder in place, same row and same session id.
/// (`docs/specs/2026-10-11-holder-transport-migration-design.md`)
///
/// Two wirings, because the composition has two different things to prove and
/// a single wiring cannot prove both in the fast pass.
///
/// - **The production wiring** runs the real park and the real wake against a
///   dry-run tmux and a `HolderRegistry` whose spawner cannot start anything.
///   That is what makes "nothing was spawned" an assertion rather than a hope:
///   the holder wake reserves a replacement incarnation on the row *before* it
///   spawns, so a path that reached the wake leaves a fingerprint even though
///   the spawn then fails. It is also the only wiring that can show the park's
///   own rails refusing.
/// - **The recording wiring** keeps the real park (so the row genuinely parks
///   and the compare-and-set can succeed) and substitutes the wake, which is
///   the one step that needs a live pty. That is what makes the success path,
///   the call order, and a fleet run's report reachable here at all.
@Suite("Moving a session to the pty holder")
struct TerminalTransportMigratorTests {

    static let sessionID = "migrate-me"

    // MARK: - Fixture

    /// Records the ids the migrator asked each operation about, in order.
    ///
    /// An actor rather than a lock-guarded class because every recorded
    /// operation is reached from an `async` closure, and the ordering the
    /// tests assert on is the actor's own serialization.
    private actor CallRecorder {
        private(set) var parks: [UUID] = []
        private(set) var wakes: [UUID] = []
        private(set) var shellMoves: [UUID] = []

        func recordPark(_ id: UUID) { parks.append(id) }
        func recordWake(_ id: UUID) { wakes.append(id) }
        func recordShellMove(_ id: UUID) { shellMoves.append(id) }
    }

    /// Every tmux argv the dry-run manager was handed. `kill-window` is the
    /// one this suite asks about: it is how the migration retires the window
    /// the park kept.
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

    private struct Fixture {
        let db: TBDDatabase
        let home: String
        let worktree: Worktree
        let tmuxArgv: TmuxArgvRecorder
        let coordinator: HibernationCoordinator
        let recorder: CallRecorder
        /// The registry both the park and the wake reach. Its environment is
        /// explicit, so no rendezvous path can reach the developer's real
        /// `~/tbd` even for an instant.
        let holderRegistry: HolderRegistry?

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
        }

        var parks: [UUID] { get async { await recorder.parks } }
        var wakes: [UUID] { get async { await recorder.wakes } }
        var shellMoves: [UUID] { get async { await recorder.shellMoves } }

        /// The migrator wired to the real park and the real wake.
        func productionMigrator() -> TerminalTransportMigrator {
            TerminalTransportMigrator(
                db: db,
                operations: .production(
                    hibernation: coordinator, holderRegistry: holderRegistry))
        }

        /// The migrator wired to the real park (recorded) and a substituted
        /// wake (recorded), so the composition can be driven past the step
        /// that needs a live pty.
        ///
        /// `parkOverride` answers for the ids it is given and the real park
        /// runs for every other row, which is how a single fleet run can hold
        /// one session whose window is gone beside sessions that migrate.
        func recordingMigrator(
            canSpawnHolder: Bool = true,
            parkOverride: [UUID: HibernateResult] = [:],
            wakeResult: WakeResult = .ok(sessionIncarnationID: nil),
            parkAlsoUnparks: Bool = false,
            parkAlsoDeletesTheRow: Bool = false,
            deleteTheRowBeforeTheRewrite: Bool = false,
            shellMoveOutcome: ShellTransportMoveOutcome = .moved
        ) -> TerminalTransportMigrator {
            let database = self.db
            let park = self.coordinator
            let calls = self.recorder
            return TerminalTransportMigrator(
                db: database,
                operations: TerminalTransportMigrator.Operations(
                    canSpawnHolder: { canSpawnHolder },
                    park: { id in
                        await calls.recordPark(id)
                        if let staged = parkOverride[id] { return staged }
                        let result = await park.parkForTransportMigration(terminalID: id)
                        if parkAlsoUnparks, result == .ok {
                            // A focus-wake landing in the gap between the park
                            // and the rewrite, which is the race the
                            // compare-and-set exists to lose safely.
                            try? await database.terminals.clearHibernated(id: id)
                        }
                        if parkAlsoDeletesTheRow, result == .ok {
                            try? await database.terminals.delete(id: id)
                        }
                        return result
                    },
                    wake: { id in
                        await calls.recordWake(id)
                        return wakeResult
                    },
                    // The real probe and the real retire: both are read-only
                    // or dry-run against this fixture's tmux, so there is
                    // nothing for a double to protect here. The probe is also
                    // the last await before the rewrite, which is where a test
                    // that needs the row to vanish mid-migration removes it.
                    paneBusyRefusal: { terminal in
                        if deleteTheRowBeforeTheRewrite {
                            try? await database.terminals.delete(id: terminal.id)
                        }
                        return await park.transportMigrationPaneBusyRefusal(terminal: terminal)
                    },
                    retireWindow: {
                        await park.retireTmuxWindowAfterTransportMigration(terminal: $0)
                    },
                    // Substituted like the wake, and for the same reason: its
                    // own composition needs a holder a fixture cannot start.
                    // `RunningShellTransportMoveTests` proves it; what is
                    // proved here is which rows reach it and how its three
                    // answers are reported.
                    moveRunningShell: { terminal in
                        await calls.recordShellMove(terminal.id)
                        if shellMoveOutcome == .moved {
                            _ = try? await database.terminals.moveRunningShellToHolder(
                                id: terminal.id,
                                expectedState: TerminalReplacementSnapshot(terminal: terminal),
                                incarnationID: UUID(),
                                holderPID: 9201, childPID: 9202, startedAt: Date())
                        }
                        return shellMoveOutcome
                    }))
        }
    }

    /// A spawner whose executable does not exist: `canSpawn` is true, so a
    /// wake reaches its spawn and the spawn always throws. A registry with no
    /// spawner at all refuses earlier and for a different reason, which is the
    /// distinction `holderSpawnable: false` makes.
    private static func unspawnableSpawner() -> HolderSpawner {
        HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
    }

    /// `paneForegroundPID` is what the exit-stamped guard turns on: nil leaves
    /// `FakeInspector` answering with the pane's own pid (an idle shell), and
    /// a value different from `panePID` is something the person started.
    private static func makeFixture(
        holderSpawnable: Bool = true,
        panePID: String = "4100",
        paneForegroundPID: Int32? = nil,
        paneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)? = nil
    ) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdttm")
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let tmuxArgv = TmuxArgvRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { tmuxArgv.record($0) },
            dryRunPaneSendTarget: paneSendTarget,
            dryRunPanePID: { _, _ in panePID })

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
            path: worktreePath, tmuxServer: "tbd-ttm-test")

        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: makeIsolatedConfigDirManager(tag: "transport-migration"),
            paneProcessInspector: FakeInspector(
                claudePID: nil, foregroundPID: paneForegroundPID),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(tag: "transport-migration"))
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
            listTerminals: { [] },
            spawner: holderSpawnable ? unspawnableSpawner() : nil)
        await coordinator.setHolderRegistry(registry)

        return Fixture(
            db: db, home: home, worktree: worktree, tmuxArgv: tmuxArgv,
            coordinator: coordinator,
            recorder: CallRecorder(), holderRegistry: registry)
    }

    /// A tmux-backed Claude row. `parked` is the difference the two migration
    /// paths turn on: a parked row is only rewritten, a running one is parked,
    /// rewritten and woken.
    private static func tmuxRow(
        _ fixture: Fixture,
        parked: Bool = false,
        activityState: TerminalActivityState = .idle,
        kind: TerminalKind? = .claude,
        label: String = TerminalLabel.claudeCode,
        claudeSessionID: String? = sessionID,
        parkReason: HibernateReason = .auto,
        suspended: Bool = false,
        transcriptTail: String = #"{"type":"user","message":{"content":"move me"}}"#
    ) async throws -> Terminal {
        let transcript = "\(fixture.home)/\(UUID().uuidString).jsonl"
        try transcriptTail.write(toFile: transcript, atomically: true, encoding: .utf8)
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: label,
            claudeSessionID: claudeSessionID,
            kind: kind,
            transport: .tmux)
        if let claudeSessionID {
            try await fixture.db.terminals.updateSession(
                id: created.id, sessionID: claudeSessionID, transcriptPath: transcript)
        }
        try await fixture.db.terminals.setActivityState(
            id: created.id, activityState: activityState, source: .derived)
        if parked, let claudeSessionID {
            try await fixture.db.terminals.setHibernated(
                id: created.id, sessionID: claudeSessionID, reason: parkReason)
        }
        // The legacy park column, which `isParked` still reads and
        // `isManuallyHibernatable` still refuses on. The only way to build a
        // row the two park policies answer differently about.
        if suspended, let claudeSessionID {
            try await fixture.db.terminals.setSuspended(
                id: created.id, sessionID: claudeSessionID)
        }
        return try #require(try await fixture.db.terminals.get(id: created.id))
    }

    private static func holderRow(
        _ fixture: Fixture,
        kind: TerminalKind? = .claude,
        label: String = TerminalLabel.claudeCode,
        claudeSessionID: String? = sessionID
    ) async throws -> Terminal {
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "", tmuxPaneID: "",
            label: label,
            claudeSessionID: claudeSessionID,
            kind: kind,
            transport: .holder,
            holderPID: 9101, childPID: 9102)
        return try #require(try await fixture.db.terminals.get(id: created.id))
    }

    // MARK: - The parked path: rewrite only

    /// A parked session is only rewritten. Nothing is running, so there is
    /// nothing to park and nothing to respawn.
    ///
    /// "Nothing was spawned" is asserted on the row rather than on a counter:
    /// the holder wake reserves a replacement incarnation before it spawns, so
    /// a pending incarnation — or a recorded holder pid — is the fingerprint a
    /// path that reached the wake would leave even though this fixture's spawn
    /// could never succeed.
    @Test("a parked row is rewritten with nothing spawned")
    func aParkedRowIsRewrittenWithNothingSpawned() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "the parked row was not rewritten")
        #expect(after.isParked, "the rewrite woke a parked row")
        #expect(after.pendingSessionIncarnationID == nil,
                "the parked path reached the wake's replacement reservation")
        #expect(after.holderPID == nil && after.childPID == nil,
                "the parked path recorded processes for a session it must not have started")
    }

    /// The row keeps its identity: only the transport column (and the tmux
    /// coordinates that go with it) changes.
    @Test("a rewritten row keeps its session id, transcript and label, and loses its tmux coordinates")
    func aRewrittenRowKeepsItsIdentityAndLosesItsPaneCoordinates() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        #expect(await fixture.productionMigrator().migrate(terminalID: row.id) == .migrated)

        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.id == row.id)
        #expect(after.claudeSessionID == row.claudeSessionID, "identity did not survive")
        #expect(after.transcriptPath == row.transcriptPath)
        #expect(after.label == row.label)
        #expect(after.profileID == row.profileID)
        // A row that no longer lives in tmux must not carry a window or pane
        // id: a stale pane coordinate is what let daemon keystrokes reach a
        // different session than the one addressed.
        #expect(after.tmuxWindowID.isEmpty && after.tmuxPaneID.isEmpty,
                "the migrated row still names a tmux pane")
    }

    /// The window the park kept is retired by the rewrite.
    ///
    /// A tmux park respawns the window to a bare login shell and keeps it,
    /// which is what makes a parked tab wakeable in place. Once the row reads
    /// holder-backed nothing names that window, so leaving it would strand one
    /// window and one shell per migrated session until a reconcile pass swept
    /// it.
    @Test("the rewrite retires the tmux window the park kept")
    func theRewriteRetiresTheTmuxWindow() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)
        #expect(fixture.tmuxArgv.count("kill-window") == 0, "the fixture killed a window early")

        #expect(await fixture.productionMigrator().migrate(terminalID: row.id) == .migrated)

        #expect(fixture.tmuxArgv.count("kill-window") == 1,
                "the rewrite left the parked window behind: \(fixture.tmuxArgv.all)")
        #expect(fixture.tmuxArgv.all.contains { $0.contains(row.tmuxWindowID) },
                "a window was killed, but not this row's: \(fixture.tmuxArgv.all)")
    }

    /// A running session's window is retired too — the park kept it, and after
    /// the rewrite it belongs to nobody just the same.
    @Test("a migrated running session's window is retired after the rewrite")
    func aRunningSessionsWindowIsRetiredAfterTheRewrite() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .migrated)

        #expect(fixture.tmuxArgv.count("kill-window") == 1,
                "the migrated session's window was left behind: \(fixture.tmuxArgv.all)")
    }

    /// The retire's own guard, end to end: a coordinate tmux has recycled onto
    /// a stranger's pane costs that stranger nothing. The session still moves —
    /// the window is the only thing the guard protects, and the migration's
    /// whole point is to move the row — but no `kill-window` is issued.
    ///
    /// Both refusal arms and the identity-matched proceed arm are enumerated
    /// against the coordinator in `KillWindowSiblingSitesPaneOwnershipTests`,
    /// with the other six sites that tear a window down by DB-recorded
    /// coordinate. This is the one that proves the migration reaches the guard
    /// at all; the fixture's other retire tests pass through its
    /// no-identity-to-read arm, which is what a dry-run pane answers.
    @Test("a migrated session whose pane now belongs to a stranger keeps that window")
    func aMigratedSessionWhosePaneBelongsToAStrangerKeepsThatWindow() async throws {
        let strangerID = UUID().uuidString
        let fixture = try await Self.makeFixture(
            paneSendTarget: { _, _ in .live(terminalID: strangerID) })
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        #expect(await fixture.productionMigrator().migrate(terminalID: row.id) == .migrated)

        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the migration killed a window that now belongs to another terminal: \(fixture.tmuxArgv.all)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "a refused retire blocked the move itself")
    }

    /// A rewrite that was refused must not take the window with it: the row is
    /// still on tmux, and that window is still the tab a person wakes.
    @Test("a refused rewrite leaves the tmux window alone")
    func aRefusedRewriteLeavesTheWindowAlone() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        #expect(await fixture.recordingMigrator(parkAlsoUnparks: true)
            .migrate(terminalID: row.id) == .skipped(reason: TerminalTransportMigrator.raceSkip))

        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "a refused rewrite killed the row's window: \(fixture.tmuxArgv.all)")
    }

    // MARK: - The exit-stamped pane a person is using

    /// `.exited` parks a row whose pane's SHELL stays alive and usable — that
    /// is the whole point of the stamp — so the pane is the one the person was
    /// sitting in when the agent left, and they may have started something in
    /// it since. Rewriting the row would blank its coordinates and retire the
    /// window, killing that process. Refuse instead, with the same text the
    /// wake refuses its own `respawn-window -k` with.
    @Test("an exit-stamped row whose pane is busy is skipped and keeps its window")
    func anExitStampedRowWhosePaneIsBusyIsSkipped() async throws {
        let fixture = try await Self.makeFixture(
            panePID: "4100", paneForegroundPID: 4242)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true, parkReason: .exited)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(
            reason: HibernationCoordinator.paneBusyRefusal(pid: 4242)))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "a busy exit-stamped row was rewritten anyway")
        #expect(after.tmuxWindowID == row.tmuxWindowID && after.tmuxPaneID == row.tmuxPaneID,
                "the row lost the coordinates of a pane someone is using")
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the migration killed a window someone was working in: \(fixture.tmuxArgv.all)")
    }

    /// The other leg: an exit-stamped row whose pane holds nothing but its own
    /// idle shell migrates like any other parked row.
    @Test("an exit-stamped row whose pane is idle migrates")
    func anExitStampedRowWhosePaneIsIdleMigrates() async throws {
        // `paneForegroundPID` nil leaves the inspector answering with the
        // pane's own pid, which is what an idle interactive shell answers.
        let fixture = try await Self.makeFixture(panePID: "4100")
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true, parkReason: .exited)

        #expect(await fixture.productionMigrator().migrate(terminalID: row.id) == .migrated)

        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.tmuxWindowID.isEmpty && after.tmuxPaneID.isEmpty)
    }

    // MARK: - The running path: park, rewrite, wake

    /// The whole composition, with only the step that needs a live pty
    /// substituted.
    @Test("a running row is parked, rewritten and woken")
    func aRunningRowIsParkedRewrittenAndWoken() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(await fixture.parks == [row.id])
        #expect(await fixture.wakes == [row.id])
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.claudeSessionID == row.claudeSessionID, "identity did not survive")
    }

    /// The wake fails after the rewrite — this fixture cannot start a holder
    /// at all, so the real wake refuses at its spawn. Nothing is unwound: the
    /// row is left parked and recorded as holder-backed, which the ordinary
    /// wake path already handles, so the worst case is a session that comes
    /// back on the holder later rather than now.
    @Test("a wake that cannot start a holder leaves the row parked and recorded on the holder")
    func aFailedWakeLeavesTheRowParkedOnTheHolder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        // Not a refusal: a refusal says the session is where it was, and this
        // one has moved. The report surfaces group the two apart because the
        // remedy differs — this session needs nothing but a wake.
        guard case .movedNotResumed(let reason) = outcome else {
            Issue.record("expected a moved-but-not-resumed outcome, got \(outcome)")
            return
        }
        #expect(reason.contains("starting a holder for this session failed"),
                "the wake failed somewhere other than the spawn: \(reason)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "the refusal unwound the rewrite")
        #expect(after.isParked, "the row was left neither awake nor parked")
    }

    /// Every wake failure after the rewrite is the same outcome, because the
    /// rewrite is what decides it: the row is on the holder whatever the wake
    /// answered. Three shapes of answer, one classification.
    @Test(arguments: [
        WakeResult.notHibernated,
        WakeResult.inFlight,
        WakeResult.respawnFailed(reason: "tmux said no"),
    ])
    func everyWakeFailureAfterTheRewriteIsMovedNotResumed(_ wake: WakeResult) async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(wakeResult: wake)
            .migrate(terminalID: row.id)

        guard case .movedNotResumed = outcome else {
            Issue.record("\(wake) after the rewrite was reported as \(outcome)")
            return
        }
        #expect(try await fixture.db.terminals.get(id: row.id)?.transport == .holder)
    }

    // MARK: - Refusing before the park

    /// The one ordering this composition commits to: a session whose holder
    /// cannot be started is left exactly as it was, running on tmux, with no
    /// parked row behind it.
    @Test("an unspawnable holder refuses and changes nothing")
    func anUnspawnableHolderRefusesAndChangesNothing() async throws {
        let fixture = try await Self.makeFixture(holderSpawnable: false)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(canSpawnHolder: false)
            .migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        #expect(await fixture.parks.isEmpty, "the refusal parked the session first")
        #expect(await fixture.wakes.isEmpty)
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
        #expect(after == row, "the refusal changed the row")
    }

    /// The same refusal for the parked variant, which has no park to skip but
    /// must still not be rewritten onto a transport nothing can wake it on.
    @Test("an unspawnable holder refuses a parked row too")
    func anUnspawnableHolderRefusesAParkedRowToo() async throws {
        let fixture = try await Self.makeFixture(holderSpawnable: false)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "a refused migration rewrote the row anyway")
        #expect(after == row)
    }

    // MARK: - The park's rails

    /// The park honours the rails that read live state, and a rail's refusal
    /// becomes this session's skip reason rather than being overridden. The
    /// transcript-tail rail is the one that reads live state, and it refuses a
    /// transcript caught mid-write.
    ///
    /// This is the opposite of the in-place profile swap's policy, which
    /// bypasses that rail: a swap interrupts the conversation and preserves
    /// it, while a migration that cut a transcript mid-write would leave a
    /// session the wake cannot resume. The policy itself is pinned by
    /// `theMigrationParkRefusesASuspendedRowThatTheSwapPolicyWouldPark`.
    @Test("a transcript mid-write is reported as skipped with the rail's reason")
    func aTranscriptMidWriteIsReportedAsSkipped() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, transcriptTail: #"{"type":"user","mess"#)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: "Transcript is mid-write; try again shortly"))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
        #expect(!after.isParked)
    }

    /// A session TBD already knows to be busy is skipped and named, from the
    /// activity state it already tracks, before anything is parked.
    @Test("a working row is skipped and named, and its row is untouched")
    func aWorkingRowIsSkippedAndNamed() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, activityState: .working)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: "Session is actively running"))
        #expect(await fixture.parks.isEmpty, "a busy session was parked anyway")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after == row)
    }

    // MARK: - The running shell path: stop and restart

    /// A running shell moves plainly: its program is stopped and a fresh login
    /// shell starts on the holder in the same working directory.
    ///
    /// It takes neither of the other two paths, and that is the assertion. A
    /// park exists to carry a conversation across a respawn and this row names
    /// none — which is exactly why `performHibernate` refuses it — so a
    /// composition that parked it would stop a program nothing could bring
    /// back.
    @Test("a running shell is restarted on the holder, with no park and no wake")
    func aRunningShellIsRestartedWithNoParkAndNoWake() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(await fixture.shellMoves == [row.id])
        #expect(await fixture.parks.isEmpty,
                "a session with nothing to resume was parked anyway")
        #expect(await fixture.wakes.isEmpty,
                "a session that was never parked was woken")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.tmuxWindowID.isEmpty && after.tmuxPaneID.isEmpty)
        #expect(after.id == row.id && after.label == row.label && after.kind == row.kind)
    }

    /// A shell tab whose row carries a Claude session id is still a shell: what
    /// it runs is the person's, and the park-and-wake path would bring it back
    /// as a bare `claude --resume`. It moves the way every shell moves. The
    /// branch asks the tab's kind, not whether a session id happens to be on
    /// the row.
    @Test("a running shell carrying a session id moves as a shell, with no park and no wake")
    func aRunningShellCarryingASessionIDMovesAsAShell() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: "by-hand")

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(await fixture.shellMoves == [row.id])
        #expect(await fixture.parks.isEmpty, "a shell tab was parked for a resume")
        #expect(await fixture.wakes.isEmpty, "a shell tab was woken")
    }

    /// The move's lost compare-and-set is reported as the same race skip the
    /// parked path's is: nothing was written, and the row is consistent
    /// whichever way the race went.
    @Test("a shell move that loses its race is reported as the race skip")
    func aShellMoveThatLosesItsRaceIsReportedAsTheRaceSkip() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator(shellMoveOutcome: .lostTheRace)
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.raceSkip))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
    }

    /// A busy pane is reported as a SKIP, not a refusal: it names a state the
    /// person can change, which is the other column of a fleet run's report —
    /// "change this and try again" rather than "can't be moved until this
    /// changes".
    @Test("a shell move's busy pane is reported as a skip, with its reason")
    func aShellMovesBusyPaneIsReportedAsASkip() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator(
            shellMoveOutcome: .busy(reason: "something is running in it"))
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: "something is running in it"))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
    }

    /// A refusal is reported as a refusal, carrying the move's own reason: it
    /// names a fact that has to change before a retry can work, which is a
    /// different column of a fleet run's report than a skip.
    @Test("a shell move's refusal is carried through verbatim")
    func aShellMovesRefusalIsCarriedThroughVerbatim() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator(
            shellMoveOutcome: .refused(reason: "no holder for you"))
            .migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: "no holder for you"))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
    }

    /// The regression guard the new branch most needs: a running Claude
    /// session still goes park, rewrite, wake. The branch tests the row's
    /// `claudeResumeDecision`, which is the decision the park refuses on, so a
    /// session that *can* be resumed must never be restarted as a bare shell.
    @Test("a running Claude session still parks and wakes rather than restarting as a shell")
    func aRunningClaudeSessionStillParksAndWakes() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .migrated)

        #expect(await fixture.shellMoves.isEmpty,
                "a resumable session was restarted as a bare shell")
        #expect(await fixture.parks == [row.id])
        #expect(await fixture.wakes == [row.id])
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.claudeSessionID == row.claudeSessionID, "identity did not survive")
    }

    /// A parked row is still only rewritten, and the shell move is not reached
    /// on its way there. Every park writes the session id it parks, so a
    /// parked row always names one — which is the fact that keeps the two
    /// paths apart.
    @Test("a parked row is rewritten without reaching the shell move")
    func aParkedRowIsRewrittenWithoutReachingTheShellMove() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .migrated)

        #expect(await fixture.shellMoves.isEmpty,
                "a parked row's program was stopped and restarted")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.isParked, "the rewrite woke a parked row")
    }

    /// A Codex tab names no resumable session either, so without its own skip
    /// it would fall into the shell move and be silently replaced by a bare
    /// shell. Moving it properly needs Codex's own launch preparation, which
    /// this path does not have.
    @Test("a Codex tab is skipped with its own reason and nothing is touched")
    func aCodexTabIsSkippedWithItsOwnReason() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .codex, label: TerminalLabel.codex, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TransportMigrationEligibility.codexSkip))
        #expect(await fixture.shellMoves.isEmpty,
                "a Codex session was restarted as a bare shell")
        #expect(await fixture.parks.isEmpty)
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the migration killed a Codex tab's window: \(fixture.tmuxArgv.all)")
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a skipped Codex row was changed")
    }

    /// The production wiring's running-shell arm, end to end: this fixture's
    /// registry reports that it can spawn and then cannot, which is a holder
    /// that could not be started. The program is already stopped by then, so
    /// the refusal has to say what state the session is in — and the row must
    /// keep the coordinates its window-died recovery needs.
    @Test("a running shell whose holder cannot be started is refused with its row intact")
    func aRunningShellWhoseHolderCannotBeStartedIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        guard case .refused(let reason) = outcome else {
            Issue.record("a failed shell move was reported as \(outcome)")
            return
        }
        #expect(reason.contains("starting a holder"),
                "the refusal did not name the failed spawn: \(reason)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "a failed move rewrote the row anyway")
        #expect(after.tmuxWindowID == row.tmuxWindowID && after.tmuxPaneID == row.tmuxPaneID,
                "the row lost the coordinates its recovery needs")
        #expect(!after.isParked, "a session with nothing to resume was left parked")
    }

    // MARK: - Already there, and gone

    @Test("a holder row is left alone entirely")
    func aHolderRowIsLeftAloneEntirely() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.holderRow(fixture)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .alreadyHolder)
        #expect(await fixture.parks.isEmpty)
        #expect(await fixture.wakes.isEmpty)
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after == row)
    }

    /// A shell that is already holder-backed. Worth its own case beside the
    /// Claude one: the shell path is the branch that would otherwise reach it
    /// first, and `.alreadyHolder` has to come before every skip.
    @Test("a holder-backed shell is left alone entirely")
    func aHolderBackedShellIsLeftAloneEntirely() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.holderRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .alreadyHolder)
        #expect(await fixture.shellMoves.isEmpty,
                "a session already on the holder was restarted")
        #expect(await fixture.parks.isEmpty)
        #expect(await fixture.wakes.isEmpty)
        #expect(fixture.tmuxArgv.count("kill-window") == 0,
                "the migration killed a window for a row already on the holder: \(fixture.tmuxArgv.all)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after == row)
    }

    @Test("a terminal the database does not hold is skipped by name")
    func anUnknownTerminalIsSkippedByName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        let outcome = await fixture.recordingMigrator().migrate(terminalID: UUID())

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.notFoundSkip))
        #expect(await fixture.parks.isEmpty)
    }

    // MARK: - The race

    /// A wake that wins the gap between the park and the rewrite. The
    /// compare-and-set rejects the write atomically rather than leaving the
    /// row naming a transport the live process is not on, and the session is
    /// reported as skipped with the row consistent by construction.
    @Test("a wake winning the race is reported as skipped and rewrites nothing")
    func aWakeWinningTheRaceIsReportedAsSkipped() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkAlsoUnparks: true)
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.raceSkip))
        #expect(await fixture.wakes.isEmpty, "the migration woke a row it had not rewritten")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "the rewrite landed on a row that had moved")
    }

    /// A write that failed is `refused`, not `skipped`: nothing about the
    /// person's state has to change for the retry to work, and a skip would
    /// put it in the column of sessions they are expected to act on.
    @Test("a rewrite whose write fails is refused, not skipped")
    func aRewriteWhoseWriteFailsIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        let outcome = await fixture.recordingMigrator(deleteTheRowBeforeTheRewrite: true)
            .migrate(terminalID: row.id)

        guard case .refused(let reason) = outcome else {
            Issue.record("a failed write was reported as \(outcome)")
            return
        }
        #expect(reason.hasPrefix("The move could not be recorded"),
                "the refusal did not name the failed write: \(reason)")
    }

    /// The one skip that follows a park which succeeded, so it is the one skip
    /// that must not read as "nothing happened": the session's program has
    /// already been stopped, and the reason has to say what becomes of it.
    @Test("a row that parked and could not be read back says so, not not-found")
    func aRowThatParkedAndCouldNotBeReadBackSaysSo() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkAlsoDeletesTheRow: true)
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(
            reason: TerminalTransportMigrator.unreadableAfterParkSkip),
                "a session whose agent was just killed was reported as \(outcome)")
    }

    // MARK: - The fleet

    /// A session whose window is gone is reported and does not end the run.
    @Test("a row whose window is gone does not fail the run")
    func aRowWhoseWindowIsGoneDoesNotFailTheRun() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let stale = try await Self.tmuxRow(fixture)
        let parked = try await Self.tmuxRow(fixture, parked: true)

        let report = await fixture.recordingMigrator(parkOverride: [
            stale.id: .notEligible(reason: "Terminal window is no longer live"),
        ]).migrateFleet()

        #expect(report.count == 2)
        #expect(report.first { $0.terminalID == parked.id }?.outcome == .migrated)
        #expect(report.first { $0.terminalID == stale.id }?.outcome
            == .skipped(reason: "Terminal window is no longer live"))
    }

    /// A fleet run's product is its report: every session it considered,
    /// whatever became of it.
    @Test("a fleet run reports every session and keeps going")
    func aFleetRunReportsEverySessionAndKeepsGoing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let parked = try await Self.tmuxRow(fixture, parked: true)
        let working = try await Self.tmuxRow(fixture, activityState: .working)
        let holder = try await Self.holderRow(fixture)

        let report = await fixture.recordingMigrator().migrateFleet()

        #expect(report.count == 3)
        #expect(report.first { $0.terminalID == parked.id }?.outcome == .migrated)
        #expect(report.first { $0.terminalID == working.id }?.outcome
            == .skipped(reason: "Session is actively running"))
        #expect(report.first { $0.terminalID == holder.id }?.outcome == .alreadyHolder)
    }

    /// A failure in the middle of a run migrates the rest and reports the one.
    /// The running row's wake fails after its rewrite, which is the
    /// moved-but-not-resumed outcome rather than a refusal: that row IS on the
    /// holder.
    @Test("a fleet run containing a failure still migrates the rest")
    func aFleetRunContainingAFailureStillMigratesTheRest() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let notResumed = try await Self.tmuxRow(fixture)
        let parked = try await Self.tmuxRow(fixture, parked: true)

        let report = await fixture.recordingMigrator(
            wakeResult: .respawnFailed(reason: "no holder for you")).migrateFleet()

        #expect(report.first { $0.terminalID == notResumed.id }?.outcome
            == .movedNotResumed(reason: "no holder for you"))
        #expect(try await fixture.db.terminals.get(id: notResumed.id)?.transport == .holder,
                "the row the report says moved is not on the holder")
        #expect(report.first { $0.terminalID == parked.id }?.outcome == .migrated)
    }

    // MARK: - The park half, on its own

    /// `parkForTransportMigration` passes the manual policy, so the rail that
    /// reads live state still applies. Asserted on the park directly as well as
    /// through the migrator, because the policy is the decision this method
    /// exists to make.
    @Test("the migration park honours the live rails")
    func theMigrationParkHonoursTheLiveRails() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, transcriptTail: #"{"type":"user","mess"#)

        let result = await fixture.coordinator.parkForTransportMigration(terminalID: row.id)

        #expect(result == .notEligible(reason: "Transcript is mid-write; try again shortly"))
    }

    /// **The A/B that pins the policy.** `hibernationRefusal`'s `.manual` arm
    /// requires `isManuallyHibernatable()`, which refuses a suspended row;
    /// the `.profileSwap` arm checks only `hibernatedAt == nil` and parks it.
    /// So one row, parked through the legacy `suspendedAt` column, gets two
    /// different answers from the two policies — which is what makes
    /// `parkForTransportMigration`'s choice of `.manual` an assertion rather
    /// than a comment. Flipping that call to `.profileSwap` reds this test and
    /// nothing else in the suite.
    @Test("the migration park refuses a suspended row that the swap policy would park")
    func theMigrationParkRefusesASuspendedRowThatTheSwapPolicyWouldPark() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let migrated = try await Self.tmuxRow(fixture, suspended: true)
        let swapped = try await Self.tmuxRow(fixture, suspended: true)

        let migrationResult = await fixture.coordinator
            .parkForTransportMigration(terminalID: migrated.id)
        let swapResult = await fixture.coordinator.parkForProfileSwap(terminalID: swapped.id)

        #expect(migrationResult == .notEligible(reason: "Terminal is suspended"),
                "the migration park did not honour the manual rails")
        #expect(swapResult == .ok,
                "the A/B pins nothing unless the swap policy parks the same row; got \(swapResult)")
    }

    /// `.auto` as the park reason, so a daemon that dies between the park and
    /// the wake leaves a row the next focus-wake heals rather than one that
    /// sits parked until somebody wakes it by hand.
    @Test("the migration park stamps the auto reason so a focus wake can heal it")
    func theMigrationParkStampsTheAutoReason() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        #expect(await fixture.coordinator.parkForTransportMigration(terminalID: row.id) == .ok)

        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.isParked)
        #expect(after.hibernateReason == .auto)
    }

    @Test("the migration park reports a terminal it cannot read as not found")
    func theMigrationParkReportsAnUnknownTerminal() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        #expect(await fixture.coordinator.parkForTransportMigration(
            terminalID: UUID()) == .notFound)
    }
}

/// The fleet run as `handleTerminalMigrateTransport` composes it: the
/// migrator's own list of sessions, moved one at a time. The handler drives the
/// loop itself because it writes an actuation row and publishes the rewritten
/// row at each session's own act moment, so the loop lives here for the tests
/// that only care about the report.
extension TerminalTransportMigrator {
    func migrateFleet() async -> [(terminalID: UUID, outcome: TransportMigrationOutcome)] {
        var report: [(terminalID: UUID, outcome: TransportMigrationOutcome)] = []
        for id in await fleetTerminalIDs() {
            report.append((terminalID: id, outcome: await migrate(terminalID: id)))
        }
        return report
    }
}
