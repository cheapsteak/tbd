import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The pane-ownership guard (`TmuxManager.paneOwnership`) extended to every
/// other call site that tears down a tmux window by DB-recorded coordinate.
/// There are seven. `terminal.delete` is the first and is covered by
/// `TerminalDeletePaneOwnershipTests`; the other six each have a `MARK:`
/// section below:
///
/// - `captureThenKillWindow`, shared by the archive path and the
///   vanished-worktree reconcile sweep
/// - the transport migration's window retire, for a parked row
/// - the running-shell move's program stop
/// - `forgetWorktree`
/// - `scratch.delete`'s teardown
/// - `terminal.recreateWindow`, whose shell and codex branches carry the guard
///   separately and are tested separately
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

    // MARK: - the transport migration's window retire

    /// The sixth site. Moving a PARKED session to the pty holder blanks the row's
    /// tmux coordinates, so the window the park kept belongs to nobody
    /// afterwards and the migration retires it — through the same guard, for
    /// the same reason. The hazard is sharper here than for the others
    /// because the migration is a *bulk* action: a fleet run reaches every
    /// tmux row on the machine, and a single recycled coordinate would be a
    /// stranger's live window killed on somebody else's behalf.
    ///
    /// The retire writes nothing to the database, so a refusal must leave the
    /// row's coordinates exactly as the caller handed them over as well as
    /// leaving the window alive.
    @Test(arguments: RefusingPaneAnswer.allCases)
    func transportMigrationLeavesAWindowUntouchedWhenItsPaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/kwss-migrate-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/kwss-migrate-wt-\(UUID().uuidString)", tmuxServer: "tbd-kwss-migrate")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in try refusal.answer() })
        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: isolatedConfigDirManager("kwss-migrate-\(refusal.rawValue)"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        await coordinator.retireTmuxWindowAfterTransportMigration(terminal: terminal)

        #expect(!recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane not provably this terminal's must never be kill-windowed: \(recorder.snapshot())")
        let unchanged = try #require(try await db.terminals.get(id: terminal.id))
        #expect(unchanged.tmuxWindowID == "@2" && unchanged.tmuxPaneID == "%2",
                "the retire must write nothing to the row")
    }

    /// The positive control: a pane answering with the row's own id is the
    /// window the migration is there to retire.
    @Test func transportMigrationRetiresAWindowWhosePaneAnswersWithItsOwnID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/kwss-migrate-ok-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/kwss-migrate-ok-wt-\(UUID().uuidString)", tmuxServer: "tbd-kwss-migrate-ok")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: terminal.id.uuidString) })
        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux,
            configDirManager: isolatedConfigDirManager("kwss-migrate-ok"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())

        await coordinator.retireTmuxWindowAfterTransportMigration(terminal: terminal)

        #expect(recorder.snapshot().contains { $0.contains("kill-window") && $0.contains("@2") },
                "a pane confirmed as this row's own must still be killed: \(recorder.snapshot())")
    }

    // MARK: - the running shell move's kill

    /// The seventh site. A session with nothing to resume moves by having its
    /// program stopped and a fresh login shell started on a holder — and the
    /// stop is a `kill-window` by DB-recorded coordinate, so it goes through
    /// the same guard. It is the sharpest of the seven: this kill is not
    /// reclaiming a window somebody has finished with, it is *ending a running
    /// program*, so a recycled coordinate would kill a stranger's live session
    /// rather than an idle leftover.
    ///
    /// A refusal must write nothing: the row keeps its transport, its
    /// coordinates and its awake state, so the session the person is using
    /// carries on.
    @Test(arguments: RefusingPaneAnswer.allCases)
    func theShellMoveLeavesAWindowUntouchedWhenItsPaneIsNotProvablyOurs(_ refusal: RefusingPaneAnswer) async throws {
        let fixture = try await ShellMoveSiteFixture.make(
            tag: "kwss-shellmove-\(refusal.rawValue)", paneAnswer: .refusing(refusal))
        defer { fixture.tearDown() }

        let outcome = await fixture.coordinator.moveRunningShellToHolder(
            terminal: fixture.terminal)

        #expect(outcome != .moved, "an unverified pane's session was moved anyway")
        #expect(!fixture.recorder.snapshot().contains { $0.contains("kill-window") },
                "a pane not provably this terminal's must never be kill-windowed: \(fixture.recorder.snapshot())")
        let unchanged = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(unchanged.transport == .tmux, "a refused move rewrote the row anyway")
        #expect(unchanged.tmuxWindowID == "@2" && unchanged.tmuxPaneID == "%2",
                "a refused move must write nothing to the row")
    }

    /// The positive control: a pane answering with the row's own id is the
    /// program the move is there to stop. The spawn that follows cannot
    /// succeed in this fixture, which is beside the point — the kill is what
    /// this site is about.
    @Test func theShellMoveStopsAWindowWhosePaneAnswersWithItsOwnID() async throws {
        let fixture = try await ShellMoveSiteFixture.make(
            tag: "kwss-shellmove-ok", paneAnswer: .ownID)
        defer { fixture.tearDown() }

        _ = await fixture.coordinator.moveRunningShellToHolder(terminal: fixture.terminal)

        #expect(fixture.recorder.snapshot().contains { $0.contains("kill-window") && $0.contains("@2") },
                "a pane confirmed as this row's own must still be stopped: \(fixture.recorder.snapshot())")
    }

    /// Everything the shell-move site needs: a row with a tmux coordinate, a
    /// recording dry-run tmux, and a registry that reports it can spawn — the
    /// pane consultation happens before any spawn, so a registry that refused
    /// up front would hide the guard entirely.
    private struct ShellMoveSiteFixture {
        let db: TBDDatabase
        let home: String
        let terminal: Terminal
        let recorder: RecordedTmuxArgs
        let coordinator: HibernationCoordinator

        func tearDown() {
            try? FileManager.default.removeItem(atPath: home)
        }

        /// What the pane consultation answers. `ownID` can only be built once
        /// the row exists, which is why it is named rather than passed as a
        /// closure.
        enum PaneAnswer: Sendable {
            case refusing(RefusingPaneAnswer)
            case ownID
        }

        static func make(
            tag: String, paneAnswer: PaneAnswer
        ) async throws -> ShellMoveSiteFixture {
            let home = fencedScratchRoot(prefix: "tbdkwsssm")
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true)
            let db = try TBDDatabase(inMemory: true)
            let repo = try await db.repos.create(
                path: "\(home)/repo", displayName: "R", defaultBranch: "main")
            let wt = try await db.worktrees.create(
                repoID: repo.id, name: "wt", branch: "b",
                path: "\(home)/wt", tmuxServer: "tbd-kwss-shellmove")
            let created = try await db.terminals.create(
                worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)
            let ownID = created.id.uuidString
            let recorder = RecordedTmuxArgs()
            let tmux = TmuxManager(
                dryRun: true,
                dryRunRecorder: { recorder.append($0) },
                dryRunPaneSendTarget: { _, _ in
                    switch paneAnswer {
                    case .refusing(let refusal): return try refusal.answer()
                    case .ownID: return .live(terminalID: ownID)
                    }
                })
            let coordinator = HibernationCoordinator(
                db: db, tmux: tmux,
                configDirManager: makeIsolatedConfigDirManager(tag: tag),
                sessionTitles: ClaudeSessionTitleStore(),
                actuationLog: makeTestActuationLog())
            await coordinator.setHolderRegistry(HolderRegistry(
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
                listTerminals: { [] },
                spawner: HolderSpawner(
                    executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))))
            return ShellMoveSiteFixture(
                db: db, home: home,
                terminal: try #require(try await db.terminals.get(id: created.id)),
                recorder: recorder, coordinator: coordinator)
        }
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

    // MARK: - terminal.recreateWindow against a dead server

    /// The post-reboot case recreate exists for: the repo's tmux server is
    /// gone, so the pane probe and its reachability probe both fail
    /// (`.unreachable`). tmux positively reports no server behind the socket
    /// (`probeServer` → `.absent`), and a dead server holds no stranger pane,
    /// so the guard must not block the rebuild — on either branch.
    @Test(arguments: [TerminalKind.shell, TerminalKind.codex])
    func recreateWindowProceedsWhenTheServerIsPositivelyGone(_ kind: TerminalKind) async throws {
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-kwss-recreate-dead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-kwss-recreate-dead")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: kind == .codex ? "Codex" : nil, kind: kind)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in .unreachable },
            dryRunServerPresence: { _ in .absent })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager("kwss-recreate-dead-\(kind.rawValue)"),
            actuationLog: makeTestActuationLog())

        let resp = try await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(resp.success, "a dead server must not block the rebuild recreate exists for: \(resp.error ?? "")")
        let replaced = try #require(try await db.terminals.get(id: terminal.id))
        #expect(replaced.tmuxWindowID != "@2" || replaced.tmuxPaneID != "%2",
                "the row must be re-pointed at the rebuilt window")
    }

    /// The other side of that line: an unreachable pane on a server NOT
    /// positively known to be gone stays "we do not know" and still refuses.
    @Test(arguments: [TmuxPresence.alive, TmuxPresence.unknown])
    func recreateWindowStillRefusesAnUnreachablePaneOnAServerNotProvablyGone(
        _ serverPresence: TmuxPresence
    ) async throws {
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-kwss-recreate-unreach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-kwss-recreate-unreach")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        let recorder = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunPaneSendTarget: { _, _ in .unreachable },
            dryRunServerPresence: { _ in serverPresence })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager("kwss-recreate-unreach"),
            actuationLog: makeTestActuationLog())

        let resp = try await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!resp.success, "an unreachable pane on a server not provably gone must still refuse")
        #expect(!recorder.snapshot().contains { $0.contains("kill-window") },
                "an unverified pane must never be kill-windowed: \(recorder.snapshot())")
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
