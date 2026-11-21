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
/// TBD no longer drives tmux, so nothing here reaches a tmux server. A parked
/// row is only rewritten; a live row moves only once a socket probe has found
/// its tmux server gone, and is refused while the server may still run.
///
/// Two wirings, because the composition has two different things to prove and
/// a single wiring cannot prove both in the fast pass.
///
/// - **The production wiring** runs the real probe-backed sighting, the real
///   park and the real wake, with the lifecycle's socket probe injected. Its
///   holder registry either cannot start anything or is the spawn double, so
///   "nothing was spawned" is an assertion rather than a hope: the holder wake
///   reserves a replacement incarnation on the row *before* it spawns, so a
///   path that reached the wake leaves a fingerprint even though the spawn
///   then fails.
/// - **The recording wiring** keeps the real park (so the row genuinely parks
///   and the compare-and-set can succeed) and substitutes the sighting, the
///   wake and the shell move, which is what makes every answer each of them
///   can give, the call order, and a fleet run's report reachable here.
@Suite("Moving a session to the pty holder")
struct TerminalTransportMigratorTests {

    static let sessionID = "migrate-me"
    static let server = "tbd-ttm-test"

    // MARK: - Fixture

    /// One call the migrator made, in the order it made them.
    enum Call: Equatable, Sendable {
        case sighting(UUID)
        case park(UUID)
        /// The row's transport as the wake found it, which is how a test sees
        /// that the rewrite landed before the wake.
        case wake(UUID, transport: TerminalTransport?)
        case shellMove(UUID)
    }

    /// Records the calls the migrator made, in order.
    ///
    /// An actor rather than a lock-guarded class because every recorded
    /// operation is reached from an `async` closure, and the ordering the
    /// tests assert on is the actor's own serialization.
    private actor CallRecorder {
        private(set) var calls: [Call] = []
        func record(_ call: Call) { calls.append(call) }
    }

    /// A park the recording wiring answers itself instead of running.
    enum StagedPark: Sendable {
        /// The row changed before the park: `parkLeftover` reports it left
        /// alone.
        case changedFirst
        /// The tab was closed before the park: `parkLeftover` reports it
        /// closed.
        case closedFirst
        /// The park was written, and reading the row back failed.
        case parkedUnreadable
        /// The park's write threw.
        case fails
    }

    private struct StagedParkError: Error, CustomStringConvertible {
        var description: String { "acme park write failed" }
    }

    private struct Fixture {
        let db: TBDDatabase
        let home: String
        let worktree: Worktree
        let coordinator: HibernationCoordinator
        let recorder: CallRecorder
        /// The registry the wake reaches. Its environment is explicit, so no
        /// rendezvous path can reach the developer's real `~/tbd` even for an
        /// instant.
        let holderRegistry: HolderRegistry?

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
        }

        var calls: [Call] { get async { await recorder.calls } }

