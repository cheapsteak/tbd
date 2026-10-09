import Foundation
import Testing
@testable import TBDDaemonLib

/// The reader-count assertion: the always-on detector behind the holder
/// transport's one unrecoverable failure.
///
/// **Two readers on one pty master is silent.** Each `read()` takes bytes the
/// other never sees, and nothing in the kernel, the holder, the daemon or the
/// app says so — the only symptom is a screen that is quietly missing output
/// nobody knows was produced. So an absence of corruption reports is not
/// evidence that the arbitration is correct, and the transport's central safety
/// property cannot be gated on unaided observation. `HolderReaderCensus` is
/// what makes a violation observable: the daemon holds explicit per-session
/// reader state, and every transition into reading asserts the count was zero
/// first.
///
/// **Every assertion here is on the counter, never on log output.** A detector
/// whose only interface is a log line is a detector no test can pin, and a
/// grep-for-the-message test breaks the day somebody rewords it.
///
/// **A violation must not be fatal**, which is why these tests can exist at
/// all: the census counts and logs and then keeps going, recording the
/// newcomer, so a test can drive several violations through one ledger. A
/// `precondition` here would turn a benign ordering race in production into a
/// daemon crash that took every other session's drain down with it.
///
/// Tier 1: a value type, no pty, no process, no clock. The same detector seen
/// through the registry's real attach-and-detach choreography is
/// `HolderReaderCensusLiveTests`.
@Suite struct HolderReaderCensusTests {

    private static let sessionA = UUID()
    private static let sessionB = UUID()

    // MARK: - The counter's resting state

    @Test func aFreshCensusIsReadingNothingAndHasSeenNothing() {
        let census = HolderReaderCensus()
        #expect(census.violations == 0)
        #expect(census.lastViolation == nil)
        #expect(census.sessionsBeingRead == 0)
        #expect(census.reader(of: Self.sessionA) == nil)
    }

    @Test func theFirstReaderOnASessionIsNotAViolation() {
        var census = HolderReaderCensus()
        let violation = census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        #expect(violation == nil)
        #expect(census.violations == 0)
        #expect(census.reader(of: Self.sessionA) == .daemon)
    }

    // MARK: - The transitions a violation is

    @Test func aSecondDaemonReaderOnOneSessionIsDetected() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        let violation = census.beganReading(.daemon, session: Self.sessionA, at: "publish")

