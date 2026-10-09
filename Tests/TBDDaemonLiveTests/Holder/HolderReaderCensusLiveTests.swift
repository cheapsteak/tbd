import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The reader-count assertion, driven through the registry's real arbitration
/// against a real pty.
///
/// `HolderReaderCensusTests` pins the ledger itself — what a violation is, what
/// a departure is, what the count means. This file asks the question that
/// matters in production and that a value type cannot answer: **does the
/// arbitration actually make the transitions it claims to?** The ordinary
/// attach-and-detach cycle must count zero violations, and the ledger must name
/// the right reader at every step of it. A detector that reported a violation
/// on the healthy path would be worse than none, because the first thing a soak
/// would do is stop believing it.
///
/// **Assertions are on the counter, not on log output** — a detector whose only
/// interface is a message is one no test can pin.
///
/// **`ptyReader(for:)` is the honest instrument, and this suite uses it as
/// such.** `reader(for:)` answers for a suspended reader as well as a draining
/// one, and `viewerAttachment(for:)` answers "a viewer *may* hold this pty";
/// neither is "who is reading", which is exactly the fact the census exists to
/// hold explicitly.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real job.
@Suite(.serialized)
struct HolderReaderCensusLiveTests {

    /// The same speak-only-when-spoken-to job the handback and seizure suites
    /// use: a job writing on its own would fill the terminal queue during the
    /// windows these tests spend with nobody reading.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    // MARK: - The clean cycle

    /// Daemon reading → drain quiesced → viewer attaches and reads → viewer
    /// detaches → daemon resumes. Five transitions, one reader at a time, and
    /// the counter untouched from end to end.
    @Test func theOrdinaryAttachAndDetachCycleCountsNoViolations() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        #expect(await fixture.registry.readerCensusViolations == 0)
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon, """
            an adopted session is the daemon's to read, and the census is where that is \
            recorded explicitly rather than inferred from a slot plus a drain flag
            """)

        // The vend takes the daemon off the pty and puts the viewer on it. Both
        // halves happen inside `beginAttach`, which is the ordering the whole
        // design rests on: the daemon stops reading at the vend, not at the
        // acknowledgement.
        let viewer = try await fixture.attachAViewer()
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID)
                == .viewer(attach: viewer.generation), """
            the session is read by the viewer that acknowledged it, and by nobody else
            """)
        #expect(await fixture.registry.readerCensusViolations == 0, """
            the attach handshake reported a double reader: the daemon's drain was still \
            counted when its pty was vended
            """)

        // The ordering the app owns and the daemon cannot check: leave the pty
        // first, then say so.
        viewer.close()
        try await fixture.registry.acceptHandback(
            terminal: fixture.terminalRow, generation: viewer.generation,
            preamble: viewer.terminal.snapshot())

        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon)
        #expect(await fixture.registry.readerCensusViolations == 0, """
            the handback resumed the daemon's drain while a viewer was still counted on \
            that pty
            """)
        #expect(await fixture.registry.lastReaderCensusViolation == nil)

        // And the session is genuinely live again, so the cycle that counted
        // zero is the cycle a user actually gets.
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        try await resumed.write(Data("AFTER-DETACH\n".utf8))
        #expect(await pollUntil("the job's answer after the handback") {
            await resumed.renderScreen().contains("GOT:AFTER-DETACH")
        })
        #expect(await fixture.registry.readerCensusViolations == 0)
    }

    /// The uncooperative detach: an app that died holding an acknowledged
    /// attach. The seizure is licensed by an app-liveness verdict rather than
    /// by the viewer's own detach, and it must reach the same ledger state —
    /// one reader, no violation.
    @Test func seizingFromAConfirmedDeadAppCountsNoViolations() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        // Exactly what a dying app does: its descriptors close with it, and no
        // detach follows.
        viewer.close()

        let reclaimed = await fixture.registry.reclaimSessionsFromADeadApp()
        #expect(reclaimed == [fixture.terminalID])

        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon)
        #expect(await fixture.registry.readerCensusViolations == 0, """
            the seizure put the daemon back on a pty the census still counted a viewer on
            """)
    }

    /// Adoption is idempotent through the slot, and the census must agree: a
    /// second `adopt` of a live session hands back the reader that is already
    /// draining rather than publishing a second one. If it ever published
    /// twice, this is the assertion that sees it — `reader(for:)` returning the
    /// same object cannot tell a reused reader from a second one built beside
    /// it and thrown away.
    @Test func aSecondAdoptOfALiveSessionAddsNoSecondReader() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        _ = try await fixture.registry.adopt(terminal: fixture.terminalRow)

        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon)
        #expect(await fixture.registry.readerCensusViolations == 0)
    }

    // MARK: - Teardown

    /// A released session leaves the ledger, so a long-lived daemon's census
    /// cannot grow an entry per session it has ever torn down — and so the
    /// count a soak reads describes live sessions rather than every session
    /// that ever existed.
    @Test func releasingASessionTakesItOffTheCensus() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon)

        await fixture.registry.release(terminalID: fixture.terminalID)

        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == nil, """
            a released session is read by nobody, and a ledger that still named its reader \
            would refuse the next adoption of that pty as a double read
            """)
        #expect(await fixture.registry.readerCensusViolations == 0)
    }

    /// A session torn down while a viewer still holds its pty: the viewer's
    /// descriptor refers to a terminal whose job is being killed, so the
    /// release is also that reader leaving. The ledger has to see it, or the
    /// count would carry a phantom viewer for the daemon's whole life.
    @Test func releasingAnAttachedSessionTakesItsViewerOffTheCensus() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID)
                == .viewer(attach: viewer.generation))

        await fixture.registry.release(terminalID: fixture.terminalID)
        viewer.close()

        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == nil)
        #expect(await fixture.registry.readerCensusViolations == 0)
    }

    // MARK: - Reading the count back

    /// The summary line is the durable half of the detector: the count lives in
    /// daemon memory, so a persisted `.notice` is the only thing that answers
    /// "did the soak see any violations?" weeks later. On a healthy cycle it
    /// has to say so positively.
    @Test func theSummaryReportsAHealthyAttachedSessionAsClean() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        defer { viewer.close() }

        let summary = await fixture.registry.readerCensusSummary
        #expect(summary.contains("violations=0"), "\(summary)")
        #expect(summary.contains("daemon-read=0"), "\(summary)")
        #expect(summary.contains("viewer-read=1"), "\(summary)")
        #expect(summary.contains("last-violation=none"), "\(summary)")
    }
}
