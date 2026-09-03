import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// What the reclaimer is allowed to conclude from a probe that threw.
///
/// The reclaimer releases a reader on two conditions — the drain has reached
/// the end of the session's output, **and** the holder says the child exited —
/// and the second one is only a condition if it takes an *answer*. A probe that
/// merely failed collapses the pair back to the first condition, which is the
/// one that would throw away the scrollback of a job that closed its terminal
/// and kept running.
///
/// So every way a round trip can fail is ruled on by name here rather than
/// inheriting a catch-all. The suite is the table: one case per
/// `HolderClient.Error`, plus the shape that is not one at all.
///
/// Tier 1 — no holder is spawned and no socket is opened. The end-to-end
/// polarities live in `HolderReclaimTests` (tier 3), which spawns real holders;
/// this suite is what makes the classification cheap to pin case by case.
@Suite struct HolderExitProbeClassificationTests {

    // MARK: - Evidence that the session is over

    /// Nothing listening at the rendezvous is the one failure that establishes
    /// anything: the holder process is gone.
    ///
    /// `ENOENT` and `ECONNREFUSED` are the only two errnos read as absence,
    /// and they are read that way in two other places already —
    /// `RowlessHolderCollector.productionHandshake` and
    /// `HolderRendezvousCollector.probeForListener`. Three readers of the same
    /// two errnos must not disagree, so this pins the agreement rather than
    /// trusting it.
    ///
    /// It is established rather than retried because absence is monotone here:
    /// the session's holder provably bound the path once, since a hand-over
    /// came over it, and a holder that has gone does not come back.
    @Test func nothingListeningIsEvidenceTheSessionIsOver() {
        for code in [ENOENT, ECONNREFUSED] {
            let outcome = HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.cannotConnect(path: "/tmp/gone.sock", errno: code))
            #expect(
                outcome == .established(.exitedStatusUnknown),
                """
                errno \(code) at the rendezvous means the holder is gone, and the honest record \
                of how the job ended is that nobody collected it: \(outcome)
                """)
        }
    }

    // MARK: - Failures worth asking again about

    /// A connect that failed for any other reason describes this daemon's own
    /// attempt, not the holder.
    ///
    /// Descriptor exhaustion, an interrupted syscall, buffer pressure, a
    /// connect timeout: none of them is a fact about the child, and every one
    /// of them can be gone by the next attempt.
    @Test func anyOtherConnectFailureIsRetried() {
        for code in [EINTR, EMFILE, ENFILE, ENOBUFS, ENOMEM, ETIMEDOUT, EACCES] {
            let outcome = HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.cannotConnect(path: "/tmp/holder.sock", errno: code))
            #expect(
                outcome == .retry,
                "errno \(code) says nothing about the child and must be asked again: \(outcome)")
        }
    }

    /// A round trip that reached the socket and then failed is retried.
    ///
    /// A holder winding down hangs up mid-frame, and so does one killed between
    /// the accept and its answer; whether that surfaces as `peerClosed` or as a
    /// broken pipe on the way out is decided by microseconds, and the two must
    /// not reach different conclusions. The receive timeout arrives as
    /// `transportFailed` too.
    @Test func aFailedRoundTripIsRetried() {
        #expect(HolderRegistry.exitProbeOutcome(for: HolderClient.Error.peerClosed) == .retry)
        #expect(
            HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.transportFailed("Broken pipe")) == .retry)
    }

    /// A frame that is not the description asked for is retried, never read as
    /// an exit.
    ///
    /// The client's own queue can carry an unsolicited push that crossed the
    /// wire with somebody else's answer, so one wrong frame is worth asking
    /// past. A disagreement that persists is a reason to stop trusting the
    /// answer, and the budget then expires into a keep — which is what the
    /// end-to-end suite asserts.
    @Test func anUnreadableAnswerIsRetried() {
        #expect(
            HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.unexpectedResponse("handedOverPTY")) == .retry)
    }

    // MARK: - Failures that establish nothing at all

    /// A refusal is a *live* holder, busy serving somebody else.
    ///
    /// The one failure that was always classified correctly, and the polarity
    /// everything else here was brought into line with: evidence of liveness is
    /// not evidence of exit.
    @Test func aRefusalKeepsTheReader() {
        #expect(HolderRegistry.exitProbeOutcome(for: HolderClient.Error.rejected(version: 1)) == .keep)
    }

    /// A path that cannot be represented was never asked anything, and asking
    /// again would ask the same unrepresentable path.
    @Test func anUnrepresentablePathKeepsTheReader() {
        let outcome = HolderRegistry.exitProbeOutcome(
            for: HolderClient.Error.socketPathTooLong(path: String(repeating: "x", count: 200), limit: 104))
        #expect(outcome == .keep, "a deterministic failure is neither retried nor believed: \(outcome)")
    }

    /// The two cases a `describe` over a fresh client cannot reach are still
    /// classified, and classified as keeps.
    ///
    /// Named rather than left to a fall-through so that unreachability is a
    /// claim the suite makes rather than a gap it leaves: if either ever
    /// becomes reachable, it already has the conservative answer.
    @Test func structurallyUnreachableFailuresKeepTheReader() {
        #expect(HolderRegistry.exitProbeOutcome(for: HolderClient.Error.noDescriptor) == .keep)
        #expect(HolderRegistry.exitProbeOutcome(for: HolderClient.Error.notConnected) == .keep)
    }

    /// Anything that is not a `HolderClient.Error` at all keeps.
    ///
    /// This is the fall-through, and it is the one the bug lived in: a
    /// catch-all that released meant every unclassified failure licensed
    /// throwing a live session's scrollback away.
    @Test func anErrorFromNowhereKeepsTheReader() {
        struct SomethingElse: Swift.Error {}
        #expect(HolderRegistry.exitProbeOutcome(for: SomethingElse()) == .keep)
        #expect(
            HolderRegistry.exitProbeOutcome(for: CancellationError()) == .keep,
            "a cancelled probe answered nothing and must not release a reader")
    }
}
