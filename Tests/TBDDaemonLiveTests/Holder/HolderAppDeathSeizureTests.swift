import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The **uncooperative** half of the handback: an app that died still holding
/// a session's pty.
///
/// `HolderDetachHandbackTests` covers the cooperative path — the viewer closes
/// its descriptor and tells the daemon, carrying the screen back with it. This
/// file covers what happens when nobody tells the daemon anything, which is the
/// state that file's `aViewerThatVanishesWithoutDetachingIsLeftToAppLiveness`
/// deliberately leaves standing: the claim held, nothing draining the pty, no
/// injection able to reach it, and every re-open refused.
///
/// **Only a confirmed death licenses this.** The verdict itself is arbitrated
/// in `HolderAppLivenessTests` (tier 1, scripted process table); everything
/// here starts *after* that verdict and asks what the registry then does with
/// a real pty, a real job, and a claim nobody is coming back for.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real job.
@Suite(.serialized)
struct HolderAppDeathSeizureTests {

    /// The same speak-only-when-spoken-to job the handback suite uses: a job
    /// writing on its own would fill the terminal queue during the windows
    /// these tests spend with nobody reading.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    // MARK: - Confirmed gone

    /// The whole task, at the far end. An app died holding an acknowledged
    /// attach: no detach arrived, no preamble came back, and no cooperation
    /// from it is possible. The daemon puts its own suspended reader back on
    /// the pty, and the session is *live* again — not merely unclaimed.
    ///
    /// **One reader, throughout.** The reader the seizure resumes is the very
    /// one the attach suspended, so no second hand-over is opened and no second
    /// drain loop is started against a master this registry already holds. The
    /// two counters say that in the only way object identity cannot: a
    /// `drainLoopsStarted` unchanged across the seizure, and a
    /// `peakLiveDrainLoops` that never reached two.
    @Test func aConfirmedDeadAppsSessionRevertsToDaemonRead() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        let suspended = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(await !suspended.isDraining,
                "the daemon is still draining a pty a viewer acknowledged owning")
        let loopsBefore = await fixture.registry.drainLoopsStarted
        // Exactly what a dying app does, and nothing else: its descriptors
        // close with the process, and no detach follows.
        viewer.close()

