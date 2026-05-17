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
}
