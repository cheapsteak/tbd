import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// A router over an in-memory DB with one repo (`acme/acme-prod`), N active
/// worktrees and seeded `PRBinding` rows, answering `gh` from canned nodes.
///
/// Tier 1: no git subprocess (each worktree's branch facts are primed into the
/// router's own TTL cache), no merge trigger, no clock. Shared by the poll-leg
/// and schedule suites, which assert on what the legs ask `gh` and what they
/// write back.
struct PRPollLegsHarness {
    let db: TBDDatabase
    let router: RPCRouter
    let gh: PRPollLegsGH
    let prManager: PRStatusManager
    let repoID: UUID
    let worktreeIDs: [UUID]

    /// `bindings` seeds one live binding per tuple on worktree index `wt`
    /// (worktrees are created for every index up to the largest named).
    /// `responses` maps a PR number to the verdict the forge reports for it —
    /// see `PRPollLegsGH.nodeJSON(number:verdict:)` for the vocabulary. A number
    /// with no response resolves to `null`, which the refresh treats as "did
    /// not resolve" and keeps the stored status. `provenanceNumbers` maps a
    /// worktree index to the `Worktree.prNumber` it was created from.
    ///
    /// `branchNodes` maps a PR number to the GraphQL `state` (`"OPEN"`,
    /// `"CLOSED"`, `"MERGED"`) the branch query reports for it, on the branch
    /// of the first worktree bound to (or created from) that number; empty
    /// means no branch has a PR. `activeWorktrees` names the worktree indexes
    /// given a selection stamp in the router's activity ledger, so
    /// `pollScheduleFacts()` reports them active.
    static func make(
        bindings: [(wt: Int, number: Int, state: PRMergeableState)],
        responses: [Int: String],
        worktreeCount: Int? = nil,
        provenanceNumbers: [Int: Int] = [:],
        branchNodes: [Int: String] = [:],
        activeWorktrees: Set<Int> = [0]
    ) async throws -> PRPollLegsHarness {
        let db = try TBDDatabase(inMemory: true)
        var branchNodeJSON: [String] = []
        for (number, state) in branchNodes.sorted(by: { $0.key < $1.key }) {
            let bound: Int? = bindings.first(where: { $0.number == number })?.wt
            let createdFrom: Int? = provenanceNumbers.keys.sorted().first(where: { provenanceNumbers[$0] == number })
            let owner = bound ?? createdFrom ?? 0
            branchNodeJSON.append(PRPollLegsGH.nodeJSON(
                number: number, verdict: state == "OPEN" ? "MERGEABLE_CLEAN" : state,
                head: "tbd/legs-\(owner)"))
        }
        let gh = PRPollLegsGH(responses: responses, branchNodes: branchNodeJSON)
        let manager = PRStatusManager(ghRunner: { args, path in
            await gh.run(args: args, repoPath: path)
        })
        let repo = try await db.repos.create(
            path: "/tmp/prlegs-repo-\(UUID().uuidString)",
            displayName: "acme-prod", defaultBranch: "main")
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            prManager: manager,
            prBindingRepoResolver: { _ in ("acme", "acme-prod", "github.com") },
            actuationLog: makeTestActuationLog())

        let highest = (bindings.map { $0.wt } + Array(provenanceNumbers.keys)).max() ?? -1
        let count = worktreeCount ?? (highest + 1)
        var worktreeIDs: [UUID] = []
        for index in 0..<count {
            let suffix = UUID().uuidString
            let path = "/tmp/prlegs-wt-\(suffix)"
            let branch = "tbd/legs-\(index)"
            let worktree = try await db.worktrees.create(
                repoID: repo.id, name: "wt-\(suffix)", branch: branch,
                path: path, tmuxServer: "tbd-prlegs", prNumber: provenanceNumbers[index])
            // The facts the poll would otherwise shell out to git for.
            _ = await router.branchTrackingCache.upstreamBranchName(
                worktreePath: path, branch: branch) { "main" }
            _ = await router.branchTrackingCache.pushBranch(
                worktreePath: path, branch: branch) { .noPushDestination }
            worktreeIDs.append(worktree.id)
        }

        for seed in bindings {
            let url = "https://github.com/acme/acme-prod/pull/\(seed.number)"
            _ = try await db.prBindings.upsert(PRBinding(
                worktreeID: worktreeIDs[seed.wt], owner: "acme", repo: "acme-prod",
                number: seed.number, url: url,
                status: PRStatus(number: seed.number, url: url, state: seed.state),
                source: .manual))
        }

        for index in activeWorktrees where index < worktreeIDs.count {
            await router.activityLedger.recordSelection(worktreeID: worktreeIDs[index], at: Date())
        }

