import Foundation
import os

/// Shared capture-list + replay-assembly for the two sequences that rebuild a
/// pane's terminal state from tmux captures:
///
///  - the ATTACH orchestrator (M4.3 + Phase B M2): attach.ready → pause →
///    fence → captures+continue → replay behind the closed gate;
///  - the overflow REPAIR coordinator (Phase B M3): queue overflow → pause →
///    wait for the reader → recapture + atomic continue → replay → fence
///    flush.
///
/// Both send the SAME 6-command capture list and assemble the SAME replay
/// bytes; extracting them here keeps the two sequences byte-identical (the
/// M3 repair is exactly "the attach's capture half, re-run mid-session").
enum PaneCaptureReplay {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    /// The capture half of the atomic captures+continue batch — all entries
    /// tolerate errors at the correlator level: a capture %error (pane died
    /// mid-sequence) must fail THIS sequence, not tear down the server's
    /// connection and every other pane on it. The caller turns any capture
    /// failure into `AttachReplayError.captureFailed`.
    /// THREE capture legs (review H1): `-a` reaches only the saved primary
    /// VIEWPORT while the pane is on the alt screen — the primary
    /// SCROLLBACK is reachable only through the history portion of a
    /// no-`-a` capture (adding `-S` to the `-a` leg is a no-op; live-probed
    /// on tmux 3.6a). So the scrollback is captured on its own leg
    /// (`-E -1` = end before the visible screen), which works during alt
    /// mode too, and the assembler recombines the legs by `alternate_on`.
    static func captureCommands(paneID: String, historyDepth: Int) -> [String] {
        [
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
    }

    /// Parse the capture batch's results and assemble the replay bytes —
    /// everything between "all reply blocks are in hand" and "write the
    /// replay into the pipe". Throws `AttachReplayError.captureFailed` /
    /// `.paneStateMissing`, `PaneStateCaptureError`, or `ReplayWriterError`;
    /// the caller owns the write, the gate/fence, and failure cleanup.
    static func assemble(
        captureResults: [Result<[String], TmuxCommandError>],
        captureCommands: [String],
        server: String,
        paneID: String,
        historyDepth: Int,
        onHistoryTruncation: (@Sendable (Int) -> Void)?
    ) throws -> Data {
        var captured: [[String]] = []
        for (result, command) in zip(captureResults, captureCommands) {
            switch result {
            case .success(let lines):
                captured.append(lines)
            case .failure(let error):
                logger.error("""
                    capture failed for \(server, privacy: .public)/\(paneID, privacy: .public) \
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
            logger.info("""
                capture hit history ceiling for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(historyLeg.count) lines >= depth \(historyDepth)
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
        return try ReplayWriter.assemble(
            history: state.alternateOn ? scrollback + savedLeg : combinedLeg,
            altScreen: state.alternateOn ? screenLeg : nil,
            pending: pending,
            state: state,
            cols: state.width,
            rows: state.height)
    }
}

extension TmuxControlCommandClient {
    /// Send `texts` as ONE atomic command list and await ALL their replies.
    /// Sound because the correlator guarantees every completion eventually
    /// fires: a reply block per command in FIFO order, or `.connectionClosed`
    /// for the remainder when the stream ends. (A mute-but-alive tmux stalls
    /// this like any other awaited command — stream teardown resolves it.)
    /// Every entry tolerates errors at the correlator level — one dead pane's
    /// %error must not tear down the whole server's connection.
    func sendBatch(texts: [String]) async -> [Result<[String], TmuxCommandError>] {
        let collector = TmuxCommandBatchCollector(count: texts.count)
        let commands = texts.enumerated().map { index, text in
            TmuxCommand(text: text, tolerateErrors: true) { result in
                collector.set(index, result)
            }
        }
        sendList(commands)
        return await collector.wait()
    }
}

/// Bridges the correlator's per-command completion callbacks to one awaited
/// batch result. Lock-protected: completions arrive on the correlator actor,
/// `wait` suspends the sender's task.
final class TmuxCommandBatchCollector: @unchecked Sendable {
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
