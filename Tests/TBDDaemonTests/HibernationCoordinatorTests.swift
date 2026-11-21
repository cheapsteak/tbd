import Testing
import Foundation
import GRDB
import TBDKernel
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A `ClaudeProfileConfigDirManager` pointed at fresh temp dirs, so wake()'s
/// transcript-sync ambient fallback lists a sandbox — never the developer's
/// real `~/.claude/projects` (the sync lists every project dir there and can
/// copy a transcript into it). Every `HibernationCoordinator`/`RPCRouter`
/// construction in this file must pass one.
private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-hib-claude-\(UUID().uuidString)", isDirectory: true)
    return ClaudeProfileConfigDirManager(
        baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
        hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
    )
}

/// `.clockDriven` is applied at SUITE level although few tests below drive
/// an `EventDrivenTestClock`. The trait is a five-minute time limit — a
/// hang-catcher, not a perf budget — so it costs the other tests nothing and
/// it catches the one failure mode virtual time introduces here (a test-clock
/// sleep nobody advances hangs forever instead of going red). `.serialized`
/// is deliberately NOT applied: a few clock-driven tests don't justify
/// serializing the whole suite.
@Suite("HibernationCoordinator", .clockDriven)
struct HibernationCoordinatorTests {

    /// In-memory DB + repo + worktree + an idle Claude terminal. A `.holder`
    /// row — the default, and the only transport TBD parks and wakes — carries
    /// the empty tmux coordinates every holder row carries; a `.tmux` row is
    /// what an earlier build left behind.
    private func setup(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude,
        sessionIncarnationID: UUID? = nil,
        transport: TerminalTransport = .holder
    ) async throws -> (TBDDatabase, UUID, UUID) {
        let db = try TBDDatabase(inMemory: true)
        // wake() refuses to respawn into a missing directory, so the (shared,
        // idempotently created) fixture path must exist on disk.
        try FileManager.default.createDirectory(
            atPath: "/tmp/hib-repo", withIntermediateDirectories: true)
        let repo = try await db.repos.create(path: "/tmp/hib-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/hib-repo", tmuxServer: "tbd-hib"
        )
        let holder = transport == .holder
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: holder ? "" : "@0", tmuxPaneID: holder ? "" : "%0",
            label: "claude", claudeSessionID: sessionID, kind: kind,
            transport: transport, sessionIncarnationID: sessionIncarnationID
        )
        if activityState != .unknown {
            try await db.terminals.setActivityState(id: terminal.id, activityState: activityState, source: .derived)
        }
        if keepWarm {
            try await db.terminals.setKeepWarm(id: terminal.id, keepWarm: true)
        }
        return (db, wt.id, terminal.id)
    }

    private func coordinator(_ db: TBDDatabase) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
    }

    /// Wires the holder spawn double into `coordinator`, so a parked holder
    /// row's wake launches through it instead of a real `TBDHolder`. Only a
    /// holder row wakes: a parked tmux row refuses (`TmuxWakeBackstopTests`).
    @discardableResult
    private func wireHolderDouble(_ coordinator: HibernationCoordinator) async -> FakeHolderLaunch {
        let holder = FakeHolderLaunch()
        await coordinator.setHolderRegistry(makeHolderRegistryDouble(launch: holder))
        return holder
    }

    /// Holder and child pids that name no process: far above any pid darwin
    /// issues, and scripted dead in `endedSessionSignaller()` besides.
    private static let endedHolderPID: Int32 = 1_900_000_201
    private static let endedChildPID: Int32 = 1_900_000_202

    /// An idle Claude row on the holder transport that this file's parks can
    /// finish. Its recorded holder and job are both gone, so the holder park
    /// takes its ended-session path, which needs neither a reader nor a
    /// screen — and a unit test can supply neither. Everything the park tests
    /// here are about is decided before that path, the same for every holder
    /// park: the rails, the composer-draft gate, the parked incarnation, the
    /// record and the deltas.
    private func setupParkable(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        sessionIncarnationID: UUID? = nil
    ) async throws -> (TBDDatabase, UUID, UUID) {
        let (db, worktreeID, terminalID) = try await setup(
            activityState: activityState, keepWarm: keepWarm,
            sessionIncarnationID: sessionIncarnationID)
        try await db.terminals.setHolderProcess(
            id: terminalID, holderPID: Self.endedHolderPID,
            childPID: Self.endedChildPID, startedAt: Date())
        return (db, worktreeID, terminalID)
    }

    /// A process table in which the ended session's pids name nothing.
    private static func endedSessionSignaller() -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[endedHolderPID] = .init(aliveInitially: false)
        signaller.behaviors[endedChildPID] = .init(aliveInitially: false)
        return signaller
    }

    /// Wires what a park of a `setupParkable` row needs into `coordinator`:
    /// the holder spawn double as its registry — a park with no registry
    /// refuses by name — and a holder-liveness check that finds the recorded
    /// holder gone. The coordinator's signaller has to be
    /// `endedSessionSignaller()`. Returns the spawn double, so a later wake's
    /// launch can be read.
    @discardableResult
    private func wireParkable(_ coordinator: HibernationCoordinator) async -> FakeHolderLaunch {
        let holder = await wireHolderDouble(coordinator)
        await coordinator.setHolderProcessIsLive { _ in false }
        return holder
    }

    /// `coordinator(db)` for a `setupParkable` row.
    private func parkingCoordinator(_ db: TBDDatabase) async -> HibernationCoordinator {
        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            signaller: Self.endedSessionSignaller(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireParkable(coordinator)
        return coordinator
    }

    @Test func codexWakeResumesRecordedOptionsWithoutClaudeWork() async throws {
        let (db, worktreeID, terminalID) = try await setup(kind: .codex, transport: .holder)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("acme-codex-wake-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("".utf8).write(to: home.appendingPathComponent("config.toml"))
        try Data(#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"true"}]}]}}"#.utf8)
            .write(to: home.appendingPathComponent("hooks.json"))
        let options = CodexLaunchOptions(model: "acme-model", disabledFeatures: ["acme-feature"], codexHome: home.path)
        let raw = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        try await db.writerForTests.write { db in
            try db.execute(sql: "UPDATE terminal SET codex_launch_options = ? WHERE id = ?", arguments: [raw, terminalID.uuidString])
        }
        let worktree = try #require(try await db.worktrees.get(id: worktreeID))
        try await db.config.setEnvOverrides(["DISABLE_AUTO_UPDATE": "false", "GLOBAL_ONLY": "global", "COLLISION": "global", "CODEX_HOME": "/tmp/acme-wrong-home"])
        try await db.repos.setEnvOverrides(id: try #require(worktree.repoID), overrides: ["DISABLE_AUTO_UPDATE": "false", "REPO_ONLY": "repo", "COLLISION": "repo"])
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: .recovery)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let clock = EventDrivenTestClock()
        let titles = ClaudeSessionTitleStore()
        let coord = HibernationCoordinator(db: db,
            tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(), clock: clock,
            sessionTitles: titles, actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)
        try await db.config.setComposerDraftEnabled(true)
        let refused = await coord.wake(terminalID: terminalID, initialPrompt: "must not be sent")
        #expect(refused == .respawnFailed(reason: "Codex wake cannot deliver an initial prompt; resume without a prompt, then send it to the session."))
        #expect(try await db.terminals.get(id: terminalID)?.isParked == true)
        #expect(holder.launches.isEmpty, "the refused wake started a holder")
        let result = await coord.wake(terminalID: terminalID)
        #expect(result.isOk)
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(!after.isParked)
        #expect(after.sessionIncarnationID != before.sessionIncarnationID)
        #expect(after.claudeSessionID == "sess-1")
        #expect(after.sessionOrderObservedAt == nil)
        #expect(await titles.lastApplied(terminalID: terminalID) == nil)
        #expect(await titles.isReserved(terminalID: terminalID) == false)
        let launch = try #require(holder.launch(for: terminalID))
        let command = try #require(launch.commandLine)
        // The job's process environment: the merged overrides, with the
        // guarded home and the forced auto-update switch on top.
        let environment = launch.request.environment
        #expect(command.contains("resume 'sess-1'"))
        #expect(command.contains("model=\"acme-model\""))
        #expect(command.contains("--disable 'acme-feature'"))
        #expect(command.contains("CODEX_HOME='\(home.path)'"))
        #expect(environment["CODEX_HOME"] == home.path)
        #expect(environment["GLOBAL_ONLY"] == "global")
        #expect(environment["REPO_ONLY"] == "repo")
        #expect(environment["COLLISION"] == "repo")
        #expect(environment["DISABLE_AUTO_UPDATE"] == "true")
        #expect(command.contains("TBD_WORKTREE_ID='\(worktreeID.uuidString)'"))
        #expect(command.contains("TBD_TERMINAL_ID='\(terminalID.uuidString)'"))
        #expect(!command.contains("must not be sent"))
        #expect(!command.contains("--settings"))
        #expect(!command.contains("--name"))
        #expect(environment[SessionModSpawn.featuresVariable] == nil)
        #expect(!(await watchForSleeper(on: clock)), "Codex must wait for SessionStart, not schedule Claude recapture")
    }

    @Test(arguments: ["{broken", #"{"codexHome":"/missing/acme-home"}"#])
    func codexWakeRefusesUnsafeStoredOptions(raw: String) async throws {
        let (db, _, terminalID) = try await setup(kind: .codex, transport: .holder)
        try await db.writerForTests.write { db in
            try db.execute(sql: "UPDATE terminal SET codex_launch_options = ? WHERE id = ?", arguments: [raw, terminalID.uuidString])
        }
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: .recovery)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let coord = HibernationCoordinator(db: db,
            tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)
        guard case .respawnFailed = await coord.wake(terminalID: terminalID) else {
            Issue.record("unsafe stored Codex options must refuse preparation"); return
        }
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.isParked)
        #expect(after.sessionIncarnationID == before.sessionIncarnationID)
        #expect(after.claudeSessionID == before.claudeSessionID)
        #expect(holder.launches.isEmpty, "a refused preparation started a holder")
    }

    @Test func codexWakeMissingExecutableKeepsTheOriginalPark() async throws {
        let (db, worktreeID, _) = try await setup()
        let terminal = try await db.terminals.create(worktreeID: worktreeID,
            tmuxWindowID: "", tmuxPaneID: "", claudeSessionID: "acme-thread",
            kind: .codex, transport: .holder)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "acme-thread", reason: .recovery)
        let before = try #require(try await db.terminals.get(id: terminal.id))
        struct MissingExecutable: Error {}
        let coord = HibernationCoordinator(db: db,
            tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            codexExecutableResolver: { throw MissingExecutable() },
            codexHomeEnsurer: { Issue.record("home preparation must follow executable resolution"); throw MissingExecutable() },
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)
        guard case .respawnFailed(let reason) = await coord.wake(terminalID: terminal.id) else {
            Issue.record("missing Codex executable must refuse preparation"); return
        }
        #expect(reason.contains("preparing Codex resume failed"))
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.isParked)
        #expect(after.sessionIncarnationID == before.sessionIncarnationID)
        #expect(after.claudeSessionID == before.claudeSessionID)
        #expect(holder.launches.isEmpty, "a refused preparation started a holder")
    }

    @Test func codexHolderWakeLosesChangedRowBeforeSpawning() async throws {
        let (db, _, terminalID) = try await setup(kind: .codex, transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: .recovery)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let gate = BlockingRespawnRecorder()
        gate.arm(matching: "prepare-codex")
        let coord = HibernationCoordinator(db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            codexExecutableResolver: { gate.record(["prepare-codex"]); return "/opt/acme/bin/codex" },
            leftoverTmuxProbe: .absent)
        let registry = HolderRegistry(owner: HolderOwnerToken(rawValue: "acme"), listTerminals: { [] })
        await coord.setHolderRegistry(registry)
        let wake = gateHoldingTask { await coord.wake(terminalID: terminalID) }
        guard await waitUntil({ gate.isBlocked }, timeout: ciSafeDeadline) else {
            gate.release(); _ = await wake.value
            Issue.record("wake did not reach Codex preparation"); return
        }
        let completed = RecordedTmuxCommands()
        let otherWake = gateHoldingTask {
            let result = await coord.wake(terminalID: UUID())
            completed.append(["finished"])
            return result
        }
        let remainedResponsive = await waitUntil({ !completed.snapshot().isEmpty }, timeout: ciSafeDeadline)
        try await db.terminals.updateSessionID(id: terminalID, sessionID: "replacement-thread")
        gate.release()
        #expect(remainedResponsive, "Codex preparation must not block unrelated coordinator operations")
        #expect(await otherWake.value == .notFound)
        #expect(await wake.value == .respawnFailed(reason: "terminal changed while wake was preparing; retry"))
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.isParked)
        #expect(after.sessionIncarnationID == before.sessionIncarnationID)
        #expect(after.claudeSessionID == "replacement-thread")
        #expect(await registry.reader(for: terminalID) == nil)
    }

    // MARK: - Manual hibernate

    @Test func manualHibernateMarksHibernated() async throws {
        let (db, _, terminalID) = try await setupParkable(activityState: .idle)
        let result = await parkingCoordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.isHibernated == true)
    }

    /// A live row still on tmux is a session TBD can neither reach nor stop,
    /// so its park refuses with the advice that ends it and leaves the row
    /// exactly as it was. Every manual rail would have let this row through —
    /// idle, resumable, not kept warm — so the refusal is the transport's.
    @Test func manualHibernateRefusesALiveTmuxRowAsStillRunning() async throws {
        let (db, worktreeID, terminalID) = try await setup(activityState: .idle, transport: .tmux)
        let before = try #require(try await db.terminals.get(id: terminalID))
        #expect(before.isManuallyHibernatable(),
                "the fixture would be refused by a rail, not by its transport")
        let worktree = try #require(try await db.worktrees.get(id: worktreeID))
        let recorded = RecordedTmuxCommands()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true, dryRunRecorder: recorded.append),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireParkable(coord)

        let result = await coord.manualHibernate(terminalID: terminalID)

        #expect(result == .onTmux(reason: LeftoverTmuxSession.stillRunningRefusal(
            terminalID: terminalID, server: worktree.tmuxServer)),
                "a live tmux row's park did not say it is still running: \(result)")
        #expect(try await db.terminals.get(id: terminalID) == before,
                "a refused park changed the row")
        #expect(recorded.snapshot().isEmpty, "a refused park ran tmux: \(recorded.snapshot())")
    }

    /// The merge-park refuses it the same way, and before its record: a park
    /// this rail can never make writes no actuation row.
    @Test func mergeParkRefusesALiveTmuxRowAsStillRunning() async throws {
        let (db, worktreeID, terminalID) = try await setup(activityState: .idle, transport: .tmux)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let worktree = try #require(try await db.worktrees.get(id: worktreeID))
        let logPath = try sweepLogPath()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: ActuationLog(path: logPath),
            leftoverTmuxProbe: .absent)

        #expect(await coord.hibernateForMerge(terminalID: terminalID)
            == .onTmux(reason: LeftoverTmuxSession.stillRunningRefusal(
                terminalID: terminalID, server: worktree.tmuxServer)))
        #expect(try await db.terminals.get(id: terminalID) == before,
                "a refused merge-park changed the row")
        #expect(try logRows(at: logPath).isEmpty,
                "a merge-park that could never happen wrote an actuation row")
    }

    /// The profile swap's park refuses it too: a swap cannot re-home a
    /// session TBD cannot stop.
    @Test func profileSwapParkRefusesALiveTmuxRowAsStillRunning() async throws {
        let (db, worktreeID, terminalID) = try await setup(activityState: .idle, transport: .tmux)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let worktree = try #require(try await db.worktrees.get(id: worktreeID))

        #expect(await coordinator(db).parkForProfileSwap(terminalID: terminalID)
            == .onTmux(reason: LeftoverTmuxSession.stillRunningRefusal(
                terminalID: terminalID, server: worktree.tmuxServer)))
        #expect(try await db.terminals.get(id: terminalID) == before,
                "a refused profile-swap park changed the row")
    }

    /// A park writes `.idle` and a wake resets the column to `.unknown` for
    /// the incarnation it mints; no activity delta announces either, so each
    /// one's hibernation delta carries the activity columns it committed, read
    /// back from the row.
    @Test func parkAndWakeDeltasCarryTheCommittedActivityColumns() async throws {
        let (db, _, terminalID) = try await setupParkable(activityState: .idle)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true),
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            signaller: Self.endedSessionSignaller(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireParkable(coord)

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID))
        let parkActivity = try #require(deltas.snapshot().last { $0.hibernated }?.activity)
        #expect(parkActivity.activityState == .idle)
        #expect(parkActivity.activityStateSource == .database)
        #expect(parkActivity.activityStateObservedAt == parked.activityStateObservedAt)
        #expect(parkActivity.activityStateOrderObservedAt == parked.activityStateOrderObservedAt)

        #expect(await coord.wake(terminalID: terminalID).isOk)
        let awake = try #require(try await db.terminals.get(id: terminalID))
        let wakeActivity = try #require(deltas.snapshot().last { !$0.hibernated }?.activity)
        #expect(awake.activityState == .unknown)
        #expect(wakeActivity.activityState == .unknown)
        #expect(wakeActivity.activityStateSource == .derived)
        #expect(wakeActivity.activityStateObservedAt == awake.activityStateObservedAt)
        #expect(wakeActivity.activityStateOrderObservedAt == awake.activityStateOrderObservedAt)
    }

    /// A park mints the parked incarnation, so a SessionStart the outgoing
    /// process reports afterwards — naming the incarnation it was launched
    /// with — is fenced, and the parked row keeps the session it will resume.
    @Test func parkFencesASessionStartFromBeforeThePark() async throws {
        let (db, _, terminalID) = try await setupParkable(activityState: .idle)
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/hibernation-old-session.jsonl")
        let before = try #require(try await db.terminals.get(id: terminalID))

        #expect(await parkingCoordinator(db).manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID))
        #expect(parked.sessionIncarnationID != before.sessionIncarnationID)
        #expect(parked.label == before.label)
        #expect(parked.claudeSessionID == "sess-1")
        #expect(parked.transcriptPath == "/tmp/hibernation-old-session.jsonl")
        #expect(parked.sessionOrderObservedAt == nil)
        #expect(parked.codexTranscriptBoundaryOffset == nil)

        let staleApplication = try await db.terminals.applySessionStart(
            id: terminalID,
            expectedIncarnation: TerminalSessionIncarnation(terminal: before),
            sessionID: "stale-session",
            transcriptPath: "/tmp/stale-hibernation-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 20))
        #expect(staleApplication == nil)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged.claudeSessionID == parked.claudeSessionID)
        #expect(unchanged.transcriptPath == parked.transcriptPath)
        #expect(unchanged.sessionIncarnationID == parked.sessionIncarnationID)
        #expect(unchanged.isHibernated)
    }

    /// A park owns its row from its claim to its return — the holder park
    /// polls its job's exit across suspension points — and a wake landing in
    /// that window is answered `.inFlight` rather than un-parking a row the
    /// park is about to finalize.
    @Test func wakeAnswersInFlightWhileAParkHoldsTheRow() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let coordinator = coordinator(db)
        let holder = await wireHolderDouble(coordinator)

        await coordinator.claimHibernateSlotForTest(terminalID)
        #expect(await coordinator.wake(terminalID: terminalID) == .inFlight,
                "a wake raced a park that holds this row")
        #expect(holder.launches.isEmpty, "a wake raced a park and started a holder")
        await coordinator.releaseHibernateSlotForTest(terminalID)
        #expect(await coordinator.wake(terminalID: terminalID).isOk,
                "the row did not wake once the park released it")
    }

    // MARK: - The in-place profile swap's claim on a row

    /// The swap claim exists because the row is PARKED and unowned between the
    /// park and the re-home: `hibernatesInFlight` releases when the park
    /// returns and `wakesInFlight` is not taken until the wake several
    /// suspension points later. The app's wake-on-focus wakes exactly the
    /// active tab's parked terminal, which is the tab "Switch account" was
    /// pressed on — so without this the ordinary focus-wake can un-park the
    /// row and start a session under the account being switched away from.
    @Test func wakeAnswersInFlightWhileAProfileSwapHoldsTheRow() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let coordinator = coordinator(db)

        #expect(await coordinator.claimSwap(terminalID: terminalID),
                "a row nothing holds refused the swap claim")
        #expect(await coordinator.wake(terminalID: terminalID) == .inFlight,
                "a wake raced a swap that holds this row")

        await coordinator.releaseSwap(terminalID: terminalID)
        // Not an assertion that the wake SUCCEEDS — this row is awake and no
        // holder runs it. What the release has to restore is that a wake is
        // answered on its merits again rather than deflected.
        #expect(await coordinator.wake(terminalID: terminalID) != .inFlight,
                "releasing the swap claim left the row permanently unwakeable")
    }

    /// The claim is exclusive in both directions: it refuses a row either
    /// singleflight set already holds, so a swap cannot start against a park
    /// or a wake that is mid-ladder.
    @Test func claimSwapRefusesARowAParkOrWakeAlreadyHolds() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let coordinator = coordinator(db)

        await coordinator.claimHibernateSlotForTest(terminalID)
        #expect(await coordinator.claimSwap(terminalID: terminalID) == false,
                "a swap claimed a row whose park is in flight")
        await coordinator.releaseHibernateSlotForTest(terminalID)

        await coordinator.claimWakeSlotForTest(terminalID)
        #expect(await coordinator.claimSwap(terminalID: terminalID) == false,
                "a swap claimed a row whose wake is in flight")
        await coordinator.releaseWakeSlotForTest(terminalID)

        #expect(await coordinator.claimSwap(terminalID: terminalID),
                "the claim stayed refused after both singleflights released")
        #expect(await coordinator.claimSwap(terminalID: terminalID) == false,
                "two swaps claimed the same row at once")
        await coordinator.releaseSwap(terminalID: terminalID)
        #expect(await coordinator.claimSwap(terminalID: terminalID),
                "releasing the swap claim did not make the row claimable again")
        await coordinator.releaseSwap(terminalID: terminalID)
    }

    /// The arm's swap claim excludes wakes and other swaps, and it does NOT
    /// exclude parks — a hibernate may begin after the claim is taken, and the
    /// swap's own park is then answered `.alreadyHibernated`, which the arm
    /// reports as a refusal that changed nothing. This pins the coordinator
    /// half of that: `parkForProfileSwap` still answers the singleflight, so
    /// the arm's branch for it is reachable and not dead code.
    @Test func parkForProfileSwapIsRefusedWhileAParkIsMidLadder() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let coordinator = coordinator(db)

        #expect(await coordinator.claimSwap(terminalID: terminalID),
                "a row nothing holds refused the swap claim")
        await coordinator.claimHibernateSlotForTest(terminalID)
        #expect(await coordinator.parkForProfileSwap(terminalID: terminalID) == .alreadyHibernated,
                "a park that began after the swap claim did not refuse the swap's own park")
        await coordinator.releaseHibernateSlotForTest(terminalID)
        await coordinator.releaseSwap(terminalID: terminalID)
    }

    @Test func manualHibernateRefusesRunningTurn() async throws {
        let (db, _, terminalID) = try await setup(activityState: .working)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        guard case .notEligible = result else {
            Issue.record("expected .notEligible for a running turn, got \(result)")
            return
        }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func manualHibernateRefusesPermissionPrompt() async throws {
        let (db, _, terminalID) = try await setup(activityState: .waitingForUser)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        guard case .notEligible = result else {
            Issue.record("expected .notEligible for a permission prompt, got \(result)")
            return
        }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func manualHibernateIgnoresKeepWarm() async throws {
        // Manual hibernate BYPASSES keep-warm (the user asked explicitly).
        let (db, _, terminalID) = try await setupParkable(activityState: .idle, keepWarm: true)
        let result = await parkingCoordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    @Test func manualHibernateRejectsNonClaude() async throws {
        let (db, _, terminalID) = try await setup(sessionID: nil, kind: .shell)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        guard case .notEligible = result else {
            Issue.record("expected .notEligible for a shell terminal, got \(result)")
            return
        }
    }

    @Test func manualHibernateAlreadyHibernatedIsNoOp() async throws {
        let (db, _, terminalID) = try await setupParkable()
        let coord = await parkingCoordinator(db)
        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let second = await coord.manualHibernate(terminalID: terminalID)
        #expect(second == .alreadyHibernated)
    }

    // MARK: - Park path: poll pacing
    //
    // The holder park's ladder polls its child at `exitPollInterval`, on an
    // injected `clock`, with a budget per rung.

    /// Pins the SHIPPED poll windows, which the injected-pacing tests
    /// deliberately do not run. Making the pacing injectable must not quietly
    /// change how long production waits for a claude that is shutting down
    /// before it kills one.
    @Test func defaultHolderParkPacing() async throws {
        let (db, _, _) = try await setup()
        let coord = coordinator(db)
        #expect(coord.exitPollInterval == .milliseconds(200))
        // The middle rung: 25 checks after a `SIGTERM`, i.e. five seconds for
        // a session to run its Stop hooks, tear down its MCP children and
        // flush the transcript it is mid-write on. Shortening it is a
        // behaviour change rather than a tuning nudge.
        #expect(coord.holderTerminateAttempts == 25)
        #expect(coord.exitPollInterval * coord.holderTerminateAttempts == .seconds(5),
                "the shipped SIGTERM window must stay ~5s")
        // The escalation budget after it is a different budget again: five
        // more checks once `abandon` has SIGKILLed the job, i.e. one second for
        // a dead process to leave the process table. The rung above does not
        // wait for that, and it does not wait for the rung above.
        #expect(coord.holderEscalationAttempts == 5)
        #expect(coord.exitPollInterval * coord.holderEscalationAttempts == .seconds(1),
                "the shipped holder escalation window must stay ~1s")
    }

    // MARK: - Park cancels the scheduled auto-resume

    /// A hibernated terminal must never carry a scheduled auto-resume — the
    /// Claude process is dead, so a resume firing later would type "continue"
    /// into a bare shell. The park write (`setHibernated`, reached here via
    /// `performHibernate`) cancels the pending row and clears the
    /// `pendingResumeAt` mirror atomically; wake does NOT resurrect it.
    @Test func parkCancelsScheduledResumeAndWakeDoesNotResurrect() async throws {
        let (db, worktreeID, terminalID) = try await setupParkable(activityState: .idle)
        let resume = ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            claudeSessionID: "sess-1",
            resetsAt: Date().addingTimeInterval(60),
            fireAt: Date().addingTimeInterval(90),
            limitType: "session", rawMessage: "You've hit your session limit")
        _ = try await db.scheduledResumes.insertPending(resume)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt != nil)

        let coord = await parkingCoordinator(db)
        let parked = await coord.manualHibernate(terminalID: terminalID)
        #expect(parked == .ok)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil,
                "parking must cancel the pending scheduled resume")
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil,
                "the pendingResumeAt mirror must clear with the park write")

        let woke = await coord.wake(terminalID: terminalID)
        #expect(woke.isOk)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil,
                "wake must not resurrect the cancelled resume")
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
    }

    // MARK: - Auto-off: manual park still works

    /// Manual "Hibernate now" must NOT consult `auto_hibernate_enabled`. With the
    /// master switch OFF, the idle sweep does nothing (covered by
    /// `sweepDoesNotHibernateWhenFeatureDisabled`), but manual park still fully
    /// succeeds — the replacement for the old manual Suspend workflow.
    @Test func manualHibernateWorksWhileAutoOff() async throws {
        let (db, _, terminalID) = try await setupParkable(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: false, idleMinutes: 30)
        let result = await parkingCoordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok, "manual hibernate must not depend on the auto switch")
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    // MARK: - Wake
    //
    // Only a holder row wakes; a parked tmux row refuses before anything is
    // touched (`TmuxWakeBackstopTests`). The wakes below run on holder rows,
    // through the holder spawn double.

    /// The park mints the parked incarnation, and the wake mints the
    /// replacement's.
    @Test func wakeRespawnPreservesRetryIdentityAndRejectsParkedIncarnation() async throws {
        let (db, _, terminalID) = try await setupParkable()
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/hibernation-wake-old-session.jsonl")
        let coord = await parkingCoordinator(db)
        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID))

        let wakeResult = await coord.wake(terminalID: terminalID)
        #expect(wakeResult.isOk)
        let awake = try #require(try await db.terminals.get(id: terminalID))
        #expect(wakeResult == .ok(sessionIncarnationID: awake.sessionIncarnationID))
        #expect(awake.sessionIncarnationID != parked.sessionIncarnationID)
        #expect(awake.tmuxWindowID == parked.tmuxWindowID)
        #expect(awake.tmuxPaneID == parked.tmuxPaneID)
        #expect(awake.label == parked.label)
        #expect(awake.claudeSessionID == "sess-1")
        #expect(awake.transcriptPath == "/tmp/hibernation-wake-old-session.jsonl")
        #expect(awake.sessionOrderObservedAt == nil)
        #expect(awake.codexTranscriptBoundaryOffset == nil)
        #expect(awake.activityState == .unknown)
        #expect(!awake.isParked)

        let staleApplication = try await db.terminals.applySessionStart(
            id: terminalID,
            expectedIncarnation: TerminalSessionIncarnation(terminal: parked),
            sessionID: "stale-parked-session",
            transcriptPath: "/tmp/stale-parked-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 30))
        #expect(staleApplication == nil)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged.claudeSessionID == "sess-1")
        #expect(unchanged.transcriptPath == "/tmp/hibernation-wake-old-session.jsonl")
        #expect(unchanged.sessionIncarnationID == awake.sessionIncarnationID)
        #expect(!unchanged.isParked)
    }

    @Test func wakeOnNonHibernatedIsIdempotentNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(), leftoverTmuxProbe: .absent)
        let result = await coord.wake(terminalID: terminalID)
        #expect(result == .notHibernated)
        #expect(recorded.snapshot().isEmpty,
                "a non-parked wake must not touch tmux; got: \(recorded.snapshot())")
    }

    // MARK: - Unparked rows

    /// A wake whose replacement agent launched but whose row could not be
    /// un-parked still launched a session under its `--name`, so the title
    /// store must hold that name as given — releasing it would put back an
    /// entry the running session no longer carries.
    @Test func wakeThatLaunchedButCouldNotUnparkConfirmsItsTitle() async throws {
        let (db, worktreeID, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        try await db.writerForTests.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER reject_unpark BEFORE UPDATE ON terminal
                WHEN OLD.hibernatedAt IS NOT NULL AND NEW.hibernatedAt IS NULL
                BEGIN
                    SELECT RAISE(ABORT, 'unpark rejected');
                END;
                """)
        }
        let titles = ClaudeSessionTitleStore()
        await titles.record(terminalID: terminalID, worktreeID: worktreeID, title: "before-wake")
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true), configDirManager: isolatedConfigDirManager(),
            sessionTitles: titles,
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)

        let result = await coord.wake(terminalID: terminalID)
        guard case .respawnFailed(let reason) = result, reason.contains("launched") else {
            Issue.record("expected the launched-but-still-parked failure, got \(result)")
            return
        }
        #expect(holder.launch(for: terminalID) != nil, "the wake never launched its replacement")
        // The worktree's display name, the only Claude terminal's title.
        #expect(await titles.lastApplied(terminalID: terminalID) == "wt",
                "a wake that launched under its --name did not keep that name")
        #expect(await titles.isReserved(terminalID: terminalID) == false)
    }

    @Test func wakeUnknownTerminalNotFound() async throws {
        let (db, _, _) = try await setup()
        let result = await coordinator(db).wake(terminalID: UUID())
        #expect(result == .notFound)
    }

    /// Wake must clear BOTH the authoritative `hibernatedAt` AND any legacy
    /// `suspendedAt` so a row parked by the pre-merge Suspend feature (or one
    /// that still has a stale suspendedAt) fully un-parks. Here we set both, wake,
    /// and assert both are nil.
    @Test func wakeClearsBothHibernatedAndLegacySuspended() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        // Mark hibernated (authoritative) AND stamp a legacy suspendedAt.
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess-1")
        // setSuspended cleared hibernatedAt? No — it only sets suspendedAt. But to
        // be safe re-mark hibernated so both columns are set.
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let before = try await db.terminals.get(id: terminalID)
        #expect(before?.hibernatedAt != nil)
        #expect(before?.suspendedAt != nil)

        let coord = coordinator(db)
        await wireHolderDouble(coord)
        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake.isOk)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil, "wake must clear hibernatedAt")
        #expect(after?.suspendedAt == nil, "wake must also clear legacy suspendedAt")
    }

    /// Regression: a row parked with ONLY `suspendedAt` (the reconcile /
    /// recreate-window paths, or a pre-merge Suspend row) must still wake. The
    /// guard checks `isParked`, not `hibernatedAt` alone — otherwise these rows
    /// show a Wake button that silently no-ops and the pane is stuck forever.
    @Test func wakeUnparksLegacySuspendedOnlyRow() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        let coord = coordinator(db)
        let holder = await wireHolderDouble(coord)

        // Legacy park: only suspendedAt set, hibernatedAt nil.
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess-1")
        let before = try await db.terminals.get(id: terminalID)
        #expect(before?.hibernatedAt == nil)
        #expect(before?.suspendedAt != nil)
        #expect(before?.isParked == true)

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake.isOk, "wake must un-park a suspendedAt-only row, not no-op it")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false, "row fully un-parked (both columns nil)")

        let command = holder.launch(for: terminalID)?.commandLine
        #expect(command?.contains("claude --resume sess-1") == true,
                "expected a holder launch carrying claude --resume; got: \(command ?? "nil")")
    }

    // MARK: - Wake and park: a tab that is not Claude's

    /// A parked SHELL tab whose row carries a Claude session id — the exit
    /// stamp `SessionEnd` leaves when a Claude run by hand inside the tab
    /// exits, or any other park — is still a shell tab. Waking it must not run
    /// `claude --resume`: that would replace the tab's shell with a bare Claude
    /// launched however TBD launches one, not however the person launched
    /// theirs. It takes the shell answer instead: refused before anything is
    /// touched, the row left as it was.
    @Test(arguments: [HibernateReason.exited, .auto])
    func wakeOfAParkedShellTabCarryingASessionIDResumesNothing(reason: HibernateReason) async throws {
        let (db, _, terminalID) = try await setup(sessionID: "sess-1", kind: .shell)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: reason)
        let coord = coordinator(db)
        let holder = await wireHolderDouble(coord)

        let result = await coord.wake(terminalID: terminalID)

        #expect(result == .notAClaudeTab(kind: .shell),
                "a shell tab was woken as a Claude session: \(result)")
        #expect(holder.launches.isEmpty,
                "the refused wake started a holder: \(holder.launches.map(\.commandLine))")
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.isParked, "the refused wake un-parked the row")
        #expect(after.pendingSessionIncarnationID == nil,
                "the refused wake reserved a replacement launch")
    }

    /// The park is the first half of every resume: a row is parked so a later
    /// wake can resume it. A shell tab carrying a session id must not be
    /// parked by the profile swap's park either — its policy skips the live
    /// rails, so nothing else on that path asks what kind of tab it is.
    @Test func profileSwapParkRefusesAShellTabCarryingASessionID() async throws {
        let (db, _, terminalID) = try await setup(sessionID: "sess-1", kind: .shell)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let coord = coordinator(db)

        let result = await coord.parkForProfileSwap(terminalID: terminalID)

        #expect(result == .notEligible(reason: ClaudeResumeDecision.notAClaudeTabReason(.shell)),
                "expected the park to refuse a shell tab, got \(result)")
        #expect(try await db.terminals.get(id: terminalID) == before,
                "the refused park changed the row")
    }

    /// An exit stamp an earlier build left on a tab that is not Claude's is
    /// lifted at startup. Builds before the stamp asked the tab's kind stamped
    /// a shell tab whose hand-started Claude exited. This build's wake refuses
    /// that tab and the app never auto-wakes `.exited`, so nothing else would
    /// lift the stamp: the tab would stay parked until it was closed. The
    /// stamp stopped nothing — the pane's shell stays alive under it — so
    /// lifting it leaves the row as this build would have: unstamped, a live
    /// shell, its session id untouched.
    @Test(arguments: [TerminalKind.shell, .codex])
    func startupLiftsAnEarlierBuildsExitStampFromATabThatIsNotClaudes(kind: TerminalKind) async throws {
        let (db, _, terminalID) = try await setup(sessionID: "sess-1", kind: kind, transport: .tmux)
        // `stampSessionExited` refuses this tab now, so the earlier build's
        // stamp is written the way any park is.
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: .exited)
        let recorded = RecordedTmuxCommands()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true, dryRunRecorder: recorded.append),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)

        await coord.reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(!after.isParked, "a \(kind.rawValue) tab stayed behind an exit stamp no wake can lift")
        #expect(after.hibernateReason == nil)
        #expect(after.claudeSessionID == "sess-1")
        #expect(recorded.snapshot().isEmpty,
                "lifting the stamp asked tmux something: \(recorded.snapshot())")
    }

    /// The mirror: the repair is for that one stale stamp. A Claude tab's exit
    /// stamp is what its wake resumes from, and a shell tab parked for any
    /// other reason had its process replaced, so both stay parked.
    @Test(arguments: [TerminalKind.claude, .shell])
    func startupLeavesEveryOtherParkAlone(kind: TerminalKind) async throws {
        let (db, _, terminalID) = try await setup(sessionID: "sess-1", kind: kind, transport: .tmux)
        let reason: HibernateReason = kind == .claude ? .exited : .auto
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: reason)
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)

        await coord.reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.isParked, "startup un-parked a \(kind.rawValue) tab parked as \(reason.rawValue)")
        #expect(after.hibernateReason == reason)
    }

    /// The lift is tmux-only. The stamp never reached a holder row, and a
    /// parked holder row is answered by the arm that verifies its child
    /// process — with no child recorded, that arm leaves it as it is.
    @Test func startupLeavesAHolderShellRowToTheHolderArm() async throws {
        let (db, worktreeID, _) = try await setup()
        let holder = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "shell", claudeSessionID: "sess-1", kind: .shell, transport: .holder)
        try await db.terminals.setHibernated(id: holder.id, sessionID: "sess-1", reason: .exited)
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)

        await coord.reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: holder.id))
        #expect(after.isParked, "the tmux-only lift un-parked a holder row")
        #expect(after.hibernateReason == .exited)
    }

    // MARK: - Session mod on wake

    /// A draft the mod saved before the park, byte for byte as it wrote it.
    private static let savedDraft = Data(
        #"{"schemaVersion":1,"sessionId":"sess-1","hasDraft":true,"text":"unsent","cursor":6,"restorable":true,"savedAtMs":1}"#.utf8)

    /// Seeds `sess-1`'s directory as an earlier spawn and the mod left it: a
    /// spawn record naming a previous incarnation, and a saved draft.
    private func seedSessionFiles(_ sessionsDir: URL) throws -> URL {
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: "sess-1", incarnationId: UUID().uuidString,
                  spawnedAtMs: 1, features: ["composer-draft"]),
            sessionsDir: sessionsDir)
        let directory = sessionsDir.appendingPathComponent("sess-1", isDirectory: true)
        try Self.savedDraft.write(
            to: directory.appendingPathComponent(SessionModFiles.composerDraftFileName))
        return directory
    }

    /// With the flag on, a wake launches the replacement with the three mod
    /// variables in its process environment and rewrites `spawn.json` to name
    /// the incarnation the row now holds. The rest of the session's directory,
    /// the saved draft above all, is untouched: the woken mod restores from it.
    @Test func wakeWithTheFlagOnExportsTheModAndRewritesSpawn() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        try await db.config.setComposerDraftAsTheOnlyModFeature(true)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let directory = try seedSessionFiles(sessionsDir)
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true), configDirManager: isolatedConfigDirManager(),
            sessionsDir: sessionsDir, sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)

        #expect(await coord.wake(terminalID: terminalID).isOk)

        let awake = try #require(try await db.terminals.get(id: terminalID))
        let incarnation = try #require(awake.sessionIncarnationID)
        let launch = try #require(holder.launch(for: terminalID))
        let launchEnv = launch.request.environment
        #expect(launchEnv[SessionModSpawn.sessionsDirVariable] == sessionsDir.path)
        #expect(launchEnv[SessionModSpawn.featuresVariable] == "composer-draft")
        #expect(launchEnv[SessionModSpawn.incarnationVariable] == incarnation.uuidString)

        let spawn = try #require(readSpawnRecord(sessionsDir: sessionsDir, sessionID: "sess-1"))
        #expect(spawn.sessionId == "sess-1")
        #expect(spawn.incarnationId == incarnation.uuidString)
        #expect(spawn.features == ["composer-draft"])
        #expect(try Data(contentsOf: directory.appendingPathComponent(
            SessionModFiles.composerDraftFileName)) == Self.savedDraft)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
            == [SessionModFiles.spawnFileName, SessionModFiles.composerDraftFileName])
    }

    /// With every feature off a wake is what it always was: no mod variable in
    /// the launch's process environment and nothing written under the sessions
    /// directory.
    @Test func wakeWithTheFlagOffExportsNothing() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        try await db.config.setEverySessionModFeatureOff()
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true), configDirManager: isolatedConfigDirManager(),
            sessionsDir: sessionsDir, sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)

        #expect(await coord.wake(terminalID: terminalID).isOk)

        let launch = try #require(holder.launch(for: terminalID))
        let launchEnv = launch.request.environment
        #expect(launchEnv[SessionModSpawn.sessionsDirVariable] == nil)
        #expect(launchEnv[SessionModSpawn.featuresVariable] == nil)
        #expect(launchEnv[SessionModSpawn.incarnationVariable] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path).isEmpty)
    }

    // MARK: - Wake: the launch gap

    /// The wake persists the replacement's incarnation before it starts the
    /// agent, and the launch carries that token. A SessionStart the router
    /// handles in the gap between the two names no incarnation, so it is the
    /// old process's and is fenced; the replacement's own, naming the token,
    /// attaches. The gap is observed from inside the holder double's spawn,
    /// which runs after the row is staged and before the launch is answered.
    @Test func wakeFencesSessionStartHandledDuringTheLaunchGap() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager(),
                leftoverTmuxProbe: .absent),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let launches = WakeGapHolderLaunch()
        let registry = launches.registry()
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)

        let gapEvent = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "old-process-gap-session",
                transcriptPath: "/tmp/old-process-gap-session.jsonl",
                source: "startup"))
        let staged = WakeGapValue<Terminal>()
        let gapHandled = WakeGapValue<Bool>()
        let sessionAfterGap = WakeGapValue<String>()
        launches.onSpawn { id in
            guard id == terminalID else { return }
            if let row = try? await db.terminals.get(id: terminalID) {
                staged.set(row)
            }
            gapHandled.set(await router.handle(gapEvent).success)
            if let session = try? await db.terminals.get(id: terminalID)?.claudeSessionID {
                sessionAfterGap.set(session)
            }
        }

        #expect((await router.hibernationCoordinator.wake(terminalID: terminalID)).isOk)

        let stagedRow = try #require(staged.value, "the wake never reached the launch")
        #expect(stagedRow.isParked, "the row was un-parked before its replacement launched")
        #expect(stagedRow.label == "claude")
        let replacementToken = try #require(stagedRow.sessionIncarnationID)
        let command = try #require(launches.inner.launch(for: terminalID)?.commandLine)
        #expect(command.contains("TBD_TERMINAL_INCARNATION_ID='\(replacementToken.uuidString)'"))
        let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
        #expect(command.contains("TBD_CLI_PATH=\(shellEscape(matchedCLIPath))"))
        #expect(gapHandled.value == true)
        #expect(sessionAfterGap.value == "sess-1",
                "a SessionStart from the launch gap replaced the resumed session")

        let finalized = try #require(try await db.terminals.get(id: terminalID))
        #expect(!finalized.isParked)
        #expect(finalized.claudeSessionID == "sess-1")
        #expect(finalized.transcriptPath == nil)

        let replacementEvent = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "replacement-session",
                transcriptPath: "/tmp/replacement-session.jsonl",
                source: "startup",
                sessionIncarnationID: replacementToken))
        #expect((await router.handle(replacementEvent)).success)
        let attached = try #require(try await db.terminals.get(id: terminalID))
        #expect(attached.claudeSessionID == "replacement-session")
        #expect(attached.transcriptPath == "/tmp/replacement-session.jsonl")
    }

    /// A wake whose replacement launched but whose final un-park write failed
    /// does not report success and broadcasts no un-park. Nor does it abandon
    /// the replacement: the row stays parked naming the running holder's pids,
    /// which startup reconciliation heals.
    @Test func wakeDoesNotReportSuccessWhenPostLaunchMarkerClearFails() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        try await db.writerForTests.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER reject_unpark BEFORE UPDATE ON terminal
                WHEN OLD.hibernatedAt IS NOT NULL AND NEW.hibernatedAt IS NULL
                BEGIN
                    SELECT RAISE(ABORT, 'unpark rejected');
                END;
                """)
        }
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true),
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coord)

        #expect(!(await coord.wake(terminalID: terminalID)).isOk)
        #expect(deltas.snapshot().isEmpty,
                "a wake whose final durable marker clear failed must not broadcast success")
        let launch = try #require(holder.launch(for: terminalID),
                                  "the wake never launched its replacement")
        #expect(holder.launches.count == 1)
        #expect(holder.abandonments.isEmpty,
                "marker failure must not erase an already-running replacement")
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.isParked)
        #expect(after.childPID == launch.handle.childPID,
                "the parked row does not name the replacement it launched")
    }

    // MARK: - Wake: the same-terminal claim
    //
    // Actors are reentrant across awaits and SocketServer runs RPCs
    // concurrently, so `wakesInFlight` claims a terminal before its first
    // suspension: a second wake of the same terminal is refused as in flight
    // rather than launching a second replacement.

    @Test func concurrentWakesForSameTerminalClaimBeforeDatabaseLookup() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parked = try #require(try await db.terminals.get(id: terminalID))
        let deltas = RecordedHibernationDeltas()
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true),
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let holder = await wireHolderDouble(coordinator)
        let databaseGate = BlockingDatabaseWriter()
        let heldWriter = databaseGate.hold(db)
        guard await waitUntil({ databaseGate.isHolding }) else {
            databaseGate.release()
            await heldWriter.value
            Issue.record("database writer gate was never acquired")
            return
        }

        let earlyResults = RecordedWakeResults()
        let first = Task {
            let result = await coordinator.wake(
                terminalID: terminalID,
                initialPrompt: "deliver exactly once")
            earlyResults.append(result)
            return result
        }
        let second = Task {
            let result = await coordinator.wake(
                terminalID: terminalID,
                initialPrompt: "deliver exactly once")
            earlyResults.append(result)
            return result
        }
        let duplicateWasRejectedBeforeDatabaseRelease = await waitUntil {
            earlyResults.snapshot().contains(.inFlight)
        }
        databaseGate.release()
        await heldWriter.value

        let results = await [first.value, second.value]
        #expect(duplicateWasRejectedBeforeDatabaseRelease)
        #expect(results.filter { $0.isOk }.count == 1)
        #expect(results.filter { $0 == .inFlight }.count == 1)
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.sessionIncarnationID != parked.sessionIncarnationID)
        #expect(!after.isParked)
        let replacementLaunches = holder.launches.filter { launch in
            let command = launch.commandLine ?? ""
            return command.contains("claude --resume sess-1")
                && command.contains("deliver exactly once")
        }
        #expect(holder.launches.count == 1)
        #expect(replacementLaunches.count == 1)
        #expect(deltas.snapshot().filter { !$0.hibernated }.count == 1)
    }

    @Test func terminalLookupFailureReleasesSameTerminalClaim() async throws {
        let (db, worktreeID, _) = try await setup()
        let terminalID = UUID()
        let subject = coordinator(db)
        await wireHolderDouble(subject)

        #expect(await subject.wake(terminalID: terminalID) == .notFound)

        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: "claude",
            claudeSessionID: "sess-retry",
            kind: .claude,
            transport: .holder)
        try await db.terminals.setHibernated(
            id: terminalID, sessionID: "sess-retry")
        #expect((await subject.wake(terminalID: terminalID)).isOk)
    }

    /// A wake whose replacement fails to start reports the failure and leaves
    /// the row parked with the session id and transcript it resumes, so the
    /// next wake resumes the same conversation.
    @Test(arguments: [TerminalKind.claude, .codex])
    func launchFailurePreservesResumeIdentityForRetry(kind: TerminalKind) async throws {
        let (db, _, terminalID) = try await setup(kind: kind, transport: .holder)
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/live-wake-retry.jsonl")
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let coord = coordinator(db)
        let holder = await wireHolderDouble(coord)
        holder.failNextSpawn()

        guard case .respawnFailed(let reason) = await coord.wake(terminalID: terminalID) else {
            Issue.record("the first wake must expose the launch failure")
            return
        }
        #expect(reason.contains("starting a holder for this session failed"),
                "the failure does not name the launch: \(reason)")
        let failed = try #require(try await db.terminals.get(id: terminalID))
        #expect(failed.isParked)
        #expect(failed.claudeSessionID == "sess-1")
        #expect(failed.transcriptPath == "/tmp/live-wake-retry.jsonl")
        #expect(holder.failedSpawns == [terminalID])
        #expect(holder.launches.isEmpty)

        #expect((await coord.wake(terminalID: terminalID)).isOk)
        let retried = try #require(try await db.terminals.get(id: terminalID))
        #expect(!retried.isParked)
        #expect(retried.claudeSessionID == "sess-1")
        #expect(retried.transcriptPath == "/tmp/live-wake-retry.jsonl")
        #expect(holder.launches.count == 1)
        let command = holder.launch(for: terminalID)?.commandLine ?? ""
        let resume = kind == .codex ? "resume 'sess-1'" : "--resume sess-1"
        #expect(command.contains(resume), "the retry did not resume sess-1: \(command)")
    }

    /// The wake transcript sync must resolve the ambient (nil-profile)
    /// projects root through the INJECTED `configDirManager` — the seam this
    /// suite relies on to stay out of the real `~/.claude`. A transcript
    /// parked under an old munged dir inside the injected root gets mirrored
    /// into the dir derived from the worktree's current path.
    @Test func wakeSyncsTranscriptViaInjectedConfigDirManager() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-hib-seam-\(UUID().uuidString)", isDirectory: true)
        let host = home.appendingPathComponent("claude-host", isDirectory: true)
        let projects = host.appendingPathComponent("projects", isDirectory: true)
        let oldDir = projects.appendingPathComponent("-old-moved-path", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "{}".write(
            to: oldDir.appendingPathComponent("sess-1.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: host
            ),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent
        )
        await wireHolderDouble(coord)
        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake.isOk)

        // `/tmp/hib-repo` munges to `-tmp-hib-repo` under the injected root.
        let derived = projects.appendingPathComponent("-tmp-hib-repo/sess-1.jsonl")
        #expect(FileManager.default.fileExists(atPath: derived.path),
                "wake must mirror the parked transcript into the derived dir under the injected projects root")
    }

    // MARK: - Profile pre-wake check
    //
    // When a terminal is pinned to a profile that no longer resolves (row
    // deleted or keychain secret missing for .apiKey), the OLD behavior silently
    // fell back to ambient keychain login — resuming on the WRONG account. The
    // new behavior refuses and surfaces `.profileMissing` so the app can offer
    // an explicit default-profile fallback. Both branches covered: missing
    // profile (strict mode) and opt-in fallback (lax mode). Also test that the
    // check only fires when a resolver is present (no regression for daemon
    // without a resolver).

    /// A coordinator with a profile resolver, wired to the holder spawn double
    /// so a parked holder row's wake launches through it.
    private func coordinatorWithResolver(
        _ db: TBDDatabase
    ) async -> (HibernationCoordinator, FakeHolderLaunch) {
        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            modelProfileResolver: ModelProfileResolver(
                profiles: db.modelProfiles, repos: db.repos, config: db.config,
                keychain: { _ in nil }),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        return (coordinator, await wireHolderDouble(coordinator))
    }

    /// Wake refuses when the pinned profile ID no longer exists, returning
    /// `.profileMissing` with the profile id. The row stays parked, retryable.
    @Test func wakeRefusesWhenPinnedProfileMissing() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let bogusProfileID = UUID()
        try await db.terminals.setProfileID(id: terminalID, profileID: bogusProfileID)

        let (coord, holder) = await coordinatorWithResolver(db)
        let wake = await coord.wake(terminalID: terminalID)

        #expect(wake == .profileMissing(profileID: bogusProfileID))
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil, "row must stay parked and retryable")
        #expect(holder.launches.isEmpty, "a refused wake started a holder")
    }

    /// Wake succeeds when `allowDefaultProfileFallback: true` is passed, even
    /// if the pinned profile is missing. The row is un-parked.
    @Test func wakeWithFallbackResumesDespiteMissingProfile() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let bogusProfileID = UUID()
        try await db.terminals.setProfileID(id: terminalID, profileID: bogusProfileID)

        let (coord, _) = await coordinatorWithResolver(db)
        let wake = await coord.wake(terminalID: terminalID, allowDefaultProfileFallback: true)

        #expect(wake.isOk)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil, "row must be un-parked")
    }

    /// Wake succeeds (and doesn't return `.profileMissing`) when the pinned
    /// profile actually resolves. Tests the happy path isn't broken by the check.
    @Test func wakeSucceedsWhenPinnedProfileResolves() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        // Create a real oauth profile (oauth resolves without a keychain secret).
        let profile = try await db.modelProfiles.create(name: "test", kind: .oauth)
        try await db.terminals.setProfileID(id: terminalID, profileID: profile.id)

        let (coord, _) = await coordinatorWithResolver(db)
        let wake = await coord.wake(terminalID: terminalID)

        #expect(wake.isOk)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil, "row must be un-parked")
    }

    @Test func coldProfileSwapWinsBeforeWakeLaunch() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        let oldProfile = try await db.modelProfiles.create(name: "Old", kind: .apiKey)
        let newProfile = try await db.modelProfiles.create(name: "New", kind: .oauth)
        try await db.terminals.setProfileID(id: terminalID, profileID: oldProfile.id)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let keychainGate = BlockingKeychainLookup()
        let wakeResolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            keychain: keychainGate.load)
        let configDirs = isolatedConfigDirManager()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: commands.append)
        let deltas = RecordedStateDeltas()
        let subscriptions = deltas.subscriptions()
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            modelProfileResolver: wakeResolver,
            subscriptions: subscriptions,
            configDirManager: configDirs,
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let swapRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: configDirs,
                leftoverTmuxProbe: .absent),
            tmux: tmux,
            subscriptions: subscriptions,
            configDirManager: configDirs,
            actuationLog: makeTestActuationLog())
        let holder = await wireHolderDouble(coordinator)

        let wake = gateHoldingTask { await coordinator.wake(terminalID: terminalID) }
        guard await waitUntil({ keychainGate.isBlocked }) else {
            keychainGate.release()
            _ = await wake.value
            Issue.record("wake never reached old-profile resolution")
            return
        }
        let swapResponse = await swapRouter.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminalID, newProfileID: newProfile.id, mode: .inPlace)))
        #expect(swapResponse.success)
        let swapped = try #require(try await db.terminals.get(id: terminalID))
        #expect(swapped.isParked)
        #expect(swapped.profileID == newProfile.id)
        let commandCount = commands.snapshot().count
        keychainGate.release()

        #expect(!(await wake.value).isOk)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == swapped)
        #expect(commands.snapshot().count == commandCount,
                "a wake prepared for the old profile must not launch")
        #expect(holder.launches.isEmpty,
                "a wake prepared for the old profile started a holder")
        #expect(deltas.snapshot().filter { delta in
            if case .terminalHibernationChanged = delta { return true }
            return false
        }.isEmpty, "the rejected wake must not broadcast an unpark")
    }

    @Test func wakeWinsBeforeColdProfileSwapCommit() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        let oldProfile = try await db.modelProfiles.create(name: "Old", kind: .oauth)
        let newProfile = try await db.modelProfiles.create(name: "New", kind: .apiKey)
        try await db.terminals.setProfileID(id: terminalID, profileID: oldProfile.id)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let keychainGate = BlockingKeychainLookup()
        let swapResolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            keychain: keychainGate.load)
        let wakeResolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            keychain: { _ in nil })
        let configDirs = isolatedConfigDirManager()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: commands.append)
        let deltas = RecordedStateDeltas()
        let subscriptions = deltas.subscriptions()
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            modelProfileResolver: wakeResolver,
            subscriptions: subscriptions,
            configDirManager: configDirs,
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        let swapRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: configDirs,
                leftoverTmuxProbe: .absent),
            tmux: tmux,
            subscriptions: subscriptions,
            modelProfileResolver: swapResolver,
            configDirManager: configDirs,
            actuationLog: makeTestActuationLog())
        let holder = await wireHolderDouble(coordinator)

        let swapRequest = try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminalID, newProfileID: newProfile.id, mode: .inPlace))
        let swap = gateHoldingTask { await swapRouter.handle(swapRequest) }
        guard await waitUntil({ keychainGate.isBlocked }) else {
            keychainGate.release()
            _ = await swap.value
            Issue.record("cold swap never reached new-profile resolution")
            return
        }

        #expect((await coordinator.wake(terminalID: terminalID)).isOk)
        let woken = try #require(try await db.terminals.get(id: terminalID))
        #expect(!woken.isParked)
        #expect(woken.profileID == oldProfile.id)
        #expect(holder.launches.count == 1)
        let commandCount = commands.snapshot().count
        keychainGate.release()

        #expect(!(await swap.value).success)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == woken)
        #expect(commands.snapshot().count == commandCount)
        #expect(holder.launches.count == 1, "the rejected cold swap started a holder")
        #expect(deltas.snapshot().filter { delta in
            if case .terminalProfileChanged = delta { return true }
            return false
        }.isEmpty, "the rejected cold swap must not broadcast a profile change")
    }

    /// When no resolver is injected, the profile check doesn't fire — even if a
    /// profileID is pinned. This pins that the plain `coordinator(db)` (used by
    /// other tests) is unaffected.
    @Test func wakeIgnoresProfileCheckWhenNoResolverInjected() async throws {
        let (db, _, terminalID) = try await setup(transport: .holder)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let bogusProfileID = UUID()
        try await db.terminals.setProfileID(id: terminalID, profileID: bogusProfileID)

        // Plain coordinator with no resolver.
        let coord = coordinator(db)
        await wireHolderDouble(coord)
        let wake = await coord.wake(terminalID: terminalID)

        #expect(wake.isOk, "without a resolver, no profile check fires")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil)
    }

    // MARK: - Startup reconciliation

    /// A parked row on the tmux transport is left parked at startup, and tmux
    /// is asked nothing about it. TBD no longer reads tmux, so it has no
    /// evidence to un-park one with; such a row wakes once `tbd terminal
    /// migrate` has moved it to the holder.
    @Test func reconcileOnStartupLeavesAParkedTmuxRowParkedWithoutAskingTmux() async throws {
        let (db, _, terminalID) = try await setup(transport: .tmux)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parked = try #require(try await db.terminals.get(id: terminalID))
        let recorded = RecordedTmuxCommands()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true, dryRunRecorder: recorded.append),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)

        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID) == parked,
                "startup changed a parked tmux row")
        #expect(recorded.snapshot().isEmpty,
                "startup asked tmux about a parked row: \(recorded.snapshot())")
    }

    // MARK: - Keep-warm

    @Test func setKeepWarmPersists() async throws {
        let (db, _, terminalID) = try await setup()
        let ok = await coordinator(db).setKeepWarm(terminalID: terminalID, keepWarm: true)
        #expect(ok)
        #expect(try await db.terminals.get(id: terminalID)?.keepWarm == true)
        _ = await coordinator(db).setKeepWarm(terminalID: terminalID, keepWarm: false)
        #expect(try await db.terminals.get(id: terminalID)?.keepWarm == false)
    }

    // MARK: - Broadcast delta contents (snapshot + reason ride the delta)
    //
    // The app applies `terminalHibernationChanged` to its cached row IN PLACE;
    // the parked view materializes on that flip and reads the row's
    // `suspendedSnapshot` once, and wake-on-focus reads `hibernateReason` — so
    // the hibernate delta must CARRY both (a later refetch is too late).

    /// Manual park: the published delta carries the `.manual` reason
    /// alongside `hibernated: true`.
    @Test func manualHibernatePublishesReasonOnDelta() async throws {
        let (db, _, terminalID) = try await setupParkable(activityState: .idle)
        let recorder = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            signaller: Self.endedSessionSignaller(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireParkable(coord)

        let result = await coord.manualHibernate(terminalID: terminalID)
        #expect(result == .ok)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == true)
        #expect(delta?.hibernateReason == .manual,
                "the hibernate delta must carry the park reason — wake-on-focus filters on it before the refetch")
    }

    /// Wake: the un-park delta publishes nil snapshot/reason (the app clears
    /// its cached reason; the DB keeps the snapshot per `clearHibernated`),
    /// although the parked row carried both.
    @Test func wakePublishesNilSnapshotAndReasonOnDelta() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(
            id: terminalID, sessionID: "sess-1",
            snapshot: "FROZEN PANE", reason: .manual)
        let recorder = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireHolderDouble(coord)

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake.isOk)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == false)
        #expect(delta?.suspendedSnapshot == nil)
        #expect(delta?.hibernateReason == nil)
    }

    /// A park and a wake each mint a session incarnation, and the app forwards
    /// Program Status reports under its cached row's: both deltas carry the
    /// incarnation the row holds once each has committed.
    @Test func parkAndWakeDeltasCarryTheCommittedIncarnation() async throws {
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: UUID())
        let recorder = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            signaller: Self.endedSessionSignaller(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireParkable(coord)
        let before = try #require(try await db.terminals.get(id: terminalID)?.sessionIncarnationID)

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID)?.sessionIncarnationID)
        #expect(parked != before)
        #expect(recorder.snapshot().last?.sessionIncarnationID == parked)

        #expect(await coord.wake(terminalID: terminalID).isOk)
        let woken = try #require(try await db.terminals.get(id: terminalID)?.sessionIncarnationID)
        #expect(woken != parked)
        let wakeDelta = try #require(recorder.snapshot().last)
        #expect(wakeDelta.hibernated == false)
        #expect(wakeDelta.sessionIncarnationID == woken)
    }

    /// Keep-warm toggle on an ALREADY PARKED row re-broadcasts
    /// `hibernated: true` — it must carry the row's persisted snapshot and
    /// reason, or the in-place apply would wipe them from the cached row.
    @Test func keepWarmOnParkedRowRebroadcastsRowSnapshotAndReason() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(
            id: terminalID, sessionID: "sess-1",
            snapshot: "FROZEN PANE", reason: .manual)
        let recorder = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)

        let ok = await coord.setKeepWarm(terminalID: terminalID, keepWarm: true)
        #expect(ok)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == true)
        #expect(delta?.keepWarm == true)
        #expect(delta?.suspendedSnapshot == "FROZEN PANE",
                "a keep-warm re-broadcast on a parked row must not wipe the cached snapshot")
        #expect(delta?.hibernateReason == .manual,
                "a keep-warm re-broadcast on a parked row must not wipe the cached reason")
    }

    /// Keep-warm toggle on a LIVE (non-parked) row: `hibernated: false` with
    /// nil snapshot/reason — nothing parked, nothing to carry.
    @Test func keepWarmOnLiveRowPublishesNilSnapshotAndReason() async throws {
        let (db, _, terminalID) = try await setup()
        let recorder = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)

        let ok = await coord.setKeepWarm(terminalID: terminalID, keepWarm: true)
        #expect(ok)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == false)
        #expect(delta?.keepWarm == true)
        #expect(delta?.suspendedSnapshot == nil)
        #expect(delta?.hibernateReason == nil)
    }

    // MARK: - Idle sweep gating

    @Test func sweepDoesNotHibernateWhenFeatureDisabled() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: false, idleMinutes: 1)
        let coord = coordinator(db)
        // Even after many sweeps, disabled means never hibernated.
        await coord.sweep()
        await coord.sweep()
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func sweepDoesNotHibernateRunningTurn() async throws {
        let (db, _, terminalID) = try await setup(activityState: .working)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let coord = coordinator(db)
        for _ in 0..<4 { await coord.sweep() }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "a running turn must never be auto-hibernated")
    }

    @Test func sweepDoesNotHibernateKeepWarm() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle, keepWarm: true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let coord = coordinator(db)
        for _ in 0..<4 { await coord.sweep() }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "a keep-warm session must never be auto-hibernated")
    }

    // MARK: - Idle sweep: the rail's own actuation record

    /// A log at a fresh temp path, plus a coordinator wired to it whose date
    /// seam the test drives, with no holder registry.
    ///
    /// No registry is what lets a unit test reach the sweep's act at all. The
    /// sweep does not arm a holder row whose session this daemon holds no
    /// reader for, and no fixture here can give it one; a daemon with no
    /// registry is not asked that question. Its park is then refused by name
    /// ("this daemon has no holder registry") — after the act's record is
    /// written, which is what these tests are about.
    private func sweepCoordinator(
        _ db: TBDDatabase, logPath: String, dates: TestDateSource
    ) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            now: dates.provider,
            exitPollInterval: .milliseconds(1),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: ActuationLog(path: logPath),
            leftoverTmuxProbe: .absent)
    }

    private func sweepLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-sweep-actuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    private func logRows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    /// Walk one terminal all the way through the sweep's poll/decide sequence:
    /// seed the idle marker, cross the idle window to arm the debounce, then
    /// let the settle window elapse so the rail acts on it. The date seam does
    /// the waiting, so no wall time is spent.
    private func sweepUntilItActs(
        _ coord: HibernationCoordinator, dates: TestDateSource, idleMinutes: Int = 1
    ) async {
        await coord.sweep()                                        // seed idleSince
        dates.advance(by: TimeInterval(idleMinutes) * 60 + 1)
        await coord.sweep()                                        // arm the debounce
        dates.advance(by: HibernationCoordinator.killDebounce + 1)
        await coord.sweep()                                        // act
    }

    /// The idle rail's act. Everything else about the sweep is gating; this is
    /// the one branch that actuates, and it must leave the same
    /// request-then-outcome pair as any RPC surface — under its own rail name,
    /// with no `method`, because no RPC carried it. The outcome is the park's
    /// own answer, a refusal here (see `sweepCoordinator`); the pair's shape
    /// does not depend on it.
    @Test func sweepActWritesItsOwnRailRowAndOutcome() async throws {
        let (db, worktreeID, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = sweepCoordinator(db, logPath: logPath, dates: dates)

        await sweepUntilItActs(coord, dates: dates)

        let written = try logRows(at: logPath)
        #expect(written.count == 2, "exactly one request row and its outcome")
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "hibernate")
        #expect(request["method"] == nil)
        let actor = try #require(request["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "daemon")
        #expect(actor["rail"] as? String == "auto-hibernate")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == worktreeID.uuidString)
        #expect(target["terminal"] as? String == terminalID.uuidString)
        let outcome = try #require(written.last)
        #expect(outcome["kind"] as? String == "outcome")
        #expect(outcome["confirms"] as? String == request["id"] as? String)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["error"] as? String == "this daemon has no holder registry")
    }

    /// Fail-closed on a daemon-internal rail: an unrecordable park is not
    /// attempted. The sweep has no caller to return an error to, so the
    /// property is the park itself — skipped, silently to the user, loudly in
    /// the log. A park attempted here would have been refused and would have
    /// cleared the armed debounce, so the debounce still standing is what
    /// shows the park never started.
    @Test func sweepSkipsTheParkWhenTheRecordIsUnwritable() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        // A path that can never be opened: its parent is a regular file.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-sweep-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let dates = TestDateSource()
        let coord = sweepCoordinator(
            db, logPath: blocker.appendingPathComponent("actuations.jsonl").path, dates: dates)

        await sweepUntilItActs(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "an unrecordable park must not happen")
        #expect(await coord.pendingKillSince[terminalID] != nil,
                "the park was attempted although its record could not be written")
    }

    /// A row still on tmux is never a sweep candidate, however idle: every
    /// park refuses it, so the sweep arms nothing for it and writes no record
    /// — asking would write a request and its refusal on every pass.
    @Test func sweepNeverTriesATmuxRow() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle, transport: .tmux)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = sweepCoordinator(db, logPath: logPath, dates: dates)

        await sweepUntilItActs(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.isParked == false)
        #expect(try logRows(at: logPath).isEmpty, "the sweep tried to park a tmux row")
        #expect(await coord.idleSince[terminalID] == nil)
        #expect(await coord.pendingKillSince[terminalID] == nil)
    }

    // MARK: - Composer-draft park gate
    //
    // The session mod is the park's only guard for an unsent draft. These pin
    // how each row of `docs/specs/2026-10-24-mod-only-park-guard-design.md`,
    // "Which parks go ahead", reaches a real park; `ComposerDraftParkGateTests`
    // states the table itself.

    /// A coordinator that reads session files from `sessionsDir`, wired to
    /// park a `setupParkable` row.
    private func draftGateCoordinator(
        _ db: TBDDatabase, sessionsDir: URL,
        now: @escaping @Sendable () -> Date
    ) async -> HibernationCoordinator {
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            now: now,
            exitPollInterval: .milliseconds(1),
            signaller: Self.endedSessionSignaller(),
            sessionsDir: sessionsDir,
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(),
            leftoverTmuxProbe: .absent)
        await wireParkable(coordinator)
        return coordinator
    }

    /// A session spawned without the feature parks by hand: nothing saved a
    /// draft, and nothing reads the screen to decide.
    @Test func legacySessionParksByHand() async throws {
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: UUID())
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let coord = await draftGateCoordinator(db, sessionsDir: sessionsDir, now: { Date() })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    /// The same session, spawned without the feature, is parked by the
    /// merge-park too: automatic parking does not wait for a mod that was never
    /// spawned.
    @Test func legacySessionIsParkedByMergePark() async throws {
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: UUID())
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let coord = await draftGateCoordinator(db, sessionsDir: sessionsDir, now: { Date() })

        #expect(await coord.hibernateForMerge(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.hibernateReason == .merged)
    }

    /// A session the feature confirms, with its draft saved, parks.
    @Test func confirmedSessionWithASavedDraftParks() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let now = Date()
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation,
            heartbeatAt: now, hasDraft: true)
        let coord = await draftGateCoordinator(db, sessionsDir: sessionsDir, now: { now })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    /// A spawn record and no heartbeat: TBD cannot confirm the draft is
    /// saved, and a manual park goes ahead without asking.
    @Test func unknownSessionParksByHand() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let coord = await draftGateCoordinator(db, sessionsDir: sessionsDir, now: { Date() })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    /// A live, confirmed mod whose saved draft holds content its text lacks
    /// (a collapsed paste) reads unknown, and a manual park of it goes ahead.
    @Test func aDraftNotRestorableParksByHand() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let now = Date()
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation,
            heartbeatAt: now, hasDraft: true, restorable: false)
        let coord = await draftGateCoordinator(db, sessionsDir: sessionsDir, now: { now })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    /// The idle sweep skips an unknown session: nothing parks, and the sweep's
    /// own record names the gate's reason — not the refusal the park would
    /// reach after the gate, so the gate answered first. On a coordinator with
    /// no registry, because the sweep acts on no holder row it holds no reader
    /// for (see `sweepCoordinator`).
    @Test func sweepSkipsAnUnknownSession() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            now: dates.provider,
            exitPollInterval: .milliseconds(1),
            sessionsDir: sessionsDir,
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: ActuationLog(path: logPath),
            leftoverTmuxProbe: .absent)

        await sweepUntilItActs(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
        let written = try logRows(at: logPath)
        #expect(written.count == 2, "exactly one request row and its outcome")
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
        #expect(outcome["error"] as? String
            == ComposerDraftParkGate.skipReason("no-alive-file"))

        // The skip cleared the idle markers, so a sweep past another settle
        // window starts a fresh idle window rather than firing the same skip
        // again. Left armed, this sweep would write a second pair.
        dates.advance(by: HibernationCoordinator.killDebounce + 1)
        await coord.sweep()
        #expect(try logRows(at: logPath).count == 2,
                "the skip re-fired without waiting out a fresh idle window")
    }

    /// The merge-park skips an unknown session the way the sweep does, and
    /// leaves the row as it was.
    @Test func mergeParkSkipsAnUnknownSession() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let before = try #require(try await db.terminals.get(id: terminalID))
        let coord = await draftGateCoordinator(db, sessionsDir: sessionsDir, now: { Date() })

        #expect(await coord.hibernateForMerge(terminalID: terminalID)
            == .notEligible(reason: ComposerDraftParkGate.skipReason("no-alive-file")))
        #expect(try await db.terminals.get(id: terminalID) == before,
                "a skipped merge-park changed the row")
    }

    /// `terminal.hibernate` parks an unknown session on the first request:
    /// there is no confirmation to ask for.
    @Test func hibernateRPCParksAnUnknownSession() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setupParkable(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager(),
                leftoverTmuxProbe: .absent),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            sessionsDir: sessionsDir,
            actuationLog: makeTestActuationLog())
        // The router's coordinator asks the real process table, where the
        // ended session's pids name nothing; its holder must read as gone too.
        await router.hibernationCoordinator.setHolderRegistry(
            makeHolderRegistryDouble(launch: FakeHolderLaunch()))
        await router.hibernationCoordinator.setHolderProcessIsLive { _ in false }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHibernate,
            params: TerminalHibernateParams(terminalID: terminalID)))
        #expect(response.success, "the park was refused: \(response.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    /// An app built when a manual park could carry an override still sends
    /// the key; the params decode and ignore it.
    @Test func hibernateParamsDecodeAnOlderClientsOverride() throws {
        let id = UUID()
        let params = try JSONDecoder().decode(
            TerminalHibernateParams.self,
            from: Data("{\"terminalID\":\"\(id.uuidString)\",\"overrideUnconfirmedDraft\":true}".utf8))
        #expect(params.terminalID == id)
    }

}

