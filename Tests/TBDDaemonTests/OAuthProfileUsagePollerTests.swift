import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Test doubles

/// Scriptable fetcher: per-credential queue of statuses, falling back to a
/// default. Records call order. Stands in for BOTH fetchers the poller
/// dispatches to, so one instance can assert that a sweep issued no token
/// probe at all.
private final class ScriptedProfileUsageFetcher: ProfileUsageFetching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ScriptedProfileUsageFetcher")
    private var scripted: [String: [ProfileUsageFetchStatus]] = [:]
    private var fallback: ProfileUsageFetchStatus
    private var _calls: [String] = []
    private var _tokenProbeCount = 0

    init(default fallback: ProfileUsageFetchStatus) {
        self.fallback = fallback
    }

    func enqueue(configDirPath: String, _ status: ProfileUsageFetchStatus) {
        queue.sync { scripted[configDirPath, default: []].append(status) }
    }

    func enqueue(token: String, _ status: ProfileUsageFetchStatus) {
        queue.sync { scripted[Self.key(.token(token)), default: []].append(status) }
    }

    var calls: [String] { queue.sync { _calls } }

    /// How many `.token` credentials this fetcher was handed — i.e. how many
    /// real billed probes the run would have issued.
    var tokenProbeCount: Int { queue.sync { _tokenProbeCount } }

    private static func key(_ credential: ProfileUsageCredential) -> String {
        switch credential {
        case .configDir(let path): return path
        case .token(let token): return "token:\(token)"
        }
    }

    func fetchUsage(credential: ProfileUsageCredential) async -> ProfileUsageFetchStatus {
        let key = Self.key(credential)
        let isToken: Bool
        if case .token = credential { isToken = true } else { isToken = false }
        return queue.sync {
            _calls.append(key)
            if isToken { _tokenProbeCount += 1 }
            if var statuses = scripted[key], !statuses.isEmpty {
                let next = statuses.removeFirst()
                scripted[key] = statuses
                return next
            }
            return fallback
        }
    }
}

private final class BroadcastCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BroadcastCounter")
    private var _count = 0
    var count: Int { queue.sync { _count } }
    func bump() { queue.sync { _count += 1 } }
}

private func oauthProfile(named name: String) -> ModelProfile {
    ModelProfile(name: name, kind: .oauth)
}

private func tokenProfile(named name: String) -> ModelProfile {
    ModelProfile(name: name, kind: .oauthToken)
}

private let okBuckets = [
    ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 12,
                           resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
    ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 34),
    ClaudeUsageLimitBucket(kind: "weekly_scoped", group: "weekly", percent: 56,
                           modelDisplayName: "Fable"),
]

/// Build a poller over in-memory fixtures. `loggedIn` controls which profile
/// ids report a login identity. The sleeper is a no-op so sweeps are instant.
private func makePoller(
    profiles: [ModelProfile],
    loggedIn: Set<UUID>,
    fetcher: ScriptedProfileUsageFetcher,
    broadcasts: BroadcastCounter,
    now: Date = Date(timeIntervalSince1970: 1_750_000_000),
    tokens: [UUID: String] = [:],
    loadPersisted: OAuthProfileUsagePoller.SnapshotLoader? = nil,
    persist: OAuthProfileUsagePoller.SnapshotPersister? = nil
) -> OAuthProfileUsagePoller {
    OAuthProfileUsagePoller(
        profilesProvider: { profiles },
        loginIdentity: { id in loggedIn.contains(id) ? "someone@example.com" : nil },
        configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
        fetcher: fetcher,
        // One double serves both legs so a test can assert the number of
        // BILLED token probes a sweep issued, not just its total call count.
        tokenFetcher: fetcher,
        profileSecret: { tokens[$0] },
        broadcast: { broadcasts.bump() },
        sleeper: { _ in },
        now: { now },
        loadPersisted: loadPersisted,
        persist: persist
    )
}

/// Thread-safe recorder for the poller's `persist` seam.
private final class SnapshotBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SnapshotBox")
    private var _saved: [UUID: ProfileUsageSnapshot] = [:]
    var saved: [UUID: ProfileUsageSnapshot] { queue.sync { _saved } }
    func save(_ id: UUID, _ snapshot: ProfileUsageSnapshot) {
        queue.sync { _saved[id] = snapshot }
    }
}

// MARK: - Tests

struct OAuthProfileUsagePollerTests {

    @Test func sweepPopulatesSnapshotsForLoggedInOAuthProfilesOnly() async {
        let loggedIn = oauthProfile(named: "A")
        let notLoggedIn = oauthProfile(named: "B")
        let apiKey = ModelProfile(name: "C", kind: .apiKey)
        let bedrock = ModelProfile(name: "D", kind: .bedrock, awsRegion: "us-west-2")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [loggedIn, notLoggedIn, apiKey, bedrock],
            loggedIn: [loggedIn.id, apiKey.id],  // apiKey id "logged in" must still be skipped
            fetcher: fetcher,
            broadcasts: broadcasts
        )

        let snapshots = await poller.sweepNow()

