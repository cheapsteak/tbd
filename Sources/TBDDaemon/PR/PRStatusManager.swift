import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRStatusManager")

/// In-memory cache of GitHub PR status per worktree.
/// Fetches via `gh api graphql` — one call per `fetchAll`, one `gh pr view` per `refresh`.
public actor PRStatusManager {

    private var cache: [UUID: PRStatus] = [:]

    public init() {}

    // MARK: - Public interface

    public func allStatuses() -> [UUID: PRStatus] { cache }

    public func invalidate(worktreeID: UUID) { cache.removeValue(forKey: worktreeID) }

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
                let signals = await computeRequiredCheckSignals(node: node, repoPath: repoPath)
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

    /// Compute the `(failing, pending)` required-check signals for a batch-matched PR node.
    ///
    /// Cheap aggregate pre-filter, then the SAME per-check query/parse used by `refresh` so
    /// both paths always agree:
    /// - Not OPEN → `(false, false)`, no query.
    /// - Aggregate rollup indicates neither failing nor pending (SUCCESS/nil) → `(false, false)`, no query.
    /// - Otherwise (any non-success aggregate) → run the per-check query and parse both signals.
    private func computeRequiredCheckSignals(node: PRNode, repoPath: String) async -> (failing: Bool, pending: Bool) {
        guard node.state == "OPEN",
              Self.aggregateRollupIsNonSuccess(node.statusCheckRollupState) else {
            return (false, false)
        }
        guard let ownerRepo = Self.parseOwnerRepo(fromURL: node.url) else {
            // Can't query — be conservative and keep red.
            return (true, false)
        }
        return await fetchRequiredCheckSignals(
            owner: ownerRepo.owner,
            name: ownerRepo.name,
            number: node.number,
            repoPath: repoPath
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
                        "--json", "number,url,state,mergeStateStatus,reviewDecision,isDraft"]
            guard let output = await runGH(args: args, repoPath: repoPath),
                  let data = output.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(GHPRViewResult.self, from: data) else {
                continue
            }

            // Fetch the per-check contexts (with `isRequired`) and parse BOTH the failing and
            // pending signals from the SAME data — the identical computation used by `fetchAll`,
            // so the two paths can never disagree.
            let signals: (failing: Bool, pending: Bool)
            if let ownerRepo = Self.parseOwnerRepo(fromURL: obj.url) {
                signals = await fetchRequiredCheckSignals(
                    owner: ownerRepo.owner,
                    name: ownerRepo.name,
                    number: obj.number,
                    repoPath: repoPath
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

    /// Pure parse of a single PR's last-commit status-check contexts, returning BOTH
    /// the failing and pending signals for *required* checks in one pass.
    ///
    /// - failing: any required context with a failing CheckRun conclusion or failing StatusContext state.
    /// - pending: any required context that is a CheckRun still running (status in the pending set and
    ///   no conclusion yet) or a StatusContext in a pending state.
    ///
    /// Expects the JSON shape returned by the `isRequired` GraphQL query
    /// (`data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes`).
    /// Throws `PRStatusError.invalidJSON` if the outer shape can't be parsed.
    static func requiredCheckSignals(fromContextsJSON data: Data) throws -> (failing: Bool, pending: Bool) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let commits = pullRequest["commits"] as? [String: Any],
              let commitNodes = commits["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        var failing = false
        var pending = false

        for commitNode in commitNodes.compactMap({ $0 as? [String: Any] }) {
            guard let commit = commitNode["commit"] as? [String: Any],
                  let rollup = commit["statusCheckRollup"] as? [String: Any],
                  let contexts = rollup["contexts"] as? [String: Any],
                  let contextNodes = contexts["nodes"] as? [Any] else {
                continue
            }

            for context in contextNodes.compactMap({ $0 as? [String: Any] }) {
                guard context["isRequired"] as? Bool == true else { continue }

                let conclusion = context["conclusion"] as? String
                if let conclusion, Self.failingCheckRunConclusions.contains(conclusion) {
                    failing = true
                }
                if let state = context["state"] as? String,
                   Self.failingStatusContextStates.contains(state) {
                    failing = true
                }

                // CheckRun pending: still running AND has no conclusion yet.
                if let status = context["status"] as? String,
                   Self.pendingCheckRunStatuses.contains(status),
                   conclusion == nil {
                    pending = true
                }
                // StatusContext pending.
                if let state = context["state"] as? String,
                   Self.pendingStatusContextStates.contains(state) {
                    pending = true
                }
            }
        }

        return (failing: failing, pending: pending)
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

    /// GraphQL query for a single PR's last-commit check contexts with per-check `isRequired`.
    /// The literal `number` must appear in both `pullRequest(number:)` and `isRequired(pullRequestNumber:)`.
    static func requiredChecksQuery(owner: String, name: String, number: Int) -> String {
        """
        { repository(owner: "\(owner)", name: "\(name)") { pullRequest(number: \(number)) {
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { status conclusion isRequired(pullRequestNumber: \(number)) }
            ... on StatusContext { state isRequired(pullRequestNumber: \(number)) }
          } } } } } } } } }
        """
    }

    /// Like `requiredChecksQuery` but also fetches the aggregate `statusCheckRollup.state`
    /// (for pending detection) — used by the single-PR refresh path.
    static func prCheckDetailQuery(owner: String, name: String, number: Int) -> String {
        """
        { repository(owner: "\(owner)", name: "\(name)") { pullRequest(number: \(number)) {
          commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { status conclusion isRequired(pullRequestNumber: \(number)) }
            ... on StatusContext { state isRequired(pullRequestNumber: \(number)) }
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

    private func runGHGraphQL(repoPath: String) async -> Data? {
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

    /// Single shared per-check query used by BOTH `fetchAll` and `refresh`: query the per-check
    /// `isRequired` data for one PR and parse the `(failing, pending)` signals from the same data.
    /// Conservative: returns `(failing: true, pending: false)` on any failure (gh missing,
    /// non-zero exit, parse failure) so we keep showing red rather than falsely flipping to
    /// green/settled.
    private func fetchRequiredCheckSignals(
        owner: String,
        name: String,
        number: Int,
        repoPath: String
    ) async -> (failing: Bool, pending: Bool) {
        let query = Self.requiredChecksQuery(owner: owner, name: name, number: number)
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              result.exitStatus == 0,
              let data = Self.graphQLOutputData(stdout: result.stdout),
              let signals = try? Self.requiredCheckSignals(fromContextsJSON: data) else {
            logger.debug("isRequired query failed for PR #\(number, privacy: .public); assuming required checks failing")
            return (failing: true, pending: false)
        }
        return signals
    }

    /// Pure extraction of the aggregate `statusCheckRollup.state` from the isRequired query shape.
    static func rollupState(fromContextsJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let commits = pullRequest["commits"] as? [String: Any],
              let commitNodes = commits["nodes"] as? [Any] else {
            return nil
        }
        for commitNode in commitNodes.compactMap({ $0 as? [String: Any] }) {
            if let commit = commitNode["commit"] as? [String: Any],
               let rollup = commit["statusCheckRollup"] as? [String: Any],
               let state = rollup["state"] as? String {
                return state
            }
        }
        return nil
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
}

public enum PRStatusError: Error {
    case invalidJSON
}
