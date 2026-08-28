import Clocks
import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

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
    ///
    /// Bounded by `ciSafeDeadline`, not by a snappier number of its own: this
    /// asserts nothing about how *fast* the recheck lands, only that it does,
    /// so the bound is a hang-catcher and a passing run never pays it. Its
    /// previous 10 s went red on `main` at `ea27710d` while asserting nothing —
    /// in that pass the median test's own reported span was 85.8 s, so a 10 s
    /// wall-clock budget was an order of magnitude under the noise floor. See
    /// `ciSafeDeadline`'s own derivation in `ControlModeTestSupport.swift`.
    func waitForRecheck(within timeout: Duration = ciSafeDeadline) async -> Bool {
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
        "title":"Rate-limit the ingest queue",
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
    /// How many rechecks were issued, so a test can assert a second one never
    /// was — the whole point of the single-flight gate.
    private(set) var issued = 0

    func hang() async {
        entered = true
        issued += 1
        while !released { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Whether the issued count is still `count` after `grace`. A recheck is
    /// issued from a detached task nobody schedules, so "a second one never
    /// appeared" can only be asserted by giving it a window to appear in.
    func issuedStayedAt(_ count: Int, for grace: Duration = .milliseconds(500)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: grace)
        while ContinuousClock.now < deadline {
            if issued != count { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return issued == count
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

/// A mergeability recheck that never answers until something cancels it.
///
/// Cancellation is the observable stand-in for the kill: production's `runCLI`
/// turns exactly this cancellation into a `terminate()` on the `glab` child, so
/// a recheck that observes it is one whose subprocess ends.
private actor CancellableRecheck {
    private var entered = false
    private var cancelled = false

    func hangUntilCancelled() async {
        entered = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        cancelled = true
    }

    /// Polled, because the recheck is issued from a detached task whose
    /// scheduling no test owns. The bound under test is virtual time; these
    /// waits only cover that scheduling.
    func wasEntered(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !entered && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }

    func wasCancelled(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !cancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cancelled
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

/// A `gh` that disowns the checkout — as it does on every GitLab remote — and
/// would still answer any GraphQL query put to it, because a FLAT GitLab
/// namespace is a valid GitHub coordinate and a same-named repository on
/// github.com really does answer for it.
///
/// Every answer here is MERGED: on the wrong forge that is the destructive one,
/// since it drives the merged-transition machinery (auto-archive included).
private actor MirrorGH {
    private(set) var graphQLQueries: [String] = []

    private static let disownment = GHCommandResult(
        stdout: "",
        stderr: "none of the git remotes configured for this repository point to a known GitHub host",
        exitStatus: 1)

    func run(args: [String]) -> GHCommandResult? {
        if args.first == "repo" { return Self.disownment }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        graphQLQueries.append(query)
        if query.contains("title") {
            // `openPRsQuery` — the branch picker's list.
            return GHCommandResult(stdout: """
            {"data":{"repository":{"pullRequests":{"nodes":[
            {"number":77,"title":"Mirror pull request","headRefName":"tbd/my-branch",
             "isDraft":false,"isCrossRepository":false,
             "headRepositoryOwner":{"login":"acme"}}]}}}}
            """)
        }
        if query.contains("pullRequest(number:") {
            return GHCommandResult(stdout: """
            {"data":{"repository":{"pr0":\(Self.mergedNode)}}}
            """)
        }
        return GHCommandResult(stdout: """
        {"data":{"repository":{"pullRequests":{"nodes":[\(Self.mergedNode)]}}}}
        """)
    }

    private static let mergedNode = """
    {"number":77,"url":"https://github.com/acme/api-gateway/pull/77","state":"MERGED",
     "mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","headRefName":"tbd/my-branch",
     "baseRefName":"main","createdAt":"2026-08-01T00:00:00Z","isDraft":false,
     "statusCheckRollup":{"state":"SUCCESS"}}
    """
}

/// Records every merged transition the manager fires — the edge that reaches
/// auto-archive and auto-hibernate.
private actor MergedTransitions {
    private(set) var fired: [(worktreeID: UUID, number: Int)] = []
    func record(_ worktreeID: UUID, _ number: Int) { fired.append((worktreeID, number)) }
    var count: Int { fired.count }
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
        // The hover card renders `binding.title` whatever the forge, so a
        // GitLab arm that never observed one renders a permanently degraded
        // card: a number and a state, and nothing saying what the MR is.
        #expect(observed[binding.id]?.title == "Rate-limit the ingest queue")
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

    @Test("a project whose recheck is still outstanding is not issued another")
    func recheckIsSingleFlightPerProject() async throws {
        // The detached recheck inherits no cancellation and `runCLI` imposes no
        // timeout, so without a gate a hung endpoint accumulates one `glab`,
        // one `Process` and its descriptors per tick, forever — and no
        // reconciler covers a forge CLI subprocess.
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

        _ = await manager.refreshBindings([binding])
        #expect(await recheck.wasEntered(), "the first poll issued no recheck to be blocked by")

        // A second poll of the same project, while the first recheck hangs.
        _ = await manager.refreshBindings([binding])
        #expect(await recheck.issuedStayedAt(1))

        // …and the gate re-arms when the outstanding one ends, so this is a
        // bound rather than a one-shot.
        await recheck.release()
        try await waitFor("the gate to re-arm once the outstanding recheck ended") {
            _ = await manager.refreshBindings([binding])
            return await recheck.issued >= 2
        }
    }

    @Test("a hung mergeability recheck is terminated once its deadline elapses",
          .clockDriven)
    func recheckIsBoundedByADeadline() async {
        // Single-flight caps how MANY rechecks are live and can never end one:
        // a `glab` that hangs stays for the life of the daemon, and no
        // reconciler covers a forge CLI subprocess. The deadline is the half
        // that caps the LIFETIME, and it has to reach the call itself —
        // cancellation, which `runCLI` turns into a terminate on the child —
        // rather than merely stop this side waiting for it.
        let clock = TestClock()
        let gl = GitLabFake()
        let recheck = CancellableRecheck()
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in
                if args.contains(where: { $0.contains("with_merge_status_recheck=true") }) {
                    await recheck.hangUntilCancelled()
                    return nil
                }
                return await gl.run(args: args, repoPath: path)
            },
            gitLabHosts: [Self.gitLabHost],
            clock: clock)

        _ = await manager.refreshBindings([Self.gitLabBinding()])
        #expect(await recheck.wasEntered(), "no recheck was issued for a deadline to bound")

        // Virtual time: the bound is proven without spending it.
        await clock.advanceWhenSuspended(by: PRStatusManager.recheckTimeout)

        #expect(await recheck.wasCancelled(),
                "the recheck was still running after its deadline elapsed")
    }

    @Test("a recheck child that ignores SIGTERM is killed by its deadline",
          .clockDriven)
    func recheckChildIsKilledWhenItIgnoresSIGTERM() async throws {
        // The deadline above proves the Swift task stops waiting. This proves
        // the thing that actually matters: a real OS process is gone by the
        // bound. The injected runner drives `runCLI` — the production
        // subprocess path, cancellation handler and all — with a child that
        // installs SIG_IGN for SIGTERM and then `exec`s, so the ignore survives
        // into a single long-lived process whose pid never changes. SIGTERM
        // alone leaves it running, `withTaskGroup` awaits it before returning,
        // and the recheck task plus that project's single-flight gate stay
        // wedged for as long as it lives — well past the 60 s the design leans
        // on to argue no reconciler is needed.
        let clock = TestClock()
        let gl = GitLabFake()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-glab-kill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The child reports its own pid: `$$` is the shell's, and `exec` keeps
        // it, so this is the pid of the `sleep` the deadline has to reach.
        let pidFile = dir.appendingPathComponent("child.pid")
        // Nothing reclaims a forge CLI subprocess, this suite included: if the
        // assertion below fails the child is still out there, so end it here.
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let leaked = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(leaked, SIGKILL)
            }
        }

        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in
                guard args.contains(where: { $0.contains("with_merge_status_recheck=true") })
                else { return await gl.run(args: args, repoPath: path) }
                return await PRStatusManager.runCLI(
                    executable: "/bin/sh",
                    args: ["-c", "trap '' TERM; echo $$ > '\(pidFile.path)'; exec sleep 120"],
                    repoPath: dir.path,
                    clock: clock)
            },
            gitLabHosts: [Self.gitLabHost],
            clock: clock)

        _ = await manager.refreshBindings([Self.gitLabBinding()])

        try await waitFor("the recheck child to report its pid") {
            (try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let childPID = try #require(pid_t(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(childPID, 0) == 0, "the child was not running for the deadline to end")

        // Virtual time: the deadline fires, then the grace after SIGTERM.
        await clock.advanceWhenSuspended(by: PRStatusManager.recheckTimeout)
        let died = await clock.advanceUntil(
            "the SIGTERM-immune recheck child to be killed", by: PRStatusManager.childKillGrace
        ) { kill(childPID, 0) != 0 && errno == ESRCH }

        #expect(died, "the child outlived its deadline: SIGTERM alone cannot end it")
    }

    @Test("a recheck child that honours SIGTERM ends without waiting out the grace",
          .clockDriven)
    func recheckChildThatHonoursSIGTERMIsNotWaitedOn() async throws {
        // The other branch of the escalation, and the reason it is a grace
        // rather than an immediate SIGKILL: the ordinary child — a `glab` that
        // takes the signal and exits — is gone the moment the deadline fires,
        // with no advance past it. The wait below spends real time and no
        // virtual time at all, so a build that had started killing children
        // outright would still pass here while the previous test is what pins
        // the grace being spent only on a child that needs it.
        let clock = TestClock()
        let gl = GitLabFake()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-glab-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let leaked = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(leaked, SIGKILL)
            }
        }

        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { args, path in
                guard args.contains(where: { $0.contains("with_merge_status_recheck=true") })
                else { return await gl.run(args: args, repoPath: path) }
                return await PRStatusManager.runCLI(
                    executable: "/bin/sh",
                    args: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 120"],
                    repoPath: dir.path,
                    clock: clock)
            },
            gitLabHosts: [Self.gitLabHost],
            clock: clock)

        _ = await manager.refreshBindings([Self.gitLabBinding()])

        try await waitFor("the recheck child to report its pid") {
            (try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let childPID = try #require(pid_t(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        await clock.advanceWhenSuspended(by: PRStatusManager.recheckTimeout)

        try await waitFor("the recheck child to exit on SIGTERM alone") {
            kill(childPID, 0) != 0 && errno == ESRCH
        }
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

    // MARK: - Cross-forge containment

    /// A GitLab project whose namespace is FLAT, so its owner/name are also
    /// valid GitHub coordinates — 21% of sampled projects, and the shape where
    /// a wrong-forge query does not fail but answers.
    private static func flatGitLabWorktree(
        _ id: UUID, prNumber: Int? = nil
    ) -> PRStatusManager.PollWorktree {
        (id: id, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main",
         pushBranch: .noPushDestination, worktreePath: "/wt/api-gateway", prNumber: prNumber)
    }

    private static func mirrorManager(
        _ gh: MirrorGH
    ) -> PRStatusManager {
        PRStatusManager(
            ghRunner: { args, _ in await gh.run(args: args) },
            glRunner: { _, _ in nil },
            gitLabHosts: [Self.gitLabHost],
            remoteURLReader: { _ in "https://git.acme.example/acme/api-gateway.git" })
    }

    @Test("an on-select refresh never writes a GitHub pull request onto a GitLab worktree")
    func refreshDoesNotCrossForges() async {
        let gh = MirrorGH()
        let manager = Self.mirrorManager(gh)
        let merges = MergedTransitions()
        await manager.setOnMergedTransition { id, number in await merges.record(id, number) }
        let wt = UUID()

        let status = await manager.refresh(
            worktreeID: wt, branch: "tbd/my-branch", upstreamBranch: "main",
            defaultBranch: "main", pushBranch: .noPushDestination,
            repoPath: "/wt/api-gateway")

        #expect(status == nil)
        #expect(await manager.allStatuses()[wt] == nil)
        #expect(await merges.count == 0)
        #expect(await gh.graphQLQueries.isEmpty)
        // Declining to ask gh is not an attempt that failed. A worktree with no
        // outcome on record still has none — asserting one would light the "PR
        // status unknown" indicator on a worktree nothing was ever asked about.
        #expect(await manager.observation(for: wt) == nil)
    }

    @Test("a manual refresh on a GitLab worktree leaves its last observation standing")
    func refreshKeepsTheGitLabObservation() async {
        // `pr.refresh` is a user gesture. A GitLab worktree whose bindings poll
        // perfectly must not answer it with "last check did not resolve" — the
        // binding poll settles this worktree, and its word stands until it has
        // a new one.
        let gh = MirrorGH()
        let manager = Self.mirrorManager(gh)
        let wt = UUID()
        let polled = Date(timeIntervalSince1970: 1_770_000_000)
        await manager.hydrateObservations([wt: PRObservation(outcome: .observed, observedAt: polled)])

        _ = await manager.refresh(
            worktreeID: wt, branch: "tbd/my-branch", upstreamBranch: "main",
            defaultBranch: "main", pushBranch: .noPushDestination,
            repoPath: "/wt/api-gateway")

        let observation = await manager.observation(for: wt)
        #expect(observation?.outcome == .observed)
        #expect(observation?.observedAt == polled)
        #expect(await gh.graphQLQueries.isEmpty)
    }

    @Test("a stored number on a GitLab worktree is never offered to gh")
    func refreshByNumberDoesNotCrossForges() async {
        // The by-number route is the one that reaches a pull request the branch
        // query cannot, so it is also the one that reaches the wrong forge's.
        let gh = MirrorGH()
        let manager = Self.mirrorManager(gh)
        let merges = MergedTransitions()
        await manager.setOnMergedTransition { id, number in await merges.record(id, number) }
        let wt = UUID()

        let status = await manager.refresh(
            worktreeID: wt, branch: "tbd/my-branch", upstreamBranch: "main",
            defaultBranch: "main", pushBranch: .noPushDestination,
            repoPath: "/wt/api-gateway", prNumber: 77)

        #expect(status == nil)
        #expect(await merges.count == 0)
        #expect(await gh.graphQLQueries.isEmpty)
    }

    @Test("the poll's by-number path cannot auto-archive a GitLab worktree on a GitHub PR")
    func pollByNumberDoesNotCrossForges() async {
        let gh = MirrorGH()
        let manager = Self.mirrorManager(gh)
        let merges = MergedTransitions()
        await manager.setOnMergedTransition { id, number in await merges.record(id, number) }
        let wt = UUID()

        _ = await manager.fetchAll(worktrees: [Self.flatGitLabWorktree(wt, prNumber: 77)])

        #expect(await manager.allStatuses()[wt] == nil)
        #expect(await merges.count == 0)
        #expect(await gh.graphQLQueries.isEmpty)
    }

    @Test("the open-PR picker does not offer a GitLab repo another forge's pull requests")
    func openPRPickerDoesNotCrossForges() async {
        // Listing GitLab merge requests is not built, so an empty list is the
        // honest answer — a list of somebody else's pull requests is not, and
        // creating a worktree from one would check out a foreign branch.
        let gh = MirrorGH()
        let manager = Self.mirrorManager(gh)

        let prs = await manager.fetchOpenPRs(repoPath: "/wt/api-gateway")

        #expect(prs.isEmpty)
        #expect(await gh.graphQLQueries.isEmpty)
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

    @Test("a credential refusal on the binding path reaches the worktree, not just a log")
    func authFailureIsReportedOnTheBindingPath() async {
        // Once a GitLab worktree has a binding, this is the path that polls it.
        // A personal access token has no refresh, so an expired one refuses
        // every tick from here on: keeping the last value is right, and saying
        // nothing about it is what leaves every chip frozen and unexplained.
        let wt = UUID()
        let previous = PRStatus(number: 412, url: Self.gitLabMRURL, state: .mergeable)
        let manager = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { _, _ in
                GHCommandResult(stdout: "", stderr: "401 Unauthorized", exitStatus: 1)
            },
            gitLabHosts: [Self.gitLabHost])
        let binding = Self.gitLabBinding(worktreeID: wt, status: previous)

        let observed = await manager.refreshBindings([binding])

        #expect(observed[binding.id]?.status == previous)
        #expect(await manager.observation(for: wt)?.outcome
                == .undetermined(cause: PRUndeterminedCause.forgeAuthFailed(host: Self.gitLabHost)))

        // And deliberately only the refusal: a query that merely failed is
        // reconfirmed by the next tick, and recording it here would relabel a
        // worktree whose other bindings were read perfectly well this pass.
        let other = UUID()
        let quiet = PRStatusManager(
            ghRunner: { _, _ in nil },
            glRunner: { _, _ in nil },
            gitLabHosts: [Self.gitLabHost])
        _ = await quiet.refreshBindings([Self.gitLabBinding(worktreeID: other)])
        #expect(await quiet.observation(for: other) == nil)
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

    @Test("withObservation carries the observed refs and title, and never clears a stored one")
    func withObservationCarriesRefs() {
        let wt = UUID()
        let original = binding(7, worktreeID: wt, state: nil)
        let fresh = PRStatus(number: 7, url: original.url, state: .merged)

        let observed = original.withObservation(
            status: fresh, headBranch: "tbd/feature", baseRef: "main",
            title: "Fix the login timeout")
        #expect(observed.id == original.id)
        #expect(observed.identityKey == original.identityKey)
        #expect(observed.source == original.source)
        #expect(observed.boundAt == original.boundAt)
        #expect(observed.status == fresh)
        #expect(observed.headBranch == "tbd/feature")
        #expect(observed.baseRef == "main")
        #expect(observed.title == "Fix the login timeout")

        // A nil ref or title means "not observed this pass", never "cleared" —
        // a `gh` outage must not blank the title the status bar has on screen.
        let unobserved = observed.withObservation(status: fresh, headBranch: nil,
                                                  baseRef: nil, title: nil)
        #expect(unobserved.headBranch == "tbd/feature")
        #expect(unobserved.baseRef == "main")
        #expect(unobserved.title == "Fix the login timeout")

        // A retitled PR does replace it — "not observed" is nil, not a lock.
        let retitled = observed.withObservation(status: fresh, headBranch: nil,
                                                baseRef: nil, title: "Fix the login timeout, again")
        #expect(retitled.title == "Fix the login timeout, again")
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
            status: fresh, headBranch: "tbd/feature", baseRef: "main",
            title: "Fix the login timeout"))
        #expect(folded.status == fresh)
        #expect(folded.headBranch == "tbd/feature")
        #expect(folded.baseRef == "main")
        #expect(folded.title == "Fix the login timeout")
    }

    /// The fold is the only place the poll can lose a title, and the pass that
    /// keeps a previous status (a failed check query) is the one that would do
    /// it: it reports refs and title from the node it DID resolve, and folding
    /// must carry them rather than dropping back to what the row held.
    @Test("folding an observation with no title keeps the stored one")
    func foldingKeepsAStoredTitle() {
        let wt = UUID()
        let stored = PRBinding(
            worktreeID: wt, owner: "acme", repo: "acme-prod", number: 7,
            url: "https://github.com/acme/acme-prod/pull/7",
            title: "Fix the login timeout", source: .hook)
        let fresh = PRStatus(number: 7, url: stored.url, state: .mergeable)

        let folded = RPCRouter.folding(stored, onto: PRStatusManager.PRBindingObservation(
            status: fresh, headBranch: nil, baseRef: nil, title: nil))
        #expect(folded.title == "Fix the login timeout")

        // And an absent observation leaves the binding wholly alone.
        #expect(RPCRouter.folding(stored, onto: nil).title == "Fix the login timeout")
    }

    /// Persist-on-change reads `sameValue`, so a title has to be inside it or a
    /// renamed PR would never reach the row — and `observedAt` has to stay
    /// outside it or every idle poll would write every binding.
    @Test("a changed title is a change, a fresh stamp on an identical title is not")
    func titleParticipatesInChangeDetection() {
        let wt = UUID()
        // One id and one boundAt across every variant: `sameValue` compares
        // whole bindings, so two independently minted rows differ on identity
        // alone and would prove nothing about the title.
        let id = UUID()
        let boundAt = Date(timeIntervalSince1970: 0)
        let url = "https://github.com/acme/acme-prod/pull/7"
        func stamped(_ title: String?, at date: Date) -> PRBinding {
            PRBinding(id: id, worktreeID: wt, owner: "acme", repo: "acme-prod",
                      number: 7, url: url, title: title,
                      status: PRStatus(number: 7, url: url, state: .mergeable,
                                       observedAt: date),
                      source: .hook, boundAt: boundAt)
        }
        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        #expect(stamped("Fix the login timeout", at: early)
            .sameValue(as: stamped("Fix the login timeout", at: later)))
        #expect(!stamped("Fix the login timeout", at: early)
            .sameValue(as: stamped("Fix the login timeout, again", at: early)))
        #expect(!stamped(nil, at: early).sameValue(as: stamped("Fix the login timeout", at: early)))
    }
}