        #expect(snapshots.count == 1)
        let snapshot = snapshots[loggedIn.id]
        #expect(snapshot?.buckets == okBuckets)
        #expect(snapshot?.status == "ok")
        #expect(snapshot?.fetchedAt != nil)
        #expect(fetcher.calls.count == 1)
        #expect(broadcasts.count == 1)
    }

    @Test func perProfileFailureDoesNotPoisonTheSweep() async {
        let good = oauthProfile(named: "Good")
        let bad = oauthProfile(named: "Bad")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        fetcher.enqueue(
            configDirPath: "/profiles/\(bad.id.uuidString.lowercased())/claude",
            .httpError(401)
        )
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [good, bad],
            loggedIn: [good.id, bad.id],
            fetcher: fetcher,
            broadcasts: broadcasts
        )

        let snapshots = await poller.sweepNow()

        #expect(snapshots[good.id]?.status == "ok")
        #expect(snapshots[good.id]?.buckets == okBuckets)
        let failed = snapshots[bad.id]
        #expect(failed?.status == "fetch failed: HTTP 401")
        #expect(failed?.buckets == [])
        #expect(failed?.fetchedAt == nil)
        #expect(failed?.lastAttemptAt != nil)
    }

    @Test func failureAfterSuccessKeepsOldBucketsAndMarksStale() async {
        let profile = oauthProfile(named: "Flaky")
        let dir = "/profiles/\(profile.id.uuidString.lowercased())/claude"
        let fetcher = ScriptedProfileUsageFetcher(default: .networkError("timed out"))
        fetcher.enqueue(configDirPath: dir, .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts
        )

        let first = await poller.sweepNow()
        let successFetchedAt = first[profile.id]?.fetchedAt
        #expect(first[profile.id]?.status == "ok")

        // Scheduled-path sweep (sweepNow would skip: the snapshot is fresh).
        let second = await poller.sweepForTest()
        let stale = second[profile.id]
        #expect(stale?.buckets == okBuckets)             // old data retained
        #expect(stale?.fetchedAt == successFetchedAt)    // success timestamp preserved
        #expect(stale?.status.hasPrefix("stale since ") == true)
        #expect(stale?.status.contains("network error: timed out") == true)
    }

    @Test func noLoggedInProfilesYieldsEmptySweepAndNoBroadcast() async {
        let profile = oauthProfile(named: "LoggedOut")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [],
            fetcher: fetcher, broadcasts: broadcasts
        )

        let snapshots = await poller.sweepNow()

        #expect(snapshots.isEmpty)
        #expect(fetcher.calls.isEmpty)
        #expect(broadcasts.count == 0)
    }

    @Test func repeatedIdenticalFailuresBroadcastOnlyOnce() async {
        let profile = oauthProfile(named: "Dead")
        let fetcher = ScriptedProfileUsageFetcher(default: .httpError(401))
        let broadcasts = BroadcastCounter()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_750_000_000))
        let poller = OAuthProfileUsagePoller(
            profilesProvider: { [profile] },
            loginIdentity: { _ in "someone@example.com" },
            configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
            fetcher: fetcher,
            broadcast: { broadcasts.bump() },
            sleeper: { _ in },
            now: { clock.now },
            jitter: { _ in 0 }
        )

        await poller.sweepForTest()
        #expect(broadcasts.count == 1)  // nil → failed is a change
        clock.advance(31)               // past the 30s backoff from failure 1
        await poller.sweepForTest()
        clock.advance(61)               // past the 60s backoff from failure 2
        await poller.sweepForTest()
        #expect(fetcher.calls.count == 3)
        #expect(broadcasts.count == 1)  // same failure text: no re-broadcast
    }

    @Test func targetedSweepFetchesOnlyThatProfile() async {
        let one = oauthProfile(named: "One")
        let two = oauthProfile(named: "Two")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [one, two], loggedIn: [one.id, two.id],
            fetcher: fetcher, broadcasts: broadcasts
        )

        let snapshots = await poller.sweepNow(profileID: two.id)

        #expect(fetcher.calls == ["/profiles/\(two.id.uuidString.lowercased())/claude"])
        #expect(snapshots.count == 1)
        #expect(snapshots[two.id]?.status == "ok")
        // Untargeted profile is untouched (no snapshot yet).
        #expect(await poller.snapshot(for: one.id) == nil)
    }

    @Test func fullSweepPrunesProfilesNoLongerEligible() async {
        let keep = oauthProfile(named: "Keep")
        let drop = oauthProfile(named: "Drop")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()

        // First poller sees both profiles logged in.
        let both = makePoller(
            profiles: [keep, drop], loggedIn: [keep.id, drop.id],
            fetcher: fetcher, broadcasts: broadcasts
        )
        let first = await both.sweepNow()
        #expect(first.count == 2)

        // Simulate "drop logged out" by sweeping a poller whose identity
        // provider no longer reports it. (Same actor instance can't swap
        // closures, so verify prune semantics through sweep(only: nil) on a
        // fresh sweep of the same instance is not possible — instead assert
        // that a full sweep never returns ineligible ghosts.)
        let after = makePoller(
            profiles: [keep, drop], loggedIn: [keep.id],
            fetcher: fetcher, broadcasts: broadcasts
        )
        let snapshots = await after.sweepNow()
        #expect(snapshots.count == 1)
        #expect(snapshots[keep.id] != nil)
        #expect(snapshots[drop.id] == nil)
    }

    @Test func failedFetchSetsTypedStatusKind() async {
        let profile = oauthProfile(named: "Rate")
        let fetcher = ScriptedProfileUsageFetcher(default: .rateLimited(retryAfter: 60))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts
        )
        let snapshots = await poller.sweepNow()
        #expect(snapshots[profile.id]?.statusKind == .rateLimited)
    }

    @Test func needsLoginStatusFlowsThroughToSnapshot() async {
        let profile = oauthProfile(named: "Expired")
        let fetcher = ScriptedProfileUsageFetcher(default: .needsLogin("refresh token expired"))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts
        )
        let snapshots = await poller.sweepNow()
        #expect(snapshots[profile.id]?.statusKind == .needsLogin)
        #expect(snapshots[profile.id]?.status.contains("needs re-login") == true)
    }

    @Test func profilesProviderErrorLeavesExistingSnapshotsIntact() async {
        let profile = oauthProfile(named: "Sticky")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let flag = BroadcastCounter()  // reuse as a thread-safe toggle
        let poller = OAuthProfileUsagePoller(
            profilesProvider: {
                if flag.count > 0 {
                    throw ClaudeOAuthTokenReadError("db unavailable")
                }
                flag.bump()
                return [profile]
            },
            loginIdentity: { _ in "someone@example.com" },
            configDirPath: { _ in "/profiles/x/claude" },
            fetcher: fetcher,
            broadcast: { broadcasts.bump() },
            sleeper: { _ in },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        let first = await poller.sweepNow()
        #expect(first[profile.id]?.status == "ok")

        // Second sweep: provider throws — snapshots stay as-is.
        let second = await poller.sweepNow()
        #expect(second[profile.id]?.status == "ok")
        #expect(broadcasts.count == 1)
    }

    // MARK: - Persistence across restarts

    @Test func persistedSnapshotsAreVisibleBeforeAnyFetch() async {
        let profile = oauthProfile(named: "Cached")
        let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)
        let saved = ProfileUsageSnapshot(
            buckets: okBuckets,
            fetchedAt: fixedNow.addingTimeInterval(-600),
            lastAttemptAt: fixedNow.addingTimeInterval(-600),
            status: "ok", statusKind: .ok
        )
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts,
            loadPersisted: { [profile.id: saved] }
        )

        await poller.loadPersistedForTest()

        #expect(await poller.snapshot(for: profile.id) == saved)
        #expect(fetcher.calls.isEmpty)          // load is not a fetch
        #expect(broadcasts.count == 1)          // loaded cache is announced
    }

    @Test func successfulFetchPersistsAndReloadsIntoFreshPoller() async {
        let profile = oauthProfile(named: "P")
        let box = SnapshotBox()
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts,
            persist: { box.save($0, $1) }
        )
        _ = await poller.sweepNow()
        #expect(box.saved[profile.id]?.buckets == okBuckets)
        #expect(box.saved[profile.id]?.fetchedAt != nil)  // staleness computable

        // "Daemon restart": a fresh poller instance loads the persisted data.
        let reloaded = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts,
            loadPersisted: { box.saved }
        )
        await reloaded.loadPersistedForTest()
        #expect(await reloaded.snapshot(for: profile.id) == box.saved[profile.id])
    }

    @Test func failedFetchDoesNotPersist() async {
        let profile = oauthProfile(named: "Bad")
        let box = SnapshotBox()
        let fetcher = ScriptedProfileUsageFetcher(default: .httpError(500))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts,
            persist: { box.save($0, $1) }
        )
        _ = await poller.sweepNow()
        #expect(box.saved.isEmpty)
    }

    @Test func startupSweepSkipsFreshPersistedAndFetchesStale() async {
        let fresh = oauthProfile(named: "Fresh")
        let stale = oauthProfile(named: "Stale")
        let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)
        func snap(age: TimeInterval) -> ProfileUsageSnapshot {
            ProfileUsageSnapshot(
                buckets: okBuckets,
                fetchedAt: fixedNow.addingTimeInterval(-age),
                lastAttemptAt: fixedNow.addingTimeInterval(-age),
                status: "ok", statusKind: .ok
            )
        }
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let persisted = [fresh.id: snap(age: 10), stale.id: snap(age: 300)]
        let poller = makePoller(
            profiles: [fresh, stale], loggedIn: [fresh.id, stale.id],
            fetcher: fetcher, broadcasts: broadcasts, now: fixedNow,
            loadPersisted: { persisted }
        )
        await poller.loadPersistedForTest()

        // Startup sweep gates on the cadence: only the stale profile fetches.
        _ = await poller.sweepForTest(skipFresherThan: OAuthProfileUsagePoller.cadence)

        #expect(fetcher.calls == ["/profiles/\(stale.id.uuidString.lowercased())/claude"])
        // The fresh profile keeps its persisted snapshot untouched.
        #expect(await poller.snapshot(for: fresh.id)?.fetchedAt == fixedNow.addingTimeInterval(-10))
        // The stale one was refetched now.
        #expect(await poller.snapshot(for: stale.id)?.fetchedAt == fixedNow)
    }

    /// Actor reentrancy: a sweep can land fresher data while `start()` is
    /// suspended in `loadPersisted()`. The load must merge per profile by
    /// `fetchedAt` — never clobber a fresher in-memory snapshot — while still
    /// seeding profiles the sweep didn't cover.
    @Test func loadPersistedMergesByFreshnessInsteadOfReplacing() async {
        let sweptProfile = oauthProfile(named: "Swept")
        let cachedOnly = oauthProfile(named: "CachedOnly")
        let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)
        func snap(age: TimeInterval) -> ProfileUsageSnapshot {
            ProfileUsageSnapshot(
                buckets: okBuckets,
                fetchedAt: fixedNow.addingTimeInterval(-age),
                lastAttemptAt: fixedNow.addingTimeInterval(-age),
                status: "ok", statusKind: .ok
            )
        }
        let persisted = [sweptProfile.id: snap(age: 600), cachedOnly.id: snap(age: 600)]
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [sweptProfile], loggedIn: [sweptProfile.id],
            fetcher: fetcher, broadcasts: broadcasts, now: fixedNow,
            loadPersisted: { persisted }
        )

        // Racing sweep fetches sweptProfile fresh (fetchedAt == fixedNow)...
        _ = await poller.sweepNow()
        // ...then the interleaved load resumes.
        await poller.loadPersistedForTest()

        // Fresher in-memory snapshot survives; stale persisted one loses.
        #expect(await poller.snapshot(for: sweptProfile.id)?.fetchedAt == fixedNow)
        // Profile only present in the cache is still seeded.
        #expect(await poller.snapshot(for: cachedOnly.id) == persisted[cachedOnly.id])
    }

    @Test func fullSweepPrunesPersistedRowsForIneligibleProfiles() async {
        let eligible = oauthProfile(named: "In")
        let loggedOut = oauthProfile(named: "Out")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let broadcasts = BroadcastCounter()
        let prunedSets = LockedBox<[Set<UUID>]>([])
        let poller = OAuthProfileUsagePoller(
            profilesProvider: { [eligible, loggedOut] },
            loginIdentity: { id in id == eligible.id ? "someone@example.com" : nil },
            configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
            fetcher: fetcher,
            broadcast: { broadcasts.bump() },
            sleeper: { _ in },
            prunePersisted: { ids in prunedSets.mutate { $0.append(ids) } }
        )

        _ = await poller.sweepNow()                          // full sweep: prunes
        _ = await poller.sweepNow(profileID: eligible.id)    // targeted: must not

        #expect(prunedSets.value == [[eligible.id]])
    }
}

