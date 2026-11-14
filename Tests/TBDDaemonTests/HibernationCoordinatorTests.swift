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

/// `.clockDriven` is applied at SUITE level even though only the park-poll
/// tests below drive an `EventDrivenTestClock`. The trait is a five-minute time
/// limit — a hang-catcher, not a perf budget — so it costs the other tests
/// nothing and it catches the one failure mode virtual time introduces here (a
/// test-clock sleep nobody advances hangs forever instead of going red).
/// `.serialized` is deliberately NOT applied: a handful of clock-driven tests
/// out of ~35 don't justify serializing the whole suite.
@Suite("HibernationCoordinator", .clockDriven)
struct HibernationCoordinatorTests {

    /// In-memory DB + repo + worktree + an idle Claude terminal. A `.holder`
    /// row carries the empty tmux coordinates every holder row carries.
    private func setup(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude,
        sessionIncarnationID: UUID? = nil,
        transport: TerminalTransport = .tmux
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
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
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

    /// Moves a row a tmux park left parked onto the holder transport, the way
    /// `tbd terminal migrate` does, so the test can wake it through the holder
    /// spawn double. Only the transport and the tmux coordinates change.
    @discardableResult
    private func moveParkedRowToHolder(_ db: TBDDatabase, _ terminalID: UUID) async throws -> Terminal {
        let parked = try #require(try await db.terminals.get(id: terminalID))
        return try #require(try await db.terminals.setParkedTransport(
            id: terminalID,
            expectedState: TerminalReplacementSnapshot(terminal: parked),
            transport: .holder))
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
            sessionTitles: titles, actuationLog: makeTestActuationLog())
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
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
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
            codexHomeEnsurer: { Issue.record("home preparation must follow executable resolution"); throw MissingExecutable() })
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
            codexExecutableResolver: { gate.record(["prepare-codex"]); return "/opt/acme/bin/codex" })
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
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.isHibernated == true)
    }

    /// A park writes `.idle` and a wake resets the column to `.unknown` for
    /// the incarnation it mints; no activity delta announces either, so each
    /// one's hibernation delta carries the activity columns it committed, read
    /// back from the row. The park runs on tmux; the parked row then moves to
    /// the holder, where a wake runs.
    @Test func parkAndWakeDeltasCarryTheCommittedActivityColumns() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true),
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await wireHolderDouble(coord)

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID))
        let parkActivity = try #require(deltas.snapshot().last { $0.hibernated }?.activity)
        #expect(parkActivity.activityState == .idle)
        #expect(parkActivity.activityStateSource == .database)
        #expect(parkActivity.activityStateObservedAt == parked.activityStateObservedAt)
        #expect(parkActivity.activityStateOrderObservedAt == parked.activityStateOrderObservedAt)

        try await moveParkedRowToHolder(db, terminalID)
        #expect(await coord.wake(terminalID: terminalID).isOk)
        let awake = try #require(try await db.terminals.get(id: terminalID))
        let wakeActivity = try #require(deltas.snapshot().last { !$0.hibernated }?.activity)
        #expect(awake.activityState == .unknown)
        #expect(wakeActivity.activityState == .unknown)
        #expect(wakeActivity.activityStateSource == .derived)
        #expect(wakeActivity.activityStateObservedAt == awake.activityStateObservedAt)
        #expect(wakeActivity.activityStateOrderObservedAt == awake.activityStateOrderObservedAt)
    }

    @Test func hibernateRespawnRejectsPreReplacementSessionStart() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorded.append)
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/hibernation-old-session.jsonl")
        let before = try #require(try await db.terminals.get(id: terminalID))

        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID))
        #expect(parked.sessionIncarnationID != before.sessionIncarnationID)
        #expect(parked.tmuxWindowID == before.tmuxWindowID)
        #expect(parked.tmuxPaneID == before.tmuxPaneID)
        #expect(parked.label == before.label)
        #expect(parked.claudeSessionID == "sess-1")
        #expect(parked.transcriptPath == "/tmp/hibernation-old-session.jsonl")
        #expect(parked.sessionOrderObservedAt == nil)
        #expect(parked.codexTranscriptBoundaryOffset == nil)
        let parkedToken = try #require(parked.sessionIncarnationID)
        let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
        let shellRespawn = try #require(recorded.snapshot().last { call in
            call.contains("respawn-window")
        }?.last)
        #expect(shellRespawn.contains(
            "TBD_TERMINAL_INCARNATION_ID='\(parkedToken.uuidString)'"))
        #expect(shellRespawn.contains(
            "TBD_CLI_PATH=\(shellEscape(matchedCLIPath))"))

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

    @Test func hibernateDoesNotReportSuccessWhenPostShellCommitFails() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorder = BlockingRespawnRecorder()
        let deltas = RecordedHibernationDeltas()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorder.record)
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        recorder.arm(matching: "; \(shell)")
        let hibernate = gateHoldingTask {
            await coord.manualHibernate(terminalID: terminalID)
        }
        guard await waitUntil({ recorder.isBlocked }) else {
            recorder.release()
            _ = await hibernate.value
            Issue.record("hibernate never reached the shell respawn")
            return
        }
        #expect(recorder.blockedCommand?.last?.hasSuffix(shell) == true)
        try await db.terminals.delete(id: terminalID)
        recorder.release()

        let result = await hibernate.value
        #expect(result != .ok)
        #expect(deltas.snapshot().isEmpty,
                "a failed durable park must not broadcast hibernated=true")
    }

    @Test func firstHibernateRespawnFailureKeepsOldTokenForStartupRecovery() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/hibernate-first-respawn.jsonl")
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parkedForToken = try #require(try await db.terminals.get(id: terminalID))
        let oldToken = try #require(try await db.terminals.prepareHibernatedAgentRespawn(
            id: terminalID,
            expectedState: TerminalReplacementSnapshot(terminal: parkedForToken),
            at: Date(timeIntervalSinceReferenceDate: 1)))
        try await db.terminals.clearHibernated(id: terminalID)
        try await db.terminals.setActivityState(
            id: terminalID, activityState: .idle, source: .derived)
        let failures = FailRespawnOnAttempt(1)
        let deltas = RecordedHibernationDeltas()
        let failingTmux = TmuxManager(
            dryRun: true,
            dryRunRespawnWindowError: failures.error)
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: failingTmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        #expect(await coordinator.manualHibernate(terminalID: terminalID) != .ok)
        let failed = try #require(try await db.terminals.get(id: terminalID))
        #expect(failed.isParked)
        #expect(failed.sessionIncarnationID == oldToken)
        #expect(failed.pendingSessionIncarnationID != nil)
        #expect(failed.claudeSessionID == "sess-1")
        #expect(failed.transcriptPath == "/tmp/hibernate-first-respawn.jsonl")
        #expect(failed.activityState == .idle)
        #expect(failed.activityStateSource == .database)
        #expect(failed.activityStateObservedAt != nil)
        #expect(failed.activityStateOrderObservedAt == failed.activityStateObservedAt)
        #expect(deltas.snapshot().isEmpty)

        let liveTmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: terminalID.uuidString) })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: liveTmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: liveTmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        await router.hibernationCoordinator.reconcileOnStartup()
        let unparked = try #require(try await db.terminals.get(id: terminalID))
        #expect(!unparked.isParked)
        #expect(unparked.sessionIncarnationID == oldToken)
        #expect(unparked.pendingSessionIncarnationID == nil)

        let oldProcessHook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "still-live-session",
                transcriptPath: "/tmp/still-live-session.jsonl",
                source: "startup",
                sessionIncarnationID: oldToken))
        #expect((await router.handle(oldProcessHook)).success)
        let recovered = try #require(try await db.terminals.get(id: terminalID))
        #expect(recovered.claudeSessionID == "still-live-session")
        #expect(recovered.transcriptPath == "/tmp/still-live-session.jsonl")
        #expect(recovered.sessionIncarnationID == oldToken)
    }

    @Test func secondHibernateRespawnFailureLeavesInertPaneWithNewToken() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parkedForToken = try #require(try await db.terminals.get(id: terminalID))
        let oldToken = try #require(try await db.terminals.prepareHibernatedAgentRespawn(
            id: terminalID,
            expectedState: TerminalReplacementSnapshot(terminal: parkedForToken),
            at: Date(timeIntervalSinceReferenceDate: 1)))
        try await db.terminals.clearHibernated(id: terminalID)
        try await db.terminals.setActivityState(
            id: terminalID, activityState: .idle, source: .derived)
        let oldProcess = try #require(try await db.terminals.get(id: terminalID))
        let failures = FailRespawnOnAttempt(2)
        let recorded = RecordedTmuxCommands()
        let deltas = RecordedHibernationDeltas()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorded.append,
            dryRunRespawnWindowError: failures.error)
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        #expect(await coordinator.manualHibernate(terminalID: terminalID) != .ok)
        let failed = try #require(try await db.terminals.get(id: terminalID))
        let newToken = try #require(failed.sessionIncarnationID)
        #expect(failed.isParked)
        #expect(newToken != oldToken)
        #expect(deltas.snapshot().isEmpty)
        let respawns = recorded.snapshot()
            .filter { $0.contains("respawn-window") }
            .compactMap(\.last)
        #expect(respawns.count == 2)
        #expect(respawns.first?.contains("exec /usr/bin/tail -f /dev/null") == true)
        #expect(respawns.last?.contains(
            "TBD_TERMINAL_INCARNATION_ID='\(newToken.uuidString)'") == true)

        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let staleHook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "stale-session",
                transcriptPath: "/tmp/stale-session.jsonl",
                source: "startup",
                sessionIncarnationID: oldProcess.sessionIncarnationID))
        #expect((await router.handle(staleHook)).success)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged.sessionIncarnationID == newToken)
        #expect(unchanged.claudeSessionID == failed.claudeSessionID)
        #expect(unchanged.transcriptPath == failed.transcriptPath)
    }

    @Test func wakeCannotOvertakeStagedHibernation() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        let clock = EventDrivenTestClock()
        // A Claude process the park finds under the pane and signals, still
        // running when the park polls, so the park holds its staged state on
        // the injected clock while the wake races it.
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorded.append,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPanePID: { _, _ in String(Self.shellPID) })
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            exitPollAttempts: 1,
            exitPollInterval: .milliseconds(200),
            clock: clock,
            signaller: FakeProcessSignaller(),
            paneProcessInspector: FakeInspector(claudePID: Self.claudePID),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        let hibernate = Task {
            await coordinator.manualHibernate(terminalID: terminalID)
        }
        try await clock.requireSleeperArmed()
        #expect(try await db.terminals.get(id: terminalID)?.isParked == true)

        #expect(await coordinator.wake(terminalID: terminalID) == .inFlight)
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(200))
        #expect(await hibernate.value == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isParked == true)
        let respawns = recorded.snapshot().filter { $0.contains("respawn-window") }
        #expect(respawns.count == 2)
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
        // Not an assertion that the wake SUCCEEDS — this row is awake and its
        // tmux pane is a dry-run fiction. What the release has to restore is
        // that a wake is answered on its merits again rather than deflected.
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

    @Test func queuedHibernateRefusesActivityThatStartsWhileWaitingForServerLock() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let queued = QueuedParkSignal()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.setTmuxParkWillAwaitServerLock(queued.signal)
        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }

        let hibernate = gateHoldingTask {
            await coord.manualHibernate(terminalID: terminalID)
        }
        await queued.waitUntilQueued()
        await Task.megaYield()
        let workingAt = Date(timeIntervalSinceReferenceDate: 50)
        try await db.terminals.setActivityState(
            id: terminalID,
            activityState: .working,
            source: .hookEvent("task_started"),
            observedAt: workingAt)
        let working = try #require(try await db.terminals.get(id: terminalID))
        let commandCount = commands.snapshot().count
        serverLock.release()
        _ = await holder.value

        #expect(await hibernate.value != .ok)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == working)
        #expect(commands.snapshot().count == commandCount)
        #expect(deltas.snapshot().isEmpty)
    }

    @Test func queuedAutomaticHibernateRestartsIdleWindowAfterCompletedTurn() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let queued = QueuedParkSignal()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append)
        let deltas = RecordedHibernationDeltas()
        let dates = TestDateSource()
        let originallyIdle = try #require(try await db.terminals.get(id: terminalID))
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            now: dates.provider,
            exitPollAttempts: 1,
            exitPollInterval: .milliseconds(1),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: ActuationLog(path: try sweepLogPath()))
        await coord.setTmuxParkWillAwaitServerLock(queued.signal)

        await coord.sweep()
        dates.advance(by: 61)
        await coord.sweep()
        dates.advance(by: HibernationCoordinator.killDebounce + 1)

        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }
        let sweep = gateHoldingTask { await coord.sweep() }
        await queued.waitUntilQueued()
        await Task.megaYield()

        dates.advance(by: 1)
        try await db.terminals.setActivityState(
            id: terminalID,
            activityState: .working,
            source: .hookEvent("task_started"),
            observedAt: dates.now)
        dates.advance(by: 1)
        try await db.terminals.setActivityState(
            id: terminalID,
            activityState: .idle,
            source: .hookEvent("stop"),
            observedAt: dates.now)
        let newlyIdle = try #require(try await db.terminals.get(id: terminalID))
        #expect(TerminalReplacementSnapshot(terminal: originallyIdle).matches(newlyIdle))
        let commandCount = commands.snapshot().count
        serverLock.release()
        _ = await holder.value
        _ = await sweep.value

        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == newlyIdle)
        #expect(!unchanged.isParked)
        #expect(commands.snapshot().count == commandCount)
        #expect(deltas.snapshot().isEmpty)
    }

    @Test func queuedHibernateRevalidatesTranscriptTailAfterServerLock() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-hibernate-tail-\(UUID().uuidString).jsonl")
        try Data("{\"type\":\"result\"}\n".utf8).write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: transcript.path)
        let queued = QueuedParkSignal()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.setTmuxParkWillAwaitServerLock(queued.signal)
        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }

        let before = try #require(try await db.terminals.get(id: terminalID))
        let hibernate = gateHoldingTask {
            await coord.manualHibernate(terminalID: terminalID)
        }
        await queued.waitUntilQueued()
        await Task.megaYield()
        try Data("{\"type\":\"assistant\"".utf8).write(to: transcript)
        let commandCount = commands.snapshot().count
        serverLock.release()
        _ = await holder.value

        #expect(await hibernate.value == .notEligible(
            reason: "Transcript is mid-write; try again shortly"))
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == before)
        #expect(commands.snapshot().count == commandCount)
        #expect(deltas.snapshot().isEmpty)
    }

    @Test func manualHibernateIgnoresKeepWarm() async throws {
        // Manual hibernate BYPASSES keep-warm (the user asked explicitly).
        let (db, _, terminalID) = try await setup(activityState: .idle, keepWarm: true)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
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
        let (db, _, terminalID) = try await setup()
        _ = await coordinator(db).manualHibernate(terminalID: terminalID)
        let second = await coordinator(db).manualHibernate(terminalID: terminalID)
        #expect(second == .alreadyHibernated)
    }

    // MARK: - Park path: poll pacing
    //
    // Every park ends by SIGTERM, then polls `exitPollAttempts` ×
    // `exitPollInterval` (production: 15 × 200ms ≈ 3s) for Claude to leave
    // before the respawn ends it. The pacing is injected and its delay runs on
    // an injected `clock`; the ending's branches are pinned under "Every park
    // ends by signal" below.

    /// Pins the SHIPPED poll windows, which the injected-pacing tests
    /// deliberately do not run: 15 × 200ms ≈ 3s for the tmux park's wait after
    /// its SIGTERM, and the two holder-park budgets that ride the same
    /// interval. Making the pacing injectable must not quietly change how long
    /// production waits for a claude that is shutting down before it kills
    /// one.
    @Test func defaultPollPacingIsFifteenTimesTwoHundredMillis() async throws {
        let (db, _, _) = try await setup()
        let coord = coordinator(db)
        #expect(coord.exitPollAttempts == 15)
        #expect(coord.exitPollInterval == .milliseconds(200))
        #expect(coord.exitPollInterval * coord.exitPollAttempts == .seconds(3),
                "the shipped verify-exit window must stay ~3s")
        // The holder park's middle rung rides the same interval: 25 checks
        // after a `SIGTERM`, i.e. five seconds for a session to run its Stop
        // hooks, tear down its MCP children and flush the transcript it is
        // mid-write on. It is the rung that keeps the holder park from being
        // harsher than the tmux one, so shortening it is a behaviour change
        // rather than a tuning nudge.
        #expect(coord.holderTerminateAttempts == 25)
        #expect(coord.exitPollInterval * coord.holderTerminateAttempts == .seconds(5),
                "the shipped SIGTERM window must stay ~5s")
        // The escalation budget after it is a different budget again: five
        // more checks once `abandon` has SIGKILLed the job, i.e. one second for
        // a dead process to leave the process table. Neither of the two above
        // waits for that, and it waits for neither of them.
        #expect(coord.holderEscalationAttempts == 5)
        #expect(coord.exitPollInterval * coord.holderEscalationAttempts == .seconds(1),
                "the shipped holder escalation window must stay ~1s")
    }

    /// The ANSI pane snapshot captured before the kill is persisted into
    /// `suspendedSnapshot` (reused column) so the app can show the frozen pane as
    /// a backdrop while parked. Ported from the old Suspend snapshot-capture test.
    @Test func parkPersistsPaneSnapshot() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        // Inject a non-empty ANSI capture via the capturePane dryRun hook; the
        // park path reads it through `capturePaneWithAnsi` (which consults the
        // same hook in dryRun) and must persist it into `suspendedSnapshot`.
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "FROZEN PANE" })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

        let result = await coord.manualHibernate(terminalID: terminalID)
        #expect(result == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.suspendedSnapshot == "FROZEN PANE",
                "the captured pane must persist into suspendedSnapshot")
        #expect(after?.hibernatedAt != nil)
    }

    // MARK: - Park cancels the scheduled auto-resume

    /// A hibernated terminal must never carry a scheduled auto-resume — the
    /// Claude process is dead, so a resume firing later would type "continue"
    /// into a bare shell. The park write (`setHibernated`, reached here via
    /// `performHibernate`) cancels the pending row and clears the
    /// `pendingResumeAt` mirror atomically; wake does NOT resurrect it.
    @Test func parkCancelsScheduledResumeAndWakeDoesNotResurrect() async throws {
        let (db, worktreeID, terminalID) = try await setup(activityState: .idle)
        let resume = ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            claudeSessionID: "sess-1",
            resetsAt: Date().addingTimeInterval(60),
            fireAt: Date().addingTimeInterval(90),
            limitType: "session", rawMessage: "You've hit your session limit")
        _ = try await db.scheduledResumes.insertPending(resume)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt != nil)

        let coord = coordinator(db)
        let parked = await coord.manualHibernate(terminalID: terminalID)
        #expect(parked == .ok)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil,
                "parking must cancel the pending scheduled resume")
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil,
                "the pendingResumeAt mirror must clear with the park write")

        // Only a holder row wakes: move the parked row there first.
        await wireHolderDouble(coord)
        try await moveParkedRowToHolder(db, terminalID)
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
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: false, idleMinutes: 30)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok, "manual hibernate must not depend on the auto switch")
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    // MARK: - Wake
    //
    // Only a holder row wakes; a parked tmux row refuses before anything is
    // touched (`TmuxWakeBackstopTests`). The wakes below run on holder rows,
    // through the holder spawn double.

    /// The park runs on tmux and mints the parked incarnation; the parked row
    /// then moves to the holder, where the wake mints the replacement's.
    @Test func wakeRespawnPreservesRetryIdentityAndRejectsParkedIncarnation() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/hibernation-wake-old-session.jsonl")
        let coord = coordinator(db)
        await wireHolderDouble(coord)
        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try await moveParkedRowToHolder(db, terminalID)

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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
        let result = await coord.wake(terminalID: terminalID)
        #expect(result == .notHibernated)
        #expect(recorded.snapshot().isEmpty,
                "a non-parked wake must not touch tmux; got: \(recorded.snapshot())")
    }

    // MARK: - Unparked rows: "already awake" must be a provable claim

    /// The bug this section exists to fix. The row is unparked — TBD believes
    /// the terminal is awake — but its pane is gone. The old answer was an
    /// unconditional `.notHibernated` ("already awake, no-op"), a claim about a
    /// live session made without ever asking tmux.
    @Test func wakeOnUnparkedRowWithMissingPaneReportsSessionGone() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in .absent })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID)
                == .sessionGone(paneID: "%0", detail: .paneMissing))
    }

    /// A pane that outlived its process (`remain-on-exit`) is just as dishonest
    /// a basis for "already awake" as a missing one — the row refers to a shell.
    @Test func wakeOnUnparkedRowWithExitedProcessReportsSessionGone() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneSendTarget: { _, _ in .dead(terminalID: terminalID.uuidString) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID)
                == .sessionGone(paneID: "%0", detail: .processExited))
    }

    /// Pane-id reuse (#384): the row's coordinate now names a live STRANGER.
    /// Someone else's healthy pane is not evidence this session is alive.
    @Test func wakeOnUnparkedRowWhosePaneBelongsToAnotherTerminalReportsSessionGone() async throws {
        let (db, _, terminalID) = try await setup()
        let stranger = UUID().uuidString
        let tmux = TmuxManager(dryRun: true,
                               dryRunPaneSendTarget: { _, _ in .live(terminalID: stranger) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID)
                == .sessionGone(paneID: "%0",
                                detail: .paneBelongsToAnotherTerminal(actualTerminalID: stranger)))
    }

    /// Reporting only — `.sessionGone` must never respawn or recreate. Making
    /// tmux authoritative over the parked flag is the separate, riskier change
    /// this deliberately stops short of (#586).
    @Test func sessionGoneReportsWithoutMutatingTmuxOrTheRow() async throws {
        let (db, _, terminalID) = try await setup()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) },
                               dryRunPaneSendTarget: { _, _ in .absent })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        _ = await coord.wake(terminalID: terminalID)
        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(!joined.contains { $0.contains("respawn-window") || $0.contains("new-window") },
                "sessionGone must not respawn or recreate anything; got: \(joined)")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false)
        #expect(after?.tmuxPaneID == "%0")
    }

    /// The safety property that makes this shippable without a spec. A probe
    /// that merely FAILED proves nothing, so it must keep the benign historical
    /// answer — never be read as a dead terminal. tmux calls fail spuriously
    /// exactly when the box is loaded enough for the session to be alive.
    @Test func unreadablePaneProbeFailsClosedToBenignNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in
            throw TmuxError.timedOut(command: "tmux list-panes", timeout: .seconds(15))
        })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID) == .notHibernated)
    }

    /// A consultation that RAN and reached no tmux server is not a
    /// disagreement: nothing answered, so nothing disagreed. Reporting
    /// `.sessionGone` would tell the caller its live session is gone on the
    /// strength of a failed read — the exact conflation this change removes.
    @Test func unreachableServerIsNotReportedAsSessionGone() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in .unreachable })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        let result = await coord.wake(terminalID: terminalID)
        #expect(result == .paneUnreadable(paneID: "%0", server: "tbd-hib"))
        // Named explicitly, because "not sessionGone" is the whole property and
        // a future refactor could reintroduce it through a different detail.
        if case .sessionGone = result {
            Issue.record("an unreachable server must never be reported as sessionGone")
        }
        // And the row is left exactly as it was — reporting, never repairing.
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false)
        #expect(after?.tmuxPaneID == "%0")
    }

    /// The record must not claim a refusal either: nothing was decided, the
    /// transport simply did not answer.
    @Test func unreachableServerWakeIsRecordedAsTransportFailure() {
        #expect(ActuationOutcome.classify(
            WakeResult.paneUnreadable(paneID: "%0", server: "tbd-hib")) == .transportFailed)
        #expect(ActuationOutcome.classify(
            WakeResult.paneUnreadable(paneID: "%0", server: "tbd-hib")).reason == nil)
    }

    /// A live pane carrying no identity is left alone — refusal requires
    /// POSITIVE disagreement, the same rule the send path follows.
    @Test func wakeOnUnparkedRowWithLivePaneStaysBenignNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(dryRun: true,
                               dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID) == .notHibernated)
    }

    /// A pane that answers with THIS terminal's own id agrees, so the row's
    /// "awake" is supported and the benign no-op stands.
    @Test func wakeOnUnparkedRowWhosePaneAgreesStaysBenignNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in
            .live(terminalID: terminalID.uuidString)
        })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID) == .notHibernated)
    }

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
            actuationLog: makeTestActuationLog())
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
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: recorded.append,
            dryRunPanePID: { _, _ in "4242" })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            paneProcessInspector: FakeInspector(claudePID: nil, foregroundPID: 4242),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        let result = await coord.wake(terminalID: terminalID)

        #expect(result == .notAClaudeTab(kind: .shell),
                "a shell tab was woken as a Claude session: \(result)")
        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(!joined.contains { $0.contains("claude --resume") },
                "the wake resumed a Claude session in a shell tab: \(joined)")
        #expect(!joined.contains { $0.contains("respawn-window") || $0.contains("new-window") },
                "the refused wake touched the pane: \(joined)")
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
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorded.append)
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

        let result = await coord.parkForProfileSwap(terminalID: terminalID)

        #expect(result == .notEligible(reason: ClaudeResumeDecision.notAClaudeTabReason(.shell)),
                "expected the park to refuse a shell tab, got \(result)")
        #expect(try await db.terminals.get(id: terminalID)?.isParked == false)
        #expect(recorded.snapshot().filter { $0.contains("respawn-window") }.isEmpty,
                "the refused park replaced the pane")
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
        let (db, _, terminalID) = try await setup(sessionID: "sess-1", kind: kind)
        // `stampSessionExited` refuses this tab now, so the earlier build's
        // stamp is written the way any park is.
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: .exited)
        let recorded = RecordedTmuxCommands()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true, dryRunRecorder: recorded.append),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

        await coord.reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(!after.isParked, "a \(kind.rawValue) tab stayed behind an exit stamp no wake can lift")
        #expect(after.hibernateReason == nil)
        #expect(after.claudeSessionID == "sess-1")
        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(!joined.contains { $0.contains("respawn-window") || $0.contains("claude --resume") },
                "lifting the stamp touched the pane: \(joined)")
    }

    /// The mirror: the repair is for that one stale stamp. A Claude tab's exit
    /// stamp is what its wake resumes from, and a shell tab parked for any
    /// other reason had its process replaced, so both stay parked.
    @Test(arguments: [TerminalKind.claude, .shell])
    func startupLeavesEveryOtherParkAlone(kind: TerminalKind) async throws {
        let (db, _, terminalID) = try await setup(sessionID: "sess-1", kind: kind)
        let reason: HibernateReason = kind == .claude ? .exited : .auto
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", reason: reason)
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

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
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

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
            actuationLog: makeTestActuationLog())
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
            actuationLog: makeTestActuationLog())
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
                configDirManager: isolatedConfigDirManager()),
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
            actuationLog: makeTestActuationLog())
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

    // MARK: - Wake: the same-terminal claim, and the server-resource lock
    //
    // Actors are reentrant across awaits and SocketServer runs RPCs
    // concurrently, so `wakesInFlight` claims a terminal before its first
    // suspension: a second wake of the same terminal is refused as in flight
    // rather than launching a second replacement. The lock tests cover the
    // tmux server-resource lock the tmux park takes: same key serializes,
    // different keys don't.

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
            actuationLog: makeTestActuationLog())
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

    /// Focused lock-helper semantics: a second acquirer of the SAME key waits
    /// until the holder releases; a DIFFERENT key proceeds immediately. Driven
    /// by AsyncStream handshakes (no sleeps): A provably holds the lock, C
    /// (other key) completes while A holds it, B (same key) only runs after A.
    @Test func serverResourceLockSerializesSameKeyAndNotDifferentKeys() async throws {
        let tmux = TmuxManager(dryRun: true)
        let events = RecordedTmuxCommands()
        let (enteredStream, enteredCont) = AsyncStream.makeStream(of: Void.self)
        let (releaseStream, releaseCont) = AsyncStream.makeStream(of: Void.self)

        let taskA = Task {
            await tmux.withServerResourceLock(server: "s1") {
                enteredCont.yield()
                var it = releaseStream.makeAsyncIterator()
                _ = await it.next()
                events.append(["A-end"])
            }
        }
        // Wait until A provably HOLDS the s1 lock.
        var enteredIt = enteredStream.makeAsyncIterator()
        _ = await enteredIt.next()

        let taskB = Task {
            await tmux.withServerResourceLock(server: "s1") { events.append(["B-ran"]) }
        }
        let taskC = Task {
            await tmux.withServerResourceLock(server: "s2") { events.append(["C-ran"]) }
        }
        // A different key must proceed while s1 is held...
        _ = await taskC.value
        // ...and the same key must still be waiting.
        #expect(!events.snapshot().contains(["B-ran"]),
                "same-key acquirer must wait for the holder to release")

        releaseCont.yield()
        _ = await taskB.value
        _ = await taskA.value
        let snapshot = events.snapshot()
        guard let aEnd = snapshot.firstIndex(of: ["A-end"]),
              let bRan = snapshot.firstIndex(of: ["B-ran"]) else {
            Issue.record("expected both A-end and B-ran to have run; got \(snapshot)")
            return
        }
        #expect(aEnd < bRan, "B must only run after A releases; got \(snapshot)")
    }

    @Test func serverResourceLockReleasesAfterThrow() async {
        struct ExpectedFailure: Error {}
        let tmux = TmuxManager(dryRun: true)

        await #expect(throws: ExpectedFailure.self) {
            try await tmux.withServerResourceLock(server: "s1") {
                throw ExpectedFailure()
            }
        }

        let nextAcquirerRan = await tmux.withServerResourceLock(server: "s1") { true }
        #expect(nextAcquirerRan, "a thrown operation must structurally release the server lock")
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
            actuationLog: makeTestActuationLog()
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
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
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
            actuationLog: makeTestActuationLog())
        let swapRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: configDirs),
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
            actuationLog: makeTestActuationLog())
        let swapRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: configDirs),
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

    /// `reconcileOnStartup` clears a stale parked timestamp for a terminal whose
    /// claude is actually still alive (daemon crashed mid-park). Uses the
    /// paneCurrentCommand hook to report a live claude and windowExists (default
    /// dryRun = alive). Covers BOTH the authoritative and legacy columns via
    /// `clearHibernated` nulling both.
    @Test func reconcileOnStartupClearsStaleParkedForLiveClaude() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parked = try #require(try await db.terminals.get(id: terminalID))
        #expect(parked.hibernatedAt != nil)

        // Pane still runs claude (reported as its version string) and answers
        // with this row's own id → the parked state is stale and must be
        // cleared.
        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: terminalID.uuidString) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        let reconciled = try #require(try await db.terminals.get(id: terminalID))
        #expect(reconciled.hibernatedAt == nil,
                "a still-running claude must have its stale parked timestamp cleared")
        #expect(reconciled.claudeSessionID == parked.claudeSessionID)
        #expect(reconciled.transcriptPath == parked.transcriptPath)
        #expect(reconciled.sessionIncarnationID == parked.sessionIncarnationID)
        // The park's `.idle` described a parked row, not the Claude found still
        // running, and on tmux no report replaces it: the un-park resets it,
        // so neither the idle sweep nor merge-park parks a turn in flight.
        #expect(parked.activityState == .idle)
        #expect(reconciled.activityState == .unknown)
        #expect(reconciled.activityStateSource == .derived)
        #expect(HibernationGate.decideForMerge(terminal: reconciled) == .unknownActivity)
    }

    @Test func reconcileOnStartupPreservesSessionStartAcceptedWhileReplacementStayedParked() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parkedBeforeReplacement = try #require(
            try await db.terminals.get(id: terminalID))
        let replacementToken = try #require(
            try await db.terminals.prepareHibernatedAgentRespawn(
                id: terminalID,
                expectedState: TerminalReplacementSnapshot(
                    terminal: parkedBeforeReplacement),
                at: Date(timeIntervalSinceReferenceDate: 10)))
        let staged = try #require(try await db.terminals.get(id: terminalID))
        #expect(staged.isParked)
        #expect(staged.sessionIncarnationID == replacementToken)

        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: terminalID.uuidString) })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let replacementHook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "replacement-session",
                transcriptPath: "/tmp/replacement-session.jsonl",
                source: "startup",
                sessionIncarnationID: replacementToken))
        #expect((await router.handle(replacementHook)).success)

        let attachedWhileParked = try #require(try await db.terminals.get(id: terminalID))
        #expect(attachedWhileParked.isParked)
        #expect(attachedWhileParked.claudeSessionID == "replacement-session")
        await router.hibernationCoordinator.reconcileOnStartup()

        let reconciled = try #require(try await db.terminals.get(id: terminalID))
        #expect(!reconciled.isParked)
        #expect(reconciled.claudeSessionID == "replacement-session")
        #expect(reconciled.transcriptPath == "/tmp/replacement-session.jsonl")
        #expect(reconciled.sessionIncarnationID == replacementToken)
    }

    /// The inverse: a genuinely parked terminal (pane running a bare shell, not
    /// claude) is LEFT parked by reconcile.
    @Test func reconcileOnStartupLeavesGenuinelyParkedRow() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        // Pane runs zsh (dryRun default) → genuinely parked, leave it.
        let coord = coordinator(db)
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil,
                "a genuinely parked row (shell in pane) must stay parked")
    }

    /// A tmux server restart can hand this row's window/pane coordinate to a
    /// DIFFERENT terminal's pane, which also happens to be running claude. The
    /// window-alive and process-alive checks alone cannot see that — only the
    /// pane's own `@tbd_terminal_id` answer can. A false park is recoverable
    /// by `wake`; a false un-park is not, so a mismatched id must leave the
    /// row parked.
    @Test func reconcileOnStartupLeavesAParkedRowWhosePaneAnswersWithAStrangersID() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: UUID().uuidString) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil,
                "a pane answering with a different terminal's id must stay parked")
    }

    /// The mirror case: the pane carries no identity to compare at all — a
    /// pane spawned before TBD stamped `@tbd_terminal_id` onto it. That stamp
    /// is deliberately never backfilled onto existing panes, so refusing here
    /// too (treating "no answer" the same as "wrong answer") would leave every
    /// pre-existing session parked after every daemon restart forever —
    /// exactly the "sessions keep falling asleep" symptom this pass exists to
    /// prevent. So the row falls back to today's behavior instead: un-park on
    /// the window/process checks alone.
    @Test func reconcileOnStartupUnparksARowWhosePaneCarriesNoIDToCompare() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "a pane with no identity to compare must fall back to un-parking, not stay parked")
    }

    /// The race the joint `.live`/`.dead` match exists to catch: between the
    /// `paneCurrentCommand` liveness check above and this identity probe (two
    /// separate tmux round trips), the STRANGER pane's process exits. A guard
    /// matching only `.live` would see no case match at all here and silently
    /// fall through to un-parking onto the stranger's pane; matching `.dead`
    /// too must still catch the mismatch.
    @Test func reconcileOnStartupLeavesAParkedRowWhoseStrangerPaneWentDeadBetweenProbes() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .dead(terminalID: UUID().uuidString) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil,
                "a dead stranger pane must still be caught as a mismatch, not slip through unmatched")
    }

    /// The pane the earlier liveness checks just confirmed vanishes entirely by
    /// the time of this probe. That is a race, not evidence of anything — stay
    /// parked rather than guess.
    @Test func reconcileOnStartupLeavesAParkedRowWhosePaneWentMissingBetweenProbes() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in .absent })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil,
                "a pane that went missing mid-probe must stay parked")
    }

    /// An unreadable probe (a wedged server timing out the subprocess) is not
    /// the same fact as "no id to compare" — it is no evidence at all, so it
    /// must NOT fall through to un-parking. Mirrors the sibling reconciler's
    /// "an unreadable identity is not evidence of staleness."
    @Test func reconcileOnStartupLeavesAParkedRowWhoseProbeThrows() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" },
            dryRunPaneSendTarget: { _, _ in
                throw TmuxError.timedOut(command: "list-panes", timeout: .seconds(5))
            })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil,
                "a probe that throws must leave the row parked, not un-park it")
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

    /// Manual park: the published delta carries the just-captured ANSI
    /// snapshot and the `.manual` reason alongside `hibernated: true`.
    @Test func manualHibernatePublishesSnapshotAndReasonOnDelta() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorder = RecordedHibernationDeltas()
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "FROZEN PANE" })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux,
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

        let result = await coord.manualHibernate(terminalID: terminalID)
        #expect(result == .ok)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == true)
        #expect(delta?.suspendedSnapshot == "FROZEN PANE",
                "the hibernate delta must carry the captured snapshot — the parked view reads the cached row at the flip")
        #expect(delta?.hibernateReason == .manual,
                "the hibernate delta must carry the park reason — wake-on-focus filters on it before the refetch")
    }

    /// Wake: the un-park delta publishes nil snapshot/reason (the app clears
    /// its cached reason; the DB keeps the snapshot per `clearHibernated`).
    /// The park runs on tmux and captures the snapshot; the parked row then
    /// moves to the holder, where a wake runs.
    @Test func wakePublishesNilSnapshotAndReasonOnDelta() async throws {
        let (db, _, terminalID) = try await setup()
        let recorder = RecordedHibernationDeltas()
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "FROZEN PANE" })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux,
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
        await wireHolderDouble(coord)

        _ = await coord.manualHibernate(terminalID: terminalID)
        try await moveParkedRowToHolder(db, terminalID)
        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake.isOk)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == false)
        #expect(delta?.suspendedSnapshot == nil)
        #expect(delta?.hibernateReason == nil)
    }

    /// A park and a wake each mint a session incarnation, and the app forwards
    /// Program Status reports under its cached row's: both deltas carry the
    /// incarnation the row holds once each has committed. The park runs on
    /// tmux; the parked row then moves to the holder, where a wake runs.
    @Test func parkAndWakeDeltasCarryTheCommittedIncarnation() async throws {
        let (db, _, terminalID) = try await setup(sessionIncarnationID: UUID())
        let recorder = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
        await wireHolderDouble(coord)
        let before = try #require(try await db.terminals.get(id: terminalID)?.sessionIncarnationID)

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID)?.sessionIncarnationID)
        #expect(parked != before)
        #expect(recorder.snapshot().last?.sessionIncarnationID == parked)

        try await moveParkedRowToHolder(db, terminalID)
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
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

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
            configDirManager: isolatedConfigDirManager(), sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())

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
    /// seam the test drives. The verify-exit poll is paced down to virtual-ish
    /// speed (`exitPollInterval`) because this test is about the record, not
    /// about how long a park waits for Claude to leave.
    private func sweepCoordinator(
        _ db: TBDDatabase, logPath: String, dates: TestDateSource
    ) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            now: dates.provider,
            exitPollAttempts: 1, exitPollInterval: .milliseconds(1),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: ActuationLog(path: logPath))
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
    /// let the settle window elapse so the rail actually parks it. The date
    /// seam does the waiting, so no wall time is spent.
    private func sweepUntilParked(
        _ coord: HibernationCoordinator, dates: TestDateSource, idleMinutes: Int = 1
    ) async {
        await coord.sweep()                                        // seed idleSince
        dates.advance(by: TimeInterval(idleMinutes) * 60 + 1)
        await coord.sweep()                                        // arm the debounce
        dates.advance(by: HibernationCoordinator.killDebounce + 1)
        await coord.sweep()                                        // act
    }

    /// The idle rail's success path. Everything else about the sweep is gating;
    /// this is the one branch that actuates, and it must leave the same
    /// request-then-outcome pair as any RPC surface — under its own rail name,
    /// with no `method`, because no RPC carried it.
    @Test func sweepParkWritesItsOwnRailRowAndOutcome() async throws {
        let (db, worktreeID, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = sweepCoordinator(db, logPath: logPath, dates: dates)

        await sweepUntilParked(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil)
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
        #expect(outcome["result"] as? String == "dispatched")
        // The rail acted; there is no refusal, so there is no reason.
        #expect(outcome["reason"] == nil)
    }

    /// Fail-closed on a daemon-internal rail: an unrecordable park does not
    /// happen. The sweep has no caller to return an error to, so the property
    /// is the park itself — skipped, silently to the user, loudly in the log.
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

        await sweepUntilParked(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "an unrecordable park must not happen")
    }

    // MARK: - Composer-draft park gate
    //
    // The session mod is the park's only guard for an unsent draft. These pin
    // how each row of `docs/specs/2026-10-24-mod-only-park-guard-design.md`,
    // "Which parks go ahead", reaches a real park; `ComposerDraftParkGateTests`
    // states the table itself.

    /// A coordinator over dry-run tmux that reads session files from
    /// `sessionsDir`. `capture` answers every pane read and counts them, which
    /// is how a test sees whether a park reached the transport at all.
    private func draftGateCoordinator(
        _ db: TBDDatabase, sessionsDir: URL, capture: MutableHibernationCapture,
        now: @escaping @Sendable () -> Date,
        actuationLog: ActuationLog = makeTestActuationLog()
    ) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true, dryRunCapturePane: capture.capture),
            configDirManager: isolatedConfigDirManager(),
            now: now,
            exitPollAttempts: 1, exitPollInterval: .milliseconds(1),
            sessionsDir: sessionsDir,
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: actuationLog)
    }

    /// A pane read that shows a half-composed prompt.
    private func typedPane() -> MutableHibernationCapture {
        let capture = MutableHibernationCapture()
        capture.showTypedPrompt()
        return capture
    }

    /// A session spawned without the feature parks by hand with a
    /// half-composed prompt on its pane: nothing saved the draft and nothing
    /// reads the screen to decide. The pane is read once, for the snapshot.
    @Test func legacySessionParksByHandWithATypedPane() async throws {
        let (db, _, terminalID) = try await setup(sessionIncarnationID: UUID())
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let capture = typedPane()
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: capture, now: { Date() })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
        #expect(capture.count == 1, "the pane was read \(capture.count) time(s), not once for the snapshot")
    }

    /// The same session, spawned without the feature, is parked by the
    /// merge-park too: automatic parking does not wait for a mod that was never
    /// spawned.
    @Test func legacySessionIsParkedByMergePark() async throws {
        let (db, _, terminalID) = try await setup(sessionIncarnationID: UUID())
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: typedPane(), now: { Date() })

        #expect(await coord.hibernateForMerge(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.hibernateReason == .merged)
    }

    /// And by the idle sweep.
    @Test func legacySessionIsParkedByTheIdleSweep() async throws {
        let (db, _, terminalID) = try await setup(sessionIncarnationID: UUID())
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let dates = TestDateSource()
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: typedPane(), now: dates.provider,
            actuationLog: ActuationLog(path: try sweepLogPath()))

        await sweepUntilParked(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.hibernateReason == .auto)
    }

    /// A session the feature confirms parks with a typed pane, the pane read
    /// once for the snapshot.
    @Test func confirmedSessionParksWithATypedPane() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let now = Date()
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation,
            heartbeatAt: now, hasDraft: true)
        let capture = typedPane()
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: capture, now: { now })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
        #expect(capture.count == 1)
    }

    /// A spawn record and no heartbeat: TBD cannot confirm the draft is
    /// saved, and a manual park goes ahead without asking.
    @Test func unknownSessionParksByHand() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let capture = typedPane()
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: capture, now: { Date() })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
        #expect(capture.count == 1)
    }

    /// A live, confirmed mod whose saved draft holds content its text lacks
    /// (a collapsed paste) reads unknown, and a manual park of it goes ahead.
    @Test func aDraftNotRestorableParksByHand() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let now = Date()
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation,
            heartbeatAt: now, hasDraft: true, restorable: false)
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: MutableHibernationCapture(), now: { now })

        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    /// The idle sweep skips an unknown session: nothing parks, no pane is
    /// read, and the sweep's own record names the reason.
    @Test func sweepSkipsAnUnknownSession() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let capture = MutableHibernationCapture()
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: capture, now: dates.provider,
            actuationLog: ActuationLog(path: logPath))

        await sweepUntilParked(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
        #expect(capture.count == 0, "the skip came after the park reached the transport")
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

    /// The merge-park skips an unknown session the way the sweep does.
    @Test func mergeParkSkipsAnUnknownSession() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let capture = MutableHibernationCapture()
        let coord = draftGateCoordinator(
            db, sessionsDir: sessionsDir, capture: capture, now: { Date() })

        #expect(await coord.hibernateForMerge(terminalID: terminalID)
            == .notEligible(reason: ComposerDraftParkGate.skipReason("no-alive-file")))
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
        #expect(capture.count == 0)
    }

    /// `terminal.hibernate` parks an unknown session on the first request:
    /// there is no confirmation to ask for.
    @Test func hibernateRPCParksAnUnknownSession() async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        try writeComposerDraftSession(
            sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            sessionsDir: sessionsDir,
            actuationLog: makeTestActuationLog())

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

    // MARK: - Every park ends by signal
    //
    // Nothing is ever typed into a pane to end Claude: no `/exit`, and no
    // Escape or Ctrl+C, because a typed `/exit` would submit a draft and a
    // daemon-sent Ctrl+C clears one. The park sends SIGTERM to the Claude
    // process, polls the pane on the injected clock, and then respawns.

    /// The pane's own pid — its login-shell wrapper — and the Claude process
    /// beneath it. Both sit above macOS's PID_MAX (99999), so no regression
    /// into a raw `kill` of the pane pid can reach a real process; the Claude
    /// pid only ever reaches the fake signaller.
    private static let shellPID: Int32 = 900_001
    private static let claudePID: Int32 = 900_002

    /// A coordinator over dry-run tmux whose pane pid is `shellPID`, with an
    /// inspector that answers `claudePID` beneath it (or nothing) and a
    /// signaller that records every signal it is asked to send.
    private func signalEndingCoordinator(
        _ db: TBDDatabase, sessionsDir: URL, recorded: RecordedTmuxCommands,
        signaller: FakeProcessSignaller, claudePID: Int32?, clock: EventDrivenTestClock,
        exitPollAttempts: Int = 15,
        paneCurrentCommand: (@Sendable (String, String) -> String)? = nil,
        now: @escaping @Sendable () -> Date
    ) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db,
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: recorded.append,
                dryRunPaneCurrentCommand: paneCurrentCommand,
                dryRunPanePID: { _, _ in String(Self.shellPID) }),
            configDirManager: isolatedConfigDirManager(),
            now: now,
            exitPollAttempts: exitPollAttempts,
            exitPollInterval: .milliseconds(200),
            clock: clock,
            signaller: signaller,
            paneProcessInspector: FakeInspector(claudePID: claudePID),
            sessionsDir: sessionsDir,
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
    }

    private func sentKeys(_ recorded: RecordedTmuxCommands) -> [String] {
        recorded.snapshot()
            .map { $0.joined(separator: " ") }
            .filter { $0.contains("send-keys") }
    }

    private func respawned(_ recorded: RecordedTmuxCommands) -> Bool {
        recorded.snapshot().contains { $0.contains("respawn-window") }
    }

    /// The rows of the decision table, as a session's files leave them.
    enum SessionRow: String, CaseIterable, Sendable {
        /// No spawn record: spawned without the feature.
        case spawnedWithoutTheFeature
        /// A spawn record, a fresh heartbeat and a saved, restorable draft.
        case confirmed
        /// A spawn record and no heartbeat.
        case notConfirmed
    }

    /// What started the park. The idle sweep shares the merge-park's column of
    /// the table and its skip; `sweepSkipsAnUnknownSession` pins the sweep's.
    enum ParkTrigger: String, CaseIterable, Sendable {
        case manual
        case merge
    }

    /// Every row of the table under each trigger on tmux: a park that goes
    /// ahead SIGTERMs the Claude pid the inspector found under the pane (not
    /// the pane's shell), sees Claude leave on the first poll, and respawns,
    /// and nothing is ever typed into the pane. The one skip — an unconfirmed
    /// session at a merge-park — signals nothing and types nothing either.
    @Test(arguments: SessionRow.allCases, ParkTrigger.allCases)
    func everyTmuxParkEndsBySignalAndTypesNothing(
        _ row: SessionRow, _ trigger: ParkTrigger
    ) async throws {
        let incarnation = UUID()
        let (db, _, terminalID) = try await setup(sessionIncarnationID: incarnation)
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let now = Date()
        switch row {
        case .spawnedWithoutTheFeature:
            break
        case .confirmed:
            try writeComposerDraftSession(
                sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation,
                heartbeatAt: now, hasDraft: true)
        case .notConfirmed:
            try writeComposerDraftSession(
                sessionsDir: sessionsDir, sessionID: "sess-1", incarnation: incarnation)
        }
        let recorded = RecordedTmuxCommands()
        let signaller = FakeProcessSignaller()
        let clock = EventDrivenTestClock()
        let coord = signalEndingCoordinator(
            db, sessionsDir: sessionsDir, recorded: recorded, signaller: signaller,
            claudePID: Self.claudePID, clock: clock, now: { now })
        let proceeds = !(row == .notConfirmed && trigger == .merge)

        let park = Task { () -> HibernateResult in
            switch trigger {
            case .manual: return await coord.manualHibernate(terminalID: terminalID)
            case .merge: return await coord.hibernateForMerge(terminalID: terminalID)
            }
        }
        if proceeds {
            // The dry-run pane reports `zsh`: the first poll sees Claude gone.
            try await clock.requireAdvanceWhenArmed(by: coord.exitPollInterval)
            #expect(await park.value == .ok, "\(row) under \(trigger) did not park")
            #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
            #expect(signaller.terminatedProcessOnly == [Self.claudePID])
            #expect(signaller.terminated == [Self.claudePID], "a signal went somewhere else too")
            #expect(respawned(recorded))
        } else {
            #expect(await park.value
                == .notEligible(reason: ComposerDraftParkGate.skipReason("no-alive-file")))
            #expect(signaller.terminated.isEmpty, "a skipped park signalled \(signaller.terminated)")
            #expect(!respawned(recorded))
        }
        #expect(sentKeys(recorded).isEmpty,
                "\(row) under \(trigger) was typed into: \(sentKeys(recorded))")
    }

    /// Claude outlives the whole poll window: the park waits out every
    /// attempt — the window is Claude's time to make its final save — then
    /// goes straight to the respawn, still without a keystroke.
    @Test func parkEscalatesToRespawnWhenClaudeStays() async throws {
        let (db, _, terminalID) = try await setup(sessionIncarnationID: UUID())
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let recorded = RecordedTmuxCommands()
        let signaller = FakeProcessSignaller()
        let clock = EventDrivenTestClock()
        let attempts = 3
        let coord = signalEndingCoordinator(
            db, sessionsDir: sessionsDir, recorded: recorded, signaller: signaller,
            claudePID: Self.claudePID, clock: clock, exitPollAttempts: attempts,
            paneCurrentCommand: { _, _ in "1.2.3" },  // claude, every attempt
            now: { Date() })

        let park = Task { await coord.manualHibernate(terminalID: terminalID) }
        for _ in 0..<(attempts - 1) {
            try await clock.requireAdvanceWhenArmed(by: coord.exitPollInterval)
        }
        // Armed for the last attempt, or already respawned early.
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            clock.hasSleeper || respawned(recorded)
        } == .satisfied)
        #expect(!respawned(recorded), "the respawn came before the poll window closed")

        try await clock.requireAdvanceWhenArmed(by: coord.exitPollInterval)
        #expect(await park.value == .ok)
        #expect(respawned(recorded))
        #expect(sentKeys(recorded).isEmpty, "the escalation typed into the pane: \(sentKeys(recorded))")
        #expect(signaller.terminatedProcessOnly == [Self.claudePID])
        #expect(signaller.terminated == [Self.claudePID])
    }

    /// No Claude process answers under the pane: nothing is signalled — the
    /// shell wrapper least of all — nothing is waited for, nothing is typed,
    /// and the respawn ends whatever is there.
    @Test func parkWithoutAClaudePidGoesStraightToRespawn() async throws {
        let (db, _, terminalID) = try await setup(sessionIncarnationID: UUID())
        let sessionsDir = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let recorded = RecordedTmuxCommands()
        let signaller = FakeProcessSignaller()
        let clock = EventDrivenTestClock()
        let coord = signalEndingCoordinator(
            db, sessionsDir: sessionsDir, recorded: recorded, signaller: signaller,
            claudePID: nil, clock: clock, exitPollAttempts: 1, now: { Date() })
        let finished = FireRecorder<HibernateResult>()

        let park = Task {
            let result = await coord.manualHibernate(terminalID: terminalID)
            finished.record(result)
            return result
        }
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            !finished.values.isEmpty || clock.hasSleeper
        } == .satisfied)
        #expect(!clock.hasSleeper, "no Claude pid answered, yet the park waited for one to exit")
        if clock.hasSleeper {
            // Release the regression so the test ends red instead of hanging.
            await clock.advance(by: coord.exitPollInterval)
        }
        #expect(await park.value == .ok)
        #expect(sentKeys(recorded).isEmpty, "the park typed into the pane: \(sentKeys(recorded))")
        #expect(signaller.terminated.isEmpty, "something was signalled: \(signaller.terminated)")
        #expect(respawned(recorded))
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
                configDirManager: isolatedConfigDirManager()),
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
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeTerminal(
        db: TBDDatabase, transport: TerminalTransport = .tmux
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

    /// An unreachable tmux server: the RPC must report an error (the prompt
    /// went nowhere, so `woken: false` would let an autonomous caller believe
    /// it was merely already awake) WITHOUT claiming the session is gone. In
    /// particular it must not carry `terminalSessionGone`, whose contract is a
    /// pane that positively disagreed.
    @Test func wakeOnUnreachableServerErrorsWithoutClaimingSessionGone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: { recorded.append($0) },
            dryRunPaneSendTarget: { _, _ in .unreachable })
        let terminal = try await makeTerminal(db: db)  // NOT hibernated

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "must never appear"))
        let resp = await makeRouter(db: db, tmux: tmux).handle(req)

        #expect(!resp.success)
        let error = try #require(resp.error)
        #expect(error.contains("Could not reach tmux server"))
        #expect(error.contains("tbd-wake-prompt"))
        #expect(error.contains("%0"))
        #expect(!error.contains("is gone"))
        #expect(resp.errorCode != RPCErrorCode.terminalSessionGone.rawValue)
        #expect(recorded.snapshot().isEmpty,
                "a failed read must not touch tmux; got: \(recorded.snapshot())")
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

