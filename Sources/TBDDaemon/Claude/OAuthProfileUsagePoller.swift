import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "oauthUsagePoller")

/// Background poller for per-profile OAuth usage snapshots.
///
/// Complements `ClaudeUsagePoller` (which serves API-key profiles from
/// TBD-stored secrets on a 30-min cadence, persisted in the DB): this one
/// sweeps every logged-in OAuth profile roughly every 90 seconds using
/// CLI-mediated credentials (`LiveProfileUsageFetcher`). Results live in
/// memory and — on successful fetches — in a DB-backed cache
/// (`OAuthUsageSnapshotStore`), so a daemon restart shows the last-known
/// bars (stale) instead of "usage unavailable". The spawn-time account
/// picker renders instantly from this cache and can request a
/// refresh-if-stale sweep via `modelProfile.usageRefresh`.
///
/// Rules:
/// - Eligible profiles: `kind == .oauth` with a non-nil login identity
///   (someone has completed `/login` in the profile's isolated config dir).
/// - Per-profile calls within one sweep are staggered slightly.
/// - A failing profile records a status ("stale since X; fetch failed: …")
///   without poisoning the rest of the sweep; previously fetched buckets are
///   retained so the picker can show stale-but-real numbers.
/// - `broadcast` fires (once per sweep) only when snapshot data actually
///   changed — `lastAttemptAt` alone doesn't count, so a persistently failing
///   profile doesn't emit a delta every 90 s.
public actor OAuthProfileUsagePoller {

    // MARK: - Constants

    public static let cadence: TimeInterval = 90
    public static let interProfileStagger: TimeInterval = 2

    /// `sweepNow` (the RPC / picker-open path) skips profiles whose snapshot
    /// was fetched more recently than this — opening the picker repeatedly
    /// must not turn into a fetch per open.
    public static let refreshFreshness: TimeInterval = 30

    /// Backoff schedule for a profile whose fetch failed. Doubles per
    /// consecutive failure, jittered, capped. A 429 with a `Retry-After`
    /// overrides this with the server's own value. Kept below the picker's
    /// stale threshold at the low end so a single hiccup doesn't visibly stall
    /// a profile.
    public static let baseBackoff: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 15 * 60

    // MARK: - Dependencies (closures so tests need no DB or filesystem)

    public typealias ProfilesProvider = @Sendable () async throws -> [ModelProfile]
    public typealias SnapshotLoader = @Sendable () async -> [UUID: ProfileUsageSnapshot]
    public typealias SnapshotPersister = @Sendable (UUID, ProfileUsageSnapshot) async -> Void
    /// Deletes persisted rows for every profile NOT in the given set.
    public typealias SnapshotPruner = @Sendable (Set<UUID>) async -> Void

    private let profilesProvider: ProfilesProvider
    private let loginIdentity: @Sendable (UUID) -> String?
    private let configDirPath: @Sendable (UUID) -> String
    private let fetcher: ProfileUsageFetching
    private let broadcast: @Sendable () -> Void
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    /// Persistence seams (nil = memory-only, e.g. most tests). `loadPersisted`
    /// seeds the in-memory cache at `start()`; `persist` is called on every
    /// successful fetch. Backoff state is deliberately NOT persisted.
    private let loadPersisted: SnapshotLoader?
    private let persist: SnapshotPersister?
    /// Called on every full sweep with the eligible profile set, so DB rows
    /// for deleted/logged-out profiles don't reload as ghosts each restart.
    private let prunePersisted: SnapshotPruner?

    // MARK: - State

    private var snapshots: [UUID: ProfileUsageSnapshot] = [:]
    private var loopTask: Task<Void, Never>?
    /// Set before `start()`'s first suspension so a reentrant double-start
    /// can't launch a second loop.
    private var started = false

    /// Per-profile backoff bookkeeping. `consecutiveFailures` drives the
    /// exponential schedule; `nextEligibleAt` is when a sweep may try this
    /// profile again. Isolated per profile so one account's rate limit never
    /// delays another's polling. Every sweep honors this gate — including the
    /// picker-open RPC path (`sweepNow`), which must not re-hammer a
    /// rate-limited endpoint. In-memory only; a daemon restart resets it.
    private struct BackoffState {
        var consecutiveFailures: Int = 0
        var nextEligibleAt: Date?
    }
    private var backoff: [UUID: BackoffState] = [:]

    // MARK: - Init

    public init(
        profilesProvider: @escaping ProfilesProvider,
        loginIdentity: @escaping @Sendable (UUID) -> String?,
        configDirPath: @escaping @Sendable (UUID) -> String,
        fetcher: ProfileUsageFetching,
        broadcast: @escaping @Sendable () -> Void,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil,
        jitter: (@Sendable (TimeInterval) -> TimeInterval)? = nil,
        loadPersisted: SnapshotLoader? = nil,
        persist: SnapshotPersister? = nil,
        prunePersisted: SnapshotPruner? = nil
    ) {
        self.loadPersisted = loadPersisted
        self.persist = persist
        self.prunePersisted = prunePersisted
        self.profilesProvider = profilesProvider
        self.loginIdentity = loginIdentity
        self.configDirPath = configDirPath
        self.fetcher = fetcher
        self.broadcast = broadcast
        self.sleeper = sleeper ?? { try await Task.sleep(for: .seconds($0)) }
        self.now = now ?? { Date() }
        // Default jitter: uniform in [0, span). Injectable for deterministic
        // tests. Applied additively to the base backoff so synchronized
        // failures across profiles don't retry in lockstep.
        self.jitter = jitter ?? { span in span <= 0 ? 0 : Double.random(in: 0..<span) }
    }

    // MARK: - Lifecycle

    /// Loads persisted snapshots (so readers immediately see last-known data,
    /// stale or not), then launches the sweep loop. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        await loadPersistedSnapshots()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancels the loop. Idempotent. Cached snapshots remain readable.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        started = false
    }

    private func runLoop() async {
        // Startup sweep: skip profiles whose persisted snapshot is younger
        // than the cadence — they'd have been swept at most one tick ago by
        // the previous daemon, and the next scheduled sweep covers them.
        var skipFresherThan: TimeInterval? = Self.cadence
        while !Task.isCancelled {
            // Scheduled sweeps honor per-profile backoff windows.
            await sweep(only: nil, skipFresherThan: skipFresherThan)
            skipFresherThan = nil
            try? await sleeper(Self.cadence)
        }
    }

    /// Seed the in-memory cache from the DB-backed store before any sweep.
    /// Ineligible ghosts (deleted profiles, logged-out accounts) are pruned —
    /// from memory AND their persisted rows — by the first full sweep.
    ///
    /// Actors are reentrant across the `await`: an RPC-triggered `sweepNow`
    /// can fetch fresher data while the load is in flight. So the result is
    /// MERGED per profile, keeping whichever snapshot has the newer
    /// `fetchedAt`, never replacing the dict wholesale.
    private func loadPersistedSnapshots() async {
        guard let loadPersisted else { return }
        let loaded = await loadPersisted()
        var changed = false
        for (id, persisted) in loaded {
            if let current = snapshots[id],
               (current.fetchedAt ?? .distantPast) >= (persisted.fetchedAt ?? .distantPast) {
                continue
            }
            snapshots[id] = persisted
            changed = true
        }
        if changed { broadcast() }
    }

    // MARK: - Reads

    public func allSnapshots() -> [UUID: ProfileUsageSnapshot] { snapshots }

    public func snapshot(for profileID: UUID) -> ProfileUsageSnapshot? {
        snapshots[profileID]
    }

    // MARK: - Refresh-if-stale sweep (RPC `modelProfile.usageRefresh`)

    /// Refresh usage for stale, eligible profiles — all logged-in OAuth
    /// profiles when `profileID` is nil, or just the one profile. Returns the
    /// post-sweep snapshots (filtered to the requested profile when one was
    /// given).
    ///
    /// This is the RPC path (`modelProfile.usageRefresh`, fired on every
    /// picker open and by `tbd profile list --refresh`). It does NOT bypass
    /// per-profile backoff windows — opening the picker against a 429ing
    /// endpoint must not re-hammer it — and skips profiles whose snapshot is
    /// younger than `refreshFreshness`.
    @discardableResult
    public func sweepNow(profileID: UUID? = nil) async -> [UUID: ProfileUsageSnapshot] {
        await sweep(only: profileID, skipFresherThan: Self.refreshFreshness)
        if let profileID {
            return snapshots.filter { $0.key == profileID }
        }
        return snapshots
    }

    /// Test seams. Not part of the public runtime API.
    @discardableResult
    func sweepForTest(only: UUID? = nil,
                      skipFresherThan: TimeInterval? = nil) async -> [UUID: ProfileUsageSnapshot] {
        await sweep(only: only, skipFresherThan: skipFresherThan)
        return snapshots
    }

    func loadPersistedForTest() async {
        await loadPersistedSnapshots()
    }

    // MARK: - Sweep

    private func sweep(only: UUID?, skipFresherThan: TimeInterval?) async {
        let allProfiles: [ModelProfile]
        do {
            allProfiles = try await profilesProvider()
        } catch {
            logger.warning("profile list failed; skipping usage sweep: \(error.localizedDescription, privacy: .public)")
            return
        }

        let eligible = allProfiles.filter { $0.kind == .oauth && loginIdentity($0.id) != nil }
        let eligibleIDs = Set(eligible.map(\.id))

        let before = snapshots

        // Full sweeps prune snapshots for profiles that were deleted, logged
        // out, or changed kind, so the RPC surface never leaks ghosts.
        if only == nil {
            snapshots = snapshots.filter { eligibleIDs.contains($0.key) }
            backoff = backoff.filter { eligibleIDs.contains($0.key) }
            if let prunePersisted {
                await prunePersisted(eligibleIDs)
            }
        }

        // Every sweep skips profiles still inside their backoff window, so a
        // rate-limited account isn't hammered — by the cadence tick OR by the
        // picker-open RPC. Stagger + isolation mean the others still poll
        // normally. `skipFresherThan` additionally skips profiles whose data
        // is recent enough (startup sweep, picker-open refresh).
        let candidates = only.map { id in eligible.filter { $0.id == id } } ?? eligible
        let currentTime = now()
        let targets = candidates.filter { profile in
            guard isEligibleNow(profile.id, at: currentTime) else { return false }
            if let window = skipFresherThan,
               let fetchedAt = snapshots[profile.id]?.fetchedAt,
               currentTime.timeIntervalSince(fetchedAt) < window {
                return false
            }
            return true
        }

        var didFetch = false
        for profile in targets {
            if didFetch {
                try? await sleeper(Self.interProfileStagger)
            }
            if Task.isCancelled { break }
            didFetch = true
            let status = await fetcher.fetchUsage(configDirPath: configDirPath(profile.id))
            await record(status, for: profile.id)
        }

        if hasMeaningfulChange(from: before, to: snapshots) {
            broadcast()
        }
    }

    /// Whether a scheduled sweep may attempt this profile now (its backoff
    /// window, if any, has elapsed).
    private func isEligibleNow(_ profileID: UUID, at time: Date) -> Bool {
        guard let next = backoff[profileID]?.nextEligibleAt else { return true }
        return time >= next
    }

    private func record(_ status: ProfileUsageFetchStatus, for profileID: UUID) async {
        let timestamp = now()
        switch status {
        case .ok(let buckets):
            backoff[profileID] = BackoffState()  // reset schedule on success
            let snapshot = ProfileUsageSnapshot(
                buckets: buckets,
                fetchedAt: timestamp,
                lastAttemptAt: timestamp,
                status: "ok",
                statusKind: .ok
            )
            snapshots[profileID] = snapshot
            if let persist {
                await persist(profileID, snapshot)
            }
            logger.debug("usage sweep ok for profile \(profileID, privacy: .public): \(buckets.count, privacy: .public) buckets")
        default:
            let reason = status.failureReason ?? "unknown"
            let previous = snapshots[profileID]
            let statusText: String
            if let fetchedAt = previous?.fetchedAt {
                statusText = "stale since \(Self.iso8601String(from: fetchedAt)); fetch failed: \(reason)"
            } else {
                statusText = "fetch failed: \(reason)"
            }
            scheduleBackoff(for: profileID, status: status, at: timestamp)
            snapshots[profileID] = ProfileUsageSnapshot(
                buckets: previous?.buckets ?? [],
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: timestamp,
                status: statusText,
                statusKind: status.kind
            )
            logger.warning("usage sweep failed for profile \(profileID, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Advance a profile's backoff after a failure. Honors a 429 `Retry-After`
    /// verbatim; otherwise uses exponential backoff (base·2^failures) plus
    /// additive jitter, capped at `maxBackoff`. `needsLogin`/`noCredentials`
    /// aren't retry-worthy at high frequency, so they also back off (they'll
    /// clear when the user re-logs in and the identity/credential reappears).
    private func scheduleBackoff(for profileID: UUID, status: ProfileUsageFetchStatus, at time: Date) {
        var state = backoff[profileID] ?? BackoffState()
        state.consecutiveFailures += 1
        let delay: TimeInterval
        if let retryAfter = status.retryAfter, retryAfter > 0 {
            delay = min(retryAfter, Self.maxBackoff)
        } else {
            let exponent = Double(min(state.consecutiveFailures - 1, 10))
            let raw = Self.baseBackoff * pow(2, exponent)
            let capped = min(raw, Self.maxBackoff)
            delay = min(capped + jitter(Self.baseBackoff), Self.maxBackoff)
        }
        state.nextEligibleAt = time.addingTimeInterval(delay)
        backoff[profileID] = state
    }

    /// Snapshot change comparison ignoring `lastAttemptAt`, so repeated
    /// identical failures don't re-broadcast every sweep.
    private func hasMeaningfulChange(
        from before: [UUID: ProfileUsageSnapshot],
        to after: [UUID: ProfileUsageSnapshot]
    ) -> Bool {
        guard before.count == after.count else { return true }
        for (id, new) in after {
            guard let old = before[id] else { return true }
            if old.buckets != new.buckets || old.fetchedAt != new.fetchedAt || old.status != new.status {
                return true
            }
        }
        return false
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