/// Minimal thread-safe box for recording seam calls.
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LockedBox")
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { queue.sync { _value } }
    func mutate(_ body: (inout T) -> Void) { queue.sync { body(&_value) } }
}

// MARK: - Backoff scheduling

/// Thread-safe mutable clock for backoff tests.
private final class MutableClock: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MutableClock")
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { queue.sync { _now } }
    func advance(_ interval: TimeInterval) { queue.sync { _now = _now.addingTimeInterval(interval) } }
}

@Suite struct OAuthProfileUsagePollerBackoffTests {

    /// Build a poller for testing the *backoff arithmetic* of sweeps that the
    /// test drives by hand — `sweepNow()` (the picker-open refresh) and
    /// `sweepForTest()` (which stands in for the scheduled sweep `runLoop()`
    /// would issue). The injected `now` makes every backoff window a pure
    /// function of `clock.advance(_:)`, and zero jitter makes the exponential
    /// windows exact rather than ranged.
    ///
    /// Nothing here starts or stops a loop. An earlier version of this comment
    /// claimed the cadence sleeper "throws to stop the loop"; that mechanism
    /// does not exist. The sleeper below is non-throwing, `runLoop()` swallows
    /// its sleeper's errors with `try?` and would keep looping anyway, and —
    /// decisively — no test in this file calls `poller.start()`, so `runLoop()`
    /// is never entered. The sleeper is consulted only by `sweep()`'s
    /// inter-profile stagger, which is why a no-op makes sweeps instant.
    ///
    /// Coverage gap this leaves, stated so the next reader need not re-derive
    /// it: because nothing calls `start()`, `runLoop()`'s cadence pacing and
    /// its startup `skipFresherThan: cadence` handoff (set once, then cleared
    /// to nil for every subsequent tick) are untested.
    private func scheduledPoller(
        profile: ModelProfile,
        fetcher: ScriptedProfileUsageFetcher,
        clock: MutableClock
    ) -> OAuthProfileUsagePoller {
        OAuthProfileUsagePoller(
            profilesProvider: { [profile] },
            loginIdentity: { _ in "someone@example.com" },
            configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
            fetcher: fetcher,
            broadcast: {},
            sleeper: { _ in },  // instant staggers
            now: { clock.now },
            jitter: { _ in 0 }
        )
    }

