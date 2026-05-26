import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

private func runShell(_ cmd: String, at dir: URL) async throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = dir
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "shell", code: Int(p.terminationStatus))
    }
}

@Suite("GitStatus Tests")
struct GitStatusTests {

    @Test func newWorktreeHasNoConflicts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        #expect(wt.hasConflicts == false)
    }

    @Test func updateHasConflictsToTrue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: true)
        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.hasConflicts == true)
    }

    @Test func hasConflictsRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        // Set to true, then back to false
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: true)
        let withConflicts = try await db.worktrees.get(id: wt.id)
        #expect(withConflicts?.hasConflicts == true)

        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: false)
        let withoutConflicts = try await db.worktrees.get(id: wt.id)
        #expect(withoutConflicts?.hasConflicts == false)
    }

    @Test func isMergeBaseAncestor() async throws {
        // Set up a temp repo
        let repoDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        // Init repo and make initial commit on main
        try await runShell("git init -b main", at: repoDir)
        try await runShell("git config commit.gpgSign false", at: repoDir)
        try await runShell("git config user.email 'test@test.com'", at: repoDir)
        try await runShell("git config user.name 'Test'", at: repoDir)
        try await runShell("touch README.md && git add . && git commit -m 'initial'", at: repoDir)

        // Create feature branch with a commit
        try await runShell("git checkout -b feature", at: repoDir)
        try await runShell("touch feature.txt && git add . && git commit -m 'feature commit'", at: repoDir)

        // main IS an ancestor of feature
        let git = GitManager()
        let repoPath = repoDir.path
        let mainIsAncestor = await git.isMergeBaseAncestor(repoPath: repoPath, base: "main", branch: "feature")
        #expect(mainIsAncestor == true)

        // Now add a commit to main (diverge)
        try await runShell("git checkout main", at: repoDir)
        try await runShell("touch main-extra.txt && git add . && git commit -m 'main diverges'", at: repoDir)

        // main is now NOT an ancestor of feature (main has diverged)
        let mainIsAncestorAfterDiverge = await git.isMergeBaseAncestor(repoPath: repoPath, base: "main", branch: "feature")
        #expect(mainIsAncestorAfterDiverge == false)
    }

    // MARK: - refreshGitStatuses integration tests

    @Test func refreshGitStatusesDetectsConflicts() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        // Init repo with a file
        try await runShell("git init -b main", at: repoDir)
        try await runShell("git config commit.gpgSign false", at: repoDir)
        try await runShell("git config user.email 'test@test.com'", at: repoDir)
        try await runShell("git config user.name 'Test'", at: repoDir)
        try await runShell("echo 'line1' > shared.txt && git add . && git commit -m 'initial'", at: repoDir)

        // Set up bare origin remote and push the pre-conflict main
        try await runShell("git init --bare '\(originDir.path)'", at: repoDir)
        try await runShell("git remote add origin '\(originDir.path)'", at: repoDir)
        try await runShell("git push -u origin main", at: repoDir)

        // Create feature branch with conflicting change (NOT pushed to origin)
        try await runShell("git checkout -b tbd/feature-wt", at: repoDir)
        try await runShell("echo 'feature-change' > shared.txt && git add . && git commit -m 'feature change'", at: repoDir)

        // Back to main with conflicting change to same file, then push so
        // origin/main reflects the diverged state. The feature branch is NOT
        // pushed — origin/main is ahead of where feature branched off, with a
        // conflicting edit to shared.txt, which is what makes the conflict
        // detectable under the origin-based reconcile semantics.
        try await runShell("git checkout main", at: repoDir)
        try await runShell("echo 'main-change' > shared.txt && git add . && git commit -m 'main change'", at: repoDir)
        try await runShell("git push origin main", at: repoDir)

        // Set up DB
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "feature-wt", branch: "tbd/feature-wt",
            path: repoDir.path + "/.tbd/worktrees/feature-wt", tmuxServer: "tbd-test"
        )
        #expect(wt.hasConflicts == false)

        // Run refreshGitStatuses
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )
        await lifecycle.refreshGitStatuses(repoID: repo.id)

        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.hasConflicts == true)
    }

    @Test func refreshGitStatusesNoConflictsWhenBranchMatchesOrigin() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        // Init repo with a file
        try await runShell("git init -b main", at: repoDir)
        try await runShell("git config commit.gpgSign false", at: repoDir)
        try await runShell("git config user.email 'test@test.com'", at: repoDir)
        try await runShell("git config user.name 'Test'", at: repoDir)
        try await runShell("echo 'line1' > shared.txt && git add . && git commit -m 'initial'", at: repoDir)

        // Set up bare origin remote and push main
        try await runShell("git init --bare '\(originDir.path)'", at: repoDir)
        try await runShell("git remote add origin '\(originDir.path)'", at: repoDir)
        try await runShell("git push -u origin main", at: repoDir)

        // Create feature branch pointing at the same commit as origin/main (no extra commits)
        try await runShell("git checkout -b tbd/feature-wt", at: repoDir)

        // Set up DB
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "feature-wt", branch: "tbd/feature-wt",
            path: repoDir.path + "/.tbd/worktrees/feature-wt", tmuxServer: "tbd-test"
        )
        #expect(wt.hasConflicts == false)

        // Run refreshGitStatuses — branch is an ancestor of origin/main, no conflicts
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )
        await lifecycle.refreshGitStatuses(repoID: repo.id)

        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.hasConflicts == false)
    }
}
