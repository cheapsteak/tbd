import Foundation
import SwiftTerm
import TBDShared
import TBDTerminalSerialization

/// Turns a viewer's live SwiftTerm into the answer the daemon asked for.
///
/// While a panel is attached to a holder-backed session it holds that session's
/// pty master, so its terminal is the live store and the daemon's retained
/// emulator is frozen at the attach. When the daemon needs the live screen it
/// sends a `screenRequest`, and this is what answers it.
///
/// ## One lock hold, for the same reason the daemon takes one
///
/// Lines, the viewport offset, the cursor, the size, the three child modes and
/// the styled capture are all taken inside a **single** `withTerminal`, which
/// is what makes them one observation rather than several. Taken separately, an
/// IO-thread feed landing between two of them would produce a screen that never
/// existed — modes from after a mode change beside lines from before it, which
/// is exactly the pairing the input path must not compose against.
///
/// `withTerminal`'s discipline applies in full: nothing in the closure calls a
/// `TerminalView` API (the lock is not recursive and re-entry traps), nothing
/// feeds the terminal, and only values come out.
///
/// ## What it answers with, and what it refuses to invent
///
/// A `ViewerScreenPayload`, never a `TerminalScreen`. `source`, the age's
/// interpretation, `modesObserved` and `contentObserved` are facts about which
/// emulator answered and how it came to exist, and this one was seeded by the
/// daemon's attach preamble — it can hand back no more than the daemon gave it.
/// The daemon stamps them from its own reader. Cursor visibility is the one
/// value here that is a default rather than an observation, and the payload
/// says so; `ViewerScreenPayload`'s own doc argues why.
@MainActor
enum ViewerScreenProducer {

    /// What one request produces: the payload, plus the styled capture when one
    /// was asked for.
    struct Answer: Equatable, Sendable {
        let payload: ViewerScreenPayload
        let styledCapture: String?
    }

    /// `DECTCEM`'s default — the cursor is shown unless a child has hidden it.
    ///
    /// Reported as the value, and flagged on the payload as *not* an
    /// observation. SwiftTerm's `TerminalView` implements `TerminalDelegate`
    /// itself and forwards neither `showCursor` nor `hideCursor` onward, and
    /// the only other route is a `DECRQM 25` probe, which must never be fed to
    /// a live parser whose last chunk may have ended mid-sequence. A producer
    /// that can one day observe it changes this and the flag below; the wire
    /// does not move.
    static let cursorVisibleDefault = true

    /// What comes out of the one lock hold: the shared projection, plus the
    /// styled capture when one was asked for.
    ///
    /// A named type rather than a tuple so the closure's return can be written
    /// on the brace's own line, which is where the lint rule wants it and where
    /// a reader looking for "what does this hold produce" wants it too.
    private struct ViewerObservation {
        let projected: ProjectedScreen
        let styled: String?
    }

    /// Project `terminalView`'s terminal for one request.
    ///
    /// - Parameter lastByteAt: when this store last consumed a byte from the
    ///   pty, from `TerminalViewHolder.feedReading`, or nil if it never has.
    /// - Parameter attachedAt: when this panel took the pty. The fallback for
    ///   `lastByteAt`, so a session that has been silent since before its
    ///   viewer arrived reports the age of the store itself rather than zero.
    /// - Parameter now: the same monotonic clock `lastByteAt` was read from.
    ///
    /// Total: a live `TerminalView` always has a terminal to lock, so there is
    /// no "could not read it" outcome here. Whether this store exists at all is
    /// the caller's question, and the caller answers it with `.noTerminal`
    /// before asking.
    static func answer(
        for request: SidecarScreenRequest,
        terminalView: TerminalView,
        lastByteAt: ContinuousClock.Instant?,
        attachedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> Answer {
        let observed = terminalView.withTerminal { terminal -> ViewerObservation in
            let projected = TerminalScreenProjection.project(terminal, maxLines: request.lines)
            guard request.wantStyledCapture else {
                return ViewerObservation(projected: projected, styled: nil)
            }
            return ViewerObservation(
                projected: projected,
                styled: TerminalCellWalk.styledHistory(
                    of: terminal, maxScrollbackLines: request.styledScrollbackLines))
        }
        let projected = observed.projected

        let payload = ViewerScreenPayload(
            lines: projected.lines,
            viewportStart: projected.viewportStart,
            cursorRow: projected.cursorRow,
            cursorColumn: projected.cursorColumn,
            cursorVisible: cursorVisibleDefault,
            cursorVisibleObserved: false,
            columns: projected.size.columns,
            rows: projected.size.rows,
            bracketedPaste: projected.modes.bracketedPaste,
            applicationCursor: projected.modes.applicationCursor,
            alternateScreen: projected.modes.alternateScreen,
            ageMilliseconds: ageMilliseconds(
                since: lastByteAt ?? attachedAt, now: now))
        return Answer(
            payload: payload, styledCapture: observed.styled.map(closedTerminalShape))
    }

    /// The styled capture in the shape Closed Terminals history records, so one
    /// shape is written whichever store produced it.
    ///
    /// `\n`, not `\r\n`, because a revive `cat`s the file rather than feeding it
    /// to a terminal; an SGR reset appended so a revived shell's prompt does not
    /// inherit the last line's colours; and an empty screen stays "", which the
    /// history store records as an entry with no capture. Every one of those
    /// rules is `HolderReader.closedTerminalCapture`'s, applied here rather than
    /// re-derived on receipt — the daemon forwards what a viewer sends.
    private static func closedTerminalShape(_ styled: String) -> String {
        guard !styled.isEmpty else { return "" }
        return styled.replacingOccurrences(of: "\r\n", with: "\n") + "\u{1b}[0m\n"
    }

    /// The interval in milliseconds, never negative.
    ///
    /// **An interval, not an instant**: the app measures on its own monotonic
    /// clock and the daemon forwards the duration, so the two processes never
    /// have to share a notion of now. Clamped at zero rather than trusted,
    /// because the clock is an injected seam here and `TerminalScreen` refuses
    /// a negative age — the daemon clamps again on receipt for the same reason,
    /// and neither clamp makes the other redundant: this one keeps a bad
    /// measurement from going on the wire, that one keeps a bad sender from
    /// failing a machine read.
    private static func ageMilliseconds(
        since: ContinuousClock.Instant, now: ContinuousClock.Instant
    ) -> Int {
        let elapsed = since.duration(to: now)
        let milliseconds =
            elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        return Int(max(0, milliseconds))
    }
}