    @Test func retryAfterGatesTheNextScheduledSweep() async {
        let profile = oauthProfile(named: "Limited")
        let dir = "/profiles/\(profile.id.uuidString.lowercased())/claude"
        // First fetch: 429 Retry-After 300s. Second (if it happened): ok.
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        fetcher.enqueue(configDirPath: dir, .rateLimited(retryAfter: 300))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = scheduledPoller(profile: profile, fetcher: fetcher, clock: clock)

        // First sweep records the 429 and arms the 300s backoff.
        _ = await poller.sweepNow()
        #expect(fetcher.calls.count == 1)
        #expect(await poller.snapshot(for: profile.id)?.statusKind == .rateLimited)

        // A scheduled sweep only 100s later must SKIP this profile (still inside
        // the 300s Retry-After window).
        clock.advance(100)
        _ = await poller.sweepForTest()
        #expect(fetcher.calls.count == 1)  // no new fetch

        // Past the window: scheduled sweep tries again and recovers.
        clock.advance(300)
        _ = await poller.sweepForTest()
        #expect(fetcher.calls.count == 2)
        #expect(await poller.snapshot(for: profile.id)?.statusKind == .ok)
    }

    @Test func refreshSweepRespectsBackoffWindow() async {
        let profile = oauthProfile(named: "Limited")
        let dir = "/profiles/\(profile.id.uuidString.lowercased())/claude"
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        fetcher.enqueue(configDirPath: dir, .rateLimited(retryAfter: 600))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = scheduledPoller(profile: profile, fetcher: fetcher, clock: clock)

        _ = await poller.sweepNow()               // arms 600s backoff
        #expect(fetcher.calls.count == 1)
        // Picker-open refresh 1s later must NOT bypass the backoff window —
        // reopening the picker against a 429ing endpoint stays quiet.
        clock.advance(1)
        _ = await poller.sweepNow()
        #expect(fetcher.calls.count == 1)
        // Past the window, the refresh fetches again and recovers.
        clock.advance(600)
        _ = await poller.sweepNow()
        #expect(fetcher.calls.count == 2)
        #expect(await poller.snapshot(for: profile.id)?.statusKind == .ok)
    }

    @Test func refreshSweepSkipsFreshSnapshots() async {
        let profile = oauthProfile(named: "Healthy")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = scheduledPoller(profile: profile, fetcher: fetcher, clock: clock)

        _ = await poller.sweepNow()
        #expect(fetcher.calls.count == 1)
        // Reopening the picker 10s later: snapshot is fresh (< 30s) → no fetch.
        clock.advance(10)
        _ = await poller.sweepNow()
        #expect(fetcher.calls.count == 1)
        // 31s after the fetch it's stale enough to refresh.
        clock.advance(21)
        _ = await poller.sweepNow()
        #expect(fetcher.calls.count == 2)
    }

    @Test func exponentialBackoffGrowsWithConsecutiveFailures() async {
        let profile = oauthProfile(named: "Flaky")
        // Always fails with a network error (no Retry-After) → exponential path.
        let fetcher = ScriptedProfileUsageFetcher(default: .networkError("down"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = scheduledPoller(profile: profile, fetcher: fetcher, clock: clock)

        // Failure 1 → base backoff (30s). A scheduled sweep at +29s is skipped,
        // at +31s it runs (failure 2), which arms ~60s.
        _ = await poller.sweepForTest()  // failure 1, arms 30s
        #expect(fetcher.calls.count == 1)

        clock.advance(29)
        _ = await poller.sweepForTest()
        #expect(fetcher.calls.count == 1)  // still gated

        clock.advance(2)  // now +31s
        _ = await poller.sweepForTest()
        #expect(fetcher.calls.count == 2)  // failure 2, arms ~60s

        // +31s from failure-2 is NOT enough now (window doubled to 60s).
        clock.advance(31)
        _ = await poller.sweepForTest()
        #expect(fetcher.calls.count == 2)  // still gated by the longer window

        clock.advance(30)  // +61s total from failure 2
        _ = await poller.sweepForTest()
        #expect(fetcher.calls.count == 3)
    }

    @Test func oneProfileBackoffDoesNotBlockAnother() async {
        let limited = oauthProfile(named: "Limited")
        let healthy = oauthProfile(named: "Healthy")
        let limitedDir = "/profiles/\(limited.id.uuidString.lowercased())/claude"
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        fetcher.enqueue(configDirPath: limitedDir, .rateLimited(retryAfter: 600))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = OAuthProfileUsagePoller(
            profilesProvider: { [limited, healthy] },
            loginIdentity: { _ in "someone@example.com" },
            configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
            fetcher: fetcher,
            broadcast: {},
            sleeper: { _ in },
            now: { clock.now },
            jitter: { _ in 0 }
        )

        _ = await poller.sweepNow()  // limited → 429 (backoff), healthy → ok
        let firstCalls = fetcher.calls.count
        #expect(firstCalls == 2)

        // Scheduled sweep shortly after: limited is gated, but healthy still
        // polls — proving isolation.
        clock.advance(10)
        _ = await poller.sweepForTest()
        // Only the healthy profile fetched again.
        #expect(fetcher.calls.count == firstCalls + 1)
        #expect(await poller.snapshot(for: healthy.id)?.statusKind == .ok)
        #expect(await poller.snapshot(for: limited.id)?.statusKind == .rateLimited)
    }
}

// MARK: - RPC decode-compat

struct ProfileUsageRPCCompatTests {

    /// JSON from an older daemon (no `usageSnapshot` key) must still decode.
    @Test func modelProfileWithUsageDecodesWithoutSnapshotField() throws {
        let profile = ModelProfile(name: "Old", kind: .oauth)
        // Encode with the OLD shape by round-tripping a value with nil
        // snapshot and stripping nothing — synthesized Codable omits... it
        // actually encodes nil as absent only with encodeIfPresent; verify by
        // constructing raw JSON instead.
        let encoder = JSONEncoder()
        let profileJSON = String(data: try encoder.encode(profile), encoding: .utf8)!
        let old = """
        {"profile": \(profileJSON), "loginIdentity": "a@b.c"}
        """
        let decoded = try JSONDecoder().decode(ModelProfileWithUsage.self, from: Data(old.utf8))
        #expect(decoded.usageSnapshot == nil)
        #expect(decoded.loginIdentity == "a@b.c")
    }

    @Test func modelProfileWithUsageRoundTripsSnapshot() throws {
        let snapshot = ProfileUsageSnapshot(
            buckets: okBuckets,
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000),
            lastAttemptAt: Date(timeIntervalSince1970: 1_750_000_090),
            status: "ok"
        )
        let value = ModelProfileWithUsage(
            profile: ModelProfile(name: "New", kind: .oauth),
            usageSnapshot: snapshot
        )
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ModelProfileWithUsage.self, from: data)
        #expect(decoded.usageSnapshot == snapshot)
        #expect(decoded.usageSnapshot?.buckets.first?.modelDisplayName == nil)
        #expect(decoded.usageSnapshot?.buckets.last?.modelDisplayName == "Fable")
    }

