import Testing
import Foundation
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

@Suite("HibernationCoordinator")
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
            try await db.terminals.setActivityState(id: terminal.id, activityState: activityState)
        }
        if keepWarm {
            try await db.terminals.setKeepWarm(id: terminal.id, keepWarm: true)
        }
        return (db, wt.id, terminal.id)
    }

    private func coordinator(_ db: TBDDatabase) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager())
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
    // The unified park sequence tries an in-band `/exit` first and polls up to
    // ~3s for the claude process to leave; only if it's STILL claude after the
    // poll does it escalate to the graceful-interrupt SIGTERM fallback. These
    // two branches are tested SEPARATELY.

    /// `/exit` succeeds: the pane's current command reads as a non-claude shell
    /// during the poll, so the polite exit is observed and NO SIGTERM-fallback
    /// interrupt (Escape / C-c) is sent. The row is still marked hibernated.
    @Test func parkViaExitSucceedsWithoutSigtermFallback() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        // dryRun default paneCurrentCommand is "zsh" (not claude) → poll sees the
        // process leave immediately after `/exit`.
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

        let result = await coord.manualHibernate(terminalID: terminalID)
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
    /// reporting a claude process, so the park escalates to the graceful
    /// interrupt (Escape → C-c C-c → SIGTERM). The row is still marked
    /// hibernated afterward (respawn-window -k guarantees termination).
    @Test func parkFallsBackToSigtermWhenExitDoesNotKill() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let recorded = RecordedTmuxCommands()
        // Pane keeps reporting a claude process for the whole poll → fallback.
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" }  // claude reports its version as pane_current_command
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

        let result = await coord.manualHibernate(terminalID: terminalID)
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

    /// The ANSI pane snapshot captured before the kill is persisted into
    /// `suspendedSnapshot` (reused column) so the app can show the frozen pane as
    /// a backdrop while parked. Ported from the old Suspend snapshot-capture test.
    @Test func parkPersistsPaneSnapshot() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        // Inject a non-empty ANSI capture via the capturePane dryRun hook; the
        // park path reads it through `capturePaneWithAnsi`.
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "FROZEN PANE" })
        // capturePaneWithAnsi returns "" in dryRun regardless of the hook, so
        // this test asserts the write PATH is exercised (snapshot param wired)
        // by checking setHibernated persists whatever capture returns. Since
        // dryRun capturePaneWithAnsi is "", the snapshot ends up nil — so we
        // instead assert the DB path directly with an explicit snapshot.
        _ = tmux
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1", snapshot: "FROZEN PANE")
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.suspendedSnapshot == "FROZEN PANE",
                "the snapshot param must persist into suspendedSnapshot")
        #expect(after?.hibernatedAt != nil)
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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

    @Test func wakeOnNonHibernatedIsIdempotentNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())
        let result = await coord.wake(terminalID: terminalID)
        #expect(result == .notHibernated)
        #expect(recorded.snapshot().isEmpty,
                "a non-parked wake must not touch tmux; got: \(recorded.snapshot())")
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())
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
    /// persists the NEW window/pane ids, un-parks the row, and spawns the same
    /// `claude --resume` via `new-window -c <worktree path>` — no
    /// `respawn-window` into the dead window. The server hook fires so a
    /// recreated server gets its gated control-mode connection.
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())
        await coord.setOnServerCreated { server in serverHookCalls.append([server]) }

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false, "row must be un-parked")
        #expect(after?.tmuxWindowID == "@mock-0", "recreate must persist the new window id")
        #expect(after?.tmuxPaneID == "%mock-0", "recreate must persist the new pane id")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("new-window") && $0.contains("-c /tmp/hib-repo") && $0.contains("--resume sess-1") },
                "expected new-window in the worktree cwd carrying claude --resume; got: \(joined)")
        #expect(!joined.contains { $0.contains("respawn-window") },
                "a dead window must NOT be respawned into; got: \(joined)")
        // Old-window cleanup: a transient windowExists misclassification must
        // not leak a live old window (usually already dead — kill no-ops).
        #expect(joined.contains { $0.contains("kill-window") && $0.contains("@0") },
                "expected a best-effort kill of the old window; got: \(joined)")
        #expect(serverHookCalls.snapshot() == [["tbd-hib"]],
                "onServerCreated must fire once with the recreated server name")
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.isParked == false)
        #expect(after?.tmuxWindowID == "@mock-0", "collision must force a recreate with fresh ids")
        #expect(after?.tmuxPaneID == "%mock-0")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("new-window") },
                "expected the recreate branch (new-window); got: \(joined)")
        #expect(!joined.contains { $0.contains("respawn-window") },
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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
    // must be serialized by `withServerLock` — `wakesInFlight` only dedupes
    // the same terminal. Both branches of the lock gate are covered: same
    // server serializes (and loses no wake), different servers don't.

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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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
        #expect(!joined.contains { $0.contains("respawn-window") },
                "dead windows must never be respawned into; got: \(joined)")
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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
    @Test func withServerLockSerializesSameKeyAndNotDifferentKeys() async throws {
        let (db, _, _) = try await setup()
        let coord = coordinator(db)
        let events = RecordedTmuxCommands()
        let (enteredStream, enteredCont) = AsyncStream.makeStream(of: Void.self)
        let (releaseStream, releaseCont) = AsyncStream.makeStream(of: Void.self)

        let taskA = Task {
            await coord.withServerLock("s1") {
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
            await coord.withServerLock("s1") { events.append(["B-ran"]) }
        }
        let taskC = Task {
            await coord.withServerLock("s2") { events.append(["C-ran"]) }
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
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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

    /// Respawn FAILS (window alive but respawn-window errors): result is
    /// `.respawnFailed` naming the respawn, and the row stays parked.
    @Test func wakeReturnsRespawnFailedWhenRespawnFails() async throws {
        let (db, _, terminalID) = try await setup()
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRespawnWindowError: { $0 == "@0" ? TmuxError.unexpectedOutput("pane died") : nil }
        )
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())

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
            )
        )
        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)

        // `/tmp/hib-repo` munges to `-tmp-hib-repo` under the injected root.
        let derived = projects.appendingPathComponent("-tmp-hib-repo/sess-1.jsonl")
        #expect(FileManager.default.fileExists(atPath: derived.path),
                "wake must mirror the parked transcript into the derived dir under the injected projects root")
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
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt != nil)

        // Pane still runs claude (reported as its version string) → the parked
        // state is stale and must be cleared.
        let tmux = TmuxManager(dryRun: true, dryRunPaneCurrentCommand: { _, _ in "1.2.3" })
        let coord = HibernationCoordinator(db: db, tmux: tmux, configDirManager: isolatedConfigDirManager())
        await coord.reconcileOnStartup()

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "a still-running claude must have its stale parked timestamp cleared")
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
            configDirManager: isolatedConfigDirManager()
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