        #expect(census.violations == 1, """
            a second drain loop went onto a pty that already had one and the census did not \
            see it, which is the byte theft this detector exists to report
            """)
        #expect(violation?.incumbent == .daemon)
        #expect(violation?.entering == .daemon)
        #expect(violation?.sessionID == Self.sessionA)
        #expect(census.lastViolation == violation)
    }

    /// The vend's own hazard: a descriptor handed to a viewer while the
    /// daemon's drain is still on it. This is what `beginAttach`'s quiesce
    /// exists to prevent, and what the census catches if the quiesce is ever
    /// skipped, reordered, or undone behind the vend's back.
    @Test func vendingToAViewerWhileTheDaemonIsStillReadingIsDetected() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        let violation = census.beganReading(
            .viewer(attach: 1), session: Self.sessionA, at: "attach-vend")

        #expect(census.violations == 1)
        #expect(violation?.incumbent == .daemon)
        #expect(violation?.entering == .viewer(attach: 1))
        #expect(violation?.site == "attach-vend")
    }

    /// A second live `dup` of a pty a viewer already holds — the one contested
    /// state the registry refuses rather than supersedes, because a descriptor
    /// in another process cannot be taken back.
    @Test func aSecondViewerDescriptorForOnePtyIsDetected() {
        var census = HolderReaderCensus()
        census.beganReading(.viewer(attach: 1), session: Self.sessionA, at: "attach-vend")
        let violation = census.beganReading(
            .viewer(attach: 2), session: Self.sessionA, at: "attach-vend")

        #expect(census.violations == 1)
        #expect(violation?.incumbent == .viewer(attach: 1))
        #expect(violation?.entering == .viewer(attach: 2))
    }

    /// The resume's hazard: the daemon going back onto a pty whose viewer was
    /// never established to be gone. Only a handback or an app-liveness verdict
    /// licenses that, and the census is what sees a resume that had neither.
    @Test func theDaemonResumingUnderALiveViewerIsDetected() {
        var census = HolderReaderCensus()
        census.beganReading(.viewer(attach: 7), session: Self.sessionA, at: "attach-vend")
        let violation = census.beganReading(
            .daemon, session: Self.sessionA, at: "handback-resume")

        #expect(census.violations == 1)
        #expect(violation?.incumbent == .viewer(attach: 7))
        #expect(violation?.site == "handback-resume")
    }

    @Test func violationsAreCountedPerTransitionRatherThanPerSession() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        census.beganReading(.viewer(attach: 1), session: Self.sessionA, at: "attach-vend")
        census.beganReading(.viewer(attach: 2), session: Self.sessionA, at: "attach-vend")

        #expect(census.violations == 2, """
            the count is the number of times a reader went onto an occupied pty, and a ledger \
            that froze on the first one would hide every later transition behind it
            """)
        // And the ledger keeps describing the newest claim rather than the
        // first disagreement.
        #expect(census.reader(of: Self.sessionA) == .viewer(attach: 2))
    }

    @Test func oneSessionsReaderDoesNotCountAgainstAnother() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        census.beganReading(.daemon, session: Self.sessionB, at: "publish")

        #expect(census.violations == 0, """
            the invariant is one reader per SESSION; a fleet of sessions the daemon drains \
            concurrently is the ordinary state, not a violation
            """)
        #expect(census.sessionsBeingRead == 2)
        #expect(census.sessionsReadByTheDaemon == 2)
    }

    // MARK: - The clean cycle

    /// The ordinary full cycle, with the counter untouched: the daemon drains,
    /// quiesces for an attach, the viewer reads, the viewer hands back, the
    /// daemon resumes. The same choreography against a real pty and a real
    /// `TBDHolder` is `HolderReaderCensusLiveTests`.
    @Test func theOrdinaryHandoffCycleCountsNoViolations() {
        var census = HolderReaderCensus()

        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        #expect(census.reader(of: Self.sessionA) == .daemon)

        census.stoppedReading(.daemon, session: Self.sessionA)
        #expect(census.reader(of: Self.sessionA) == nil, """
            a quiesced session is read by NOBODY, and that state is real rather than a \
            bookkeeping gap — it costs queued output and a job that cannot finish exiting
            """)

        census.beganReading(.viewer(attach: 1), session: Self.sessionA, at: "attach-vend")
        #expect(census.reader(of: Self.sessionA) == .viewer(attach: 1))
        #expect(census.sessionsReadByTheDaemon == 0)

        census.stoppedReading(.viewer(attach: 1), session: Self.sessionA)
        census.beganReading(.daemon, session: Self.sessionA, at: "handback-resume")

        #expect(census.reader(of: Self.sessionA) == .daemon)
        #expect(census.violations == 0, "a clean handoff left a violation behind")
        #expect(census.lastViolation == nil)
    }

    @Test func aReaderLeavingTwiceIsNotAViolation() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        census.stoppedReading(.daemon, session: Self.sessionA)
        census.stoppedReading(.daemon, session: Self.sessionA)

        #expect(census.violations == 0, """
            two readers LEAVING is one reader leaving twice, and the paths that stop a reader \
            are deliberately idempotent
            """)
        #expect(census.reader(of: Self.sessionA) == nil)
    }

    // MARK: - Departures are generation-checked

    /// A closing viewer's detach can arrive after a successor's attach owns the
    /// pty. Applying it would take the successor off the ledger and make the
    /// next transition into reading look clean when it is the second reader —
    /// so a departure that does not name the recorded reader is ignored.
    @Test func aStaleViewersDepartureLeavesItsSuccessorOnTheLedger() {
        var census = HolderReaderCensus()
        census.beganReading(.viewer(attach: 2), session: Self.sessionA, at: "attach-vend")

        census.stoppedReading(.viewer(attach: 1), session: Self.sessionA)

        #expect(census.reader(of: Self.sessionA) == .viewer(attach: 2), """
            a superseded attach's detach cleared the ledger entry of the attach that replaced it
            """)
        // And the proof that it matters: the daemon resuming now is caught,
        // which it would not be if the stale detach had been applied.
        census.beganReading(.daemon, session: Self.sessionA, at: "handback-resume")
        #expect(census.violations == 1)
    }

    @Test func aDepartureNamingTheWrongRoleLeavesTheIncumbentAlone() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")

        census.stoppedReading(.viewer(attach: 1), session: Self.sessionA)

        #expect(census.reader(of: Self.sessionA) == .daemon)
        census.beganReading(.viewer(attach: 1), session: Self.sessionA, at: "attach-vend")
        #expect(census.violations == 1)
    }

    // MARK: - Reading the count back

    @Test func forgettingASessionDropsItsReaderWithoutCounting() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")

        census.forget(session: Self.sessionA)

        #expect(census.reader(of: Self.sessionA) == nil)
        #expect(census.sessionsBeingRead == 0)
        #expect(census.violations == 0, "a teardown sweep is not a double-reader report")
    }

    /// The summary is the durable record — the count lives in daemon memory and
    /// signposts are a ring buffer, so a persisted log line is the only thing a
    /// human can read weeks after a soak. It must name the count even when the
    /// count is zero: a line that said nothing on a clean run would leave the
    /// question answerable only by an absence, which is the unaided observation
    /// this whole detector replaces.
    @Test func theSummaryNamesTheCountEvenWhenItIsZero() {
        let census = HolderReaderCensus()
        #expect(census.summary.contains("violations=0"))
        #expect(census.summary.contains("last-violation=none"))
    }

    @Test func theSummaryNamesTheCountAndTheLastViolation() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        census.beganReading(.viewer(attach: 4), session: Self.sessionA, at: "attach-vend")

        let summary = census.summary
        #expect(summary.contains("violations=1"))
        #expect(summary.contains(Self.sessionA.uuidString))
        #expect(summary.contains("incumbent=daemon"))
        #expect(summary.contains("entering=viewer-attach-4"))
        #expect(summary.contains("site=attach-vend"))
    }

    @Test func theSummaryCountsDaemonAndViewerReadersSeparately() {
        var census = HolderReaderCensus()
        census.beganReading(.daemon, session: Self.sessionA, at: "publish")
        census.beganReading(.viewer(attach: 1), session: Self.sessionB, at: "attach-vend")

        let summary = census.summary
        #expect(summary.contains("sessions-read=2"))
        #expect(summary.contains("daemon-read=1"))
        #expect(summary.contains("viewer-read=1"))
    }
}