    /// Old clients decode new payloads by ignoring unknown keys; simulate by
    /// decoding a payload with an extra unknown top-level field.
    @Test func unknownExtraFieldsAreIgnoredOnDecode() throws {
        let profile = ModelProfile(name: "P", kind: .oauth)
        let profileJSON = String(data: try JSONEncoder().encode(profile), encoding: .utf8)!
        let futuristic = """
        {"profile": \(profileJSON), "someFutureField": {"x": 1}}
        """
        let decoded = try JSONDecoder().decode(ModelProfileWithUsage.self, from: Data(futuristic.utf8))
        #expect(decoded.profile.name == "P")
    }

    @Test func usageRefreshParamsDecodeFromEmptyObject() throws {
        // The CLI/app may send "{}" (RPCRequest's default params) for
        // refresh-all; the id must decode as nil.
        let params = try JSONDecoder().decode(
            ModelProfileUsageRefreshParams.self, from: Data("{}".utf8))
        #expect(params.id == nil)
    }

    @Test func usageRefreshResultRoundTrips() throws {
        let entry = ModelProfileUsageSnapshotEntry(
            profileID: UUID(),
            snapshot: ProfileUsageSnapshot(
                buckets: okBuckets, fetchedAt: Date(timeIntervalSince1970: 1),
                lastAttemptAt: Date(timeIntervalSince1970: 2), status: "ok")
        )
        let result = ModelProfileUsageRefreshResult(snapshots: [entry])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ModelProfileUsageRefreshResult.self, from: data)
        #expect(decoded.snapshots == [entry])
    }
}

// MARK: - Token profiles: the activity gate

/// Build a poller over a mutable clock so the five-minute floor is a pure
/// function of `clock.advance(_:)`. One scripted fetcher serves both legs, so
/// `tokenProbeCount` isolates the BILLED calls from the free ones.
private func makeTokenPoller(
    profiles: [ModelProfile],
    tokens: [UUID: String],
    fetcher: ScriptedProfileUsageFetcher,
    clock: MutableClock,
    loggedIn: Set<UUID> = [],
    prunePersisted: OAuthProfileUsagePoller.SnapshotPruner? = nil
) -> OAuthProfileUsagePoller {
    OAuthProfileUsagePoller(
        profilesProvider: { profiles },
        loginIdentity: { id in loggedIn.contains(id) ? "someone@example.com" : nil },
        configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
        fetcher: fetcher,
        tokenFetcher: fetcher,
        profileSecret: { tokens[$0] },
        broadcast: {},
        sleeper: { _ in },
        now: { clock.now },
        jitter: { _ in 0 },
        prunePersisted: prunePersisted
    )
}

@Suite struct OAuthProfileUsageTokenGateTests {

