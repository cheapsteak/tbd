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
        if args.first == "repo" { return GHCommandResult(stdout: #"{"nameWithOwner":"acme/acme-prod","url":"https://github.com/acme/acme-prod"}"#) }
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

// MARK: - Injected `glab`

/// A stand-in for the `glab` CLI answering the three shapes the GitLab path
/// issues: the batched `mergeRequests(iids:)` read, the author-blind
/// `sourceBranches` read, and the REST mergeability recheck.
///
/// It records which shapes it saw and whether `--hostname` was on every one of
/// them — the flag whose absence would not fail but would silently answer about
/// gitlab.com instead of the configured instance.
private actor GitLabFake {
    private let host: String
    private let projectPath: String
    private let iid: Int
    private let sourceBranch: String
    private let detailedMergeStatus: String
    /// When set, every call answers with this instead — the expired-token shape.
    private let refusal: GHCommandResult?

    private(set) var callCount = 0
    private(set) var sawGraphQL = false
    private(set) var sawSourceBranches = false
    private(set) var sawRecheck = false
    private(set) var recheckArgs: [String] = []
    private(set) var hostnameFlagAlwaysPresent = true
    private(set) var hostnamesSeen: [String] = []

    /// The state of the merge request this project answers with, and — when
    /// set — a second, already-merged one beside it.
    private let state: String
    private let mergedIID: Int?

    init(host: String = "git.acme.example",
         projectPath: String = "acme/platform/api-gateway",
         iid: Int = 412,
         sourceBranch: String = "tbd/my-branch",
         detailedMergeStatus: String = "NOT_APPROVED",
         state: String = "opened",
         mergedIID: Int? = nil,
         refusal: GHCommandResult? = nil) {
        self.host = host
        self.projectPath = projectPath
        self.iid = iid
        self.sourceBranch = sourceBranch
        self.detailedMergeStatus = detailedMergeStatus
        self.state = state
        self.mergedIID = mergedIID
        self.refusal = refusal
    }

    /// Wait for the mergeability recheck to arrive, up to `timeout`. It is
    /// issued from a detached task, so a test that asserts on it must wait for
    /// it rather than assume the refresh already ran it.
    func waitForRecheck(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !sawRecheck && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sawRecheck
    }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        callCount += 1
        if let index = args.firstIndex(of: "--hostname"), index + 1 < args.count {
            hostnamesSeen.append(args[index + 1])
        } else {
            hostnameFlagAlwaysPresent = false
        }
        if let refusal { return refusal }

        if let query = args.first(where: { $0.hasPrefix("query=") }) {
            sawGraphQL = true
            if query.contains("sourceBranches:") {
                sawSourceBranches = true
                guard query.contains("\"\(sourceBranch)\"") else { return Self.emptyProject }
            }
            return GHCommandResult(stdout: nodeResponse)
        }
        if args.contains(where: { $0.contains("with_merge_status_recheck=true") }) {
            sawRecheck = true
            recheckArgs = args
            return GHCommandResult(stdout: "[]")
        }
        return nil
    }

    private static let emptyProject = GHCommandResult(
        stdout: #"{"data":{"project":{"onlyAllowMergeIfPipelineSucceeds":true,"mergeRequests":{"nodes":[]}}}}"#)

    /// Written with a plain `"""` literal and interpolation — no backslash
    /// escapes — so a mis-escaped fixture cannot silently exercise the
    /// parse-failure path instead of the one under test.
    private var nodeResponse: String {
        let nodes = [node(iid: iid, state: state)]
            + (mergedIID.map { [node(iid: $0, state: "merged")] } ?? [])
        return """
        {"data":{"project":{"onlyAllowMergeIfPipelineSucceeds":true,
        "mergeRequests":{"nodes":[\(nodes.joined(separator: ","))]}}}}
        """
    }

    private func node(iid: Int, state: String) -> String {
        """
        {"iid":"\(iid)","state":"\(state)","draft":false,
        "detailedMergeStatus":"\(detailedMergeStatus)",
        "sourceBranch":"\(sourceBranch)","targetBranch":"main",
        "createdAt":"2026-08-01T10:00:00Z",
        "webUrl":"https://\(host)/\(projectPath)/-/merge_requests/\(iid)",
        "headPipeline":{"status":"SUCCESS"}}
        """
    }
}

/// A `gh` that can answer nothing, only count what it was asked.
private actor GHCallLog {
    private(set) var viewerQueries = 0

    func record(_ args: [String]) -> GHCommandResult? {
        if args.contains(where: { $0.hasPrefix("query=") && $0.contains("viewer {") }) {
            viewerQueries += 1
        }
        return nil
    }
}

/// A mergeability recheck that never returns until the test lets it, so a test
/// can assert what the poll does *while* one is outstanding.
private actor HangingRecheck {
    private var entered = false
    private var released = false

    func hang() async {
        entered = true
        while !released { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() { released = true }

    /// Whether the recheck was reached within `timeout`. Polled, because it is
    /// issued from a detached task whose scheduling no test owns.
    func wasEntered(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !entered && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }
}

/// A value some other task produces, awaited with a deadline — so a test that
/// asserts "this call does not wait for that one" fails on a timer instead of
/// hanging the whole suite when it does.
private actor OneShot<Value: Sendable> {
    private var stored: Value?

    func fulfil(_ value: Value) { stored = value }

    func value(within timeout: Duration = .seconds(10)) async -> Value? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while stored == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stored
    }
}

/// A token that expires and is later re-issued, so one test can watch a host
/// go dark and come back.
private actor AuthGate {
    private(set) var refuses = true
    func reissueToken() { refuses = false }
}

@Suite("PRStatusManager binding refresh")
struct PRStatusManagerBindingTests {

    // MARK: - Fixtures

    /// One PR node in the shape `prNodeFieldSelection` requests. Written with a
    /// plain `"""` literal and interpolation — no backslash escapes — so a
    /// mis-escaped fixture cannot silently exercise a parse-failure path.
    private static func nodeJSON(
        number: Int, owner: String = "acme", repo: String = "acme-prod",
        head: String = "tbd/my-branch", base: String = "main", state: String = "OPEN",
        mergeStateStatus: String = "CLEAN", rollup: String = "SUCCESS"
    ) -> String {
        """
        {"number": \(number), "url": "https://github.com/\(owner)/\(repo)/pull/\(number)",
         "state": "\(state)", "mergeStateStatus": "\(mergeStateStatus)",
         "reviewDecision": "APPROVED", "headRefName": "\(head)", "baseRefName": "\(base)",
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

        let observed = await manager.refreshBindings(bindings)

        #expect(observed.count == 2)
        #expect(observed[bindings[0].id]?.status.state == .mergeable)
        #expect(observed[bindings[0].id]?.status.number == 412)
        #expect(observed[bindings[0].id]?.status.url == "https://github.com/acme/acme-prod/pull/412")
        #expect(observed[bindings[1].id]?.status.state == .checksFailed)
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

        let observed = await manager.refreshBindings(bindings)

        #expect(observed[bindings[0].id]?.status.state == .mergeable)
        #expect(observed[bindings[1].id]?.status.state == .blocked)
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

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status == previous)
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

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status == previous)
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

        let observed = await manager.refreshBindings([kept, fresh])

        #expect(observed[kept.id]?.status == previous)
        #expect(observed[fresh.id] == nil)
    }

    @Test("a merged PR is reported as merged")
    func reportsMerged() async {
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                Self.nodeJSON(number: 412, state: "MERGED")
        ])
        let manager = Self.manager(gh)
        let binding = Self.binding(412, worktreeID: UUID())

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status.state == .merged)
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

    @Test("a resolved binding reports the head and base branch the same response carried")
    func reportsBranchRefs() async {
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                Self.nodeJSON(number: 412, head: "tbd/fix-login-timeout", base: "release/2026-08")
        ])
        let manager = Self.manager(gh)
        let binding = Self.binding(412, worktreeID: UUID())

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.headBranch == "tbd/fix-login-timeout")
        #expect(observed[binding.id]?.baseRef == "release/2026-08")
    }

    @Test("an unresolved binding reports no refs, so the caller keeps what it has")
    func unresolvedReportsNoRefs() async {
        let previous = PRStatus(number: 412, url: "https://github.com/acme/acme-prod/pull/412",
                                state: .pending)
        let gh = BindingGH()   // the alias comes back null
        let manager = Self.manager(gh)
        let binding = Self.binding(412, worktreeID: UUID(), status: previous)

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status == previous)
        #expect(observed[binding.id]?.headBranch == nil)
        #expect(observed[binding.id]?.baseRef == nil)
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

        let emitted = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)]).discovered

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

        let outcome = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(outcome.discovered.isEmpty)
        #expect(await manager.allStatuses()[wt] == nil)
    }

    // MARK: - Heal emitter

    @Test("the head-ref heal names the PR it disproved so the binding can go too")
    func headRefHealEmitsDisproved() async {
        // The shape the heal actually reaches: a PR a previous pass attached and
        // cached, re-resolved by number this pass (the batch matches nothing),
        // whose head turns out to be the branch this worktree merely tracks —
        // and that branch is the repo default. Clearing the cache is not enough:
        // a `.branch` binding written by that previous pass is re-queried by
        // number and no heal can see it.
        let wt = UUID()
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 90):
                Self.nodeJSON(number: 90, head: "main", state: "MERGED")
        ])
        let manager = Self.manager(gh)
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 90, url: "https://github.com/acme/acme-prod/pull/90",
                             state: .pending))

        let outcome = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(outcome.discovered.isEmpty)
        #expect(outcome.disproved.map(\.parsed.number) == [90])
        #expect(outcome.disproved.first?.worktreeID == wt)
        #expect(outcome.disproved.first?.parsed.repo == "acme-prod")
        // The existing invariant is untouched: the cache is cleared, and the
        // mis-attached MERGED PR fires no transition.
        #expect(await manager.allStatuses()[wt] == nil)
    }

    @Test("the cross-repo heal names the PR it disproved")
    func crossRepoHealEmitsDisproved() async {
        // A remote pointed at a different repo after the binding was written:
        // the coordinator's bind-time repo check can no longer help, and a
        // binding is re-queried by (owner, repo, number) without ever being
        // re-validated.
        let wt = UUID()
        let gh = BindingGH()   // `repo view` answers acme/acme-prod
        let manager = Self.manager(gh)
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 7, url: "https://github.com/acme/other-repo/pull/7",
                             state: .mergeable))

        let outcome = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(outcome.disproved.map(\.parsed.number) == [7])
        #expect(outcome.disproved.first?.parsed.repo == "other-repo")
        #expect(await manager.allStatuses()[wt] == nil)
    }

    @Test("a poll that heals nothing disproves nothing")
    func healthyPollDisprovesNothing() async {
        let wt = UUID()
        let gh = BindingGH(viewerNodes: [Self.nodeJSON(number: 89, head: "tbd/my-branch")])
        let manager = Self.manager(gh)

        let outcome = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(outcome.disproved.isEmpty)
        #expect(outcome.discovered.map(\.parsed.number) == [89])
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

        let emitted = await manager.fetchAll(worktrees: [poll]).discovered

        #expect(emitted.isEmpty)
        #expect(await manager.allStatuses()[wt]?.number == 77)
    }

    // MARK: - GitLab routing

    private static let gitLabHost = "git.acme.example"
    private static let gitLabNamespace = "acme/platform"
    private static let gitLabProject = "api-gateway"
    private static let gitLabMRURL =
        "https://git.acme.example/acme/platform/api-gateway/-/merge_requests/412"

    private static func gitLabBinding(
        worktreeID: UUID = UUID(), number: Int = 412, status: PRStatus? = nil
    ) -> PRBinding {
        PRBinding(
            worktreeID: worktreeID, host: gitLabHost, owner: gitLabNamespace,
            repo: gitLabProject, number: number, url: gitLabMRURL,
            status: status, source: .manual)
    }

    @Test("a GitLab binding group queries glab and maps through the GitLab arm")
    func gitLabGroupRefresh() async {
        let gl = GitLabFake()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding()

        let observed = await manager.refreshBindings([binding])

        // NOT_APPROVED with a green gating pipeline is GitLab's "only an
        // approval is missing" — the GitHub arm would read the same string as
        // an unknown merge state and never produce this.
        #expect(observed[binding.id]?.status.state == .mergeable)
        #expect(observed[binding.id]?.status.number == 412)
        #expect(observed[binding.id]?.status.url == Self.gitLabMRURL)
        #expect(observed[binding.id]?.headBranch == "tbd/my-branch")
        #expect(observed[binding.id]?.baseRef == "main")
        #expect(await gl.sawGraphQL)
        #expect(await gl.waitForRecheck())
        // Outside a GitLab checkout `glab api` defaults to gitlab.com, so a
        // missing --hostname would answer confidently about the wrong instance.
        #expect(await gl.hostnameFlagAlwaysPresent)
        #expect(Set(await gl.hostnamesSeen) == [Self.gitLabHost])
    }

    @Test("the mergeability recheck carries its parameters in the path, not as fields")
    func recheckStaysAGet() async {
        let gl = GitLabFake()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost])

        _ = await manager.refreshBindings([Self.gitLabBinding()])

        #expect(await gl.waitForRecheck())
        let args = await gl.recheckArgs
        // A `-f` would flip `glab api` from GET to POST, which this endpoint
        // does not answer.
        #expect(!args.contains("-f"))
        #expect(args.contains { $0.contains("iids%5B%5D=412") })
        #expect(args.contains { $0.hasPrefix("projects/") })
    }

    @Test("a failing recheck cannot disturb the statuses the poll already read")
    func recheckFailureIsDiscarded() async {
        // The recheck queues work on someone else's server and returns nothing
        // TBD reads, so its failure is not this poll's business.
        let gl = GitLabFake()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in
                if args.contains(where: { $0.contains("with_merge_status_recheck=true") }) {
                    return GHCommandResult(stdout: "", stderr: "500 Internal Server Error",
                                           exitStatus: 1)
                }
                return await gl.run(args: args, repoPath: path)
            },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding()

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status.state == .mergeable)
    }

    @Test("a hanging mergeability recheck cannot stall the poll that issued it")
    func recheckDoesNotBlockThePoll() async {
        // `runCLI` imposes no timeout, `refreshBindings` walks its groups one at
        // a time and `fetchAll` skips its next poll while one is running — so a
        // recheck that hangs would stop PR polling for the whole fleet with no
        // deadline to end it. Nothing in the pass reads its answer, so nothing
        // in the pass may wait for it.
        let gl = GitLabFake()
        let recheck = HangingRecheck()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in
                if args.contains(where: { $0.contains("with_merge_status_recheck=true") }) {
                    await recheck.hang()
                    return GHCommandResult(stdout: "[]")
                }
                return await gl.run(args: args, repoPath: path)
            },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding()
        let refreshed = OneShot<[UUID: PRStatusManager.PRBindingObservation]>()

        Task { await refreshed.fulfil(await manager.refreshBindings([binding])) }
        let observed = await refreshed.value()

        #expect(observed?[binding.id]?.status.state == .mergeable,
                "refreshBindings did not return while the recheck was still outstanding")
        // …and the recheck really was outstanding, so the pass above is not
        // green merely because nothing was ever asked.
        #expect(await recheck.wasEntered())
        await recheck.release()
    }

    @Test("the recheck asks only about merge requests that can still change")
    func recheckSkipsTerminalMergeRequests() async {
        // A merged merge request has a mergeability nobody will recompute and
        // nobody will read, so asking for it spends a job on someone else's
        // server to learn nothing.
        let gl = GitLabFake(mergedIID: 500)
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost])
        let wt = UUID()

        _ = await manager.refreshBindings([
            Self.gitLabBinding(worktreeID: wt, number: 412),
            Self.gitLabBinding(worktreeID: wt, number: 500)
        ])

        #expect(await gl.waitForRecheck())
        let args = await gl.recheckArgs
        #expect(args.contains { $0.contains("iids%5B%5D=412") })
        #expect(!args.contains { $0.contains("iids%5B%5D=500") })
    }

    @Test("a group with nothing left to settle issues no recheck at all")
    func terminalOnlyGroupSkipsTheRecheck() async {
        let gl = GitLabFake(state: "merged")
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding()

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status.state == .merged)
        // No task is created, so there is nothing to race: the recheck the old
        // code awaited inline would already have been seen by now.
        #expect(await gl.sawRecheck == false)
    }

    @Test("a GitHub binding group never invokes glab")
    func gitHubGroupSkipsGlab() async {
        let gl = GitLabFake()
        let gh = BindingGH(nodes: [
            BindingGH.key(owner: "acme", repo: "acme-prod", number: 412):
                Self.nodeJSON(number: 412)
        ])
        let manager = PRStatusManager(
            ghRunner: { args, path in await gh.run(args: args, repoPath: path) },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.binding(412, worktreeID: UUID())

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status.state == .mergeable)
        #expect(await gl.callCount == 0)
        #expect(await gh.aliasedQueries.count == 1)
    }

    @Test("branch matching finds a GitLab merge request opened by someone else")
    func gitLabBranchMatch() async {
        // `sourceBranches` has no author filter, so this is the route that finds
        // a merge request opened through the web UI or by another account —
        // GitHub's viewer batch structurally cannot.
        let gl = GitLabFake()
        let wt = UUID()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost],
            remoteURLReader: { _ in
                "https://git.acme.example/acme/platform/api-gateway.git"
            })

        let outcome = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(await gl.sawSourceBranches)
        #expect(await manager.allStatuses()[wt]?.number == 412)
        #expect(await manager.allStatuses()[wt]?.state == .mergeable)
        #expect(outcome.discovered.count == 1)
        #expect(outcome.discovered.first?.worktreeID == wt)
        #expect(outcome.discovered.first?.parsed.number == 412)
        #expect(outcome.discovered.first?.parsed.host == Self.gitLabHost)
        #expect(outcome.discovered.first?.parsed.owner == Self.gitLabNamespace)
        #expect(outcome.discovered.first?.parsed.repo == Self.gitLabProject)
        #expect(await manager.observation(for: wt)?.outcome == .observed)
    }

    @Test("a GitLab-only fleet never asks gh for the viewer batch")
    func gitLabOnlyFleetSkipsViewerBatch() async {
        // `gh` cannot name this checkout — it is not a host it speaks to — so
        // identity comes from the remote, and nothing on this fleet is GitHub.
        // The viewer batch is then not merely fruitless but never issued.
        let gl = GitLabFake()
        let gh = GHCallLog()
        let manager = PRStatusManager(
            ghRunner: { args, _ in await gh.record(args) },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost],
            remoteURLReader: { _ in
                "https://git.acme.example/acme/platform/api-gateway.git"
            })

        let wt = UUID()
        _ = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(await gh.viewerQueries == 0)
        // And the GitLab side still answered, so this is not a vacuous pass.
        #expect(await manager.allStatuses()[wt]?.number == 412)
    }

    @Test("an unmatched GitLab branch query reports none, not a failure")
    func gitLabBranchQueryAnsweredNothing() async {
        // The project answered; it simply has no merge request on this branch.
        let gl = GitLabFake(sourceBranch: "someone-elses-branch")
        let wt = UUID()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in await gl.run(args: args, repoPath: path) },
            gitLabHosts: [Self.gitLabHost],
            remoteURLReader: { _ in
                "https://git.acme.example/acme/platform/api-gateway.git"
            })

        _ = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        #expect(await manager.observation(for: wt)?.outcome == PRObservation.Outcome.none)
    }

    @Test("a GitLab project the query could not read records undetermined, not none")
    func gitLabProjectErrorIsUndetermined() async {
        // A renamed project, or a token that lost read_api on this one, comes
        // back as a GraphQL errors array with `data: null`. The forge did not
        // answer the question, so recording "this worktree has no merge
        // request" would flip every worktree on the project dark and silent.
        let wt = UUID()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, _ in
                guard args.contains(where: { $0.hasPrefix("query=") }) else { return nil }
                return GHCommandResult(stdout: """
                {"errors":[{"message":"unknown project","extensions":{"code":"undefinedField"}}],
                "data":null}
                """)
            },
            gitLabHosts: [Self.gitLabHost],
            remoteURLReader: { _ in
                "https://git.acme.example/acme/platform/api-gateway.git"
            })

        _ = await manager.fetchAll(worktrees: [Self.pollWorktree(wt)])

        let outcome = await manager.observation(for: wt)?.outcome
        #expect(outcome == .undetermined(cause: PRUndeterminedCause.unparseableResponse))
    }

    // MARK: - Authentication failure

    @Test("an auth failure names the host instead of degrading to no-forge")
    func authFailureNamesHost() async {
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { _, _ in
                GHCommandResult(stdout: "", stderr: "401 Unauthorized", exitStatus: 1)
            },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding()

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id] == nil)
        #expect(await manager.lastUndeterminedCause(forHost: Self.gitLabHost)
                == PRUndeterminedCause.forgeAuthFailed(host: Self.gitLabHost))
        // The remedy is host-shaped, so the report must name the host.
        #expect(await manager.lastUndeterminedCause(forHost: Self.gitLabHost)?
                .contains(Self.gitLabHost) == true)
    }

    @Test("a GraphQL authentication error is an auth failure too, not an empty project")
    func graphQLAuthErrorNamesHost() async {
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { _, _ in
                GHCommandResult(stdout: """
                {"errors":[{"message":"invalid token",
                "extensions":{"code":"UNAUTHENTICATED"}}]}
                """)
            },
            gitLabHosts: [Self.gitLabHost])

        _ = await manager.refreshBindings([Self.gitLabBinding()])

        #expect(await manager.lastUndeterminedCause(forHost: Self.gitLabHost)
                == PRUndeterminedCause.forgeAuthFailed(host: Self.gitLabHost))
    }

    @Test("an auth failure keeps every existing binding rather than clearing it")
    func authFailureKeepsBindings() async {
        let previous = PRStatus(number: 412, url: Self.gitLabMRURL, state: .pending,
                                reason: "Checks pending")
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { _, _ in
                GHCommandResult(stdout: "", stderr: "401 Unauthorized", exitStatus: 1)
            },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding(status: previous)

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status == previous)
    }

    @Test("a host that answers again retracts its recorded refusal")
    func successClearsAuthFailure() async {
        // A token is re-issued and the host works; only a call succeeding is
        // ever accepted as proof, and it must clear the stale report.
        let gl = GitLabFake()
        let gate = AuthGate()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in
                if await gate.refuses {
                    return GHCommandResult(stdout: "", stderr: "401 Unauthorized", exitStatus: 1)
                }
                return await gl.run(args: args, repoPath: path)
            },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding()

        _ = await manager.refreshBindings([binding])
        #expect(await manager.lastUndeterminedCause(forHost: Self.gitLabHost) != nil)

        await gate.reissueToken()
        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status.state == .mergeable)
        #expect(await manager.lastUndeterminedCause(forHost: Self.gitLabHost) == nil)
    }

    @Test("a GitHub host never gets a GitLab auth report")
    func gitHubHostHasNoForgeAuthReport() async {
        let gh = BindingGH()
        let manager = PRStatusManager(
            ghRunner: { args, path in await gh.run(args: args, repoPath: path) },
            glRunner: { _, _ in
                GHCommandResult(stdout: "", stderr: "401 Unauthorized", exitStatus: 1)
            },
            gitLabHosts: [Self.gitLabHost])

        _ = await manager.refreshBindings([Self.binding(412, worktreeID: UUID())])

        #expect(await manager.lastUndeterminedCause(forHost: "github.com") == nil)
    }

    // MARK: - Branch list composition (pure)

    @Test("one project query asks about each branch once, in first-seen order")
    func branchListDeduplicates() {
        #expect(PRStatusManager.orderedUniqueBranches(
            ["tbd/a", "release/1", "tbd/a", "", "tbd/b"]) == ["tbd/a", "release/1", "tbd/b"])
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

    @Test("withObservation carries the observed refs and never clears a stored one")
    func withObservationCarriesRefs() {
        let wt = UUID()
        let original = binding(7, worktreeID: wt, state: nil)
        let fresh = PRStatus(number: 7, url: original.url, state: .merged)

        let observed = original.withObservation(
            status: fresh, headBranch: "tbd/feature", baseRef: "main")
        #expect(observed.id == original.id)
        #expect(observed.identityKey == original.identityKey)
        #expect(observed.source == original.source)
        #expect(observed.boundAt == original.boundAt)
        #expect(observed.status == fresh)
        #expect(observed.headBranch == "tbd/feature")
        #expect(observed.baseRef == "main")

        // A nil ref means "not observed this pass", never "cleared".
        let unobserved = observed.withObservation(status: fresh, headBranch: nil, baseRef: nil)
        #expect(unobserved.headBranch == "tbd/feature")
        #expect(unobserved.baseRef == "main")
    }

    /// The fold the poll applies before judging the merge rule: an absent
    /// observation leaves the binding exactly as stored, a present one carries
    /// both the status and the refs.
    @Test("folding an observation onto a binding is what the merge rule judges")
    func foldingAppliesTheObservation() {
        let wt = UUID()
        let original = binding(7, worktreeID: wt, state: nil)
        #expect(RPCRouter.folding(original, onto: nil) == original)

        let fresh = PRStatus(number: 7, url: original.url, state: .merged)
        let folded = RPCRouter.folding(original, onto: PRStatusManager.PRBindingObservation(
            status: fresh, headBranch: "tbd/feature", baseRef: "main"))
        #expect(folded.status == fresh)
        #expect(folded.headBranch == "tbd/feature")
        #expect(folded.baseRef == "main")
    }
}
