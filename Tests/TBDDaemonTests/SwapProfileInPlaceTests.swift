import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// `terminal.swapProfile` in place — "Switch account" on a live Claude session:
/// what holds it, what it must survive between ending the old process and
/// starting the new one, and when it writes the new process's overlay.
///
/// Nested under `TBDHomeSerialized`: the per-session overlay resolves through
/// the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct SwapProfileInPlaceTests {

    private struct Scratch {
        let home: URL
        let prior: String?
        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-swap-in-place-\(UUID().uuidString)", isDirectory: true)
            prior = setTBDHome(home.path)
        }
        func cleanUp() {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let terminal: Terminal
        let deltas: FireRecorder<StateDelta>
        /// Where the swap's SIGTERM goes. A fake, so nothing real is signalled.
        let signaller: FakeProcessSignaller
    }

    /// The pane's shell pid, as the dry-run tmux answers it, and the Claude
    /// process the inspector finds beneath it: the pid the swap's signal
    /// ending sends SIGTERM to. Both sit above macOS's PID_MAX (99999), so
    /// neither can name a real process.
    private static let shellPID: Int32 = 900_021
    private static let claudePID: Int32 = 900_022

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-in-place-claude-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    /// A live (unparked) Claude terminal in a worktree whose path exists on
    /// disk.
    ///
    /// - Parameter withConversation: when true the session's transcript carries
    ///   a user message, so `isSessionBlank` is false and the swap takes the
    ///   **resume** branch; when false it takes the **fresh** branch.
    private func makeFixture(
        _ scratch: Scratch, withConversation: Bool,
        recorder: (@Sendable ([String]) -> Void)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        sessionsDir: URL? = nil
    ) async throws -> Fixture {
        let repoPath = scratch.home.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: repoPath,
            tmuxServer: "tbd-swap-in-place")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-swap", kind: .claude)
        if withConversation {
            let transcript = scratch.home.appendingPathComponent("sess-swap.jsonl").path
            let record = #"{"type":"user","message":{"content":"hello"}}"# + "\n"
            try Data(record.utf8).write(to: URL(fileURLWithPath: transcript))
            try await db.terminals.updateSession(
                id: terminal.id, sessionID: "sess-swap", transcriptPath: transcript)
        }
        // The pane answers a shell pid with Claude beneath it, so the swap's
        // signal ending finds a process to SIGTERM and then polls on `clock`.
        // The dry-run pane reports `zsh` as its current command, so the first
        // poll after that sleep sees Claude gone.
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: recorder,
            dryRunPanePID: { _, _ in String(Self.shellPID) })
        let signaller = FakeProcessSignaller()
        let deltas = FireRecorder<StateDelta>()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.record(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            subscriptions: subscriptions,
            configDirManager: isolatedConfigDirManager(),
            paneProcessInspector: FakeInspector(claudePID: Self.claudePID),
            processSignaller: signaller,
            sessionsDir: sessionsDir ?? TBDConstants.sessionsDir(),
            actuationLog: makeTestActuationLog(),
            clock: clock)
        let reloaded = try #require(try await db.terminals.get(id: terminal.id))
        return Fixture(
            db: db, router: router, terminal: reloaded, deltas: deltas, signaller: signaller)
    }

    private func swap(
        _ fixture: Fixture, mode: TerminalSwapMode
    ) async throws -> RPCResponse {
        let request = try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: fixture.terminal.id, newProfileID: nil, mode: mode))
        return await fixture.router.handle(request)
    }

    /// Hold branch only: a swap that is not held waits on the injected clock for
    /// Claude to leave, and the flag-off branch of the gate is covered for every
    /// caller by `StartAdmissionRouterTests`.
    @Test("start admission holds an in-place swap before the session is signalled")
    func startAdmissionHoldsTheSwap() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, withConversation: true,
            recorder: { commands.record($0) })
        let stub = StubAdmission(.hold(reason: "camera in use"))
        fixture.router.startAdmission = stub
        try await fixture.db.config.setStartAdmissionEnabled(true)

        let response = try await swap(fixture, mode: .inPlace)

        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(response.error == "camera in use")
        #expect(stub.requests.map(\.kind) == [.create])
        #expect(stub.requests.first?.terminalID == fixture.terminal.id)
        #expect(fixture.signaller.terminatedProcessOnly.isEmpty)
        #expect(!commands.values.contains { $0.contains("respawn-window") })
        #expect(try await fixture.db.terminals.get(id: fixture.terminal.id) == fixture.terminal)
    }

    // MARK: -

    /// The swap's SIGTERM can deliver SessionEnd before respawn. That hook
    /// must describe the predecessor, never park the row being replaced.
    ///
    /// The hook lands while the signal ending polls for Claude to leave: the
    /// one sleep between the SIGTERM and the respawn. A wait reason the
    /// predecessor reported is gone with it: the new incarnation starts with
    /// none.
    @Test(.clockDriven)
    func sessionEndDuringTheSignalEndingDoesNotAbortSwap() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let clock = EventDrivenTestClock()
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, withConversation: true,
            recorder: { commands.record($0) }, clock: clock)
        let predecessor = fixture.terminal
        let reason = try #require(ProgramStatusColumnValue.waitingForUser(
            ProgramStatusBlock(kind: .permission, taskID: nil)).awaitingInputReason)
        _ = try #require(try await fixture.db.terminals.applyProgramStatusActivity(
            id: predecessor.id, scope: .anyLiveIncarnation, activityState: .waitingForUser,
            awaitingInputReason: reason, observedAt: Date()))
        let task = Task { try await swap(fixture, mode: .inPlace) }
        defer { task.cancel() }

        try await clock.requireSleeperArmed()
        #expect(fixture.signaller.terminatedProcessOnly == [Self.claudePID],
                "the swap was not polling after its SIGTERM")
        let stamped = try await fixture.db.terminals.stampSessionExited(
            id: predecessor.id,
            reportedIncarnationID: predecessor.sessionIncarnationID)
        #expect(!stamped, "the signalled predecessor must already be fenced")

        try await clock.requireAdvanceWhenArmed(
            by: fixture.router.hibernationCoordinator.exitPollInterval)

        let response = try await task.value
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")
        let after = try #require(try await fixture.db.terminals.get(id: predecessor.id))
        #expect(!after.isParked)
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        #expect(fixture.deltas.values.contains {
            guard case .terminalAwaitingInputChanged(let delta) = $0 else { return false }
            return delta.terminalID == predecessor.id && delta.reason == nil
        }, "the swap must retract the predecessor's reason for subscribers")
        #expect(after.sessionIncarnationID != predecessor.sessionIncarnationID)
        #expect(after.claudeSessionID == predecessor.claudeSessionID)
        #expect(after.transcriptPath == predecessor.transcriptPath)
        #expect(after.tmuxWindowID == predecessor.tmuxWindowID)
        #expect(after.tmuxPaneID == predecessor.tmuxPaneID)
        #expect(try await fixture.db.terminals.list(worktreeID: after.worktreeID).count == 1)
        #expect(commands.values.filter { $0.contains("respawn-window") }.count == 1)
        #expect(!commands.values.contains { $0.contains("new-window") })
        #expect(!commands.values.contains { $0.contains("send-keys") },
                "the swap typed into the pane it was ending")
    }

    // MARK: - The session mod and the overlay across the swap

    /// A sessions directory under the scratch home.
    private func sessionsDir(_ scratch: Scratch) throws -> URL {
        let url = scratch.home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A settings fragment for the fixture's repo, which makes the swap's
    /// overlay per-session — so the per-session file is the one a launch
    /// would rewrite.
    private func writeRepoFragment(_ fixture: Fixture) async throws {
        let worktree = try #require(try await fixture.db.worktrees.get(id: fixture.terminal.worktreeID))
        let repoID = try #require(worktree.repoID)
        let path = TBDConstants.claudeSettingsOverlayPath(repoID: repoID)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"skillOverrides":{"x":"off"}}"#.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// The overlay is written by the launch, so a swap that fails before its
    /// replacement starts leaves the running process's overlay as it was.
    ///
    /// The failure is staged at the swap's replacement reservation, the first
    /// write of the arm: after the overlay is planned and before the old
    /// process is signalled or anything is launched.
    @Test func anInPlaceSwapThatFailsBeforeLaunchLeavesTheOverlayAlone() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, withConversation: true, recorder: { commands.record($0) })
        try await writeRepoFragment(fixture)
        let key = fixture.terminal.id.uuidString
        let running = Data(#"{"previous":"life"}"#.utf8)
        let overlayPath = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: overlayPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try running.write(to: URL(fileURLWithPath: overlayPath))
        try await fixture.db.writerForTests.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_swap_reservation
                BEFORE UPDATE OF profile_id ON terminal
                BEGIN
                    SELECT RAISE(FAIL, 'injected reservation failure');
                END
                """)
        }

        let response = try await swap(fixture, mode: .inPlace)

        #expect(!response.success)
        #expect(response.error?.contains("injected reservation failure") == true,
                "the swap failed somewhere other than its reservation: \(response.error ?? "success")")
        #expect(fixture.signaller.terminatedProcessOnly.isEmpty,
                "the swap signalled the old process before failing")
        #expect(!commands.values.contains { $0.contains("respawn-window") },
                "the swap launched a replacement")
        #expect(try Data(contentsOf: URL(fileURLWithPath: overlayPath)) == running,
                "a swap that launched nothing rewrote the running process's overlay")
    }

    /// The other side of the same rule: a swap that launches writes the
    /// overlay its command names, replacing the one the old process ran with.
    @Test func anInPlaceSwapThatLaunchesRewritesTheOverlay() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(scratch, withConversation: true)
        try await writeRepoFragment(fixture)
        let overlayPath = ClaudeHookOverlay.perSessionOverlayPath(
            sessionKey: fixture.terminal.id.uuidString)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: overlayPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"previous":"life"}"#.utf8).write(to: URL(fileURLWithPath: overlayPath))

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        #expect(try Data(contentsOf: URL(fileURLWithPath: overlayPath))
                == (try ClaudeHookOverlay.generateBody(
                    extraSettings: ["skillOverrides": ["x": "off"]])))
    }

    @Test func anInPlaceSwapWithUsageOnRecordsTheFeature() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let sessions = try sessionsDir(scratch)
        let fixture = try await makeFixture(
            scratch, withConversation: true, sessionsDir: sessions)
        try await fixture.db.config.setSessionModUsageEnabled(true)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        let record = try #require(readSpawnRecord(sessionsDir: sessions, sessionID: "sess-swap"))
        #expect(record.features == ["usage"])
    }
}
}
