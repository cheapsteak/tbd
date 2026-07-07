import Foundation
import os

/// Failures of the attach.ready replay sequence. Every case is an attach
/// failure — the RPC layer detaches the pane and returns an error so the app
/// falls back to grouped sessions (addendum §5). The one NON-error outcome
/// that isn't a success (`superseded`) is an `Outcome`, not an error.
enum AttachReplayError: Error, Equatable {
    /// No sink for the pane at attach.ready time (detached, timed out, or
    /// never attached) — there is nothing to replay into.
    case notAttached
    /// No `-CC` correlator exists for the server (connection never started
    /// or already torn down) — the capture batch cannot be issued.
    case noCommandClient
    /// A capture command in the batch returned `%error` (or the connection
    /// closed mid-batch). Tolerated at the CORRELATOR level — one dead pane's
    /// capture must not tear down the whole server's connection — but fatal
    /// to THIS attach.
    case captureFailed(command: String)
    /// The `list-panes` reply did not include the pane being attached.
    case paneStateMissing
}

/// A replay-sequence failure tagged with the generation of the attach the
/// sequence was running for (read atomically at acknowledge time, step 1 of
/// `performAttachReady`). The RPC layer's failure cleanup MUST be
/// generation-checked (`detachIfGeneration`): by the time a stale sequence's
/// failure surfaces, a newer attach may own the pane's sink, and an
/// unconditional detach would EOF the healthy successor's pipe.
///
/// `AttachReplayError.notAttached` is deliberately thrown UNWRAPPED — it
/// occurs before any generation exists (no sink at acknowledge time), and it
/// needs no cleanup: the sink either doesn't exist or belongs to a different
/// attach, so the caller must not detach anything.
struct AttachReplayFailure: Error {
    /// Generation of the attach whose sequence failed.
    let generation: UInt64
    /// The actual failure (`AttachReplayError` / `PaneStateCaptureError` /
    /// `ReplayWriterError` / `PaneReplayWriteError`).
    let underlying: any Error
}

