import Foundation
import Observation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "remoteTranscript")

/// Where loading earlier history stands for one pane
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "Loading
/// earlier history").
enum RemoteTranscriptEarlierState: Equatable {
    /// Nothing in flight, and the start has not been reached.
    case idle
    /// One `remote.transcriptLoadEarlier` call is in flight.
    case loading
    /// The last call failed; the next scroll into the top zone, or the
    /// header's button, retries.
    case failed(String)
    /// The cache holds the conversation's beginning.
    case reachedStart
    /// The provider answered `cursor_expired`: the history above the cache can
    /// no longer be fetched.
    case expired

    /// Whether this state ends the history for the current generation, so a
    /// sync that read the cache before the load cannot revive `hasEarlier`.
    var endsHistory: Bool {
        self == .reachedStart || self == .expired
    }
}

/// What the last completed `remote.transcriptSync` told the pane, plus a token
/// that moves on every completed sync so an append that changed none of the
/// other three is still read (`RemoteTranscriptPaneView.refreshToken`).
struct RemoteTranscriptSyncSnapshot: Equatable {
    var path: String?
    var generation = 0
    var caughtUp = false
    var refreshToken = 0
    /// The last sync's failure, cleared by the next success. Shown by the pane
    /// so a daemon that refuses the sync is not mistaken for one still loading.
    var error: String?
    /// The cache's prepend counter. A change under the same generation means
    /// earlier history landed at the front of the file: the pane re-reads it
    /// whole while holding its top visible row still.
    var head = 0
    /// Whether the cache has history above its first record that
    /// `remote.transcriptLoadEarlier` can fetch. Always false with
    /// `remote_transcript_live_sync_enabled` off, so the pane then never loads
    /// earlier history and shows no header.
    var hasEarlier = false
    var earlier: RemoteTranscriptEarlierState = .idle
}

/// Drives `remote.transcriptSync` for one remote session while its transcript
/// pane is on screen (docs/specs/2026-09-25-remote-session-transcript-design.md,
/// "Refreshing").
///
/// - **Cadence** – while active (pane visible *and* app active), one sync at
///   once and then one every `interval` (3 s).
/// - **Catch-up** – a sync that succeeds with `caughtUp == false` is followed
///   by the next one at once, with no wait. The daemon returns after every
///   page, so a long first load publishes (and the pane renders) each page as
///   it lands; the cadence resumes once a sync reports it is caught up. A
///   failed sync always waits the interval, so a refusing daemon is not
///   hammered.
/// - **Inactive** – going inactive ends the loop; no sync starts until it is
///   active again. A sync already in flight still publishes when it returns:
///   the daemon has persisted what it fetched either way, and the result is
///   for this driver's own session, so dropping it would only leave the pane
///   waiting on a spinner for data already on disk.
/// - **Stop** – `stop()` retires the driver (the pane went away, or its
///   selection moved to another session and a new driver took over). A sync
///   in flight then publishes nothing.
/// - **Order** – a result never overwrites one from a sync that started
///   later, so a slow in-flight sync finishing after a restart cannot move the
///   snapshot backwards.
/// - **Seed** – `initialSnapshot` (what the daemon already cached, see
///   `RemoteTranscriptSyncSnapshot.cached(for:)`) is the snapshot before any
///   sync publishes, so the pane renders the cache at once.
/// - **Earlier history** – `loadEarlier(trigger:)` calls
///   `remote.transcriptLoadEarlier` when the last answer reported
///   `hasEarlier`, one call at a time. The pane reports the table's near-top
///   transitions through `noteNearTop(_:)`; entering the zone loads, and so
///   does a sync published while the table is still near the top with
///   nothing in flight and nothing failed — that is how a page too short to
///   leave the zone, or a `hasEarlier` that arrives with the table already at
///   the top, keeps loading. A failed call is not retried by a sync: it waits
///   for the next entry into the zone or the header's button.
/// - **Head and generation** – `head` never moves backwards within a
///   generation (a sync that read the cache before a prepend can return after
///   it), and a sync cannot revive `hasEarlier` once a load reached the start.
///   A newer generation replaces `head` and `hasEarlier` and resets the
///   earlier-history state; an older one is ignored for those fields — except
///   that the first daemon answer is authoritative over a seed read from disk.
///   A load whose result names a generation other than the one it started
///   under fetched nothing (a sync reset the cache first) and is treated as
///   that reset.
/// - **Immediate triggers** – `syncNow()` (after a successful composer send)
///   and `noteAgentState(_:)` (whenever the session's `agent_state` or
///   `agent_state_at` moves) run a sync without waiting for the tick, and the
///   cadence restarts from that sync. A trigger landing while a sync is in
///   flight runs one more sync straight after it rather than a second
///   concurrent one; the daemon coalesces concurrent syncs too.
///
/// The interval takes an injected clock, per the repo's clock-seam rule, and
/// the sync itself is an injected closure so tests need no daemon.
@MainActor
@Observable
final class RemoteTranscriptSyncDriver {
    typealias Syncer = @MainActor (RemoteSessionSelection) async throws -> RemoteTranscriptSyncResult
    typealias LoadEarlier = @MainActor (RemoteSessionSelection) async throws -> RemoteTranscriptLoadEarlierResult

