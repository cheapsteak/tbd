import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// MARK: - Test clock

/// Virtual `PollerClock`. `advance(by:)` moves wall time forward and resolves
/// every in-flight `sleep(until:)` whose deadline it crossed.
///
/// **Arming is a signal, not a poll.**
/// ``requireSleeperArmed(count:timeout:sourceLocation:)`` parks on a
/// continuation that `sleep(until:)` claims inside the critical section that
/// registers the sleeper, and resumes once the lock is released: the handshake
/// `EventDrivenTestClock` gives a `Clock<Duration>` seam (`Tests/CLAUDE.md`,
/// "The event-driven clock"), here for the Date-based `PollerClock` seam that
/// clock cannot satisfy. The loops driven through this clock
/// (`ClaudeUsagePoller`, `LimitResumeScheduler`) park on exactly one sleeper
/// whenever they have future work and are not paused, and sleep nowhere else
/// outside store-error retries, so "a sleeper is armed" means "the loop has
/// finished everything the last advance made due".
///
/// **`advance(by:)` does no yielding.** It resolves due sleepers and returns,
/// so a positive assertion about what a resumed loop did must first wait for
/// the loop's next arming, or for the effect itself.
///
/// A sleep whose deadline has already passed returns at once without
/// registering, as `SystemPollerClock` does. A sleep whose task was cancelled
/// before it parked throws instead of registering, so a sleeper that `wake()`
/// cancelled can never linger and satisfy a later arming wait.
final class TestPollerClock: PollerClock, @unchecked Sendable {
    /// Per-sleep state shared by the continuation body and the cancellation
    /// handler, which can run in either order. Guarded by `lock`.
    private final class SleepBox: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        var isSettled = false
        var isCancelledEarly = false
    }

    private struct Sleeper {
        let deadline: Date
        let box: SleepBox
    }

    /// A parked arming waiter. Settled exactly once: by a registration that
    /// satisfies it (`true`), or by its hang guard or a cancellation (`false`).
    /// Guarded by `lock`.
    private final class ArmingWait: @unchecked Sendable {
        let count: Int
        var continuation: CheckedContinuation<Bool, Never>?
        var isSettled = false
        init(count: Int) { self.count = count }
    }

    private let lock = NSLock()
    private var currentNow: Date
    private var sleepers: [Sleeper] = []
    private var armingWaits: [ArmingWait] = []

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentNow = start
    }

    func now() -> Date {
        lock.withLock { currentNow }
    }

    /// How many tasks are parked on this clock right now. A snapshot.
    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Date) async throws {
        if lock.withLock({ currentNow >= deadline }) { return }
        let box = SleepBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if box.isCancelledEarly {
                    // Cancellation beat the park: register nothing, signal nobody.
                    box.isSettled = true
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                box.continuation = cont
                sleepers.append(Sleeper(deadline: deadline, box: box))
                let registered = sleepers.count
                let released = armingWaits.filter { $0.count <= registered }
                armingWaits.removeAll { $0.count <= registered }
                var waiters: [CheckedContinuation<Bool, Never>] = []
                for wait in released {
                    wait.isSettled = true
                    if let waiter = wait.continuation { waiters.append(waiter) }
                    wait.continuation = nil
                }
                lock.unlock()
                // Outside the lock: a waiter resumes into arbitrary test code.
                for waiter in waiters { waiter.resume(returning: true) }
            }
        } onCancel: {
            lock.lock()
            guard !box.isSettled else {
                lock.unlock()
                return
            }
            guard let cont = box.continuation else {
                // Not parked yet: the body runs next and throws instead.
                box.isCancelledEarly = true
                lock.unlock()
                return
            }
            box.isSettled = true
            box.continuation = nil
            sleepers.removeAll { $0.box === box }
            lock.unlock()
            cont.resume(throwing: CancellationError())
        }
    }

    /// Advance virtual time, resolving every sleeper whose deadline passed.
    func advance(by interval: TimeInterval) async {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            currentNow = currentNow.addingTimeInterval(interval)
            let now = currentNow
            let fired = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            var continuations: [CheckedContinuation<Void, Error>] = []
            for sleeper in fired {
                sleeper.box.isSettled = true
                if let cont = sleeper.box.continuation { continuations.append(cont) }
                sleeper.box.continuation = nil
            }
            return continuations
        }
        for cont in due { cont.resume() }
    }

    /// Waits until at least `count` tasks are parked on this clock, and throws
    /// a named diagnostic if they are not within `timeout`.
    ///
    /// Returns at once if they already are; otherwise parks until the
    /// registration that reaches `count` releases it. `timeout` is a hang guard
    /// only: one real sleep that a passing run cancels unfired. It defaults to
    /// `TestDeadlines.saturatedPass` because the arming is several hops from
    /// the test body: the loop under test runs in its own unstructured task and
    /// crosses GRDB's writer queue before it sleeps. On cancellation the wait
    /// throws `CancellationError`, so attribution stays with whatever cancelled.
    func requireSleeperArmed(
        count: Int = 1,
        timeout: Duration = TestDeadlines.saturatedPass,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let wait = ArmingWait(count: count)
        let hangGuard = Task { [self] in
            try? await Task.sleep(for: timeout)
            expire(wait)
        }
        defer { hangGuard.cancel() }
        let armed: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if wait.isSettled {
                    // The hang guard or a cancellation beat the park.
                    lock.unlock()
                    cont.resume(returning: false)
                    return
                }
                if sleepers.count >= count {
                    wait.isSettled = true
                    lock.unlock()
                    cont.resume(returning: true)
                    return
                }
                wait.continuation = cont
                armingWaits.append(wait)
                lock.unlock()
            }
        } onCancel: {
            expire(wait)
        }
        if armed { return }
        try Task.checkCancellation()
        throw PollerClockNoSleeperArmed(
            expected: count, observed: sleeperCount, timeout: timeout,
            virtualNow: now(), sourceLocation: sourceLocation)
    }

    /// Settles `wait` as not armed, unless a registration settled it first.
    private func expire(_ wait: ArmingWait) {
        lock.lock()
        guard !wait.isSettled else {
            lock.unlock()
            return
        }
        wait.isSettled = true
        let cont = wait.continuation
        wait.continuation = nil
        armingWaits.removeAll { $0 === wait }
        lock.unlock()
        cont?.resume(returning: false)
    }
}

