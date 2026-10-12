import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
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

    /// A pane whose prompt holds text the person typed and has not sent — the
    /// fact the park's typed-input rail refuses on, and exactly what a
    /// park-and-respawn would throw away.
    static let paneWithTypedInput = """
        ╭──────────────────────────────╮
        │ > half-composed prompt       │
        ╰──────────────────────────────╯
        """

    // MARK: - Fixture

    /// Records the ids the migrator asked each operation about, in order.
    ///
    /// An actor rather than a lock-guarded class because every recorded
    /// operation is reached from an `async` closure, and the ordering the
    /// tests assert on is the actor's own serialization.
    private actor CallRecorder {
        private(set) var parks: [UUID] = []
        private(set) var wakes: [UUID] = []

        func recordPark(_ id: UUID) { parks.append(id) }
        func recordWake(_ id: UUID) { wakes.append(id) }
    }

    private struct Fixture {
        let db: TBDDatabase
        let home: String
        let worktree: Worktree
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
            parkAlsoUnparks: Bool = false
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
                        return result
                    },
                    wake: { id in
                        await calls.recordWake(id)
                        return wakeResult
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

    private static func makeFixture(
        holderSpawnable: Bool = true,
        capturePane: @escaping @Sendable (String, String) -> String = { _, _ in "" }
    ) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdttm")
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(
            dryRun: true, dryRunCapturePane: capturePane)

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
            actuationLog: makeTestActuationLog(tag: "transport-migration"))
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
            listTerminals: { [] },
            spawner: holderSpawnable ? unspawnableSpawner() : nil)
        await coordinator.setHolderRegistry(registry)

        return Fixture(
            db: db, home: home, worktree: worktree, coordinator: coordinator,
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
        claudeSessionID: String? = sessionID,
        transcriptTail: String = #"{"type":"user","message":{"content":"move me"}}"#
    ) async throws -> Terminal {
        let transcript = "\(fixture.home)/\(UUID().uuidString).jsonl"
        try transcriptTail.write(toFile: transcript, atomically: true, encoding: .utf8)
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: TerminalLabel.claudeCode,
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
                id: created.id, sessionID: claudeSessionID, reason: .auto)
        }
        return try #require(try await fixture.db.terminals.get(id: created.id))
    }

    private static func holderRow(_ fixture: Fixture) async throws -> Terminal {
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode,
            claudeSessionID: sessionID,
            kind: .claude,
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

        guard case .refused(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("starting a holder for this session failed"),
                "the wake failed somewhere other than the spawn: \(reason)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "the refusal unwound the rewrite")
        #expect(after.isParked, "the row was left neither awake nor parked")
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
    /// becomes this session's skip reason rather than being overridden.
    ///
    /// This is the opposite of the in-place profile swap's policy, and the
    /// difference is in what the two actions destroy: a swap preserves the
    /// conversation and interrupts it, while a migration would discard input
    /// the person typed and has not sent.
    @Test("a rail refusing the park is reported as skipped, with the rail's reason")
    func aRailRefusingTheParkIsReportedAsSkipped() async throws {
        let fixture = try await Self.makeFixture(
            capturePane: { _, _ in Self.paneWithTypedInput })
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.productionMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: "Terminal has unsent typed input"))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "a refused park still rewrote the row")
        #expect(!after.isParked, "a refused park left the row parked")
    }

    /// The transcript-tail rail, which is the one `honoursLiveRails` gates —
    /// so a migration under the swap's policy would not have asked.
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

    /// A running shell is skipped by the park, with the park's own reason.
    ///
    /// `TransportMigrationEligibility` deliberately does not require a
    /// resumable session — so shells reach the park rather than being refused
    /// up front — and the park then refuses a row with no conversation to
    /// resume. The outcome is a named skip, which is the point: the migration
    /// never kills a program it cannot bring back.
    @Test("a running shell is skipped because nothing could resume it")
    func aRunningShellIsSkippedBecauseNothingCouldResumeIt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, kind: .shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: "No session id to resume later"))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux)
        #expect(!after.isParked)
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
        ]).migrateAll()

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

        let report = await fixture.recordingMigrator().migrateAll()

        #expect(report.count == 3)
        #expect(report.first { $0.terminalID == parked.id }?.outcome == .migrated)
        #expect(report.first { $0.terminalID == working.id }?.outcome
            == .skipped(reason: "Session is actively running"))
        #expect(report.first { $0.terminalID == holder.id }?.outcome == .alreadyHolder)
    }

    /// A refusal in the middle of a run migrates the rest and reports the one.
    @Test("a fleet run containing a refusal still migrates the rest")
    func aFleetRunContainingARefusalStillMigratesTheRest() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let refused = try await Self.tmuxRow(fixture)
        let parked = try await Self.tmuxRow(fixture, parked: true)

        let report = await fixture.recordingMigrator(
            wakeResult: .respawnFailed(reason: "no holder for you")).migrateAll()

        #expect(report.first { $0.terminalID == refused.id }?.outcome
            == .refused(reason: "no holder for you"))
        #expect(report.first { $0.terminalID == parked.id }?.outcome == .migrated)
    }

    // MARK: - The park half, on its own

    /// `parkForTransportMigration` passes the manual policy, so the rails that
    /// read live state still apply. Asserted on the park directly as well as
    /// through the migrator, because the policy is the decision this method
    /// exists to make.
    @Test("the migration park honours the live rails")
    func theMigrationParkHonoursTheLiveRails() async throws {
        let fixture = try await Self.makeFixture(
            capturePane: { _, _ in Self.paneWithTypedInput })
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let result = await fixture.coordinator.parkForTransportMigration(terminalID: row.id)

        #expect(result == .notEligible(reason: "Terminal has unsent typed input"))
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
