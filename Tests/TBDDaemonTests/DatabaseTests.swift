import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Database Tests")
struct DatabaseTests {

    // MARK: - Repo Tests

    @Test func createAndListRepos() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        #expect(repo.displayName == "test")

        let repos = try await db.repos.list()
        #expect(repos.count == 1)
        #expect(repos[0].id == repo.id)
    }

    @Test func removeRepo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        try await db.repos.remove(id: repo.id)
        let repos = try await db.repos.list()
        #expect(repos.isEmpty)
    }

    @Test func findRepoByPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let found = try await db.repos.findByPath(path: "/tmp/test")
        #expect(found != nil)
        #expect(found?.displayName == "test")

        let notFound = try await db.repos.findByPath(path: "/tmp/nonexistent")
        #expect(notFound == nil)
    }

    @Test func getRepoByID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched != nil)
        #expect(fetched?.id == repo.id)
    }

    // MARK: - Worktree Tests

    @Test func createAndListWorktrees() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "20260321-fuzzy-penguin",
            branch: "tbd/20260321-fuzzy-penguin",
            path: "/tmp/test/.tbd/worktrees/20260321-fuzzy-penguin",
            tmuxServer: "tbd-a1b2c3d4"
        )
        #expect(wt.status == .active)
        #expect(wt.displayName == "20260321-fuzzy-penguin")

        let worktrees = try await db.worktrees.list(repoID: repo.id)
        #expect(worktrees.count == 1)
    }

    @Test func archiveWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.archive(id: wt.id)
        let archived = try await db.worktrees.get(id: wt.id)
        #expect(archived?.status == .archived)
        #expect(archived?.archivedAt != nil)
    }

    @Test func reviveWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.archive(id: wt.id)
        try await db.worktrees.revive(id: wt.id)
        let revived = try await db.worktrees.get(id: wt.id)
        #expect(revived?.status == .active)
        #expect(revived?.archivedAt == nil)
    }

    @Test func renameWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.rename(id: wt.id, displayName: "My Feature")
        let renamed = try await db.worktrees.get(id: wt.id)
        #expect(renamed?.displayName == "My Feature")
    }

    @Test func findWorktreeByPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        let found = try await db.worktrees.findByPath(path: "/tmp/test/.tbd/worktrees/test-wt")
        #expect(found != nil)
    }

    @Test func deleteWorktreesForRepo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "wt1", branch: "tbd/wt1",
            path: "/tmp/test/.tbd/worktrees/wt1", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "wt2", branch: "tbd/wt2",
            path: "/tmp/test/.tbd/worktrees/wt2", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.deleteForRepo(repoID: repo.id)
        let worktrees = try await db.worktrees.list(repoID: repo.id)
        #expect(worktrees.isEmpty)
    }

    @Test func listWorktreesByStatus() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt1 = try await db.worktrees.create(
            repoID: repo.id, name: "wt1", branch: "tbd/wt1",
            path: "/tmp/test/.tbd/worktrees/wt1", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "wt2", branch: "tbd/wt2",
            path: "/tmp/test/.tbd/worktrees/wt2", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.archive(id: wt1.id)

        let active = try await db.worktrees.list(status: .active)
        #expect(active.count == 1)
        let archived = try await db.worktrees.list(status: .archived)
        #expect(archived.count == 1)
    }

    // MARK: - Terminal Tests

    @Test func createAndListTerminals() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        let term = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0", label: "claude"
        )
        #expect(term.label == "claude")

        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 1)
    }

    @Test func deleteTerminal() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        let term = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0"
        )
        try await db.terminals.delete(id: term.id)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.isEmpty)
    }

    @Test func deleteTerminalsForWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0")
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%1")
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.isEmpty)
    }

    // MARK: - Terminal Pin Tests

    @Test func terminalSetPinAndUnpin() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-term-pin", displayName: "Test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test-term-pin/.tbd/worktrees/test-wt", tmuxServer: "test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1"
        )

        // Initially not pinned
        let initial = try await db.terminals.get(id: terminal.id)
        #expect(initial?.pinnedAt == nil)

        // Pin it
        try await db.terminals.setPin(id: terminal.id, pinned: true)
        let pinned = try await db.terminals.get(id: terminal.id)
        #expect(pinned?.pinnedAt != nil)

        // Unpin it
        try await db.terminals.setPin(id: terminal.id, pinned: false)
        let unpinned = try await db.terminals.get(id: terminal.id)
        #expect(unpinned?.pinnedAt == nil)
    }

    @Test func pinnedTerminalsOrderByPinnedAt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-term-pin-order", displayName: "Test2", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt-1", branch: "tbd/wt-1",
            path: "/tmp/test-term-pin-order/.tbd/worktrees/wt-1", tmuxServer: "test"
        )
        let t1 = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1"
        )
        let t2 = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2"
        )

        // Pin t2 first, then t1
        try await db.terminals.setPin(id: t2.id, pinned: true)
        try await Task.sleep(for: .milliseconds(10))
        try await db.terminals.setPin(id: t1.id, pinned: true)

        let all = try await db.terminals.list(worktreeID: wt.id)
        let pinned = all.filter { $0.pinnedAt != nil }
        let sorted = pinned.sorted { ($0.pinnedAt ?? Date.distantPast) < ($1.pinnedAt ?? Date.distantPast) }

        #expect(sorted.count == 2)
        #expect(sorted[0].id == t2.id)
        #expect(sorted[1].id == t1.id)
    }

    // MARK: - Notification Tests

    @Test func createAndReadNotifications() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error, message: "build failed")

        let unread = try await db.notifications.unread(worktreeID: wt.id)
        #expect(unread.count == 2)

        try await db.notifications.markRead(worktreeID: wt.id)
        let afterRead = try await db.notifications.unread(worktreeID: wt.id)
        #expect(afterRead.isEmpty)
    }

    @Test func highestSeverityNotification() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error)

        let highest = try await db.notifications.highestSeverity(worktreeID: wt.id)
        #expect(highest == .error)
    }

    @Test func highestSeverityReturnsNilWhenNoUnread() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        let highest = try await db.notifications.highestSeverity(worktreeID: wt.id)
        #expect(highest == nil)
    }
}
