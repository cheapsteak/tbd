import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Test clock

/// Virtual clock. `advance(by:)` moves wall time forward and resolves any
/// in-flight `sleep(until:)` continuations whose deadlines have been crossed.
final class TestPollerClock: PollerClock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TestPollerClock")
    private var _now: Date
    private var sleepers: [(deadline: Date, cont: CheckedContinuation<Void, Error>, id: UUID)] = []
    private var cancellableSleepers: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self._now = start
    }

    func now() -> Date {
        queue.sync { _now }
    }

    func sleep(until deadline: Date) async throws {
        // Use a unique id so we can drain on cancel.
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = queue.sync {
                    if _now >= deadline { return true }
                    cancellableSleepers[id] = cont
                    sleepers.append((deadline, cont, id))
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let cont: CheckedContinuation<Void, Error>? = queue.sync {
                let c = cancellableSleepers.removeValue(forKey: id)
                sleepers.removeAll { $0.id == id }
                return c
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    /// Advance virtual time. Resolves all sleepers whose deadlines have passed.
    func advance(by interval: TimeInterval) async {
        let due: [(deadline: Date, cont: CheckedContinuation<Void, Error>, id: UUID)] = queue.sync {
            _now = _now.addingTimeInterval(interval)
            let matched = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            for m in matched { cancellableSleepers.removeValue(forKey: m.id) }
            return matched
        }
        for entry in due { entry.cont.resume() }
        for _ in 0..<30 { await Task.yield() }
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

/// Pump the actor's loop several times so it can transition through
/// refresh/sleep states between virtual-time advances. Uses tiny real-time
/// sleeps because the loop awaits the GRDB executor (a separate thread), so
/// pure `Task.yield()` is not sufficient to settle the actor between steps.
private func pump() async {
    for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        await Task.yield()
    }
}

// MARK: - Tests

@Suite("ClaudeUsagePoller")
struct ClaudeUsagePollerTests {

    @Test func happyPathStaggerAndCadence() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .oauth)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock, stagger: 30)

        await poller.start()
        await pump()

        // Before advancing, no calls have happened.
        #expect(fetcher.totalCalls == 0)

        // Advance past the 30s stagger.
        await clock.advance(by: 31)
        await pump()

        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        // Advance another 30 minutes — second tick.
        await clock.advance(by: 30 * 60 + 1)
        await pump()

        #expect(fetcher.callCount(for: a.id.uuidString) == 2)
        #expect(fetcher.callCount(for: b.id.uuidString) == 2)

        await poller.stop()
    }

    @Test func dedupeWithinSixtySeconds() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
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

        await poller.start()
        await pump()
        await clock.advance(by: 1) // first tick fires immediately (stagger=0)
        await pump()

        // Dedupe hit — no fetch.
        #expect(fetcher.callCount(for: a.id.uuidString) == 0)

        await poller.stop()
    }

    @Test func http429BackoffThenRecovery() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        // First call: 429. Subsequent: ok.
        fetcher.enqueue(token: a.id.uuidString, .http429)

        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)
        await poller.start()
        await pump()

        // First tick → 429.
        await clock.advance(by: 1)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        // After 30 minutes nothing should fire (backoff is 60 min).
        await clock.advance(by: 30 * 60)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        // After another 30 minutes (total 60 min) it fires again — this time .ok (default).
        await clock.advance(by: 30 * 60 + 1)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 2)

        // After this success, backoff should be cleared. 30 more minutes should fire again.
        await clock.advance(by: 30 * 60 + 1)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 3)

        await poller.stop()
    }

    @Test func http401PermanentExclusion() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        fetcher.enqueue(token: a.id.uuidString, .http401)

        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)
        await poller.start()
        await pump()
        await clock.advance(by: 1)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        // Advance well past the cadence — no further calls because token excluded.
        await clock.advance(by: 60 * 60)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)

        await poller.stop()
    }

    @Test func apiKeyTokensSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let oauthTok = try await db.modelProfiles.create(name: "Oauth", kind: .oauth)
        let apiKey = try await db.modelProfiles.create(name: "Api", kind: .apiKey)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        await poller.start()
        await pump()
        await clock.advance(by: 5 * 60)
        await pump()

        #expect(fetcher.callCount(for: oauthTok.id.uuidString) == 1)
        #expect(fetcher.callCount(for: apiKey.id.uuidString) == 0)

        await poller.stop()
    }

    @Test func focusPauseAndResume() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .oauth)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        await poller.start()
        await pump()
        await clock.advance(by: 1)
        await pump()
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        // Lose focus.
        await poller.onFocusChanged(isForeground: false)
        // Advance 11 minutes — past the 10-min focus pause threshold but not past the 30-min cadence.
        await clock.advance(by: 11 * 60)
        await pump()

        // Loop should be paused; no new fetches.
        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        // Regain focus → immediate pokeAll.
        await poller.onFocusChanged(isForeground: true)
        await pump()
        await clock.advance(by: 1)
        await pump()

        #expect(fetcher.callCount(for: a.id.uuidString) == 2)
        #expect(fetcher.callCount(for: b.id.uuidString) == 2)

        await poller.stop()
    }

    @Test func pokeAllFiresEverythingEligible() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .oauth)
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        // Use big stagger so first tick is far in the future.
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock, stagger: 30 * 60)

        await poller.start()
        await pump()
        // Verify nothing fired yet.
        #expect(fetcher.totalCalls == 0)

        await poller.pokeAll()
        await pump()
        await clock.advance(by: 1)
        await pump()

        #expect(fetcher.callCount(for: a.id.uuidString) == 1)
        #expect(fetcher.callCount(for: b.id.uuidString) == 1)

        await poller.stop()
    }

    @Test func broadcastCalledOnEachWrite() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
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
        await pump()
        await clock.advance(by: 1)
        await pump()

        #expect(collector.rows.count == 1)
        #expect(collector.rows[0].lastStatus == "ok")

        // Trigger another tick.
        await clock.advance(by: 30 * 60 + 1)
        await pump()

        #expect(collector.rows.count == 2)
        #expect(collector.rows[1].lastStatus == "http_429")

        await poller.stop()
    }

    @Test("profile with non-nil baseURL is not polled")
    func proxyProfileSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        // Claude direct profile — should be polled.
        let direct = try await db.modelProfiles.create(name: "Direct", kind: .oauth)
        // Proxy-routed profile — must be skipped (baseURL != nil).
        _ = try await db.modelProfiles.create(
            name: "ProxyOAuth",
            kind: .oauth,
            baseURL: "http://127.0.0.1:3456",
            model: "gpt-5-codex"
        )
        let clock = TestPollerClock()
        let fetcher = MockUsageFetcher(default: .ok(sampleUsageOK()))
        let poller = makePoller(db: db, fetcher: fetcher, clock: clock)

        await poller.start()
        await pump()
        await clock.advance(by: 1)
        await pump()

        // Only the direct (Claude-API) profile should be reached. The proxy
        // profile is filtered out before any keychain or fetch logic runs.
        #expect(fetcher.callCount(for: direct.id.uuidString) == 1)
        #expect(fetcher.totalCalls == 1)

        await poller.stop()
    }
}
