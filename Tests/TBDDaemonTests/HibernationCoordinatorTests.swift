import Clocks
import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A `ClaudeProfileConfigDirManager` pointed at fresh temp dirs, so wake()'s
/// transcript-sync ambient fallback lists a sandbox — never the developer's
/// real `~/.claude/projects` (the tier-3 resolve there opens the first jsonl
/// in every project dir). Every `HibernationCoordinator`/`RPCRouter`
/// construction in this file must pass one.
private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-hib-claude-\(UUID().uuidString)", isDirectory: true)
    return ClaudeProfileConfigDirManager(
        baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
        hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
    )
}

/// `.clockDriven` is applied at SUITE level even though only the three
/// park-poll tests below drive a `TestClock`. The trait is a four-minute time
/// limit — a hang-catcher, not a perf budget — so it costs the other tests
/// nothing and it catches the one failure mode virtual time introduces here (a
/// `TestClock` sleep nobody advances hangs forever instead of going red).
/// `.serialized` is deliberately NOT applied: three clock-driven tests out of
/// ~35 don't justify serializing the whole suite, and it stays available as
/// the documented escape hatch if the arming handshake ever flakes under load.
@Suite("HibernationCoordinator", .clockDriven)
struct HibernationCoordinatorTests {

    /// In-memory DB + repo + worktree + an idle Claude terminal.
    private func setup(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude
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
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: sessionID, kind: kind
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
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
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
            "TBD_CLI_PATH=\(SystemPromptBuilder.shellEscape(matchedCLIPath))"))

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

    @Test func staleHibernateCannotParkAProfileReplacement() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "profile-source-session",
            transcriptPath: "/tmp/profile-source-session.jsonl")
        let replacementProfile = try await db.modelProfiles.create(
            name: "Replacement", kind: .oauth)
        let captureGate = BlockingCapturePane()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append,
            dryRunCapturePane: captureGate.capture)
        let deltas = RecordedHibernationDeltas()
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        let hibernate = gateHoldingTask {
            await coordinator.manualHibernate(terminalID: terminalID)
        }
        guard await waitUntil({ captureGate.isBlocked }) else {
            captureGate.release()
            _ = await hibernate.value
            Issue.record("hibernate never reached its pre-lock capture")
            return
        }

        let profileResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminalID,
                newProfileID: replacementProfile.id,
                mode: .inPlace)))
        #expect(profileResponse.success)
        let replacement = try #require(try await db.terminals.get(id: terminalID))
        let respawnsAfterProfile = commands.snapshot().filter { $0.contains("respawn-window") }.count
        #expect(respawnsAfterProfile == 1)

        captureGate.release()
        #expect(await hibernate.value != .ok)

        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged.sessionIncarnationID == replacement.sessionIncarnationID)
        #expect(unchanged.tmuxWindowID == replacement.tmuxWindowID)
        #expect(unchanged.tmuxPaneID == replacement.tmuxPaneID)
        #expect(unchanged.profileID == replacement.profileID)
        #expect(unchanged.claudeSessionID == replacement.claudeSessionID)
        #expect(unchanged.transcriptPath == replacement.transcriptPath)
        #expect(unchanged.activityState == replacement.activityState)
        #expect(unchanged.activityStateSource == replacement.activityStateSource)
        #expect(unchanged.activityStateObservedAt == replacement.activityStateObservedAt)
        #expect(unchanged.activityStateOrderObservedAt
                == replacement.activityStateOrderObservedAt)
        #expect(!unchanged.isParked)
        #expect(commands.snapshot().filter { $0.contains("respawn-window") }.count
                == respawnsAfterProfile)
        #expect(deltas.snapshot().isEmpty)
    }

    @Test func profileReplacementRevalidatesAfterHibernationWinsServerLock() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "profile-source-session",
            transcriptPath: "/tmp/profile-source-session.jsonl")
        let replacementProfile = try await db.modelProfiles.create(
            name: "Replacement", kind: .apiKey)
        let keychainGate = BlockingKeychainLookup()
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            keychain: keychainGate.load)
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: commands.append)
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            modelProfileResolver: resolver,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        let swapRequest = try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminalID,
                newProfileID: replacementProfile.id,
                mode: .inPlace))
        let swap = gateHoldingTask { await router.handle(swapRequest) }
        guard await waitUntil({ keychainGate.isBlocked }) else {
            keychainGate.release()
            _ = await swap.value
            Issue.record("profile replacement never reached credential resolution")
            return
        }

        #expect(await coordinator.manualHibernate(terminalID: terminalID) == .ok)
        let hibernated = try #require(try await db.terminals.get(id: terminalID))
        let respawnsAfterHibernate = commands.snapshot()
            .filter { $0.contains("respawn-window") }.count
        #expect(respawnsAfterHibernate == 2)

        keychainGate.release()
        #expect(!(await swap.value).success)

        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged.sessionIncarnationID == hibernated.sessionIncarnationID)
        #expect(unchanged.tmuxWindowID == hibernated.tmuxWindowID)
        #expect(unchanged.tmuxPaneID == hibernated.tmuxPaneID)
        #expect(unchanged.profileID == hibernated.profileID)
        #expect(unchanged.claudeSessionID == hibernated.claudeSessionID)
        #expect(unchanged.transcriptPath == hibernated.transcriptPath)
        #expect(unchanged.activityState == hibernated.activityState)
        #expect(unchanged.activityStateSource == hibernated.activityStateSource)
        #expect(unchanged.isParked)
        #expect(commands.snapshot().filter { $0.contains("respawn-window") }.count
                == respawnsAfterHibernate)
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
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" })
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
        let clock = TestClock<Duration>()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorded.append,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" })
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            exitPollAttempts: 1,
            exitPollInterval: .milliseconds(200),
            clock: clock,
            actuationLog: makeTestActuationLog())

        let hibernate = Task {
            await coordinator.manualHibernate(terminalID: terminalID)
        }
        await clock.waitForSuspension()
        #expect(try await db.terminals.get(id: terminalID)?.isParked == true)

        #expect(await coordinator.wake(terminalID: terminalID) == .inFlight)
        await clock.advanceWhenSuspended(by: .milliseconds(200))
        #expect(await hibernate.value == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isParked == true)
        let respawns = recorded.snapshot().filter { $0.contains("respawn-window") }
        #expect(respawns.count == 2)
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
        let capture = MutableHibernationCapture()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append,
            dryRunCapturePane: capture.capture)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }

        let hibernate = gateHoldingTask {
            await coord.manualHibernate(terminalID: terminalID)
        }
        await capture.waitForFirstCapture()
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
        let capture = MutableHibernationCapture()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append,
            dryRunCapturePane: capture.capture)
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
            actuationLog: ActuationLog(path: try sweepLogPath()))

        await coord.sweep()
        dates.advance(by: 61)
        await coord.sweep()
        dates.advance(by: HibernationCoordinator.killDebounce + 1)

        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }
        let sweep = gateHoldingTask { await coord.sweep() }
        await capture.waitForFirstCapture()
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

    @Test func queuedHibernateRecapturesPendingInputAfterServerLock() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let capture = MutableHibernationCapture()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append,
            dryRunCapturePane: capture.capture)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }

        let before = try #require(try await db.terminals.get(id: terminalID))
        let hibernate = gateHoldingTask {
            await coord.manualHibernate(terminalID: terminalID)
        }
        await capture.waitForFirstCapture()
        capture.setPendingInput()
        await Task.megaYield()
        let commandCount = commands.snapshot().count
        serverLock.release()
        _ = await holder.value

        #expect(await hibernate.value == .notEligible(
            reason: "Terminal has unsent typed input"))
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == before)
        #expect(capture.count >= 2)
        #expect(commands.snapshot().count == commandCount)
        #expect(deltas.snapshot().isEmpty)
    }

    @Test func queuedMergeHibernateRechecksInputTrackerAfterServerLock() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let capture = MutableHibernationCapture()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append,
            dryRunCapturePane: capture.capture)
        let deltas = RecordedHibernationDeltas()
        let inputActivity = InputActivityTracker()
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        await coord.setInputActivity(inputActivity)
        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }

        let before = try #require(try await db.terminals.get(id: terminalID))
        let hibernate = gateHoldingTask {
            await coord.hibernateForMerge(
                terminalID: terminalID,
                inputVetoEnabled: true)
        }
        await capture.waitForFirstCapture()
        inputActivity.recordInput(paneID: before.tmuxPaneID)
        await Task.megaYield()
        let commandCount = commands.snapshot().count
        serverLock.release()
        _ = await holder.value

        #expect(await hibernate.value == .notEligible(
            reason: "Terminal has unsent typed input"))
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == before)
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
        let capture = MutableHibernationCapture()
        let commands = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: commands.append,
            dryRunCapturePane: capture.capture)
        let deltas = RecordedHibernationDeltas()
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let serverLock = HibernationServerLockGate()
        let holder = serverLock.hold(tmux, server: "tbd-hib")
        await serverLock.waitUntilHeld()
        defer { serverLock.release() }

        let before = try #require(try await db.terminals.get(id: terminalID))
        let hibernate = gateHoldingTask {
            await coord.manualHibernate(terminalID: terminalID)
        }
        await capture.waitForFirstCapture()
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

    // MARK: - Park path: polite /exit success vs SIGTERM fallback
    //
    // The unified park sequence tries an in-band `/exit` first and polls
    // `exitPollAttempts` × `exitPollInterval` (production: 15 × 200ms ≈ 3s) for
    // the claude process to leave; only if it's STILL claude after the whole
    // window does it escalate to the graceful-interrupt SIGTERM fallback.
    //
    // DEFECT these three tests exist to catch: *the poll gives up too early or
    // never escalates* — so a hung claude is SIGTERMed while it is still
    // exiting, or a wedged one is never escalated at all.
    //
    // The poll's pacing is injected (`exitPollAttempts` / `exitPollInterval`)
    // and its delay runs on an injected `clock`, so the exhaustion branch is
    // crossed in virtual time. Before that seam existed, the fallback test paid
    // ~3s of REAL wall time on every run to prove one branch, and nothing
    // pinned the attempt count at all.

    /// `/exit` succeeds: the pane's current command reads as a non-claude shell
    /// during the poll, so the polite exit is observed and NO SIGTERM-fallback
    /// interrupt (Escape / C-c) is sent. The row is still marked hibernated.
    ///
    /// Runs the PRODUCTION pacing (15 × 200ms) deliberately: exactly ONE
    /// interval is ever advanced, so the test also pins "the poll returns on
    /// the first successful observation". A poll that kept checking would park
    /// on an un-advanced sleep and be surfaced by `.clockDriven`.
    @Test func parkViaExitSucceedsWithoutSigtermFallback() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        // dryRun default paneCurrentCommand is "zsh" (not claude) → poll sees the
        // process leave immediately after `/exit`.
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let clock = TestClock<Duration>()
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), clock: clock, actuationLog: makeTestActuationLog())

        let park = Task { await coord.manualHibernate(terminalID: terminalID) }
        // Unblocks the single verify-exit poll attempt.
        await clock.advanceWhenSuspended(by: coord.exitPollInterval)
        let result = await park.value

        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil)

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        // A polite `/exit` must have been sent.
        #expect(joined.contains { $0.contains("send-keys") && $0.contains("/exit") },
                "expected a polite /exit send; got: \(joined)")
        // No SIGTERM-fallback interrupt: Escape / C-c must NOT appear.
        #expect(!joined.contains { $0.contains("send-keys") && $0.contains("C-c") },
                "polite /exit succeeded — no C-c interrupt should be sent; got: \(joined)")
    }

    /// `/exit` does NOT terminate claude within the poll window: the pane keeps
    /// reporting a claude process for EVERY attempt, so the park exhausts the
    /// whole window and escalates to the graceful interrupt (Escape → C-c C-c →
    /// SIGTERM). The row is still marked hibernated afterward (respawn-window
    /// -k guarantees termination).
    ///
    /// The window is 3 attempts here rather than the production 15 — pacing is
    /// injected precisely so the exhaustion threshold is still fully crossed
    /// (every attempt is advanced, and the escalation happens only after the
    /// last one) inside a 3-advance budget instead of 15 real 200ms sleeps.
    /// `defaultPollPacingIsFifteenTimesTwoHundredMillis` keeps the production
    /// ~3s window itself pinned.
    @Test func parkFallsBackToSigtermWhenExitDoesNotKill() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        // Pane keeps reporting a claude process for the whole poll → fallback.
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" }  // claude reports its version as pane_current_command
        )
        let clock = TestClock<Duration>()
        let pollInterval: Duration = .milliseconds(200)
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            exitPollAttempts: 3, exitPollInterval: pollInterval, clock: clock, actuationLog: makeTestActuationLog())

        let park = Task { await coord.manualHibernate(terminalID: terminalID) }
        // Exhaust the whole poll window: one advance per attempt.
        for _ in 0..<3 {
            await clock.advanceWhenSuspended(by: pollInterval)
        }
        let result = await park.value

        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil)

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        // Polite /exit was still attempted first.
        #expect(joined.contains { $0.contains("send-keys") && $0.contains("/exit") },
                "expected a polite /exit attempt; got: \(joined)")
        // Then the SIGTERM-fallback graceful interrupt (C-c) must have fired.
        #expect(joined.contains { $0.contains("send-keys") && $0.contains("C-c") },
                "expected a C-c interrupt in the SIGTERM-fallback branch; got: \(joined)")
    }

    /// The escalation BOUNDARY: with `exitPollAttempts == 3` the park must
    /// still be polling after 2 attempts (no interrupt sent yet) and must
    /// escalate on the 3rd. Both halves matter and neither was pinned before
    /// the pacing seam existed — the defect has two directions, giving up early
    /// (SIGTERM while claude is still exiting) and never escalating (a wedged
    /// claude polled forever).
    ///
    /// The "hasn't escalated yet" half is proved by `waitForSuspension()`: the
    /// coordinator is parked on attempt 3's sleep, which means it completed
    /// attempts 1–2, observed claude both times, and did NOT leave the loop.
    @Test func escalatesOnlyAfterExactlyTheConfiguredAttemptCount() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" }  // still claude, every attempt
        )
        let clock = TestClock<Duration>()
        let pollInterval: Duration = .milliseconds(200)
        let attempts = 3
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            exitPollAttempts: attempts, exitPollInterval: pollInterval, clock: clock, actuationLog: makeTestActuationLog())
        func interruptSent() -> Bool {
            recorded.snapshot()
                .map { $0.joined(separator: " ") }
                .contains { $0.contains("send-keys") && $0.contains("C-c") }
        }

        let park = Task { await coord.manualHibernate(terminalID: terminalID) }

        // N-1 attempts: still inside the poll window.
        for _ in 0..<(attempts - 1) {
            await clock.advanceWhenSuspended(by: pollInterval)
        }
        await clock.waitForSuspension()  // armed for attempt N ⇒ N-1 are done
        #expect(!interruptSent(),
                "must not escalate before the poll window is exhausted; got: \(recorded.snapshot())")

        // The Nth (final) attempt: the window is exhausted, so escalate.
        await clock.advanceWhenSuspended(by: pollInterval)
        let result = await park.value
        #expect(result == .ok)
        #expect(interruptSent(),
                "must escalate once all \(attempts) attempts observed claude; got: \(recorded.snapshot())")
    }

    /// Pins the SHIPPED poll window, which the two injected-pacing tests above
    /// deliberately no longer run: 15 × 200ms ≈ 3s. Making the pacing
    /// injectable must not quietly change what production waits before it
    /// SIGTERMs a claude that is still shutting down.
    @Test func defaultPollPacingIsFifteenTimesTwoHundredMillis() async throws {
        let (db, _, _) = try await setup()
        let coord = coordinator(db)
        #expect(coord.exitPollAttempts == 15)
        #expect(coord.exitPollInterval == .milliseconds(200))
        #expect(coord.exitPollInterval * coord.exitPollAttempts == .seconds(3),
                "the shipped verify-exit window must stay ~3s")
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
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

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

        let woke = await coord.wake(terminalID: terminalID)
        #expect(woke == .ok)
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

    @Test func wakeClearsHibernatedAndRespawnsResume() async throws {
        let (db, _, terminalID) = try await setup()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        _ = await coord.manualHibernate(terminalID: terminalID)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)

        // A respawn-window with `claude --resume` must have been issued.
        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("respawn-window") && $0.contains("claude --resume sess-1") },
                "expected a respawn-window carrying claude --resume; got: \(joined)")
    }

    @Test func wakeRespawnPreservesRetryIdentityAndRejectsParkedIncarnation() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/hibernation-wake-old-session.jsonl")
        let coord = coordinator(db)
        #expect(await coord.manualHibernate(terminalID: terminalID) == .ok)
        let parked = try #require(try await db.terminals.get(id: terminalID))

        #expect(await coord.wake(terminalID: terminalID) == .ok)
        let awake = try #require(try await db.terminals.get(id: terminalID))
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
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
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in .missing })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
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
                               dryRunPaneSendTarget: { _, _ in .missing })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
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
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID) == .notHibernated)
    }

    /// A live pane carrying no identity is left alone — refusal requires
    /// POSITIVE disagreement, the same rule the send path follows.
    @Test func wakeOnUnparkedRowWithLivePaneStaysBenignNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let tmux = TmuxManager(dryRun: true,
                               dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
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
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID) == .notHibernated)
    }

    /// A parked row still takes the existing recovery path, not the new
    /// reporting one — `.sessionGone` is reachable only from the unparked gate.
    @Test func parkedRowWithGoneWindowStillRecoversRatherThanReporting() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let tmux = TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true },
                               dryRunPaneSendTarget: { _, _ in .missing })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        #expect(await coord.wake(terminalID: terminalID) == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isParked == false)
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
        let (db, _, terminalID) = try await setup()
        // Mark hibernated (authoritative) AND stamp a legacy suspendedAt.
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess-1")
        // setSuspended cleared hibernatedAt? No — it only sets suspendedAt. But to
        // be safe re-mark hibernated so both columns are set.
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let before = try await db.terminals.get(id: terminalID)
        #expect(before?.hibernatedAt != nil)
        #expect(before?.suspendedAt != nil)

        let wake = await coordinator(db).wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil, "wake must clear hibernatedAt")
        #expect(after?.suspendedAt == nil, "wake must also clear legacy suspendedAt")
    }

    /// Regression: a row parked with ONLY `suspendedAt` (the reconcile /
    /// recreate-window paths, or a pre-merge Suspend row) must still wake. The
    /// guard checks `isParked`, not `hibernatedAt` alone — otherwise these rows
    /// show a Wake button that silently no-ops and the pane is stuck forever.
    @Test func wakeUnparksLegacySuspendedOnlyRow() async throws {
        let (db, _, terminalID) = try await setup()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        // Legacy park: only suspendedAt set, hibernatedAt nil.
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess-1")
        let before = try await db.terminals.get(id: terminalID)
        #expect(before?.hibernatedAt == nil)
        #expect(before?.suspendedAt != nil)
        #expect(before?.isParked == true)

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok, "wake must un-park a suspendedAt-only row, not no-op it")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false, "row fully un-parked (both columns nil)")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("respawn-window") && $0.contains("claude --resume sess-1") },
                "expected a respawn-window carrying claude --resume; got: \(joined)")
    }

    // MARK: - Wake: window-gone recreate branch
    //
    // A reboot destroys every tmux server, leaving parked rows pointing at
    // dead windows. Wake must detect the dead window and RECREATE it (server +
    // window) instead of failing "Terminal not found". Both sides of the
    // `windowExists` gate are covered.

    /// Window ALIVE (dryRun default): the existing respawn-in-place path runs
    /// unchanged — same window/pane ids, `respawn-window` issued, never
    /// `new-window` — and the recreate-only server hook does NOT fire.
    @Test func wakeWithLiveWindowRespawnsInPlaceKeepingIDs() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let recorded = RecordedTmuxCommands()
        let serverHookCalls = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        await coord.setOnServerCreated { server in serverHookCalls.append([server]) }

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false, "row must be un-parked")
        #expect(after?.tmuxWindowID == "@0", "live-window wake must keep the window id")
        #expect(after?.tmuxPaneID == "%0", "live-window wake must keep the pane id")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("respawn-window") },
                "expected respawn-window; got: \(joined)")
        #expect(!joined.contains { $0.contains("new-window") },
                "a live window must NOT be recreated; got: \(joined)")
        #expect(serverHookCalls.snapshot().isEmpty,
                "onServerCreated must only fire on the recreate branch")
    }

    /// Window DEAD (post-reboot / killed): wake recreates the server + window,
    /// persists the NEW window/pane ids, stages an inert `new-window`, then
    /// respawns the same `claude --resume` into that replacement. The
    /// server hook fires so a recreated server gets its control-mode connection.
    @Test func wakeRecreatesDeadWindowAndPersistsNewIDs() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let recorded = RecordedTmuxCommands()
        let serverHookCalls = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { $0 == "@0" }
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        await coord.setOnServerCreated { server in serverHookCalls.append([server]) }

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false, "row must be un-parked")
        #expect(after?.tmuxWindowID == "@mock-0", "recreate must persist the new window id")
        #expect(after?.tmuxPaneID == "%mock-0", "recreate must persist the new pane id")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("new-window") && $0.contains("-c /tmp/hib-repo") && $0.contains("tail -f /dev/null") },
                "expected an inert staged new-window in the worktree cwd; got: \(joined)")
        #expect(joined.contains { $0.contains("respawn-window") && $0.contains("@mock-0") && $0.contains("--resume sess-1") },
                "expected a respawn into the replacement window; got: \(joined)")
        #expect(!joined.contains { $0.contains("respawn-window") && $0.contains("-t @0") },
                "a dead window must NOT be respawned into; got: \(joined)")
        // Old-window cleanup: a transient windowExists misclassification must
        // not leak a live old window (usually already dead — kill no-ops).
        #expect(joined.contains { $0.contains("kill-window") && $0.contains("@0") },
                "expected a best-effort kill of the old window; got: \(joined)")
        #expect(serverHookCalls.snapshot() == [["tbd-hib"]],
                "onServerCreated must fire once with the recreated server name")
    }

    @Test func deadWindowWakePersistsReplacementTokenBeforeAgentLaunch() async throws {
        let (db, _, terminalID) = try await setup()
        // Dry-run recreation returns these same coordinates, exercising the
        // ABA shape where tmux IDs and the label cannot distinguish processes.
        try await db.terminals.updateTmuxIDs(
            id: terminalID, windowID: "@mock-0", paneID: "%mock-0")
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let recorder = BlockingRespawnRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.record,
            dryRunWindowIsDead: { $0 == "@mock-0" })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        recorder.arm(matching: "claude --resume sess-1")
        let wake = gateHoldingTask {
            await router.hibernationCoordinator.wake(terminalID: terminalID)
        }
        guard await waitUntil({ recorder.isBlocked }, timeout: ciSafeDeadline) else {
            recorder.release()
            _ = await wake.value
            Issue.record("wake never reached the replacement agent launch")
            return
        }

        let staged = try #require(try await db.terminals.get(id: terminalID))
        #expect(staged.tmuxWindowID == "@mock-0")
        #expect(staged.tmuxPaneID == "%mock-0")
        #expect(staged.label == "claude")
        #expect(staged.isParked)
        let replacementToken = try #require(staged.sessionIncarnationID)
        #expect(recorder.blockedCommand?.last?.contains(
            "TBD_TERMINAL_INCARNATION_ID='\(replacementToken.uuidString)'") == true)
        let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
        #expect(recorder.blockedCommand?.last?.contains(
            "TBD_CLI_PATH=\(SystemPromptBuilder.shellEscape(matchedCLIPath))") == true)

        let staleHook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "stale-session",
                transcriptPath: "/tmp/stale-session.jsonl",
                source: "startup"))
        #expect((await router.handle(staleHook)).success)
        #expect(try await db.terminals.get(id: terminalID)?.claudeSessionID == "sess-1")
        recorder.release()
        #expect(await wake.value == .ok)

        let replacementHook = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "replacement-session",
                transcriptPath: "/tmp/replacement-session.jsonl",
                source: "startup",
                sessionIncarnationID: replacementToken))
        #expect((await router.handle(replacementHook)).success)
        let attached = try #require(try await db.terminals.get(id: terminalID))
        #expect(attached.claudeSessionID == "replacement-session")
        #expect(attached.transcriptPath == "/tmp/replacement-session.jsonl")
    }

    @Test func liveWindowWakeFencesSessionStartHandledDuringRespawnGap() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let recorder = BlockingRespawnRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorder.record)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        recorder.arm(matching: "claude --resume sess-1")
        let wake = gateHoldingTask {
            await router.hibernationCoordinator.wake(terminalID: terminalID)
        }
        guard await waitUntil({ recorder.isBlocked }) else {
            recorder.release()
            _ = await wake.value
            Issue.record("wake never reached the in-place respawn")
            return
        }
        let staged = try #require(try await db.terminals.get(id: terminalID))
        let replacementToken = try #require(staged.sessionIncarnationID)
        #expect(recorder.blockedCommand?.last?.contains(
            "TBD_TERMINAL_INCARNATION_ID='\(replacementToken.uuidString)'") == true)
        let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
        #expect(recorder.blockedCommand?.last?.contains(
            "TBD_CLI_PATH=\(SystemPromptBuilder.shellEscape(matchedCLIPath))") == true)

        let gapEvent = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID,
                sessionID: "old-process-gap-session",
                transcriptPath: "/tmp/old-process-gap-session.jsonl",
                source: "startup"))
        #expect((await router.handle(gapEvent)).success)
        #expect(try await db.terminals.get(id: terminalID)?.claudeSessionID == "sess-1")

        recorder.release()
        #expect(await wake.value == .ok)
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
        #expect(try await db.terminals.get(id: terminalID)?.claudeSessionID
                == "replacement-session")
    }

    @Test func wakeDoesNotReportSuccessWhenPostLaunchMarkerClearFails() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let recorder = BlockingRespawnRecorder()
        let deltas = RecordedHibernationDeltas()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorder.record)
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        recorder.arm(matching: "claude --resume sess-1")
        let wake = gateHoldingTask {
            await coord.wake(terminalID: terminalID)
        }
        guard await waitUntil({ recorder.isBlocked }) else {
            recorder.release()
            _ = await wake.value
            Issue.record("wake never reached the replacement launch")
            return
        }
        try await db.terminals.delete(id: terminalID)
        recorder.release()

        #expect(await wake.value != .ok)
        #expect(deltas.snapshot().isEmpty,
                "a wake whose final durable marker clear failed must not broadcast success")
        let joined = recorder.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.filter { $0.contains("respawn-window") }.count == 1,
                "marker failure must not erase an already-running replacement")
    }

    // MARK: - Wake: window-id ownership (post-reboot id recycling)
    //
    // A fresh tmux server reissues window ids from @1, so a stale parked
    // row's id can equal a window ANOTHER terminal's wake just created.
    // `windowExists` alone is not ownership — both sides of the claim gate
    // are covered.

    /// Collision + windowExists true: another terminal on the same server
    /// claims this row's window id, so respawning in place would hijack that
    /// terminal's live session. Wake must take the RECREATE branch — and must
    /// NOT kill the other terminal's window.
    @Test func wakeRecreatesWhenWindowIDClaimedByAnotherTerminal() async throws {
        let (db, wtID, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        // The OTHER terminal (fresher claim — e.g. its wake just created @0
        // on the rebooted server). Same worktree → same tmux server.
        _ = try await db.terminals.create(
            worktreeID: wtID, tmuxWindowID: "@0", tmuxPaneID: "%9",
            label: "claude", claudeSessionID: "sess-2", kind: .claude
        )
        let recorded = RecordedTmuxCommands()
        // No dryRunWindowIsDead: the window EXISTS — ownership must win.
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false)
        #expect(after?.tmuxWindowID == "@mock-0", "collision must force a recreate with fresh ids")
        #expect(after?.tmuxPaneID == "%mock-0")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("new-window") },
                "expected the recreate branch (new-window); got: \(joined)")
        #expect(joined.contains { $0.contains("respawn-window") && $0.contains("@mock-0") },
                "the replacement window must receive the agent; got: \(joined)")
        #expect(!joined.contains { $0.contains("respawn-window") && $0.contains("-t @0") },
                "must never respawn into a window another terminal owns; got: \(joined)")
        #expect(!joined.contains { $0.contains("kill-window") && $0.contains("@0") },
                "must never kill the other terminal's live window; got: \(joined)")
    }

    /// No collision: another terminal exists on the same server but claims a
    /// DIFFERENT window id — the respawn-in-place branch runs unchanged.
    @Test func wakeRespawnsInPlaceWhenOtherTerminalHoldsDifferentWindow() async throws {
        let (db, wtID, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        _ = try await db.terminals.create(
            worktreeID: wtID, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "claude", claudeSessionID: "sess-2", kind: .claude
        )
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.tmuxWindowID == "@0", "no collision → in-place respawn keeps the ids")
        #expect(after?.tmuxPaneID == "%0")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("respawn-window") },
                "expected the in-place respawn branch; got: \(joined)")
        #expect(!joined.contains { $0.contains("new-window") },
                "a non-colliding live window must not be recreated; got: \(joined)")
    }

    // MARK: - Wake: cross-terminal serialization (per-server lock)
    //
    // Actors are reentrant across awaits and SocketServer runs RPCs
    // concurrently, so two wakes for DIFFERENT terminals on the SAME server
    // must be serialized by the tmux server-resource lock — `wakesInFlight` only dedupes
    // the same terminal. Both branches of the lock gate are covered: same
    // server serializes (and loses no wake), different servers don't.

    @Test func concurrentWakesForSameTerminalClaimBeforeDatabaseLookup() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let parked = try #require(try await db.terminals.get(id: terminalID))
        let recorded = RecordedTmuxCommands()
        let deltas = RecordedHibernationDeltas()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorded.append)
        let coordinator = HibernationCoordinator(
            db: db,
            tmux: tmux,
            subscriptions: deltas.subscriptions(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
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
        #expect(results.filter { $0 == .ok }.count == 1)
        #expect(results.filter { $0 == .inFlight }.count == 1)
        let after = try #require(try await db.terminals.get(id: terminalID))
        #expect(after.sessionIncarnationID != parked.sessionIncarnationID)
        #expect(!after.isParked)
        let replacementCommands = recorded.snapshot().filter { command in
            let body = command.joined(separator: " ")
            return body.contains("respawn-window")
                && body.contains("claude --resume sess-1")
                && body.contains("deliver exactly once")
        }
        #expect(replacementCommands.count == 1)
        #expect(deltas.snapshot().filter { !$0.hibernated }.count == 1)
    }

    @Test func terminalLookupFailureReleasesSameTerminalClaim() async throws {
        let (db, worktreeID, _) = try await setup()
        let terminalID = UUID()
        let subject = coordinator(db)

        #expect(await subject.wake(terminalID: terminalID) == .notFound)

        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@retry",
            tmuxPaneID: "%retry",
            label: "claude",
            claudeSessionID: "sess-retry",
            kind: .claude)
        try await db.terminals.setHibernated(
            id: terminalID, sessionID: "sess-retry")
        #expect(await subject.wake(terminalID: terminalID) == .ok)
    }

    /// Two concurrent wakes, two parked terminals, SAME server, both windows
    /// dead: both must succeed with DISTINCT fresh window ids and exactly two
    /// new-window commands — no lost wake, no hijack, no deadlock.
    @Test func concurrentWakesOnSameServerBothRecreateDistinctWindows() async throws {
        let (db, wtID, terminalA) = try await setup()
        try await db.terminals.setHibernated(id: terminalA, sessionID: "sess-1")
        let terminalB = try await db.terminals.create(
            worktreeID: wtID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-2", kind: .claude
        )
        try await db.terminals.setHibernated(id: terminalB.id, sessionID: "sess-2")
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true }
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        async let wakeA = coord.wake(terminalID: terminalA)
        async let wakeB = coord.wake(terminalID: terminalB.id)
        let (resultA, resultB) = await (wakeA, wakeB)
        #expect(resultA == .ok)
        #expect(resultB == .ok)

        let afterA = try await db.terminals.get(id: terminalA)
        let afterB = try await db.terminals.get(id: terminalB.id)
        #expect(afterA?.isParked == false)
        #expect(afterB?.isParked == false)
        #expect(afterA?.tmuxWindowID.hasPrefix("@mock-") == true)
        #expect(afterB?.tmuxWindowID.hasPrefix("@mock-") == true)
        #expect(afterA?.tmuxWindowID != afterB?.tmuxWindowID,
                "serialized wakes must mint DISTINCT windows; got \(String(describing: afterA?.tmuxWindowID)) and \(String(describing: afterB?.tmuxWindowID))")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        let newWindowCount = joined.filter { $0.contains("new-window") }.count
        #expect(newWindowCount == 2,
                "expected exactly two new-window commands (one per wake); got \(newWindowCount) in: \(joined)")
        #expect(joined.filter { $0.contains("respawn-window") && $0.contains("@mock-") }.count == 2,
                "each replacement must receive one respawn; got: \(joined)")
        #expect(!joined.contains { command in
            command.contains("respawn-window")
                && (command.contains("-t @0") || command.contains("-t @1"))
        }, "dead windows must never be respawned into; got: \(joined)")
    }

    /// Two concurrent wakes on DIFFERENT servers: the per-server lock must
    /// not serialize (or deadlock) across servers — both complete `.ok` and
    /// each server saw its own new-window.
    @Test func concurrentWakesOnDifferentServersDoNotSerialize() async throws {
        let db = try TBDDatabase(inMemory: true)
        // wake() refuses to respawn into a missing directory, so the (shared,
        // idempotently created) fixture paths must exist on disk.
        for path in ["/tmp/hib-repo", "/tmp/hib-repo-a", "/tmp/hib-repo-b"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let repo = try await db.repos.create(path: "/tmp/hib-repo", displayName: "test", defaultBranch: "main")
        let wtA = try await db.worktrees.create(
            repoID: repo.id, name: "wt-a", branch: "a",
            path: "/tmp/hib-repo-a", tmuxServer: "tbd-hib-a"
        )
        let wtB = try await db.worktrees.create(
            repoID: repo.id, name: "wt-b", branch: "b",
            path: "/tmp/hib-repo-b", tmuxServer: "tbd-hib-b"
        )
        let terminalA = try await db.terminals.create(
            worktreeID: wtA.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude
        )
        let terminalB = try await db.terminals.create(
            worktreeID: wtB.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-2", kind: .claude
        )
        try await db.terminals.setHibernated(id: terminalA.id, sessionID: "sess-1")
        try await db.terminals.setHibernated(id: terminalB.id, sessionID: "sess-2")
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true }
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        async let wakeA = coord.wake(terminalID: terminalA.id)
        async let wakeB = coord.wake(terminalID: terminalB.id)
        let (resultA, resultB) = await (wakeA, wakeB)
        #expect(resultA == .ok, "different servers must not serialize/deadlock each other")
        #expect(resultB == .ok, "different servers must not serialize/deadlock each other")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("new-window") && $0.contains("-L tbd-hib-a") },
                "server A must have recorded its own recreate; got: \(joined)")
        #expect(joined.contains { $0.contains("new-window") && $0.contains("-L tbd-hib-b") },
                "server B must have recorded its own recreate; got: \(joined)")
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

    /// Recreate FAILS (window dead + createWindow errors): result is
    /// `.respawnFailed` with a reason naming the dead window, the row STAYS
    /// parked for a later retry, and the tmux ids are unchanged.
    @Test func wakeReturnsRespawnFailedWhenRecreateFails() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let tmux = TmuxManager(
            dryRun: true,
            dryRunWindowIsDead: { $0 == "@0" },
            dryRunCreateWindowError: { _ in TmuxError.unexpectedOutput("no server running") }
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        let wake = await coord.wake(terminalID: terminalID)
        guard case .respawnFailed(let reason) = wake else {
            Issue.record("expected .respawnFailed, got \(wake)")
            return
        }
        #expect(reason.contains("@0"), "reason must name the gone window; got: \(reason)")
        #expect(reason.contains("could not be recreated"), "reason must say recreate failed; got: \(reason)")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == true, "a failed wake must leave the row parked for retry")
        #expect(after?.tmuxWindowID == "@0", "tmux ids must be unchanged on failure")
    }

    @Test func deadWindowWakeReportsStaleStateAsRetryable() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let recorder = BlockingRespawnRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.record,
            dryRunWindowIsDead: { $0 == "@0" })
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        recorder.arm(matching: "new-window")
        let wake = gateHoldingTask { await coord.wake(terminalID: terminalID) }
        guard await waitUntil({ recorder.isBlocked }) else {
            recorder.release()
            _ = await wake.value
            Issue.record("wake never reached replacement window creation")
            return
        }
        try await db.terminals.updateSessionID(
            id: terminalID, sessionID: "replacement-session")
        recorder.release()

        #expect(await wake.value == .respawnFailed(
            reason: "terminal changed before wake could launch; retry"))
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged.tmuxWindowID == "@0")
        #expect(unchanged.tmuxPaneID == "%0")
        #expect(unchanged.isParked)
    }

    /// Respawn FAILS (window alive but respawn-window errors): result is
    /// `.respawnFailed` naming the respawn, and the row stays parked.
    @Test func wakeReturnsRespawnFailedWhenRespawnFails() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRespawnWindowError: { $0 == "@0" ? TmuxError.unexpectedOutput("pane died") : nil }
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        let wake = await coord.wake(terminalID: terminalID)
        guard case .respawnFailed(let reason) = wake else {
            Issue.record("expected .respawnFailed, got \(wake)")
            return
        }
        #expect(reason.contains("respawn"), "reason must name the respawn failure; got: \(reason)")
        #expect(reason.contains("@0"), "reason must name the window; got: \(reason)")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == true, "a failed wake must leave the row parked for retry")
    }

    @Test func liveWindowLaunchFailurePreservesResumeIdentityForRetry() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/live-wake-retry.jsonl")
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let failures = FailFirstRespawn()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorded.append,
            dryRunRespawnWindowError: failures.error)
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        guard case .respawnFailed = await coord.wake(terminalID: terminalID) else {
            Issue.record("first live-window wake must expose the launch failure")
            return
        }
        let failed = try #require(try await db.terminals.get(id: terminalID))
        #expect(failed.isParked)
        #expect(failed.claudeSessionID == "sess-1")
        #expect(failed.transcriptPath == "/tmp/live-wake-retry.jsonl")

        #expect(await coord.wake(terminalID: terminalID) == .ok)
        let retried = try #require(try await db.terminals.get(id: terminalID))
        #expect(!retried.isParked)
        #expect(retried.claudeSessionID == "sess-1")
        #expect(retried.transcriptPath == "/tmp/live-wake-retry.jsonl")
        #expect(recorded.snapshot().filter {
            $0.contains("respawn-window") && $0.last?.contains("--resume sess-1") == true
        }.count == 2)
    }

    @Test func deadWindowLaunchFailurePreservesResumeIdentityForRetry() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.updateSession(
            id: terminalID,
            sessionID: "sess-1",
            transcriptPath: "/tmp/dead-wake-retry.jsonl")
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let failures = FailFirstRespawn()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorded.append,
            dryRunWindowIsDead: { $0 == "@0" },
            dryRunRespawnWindowError: failures.error)
        let coord = HibernationCoordinator(
            db: db,
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())

        guard case .respawnFailed = await coord.wake(terminalID: terminalID) else {
            Issue.record("first dead-window wake must expose the launch failure")
            return
        }
        let failed = try #require(try await db.terminals.get(id: terminalID))
        #expect(failed.isParked)
        #expect(failed.tmuxWindowID == "@mock-0")
        #expect(failed.claudeSessionID == "sess-1")
        #expect(failed.transcriptPath == "/tmp/dead-wake-retry.jsonl")

        #expect(await coord.wake(terminalID: terminalID) == .ok)
        let retried = try #require(try await db.terminals.get(id: terminalID))
        #expect(!retried.isParked)
        #expect(retried.claudeSessionID == "sess-1")
        #expect(retried.transcriptPath == "/tmp/dead-wake-retry.jsonl")
        #expect(recorded.snapshot().filter {
            $0.contains("respawn-window") && $0.last?.contains("--resume sess-1") == true
        }.count == 2)
    }

    /// The wake transcript sync must resolve the ambient (nil-profile)
    /// projects root through the INJECTED `configDirManager` — the seam this
    /// suite relies on to stay out of the real `~/.claude`. A transcript
    /// parked under an old munged dir inside the injected root gets mirrored
    /// into the dir derived from the worktree's current path.
    @Test func wakeSyncsTranscriptViaInjectedConfigDirManager() async throws {
        let (db, _, terminalID) = try await setup()
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
            actuationLog: makeTestActuationLog()
        )
        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)

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

    private func coordinatorWithResolver(_ db: TBDDatabase) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            modelProfileResolver: ModelProfileResolver(
                profiles: db.modelProfiles, repos: db.repos, config: db.config,
                keychain: { _ in nil }),
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
    }

    /// Wake refuses when the pinned profile ID no longer exists, returning
    /// `.profileMissing` with the profile id. The row stays parked, retryable.
    @Test func wakeRefusesWhenPinnedProfileMissing() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let bogusProfileID = UUID()
        try await db.terminals.setProfileID(id: terminalID, profileID: bogusProfileID)

        let coord = coordinatorWithResolver(db)
        let wake = await coord.wake(terminalID: terminalID)

        #expect(wake == .profileMissing(profileID: bogusProfileID))
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil, "row must stay parked and retryable")
    }

    /// Wake succeeds when `allowDefaultProfileFallback: true` is passed, even
    /// if the pinned profile is missing. The row is un-parked.
    @Test func wakeWithFallbackResumesDespiteMissingProfile() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let bogusProfileID = UUID()
        try await db.terminals.setProfileID(id: terminalID, profileID: bogusProfileID)

        let coord = coordinatorWithResolver(db)
        let wake = await coord.wake(terminalID: terminalID, allowDefaultProfileFallback: true)

        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil, "row must be un-parked")
    }

    /// Wake succeeds (and doesn't return `.profileMissing`) when the pinned
    /// profile actually resolves. Tests the happy path isn't broken by the check.
    @Test func wakeSucceedsWhenPinnedProfileResolves() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        // Create a real oauth profile (oauth resolves without a keychain secret).
        let profile = try await db.modelProfiles.create(name: "test", kind: .oauth)
        try await db.terminals.setProfileID(id: terminalID, profileID: profile.id)

        let coord = coordinatorWithResolver(db)
        let wake = await coord.wake(terminalID: terminalID)

        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt == nil, "row must be un-parked")
    }

    @Test func coldProfileSwapWinsBeforeWakeLaunch() async throws {
        let (db, _, terminalID) = try await setup()
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

        #expect(await wake.value != .ok)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == swapped)
        #expect(commands.snapshot().count == commandCount,
                "a wake prepared for the old profile must not launch")
        #expect(deltas.snapshot().filter { delta in
            if case .terminalHibernationChanged = delta { return true }
            return false
        }.isEmpty, "the rejected wake must not broadcast an unpark")
    }

    @Test func wakeWinsBeforeColdProfileSwapCommit() async throws {
        let (db, _, terminalID) = try await setup()
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

        #expect(await coordinator.wake(terminalID: terminalID) == .ok)
        let woken = try #require(try await db.terminals.get(id: terminalID))
        #expect(!woken.isParked)
        #expect(woken.profileID == oldProfile.id)
        let commandCount = commands.snapshot().count
        keychainGate.release()

        #expect(!(await swap.value).success)
        let unchanged = try #require(try await db.terminals.get(id: terminalID))
        #expect(unchanged == woken)
        #expect(commands.snapshot().count == commandCount)
        #expect(deltas.snapshot().filter { delta in
            if case .terminalProfileChanged = delta { return true }
            return false
        }.isEmpty, "the rejected cold swap must not broadcast a profile change")
    }

    /// When no resolver is injected, the profile check doesn't fire — even if a
    /// profileID is pinned. This pins that the plain `coordinator(db)` (used by
    /// other tests) is unaffected.
    @Test func wakeIgnoresProfileCheckWhenNoResolverInjected() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let bogusProfileID = UUID()
        try await db.terminals.setProfileID(id: terminalID, profileID: bogusProfileID)

        // Plain coordinator with no resolver.
        let coord = coordinator(db)
        let wake = await coord.wake(terminalID: terminalID)

        #expect(wake == .ok, "without a resolver, no profile check fires")
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

        // Pane still runs claude (reported as its version string) → the parked
        // state is stale and must be cleared.
        let tmux = TmuxManager(dryRun: true, dryRunPaneCurrentCommand: { _, _ in "1.2.3" })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        await coord.reconcileOnStartup()

        let reconciled = try #require(try await db.terminals.get(id: terminalID))
        #expect(reconciled.hibernatedAt == nil,
                "a still-running claude must have its stale parked timestamp cleared")
        #expect(reconciled.claudeSessionID == parked.claudeSessionID)
        #expect(reconciled.transcriptPath == parked.transcriptPath)
        #expect(reconciled.sessionIncarnationID == parked.sessionIncarnationID)
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

        let tmux = TmuxManager(dryRun: true, dryRunPaneCurrentCommand: { _, _ in "1.2.3" })
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
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

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
    @Test func wakePublishesNilSnapshotAndReasonOnDelta() async throws {
        let (db, _, terminalID) = try await setup()
        let recorder = RecordedHibernationDeltas()
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "FROZEN PANE" })
        let coord = HibernationCoordinator(
            db: db, tmux: tmux,
            subscriptions: recorder.subscriptions(),
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

        _ = await coord.manualHibernate(terminalID: terminalID)
        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)

        let delta = recorder.snapshot().last
        #expect(delta?.hibernated == false)
        #expect(delta?.suspendedSnapshot == nil)
        #expect(delta?.hibernateReason == nil)
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
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

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
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())

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
    /// about how long a polite `/exit` waits.
    private func sweepCoordinator(
        _ db: TBDDatabase, logPath: String, dates: TestDateSource
    ) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            now: dates.provider,
            exitPollAttempts: 1, exitPollInterval: .milliseconds(1),
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
}

