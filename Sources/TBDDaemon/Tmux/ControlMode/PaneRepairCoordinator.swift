import Foundation
import os

/// Phase B M3 — heals a pane whose backpressure queue overflowed (the
/// flow-control state machine's "Draining" state, Policy B, issue #376).
///
/// When a ready, unfenced sink's queue overflows, `PaneFanout` clears the
/// queue, flips the sink to `repairing`, and fires `onOverflowRepair`, which
/// lands here. The repair cycle:
///
///  1. PAUSE the pane server-side. Probe-verified (tmux 3.6a, 6/6 trials,
///     throttled + full-blast): a paused pane delivers NOTHING — zero bytes
///     even with ~500k tokens emitted while paused; the content lands in
///     pane history/screen, reachable via capture.
///  2. Wait for the app reader to catch up (pipe writability): a recapture
///     replayed into a still-full pipe would just re-overflow.
///  3. Arm the repair fence, then send the 6-command capture + continue as
///     ONE atomic command list (`PaneCaptureReplay`, shared with the attach
///     orchestrator). Probe-verified: an atomic [captures…, continue] has a
///     seam gap of exactly ZERO — the first live token after the continue is
///     contiguous with the capture's tail, and it flows into the armed fence.
///  4. Write the recapture replay behind the fence (`writeReplay`), then
///     `endRepair` — the fence flush delivers the post-continue bytes
///     strictly after the replay. Zero-loss heal of the overflow hole.
///
/// The spec's original design — drain buffered `%extended-output` while
/// paused — was REFUTED live: pause DISCARDS (tmux resumes delivery from the
/// pane's CURRENT position, draining nothing). The repair therefore
/// re-captures instead, the addendum §3 reserved "re-capture on pause"
/// (iTerm2's shape for `%pause`), which the M2 fence machinery makes cheap.
///
/// The repair replay resets the terminal (reset prelude + full history)
/// MID-SESSION — accepted and intentional: iTerm2 re-captures on %pause for
/// the same reason, and a one-frame repaint beats permanently corrupt cells
/// on a differential renderer.
///
/// Generation discipline (R10-3 / R11, mirroring the attach orchestrator):
/// every await is followed by a generation re-validation; on ANY supersession
/// the repair aborts silently — it sends NOTHING further and never unpauses
/// (pause state is per PANE on the shared per-server correlator; the
/// successor's own FIFO-ordered sequence owns it), and the superseded sink's
/// state died with it, so there is nothing to clean.
actor PaneRepairCoordinator {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    private let supervisor: TmuxControlSupervisor
    /// Command seam (`TmuxControlModeBridge.commandProvider`): resolves the
    /// server's FIFO correlator; tests substitute a fake-backed client.
    private let commandProvider: @Sendable (String) async -> TmuxControlCommandClient?
    /// Recapture depth — matches the attach orchestrator's (see its note on
    /// the server-side `history-limit 50000`).
    private let historyDepth: Int
    /// Reader-catch-up poll pacing (step 2) — injectable so tests can choose
    /// a pacing that reaches a threshold in a few clock advances (typically
    /// LARGER than production: virtual time makes small intervals pointless,
    /// and a long advance chain is a load-sensitivity hazard). The wait has
    /// NO deadline: pacing starts
    /// at `writableCheckInterval` and relaxes to `writableSlowInterval` once
    /// the wait exceeds `writableEscalationThreshold`.
    private let writableCheckInterval: Duration
    private let writableSlowInterval: Duration
    private let writableEscalationThreshold: Duration
    /// One `.error` line when the wait crosses this mark — the pane is still
    /// healthy (paused, buffering server-side) but the app reader has been
    /// stalled suspiciously long.
    private static let readerStallLogThreshold: Duration = .seconds(30)
    /// One in-flight repair per pane. Belt-and-suspenders: the sink's
    /// `repairing` flag already gates re-signaling at the fanout, but a
    /// duplicate signal for a key mid-repair must still be a no-op here.
    private var inFlight: Set<PaneKey> = []
    /// Clock behind the reader-catch-up pacing below. Defaulted, so no call
    /// site changes; tests pass a `TestClock` and drive virtual time.
    private let clock: any Clock<Duration>

    init(supervisor: TmuxControlSupervisor,
         commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?,
         historyDepth: Int = 50_000,
         writableCheckInterval: Duration = .milliseconds(50),
         writableSlowInterval: Duration = .milliseconds(500),
         writableEscalationThreshold: Duration = .seconds(5),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        self.supervisor = supervisor
        self.commandProvider = commandProvider
        self.historyDepth = historyDepth
        self.writableCheckInterval = writableCheckInterval
        self.writableSlowInterval = writableSlowInterval
        self.writableEscalationThreshold = writableEscalationThreshold
    }

    /// Test seam: whether a repair for `key` is currently running.
    func isInFlight(_ key: PaneKey) -> Bool {
        inFlight.contains(key)
    }

    /// Run the repair cycle for `key` unless one is already in flight for it.
    ///
    /// One repair per pane stays deliberately serialized — two concurrent
    /// repairs would both drive the same PANE's pause state on the shared
    /// correlator. The cost of that serialization is that an overflow signal
    /// arriving for a key mid-repair is discarded by the guard below — fine
    /// for a duplicate signal on the SAME sink (the `repairing` flag gates
    /// re-signaling), but a SUCCESSOR sink's signal (re-attach while gen-N's
    /// repair was parked on an await, then the gen-M > N sink overflowed)
    /// used to be swallowed too, leaving the successor `repairing` forever:
    /// route() drops all its output and `enqueueLocked` never re-signals — a
    /// permanently blank pane (review round 2, S1).
    ///
    /// The exit re-dispatch below heals every such swallow: after each pass,
    /// if the pane's CURRENT sink is still stuck mid-repair (`repairing` is
    /// set only by an overflow entry and cleared only by this coordinator),
    /// run the repair again for the CURRENT generation. Structurally bounded:
    /// each pass services one distinct overflow entry (one `repairing`
    /// false→true flip) and either completes it, aborts it, or is superseded
    /// by a strictly newer generation — never a busy spin, every iteration
    /// awaits a full repair cycle.
    func repairIfNeeded(key: PaneKey, generation: UInt64) async {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        var target = generation
        while true {
            await repair(key: key, generation: target)
            guard supervisor.fanout.flowStats(key: key)?.repairing == true,
                  let current = supervisor.fanout.currentGeneration(key: key) else { return }
            target = current
        }
    }

    private func repair(key: PaneKey, generation: UInt64) async {
        let (server, paneID) = (key.server, key.paneID)
        // Entry guard (review round 2, S1): the exit re-dispatch above can
        // race a not-yet-run overflow signal Task for the same overflow —
        // whichever lands second must find the sink already healed (no
        // longer `repairing`, or replaced by a newer generation) and send
        // NOTHING: a pause sent for a sink that is not mid-repair would
        // freeze a healthy pane (`beginRepairFence` refuses non-repairing
        // sinks, and no later path would unpause). Stale signals from a
        // superseded generation exit here too, before touching the
        // correlator.
        guard supervisor.fanout.currentGeneration(key: key) == generation,
              supervisor.fanout.flowStats(key: key)?.repairing == true else { return }
        guard let client = await commandProvider(server) else {
            // No correlator (connection torn down): nothing to pause, nothing
            // paused — just unfreeze the sink if we still own it
            // (`abortRepair` is generation-checked, a stale call no-ops).
            Self.logger.error("""
                repair: no command client for \(server, privacy: .public)/\(paneID, privacy: .public) \
                — aborting repair
                """)
            supervisor.fanout.abortRepair(key: key, generation: generation)
            return
        }
        // Ownership re-check after the provider hop (R10-3): a stale repair
        // resumed here must send NOTHING on the shared correlator (R11).
        guard await stillOwner(key, generation) else { return }

        // Step 1 — the PAUSE alone, awaited. A failed pause means the
        // captures below run UNPAUSED: the replay may be slightly torn
        // (cursor vs content mismatch) — surface it and PROCEED, same
        // reasoning as the attach: fullscreen apps repaint differentially
        // and self-heal, and a genuinely dead pane %errors the captures
        // below, which aborts the repair on its own.
        let continueCommand = "refresh-client -A '\(paneID):continue'"
        let pauseResults = await client.sendBatch(texts: ["refresh-client -A '\(paneID):pause'"])
        if case .failure(let pauseError) = pauseResults.first {
            Self.logger.error("""
                repair pause failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(String(describing: pauseError), privacy: .public) — proceeding with an unpaused capture
                """)
        }
        guard await stillOwner(key, generation) else { return }

        // Step 2 — wait for the app reader to catch up. `isPipeWritable` is
        // generation-checked: `nil` means the sink is gone or superseded and
        // the repair aborts silently (R11: no unpause — a successor attach's
        // own sequence owns the pane's pause state, and a plain detach
        // %errors nothing worse than a paused, viewerless pane).
        //
        // The wait has NO deadline: a TRANSIENTLY wedged reader (e.g. a long
        // app main-thread hitch) must not turn into a permanently frozen
        // pane — nothing in the daemon ever re-triggers a given generation's
        // repair, so giving up here would leave the sink `repairing` and the
        // pane paused forever. Instead the loop waits it out: the pane stays
        // paused (tmux buffers server-side — nothing is lost) and THIS repair
        // completes whenever the reader drains. Pacing escalates from
        // `writableCheckInterval` to `writableSlowInterval` past the
        // escalation threshold, with ONE `.error` line at the 30 s mark.
        // A BROKEN pipe (read end closed) can never drain: unpause + abort —
        // the viewer is gone or dying, the app-death detach path finishes the
        // job, and leaving the pane unpaused keeps it healthy for the next
        // attach.
        //
        // Elapsed is ACCUMULATED from the intervals this loop actually slept,
        // not read off an `Instant` — `any Clock<Duration>` erases `Instant`,
        // and both thresholds below are pure pacing/logging (neither gates a
        // send, an unpause, or a generation decision), so excluding the
        // nanosecond-scale writability check between slices is noise against
        // a 5 s / 30 s mark, and makes both exactly advanceable on a
        // `TestClock`.
        var waited: Duration = .zero
        var loggedStall = false
        waitLoop: while true {
            switch supervisor.fanout.isPipeWritable(key: key, generation: generation) {
            case nil:
                return
            case .writable?:
                break waitLoop
            case .broken?:
                Self.logger.error("""
                    repair pipe broken (read end closed) for \(server, privacy: .public)/\(paneID, privacy: .public) \
                    gen=\(generation) — unpausing and aborting; the app-death detach path finishes the job
                    """)
                // TOCTOU residual (accepted): the still-owner check and the
                // continue send are not atomic — a successor can interpose
                // between them, so this continue can land inside the
                // successor's pause window in a vanishingly narrow race.
                // Consequence: a torn capture that differentially self-heals,
                // same class as the accepted pause-failure tear.
                if await stillOwner(key, generation) {
                    await client.sendList([
                        TmuxCommand(text: continueCommand, tolerateErrors: true) { _ in }
                    ])
                    supervisor.fanout.abortRepair(key: key, generation: generation)
                }
                return
            case .full?:
                if !loggedStall, waited >= Self.readerStallLogThreshold {
                    loggedStall = true
                    Self.logger.error("""
                        repair reader stalled >30s for \(server, privacy: .public)/\(paneID, privacy: .public) \
                        gen=\(generation) — waiting; the pane stays paused, tmux buffers server-side
                        """)
                }
                let interval = waited >= writableEscalationThreshold
                    ? writableSlowInterval : writableCheckInterval
                // Cancellation bail (latent — the bridge's dispatch Tasks are
                // never cancelled today): in a cancelled task the sleep
                // throws immediately, which would turn this deadline-free
                // wait into an unbounded busy-spin. Exit silently, like the
                // superseded `nil` case above: send nothing — the sink stays
                // `repairing`, and a later overflow signal or attach heals it.
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                waited += interval
            }
        }

        // Step 3 — arm the repair fence (generation-checked; requires the
        // sink to still be `repairing`). The pane is provably silent — the
        // pause reply is in hand and a paused pane delivers nothing — so no
        // output can race the arming. Refusal → superseded; send nothing.
        //
        // TOCTOU residual (accepted): this generation check and the batch
        // send below are not atomic — a successor can interpose between
        // them, so this batch can land inside the successor's pause window
        // in a vanishingly narrow race. Consequence: a torn capture that
        // differentially self-heals, same class as the accepted
        // pause-failure tear above.
        guard supervisor.fanout.beginRepairFence(key: key, generation: generation) else { return }

        // Step 4 — captures + continue, ONE atomic list with the continue
        // LAST: identical shape (and shared construction) with the attach's
        // batch 2; the zero-seam probe fact carries the heal.
        let captureCommands = PaneCaptureReplay.captureCommands(
            paneID: paneID, historyDepth: historyDepth)
        let results = await client.sendBatch(texts: captureCommands + [continueCommand])
        // A failed batched continue is tolerated here, as in the attach: a
        // connection close fails the captures too, which aborts the repair
        // below with its own unpause — but a plain %error leaves the
        // captures healthy and the pane PAUSED, so the success path below
        // retries the continue once (review round 2, M3).
        var continueErrored = false
        if case .failure(let continueError) = results.last {
            Self.logger.error("""
                repair batched continue failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(String(describing: continueError), privacy: .public)
                """)
            if case .commandFailed = continueError { continueErrored = true }
        }

        do {
            // Step 5 — assemble the recapture replay and write it behind the
            // armed fence (the drain is never live while fenced, so the
            // direct pipe write cannot be interleaved).
            let replay = try PaneCaptureReplay.assemble(
                captureResults: Array(results.dropLast()),
                captureCommands: captureCommands,
                server: server,
                paneID: paneID,
                historyDepth: historyDepth,
                onHistoryTruncation: nil)
            try supervisor.writeReplay(
                server: server, paneID: paneID, generation: generation, bytes: replay)
            // Step 6 — the flush: clear fence + repairing, arm the drain so
            // the fenced (post-continue) bytes follow the replay in order.
            let fencedBytes = supervisor.fanout.flowStats(key: key)?.queuedBytes ?? 0
            guard supervisor.fanout.endRepair(key: key, generation: generation) else { return }
            Self.logger.info("""
                pane repaired \(server, privacy: .public)/\(paneID, privacy: .public) gen=\(generation) \
                — replay \(replay.count) bytes, \(fencedBytes) fenced bytes flushed
                """)
            // An %error'd batched continue (NOT a connection close — that
            // fails the captures too) leaves a healthy-looking completed
            // repair with the pane still PAUSED server-side. Retry ONE
            // generation-checked, tolerate-errors, fire-and-forget continue
            // (review round 2, M3) — same still-owner scoping as the error
            // path below (R11: a successor owns the pane's pause state).
            if continueErrored, await stillOwner(key, generation) {
                await client.sendList([
                    TmuxCommand(text: continueCommand, tolerateErrors: true) { _ in }
                ])
            }
        } catch PaneReplayWriteError.superseded {
            // A newer attach owns the pane: its own sequence manages the
            // gate, the fence, and the pause state (R11). Send nothing.
            Self.logger.debug("""
                repair superseded at writeReplay for \(server, privacy: .public)/\(paneID, privacy: .public) \
                gen=\(generation)
                """)
        } catch {
            // Still-owner cleanup (capture %error, malformed state, replay
            // write failure): unpause (tolerate-errors, fire-and-forget — it
            // covers "the pause ran but batch 2's continue may not have")
            // and abort the repair so the stream resumes. A pane frozen
            // forever behind a fence is worse than a hole. A STALE failure
            // sends nothing — the successor owns the pane's pause state.
            //
            // TOCTOU residual (accepted): the still-owner check and the
            // continue send are not atomic — a successor can interpose
            // between them, so this continue can land inside the successor's
            // pause window in a vanishingly narrow race. Consequence: a torn
            // capture that differentially self-heals, same class as the
            // accepted pause-failure tear.
            Self.logger.error("""
                repair failed for \(server, privacy: .public)/\(paneID, privacy: .public) \
                gen=\(generation): \(String(describing: error), privacy: .public)
                """)
            if await stillOwner(key, generation) {
                await client.sendList([
                    TmuxCommand(text: continueCommand, tolerateErrors: true) { _ in }
                ])
                supervisor.fanout.abortRepair(key: key, generation: generation)
            }
        }
    }

    private func stillOwner(_ key: PaneKey, _ generation: UInt64) async -> Bool {
        await supervisor.currentGeneration(server: key.server, paneID: key.paneID) == generation
    }
}