        /// A lifecycle over this fixture's database whose socket probe is
        /// `probe`, so no socket is asked.
        func lifecycle(probe: RecordingLeftoverTmuxProbe) -> WorktreeLifecycle {
            let lifecycle = WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                leftoverTmuxProbe: probe.probe)
            return lifecycle
        }

        /// The migrator wired as the daemon wires it, with the lifecycle's
        /// socket probe answering from `probe`.
        func productionMigrator(probe: RecordingLeftoverTmuxProbe) -> TerminalTransportMigrator {
            TerminalTransportMigrator(
                db: db,
                operations: .production(
                    hibernation: coordinator, holderRegistry: holderRegistry,
                    lifecycle: lifecycle(probe: probe)))
        }

        /// The migrator wired to the real park (recorded) and a substituted
        /// sighting, wake and shell move (recorded).
        ///
        /// `serverState` answers the sighting for each row; nil is a worktree
        /// that could not be read. `parkOverride` answers the park for the ids
        /// it is given and the real park runs for every other row, which is
        /// how a single fleet run can hold one session whose park lost its
        /// race beside sessions that migrate.
        func recordingMigrator(
            canSpawnHolder: Bool = true,
            serverState: @escaping @Sendable (Terminal) -> LeftoverTmuxServerState? = { _ in .absent },
            parkOverride: [UUID: StagedPark] = [:],
            parkAlsoUnparks: Bool = false,
            parkAlsoDeletesTheRow: Bool = false,
            wakeResult: WakeResult = .ok(sessionIncarnationID: nil),
            shellMoveOutcome: ShellTransportMoveOutcome = .moved
        ) -> TerminalTransportMigrator {
            let database = self.db
            let calls = self.recorder
            let lifecycle = self.lifecycle(probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent }))
            return TerminalTransportMigrator(
                db: database,
                operations: TerminalTransportMigrator.Operations(
                    canSpawnHolder: { canSpawnHolder },
                    tmuxServerSighting: { terminal in
                        await calls.record(.sighting(terminal.id))
                        return serverState(terminal).map {
                            LeftoverTmuxServerSighting(server: TerminalTransportMigratorTests.server, state: $0)
                        }
                    },
                    parkLeftover: { terminal in
                        await calls.record(.park(terminal.id))
                        switch parkOverride[terminal.id] {
                        case .changedFirst: return .leftAlone
                        case .closedFirst: return .closed
                        case .parkedUnreadable:
                            return .parkedUnreadable(error: "acme read failed")
                        case .fails: throw StagedParkError()
                        case nil: break
                        }
                        let outcome = try await lifecycle.parkLeftoverTmuxRow(terminal)
                        let parked: Terminal?
                        if case .parked(let row) = outcome { parked = row } else { parked = nil }
                        if parkAlsoUnparks, parked != nil {
                            // A focus-wake landing in the gap between the park
                            // and the rewrite, which is the race the
                            // compare-and-set exists to lose safely.
                            try? await database.terminals.clearHibernated(id: terminal.id)
                        }
                        if parkAlsoDeletesTheRow, parked != nil {
                            try? await database.terminals.delete(id: terminal.id)
                        }
                        return outcome
                    },
                    wake: { id in
                        let transport = try? await database.terminals.get(id: id)?.transport
                        await calls.record(.wake(id, transport: transport))
                        return wakeResult
                    },
                    // Substituted like the wake, and for the same reason: its
                    // own composition needs a holder a fixture cannot start.
                    // `RunningShellTransportMoveTests` proves it; what is
                    // proved here is which rows reach it and how its answers
                    // are reported.
                    moveRunningShell: { terminal in
                        await calls.record(.shellMove(terminal.id))
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

    /// `holderLaunch` swaps the unspawnable registry for the holder spawn
    /// double, so a wake after the move really launches on the holder and the
    /// test can read what it was asked to run. `holderSpawnable` is ignored
    /// then: the double can always spawn.
    private static func makeFixture(
        holderSpawnable: Bool = true,
        holderLaunch: FakeHolderLaunch? = nil
    ) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdttm")
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)

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
            path: worktreePath, tmuxServer: server)

        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: makeIsolatedConfigDirManager(tag: "transport-migration"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(tag: "transport-migration"),
            leftoverTmuxProbe: .absent)
        let registry: HolderRegistry
        if let holderLaunch {
            registry = makeHolderRegistryDouble(launch: holderLaunch)
        } else {
            registry = HolderRegistry(
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
                listTerminals: { [] },
                spawner: holderSpawnable ? unspawnableSpawner() : nil)
        }
        await coordinator.setHolderRegistry(registry)

        return Fixture(
            db: db, home: home, worktree: worktree,
            coordinator: coordinator,
            recorder: CallRecorder(), holderRegistry: registry)
    }

    /// A tmux-backed Claude row. `parked` is the difference the two migration
    /// paths turn on: a parked row is only rewritten, a live one is judged by
    /// its tmux server first. `parkInFlight` parks it with the park still in
    /// flight (`pendingSessionIncarnationID` set), the way an earlier build's
    /// tmux hibernate left a row whose respawn failed after it had signalled
    /// the agent; such a row is judged by its tmux server first too.
    private static func tmuxRow(
        _ fixture: Fixture,
        parked: Bool = false,
        parkInFlight: Bool = false,
        activityState: TerminalActivityState = .idle,
        kind: TerminalKind? = .claude,
        label: String = TerminalLabel.claudeCode,
        claudeSessionID: String? = sessionID,
        parkReason: HibernateReason = .auto,
        codexLaunchOptions: CodexLaunchOptions? = nil
    ) async throws -> Terminal {
        let transcript = "\(fixture.home)/\(UUID().uuidString).jsonl"
        try #"{"type":"user","message":{"content":"move me"}}"#
            .write(toFile: transcript, atomically: true, encoding: .utf8)
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: label,
            claudeSessionID: claudeSessionID,
            kind: kind,
            transport: .tmux,
            codexLaunchOptions: codexLaunchOptions)
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
        if parkInFlight {
            let live = try #require(try await fixture.db.terminals.get(id: created.id))
            _ = try #require(try await fixture.db.terminals.beginHibernatedShellRespawn(
                id: created.id, expectedState: TerminalHibernationSnapshot(terminal: live),
                reason: parkReason))
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
    /// nothing to park, nothing to respawn, and no tmux server to ask about.
    ///
    /// "Nothing was spawned" is asserted on the row rather than on a counter:
    /// the holder wake reserves a replacement incarnation before it spawns, so
    /// a pending incarnation — or a recorded holder pid — is the fingerprint a
    /// path that reached the wake would leave even though this fixture's spawn
    /// could never succeed.
    @Test("a parked row is rewritten with nothing spawned and no server asked")
    func aParkedRowIsRewrittenWithNothingSpawned() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)
        // Answering "running" for every server: a parked row that consulted
        // the probe would be refused.
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .running })

        let outcome = await fixture.productionMigrator(probe: probe).migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(probe.servers.isEmpty, "a parked row's tmux server was probed: \(probe.servers)")
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

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .migrated)

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
        #expect(await fixture.calls.isEmpty,
                "a parked row reached a step only a live row takes")
    }

    /// An unspawnable holder refuses a parked row too, which has no park to
    /// skip but must still not be rewritten onto a transport nothing can wake
    /// it on.
    @Test("an unspawnable holder refuses a parked row and changes nothing")
    func anUnspawnableHolderRefusesAParkedRow() async throws {
        let fixture = try await Self.makeFixture(holderSpawnable: false)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        let outcome = await fixture.productionMigrator(
            probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent })).migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .tmux, "a refused migration rewrote the row anyway")
        #expect(after == row)
    }

    /// The way back for a Codex tab parked on tmux. Startup reconcile parks a
    /// Codex row whose tmux server is gone, and the wake refuses every row
    /// parked on tmux, so without this the thread could never resume. The move
    /// is only a rewrite, and the next wake resumes the thread on the holder
    /// from the thread id and launch options the rewrite kept.
    @Test("a parked Codex tab moves to the holder, and its next wake resumes the thread there")
    func aParkedCodexTabMovesAndItsNextWakeResumesTheThreadOnTheHolder() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, parked: true, kind: .codex, label: TerminalLabel.codex,
            claudeSessionID: "acme-thread", parkReason: .recovery,
            codexLaunchOptions: CodexLaunchOptions(
                model: "acme-model", disabledFeatures: ["acme-feature"]))

        #expect(await fixture.productionMigrator(
            probe: RecordingLeftoverTmuxProbe(answer: { _ in .running }))
            .migrate(terminalID: row.id) == .migrated)

        let moved = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(moved.transport == .holder)
        #expect(moved.isParked, "the move woke the Codex tab instead of only rewriting it")
        #expect(holder.launches.isEmpty, "the move launched something")
        #expect(moved.claudeSessionID == "acme-thread", "the move lost the thread id")
        #expect(moved.codexLaunchOptions == row.codexLaunchOptions,
                "the move lost the recorded launch options")

        let woken = await fixture.coordinator.wake(terminalID: row.id)

        #expect(woken.isOk, "the moved Codex tab did not wake on the holder: \(woken)")
        let launch = try #require(holder.launch(for: row.id))
        let command = try #require(launch.commandLine)
        #expect(command.contains("resume 'acme-thread'"),
                "the wake did not resume the Codex thread: \(command)")
        #expect(command.contains("model=\"acme-model\""))
        #expect(command.contains("--disable 'acme-feature'"))
        #expect(!command.contains("claude --resume"), "a Codex tab woke as Claude: \(command)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(!after.isParked)
        #expect(after.transport == .holder)
        #expect(after.kind == .codex)
        #expect(after.claudeSessionID == "acme-thread")
        #expect(after.holderPID == launch.handle.holderPID)
    }

    /// The Claude half of the same way back: a Claude tab parked on tmux moves
    /// with nothing launched, and its next wake resumes the conversation on
    /// the holder.
    @Test("a parked Claude tab moves to the holder, and its next wake resumes the session there")
    func aParkedClaudeTabMovesAndItsNextWakeResumesOnTheHolder() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parked: true)

        #expect(await fixture.productionMigrator(
            probe: RecordingLeftoverTmuxProbe(answer: { _ in .running }))
            .migrate(terminalID: row.id) == .migrated)

        let moved = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(moved.transport == .holder)
        #expect(moved.isParked, "the move woke the Claude tab instead of only rewriting it")
        #expect(holder.launches.isEmpty, "the move launched something")

        let woken = await fixture.coordinator.wake(terminalID: row.id)

        #expect(woken.isOk, "the moved Claude tab did not wake on the holder: \(woken)")
        let launch = try #require(holder.launch(for: row.id))
        let command = try #require(launch.commandLine)
        #expect(command.contains("claude --resume \(Self.sessionID)"),
                "the wake did not resume the conversation: \(command)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(!after.isParked)
        #expect(after.transport == .holder)
        #expect(after.claudeSessionID == Self.sessionID)
        #expect(after.holderPID == launch.handle.holderPID)
    }

    /// A row parked with its park still in flight may still be running its
    /// agent, so it is judged as a live row is: its server is probed first,
    /// and while the probe says it may run the move is refused with the
    /// command that ends it and the row is untouched. Rewritten, the row would
    /// leave the resume gate's reach, and its next wake would start the
    /// session on the holder beside the tmux agent.
    @Test("a row whose park is in flight is refused while its server may run")
    func aRowWhoseParkIsInFlightIsRefusedWhileItsServerMayRun() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parkInFlight: true)
        #expect(row.isParked)
        #expect(row.pendingSessionIncarnationID != nil)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .running })

        let outcome = await fixture.productionMigrator(probe: probe).migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: LeftoverTmuxSession.stillRunningRefusal(
            terminalID: row.id, server: Self.server)))
        #expect(probe.servers == [Self.server])
        #expect(holder.launches.isEmpty, "a refused move launched something")
        #expect(try await fixture.db.terminals.get(id: row.id) == row)
    }

    /// Once the probe has found its server gone, a row whose park is in
    /// flight moves as any parked row does: rewritten, with nothing spawned.
    @Test("a row whose park is in flight is rewritten once its server is gone")
    func aRowWhoseParkIsInFlightIsRewrittenOnceItsServerIsGone() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, parkInFlight: true)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })

        let outcome = await fixture.productionMigrator(probe: probe).migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(probe.servers == [Self.server])
        #expect(holder.launches.isEmpty, "the move launched something")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.isParked, "the rewrite woke a parked row")
    }

    // MARK: - A live row whose tmux server may still run

    /// TBD can neither reach nor stop a tmux session, so a live row whose
    /// server may still be running is refused with the command that ends it,
    /// whatever else is true of it: a resumable Claude session, a shell, a
    /// Codex tab with no thread, a session recorded as working — and even a
    /// daemon that could not start a holder, because the probe's answer comes
    /// first. Nothing else is asked and the row is untouched.
    @Test("a live row on a server that may still run is refused with the command that ends it")
    func aLiveRowOnARunningServerIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let rows = [
            try await Self.tmuxRow(fixture),
            try await Self.tmuxRow(fixture, activityState: .working),
            try await Self.tmuxRow(
                fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil),
            try await Self.tmuxRow(
                fixture, kind: .codex, label: TerminalLabel.codex, claudeSessionID: nil),
        ]
        let migrator = fixture.recordingMigrator(
            canSpawnHolder: false, serverState: { _ in .running })

        for row in rows {
            let outcome = await migrator.migrate(terminalID: row.id)

            #expect(outcome == .refused(reason: LeftoverTmuxSession.stillRunningRefusal(
                terminalID: row.id, server: Self.server)), "\(row.kind as Any) row: \(outcome)")
            #expect(try await fixture.db.terminals.get(id: row.id) == row,
                    "a refused \(row.kind as Any) row was changed")
        }
        #expect(await fixture.calls == rows.map { Call.sighting($0.id) },
                "a refused row reached a step past the sighting")
    }

    /// A worktree that cannot be read gives no server to probe, so nothing is
    /// known about the session and nothing is touched.
    @Test("a live row whose worktree cannot be read is refused and untouched")
    func aLiveRowWhoseWorktreeCannotBeReadIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(serverState: { _ in nil })
            .migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: TerminalTransportMigrator.worktreeUnreadableRefusal))
        #expect(await fixture.calls == [.sighting(row.id)])
        #expect(try await fixture.db.terminals.get(id: row.id) == row)
    }

    /// The daemon's own wiring: the sighting reads the server the row's
    /// worktree stores and asks the lifecycle's socket probe about it. A probe
    /// that cannot prove the server gone refuses the move, and the spawn
    /// double proves nothing was launched.
    @Test("the daemon's wiring refuses a live row while the probe says its server may run")
    func theProductionWiringRefusesWhileTheServerMayRun() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .running })

        let outcome = await fixture.productionMigrator(probe: probe).migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: LeftoverTmuxSession.stillRunningRefusal(
            terminalID: row.id, server: Self.server)))
        #expect(probe.servers == [Self.server])
        #expect(holder.launches.isEmpty, "a refused move launched something")
        #expect(try await fixture.db.terminals.get(id: row.id) == row)
    }

    // MARK: - A live session whose tmux server is gone: park, rewrite, wake

    /// The whole composition, with the steps that need a live pty
    /// substituted. The park is the real one, and the wake sees the row
    /// already on the holder, which is the order the contract fixes.
    @Test("a live Claude session whose server is gone is parked, rewritten and woken, in that order")
    func aLiveClaudeSessionIsParkedRewrittenAndWoken() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(await fixture.calls == [
            .sighting(row.id), .park(row.id), .wake(row.id, transport: .holder),
        ])
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.claudeSessionID == row.claudeSessionID, "identity did not survive")
        #expect(after.hibernateReason == .recovery,
                "the park did not record the reason reconcile's park of the same row records")
        #expect(after.tmuxWindowID.isEmpty && after.tmuxPaneID.isEmpty)
    }

    /// The row's recorded activity is not consulted: it describes a session
    /// that ended with its server, so a "working" state is stale and must not
    /// refuse a move that interrupts nothing.
    @Test("a live row recorded as working still moves once its server is gone")
    func aLiveRowRecordedAsWorkingStillMoves() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture, activityState: .working)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .migrated)
        #expect(try await fixture.db.terminals.get(id: row.id)?.transport == .holder)
    }

    /// A live Codex tab that names a thread moves exactly as a Claude session
    /// does once its server is gone: parked with the thread id and launch
    /// options kept, rewritten, and woken on the holder, through the daemon's
    /// own wiring and a real launch on the spawn double.
    @Test("a live Codex tab naming a thread resumes the thread on the holder once its server is gone")
    func aLiveCodexTabNamingAThreadResumesOnTheHolder() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .codex, label: TerminalLabel.codex,
            claudeSessionID: "acme-thread",
            codexLaunchOptions: CodexLaunchOptions(
                model: "acme-model", disabledFeatures: ["acme-feature"]))

        let outcome = await fixture.productionMigrator(
            probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent })).migrate(terminalID: row.id)

        #expect(outcome == .migrated, "\(outcome)")
        let launch = try #require(holder.launch(for: row.id))
        let command = try #require(launch.commandLine)
        #expect(command.contains("resume 'acme-thread'"),
                "the wake did not resume the Codex thread: \(command)")
        #expect(!command.contains("claude --resume"), "a Codex tab woke as Claude: \(command)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after.transport == .holder)
        #expect(after.kind == .codex)
        #expect(after.claudeSessionID == "acme-thread")
        #expect(after.codexLaunchOptions == row.codexLaunchOptions)
    }

    /// The Claude half through the daemon's own wiring: the real sighting,
    /// the real park, the real rewrite and the real wake, launching
    /// `claude --resume` on the spawn double.
    @Test("a live Claude session whose server is gone resumes on the holder through the daemon's wiring")
    func aLiveClaudeSessionResumesThroughTheProductionWiring() async throws {
        let holder = FakeHolderLaunch()
        let fixture = try await Self.makeFixture(holderLaunch: holder)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })

        let outcome = await fixture.productionMigrator(probe: probe).migrate(terminalID: row.id)

        #expect(outcome == .migrated, "\(outcome)")
        #expect(probe.servers == [Self.server])
        let launch = try #require(holder.launch(for: row.id))
        let command = try #require(launch.commandLine)
        #expect(command.contains("claude --resume \(Self.sessionID)"),
                "the wake did not resume the conversation: \(command)")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(!after.isParked)
        #expect(after.transport == .holder)
        #expect(after.holderPID == launch.handle.holderPID)
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

        let outcome = await fixture.productionMigrator(
            probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent })).migrate(terminalID: row.id)

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
        WakeResult.respawnFailed(reason: "no holder for you"),
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
    /// cannot be started is left exactly as it was, with no parked row behind
    /// it.
    @Test("an unspawnable holder refuses before the park and changes nothing")
    func anUnspawnableHolderRefusesBeforeThePark() async throws {
        let fixture = try await Self.makeFixture(holderSpawnable: false)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(canSpawnHolder: false)
            .migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        #expect(await fixture.calls == [.sighting(row.id)], "the refusal parked the session first")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after == row, "the refusal changed the row")
    }

    /// The same refusal for a live shell, before the shell move is reached.
    @Test("an unspawnable holder refuses a live shell before the shell move")
    func anUnspawnableHolderRefusesALiveShell() async throws {
        let fixture = try await Self.makeFixture(holderSpawnable: false)
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator(canSpawnHolder: false)
            .migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: TerminalTransportMigrator.holderUnspawnableRefusal))
        #expect(await fixture.calls == [.sighting(row.id)])
        #expect(try await fixture.db.terminals.get(id: row.id) == row)
    }

    // MARK: - The park and the rewrite race

    /// A row that changed before the park could take it is left as it is, and
    /// reported as the race skip. Nothing is woken.
    @Test("a park that finds the row changed is the race skip, with no wake")
    func aParkThatFindsTheRowChangedIsTheRaceSkip() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkOverride: [row.id: .changedFirst])
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.raceSkip))
        #expect(await fixture.calls == [.sighting(row.id), .park(row.id)])
        #expect(try await fixture.db.terminals.get(id: row.id) == row)
    }

    /// A tab closed before the park could take it is reported as not found,
    /// not as a session that changed. Nothing is woken.
    @Test("a park that finds the tab closed is the not-found skip, with no wake")
    func aParkThatFindsTheTabClosedIsTheNotFoundSkip() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkOverride: [row.id: .closedFirst])
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.notFoundSkip))
        #expect(await fixture.calls == [.sighting(row.id), .park(row.id)])
    }

    /// A park that was written but could not be read back is not a tab that
    /// is gone: the row is there, parked, and the next run moves it as a
    /// parked row. So it is a skip that names the failed read and says to run
    /// the migration again, never the not-found skip. Nothing is woken.
    @Test("a park that cannot be read back is a skip naming the read, not not-found")
    func aParkThatCannotBeReadBackIsNotNotFound() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkOverride: [row.id: .parkedUnreadable])
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(
            reason: TerminalTransportMigrator.parkedUnreadableSkip("acme read failed")))
        #expect(outcome != .skipped(reason: TerminalTransportMigrator.notFoundSkip))
        #expect(await fixture.calls == [.sighting(row.id), .park(row.id)])
    }

    /// A park whose write failed is a refusal carrying the failure, not a
    /// skip: nothing about the person's state has to change.
    @Test("a park whose write fails is refused with its failure")
    func aParkWhoseWriteFailsIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkOverride: [row.id: .fails])
            .migrate(terminalID: row.id)

        #expect(outcome == .refused(reason: "The park could not be recorded (acme park write failed)."))
        #expect(await fixture.calls == [.sighting(row.id), .park(row.id)])
    }

    /// A wake that wins the gap between the park and the rewrite. The
    /// compare-and-set rejects the write atomically rather than leaving the
    /// row naming a transport the session is not on, and the session is
    /// reported as skipped with the row consistent by construction.
    @Test("a wake winning the race after the park is reported as skipped and rewrites nothing")
    func aWakeWinningTheRaceIsReportedAsSkipped() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkAlsoUnparks: true)
            .migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.raceSkip))
        #expect(await fixture.calls == [.sighting(row.id), .park(row.id)],
                "the migration woke a row it had not rewritten")
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
        let row = try await Self.tmuxRow(fixture)

        let outcome = await fixture.recordingMigrator(parkAlsoDeletesTheRow: true)
            .migrate(terminalID: row.id)

        guard case .refused(let reason) = outcome else {
            Issue.record("a failed write was reported as \(outcome)")
            return
        }
        #expect(reason.hasPrefix("The move could not be recorded"),
                "the refusal did not name the failed write: \(reason)")
        #expect(await fixture.calls == [.sighting(row.id), .park(row.id)])
    }

    // MARK: - A live shell whose tmux server is gone

    /// A live shell moves plainly: a fresh login shell starts on the holder in
    /// the same working directory.
    ///
    /// It takes neither the park nor the wake, and that is the assertion. A
    /// park exists to carry a conversation across a respawn and this row
    /// names none.
    @Test("a live shell is started again on the holder, with no park and no wake")
    func aLiveShellIsStartedAgainWithNoParkAndNoWake() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(await fixture.calls == [.sighting(row.id), .shellMove(row.id)])
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
    @Test("a live shell carrying a session id moves as a shell, with no park and no wake")
    func aLiveShellCarryingASessionIDMovesAsAShell() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: "by-hand")

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .migrated)
        #expect(await fixture.calls == [.sighting(row.id), .shellMove(row.id)])
    }

    /// The move's lost compare-and-set is reported as the same race skip the
    /// park's is: nothing was written, and the row is consistent whichever way
    /// the race went.
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

    /// The daemon's wiring of the shell arm, end to end: this fixture's
    /// registry reports that it can spawn and then cannot, which is a holder
    /// that could not be started. The row must keep the coordinates a later
    /// move reads.
    @Test("a live shell whose holder cannot be started is refused with its row intact")
    func aLiveShellWhoseHolderCannotBeStartedIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)

        let outcome = await fixture.productionMigrator(
            probe: RecordingLeftoverTmuxProbe(answer: { _ in .absent })).migrate(terminalID: row.id)

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

    /// A live Codex tab with no thread names nothing to resume, and the shell
    /// move would replace it with a bare login shell in a tab still reading
    /// Codex, so it is skipped with its own reason and nothing is touched.
    @Test("a live Codex tab naming no thread is skipped with its own reason")
    func aLiveCodexTabNamingNoThreadIsSkipped() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.tmuxRow(
            fixture, kind: .codex, label: TerminalLabel.codex, claudeSessionID: nil)

        let outcome = await fixture.recordingMigrator().migrate(terminalID: row.id)

        #expect(outcome == .skipped(reason: TransportMigrationEligibility.codexSkip))
        #expect(await fixture.calls == [.sighting(row.id)],
                "a Codex session reached a park or a shell move")
        #expect(try await fixture.db.terminals.get(id: row.id) == row,
                "a skipped Codex row was changed")
    }

    // MARK: - Already there, and gone

    @Test("a holder row is left alone entirely")
    func aHolderRowIsLeftAloneEntirely() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let row = try await Self.holderRow(fixture)

        #expect(await fixture.recordingMigrator().migrate(terminalID: row.id) == .alreadyHolder)
        #expect(await fixture.calls.isEmpty)
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
        #expect(await fixture.calls.isEmpty,
                "a session already on the holder was probed, parked or restarted")
        let after = try #require(try await fixture.db.terminals.get(id: row.id))
        #expect(after == row)
    }

    @Test("a terminal the database does not hold is skipped by name")
    func anUnknownTerminalIsSkippedByName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        let outcome = await fixture.recordingMigrator().migrate(terminalID: UUID())

        #expect(outcome == .skipped(reason: TerminalTransportMigrator.notFoundSkip))
        #expect(await fixture.calls.isEmpty)
    }

    // MARK: - The fleet

    /// A fleet run's product is its report: every session it considered,
    /// whatever became of it — a refusal in the middle does not end the run.
    @Test("a fleet run reports every session and keeps going")
    func aFleetRunReportsEverySessionAndKeepsGoing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let parked = try await Self.tmuxRow(fixture, parked: true)
        let stillRunning = try await Self.tmuxRow(fixture)
        let lostTheRace = try await Self.tmuxRow(fixture)
        let shell = try await Self.tmuxRow(
            fixture, kind: .shell, label: TerminalLabel.shell, claudeSessionID: nil)
        let holder = try await Self.holderRow(fixture)
        let runningID = stillRunning.id

        let report = await fixture.recordingMigrator(
            serverState: { $0.id == runningID ? .running : .absent },
            parkOverride: [lostTheRace.id: .changedFirst]).migrateFleet()

        #expect(report.count == 5)
        #expect(report.first { $0.terminalID == parked.id }?.outcome == .migrated)
        #expect(report.first { $0.terminalID == stillRunning.id }?.outcome
            == .refused(reason: LeftoverTmuxSession.stillRunningRefusal(
                terminalID: stillRunning.id, server: Self.server)))
        #expect(report.first { $0.terminalID == lostTheRace.id }?.outcome
            == .skipped(reason: TerminalTransportMigrator.raceSkip))
        #expect(report.first { $0.terminalID == shell.id }?.outcome == .migrated)
        #expect(report.first { $0.terminalID == holder.id }?.outcome == .alreadyHolder)
    }

    /// A failure in the middle of a run migrates the rest and reports the one.
    /// The live row's wake fails after its rewrite, which is the
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
