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

    /// Scratch is the ONLY exclusion. A remote row is pollable — it carries a PR
    /// badge like any other row, and `RPCRouter.pollWorkingDirectory` gives it
    /// the repo's checkout to run in. That contract and its no-cross-assignment
    /// consequences live in `PRPollRemoteLaneTests`; this pins that the scratch
    /// filter was not widened back into a location filter.
    @Test("pollableWorktrees keeps remote rows alongside local ones")
    func pollableWorktreesKeepsRemoteRows() {
        let local = Worktree(
            repoID: UUID(), name: "l", displayName: "l", branch: "tbd/l",
            path: "/tmp/local", tmuxServer: "tbd-l")
        let remote = Worktree(
            repoID: UUID(), name: "r", displayName: "r", branch: "tbd/r",
            path: "remote://agentbox/s-1", tmuxServer: "",
            location: .remote(provider: "agentbox", sessionID: "s-1"))

        let pollable = RPCRouter.pollableWorktrees([local, remote])

        #expect(pollable.map(\.id) == [local.id, remote.id])
    }

    @Test("pr.list never includes a scratch worktree")
    func prListExcludesScratch() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/scr-\(UUID().uuidString)", tmuxServer: "tbd-scratch")

        let response = await router.handle(RPCRequest(method: RPCMethod.prList))
        #expect(response.success)
        let result = try response.decodeResult(PRListResult.self)
        #expect(result.statuses[scratch.id] == nil)
    }

    /// The other half of the same guard, and the one that was missing: the poll
    /// skipped a scratch row while `pr.refresh` (which the app fires the moment
    /// a row is selected) queried it anyway. The query ran in a directory that
    /// is not a checkout, failed, and the failure was recorded as `.undetermined`,
    /// which every PR surface renders as an unresolvable "?" badge. Asserting the
    /// DB row too, because the recorded outcome is what outlived the attempt: it
    /// is re-hydrated at every daemon start and read straight off the row by the
    /// app.
    @Test("pr.refresh makes no attempt for a scratch worktree")
    func prRefreshMakesNoAttemptForScratch() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/scr-\(UUID().uuidString)", tmuxServer: "tbd-scratch")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: scratch.id)))
        let result = try response.decodeResult(PRRefreshResult.self)

        #expect(result.status == nil)
        #expect(result.observation == nil,
                "no attempt was made: neither `.none` nor `.undetermined`")
        #expect(try await db.worktrees.get(id: scratch.id)?.prObservation == nil,
                "a scratch row must not acquire a recorded outcome that outlives the attempt")
    }

    /// A repo-scoped row still gets asked. Without this the fix above could be
    /// widened into "never refresh anything" and nothing would notice: the test
    /// environment has no usable `gh`, so the attempt cannot resolve, but it
    /// must still be *made* and reported as unresolved.
    @Test("pr.refresh still attempts a repo-scoped worktree")
    func prRefreshStillAttemptsRegularRows() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/repo-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let regular = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "tbd/w",
            path: "/tmp/wt-\(UUID().uuidString)", tmuxServer: "tbd-w")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: regular.id)))
        let result = try response.decodeResult(PRRefreshResult.self)

        let outcome = try #require(result.observation?.outcome,
                                   "a repo-scoped row is still asked about")
        if case .undetermined = outcome {} else {
            Issue.record("expected the unresolved attempt to be .undetermined, observed \(outcome)")
        }
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
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
        let after = try await db.worktrees.get(id: scratch.id)
        #expect(after != nil)               // untouched
        #expect(after?.status == .active)   // not archived
        #expect(after?.repoID == nil)
    }
}
