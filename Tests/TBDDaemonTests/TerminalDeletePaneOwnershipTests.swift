import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `terminal.delete`'s pane-ownership guard.
///
/// After a reboot, tmux restarts a server's window/pane numbering from
/// scratch, and several worktrees of one repo share a server — so a stale
/// row's recorded coordinate can collide with a DIFFERENT, freshly-spawned
/// live terminal's. `reconcile()` eventually re-probes and parks such a stale
/// row, but a close racing that window must not `kill-window` a live session
/// it was never asked to touch. This is the actuation-layer backstop:
/// unconditional, and independent of whether or when reconcile last ran.
@Suite("terminal.delete pane-ownership guard")
struct TerminalDeletePaneOwnershipTests {

    private struct Fixture {
        let db: TBDDatabase
        let terminal: Terminal
    }

    private func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/tdpo-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/tdpo-wt-\(UUID().uuidString)", tmuxServer: "tbd-tdpo")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Build", claudeSessionID: "sess-abc", kind: .claude)
        return Fixture(db: db, terminal: terminal)
    }

    private func close(
        _ router: RPCRouter, _ id: UUID
    ) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: id)))
    }

    /// The bug this guard exists to prevent: the pane at the row's recorded
    /// coordinate now belongs to a DIFFERENT terminal. Closing must not
    /// `kill-window` it.
    @Test func refusesToKillAWindowWhosePaneNamesADifferentTerminal() async throws {
        let fx = try await makeFixture()
        var recorded: [[String]] = []
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: UUID().uuidString) })
        let router = RPCRouter(
            db: fx.db,
            lifecycle: WorktreeLifecycle(
                db: fx.db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())

        let resp = try await close(router, fx.terminal.id)

        #expect(resp.success, "the row itself must still close")
        let result = try resp.decodeResult(TerminalDeleteResult.self)
        #expect(result.closed)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil,
                "the stale row must still be removed from the list")
        #expect(!recorded.contains { $0.contains("kill-window") },
                "a pane owned by a different terminal must never be kill-windowed: \(recorded)")
    }

    /// The positive control: a pane answering with THIS row's own id closes
    /// exactly as before — killed.
    @Test func killsTheWindowWhenThePaneAnswersWithItsOwnID() async throws {
        let fx = try await makeFixture()
        var recorded: [[String]] = []
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: fx.terminal.id.uuidString) })
        let router = RPCRouter(
            db: fx.db,
            lifecycle: WorktreeLifecycle(
                db: fx.db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())

        let resp = try await close(router, fx.terminal.id)

        #expect(resp.success)
        #expect(recorded.contains { $0.contains("kill-window") },
                "a pane confirmed as this row's own must still be killed: \(recorded)")
    }

    /// A pane with no identity to compare (unstamped, or a pre-#901 daemon
    /// build) falls back to today's close behavior — killed, not refused.
    @Test func killsTheWindowWhenThePaneCarriesNoIdentity() async throws {
        let fx = try await makeFixture()
        var recorded: [[String]] = []
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) })
        let router = RPCRouter(
            db: fx.db,
            lifecycle: WorktreeLifecycle(
                db: fx.db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())

        let resp = try await close(router, fx.terminal.id)

        #expect(resp.success)
        #expect(recorded.contains { $0.contains("kill-window") },
                "a pane with no identity to compare must fall back to killing the window: \(recorded)")
    }

    /// An unreadable probe (a wedged server) is not evidence of a mismatch
    /// either — it must not newly turn an ordinary close into a refusal.
    @Test func killsTheWindowWhenTheProbeThrows() async throws {
        let fx = try await makeFixture()
        var recorded: [[String]] = []
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunPaneSendTarget: { _, _ in
                throw TmuxError.timedOut(command: "list-panes", timeout: .seconds(5))
            })
        let router = RPCRouter(
            db: fx.db,
            lifecycle: WorktreeLifecycle(
                db: fx.db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())

        let resp = try await close(router, fx.terminal.id)

        #expect(resp.success)
        #expect(recorded.contains { $0.contains("kill-window") },
                "an unreadable probe must fall back to killing the window, not refuse: \(recorded)")
    }
}
