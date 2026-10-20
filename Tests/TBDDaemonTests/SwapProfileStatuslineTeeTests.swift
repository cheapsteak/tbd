import Foundation
import GRDB
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// The statusline tee across `terminal.swapProfile` — "Switch account" on a
/// Watch Desk.
///
/// An `.inPlace` swap keeps the terminal row (`plannedTerminalID ==
/// oldTerminal.id`) and never touches `watch_desk_role`, so the row goes on
/// claiming to be a desk across the respawn. Resolving the overlay without that
/// role would leave it running with no tee — and, because a roleless resolve
/// deletes the session's capture, with no denominator either — while
/// `session.states` keeps reporting "the tee is installed but has not fired
/// yet" forever.
///
/// A `.fork` swap is the opposite case: it mints a fresh row branded no desk, so
/// its overlay must carry no tee or the two would disagree the other way.
///
/// Nested under `TBDHomeSerialized`: the per-session overlay and the capture
/// path resolve through the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct SwapProfileStatuslineTeeTests {

    private struct Scratch {
        let home: URL
        let prior: String?
        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-swap-tee-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("tbd-swap-tee-claude-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    /// A live (unparked) Claude terminal, optionally branded a desk, in a
    /// worktree whose path exists on disk.
    ///
    /// - Parameter withConversation: when true the session's transcript carries
    ///   a user message, so `isSessionBlank` is false and the swap takes the
    ///   **resume** branch; when false it takes the **fresh** branch. Both
    ///   branches resolve their own overlay, so both are covered.
    private func makeFixture(
        _ scratch: Scratch, desk: Bool, withConversation: Bool,
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
            tmuxServer: "tbd-swap-tee")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-swap", kind: .claude,
            watchDeskRole: desk ? .readOnlyCoordinator : nil)
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

    private func statusLineCommand(forSessionKey key: String) -> String? {
        let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = parsed["statusLine"] as? [String: Any] else {
            return nil
        }
        return entry["command"] as? String
    }

    // MARK: -

    /// The swap's SIGTERM can deliver SessionEnd before respawn. That hook
    /// must describe the predecessor, never park the row being replaced.
    ///
    /// The hooks land while the signal ending polls for Claude to leave: the
    /// one sleep between the SIGTERM and the respawn.
    @Test(.clockDriven, arguments: ["permission_prompt", "idle_prompt"])
    func sessionEndDuringTheSignalEndingDoesNotAbortSwap(notificationType: String) async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let clock = EventDrivenTestClock()
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, desk: false, withConversation: true,
            recorder: { commands.record($0) }, clock: clock)
        let predecessor = fixture.terminal
        let task = Task { try await swap(fixture, mode: .inPlace) }
        defer { task.cancel() }

        try await clock.requireSleeperArmed()
        #expect(fixture.signaller.terminatedProcessOnly == [Self.claudePID],
                "the swap was not polling after its SIGTERM")
        let stamped = try await fixture.db.terminals.stampSessionExited(
            id: predecessor.id,
            reportedIncarnationID: predecessor.sessionIncarnationID)
        #expect(!stamped, "the signalled predecessor must already be fenced")
        // Notification predates incarnation tokens. Unlike SessionEnd it can
        // still write during the ending, so the swap must retract its
        // persisted reason before the successor starts.
        let notification = try RPCRequest(
            method: RPCMethod.terminalNotificationEvent,
            params: TerminalNotificationEventParams(
                terminalID: predecessor.id,
                notificationType: notificationType,
                message: "Predecessor prompt"))
        #expect((await fixture.router.handle(notification)).success)
        let interrupted = try #require(try await fixture.db.terminals.get(id: predecessor.id))
        #expect(interrupted.awaitingInputReason != nil)

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
        }, "successful cleanup must retract the persisted reason for subscribers")
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

    @Test(.clockDriven)
    func promptCleanupFailureStillStartsReplacement() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let clock = EventDrivenTestClock()
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, desk: false, withConversation: true,
            recorder: { commands.record($0) }, clock: clock)
        let task = Task { try await swap(fixture, mode: .inPlace) }
        defer { task.cancel() }

        try await clock.requireSleeperArmed()
        try await fixture.db.terminals.recordAwaitingInputReason(
            id: fixture.terminal.id,
            reason: AwaitingInputReason(message: "Predecessor prompt", hookEventName: "Notification"),
            observedAt: Date())
        // Fail only the post-ending metadata clear, after the replacement
        // reservation has already committed. All reads and respawn work remain
        // available, just as with a transient failure of this one write.
        try await fixture.db.writerForTests.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_prompt_cleanup
                BEFORE UPDATE OF awaitingInputReason ON terminal
                WHEN OLD.awaitingInputReason IS NOT NULL AND NEW.awaitingInputReason IS NULL
                BEGIN
                    SELECT RAISE(FAIL, 'injected prompt cleanup failure');
                END
                """)
        }
        try await clock.requireAdvanceWhenArmed(
            by: fixture.router.hibernationCoordinator.exitPollInterval)

        let response = try await task.value
        #expect(response.success, "metadata cleanup must not abort respawn: \(response.error ?? "")")
        #expect(commands.values.filter { $0.contains("respawn-window") }.count == 1)
        let after = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(after.awaitingInputReason != nil, "the injected write failure must have fired")
        #expect(!fixture.deltas.values.contains {
            guard case .terminalAwaitingInputChanged(let delta) = $0 else { return false }
            return delta.terminalID == after.id && delta.reason == nil
        }, "a failed cleanup must not tell subscribers the persisted reason was cleared")
        #expect(after.sessionIncarnationID != fixture.terminal.sessionIncarnationID)
        #expect(!after.isParked)
    }

    @Test(arguments: [true, false])
    func anInPlaceSwapOnADeskKeepsTheStatuslineTee(withConversation: Bool) async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(
            scratch, desk: true, withConversation: withConversation)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        // The row still claims to be a desk…
        let after = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(after.watchDeskRole != nil)
        // …so the overlay it just respawned with had better install the tee.
        let command = try #require(
            statusLineCommand(forSessionKey: fixture.terminal.id.uuidString),
            "an in-place swap on a desk produced an overlay with no statusLine")
        #expect(command.contains(StatuslineTee.scriptPath))
        // The row is reused, so the capture path is too — and it must still be
        // the one the tee publishes to.
        #expect(command.contains(
            StatuslineTee.capturePath(sessionKey: fixture.terminal.id.uuidString)))
    }

    @Test func anInPlaceSwapOnAnOrdinaryTerminalInstallsNoStatusline() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(scratch, desk: false, withConversation: true)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        // TBD's per-session `--settings` outranks the operator's `statusLine` in
        // every scope they can write, so a leak here takes over a slot they own.
        #expect(statusLineCommand(forSessionKey: fixture.terminal.id.uuidString) == nil)
    }

    // MARK: - A desk whose swap carries the session mod's `usage`

    /// A sessions directory under the scratch home, or — `writable: false` — a
    /// regular file where one should be, so writing a spawn record fails and
    /// `SessionModSpawn.prepare` returns nil.
    private func sessionsDir(_ scratch: Scratch, writable: Bool = true) throws -> URL {
        let url = scratch.home.appendingPathComponent("sessions", isDirectory: true)
        if writable {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                at: scratch.home, withIntermediateDirectories: true)
            try Data("not a directory".utf8).write(to: url)
        }
        return url
    }

    @Test(arguments: [true, false])
    func anInPlaceSwapOnADeskCarryingUsageKeepsThePersonsStatusLine(
        withConversation: Bool
    ) async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let sessions = try sessionsDir(scratch)
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, desk: true, withConversation: withConversation,
            recorder: { commands.record($0) }, sessionsDir: sessions)
        try await fixture.db.config.setSessionModUsageEnabled(true)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        let after = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(after.watchDeskRole != nil)
        #expect(statusLineCommand(forSessionKey: fixture.terminal.id.uuidString) == nil,
                "an in-place swap on a desk carrying usage still took over its statusLine")
        let launch = try #require(
            commands.values.last { $0.contains("respawn-window") }.map(tmuxEnvironmentFlags))
        #expect(launch[SessionModSpawn.featuresVariable] == "usage")
        let sessionID = try #require(after.claudeSessionID)
        let record = try #require(readSpawnRecord(sessionsDir: sessions, sessionID: sessionID))
        #expect(record.features == ["usage"])
    }

    /// Planned `usage`, but the spawn record could not be written, so the
    /// launch carries no mod: the overlay is settled back to the tee before it.
    @Test func anInPlaceSwapOnADeskWhoseSpawnRecordFailsKeepsTheTee() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let blocked = try sessionsDir(scratch, writable: false)
        let commands = FireRecorder<[String]>()
        let fixture = try await makeFixture(
            scratch, desk: true, withConversation: true,
            recorder: { commands.record($0) }, sessionsDir: blocked)
        try await fixture.db.config.setSessionModUsageEnabled(true)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        let command = try #require(
            statusLineCommand(forSessionKey: fixture.terminal.id.uuidString),
            "an in-place swap on a desk spawned without the mod lost its tee")
        #expect(command.contains(StatuslineTee.scriptPath))
        let launch = try #require(
            commands.values.last { $0.contains("respawn-window") }.map(tmuxEnvironmentFlags))
        #expect(launch[SessionModSpawn.featuresVariable] == nil)
    }

    @Test func anInPlaceSwapOnAnOrdinaryTerminalWithUsageOnInstallsNoStatusline() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let sessions = try sessionsDir(scratch)
        let fixture = try await makeFixture(
            scratch, desk: false, withConversation: true, sessionsDir: sessions)
        try await fixture.db.config.setSessionModUsageEnabled(true)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        #expect(statusLineCommand(forSessionKey: fixture.terminal.id.uuidString) == nil)
        let record = try #require(readSpawnRecord(sessionsDir: sessions, sessionID: "sess-swap"))
        #expect(record.features == ["usage"])
    }

    /// The other direction of the same rule. A fork mints a fresh row branded
    /// no desk (`forkSwapNewTab` passes no role), so carrying the source row's
    /// role onto its overlay would install a tee on a session the desk
    /// machinery does not consider a desk.
    @Test func aForkSwapDoesNotCarryTheSourceRowsDeskRole() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(scratch, desk: true, withConversation: true)

        let response = try await swap(fixture, mode: .fork)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        let terminals = try await fixture.db.terminals.list(worktreeID: fixture.terminal.worktreeID)
        let forked = try #require(terminals.first { $0.id != fixture.terminal.id },
                                  "a fork swap created no new terminal")
        #expect(forked.watchDeskRole == nil)
        #expect(statusLineCommand(forSessionKey: forked.id.uuidString) == nil)
    }
}
}