/// The attach orchestration v2 (M4.3, addendum §3) with the Phase B M2
/// attach-boundary fence (issue #376): `attach.ready` triggers pause →
/// fence → captures+continue → replay → gate+flush, with pause as the
/// serialization mechanism and a generation-scoped fence queue closing the
/// boundary gap — live output physically cannot precede, interleave, OR be
/// lost around the replay.
///
/// Sequence:
///  1. Acknowledge the attach and read its CURRENT generation atomically —
///     the whole sequence is tagged with it, and the ready-timeout stops
///     threatening the attach (its purpose is "app never acked").
///  2. Batch 1: the PAUSE alone, awaited. Command replies and `%output`
///     reach the daemon on paths that do NOT preserve relative order
///     end-to-end (`%output` is routed synchronously on the connection
///     reader thread via `outputSink` → `PaneFanout.route`; replies hop
///     AsyncStream → supervisor actor → correlator actor → completion), so
///     the fence can only be armed at a moment the pane is PROVABLY silent
///     — arming it any earlier could fence pre-pause output the capture
///     already holds; any later could miss post-continue output racing
///     ahead of a reply. The pause reply is that moment: everything the
///     pane emitted before the pause has, by stream order, already been
///     routed (and dropped by the closed gate — it is in the capture, no
///     loss), and a PAUSED pane delivers NOTHING (live-probed, tmux 3.6a:
///     zero bytes even with ~500k tokens emitted while paused; the content
///     lands in pane history/screen, reachable via capture).
///  3. Arm the fence (generation-checked): output routed for the pane while
///     the gate stays closed now QUEUES (the M1 machinery, drain unarmed)
///     instead of dropping.
///  4. Batch 2: the 6-command capture + the continue, ONE atomic command
///     list with the continue LAST — live-probed (tmux 3.6a, 6/6 trials
///     under throttled AND firehose load): the first live token delivered
///     after an atomic [captures…, continue] is contiguous with the
///     capture's last token, a seam gap of exactly ZERO. Post-continue
///     output flows into the armed fence.
///  5. Assemble the replay (`ReplayWriter`) and write it into the pane's
///     pipe behind the still-closed gate (`writeReplay`, generation-checked)
///     — safe against the fence queue because the drain is never armed
///     while fenced.
///  6. Open the gate (`markReady`) — ONLY after the replay bytes landed. It
///     clears the fence and arms the drain, so the fenced bytes follow the
///     replay in order and live output folds in behind them (`route()`'s
///     queue-nonempty ordering). ZERO output loss at the attach seam.
///  7. No trailing unpause on success — batch 2's continue already ran.
///     Failure paths after the pause still send a generation-checked
///     unpause: it covers "the pause executed but batch 2's continue may
///     not have" (e.g. the send raced a connection close); a redundant
///     continue on an unpaused pane no-ops via tolerate-errors. Mid-sequence
///     supersession NEVER unpauses (R11): pause state is per PANE on the
///     shared per-server correlator, so a superseded generation leaves it
///     to its successor's own FIFO-ordered sequence — a stale continue
///     could otherwise land inside the successor's pause window and resume
///     output into its still-closed gate.
///
/// HISTORY (pre-M2 residual, M4 live matrix): pause → continue DISCARDS
/// pane output emitted while paused — tmux resumes delivery from the pane's
/// CURRENT position, draining nothing (with or without the `pause-after`
/// client flag; iTerm2 handles `%pause` by re-capturing for the same
/// reason). Before the fence, output the pane emitted between the capture
/// and the trailing unpause was therefore lost to the viewer: a measured
/// boundary-only forward gap (3–25 tokens under load). The fence + atomic
/// captures+continue batch eliminate it. Remaining residual: fence-queue
/// OVERFLOW during replay assembly (a blast pane exceeding the 128 KB cap)
/// still drops whole chunks with telemetry — M3's pause+repair cycle owns
/// healing that.
struct AttachReplayOrchestrator: Sendable {
    /// How the sequence ended without error.
    enum Outcome: Equatable {
        /// Replay delivered, gate open — the attach is live.
        case ready
        /// A newer attach replaced this one mid-sequence (`writeReplay` or
        /// `markReady` saw a different generation). Benign race: the stale
        /// viewer is gone and the successor runs its own sequence — surfaced
        /// as RPC success.
        case superseded
    }

    let supervisor: TmuxControlSupervisor
    /// Command seam (`TmuxControlModeBridge.commandProvider`): resolves the
    /// server's FIFO correlator; tests substitute a fake-backed client.
    let commandProvider: @Sendable (String) async -> TmuxControlCommandClient?
    /// Main-history capture depth (`capture-pane -S -<depth>`). Literal
    /// 50 000 to match the `history-limit 50000` set server-side at tmux
    /// server creation (M4.4, parallel commit); unifying the two constants is
    /// a review concern. Injectable for the truncation-telemetry tests.
    let historyDepth: Int
    /// Truncation-telemetry test hook: invoked with the line count whenever
    /// the main-history capture hits the ceiling (see `performAttachReady`);
    /// production relies on the `.info` log line.
    let onHistoryTruncation: (@Sendable (Int) -> Void)?
    /// Pause-failure test hook (review M4): invoked with the error's
    /// description when the batch's pause command fails while the sequence
    /// proceeds anyway; production relies on the `.error` log line.
    let onPauseFailure: (@Sendable (String) -> Void)?

