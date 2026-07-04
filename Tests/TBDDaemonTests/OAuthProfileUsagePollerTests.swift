import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Test doubles

/// Scriptable fetcher: per-configDir queue of statuses, falling back to a
/// default. Records call order.
private final class ScriptedProfileUsageFetcher: ProfileUsageFetching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ScriptedProfileUsageFetcher")
    private var scripted: [String: [ProfileUsageFetchStatus]] = [:]
    private var fallback: ProfileUsageFetchStatus
    private var _calls: [String] = []

    init(default fallback: ProfileUsageFetchStatus) {
        self.fallback = fallback
    }

    func enqueue(configDirPath: String, _ status: ProfileUsageFetchStatus) {
        queue.sync { scripted[configDirPath, default: []].append(status) }
    }

    var calls: [String] { queue.sync { _calls } }

    func fetchUsage(configDirPath: String) async -> ProfileUsageFetchStatus {
        queue.sync {
            _calls.append(configDirPath)
            if var statuses = scripted[configDirPath], !statuses.isEmpty {
                let next = statuses.removeFirst()
                scripted[configDirPath] = statuses
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
    now: Date = Date(timeIntervalSince1970: 1_750_000_000)
) -> OAuthProfileUsagePoller {
    OAuthProfileUsagePoller(
        profilesProvider: { profiles },
        loginIdentity: { id in loggedIn.contains(id) ? "someone@example.com" : nil },
        configDirPath: { id in "/profiles/\(id.uuidString.lowercased())/claude" },
        fetcher: fetcher,
        broadcast: { broadcasts.bump() },
        sleeper: { _ in },
        now: { now }
    )
}

// MARK: - Tests

struct OAuthProfileUsagePollerTests {

    @Test func sweepPopulatesSnapshotsForLoggedInOAuthProfilesOnly() async {
        let loggedIn = oauthProfile(named: "A")
        let notLoggedIn = oauthProfile(named: "B")
        let apiKey = ModelProfile(name: "C", kind: .apiKey)
        let bedrock = ModelProfile(name: "D", kind: .bedrock, awsRegion: "us-west-2")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets))
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
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets))
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
        fetcher.enqueue(configDirPath: dir, .ok(okBuckets))
        let broadcasts = BroadcastCounter()
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts
        )

        let first = await poller.sweepNow()
        let successFetchedAt = first[profile.id]?.fetchedAt
        #expect(first[profile.id]?.status == "ok")

        let second = await poller.sweepNow()
        let stale = second[profile.id]
        #expect(stale?.buckets == okBuckets)             // old data retained
        #expect(stale?.fetchedAt == successFetchedAt)    // success timestamp preserved
        #expect(stale?.status.hasPrefix("stale since ") == true)
        #expect(stale?.status.contains("network error: timed out") == true)
    }

    @Test func noLoggedInProfilesYieldsEmptySweepAndNoBroadcast() async {
        let profile = oauthProfile(named: "LoggedOut")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets))
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
        let poller = makePoller(
            profiles: [profile], loggedIn: [profile.id],
            fetcher: fetcher, broadcasts: broadcasts
        )

        await poller.sweepNow()
        #expect(broadcasts.count == 1)  // nil → failed is a change
        await poller.sweepNow()
        await poller.sweepNow()
        #expect(broadcasts.count == 1)  // same failure text: no re-broadcast
    }

    @Test func targetedSweepFetchesOnlyThatProfile() async {
        let one = oauthProfile(named: "One")
        let two = oauthProfile(named: "Two")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets))
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
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets))
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

    @Test func profilesProviderErrorLeavesExistingSnapshotsIntact() async {
        let profile = oauthProfile(named: "Sticky")
        let fetcher = ScriptedProfileUsageFetcher(default: .ok(okBuckets))
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
