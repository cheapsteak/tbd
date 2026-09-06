import Foundation
import Testing
@testable import TBDShared

/// Which `SessionEnd` reasons mean the Claude PROCESS is going away.
///
/// A `/clear` ends one session and starts another inside the same live process,
/// so parking on it would refuse every send to a perfectly healthy session.
/// The unknown case fails toward NOT parking for the same asymmetry the whole
/// design uses: a missed stamp costs one bad paste that the foreground-process
/// rail still catches, while a wrong stamp refuses a live session's sends.
@Suite("SessionEndReason")
struct SessionEndReasonTests {

    @Test func reasonsThatMeanTheProcessIsLeaving() {
        #expect(SessionEndReason.parksTheTerminal("logout"))
        #expect(SessionEndReason.parksTheTerminal("exit"))
        #expect(SessionEndReason.parksTheTerminal("prompt_input_exit"))
        #expect(SessionEndReason.parksTheTerminal("other"))
    }

    @Test func clearAndCompactStayInTheSameProcess() {
        #expect(!SessionEndReason.parksTheTerminal("clear"))
        #expect(!SessionEndReason.parksTheTerminal("compact"))
        #expect(!SessionEndReason.parksTheTerminal("resume"))
    }

    /// No reason at all is an older Claude Code, or a hook payload this build
    /// could not read. Both are "we do not know", and not-knowing must not park.
    @Test func anAbsentOrUnknownReasonDoesNotPark() {
        #expect(!SessionEndReason.parksTheTerminal(nil))
        #expect(!SessionEndReason.parksTheTerminal(""))
        #expect(!SessionEndReason.parksTheTerminal("teleported"))
    }

    @Test func matchingIsCaseInsensitiveAndTrimmed() {
        #expect(SessionEndReason.parksTheTerminal("  Logout \n"))
        #expect(!SessionEndReason.parksTheTerminal("  CLEAR "))
    }
}