/// Thrown by ``TestPollerClock/requireSleeperArmed(count:timeout:sourceLocation:)``.
/// Observed state on the primary failure line, plus the call site, because a
/// thrown error is attributed to the test function rather than to the wait.
struct PollerClockNoSleeperArmed: Error, CustomStringConvertible {
    let expected: Int
    let observed: Int
    let timeout: Duration
    let virtualNow: Date
    let sourceLocation: SourceLocation

    var description: String {
        """
        TestPollerClock: expected at least \(expected) task(s) parked on the clock within \
        \(timeout); observed \(observed), virtual now = \(virtualNow). The loop under test \
        never re-armed: it went idle, is wedged, or is still working.
        The wait that gave up: \(sourceLocation.fileID):\(sourceLocation.line).
        """
    }
}

// MARK: - Mock fetcher

final class MockUsageFetcher: ClaudeUsageFetcher, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockUsageFetcher")
    private var queues: [String: [ClaudeUsageStatus]] = [:]
    private var defaults: ClaudeUsageStatus
    private var _calls: [String] = []

    init(default defaultResult: ClaudeUsageStatus) {
        self.defaults = defaultResult
    }

    func enqueue(token: String, _ status: ClaudeUsageStatus) {
        queue.sync { queues[token, default: []].append(status) }
    }

    func callCount(for token: String) -> Int {
        queue.sync { _calls.filter { $0 == token }.count }
    }

    var totalCalls: Int {
        queue.sync { _calls.count }
    }

    func fetchUsage(token: String) async -> ClaudeUsageStatus {
        queue.sync {
            _calls.append(token)
            if var q = queues[token], !q.isEmpty {
                let s = q.removeFirst()
                queues[token] = q
                return s
            }
            return defaults
        }
    }
}

// MARK: - Broadcast collector

final class BroadcastCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BroadcastCollector")
    private var _rows: [ModelProfileUsage] = []
    var rows: [ModelProfileUsage] { queue.sync { _rows } }
    func record(_ row: ModelProfileUsage) { queue.sync { _rows.append(row) } }
}

// MARK: - Helpers

private func sampleUsageOK() -> ClaudeUsageResult {
    ClaudeUsageResult(
        fiveHourPct: 0.25,
        sevenDayPct: 0.10,
        fiveHourResetsAt: Date(timeIntervalSince1970: 2_000_000_000),
        sevenDayResetsAt: Date(timeIntervalSince1970: 2_100_000_000)
    )
}

