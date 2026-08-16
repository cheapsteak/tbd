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
        let laneA = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-a", branch: "tbd/remote-a",
            provider: "agentbox", sessionID: "s-a")
        let laneB = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-b", branch: "tbd/remote-b",
            provider: "agentbox", sessionID: "s-b")
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s",
            path: tempDir.appendingPathComponent("scratch").path, tmuxServer: "tbd-scratch")

        let router = Self.makeRouter(db: db, gh: nil)
        let rows = RPCRouter.pollableWorktrees(try await db.worktrees.list(status: .active))
        let entries = await router.pollEntries(rows, repos: try await db.repos.list())

        #expect(!rows.contains { $0.id == scratch.id })
        #expect(entries.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        // The local row is untouched by the change: its own checkout, its own branch.
        #expect(byID[local.id]?.branch == "tbd/local-lane")
        #expect(byID[local.id]?.worktreePath == localDir.path)
        #expect(byID[local.id]?.defaultBranch == "main")

        // Each lane carries the REPO's checkout and its OWN branch.
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

        let entries = await router.pollEntries([lane], repos: [])

        #expect(entries.isEmpty)
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
            repoID: repo.id, name: "lane-a", branch: "tbd/remote-a",
            provider: "agentbox", sessionID: "s-a")
        let laneB = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane-b", branch: "tbd/remote-b",
            provider: "agentbox", sessionID: "s-b")

        let gh = RecordingGH(prsByBranch: [
            "tbd/local-lane": 101,
            "tbd/remote-a": 202,
            "tbd/remote-b": 303,
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
            repoID: repo.id, name: "lane-a", branch: "tbd/remote-a",
            provider: "agentbox", sessionID: "s-a")

        let gh = RecordingGH(prsByBranch: ["tbd/remote-a": 202])
        let router = Self.makeRouter(db: db, gh: gh)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: lane.id)))
        #expect(response.success)
        let result = try response.decodeResult(PRRefreshResult.self)

        #expect(result.status?.number == 202)
        #expect(await gh.recordedBranches == ["tbd/remote-a"])
        #expect(Set(await gh.recordedPaths) == [repoDir.path])
    }

    /// The other arm of the same guard, still intact: an id that names no row
    /// gets "nothing to report" and runs no `gh` at all. (A remote row whose
    /// repo is gone reaches the same nil, but only through
    /// `pollWorkingDirectory` — the `worktree.repoID` foreign key cascades, so a
    /// deleted repo takes its lanes with it and the state is unreachable here.)
    @Test("pr.refresh reports nothing for an unknown worktree and runs no gh")
    func refreshForUnknownWorktreeReportsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let gh = RecordingGH(prsByBranch: ["tbd/lane": 404])
        let router = Self.makeRouter(db: db, gh: gh)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: UUID())))
        #expect(response.success)
        #expect(try response.decodeResult(PRRefreshResult.self).status == nil)
        #expect(await gh.recordedPaths.isEmpty)
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

    init(prsByBranch: [String: Int]) {
        self.prsByBranch = prsByBranch
        for (branch, number) in prsByBranch { branchByNumber[number] = branch }
    }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        recordedPaths.append(repoPath)
        if args.first == "repo" { return GHCommandResult(stdout: "acme/acme-prod\n") }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        if query.contains("pullRequests(headRefName:") {
            guard let branch = args.first(where: { $0.hasPrefix("branch=") })?
                .dropFirst("branch=".count) else { return nil }
            recordedBranches.append(String(branch))
            let node = prsByBranch[String(branch)].map { Self.node(number: $0, head: String(branch)) }
            return GHCommandResult(
                stdout: #"{"data":{"repository":{"pullRequests":{"nodes":[\#(node ?? "")]}}}}"#)
        }
        if query.contains("viewer {") {
            let nodes = prsByBranch.sorted { $0.value < $1.value }
                .map { Self.node(number: $0.value, head: $0.key) }
            return GHCommandResult(
                stdout: #"{"data":{"viewer":{"pullRequests":{"nodes":[\#(nodes.joined(separator: ","))]}}}}"#)
        }
        if query.contains("pullRequest(number:") {
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
