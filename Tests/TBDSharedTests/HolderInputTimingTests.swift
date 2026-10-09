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
    /// request the way the app holds an injection — but it does sit on the
    /// critical path of every holder send to an open tab, where neither
    /// write-side bound does. Pinning it under both is how a later tuning pass
    /// is stopped from quietly putting a multi-second wait in front of every
    /// composed message.
    ///
    /// Asserts the **production constants**, like the test above.
    @Test("The screen pull's bound is shorter than both write-side bounds")
    func screenPullBoundIsShorterThanTheWriteSideBounds() {
        #expect(
            HolderInputTiming.screenPullBound < HolderInputTiming.pasteHoldBound,
            """
            the screen pull is consulted before every holder send composes, so \
            \(HolderInputTiming.screenPullBound) is latency a user waits for; \
            \(HolderInputTiming.pasteHoldBound) is a fail-safe margin on a write that \
            loses nothing by waiting.
            """)
        #expect(
            HolderInputTiming.screenPullBound < HolderInputTiming.injectionAckDeadline,
            """
            a supervision nudge to an open tab pays the pull's \
            \(HolderInputTiming.screenPullBound) and then, in the worst case, the ack's \
            \(HolderInputTiming.injectionAckDeadline) as well.
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
}