/// `terminal.wake` RPC error mapping. This suite builds its own router, wired
/// to a holder spawn double scripted to fail, to drive the `.respawnFailed`
/// path end-to-end.
@Suite("RPCRouter terminal.wake error mapping")
struct RPCRouterWakeErrorMappingTests {

    /// A wake whose replacement cannot be started must surface the REAL
    /// failure over RPC — naming the launch — and never the misleading
    /// "Terminal not found" (the terminal row exists; the launch failed).
    @Test func wakeRespawnFailureIsNotReportedAsTerminalNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager(),
                leftoverTmuxProbe: .absent),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog()
        )
        // A wake refuses to launch into a missing directory, which would be a
        // different failure from the one under test.
        try FileManager.default.createDirectory(
            atPath: "/tmp/hib-repo", withIntermediateDirectories: true)
        let repo = try await db.repos.create(path: "/tmp/hib-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/hib-repo", tmuxServer: "tbd-hib"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", claudeSessionID: "sess-1", kind: .claude,
            transport: .holder
        )
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")
        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        holder.failNextSpawn()

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error != "Terminal not found",
                "a launch failure must not masquerade as a missing terminal row")
        #expect(resp.error?.contains("starting a holder for this session failed") == true,
                "the RPC error must name the failed launch; got: \(resp.error ?? "nil")")
        #expect(holder.failedSpawns == [terminal.id])
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == true,
                "the row must stay parked so a retry can wake it")
    }
}