        return PRPollLegsHarness(db: db, router: router, gh: gh, prManager: manager,
                                 repoID: repo.id, worktreeIDs: worktreeIDs)
    }

    /// The poll key every binding of PR `number` in this repo shares.
    func key(_ number: Int) -> PRPollKey {
        PRPollKey(host: "github.com", owner: "acme", repo: "acme-prod", number: number)
    }

    func worktreeID(_ index: Int) -> UUID { worktreeIDs[index] }

    /// Every active worktree row, in the shape a pass hands `runDiscoveryLeg`.
    func activeWorktrees() async throws -> [Worktree] {
        RPCRouter.pollableWorktrees(try await db.worktrees.list(status: .active))
    }

    /// The single `Worktree.prStatus` column for worktree `wt`.
    func columnState(wt: Int) async throws -> PRMergeableState? {
        try await db.worktrees.get(id: worktreeIDs[wt])?.prStatus?.state
    }

    /// The stored state of worktree `wt`'s binding to PR `number`, or nil when
    /// no such binding exists or it has never been observed.
    func bindingState(wt: Int, number: Int) async throws -> PRMergeableState? {
        try await db.prBindings.list(worktreeID: worktreeIDs[wt])
            .first { $0.number == number }?.status?.state
    }
}

/// A stand-in for `gh` that records every GraphQL query it is asked and
/// answers the by-number lookup from canned verdicts.
///
/// The branch query answers with the canned `branchNodes` filtered to each
/// bound branch (none by default), `repo view` with `acme/acme-prod`,
/// and the per-PR check query with a green rollup — though the canned nodes
/// are all green (`SUCCESS`), so the refresh never asks for checks.
actor PRPollLegsGH {
    private let responses: [Int: String]
    private let branchNodes: [String]
    private var queries: [String] = []

    init(responses: [Int: String], branchNodes: [String] = []) {
        self.responses = responses
        self.branchNodes = branchNodes
    }

    /// Every by-number lookup asked, in order. The per-PR check query also
    /// names `pullRequest(number:` and is excluded.
    func numberedQueries() -> [String] {
        queries.filter { $0.contains("pullRequest(number:") && !$0.contains("commits(last: 1)") }
    }

    /// Every branch query asked, in order.
    func branchQueries() -> [String] {
        queries.filter { BranchQueryStub.isBranchQuery($0) }
    }

    /// Every GraphQL query asked, in order.
    func allQueries() -> [String] { queries }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        if args.first == "repo" {
            return GHCommandResult(stdout: #"{"nameWithOwner":"acme/acme-prod","#
                + #""url":"https://github.com/acme/acme-prod"}"#)
        }
        guard let queryArg = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        let query = String(queryArg.dropFirst("query=".count))
        queries.append(query)
        if query.contains("commits(last: 1)") {
            return GHCommandResult(stdout: Self.greenCheckDetailJSON)
        }
        if BranchQueryStub.isBranchQuery(query) {
            return BranchQueryStub.response(args: args, nodes: branchNodes)
        }
        if query.contains("pullRequest(number:") {
            let fields = Self.aliasedNumbers(inQuery: query).map { alias, number in
                "\"" + alias + "\": "
                    + (responses[number].map { Self.nodeJSON(number: number, verdict: $0) } ?? "null")
            }
            return GHCommandResult(
                stdout: "{\"data\":{\"repository\":{" + fields.joined(separator: ",") + "}}}")
        }
        return nil
    }

    /// One PR node in the shape `prNodeFieldSelection` requests, for a verdict:
    /// - `"MERGED"` / `"CLOSED"` — that terminal state.
    /// - `"MERGEABLE_<STATUS>"` — an OPEN PR whose `mergeStateStatus` is
    ///   `<STATUS>` (so `"MERGEABLE_CLEAN"` reads as `.mergeable`).
    /// - anything else — an OPEN PR with that string as its `mergeStateStatus`.
    ///
    /// Always approved and with a `SUCCESS` rollup, so no per-PR check query
    /// runs and the merge verdict alone decides the state.
    ///
    /// `head` is the node's `headRefName`; the branch query only answers a
    /// branch with the nodes whose head is that branch.
    static func nodeJSON(number: Int, verdict: String, head: String? = nil) -> String {
        let state: String
        let mergeStateStatus: String
        switch verdict {
        case "MERGED", "CLOSED":
            state = verdict
            mergeStateStatus = "UNKNOWN"
        default:
            state = "OPEN"
            mergeStateStatus = verdict.hasPrefix("MERGEABLE_")
                ? String(verdict.dropFirst("MERGEABLE_".count)) : verdict
        }
        let headRef = head ?? "tbd/legs-pr-\(number)"
        return """
        {"number": \(number), "url": "https://github.com/acme/acme-prod/pull/\(number)",
         "title": "PR \(number)",
         "state": "\(state)", "mergeStateStatus": "\(mergeStateStatus)", "reviewDecision": "APPROVED",
         "headRefName": "\(headRef)", "baseRefName": "main",
         "createdAt": "2026-08-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "SUCCESS"}}
        """
    }

    /// A per-PR check answer: green rollup, no contexts.
    private static let greenCheckDetailJSON = """
    {"data": {"repository": {"pullRequest": {"commits": {"nodes": [{"commit": {"statusCheckRollup":
     {"state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}]}}}}}
    """

    /// Parse `pr0: pullRequest(number: 88) { … }` lines back into (alias, number).
    private static func aliasedNumbers(inQuery query: String) -> [(alias: String, number: Int)] {
        query.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  let open = line.range(of: "pullRequest(number: "),
                  let close = line[open.upperBound...].firstIndex(of: ")"),
                  let number = Int(line[open.upperBound..<close]) else { return nil }
            return (String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                    number)
        }
    }
}