    @Test func idleTransitionSchedulesExactlyOneProbe() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)

        #expect(fetcher.tokenProbeCount == 1)
        #expect(await poller.snapshot(for: profile.id)?.buckets == okBuckets)
    }

    /// The five-minute floor collapses a burst of turns into one probe. Each
    /// probe is a real billed request, so this is a cost property, not a
    /// micro-optimisation.
    @Test func secondTransitionInsideFloorSchedulesNoProbe() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        clock.advance(299)
        await poller.noteSessionBecameIdle(profileID: profile.id)

        #expect(fetcher.tokenProbeCount == 1)
    }

    @Test func transitionAfterFloorSchedulesAnotherProbe() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        clock.advance(301)
        await poller.noteSessionBecameIdle(profileID: profile.id)

        #expect(fetcher.tokenProbeCount == 2)
    }

    /// The off-branch that matters most: a signed-in profile's terminal going
    /// idle must NOT probe. It is served by the 90-second cadence sweep, whose
    /// endpoint is free.
    @Test func idleTransitionOnOAuthProfileSchedulesNoProbe() async {
        let profile = oauthProfile(named: "Acme")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [:], fetcher: fetcher, clock: clock,
            loggedIn: [profile.id])

        await poller.noteSessionBecameIdle(profileID: profile.id)

        #expect(fetcher.calls.isEmpty)
        #expect(fetcher.tokenProbeCount == 0)
    }

    /// The cadence sweep serves signed-in profiles only; if it ever targeted a
    /// token profile the activity gate would be pointless.
    @Test func cadenceSweepNeverTargetsTokenProfiles() async {
        let token = tokenProfile(named: "Acme (token)")
        let signedIn = oauthProfile(named: "Acme")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [token, signedIn], tokens: [token.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock, loggedIn: [signedIn.id])

        await poller.sweepForTest()

        #expect(fetcher.tokenProbeCount == 0)
        #expect(fetcher.calls == ["/profiles/\(signedIn.id.uuidString.lowercased())/claude"])
        #expect(await poller.snapshot(for: token.id) == nil)
    }

    /// A full sweep prunes profiles it can no longer serve. "Not swept on
    /// cadence" is not one of those: a token profile must keep the snapshot its
    /// last activity probe produced, in memory AND in the persisted store.
    @Test func fullSweepRetainsTokenProfileSnapshotAndPersistedRow() async {
        let token = tokenProfile(named: "Acme (token)")
        let signedIn = oauthProfile(named: "Acme")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let pruned = LockedBox<[Set<UUID>]>([])
        let poller = makeTokenPoller(
            profiles: [token, signedIn], tokens: [token.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock, loggedIn: [signedIn.id],
            prunePersisted: { ids in pruned.mutate { $0.append(ids) } })

        await poller.noteSessionBecameIdle(profileID: token.id)
        #expect(await poller.snapshot(for: token.id) != nil)

        await poller.sweepForTest()

        #expect(await poller.snapshot(for: token.id)?.buckets == okBuckets)
        #expect(pruned.value == [[token.id, signedIn.id]])
    }

    /// The picker-open refresh asks for a 30-second freshness window — right
    /// for a free GET, wrong for a billed probe. The floor overrides it.
    @Test func pickerRefreshCannotBypassTheTokenFloor() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        clock.advance(31)                                 // past refreshFreshness
        _ = await poller.sweepNow(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 1)

        clock.advance(270)                                // now past the 300s floor
        _ = await poller.sweepNow(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)
    }

    /// One probe at creation, so bars appear immediately and a bad paste is
    /// caught at once rather than at first spawn. A profile with no snapshot
    /// has no `fetchedAt`, so the floor has nothing to gate against.
    @Test func creationProbeFiresBeforeAnySnapshotExists() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteCredentialChanged(profileID: profile.id)

        #expect(fetcher.tokenProbeCount == 1)
    }

    /// Rotation is what the released freshness gate exists for: a snapshot
    /// fetched seconds ago describes the OLD token, so its age cannot say
    /// whether the NEW one is worth reading.
    @Test func credentialChangeProbesInsideTheFloor() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 1)

        // 5s in — deep inside the 300s floor that
        // `pickerRefreshCannotBypassTheTokenFloor` shows holds every other
        // caller back at this point.
        clock.advance(5)
        await poller.noteCredentialChanged(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)

        // The off-branch, at the same instant: releasing the gate for the
        // gesture must not leave it released for the activity path.
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)
    }

    /// The other released gate, isolated: nothing here ever succeeded, so there
    /// is no `fetchedAt` for the floor to act on and the backoff window is the
    /// only thing that could hold the probe back. It is also the realistic
    /// case — the repair for a rejected token is pasting a good one seconds
    /// later, well inside the 30s window that rejection just armed.
    @Test func credentialChangeProbesInsideTheBackoffWindow() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(
            default: .needsLogin("token rejected (HTTP 401)"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-DEAD"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 1)
        #expect(await poller.snapshot(for: profile.id)?.statusKind == .needsLogin)

        // 10s in: `rejectedTokenRecordsNeedsLoginAndBacksOff` pins that an
        // activity probe is still held here.
        clock.advance(10)
        await poller.noteCredentialChanged(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)
    }

    /// A rejected token records `.needsLogin` — the existing case, deliberately
    /// not a new `ProfileUsageStatusKind` (widening it would break snapshot
    /// decode on older apps, where `decodeIfPresent` THROWS on an unknown raw
    /// value). Backoff then applies, so activity does not hammer a dead token.
    @Test func rejectedTokenRecordsNeedsLoginAndBacksOff() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(
            default: .needsLogin("token rejected (HTTP 401)"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-DEAD"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(await poller.snapshot(for: profile.id)?.statusKind == .needsLogin)
        #expect(fetcher.tokenProbeCount == 1)

        // Nothing ever succeeded, so there is no `fetchedAt` for the floor to
        // gate against — the backoff window is what holds the second probe
        // back, which is the point: the two gates are independent.
        clock.advance(10)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 1)

        clock.advance(21)  // +31s: past the 30s window armed by failure 1
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)
    }

    /// A token profile whose secret file was removed must report
    /// `.noCredentials` rather than silently vanishing from the snapshot map:
    /// pruning it would tell the user nothing at all.
    @Test func missingSecretIsReportedRatherThanPruned() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(
            default: .noCredentials("token profile has no stored token"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [:], fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)

        #expect(fetcher.tokenProbeCount == 1)
        #expect(await poller.snapshot(for: profile.id)?.statusKind == .noCredentials)

        await poller.sweepForTest()
        #expect(await poller.snapshot(for: profile.id) != nil)
    }

    /// The organization id refreshes with the fetch that observed it, so
    /// replacing a token with one for a different account does not leave the
    /// old account's id pinned to the snapshot.
    @Test func organizationIDFollowsTheMostRecentSuccessfulFetch() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        fetcher.enqueue(token: "sk-ant-oat01-A", .ok(okBuckets, organizationID: "org_first"))
        fetcher.enqueue(token: "sk-ant-oat01-A", .ok(okBuckets, organizationID: "org_second"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(await poller.snapshot(for: profile.id)?.organizationID == "org_first")

        clock.advance(301)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(await poller.snapshot(for: profile.id)?.organizationID == "org_second")
    }

    /// A failed fetch says nothing about which account the profile belongs to,
    /// so the last known id rides along with the stale buckets.
    @Test func organizationIDSurvivesAFailedFetch() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .networkError("down"))
        fetcher.enqueue(token: "sk-ant-oat01-A", .ok(okBuckets, organizationID: "org_first"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        clock.advance(301)
        await poller.noteSessionBecameIdle(profileID: profile.id)

        let snapshot = await poller.snapshot(for: profile.id)
        #expect(snapshot?.statusKind == .networkError)
        #expect(snapshot?.organizationID == "org_first")
        #expect(snapshot?.buckets == okBuckets)
    }

    /// The spec commits to the backoff being **cleared** by a credential
    /// change, not waived for one call — "a fresh credential restarts the
    /// exponential schedule instead of inheriting a dead one's exponent".
    ///
    /// That distinction is invisible after a single pre-rotation failure:
    /// both readings put the next window at the 30s base. It only shows up
    /// from the second rung on, which is why this test fails twice before
    /// rotating. With the schedule cleared, the rotation probe's own failure
    /// re-arms rung 1 (30s). With it merely waived, the same failure is the
    /// third in a row and arms rung 3 (120s) — so the probe asserted below
    /// would be held for another minute and a half.
    @Test func credentialChangeRestartsTheBackoffScheduleRatherThanWaivingIt() async {
        let profile = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(
            default: .needsLogin("token rejected (HTTP 401)"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-DEAD"],
            fetcher: fetcher, clock: clock)

        // Failure 1 arms rung 1: 30s. (`jitter` is injected as 0 by
        // `makeTokenPoller`, so every window below is exact, not ranged.)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 1)

        // +31s: past rung 1. Failure 2 arms rung 2: 60s, expiring at +91s.
        clock.advance(31)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)

        // +62s: still deep inside rung 2, so activity is held. This is what
        // proves the schedule really did advance past its base before the
        // rotation — without it a cleared-and-never-re-armed backoff would
        // pass the rest of this test.
        clock.advance(31)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 2)

        // Rotation at +62s. Nothing has ever succeeded, so there is no
        // `fetchedAt` and the freshness floor is not in play — the backoff is
        // the only gate this probe can be released by. Its own failure re-arms
        // the schedule from wherever the poller is carrying it.
        await poller.noteCredentialChanged(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 3)

        // +82s — 20s after the rotation probe, inside the fresh schedule's
        // first rung either way.
        clock.advance(20)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 3)

        // +97s — 35s after the rotation probe. A CLEARED schedule is on rung 1
        // (30s, expired at +92s) and admits this. A WAIVED one would be on
        // rung 3 (120s, expiring at +182s) and would not.
        clock.advance(15)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.tokenProbeCount == 4)
    }
}

// MARK: - Token profiles: the per-turn cost of the activity gate

