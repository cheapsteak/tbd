import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRStatusManager")

/// In-memory cache of GitHub PR status per worktree.
/// Fetches via `gh api graphql` — one call per `fetchAll`, one `gh pr view` per `refresh`.
public actor PRStatusManager {

    private var cache: [UUID: PRStatus] = [:]

    /// Cached per-worktree classification of which check NAMES are required, keyed by the head
    /// commit SHA it was computed for. Only the `isRequired` classification is stable per commit;
    /// the live `(failing, pending)` signal must be recomputed from fresh check states every poll
    /// (a check's conclusion/status changes on the SAME commit), so it is NEVER cached.
    struct RequiredChecksClassification {
        let headSha: String
        let isRequiredByName: [String: Bool]
    }
    private var requiredChecksCache: [UUID: RequiredChecksClassification] = [:]

    public init() {}

    // MARK: - Public interface

    public func allStatuses() -> [UUID: PRStatus] { cache }

    public func invalidate(worktreeID: UUID) {
        cache.removeValue(forKey: worktreeID)
        requiredChecksCache.removeValue(forKey: worktreeID)
    }

    /// Fetch all viewer PRs in one GraphQL call and update cache for all known worktrees.
    /// worktrees: list of (id, branch, upstreamBranch, worktreePath) for active non-main worktrees.
    public func fetchAll(worktrees: [(id: UUID, branch: String, upstreamBranch: String?, worktreePath: String)]) async {
        guard !worktrees.isEmpty else { return }
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

        // Update cache for worktrees found in the batch.
        // Do NOT clear entries for missing worktrees — the batch query is
        // limited to 100 PRs across all repos, so older PRs may not appear.
        // Those entries may have been populated by a targeted `refresh` call.
        for wt in worktrees {
            let candidates = Self.branchCandidates(
                localBranch: wt.branch,
                upstreamBranch: wt.upstreamBranch
            )
            if let node = candidates.compactMap({ byBranch[$0] }).first {
                let signals = await signalsForBatchNode(worktreeID: wt.id, node: node, repoPath: repoPath)
                cache[wt.id] = PRStatus(
                    number: node.number,
                    url: node.url,
                    state: Self.mapState(
                        ghState: node.state,
                        mergeStateStatus: node.mergeStateStatus,
                        reviewDecision: node.reviewDecision,
                        isDraft: node.isDraft,
                        requiredChecksFailing: signals.failing,
                        requiredChecksPending: signals.pending
                    )
                )
            }
        }
    }

    /// Compute the LIVE `(failing, pending)` required-check signals for a batch-matched PR node.
    ///
    /// Cheap aggregate pre-filter, then live per-check computation:
    /// - Not OPEN → `(false, false)`, no query.
    /// - Aggregate rollup indicates neither failing nor pending (SUCCESS/nil) → `(false, false)`, no query.
    /// - Otherwise (any non-success aggregate) → fetch live check contexts and compute the signals
    ///   from the cached `isRequired` classification (refreshing it only when needed).
    private func signalsForBatchNode(worktreeID: UUID, node: PRNode, repoPath: String) async -> (failing: Bool, pending: Bool) {
        guard node.state == "OPEN",
              Self.aggregateRollupIsNonSuccess(node.statusCheckRollupState) else {
            return (false, false)
        }
        guard let ownerRepo = Self.parseOwnerRepo(fromURL: node.url) else {
            // Can't query — be conservative and keep red.
            return (true, false)
        }
        return await liveCheckSignals(
            worktreeID: worktreeID,
            owner: ownerRepo.owner,
            name: ownerRepo.name,
            number: node.number,
            headSha: node.headRefOid,
            repoPath: repoPath,
            forceClassificationRefresh: false
        )
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
        let candidates = Self.branchCandidates(
            localBranch: branch,
            upstreamBranch: upstreamBranch
        )
        for candidate in candidates {
            let args = ["pr", "view", candidate,
                        "--json", "number,url,state,mergeStateStatus,reviewDecision,isDraft,headRefOid"]
            guard let output = await runGH(args: args, repoPath: repoPath),
                  let data = output.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(GHPRViewResult.self, from: data) else {
                continue
            }

            // Recompute live `(failing, pending)` from fresh check states, force-refreshing the
            // `isRequired` classification since this is the user-initiated path.
            let signals: (failing: Bool, pending: Bool)
            if let ownerRepo = Self.parseOwnerRepo(fromURL: obj.url) {
                signals = await liveCheckSignals(
                    worktreeID: worktreeID,
                    owner: ownerRepo.owner,
                    name: ownerRepo.name,
                    number: obj.number,
                    headSha: obj.headRefOid,
                    repoPath: repoPath,
                    forceClassificationRefresh: true
                )
            } else {
                // Can't query — be conservative and keep red.
                signals = (true, false)
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

            switch mergeStateStatus {
            case "CLEAN", "HAS_HOOKS":
                // Mergeable. A non-required check may be failing without blocking the merge → not red.
                // Yellow only if a *required* check is still pending.
                return requiredChecksPending ? .pending : .mergeable
            case "BLOCKED":
                // Branch protection is blocking: a required check failing/missing, or a required review.
                if requiredChecksPending { return .pending }       // a *required* check is still running
                if requiredChecksFailing { return .checksFailed }  // a *required* check failed → red
                if reviewDecision == "REVIEW_REQUIRED" { return .mergeable } // only blocker is the review → green
                return .blocked
            case "UNSTABLE":
                // Mergeable; only non-required checks failing. Yellow only if a required check is still pending.
                return requiredChecksPending ? .pending : .mergeable
            case "DIRTY", "BEHIND":
                return .blocked
            case "UNKNOWN":
                return .pending
            default:
                return requiredChecksPending ? .pending : .blocked
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
    /// and `StatusContext` shapes. `isRequired` is populated only when the query requested it
    /// (the cheap live-state query omits it).
    struct CheckContext {
        let name: String          // CheckRun.name, or StatusContext.context
        let status: String?       // CheckRun.status (nil for StatusContext)
        let conclusion: String?   // CheckRun.conclusion (nil for StatusContext)
        let state: String?        // StatusContext.state (nil for CheckRun)
        let isRequired: Bool?     // present only when the query requested it
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

    /// Pure parse of a single PR's last-commit status-check contexts into `[CheckContext]`.
    ///
    /// Expects the JSON shape
    /// (`data.repository.pullRequest.commits.nodes[].commit.statusCheckRollup.contexts.nodes`).
    /// For each node: if it has a `name` it's a CheckRun (read `status`/`conclusion`); else its
    /// `context` field names a StatusContext (read `state`). `isRequired` is read as `Bool?`
    /// (absent → nil). Nodes with no name/context are skipped. Iterates all commit nodes.
    /// Throws `PRStatusError.invalidJSON` if the outer shape can't be parsed.
    static func parseCheckContexts(fromJSON data: Data) throws -> [CheckContext] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let commits = pullRequest["commits"] as? [String: Any],
              let commitNodes = commits["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        var result: [CheckContext] = []

        for commitNode in commitNodes.compactMap({ $0 as? [String: Any] }) {
            guard let commit = commitNode["commit"] as? [String: Any],
                  let rollup = commit["statusCheckRollup"] as? [String: Any],
                  let contexts = rollup["contexts"] as? [String: Any],
                  let contextNodes = contexts["nodes"] as? [Any] else {
                continue
            }

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

        return result
    }

    /// Build name → isRequired for every context whose `isRequired` was returned by the query.
    static func classification(from contexts: [CheckContext]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for ctx in contexts where ctx.isRequired != nil {
            map[ctx.name] = ctx.isRequired
        }
        return map
    }

    /// Compute live `(failing, pending)` from check contexts. Required-ness comes ONLY from the
    /// passed map, never from `ctx.isRequired`.
    static func checkSignals(
        contexts: [CheckContext],
        isRequiredByName: [String: Bool]
    ) -> (failing: Bool, pending: Bool) {
        var failing = false
        var pending = false
        for ctx in contexts where isRequiredByName[ctx.name] == true {
            if Self.contextIsFailing(ctx) { failing = true }
            if Self.contextIsPending(ctx) { pending = true }
        }
        return (failing: failing, pending: pending)
    }

    /// Whether the cached `isRequired` classification must be refreshed. True when the head SHA
    /// changed, or any failing/pending context's name isn't yet classified (we only need
    /// classification for checks that could affect the signal).
    static func needsClassificationRefresh(
        contexts: [CheckContext],
        cachedSha: String?,
        currentSha: String,
        isRequiredByName: [String: Bool]
    ) -> Bool {
        if cachedSha != currentSha { return true }
        for ctx in contexts where Self.contextIsFailing(ctx) || Self.contextIsPending(ctx) {
            if isRequiredByName[ctx.name] == nil { return true }
        }
        return false
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

    /// Live check contexts WITHOUT isRequired — run every poll (cheap).
    static func checkContextsQuery(owner: String, name: String, number: Int) -> String {
        """
        { repository(owner: "\(owner)", name: "\(name)") { pullRequest(number: \(number)) {
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name status conclusion }
            ... on StatusContext { context state }
          } } } } } } } } }
        """
    }

    /// Per-check isRequired classification — run only when (re)building the cache.
    static func requiredCheckNamesQuery(owner: String, name: String, number: Int) -> String {
        """
        { repository(owner: "\(owner)", name: "\(name)") { pullRequest(number: \(number)) {
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name isRequired(pullRequestNumber: \(number)) }
            ... on StatusContext { context isRequired(pullRequestNumber: \(number)) }
          } } } } } } } } }
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
        public let headRefOid: String
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
            let headRefOid = node["headRefOid"] as? String ?? ""
            let statusCheckRollup = node["statusCheckRollup"] as? [String: Any]
            let statusCheckRollupState = statusCheckRollup?["state"] as? String
            return PRNode(number: number, url: url, state: state,
                          mergeStateStatus: mergeStateStatus,
                          reviewDecision: reviewDecision,
                          headRefName: headRefName,
                          headRefOid: headRefOid,
                          createdAt: createdAt,
                          isDraft: isDraft,
                          statusCheckRollupState: statusCheckRollupState)
        }
    }

    // MARK: - Shell helpers

    private func runGHGraphQL(repoPath: String) async -> Data? {
        let query = """
        {
          viewer {
            pullRequests(first: 100, states: [OPEN, MERGED, CLOSED],
                         orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes {
                number url state mergeStateStatus reviewDecision headRefName headRefOid createdAt isDraft
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

    /// Fetch the LIVE check contexts (no `isRequired`) for one PR. Returns nil on any failure.
    private func fetchCheckContexts(
        owner: String,
        name: String,
        number: Int,
        repoPath: String
    ) async -> [CheckContext]? {
        let query = Self.checkContextsQuery(owner: owner, name: name, number: number)
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              result.exitStatus == 0,
              let data = Self.graphQLOutputData(stdout: result.stdout),
              let contexts = try? Self.parseCheckContexts(fromJSON: data) else {
            logger.debug("check contexts query failed for PR #\(number, privacy: .public)")
            return nil
        }
        return contexts
    }

    /// Fetch the per-check `isRequired` classification (name → isRequired). Returns nil on failure.
    private func fetchClassification(
        owner: String,
        name: String,
        number: Int,
        repoPath: String
    ) async -> [String: Bool]? {
        let query = Self.requiredCheckNamesQuery(owner: owner, name: name, number: number)
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              result.exitStatus == 0,
              let data = Self.graphQLOutputData(stdout: result.stdout),
              let contexts = try? Self.parseCheckContexts(fromJSON: data) else {
            logger.debug("isRequired classification query failed for PR #\(number, privacy: .public)")
            return nil
        }
        return Self.classification(from: contexts)
    }

    /// Compute live `(failing, pending)` for one PR, using the cached `isRequired` classification
    /// and refreshing that classification only when needed. `forceClassificationRefresh` is true
    /// for the user-initiated refresh path so it always re-reads `isRequired`.
    private func liveCheckSignals(
        worktreeID: UUID,
        owner: String,
        name: String,
        number: Int,
        headSha: String,
        repoPath: String,
        forceClassificationRefresh: Bool
    ) async -> (failing: Bool, pending: Bool) {
        guard let contexts = await fetchCheckContexts(owner: owner, name: name, number: number, repoPath: repoPath) else {
            return (true, false)   // conservative: keep red when we can't read live state
        }
        let cached = requiredChecksCache[worktreeID]
        var map = cached?.isRequiredByName ?? [:]
        let mustRefresh = forceClassificationRefresh
            || Self.needsClassificationRefresh(
                contexts: contexts,
                cachedSha: cached?.headSha,
                currentSha: headSha,
                isRequiredByName: map
            )
        if mustRefresh {
            if let fresh = await fetchClassification(owner: owner, name: name, number: number, repoPath: repoPath) {
                map = fresh
                requiredChecksCache[worktreeID] = RequiredChecksClassification(headSha: headSha, isRequiredByName: map)
            } else {
                // classification query failed — be conservative: treat failing/pending checks as required.
                return (contexts.contains(where: Self.contextIsFailing), contexts.contains(where: Self.contextIsPending))
            }
        }
        return Self.checkSignals(contexts: contexts, isRequiredByName: map)
    }

    private func runGH(args: [String], repoPath: String) async -> String? {
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

    private func runGHResult(args: [String], repoPath: String) async -> GHCommandResult? {
        guard let ghPath = findGH() else {
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

    private func findGH() -> String? {
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
    }
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
    let headRefOid: String
}

public enum PRStatusError: Error {
    case invalidJSON
}
