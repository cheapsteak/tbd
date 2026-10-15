/// The timeouts that govern how a daemon-originated injection and a user's
/// bracketed paste share one holder-backed session's pty, the ordering between
/// them that makes the sharing safe, and how long the daemon waits for the
/// store that holds a pty to answer a question about it.
///
/// The first two are here, in one type, because they are **one decision**. They are read
/// from opposite ends of the system — `OutgoingInputQueue` (TBDApp) parks a
/// held injection for `pasteHoldBound`, `HolderInjectionCourier` (TBDDaemon)
/// waits `injectionAckDeadline` before writing the pty itself — and neither
/// module can see the other's literal. Left as two literals in two modules,
/// someone shaving the daemon's deadline to cut injection latency would break
/// the app's guarantee without ever opening the app's file.
///
/// ## The invariant
///
/// **`pasteHoldBound` must be strictly shorter than `injectionAckDeadline`.**
///
/// The daemon's injection path fails open: an injection the app does not
/// acknowledge within `injectionAckDeadline` is written by the daemon to its
/// own dup of the pty. The app holds an injection that arrives mid-paste until
/// the paste closes, for at most `pasteHoldBound`. If the daemon's deadline
/// were the shorter of the two, then *every* injection the app held would be
/// written directly by the daemon **while the paste was still open** — landing
/// between the paste's `ESC[200~`/`ESC[201~` markers, where the child absorbs
/// it into the pasted text instead of reading it as input. That is the precise
/// harm the app-side hold exists to prevent, made systematic rather than rare.
///
/// The gap between the two is the app's whole budget for closing a paste and
/// answering. Nothing else claims it.
///
/// ## How it is enforced
///
/// Sharing the constants removes the possibility of two literals drifting; it
/// does not stop someone from editing one of these two lines. Three tests close
/// that, and each catches the drift direction that is actually unsafe:
///
/// - `HolderInputTimingTests` asserts the ordering here, on these values.
/// - `OutgoingInputQueueTests.unclosedPasteDoesNotStrandInjectionForever`
///   pins a *default-constructed* queue's hold to `pasteHoldBound` from both
///   sides — still held one instant short of it, released at it.
/// - `HolderInjectionRoutingTests`' missing-ack and not-before-the-deadline
///   tests pin a *default-constructed* courier's wait to
///   `injectionAckDeadline` from both sides in the same way.
///
/// Every call site keeps these as *defaulted initializer parameters*, so a test
/// can still inject a bound of its own; the defaults are what the pinning tests
/// exercise.
public enum HolderInputTiming {
    /// How long `OutgoingInputQueue` holds a daemon injection that arrived
    /// while a user paste was open, before it stops trusting the paste to
    /// close and writes the injection anyway.
    ///
    /// This bound exists to fail SAFE, not to be tuned for latency: an
    /// unclosed paste is a bug somewhere else in the stack, and losing the
    /// injection on top of it would compound the failure instead of surfacing
    /// it. Two seconds is an enormous margin — a legitimate paste closes
    /// within one or a few main-actor turns, because SwiftTerm emits its start
    /// marker, payload and end marker back-to-back.
    ///
    /// Shortening this is **not** an alternative way to satisfy the invariant
    /// above: the write on expiry is itself a controlled instance of the
    /// between-markers write, chosen over stranding the injection forever, so
    /// a shorter bound only commits that harm sooner on a merely-slow paste.
    /// The invariant is satisfied by keeping `injectionAckDeadline` longer.
    public static let pasteHoldBound: Duration = .seconds(2)

    /// How long `HolderInjectionCourier` waits for the app's `.injectionAck`
    /// before writing the session's pty from the daemon itself.
    ///
    /// Five seconds, matching the attach handshake's `readyTimeout` precedent
    /// elsewhere in this subsystem. The number is not the point; its being
    /// longer than `pasteHoldBound` is.
    public static let injectionAckDeadline: Duration = .seconds(5)