/// `terminal.wake` prompt delivery over RPC — the safety contract an
/// autonomous caller relies on: a `prompt` reaches ONLY a session this call
/// actually woke (`woken: true`); the idempotent no-op paths report
/// `woken: false` and never deliver it anywhere.
@Suite("RPCRouter terminal.wake prompt delivery")
struct RPCRouterWakePromptDeliveryTests {

    private func makeRouter(db: TBDDatabase, tmux: TmuxManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager(),
                leftoverTmuxProbe: .absent),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeTerminal(
        db: TBDDatabase, transport: TerminalTransport = .holder
    ) async throws -> Terminal {
        let repo = try await db.repos.create(path: "/tmp/wake-prompt-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/wake-prompt-repo", tmuxServer: "tbd-wake-prompt"
        )
        let holder = transport == .holder
        return try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: holder ? "" : "@0", tmuxPaneID: holder ? "" : "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude,
            transport: transport
        )
    }

    /// Parked terminal: the RPC reports `woken: true` and the replacement's
    /// `claude --resume` command carries the prompt as a trailing argv.
    @Test func wakeOnParkedDeliversPromptAndReportsWokenTrue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        try FileManager.default.createDirectory(atPath: "/tmp/wake-prompt-repo", withIntermediateDirectories: true)
        let terminal = try await makeTerminal(db: db, transport: .holder)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")
        let router = makeRouter(db: db, tmux: tmux)
        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "verify live state first")
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        #expect(try resp.decodeResult(TerminalWakeResult.self).woken == true)

        let command = holder.launch(for: terminal.id)?.commandLine ?? ""
        #expect(command.contains("claude --resume sess-1") && command.contains("'verify live state first'"),
                "the launch must carry the prompt as a trailing argv; got: \(command)")
    }

    /// Already-awake terminal (the race an autonomous caller must guard
    /// against): the RPC reports `woken: false`, touches no tmux pane, and the
    /// prompt is delivered NOWHERE — not typed, not pasted, not queued.
    @Test func wakeOnAwakeNoOpsAndWithholdsPrompt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let terminal = try await makeTerminal(db: db)  // NOT hibernated

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "must never appear")
        )
        let resp = await makeRouter(db: db, tmux: tmux).handle(req)
        #expect(resp.success, "the no-op must stay a benign success for idempotent callers")
        #expect(try resp.decodeResult(TerminalWakeResult.self).woken == false)
        #expect(recorded.snapshot().isEmpty,
                "a no-op wake must not touch tmux at all; got: \(recorded.snapshot())")
    }

    /// A live row still on tmux: TBD can neither reach nor stop it, so the
    /// RPC errors with the advice that ends it — not `woken: false`, which
    /// would tell an autonomous caller the session is awake and reachable —
    /// and the prompt goes nowhere.
    @Test func wakeOnALiveTmuxRowErrorsWithTheStillRunningAdvice() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let terminal = try await makeTerminal(db: db, transport: .tmux)  // NOT hibernated

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "must never appear"))
        let resp = await makeRouter(db: db, tmux: tmux).handle(req)

        #expect(!resp.success, "a live tmux row's wake reported success")
        #expect(resp.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: terminal.id, server: "tbd-wake-prompt"),
                "the RPC error is not the still-running advice: \(resp.error ?? "nil")")
        #expect(resp.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(recorded.snapshot().isEmpty,
                "a refused wake must not touch tmux; got: \(recorded.snapshot())")
    }
}

