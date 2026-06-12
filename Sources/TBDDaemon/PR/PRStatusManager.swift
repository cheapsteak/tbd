import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRStatusManager")

/// In-memory cache of GitHub PR status per worktree.
///
/// `fetchAll` runs one batch GraphQL call for all viewer PRs, plus one combined per-PR
/// GraphQL call (run concurrently) for each OPEN PR whose aggregate rollup isn't SUCCESS —
/// that call returns the aggregate state, every check context with its `isRequired`
/// flag, and a pagination flag in a single round trip. `refresh` runs
/// `gh pr view` plus the same combined call for OPEN PRs. On transient fetch failure,
/// callers keep the previous cached status instead of guessing.
public actor PRStatusManager {

    private var cache: [UUID: PRStatus] = [:]

    /// Reentrancy guard: a previous poll still running means a new `fetchAll` is skipped
    /// so two generations of batch data can't interleave their cache writes.
    private var fetchAllInProgress = false

    /// Set by `refresh()`/`invalidate()`; `fetchAll` won't overwrite newer data.
    private var lastDirectUpdate: [UUID: Date] = [:]

    public init() {}

    // MARK: - Public interface

    public func allStatuses() -> [UUID: PRStatus] { cache }

    public func invalidate(worktreeID: UUID) {
        cache.removeValue(forKey: worktreeID)
        lastDirectUpdate[worktreeID] = Date()   // an in-flight fetchAll must not resurrect the entry
    }

    /// Fetch all viewer PRs in one GraphQL call and update cache for all known worktrees.
    /// worktrees: list of (id, branch, upstreamBranch, worktreePath) for active non-main worktrees.
    public func fetchAll(worktrees: [(id: UUID, branch: String, upstreamBranch: String?, worktreePath: String)]) async {
        guard !worktrees.isEmpty else { return }
        guard !fetchAllInProgress else { return }   // a previous poll is still running; skip to avoid interleaved generations
        fetchAllInProgress = true
        defer { fetchAllInProgress = false }
        let batchStartedAt = Date()
        // All worktrees share one repo; any path works as gh's working directory for auth.
        let repoPath = worktrees[0].worktreePath

        guard let jsonData = await runGHGraphQL(repoPath: repoPath) else { return }

        guard let nodes = try? Self.parsePRNodes(from: jsonData) else {
            logger.warning("Failed to parse GraphQL response")
            return
        }

        // Build branch → PRNode lookup. When multiple PRs share a branch,
        // pick the best one: sort by state priority (OPEN > MERGED > CLOSED),
        // then by createdAt descending (newest first within the same state).
        var byBranch: [String: PRNode] = [:]
        for node in nodes {
            if let existing = byBranch[node.headRefName] {
                let nodePriority = Self.prPriority(node.state)
                let existingPriority = Self.prPriority(existing.state)
                if nodePriority > existingPriority {
                    byBranch[node.headRefName] = node
                } else if nodePriority == existingPriority && node.createdAt > existing.createdAt {
                    byBranch[node.headRefName] = node
                }
            } else {
                byBranch[node.headRefName] = node
            }
        }

        // Collect matches first.
        // Do NOT clear entries for missing worktrees — the batch query is
        // limited to 100 PRs across all repos, so older PRs may not appear.
        // Those entries may have been populated by a targeted `refresh` call.
        var matches: [(worktreeID: UUID, node: PRNode)] = []
        for wt in worktrees {
            let candidates = Self.branchCandidates(localBranch: wt.branch, upstreamBranch: wt.upstreamBranch)
            if let node = candidates.compactMap({ byBranch[$0] }).first {
                matches.append((wt.id, node))
            }
        }

        // Fetch per-PR signals concurrently; only non-green OPEN PRs need the query.
        let signalsByID = await withTaskGroup(of: (UUID, (failing: Bool, pending: Bool)?).self,
                                              returning: [UUID: (failing: Bool, pending: Bool)?].self) { group in
            for match in matches {
                let node = match.node
                let id = match.worktreeID
                if node.state != "OPEN" || !Self.aggregateRollupIsNonSuccess(node.statusCheckRollupState) {
                    group.addTask { (id, (failing: false, pending: false)) }
                } else {
                    group.addTask {
                        (id, await self.fetchCheckSignals(url: node.url, number: node.number, repoPath: repoPath))
                    }
                }
            }
            var out: [UUID: (failing: Bool, pending: Bool)?] = [:]
            for await (id, signals) in group { out[id] = signals }
            return out
        }

        for match in matches {
            // A user-initiated refresh (or invalidate) landed after this batch's snapshot —
            // its data is fresher than ours; don't clobber it.
            if let direct = lastDirectUpdate[match.worktreeID], direct > batchStartedAt { continue }
            let signals: (failing: Bool, pending: Bool)
            if let fetched = signalsByID[match.worktreeID] ?? nil {
                signals = fetched
            } else if cache[match.worktreeID] != nil {
                continue   // transient failure: keep the previous status rather than guessing
            } else {
                signals = Self.aggregateFallbackSignals(match.node.statusCheckRollupState)
            }
            cache[match.worktreeID] = PRStatus(
                number: match.node.number,
                url: match.node.url,
                state: Self.mapState(
                    ghState: match.node.state,
                    mergeStateStatus: match.node.mergeStateStatus,
                    reviewDecision: match.node.reviewDecision,
                    isDraft: match.node.isDraft,
                    requiredChecksFailing: signals.failing,
                    requiredChecksPending: signals.pending
                )
            )
        }
    }

    /// The aggregate rollup classifies a per-check query as worthwhile when it is NOT a settled
    /// success — i.e. it is failing or pending (or any other non-success/non-nil value). SUCCESS
    /// or nil means no required check can be failing or pending → skip the query.
    private static func aggregateRollupIsNonSuccess(_ state: String?) -> Bool {
        guard let state else { return false }
        return state != "SUCCESS"
    }

    /// Refresh a single worktree using `gh pr view`. Used for on-select refresh.
    public func refresh(worktreeID: UUID, branch: String, upstreamBranch: String?, repoPath: String) async -> PRStatus? {
        let candidates = Self.branchCandidates(localBranch: branch, upstreamBranch: upstreamBranch)
        for candidate in candidates {
            let args = ["pr", "view", candidate,
                        "--json", "number,url,state,mergeStateStatus,reviewDecision,isDraft"]
            guard let output = await runGH(args: args, repoPath: repoPath),
                  let data = output.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(GHPRViewResult.self, from: data) else {
                continue
            }

            let signals: (failing: Bool, pending: Bool)
            if obj.state != "OPEN" {
                signals = (false, false)   // mapState ignores signals for MERGED/CLOSED
            } else if let fetched = await fetchCheckSignals(url: obj.url, number: obj.number, repoPath: repoPath) {
                signals = fetched
            } else if let cached = cache[worktreeID] {
                return cached   // transient failure: keep the previous status rather than guessing
            } else {
                signals = (false, false)   // bootstrap with no data; the next poll corrects it
            }

            let status = PRStatus(
                number: obj.number,
                url: obj.url,
                state: Self.mapState(ghState: obj.state,
                                     mergeStateStatus: obj.mergeStateStatus,
                                     reviewDecision: obj.reviewDecision ?? "",
                                     isDraft: obj.isDraft,
                                     requiredChecksFailing: signals.failing,
                                     requiredChecksPending: signals.pending)
            )
            cache[worktreeID] = status
            lastDirectUpdate[worktreeID] = Date()
            return status
        }

        // gh exited non-zero or parse failed for every candidate — leave cache unchanged.
        return cache[worktreeID]
    }

    /// For tests only: seed a cache entry directly.
    public func seedForTesting(worktreeID: UUID, status: PRStatus) {
        cache[worktreeID] = status
    }

    // MARK: - State mapping (internal but static for testability)

    public static func mapState(
        ghState: String,
        mergeStateStatus: String,
        reviewDecision: String = "",
        isDraft: Bool = false,
        requiredChecksFailing: Bool = false,
        requiredChecksPending: Bool = false
    ) -> PRMergeableState {
        switch ghState {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default:
            if isDraft || mergeStateStatus == "DRAFT" { return .draft }
            if reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
            // Uniform precedence: a failing required check is red and a pending required check
            // is yellow regardless of merge state. (When the PR has no required checks at all,
            // both signals are false and mergeStateStatus below decides — see checkSignals.)
            if requiredChecksFailing { return .checksFailed }
            if requiredChecksPending { return .pending }

            switch mergeStateStatus {
            case "CLEAN", "HAS_HOOKS", "UNSTABLE":
                // UNSTABLE = mergeable with non-required checks failing → not red.
                return .mergeable
            case "BLOCKED":
                // Checks are settled and passing; the only blocker is a not-yet-given review.
                return reviewDecision == "REVIEW_REQUIRED" ? .mergeable : .blocked
            case "DIRTY", "BEHIND":
                return .blocked
            case "UNKNOWN":
                return .pending
            default:
                return .blocked
            }
        }
    }

    /// Conclusions (CheckRun) that count as a failing check.
    private static let failingCheckRunConclusions: Set<String> = [
        "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"
    ]
    /// States (StatusContext) that count as a failing check.
    private static let failingStatusContextStates: Set<String> = ["FAILURE", "ERROR"]
    /// CheckRun `status` values that mean the check is still running / not yet concluded.
    private static let pendingCheckRunStatuses: Set<String> = [
        "QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"
    ]
    /// StatusContext `state` values that count as a pending check.
    private static let pendingStatusContextStates: Set<String> = ["PENDING", "EXPECTED"]

    /// A single status-check context for one PR's last commit. Unifies the GraphQL `CheckRun`
    /// and `StatusContext` shapes.
    struct CheckContext {
        let name: String          // CheckRun.name, or StatusContext.context
        let status: String?       // CheckRun.status (nil for StatusContext)
        let conclusion: String?   // CheckRun.conclusion (nil for StatusContext)
        let state: String?        // StatusContext.state (nil for CheckRun)
        let isRequired: Bool?     // absent in the JSON → nil
    }

    /// Whether a context counts as failing (regardless of required-ness).
    static func contextIsFailing(_ ctx: CheckContext) -> Bool {
        if let conclusion = ctx.conclusion, Self.failingCheckRunConclusions.contains(conclusion) {
            return true
        }
        if let state = ctx.state, Self.failingStatusContextStates.contains(state) {
            return true
        }
        return false
    }

    /// Whether a context counts as pending (regardless of required-ness).
    static func contextIsPending(_ ctx: CheckContext) -> Bool {
        if let status = ctx.status, Self.pendingCheckRunStatuses.contains(status), ctx.conclusion == nil {
            return true
        }
        if let state = ctx.state, Self.pendingStatusContextStates.contains(state) {
            return true
        }
        return false
    }

    /// Compute the (failing, pending) signals for one PR's check contexts.
    /// Only checks GitHub marks `isRequired` for this PR ever color the icon. A PR with no
    /// required checks (stacked PR targeting an unprotected feature branch, or a repo without
    /// branch protection) gets no CI coloring from checks — the mergeStateStatus refinement in
    /// mapState decides instead, matching GitHub's own merge verdict.
    /// `aggregateRollupState` EXPECTED covers the post-push window: a required check that
    /// hasn't reported a context yet can't be seen in `contexts`.
    static func checkSignals(contexts: [CheckContext], aggregateRollupState: String?) -> (failing: Bool, pending: Bool) {
        let required = contexts.filter { $0.isRequired == true }
        return (
            required.contains(where: contextIsFailing),
            required.contains(where: contextIsPending) || aggregateRollupState == "EXPECTED"
        )
    }

    /// Signals derived from the aggregate rollup alone — used when per-check data is
    /// unavailable (query failure) or incomplete (contexts truncated past first page).
    /// The aggregate counts non-required checks too, so this can over-report; it is a
    /// bootstrap/degraded mode, not the normal path.
    static func aggregateFallbackSignals(_ rollupState: String?) -> (failing: Bool, pending: Bool) {
        (["FAILURE", "ERROR"].contains(rollupState ?? ""),
         ["PENDING", "EXPECTED"].contains(rollupState ?? ""))
    }

    /// Result of the combined per-PR check query.
    struct PRCheckDetail {
        let contexts: [CheckContext]
        let rollupState: String?
        let truncated: Bool   // contexts has more than one page; per-check view is incomplete
    }

    /// Pure parse of a single PR's last-commit status-check detail.
    ///
    /// Walks `data.repository.pullRequest.commits.nodes[].commit.statusCheckRollup`: reads
    /// `state`, `contexts.pageInfo.hasNextPage`, and the context nodes (CheckRun via
    /// name/status/conclusion/isRequired; StatusContext via context/state/isRequired; nameless
    /// nodes are skipped). Throws `PRStatusError.invalidJSON` if the outer shape can't be parsed.
    /// A null `statusCheckRollup` (no checks at all) yields empty contexts, nil state, not truncated.
    static func parsePRCheckDetail(fromJSON data: Data) throws -> PRCheckDetail {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let commits = pullRequest["commits"] as? [String: Any],
              let commitNodes = commits["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        var result: [CheckContext] = []
        var rollupState: String?
        var truncated = false

        for commitNode in commitNodes.compactMap({ $0 as? [String: Any] }) {
            guard let commit = commitNode["commit"] as? [String: Any],
                  let rollup = commit["statusCheckRollup"] as? [String: Any] else {
                continue
            }
            if let state = rollup["state"] as? String {
                rollupState = state
            }
            guard let contexts = rollup["contexts"] as? [String: Any] else { continue }
            if let pageInfo = contexts["pageInfo"] as? [String: Any],
               pageInfo["hasNextPage"] as? Bool == true {
                truncated = true
            }
            guard let contextNodes = contexts["nodes"] as? [Any] else { continue }

            for context in contextNodes.compactMap({ $0 as? [String: Any] }) {
                let isRequired = context["isRequired"] as? Bool
                if let name = context["name"] as? String {
                    // CheckRun
                    result.append(CheckContext(
                        name: name,
                        status: context["status"] as? String,
                        conclusion: context["conclusion"] as? String,
                        state: nil,
                        isRequired: isRequired
                    ))
                } else if let name = context["context"] as? String {
                    // StatusContext
                    result.append(CheckContext(
                        name: name,
                        status: nil,
                        conclusion: nil,
                        state: context["state"] as? String,
                        isRequired: isRequired
                    ))
                }
                // else: no name/context — skip.
            }
        }

        return PRCheckDetail(contexts: result, rollupState: rollupState, truncated: truncated)
    }

    /// Parse `owner` and `name` from a PR URL like
    /// `https://github.com/<owner>/<name>/pull/<n>`.
    static func parseOwnerRepo(fromURL url: String) -> (owner: String, name: String)? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        // Expect: [owner, name, "pull", <n>]
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return (owner: String(parts[0]), name: String(parts[1]))
    }

    /// Combined per-PR query: aggregate rollup state + every check context with its
    /// isRequired flag + pagination flag, in one round trip.
    /// The literal number must appear in both pullRequest(number:) and isRequired(pullRequestNumber:).
    static func prCheckQuery(owner: String, name: String, number: Int) -> String {
        """
        { repository(owner: "\(owner)", name: "\(name)") { pullRequest(number: \(number)) {
          commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              __typename
              ... on CheckRun { name status conclusion isRequired(pullRequestNumber: \(number)) }
              ... on StatusContext { context state isRequired(pullRequestNumber: \(number)) }
            }
          } } } } } } } }
        """
    }

    /// Priority for choosing between multiple PRs on the same branch.
    /// Higher value = preferred.
    private static func prPriority(_ ghState: String) -> Int {
        switch ghState {
        case "OPEN": return 3
        case "MERGED": return 2
        case "CLOSED": return 1
        default: return 0
        }
    }

    static func branchCandidates(localBranch: String, upstreamBranch: String?) -> [String] {
        guard let upstreamBranch, upstreamBranch != localBranch else {
            return [localBranch]
        }
        return [localBranch, upstreamBranch]
    }

    // MARK: - JSON parsing (internal but static for testability)

    public struct PRNode: Sendable {
        public let number: Int
        public let url: String
        public let state: String
        public let mergeStateStatus: String
        public let reviewDecision: String   // "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", or ""
        public let headRefName: String
        public let createdAt: String        // ISO 8601, e.g. "2026-03-24T15:58:27Z"
        public let isDraft: Bool
        public let statusCheckRollupState: String?
    }

    public static func parsePRNodes(from data: Data) throws -> [PRNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let viewer = dataObj["viewer"] as? [String: Any],
              let prs = viewer["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        return nodes.compactMap { $0 as? [String: Any] }.compactMap { node -> PRNode? in
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String,
                  let mergeStateStatus = node["mergeStateStatus"] as? String,
                  let headRefName = node["headRefName"] as? String,
                  let createdAt = node["createdAt"] as? String else { return nil }
            let reviewDecision = node["reviewDecision"] as? String ?? ""
            let isDraft = node["isDraft"] as? Bool ?? false
            let statusCheckRollup = node["statusCheckRollup"] as? [String: Any]
            let statusCheckRollupState = statusCheckRollup?["state"] as? String
            return PRNode(number: number, url: url, state: state,
                          mergeStateStatus: mergeStateStatus,
                          reviewDecision: reviewDecision,
                          headRefName: headRefName,
                          createdAt: createdAt,
                          isDraft: isDraft,
                          statusCheckRollupState: statusCheckRollupState)
        }
    }

    // MARK: - Shell helpers

    private nonisolated func runGHGraphQL(repoPath: String) async -> Data? {
        let query = """
        {
          viewer {
            pullRequests(first: 100, states: [OPEN, MERGED, CLOSED],
                         orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes {
                number url state mergeStateStatus reviewDecision headRefName createdAt isDraft
                statusCheckRollup { state }
              }
            }
          }
        }
        """
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              let data = Self.graphQLOutputData(stdout: result.stdout) else {
            return nil
        }

        if result.exitStatus != 0 {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if errSuffix.isEmpty {
                logger.debug("gh graphql exited \(result.exitStatus, privacy: .public) with partial stdout")
            } else {
                logger.debug("gh graphql exited \(result.exitStatus, privacy: .public) with partial stdout: \(errSuffix, privacy: .public)")
            }
        }

        return data
    }

    /// One combined GraphQL round trip for a PR's check signals.
    /// Returns nil on any failure (gh missing, non-zero exit, parse error) — callers keep
    /// the previous cached status rather than guessing.
    private nonisolated func fetchCheckSignals(url: String, number: Int, repoPath: String) async -> (failing: Bool, pending: Bool)? {
        guard let ownerRepo = Self.parseOwnerRepo(fromURL: url) else {
            logger.debug("Cannot parse owner/repo from PR URL \(url, privacy: .public)")
            return nil
        }
        let query = Self.prCheckQuery(owner: ownerRepo.owner, name: ownerRepo.name, number: number)
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              result.exitStatus == 0,
              let data = Self.graphQLOutputData(stdout: result.stdout),
              let detail = try? Self.parsePRCheckDetail(fromJSON: data) else {
            logger.debug("Check signal query failed for PR #\(number, privacy: .public)")
            return nil
        }
        if detail.truncated {
            // Can't see every check — trust the aggregate instead of a partial view.
            logger.debug("PR #\(number, privacy: .public) has >100 check contexts; using aggregate fallback")
            return Self.aggregateFallbackSignals(detail.rollupState)
        }
        return Self.checkSignals(contexts: detail.contexts, aggregateRollupState: detail.rollupState)
    }

    private nonisolated func runGH(args: [String], repoPath: String) async -> String? {
        guard let result = await runGHResult(args: args, repoPath: repoPath) else {
            return nil
        }

        guard result.exitStatus == 0 else {
            let errStr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("gh exited \(result.exitStatus, privacy: .public): \(errStr, privacy: .public)")
            return nil
        }

        return result.stdout
    }

    static func graphQLOutputData(stdout: String) -> Data? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return stdout.data(using: .utf8)
    }

    private nonisolated func runGHResult(args: [String], repoPath: String) async -> GHCommandResult? {
        guard let ghPath = Self.resolvedGHPath else {
            logger.debug("gh CLI not found in PATH")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { p in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: GHCommandResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitStatus: p.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                logger.debug("Failed to launch gh: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Resolved once per process — gh's location doesn't change mid-process.
    private static let resolvedGHPath: String? = {
        let candidates = ["/usr/local/bin/gh", "/opt/homebrew/bin/gh", "/usr/bin/gh"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Fall back to PATH search
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/gh"
                if FileManager.default.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }()
}

private struct GHCommandResult {
    let stdout: String
    let stderr: String
    let exitStatus: Int32
}

// MARK: - Supporting types

private struct GHPRViewResult: Codable {
    let number: Int
    let url: String
    let state: String
    let mergeStateStatus: String
    let reviewDecision: String?
    let isDraft: Bool
}

public enum PRStatusError: Error {
    case invalidJSON
}