    /// How long the daemon waits for a viewer's answer to a screen request
    /// before answering from its own retained emulator instead.
    ///
    /// **Much shorter than the other two, and for a reason that is theirs in
    /// reverse.** `pasteHoldBound` and `injectionAckDeadline` govern a *write*:
    /// nothing is lost by waiting, the fallback writes the same bytes, and the
    /// generous margin buys safety. This bound sits on a *read* that is on the
    /// critical path of every holder send to an open tab — the input path asks
    /// the oracle before it composes, so a supervision nudge to a session
    /// somebody has open pays this wait and then, in the worst case, the
    /// injection ack's as well. It also has a correct fallback to land on: a
    /// bound that expires answers `staleDaemon` from the emulator retained
    /// since the attach, which is what every consumer's policy was already
    /// written against.
    ///
    /// Half a second is therefore a latency budget rather than a safety margin.
    /// It is many main-actor turns for an app that is awake, and an app that is
    /// napping, wedged or mid-paste was never going to answer in five seconds
    /// either — and those are exactly the moments supervision most wants to
    /// act, so the read must not be the thing that blocks it.
    ///
    /// **Ordering against the other two carries no invariant.** The write-side
    /// pair constrain each other because the app holds an injection the daemon
    /// is timing; nothing holds a screen request. This bound is shorter than
    /// both only because a read on a latency path should be, and
    /// `HolderInputTimingTests` pins that relationship so a later tuning pass
    /// cannot quietly put a multi-second wait in front of every send.
    public static let screenPullBound: Duration = .milliseconds(500)

    /// How long a holder-backed terminal's disposal waits for the viewer that
    /// holds its pty to hand back the session's final screen, before writing
    /// the Closed Terminals entry without one.
    ///
    /// **Shorter than the read bound, not equal to it**, because the two waits
    /// are spent in different places. `screenPullBound` sits in front of an
    /// RPC answer nobody is watching render; this one sits inside a close — a
    /// gesture the user made and is watching complete, where the panel being
    /// asked is itself being torn down. A quarter of a second is still many
    /// main-actor turns for an awake app, and the only app that can spend the
    /// whole of it is one that was not going to answer at all.
    ///
    /// **Expiring costs a capture and nothing else.** The entry is written
    /// either way, carrying the row's Claude session id, which is all a revive
    /// needs; what is lost is the screen text, and the alternative to losing it
    /// is presenting the daemon's attach-time screen as a session's final one.
    /// So the wait is bounded against the close rather than against the value
    /// of the answer.
    public static let closedTerminalPullBound: Duration = .milliseconds(250)

    /// How long the daemon waits for a viewer's answer when the question is
    /// being asked **to compose a send**, rather than to answer a read.
    ///
    /// The tightest of the four, and the asymmetry is the point. Three things
    /// differ between this and the read bound:
    ///
    /// - **A read has nobody waiting on it; a send does.** `terminal.output` is
    ///   answered when it is answered — a supervisor polling a fleet absorbs
    ///   half a second without noticing. A `terminal.send` is a person or a
    ///   rail trying to make something happen, and the wait lands in front of
    ///   the act itself.
    /// - **The send pays twice in the worst case.** A nudge to a session
    ///   somebody has open waits this bound for the modes, and then the
    ///   injection ack's five seconds for the write. The read pays once.
    /// - **Expiry here is a defined behaviour, not a failure.** It falls
    ///   through to the `staleDaemon` rule: proceed on the frozen modes,
    ///   trusting a stale "on" and treating a stale "off" as not known, and
    ///   record the source on the actuation row. That rule was built for
    ///   exactly this branch. A read that gives up has a weaker story — its
    ///   answer is simply older.
    ///
    /// So the trade is a rare stale composition, visible afterwards in the
    /// recorded `modeSource`, against latency on **every** send to an attached
    /// session. 150 ms is five to ten main-actor turns of headroom for an awake
    /// app, while an app that is napping, wedged or mid-paste was never going
    /// to answer inside half a second either.
    ///
    /// **It is a ceiling on waiting, not on work.** A modes-only request makes
    /// the answering viewer read a handful of properties —
    /// `TerminalScreenProjection.project` returns before it walks the buffer
    /// when no lines are asked for — so what this bound covers is scheduling
    /// and the sidecar round trip, not a projection. That is what makes it
    /// generous rather than tight.
    ///
    /// Shorter than `screenPullBound` is the relationship that matters, not the
    /// number; `HolderInputTimingTests` pins it.
    public static let sendPathScreenPullBound: Duration = .milliseconds(150)
}