/// Thread-safe collector of `terminalHibernationChanged` deltas published
/// through a real `StateSubscriptionManager` — the same wire the app's
/// subscription receives, so these tests assert the actual encoded payload.
private final class RecordedHibernationDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [TerminalHibernationDelta] = []

    /// A subscription manager whose (kept-alive) subscriber records every
    /// hibernation delta into this collector.
    func subscriptions() -> StateSubscriptionManager {
        let manager = StateSubscriptionManager()
        manager.addSubscriber { [weak self] data in
            if let decoded = try? JSONDecoder().decode(StateDelta.self, from: data),
               case .terminalHibernationChanged(let delta) = decoded {
                self?.record(delta)
            }
            return true
        }
        return manager
    }

    private func record(_ delta: TerminalHibernationDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [TerminalHibernationDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

private final class RecordedStateDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func subscriptions() -> StateSubscriptionManager {
        let manager = StateSubscriptionManager()
        manager.addSubscriber { [weak self] data in
            guard let delta = try? JSONDecoder().decode(StateDelta.self, from: data) else {
                return true
            }
            self?.lock.withLock { self?.deltas.append(delta) }
            return true
        }
        return manager
    }

    func snapshot() -> [StateDelta] {
        lock.withLock { deltas }
    }
}

/// Thread-safe collector for TmuxManager dryRun recorded args.
private final class RecordedTmuxCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
    }
    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}

