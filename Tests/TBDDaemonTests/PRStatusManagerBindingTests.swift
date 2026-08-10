import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Injected `gh`

/// A stand-in for the `gh` CLI answering the three query shapes the binding
/// refresh and the branch-match emitter issue: `repo view` (owner/name), the
/// aliased by-number lookup (one per repo group), the per-PR check-signal
/// query, and the viewer batch.
///
/// It records every aliased query with the repo it was scoped to, so a test can
/// assert not just the resulting statuses but how many round trips — and to
/// which repo — it took to get them.
private actor BindingGH {
    /// PR node JSON keyed by "owner/repo#number" (lowercased owner/repo).
    private let nodes: [String: String]
    /// Check-detail JSON keyed by PR number.
    private let checks: [Int: String]
    private let viewerNodes: [String]
    private let aliasedSucceeds: Bool

    private(set) var aliasedQueries: [(owner: String, name: String, numbers: [Int])] = []
    private(set) var checkQueries: [Int] = []
    private(set) var viewerQueries = 0

    init(nodes: [String: String] = [:],
         checks: [Int: String] = [:],
         viewerNodes: [String] = [],
         aliasedSucceeds: Bool = true) {
        self.nodes = nodes
        self.checks = checks
        self.viewerNodes = viewerNodes
        self.aliasedSucceeds = aliasedSucceeds
    }

    static func key(owner: String, repo: String, number: Int) -> String {
        "\(owner.lowercased())/\(repo.lowercased())#\(number)"
    }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        if args.first == "repo" { return GHCommandResult(stdout: "acme/acme-prod\n") }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }

        // The per-PR check query interpolates owner/name into the query text and
        // is the only shape carrying `commits(last: 1)`. Checked first because it
        // also contains `pullRequest(number:`.
        if query.contains("commits(last: 1)") {
            guard let number = Self.firstNumber(inQuery: query) else { return nil }
            checkQueries.append(number)
            guard let detail = checks[number] else { return nil }
            return GHCommandResult(stdout: detail)
        }

        if query.contains("viewer {") {
            viewerQueries += 1
            return GHCommandResult(
                stdout: #"{"data":{"viewer":{"pullRequests":{"nodes":[\#(viewerNodes.joined(separator: ","))]}}}}"#)
        }

        if query.contains("pullRequest(number:") {
            let owner = Self.value(of: "owner", in: args) ?? ""
            let name = Self.value(of: "name", in: args) ?? ""
            let aliased = Self.aliasedNumbers(inQuery: query)
            aliasedQueries.append((owner, name, aliased.map(\.number)))
            guard aliasedSucceeds else { return nil }
            let fields = aliased.map { alias, number in
                "\"\(alias)\": \(nodes[Self.key(owner: owner, repo: name, number: number)] ?? "null")"
            }
            return GHCommandResult(stdout: #"{"data":{"repository":{\#(fields.joined(separator: ","))}}}"#)
        }
        return nil
    }

    /// Read a `-f key=value` argument back out of the vector.
    private static func value(of key: String, in args: [String]) -> String? {
        guard let arg = args.first(where: { $0.hasPrefix("\(key)=") }) else { return nil }
        return String(arg.dropFirst(key.count + 1))
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

    private static func firstNumber(inQuery query: String) -> Int? {
        guard let open = query.range(of: "pullRequest(number: "),
              let close = query[open.upperBound...].firstIndex(of: ")") else { return nil }
        return Int(query[open.upperBound..<close])
    }
}

@Suite("PRStatusManager binding refresh")
struct PRStatusManagerBindingTests {

    // MARK: - Fixtures

    /// One PR node in the shape `prNodeFieldSelection` requests. Written with a
    /// plain `"""` literal and interpolation — no backslash escapes — so a
    /// mis-escaped fixture cannot silently exercise a parse-failure path.
    private static func nodeJSON(
        number: Int, owner: String = "acme", repo: String = "acme-prod",
        head: String = "tbd/my-branch", state: String = "OPEN",
        mergeStateStatus: String = "CLEAN", rollup: String = "SUCCESS"
    ) -> String {
        """
        {"number": \(number), "url": "https://github.com/\(owner)/\(repo)/pull/\(number)",
         "state": "\(state)", "mergeStateStatus": "\(mergeStateStatus)",
         "reviewDecision": "APPROVED", "headRefName": "\(head)",
         "createdAt": "2026-08-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "\(rollup)"}}
        """
    }

    /// One PR's check detail with a single required check in `conclusion`.
    private static func checkJSON(conclusion: String, rollup: String = "FAILURE") -> String {
        """
        {"data": {"repository": {"pullRequest": {"commits": {"nodes": [
          {"commit": {"statusCheckRollup": {"state": "\(rollup)", "contexts": {
            "pageInfo": {"hasNextPage": false},
            "nodes": [{"__typename": "CheckRun", "name": "build",
                       "status": "COMPLETED", "conclusion": "\(conclusion)",
                       "isRequired": true}]
          }}}}
        ]}}}}
        """
    }

    private static func binding(
        _ number: Int, worktreeID: UUID, owner: String = "acme", repo: String = "acme-prod",
        status: PRStatus? = nil, source: PRBindingSource = .hook
    ) -> PRBinding {
        PRBinding(
            worktreeID: worktreeID, owner: owner, repo: repo, number: number,
            url: "https://github.com/\(owner)/\(repo)/pull/\(number)",
            status: status, source: source)
    }

    private static func manager(_ gh: BindingGH) -> PRStatusManager {
        PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
    }

    // MARK: - refreshBindings

    @Test("refreshBindings resolves several PRs in one repo through one aliased query")
    func refreshesManyBindings() async {
        let gh = BindingGH(
            nodes: [
                BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                    Self.nodeJSON(number: 412),
                BindingGH.key(owner: "acme", repo: "acme-prod", number: 413):
                    Self.nodeJSON(number: 413, mergeStateStatus: "BLOCKED", rollup: "FAILURE")
            ],
            checks: [413: Self.checkJSON(conclusion: "FAILURE")])
        let manager = Self.manager(gh)
        let wt = UUID()
        let bindings = [Self.binding(412, worktreeID: wt), Self.binding(413, worktreeID: wt)]

        let statuses = await manager.refreshBindings(bindings)

        #expect(statuses.count == 2)
        #expect(statuses[bindings[0].id]?.state == .mergeable)
        #expect(statuses[bindings[0].id]?.number == 412)
        #expect(statuses[bindings[0].id]?.url == "https://github.com/acme/acme-prod/pull/412")
        #expect(statuses[bindings[1].id]?.state == .checksFailed)
        // One aliased query for the pair, not one call each.
        #expect(await gh.aliasedQueries.count == 1)
        #expect(await gh.aliasedQueries.first?.numbers.sorted() == [412, 413])
        // The green PR skips the per-check round trip entirely.
        #expect(await gh.checkQueries == [413])
    }

    @Test("bindings in different repos are queried separately, each scoped to its own repo")
    func groupsByRepo() async {
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 1):
                Self.nodeJSON(number: 1),
            BindingGH.key(owner: "acme", repo: "other-repo", number: 2):
                Self.nodeJSON(number: 2, repo: "other-repo", mergeStateStatus: "DIRTY")
        ])
        let manager = Self.manager(gh)
        let wt = UUID()
        let bindings = [
            Self.binding(1, worktreeID: wt),
            Self.binding(2, worktreeID: wt, repo: "other-repo")
        ]

        let statuses = await manager.refreshBindings(bindings)

        #expect(statuses[bindings[0].id]?.state == .mergeable)
        #expect(statuses[bindings[1].id]?.state == .blocked)
        let queries = await gh.aliasedQueries
        #expect(queries.count == 2)
        #expect(queries.map(\.name).sorted() == ["acme-prod", "other-repo"])
        // A number is never offered to the wrong repo.
        #expect(queries.first(where: { $0.name == "acme-prod" })?.numbers == [1])
        #expect(queries.first(where: { $0.name == "other-repo" })?.numbers == [2])
    }

    @Test("a transient gh failure keeps the previous status rather than guessing")
    func transientFailureKeepsPrevious() async {
        let previous = PRStatus(number: 412, url: "https://github.com/acme/acme-prod/pull/412",
                                state: .pending, reason: "Checks pending")
        let gh = BindingGH(aliasedSucceeds: false)
        let manager = Self.manager(gh)
        let binding = Self.binding(412, worktreeID: UUID(), status: previous)

        let statuses = await manager.refreshBindings([binding])

        #expect(statuses[binding.id] == previous)
    }

    @Test("a transient check-signal failure keeps the previous status")
    func checkSignalFailureKeepsPrevious() async {
        let previous = PRStatus(number: 412, url: "https://github.com/acme/acme-prod/pull/412",
                                state: .pending, reason: "Checks pending")
        // The node resolves but the check query has no answer for it.
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                Self.nodeJSON(number: 412, mergeStateStatus: "BLOCKED", rollup: "FAILURE")
        ])
        let manager = Self.manager(gh)
        let binding = Self.binding(412, worktreeID: UUID(), status: previous)

        let statuses = await manager.refreshBindings([binding])

        #expect(statuses[binding.id] == previous)
        #expect(await gh.checkQueries == [412])
    }

    @Test("an unresolvable PR number keeps the previous status and reports nothing when there is none")
    func unresolvableNumber() async {
        // `null` for the alias — a deleted or inaccessible PR.
        let gh = BindingGH()
        let manager = Self.manager(gh)
        let wt = UUID()
        let previous = PRStatus(number: 5, url: "https://github.com/acme/acme-prod/pull/5",
                                state: .mergeable)
        let kept = Self.binding(5, worktreeID: wt, status: previous)
        let fresh = Self.binding(6, worktreeID: wt)

        let statuses = await manager.refreshBindings([kept, fresh])

        #expect(statuses[kept.id] == previous)
        #expect(statuses[fresh.id] == nil)
    }

    @Test("a merged PR is reported as merged")
    func reportsMerged() async {
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                Self.nodeJSON(number: 412, state: "MERGED")
        ])
        let manager = Self.manager(gh)
        let binding = Self.binding(412, worktreeID: UUID())

        let statuses = await manager.refreshBindings([binding])

        #expect(statuses[binding.id]?.state == .merged)
        // A non-OPEN PR never pays for a check query.
        #expect(await gh.checkQueries.isEmpty)
    }

    @Test("refreshBindings leaves the worktree-keyed cache untouched")
    func doesNotDisturbWorktreeCache() async {
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                Self.nodeJSON(number: 412, state: "MERGED")
        ])
        let manager = Self.manager(gh)
        let wt = UUID()
        let seeded = PRStatus(number: 412, url: "https://github.com/acme/acme-prod/pull/412",
                              state: .pending)
        await manager.seedForTesting(worktreeID: wt, status: seeded)

        _ = await manager.refreshBindings([Self.binding(412, worktreeID: wt)])

        // The binding path is a sibling of the worktree-keyed path, not a
        // replacement: it must not write the cache, and — crucially — must not
        // fire the merged transition that drives auto-archive.
        #expect(await manager.allStatuses()[wt] == seeded)
    }

    @Test("no bindings means no gh calls at all")
    func emptyBindingsIsFree() async {
        let gh = BindingGH()
        let manager = Self.manager(gh)

        #expect(await manager.refreshBindings([]).isEmpty)
        #expect(await gh.aliasedQueries.isEmpty)
    }

    // MARK: - Grouping (pure)

    @Test("grouping is case-insensitive on owner and repo and keeps first-seen order")
    func groupingIsCaseInsensitive() {
        let wt = UUID()
        let groups = PRStatusManager.groupBindingsByRepo([
            Self.binding(1, worktreeID: wt, owner: "acme", repo: "acme-prod"),
            Self.binding(2, worktreeID: wt, owner: "acme", repo: "other-repo"),
            Self.binding(3, worktreeID: wt, owner: "ACME", repo: "ACME-PROD")
        ])
        #expect(groups.count == 2)
        #expect(groups[0].name == "acme-prod")
        #expect(groups[0].bindings.map(\.number) == [1, 3])
        #expect(groups[1].name == "other-repo")
    }

    // MARK: - Branch-match emitter

    @Test("fetchAll emits a branch-matched PR as a ParsedPRURL for the coordinator")
    func emitsBranchMatches() async {
        let wt = UUID()
        let gh = BindingGH(viewerNodes: [Self.nodeJSON(number: 89, head: "tbd/my-branch")])
        let manager = Self.manager(gh)

        let emitted = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(emitted.count == 1)
        #expect(emitted.first?.worktreeID == wt)
        #expect(emitted.first?.parsed.number == 89)
        #expect(emitted.first?.parsed.owner == "acme")
        #expect(emitted.first?.parsed.repo == "acme-prod")
        #expect(emitted.first?.parsed.host == "github.com")
        // The worktree-keyed path still applies the match exactly as before.
        #expect(await manager.allStatuses()[wt]?.number == 89)
    }

    @Test("a head-ref-mismatched match is healed away and never emitted")
    func healedMatchIsNotEmitted() async {
        // The PR's head is the branch this worktree merely tracks, and that
        // branch is the repo default — the heal clears it, so binding it would
        // durably attach the base branch's PR.
        let wt = UUID()
        let gh = BindingGH(viewerNodes: [Self.nodeJSON(number: 90, head: "main")])
        let manager = Self.manager(gh)

        let emitted = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(emitted.isEmpty)
        #expect(await manager.allStatuses()[wt] == nil)
    }

    @Test("a numbered match is not emitted as a branch source")
    func numberedMatchIsNotEmitted() async {
        // Only the branch matcher may claim `.branch`; a worktree created from a
        // PR row was already bound by its own path.
        let wt = UUID()
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 77):
                Self.nodeJSON(number: 77, head: "tbd/my-branch")
        ])
        let manager = Self.manager(gh)
        var poll = Self.pollWorktree(wt)
        poll.prNumber = 77

        let emitted = await manager.fetchAll(worktrees: [poll])

        #expect(emitted.isEmpty)
        #expect(await manager.allStatuses()[wt]?.number == 77)
    }

    private static func pollWorktree(
        _ id: UUID, branch: String = "tbd/my-branch", upstream: String? = "main",
        defaultBranch: String? = "main"
    ) -> PRStatusManager.PollWorktree {
        (id: id, branch: branch, upstreamBranch: upstream, defaultBranch: defaultBranch,
         pushBranch: .noPushDestination, worktreePath: "/wt/acme-prod", prNumber: nil)
    }
}

