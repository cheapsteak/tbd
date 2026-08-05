import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The precedence rule when a PR merges: archive supersedes hibernate, but only
/// when archive ACTUALLY began. The important asymmetry — an armed-but-blocked
/// archive must NOT suppress hibernate — gets its own test.
@Suite("MergedTransitionPrecedence")
struct MergedTransitionPrecedenceTests {

    private struct Deps {
        let dispatcher: MergedTransitionDispatcher
        let archive: AutoArchiveOnMergeCoordinator
        let db: TBDDatabase
    }

    private func makeDeps() throws -> Deps {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(),
            subscriptions: subs
        )
        let archive = AutoArchiveOnMergeCoordinator(
            db: db, lifecycle: lifecycle, subscriptions: subs,
            actuationLog: makeTestActuationLog())
        let hibernation = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: subs, configDirManager: mergeIsolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        let hibernate = AutoHibernateOnMergeCoordinator(db: db, hibernation: hibernation, subscriptions: subs)
        let dispatcher = MergedTransitionDispatcher(archive: archive, hibernate: hibernate)
        return Deps(dispatcher: dispatcher, archive: archive, db: db)
    }

    /// Create an active worktree with a single idle Claude terminal.
    private func makeWorktreeWithTerminal(
        _ db: TBDDatabase, parentID: UUID? = nil
    ) async throws -> (wtID: UUID, terminalID: UUID) {
        let repo = try await db.repos.create(
            path: "/tmp/repoMTP-\(UUID().uuidString)", displayName: "repoMTP", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/repoMTP/w-\(UUID().uuidString)", tmuxServer: "s",
            parentWorktreeID: parentID)
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        try await db.terminals.setActivityState(id: terminal.id, activityState: .idle)
        return (wt.id, terminal.id)
    }

    // MARK: - Precedence via the dispatcher

    @Test func bothArmedArchivesAndDoesNotPark() async throws {
        let deps = try makeDeps()
        let (wtID, terminalID) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: wtID, value: true)
        try await deps.db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await deps.dispatcher.handleMergedTransition(worktreeID: wtID, prNumber: 1)

        #expect(try await deps.db.worktrees.get(id: wtID)?.status == .archived)
        // Archive superseded hibernate → the terminal was NOT parked.
        #expect(try await deps.db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func archiveBlockedByChildrenStillParks() async throws {
        // The important asymmetry: archive is armed but BLOCKED by active
        // children, so the worktree survives — its idle sessions ARE parked.
        let deps = try makeDeps()
        let (parentID, parentTerminalID) = try await makeWorktreeWithTerminal(deps.db)
        _ = try await makeWorktreeWithTerminal(deps.db, parentID: parentID)  // active child
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: parentID, value: true)
        try await deps.db.worktrees.setAutoHibernateOnMerge(id: parentID, value: true)

        await deps.dispatcher.handleMergedTransition(worktreeID: parentID, prNumber: 2)

        #expect(try await deps.db.worktrees.get(id: parentID)?.status == .active)
        let after = try await deps.db.terminals.get(id: parentTerminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.hibernateReason == .merged)
    }

    @Test func onlyHibernateArmedParksNotArchived() async throws {
        let deps = try makeDeps()
        let (wtID, terminalID) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await deps.dispatcher.handleMergedTransition(worktreeID: wtID, prNumber: 3)

        #expect(try await deps.db.worktrees.get(id: wtID)?.status == .active)
        #expect(try await deps.db.terminals.get(id: terminalID)?.hibernatedAt != nil)
    }

    @Test func onlyArchiveArmedArchives() async throws {
        let deps = try makeDeps()
        let (wtID, terminalID) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: wtID, value: true)

        await deps.dispatcher.handleMergedTransition(worktreeID: wtID, prNumber: 4)

        #expect(try await deps.db.worktrees.get(id: wtID)?.status == .archived)
        #expect(try await deps.db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    // MARK: - Direct Bool contract on the archive coordinator

    @Test func archiveReturnsTrueOnlyWhenItBeganArchiving() async throws {
        let deps = try makeDeps()

        // Armed + no children → began archiving → true.
        let (armedID, _) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: armedID, value: true)
        let began = await deps.archive.handleMergedTransition(worktreeID: armedID, prNumber: 10)
        #expect(began == true)

        // Not armed → false.
        let (offID, _) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: offID, value: false)
        let notArmed = await deps.archive.handleMergedTransition(worktreeID: offID, prNumber: 11)
        #expect(notArmed == false)

        // Armed but active children → false.
        let (parentID, _) = try await makeWorktreeWithTerminal(deps.db)
        _ = try await makeWorktreeWithTerminal(deps.db, parentID: parentID)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: parentID, value: true)
        let blocked = await deps.archive.handleMergedTransition(worktreeID: parentID, prNumber: 12)
        #expect(blocked == false)

        // Not active (already archived) → false.
        let (goneID, _) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.updateStatus(id: goneID, status: .archived)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: goneID, value: true)
        let notActive = await deps.archive.handleMergedTransition(worktreeID: goneID, prNumber: 13)
        #expect(notActive == false)
    }
}

/// Isolated Claude config dir (mirrors HibernationCoordinatorTests) so nothing
/// touches the developer's real `~/.claude`.
private func mergeIsolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-mtp-claude-\(UUID().uuidString)", isDirectory: true)
    return ClaudeProfileConfigDirManager(
        baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
        hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
    )
}
