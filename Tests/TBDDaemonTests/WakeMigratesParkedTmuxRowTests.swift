import Foundation
import Testing
import GRDB
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A person's wake of a session parked on the tmux transport moves it to the
/// pty holder and wakes it there, in one step; a rail's wake moves nothing.
///
/// Driven through the router, with the holder spawn double behind the
/// coordinator, so what these prove is the composition: who moves a row, what
/// the wake answers when the move cannot happen, and that the wake which
/// follows a move resumes the same session on the holder. The move itself is
/// `TerminalTransportMigrator.migrate`, proved in
/// `TerminalTransportMigratorTests`; the coordinator's own refusal of a row
/// still on tmux, in `TmuxWakeBackstopTests`.
@Suite("Wake migrates a parked tmux row")
struct WakeMigratesParkedTmuxRowTests {
    private static let sessionID = "sess-wake-migrates"
    private static let server = "tbd-wake-migrates-test"

    /// Collects every delta the router publishes.
    private final class DeltaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StateDelta] = []
        func append(_ d: StateDelta) { lock.withLock { items.append(d) } }
        var all: [StateDelta] { lock.withLock { items } }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let deltas: DeltaBox
        let actuationLogPath: String
        let scratch: String

        func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

        /// Every row `terminalID` was published whole as, in order.
        func replaced(_ terminalID: UUID) -> [Terminal] {
            deltas.all.compactMap {
                if case .terminalReplaced(let t) = $0, t.id == terminalID { return t }
                return nil
            }
        }

        /// The outcome rows the actuation record holds, as JSON objects.
        func actuationOutcomes() throws -> [[String: Any]] {
            guard let contents = try? String(
                contentsOfFile: actuationLogPath, encoding: .utf8) else { return [] }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(try JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any])
                }
                .filter { $0["kind"] as? String == "outcome" }
        }
    }

    /// A router whose coordinator wakes holder rows through the spawn double,
    /// on a worktree whose tmux server `probe` answers for.
    private static func makeFixture(
        probe: LeftoverTmuxServerProbe = .absent
    ) async throws -> Fixture {
        let scratch = fencedScratchRoot(prefix: "tbdwakemig")
        let wtPath = "\(scratch)/wt"
        let logDirectory = "\(scratch)/log"
        for dir in [wtPath, "\(scratch)/repo", logDirectory] {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: wtPath, tmuxServer: Self.server)

        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            leftoverTmuxProbe: probe)
        lifecycle.holderRegistry = registry

        let deltas = DeltaBox()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let actuationLogPath = "\(logDirectory)/actuations.jsonl"
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, subscriptions: subscriptions,
            configDirManager: makeIsolatedConfigDirManager(tag: "wake-migrates"),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            actuationLog: ActuationLog(path: actuationLogPath))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        return Fixture(
            db: db, router: router, worktree: worktree, holder: holder, deltas: deltas,
            actuationLogPath: actuationLogPath, scratch: scratch)
    }

    /// A row parked on tmux with its park complete: what startup reconcile
    /// leaves once a session's tmux server is gone.
    private static func parkedTmuxRow(
        _ f: Fixture, kind: TerminalKind = .claude, session: String = sessionID
    ) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            label: kind == .codex ? TerminalLabel.codex : TerminalLabel.claudeCode,
            claudeSessionID: session, kind: kind, transport: .tmux)
        try await f.db.terminals.setHibernated(
            id: created.id, sessionID: session, reason: .recovery)
        let row = try #require(try await f.db.terminals.get(id: created.id))
        #expect(row.isParked && row.transport == .tmux, "the fixture is not a parked tmux row")
        return row
    }

    /// A row parked on tmux with its park still in flight
    /// (`pendingSessionIncarnationID` set): an earlier build's tmux hibernate
    /// left it so when its respawn failed after it had signalled the agent, so
    /// its session may still be running in tmux.
    private static func parkInFlightTmuxRow(_ f: Fixture) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID,
            kind: .claude, transport: .tmux)
        let live = try #require(try await f.db.terminals.get(id: created.id))
        _ = try #require(try await f.db.terminals.beginHibernatedShellRespawn(
            id: created.id, expectedState: TerminalHibernationSnapshot(terminal: live),
            reason: .auto))
        let row = try #require(try await f.db.terminals.get(id: created.id))
        #expect(row.isParked && row.pendingSessionIncarnationID != nil,
                "the fixture is not a row whose park is in flight")
        return row
    }

    /// The three requests that wake a parked row.
    enum Entry: CaseIterable, Sendable {
        case terminalWake
        case terminalResume
        case worktreeResume

        func request(_ row: Terminal, actor: ActuationActor?) throws -> RPCRequest {
            switch self {
            case .terminalWake:
                return try RPCRequest(
                    method: RPCMethod.terminalWake,
                    params: TerminalWakeParams(terminalID: row.id), actor: actor)
            case .terminalResume:
                return try RPCRequest(
                    method: RPCMethod.terminalResume,
                    params: TerminalResumeParams(terminalID: row.id), actor: actor)
            case .worktreeResume:
                return try RPCRequest(
                    method: RPCMethod.worktreeResume,
                    params: WorktreeResumeParams(worktreeID: row.worktreeID), actor: actor)
            }
        }
    }

    /// The row moved and woke on the holder as the same session: the same
    /// row, conversation and label, spawned through the holder seam, with the
    /// move published whole so a mounted pane stops reading tmux.
    private static func expectMovedAndResumed(
        _ row: Terminal, _ f: Fixture, command expected: String
    ) async throws {
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "the wake did not move the row")
        #expect(!after.isParked, "the moved row was not woken")
        #expect(after.claudeSessionID == row.claudeSessionID)
        #expect(after.label == row.label)
        #expect(after.kind == row.kind)
        #expect(f.holder.launches.count == 1)
        let launch = try #require(f.holder.launch(for: row.id), "nothing was spawned through the holder")
        #expect(after.holderPID == launch.handle.holderPID)
        let command = try #require(launch.commandLine)
        #expect(command.contains(expected), "the wake did not resume the session: \(command)")
        let replaced = f.replaced(row.id)
        #expect(replaced.first?.transport == .holder, "the move was not published: \(replaced)")
    }

    // MARK: - Who moves a row

    /// Every actor that is not the daemon is a person's request, a kind a
    /// newer client declares and no declared actor included; every daemon
    /// actor is a rail, whatever its rail name.
    @Test("only a daemon actor's wake leaves a parked tmux row where it is")
    func everyKindButDaemonIsPersonStarted() throws {
        let session = try #require(ActuationActor.session(
            worktree: UUID().uuidString, terminal: UUID().uuidString))
        let people: [ActuationActor?] = [
            nil, .app, .phone(deviceID: UUID()), session, .anonymous,
            ActuationActor(kind: "declared-by-a-newer-client"),
        ]
        for actor in people {
            #expect(TransportMigrationOnWake.isPersonStarted(actor),
                    "\(actor?.kind ?? "no actor") does not move a parked tmux row")
        }
        let rails: [String?] = [
            nil, ActuationRail.sessionRestore, ActuationRail.limitResume,
            ActuationRail.queuedPrompt, ActuationRail.reconcile, ActuationRail.autoHibernate,
        ]
        for rail in rails {
            #expect(!TransportMigrationOnWake.isPersonStarted(.daemon(rail: rail)),
                    "the \(rail ?? "unnamed") rail moves a parked tmux row")
        }
    }

    // MARK: - A person's wake

    /// The app's wake, by each request that wakes a parked row, moves it to
    /// the holder and resumes the same conversation there.
    @Test("a person's wake moves a parked tmux row to the holder and resumes it there",
          arguments: Entry.allCases)
    func aPersonsWakeMovesTheRowAndResumesIt(_ entry: Entry) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)

        let response = await f.router.handle(try entry.request(row, actor: .app))

        #expect(response.success, "the wake failed: \(response.error ?? "")")
        try await Self.expectMovedAndResumed(
            row, f, command: "claude --resume \(Self.sessionID)")
    }

    /// The phone's wake is a person's too.
    @Test("the phone's wake moves a parked tmux row to the holder and resumes it there")
    func thePhonesWakeMovesTheRow() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)

        let response = try await f.router.phoneWake(
            TerminalWakeParams(terminalID: row.id), deviceID: UUID())

        #expect(response.success, "the phone's wake failed: \(response.error ?? "")")
        try await Self.expectMovedAndResumed(
            row, f, command: "claude --resume \(Self.sessionID)")
    }

    /// A Codex tab with a recorded thread moves the same way, and its wake
    /// resumes the thread, not a Claude session.
    @Test("a person's wake moves a parked Codex tab and resumes its thread on the holder")
    func aParkedCodexTabIsMovedAndResumed() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f, kind: .codex, session: "acme-thread")
        #expect(row.recoveryResumePlan?.identity.agentKind == .codex)

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        #expect(response.success, "the wake failed: \(response.error ?? "")")
        try await Self.expectMovedAndResumed(row, f, command: "resume 'acme-thread'")
        let command = try #require(f.holder.launch(for: row.id)?.commandLine)
        #expect(!command.contains("claude --resume"), "a Codex tab woke as Claude: \(command)")
    }

    // MARK: - A rail's wake

    /// A rail's wake moves nothing, by any request: the row stays parked on
    /// tmux, exactly as it was, and the wake answers with the coordinator's
    /// refusal that names the move. Session restore is the rail start
    /// admission checks, and limit resume one it does not.
    @Test("a rail's wake leaves a parked tmux row where it is",
          arguments: [ActuationRail.sessionRestore, ActuationRail.limitResume], Entry.allCases)
    func aRailsWakeMovesNothing(rail: String, entry: Entry) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)

        let response = await f.router.handle(try entry.request(row, actor: .daemon(rail: rail)))

        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: row.id))
        #expect(try await f.db.terminals.get(id: row.id) == row, "a rail's wake changed the row")
        #expect(f.holder.launches.isEmpty, "a rail's wake started a holder")
        #expect(f.replaced(row.id).isEmpty, "a rail's wake published a move")
    }

    // MARK: - A move that cannot happen

    /// A row whose park is still in flight may still be running its agent in
    /// tmux, so while its server may run the move is refused, as
    /// `terminal.migrateTransport` refuses it, and the wake with it: nothing is
    /// rewritten and nothing is spawned.
    @Test("a person's wake of a row whose park is in flight is refused while its server may run")
    func aParkInFlightRowIsRefusedWhileItsServerMayRun() async throws {
        let f = try await Self.makeFixture(probe: LeftoverTmuxServerProbe { _ in .running })
        defer { f.tearDown() }
        let row = try await Self.parkInFlightTmuxRow(f)

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: row.id, server: Self.server))
        #expect(try await f.db.terminals.get(id: row.id) == row, "a refused move rewrote the row")
        #expect(f.holder.launches.isEmpty, "a refused move started a holder")
        #expect(f.replaced(row.id).isEmpty, "a refused move published a move")
        let outcome = try #require(try f.actuationOutcomes().last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
    }

    /// A row the move turns away for having nothing to resume is refused with
    /// that reason, which says what to do instead, and stays on tmux.
    @Test("a person's wake of a parked tmux row with nothing to resume is refused with the reason")
    func aRowWithNothingToResumeIsRefusedWithItsReason() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let parked = try await Self.parkedTmuxRow(f)
        let rowID = parked.id
        try await f.db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE terminal SET claudeSessionID = NULL WHERE id = ?",
                arguments: [rowID.uuidString])
        }
        let row = try #require(try await f.db.terminals.get(id: rowID))
        let skip = try #require(TransportMigrationEligibility.nothingToResumeSkip(row),
                                "the fixture is not a row with nothing to resume")

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == skip)
        #expect(try await f.db.terminals.get(id: row.id) == row, "a refused move rewrote the row")
        #expect(f.holder.launches.isEmpty, "a refused move started a holder")
    }

    /// Operations whose server sighting first runs `race`, a write by another
    /// writer between the move's read of the row and its compare-and-set, and
    /// then reads the server as gone. Only a row whose park is in flight is
    /// sighted, so only such a row meets the race. Nothing else the move could
    /// do is expected of a parked row.
    private static func racingOperations(
        race: @escaping @Sendable (UUID) async throws -> Void
    ) -> TerminalTransportMigrator.Operations {
        TerminalTransportMigrator.Operations(
            canSpawnHolder: { true },
            tmuxServerSighting: { terminal in
                do {
                    try await race(terminal.id)
                } catch {
                    Issue.record("the other writer's write failed: \(error)")
                }
                return LeftoverTmuxServerSighting(server: Self.server, state: .absent)
            },
            parkLeftover: { _ in
                Issue.record("the move of a parked row parked it again")
                return .leftAlone
            },
            wake: { _ in
                Issue.record("the move woke the row itself; the wake that follows it does")
                return .notFound
            },
            moveRunningShell: { _ in
                Issue.record("the move of a parked row moved a running shell")
                return .refused(reason: "not expected")
            })
    }

    /// The move loses its compare-and-set to another writer. When that writer
    /// left the row on tmux, the wake is refused with a reason that says the
    /// row changed, and the row is as the other writer left it. When it moved
    /// the row to the holder first — a concurrent wake, or a migration — the
    /// wake has nothing left to move and wakes the row there.
    @Test("a move that loses its compare-and-set refuses, unless the row is already on the holder",
          arguments: [false, true])
    func aMoveThatLosesTheRace(endsOnTheHolder: Bool) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkInFlightTmuxRow(f)
        let db = f.db
        f.router.transportMigratorOperationsOverride = Self.racingOperations { terminalID in
            try await db.writerForTests.write { conn in
                if endsOnTheHolder {
                    try conn.execute(
                        sql: """
                            UPDATE terminal SET transport = 'holder', tmuxWindowID = '',
                                tmuxPaneID = '', pendingSessionIncarnationID = NULL
                            WHERE id = ?
                            """,
                        arguments: [terminalID.uuidString])
                } else {
                    try conn.execute(
                        sql: "UPDATE terminal SET claudeSessionID = ? WHERE id = ?",
                        arguments: ["sess-other-writer", terminalID.uuidString])
                }
            }
        }

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        let after = try #require(try await f.db.terminals.get(id: row.id))
        if endsOnTheHolder {
            #expect(response.success, "the wake of a row moved by another writer failed: \(response.error ?? "")")
            #expect(after.transport == .holder)
            #expect(!after.isParked, "the row another writer moved was not woken")
            let launch = try #require(f.holder.launch(for: row.id))
            #expect(launch.commandLine?.contains("claude --resume \(Self.sessionID)") == true,
                    "the wake did not resume the session: \(launch.commandLine ?? "nil")")
        } else {
            #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
            #expect(response.error == TransportMigrationOnWake.raceRefusal)
            #expect(after.transport == .tmux)
            #expect(after.isParked)
            #expect(after.tmuxWindowID == "@4")
            #expect(after.claudeSessionID == "sess-other-writer",
                    "the row is not as the other writer left it")
            #expect(f.holder.launches.isEmpty, "a refused move started a holder")
            #expect(f.replaced(row.id).isEmpty, "a refused move published a move")
            let outcome = try #require(try f.actuationOutcomes().last)
            #expect(outcome["result"] as? String == "refused")
        }
    }
}
