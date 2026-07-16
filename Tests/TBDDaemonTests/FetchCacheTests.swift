import Foundation
import Testing
@testable import TBDDaemonLib

/// Mutable clock for test time control + fetch call counter, both isolated for concurrency safety.
private actor FetchCounter {
    private(set) var count = 0
    private(set) var lastRepoPath: String?
    private(set) var lastBranch: String?

    func increment(for repoPath: String, branch: String) -> Int {
        count += 1
        lastRepoPath = repoPath
        lastBranch = branch
        return count
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { self.value = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

struct FetchCacheTests {

    // MARK: - (a) Cold start: first call invokes the fetch

    @Test func coldStartInvokesFetch() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let counter = FetchCounter()
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { repoPath, branch, _ in
            _ = await counter.increment(for: repoPath, branch: branch)
        }

        #expect(await counter.count == 0)

        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 1)
        #expect(await counter.lastRepoPath == "/repo/a")
        #expect(await counter.lastBranch == "main")
    }

    // MARK: - (b) Within TTL: second call SKIPPED (fetch not called again)

    @Test func withinTTLSkipsFetch() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let counter = FetchCounter()
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { repoPath, branch, _ in
            _ = await counter.increment(for: repoPath, branch: branch)
        }

        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 1)

        // Advance time within TTL: fetch should be skipped
        clock.advance(by: 30)
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 1, "fetch should not be called within TTL")
    }

    // MARK: - (c) Past TTL: after advancing clock beyond TTL, refetch

    @Test func pastTTLRefetches() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let counter = FetchCounter()
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { repoPath, branch, _ in
            _ = await counter.increment(for: repoPath, branch: branch)
        }

        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 1)

        // Advance time past TTL: fetch should happen again
        clock.advance(by: 61)
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 2, "fetch should be called after TTL expires")
    }

    // MARK: - (d) Failure path: when fetch throws, success NOT recorded (retry on next call)

    @Test func failureDoesNotRecordSuccess() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let counter = FetchCounter()
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { repoPath, branch, _ in
            _ = await counter.increment(for: repoPath, branch: branch)
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "mock fetch failure"])
        }

        // First call fails
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 1)

        // Within TTL, but failure wasn't recorded → retry should happen
        clock.advance(by: 30)
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 2, "fetch should retry after failure (failure not cached)")
    }

    @Test func failureDoesNotThrow() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { _, _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "mock fetch failure"])
        }

        // fetchIfNeeded is best-effort; fetch failure must not throw
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        // If we get here without crashing, test passes
        #expect(Bool(true))
    }

    // MARK: - (e) Singleflight: N concurrent calls for same repo share ONE in-flight fetch

    @Test func singleflightSharesInFlightFetch() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let counter = FetchCounter()
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { repoPath, branch, _ in
            _ = await counter.increment(for: repoPath, branch: branch)
            // Simulate a slow fetch so concurrent calls overlap
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        // Launch 5 concurrent calls for the same repo
        async let call1: Void = cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        async let call2: Void = cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        async let call3: Void = cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        async let call4: Void = cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        async let call5: Void = cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")

        _ = await (call1, call2, call3, call4, call5)

        #expect(await counter.count == 1, "5 concurrent calls should share 1 in-flight fetch, not 5 parallel fetches")
    }

    // MARK: - Additional: Multiple repos are independent

    @Test func multipleReposAreIndependent() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let counter = FetchCounter()
        let cache = FetchCache(ttl: 60, now: { clock.now() }) { repoPath, branch, _ in
            _ = await counter.increment(for: repoPath, branch: branch)
        }

        // Fetch two different repos
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        await cache.fetchIfNeeded(repoPath: "/repo/b", branch: "main")
        #expect(await counter.count == 2)

        // Advance time within TTL
        clock.advance(by: 30)

        // Calling /repo/a again: should be cached
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        #expect(await counter.count == 2)

        // Calling /repo/b again: should be cached
        await cache.fetchIfNeeded(repoPath: "/repo/b", branch: "main")
        #expect(await counter.count == 2)

        // Advance past TTL
        clock.advance(by: 31)

        // Both should refetch
        await cache.fetchIfNeeded(repoPath: "/repo/a", branch: "main")
        await cache.fetchIfNeeded(repoPath: "/repo/b", branch: "main")
        #expect(await counter.count == 4)
    }
}
