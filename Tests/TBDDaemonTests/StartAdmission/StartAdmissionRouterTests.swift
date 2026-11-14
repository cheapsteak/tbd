import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Answers every start-admission question with a fixed verdict and records what
/// it was asked, so router tests stub the command without writing a script.
final class StubAdmission: StartAdmissionEvaluating, @unchecked Sendable {
    private let lock = NSLock()
    private var verdict: StartAdmissionVerdict
    private var asked: [StartAdmissionRequest] = []

    init(_ verdict: StartAdmissionVerdict) { self.verdict = verdict }

    func setVerdict(_ new: StartAdmissionVerdict) { lock.withLock { verdict = new } }
    var requests: [StartAdmissionRequest] { lock.withLock { asked } }

    func evaluate(_ request: StartAdmissionRequest) async -> StartAdmissionVerdict {
        lock.withLock {
            asked.append(request)
            return verdict
        }
    }
}

/// Hold paths through the real router, with dry-run tmux, a real temp-directory
/// actuation log and a stubbed verdict. The runner itself is covered by
/// `StartAdmissionGateTests`.
@Suite("StartAdmissionRouter")
struct StartAdmissionRouterTests {

    private static let holdReason = "camera in use"

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let logPath: String
        let stub: StubAdmission
    }

    private func makeFixture(
        flag: Bool? = true, verdict: StartAdmissionVerdict = .hold(reason: holdReason)
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-start-admission-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        // Spawns go through the holder spawn double, so an admitted
        // `terminal.create` opens a session without starting a process.
        let registry = makeHolderRegistryDouble(launch: FakeHolderLaunch())
        var lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        lifecycle.holderRegistry = registry
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux, startTime: Date(), actuationLog: ActuationLog(path: path))
        router.holderRegistry = registry
        let stub = StubAdmission(verdict)
        router.startAdmission = stub
        if let flag { try await db.config.setStartAdmissionEnabled(flag) }
        return Fixture(router: router, db: db, logPath: path, stub: stub)
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func makeWorktree(in db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
    }

    /// A session parked on the pty holder: the only kind of row a wake can
    /// start, and so the only kind a wake asks admission about.
    private func makeParkedClaude(
        in db: TBDDatabase, worktree: Worktree, kind: TerminalKind = .claude,
        transport: TerminalTransport = .holder
    ) async throws -> Terminal {
        let onHolder = transport == .holder
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: onHolder ? "" : "@1", tmuxPaneID: onHolder ? "" : "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "session-1", kind: kind,
            transport: transport)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "session-1")
        return terminal
    }

    // MARK: - Actor table

    private static let actorKinds = [
        ActuationActor.Kind.app, ActuationActor.Kind.daemon, ActuationActor.Kind.phone,
        ActuationActor.Kind.session, ActuationActor.Kind.anonymous, "declared-by-a-newer-client",
    ]

    private static let uncheckedKinds: Set<String> = [
        ActuationActor.Kind.app, ActuationActor.Kind.daemon, ActuationActor.Kind.phone,
    ]

    @Test("each actor kind against create and wake, flag on", arguments: actorKinds)
    func actorTableWithTheFlagOn(kind: String) async throws {
        let fixture = try await makeFixture(verdict: .admit)
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree)
        let actor = ActuationActor(kind: kind)
        let checked = !Self.uncheckedKinds.contains(kind)

        fixture.stub.setVerdict(.hold(reason: Self.holdReason))
        let create = await fixture.router.holdStartIfDenied(
            "id", actor: actor, agent: .claude, worktreeID: worktree.id)
        let wake = await fixture.router.holdWakeIfDenied(
            "id", actor: actor, terminalID: terminal.id)

        #expect((create != nil) == checked)
        #expect((wake != nil) == checked)
        #expect(fixture.stub.requests.count == (checked ? 2 : 0))
        if checked {
            #expect(fixture.stub.requests.map(\.kind) == [.create, .wake])
            #expect(fixture.stub.requests.allSatisfy { $0.actorKind == kind })
        }
    }

    @Test("the restore rail's wake is checked, and another daemon rail's is not")
    func daemonRailsAgainstAWake() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree)

        let otherRail = await fixture.router.holdWakeIfDenied(
            "id", actor: .daemon(rail: ActuationRail.limitResume), terminalID: terminal.id)
        #expect(otherRail == nil)
        #expect(fixture.stub.requests.isEmpty)

        let restoreRail = await fixture.router.holdWakeIfDenied(
            "id", actor: .daemon(rail: ActuationRail.sessionRestore), terminalID: terminal.id)
        #expect(restoreRail?.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.map(\.kind) == [.wake])
        #expect(fixture.stub.requests.first?.actorKind == ActuationActor.Kind.daemon)
    }

    @Test("a start with no declared actor is checked as anonymous")
    func undeclaredActorIsAnonymous() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let held = await fixture.router.holdStartIfDenied(
            "id", actor: nil, agent: .codex, worktreeID: worktree.id)
        #expect(held?.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.first?.actorKind == ActuationActor.Kind.anonymous)
        #expect(fixture.stub.requests.first?.agent == .codex)
    }

    @Test("flag off or never chosen: the command is never run, for any actor",
          arguments: [false as Bool?, nil])
    func flagOffNeverRunsTheCommand(flag: Bool?) async throws {
        let fixture = try await makeFixture(flag: flag)
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree)
        for kind in Self.actorKinds {
            let actor = ActuationActor(kind: kind)
            #expect(await fixture.router.holdStartIfDenied(
                "id", actor: actor, agent: .claude, worktreeID: worktree.id) == nil)
            #expect(await fixture.router.holdWakeIfDenied(
                "id", actor: actor, terminalID: terminal.id) == nil)
        }
        #expect(fixture.stub.requests.isEmpty)
        #expect(try await fixture.db.terminals.get(id: terminal.id)?.startHeldReason == nil)
    }

    // MARK: - terminal.create

    @Test("a held terminal.create writes no terminal and no dispatched outcome")
    func heldCreateWritesNothing() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, type: .claude)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(response.error == Self.holdReason)
        #expect(try await fixture.db.terminals.list(worktreeID: worktree.id).isEmpty)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "spawn")
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "held")
        #expect(outcome["error"] as? String == Self.holdReason)
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
        #expect(fixture.stub.requests.first?.kind == .create)
        #expect(fixture.stub.requests.first?.agent == .claude)
    }

    @Test("a resume with no type, or a shell type, is a Claude start and is held",
          arguments: [nil, TerminalCreateType.shell])
    func resumeWithoutClaudeTypeIsHeld(type: TerminalCreateType?) async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: worktree.id, type: type, resumeSessionID: "session-9")))

        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.map(\.agent) == [.claude])
        #expect(try await fixture.db.terminals.list(worktreeID: worktree.id).isEmpty)
        let spawn = try #require(try rows(at: fixture.logPath).first)
        #expect(spawn["agent"] as? String == "claude")
    }

    @Test("a shell terminal.create is never checked")
    func shellCreateIsNotChecked() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, cmd: "ls", type: .shell)))

        #expect(response.success)
        #expect(fixture.stub.requests.isEmpty)
    }

    @Test("the app's terminal.create is never held")
    func appCreateIsNeverHeld() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, type: .claude),
            actor: .app))

        #expect(response.errorCode != RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.isEmpty)
    }

    // MARK: - Wakes

    @Test("a held terminal.wake records the reason and time, and starts nothing", arguments: [TerminalKind.claude, .codex])
    func heldWakeIsRecordedOnTheRow(kind: TerminalKind) async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree, kind: kind)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))

        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(response.error == Self.holdReason)
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.startHeldReason == Self.holdReason)
        #expect(row.startHeldAt != nil)
        // Still parked, with no holder recorded: nothing was respawned.
        #expect(fixture.stub.requests.first?.agent == (kind == .codex ? .codex : .claude))
        #expect(row.claudeSessionID == "session-1")
        #expect(row.isParked)
        #expect(row.holderPID == nil)
        let outcome = try #require(try rows(at: fixture.logPath).last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "held")
        #expect(fixture.stub.requests.first?.kind == .wake)
        #expect(fixture.stub.requests.first?.terminalID == terminal.id)
        #expect(fixture.stub.requests.first?.worktreeID == worktree.id)
    }

    @Test("a later successful wake clears the held marker")
    func clearedByTheNextWake() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree)

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))
        #expect(try await fixture.db.terminals.get(id: terminal.id)?.startHeldReason != nil)

        // A wake the app makes is never held. Whether that wake then
        // succeeds is not this test's concern; the marker's lifetime is the
        // un-park, which every wake path ends in.
        try await fixture.db.terminals.clearHibernated(id: terminal.id)
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.startHeldReason == nil)
        #expect(row.startHeldAt == nil)
        #expect(!row.isParked)
    }

    @Test("the app's wake of a held terminal is never held")
    func appWakeIsNeverHeld() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id),
            actor: .app))

        #expect(response.errorCode != RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.isEmpty)
        #expect(try await fixture.db.terminals.get(id: terminal.id)?.startHeldReason == nil)
    }

    @Test("a wake of a terminal that is not parked keeps its no-op answer and is never checked")
    func liveWakeIsUntouched() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "session-1", kind: .claude)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))

        #expect(response.errorCode != RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.isEmpty)
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.startHeldReason == nil)
    }

    /// Which wake entry points ask admission before they wake.
    enum WakeEntry: CaseIterable, Sendable {
        case terminalWake
        case terminalResume
        case worktreeResume
    }

    /// A row parked on tmux never wakes where it is, so a wake of one starts
    /// nothing and is not checked, even with admission set to hold. The person
    /// gets the refusal that names `tbd terminal migrate`, which a hold would
    /// otherwise hide, and the row is not marked start-held: no wake will ever
    /// start it there, so there is no start to hold.
    @Test("a wake of a row parked on tmux is refused with the migration, and never held",
          arguments: WakeEntry.allCases)
    func tmuxParkedWakeIsRefusedAndNeverHeld(_ entry: WakeEntry) async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(
            in: fixture.db, worktree: worktree, transport: .tmux)

        let response: RPCResponse
        switch entry {
        case .terminalWake:
            response = await fixture.router.handle(try RPCRequest(
                method: RPCMethod.terminalWake,
                params: TerminalWakeParams(terminalID: terminal.id)))
        case .terminalResume:
            response = await fixture.router.handle(try RPCRequest(
                method: RPCMethod.terminalResume,
                params: TerminalResumeParams(terminalID: terminal.id)))
        case .worktreeResume:
            response = await fixture.router.handle(try RPCRequest(
                method: RPCMethod.worktreeResume,
                params: WorktreeResumeParams(worktreeID: worktree.id)))
        }

        #expect(fixture.stub.requests.isEmpty, "admission was asked about a wake that starts nothing")
        #expect(response.errorCode != RPCErrorCode.startHeld.rawValue)
        // `worktree.resume` reports holds only; each terminal's own answer is
        // its actuation outcome, checked below for every entry point.
        if entry != .worktreeResume {
            #expect(response.error
                == HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: terminal.id))
        }
        let outcome = try #require(try rows(at: fixture.logPath).last)
        #expect(outcome["reason"] as? String != "held")
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.startHeldReason == nil)
        #expect(row.startHeldAt == nil)
        #expect(row.isParked)
        #expect(row.transport == .tmux)
    }

    @Test("a wake of a missing terminal is never checked")
    func missingTerminalWakeIsUntouched() async throws {
        let fixture = try await makeFixture()
        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: UUID())))
        #expect(response.errorCode != RPCErrorCode.startHeld.rawValue)
        #expect(fixture.stub.requests.isEmpty)
    }

    @Test("which parked rows a wake checks, and as which agent")
    func wakeAgentClassification() {
        func row(
            kind: TerminalKind?, session: String?, parked: Bool = true,
            transport: TerminalTransport = .holder
        ) -> Terminal {
            Terminal(
                worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
                claudeSessionID: session, kind: kind,
                hibernatedAt: parked ? Date() : nil, transport: transport)
        }
        #expect(RPCRouter.startAdmissionAgent(forWaking: row(kind: .claude, session: "s")) == .claude)
        // A row written before kinds were recorded, with a Claude session id.
        #expect(RPCRouter.startAdmissionAgent(forWaking: row(kind: nil, session: "s")) == .claude)
        // An explicit Codex kind resumes its native thread.
        #expect(RPCRouter.startAdmissionAgent(forWaking: row(kind: .codex, session: "t")) == .codex)
        // Nothing to resume, so the wake starts nothing; and a shell is no agent.
        #expect(RPCRouter.startAdmissionAgent(forWaking: row(kind: .claude, session: nil)) == nil)
        #expect(RPCRouter.startAdmissionAgent(forWaking: row(kind: .shell, session: "s")) == nil)
        // A live row starts nothing when "woken".
        #expect(RPCRouter.startAdmissionAgent(
            forWaking: row(kind: .claude, session: "s", parked: false)) == nil)
        // A row parked on tmux starts nothing: its wake is refused.
        #expect(RPCRouter.startAdmissionAgent(
            forWaking: row(kind: .claude, session: "s", transport: .tmux)) == nil)
        #expect(RPCRouter.startAdmissionAgent(
            forWaking: row(kind: .codex, session: "t", transport: .tmux)) == nil)
    }

    @Test("terminal.resume is held like a wake")
    func heldResume() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await makeParkedClaude(in: fixture.db, worktree: worktree)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalResume,
            params: TerminalResumeParams(terminalID: terminal.id)))

        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(try await fixture.db.terminals.get(id: terminal.id)?.startHeldReason == Self.holdReason)
    }

    @Test("worktree.resume asks once, holds every parked terminal and reports the hold")
    func heldWorktreeResume() async throws {
        let fixture = try await makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        var ids: [UUID] = []
        for index in 1...2 {
            let terminal = try await fixture.db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
                label: TerminalLabel.claudeCode, claudeSessionID: "session-\(index)", kind: .claude,
                transport: .holder)
            try await fixture.db.terminals.setHibernated(id: terminal.id, sessionID: "session-\(index)")
            ids.append(terminal.id)
        }

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeResume,
            params: WorktreeResumeParams(worktreeID: worktree.id)))

        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        // Asked before the first wake only: the second is held for the same
        // reason without running the command again.
        #expect(fixture.stub.requests.count == 1)
        for id in ids {
            let row = try #require(try await fixture.db.terminals.get(id: id))
            #expect(row.startHeldReason == Self.holdReason)
            #expect(row.isParked)
        }
        let outcomes = try rows(at: fixture.logPath).filter { $0["kind"] as? String == "outcome" }
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0["reason"] as? String == "held" })
    }

    // MARK: - Relaunches

    /// The rows a transport migration parked, in order.
    private final class ParkLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func append(_ id: UUID) { lock.withLock { ids.append(id) } }
        var parked: [UUID] { lock.withLock { ids } }
    }

    /// Replaces the migrator's operations: the park parks the row for real, so
    /// an admitted move can finish, and records that it ran.
    private func overrideMigrator(_ fixture: Fixture, parks: ParkLog) {
        let db = fixture.db
        fixture.router.transportMigratorOperationsOverride = TerminalTransportMigrator.Operations(
            canSpawnHolder: { true },
            park: { id in
                parks.append(id)
                try? await db.terminals.setHibernated(id: id, sessionID: "session-1", reason: .manual)
                return .ok
            },
            wake: { _ in .ok(sessionIncarnationID: nil) },
            paneBusyRefusal: { _ in nil },
            retireWindow: { _ in },
            moveRunningShell: { _ in .moved })
    }

    private func makeRunningClaude(
        in db: TBDDatabase, worktree: Worktree, window: Int
    ) async throws -> Terminal {
        try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@\(window)", tmuxPaneID: "%\(window)",
            label: TerminalLabel.claudeCode, claudeSessionID: "session-\(window)", kind: .claude)
    }

    @Test("a held transport move asks once and leaves every running Claude session where it is")
    func heldTransportMove() async throws {
        let fixture = try await makeFixture()
        let parks = ParkLog()
        overrideMigrator(fixture, parks: parks)
        let worktree = try await makeWorktree(in: fixture.db)
        let first = try await makeRunningClaude(in: fixture.db, worktree: worktree, window: 1)
        let second = try await makeRunningClaude(in: fixture.db, worktree: worktree, window: 2)
        // A parked row is only rewritten, which starts nothing, so it still moves.
        let parked = try await makeParkedClaude(in: fixture.db, worktree: worktree)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalMigrateTransport,
            params: TerminalMigrateTransportParams(terminalID: nil)))
        let result = try response.decodeResult(TerminalMigrateTransportResult.self)

        #expect(fixture.stub.requests.count == 1)
        #expect(fixture.stub.requests.first?.kind == .wake)
        #expect(fixture.stub.requests.first?.agent == .claude)
        #expect(parks.parked.isEmpty)
        let held = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.terminalID, $0.reason) })
        #expect(held == [first.id: "held: \(Self.holdReason)", second.id: "held: \(Self.holdReason)"])
        #expect(result.migrated == [parked.id])
        for id in [first.id, second.id] {
            let row = try #require(try await fixture.db.terminals.get(id: id))
            #expect(!row.isParked)
            #expect(row.transport == .tmux)
        }
        let heldOutcomes = try rows(at: fixture.logPath)
            .filter { $0["kind"] as? String == "outcome" && $0["reason"] as? String == "held" }
        #expect(heldOutcomes.count == 2)
    }

    @Test("an admitted transport move asks before each relaunch, and the app's move is never asked",
          arguments: [nil, ActuationActor.app])
    func admittedTransportMove(actor: ActuationActor?) async throws {
        let fixture = try await makeFixture(verdict: .admit)
        let parks = ParkLog()
        overrideMigrator(fixture, parks: parks)
        let worktree = try await makeWorktree(in: fixture.db)
        let first = try await makeRunningClaude(in: fixture.db, worktree: worktree, window: 1)
        let second = try await makeRunningClaude(in: fixture.db, worktree: worktree, window: 2)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalMigrateTransport,
            params: TerminalMigrateTransportParams(terminalID: nil), actor: actor))
        let result = try response.decodeResult(TerminalMigrateTransportResult.self)

        #expect(fixture.stub.requests.count == (actor == nil ? 2 : 0))
        #expect(Set(parks.parked) == [first.id, second.id])
        #expect(Set(result.migrated) == [first.id, second.id])
    }

    @Test("which rows a transport move starts an agent for")
    func migrationAgentClassification() {
        func row(
            kind: TerminalKind?, session: String?, parked: Bool = false,
            transport: TerminalTransport = .tmux
        ) -> Terminal {
            Terminal(
                worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                claudeSessionID: session, kind: kind,
                hibernatedAt: parked ? Date() : nil, transport: transport)
        }
        #expect(RPCRouter.startAdmissionAgent(forMigrating: row(kind: .claude, session: "s")) == .claude)
        #expect(RPCRouter.startAdmissionAgent(forMigrating: row(kind: nil, session: "s")) == .claude)
        // A parked row is only rewritten; a shell restarts as a shell.
        #expect(RPCRouter.startAdmissionAgent(
            forMigrating: row(kind: .claude, session: "s", parked: true)) == nil)
        #expect(RPCRouter.startAdmissionAgent(forMigrating: row(kind: .shell, session: nil)) == nil)
        #expect(RPCRouter.startAdmissionAgent(forMigrating: row(kind: .shell, session: "s")) == nil)
        // The migrator skips these, so they start nothing.
        #expect(RPCRouter.startAdmissionAgent(forMigrating: row(kind: .claude, session: nil)) == nil)
        #expect(RPCRouter.startAdmissionAgent(forMigrating: row(kind: .codex, session: nil)) == nil)
        #expect(RPCRouter.startAdmissionAgent(
            forMigrating: row(kind: .claude, session: "s", transport: .holder)) == nil)
    }
}
