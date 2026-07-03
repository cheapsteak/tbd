import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Scratch exclusion by construction")
struct ScratchExclusionTests {

    /// Direct, falsifiable proof of the poller guard: a scratch worktree is
    /// dropped and a regular (repo-scoped) worktree is kept. Exercises
    /// `RPCRouter.pollableWorktrees` in isolation — no git/gh machinery, no
    /// dependence on `PRStatusManager`'s incidental empty-branch behavior —
    /// so an inverted or deleted filter fails this test immediately.
    @Test("pollableWorktrees drops scratch rows and keeps regular rows")
    func pollableWorktreesDiscriminatesScratchFromRegular() {
        let regular = Worktree(
            repoID: UUID(), name: "r", displayName: "r", branch: "tbd/r",
            path: "/tmp/regular", tmuxServer: "tbd-r")
        let scratch = Worktree(
            repoID: nil, name: "s", displayName: "s", branch: "",
            path: "/tmp/scratch", tmuxServer: "tbd-scratch")

        let pollable = RPCRouter.pollableWorktrees([regular, scratch])

        #expect(pollable.map(\.id) == [regular.id])
        #expect(!pollable.contains { $0.id == scratch.id })
    }

    @Test("pr.list never includes a scratch worktree")
    func prListExcludesScratch() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/scr-\(UUID().uuidString)", tmuxServer: "tbd-scratch")

        let response = await router.handle(RPCRequest(method: RPCMethod.prList))
        #expect(response.success)
        let result = try response.decodeResult(PRListResult.self)
        #expect(result.statuses[scratch.id] == nil)
    }

    @Test("reconcile only ever lists worktrees scoped to a repoID")
    func reconcileIsRepoScoped() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/scr-\(UUID().uuidString)", tmuxServer: "tbd-scratch")
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Reconcile is entered per repo and scopes its worktree lookups to
        // that repoID — a scratch row (repoID == nil) can never be in scope,
        // even when the repo itself is real and reconcile runs to completion.
        try await lifecycle.reconcile(repoID: repo.id)
        let after = try await db.worktrees.get(id: scratch.id)
        #expect(after != nil)               // untouched
        #expect(after?.status == .active)   // not archived
        #expect(after?.repoID == nil)
    }
}
