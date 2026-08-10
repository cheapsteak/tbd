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
        /// Where the archive rail's actuation rows land, so a test can count
        /// what it actually did rather than only what it left behind.
        let actuationLogPath: String
    }

    /// Rows the archive rail wrote, newest last. Request rows carry `kind`;
    /// outcome rows carry `confirms`.
    private func actuationRequests(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
            .filter { $0["confirms"] == nil }
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
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-mtp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logPath = logDirectory.appendingPathComponent("actuations.jsonl").path
        let archive = AutoArchiveOnMergeCoordinator(
            db: db, lifecycle: lifecycle, subscriptions: subs,
            actuationLog: ActuationLog(path: logPath))
        let hibernation = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: subs, configDirManager: mergeIsolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        let hibernate = AutoHibernateOnMergeCoordinator(db: db, hibernation: hibernation, subscriptions: subs)
        let dispatcher = MergedTransitionDispatcher(archive: archive, hibernate: hibernate)
        return Deps(dispatcher: dispatcher, archive: archive, db: db,
                    actuationLogPath: logPath)
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

    // MARK: - Idempotency: two fan-outs in one pass

    /// One poll pass CAN fan out twice for the same worktree, and this is what
    /// makes that harmless.
    ///
    /// `PRStatusManager.apply` fires the un-bound fallback from inside
    /// `fetchAll`, *before* the same pass creates the branch binding; the poll
    /// then judges that fresh binding with `evaluate`. The two once-only sets
    /// are deliberately independent, so neither suppresses the other, and both
    /// fire on the first pass that ever sees an already-merged PR with nothing
    /// bound yet — the ordinary upgrade path for any worktree whose PR merged
    /// while the daemon was down.
    ///
    /// Safety therefore rests entirely on the coordinators being idempotent
    /// rather than on the firing order. These two tests pin that; if either
    /// coordinator ever starts acting twice, they are what catches it.
    @Test("firing the fan-out twice archives once and notifies once")
    func doubledFanOutArchivesOnce() async throws {
        let deps = try makeDeps()
        let (wtID, _) = try await makeWorktreeWithTerminal(deps.db)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: wtID, value: true)
        try await deps.db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await deps.dispatcher.handleMergedTransition(worktreeID: wtID, prNumber: 20)
        await deps.dispatcher.handleMergedTransition(worktreeID: wtID, prNumber: 20)

        // The `wt.status == .active` re-read is the guard: the second pass finds
        // an archived worktree and does nothing at all.
        #expect(try await deps.db.worktrees.get(id: wtID)?.status == .archived)
        let requests = try actuationRequests(at: deps.actuationLogPath)
        #expect(requests.count == 1)
        #expect(requests.first?["kind"] as? String == "dispose")
        #expect(try await deps.db.notifications.unread(worktreeID: wtID).count == 1)
    }

    @Test("firing the fan-out twice with archive blocked parks once and notifies once")
    func doubledFanOutParksOnce() async throws {
        // Archive armed but blocked by an active child, so BOTH fan-outs reach
        // the hibernate arm — the harder half of the idempotency claim.
        let deps = try makeDeps()
        let (parentID, terminalID) = try await makeWorktreeWithTerminal(deps.db)
        _ = try await makeWorktreeWithTerminal(deps.db, parentID: parentID)
        try await deps.db.worktrees.setAutoArchiveOnMerge(id: parentID, value: true)
        try await deps.db.worktrees.setAutoHibernateOnMerge(id: parentID, value: true)

        await deps.dispatcher.handleMergedTransition(worktreeID: parentID, prNumber: 21)
        let firstStamp = try await deps.db.terminals.get(id: terminalID)?.hibernatedAt
        #expect(firstStamp != nil)

        await deps.dispatcher.handleMergedTransition(worktreeID: parentID, prNumber: 21)

        // The already-hibernated session is not re-parked, so `parked` is 0 and
        // the second pass sends no notification.
        #expect(try await deps.db.terminals.get(id: terminalID)?.hibernatedAt == firstStamp)
        #expect(try await deps.db.notifications.unread(worktreeID: parentID).count == 1)
        // Blocked before the act, so the archive rail wrote no row either time.
        #expect(try actuationRequests(at: deps.actuationLogPath).isEmpty)
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
