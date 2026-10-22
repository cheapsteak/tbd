import AppKit

/// The scroll monitor's per-panel wheel state: whether it claims a scroll
/// event, and how many SGR wheel reports that event becomes.
///
/// `TerminalPanelRepresentable.Coordinator`'s monitor hand-encodes wheel
/// reports because SwiftTerm's own `scrollWheel` cannot run in this
/// embedding: a tmux panel, and a holder panel with "Send clicks and drags
/// to apps that use the mouse" off, keep `allowMouseReporting` off, so on the
/// alternate screen that handler returns before reporting anything. With the
/// toggle on a holder panel reports, but the monitor still claims every wheel
/// event while a mouse mode is on, so the wheel takes this one path, with its
/// rate bound, in both states of the toggle. Bypassing the entry
/// point also bypassed its arithmetic, and the monitor sent
/// `max(1, Int(abs(deltaY)))` reports for every event — a 0.3-line trackpad
/// delta became a full report, and a flick's 60-120 Hz momentum tail became
/// one report per event. Each report makes a fullscreen TUI repaint, so
/// scrolling manufactured an output flood: 634 output chunks/s while
/// scrolling against 79.5/s while typing (#719). This restores the
/// arithmetic of `MacTerminalView.scrollWheel`, not its entry point:
///
/// - **Precise devices** (trackpad, Magic Mouse) deliver point deltas. They
///   accumulate signed against the cell height, one report per whole cell
///   crossed, with the remainder banked for the next event. The bank is
///   discarded when the direction reverses and when a new gesture begins, so
///   a stale fraction never leaks into motion it did not belong to.
/// - **Classic wheels** deliver line-quantized notches: one report per
///   notch, direction from the sign.
/// - **Momentum** flows through the same accumulator, so inertial scrolling
///   still moves a fullscreen agent. Dropping it outright would make the
///   trackpad feel dead there; the accumulator alone already keeps a
///   sub-cell tail event from becoming a report.
/// - **A token bucket** — `sustainedReportsPerSecond` with a burst of
///   `burstReports` — bounds whatever the arithmetic lets through, from
///   either kind of device. Reports over it are dropped, not queued: a
///   backlog would keep scrolling after the fingers stop, and reports still
///   arriving after the TUI leaves mouse mode land in its composer as
///   literal text such as `<64;23;32M`.
///
/// Pure value logic: every input arrives as a plain value and time is the
/// event's own `timestamp`, so tests drive it without an `NSEvent`, a clock
/// or a timer.
struct ScrollWheelAccumulator {
    /// Where an event sits in a scroll gesture, collapsed from `NSEvent`'s
    /// `phase` and `momentumPhase` to what the accumulator acts on.
    enum Phase: Equatable, Sendable {
        /// Neither phase set: a classic wheel notch, or a precise device that
        /// reports no gesture.
        case unphased
        /// Fingers touched down or started moving (`.mayBegin`, `.began`): a
        /// new gesture, which must not inherit the last one's remainder.
        case gestureBegan
        /// The rest of a gesture with fingers on the surface (`.changed`,
        /// `.stationary`, `.ended`, `.cancelled`).
        case gestureChanged
        /// Inertial motion after the fingers lift (`momentumPhase` set). It
        /// continues the gesture it follows, remainder included.
        case momentum

        init(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
            if !momentumPhase.isEmpty {
                self = .momentum
            } else if phase.contains(.began) || phase.contains(.mayBegin) {
                self = .gestureBegan
            } else if !phase.isEmpty {
                self = .gestureChanged
            } else {
                self = .unphased
            }
        }
    }

    /// One scroll event, as the plain values the accumulator reads from it.
    struct Event: Equatable, Sendable {
        /// Vertical motion, positive for wheel-up. Points (`scrollingDeltaY`)
        /// when `precise`; otherwise the notch's `deltaY`, of which only the
        /// sign is read.
        var deltaY: CGFloat
        /// `hasPreciseScrollingDeltas`.
        var precise: Bool
        var phase: Phase
        /// The event's own `timestamp`, in seconds; the token bucket refills
        /// from its progress.
        var timestamp: TimeInterval
    }