private final class BlockingDatabaseWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var holding = false

    var isHolding: Bool { lock.withLock { holding } }

    func hold(_ db: TBDDatabase) -> Task<Void, Never> {
        gateHoldingTask { [self] in
            try? await db.writerForTests.writeWithoutTransaction { _ in
                lock.withLock { holding = true }
                releaseGate.waitForGate("same-terminal wake database writer")
            }
        }
    }

    func release() {
        releaseGate.signal()
    }
}

/// The holder spawn double with a hook that runs inside `spawn`, before the
/// launch is answered: after a wake has staged its replacement's incarnation
/// on the row and before it records the holder or un-parks the row.
private final class WakeGapHolderLaunch: HolderSpawnFabricator, @unchecked Sendable {
    let inner = FakeHolderLaunch()
    private let lock = NSLock()
    private var hook: (@Sendable (UUID) async -> Void)?

    func onSpawn(_ body: @escaping @Sendable (UUID) async -> Void) {
        lock.withLock { hook = body }
    }

    /// A real registry whose spawns and teardowns go through this double.
    func registry() -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: FakeHolderLaunch.scratchEnvironment(),
            listTerminals: { [] },
            spawner: nil,
            spawnFabricator: self)
    }

    func spawn(
        terminalID: UUID, launch: HolderLaunchRequest, environment: [String: String]
    ) async throws -> HolderHandle {
        let body = lock.withLock { hook }
        await body?(terminalID)
        return try await inner.spawn(terminalID: terminalID, launch: launch, environment: environment)
    }

    func abandon(terminalID: UUID, handle: HolderHandle) async {
        await inner.abandon(terminalID: terminalID, handle: handle)
    }
}

