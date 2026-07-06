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

/// The attach orchestration v2 (M4.3, addendum §3): `attach.ready` triggers
/// pause → capture → replay → gate → unpause, with pause as the serialization
/// mechanism — the pane emits nothing between the pause and the unpause the
/// orchestrator sends only after the replay bytes are in the pipe, so live
/// output physically cannot race the replay. No interleave buffer.
///
/// Sequence:
///  1. Acknowledge the attach and read its CURRENT generation atomically —
///     the whole sequence is tagged with it, and the ready-timeout stops
///     threatening the attach (its purpose is "app never acked").
///  2. ONE atomic command list down the `-CC` stream: pause, then the
///     4-command capture (main history, alt screen, pane state, pending).
///  3. Assemble the replay (`ReplayWriter`) and write it into the pane's
///     pipe behind the still-closed gate (`writeReplay`, generation-checked).
///  4. Open the gate (`markReady`) — ONLY after the replay bytes landed.
///  5. Unpause LAST, on every exit path after the pause was sent EXCEPT
///     mid-sequence supersession: pause state is per PANE on the shared
///     per-server correlator, so a superseded generation leaves the unpause
///     to its successor's own FIFO-ordered sequence — a stale continue could
///     otherwise land inside the successor's pause window and resume output
///     into its still-closed gate. (A stale unpause on an unpaused pane
///     no-ops via tolerate-errors.)
///
/// Measured residual (tmux 3.6a, M4 live matrix): pause → continue DISCARDS
/// pane output emitted while paused — tmux resumes delivery from the pane's
/// CURRENT position, draining nothing (with or without the `pause-after`
/// client flag; iTerm2 handles `%pause` by re-capturing for the same reason).
/// So output the pane emits between the capture and the unpause is lost to
/// the viewer: a boundary-only, strictly-forward gap. Live output still
/// cannot precede or interleave the replay; closing the gap needs an
/// interleave buffer (capture fence → gate open), a design follow-up.
struct AttachReplayOrchestrator: Sendable {
    /// How the sequence ended without error.
    enum Outcome: Equatable {
        /// Replay delivered, gate open — the attach is live.
        case ready
        /// A newer attach replaced this one mid-sequence (`writeReplay` saw a
        /// different generation). Benign race: the stale viewer is gone and
        /// the successor runs its own sequence — surfaced as RPC success.
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

    init(supervisor: TmuxControlSupervisor,
         commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?,
         historyDepth: Int = 50_000,
         onHistoryTruncation: (@Sendable (Int) -> Void)? = nil) {
        self.supervisor = supervisor
        self.commandProvider = commandProvider
        self.historyDepth = historyDepth
        self.onHistoryTruncation = onHistoryTruncation
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
        case .acknowledged(let acknowledged):
            generation = acknowledged
        }
        guard let client = await commandProvider(server) else {
            throw AttachReplayFailure(
                generation: generation, underlying: AttachReplayError.noCommandClient)
        }

        // ONE atomic sendList: pause FIRST, then the capture batch — atomicity
        // in the FIFO guarantees nothing (not even our own commands) slips
        // between the pause and the captures, and everything the pane emitted
        // before the pause is already ordered ahead of the capture replies.
        //
        // All entries tolerate errors at the correlator level: a capture
        // %error (pane died mid-attach) must fail THIS attach, not tear down
        // the server's connection and every other pane on it. The orchestrator
        // turns any capture failure into `AttachReplayError.captureFailed`.
        let pause = "refresh-client -A '\(paneID):pause'"
        let captureCommands = [
            "capture-pane -peqJN -S -\(historyDepth) -t \(paneID)",
            // -a: alt screen; -q: an alt-less pane yields empty, not %error.
            "capture-pane -peqJN -a -q -t \(paneID)",
            PaneStateCapture.listPanesCommand(target: paneID),
            "capture-pane -p -P -C -t \(paneID)",
        ]
        let results = await sendBatch(client, texts: [pause] + captureCommands)

        // The pause has been sent — from here, unpause runs on every exit
        // path EXCEPT mid-sequence supersession (defer-equivalent; `defer`
        // can't await the actor call).
        do {
            let outcome = try await replayAndOpenGate(
                server: server, paneID: paneID, generation: generation,
                captureResults: Array(results.dropFirst()),
                captureCommands: captureCommands)
            // `.superseded` (writeReplay saw a newer generation) SKIPS the
            // unpause: pause state is per PANE on the shared correlator, and
            // FIFO ordering puts the successor's own pause → captures →
            // replay → unpause sequence AFTER ours — a stale continue here
            // could land while the successor is mid-capture with its gate
            // still closed, resuming live output into a closed gate (dropped;
            // widens the boundary gap). Accepted residual: if the successor's
            // ready never arrives, the pane stays paused until the NEXT
            // attach's sequence unpauses it — benign (no viewer is watching;
            // tmux buffers server-side).
            if outcome == .ready {
                await sendUnpause(client, paneID: paneID)
            }
            return outcome
        } catch {
            await sendUnpause(client, paneID: paneID)
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
        let (currentScreen, savedScreen, stateLines, pending) = (captured[0], captured[1], captured[2], captured[3])

        // Truncation telemetry (plan M4.4 fold-in): at >= depth lines the
        // capture almost certainly hit the history ceiling and older
        // scrollback was lost to this replay.
        if currentScreen.count >= historyDepth {
            Self.logger.info("""
                capture hit history ceiling for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(currentScreen.count) lines >= depth \(self.historyDepth)
                """)
            onHistoryTruncation?(currentScreen.count)
        }

        guard let state = try PaneStateCapture.state(forPane: paneID, in: stateLines) else {
            throw AttachReplayError.paneStateMissing
        }
        // capture-pane's two legs INVERT meaning with `alternate_on` (verified
        // live against tmux 3.6a by the M4 integration matrix): without `-a`
        // it returns the pane's CURRENT screen — the ALT content when the pane
        // is in alt mode (primary history is inaccessible there) — while `-a`
        // returns the SAVED grid, i.e. the pre-1049h primary snapshot. Map
        // legs by what each screen must be painted with, not by flag.
        let replay = try ReplayWriter.assemble(
            history: state.alternateOn ? savedScreen : currentScreen,
            altScreen: state.alternateOn ? currentScreen : nil,
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
        // routed from here lands strictly after the replay.
        await supervisor.markReady(server: server, paneID: paneID)
        return .ready
    }

    /// Unpause, tolerate-errors: must no-op when the pane wasn't paused or a
    /// newer attach already unpaused it. Fire-and-forget — the reply is not
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
