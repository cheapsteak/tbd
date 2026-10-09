import Foundation
import TBDShared

/// The disposal path's half of the two-store question: when a holder-backed
/// terminal is closed, archived or reclaimed, which store holds the screen that
/// is the session's *final* one.
///
/// Closed Terminals history wants colours, so this cannot ride the typed
/// screen — `TerminalScreen`'s whitelist forbids ESC. It rides the reply's
/// optional styled capture instead, produced by the same cell walk the daemon's
/// own `HolderReader.closedTerminalCapture` uses and taken in the same
/// observation as the lines. The rejected alternative — have the viewer hand
/// back a preamble-shaped snapshot and ingest it into the daemon's suspended
/// emulator before capturing — reuses more code and makes a *read* write to
/// that emulator as a side effect, which is the one thing the two-store model
/// forbids.
///
/// **The shape is the producer's, not this file's.** Whoever answers joins with
/// `\n`, appends an SGR reset, and answers `""` for an empty screen, so one
/// shape reaches the history store whichever store produced it. Nothing here
/// reshapes a capture on receipt; a second shaping site is how the two stores
/// would start writing two kinds of file.
extension HolderScreenResolver {

    /// The session's final screen for Closed Terminals history, from whichever
    /// store is live — or nil when neither can answer, which the history store
    /// records as an entry with no capture.
    ///
    /// The routing fact is the census ledger's, exactly as it is for `screen`,
    /// and the three ways cost what they cost there:
    ///
    /// - **The daemon is reading** — its emulator is the live store. Answer
    ///   from it and **send no frame**, so a fleet of detached sessions closing
    ///   never goes near the app.
    /// - **A viewer is reading** — the daemon's emulator has been frozen since
    ///   the attach, and presenting that as a session's final screen would be a
    ///   confident wrong answer. Pull, and take the styled capture the viewer
    ///   sends.
    /// - **Nobody is reading** — there is no live store, and the daemon's own
    ///   answer (nil, from a suspended reader) is what this path has always
    ///   written.
    ///
    /// **A dispose is never blocked or lost by a pull that does not answer.**
    /// Every outcome that is not a styled answer re-reads the daemon's own
    /// store and takes whatever it honestly has — nil while it is still
    /// suspended, a real capture if the viewer detached while the request was
    /// in flight and the reader resumed draining. The entry is written either
    /// way, carrying the row's Claude session id, which is all a revive needs.
    ///
    /// - Parameter daemonCapture: the daemon's own store's answer, deferred so
    ///   that the detached case is the only one that evaluates it and the
    ///   viewer case does not render an emulator nobody will read.
    /// - Parameter bound: how long the close waits. Tighter than a read's by
    ///   default — see `HolderInputTiming.closedTerminalPullBound`.
    func closedTerminalCapture(
        terminalID: UUID,
        daemonCapture: () async -> String?,
        bound: Duration = HolderInputTiming.closedTerminalPullBound
    ) async -> String? {
        guard case .viewer = await ptyReader(terminalID), let pull else {
            return await daemonCapture()
        }
        let answer = await pull.pull(
            terminalID: terminalID,
            // Modes-only on the typed half: the screen is not what this caller
            // came for, and `lines: 0` makes the app walk the grid once, for
            // the styled capture alone.
            lines: 0,
            retainedScrollbackLines: retainedScrollbackLines,
            wantStyledCapture: true,
            bound: bound)
        if case .answered(_, let styled) = answer, let styled { return styled }
        return await daemonCapture()
    }
}
