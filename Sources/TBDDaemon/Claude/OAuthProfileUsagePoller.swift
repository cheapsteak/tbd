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
/// - Cadence-swept profiles: `kind == .oauth` with a non-nil login identity
///   (someone has completed `/login` in the profile's isolated config dir).
/// - `kind == .oauthToken` profiles are deliberately NOT cadence-swept. Their
///   usage comes from the headers of a real billed request (a setup token 403s
///   on the read-only usage endpoint), so they refresh on a `working -> idle`
///   session transition instead — `noteSessionBecameIdle(profileID:)` — at most
///   once per `tokenProfileFloor`. They are still swept by a *targeted* sweep,
///   and still keep their snapshots across full sweeps.
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

    /// Floor between two usage probes of the same token profile.
    ///
    /// A `.oauthToken` profile's usage cannot be read from the read-only usage
    /// endpoint (a setup token 403s there); it comes from the headers of a real,
    /// billed `max_tokens: 0` request. So token profiles are kept off the
    /// cadence sweep entirely and refresh on session activity instead — and even
    /// then no more often than this, so a burst of turns collapses into one
    /// probe. Enforced for EVERY caller by `freshnessWindow(requested:kind:)`,
    /// including the picker-open refresh, which asks for a 30-second window.
    public static let tokenProfileFloor: TimeInterval = 300

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
    /// Serves `.oauthToken` profiles, whose usage comes from probe response
    /// headers rather than the OAuth usage endpoint.
    private let tokenFetcher: ProfileUsageFetching
    /// The stored `claude setup-token` for a `.oauthToken` profile, or nil when
    /// no secret is stored. Never logged, never included in an error string.
    private let profileSecret: @Sendable (UUID) -> String?
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
        tokenFetcher: ProfileUsageFetching = TokenProfileUsageFetcher(),
        profileSecret: @escaping @Sendable (UUID) -> String? = { _ in nil },
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
        self.tokenFetcher = tokenFetcher
        self.profileSecret = profileSecret
        self.broadcast = broadcast
        // swiftlint:disable:next no_raw_task_sleep - already seamed: this closure IS the default of the type's own `sleeper:` seam (which sits alongside the `now:` and `jitter:` seams), injected as `sleeper: { _ in }` at 6 sites in Tests/TBDDaemonTests/OAuthProfileUsagePollerTests.swift — but only the `sweep()` inter-profile stagger below is actually REACHED by those tests: no test calls `start()`, so `runLoop()`'s cadence use of this same closure is unexercised; see docs/specs/2026-07-24-test-hardening-design.md
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

    // MARK: - Activity-gated probes (token profiles)

    /// Called when a terminal using this profile transitions `working -> idle`:
    /// the moment a turn completed and utilization actually moved.
    ///
    /// Only `.oauthToken` profiles act on this. A signed-in profile is served
    /// by the 90-second cadence sweep and its usage endpoint is free to call,
    /// so there is nothing to gain by probing it here — and the guard is what
    /// keeps a busy fleet of `.oauth` sessions from turning every turn into a
    /// fetch.
    ///
    /// Probes at most once per `tokenProfileFloor`, so a burst of short turns
    /// collapses into one billed request. Per-profile backoff still applies on
    /// top of that, so a rejected or rate-limited token is not hammered by
    /// activity either.
    public func noteSessionBecameIdle(profileID: UUID) async {
        let profiles: [ModelProfile]
        do {
            profiles = try await profilesProvider()
        } catch {
            logger.warning("profile list failed; skipping activity probe: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let profile = profiles.first(where: { $0.id == profileID }),
              profile.kind == .oauthToken else { return }
        await sweep(only: profileID, skipFresherThan: Self.tokenProfileFloor)
    }

    /// Probe once for a freshly created token profile, so bars appear
    /// immediately and a bad paste is caught at once rather than at first
    /// spawn. Asking for no freshness window is safe: a profile that has never
    /// been fetched has no `fetchedAt` for the floor to compare against, and
    /// `freshnessWindow(requested:kind:)` re-imposes the floor on every later
    /// call regardless.
    public func noteProfileCreated(profileID: UUID) async {
        await sweep(only: profileID, skipFresherThan: nil)
    }

    // MARK: - Sweep

    /// The freshness window a sweep actually applies to one profile.
    ///
    /// For a token profile this is never shorter than `tokenProfileFloor`,
    /// whatever the caller asked for: the picker-open refresh asks for 30
    /// seconds, which is the right answer for a free GET and the wrong one for
    /// a billed probe. Enforcing it here rather than at each call site means
    /// there is one place a future caller can't forget.
    static func freshnessWindow(requested: TimeInterval?, kind: CredentialKind) -> TimeInterval? {
        guard kind == .oauthToken else { return requested }
        return max(requested ?? 0, tokenProfileFloor)
    }

    /// Whether this poller can fetch usage for the profile at all.
    ///
    /// Wider than the cadence-sweep filter: a token profile is supported (it is
    /// simply refreshed on a different trigger), so a full sweep's pruning must
    /// not mistake "not swept on cadence" for "no longer a profile" and delete
    /// its snapshot.
    private func isSupported(_ profile: ModelProfile) -> Bool {
        switch profile.kind {
        case .oauth: return loginIdentity(profile.id) != nil
        case .oauthToken: return true
        case .apiKey, .bedrock: return false
        }
    }

    private func credential(for profile: ModelProfile) -> ProfileUsageCredential? {
        switch profile.kind {
        case .oauth:
            return .configDir(configDirPath(profile.id))
        case .oauthToken:
            // An absent secret becomes an empty token deliberately: the fetcher
            // reports `.noCredentials`, which is recorded on the snapshot and
            // shown. Calling it "unsupported" here would instead silently prune
            // the profile's snapshot and tell the user nothing.
            return .token(profileSecret(profile.id) ?? "")
        case .apiKey, .bedrock:
            return nil
        }
    }

    private func sweep(only: UUID?, skipFresherThan: TimeInterval?) async {
        let allProfiles: [ModelProfile]
        do {
            allProfiles = try await profilesProvider()
        } catch {
            logger.warning("profile list failed; skipping usage sweep: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Deliberately `.oauth` only. Token profiles are NOT swept on cadence:
        // their probe is a real billed API request, so they refresh on session
        // activity instead (see `noteSessionBecameIdle`). Widening this filter
        // would defeat that gate and put every token profile back on a
        // ~960-request-per-day timer.
        let cadenceEligible = allProfiles.filter { $0.kind == .oauth && loginIdentity($0.id) != nil }
        let supported = allProfiles.filter { isSupported($0) }
        let supportedIDs = Set(supported.map(\.id))

        let before = snapshots

        // Full sweeps prune snapshots for profiles that were deleted, logged
        // out, or changed kind, so the RPC surface never leaks ghosts. The
        // retention set is the SUPPORTED one, not the cadence one — a token
        // profile keeps its snapshot between activity probes.
        if only == nil {
            snapshots = snapshots.filter { supportedIDs.contains($0.key) }
            backoff = backoff.filter { supportedIDs.contains($0.key) }
            if let prunePersisted {
                await prunePersisted(supportedIDs)
            }
        }

        // Every sweep skips profiles still inside their backoff window, so a
        // rate-limited account isn't hammered — by the cadence tick OR by the
        // picker-open RPC. Stagger + isolation mean the others still poll
        // normally. `skipFresherThan` additionally skips profiles whose data
        // is recent enough (startup sweep, picker-open refresh).
        //
        // A full sweep covers the cadence set; a targeted sweep may name any
        // SUPPORTED profile, which is how an activity-gated token probe and the
        // creation-time probe reach a profile the cadence deliberately skips.
        let candidates = only.map { id in supported.filter { $0.id == id } } ?? cadenceEligible
        let currentTime = now()
        let targets = candidates.filter { profile in
            guard isEligibleNow(profile.id, at: currentTime) else { return false }
            if let window = Self.freshnessWindow(requested: skipFresherThan, kind: profile.kind),
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
            guard let usageCredential = credential(for: profile) else { continue }
            didFetch = true
            // Dispatch by kind: a signed-in profile's usage comes from the
            // OAuth usage endpoint, a token profile's from probe response
            // headers. Neither fetcher knows the other exists.
            let usageFetcher: any ProfileUsageFetching =
                profile.kind == .oauthToken ? tokenFetcher : fetcher
            let status = await usageFetcher.fetchUsage(credential: usageCredential)
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
        case .ok(let buckets, let organizationID):
            backoff[profileID] = BackoffState()  // reset schedule on success
            let snapshot = ProfileUsageSnapshot(
                buckets: buckets,
                fetchedAt: timestamp,
                lastAttemptAt: timestamp,
                status: "ok",
                statusKind: .ok,
                organizationID: organizationID
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
                statusKind: status.kind,
                // Retained alongside the stale buckets it was observed with: a
                // failed fetch says nothing about which account the profile
                // belongs to.
                organizationID: previous?.organizationID
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
