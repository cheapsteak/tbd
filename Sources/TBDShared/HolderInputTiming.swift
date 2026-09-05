/// The two timeouts that govern how a daemon-originated injection and a user's
/// bracketed paste share one holder-backed session's pty, and the ordering
/// between them that makes the sharing safe.
///
/// They are here, in one type, because they are **one decision**. They are read
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
/// Both call sites keep these as *defaulted initializer parameters*, so a test
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
}
