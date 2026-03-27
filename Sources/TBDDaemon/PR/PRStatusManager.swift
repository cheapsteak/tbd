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
    /// worktrees: list of (id, branch, repoPath) for active non-main worktrees.
    public func fetchAll(worktrees: [(id: UUID, branch: String, repoPath: String)]) async {
        guard !worktrees.isEmpty else { return }
        // All worktrees share one repo; any path works as gh's working directory for auth.
        let repoPath = worktrees[0].repoPath

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
            if let node = byBranch[wt.branch] {
                cache[wt.id] = PRStatus(
                    number: node.number,
                    url: node.url,
                    state: Self.mapState(ghState: node.state, mergeStateStatus: node.mergeStateStatus, reviewDecision: node.reviewDecision)
                )
            }
        }
    }

    /// Refresh a single worktree using `gh pr view`. Used for on-select refresh.
    public func refresh(worktreeID: UUID, branch: String, repoPath: String) async -> PRStatus? {
        let args = ["pr", "view", branch,
                    "--json", "number,url,state,mergeStateStatus,reviewDecision",
                    "-R", "."]
        guard let output = await runGH(args: args, repoPath: repoPath),
              let data = output.data(using: .utf8),
              let obj = try? JSONDecoder().decode(GHPRViewResult.self, from: data) else {
            // gh exited non-zero or parse failed — leave cache unchanged
            return cache[worktreeID]
        }

        let status = PRStatus(
            number: obj.number,
            url: obj.url,
            state: Self.mapState(ghState: obj.state,
                                 mergeStateStatus: obj.mergeStateStatus,
                                 reviewDecision: obj.reviewDecision ?? "")
        )
        cache[worktreeID] = status
        return status
    }

    /// For tests only: seed a cache entry directly.
    public func seedForTesting(worktreeID: UUID, status: PRStatus) {
        cache[worktreeID] = status
    }

    // MARK: - State mapping (internal but static for testability)

    public static func mapState(ghState: String, mergeStateStatus: String, reviewDecision: String = "") -> PRMergeableState {
        switch ghState {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default:
            if reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
            return mergeStateStatus == "CLEAN" ? .mergeable : .open
        }
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

    // MARK: - JSON parsing (internal but static for testability)

    public struct PRNode: Sendable {
        public let number: Int
        public let url: String
        public let state: String
        public let mergeStateStatus: String
        public let reviewDecision: String   // "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", or ""
        public let headRefName: String
        public let createdAt: String        // ISO 8601, e.g. "2026-03-24T15:58:27Z"
    }

    public static func parsePRNodes(from data: Data) throws -> [PRNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let viewer = dataObj["viewer"] as? [String: Any],
              let prs = viewer["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [[String: Any]] else {
            throw PRStatusError.invalidJSON
        }

        return nodes.compactMap { node -> PRNode? in
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String,
                  let mergeStateStatus = node["mergeStateStatus"] as? String,
                  let headRefName = node["headRefName"] as? String,
                  let createdAt = node["createdAt"] as? String,
                  headRefName.hasPrefix("tbd/") else { return nil }
            let reviewDecision = node["reviewDecision"] as? String ?? ""
            return PRNode(number: number, url: url, state: state,
                          mergeStateStatus: mergeStateStatus,
                          reviewDecision: reviewDecision,
                          headRefName: headRefName,
                          createdAt: createdAt)
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
                number url state mergeStateStatus reviewDecision headRefName createdAt
              }
            }
          }
        }
        """
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let output = await runGH(args: args, repoPath: repoPath) else { return nil }
        return output.data(using: .utf8)
    }

    private func runGH(args: [String], repoPath: String) async -> String? {
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
                if p.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    logger.debug("gh exited \(p.terminationStatus): \(errStr)")
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
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

// MARK: - Supporting types

private struct GHPRViewResult: Codable {
    let number: Int
    let url: String
    let state: String
    let mergeStateStatus: String
    let reviewDecision: String?
}

public enum PRStatusError: Error {
    case invalidJSON
}
