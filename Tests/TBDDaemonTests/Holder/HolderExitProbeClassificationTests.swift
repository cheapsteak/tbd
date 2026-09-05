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

    // MARK: - A status the holder pushed before the round trip failed

    /// A holder that pushed its exit has answered, whatever the connection did
    /// afterwards.
    ///
    /// This is the shape the reclaimer actually meets, and the one that
    /// recorded a wrong status: the holder pushes at whichever client is
    /// connected and winds down in the same breath, so the probe is handed
    /// `.exited(code: 7)` and *then* finds the socket hung up under it. The
    /// push is retired as unsolicited — correctly, it answers no request — and
    /// reading only the failure retries at a rendezvous the holder has already
    /// unlinked, where `ENOENT` reads as absence and `exitedStatusUnknown` goes
    /// into the record for a child that exited ordinarily.
    @Test func aPushedExitOutranksTheFailureThatFollowedIt() {
        for failure: HolderClient.Error in [
            .peerClosed,
            .transportFailed("Broken pipe"),
            .cannotConnect(path: "/tmp/gone.sock", errno: ENOENT),
            .cannotConnect(path: "/tmp/gone.sock", errno: ECONNREFUSED),
        ] {
            let outcome = HolderRegistry.exitProbeOutcome(
                for: failure,
                pushedByTheHolder: Self.description(status: .exited(code: 7)),
                expecting: Self.owner)
            #expect(
                outcome == .established(.exited(code: 7)),
                """
                the holder said how its child ended and the daemon was holding the answer; \
                \(failure) must not overwrite it: \(outcome)
                """)
        }
    }

    /// No push leaves every classification exactly as it was.
    @Test func noPushLeavesTheErrnoRulesUntouched() {
        #expect(
            HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.peerClosed,
                pushedByTheHolder: nil,
                expecting: Self.owner) == .retry)
        #expect(
            HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.cannotConnect(path: "/tmp/gone.sock", errno: ENOENT),
                pushedByTheHolder: nil,
                expecting: Self.owner) == .established(.exitedStatusUnknown))
        #expect(
            HolderRegistry.exitProbeOutcome(
                for: HolderClient.Error.rejected(version: 1),
                pushedByTheHolder: nil,
                expecting: Self.owner) == .keep)
    }

    /// A push from another installation's holder is not this registry's answer.
    ///
    /// The same rule the answered path applies to `description.owner`, and it
    /// has to hold here too: a rendezvous path can be re-bound by a holder some
    /// other TBD spawned, and its child's exit says nothing about this one's.
    @Test func aPushFromAnotherInstallationIsIgnored() {
        let outcome = HolderRegistry.exitProbeOutcome(
            for: HolderClient.Error.peerClosed,
            pushedByTheHolder: Self.description(
                status: .exited(code: 7), owner: HolderOwnerToken(rawValue: "someone-else")),
            expecting: Self.owner)
        #expect(outcome == .retry, "a stranger's holder answered for its own child: \(outcome)")
    }

    /// A push that says the child is alive establishes nothing.
    ///
    /// The holder pushes only from its reaping branch, so it never sends this —
    /// which is exactly why it is pinned: a status that is not terminal must
    /// not become one by riding an unsolicited frame.
    @Test func aPushThatSaysAliveEstablishesNothing() {
        let outcome = HolderRegistry.exitProbeOutcome(
            for: HolderClient.Error.peerClosed,
            pushedByTheHolder: Self.description(status: .alive),
            expecting: Self.owner)
        #expect(outcome == .retry, "\"still running\" is not a terminal status: \(outcome)")
    }

    // MARK: - Support

    private static let owner = HolderOwnerToken(rawValue: "acme-installation")

    private static func description(
        status: HolderChildStatus, owner: HolderOwnerToken = HolderExitProbeClassificationTests.owner
    ) -> HolderChildDescription {
        HolderChildDescription(
            childPID: 4242,
            ttyName: "/dev/ttys004",
            status: status,
            launch: HolderLaunchRequest(
                executable: "/bin/sh",
                arguments: ["-c", "exit 7"],
                workingDirectory: "/tmp",
                environment: [:],
                columns: 80,
                rows: 24),
            owner: owner)
    }
}