private final class HibernationServerLockGate: @unchecked Sendable {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        (releaseStream, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func hold(_ tmux: TmuxManager, server: String) -> Task<Void, Never> {
        Task {
            await tmux.withServerResourceLock(server: server) { [self] in
                enteredContinuation.yield()
                var iterator = releaseStream.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
    }

    func waitUntilHeld() async {
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield()
    }
}

/// Answers every pane capture and counts them; after `showTypedPrompt`, each
/// capture shows a half-composed prompt.
private final class MutableHibernationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captures = 0
    private var typedPrompt = false

    var count: Int { lock.withLock { captures } }

    var capture: @Sendable (String, String) -> String {
        { [self] _, _ in
            lock.withLock {
                captures += 1
                return typedPrompt ? "> preserve this typed prompt" : ""
            }
        }
    }

    func showTypedPrompt() {
        lock.withLock { typedPrompt = true }
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

private final class FailRespawnOnAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let failingAttempt: Int
    private var attempt = 0

    init(_ failingAttempt: Int) {
        self.failingAttempt = failingAttempt
    }

    var error: @Sendable (String) -> Error? {
        { [self] _ in
            lock.withLock {
                attempt += 1
                guard attempt == failingAttempt else { return nil }
                return TmuxError.unexpectedOutput(
                    "replacement attempt \(failingAttempt) failed")
            }
        }
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

/// Learns that a tmux park has passed its pre-lock rails and is about to
/// queue for the server lock, through `tmuxParkWillAwaitServerLock`.
private final class QueuedParkSignal: @unchecked Sendable {
    private let queued: AsyncStream<Void>
    private let queuedContinuation: AsyncStream<Void>.Continuation

    init() {
        (queued, queuedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var signal: @Sendable (UUID) -> Void {
        { [queuedContinuation] _ in queuedContinuation.yield() }
    }

    func waitUntilQueued() async {
        var iterator = queued.makeAsyncIterator()
        _ = await iterator.next()
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
    private var match = "respawn-window"
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
                releaseGate.waitForGate("hibernation respawn")
            }
        }
    }

    func arm(matching match: String = "respawn-window") {
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
