import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("GitStatus Tests")
struct GitStatusTests {

    @Test func newWorktreeHasCurrentGitStatus() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        #expect(wt.gitStatus == .current)
    }

    @Test func updateGitStatusToConflicts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.updateGitStatus(id: wt.id, gitStatus: .conflicts)
        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.gitStatus == .conflicts)
    }

    @Test func updateGitStatusToBehind() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.updateGitStatus(id: wt.id, gitStatus: .behind)
        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.gitStatus == .behind)
    }

    @Test func updateGitStatusRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        // Set to merged, then back to current
        try await db.worktrees.updateGitStatus(id: wt.id, gitStatus: .merged)
        let merged = try await db.worktrees.get(id: wt.id)
        #expect(merged?.gitStatus == .merged)

        try await db.worktrees.updateGitStatus(id: wt.id, gitStatus: .current)
        let current = try await db.worktrees.get(id: wt.id)
        #expect(current?.gitStatus == .current)
    }
}
