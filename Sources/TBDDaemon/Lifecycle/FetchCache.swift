import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "fetchCache")

/// Named constant for the fetch TTL (time-to-live) — fetches within this window are skipped.
public let fetchCacheTTL: TimeInterval = 60

/// Named constant for the fetch timeout — a hung fetch won't stall creation.
public let fetchTimeout: Duration = .seconds(20)

/// Coalesces fetch operations per repo using a TTL cache + singleflight.
/// If a fetch for a repo succeeded within the TTL window, the next fetch is skipped.
/// Multiple concurrent fetches for the same repo share a single in-flight operation.
public actor FetchCache {
    private struct CacheEntry {
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let performFetch: @Sendable (String, String, Duration) async throws -> Void

    // Cache and singleflight keyed by repoPath. Since callers always pass the repo's
    // default branch (which is stable per repo), repoPath uniquely determines the branch.
    private var lastFetchTime: [String: CacheEntry] = [:]
    private var inFlightFetches: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - ttl: How long a cached fetch stays fresh, in seconds.
    ///   - now: Clock seam for tests; defaults to wall-clock `Date()`.
    ///   - performFetch: The actual fetch operation; defaults to `gitManager.fetch(branch:)`.
    ///     Closure receives (repoPath, branch, timeout).
    public init(
        ttl: TimeInterval = fetchCacheTTL,
        now: @Sendable @escaping () -> Date = { Date() },
        performFetch: @Sendable @escaping (String, String, Duration) async throws -> Void = { repoPath, branch, timeout in
            let manager = GitManager()
            try await manager.fetch(repoPath: repoPath, branch: branch, timeout: timeout)
        }
    ) {
        self.ttl = ttl
        self.now = now
        self.performFetch = performFetch
    }

    /// Fetch the repo's default branch if no successful fetch exists within the TTL window.
    /// Uses singleflight so concurrent calls for the same repo share one in-flight fetch.
    /// Fetch failures do NOT update the cache, so retries can happen on next call.
    /// - Parameters:
    ///   - repoPath: The path to the repo being fetched.
    ///   - branch: The repo's default branch (e.g., "main" or "master"). Fetch is scoped to this branch only.
    ///   - timeout: How long the fetch is allowed to run; defaults to `fetchTimeout` (20s).
    public func fetchIfNeeded(
        repoPath: String,
        branch: String,
        timeout: Duration = fetchTimeout
    ) async {
        // Check if we have a recent successful fetch within TTL
        if let entry = lastFetchTime[repoPath] {
            let elapsed = now().timeIntervalSince(entry.fetchedAt)
            if elapsed < ttl {
                logger.debug("fetch coalesced for \(repoPath, privacy: .public) (cached \(Int(elapsed))s ago)")
                return
            }
        }

        // Singleflight: if a fetch is already in-flight for this repo, wait for it
        if let inFlight = inFlightFetches[repoPath] {
            logger.debug("fetch singleflight for \(repoPath, privacy: .public) — waiting on in-flight")
            await inFlight.value
            return
        }

        // Launch the fetch and record it
        let fetchTask = Task {
            do {
                try await performFetch(repoPath, branch, timeout)
                logger.debug("fetch succeeded for \(repoPath, privacy: .public)")
                // Record success only on completion
                await self.recordSuccessAsync(repoPath: repoPath)
            } catch {
                logger.debug("fetch timeout or error for \(repoPath, privacy: .public): \(error, privacy: .public)")
                // Best-effort: don't record failure, so retries can happen
            }
        }

        inFlightFetches[repoPath] = fetchTask
        await fetchTask.value
        inFlightFetches.removeValue(forKey: repoPath)
    }

    private func recordSuccess(repoPath: String) {
        lastFetchTime[repoPath] = CacheEntry(fetchedAt: now())
    }

    private func recordSuccessAsync(repoPath: String) async {
        recordSuccess(repoPath: repoPath)
    }
}
