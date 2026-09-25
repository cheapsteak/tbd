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

    var errorDescription: String? {
        switch self {
        case .providerFailed(let message): return message
        }
    }
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
/// fetching the next, so a slow first load fills the pane progressively. A
/// sync stops after `pageCap` pages and reports `caughtUp == false`, so a
/// provider that never clears `more` cannot hold the lane forever; the next
/// sync resumes from the stored cursor.
///
/// **A `--since` answer without a valid envelope is discarded.** That output
/// is only the delta after the cursor, so writing it as a reset would wipe the
/// history held before it. The sync drops the cursor and refetches from the
/// beginning within the same sync; the refetch counts toward `pageCap`.
///
/// No clock: nothing here sleeps, polls, debounces or times out. The app owns
/// the refresh cadence (the daemon runs no transcript timers), and each
/// provider call's timeout is enforced by the invoker it goes through.
actor RemoteTranscriptSync {
    /// One provider invocation: `verb` is the argv after the provider's own
    /// `exec` and `args`. Production passes `RemoteProviderManager.invoke`
    /// with the contract's 60-second `transcript read` budget.
    typealias Invoke = @Sendable (_ provider: String, _ verb: [String]) async throws -> ProviderResult

    /// Pages fetched by one sync before it reports it is not caught up. Each
    /// page is one provider call of up to 60 seconds, so the cap bounds how
    /// long a single sync can hold its lane.
    static let defaultPageCap = 8

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
    private let environment: [String: String]
    private let pageCap: Int
    private var lanes: [LaneKey: Lane] = [:]
    /// Test-only inspection: how many `sync` calls have reached the actor, so
    /// a coalescing test can tell every request has arrived — and so has
    /// either queued or joined a follow-up — before it lets a fetch finish.
    private(set) var receivedRequestCount = 0

    /// - Parameters:
    ///   - environment: resolves the cache root through `TBDConstants`, so
    ///     `TBD_HOME` decides where caches live. Tests pass a temp home.
    ///   - pageCap: see `defaultPageCap`. Must be at least 1.
    ///   - invoke: see `Invoke`.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pageCap: Int = RemoteTranscriptSync.defaultPageCap,
        invoke: @escaping Invoke
    ) {
        precondition(pageCap >= 1, "a sync must be allowed at least one page")
        self.environment = environment
        self.pageCap = pageCap
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

    /// Test-only inspection: the number of sessions with a lane, which drops
    /// back to zero once every sync has finished.
    var activeLaneCount: Int { lanes.count }

    /// Test-only inspection: whether a follow-up is queued for this session.
    func hasQueuedFollowUp(provider: String, sessionID: String) -> Bool {
        lanes[LaneKey(provider: provider, sessionID: sessionID)]?.followUp != nil
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
        }
    }

    // MARK: - Fetching

    private func fetchPages(_ key: LaneKey) async throws -> RemoteTranscriptSyncResult {
        let cache = self.cache(provider: key.provider, sessionID: key.sessionID)
        var state = try cache.load()
        var since = state.cursor
        var caughtUp = false
        for _ in 0..<pageCap {
            let result = try await invoke(
                key.provider, RemoteVerb.transcriptRead(sessionID: key.sessionID, since: since))
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
            let envelope = RemoteTranscriptEnvelope.parse(
                stderr: result.stderr, requestedSince: since != nil, provider: key.provider)
            if since != nil, envelope.source != .envelope {
                syncLogger.error(
                    """
                    transcript read provider=\(key.provider, privacy: .public) \
                    session=\(key.sessionID, privacy: .public): a --since answer came without a valid \
                    envelope; discarding it and refetching from the beginning
                    """)
                since = nil
                continue
            }
            if envelope.reset {
                state = try cache.reset(to: result.stdout, cursor: envelope.cursor, from: state)
            } else {
                state = try cache.append(result.stdout, cursor: envelope.cursor, to: state)
            }
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
        return RemoteTranscriptSyncResult(
            path: cache.transcriptURL.path, generation: state.generation, caughtUp: caughtUp)
    }
}