        let reclaimed = await fixture.registry.reclaimSessionsFromADeadApp()
        #expect(reclaimed == [fixture.terminalID])

        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil, """
            the dead app's claim outlived it, so this session stays undrained, unwritable and \
            refused by every re-open for the daemon's whole life
            """)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === suspended, """
            the seizure opened a second hand-over for a session whose own reader had never left \
            the descriptor
            """)
        #expect(await fixture.registry.drainLoopsStarted == loopsBefore, """
            the seizure published a second drain loop for a pty this registry was already \
            holding a reader for
            """)
        #expect(await fixture.registry.peakLiveDrainLoops == 1,
                "two drain loops were live at once, which is byte theft seen after the fact")
        #expect(await resumed.isDraining, "the daemon took the session back without reading it")

        // Live again, not merely claimed: the daemon writes, the job answers,
        // and the answer lands on the screen it is keeping.
        try await resumed.write(Data("AFTER-THE-APP-DIED\n".utf8))
        #expect(await pollUntil("the job's answer after the seizure") {
            await resumed.renderScreen().contains("GOT:AFTER-THE-APP-DIED")
        })
    }

    /// The other state a claim can be in, and it takes the other arm. An attach
    /// that timed out unacknowledged kept its *suspended* reader — the viewer
    /// might have been reading all along, so the daemon neither resumed nor
    /// released it. A confirmed death settles that: the reader goes back on the
    /// pty it never let go of, rather than a second hand-over being opened
    /// against a master this registry already holds.
    @Test func aSeizureAfterAnUnacknowledgedAttachResumesTheSuspendedReader() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        let held = try #require(await fixture.registry.reader(for: fixture.terminalID))
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation, reason: .unacknowledged)
        #expect(await held.isDraining == false, "an unacknowledged attach leaves its reader suspended")
        Darwin.close(vend.ptyFD)

        let reclaimed = await fixture.registry.reclaimSessionsFromADeadApp()
        #expect(reclaimed == [fixture.terminalID])

        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === held, """
            the seizure opened a second hand-over for a session whose own reader had never left \
            the descriptor
            """)
        #expect(await resumed.isDraining, "the suspended reader was not put back on the pty")
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil)

        try await resumed.write(Data("RESUMED-AFTER-DEATH\n".utf8))
        #expect(await pollUntil("the job's answer after the suspended reader resumed") {
            await resumed.renderScreen().contains("GOT:RESUMED-AFTER-DEATH")
        })
    }

    // MARK: - The generation discipline

    /// A seizure names the attach it is taking back, and any generation but the
    /// standing one is refused — the same rule the handback keeps. It matters
    /// more here, not less: an app death is arbitrated asynchronously, so a
    /// verdict can be applied to a session whose claim has since moved on, and
    /// applying it would put a drain on a pty another process is reading.
    ///
    /// The guard is `==`, so it is pinned identically in both directions and
    /// either side proves it. This passes a generation one *ahead* of the one
    /// the viewer holds, which is the cheaper side to construct: no second
    /// attach is needed to move the standing claim off the number under test.
    @Test func aSeizureUnderAStaleGenerationLeavesTheCurrentAttachAlone() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        defer { viewer.close() }

        // The specific case, not merely `Error.self`: a mutation that threw
        // `notAHolderSession` — refusing every seizure, including the ones this
        // path exists to perform — would satisfy the loose form.
        await #expect(throws: HolderRegistry.Error.handbackSuperseded(
            terminalID: fixture.terminalID, generation: viewer.generation &+ 1)) {
            try await fixture.registry.seizeFromDeadApp(
                terminalID: fixture.terminalID, generation: viewer.generation &+ 1)
        }
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == viewer.generation,
                "a stale seizure took the pty from the attach that holds it")
        // The reader is retained across an attach, so its presence proves
        // nothing here; `isDraining` reads the drain thread's own flag.
        let stillSuspended = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(await !stillSuspended.isDraining,
                "a stale seizure put the daemon back on a pty a viewer is reading")
    }

    /// **A seizure no longer needs the holder to be reachable**, which is the
    /// strictly better outcome the retained reader buys — and it is what used
    /// to make this case a failure at all.
    ///
    /// Before the emulator was retained, an acknowledged attach left the slot
    /// empty, so a seizure had to open a fresh hand-over from the holder; a
    /// rendezvous socket a `connect` could no longer find was then a way for a
    /// crashed app to brick every session it had open. The reader now never
    /// leaves the descriptor, so the resume is a restart of its own thread and
    /// asks the holder nothing.
    ///
    /// **The failing take-back is no longer reachable by a test on this arm,
    /// and no failure is fabricated to stand in for it.** All that is left that
    /// can throw is `HolderReader.resumeDraining`, which fails only when
    /// `pipe()` does — an out-of-descriptors condition a test on a shared box
    /// must not induce. `takeBackFromViewer` still drops the claim on its error
    /// path, and that behaviour is still correct; it is simply unreachable from
    /// here now.
    @Test func aFailedSeizureIsNoLongerReachableThroughAMissingSocket() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        let suspended = try #require(await fixture.registry.reader(for: fixture.terminalID))
        viewer.close()
        try FileManager.default.removeItem(
            atPath: try HolderRendezvous.socketPath(
                sessionID: fixture.terminalID,
                environment: HolderProcessFixture.environment(home: fixture.process.home)))

        let reclaimed = await fixture.registry.reclaimSessionsFromADeadApp()
        #expect(reclaimed == [fixture.terminalID], """
            the seizure could not take the session back with the rendezvous socket gone, so it \
            still depends on a hand-over from the holder
            """)
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil, """
            the seizure left the dead app's claim standing, so nothing drains this pty and every \
            re-open is refused
            """)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === suspended, "the seizure opened a second hand-over")
        #expect(await resumed.isDraining, "the suspended reader was not put back on the pty")
    }
}
