import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

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

        func shell(_ cmd: String, at dir: URL? = nil) async throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            p.currentDirectoryURL = dir ?? repoDir
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "shell", code: Int(p.terminationStatus))
            }
        }

        // Init repo and make initial commit on main
        try await shell("git init -b main")
        try await shell("git config commit.gpgSign false")
        try await shell("git config user.email 'test@test.com'")
        try await shell("git config user.name 'Test'")
        try await shell("touch README.md && git add . && git commit -m 'initial'")

        // Create feature branch with a commit
        try await shell("git checkout -b feature")
        try await shell("touch feature.txt && git add . && git commit -m 'feature commit'")

        // main IS an ancestor of feature
        let git = GitManager()
        let repoPath = repoDir.path
        let mainIsAncestor = await git.isMergeBaseAncestor(repoPath: repoPath, base: "main", branch: "feature")
        #expect(mainIsAncestor == true)

        // Now add a commit to main (diverge)
        try await shell("git checkout main")
        try await shell("touch main-extra.txt && git add . && git commit -m 'main diverges'")

        // main is now NOT an ancestor of feature (main has diverged)
        let mainIsAncestorAfterDiverge = await git.isMergeBaseAncestor(repoPath: repoPath, base: "main", branch: "feature")
        #expect(mainIsAncestorAfterDiverge == false)
    }

    // MARK: - refreshGitStatuses integration tests

    @Test func refreshGitStatusesDetectsConflicts() async throws {
        let repoDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        func shell(_ cmd: String, at dir: URL? = nil) async throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            p.currentDirectoryURL = dir ?? repoDir
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "shell", code: Int(p.terminationStatus))
            }
        }

        // Init repo with a file
        try await shell("git init -b main")
        try await shell("git config commit.gpgSign false")
        try await shell("git config user.email 'test@test.com'")
        try await shell("git config user.name 'Test'")
        try await shell("echo 'line1' > shared.txt && git add . && git commit -m 'initial'")

        // Create feature branch with conflicting change
        try await shell("git checkout -b tbd/feature-wt")
        try await shell("echo 'feature-change' > shared.txt && git add . && git commit -m 'feature change'")

        // Back to main with conflicting change to same file
        try await shell("git checkout main")
        try await shell("echo 'main-change' > shared.txt && git add . && git commit -m 'main change'")

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
}
