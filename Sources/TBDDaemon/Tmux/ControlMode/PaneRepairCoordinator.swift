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
    /// Reader-catch-up poll pacing and deadline (step 2) — injectable so
    /// tests can wedge the reader without waiting 30 s.
    private let writableCheckInterval: Duration
    private let writableDeadline: Duration
    /// One in-flight repair per pane. Belt-and-suspenders: the sink's
    /// `repairing` flag already gates re-signaling at the fanout, but a
    /// duplicate signal for a key mid-repair must still be a no-op here.
    private var inFlight: Set<PaneKey> = []

    init(supervisor: TmuxControlSupervisor,
         commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?,
         historyDepth: Int = 50_000,
         writableCheckInterval: Duration = .milliseconds(50),
         writableDeadline: Duration = .seconds(30)) {
        self.supervisor = supervisor
        self.commandProvider = commandProvider
        self.historyDepth = historyDepth
        self.writableCheckInterval = writableCheckInterval
        self.writableDeadline = writableDeadline
    }

    /// Test seam: whether a repair for `key` is currently running.
    func isInFlight(_ key: PaneKey) -> Bool {
        inFlight.contains(key)
    }

    /// Run the repair cycle for `key` unless one is already in flight for it.
    func repairIfNeeded(key: PaneKey, generation: UInt64) async {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        await repair(key: key, generation: generation)
    }

    private func repair(key: PaneKey, generation: UInt64) async {
        let (server, paneID) = (key.server, key.paneID)
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
        let deadline = ContinuousClock.now + writableDeadline
        waitLoop: while true {
            switch supervisor.fanout.isPipeWritable(key: key, generation: generation) {
            case nil:
                return
            case true?:
                break waitLoop
            case false?:
                if ContinuousClock.now >= deadline {
                    // The reader is wedged. Deliberately do NOT abortRepair:
                    // a continue now would just re-overflow the queue, so
                    // the pane stays PAUSED (tmux buffers it server-side in
                    // pane history/screen — nothing is being lost) and the
                    // sink stays `repairing` (which keeps re-signaling
                    // gated). A later attach replaces the sink and re-runs
                    // the full pause→capture→replay sequence, which heals
                    // everything this repair could not.
                    Self.logger.error("""
                        repair reader wedged for \(server, privacy: .public)/\(paneID, privacy: .public) \
                        gen=\(generation) — leaving the pane paused; a later attach re-runs the sequence
                        """)
                    return
                }
                try? await Task.sleep(for: writableCheckInterval)
            }
        }

        // Step 3 — arm the repair fence (generation-checked; requires the
        // sink to still be `repairing`). The pane is provably silent — the
        // pause reply is in hand and a paused pane delivers nothing — so no
        // output can race the arming. Refusal → superseded; send nothing.
        guard supervisor.fanout.beginRepairFence(key: key, generation: generation) else { return }

        // Step 4 — captures + continue, ONE atomic list with the continue
        // LAST: identical shape (and shared construction) with the attach's
        // batch 2; the zero-seam probe fact carries the heal.
        let captureCommands = PaneCaptureReplay.captureCommands(
            paneID: paneID, historyDepth: historyDepth)
        let results = await client.sendBatch(texts: captureCommands + [continueCommand])
        // A failed batched continue is log-only, as in the attach: a %error
        // is tolerated, and a connection close fails the captures too, which
        // aborts the repair below with its own unpause.
        if case .failure(let continueError) = results.last {
            Self.logger.error("""
                repair batched continue failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(String(describing: continueError), privacy: .public)
                """)
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