/// Poller whose profile-table reads are counted, over a MUTABLE profile list —
/// so a test can both measure what a completed turn costs and make a profile
/// appear after the gate's cache was warmed.
private func makeCountingTokenPoller(
    profiles: LockedBox<[ModelProfile]>,
    tokens: [UUID: String],
    fetcher: ScriptedProfileUsageFetcher,
    clock: MutableClock,
    loggedIn: Set<UUID>,
    providerCalls: LockedBox<Int>
) -> OAuthProfileUsagePoller {
    OAuthProfileUsagePoller(
        profilesProvider: {
            providerCalls.mutate { $0 += 1 }
            return profiles.value
        },
        loginIdentity: { id in loggedIn.contains(id) ? "someone@example.com" : nil },
        configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
        fetcher: fetcher,
        tokenFetcher: fetcher,
        profileSecret: { tokens[$0] },
        broadcast: {},
        sleeper: { _ in },
        now: { clock.now },
        jitter: { _ in 0 }
    )
}

@Suite struct OAuthProfileUsageIdleGateCostTests {

    /// EVERY completed turn on every session in the fleet reaches
    /// `noteSessionBecameIdle`, and in most installs none of them can act.
    /// Once the profile table has been read once, a turn on a profile that is
    /// not a token profile must cost no read at all.
    @Test func idleTransitionOnANonTokenProfileReadsNoProfileTableOnceWarm() async {
        let signedIn = oauthProfile(named: "Acme")
        let token = tokenProfile(named: "Acme (token)")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let calls = LockedBox<Int>(0)
        let poller = makeCountingTokenPoller(
            profiles: LockedBox([signedIn, token]),
            tokens: [token.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock, loggedIn: [signedIn.id],
            providerCalls: calls)

        // One cadence sweep warms the gate's cache.
        await poller.sweepForTest()
        let warm = calls.value

        await poller.noteSessionBecameIdle(profileID: signedIn.id)
        #expect(calls.value == warm)
        #expect(fetcher.tokenProbeCount == 0)

        // A terminal with no profile at all never reaches here, but an id the
        // table does not know must be just as cheap.
        await poller.noteSessionBecameIdle(profileID: UUID())
        #expect(calls.value == warm)

        // The gate is a shortcut, not a wall: a token profile still gets
        // through and probes.
        await poller.noteSessionBecameIdle(profileID: token.id)
        #expect(calls.value > warm)
        #expect(fetcher.tokenProbeCount == 1)
    }

    /// The staleness direction that would silently lose probes: a token
    /// profile created AFTER the cache was warmed. It is covered because the
    /// creation probe reads the table, and every read refreshes the cache —
    /// remove that refresh and the profile is invisible to the activity gate
    /// for good.
    @Test func aTokenProfileCreatedAfterTheCacheWasWarmedIsStillProbed() async {
        let signedIn = oauthProfile(named: "Acme")
        let token = tokenProfile(named: "Acme (token)")
        let profiles = LockedBox<[ModelProfile]>([signedIn])
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeCountingTokenPoller(
            profiles: profiles, tokens: [token.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock, loggedIn: [signedIn.id],
            providerCalls: LockedBox<Int>(0))

        // Warm with a table that holds no token profile at all.
        await poller.sweepForTest()
        #expect(fetcher.tokenProbeCount == 0)

        // Creation: the row lands, and the creation probe follows it.
        profiles.mutate { $0.append(token) }
        await poller.noteCredentialChanged(profileID: token.id)
        #expect(fetcher.tokenProbeCount == 1)

        // The activity path now recognises it.
        clock.advance(301)
        await poller.noteSessionBecameIdle(profileID: token.id)
        #expect(fetcher.tokenProbeCount == 2)
    }
}

// MARK: - Token profiles: concurrent probes

/// Deterministic rendezvous for the concurrency tests: a fetcher parks in
/// `arrive()` until the gate opens, so a probe can be held "in flight" while a
/// second caller races it. No sleeps and no polling — every wait resumes off an
/// explicit signal.
///
/// The gate also opens ITSELF once `autoOpenAt` probes have arrived. That is
/// what keeps a regression from turning into a hung test run: if the in-flight
/// guard is removed, the duplicate probe arrives, the gate releases both, every
/// task completes, and the assertion on the probe COUNT fails promptly.
private actor ProbeGate {
    private let autoOpenAt: Int
    private var arrivals = 0
    private var opened = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(autoOpenAt: Int) { self.autoOpenAt = autoOpenAt }

    /// Called from inside a fetch: records the arrival, wakes any
    /// `waitForArrivals`, then parks until the gate opens.
    func arrive() async {
        arrivals += 1
        let reached = arrivals
        let ready = watchers.filter { $0.threshold <= reached }
        watchers.removeAll { $0.threshold <= reached }
        for watcher in ready { watcher.continuation.resume() }
        if reached >= autoOpenAt { open() }
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked.append(continuation)
        }
    }

    /// Releases every parked fetch, and every later one immediately.
    func open() {
        opened = true
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }

    /// Resumes once `threshold` fetches have reached `arrive()`.
    func waitForArrivals(_ threshold: Int) async {
        if arrivals >= threshold { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            watchers.append((threshold: threshold, continuation: continuation))
        }
    }
}

/// Fetcher that counts every entry and then parks on a `ProbeGate`. The count
/// is bumped BEFORE parking, so it measures requests issued rather than
/// requests completed — which is what a billed probe costs.
private final class GatedProfileUsageFetcher: ProfileUsageFetching, @unchecked Sendable {
    private let gate: ProbeGate
    private let status: ProfileUsageFetchStatus
    private let queue = DispatchQueue(label: "GatedProfileUsageFetcher")
    private var _probeCount = 0

    var probeCount: Int { queue.sync { _probeCount } }

    init(gate: ProbeGate, status: ProfileUsageFetchStatus) {
        self.gate = gate
        self.status = status
    }

    func fetchUsage(credential: ProfileUsageCredential) async -> ProfileUsageFetchStatus {
        queue.sync { _probeCount += 1 }
        await gate.arrive()
        return status
    }
}

private func makeGatedTokenPoller(
    profiles: [ModelProfile],
    tokens: [UUID: String],
    fetcher: GatedProfileUsageFetcher,
    clock: MutableClock
) -> OAuthProfileUsagePoller {
    OAuthProfileUsagePoller(
        profilesProvider: { profiles },
        loginIdentity: { _ in nil },
        configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
        fetcher: fetcher,
        tokenFetcher: fetcher,
        profileSecret: { tokens[$0] },
        broadcast: {},
        sleeper: { _ in },
        now: { clock.now },
        jitter: { _ in 0 }
    )
}

/// The poller is an actor, and every other test in this file drives it
/// sequentially — which is precisely how the double-billing window survived
/// review. These drive two callers that genuinely overlap.
@Suite struct OAuthProfileUsageConcurrentProbeTests {

