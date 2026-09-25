import Foundation
import Observation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "remoteTranscript")

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
/// - **Stop** – going inactive ends the loop; no sync runs until it is active
///   again, and a sync in flight when it stops publishes nothing.
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

    nonisolated static let defaultInterval: Duration = .seconds(3)

    let selection: RemoteSessionSelection
    private(set) var snapshot = RemoteTranscriptSyncSnapshot()

    /// How many syncs have completed (successfully or not). For tests and
    /// diagnostics; nothing renders from it.
    @ObservationIgnored private(set) var completedSyncs = 0

    private let sync: Syncer
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

    /// `agent_state` together with `agent_state_at`: a session that goes
    /// working → idle → working between two reads still moves the timestamp.
    struct AgentStateMark: Equatable {
        let state: RemoteAgentState
        let at: String?
    }

    init(
        selection: RemoteSessionSelection,
        sync: @escaping Syncer,
        interval: Duration = RemoteTranscriptSyncDriver.defaultInterval,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.selection = selection
        self.sync = sync
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

    /// Stop for good — the pane went away.
    func stop() {
        setActive(false)
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
    private func runSync() async -> Bool {
        let loopTask = loop
        do {
            let result = try await sync(selection)
            // A sync that was in flight when the loop stopped (or restarted)
            // publishes nothing: its pane is not the one on screen any more.
            guard loopTask == loop, !Task.isCancelled else { return false }
            snapshot = RemoteTranscriptSyncSnapshot(
                path: result.path, generation: result.generation,
                caughtUp: result.caughtUp, refreshToken: snapshot.refreshToken &+ 1,
                error: nil)
            completedSyncs += 1
            return !result.caughtUp
        } catch {
            guard loopTask == loop, !Task.isCancelled else { return false }
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