    init(supervisor: TmuxControlSupervisor,
         commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?,
         historyDepth: Int = 50_000,
         onHistoryTruncation: (@Sendable (Int) -> Void)? = nil,
         onPauseFailure: (@Sendable (String) -> Void)? = nil) {
        self.supervisor = supervisor
        self.commandProvider = commandProvider
        self.historyDepth = historyDepth
        self.onHistoryTruncation = onHistoryTruncation
        self.onPauseFailure = onPauseFailure
    }

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    /// Run the full attach.ready sequence for one pane. On attach failure the
    /// caller detaches the pane (generation-checked) and surfaces an RPC
    /// error (app falls back to grouped sessions). Error surface:
    /// - `AttachReplayError.notAttached` (no sink at acknowledge time) is
    ///   thrown bare — no generation exists yet, so there is nothing for the
    ///   caller to clean up (see `AttachReplayFailure`).
    /// - Every later failure is wrapped in `AttachReplayFailure`, carrying
    ///   the generation this sequence was tagged with so the caller's detach
    ///   cannot hit a successor attach's sink.
    ///
    /// `expectedGeneration` is the app's echo of its own attach's generation
    /// (`AttachRequestResult.generation`). When present and no longer the
    /// pane's CURRENT generation, this ready is stale — a superseded viewer's
    /// ack landing after a successor's attach — and returns `.superseded`
    /// having sent NOTHING on the shared correlator: pause state is keyed per
    /// PANE there, so a stale pause would freeze the pane after the
    /// successor's completed sequence, and a stale continue could resume
    /// output into the successor's still-closed gate. Absent (older app) →
    /// generation-unchecked, as before.
    func performAttachReady(
        server: String, paneID: String, expectedGeneration: UInt64? = nil
    ) async throws -> Outcome {
        // Steps 1+2 of the milestone, atomic in the fanout: read the CURRENT
        // generation and mark the attach acknowledged so the ready-timeout
        // stands down. (Only the post-capture replay WRITE below has a
        // deadline; the capture wait itself has none — a mute-but-alive tmux
        // stalls the attach until the stream closes. Phase B owns that.)
        let generation: UInt64
        switch await supervisor.acknowledgeAttach(
            server: server, paneID: paneID, expectedGeneration: expectedGeneration) {
        case .noSink:
            throw AttachReplayError.notAttached
        case .superseded:
            Self.logger.debug("""
                stale attach.ready for \(server, privacy: .public)/\(paneID, privacy: .public) \
                echoed gen=\(expectedGeneration ?? 0) — a newer attach owns the pane; sending nothing
                """)
            return .superseded
        case .alreadyAcknowledged:
            // A duplicate ready for an already-acked generation (R5-4): the
            // first ready's sequence owns the replay — running a second one
            // would write concurrently into the same pipe. Benign: surfaced
            // as RPC success, nothing sent on the shared correlator.
            Self.logger.debug("""
                duplicate attach.ready for \(server, privacy: .public)/\(paneID, privacy: .public) \
                echoed gen=\(expectedGeneration ?? 0) — replay already owned; sending nothing
                """)
            return .superseded
        case .acknowledged(let acknowledged):
            generation = acknowledged
        }
        guard let client = await commandProvider(server) else {
            throw AttachReplayFailure(
                generation: generation, underlying: AttachReplayError.noCommandClient)
        }
        // Re-check ownership AFTER the provider hop (R10-3, same post-hop
        // pattern as the R7-M1 resize fix): the acknowledge above and the
        // sendList below are separated by an await — a stale task preempted
        // here can otherwise enqueue its PAUSE after the successor's entire
        // sequence (including its unpause) already completed, re-freezing a
        // live pane with nothing left to unpause it.
        guard await supervisor.currentGeneration(server: server, paneID: paneID) == generation else {
            Self.logger.debug("""
                attach.ready superseded across the provider hop for \
                \(server, privacy: .public)/\(paneID, privacy: .public) gen=\(generation) — sending nothing
                """)
            return .superseded
        }

        // Batch 1 — the PAUSE alone, awaited (M2). The fence below can only
        // be armed while the pane is provably silent, and the pause reply is
        // the earliest such moment (see the sequence doc: replies and
        // %output travel order-skewed paths, so no reply-relative moment
        // earlier than "paused and confirmed" is race-free). Tolerates
        // errors at the correlator level like every command this sequence
        // sends: one dead pane must not tear down the whole server's
        // connection.
        let pause = "refresh-client -A '\(paneID):pause'"
        let pauseResults = await sendBatch(client, texts: [pause])

        // A failed pause means the captures below run UNPAUSED: the pane may
        // emit between the capture replies and the gate opening, so the
        // replay can be slightly torn (cursor vs content mismatch). Surface
        // it and PROCEED rather than fail the attach: fullscreen apps
        // repaint differentially and self-heal, and a genuinely dead pane
        // %errors the captures right below, which fails the attach on its
        // own (review M4). The fence still arms — whatever the pane emits
        // after the arm is queued, not lost.
        if case .failure(let pauseError) = pauseResults.first {
            Self.logger.error("""
                attach pause failed for \(server, privacy: .public)/\(paneID, privacy: .public) \
                (\(pause, privacy: .public)): \(String(describing: pauseError), privacy: .public) \
                — proceeding with an unpaused capture (replay may be slightly torn; self-heals)
                """)
            onPauseFailure?(String(describing: pauseError))
        }

        // Post-pause supersession re-check (M2): splitting the batch adds an
        // await between the acknowledge and the capture send — a stale task
        // resumed here must not send its captures+continue after a
        // successor's completed sequence (same rationale as the R10-3
        // post-hop re-check above). R11 scoping: superseded → send NOTHING
        // more and do NOT unpause — the successor's own FIFO-ordered
        // sequence owns the pane's pause state.
        guard await supervisor.currentGeneration(server: server, paneID: paneID) == generation else {
            Self.logger.debug("""
                attach.ready superseded after the pause for \
                \(server, privacy: .public)/\(paneID, privacy: .public) gen=\(generation) — sending nothing
                """)
            return .superseded
        }

        // Arm the fence — the pane is silent (pause reply in hand), so no
        // output can race the arming. Generation-checked: refusal means a
        // newer attach owns the pane, the same benign race as above (R11:
        // no unpause; the successor owns the pause state).
        guard await supervisor.armFence(server: server, paneID: paneID, generation: generation) else {
            Self.logger.debug("""
                attach.ready superseded at the fence for \
                \(server, privacy: .public)/\(paneID, privacy: .public) gen=\(generation) — sending nothing
                """)
            return .superseded
        }

        // Batch 2 — the capture list + the CONTINUE, one atomic command list
        // with the continue LAST (M2): atomicity in the FIFO guarantees
        // nothing slips between the captures and the continue, and the
        // live-probed seam of an atomic [captures…, continue] is exactly
        // zero — the first post-continue byte (which flows into the armed
        // fence) is contiguous with the capture's tail.
        //
        // All entries tolerate errors at the correlator level: a capture
        // %error (pane died mid-attach) must fail THIS attach, not tear down
        // the server's connection and every other pane on it. The orchestrator
        // turns any capture failure into `AttachReplayError.captureFailed`.
        // THREE capture legs (review H1): `-a` reaches only the saved primary
        // VIEWPORT while the pane is on the alt screen — the primary
        // SCROLLBACK is reachable only through the history portion of a
        // no-`-a` capture (adding `-S` to the `-a` leg is a no-op; live-probed
        // on tmux 3.6a). So the scrollback is captured on its own leg
        // (`-E -1` = end before the visible screen), which works during alt
        // mode too, and the assembler recombines the legs by `alternate_on`.
        let captureCommands = [
            // Pure primary scrollback, NO screen rows. QUIRK (live-probed):
            // on a history-less pane this clamps and returns the first
            // visible screen row — the assembler discards this leg when
            // `history_size` == 0. -q guards %error.
            "capture-pane -peqJN -S -\(historyDepth) -E -1 -q -t \(paneID)",
            // Current screen only — the PRIMARY screen normally, the ALT
            // screen while `alternate_on`.
            "capture-pane -peqJN -t \(paneID)",
            // -a: the SAVED primary viewport while `alternate_on`;
            // -q: empty (not %error) when there is no saved screen.
            "capture-pane -peqJN -a -q -t \(paneID)",
            // COMBINED history+screen in ONE invocation (review R8-M3): `-J`
            // joins soft wraps only WITHIN a capture, so the split legs above
            // hard-break a logical line that wraps across the scrollback/
            // screen seam. Non-alt replays use this leg verbatim (identical
            // to the pre-split single capture); the split legs remain for the
            // alt mapping, which has no combined-capture equivalent.
            "capture-pane -peqJN -S -\(historyDepth) -t \(paneID)",
            PaneStateCapture.listPanesCommand(target: paneID),
            "capture-pane -p -P -C -t \(paneID)",
        ]
        let continueCommand = "refresh-client -A '\(paneID):continue'"
        let results = await sendBatch(client, texts: captureCommands + [continueCommand])

        // A failed batched continue is log-only: a %error is tolerated (the
        // failure-path unpause below re-sends one when the captures failed
        // too), and a connection close fails the captures as well — which
        // fails the attach on its own. Pause state is per control CLIENT,
        // so it cannot outlive a closed connection either way.
        if case .failure(let continueError) = results.last {
            Self.logger.error("""
                attach batched continue failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(String(describing: continueError), privacy: .public)
                """)
        }

        // The pause has been sent — from here, every FAILURE exit unpauses
        // unless superseded (defer-equivalent; `defer` can't await the actor
        // call). The SUCCESS path sends nothing more: batch 2's continue
        // already ran.
        do {
            // `.superseded` (writeReplay/markReady saw a newer generation)
            // sends nothing further either — batch 2 (with its continue) was
            // already on the stream BEFORE the successor's own sequence, so
            // FIFO keeps it clear of the successor's pause window (R11).
            return try await replayAndOpenGate(
                server: server, paneID: paneID, generation: generation,
                captureResults: Array(results.dropLast()),
                captureCommands: captureCommands)
        } catch {
            // Generation-checked unpause-on-failure: it covers "the pause
            // executed but batch 2's continue may not have" (e.g. the send
            // raced a connection close); a redundant continue on an unpaused
            // pane no-ops via tolerate-errors. R11 scoping unchanged: a
            // failing STALE sequence must not unpause — its continue could
            // land between a live successor's pause and captures, tearing
            // the successor's capture. The successor's own sequence owns the
            // pane's pause state.
            if await supervisor.currentGeneration(server: server, paneID: paneID) == generation {
                await sendUnpause(client, paneID: paneID)
            }
            throw AttachReplayFailure(generation: generation, underlying: error)
        }
    }

