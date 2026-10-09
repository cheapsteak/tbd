import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// `WorktreeLifecycle.rollBackFailedCreate` — the daemon side of a creation
/// that fails after the app parked a first message in the row. The row and
/// its `pending_prompt` are deleted, so the daemon saves the text and names
/// the file in the failure delta.
///
/// Tier 2: an in-memory database, a real temp directory passed through the
/// `reposDir` seam, a fixed date. Never reads the process-global `TBD_HOME`.
@Suite("Failed create saves its parked first message")
struct FailedCreateUnsentPromptTests: ~Copyable {
    private let fm = FileManager.default
    /// 2026-03-04 05:06:07 UTC.
    private let date = Date(timeIntervalSince1970: 1_772_600_767)
    let reposDir: URL

    init() {
        reposDir = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdfcup"), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: reposDir) }

    private func makeLifecycle() throws -> (WorktreeLifecycle, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        return (lifecycle, db)
    }

    private func makeCreatingRow(_ db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/fcup-\(UUID())", displayName: "r", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "brave-otter", branch: "tbd/brave-otter",
            path: "/tmp/fcup-wt-\(UUID())", tmuxServer: "srv", status: .creating)
    }

    /// A real git repo with a real linked worktree, for the recovery paths that
    /// only activate a row whose path `git worktree list` names.
    private func makeRepoWithCheckout(
        _ db: TBDDatabase
    ) async throws -> (repo: Repo, checkout: URL, cleanup: () -> Void) {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "r", defaultBranch: "main")
        let checkout = tempDir.appendingPathComponent("checkout-\(UUID().uuidString.prefix(8))")
        try await shell("git worktree add -b tbd/brave-otter '\(checkout.path)'", at: repoDir)
        return (repo, checkout, { try? FileManager.default.removeItem(at: tempDir) })
    }

    @Test func aParkedPromptIsSavedAndNamedInTheDelta() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)
        try await db.worktrees.setPendingPrompt(
            worktreeID: row.id, text: "  fix the build\nthen open a PR  ", submit: true)

        let delta = await lifecycle.rollBackFailedCreate(
            worktreeID: row.id, reposDir: reposDir, date: date)

        let path = try #require(delta.unsentPromptPath)
        #expect(delta.worktreeID == row.id)
        #expect(delta.creationFailed)
        #expect(path.hasPrefix(reposDir.path + "/" + (row.repoID?.uuidString ?? "") + "/unsent-prompts/"))
        #expect(path.hasSuffix("-brave-otter.md"))
        // Written as parked: leading indentation is part of the message.
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "  fix the build\nthen open a PR  \n")
        #expect(try await db.worktrees.getLocal(id: row.id) == nil)
    }

    @Test func noParkedPromptWritesNothing() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)

        let delta = await lifecycle.rollBackFailedCreate(
            worktreeID: row.id, reposDir: reposDir, date: date)

        #expect(delta.creationFailed)
        #expect(delta.unsentPromptPath == nil)
        #expect(delta.unsentPromptLost == false)
        #expect(fm.fileExists(atPath: reposDir.path) == false)
        #expect(try await db.worktrees.getLocal(id: row.id) == nil)
    }

    @Test func aBlankParkedPromptWritesNothing() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)
        try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: " \n\t ", submit: false)

        let delta = await lifecycle.rollBackFailedCreate(
            worktreeID: row.id, reposDir: reposDir, date: date)

        #expect(delta.unsentPromptPath == nil)
        #expect(fm.fileExists(atPath: reposDir.path) == false)
    }

    @Test func settingAPromptOnAMissingRowReportsNoRowWritten() async throws {
        let (_, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)
        #expect(try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: "x", submit: true))

        try await db.worktrees.delete(id: row.id)

        #expect(try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: "x", submit: true) == false)
    }

    /// Startup recovery deletes a `.creating` row whose checkout never
    /// appeared; the first message parked in it is saved, not deleted with it.
    @Test func recoveryOfAStrandedRowSavesItsParkedPrompt() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)
        try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: "kept across a restart", submit: true)

        await lifecycle.recoverCreatingWorktrees(unsentPromptsReposDir: reposDir)

        #expect(try await db.worktrees.get(id: row.id) == nil)
        let repoID = try #require(row.repoID)
        let dir = reposDir.appendingPathComponent(repoID.uuidString)
            .appendingPathComponent(TBDConstants.unsentPromptsDirName)
        let files = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        let path = dir.appendingPathComponent(try #require(files.first)).path
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "kept across a restart\n")
    }

    /// A `.creating` row whose checkout exists but which has no terminals is
    /// kept and activated, not deleted. Its parked first message is saved the
    /// way a failed create saves it and then cleared, so it can never be
    /// delivered into whatever terminal the row gets later.
    @Test func activatingATerminalLessRowSavesThenClearsItsParkedPrompt() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let (repo, checkout, cleanup) = try await makeRepoWithCheckout(db)
        defer { cleanup() }
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "brave-otter", branch: "tbd/brave-otter",
            path: checkout.path, tmuxServer: "srv", status: .creating)
        try await db.worktrees.setPendingPrompt(
            worktreeID: row.id, text: "kept across a restart", submit: true)

        await lifecycle.recoverCreatingWorktrees(unsentPromptsReposDir: reposDir)

        let after = try #require(try await db.worktrees.get(id: row.id))
        #expect(after.status == .active)
        #expect(after.pendingPrompt == nil, "a stale first message must not wait in an active row")
        let dir = reposDir.appendingPathComponent(repo.id.uuidString)
            .appendingPathComponent(TBDConstants.unsentPromptsDirName)
        let files = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        let saved = dir.appendingPathComponent(try #require(files.first)).path
        #expect(try String(contentsOfFile: saved, encoding: .utf8) == "kept across a restart\n")
    }

    /// A terminal-less row that was mid-revive keeps its archived Claude
    /// sessions (there is no terminal to restore them into) and drops its
    /// archive stamp, the same outcome as a revive with `skipClaude`.
    @Test func activatingATerminalLessMidReviveRowKeepsItsArchivedSessions() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let (repo, checkout, cleanup) = try await makeRepoWithCheckout(db)
        defer { cleanup() }
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "brave-otter", branch: "tbd/brave-otter",
            path: checkout.path, tmuxServer: "srv", status: .active)
        try await db.worktrees.archive(id: row.id, claudeSessionIDs: ["session-a", "session-b"])
        try await db.worktrees.updateStatus(id: row.id, status: .creating)
        #expect(try await db.worktrees.get(id: row.id)?.archivedAt != nil)

        await lifecycle.recoverCreatingWorktrees(unsentPromptsReposDir: reposDir)

        let after = try #require(try await db.worktrees.get(id: row.id))
        #expect(after.status == .active)
        #expect(after.archivedAt == nil)
        #expect(after.archivedClaudeSessions == ["session-a", "session-b"])
    }

    @Test func aParkedPromptInARepolessRowIsReportedLost() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let row = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/fcup-scratch-\(UUID())", tmuxServer: "srv")
        try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: "orphaned", submit: true)

        let delta = await lifecycle.rollBackFailedCreate(
            worktreeID: row.id, reposDir: reposDir, date: date)

        #expect(delta.unsentPromptLost)
        #expect(delta.unsentPromptPath == nil)
        #expect(try await db.worktrees.get(id: row.id) == nil)
    }

    @Test func aParkOnAMissingRowIsRefused() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setQueuedPrompt(true)
        let coordinator = PendingPromptCoordinator(db: db)

        let result = await coordinator.park(worktreeID: UUID(), text: "x", submit: true)

        guard case .refused(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason.contains("worktree not found"))
    }

    @Test func deleteReturningHandsBackTheParkedPromptAndRemovesTheRow() async throws {
        let (_, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)
        try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: "held", submit: false)

        let deleted = try await db.worktrees.deleteReturning(id: row.id)

        #expect(deleted?.pendingPrompt == "held")
        #expect(try await db.worktrees.get(id: row.id) == nil)
        #expect(try await db.worktrees.deleteReturning(id: row.id) == nil)
    }

    @Test func aFailedWriteLeavesThePathNilAndStillDeletesTheRow() async throws {
        let (lifecycle, db) = try makeLifecycle()
        let row = try await makeCreatingRow(db)
        try await db.worktrees.setPendingPrompt(worktreeID: row.id, text: "lost", submit: true)
        // A regular file where the repos directory should be.
        fm.createFile(atPath: reposDir.path, contents: Data())

        let delta = await lifecycle.rollBackFailedCreate(
            worktreeID: row.id, reposDir: reposDir, date: date)

        #expect(delta.creationFailed)
        #expect(delta.unsentPromptPath == nil)
        #expect(delta.unsentPromptLost)
        #expect(try await db.worktrees.getLocal(id: row.id) == nil)
    }
}