    /// What asked for a page of earlier history. Either one may retry a failed
    /// call; the pane only reports `.nearTop` on an entry into the zone.
    enum LoadEarlierTrigger: String {
        case nearTop
        case button
    }

    nonisolated static let defaultInterval: Duration = .seconds(3)

    let selection: RemoteSessionSelection
    private(set) var snapshot: RemoteTranscriptSyncSnapshot

    /// How many syncs have completed (successfully or not). For tests and
    /// diagnostics; nothing renders from it.
    @ObservationIgnored private(set) var completedSyncs = 0

    private let sync: Syncer
    private let loadEarlierCall: LoadEarlier?
    private let interval: Duration
    private let clock: any Clock<Duration>

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The loop's current wait between syncs, resumed early by a trigger.
    @ObservationIgnored private var wait: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var nextWaitID = 0
    /// A trigger that arrived while a sync was in flight: honoured as soon as
    /// that sync finishes, in place of the wait.
    @ObservationIgnored private var pendingTrigger = false
    /// The agent-state fingerprint last seen, so only a *change* triggers.
    @ObservationIgnored private var lastAgentState: AgentStateMark?
    /// Moved by `stop()`: a sync publishes only if it is unchanged since the
    /// sync started.
    @ObservationIgnored private var epoch = 0
    /// Ordinal of the last sync started, and of the last one whose success
    /// was published, so an older result never replaces a newer one.
    @ObservationIgnored private var lastStartedSync = 0
    @ObservationIgnored private var lastPublishedSync = 0
    /// Set by `stop()`: a retired driver starts no load of earlier history.
    @ObservationIgnored private var retired = false
    /// Whether any daemon answer has been published. Until one has, the
    /// generation is a seed read from disk and the first answer replaces it
    /// whichever way it moved.
    @ObservationIgnored private var hasDaemonAnswer = false
    /// One load of earlier history in flight at a time. Separate from
    /// `snapshot.earlier`, which a generation change resets to `.idle` while
    /// the load is still out.
    @ObservationIgnored private var loadInFlight = false
    /// The table's last near-top report.
    @ObservationIgnored private var nearTop = false

    /// `agent_state` together with `agent_state_at`: a session that goes
    /// working → idle → working between two reads still moves the timestamp.
    struct AgentStateMark: Equatable {
        let state: RemoteAgentState
        let at: String?
    }

