import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// The pane-ownership guard (`TmuxManager.paneOwnership`) extended to every
/// other call site that tears down a tmux window by DB-recorded coordinate.
/// There are four. `terminal.delete` is the first and is covered by
/// `TerminalDeletePaneOwnershipTests`; the other three each have a `MARK:`
/// section below:
///
/// - `captureThenKillWindow`, shared by the archive path and the
///   vanished-worktree reconcile sweep
/// - `forgetWorktree`
/// - `scratch.delete`'s teardown
///
/// The transport migration is not one of them: it moves a tmux row only once
/// its server is gone, so it has no window to tear down.
///
/// `terminal.recreateWindow` is not one of them: it refuses every tmux row
/// before it consults a pane or kills anything.
///
/// All of them `kill-window` the exact same way and share the exact same
/// hazard: a tmux server restart resets window/pane numbering, and several
/// worktrees of one repo share a server, so a stale row's coordinate can
/// collide with an unrelated live terminal's.
///
/// Every refusal case runs twice: once against a pane that positively names a
/// stranger, and once against a probe that could not run at all (a wedged
/// server). The second is "we do not know", not "gone", so it refuses too —
/// the same stance the reconcile sweep takes on an unreadable identity.
@Suite("kill-window sibling sites — pane-ownership guard")
struct KillWindowSiblingSitesPaneOwnershipTests {

    private func isolatedConfigDirManager(_ tag: String) -> ClaudeProfileConfigDirManager {
        makeIsolatedConfigDirManager(tag: tag)
    }

    // MARK: - captureThenKillWindow (archive path + vanished-worktree reconcile)

    /// Shared by the explicit archive path and the vanished-worktree
    /// reconcile sweep — guarding here covers both. A mismatch must not
    /// capture the stranger's screen into this row's Closed Terminals
    /// history, nor destroy their window.
    @Test(arguments: RefusingPaneAnswer.allCases)
    func captureThenKillWindowLeavesAWindowUntouchedWhenItsPaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/kwss-capture-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/kwss-capture-wt-\(UUID().uuidString)", tmuxServer: "tbd-kwss-capture")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in try refusal.answer() })
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())

        await lifecycle.captureThenKillWindow(terminal: terminal, server: wt.tmuxServer)

        #expect(!recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane not provably this terminal's must never be kill-windowed: \(recorder.snapshot())")
        let captured = try await db.terminalHistory.list(worktreeID: wt.id)
        #expect(captured.isEmpty,
                "an unverified pane's screen must never be captured into this row's Closed Terminals history")
    }

    /// The positive control: a pane answering with the row's own id captures
    /// and kills exactly as before.
    @Test func captureThenKillWindowProceedsWhenThePaneAnswersWithItsOwnID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/kwss-capture-ok-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/kwss-capture-ok-wt-\(UUID().uuidString)", tmuxServer: "tbd-kwss-capture-ok")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: terminal.id.uuidString) })
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())

        await lifecycle.captureThenKillWindow(terminal: terminal, server: wt.tmuxServer)

        #expect(recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane confirmed as this row's own must still be killed: \(recorder.snapshot())")
    }

    // MARK: - forgetWorktree

    @Test(arguments: RefusingPaneAnswer.allCases)
    func forgetLeavesAWindowUntouchedWhenItsPaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/kwss-forget-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/kwss-forget-wt-\(UUID().uuidString)", tmuxServer: "tbd-kwss-forget")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in try refusal.answer() })
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())

        try await lifecycle.forgetWorktree(worktreeID: wt.id)

        #expect(try await db.worktrees.get(id: wt.id) == nil,
                "forget must still remove the worktree row")
        #expect(try await db.terminals.get(id: terminal.id) == nil,
                "forget must still remove the stale terminal row")
        #expect(!recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane not provably this terminal's must never be kill-windowed: \(recorder.snapshot())")
    }

    // MARK: - scratch.delete

    @Test(arguments: RefusingPaneAnswer.allCases)
    func scratchDeleteLeavesAWindowUntouchedWhenItsPaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await db.worktrees.createScratch(
            name: "scratch", displayName: "scratch",
            path: "/tmp/kwss-scratch-\(UUID().uuidString)", tmuxServer: "tbd-kwss-scratch")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in try refusal.answer() })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())

        let resp = try await router.handle(try RPCRequest(
            method: RPCMethod.scratchDelete,
            params: ScratchDeleteParams(worktreeID: wt.id)))

        #expect(resp.success, "the scratch space must still be removed")
        #expect(try await db.terminals.get(id: terminal.id) == nil,
                "scratch delete must still remove the stale terminal row")
        #expect(!recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane not provably this terminal's must never be kill-windowed: \(recorder.snapshot())")
    }
}

/// The two pane answers that must refuse a teardown: a positive mismatch, and
/// a consultation that could not be run at all.
enum RefusingPaneAnswer: String, CaseIterable, Sendable {
    case stranger
    case unreadable

    func answer() throws -> PaneSendTarget {
        switch self {
        case .stranger:
            return .live(terminalID: UUID().uuidString)
        case .unreadable:
            throw TmuxError.timedOut(command: "list-panes", timeout: .seconds(5))
        }
    }
}
