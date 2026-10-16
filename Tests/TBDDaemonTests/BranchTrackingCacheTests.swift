import Foundation
import Testing
@testable import TBDDaemonLib

/// Mutable clock + fetch-call counter, both isolated for concurrency safety.
private actor FetchCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { self.value = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

struct BranchTrackingCacheTests {

    @Test func freshHitDoesNotRefetch() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        let first = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment()
            return "main"
        }
        #expect(first == "main")
        #expect(await counter.count == 1)

        // Within TTL: served from cache, fetch NOT called again.
        clock.advance(by: 59)
        let second = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment()
            return "main"
        }
        #expect(second == "main")
        #expect(await counter.count == 1)
    }

    @Test func expiryRefetches() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        _ = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return "main"
        }
        #expect(await counter.count == 1)

        // Past TTL: refetch.
        clock.advance(by: 61)
        let again = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return "develop"
        }
        #expect(again == "develop")
        #expect(await counter.count == 2)
    }

    @Test func invalidateForcesRefetch() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        _ = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return "main"
        }
        #expect(await counter.count == 1)

        await cache.invalidate(worktreePath: "/wt")

        // Still within TTL, but invalidated → refetch.
        let after = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return "main"
        }
        #expect(after == "main")
        #expect(await counter.count == 2)
    }

    @Test func nilValuesAreCached() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        let first = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return nil
        }
        #expect(first == nil)
        #expect(await counter.count == 1)

        // A cached nil must NOT trigger a refetch within the TTL.
        clock.advance(by: 30)
        let second = await cache.upstreamBranchName(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return "shouldNotBeReturned"
        }
        #expect(second == nil)
        #expect(await counter.count == 1)
    }

    @Test func invalidateAllClearsEveryEntry() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        _ = await cache.upstreamBranchName(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return "main"
        }
        _ = await cache.upstreamBranchName(worktreePath: "/b", branch: "y") {
            _ = await counter.increment(); return "main"
        }
        #expect(await counter.count == 2)

        await cache.invalidateAll()

        _ = await cache.upstreamBranchName(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return "main"
        }
        #expect(await counter.count == 3)
    }

    @Test func retainDropsEntriesOutsideActiveSet() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        // Seed entries for two worktree paths A and B.
        _ = await cache.upstreamBranchName(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return "main"
        }
        _ = await cache.upstreamBranchName(worktreePath: "/b", branch: "y") {
            _ = await counter.increment(); return "main"
        }
        #expect(await counter.count == 2)

        // Retain only A: B's entry is dropped, A's is kept (still within TTL).
        await cache.retain(active: [(worktreePath: "/a", branch: "x")])

        // A still served from cache → fetch NOT called.
        let aHit = await cache.upstreamBranchName(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return "shouldNotBeReturned"
        }
        #expect(aHit == "main")
        #expect(await counter.count == 2)

        // B was dropped → refetch.
        let bMiss = await cache.upstreamBranchName(worktreePath: "/b", branch: "y") {
            _ = await counter.increment(); return "develop"
        }
        #expect(bMiss == "develop")
        #expect(await counter.count == 3)
    }

    // MARK: - @{push} resolution

    @Test func pushBranchIsCachedWithinTTLAndRefetchedAfter() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        let first = await cache.pushBranch(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return .resolved("renamed-on-remote")
        }
        #expect(first == .resolved("renamed-on-remote"))
        #expect(await counter.count == 1)

        clock.advance(by: 59)
        let cached = await cache.pushBranch(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return .noPushDestination
        }
        #expect(cached == .resolved("renamed-on-remote"))
        #expect(await counter.count == 1)

        clock.advance(by: 2)
        let refetched = await cache.pushBranch(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return .noPushDestination
        }
        #expect(refetched == .noPushDestination)
        #expect(await counter.count == 2)
    }

    @Test func pushAndUpstreamEntriesAreIndependentButPrunedTogether() async {
        // One key, two facts: `retain` must not leave a push entry behind for a
        // worktree whose upstream entry it just dropped.
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        _ = await cache.upstreamBranchName(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return "main"
        }
        _ = await cache.pushBranch(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return .noPushDestination
        }
        #expect(await counter.count == 2)

        await cache.retain(active: [(worktreePath: "/b", branch: "y")])

        _ = await cache.pushBranch(worktreePath: "/a", branch: "x") {
            _ = await counter.increment(); return .lookupFailed
        }
        #expect(await counter.count == 3)
    }

    @Test func invalidateDropsPushEntriesToo() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()

        _ = await cache.pushBranch(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return .noPushDestination
        }
        await cache.invalidate(worktreePath: "/wt")
        _ = await cache.pushBranch(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return .noPushDestination
        }
        #expect(await counter.count == 2)

        await cache.invalidateAll()
        _ = await cache.pushBranch(worktreePath: "/wt", branch: "feat") {
            _ = await counter.increment(); return .noPushDestination
        }
        #expect(await counter.count == 3)
    }

    // MARK: - Repository snapshots

    private static let snapshot = BranchTrackingSnapshot.parse(
        config: "branch.feat.merge\nrefs/heads/main\0",
        refListing: "refs/heads/feat\0refs/remotes/origin/feat\nrefs/remotes/origin/feat\0\n")

    @Test func snapshotIsReadOncePerRepoPerTTL() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()
        let load: @Sendable () async -> BranchTrackingSnapshot? = {
            _ = await counter.increment(); return Self.snapshot
        }

        #expect(await cache.snapshot(repoPath: "/repo", load: load) == Self.snapshot)
        clock.advance(by: 59)
        #expect(await cache.snapshot(repoPath: "/repo", load: load) == Self.snapshot)
        #expect(await counter.count == 1)

        // Another repo is its own read.
        _ = await cache.snapshot(repoPath: "/other", load: load)
        #expect(await counter.count == 2)

        clock.advance(by: 2)
        _ = await cache.snapshot(repoPath: "/repo", load: load)
        #expect(await counter.count == 3)
    }

    @Test func aFailedSnapshotIsCachedForTheTTL() async {
        // Each row of a pass asks for the snapshot; a failing repo must cost one
        // attempt per window, not one per row.
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()
        let failing: @Sendable () async -> BranchTrackingSnapshot? = {
            _ = await counter.increment(); return nil
        }

        for _ in 0..<5 {
            #expect(await cache.snapshot(repoPath: "/repo", load: failing) == nil)
        }
        #expect(await counter.count == 1)

        clock.advance(by: 61)
        let recovered = await cache.snapshot(repoPath: "/repo") {
            _ = await counter.increment(); return Self.snapshot
        }
        #expect(recovered == Self.snapshot)
        #expect(await counter.count == 2)
    }

    @Test func retainDropsOnlyExpiredSnapshots() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()
        let load: @Sendable () async -> BranchTrackingSnapshot? = {
            _ = await counter.increment(); return Self.snapshot
        }
        _ = await cache.snapshot(repoPath: "/old", load: load)
        clock.advance(by: 30)
        _ = await cache.snapshot(repoPath: "/fresh", load: load)
        clock.advance(by: 31)

        // A snapshot is keyed by repo, not by row, so `retain` keeps a fresh
        // one whatever rows it is handed, and drops one past its TTL.
        await cache.retain(active: [])
        _ = await cache.snapshot(repoPath: "/fresh", load: load)
        #expect(await counter.count == 2)
        _ = await cache.snapshot(repoPath: "/old", load: load)
        #expect(await counter.count == 3)
    }

    @Test func invalidateDropsSnapshots() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = BranchTrackingCache(ttl: 60, now: { clock.now() })
        let counter = FetchCounter()
        let load: @Sendable () async -> BranchTrackingSnapshot? = {
            _ = await counter.increment(); return Self.snapshot
        }
        _ = await cache.snapshot(repoPath: "/repo", load: load)
        await cache.invalidate(worktreePath: "/repo")
        _ = await cache.snapshot(repoPath: "/repo", load: load)
        #expect(await counter.count == 2)

        await cache.invalidateAll()
        _ = await cache.snapshot(repoPath: "/repo", load: load)
        #expect(await counter.count == 3)
    }
}