    init(
        selection: RemoteSessionSelection,
        sync: @escaping Syncer,
        loadEarlier: LoadEarlier? = nil,
        initialSnapshot: RemoteTranscriptSyncSnapshot? = nil,
        interval: Duration = RemoteTranscriptSyncDriver.defaultInterval,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.selection = selection
        self.sync = sync
        self.loadEarlierCall = loadEarlier
        self.snapshot = initialSnapshot ?? RemoteTranscriptSyncSnapshot()
        self.interval = interval
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Visible and app-active → run the cadence; anything else → stop it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startLoop()
        } else {
            stopLoop()
        }
    }

    /// Sync at once, then restart the cadence. A no-op while inactive: the
    /// pane that would show the result is not on screen.
    func syncNow() {
        guard isActive else { return }
        if let wait {
            self.wait = nil
            wait.continuation.resume()
        } else {
            pendingTrigger = true
        }
    }

    /// Record the session's agent state; a change from the last one seen
    /// triggers an immediate sync. The first observation only records.
    func noteAgentState(_ mark: AgentStateMark?) {
        defer { lastAgentState = mark }
        guard let previous = lastAgentState, previous != mark else { return }
        syncNow()
    }

    /// Stop for good — the pane went away, or moved to another session. A
    /// sync in flight publishes nothing.
    func stop() {
        epoch &+= 1
        retired = true
        loadInFlight = false
        setActive(false)
    }

    // MARK: - Earlier history

    /// The table reported whether it is scrolled near its top. Entering the
    /// zone loads a page of earlier history (when there is one); leaving it
    /// only records.
    func noteNearTop(_ near: Bool) {
        let entering = near && !nearTop
        nearTop = near
        if entering {
            loadEarlier(trigger: .nearTop)
        }
    }

    /// Fetch one page of earlier history, unless there is none, one is
    /// already in flight, or the driver is retired. Nothing here sleeps.
    func loadEarlier(trigger: LoadEarlierTrigger) {
        guard !retired, let loadEarlierCall, snapshot.hasEarlier, !loadInFlight else { return }
        loadInFlight = true
        snapshot.earlier = .loading
        let epoch = self.epoch
        let startGeneration = snapshot.generation
        let selection = self.selection
        logger.debug("""
        load earlier (\(trigger.rawValue, privacy: .public)) for \(selection.provider, privacy: .public)/\
        \(selection.sessionID, privacy: .public)
        """)
        Task { [weak self] in
            do {
                let result = try await loadEarlierCall(selection)
                self?.finishLoad(result, epoch: epoch, startGeneration: startGeneration)
            } catch {
                self?.failLoad(error, epoch: epoch)
            }
        }
    }

    private func finishLoad(
        _ result: RemoteTranscriptLoadEarlierResult, epoch: Int, startGeneration: Int
    ) {
        guard epoch == self.epoch else { return }
        loadInFlight = false
        hasDaemonAnswer = true
        var next = snapshot
        if result.generation != startGeneration || result.generation != next.generation {
            // A sync replaced the cache before the load ran, so the load
            // fetched nothing. Adopt the reset if no sync has published it
            // yet; `hasEarlier` waits for that sync to say.
            if result.generation > next.generation {
                next.generation = result.generation
                next.head = result.head
                next.hasEarlier = false
                next.refreshToken &+= 1
            }
            next.earlier = .idle
        } else {
            next.head = max(next.head, result.head)
            next.hasEarlier = !result.reachedStart
            next.earlier = result.expired ? .expired : result.reachedStart ? .reachedStart : .idle
            next.refreshToken &+= 1
        }
        snapshot = next
    }

    private func failLoad(_ error: any Error, epoch: Int) {
        guard epoch == self.epoch else { return }
        loadInFlight = false
        // Not `.loading` any more: a newer generation reset it while the call
        // was out, and this failure belongs to history that is gone.
        guard snapshot.earlier == .loading else { return }
        // A cancelled call says nothing about the daemon.
        if error is CancellationError {
            snapshot.earlier = .idle
            return
        }
        logger.debug("""
        load earlier failed for \(self.selection.provider, privacy: .public)/\
        \(self.selection.sessionID, privacy: .public): \(error, privacy: .public)
        """)
        snapshot.earlier = .failed(ComposerSendCoordinator.bannerMessage(for: error))
    }

    /// Folds a sync's answer about the generation, `head` and `hasEarlier`
    /// into `snapshot` (see the type doc's "Head and generation").
    private static func merge(
        _ result: RemoteTranscriptSyncResult, into snapshot: inout RemoteTranscriptSyncSnapshot,
        authoritative: Bool
    ) {
        if result.generation > snapshot.generation
            || (authoritative && result.generation != snapshot.generation) {
            snapshot.generation = result.generation
            snapshot.head = result.head
            snapshot.hasEarlier = result.hasEarlier
            snapshot.earlier = .idle
        } else if result.generation == snapshot.generation {
            let stale = result.head < snapshot.head
            snapshot.head = max(snapshot.head, result.head)
            if snapshot.earlier.endsHistory {
                snapshot.hasEarlier = false
            } else if !stale {
                snapshot.hasEarlier = result.hasEarlier
            }
        }
        // An older generation: this sync read the cache before a reset that a
        // load result already published. Nothing in it is current.
    }

    // MARK: - Loop

    private func startLoop() {
        pendingTrigger = false
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let catchingUp = await self.runSync()
                guard !Task.isCancelled else { return }
                if catchingUp {
                    // The next sync starts now, so it also answers any
                    // trigger that arrived during this one.
                    self.pendingTrigger = false
                } else {
                    await self.waitForNextTick()
                }
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        pendingTrigger = false
        if let wait {
            self.wait = nil
            wait.continuation.resume()
        }
    }

    /// Runs one sync and publishes it. Returns true when it succeeded without
    /// catching up, i.e. the next sync should start without waiting.
    ///
    /// Publishes even when the loop stopped (went inactive) while the sync
    /// ran; only `stop()` or a newer published result suppresses it.
    private func runSync() async -> Bool {
        let epoch = self.epoch
        lastStartedSync += 1
        let ordinal = lastStartedSync
        do {
            let result = try await sync(selection)
            guard epoch == self.epoch, ordinal > lastPublishedSync else { return false }
            lastPublishedSync = ordinal
            var next = snapshot
            next.path = result.path
            next.caughtUp = result.caughtUp
            next.refreshToken &+= 1
            next.error = nil
            Self.merge(result, into: &next, authoritative: !hasDaemonAnswer)
            hasDaemonAnswer = true
            snapshot = next
            completedSyncs += 1
            // Still near the top with more above and nothing in flight or
            // failed: keep loading (a page too short to leave the zone, or a
            // `hasEarlier` that arrived with the table already at the top).
            if nearTop, snapshot.earlier == .idle {
                loadEarlier(trigger: .nearTop)
            }
            return !result.caughtUp
        } catch {
            // A cancelled call says nothing about the daemon; the next sync
            // will. Not shown as a failure.
            if error is CancellationError { return false }
            guard epoch == self.epoch, ordinal > lastPublishedSync else { return false }
            logger.debug("""
            transcript sync failed for \(self.selection.provider, privacy: .public)/\
            \(self.selection.sessionID, privacy: .public): \(error, privacy: .public)
            """)
            snapshot.error = ComposerSendCoordinator.bannerMessage(for: error)
            completedSyncs += 1
            return false
        }
    }

    /// Sleep `interval`, or less if a trigger arrives. A trigger that already
    /// arrived during the sync skips the wait entirely.
    private func waitForNextTick() async {
        if pendingTrigger {
            pendingTrigger = false
            return
        }
        nextWaitID += 1
        let id = nextWaitID
        let clock = self.clock
        let interval = self.interval
        // Local, not a property: a restarted loop's wait must never cancel the
        // sleeper of the wait that replaced it.
        var sleeper: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait = (id, continuation)
            sleeper = Task { [weak self] in
                try? await clock.sleep(for: interval)
                // Cancelled or not, only resume the wait this sleeper was made
                // for: a later wait belongs to a later sleeper.
                self?.endWait(id: id)
            }
        }
        sleeper?.cancel()
    }

    private func endWait(id: Int) {
        guard let wait, wait.id == id else { return }
        self.wait = nil
        wait.continuation.resume()
    }
}
