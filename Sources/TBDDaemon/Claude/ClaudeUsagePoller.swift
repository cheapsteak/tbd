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

    private let tokens: ClaudeTokenStore
    private let usage: ClaudeTokenUsageStore
    private let keychain: @Sendable (String) throws -> String?
    private let fetcher: ClaudeUsageFetcher
    private let clock: PollerClock
    private let broadcast: @Sendable (ClaudeTokenUsage) -> Void
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
    /// Tokens that returned HTTP 401 and must never be polled again until restart.
    private var permanentlyExcluded: Set<String> = []

    // MARK: - Init

    public init(
        tokens: ClaudeTokenStore,
        usage: ClaudeTokenUsageStore,
        keychain: @escaping @Sendable (String) throws -> String?,
        fetcher: ClaudeUsageFetcher,
        clock: PollerClock,
        broadcast: @escaping @Sendable (ClaudeTokenUsage) -> Void,
        staggerProvider: (@Sendable () -> TimeInterval)? = nil
    ) {
        self.tokens = tokens
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

    /// Single-token poke (used by RPC fetchUsage handler).
    public func poke(tokenID: String) async {
        guard var entry = schedule[tokenID], !entry.excluded else { return }
        entry.nextFireAt = clock.now()
        schedule[tokenID] = entry
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

            // Tick all tokens that are due now.
            let now = clock.now()
            let due = schedule
                .filter { !$0.value.excluded && $0.value.nextFireAt <= now }
                .map { $0.key }
            for tokenID in due {
                await tick(tokenID: tokenID)
            }
        }
    }

    private func waitIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleWakeContinuation = cont
        }
    }

    /// Re-read tokens from the store, add new oauth tokens to schedule,
    /// drop missing/api_key tokens.
    private func refreshSchedule() async {
        let allTokens: [ClaudeToken]
        do {
            allTokens = try await tokens.list()
        } catch {
            return
        }
        let oauthIDs = Set(allTokens.filter { $0.kind == .oauth }.map { $0.id.uuidString })

        // Drop tokens no longer present or no longer oauth.
        for key in schedule.keys where !oauthIDs.contains(key) {
            schedule.removeValue(forKey: key)
        }
        // Add new tokens with stagger.
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

    private func tick(tokenID: String) async {
        // 1. Confirm still exists & is oauth.
        guard let uuid = UUID(uuidString: tokenID) else {
            schedule.removeValue(forKey: tokenID)
            return
        }
        let row: ClaudeToken?
        do {
            row = try await tokens.get(id: uuid)
        } catch {
            return
        }
        guard let token = row, token.kind == .oauth else {
            schedule.removeValue(forKey: tokenID)
            return
        }

        var entry = schedule[tokenID] ?? Entry(nextFireAt: clock.now(), backoffActive: false, excluded: false)
        let now = clock.now()

        // 2. Dedupe against fetched_at.
        if let cached = try? await usage.get(tokenID: uuid),
           let fetchedAt = cached.fetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.dedupeWindow {
            entry.nextFireAt = now.addingTimeInterval(entry.backoffActive ? Self.backoff : Self.cadence)
            schedule[tokenID] = entry
            return
        }

        // 3. Load secret.
        let secret: String?
        do {
            secret = try keychain(tokenID)
        } catch {
            entry.nextFireAt = now.addingTimeInterval(Self.cadence)
            schedule[tokenID] = entry
            return
        }
        guard let bytes = secret else {
            entry.nextFireAt = now.addingTimeInterval(Self.cadence)
            schedule[tokenID] = entry
            return
        }

        // 4. Fetch.
        let status = await fetcher.fetchUsage(token: bytes)

        // 5. Branch on result.
        switch status {
        case .ok(let result):
            let updated = ClaudeTokenUsage(
                tokenID: uuid,
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
            loggedBackoff.remove(tokenID)
            entry.nextFireAt = clock.now().addingTimeInterval(Self.cadence)
            schedule[tokenID] = entry

        case .http429:
            // Preserve cached pcts; only update status + fetched_at.
            let cached = try? await usage.get(tokenID: uuid)
            let updated = ClaudeTokenUsage(
                tokenID: uuid,
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
            if !loggedBackoff.contains(tokenID) {
                loggedBackoff.insert(tokenID)
                logger.warning("429 backoff for token \(tokenID)")
            }
            entry.nextFireAt = clock.now().addingTimeInterval(Self.backoff)
            schedule[tokenID] = entry

        case .http401:
            let cached = try? await usage.get(tokenID: uuid)
            let updated = ClaudeTokenUsage(
                tokenID: uuid,
                fiveHourPct: cached?.fiveHourPct,
                sevenDayPct: cached?.sevenDayPct,
                fiveHourResetsAt: cached?.fiveHourResetsAt,
                sevenDayResetsAt: cached?.sevenDayResetsAt,
                fetchedAt: clock.now(),
                lastStatus: "http_401"
            )
            try? await usage.upsert(updated)
            broadcast(updated)
            permanentlyExcluded.insert(tokenID)
            schedule.removeValue(forKey: tokenID)

        case .networkError:
            let cached = try? await usage.get(tokenID: uuid)
            let updated = ClaudeTokenUsage(
                tokenID: uuid,
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
            schedule[tokenID] = entry

        case .decodeError:
            entry.nextFireAt = clock.now().addingTimeInterval(entry.backoffActive ? Self.backoff : Self.cadence)
            schedule[tokenID] = entry
        }
    }
}
