import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux, a real (temp-directory) actuation log, and a real git
/// repo for the reconcile fixture.
///
/// The two daemon-internal rails this covers act with nobody having asked: the
/// boot-time reconcile sweep (kills the windows of worktrees that left disk,
/// parks sessions whose window is gone, reaps orphaned windows and dead
/// servers) and the auto-archive-on-merge rail. Both carry `{"kind":"daemon",
/// "rail":…}` and no `method`, and both skip their act rather than perform it
/// unrecorded.
@Suite("Actuation log sweep wiring")
struct ActuationLogSweepWiringTests {

    // MARK: - Fixture

    private func makeLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    /// A path that can never be opened: its parent is a regular file.
    private func makeUnwritablePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent("actuations.jsonl").path
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func requests(at path: String) throws -> [[String: Any]] {
        try rows(at: path).filter { $0["kind"] as? String != "outcome" }
    }

    private func outcomes(at path: String) throws -> [[String: Any]] {
        try rows(at: path).filter { $0["kind"] as? String == "outcome" }
    }

    private func makeLifecycle(db: TBDDatabase, tmux: TmuxManager) -> WorktreeLifecycle {
        // Database-only fixtures: the worktree paths never exist on disk, so the
        // real archive preflight would refuse them. Stub the two archive seams
        // so these tests stay about the actuation rows a sweep writes, not about
        // the safety gate that ArchiveSafetyClassifierTests owns.
        WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            archiveSafetyEvaluator: { _, _ in
                ArchiveSafetyReport(findings: [], headIsPublished: true)
            },
            worktreeRemover: { _, _ in }
        )
    }

    // MARK: - reconcile: a worktree that left disk

    @Test("reconcile writes one dispose row per window it kills, with the reconcile rail")
    func reconcileKillsWriteDisposeRows() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, tmux: TmuxManager(dryRun: true))
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        // A worktree row whose path is not a live git worktree → reconcile
        // archives it, killing its windows on the way.
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-acme")
        var terminalIDs: Set<String> = []
        for index in 0..<2 {
            let terminal = try await db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)")
            terminalIDs.insert(terminal.id.uuidString)
        }

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: ActuationLog(path: logPath))

        // The same sweep also reaps the servers those rows leave behind; this is
        // about the per-terminal kills.
        let written = try requests(at: logPath).filter {
            ($0["target"] as? [String: Any])?["terminal"] != nil
        }
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0["kind"] as? String == "dispose" })
        // Daemon-internal: no RPC carried this, so no method.
        #expect(written.allSatisfy { $0["method"] == nil })
        #expect(written.allSatisfy {
            ($0["actor"] as? [String: Any])?["rail"] as? String == "reconcile"
        })
        #expect(written.allSatisfy {
            ($0["actor"] as? [String: Any])?["kind"] as? String == "daemon"
        })
        // One row per kill: each names the terminal it was about to kill.
        let named = Set(written.compactMap { ($0["target"] as? [String: Any])?["terminal"] as? String })
        #expect(named == terminalIDs)
        #expect(try outcomes(at: logPath).allSatisfy { $0["result"] as? String == "dispatched" })
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived)
    }

    @Test("an unwritable record leaves the worktree and its windows for the next sweep")
    func unwritableRecordSkipsReconcileKills() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, tmux: TmuxManager(dryRun: true))
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-acme")
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0")

        // The sweep still completes — the daemon boots either way.
        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: ActuationLog(path: try makeUnwritablePath()))

        // But the act did not happen: the row is still active and still owns its
        // terminal, so the next sweep (with a writable log) retries it.
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
        #expect(try await db.terminals.list(worktreeID: worktree.id).count == 1)
    }

    // MARK: - reconcile: the recovery park

    @Test("reconcile writes a hibernate row for the recovery park it performs itself")
    func reconcileRecoveryParkWritesHibernateRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        // Every window reports dead, so the live main worktree's Claude session
        // takes the park-on-recovery branch.
        let lifecycle = makeLifecycle(
            db: db, tmux: TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true }))
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))
        let terminal = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-1", kind: .claude)

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: ActuationLog(path: logPath))

        let parks = try requests(at: logPath).filter { $0["kind"] as? String == "hibernate" }
        #expect(parks.count == 1)
        let request = try #require(parks.first)
        #expect(request["method"] == nil)
        #expect((request["actor"] as? [String: Any])?["rail"] as? String == "reconcile")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == main.id.uuidString)
        #expect(target["terminal"] as? String == terminal.id.uuidString)

        let outcome = try #require(
            try outcomes(at: logPath).first { $0["confirms"] as? String == request["id"] as? String })
        #expect(outcome["result"] as? String == "dispatched")
        let parked = try await db.terminals.get(id: terminal.id)
        #expect(parked?.hibernatedAt != nil)
        #expect(parked?.hibernateReason == .recovery)
    }

    @Test("an unwritable record skips the recovery park — the row stays unparked")
    func unwritableRecordSkipsRecoveryPark() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db, tmux: TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true }))
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))
        let terminal = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-1", kind: .claude)

        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: ActuationLog(path: try makeUnwritablePath()))

        #expect(try await db.terminals.get(id: terminal.id)?.hibernatedAt == nil)
    }

    // MARK: - reconcile: servers and orphaned windows

    @Test("killing a server nobody references writes a dispose row naming the server")
    func reconcileKillServerWritesDisposeRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, tmux: TmuxManager(dryRun: true))
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        // An archived row is the last pointer at this server — no live row
        // references it, so the sweep kills the server itself.
        let retired = try await db.worktrees.create(
            repoID: repo.id, name: "retired", branch: "retired-branch",
            path: tempDir.appendingPathComponent("retired").path, tmuxServer: "tbd-orphan-server")
        try await db.worktrees.archive(id: retired.id)

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: ActuationLog(path: logPath))

        let serverRows = try requests(at: logPath).filter {
            ($0["target"] as? [String: Any])?["server"] as? String == "tbd-orphan-server"
        }
        #expect(serverRows.count == 1)
        let request = try #require(serverRows.first)
        #expect(request["kind"] as? String == "dispose")
        #expect(request["method"] == nil)
        #expect((request["actor"] as? [String: Any])?["rail"] as? String == "reconcile")
        let target = try #require(request["target"] as? [String: Any])
        // Nothing names this server any more, so the row carries what does
        // identify it: the server, and the repo whose sweep found it.
        #expect(target["repo"] as? String == repo.id.uuidString)
        #expect(target["window"] == nil)
        #expect(target["terminal"] == nil)
        #expect(try outcomes(at: logPath).contains {
            $0["confirms"] as? String == request["id"] as? String
                && $0["result"] as? String == "dispatched"
        })
    }

    @Test("sweeping an orphaned window writes a dispose row naming server and window")
    func reconcileOrphanWindowWritesDisposeRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let server = TmuxManager.serverName(forRepoPath: repoDir.path)
        // One live window on the repo's own server that no terminal row claims.
        let lifecycle = makeLifecycle(
            db: db,
            tmux: TmuxManager(
                dryRun: true,
                dryRunListWindows: { probed, _ in
                    probed == server ? [(windowID: "@99", paneID: "%99")] : []
                }))
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: server)

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: ActuationLog(path: logPath))

        let orphanRows = try requests(at: logPath).filter {
            ($0["target"] as? [String: Any])?["window"] as? String == "@99"
        }
        #expect(orphanRows.count == 1)
        let request = try #require(orphanRows.first)
        #expect(request["kind"] as? String == "dispose")
        #expect((request["actor"] as? [String: Any])?["rail"] as? String == "reconcile")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["server"] as? String == server)
        #expect(target["repo"] as? String == repo.id.uuidString)
        #expect(try outcomes(at: logPath).contains {
            $0["confirms"] as? String == request["id"] as? String
                && $0["result"] as? String == "dispatched"
        })
    }

    // MARK: - The auto-archive-on-merge rail

    private func makeMergeFixture(
        logPath: String
    ) async throws -> (coordinator: AutoArchiveOnMergeCoordinator, db: TBDDatabase, worktreeID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let subscriptions = StateSubscriptionManager()
        let lifecycle = makeLifecycle(db: db, tmux: TmuxManager(dryRun: true))
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        try await db.worktrees.setAutoArchiveOnMerge(id: worktree.id, value: true)
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0")
        let coordinator = AutoArchiveOnMergeCoordinator(
            db: db, lifecycle: lifecycle, subscriptions: subscriptions,
            actuationLog: ActuationLog(path: logPath))
        return (coordinator, db, worktree.id)
    }

    @Test("auto-archive-on-merge writes its own rail row, with no method")
    func autoArchiveRailWritesRow() async throws {
        let logPath = try makeLogPath()
        let fixture = try await makeMergeFixture(logPath: logPath)

        let archived = await fixture.coordinator.handleMergedTransition(
            worktreeID: fixture.worktreeID, prNumber: 7)
        #expect(archived)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "dispose")
        #expect(request["method"] == nil)
        let actor = try #require(request["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "daemon")
        #expect(actor["rail"] as? String == "auto-archive-on-merge")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == fixture.worktreeID.uuidString)
        // One row for the whole worktree, as the RPC archive records it.
        #expect(target["terminal"] == nil)
        let outcome = try #require(written.last)
        #expect(outcome["confirms"] as? String == request["id"] as? String)
        #expect(outcome["result"] as? String == "dispatched")
    }

    @Test("a worktree the rail is not armed for is never acted on, so it writes no row")
    func autoArchiveDisarmedWritesNothing() async throws {
        let logPath = try makeLogPath()
        let fixture = try await makeMergeFixture(logPath: logPath)
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: fixture.worktreeID, value: false)

        let archived = await fixture.coordinator.handleMergedTransition(
            worktreeID: fixture.worktreeID, prNumber: 7)
        #expect(!archived)
        #expect(try rows(at: logPath).isEmpty)
    }

    @Test("an unwritable record skips the auto-archive — the worktree survives")
    func unwritableRecordSkipsAutoArchive() async throws {
        let fixture = try await makeMergeFixture(logPath: try makeUnwritablePath())

        let archived = await fixture.coordinator.handleMergedTransition(
            worktreeID: fixture.worktreeID, prNumber: 7)

        // Reported as not-archived, so the merge-park rail behind it still gets
        // its turn — and the worktree and its session are untouched.
        #expect(!archived)
        #expect(try await fixture.db.worktrees.get(id: fixture.worktreeID)?.status == .active)
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktreeID).count == 1)
    }
}
