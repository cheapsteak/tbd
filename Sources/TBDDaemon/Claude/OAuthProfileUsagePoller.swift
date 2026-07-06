import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "oauthUsagePoller")

/// Background poller for per-profile OAuth usage snapshots.
///
/// Complements `ClaudeUsagePoller` (which serves API-key profiles from
/// TBD-stored secrets on a 30-min cadence, persisted in the DB): this one
/// sweeps every logged-in OAuth profile roughly every 90 seconds using
/// CLI-mediated credentials (`LiveProfileUsageFetcher`), holding results
/// purely in memory — the spawn-time account picker renders instantly from
/// this cache and can force a fresh sweep via `modelProfile.usageRefresh`.
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

    /// Backoff schedule for a profile whose fetch failed. Doubles per
    /// consecutive failure, jittered, capped. A 429 with a `Retry-After`
    /// overrides this with the server's own value. Kept below the picker's
    /// stale threshold at the low end so a single hiccup doesn't visibly stall
    /// a profile.
    public static let baseBackoff: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 15 * 60

    // MARK: - Dependencies (closures so tests need no DB or filesystem)

    public typealias ProfilesProvider = @Sendable () async throws -> [ModelProfile]

    private let profilesProvider: ProfilesProvider
    private let loginIdentity: @Sendable (UUID) -> String?
    private let configDirPath: @Sendable (UUID) -> String
    private let fetcher: ProfileUsageFetching
    private let broadcast: @Sendable () -> Void
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let jitter: @Sendable (TimeInterval) -> TimeInterval

    // MARK: - State

    private var snapshots: [UUID: ProfileUsageSnapshot] = [:]
    private var loopTask: Task<Void, Never>?

    /// Per-profile backoff bookkeeping. `consecutiveFailures` drives the
    /// exponential schedule; `nextEligibleAt` is when a scheduled sweep may try
    /// this profile again. Isolated per profile so one account's rate limit
    /// never delays another's polling. A forced sweep (`sweepNow`) ignores this
    /// gate — the user explicitly asked.
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
        jitter: (@Sendable (TimeInterval) -> TimeInterval)? = nil
    ) {
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

    /// Launches the sweep loop. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancels the loop. Idempotent. Cached snapshots remain readable.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            // Scheduled sweeps honor per-profile backoff windows.
            await sweep(only: nil, forced: false)
            try? await sleeper(Self.cadence)
        }
    }

    // MARK: - Reads

    public func allSnapshots() -> [UUID: ProfileUsageSnapshot] { snapshots }

    public func snapshot(for profileID: UUID) -> ProfileUsageSnapshot? {
        snapshots[profileID]
    }

    // MARK: - Forced sweep (RPC `modelProfile.usageRefresh`)

    /// Fetch fresh usage now — all logged-in OAuth profiles when `profileID`
    /// is nil, or just the one profile. Returns the post-sweep snapshots
    /// (filtered to the requested profile when one was given).
    ///
    /// This is the user-explicit path (RPC `modelProfile.usageRefresh`), so it
    /// bypasses per-profile backoff windows — the user asked, so we try even a
    /// rate-limited profile.
    @discardableResult
    public func sweepNow(profileID: UUID? = nil) async -> [UUID: ProfileUsageSnapshot] {
        await sweep(only: profileID, forced: true)
        if let profileID {
            return snapshots.filter { $0.key == profileID }
        }
        return snapshots
    }

    /// Test seam: run the SCHEDULED sweep path (honoring backoff) synchronously,
    /// as the background loop would. Not part of the public runtime API.
    @discardableResult
    func sweepNow(profileID: UUID?, forcedForTest: Bool) async -> [UUID: ProfileUsageSnapshot] {
        await sweep(only: profileID, forced: forcedForTest)
        return snapshots
    }

    // MARK: - Sweep

    private func sweep(only: UUID?, forced: Bool) async {
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
        }

        // A forced sweep (only != nil) always tries the requested profile.
        // A scheduled sweep skips any profile still inside its backoff window,
        // so a rate-limited account isn't hammered every cadence tick — but the
        // stagger + isolation mean the others still poll normally.
        let candidates = only.map { id in eligible.filter { $0.id == id } } ?? eligible
        let currentTime = now()
        let targets = candidates.filter { profile in
            forced || isEligibleNow(profile.id, at: currentTime)
        }

        var didFetch = false
        for profile in targets {
            if didFetch {
                try? await sleeper(Self.interProfileStagger)
            }
            if Task.isCancelled { break }
            didFetch = true
            let status = await fetcher.fetchUsage(configDirPath: configDirPath(profile.id))
            record(status, for: profile.id)
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

    private func record(_ status: ProfileUsageFetchStatus, for profileID: UUID) {
        let timestamp = now()
        switch status {
        case .ok(let buckets):
            backoff[profileID] = BackoffState()  // reset schedule on success
            snapshots[profileID] = ProfileUsageSnapshot(
                buckets: buckets,
                fetchedAt: timestamp,
                lastAttemptAt: timestamp,
                status: "ok",
                statusKind: .ok
            )
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
