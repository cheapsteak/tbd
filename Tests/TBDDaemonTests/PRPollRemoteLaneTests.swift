import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A remote lane carries a PR badge like any other row
/// (`docs/specs/2026-08-10-remote-sessions-in-worktree-tree-design.md`, "PR
/// polling is fenced, and has to be un-fenced by branch"). Un-fencing means the
/// poll keys on the **branch** and runs in the repo's own checkout, so several
/// rows now resolve to one working directory. These tests pin both halves: the
/// directory each row resolves to, and that rows sharing one are still told
/// apart.
///
/// Tier 1 for the resolution tests (pure functions, no I/O); tier 2 for the
/// composition and `pr.list` tests, which use a real temp git repo, real `git`
/// subprocesses and an in-memory DB. `gh` is always a stub — never the network.
@Suite("PR poll: remote lanes")
struct PRPollRemoteLaneTests {

    // MARK: - Fixtures

    private static func localRow(
        repoID: UUID, branch: String, path: String
    ) -> Worktree {
        Worktree(repoID: repoID, name: "l", displayName: "l", branch: branch,
                 path: path, tmuxServer: "tbd-l")
    }

    private static func remoteRow(
        repoID: UUID?, branch: String, sessionID: String
    ) -> Worktree {
        Worktree(repoID: repoID, name: "r", displayName: "r", branch: branch,
                 path: WorktreeLocation.remote(provider: "agentbox", sessionID: sessionID)
                    .storagePath ?? "",
                 tmuxServer: "",
                 location: .remote(provider: "agentbox", sessionID: sessionID))
    }

    /// Seed the mirror row whose `meta` the poll reads a lane's live branch from.
    private static func seedMirror(_ db: TBDDatabase, provider: String = "agentbox",
                                   sessionID: String, meta: [String: String]?) async throws {
        _ = try await db.remoteSessions.upsertOne(
            provider: provider,
            session: RemoteSessionPayload(id: sessionID, state: .running, meta: meta),
            now: Date())
    }

    // MARK: - Which branch a row is matched on

    @Test("a remote row whose stored branch is main matches on its live branch")
    func remoteRowUsesLiveBranch() {
        let lane = Self.remoteRow(repoID: UUID(), branch: "main", sessionID: "s-1")
        #expect(RPCRouter.pollBranch(for: lane, mirrorMeta: ["branch": "claude/fix-x"]) == .match("claude/fix-x"))
    }

    @Test("an absent, blank or invalid live branch skips branch matching, never falling back",
          arguments: [nil, [:], ["branch": ""], ["branch": "-rf"], ["branch": "a..b"]] as [[String: String]?])
    func remoteRowWithoutLiveBranchIsBindingsOnly(_ meta: [String: String]?) {
        let lane = Self.remoteRow(repoID: UUID(), branch: "main", sessionID: "s-1")
        #expect(RPCRouter.pollBranch(for: lane, mirrorMeta: meta) == .bindingsOnly)
    }

    @Test("a local row still uses its stored branch, whatever a mirror says")
    func localRowUsesStoredBranch() {
        let local = Self.localRow(repoID: UUID(), branch: "tbd/local", path: "/tmp/l")
        #expect(RPCRouter.pollBranch(for: local, mirrorMeta: ["branch": "other"]) == .match("tbd/local"))
    }

    /// A landed lane is `.local` with its origin retained, so the mirror still
    /// has a row for its session. It is a local worktree now.
    @Test("a landed lane polls on its local stored branch, not the mirror's live one")
    func landedLaneIsLocal() {
        var landed = Self.localRow(repoID: UUID(), branch: "claude/landed", path: "/tmp/landed")
        landed.origin = WorktreeOrigin(provider: "agentbox", sessionID: "s-1")
        #expect(RPCRouter.pollBranch(for: landed, mirrorMeta: ["branch": "claude/other"]) == .match("claude/landed"))
    }