@Suite("Worktree PR status from bindings")
struct WorktreePRStatusFromBindingsTests {

    private func binding(_ number: Int, worktreeID: UUID, state: PRMergeableState?) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod", number: number, url: url,
            status: state.map { PRStatus(number: number, url: url, state: $0) }, source: .hook)
    }

    @Test("the worst binding becomes the worktree's single status")
    func worstWins() {
        let wt = UUID()
        let updates = RPCRouter.worktreePRStatusUpdates([
            binding(1, worktreeID: wt, state: .mergeable),
            binding(2, worktreeID: wt, state: .checksFailed),
            binding(3, worktreeID: wt, state: .draft)
        ])
        #expect(updates.count == 1)
        #expect(updates.first?.worktreeID == wt)
        #expect(updates.first?.status.number == 2)
    }

    @Test("a merged worst status is never written to the worktree column")
    func mergedIsNotPersisted() {
        // `.merged` is the auto-archive trigger; persisting it would let a
        // restart hydrate an already-merged baseline and lose the re-fire.
        let wt = UUID()
        #expect(RPCRouter.worktreePRStatusUpdates([
            binding(1, worktreeID: wt, state: .merged),
            binding(2, worktreeID: wt, state: .closed)
        ]).isEmpty)
    }

    @Test("a worktree whose bindings were never observed gets no write")
    func unobservedBindingsWriteNothing() {
        let wt = UUID()
        #expect(RPCRouter.worktreePRStatusUpdates([binding(1, worktreeID: wt, state: nil)]).isEmpty)
    }

    @Test("each worktree gets its own status")
    func perWorktree() {
        let a = UUID(), b = UUID()
        let updates = RPCRouter.worktreePRStatusUpdates([
            binding(1, worktreeID: a, state: .mergeable),
            binding(2, worktreeID: b, state: .blocked)
        ])
        #expect(updates.count == 2)
        #expect(updates.first { $0.worktreeID == a }?.status.state == .mergeable)
        #expect(updates.first { $0.worktreeID == b }?.status.state == .blocked)
    }

    @Test("withStatus replaces only the status")
    func withStatusPreservesIdentity() {
        let wt = UUID()
        let original = binding(7, worktreeID: wt, state: nil)
        let fresh = PRStatus(number: 7, url: original.url, state: .pending)
        let updated = original.withStatus(fresh)
        #expect(updated.id == original.id)
        #expect(updated.identityKey == original.identityKey)
        #expect(updated.source == original.source)
        #expect(updated.boundAt == original.boundAt)
        #expect(updated.status == fresh)
    }
}