/// `terminal.wake` RPC error mapping. The shared `RPCRouterTests` harness pins
/// a plain dry-run TmuxManager, so this suite builds its own router with a
/// failing tmux to drive the `.respawnFailed` path end-to-end.
@Suite("RPCRouter terminal.wake error mapping")
struct RPCRouterWakeErrorMappingTests {

    /// A wake whose tmux window is gone AND cannot be recreated must surface
    /// the REAL failure over RPC — naming the window — and never the
    /// misleading "Terminal not found" (the terminal row exists; the WINDOW
    /// is gone).
    @Test func wakeRespawnFailureIsNotReportedAsTerminalNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(
            dryRun: true,
            dryRunWindowIsDead: { $0 == "@0" },
            dryRunCreateWindowError: { _ in TmuxError.unexpectedOutput("no server running") }
        )
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog()
        )
        let repo = try await db.repos.create(path: "/tmp/hib-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/hib-repo", tmuxServer: "tbd-hib"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude
        )
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error != "Terminal not found",
                "a tmux failure must not masquerade as a missing terminal row")
        #expect(resp.error?.contains("@0") == true,
                "the RPC error must name the gone window; got: \(resp.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == true,
                "the row must stay parked so a retry can wake it")
    }
}

/// `terminal.wake` prompt delivery over RPC — the safety contract nightwatch
/// wake.py relies on: a `prompt` reaches ONLY a session this call actually
/// woke (`woken: true`); the idempotent no-op paths report `woken: false`
/// and never deliver it anywhere.
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

    private func makeTerminal(db: TBDDatabase) async throws -> Terminal {
        let repo = try await db.repos.create(path: "/tmp/wake-prompt-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/wake-prompt-repo", tmuxServer: "tbd-wake-prompt"
        )
        return try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude
        )
    }

    /// Parked terminal: the RPC reports `woken: true` and the respawned
    /// `claude --resume` command carries the prompt as a trailing argv.
    @Test func wakeOnParkedDeliversPromptAndReportsWokenTrue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        try FileManager.default.createDirectory(atPath: "/tmp/wake-prompt-repo", withIntermediateDirectories: true)
        let terminal = try await makeTerminal(db: db)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "verify live state first")
        )
        let resp = await makeRouter(db: db, tmux: tmux).handle(req)
        #expect(resp.success)
        #expect(try resp.decodeResult(TerminalWakeResult.self).woken == true)

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("claude --resume sess-1") && $0.contains("'verify live state first'") },
                "the respawn must carry the prompt as a trailing argv; got: \(joined)")
    }

    /// Already-awake terminal (the race wake.py guards against): the RPC
    /// reports `woken: false`, touches no tmux pane, and the prompt is
    /// delivered NOWHERE — not typed, not pasted, not queued.
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

