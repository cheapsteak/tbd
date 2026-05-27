import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Worktree-scoped RPC methods.
extension RPCRouterTests {

    // MARK: - Worktree Tests

    @Test("worktree.list returns worktrees filtered by status")
    func worktreeList() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id,
            name: "active-wt",
            branch: "tbd/active-wt",
            path: "/tmp/active-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repo.id, status: .active)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let worktrees = try response.decodeResult([Worktree].self)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].name == "active-wt")
    }

    @Test("worktree.rename updates display name")
    func worktreeRename() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.worktreeRename,
            params: WorktreeRenameParams(worktreeID: wt.id, displayName: "My Feature")
        )
        let response = await router.handle(request)

        #expect(response.success)

        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.displayName == "My Feature")
    }

    @Test("worktree.list with limit returns paginated results")
    func worktreeListWithLimit() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt1 = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt1",
            branch: "b1",
            path: "/tmp/wt1-\(UUID())",
            tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt2",
            branch: "b2",
            path: "/tmp/wt2-\(UUID())",
            tmuxServer: "srv2"
        )
        let wt3 = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt3",
            branch: "b3",
            path: "/tmp/wt3-\(UUID())",
            tmuxServer: "srv3"
        )

        // Page 1: limit 2
        let request1 = try RPCRequest(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repo.id, status: .active, limit: 2, offset: 0)
        )
        let response1 = await router.handle(request1)
        #expect(response1.success)
        let page1 = try response1.decodeResult([Worktree].self)
        #expect(page1.map(\.id) == [wt1.id, wt2.id])

        // Page 2: limit 2, offset 2
        let request2 = try RPCRequest(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repo.id, status: .active, limit: 2, offset: 2)
        )
        let response2 = await router.handle(request2)
        #expect(response2.success)
        let page2 = try response2.decodeResult([Worktree].self)
        #expect(page2.map(\.id) == [wt3.id])
    }

    @Test("worktree.list archived with pagination sorts by archivedAt desc")
    func worktreeListArchivedPagination() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt1 = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt1",
            branch: "b1",
            path: "/tmp/wt1-\(UUID())",
            tmuxServer: "srv1"
        )
        let wt2 = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt2",
            branch: "b2",
            path: "/tmp/wt2-\(UUID())",
            tmuxServer: "srv2"
        )

        try await db.worktrees.archive(id: wt1.id)
        try await db.worktrees.archive(id: wt2.id)

        // Get archived with limit
        let request = try RPCRequest(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repo.id, status: .archived, limit: 1, offset: 0)
        )
        let response = await router.handle(request)
        #expect(response.success)
        let page = try response.decodeResult([Worktree].self)
        // Most recent archive (wt2) should be first
        #expect(page.map(\.id) == [wt2.id])
    }
}
