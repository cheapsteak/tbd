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

    // MARK: - Dependencies (closures so tests need no DB or filesystem)

    public typealias ProfilesProvider = @Sendable () async throws -> [ModelProfile]

    private let profilesProvider: ProfilesProvider
    private let loginIdentity: @Sendable (UUID) -> String?
    private let configDirPath: @Sendable (UUID) -> String
    private let fetcher: ProfileUsageFetching
    private let broadcast: @Sendable () -> Void
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    // MARK: - State

    private var snapshots: [UUID: ProfileUsageSnapshot] = [:]
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        profilesProvider: @escaping ProfilesProvider,
        loginIdentity: @escaping @Sendable (UUID) -> String?,
        configDirPath: @escaping @Sendable (UUID) -> String,
        fetcher: ProfileUsageFetching,
        broadcast: @escaping @Sendable () -> Void,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil
    ) {
        self.profilesProvider = profilesProvider
        self.loginIdentity = loginIdentity
        self.configDirPath = configDirPath
        self.fetcher = fetcher
        self.broadcast = broadcast
        self.sleeper = sleeper ?? { try await Task.sleep(for: .seconds($0)) }
        self.now = now ?? { Date() }
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
            await sweep(only: nil)
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
    @discardableResult
    public func sweepNow(profileID: UUID? = nil) async -> [UUID: ProfileUsageSnapshot] {
        await sweep(only: profileID)
        if let profileID {
            return snapshots.filter { $0.key == profileID }
        }
        return snapshots
    }

    // MARK: - Sweep

    private func sweep(only: UUID?) async {
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
        }

        let targets = only.map { id in eligible.filter { $0.id == id } } ?? eligible

        for (index, profile) in targets.enumerated() {
            if index > 0 {
                try? await sleeper(Self.interProfileStagger)
            }
            if Task.isCancelled { break }
            let status = await fetcher.fetchUsage(configDirPath: configDirPath(profile.id))
            record(status, for: profile.id)
        }

        if hasMeaningfulChange(from: before, to: snapshots) {
            broadcast()
        }
    }

    private func record(_ status: ProfileUsageFetchStatus, for profileID: UUID) {
        let timestamp = now()
        switch status {
        case .ok(let buckets):
            snapshots[profileID] = ProfileUsageSnapshot(
                buckets: buckets,
                fetchedAt: timestamp,
                lastAttemptAt: timestamp,
                status: "ok"
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
            snapshots[profileID] = ProfileUsageSnapshot(
                buckets: previous?.buckets ?? [],
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: timestamp,
                status: statusText
            )
            logger.warning("usage sweep failed for profile \(profileID, privacy: .public): \(reason, privacy: .public)")
        }
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
