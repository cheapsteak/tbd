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
}
