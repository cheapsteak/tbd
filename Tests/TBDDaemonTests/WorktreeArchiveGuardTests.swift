import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct WorktreeArchiveGuardTests {

    @Test func archivingParentWithActiveChildrenFails() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main"
        )
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "tbd/p",
            path: "/tmp/p-\(UUID())", tmuxServer: "srv"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent.id
        )

        await #expect(throws: (any Error).self) {
            try await db.worktrees.assertArchivable(id: parent.id)
        }
    }

    @Test func archivingLeafSucceedsAndCrossRepoChildBlocks() async throws {
        let db = try TBDDatabase(inMemory: true)
        let r1 = try await db.repos.create(path: "/tmp/r1-\(UUID())", displayName: "R1", defaultBranch: "main")
        let r2 = try await db.repos.create(path: "/tmp/r2-\(UUID())", displayName: "R2", defaultBranch: "main")
        let parent = try await db.worktrees.create(
            repoID: r1.id, name: "p", branch: "tbd/p",
            path: "/tmp/p-\(UUID())", tmuxServer: "srv"
        )
        let child = try await db.worktrees.create(
            repoID: r2.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent.id
        )

        // Cross-repo child still blocks archive of parent
        await #expect(throws: (any Error).self) {
            try await db.worktrees.assertArchivable(id: parent.id)
        }

        // Leaf child is archivable
        try await db.worktrees.assertArchivable(id: child.id)
    }

    @Test func archivingParentWithOnlyArchivedChildrenSucceeds() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "R", defaultBranch: "main"
        )
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "tbd/p",
            path: "/tmp/p-\(UUID())", tmuxServer: "srv"
        )
        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "tbd/c",
            path: "/tmp/c-\(UUID())", tmuxServer: "srv",
            parentWorktreeID: parent.id
        )
        try await db.worktrees.updateStatus(id: child.id, status: .archived)

        // Should succeed — only active/creating children block
        try await db.worktrees.assertArchivable(id: parent.id)
    }
}
