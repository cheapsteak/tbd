import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — in-memory database, dry-run tmux, a real actuation log in a temp
/// directory. No `TBD_HOME`, no subprocesses.
///
/// The auto-archive-on-merge rail refuses a remote lane before it writes its
/// `.dispose` request: a remote worktree cannot be archived today, so a request
/// row for one would claim an act that was never attempted. Both arms are here
/// — the refusal, and a local worktree with the identical arming still
/// archiving, which is what proves the fence did not disarm the feature.
@Suite("Auto-archive on merge: remote lanes")
struct AutoArchiveRemoteLaneTests {

    private func makeLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-autoarchive-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
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

    private func makeFixture(
        logPath: String
    ) async throws -> (coordinator: AutoArchiveOnMergeCoordinator, db: TBDDatabase, repo: Repo) {
        let db = try TBDDatabase(inMemory: true)
        let subscriptions = StateSubscriptionManager()
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: subscriptions)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let coordinator = AutoArchiveOnMergeCoordinator(
            db: db, lifecycle: lifecycle, subscriptions: subscriptions,
            actuationLog: ActuationLog(path: logPath))
        return (coordinator, db, repo)
    }

    @Test("an armed remote worktree is refused, and no actuation row is written for it")
    func remoteLaneIsRefusedAndRecordsNothing() async throws {
        let logPath = try makeLogPath()
        let fixture = try await makeFixture(logPath: logPath)
        let worktree = try await fixture.db.worktrees.createRemote(
            repoID: fixture.repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "acme-provider", sessionID: "sess-1")
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: worktree.id, value: true)

        let archived = await fixture.coordinator.handleMergedTransition(
            worktreeID: worktree.id, prNumber: 7)

        #expect(!archived)
        #expect(try await fixture.db.worktrees.get(id: worktree.id)?.status == .active)
        // Not "no dispose row" but no row of any kind: the rail never reached
        // its act moment, so it has nothing to record — neither a request nor
        // the transport-failed outcome the downstream throw used to produce.
        #expect(try rows(at: logPath).isEmpty)
    }

    @Test("a local worktree armed the same way still auto-archives and records its act")
    func localLaneStillArchives() async throws {
        let logPath = try makeLogPath()
        let fixture = try await makeFixture(logPath: logPath)
        let worktree = try await fixture.db.worktrees.create(
            repoID: fixture.repo.id, name: "acme-local", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: worktree.id, value: true)

        let archived = await fixture.coordinator.handleMergedTransition(
            worktreeID: worktree.id, prNumber: 7)

        #expect(archived)
        #expect(try await fixture.db.worktrees.get(id: worktree.id)?.status == .archived)
        let written = try rows(at: logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "dispose")
        #expect(written.last?["result"] as? String == "dispatched")
    }
}