    // MARK: - Sequence body

    private func replayAndOpenGate(
        server: String, paneID: String, generation: UInt64,
        captureResults: [Result<[String], TmuxCommandError>],
        captureCommands: [String]
    ) async throws -> Outcome {
        var captured: [[String]] = []
        for (result, command) in zip(captureResults, captureCommands) {
            switch result {
            case .success(let lines):
                captured.append(lines)
            case .failure(let error):
                Self.logger.error("""
                    attach capture failed for \(server, privacy: .public)/\(paneID, privacy: .public) \
                    (\(command, privacy: .public)): \(String(describing: error), privacy: .public)
                    """)
                throw AttachReplayError.captureFailed(command: command)
            }
        }
        let (historyLeg, screenLeg, savedLeg, combinedLeg, stateLines, pending) =
            (captured[0], captured[1], captured[2], captured[3], captured[4], captured[5])

        // Truncation telemetry (plan M4.4 fold-in): at >= depth lines the
        // scrollback capture almost certainly hit the history ceiling and
        // older scrollback was lost to this replay.
        if historyLeg.count >= historyDepth {
            Self.logger.info("""
                capture hit history ceiling for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(historyLeg.count) lines >= depth \(self.historyDepth)
                """)
            onHistoryTruncation?(historyLeg.count)
        }

        guard let state = try PaneStateCapture.state(forPane: paneID, in: stateLines) else {
            throw AttachReplayError.paneStateMissing
        }
        // Leg recombination (reviews H1 + R8-M3, verified live on tmux 3.6a):
        // - NON-alt: use combinedLeg VERBATIM — one tmux invocation whose -J
        //   joins soft wraps across the scrollback/screen seam, byte-identical
        //   to the pre-split single capture (and immune to the history-less
        //   clamp quirk: with no history it is exactly the screen).
        // - ALT: the primary content must be stitched from historyLeg (pure
        //   scrollback; reachable during alt, but CLAMPS to the first screen
        //   row on a history-less pane, so discarded when history_size == 0)
        //   + savedLeg (the -a saved primary viewport). ACCEPTED RESIDUAL: a
        //   logical line soft-wrapping across THAT seam replays with a
        //   spurious hard break — there is no combined capture that reaches
        //   both regions while the pane is on the alt screen. Cosmetic,
        //   narrow (exact seam alignment), no data loss.
        //   screenLeg is the ALT content in this case.
        let scrollback = state.historySize > 0 ? historyLeg : []
        let replay = try ReplayWriter.assemble(
            history: state.alternateOn ? scrollback + savedLeg : combinedLeg,
            altScreen: state.alternateOn ? screenLeg : nil,
            pending: pending,
            state: state,
            cols: state.width,
            rows: state.height)

        do {
            // Pre-ready, generation-checked; blocks (bounded by its deadline)
            // on this task while the app drains the pipe — never on an actor.
            try supervisor.writeReplay(
                server: server, paneID: paneID, generation: generation, bytes: replay)
        } catch PaneReplayWriteError.superseded {
            // A newer attach owns the pane. Do NOT touch the successor's gate:
            // its own sequence opens it. Benign — surfaced as success.
            Self.logger.debug("""
                replay superseded for \(server, privacy: .public)/\(paneID, privacy: .public) \
                gen=\(generation) — a newer attach owns the pane
                """)
            return .superseded
        }
        // Gate opens ONLY after the replay bytes are in the pipe: live output
        // routed from here lands strictly after the replay. markReady also
        // clears the M2 fence and arms the drain, flushing the fenced bytes
        // (everything the pane emitted since batch 2's continue) in behind
        // the replay — the zero-seam flush. Generation-checked
        // (R6-H1): a re-attach can swap the sink between the writeReplay above
        // and this call, and a stale markReady must not open the successor's
        // gate before ITS replay landed. Refusal is the same benign race as a
        // superseded writeReplay — the successor's own sequence opens its gate.
        guard await supervisor.markReady(server: server, paneID: paneID, generation: generation) else {
            Self.logger.debug("""
                markReady superseded for \(server, privacy: .public)/\(paneID, privacy: .public) \
                gen=\(generation) — a newer attach owns the pane; leaving its gate closed
                """)
            return .superseded
        }
        return .ready
    }

