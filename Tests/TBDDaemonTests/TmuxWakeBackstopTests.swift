import Foundation
import Testing
import GRDB
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A tmux row never wakes where it is: TBD starts sessions only on the pty
/// holder. The coordinator refuses a parked one with the gestures that move
/// it, before anything else about it is asked, and it stays parked with its
/// session id; a live one is refused as still running in tmux and left
/// exactly as it was. Either way nothing is touched. A parked holder row
/// wakes as before. A person's wake moves a parked tmux row to the holder
/// before the coordinator sees it (`WakeMigratesParkedTmuxRowTests`), so the
/// router's refusal is a rail's: `worktree.resume` hands it to its caller when
/// it woke nothing.
@Suite("Tmux wake backstop")
struct TmuxWakeBackstopTests {
    private static let sessionID = "sess-backstop"

    private struct Fixture {
        let db: TBDDatabase
        let coordinator: HibernationCoordinator
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let scratch: String
        func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }
    }

    /// The coordinator holds a holder registry that can spawn, through the
    /// spawn double, so a refusal is never for want of one.
    private static func makeFixture() async throws -> Fixture {
        let scratch = fencedScratchRoot(prefix: "tbdbackstop")
        let wtPath = "\(scratch)/wt"
        for dir in [wtPath, "\(scratch)/repo"] {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: wtPath, tmuxServer: "tbd-backstop-test")
        // The Codex stub, so a refusal that came later than it should resolves
        // the stub rather than the machine's own `codex`.
        let coordinator = HibernationCoordinator(
            db: db, configDirManager: makeIsolatedConfigDirManager(tag: "tmux-backstop"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(tag: "tmux-backstop"),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            leftoverTmuxProbe: .absent)
        let holder = FakeHolderLaunch()
        await coordinator.setHolderRegistry(makeHolderRegistryDouble(launch: holder))
        return Fixture(
            db: db, coordinator: coordinator, worktree: worktree, holder: holder,
            scratch: scratch)
    }

    private static func parkedRow(
        _ f: Fixture, transport: TerminalTransport, session: String = sessionID,
        kind: TerminalKind = .claude
    ) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id,
            tmuxWindowID: transport == .holder ? "" : "@3",
            tmuxPaneID: transport == .holder ? "" : "%3",
            label: kind == .codex ? TerminalLabel.codex : TerminalLabel.claudeCode,
            claudeSessionID: session,
            kind: kind,
            transport: transport)
        try await f.db.terminals.setHibernated(
            id: created.id, sessionID: session, reason: .auto)
        return try #require(try await f.db.terminals.get(id: created.id))
    }

    /// An awake tmux row: what a session an earlier build started looks like
    /// while its tmux server may still be running it.
    private static func liveTmuxRow(_ f: Fixture) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id,
            tmuxWindowID: "@3",
            tmuxPaneID: "%3",
            label: TerminalLabel.claudeCode,
            claudeSessionID: Self.sessionID,
            kind: .claude,
            transport: .tmux)
        try await f.db.terminals.setActivityState(
            id: created.id, activityState: .idle, source: .derived)
        return try #require(try await f.db.terminals.get(id: created.id))
    }

    /// A router on the fixture's database whose coordinator wakes holder rows
    /// through the fixture's spawn double.
    private static func makeRouter(_ f: Fixture) async -> RPCRouter {
        let registry = makeHolderRegistryDouble(launch: f.holder)
        var lifecycle = WorktreeLifecycle(
            db: f.db, git: GitManager(), hooks: HookResolver(),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            leftoverTmuxProbe: .absent)
        lifecycle.holderRegistry = registry
        let router = RPCRouter(
            db: f.db, lifecycle: lifecycle, configDirManager: makeIsolatedConfigDirManager(tag: "tmux-backstop-router"),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            actuationLog: makeTestActuationLog(tag: "tmux-backstop-router"))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        return router
    }

    /// The refusal, and that it changed nothing: the row is still parked on
    /// tmux with its session id, and no holder was started for it.
    private static func expectRefused(
        _ result: WakeResult, row: Terminal, _ f: Fixture,
        session: String? = sessionID
    ) async throws {
        guard case .onTmux(let reason) = result else {
            Issue.record("expected the tmux refusal, got \(result)")
            return
        }
        #expect(reason == HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: row.id))
        // The commands have to be runnable as printed: a literal `<id>` would
        // send whoever reads the refusal looking for which session it meant.
        #expect(reason.contains("tbd terminal migrate \(row.id.uuidString)"),
                "the refusal does not name the session to migrate: \(reason)")
        #expect(reason.contains("tbd terminal wake --terminal \(row.id.uuidString)"),
                "the refusal does not name the session to wake as the CLI takes it: \(reason)")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(after.isParked, "the refusal must leave the row parked")
        #expect(after.claudeSessionID == session)
        #expect(after.transport == .tmux)
        #expect(after.tmuxWindowID == "@3")
        #expect(f.holder.launches.isEmpty, "a tmux row's wake started a holder")
    }

    @Test func aParkedTmuxRowRefusesItsWake() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux)

        let result = await f.coordinator.wake(terminalID: row.id)

        try await Self.expectRefused(result, row: row, f)
    }

    /// The refusal comes before every other question the wake would ask. A
    /// Codex row handed a prompt would otherwise be told the prompt cannot be
    /// delivered — advice that changes nothing, since the row cannot wake on
    /// tmux with or without one.
    @Test func aParkedTmuxCodexRowGivenAPromptIsToldToMigrate() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux, kind: .codex)
        // The precondition that makes this discriminate: on a holder row, this
        // plan and this prompt are refused by the Codex check.
        #expect(row.recoveryResumePlan?.identity.agentKind == .codex)

        let result = await f.coordinator.wake(terminalID: row.id, initialPrompt: "acme prompt")

        try await Self.expectRefused(result, row: row, f)
    }

    /// The same order for a parked tmux row with no session id: it is told to
    /// migrate rather than that it has nothing to resume, because migrating is
    /// what the person can do about a tmux row and the answer it would
    /// otherwise get is a holder row's.
    @Test func aParkedTmuxRowWithNoSessionIDIsToldToMigrate() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        var row = try await Self.parkedRow(f, transport: .tmux)
        let rowID = row.id
        try await f.db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE terminal SET claudeSessionID = NULL WHERE id = ?",
                arguments: [rowID.uuidString])
        }
        row = try #require(try await f.db.terminals.get(id: row.id))
        #expect(row.isParked && row.recoveryResumePlan == nil,
                "the fixture is not a parked row with nothing to resume")

        let result = await f.coordinator.wake(terminalID: row.id)

        try await Self.expectRefused(result, row: row, f, session: nil)
    }

    /// A LIVE tmux row is running in tmux as far as this daemon knows — a row
    /// is parked once its server is gone — and TBD can neither reach nor stop
    /// it. So a wake says so, with the command that ends it, instead of
    /// answering "already awake" for a session TBD cannot reach. The prompt is
    /// not delivered, and the row is left exactly as it was.
    @Test func aLiveTmuxRowRefusesItsWakeAsStillRunning() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.liveTmuxRow(f)

        let result = await f.coordinator.wake(terminalID: row.id, initialPrompt: "acme prompt")

        #expect(result == .onTmux(reason: LeftoverTmuxSession.stillRunningRefusal(
            terminalID: row.id, server: f.worktree.tmuxServer)),
                "a live tmux row's wake did not say it is still running: \(result)")
        #expect(try await f.db.terminals.get(id: row.id) == row,
                "a refused wake changed the row")
        #expect(f.holder.launches.isEmpty, "a tmux row's wake started a holder")
    }

    /// The other branch of the backstop: a parked holder row wakes on the
    /// holder and resumes its own session.
    @Test func aParkedHolderRowStillWakes() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .holder)

        let result = await f.coordinator.wake(terminalID: row.id)

        #expect(result.isOk, "a parked holder row did not wake: \(result)")
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(!after.isParked)
        #expect(after.transport == .holder)
        let launch = try #require(f.holder.launch(for: row.id))
        #expect(launch.commandLine?.contains(Self.sessionID) == true,
                "the wake did not resume the row's session: \(launch.commandLine ?? "nil")")
    }

    // MARK: - worktree.resume

    /// A rail's resume moves nothing, so the router hands its tmux row to the
    /// coordinator's refusal. No rail sends `worktree.resume` today; the actor
    /// is declared here so the refusal path the fan-out keeps is still proved.
    private static let rail = ActuationActor.daemon(rail: ActuationRail.limitResume)

    /// A rail's resume whose only parked row is on tmux wakes nothing, so it
    /// answers with the refusal that names the move rather than with success,
    /// and the row stays parked on tmux.
    @Test func aResumeThatWokeNothingAnswersWithTheMove() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedRow(f, transport: .tmux)
        let router = await Self.makeRouter(f)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeResume,
            params: WorktreeResumeParams(worktreeID: f.worktree.id), actor: Self.rail))

        #expect(!response.success, "a resume that woke nothing reported success")
        #expect(response.error == HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: row.id))
        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(try await f.db.terminals.get(id: row.id)?.isParked == true)
        #expect(try await f.db.terminals.get(id: row.id)?.transport == .tmux,
                "a rail's resume moved the row")
        #expect(f.holder.launches.isEmpty, "a tmux row's wake started a holder")
    }

    /// The other branch: a rail's resume that woke another session succeeds,
    /// as it does when any other row fails, and the tmux row stays parked.
    @Test func aResumeThatWokeAnotherSessionStillSucceeds() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let tmuxRow = try await Self.parkedRow(f, transport: .tmux)
        let holderRow = try await Self.parkedRow(
            f, transport: .holder, session: "sess-backstop-holder")
        let router = await Self.makeRouter(f)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeResume,
            params: WorktreeResumeParams(worktreeID: f.worktree.id), actor: Self.rail))

        #expect(response.success, "a resume that woke a session failed: \(response.error ?? "")")
        #expect(try await f.db.terminals.get(id: holderRow.id)?.isParked == false,
                "the holder row did not wake")
        #expect(try await f.db.terminals.get(id: tmuxRow.id)?.isParked == true,
                "the tmux row woke")
    }
}
