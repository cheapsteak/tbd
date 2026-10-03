import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The pane-ownership guard (`TmuxManager.paneOwnership`) extended to
/// every other call site that tears down a tmux window by DB-recorded
/// coordinate — `terminal.delete` (`TerminalDeletePaneOwnershipTests`) was
/// the first, but `forgetWorktree`, `scratch.delete`'s teardown, and
/// `terminal.recreateWindow`'s non-Claude-resumable branch all `kill-window`
/// the exact same way and share the exact same hazard: a tmux server restart
/// resets window/pane numbering, and several worktrees of one repo share a
/// server, so a stale row's coordinate can collide with an unrelated live
/// terminal's.
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

    // MARK: - terminal.recreateWindow (non-Claude-resumable branch)

    /// The shell-recreate branch: unlike `terminal.delete` and the bulk-kill
    /// teardowns above, this action targets ONE specific row the caller named,
    /// so a mismatch means that row's own coordinate has already been
    /// recycled — the same "stale, please retry" condition every other check
    /// in this handler reports, rather than a silent skip.
    @Test(arguments: RefusingPaneAnswer.allCases)
    func recreateWindowRefusesWhenThePaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-kwss-recreate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-kwss-recreate")
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
            tmux: tmux,
            configDirManager: isolatedConfigDirManager("kwss-recreate"),
            actuationLog: makeTestActuationLog())

        let resp = try await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!resp.success, "a pane not provably this terminal's must refuse the recreate rather than destroy a stranger's window")
        let unchanged = try #require(try await db.terminals.get(id: terminal.id))
        #expect(unchanged.tmuxWindowID == "@2", "the row's own coordinate must be untouched by a refused recreate")
        #expect(unchanged.tmuxPaneID == "%2", "the row's own coordinate must be untouched by a refused recreate")
        #expect(!recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane not provably this terminal's must never be kill-windowed: \(recorder.snapshot())")
    }

    /// The positive control: a pane answering with the row's own id recreates
    /// exactly as before — the old window is killed and a new one replaces it.
    @Test func recreateWindowProceedsWhenThePaneAnswersWithItsOwnID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-kwss-recreate-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-kwss-recreate-ok")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: terminal.id.uuidString) })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager("kwss-recreate-ok"),
            actuationLog: makeTestActuationLog())

        let resp = try await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(resp.success, "a pane confirmed as this row's own must still recreate")
        #expect(recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane confirmed as this row's own must still be killed: \(recorder.snapshot())")
    }

    /// The codex branch's own guard, mirroring the shell branch's mismatch
    /// test above — the two branches duplicate the same guard shape, and a
    /// regression in one would not be caught by a test of the other.
    @Test(arguments: RefusingPaneAnswer.allCases)
    func recreateWindowCodexBranchRefusesWhenThePaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-kwss-recreate-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-kwss-recreate-codex")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Codex", kind: .codex)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in try refusal.answer() })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, actuationLog: makeTestActuationLog())

        let resp = try await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!resp.success, "a pane not provably this terminal's must refuse the recreate rather than destroy a stranger's window")
        let unchanged = try #require(try await db.terminals.get(id: terminal.id))
        #expect(unchanged.tmuxWindowID == "@2", "the row's own coordinate must be untouched by a refused recreate")
        #expect(unchanged.tmuxPaneID == "%2", "the row's own coordinate must be untouched by a refused recreate")
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