    /// Failure-path unpause (M2: the success path's continue rides batch 2),
    /// tolerate-errors: must no-op when the pane wasn't paused or a newer
    /// attach already unpaused it. Fire-and-forget — the reply is not
    /// awaited (nothing left to order behind it for THIS attach).
    private func sendUnpause(_ client: TmuxControlCommandClient, paneID: String) async {
        await client.sendList([
            TmuxCommand(text: "refresh-client -A '\(paneID):continue'", tolerateErrors: true) { _ in }
        ])
    }

    /// Send `texts` as ONE atomic command list and await ALL their replies.
    /// Sound because the correlator guarantees every completion eventually
    /// fires: a reply block per command in FIFO order, or `.connectionClosed`
    /// for the remainder when the stream ends. (A mute-but-alive tmux stalls
    /// this like any other awaited command — stream teardown resolves it.)
    private func sendBatch(
        _ client: TmuxControlCommandClient, texts: [String]
    ) async -> [Result<[String], TmuxCommandError>] {
        let collector = BatchCollector(count: texts.count)
        let commands = texts.enumerated().map { index, text in
            TmuxCommand(text: text, tolerateErrors: true) { result in
                collector.set(index, result)
            }
        }
        await client.sendList(commands)
        return await collector.wait()
    }
}

/// Bridges the correlator's per-command completion callbacks to one awaited
/// batch result. Lock-protected: completions arrive on the correlator actor,
/// `wait` suspends the orchestrator's task.
private final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[String], TmuxCommandError>?]
    private var continuation: CheckedContinuation<[Result<[String], TmuxCommandError>], Never>?

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ result: Result<[String], TmuxCommandError>) {
        lock.lock()
        results[index] = result
        guard let done = completedResults(), let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: done)
    }

    func wait() async -> [Result<[String], TmuxCommandError>] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let done = completedResults() {
                lock.unlock()
                continuation.resume(returning: done)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// All results, iff every slot is filled. Caller must hold `lock`.
    private func completedResults() -> [Result<[String], TmuxCommandError>]? {
        let filled = results.compactMap { $0 }
        return filled.count == results.count ? filled : nil
    }
}
