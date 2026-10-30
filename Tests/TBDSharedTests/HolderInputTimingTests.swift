import Testing

@testable import TBDShared

/// The one thing `HolderInputTiming` exists to make un-driftable: the app's
/// paste hold must expire **before** the daemon gives up waiting for an ack.
///
/// Read the type's own documentation for why. The short version: the daemon's
/// injection path fails open, so if its deadline were the shorter of the two,
/// every injection the app parked behind an open paste would be written by the
/// daemon *into* that paste — between the `ESC[200~`/`ESC[201~` markers, where
/// the child absorbs it as pasted text. Rare harm would become systematic.
///
/// This asserts the **production constants**, not values the test supplies —
/// that is the whole point, and any rewrite that introduces a local `let` for
/// either side has quietly turned this into a test of nothing.
@Suite("Holder input timing")
struct HolderInputTimingTests {
    @Test("The paste hold expires strictly before the injection-ack deadline")
    func pasteHoldIsStrictlyShorterThanTheAckDeadline() {
        #expect(
            HolderInputTiming.pasteHoldBound < HolderInputTiming.injectionAckDeadline,
            """
            OutgoingInputQueue holds an injection for \(HolderInputTiming.pasteHoldBound) while a \
            paste is open, and HolderInjectionCourier writes the pty itself after \
            \(HolderInputTiming.injectionAckDeadline). With the hold no shorter than the \
            deadline, every held injection lands between the paste's markers.
            """)
    }

    /// The read-side bound carries no safety invariant — nothing holds a screen
    /// request the way the app holds an injection — but it is a wait the caller
    /// of a screen read such as `terminal.output` sits through, while both
    /// write-side bounds are fail-safe margins on writes that lose nothing by
    /// waiting. Pinning it under both is how a later tuning pass is stopped
    /// from quietly stretching a screen read's wait out to a write-side margin
    /// of seconds.
    ///
    /// Asserts the **production constants**, like the test above.
    @Test("The screen pull's bound is shorter than both write-side bounds")
    func screenPullBoundIsShorterThanTheWriteSideBounds() {
        #expect(
            HolderInputTiming.screenPullBound < HolderInputTiming.pasteHoldBound,
            """
            a screen read such as `terminal.output` waits up to \
            \(HolderInputTiming.screenPullBound) for the viewer, latency its caller sits \
            through; \(HolderInputTiming.pasteHoldBound) is a fail-safe margin on a write \
            that loses nothing by waiting.
            """)
        #expect(
            HolderInputTiming.screenPullBound < HolderInputTiming.injectionAckDeadline,
            """
            a screen read gives up on the viewer after \
            \(HolderInputTiming.screenPullBound) and answers from the daemon's emulator; \
            that should stay well under the \(HolderInputTiming.injectionAckDeadline) a \
            write may wait for its ack, because the write loses nothing by waiting and \
            the read has a fallback to land on.
            """)
    }

    /// The disposal bound is spent inside a close the user is watching, where
    /// the read bound is spent in front of an answer nobody watches render. It
    /// carries no safety invariant either — an expiry costs a capture and the
    /// entry is written regardless — so what is pinned is that it stays the
    /// tighter of the two.
    ///
    /// Asserts the **production constants**, like the tests above.
    @Test("the disposal pull's bound is tighter than the read pull's")
    func closedTerminalBoundIsTighterThanTheReadBound() {
        #expect(
            HolderInputTiming.closedTerminalPullBound < HolderInputTiming.screenPullBound,
            """
            a dispose waits \(HolderInputTiming.closedTerminalPullBound) while a window is \
            closing, where \(HolderInputTiming.screenPullBound) is spent in front of an RPC \
            answer nobody is watching render.
            """)
    }

    /// The send path waits less than the read path for the same answer, because
    /// a read's caller can absorb the wait and a send's cannot — and because
    /// the send's expiry lands on a defined behaviour (the stale-modes rule)
    /// rather than merely on an older answer.
    ///
    /// Pinned as a relationship, not a number: the constants may be tuned, but
    /// a send that waited *longer* than a read would have the asymmetry
    /// backwards, and the cost would land on every message composed for a
    /// session somebody has open.
    ///
    /// Asserts the **production constants**, like the tests above.
    @Test("The send path's pull bound is shorter than the read path's")
    func sendPathBoundIsShorterThanTheReadPathBound() {
        #expect(
            HolderInputTiming.sendPathScreenPullBound < HolderInputTiming.screenPullBound,
            """
            the oracle waits \(HolderInputTiming.sendPathScreenPullBound) in front of every \
            holder send to an attached session, while a read waits \
            \(HolderInputTiming.screenPullBound) for a caller that can absorb it; a send \
            waiting the longer of the two has the asymmetry backwards.
            """)
        // Still a real wait, not a token one: an awake app answers in one or
        // two main-actor turns, and a bound under that would make the stale
        // fallback the ordinary answer for an open tab — the exact branch the
        // pull exists to stop being ordinary.
        #expect(HolderInputTiming.sendPathScreenPullBound > .milliseconds(32))
    }
}