    /// Reports the bucket regains per second of event time.
    static let sustainedReportsPerSecond: Double = 100
    /// Reports the bucket holds when full: what passes at once after a pause.
    static let burstReports: Double = 6

    /// Signed points of precise motion not yet worth a whole cell.
    private var remainder: CGFloat = 0
    /// Reports the bucket can still send. Starts full.
    private var tokens: Double = ScrollWheelAccumulator.burstReports
    /// `timestamp` of the last refill; nil until the first report.
    private var lastRefill: TimeInterval?

    /// Whether the monitor claims `event`, and the reports it sends. `lines`
    /// is signed — positive is wheel-up (button 4), negative wheel-down
    /// (button 5) — and its magnitude is the report count.
    ///
    /// The claim depends only on the modes, never on the arithmetic. A wheel
    /// event the monitor passes through reaches SwiftTerm's own
    /// `scrollWheel`, whose fallback (no mouse reporting) differs by buffer:
    /// on the alternate screen it converts accumulated motion into Up/Down
    /// arrow keys, which land on whatever is attached, including a composer
    /// draft; on the normal screen it instead scrolls SwiftTerm's own local
    /// scrollback, which is exactly what an un-mouse-aware shell prompt
    /// needs. Claiming must tell those two apart — claiming on the normal
    /// screen would silence scrollback for every ordinary shell tab.
    ///
    /// Once reporting is on, buffer doesn't matter: always claim, including
    /// an event that sends nothing — a zero delta, a sub-cell delta being
    /// banked, or reports the bucket drops — since an unclaimed one would
    /// fall through to the arrow-key fallback and interleave stray keys with
    /// the real reports.
    ///
    /// Before reporting is on — at spawn, or any other moment it is
    /// transiently off — claim and drop on the alternate screen (there is no
    /// reporting session to forward to, and dropping is far less surprising
    /// than turning a scroll into keystrokes), but pass through unclaimed on
    /// the normal screen so SwiftTerm's native scrollback keeps working.
    /// Either way the bank is discarded, as upstream does, so motion
    /// suppressed now is not handed to the first event after reporting
    /// comes back.
    mutating func reports(
        for event: Event, cellHeight: CGFloat, mouseReporting: Bool, alternateScreen: Bool
    ) -> (claim: Bool, lines: Int) {
        guard mouseReporting else {
            remainder = 0
            return (claim: alternateScreen, lines: 0)
        }
        let lines = wholeLines(for: event, cellHeight: cellHeight)
        return (claim: true, lines: bounded(lines, at: event.timestamp))
    }

    /// The signed reports `event`'s motion is worth, before the rate bound.
    private mutating func wholeLines(for event: Event, cellHeight: CGFloat) -> Int {
        guard event.precise else {
            // A notch is one report whatever its magnitude, and it ends any
            // precise motion in progress.
            remainder = 0
            guard event.deltaY != 0 else { return 0 }
            return event.deltaY > 0 ? 1 : -1
        }
        if event.phase == .gestureBegan { remainder = 0 }
        guard event.deltaY != 0, cellHeight > 0 else { return 0 }
        // A reversal starts from zero rather than netting against a fraction
        // banked in the other direction.
        if remainder * event.deltaY < 0 { remainder = 0 }
        remainder += event.deltaY
        let lines = Int(remainder / cellHeight)
        remainder -= CGFloat(lines) * cellHeight
        return lines
    }

    /// `lines` capped at what the bucket holds at `timestamp`, after
    /// refilling it for the event time elapsed since the last refill.
    private mutating func bounded(_ lines: Int, at timestamp: TimeInterval) -> Int {
        guard lines != 0 else { return 0 }
        if let lastRefill {
            // Clamped so an out-of-order timestamp can never drive the
            // bucket negative.
            let elapsed = max(0, timestamp - lastRefill)
            tokens = min(Self.burstReports, tokens + elapsed * Self.sustainedReportsPerSecond)
        }
        lastRefill = timestamp
        let sent = min(abs(lines), Int(tokens))
        tokens -= Double(sent)
        return lines > 0 ? sent : -sent
    }
}