    @Test("mirror meta is keyed by provider and session, and a gone row still counts")
    func mirrorMetaByOriginKeys() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/a"])
        try await Self.seedMirror(db, sessionID: "s-b", meta: nil)
        #expect(try await db.remoteSessions.markGone(provider: "agentbox", sessionID: "s-a"))
        let byOrigin = RPCRouter.mirrorMetaByOrigin(try await db.remoteSessions.list())
        #expect(byOrigin[WorktreeOrigin(provider: "agentbox", sessionID: "s-a")] == ["branch": "tbd/a"])
        #expect(byOrigin[WorktreeOrigin(provider: "agentbox", sessionID: "s-b")] == nil)
    }

    // MARK: - Which rows are pollable

    /// The fence that this change removes. A remote lane survives
    /// `pollableWorktrees`; a scratch row still does not, because it is repo-less
    /// and has no PR to poll for at all.
    @Test("pollableWorktrees keeps remote lanes and still drops scratch rows")
    func pollableKeepsRemoteDropsScratch() {
        let repoID = UUID()
        let local = Self.localRow(repoID: repoID, branch: "tbd/local", path: "/tmp/local")
        let remote = Self.remoteRow(repoID: repoID, branch: "tbd/lane", sessionID: "s-1")
        let scratch = Worktree(repoID: nil, name: "s", displayName: "s", branch: "",
                               path: "/tmp/scratch", tmuxServer: "tbd-scratch")

        let pollable = RPCRouter.pollableWorktrees([local, remote, scratch])

        #expect(pollable.map(\.id) == [local.id, remote.id])
    }

    // MARK: - Where a row's poll runs

    @Test("a local row polls in its own checkout")
    func localRowUsesOwnCheckout() {
        let repoID = UUID()
        let local = Self.localRow(repoID: repoID, branch: "tbd/local", path: "/repos/acme/wt/local")

        let dir = RPCRouter.pollWorkingDirectory(local, repoPathByID: [repoID: "/repos/acme"])

        #expect(dir == "/repos/acme/wt/local")
    }

    /// The whitelist assertion that matters most for a remote row: the answer is
    /// the REPO's checkout, and the synthetic `remote://` URI the row stores is
    /// not merely filtered out downstream — it is unreachable from here.
    @Test("a remote row polls in its repo's checkout, never its remote:// path")
    func remoteRowUsesRepoCheckout() {
        let repoID = UUID()
        let remote = Self.remoteRow(repoID: repoID, branch: "tbd/lane", sessionID: "s-1")
        #expect(remote.localPath == "remote://agentbox/s-1")   // the value that must not escape

        let dir = RPCRouter.pollWorkingDirectory(remote, repoPathByID: [repoID: "/repos/acme"])

        #expect(dir == "/repos/acme")
    }

    /// The other half of the guard `handlePRRefresh` used to inherit from
    /// `getLocal`, which rejected an empty path as well as a remote row
    /// (`LocalWorktree.init?`). Now that the refresh resolves its directory
    /// through `pollWorkingDirectory` instead, that arm has to live here.
    ///
    /// It matters because the failure is silent rather than loud:
    /// `URL(fileURLWithPath: "")` is the *daemon's own* working directory, so
    /// an empty path would run `git` and `gh` somewhere plausible and cache the
    /// answers under this row — unlike a `remote://` URI, which would fail
    /// visibly.
    @Test("a local row with no path yet is not polled at all")
    func localRowWithEmptyPathIsSkipped() {
        let repoID = UUID()
        let pathless = Self.localRow(repoID: repoID, branch: "tbd/local", path: "")

        #expect(RPCRouter.pollWorkingDirectory(
            pathless, repoPathByID: [repoID: "/repos/acme"]) == nil)
    }

    @Test("a remote row whose repo is unknown is not polled at all")
    func remoteRowWithoutResolvableRepoIsSkipped() {
        let remote = Self.remoteRow(repoID: UUID(), branch: "tbd/lane", sessionID: "s-1")
        let orphan = Self.remoteRow(repoID: nil, branch: "tbd/lane", sessionID: "s-2")

        // Repo deleted (id not in the map) and a row with no repoID at all.
        #expect(RPCRouter.pollWorkingDirectory(remote, repoPathByID: [:]) == nil)
        #expect(RPCRouter.pollWorkingDirectory(orphan, repoPathByID: [UUID(): "/repos/acme"]) == nil)
    }

    // MARK: - What the composed poll input IS

    /// The collision case, stated positively: one repo holding a local worktree
    /// and two remote lanes on different branches composes THREE entries that
    /// share a repo but not an identity. Asserted as a whitelist — the exact
    /// `(id, branch, worktreePath, defaultBranch)` of each — so a change that
    /// merged, dropped, or cross-assigned an entry fails here rather than
    /// showing up as a wrong badge.
    @Test("one repo's local worktree and two remote lanes compose three distinct entries")
    func threeRowsOneRepoComposeThreeDistinctEntries() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let localDir = tempDir.appendingPathComponent("wt-local")
        try await shell("git worktree add \(localDir.path) -b tbd/local-lane", at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let local = try await db.worktrees.create(
            repoID: repo.id, name: "local", branch: "tbd/local-lane",
            path: localDir.path, tmuxServer: "tbd-local")
        // Stored branches are both `main`: a lane's stored branch is identity,
        // frozen at adoption, and the poll must match on the LIVE branch the
        // mirror carries instead.
        let laneA = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-a", branch: "main",
            provider: "agentbox", sessionID: "s-a")
        let laneB = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-b", branch: "main",
            provider: "agentbox", sessionID: "s-b")
        // No mirror row at all: no live branch, so bindings only.
        let laneC = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-c", branch: "main",
            provider: "agentbox", sessionID: "s-c")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/remote-a"])
        try await Self.seedMirror(db, sessionID: "s-b", meta: ["branch": "tbd/remote-b"])
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s",
            path: tempDir.appendingPathComponent("scratch").path, tmuxServer: "tbd-scratch")

        let router = Self.makeRouter(db: db, gh: nil)
        let rows = RPCRouter.pollableWorktrees(try await db.worktrees.list(status: .active))
        let plan = await router.pollEntries(
            rows, repos: try await db.repos.list(),
            mirrorMeta: RPCRouter.mirrorMetaByOrigin(try await db.remoteSessions.list()))
        let entries = plan.matched

        #expect(!rows.contains { $0.id == scratch.id })
        #expect(entries.count == 3)
        #expect(!entries.contains { $0.id == laneC.id })
        #expect(plan.bindingsOnly.map(\.id) == [laneC.id])
        #expect(plan.bindingsOnly.first?.worktreePath == repoDir.path)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        // The local row is untouched by the change: its own checkout, its own branch.
        #expect(byID[local.id]?.branch == "tbd/local-lane")
        #expect(byID[local.id]?.worktreePath == localDir.path)
        #expect(byID[local.id]?.defaultBranch == "main")

        // Each lane carries the REPO's checkout and its own LIVE branch.
        #expect(byID[laneA.id]?.branch == "tbd/remote-a")
        #expect(byID[laneA.id]?.worktreePath == repoDir.path)
        #expect(byID[laneA.id]?.defaultBranch == "main")
        #expect(byID[laneB.id]?.branch == "tbd/remote-b")
        #expect(byID[laneB.id]?.worktreePath == repoDir.path)
        #expect(byID[laneB.id]?.defaultBranch == "main")

        // Sharing a path is fine; sharing an identity is not. Three ids, two
        // paths, three branches.
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(Set(entries.map(\.branch)).count == 3)
        #expect(!entries.contains { $0.worktreePath.hasPrefix("remote://") })
    }

    /// A lane whose repo row was deleted has no directory to run in, so it is
    /// dropped from the composed input rather than polled against a path that
    /// does not exist.
    @Test("a remote lane with no resolvable repo is absent from the composed input")
    func laneWithoutRepoIsAbsentFromComposedInput() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = Self.makeRouter(db: db, gh: nil)
        let repoID = UUID()
        let lane = Self.remoteRow(repoID: repoID, branch: "tbd/lane", sessionID: "s-1")

        let plan = await router.pollEntries(
            [lane], repos: [],
            mirrorMeta: [WorktreeOrigin(provider: "agentbox", sessionID: "s-1"): ["branch": "tbd/lane"]])

        #expect(plan.matched.isEmpty)
        #expect(plan.bindingsOnly.isEmpty)
    }

    // MARK: - End to end through pr.list

    /// The no-cross-assignment proof, driven through the real `pr.list` handler:
    /// three rows of one repo, three open PRs on three branches, one `gh` stub.
    /// Each row must end up with ITS OWN PR number, and no `gh` invocation may
    /// ever have run in a `remote://` directory.
    @Test("the poll gives each of three rows its own PR and never runs gh in a remote:// path")
    func prListDistinguishesThreeRowsOfOneRepo() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let localDir = tempDir.appendingPathComponent("wt-local")
        try await shell("git worktree add \(localDir.path) -b tbd/local-lane", at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let local = try await db.worktrees.create(
            repoID: repo.id, name: "local", branch: "tbd/local-lane",
            path: localDir.path, tmuxServer: "tbd-local")
        let laneA = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-a", branch: "main",
            provider: "agentbox", sessionID: "s-a")
        let laneB = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-b", branch: "main",
            provider: "agentbox", sessionID: "s-b")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/remote-a"])
        try await Self.seedMirror(db, sessionID: "s-b", meta: ["branch": "tbd/remote-b"])

        // `main` answers too, which proves the lanes' stored branch is never asked.
        let gh = RecordingGH(prsByBranch: [
            "tbd/local-lane": 101,
            "tbd/remote-a": 202,
            "tbd/remote-b": 303,
            "main": 999,
        ])
        let router = Self.makeRouter(db: db, gh: gh)

        // The poll pass, not `pr.list`: the RPC serves the snapshot the
        // daemon's own clock produced and never fetches.
        try await router.runPollPass()
        let response = await router.handle(RPCRequest(method: RPCMethod.prList))
        #expect(response.success)
        let result = try response.decodeResult(PRListResult.self)

        #expect(result.statuses[local.id]?.number == 101)
        #expect(result.statuses[laneA.id]?.number == 202)
        #expect(result.statuses[laneB.id]?.number == 303)
        #expect(!result.statuses.values.contains { $0.number == 999 })

        // The structural guarantee: the synthetic path never reaches a subprocess.
        let paths = await gh.recordedPaths
        #expect(!paths.isEmpty)
        #expect(!paths.contains { $0.hasPrefix("remote://") })
        #expect(Set(paths).isSubset(of: [repoDir.path, localDir.path]))
    }

    // MARK: - The targeted refresh takes the same working directory

    /// `pr.refresh` is the on-select sibling of the poll and must resolve its
    /// directory the same way, or a lane's badge would appear on the poll and
    /// vanish the moment the user selected the row. The by-branch query proves
    /// the branch that travelled with it was the LANE's, not the repo's HEAD.
    @Test("pr.refresh on a remote lane queries the lane's branch from the repo's checkout")
    func refreshOnRemoteLaneUsesRepoCheckoutAndOwnBranch() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-a", branch: "main",
            provider: "agentbox", sessionID: "s-a")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/remote-a"])

        let gh = RecordingGH(prsByBranch: ["tbd/remote-a": 202, "main": 999])
        let router = Self.makeRouter(db: db, gh: gh)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: lane.id)))
        #expect(response.success)
        let result = try response.decodeResult(PRRefreshResult.self)

        #expect(result.status?.number == 202)
        #expect(await gh.recordedBranches == ["tbd/remote-a"])
        #expect(Set(await gh.recordedPaths) == [repoDir.path])
    }

    @Test("pr.refresh on a lane with no live branch makes no attempt and runs no gh")
    func refreshWithoutLiveBranchMakesNoAttempt() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["repo": "acme/acme-prod"])
        let gh = RecordingGH(prsByBranch: ["main": 999])
        let router = Self.makeRouter(db: db, gh: gh)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: lane.id)))
        #expect(response.success)
        let result = try response.decodeResult(PRRefreshResult.self)
        #expect(result.status == nil)
        #expect(result.observation == nil)
        #expect(await gh.recordedPaths.isEmpty)
    }

    // MARK: - Bindings on remote lanes

    /// Before remote rows resolved their repo through the repo's checkout,
    /// every bind on a lane deferred, so a lane could hold no binding at all.
    @Test("a branch-found PR on a remote lane becomes a binding")
    func remoteLaneBranchMatchBinds() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/remote-a"])
        let router = Self.makeRouter(db: db, gh: RecordingGH(prsByBranch: ["tbd/remote-a": 202]))

        try await router.runPollPass()

        let bound = try await db.prBindings.list(worktreeID: lane.id)
        #expect(bound.map(\.number) == [202])
        #expect(bound.first?.source == .branch)
    }

    @Test("bindingRepoPath: local row -> own checkout, remote row -> repo checkout")
    func bindingRepoPathResolution() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/repos/acme", displayName: "acme", defaultBranch: "main")
        let local = try await db.worktrees.create(repoID: repo.id, name: "l", branch: "b",
                                                  path: "/repos/acme/wt/l", tmuxServer: "t")
        let lane = try await db.worktrees.createRemote(repoID: repo.id, name: "r", branch: "main",
                                                       provider: "agentbox", sessionID: "s")
        #expect(await RPCRouter.bindingRepoPath(worktreeID: local.id, db: db) == "/repos/acme/wt/l")
        #expect(await RPCRouter.bindingRepoPath(worktreeID: lane.id, db: db) == "/repos/acme")
        #expect(await RPCRouter.bindingRepoPath(worktreeID: UUID(), db: db) == nil)
    }

    /// A pass where every polled row is bindings-only: no row was matched by
    /// branch, and bound PRs must still refresh — with `gh` run in the repo's
    /// checkout, never the daemon's own working directory.
    @Test("a lane with no live branch still refreshes its bindings, in the repo's checkout")
    func bindingsOnlyLaneRefreshesInRepoCheckout() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await db.prBindings.upsert(PRBinding(
            worktreeID: lane.id, owner: "acme", repo: "acme-prod", number: 202,
            url: "https://github.com/acme/acme-prod/pull/202", source: .provider))
        let gh = RecordingGH(prsByBranch: ["tbd/remote-a": 202])
        let router = Self.makeRouter(db: db, gh: gh)

        try await router.runPollPass()

        let stored = try await db.prBindings.list(worktreeID: lane.id)
        #expect(stored.first?.status?.number == 202)
        let paths = await gh.recordedPaths
        #expect(!paths.isEmpty)
        #expect(paths.allSatisfy { $0 == repoDir.path })
    }

    // MARK: - Provider-named PRs in another repo, and on another host

    /// Pinning: a binding's status is looked up by its OWN owner and name, so
    /// a provider-named PR in a companion repo is observed there.
    @Test("a provider PR in another repo is refreshed against that repo")
    func foreignProviderPRRefreshesByItsOwnIdentity() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/remote-a"])
        try await db.prBindings.upsert(PRBinding(
            worktreeID: lane.id, owner: "acme", repo: "acme-web", number: 88,
            url: "https://github.com/acme/acme-web/pull/88", source: .provider))
        let gh = RecordingGH(prsByBranch: ["tbd/remote-a": 202], numberedOnly: [88: "feature/web"])
        let router = Self.makeRouter(db: db, gh: gh)

        try await router.runPollPass()

        #expect(await gh.recordedRepos.contains("acme/acme-web"))
        let web = try await db.prBindings.list(worktreeID: lane.id).first { $0.repo == "acme-web" }
        #expect(web?.status?.number == 88)
    }

    /// Pinning: a lookup that resolves nothing leaves the binding in place with
    /// no status, which the app renders as the never-observed chip.
    @Test("a provider PR whose lookup resolves nothing stays bound and never-observed")
    func unresolvedProviderPRStaysNeverObserved() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await Self.seedMirror(db, sessionID: "s-a", meta: ["branch": "tbd/remote-a"])
        try await db.prBindings.upsert(PRBinding(
            worktreeID: lane.id, owner: "acme", repo: "acme-web", number: 88,
            url: "https://github.com/acme/acme-web/pull/88", source: .provider))
        let router = Self.makeRouter(db: db, gh: RecordingGH(prsByBranch: ["tbd/remote-a": 202]))

        try await router.runPollPass()

        let web = try await db.prBindings.list(worktreeID: lane.id).first { $0.repo == "acme-web" }
        #expect(web != nil)
        #expect(web?.status == nil)
    }

    /// Without `--hostname`, `gh` asks its default host, where the same
    /// owner/repo/number may be a different pull request — and a stranger's
    /// status, merged included, must never land on a GitHub Enterprise
    /// binding. So the by-number query names the binding's own host, and a
    /// github.com binding keeps the unchanged invocation. The lane has no live
    /// branch, so the binding refresh is the only thing that queries.
    @Test("a GitHub Enterprise binding is queried against its own host, never the default")
    func enterpriseBindingIsQueriedOnItsOwnHost() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await db.prBindings.upsert(PRBinding(
            worktreeID: lane.id, host: "ghe.acme.example", owner: "acme", repo: "acme-web",
            number: 88, url: "https://ghe.acme.example/acme/acme-web/pull/88", source: .provider))
        try await db.prBindings.upsert(PRBinding(
            worktreeID: lane.id, owner: "acme", repo: "acme-prod", number: 202,
            url: "https://github.com/acme/acme-prod/pull/202", source: .provider))
        let gh = RecordingGH(prsByBranch: ["tbd/remote-a": 202], numberedOnly: [88: "feature/web"])
        let router = Self.makeRouter(db: db, gh: gh)

        try await router.runPollPass()

        let queries = await gh.numberQueries
        #expect(queries.contains { $0.repo == "acme/acme-web" && $0.hostname == "ghe.acme.example" })
        #expect(!queries.contains { $0.repo == "acme/acme-web" && $0.hostname == nil })
        #expect(queries.contains { $0.repo == "acme/acme-prod" && $0.hostname == nil })
        let stored = try await db.prBindings.list(worktreeID: lane.id)
        #expect(stored.first { $0.number == 88 }?.status?.number == 88)
    }

    /// An Enterprise host that cannot answer leaves its binding unobserved; the
    /// query is never retried against the default host.
    @Test("a failed Enterprise host query leaves the binding never-observed")
    func failedEnterpriseHostStaysNeverObserved() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "main", provider: "agentbox", sessionID: "s-a")
        try await db.prBindings.upsert(PRBinding(
            worktreeID: lane.id, host: "ghe.acme.example", owner: "acme", repo: "acme-prod",
            number: 202, url: "https://ghe.acme.example/acme/acme-prod/pull/202", source: .provider))
        // github.com WOULD answer #202 for acme/acme-prod; the Enterprise host fails.
        let gh = RecordingGH(prsByBranch: ["tbd/remote-a": 202], failingHosts: ["ghe.acme.example"])
        let router = Self.makeRouter(db: db, gh: gh)

        try await router.runPollPass()

        let queries = await gh.numberQueries
        #expect(queries.allSatisfy { $0.hostname == "ghe.acme.example" })
        let stored = try await db.prBindings.list(worktreeID: lane.id)
        #expect(stored.map(\.number) == [202])
        #expect(stored.first?.status == nil)
    }

    @Test("gh host arguments: github.com unchanged, a plain host named, anything else refused")
    func ghHostArguments() {
        #expect(PRStatusManager.ghHostArguments(forBindingHost: "github.com") == [])
        #expect(PRStatusManager.ghHostArguments(forBindingHost: "GitHub.com") == [])
        #expect(PRStatusManager.ghHostArguments(forBindingHost: "") == [])
        #expect(PRStatusManager.ghHostArguments(forBindingHost: "ghe.acme.example")
                == ["--hostname", "ghe.acme.example"])
        #expect(PRStatusManager.ghHostArguments(forBindingHost: "ghe.acme.example:8443")
                == ["--hostname", "ghe.acme.example:8443"])
        for bad in ["-rf", "--hostname", "ghe_acme.example", "ghe.acme.example:", "a:b:c",
                    "ghe acme", "ghe.acme.example:x", "héllo.example"] {
            #expect(PRStatusManager.ghHostArguments(forBindingHost: bad) == nil, "\(bad)")
        }
    }

    // MARK: - Helpers

    private static func makeRouter(db: TBDDatabase, gh: RecordingGH?) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(),
                                         tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            prManager: gh.map { stub in
                PRStatusManager(ghRunner: { args, path in await stub.run(args: args, repoPath: path) })
            } ?? PRStatusManager(ghRunner: { _, _ in nil }),
            actuationLog: makeTestActuationLog())
    }
}

