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

struct UpstreamBranchCacheTests {

    @Test func freshHitDoesNotRefetch() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cache = UpstreamBranchCache(ttl: 60, now: { clock.now() })
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
        let cache = UpstreamBranchCache(ttl: 60, now: { clock.now() })
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
        let cache = UpstreamBranchCache(ttl: 60, now: { clock.now() })
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
        let cache = UpstreamBranchCache(ttl: 60, now: { clock.now() })
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
        let cache = UpstreamBranchCache(ttl: 60, now: { clock.now() })
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
        let cache = UpstreamBranchCache(ttl: 60, now: { clock.now() })
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
}