/// Build a poller with deterministic stagger=0 (no jitter) so tests are stable.
private func makePoller(
    db: TBDDatabase,
    fetcher: ClaudeUsageFetcher,
    clock: TestPollerClock,
    keychain: @escaping @Sendable (String) throws -> String? = { id in id },
    broadcast: @escaping @Sendable (ModelProfileUsage) -> Void = { _ in },
    stagger: TimeInterval = 0
) -> ClaudeUsagePoller {
    ClaudeUsagePoller(
        profiles: db.modelProfiles,
        usage: db.modelProfileUsage,
        keychain: keychain,
        fetcher: fetcher,
        clock: clock,
        broadcast: broadcast,
        staggerProvider: { stagger }
    )
}

// MARK: - Tests

/// Every step waits for the loop to re-arm on the clock instead of sleeping a
/// fixed time: the poller sleeps on exactly one deadline whenever it has an
/// eligible profile and is not paused, so once it is parked again, every tick
/// the last advance (or poke) made due has finished. With stagger 0 the first
/// deadline is "now", which the clock returns without parking, so the first
/// arming after `start()` already follows the first tick.
@Suite("ClaudeUsagePoller")
struct ClaudeUsagePollerTests {

    @Test func happyPathStaggerAndCadence() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        let b = try await db.modelProfiles.create(name: "B", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock, stagger: 30)

        await poller.start()
        try await clock.requireSleeperArmed()

        // Parked on the 30s stagger: no calls have happened.
        #expect(fetcher.totalCalls == 0)

        // Advance past the 30s stagger.
        await clock.advance(by: 31)
        try await clock.requireSleeperArmed()

        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        // Advance another 30 minutes — second tick.
        await clock.advance(by: 30 * 60 + 1)
        try await clock.requireSleeperArmed()

        #expect(fetcher.callCount(for: a.id.uuidString) == 2)
        #expect(fetcher.callCount(for: b.id.uuidString) == 2)