/// A `gh` stub that answers the three query shapes the poll uses and records the
/// working directory of every invocation, so a test can assert on where `gh` ran
/// as well as what it returned.
private actor RecordingGH {
    private let prsByBranch: [String: Int]
    private var branchByNumber: [Int: String] = [:]
    private(set) var recordedPaths: [String] = []
    /// The `branch=` variable of every by-branch refresh query, in order.
    private(set) var recordedBranches: [String] = []
    /// `owner/name` of every query that bound both variables, in order.
    private(set) var recordedRepos: [String] = []
    /// Every by-number (`pullRequest(number:)`) query: its `owner/name` and
    /// the `--hostname` it carried, nil when it had none.
    private(set) var numberQueries: [(repo: String, hostname: String?)] = []
    private let failingHosts: Set<String>

    /// - Parameter numberedOnly: PRs that resolve by number (to the given head
    ///   branch) but are on no branch the poll asks about — a PR in another
    ///   repository, reached only through its binding.
    /// - Parameter failingHosts: `--hostname` values whose queries fail (no
    ///   auth, unreachable).
    init(prsByBranch: [String: Int], numberedOnly: [Int: String] = [:],
         failingHosts: Set<String> = []) {
        self.prsByBranch = prsByBranch
        self.failingHosts = failingHosts
        for (branch, number) in prsByBranch { branchByNumber[number] = branch }
        for (number, branch) in numberedOnly { branchByNumber[number] = branch }
    }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        recordedPaths.append(repoPath)
        let hostname = args.firstIndex(of: "--hostname").flatMap { index in
            args.index(after: index) < args.endIndex ? args[args.index(after: index)] : nil
        }
        if let owner = args.first(where: { $0.hasPrefix("owner=") })?.dropFirst("owner=".count),
           let name = args.first(where: { $0.hasPrefix("name=") })?.dropFirst("name=".count) {
            recordedRepos.append("\(owner)/\(name)")
        }
        if args.first == "repo" { return GHCommandResult(stdout: #"{"nameWithOwner":"acme/acme-prod","url":"https://github.com/acme/acme-prod"}"#) }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        // The aliased branch query the poll issues, checked before the
        // single-branch refresh query below: both select `pullRequests(headRefName:)`,
        // and only the poll's binds `$b0`.
        if BranchQueryStub.isBranchQuery(query) {
            let nodes = prsByBranch.sorted { $0.value < $1.value }
                .map { Self.node(number: $0.value, head: $0.key) }
            return BranchQueryStub.response(args: args, nodes: nodes)
        }
        if query.contains("pullRequests(headRefName:") {
            guard let branch = args.first(where: { $0.hasPrefix("branch=") })?
                .dropFirst("branch=".count) else { return nil }
            recordedBranches.append(String(branch))
            let node = prsByBranch[String(branch)].map { Self.node(number: $0, head: String(branch)) }
            return GHCommandResult(
                stdout: #"{"data":{"repository":{"pullRequests":{"nodes":[\#(node ?? "")]}}}}"#)
        }
        if query.contains("pullRequest(number:") {
            let owner = args.first(where: { $0.hasPrefix("owner=") })?.dropFirst("owner=".count) ?? ""
            let name = args.first(where: { $0.hasPrefix("name=") })?.dropFirst("name=".count) ?? ""
            numberQueries.append((repo: "\(owner)/\(name)", hostname: hostname))
            if let hostname, failingHosts.contains(hostname) { return nil }
            let fields = Self.aliasedNumbers(inQuery: query).map { alias, number in
                let node = branchByNumber[number].map { Self.node(number: number, head: $0) } ?? "null"
                return "\"\(alias)\": \(node)"
            }
            return GHCommandResult(stdout: #"{"data":{"repository":{\#(fields.joined(separator: ","))}}}"#)
        }
        return nil
    }

    /// A green OPEN PR, so `fetchCheckSignals` is skipped and every `gh`
    /// invocation this test records belongs to the poll itself.
    private static func node(number: Int, head: String) -> String {
        """
        {"number": \(number), "url": "https://github.com/acme/acme-prod/pull/\(number)",
         "state": "OPEN", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
         "headRefName": "\(head)", "baseRefName": "main",
         "createdAt": "2026-08-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "SUCCESS"}}
        """
    }

    /// Parse `pr0: pullRequest(number: 88) { … }` lines back into (alias, number).
    private static func aliasedNumbers(inQuery query: String) -> [(alias: String, number: Int)] {
        query.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  let open = line.range(of: "pullRequest(number: "),
                  let close = line[open.upperBound...].firstIndex(of: ")"),
                  let number = Int(line[open.upperBound..<close]) else { return nil }
            return (String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces), number)
        }
    }
}
