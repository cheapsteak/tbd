import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A claim sweep against a real holder: the app says it no longer holds a
/// session, and the daemon reads that session again.
///
/// `HolderClaimReconcileTests` covers which claims a sweep selects, on a
/// registry with no holder behind it. This file covers what a sweep's
/// take-back then does with a real pty and a real job: the reader the attach
/// suspended goes back on the descriptor, the census records the daemon
/// reading again, and the job is jiggled — `takeBacksCompleted` counts only a
/// take-back that got past its jiggle.
///
/// Every viewer here is vended to `HandbackFixture.viewerApp` under
/// `attachSeq` 5, and every sweep is that app's, through `throughSeq` 5 with
/// nothing held: the app has closed its descriptor and stopped listing the
/// session, which is the statement a sweep acts on.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real job.
@Suite(.serialized)
struct HolderClaimReconcileLiveTests {

    /// The speak-only-when-spoken-to job the handback suites use: a job writing
    /// on its own would fill the terminal queue during the windows these tests
    /// spend with nobody reading.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    /// The app's number for every attach here, and the sweep's `throughSeq`.
    private static let attachSeq: UInt64 = 5

    // MARK: - Taken back

    /// **A lost handback**, recovered. The panel closed its descriptor and its
    /// `pane.detach` never arrived, so the claim stands with nothing reading
    /// the pty. The app's next sweep leaves the session out, and the daemon
    /// puts its own suspended reader back on the pty: one reader, the same
    /// one, and the session is live again.
    @Test func anOwnedUnheldCoveredClaimIsTakenBack() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer(attachSeq: Self.attachSeq)
        let suspended = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID)
                    == .viewer(attach: viewer.generation))
        let completedBefore = await fixture.registry.takeBacksCompleted
        // The panel leaves the pty, and its handback is lost on the way.
        viewer.close()

        let sweep = await fixture.registry.reconcileClaims(
            heldBy: HandbackFixture.viewerApp, held: [], throughSeq: Self.attachSeq, act: true)

        #expect(sweep == HolderClaimSweep(takenBack: [fixture.terminalID], wouldTakeBack: []))
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil, """
            the sweep left the claim standing, so this session stays undrained and refused to \
            every attach until the app quits
            """)
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon, """
            the census does not show the daemon reading the session the sweep took back
            """)
        #expect(await fixture.registry.takeBacksCompleted == completedBefore + 1, """
            the sweep's take-back did not finish, so the job was never jiggled to repaint
            """)
        #expect(await fixture.registry.readerCensusViolations == 0)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === suspended, """
            the sweep opened a second hand-over for a session whose own reader had never left \
            the descriptor
            """)
        #expect(await resumed.isDraining, "the sweep took the session back without reading it")

        try await resumed.write(Data("AFTER-THE-SWEEP\n".utf8))
        #expect(await pollUntil("the job's answer after the sweep") {
            await resumed.renderScreen().contains("GOT:AFTER-THE-SWEEP")
        })
    }

    /// **A lost attach reply**, recovered. The descriptor reached the app but
    /// the reply carrying the generation did not, so the app cannot hand back
    /// an attach it cannot name: it closes the descriptor and stops listing
    /// the session. The attach is still pending, delivered to that app, and
    /// the sweep covers it — settled and taken back in one pass, so its
    /// ready-timeout finds nothing left to turn into a claim.
    @Test func aSentPendingAttachIsCovered() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(
            terminalID: fixture.terminalID, attachSeq: Self.attachSeq)
        await fixture.registry.recordAttachRecipient(
            HandbackFixture.viewerApp, terminalID: fixture.terminalID, generation: vend.generation)
        let held = try #require(await fixture.registry.reader(for: fixture.terminalID))
        Darwin.close(vend.ptyFD)

        let sweep = await fixture.registry.reconcileClaims(
            heldBy: HandbackFixture.viewerApp, held: [], throughSeq: Self.attachSeq, act: true)

        #expect(sweep == HolderClaimSweep(takenBack: [fixture.terminalID], wouldTakeBack: []), """
            an attach delivered to the app, which it says it no longer holds, was not taken back
            """)
        #expect(await fixture.registry.pendingAttachGeneration(for: fixture.terminalID) == nil)
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil)
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon)
        #expect(await fixture.registry.takeBacksCompleted == 1)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === held, "the take-back opened a second hand-over")
        #expect(await resumed.isDraining, "the suspended reader was not put back on the pty")

        // The ready-timeout still fires, late, and finds nothing left to settle.
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation, reason: .unacknowledged)
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil, """
            a late ready-timeout claimed a session the sweep had already taken back
            """)

        try await resumed.write(Data("AFTER-THE-LOST-REPLY\n".utf8))
        #expect(await pollUntil("the job's answer after the pending attach was taken back") {
            await resumed.renderScreen().contains("GOT:AFTER-THE-LOST-REPLY")
        })
    }

    // MARK: - One take-back at a time

    /// The app's handback attempt gave up waiting for its answer, so the
    /// session left the held set while the daemon was still putting the
    /// reader back — and the next sweep arrives inside that take-back. The
    /// claim is held across the resume by design, so the sweep sees it
    /// standing; it must leave the outcome to the take-back in flight rather
    /// than resume the same reader a second time, which the census would count
    /// as the daemon starting to read a pty it already reads.
    ///
    /// Parked through the take-back barrier rather than raced: the real window
    /// is a single `await` on the reader's actor.
    @Test func aTakeBackInFlightIsNotDoubled() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }
        // Only Sendable values cross into the task below.
        let registry = fixture.registry
        let terminalID = fixture.terminalID
        let row = fixture.terminalRow

        let viewer = try await fixture.attachAViewer(attachSeq: Self.attachSeq)
        let suspended = try #require(await registry.reader(for: terminalID))
        let generation = viewer.generation
        let preamble = viewer.terminal.snapshot()
        viewer.close()

        let barrier = ReentryBarrier()
        await registry.setTakeBackBarrier(barrier.hook())
        let handback = Task {
            try await registry.acceptHandback(
                terminal: row, generation: generation, preamble: preamble)
        }
        #expect(await pollUntil("the handback to reach the take-back barrier") {
            await barrier.hasParked
        })

        let sweep = await registry.reconcileClaims(
            heldBy: HandbackFixture.viewerApp, held: [], throughSeq: Self.attachSeq, act: true)

        #expect(sweep == HolderClaimSweep(takenBack: [], wouldTakeBack: []), """
            the sweep claimed a take-back the handback in flight owns
            """)
        #expect(await !suspended.isDraining, """
            the sweep resumed the reader while the handback was still taking the session back
            """)
        #expect(await registry.viewerAttachment(for: terminalID) == generation, """
            the sweep cleared a claim the handback is holding across its resume
            """)
        #expect(await registry.takeBacksCompleted == 0)

        await barrier.release()
        try await handback.value

        #expect(await registry.takeBacksCompleted == 1, "one attach was taken back twice")
        #expect(await registry.readerCensusViolations == 0, """
            a second take-back recorded the daemon as starting to read a pty it was already reading
            """)
        #expect(await registry.lastReaderCensusViolation == nil)
        #expect(await registry.viewerAttachment(for: terminalID) == nil)
        #expect(await registry.ptyReader(for: terminalID) == .daemon)
        let resumed = try #require(await registry.reader(for: terminalID))
        #expect(resumed === suspended, "the take-back opened a second hand-over")
        #expect(await resumed.isDraining, "the handback did not put the reader back on the pty")
    }
}

// MARK: - Forcing an interleave

/// Holds the **first** caller that reaches the seam it is installed on, and
/// waves through every one after it — the same barrier
/// `HolderAppDeathSeizureTests` parks its handback on, for the same reason:
/// the race is a continuation-ordering accident inside an actor, so
/// reproducing it by timing would pass by luck. The polling is bounded through
/// `pollUntil`, so a barrier nobody releases fails its test with a named
/// diagnostic instead of hanging the suite.
private actor ReentryBarrier {
    private var parked = false
    private var released = false

    /// Whether a caller is being held.
    var hasParked: Bool { parked }

    /// Lets the parked caller finish.
    func release() { released = true }

    private var isReleased: Bool { released }

    /// True for the first caller only; every later one is waved through.
    private func claimPark() -> Bool {
        guard !parked else { return false }
        parked = true
        return true
    }

    nonisolated func hook() -> @Sendable () async -> Void {
        { [self] in
            guard await claimPark() else { return }
            await pollUntil("the test to release the parked take-back") { await self.isReleased }
        }
    }
}
