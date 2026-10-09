import Foundation
import os
import TBDShared

private let syncLogger = Logger(subsystem: "com.tbd.daemon", category: "remote-transcript")

/// Why a sync stopped short of what it was asked to do. Pages persisted before
/// the failure stay persisted; the next sync resumes from the stored cursor.
enum RemoteTranscriptSyncError: Error, Equatable, LocalizedError {
    /// The provider exited non-zero. `message` is its contract error message
    /// when it emitted one, otherwise a description of the exit.
    case providerFailed(message: String)
    /// The session was deleted or dismissed while this sync was running, and
    /// its cache was discarded; the page fetched meanwhile was dropped rather
    /// than written back into a directory nothing tracks any more.
    case discarded
    /// A `--before` read answered `cursor_expired`: the provider can no longer
    /// page from the cache's `before`. `loadEarlier` reports it as the
    /// `expired` outcome rather than throwing it.
    case cursorExpired

    var errorDescription: String? {
        switch self {
        case .providerFailed(let message): return message
        case .discarded: return "the session was removed; its transcript cache was discarded"
        case .cursorExpired: return "earlier history is no longer available"
        }
    }
}

/// What one sync is allowed to do, resolved fresh for every sync
/// (§ `RemoteTranscriptSync` and § Gating).
///
/// - `liveSyncEnabled` — the `remote_transcript_live_sync_enabled` flag, read
///   at this decision, never cached.
/// - `tailDeclared` — the provider declared `transcript.tail`.
/// - `hint` — the session's current transcript hint from
///   `RemoteTranscriptHints`, nil when unknown. Recorded at a caught-up sync
///   whatever the flag says; only `tailMode` lets it drive a decision.
struct RemoteTranscriptSyncPolicy: Equatable, Sendable {
    var liveSyncEnabled: Bool
    var tailDeclared: Bool
    var hint: RemoteTranscriptHint?

    /// Whether this sync may pass `--tail` or `--before` at all. Off, every
    /// sync is a forward read, and a cache holding a `before` is refetched in
    /// full.
    var tailMode: Bool { liveSyncEnabled && tailDeclared }

    /// Flag off, no tail support, no hint: the behavior before live sync.
    static let forwardOnly = RemoteTranscriptSyncPolicy(liveSyncEnabled: false, tailDeclared: false, hint: nil)
}

/// How one `loadEarlier` ended.
///
/// - `generation` / `head` — the cache's after the call. A caller whose
///   generation differs discards what it holds and rereads; one whose `head`
///   differs rereads holding its anchor.
/// - `reachedStart` — the cache now holds the conversation's beginning, or
///   history above it that can no longer be fetched; nothing earlier remains.
/// - `expired` — the provider answered `cursor_expired`. Implies `reachedStart`.
/// - `discarded` — a sync queued ahead of the load changed the generation, so
///   the load made no provider call; `reachedStart` and `expired` are false
///   and say nothing about the new generation.
struct RemoteTranscriptLoadEarlierOutcome: Equatable, Sendable {
    let generation: Int
    let head: Int
    let reachedStart: Bool
    let expired: Bool
    let discarded: Bool
}