    /// A rotation probe and an activity probe for the SAME profile, overlapping.
    ///
    /// `sweep` suspends at `profilesProvider()` and admits the second caller
    /// there, with `snapshots` and `backoff` both still unwritten — so neither
    /// the freshness floor nor the backoff window can hold it. Only the
    /// in-flight reservation can, and for a token profile the cost of it not
    /// doing so is a second BILLED inference request.
    @Test func concurrentProbesOfOneTokenProfileIssueOneBilledRequest() async {
        let profile = tokenProfile(named: "Acme (token)")
        let gate = ProbeGate(autoOpenAt: 2)
        let fetcher = GatedProfileUsageFetcher(
            gate: gate, status: .ok(okBuckets, organizationID: "org_acme"))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeGatedTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        let rotation = Task { await poller.noteCredentialChanged(profileID: profile.id) }
        // The rotation probe is now parked inside the fetcher: its reservation
        // is held and nothing has been recorded yet. This is the window.
        await gate.waitForArrivals(1)

        let activity = Task { await poller.noteSessionBecameIdle(profileID: profile.id) }
        await activity.value

        #expect(fetcher.probeCount == 1)

        await gate.open()
        await rotation.value

        #expect(fetcher.probeCount == 1)
        #expect(await poller.snapshot(for: profile.id)?.buckets == okBuckets)
    }

    /// The guard is per profile, not a global lock. A fix that serialized ALL
    /// fetches would pass the test above and quietly turn a full sweep into a
    /// queue — so this pins that two DIFFERENT profiles still probe at once.
    @Test func concurrentProbesOfTwoTokenProfilesBothFire() async {
        let first = tokenProfile(named: "Acme (token)")
        let second = tokenProfile(named: "Globex (token)")
        let gate = ProbeGate(autoOpenAt: 2)
        let fetcher = GatedProfileUsageFetcher(
            gate: gate, status: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeGatedTokenPoller(
            profiles: [first, second],
            tokens: [first.id: "sk-ant-oat01-A", second.id: "sk-ant-oat01-B"],
            fetcher: fetcher, clock: clock)

        let firstProbe = Task { await poller.noteSessionBecameIdle(profileID: first.id) }
        await gate.waitForArrivals(1)

        // Reaches the fetcher while `first` is still parked there, which is
        // what opens the gate for both.
        let secondProbe = Task { await poller.noteSessionBecameIdle(profileID: second.id) }
        await secondProbe.value
        // Belt and braces: if a global lock had dropped `second`, the gate
        // never reached its threshold and `first` would still be parked.
        // Opening explicitly keeps that a failed assertion rather than a hang.
        await gate.open()
        await firstProbe.value

        #expect(fetcher.probeCount == 2)
        #expect(await poller.snapshot(for: first.id)?.buckets == okBuckets)
        #expect(await poller.snapshot(for: second.id)?.buckets == okBuckets)
    }

    /// Once the winner's snapshot has been recorded, the ordinary gates take
    /// over again: the reservation is released only AFTER `record` commits, so
    /// the next caller meets a `fetchedAt` and is held by the 300s floor
    /// rather than racing for the reservation.
    @Test func reservationIsReleasedSoTheFloorTakesOverAfterwards() async {
        let profile = tokenProfile(named: "Acme (token)")
        // Opens on first arrival: nothing parks, so these calls are ordinary
        // sequential ones and the assertion is about the state left behind.
        let gate = ProbeGate(autoOpenAt: 1)
        let fetcher = GatedProfileUsageFetcher(
            gate: gate, status: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let poller = makeGatedTokenPoller(
            profiles: [profile], tokens: [profile.id: "sk-ant-oat01-A"],
            fetcher: fetcher, clock: clock)

        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.probeCount == 1)

        // Inside the floor: held by freshness, not by a leaked reservation.
        clock.advance(10)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.probeCount == 1)

        // Past the floor: a leaked reservation would keep this at 1 forever.
        clock.advance(300)
        await poller.noteSessionBecameIdle(profileID: profile.id)
        #expect(fetcher.probeCount == 2)
    }

    /// A profile-table read that COMPLETES OUT OF ORDER — the staleness
    /// direction the double-billing tests above do not cover.
    ///
    /// Both `sweep` and `noteSessionBecameIdle` read the profile table across
    /// an `await`, and the actor admits other callers there. So a sweep whose
    /// read began before a token profile existed can commit after a read that
    /// saw it. If the activity gate's cache were REPLACED on every read, that
    /// late arrival would put the cache back to a set without the new profile,
    /// and the profile's next `working -> idle` would early-return: a probe
    /// dropped silently, with nothing in the log and no bars ever appearing.
    /// The cache unions instead, so read order cannot lose an id.
    @Test func aReadThatCompletesOutOfOrderCannotEraseANewTokenProfile() async {
        let signedIn = oauthProfile(named: "Acme")
        let token = tokenProfile(named: "Acme (token)")
        let profiles = LockedBox<[ModelProfile]>([signedIn])
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets, organizationID: nil))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        // Never auto-opens: this test releases the held read explicitly, so the
        // completion order it asserts about is the order it actually produced.
        let readGate = ProbeGate(autoOpenAt: Int.max)
        let reads = LockedBox<Int>(0)

        let poller = OAuthProfileUsagePoller(
            profilesProvider: {
                var index = 0
                reads.mutate { index = $0; $0 += 1 }
                // Observed BEFORE parking: this read sees the table as it was
                // when it started, which is the whole point of the exercise.
                let observed = profiles.value
                if index == 0 { await readGate.arrive() }
                return observed
            },
            loginIdentity: { id in id == signedIn.id ? "someone@example.com" : nil },
            configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
            fetcher: fetcher,
            tokenFetcher: fetcher,
            profileSecret: { _ in "sk-ant-oat01-A" },
            broadcast: {},
            sleeper: { _ in },
            now: { clock.now },
            jitter: { _ in 0 }
        )

        // A cadence sweep starts while no token profile exists and parks inside
        // its profile-table read, holding the pre-creation view of the table.
        let staleSweep = Task { await poller.sweepForTest() }
        await readGate.waitForArrivals(1)

        // The profile is created, and its credential-change probe runs to
        // completion — so the gate's cache now knows the id.
        profiles.mutate { $0.append(token) }
        await poller.noteCredentialChanged(profileID: token.id)
        #expect(fetcher.tokenProbeCount == 1)

        // Only now does the stale read land, carrying a table that predates the
        // profile.
        await readGate.open()
        await staleSweep.value

        // The activity gate must still recognise the profile.
        clock.advance(301)
        await poller.noteSessionBecameIdle(profileID: token.id)
        #expect(fetcher.tokenProbeCount == 2)
    }
}