private final class MutableHibernationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let firstCapture: AsyncStream<Void>
    private let firstCaptureContinuation: AsyncStream<Void>.Continuation
    private var captures = 0
    private var pendingInput = false

    init() {
        (firstCapture, firstCaptureContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var count: Int { lock.withLock { captures } }

    var capture: @Sendable (String, String) -> String {
        { [self] _, _ in
            lock.withLock {
                captures += 1
                if captures == 1 {
                    firstCaptureContinuation.yield()
                }
                return pendingInput ? "> preserve this typed prompt" : ""
            }
        }
    }

    func waitForFirstCapture() async {
        var iterator = firstCapture.makeAsyncIterator()
        _ = await iterator.next()
    }

    func setPendingInput() {
        lock.withLock { pendingInput = true }
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

private final class FailFirstRespawn: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    var error: @Sendable (String) -> Error? {
        { [self] _ in
            lock.withLock {
                guard !hasFailed else { return nil }
                hasFailed = true
                return TmuxError.unexpectedOutput("first replacement launch failed")
            }
        }
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

private final class BlockingCapturePane: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var blocked = false

    var isBlocked: Bool { lock.withLock { blocked } }

    var capture: @Sendable (String, String) -> String {
        { [self] _, _ in
            lock.withLock { blocked = true }
            releaseGate.waitForGate("pre-hibernation capture")
            return ""
        }
    }

    func release() {
        releaseGate.signal()
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