/// One value a hook records for the test to read once the wake returns.
private final class WakeGapValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? { lock.withLock { stored } }

    func set(_ newValue: Value) {
        lock.withLock { stored = newValue }
    }
}

private final class RecordedWakeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [WakeResult] = []

    func append(_ result: WakeResult) {
        lock.withLock { results.append(result) }
    }

    func snapshot() -> [WakeResult] {
        lock.withLock { results }
    }
}

private final class BlockingKeychainLookup: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var blocked = false

    var isBlocked: Bool { lock.withLock { blocked } }

    var load: @Sendable (String) throws -> String? {
        { [self] _ in
            lock.withLock { blocked = true }
            releaseGate.waitForGate("profile credential lookup")
            return "replacement-secret"
        }
    }

    func release() {
        releaseGate.signal()
    }
}

private final class BlockingRespawnRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var armed = false
    private var blocked = false
    private var match = ""
    private var blockedValue: [String]?
    private var commands: [[String]] = []

    var isBlocked: Bool { lock.withLock { blocked } }
    var blockedCommand: [String]? { lock.withLock { blockedValue } }

    var record: @Sendable ([String]) -> Void {
        { [self] command in
            let shouldBlock = lock.withLock { () -> Bool in
                commands.append(command)
                guard armed,
                      !blocked,
                      command.joined(separator: " ").contains(match) else {
                    return false
                }
                blocked = true
                blockedValue = command
                return true
            }
            if shouldBlock {
                releaseGate.waitForGate("hibernation wake preparation")
            }
        }
    }

    func arm(matching match: String) {
        lock.withLock {
            armed = true
            blocked = false
            self.match = match
            blockedValue = nil
        }
    }

    func release() {
        releaseGate.signal()
    }

    func snapshot() -> [[String]] {
        lock.withLock { commands }
    }
}
