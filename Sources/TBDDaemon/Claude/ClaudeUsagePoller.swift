import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "usagePoller")

/// Background poller that keeps `claude_token_usage` rows fresh for OAuth tokens.
///
/// Rules (from spec "Usage fetching"):
/// - OAuth only; api_key kind is skipped permanently.
/// - Default cadence: 30 min per token.
/// - Startup stagger: first poll for each token at random(0..30s) from start().
/// - HTTP 429 → next poll 60 min out; first success after that reverts to 30 min.
/// - HTTP 401 → stop polling that token entirely.
/// - Focus loss > 10 min → pause loop. On focus regained, resume + pokeAll.
/// - Dedupe: if fetched_at < 60 s ago, skip the network call.
public actor ClaudeUsagePoller {

    // MARK: - Constants

    public static let cadence: TimeInterval = 30 * 60      // 30 minutes
    public static let backoff: TimeInterval = 60 * 60      // 60 minutes
    public static let stagger: TimeInterval = 30           // 30 seconds
    public static let dedupeWindow: TimeInterval = 60      // 60 seconds
    public static let focusPauseThreshold: TimeInterval = 10 * 60 // 10 minutes

    // MARK: - Per-token schedule entry

    struct Entry {
        var nextFireAt: Date
        var backoffActive: Bool
        var excluded: Bool
    }

    // MARK: - Dependencies

    private let profiles: ModelProfileStore
    private let usage: ModelProfileUsageStore
    private let keychain: @Sendable (String) throws -> String?
    private let fetcher: ClaudeUsageFetcher
    private let clock: PollerClock
    private let broadcast: @Sendable (ModelProfileUsage) -> Void
    /// Optional jitter override for tests; production uses `Double.random`.
    private let staggerProvider: @Sendable () -> TimeInterval

    // MARK: - State

    private var schedule: [String: Entry] = [:]
    private var loopTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastFocusLostAt: Date?
    /// Resumed when an idle loop (no schedule entries, or paused) should wake.
    private var idleWakeContinuation: CheckedContinuation<Void, Never>?
    /// In-flight sleep task; cancelled by `wake()` to interrupt the current sleep.
    private var currentSleepTask: Task<Void, Error>?
    private var loggedBackoff: Set<String> = []
    /// Profiles that returned HTTP 401 and must never be polled again until restart.
    private var permanentlyExcluded: Set<String> = []

    // MARK: - Init

    public init(
        profiles: ModelProfileStore,
        usage: ModelProfileUsageStore,
        keychain: @escaping @Sendable (String) throws -> String?,
        fetcher: ClaudeUsageFetcher,
        clock: PollerClock,
        broadcast: @escaping @Sendable (ModelProfileUsage) -> Void,
        staggerProvider: (@Sendable () -> TimeInterval)? = nil
    ) {
        self.profiles = profiles
        self.usage = usage
        self.keychain = keychain
        self.fetcher = fetcher
        self.clock = clock
        self.broadcast = broadcast
        self.staggerProvider = staggerProvider ?? { Double.random(in: 0..<Self.stagger) }
    }

    // MARK: - Lifecycle

    /// Initial population of the schedule from the token store, then launches loop.
    /// Idempotent: if already started, does nothing.
    public func start() async {
        guard loopTask == nil else { return }
        await refreshSchedule()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancels the loop. Idempotent.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentSleepTask?.cancel()
        currentSleepTask = nil
        if let cont = idleWakeContinuation {
            idleWakeContinuation = nil
            cont.resume()
        }
        schedule.removeAll()
    }

    // MARK: - External signals

    /// App focus changed. `false` records the timestamp; `true` clears it,
    /// resumes if paused, and pokes all eligible tokens.
    public func onFocusChanged(isForeground: Bool) async {
        if isForeground {
            lastFocusLostAt = nil
            isPaused = false
            if let cont = idleWakeContinuation {
                idleWakeContinuation = nil
                cont.resume()
            }
            await pokeAll()
        } else {
            lastFocusLostAt = clock.now()
        }
    }

    /// Set every non-excluded entry's `nextFireAt = now` and wake the loop.
    public func pokeAll() async {
        let now = clock.now()
        for key in schedule.keys {
            guard var entry = schedule[key], !entry.excluded else { continue }
            entry.nextFireAt = now
            schedule[key] = entry
        }
        wake()
    }

    /// Single-profile poke (used by RPC fetchUsage handler).
    public func poke(profileID: String) async {
        guard var entry = schedule[profileID], !entry.excluded else { return }
        entry.nextFireAt = clock.now()
        schedule[profileID] = entry
        wake()
    }

    // MARK: - Test introspection

    /// For tests: snapshot schedule.
    func _scheduleSnapshot() -> [String: Entry] { schedule }
    func _isPaused() -> Bool { isPaused }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshSchedule()

            // Focus pause check.
            if let lostAt = lastFocusLostAt,
               clock.now().timeIntervalSince(lostAt) > Self.focusPauseThreshold {
                isPaused = true
            }
            if isPaused {
                await waitIdle()
                if Task.isCancelled { return }
                continue
            }

            // Pick earliest non-excluded entry.
            let eligible = schedule.filter { !$0.value.excluded }
            guard let next = eligible.min(by: { $0.value.nextFireAt < $1.value.nextFireAt }) else {
                await waitIdle()
                if Task.isCancelled { return }
                continue
            }

            // Sleep until the earliest deadline. Stash the sleep task so wake()
            // can cancel it without killing the loop task itself.
            let deadline = next.value.nextFireAt
            let clock = self.clock
            let sleepTask = Task<Void, Error> {
                try await clock.sleep(until: deadline)
            }
            currentSleepTask = sleepTask
            _ = try? await sleepTask.value
            currentSleepTask = nil
            if Task.isCancelled { return }

            // Tick all profiles that are due now.
            let now = clock.now()
            let due = schedule
                .filter { !$0.value.excluded && $0.value.nextFireAt <= now }
                .map { $0.key }
            for profileID in due {
                await tick(profileID: profileID)
            }
        }
    }

    private func waitIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleWakeContinuation = cont
        }
    }

    /// Re-read profiles from the store, add new oauth profiles (Claude direct
    /// only — `baseURL == nil`) to the schedule, drop missing / api_key /
    /// proxy-routed profiles.
    private func refreshSchedule() async {
        let allProfiles: [ModelProfile]
        do {
            allProfiles = try await profiles.list()
        } catch {
            return
        }
        // Only poll OAuth profiles that target Claude direct (baseURL == nil).
        // Proxy-routed profiles can't use the Claude API usage endpoint —
        // cross-profile cost tracking is out of scope per the spec.
        let oauthIDs = Set(
            allProfiles
                .filter { $0.kind == .oauth && $0.baseURL == nil }
                .map { $0.id.uuidString }
        )

        // Drop profiles no longer present, or no longer eligible.
        for key in schedule.keys where !oauthIDs.contains(key) {
            schedule.removeValue(forKey: key)
        }
        // Add new profiles with stagger.
        let now = clock.now()
        for id in oauthIDs where schedule[id] == nil && !permanentlyExcluded.contains(id) {
            schedule[id] = Entry(
                nextFireAt: now.addingTimeInterval(staggerProvider()),
                backoffActive: false,
                excluded: false
            )
        }
    }

    private func wake() {
        if let cont = idleWakeContinuation {
            idleWakeContinuation = nil
            cont.resume()
        }
        currentSleepTask?.cancel()
        currentSleepTask = nil
    }

    // MARK: - Tick (single-token fetch)

    private func tick(profileID: String) async {
        // 1. Confirm still exists, is oauth, and is Claude direct.
        guard let uuid = UUID(uuidString: profileID) else {
            schedule.removeValue(forKey: profileID)
            return
        }
        let row: ModelProfile?
        do {
            row = try await profiles.get(id: uuid)
        } catch {
            return
        }
        guard let profile = row, profile.kind == .oauth, profile.baseURL == nil else {
            schedule.removeValue(forKey: profileID)
            return
        }

        var entry = schedule[profileID] ?? Entry(nextFireAt: clock.now(), backoffActive: false, excluded: false)
        let now = clock.now()

        // 2. Dedupe against fetched_at.
        if let cached = try? await usage.get(profileID: uuid),
           let fetchedAt = cached.fetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.dedupeWindow {
            entry.nextFireAt = now.addingTimeInterval(entry.backoffActive ? Self.backoff : Self.cadence)
            schedule[profileID] = entry
            return
        }

        // 3. Load secret.
        let secret: String?
        do {
            secret = try keychain(profileID)
        } catch {
            entry.nextFireAt = now.addingTimeInterval(Self.cadence)
            schedule[profileID] = entry
            return
        }
        guard let bytes = secret else {
            entry.nextFireAt = now.addingTimeInterval(Self.cadence)
            schedule[profileID] = entry
            return
        }

        // 4. Fetch.
        let status = await fetcher.fetchUsage(token: bytes)

        // 5. Branch on result.
        switch status {
        case .ok(let result):
            let updated = ModelProfileUsage(
                profileID: uuid,
                fiveHourPct: result.fiveHourPct,
                sevenDayPct: result.sevenDayPct,
                fiveHourResetsAt: result.fiveHourResetsAt,
                sevenDayResetsAt: result.sevenDayResetsAt,
                fetchedAt: clock.now(),
                lastStatus: "ok"
            )
            try? await usage.upsert(updated)
            broadcast(updated)
            entry.backoffActive = false
            loggedBackoff.remove(profileID)
            entry.nextFireAt = clock.now().addingTimeInterval(Self.cadence)
            schedule[profileID] = entry

        case .http429:
            // Preserve cached pcts; only update status + fetched_at.
            let cached = try? await usage.get(profileID: uuid)
            let updated = ModelProfileUsage(
                profileID: uuid,
                fiveHourPct: cached?.fiveHourPct,
                sevenDayPct: cached?.sevenDayPct,
                fiveHourResetsAt: cached?.fiveHourResetsAt,
                sevenDayResetsAt: cached?.sevenDayResetsAt,
                fetchedAt: clock.now(),
                lastStatus: "http_429"
            )
            try? await usage.upsert(updated)
            broadcast(updated)
            entry.backoffActive = true
            if !loggedBackoff.contains(profileID) {
                loggedBackoff.insert(profileID)
                logger.warning("429 backoff for profile \(profileID, privacy: .public)")
            }
            entry.nextFireAt = clock.now().addingTimeInterval(Self.backoff)
            schedule[profileID] = entry

        case .http401:
            let cached = try? await usage.get(profileID: uuid)
            let updated = ModelProfileUsage(
                profileID: uuid,
                fiveHourPct: cached?.fiveHourPct,
                sevenDayPct: cached?.sevenDayPct,
                fiveHourResetsAt: cached?.fiveHourResetsAt,
                sevenDayResetsAt: cached?.sevenDayResetsAt,
                fetchedAt: clock.now(),
                lastStatus: "http_401"
            )
            try? await usage.upsert(updated)
            broadcast(updated)
            permanentlyExcluded.insert(profileID)
            schedule.removeValue(forKey: profileID)

        case .networkError:
            let cached = try? await usage.get(profileID: uuid)
            let updated = ModelProfileUsage(
                profileID: uuid,
                fiveHourPct: cached?.fiveHourPct,
                sevenDayPct: cached?.sevenDayPct,
                fiveHourResetsAt: cached?.fiveHourResetsAt,
                sevenDayResetsAt: cached?.sevenDayResetsAt,
                fetchedAt: clock.now(),
                lastStatus: "network_error"
            )
            try? await usage.upsert(updated)
            broadcast(updated)
            entry.nextFireAt = clock.now().addingTimeInterval(entry.backoffActive ? Self.backoff : Self.cadence)
            schedule[profileID] = entry

        case .decodeError:
            entry.nextFireAt = clock.now().addingTimeInterval(entry.backoffActive ? Self.backoff : Self.cadence)
            schedule[profileID] = entry
        }
    }
}
