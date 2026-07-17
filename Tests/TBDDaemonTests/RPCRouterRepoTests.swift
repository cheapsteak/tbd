import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// Repo-scoped RPC methods: repo.add, repo.list, repo.remove,
// repo.updateInstructions, plus the unknown-method fallthrough (a
// generic router behavior that doesn't belong with any single subsystem).
extension RPCRouterTests {

    // MARK: - Repo Tests

    @Test("repo.add validates git repo and inserts into db")
    func repoAdd() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let request = try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: repoDir.path))
        let response = await router.handle(request)

        #expect(response.success)
        #expect(response.error == nil)

        let repo = try response.decodeResult(Repo.self)
        #expect(repo.path == repoDir.path)
    }

    @Test("repo.add rejects non-git directory")
    func repoAddNonGit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: tempDir.path))
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Not a git repository") == true)
    }

    @Test("repo.list returns all repos")
    func repoList() async throws {
        // Add a repo directly to db
        _ = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = RPCRequest(method: RPCMethod.repoList)
        let response = await router.handle(request)

        #expect(response.success)
        let repos = try response.decodeResult([Repo].self)
        #expect(repos.count >= 1)
    }

    @Test("repo.remove deletes repo from db")
    func repoRemove() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repo.id)
        )
        let response = await router.handle(request)

        #expect(response.success)

        // Verify it's gone
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched == nil)
    }

    @Test("repo.remove refuses when active worktrees exist without force")
    func repoRemoveRefusesActiveWorktrees() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repo.id, force: false)
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("active worktree") == true)
    }

    /// Medium-2 review finding: `repo.remove` hard-deletes every worktree
    /// row for the repo (`deleteForRepo`, all statuses) with no chance for
    /// the sweep's own reconciliation to catch up afterward — the rows are
    /// gone. Verifies the RPC path reclaims an archived row's scratchpad
    /// before the delete, wired through a real `OrphanGC` with an injected
    /// scratchpad base (mirrors `GCHandlersTests.makeGC`).
    @Test("repo.remove reclaims scratchpads for gone worktree rows before deleting them")
    func repoRemoveReclaimsScratchpadsBeforeDeletingRows() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("repo-remove-scratchpad-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
        router.orphanGC = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }, scratchpadBase: base)

        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "acme", defaultBranch: "main"
        )
        let goneWorktreePath = sandbox.appendingPathComponent("gone-wt").path
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "gone-wt", branch: "gone-wt",
            path: goneWorktreePath, tmuxServer: "test-server"
        )
        try await db.worktrees.archive(id: row.id)

        let slug = ScratchpadCollector.slug(forWorktreePath: goneWorktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let request = try RPCRequest(method: RPCMethod.repoRemove, params: RepoRemoveParams(repoID: repo.id, force: true))
        let response = await router.handle(request)
        #expect(response.success)

        #expect(!FileManager.default.fileExists(atPath: scratchDir.path),
                "the archived row's scratchpad must be reclaimed before its row disappears")
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.contains { $0.kind == .scratchpad && $0.worktreePath == scratchDir.path && $0.repoPath == repo.path })
    }

    @Test("repo.remove with gcEnabled=false leaves scratchpads untouched")
    func repoRemoveLeavesScratchpadsWhenGCDisabled() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("repo-remove-scratchpad-disabled-test-\(UUID().uuidString)")
        let base = sandbox.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
        router.orphanGC = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }, scratchpadBase: base)

        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "acme", defaultBranch: "main"
        )
        let goneWorktreePath = sandbox.appendingPathComponent("gone-wt").path
        let row = try await db.worktrees.create(
            repoID: repo.id, name: "gone-wt", branch: "gone-wt",
            path: goneWorktreePath, tmuxServer: "test-server"
        )
        try await db.worktrees.archive(id: row.id)

        let slug = ScratchpadCollector.slug(forWorktreePath: goneWorktreePath)
        let scratchDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let request = try RPCRequest(method: RPCMethod.repoRemove, params: RepoRemoveParams(repoID: repo.id, force: true))
        let response = await router.handle(request)
        #expect(response.success)

        #expect(FileManager.default.fileExists(atPath: scratchDir.path),
                "gcEnabled=false must suppress repo-removal scratchpad reconciliation too")
    }

    // MARK: - Repo Instructions Tests

    @Test("repo.updateInstructions stores and retrieves instructions")
    func repoUpdateInstructions() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(
                repoID: repo.id,
                renamePrompt: "Use cw/4/feat- prefix",
                customInstructions: "Always use pytest"
            )
        )
        let response = await router.handle(request)

        #expect(response.success)
        let updated = try response.decodeResult(Repo.self)
        #expect(updated.renamePrompt == "Use cw/4/feat- prefix")
        #expect(updated.customInstructions == "Always use pytest")

        // Verify via repo.list
        let listResp = await router.handle(RPCRequest(method: RPCMethod.repoList))
        let repos = try listResp.decodeResult([Repo].self)
        let found = repos.first { $0.id == repo.id }
        #expect(found?.renamePrompt == "Use cw/4/feat- prefix")
        #expect(found?.customInstructions == "Always use pytest")
    }

    @Test("repo.updateInstructions with nil clears instructions")
    func repoUpdateInstructionsClear() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        // Set instructions
        let setReq = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: repo.id, renamePrompt: "test", customInstructions: "test")
        )
        _ = await router.handle(setReq)

        // Clear them
        let clearReq = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: repo.id, renamePrompt: nil, customInstructions: nil)
        )
        let response = await router.handle(clearReq)

        #expect(response.success)
        let updated = try response.decodeResult(Repo.self)
        #expect(updated.renamePrompt == nil)
        #expect(updated.customInstructions == nil)
    }

    @Test("repo.updateInstructions returns error for unknown repo")
    func repoUpdateInstructionsUnknownRepo() async throws {
        let request = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: UUID(), renamePrompt: nil, customInstructions: nil)
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Repository not found") == true)
    }

    @Test("existing repos have nil instructions after migration")
    func existingReposNilInstructions() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.renamePrompt == nil)
        #expect(fetched?.customInstructions == nil)
    }

    // MARK: - Unknown Method

    @Test("unknown method returns error")
    func unknownMethod() async throws {
        let request = RPCRequest(method: "foo.bar")
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == true)
    }

    // MARK: - repo.listOpenPRs in-use filter

    private func openPR(_ number: Int, head: String, fork: Bool = false) -> OpenPRInfo {
        OpenPRInfo(number: number, title: "PR \(number)", headRefName: head,
                   headOwner: "acme", isCrossRepository: fork, isDraft: false)
    }

    @Test("filterOpenPRsNotInUse drops a PR whose number is stamped on a worktree even when branch names differ")
    func filterOpenPRsDropsByStoredNumber() {
        // The PR head was fetched under a uniquified local branch ("feature-2"),
        // so its head name ("feature") is NOT in the in-use branch set, but the
        // worktree row carries PR #42 — the number filter must still drop it.
        let prs = [openPR(42, head: "feature"), openPR(43, head: "other")]
        let filtered = RPCRouter.filterOpenPRsNotInUse(
            prs, inUseBranches: ["feature-2"], inUsePRNumbers: [42])
        #expect(filtered.map(\.number) == [43])
    }

    @Test("filterOpenPRsNotInUse still drops a PR by matching head branch name")
    func filterOpenPRsDropsByBranchName() {
        let prs = [openPR(42, head: "feature"), openPR(43, head: "other")]
        let filtered = RPCRouter.filterOpenPRsNotInUse(
            prs, inUseBranches: ["feature"], inUsePRNumbers: [])
        #expect(filtered.map(\.number) == [43])
    }

    @Test("filterOpenPRsNotInUse keeps PRs that are neither checked out nor stamped")
    func filterOpenPRsKeepsFree() {
        let prs = [openPR(42, head: "feature"), openPR(43, head: "other")]
        let filtered = RPCRouter.filterOpenPRsNotInUse(
            prs, inUseBranches: ["unrelated"], inUsePRNumbers: [99])
        #expect(filtered.map(\.number) == [42, 43])
    }

    @Test("filterOpenPRsNotInUse keeps a fork PR whose head name coincidentally matches an in-use branch")
    func filterOpenPRsKeepsForkWithMatchingBranchName() {
        // Fork PR head lives in the contributor's namespace, not origin's — a
        // same-named checked-out branch is a coincidence, not the same ref.
        let prs = [openPR(42, head: "main", fork: true)]
        let filtered = RPCRouter.filterOpenPRsNotInUse(
            prs, inUseBranches: ["main"], inUsePRNumbers: [])
        #expect(filtered.map(\.number) == [42])
    }

    @Test("filterOpenPRsNotInUse still drops a fork PR by stored PR number")
    func filterOpenPRsDropsForkByStoredNumber() {
        let prs = [openPR(42, head: "main", fork: true)]
        let filtered = RPCRouter.filterOpenPRsNotInUse(
            prs, inUseBranches: ["main"], inUsePRNumbers: [42])
        #expect(filtered.map(\.number) == [])
    }

    @Test("filterOpenPRsNotInUse still drops a same-repo PR by matching head branch name")
    func filterOpenPRsDropsSameRepoByBranchName() {
        let prs = [openPR(42, head: "feature", fork: false)]
        let filtered = RPCRouter.filterOpenPRsNotInUse(
            prs, inUseBranches: ["feature"], inUsePRNumbers: [])
        #expect(filtered.map(\.number) == [])
    }
}