        await poller.stop()
    }

    @Test func dedupeWithinSixtySeconds() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        let clock = TestPollerClock()

        // Pre-populate a fresh usage row (fetched 30s ago).
        let prePop = ModelProfileUsage(
            profileID: a.id,
            fiveHourPct: 0.5,
            sevenDayPct: 0.2,
            fiveHourResetsAt: Date(timeIntervalSince1970: 1_900_000_000),
            sevenDayResetsAt: Date(timeIntervalSince1970: 1_950_000_000),
            fetchedAt: clock.now().addingTimeInterval(-30),
            lastStatus: "ok"
        )
        try await db.modelProfileUsage.upsert(prePop)

        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        // First tick fires immediately (stagger=0); the arming follows it.
        await poller.start()
        try await clock.requireSleeperArmed()

        // Dedupe hit — no fetch.
        #expect(fetcher.callCount(for: a.id.uuidString) == 0)

        await poller.stop()
    }

    @Test func http429BackoffThenRecovery() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        // First call: 429. Subsequent: ok.
        fetcher.enqueue(token: a.id.uuidString, .http429)

        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        // First tick fires immediately (stagger=0) → 429.
        await poller.start()
        try await clock.requireSleeperArmed()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        // After 30 minutes nothing should fire (backoff is 60 min): the loop
        // stays parked on the backoff deadline.
        await clock.advance(by: 30 * 60)
        #expect(clock.sleeperCount == 1)
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        // After another 30 minutes (total 60 min) it fires again — this time .ok (default).
        await clock.advance(by: 30 * 60 + 1)
        try await clock.requireSleeperArmed()
        #expect(fetcher.callCount(for: a.id.uuidString) == 2)

        // After this success, backoff should be cleared. 30 more minutes should fire again.
        await clock.advance(by: 30 * 60 + 1)
        try await clock.requireSleeperArmed()
        #expect(fetcher.callCount(for: a.id.uuidString) == 3)

        await poller.stop()
    }

    @Test func http401PermanentExclusion() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        // A healthy profile keeps the loop parked on the clock after A drops
        // out, so its arming is the barrier that the loop has been through the
        // post-401 refresh. Without it the loop goes idle, which nothing can
        // observe, and "no further calls" would be a guess about timing.
        let healthy = try await db.modelProfiles.create(name: "Healthy", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        fetcher.enqueue(token: a.id.uuidString, .http401)

        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)
        await poller.start()
        try await clock.requireSleeperArmed()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: healthy.id.uuidString) == 1)

        // Advance well past the cadence — no further calls because token excluded.
        await clock.advance(by: 60 * 60)
        try await clock.requireSleeperArmed()
        #expect(fetcher.callCount(for: healthy.id.uuidString) == 2)
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        await poller.stop()
    }

    @Test func oauthProfilesNotPolled() async throws {
        let db = try TBDDatabase(inMemory: true)
        let oauthProfile = try await db.modelProfiles.create(name: "Oauth", kind: .oauth)
        let apiKeyProfile = try await db.modelProfiles.create(name: "Api", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        await poller.start()
        try await clock.requireSleeperArmed()

        // OAuth profiles don't store TBD-side secrets, so they are not polled
        #expect(fetcher.callCount(for: oauthProfile.id.uuidString) == 0)
        // API key profiles store secrets and are polled
        #expect(fetcher.callCount(for: apiKeyProfile.id.uuidString) == 1)

        await poller.stop()
    }

    @Test func focusPauseAndResume() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        let b = try await db.modelProfiles.create(name: "B", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        await poller.start()
        try await clock.requireSleeperArmed()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        // Lose focus.
        await poller.onFocusChanged(isForeground: false)
        // Advance 11 minutes — past the 10-min focus pause threshold but not past the 30-min cadence.
        await clock.advance(by: 11 * 60)

        // No deadline passed, so the loop is still parked; no new fetches.
        #expect(clock.sleeperCount == 1)
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        // Regain focus → immediate pokeAll. Its wake cancels the parked sleep,
        // so the next arming follows the poked ticks.
        await poller.onFocusChanged(isForeground: true)
        try await clock.requireSleeperArmed()

        #expect(fetcher.callCount(for: a.id.uuidString) == 2)
        #expect(fetcher.callCount(for: b.id.uuidString) == 2)

        await poller.stop()
    }

    @Test func pokeAllFiresEverythingEligible() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        let b = try await db.modelProfiles.create(name: "B", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        // Use big stagger so first tick is far in the future.
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock, stagger: 30 * 60)

        await poller.start()
        try await clock.requireSleeperArmed()
        // Verify nothing fired yet.
        #expect(fetcher.totalCalls == 0)

        // The poke's wake cancels the parked sleep, so the next arming
        // follows the poked ticks.
        await poller.pokeAll()
        try await clock.requireSleeperArmed()

        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        await poller.stop()
    }

    @Test func broadcastCalledOnEachWrite() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        // First .ok, then .http429.
        fetcher.enqueue(token: a.id.uuidString, .ok(sampleUsageOK()))
        fetcher.enqueue(token: a.id.uuidString, .http429)

        let collector = BroadcastCollector()
        let poller = makePoller(
            db: db, fetcher: fetcher, clock: clock,
            broadcast: { row in collector.record(row) }
        )

        await poller.start()
        try await clock.requireSleeperArmed()

        #expect(collector.rows.count == 1)
        #expect(collector.rows.first?.lastStatus == "ok")

        // Trigger another tick.
        await clock.advance(by: 30 * 60 + 1)
        try await clock.requireSleeperArmed()

        #expect(collector.rows.count == 2)
        #expect(collector.rows.last?.lastStatus == "http_429")

        await poller.stop()
    }

    @Test("profile with non-nil baseURL is not polled")
    func proxyProfileSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        // Claude direct profile — should be polled.
        let direct = try await db.modelProfiles.create(name: "Direct", kind: .apiKey)
        // Proxy-routed profile — must be skipped (baseURL != nil).
        _ = try await db.modelProfiles.create(
            name: "ProxyOAuth",
            kind: .apiKey,
            baseURL: "http://127.0.0.1:3456",
            model: "gpt-5-codex"
        )
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        await poller.start()
        try await clock.requireSleeperArmed()

        // Only the direct (Claude-API) profile should be reached. The proxy
        // profile is filtered out before any keychain or fetch logic runs.
        #expect(fetcher.callCount(for: direct.id.uuidString) == 1)
        #expect(fetcher.totalCalls == 1)

        await poller.stop()
    }
}