/// Keeps one remote session's local transcript cache up to date through
/// `transcript read --since`
/// (`docs/specs/2026-09-25-remote-session-transcript-design.md` §
/// `RemoteTranscriptSync`).
///
/// **One lane per `(provider, sessionID)`.** At most one fetch runs per session
/// at a time. A request arriving while one is in flight does not start a
/// second: it queues exactly one follow-up behind the running fetch, and every
/// further request arriving before that follow-up starts joins it rather than
/// queuing another. A burst of requests therefore costs at most two fetches —
/// the one already running, whose answer may predate the request, and one that
/// starts after it and so reflects everything up to the moment the burst
/// began. Different sessions sync independently.
///
/// **Pages while the envelope says `more`,** persisting each page before
/// fetching the next. A sync stops after `pageCap` persisted pages and reports
/// `caughtUp == false`, so a provider that never clears `more` cannot hold the
/// lane forever; the next sync resumes from the stored cursor. The default cap
/// is one page, so a long first load returns after every page and the app's
/// driver, which re-syncs at once while `caughtUp` is false, renders each
/// page as it lands.
///
/// **A `--since` answer without a valid envelope is discarded.** That output
/// is only the delta after the cursor, so writing it as a reset would wipe the
/// history held before it. The sync drops the cursor and refetches from the
/// beginning within the same sync. The discarded answer does not count toward
/// `pageCap` and the refetch does: were the discard to use up a one-page sync,
/// the next sync would send the same cursor, be discarded again, and never
/// progress. The loop stays bounded because the refetch carries no cursor and
/// so cannot itself be discarded — every discard is followed by a persisted
/// page.
///
/// **Tail or forward.** With `RemoteTranscriptSyncPolicy.tailMode` on, every
/// sync first decides between a tail reset (`--tail 12`) and a forward read
/// (`wantsTailReset`): a tail when the cache holds no forward cursor, when the
/// session moved to a new conversation, or when it grew past
/// `tailResetGrowthThreshold` since the last caught-up sync. A tail answer
/// without an envelope cursor is discarded and the same sync falls back to a
/// full forward read, which carries no cursor and so cannot be discarded in
/// turn. With `tailMode` off, `--tail` and `--before` are never passed, and a
/// cache holding a `before` is refetched in full, so the history above it
/// returns. A caught-up sync records the current hint, when known, whatever
/// the flag says.
///
/// **Load earlier** (`loadEarlier`) runs `--before` on the same lane and
/// prepends the page. A lane mutex orders loads and syncs one at a time, in
/// arrival order; the coalescing above still bounds a burst of syncs to two
/// fetches, and applies to syncs only.
///
/// No clock: nothing here sleeps, polls, debounces or times out. The app owns
/// the refresh cadence (the daemon runs no transcript timers), and each
/// provider call's timeout is enforced by the invoker it goes through.
actor RemoteTranscriptSync {
    /// One provider invocation: `verb` is the argv after the provider's own
    /// `exec` and `args`. Production passes `RemoteProviderManager.invoke`
    /// with the contract's 60-second `transcript read` budget.
    typealias Invoke = @Sendable (_ provider: String, _ verb: [String]) async throws -> ProviderResult

    /// Resolves what one sync may do (see `RemoteTranscriptSyncPolicy`).
    /// Called once per sync, at the start of its turn on the lane, so a flag
    /// change takes effect on the next sync.
    typealias Policy = @Sendable (_ provider: String, _ sessionID: String) async -> RemoteTranscriptSyncPolicy

    /// Conversation records TBD asks for, for a tail reset and for each page
    /// of earlier history alike. TBD's request parameter, not a contract
    /// constant: about a screenful of rows in the pane.
    static let tailRecordCount = 12

    /// Growth, in bytes of the hint's `size` past the size recorded at the
    /// last caught-up sync, beyond which a tail reset beats reading forward.
    /// Past it the session is far enough behind that streaming the gap would
    /// keep the pane waiting; the history skipped becomes earlier history,
    /// loaded on scroll-up. A constant, not configuration.
    static let tailResetGrowthThreshold = 524_288

    /// Pages persisted by one sync before it reports it is not caught up.
    ///
    /// One, because a page is the unit the pane can show and it is slow: a
    /// full `transcript read` page over a provider transport runs to tens of
    /// seconds, while the round trip that ends one sync and starts the next —
    /// a local RPC, a `state.json` load, and the app's read of the appended
    /// bytes — costs milliseconds. Returning after every page therefore buys
    /// first paint one page in for no measurable throughput, and keeps the
    /// lane's hold to a single provider call, so a sync asked for by a send
    /// queues behind one page rather than several. An initial load and an
    /// incremental sync share the cap: an incremental delta is almost always
    /// one page anyway.
    static let defaultPageCap = 1

    private struct LaneKey: Hashable {
        let provider: String
        let sessionID: String
    }

    private struct Lane {
        /// The fetch running now (or, once it finished with a follow-up
        /// queued, the fetch that just ran — the follow-up replaces it when
        /// it starts).
        var current: Task<RemoteTranscriptSyncResult, Error>
        /// The one fetch queued behind `current`, which every request arriving
        /// before it starts joins.
        var followUp: Task<RemoteTranscriptSyncResult, Error>?
    }

    private let invoke: Invoke
    private let policy: Policy
    private let environment: [String: String]
    private let pageCap: Int
    private var lanes: [LaneKey: Lane] = [:]
    /// The lane mutex: sessions whose cache a sync fetch or a load of earlier
    /// history is working on now, and those queued for it, FIFO. A release
    /// hands the lane straight to the next waiter, so `busy` stays set.
    private var busy: Set<LaneKey> = []
    private var waiters: [LaneKey: [CheckedContinuation<Void, Never>]] = [:]
    /// Sessions whose cache was discarded while their lane was running or
    /// queued. A fetch or load in such a lane persists nothing more — see
    /// `discard`. Cleared once the lane is idle, so a request made afterwards
    /// runs normally.
    private var discarded: Set<LaneKey> = []
    /// Test-only inspection: how many `sync` calls have reached the actor, so
    /// a coalescing test can tell every request has arrived — and so has
    /// either queued or joined a follow-up — before it lets a fetch finish.
    private(set) var receivedRequestCount = 0

    /// - Parameters:
    ///   - environment: resolves the cache root through `TBDConstants`, so
    ///     `TBD_HOME` decides where caches live. Tests pass a temp home.
    ///   - pageCap: see `defaultPageCap`. Must be at least 1.
    ///   - policy: see `Policy`. Defaults to `.forwardOnly` for every sync.
    ///   - invoke: see `Invoke`.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pageCap: Int = RemoteTranscriptSync.defaultPageCap,
        policy: @escaping Policy = { _, _ in .forwardOnly },
        invoke: @escaping Invoke
    ) {
        precondition(pageCap >= 1, "a sync must be allowed at least one page")
        self.environment = environment
        self.pageCap = pageCap
        self.policy = policy
        self.invoke = invoke
    }

    /// The cache for one session, at the path this sync writes.
    nonisolated func cache(provider: String, sessionID: String) -> RemoteTranscriptCache {
        RemoteTranscriptCache(provider: provider, sessionID: sessionID, environment: environment)
    }

    /// Brings one session's cache up to date, coalescing with any sync already
    /// running for it (see the type's doc comment). Returns where the
    /// transcript is, its generation, and whether the provider has nothing
    /// more to give.
    func sync(provider: String, sessionID: String) async throws -> RemoteTranscriptSyncResult {
        receivedRequestCount += 1
        let key = LaneKey(provider: provider, sessionID: sessionID)
        if let lane = lanes[key] {
            if let followUp = lane.followUp {
                return try await followUp.value
            }
            let running = lane.current
            let followUp = Task<RemoteTranscriptSyncResult, Error> {
                _ = await running.result
                return try await self.runFollowUp(key)
            }
            lanes[key]?.followUp = followUp
            return try await followUp.value
        }
        let task = Task<RemoteTranscriptSyncResult, Error> {
            try await self.runCurrent(key)
        }
        lanes[key] = Lane(current: task, followUp: nil)
        return try await task.value
    }

    /// Removes one session's cache directory, for a session TBD has stopped
    /// tracking (a successful `remote.delete` or `remote.dismiss`). Best
    /// effort: a failure is logged, and `OrphanGC`'s remote-transcript leg is
    /// the guarantee behind it.
    ///
    /// A fetch already in flight for the session would otherwise write its
    /// page straight back into a freshly recreated directory, so its lane is
    /// marked: every fetch in it — the running one and a queued follow-up —
    /// drops what it fetched and throws `.discarded` instead of persisting.
    /// The check and the writes both run on this actor with no suspension
    /// between them, so a page can never land after the removal. A load of
    /// earlier history running or queued on the lane is marked the same way.
    /// A request made after the lane goes idle runs normally: the caller asked
    /// for it.
    func discard(provider: String, sessionID: String) {
        let key = LaneKey(provider: provider, sessionID: sessionID)
        if lanes[key] != nil || busy.contains(key) || waiters[key] != nil { discarded.insert(key) }
        let directory = cache(provider: provider, sessionID: sessionID).directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            syncLogger.info(
                """
                discarded transcript cache provider=\(provider, privacy: .public) \
                session=\(sessionID, privacy: .public)
                """)
        } catch {
            syncLogger.warning(
                """
                could not discard transcript cache provider=\(provider, privacy: .public) \
                session=\(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public); \
                the orphan sweep reclaims it later
                """)
        }
    }

    /// Test-only inspection: the number of sessions with a lane, which drops
    /// back to zero once every sync has finished.
    var activeLaneCount: Int { lanes.count }

    /// Test-only inspection: whether a follow-up is queued for this session.
    func hasQueuedFollowUp(provider: String, sessionID: String) -> Bool {
        lanes[LaneKey(provider: provider, sessionID: sessionID)]?.followUp != nil
    }

    /// Test-only inspection: how many fetches or loads are waiting for this
    /// session's lane mutex.
    func laneWaiterCount(provider: String, sessionID: String) -> Int {
        waiters[LaneKey(provider: provider, sessionID: sessionID)]?.count ?? 0
    }

    // MARK: - Lane bookkeeping

    private func runCurrent(_ key: LaneKey) async throws -> RemoteTranscriptSyncResult {
        defer { finish(key) }
        return try await fetchPages(key)
    }

    /// Runs once the fetch it queued behind has finished: the follow-up
    /// becomes the lane's current fetch, so a request arriving from now on
    /// queues a new follow-up behind it rather than joining one that has
    /// already started.
    private func runFollowUp(_ key: LaneKey) async throws -> RemoteTranscriptSyncResult {
        if let followUp = lanes[key]?.followUp {
            lanes[key] = Lane(current: followUp, followUp: nil)
        }
        defer { finish(key) }
        return try await fetchPages(key)
    }

    /// Drops the lane once its fetch is done, unless a follow-up is queued —
    /// that follow-up promotes itself when it starts.
    private func finish(_ key: LaneKey) {
        if lanes[key]?.followUp == nil {
            lanes[key] = nil
            clearDiscardIfIdle(key)
        }
    }

    /// Takes the lane mutex, waiting in arrival order behind whatever holds
    /// it. Never times out: whoever holds it is bounded by its one provider
    /// call's timeout.
    private func acquire(_ key: LaneKey) async {
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        // Resumed by `release`, which hands the mutex over with `busy` still set.
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    private func release(_ key: LaneKey) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
            return
        }
        busy.remove(key)
        clearDiscardIfIdle(key)
    }

    /// Forgets a discard once nothing is running or queued on the lane.
    private func clearDiscardIfIdle(_ key: LaneKey) {
        if lanes[key] == nil, !busy.contains(key), waiters[key] == nil {
            discarded.remove(key)
        }
    }

    // MARK: - Fetching

    private func fetchPages(_ key: LaneKey) async throws -> RemoteTranscriptSyncResult {
        await acquire(key)
        defer { release(key) }
        if discarded.contains(key) { throw RemoteTranscriptSyncError.discarded }
        let policy = await self.policy(key.provider, key.sessionID)
        // The policy read suspends, and `load()` creates the directory: a
        // discard that landed meanwhile must not be undone by it.
        if discarded.contains(key) { throw RemoteTranscriptSyncError.discarded }
        let cache = self.cache(provider: key.provider, sessionID: key.sessionID)
        var state = try cache.load()
        // Without tail mode a cache holding history above it can only be made
        // whole by starting over: its `before` can never be followed
        // (§ `RemoteTranscriptSync`, the flag-off bullet).
        var since: String? = (!policy.tailMode && state.before != nil) ? nil : state.cursor
        var useTail = policy.tailMode && Self.wantsTailReset(state: state, hint: policy.hint)
        var caughtUp = false
        var pages = 0
        while pages < pageCap {
            let verb = useTail
                ? RemoteVerb.transcriptReadTail(sessionID: key.sessionID, count: Self.tailRecordCount)
                : RemoteVerb.transcriptRead(sessionID: key.sessionID, since: since)
            let result = try await invoke(key.provider, verb)
            if result.failureClass != nil {
                let message = result.decodedError?.message
                    ?? "transcript read failed (exit \(result.exitCode))"
                syncLogger.error(
                    """
                    transcript read provider=\(key.provider, privacy: .public) \
                    session=\(key.sessionID, privacy: .public) failed: \(message, privacy: .public)
                    """)
                throw RemoteTranscriptSyncError.providerFailed(message: message)
            }
            // Checked after the provider call, the one suspension point in the
            // loop: a discard that landed while it ran must not be undone by
            // persisting its answer.
            if discarded.contains(key) { throw RemoteTranscriptSyncError.discarded }
            if useTail {
                let envelope = RemoteTranscriptEnvelope.parse(
                    stderr: result.stderr, requestedSince: false, provider: key.provider)
                guard envelope.source == .envelope, let cursor = envelope.cursor else {
                    syncLogger.error(
                        """
                        transcript read --tail provider=\(key.provider, privacy: .public) \
                        session=\(key.sessionID, privacy: .public): the answer carried no valid envelope \
                        with a cursor; discarding it and reading forward from the beginning
                        """)
                    // Not counted toward the cap, exactly as a discarded
                    // `--since` answer: the forward read that follows has no
                    // cursor, so it cannot be discarded in turn.
                    useTail = false
                    since = nil
                    continue
                }
                state = try cache.reset(to: result.stdout, cursor: cursor, before: envelope.before, from: state)
                pages += 1
                // `--tail` never pages; a `more` it sets is ignored.
                caughtUp = true
                break
            }
            let envelope = RemoteTranscriptEnvelope.parse(
                stderr: result.stderr, requestedSince: since != nil, provider: key.provider)
            if since != nil, envelope.source != .envelope {
                syncLogger.error(
                    """
                    transcript read provider=\(key.provider, privacy: .public) \
                    session=\(key.sessionID, privacy: .public): a --since answer came without a valid \
                    envelope; discarding it and refetching from the beginning
                    """)
                // Not counted toward the cap: the refetch that follows is, and
                // it carries no cursor, so it cannot be discarded in turn.
                since = nil
                continue
            }
            if envelope.reset {
                state = try cache.reset(to: result.stdout, cursor: envelope.cursor, before: nil, from: state)
            } else {
                state = try cache.append(result.stdout, cursor: envelope.cursor, to: state)
            }
            pages += 1
            since = state.cursor
            if !envelope.more {
                caughtUp = true
                break
            }
        }
        if !caughtUp {
            syncLogger.info(
                """
                transcript read provider=\(key.provider, privacy: .public) \
                session=\(key.sessionID, privacy: .public) stopped at the \(self.pageCap, privacy: .public)-page cap; \
                the next sync resumes from the stored cursor
                """)
        }
        // Bookkeeping, not a decision, so it ignores the flag: a hint recorded
        // only with the flag on would be stale when it came back on, and the
        // first sync would read all the growth since as far behind. An unknown
        // hint leaves the recorded one alone, so the first sighting after a
        // daemon restart still matches it.
        if caughtUp, let hint = policy.hint, state.hint != hint {
            state = try cache.commitHint(hint, to: state)
        }
        return RemoteTranscriptSyncResult(
            path: cache.transcriptURL.path, generation: state.generation, caughtUp: caughtUp,
            head: state.head, hasEarlier: policy.tailMode && state.before != nil)
    }

    /// Whether a tail-mode sync should start over from the conversation's end
    /// (§ `RemoteTranscriptSync`): the cache holds no forward cursor, so a
    /// forward read would fetch the whole conversation; the session moved to
    /// a new conversation; or it grew more than `tailResetGrowthThreshold`
    /// since the last caught-up sync. With no recorded hint (a cache written
    /// before hints existed) or no current one (none sighted since a daemon
    /// restart) there is nothing to compare, and a non-empty cache reads
    /// forward: neither is evidence of being far behind.
    static func wantsTailReset(state: RemoteTranscriptCacheState, hint: RemoteTranscriptHint?) -> Bool {
        if state.cursor == nil { return true }
        guard let hint, let recorded = state.hint else { return false }
        if hint.id != recorded.id { return true }
        return hint.size - recorded.size > tailResetGrowthThreshold
    }

    // MARK: - Loading earlier history

    /// Fetches the page of history above the cache with
    /// `transcript read --before <before> --tail 12` and prepends it, on the
    /// session's lane (§ RPCs, `remote.transcriptLoadEarlier`).
    ///
    /// - `requestGeneration` is the cache generation the caller holds. A sync
    ///   queued ahead of this load that changed it makes the load return
    ///   `discarded` with the new generation and no provider call. While the
    ///   load holds the lane nothing else can change the cache.
    /// - An answer with no envelope, or no `before` in it, has reached the
    ///   beginning: the page is prepended and `before` cleared.
    /// - A page that is empty, or whose `before` equals the cursor just sent,
    ///   cannot advance: logged as a contract violation, a non-empty page is
    ///   still prepended, and `before` is cleared, so a scroll-up can never
    ///   loop on the same request.
    /// - `cursor_expired` clears `before` and reports `expired`; any other
    ///   failure, or a malformed envelope, writes nothing and throws.
    ///
    /// The caller checks the flag, the capability, and dismissal; this does
    /// not. A cache with no `before` reports `reachedStart` without a call.
    func loadEarlier(
        provider: String, sessionID: String, requestGeneration: Int
    ) async throws -> RemoteTranscriptLoadEarlierOutcome {
        let key = LaneKey(provider: provider, sessionID: sessionID)
        await acquire(key)
        defer { release(key) }
        if discarded.contains(key) { throw RemoteTranscriptSyncError.discarded }
        let cache = self.cache(provider: provider, sessionID: sessionID)
        var state = try cache.load()
        if state.generation != requestGeneration {
            return RemoteTranscriptLoadEarlierOutcome(
                generation: state.generation, head: state.head,
                reachedStart: false, expired: false, discarded: true)
        }
        guard let before = state.before else {
            return RemoteTranscriptLoadEarlierOutcome(
                generation: state.generation, head: state.head,
                reachedStart: true, expired: false, discarded: false)
        }
        let result = try await invoke(
            provider,
            RemoteVerb.transcriptReadBefore(sessionID: sessionID, before: before, count: Self.tailRecordCount))
        if discarded.contains(key) { throw RemoteTranscriptSyncError.discarded }
        if result.failureClass != nil {
            if result.decodedError?.code == ProviderErrorObject.cursorExpiredCode {
                syncLogger.info(
                    """
                    transcript read --before provider=\(provider, privacy: .public) \
                    session=\(sessionID, privacy: .public): cursor expired; no earlier history
                    """)
                state = try cache.clearBefore(in: state)
                return RemoteTranscriptLoadEarlierOutcome(
                    generation: state.generation, head: state.head,
                    reachedStart: true, expired: true, discarded: false)
            }
            let message = result.decodedError?.message
                ?? "transcript read --before failed (exit \(result.exitCode))"
            syncLogger.error(
                """
                transcript read --before provider=\(provider, privacy: .public) \
                session=\(sessionID, privacy: .public) failed: \(message, privacy: .public)
                """)
            throw RemoteTranscriptSyncError.providerFailed(message: message)
        }
        let envelope = RemoteTranscriptEnvelope.parse(
            stderr: result.stderr, requestedSince: false, provider: provider)
        if envelope.source == .malformed {
            syncLogger.error(
                """
                transcript read --before provider=\(provider, privacy: .public) \
                session=\(sessionID, privacy: .public): malformed envelope; nothing written
                """)
            throw RemoteTranscriptSyncError.providerFailed(message: "malformed transcript read --before envelope")
        }
        var nextBefore = envelope.before
        if nextBefore != nil, result.stdout.isEmpty || nextBefore == before {
            syncLogger.error(
                """
                transcript read --before provider=\(provider, privacy: .public) \
                session=\(sessionID, privacy: .public): the page made no progress (contract violation); \
                treating it as the start of the conversation
                """)
            nextBefore = nil
        }
        if result.stdout.isEmpty {
            state = try cache.clearBefore(in: state)
        } else {
            state = try cache.prepend(result.stdout, before: nextBefore, to: state)
        }
        return RemoteTranscriptLoadEarlierOutcome(
            generation: state.generation, head: state.head,
            reachedStart: state.before == nil, expired: false, discarded: false)
    }
}
