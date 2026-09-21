import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The one decision three callers share: whether a holder session's typed
/// screen is something this daemon may judge.
///
/// Tier 1 — a pure function of two facts, and the reason it is tested here
/// rather than only through its callers is that the callers cannot see each
/// other. The park, the idle sweep and the auto-`/login` pump each dress the
/// answer in their own words; if the answer itself drifted, every one of them
/// would keep passing its own tests while disagreeing with the others.
@Suite("Holder screen evidence")
struct HolderScreenEvidenceTests {

    /// Somebody else is at the pty — either the daemon's emulator is frozen at
    /// the attach, or the viewer answered the pull itself. Both refuse, and
    /// `contentObserved` cannot buy either of them out of it.
    @Test("a screen somebody else holds the pty for is refused, observed or not")
    func aViewerHeldScreenIsRefused() {
        for source in [TerminalScreen.Source.staleDaemon, .viewer] {
            for observed in [true, false] {
                #expect(
                    HolderScreenEvidence.refusal(forSource: source, contentObserved: observed)
                        == .viewerHoldsPty,
                    "a \(source.rawValue) screen (contentObserved: \(observed)) was not refused")
            }
        }
    }

    /// The daemon is rendering live, but its emulator was built over a child
    /// that was already running, so the cells nobody has repainted since are
    /// this grid's invention rather than the child's text.
    @Test("a live screen that never watched its child paint is refused")
    func anUnobservedDaemonScreenIsRefused() {
        #expect(
            HolderScreenEvidence.refusal(forSource: .daemon, contentObserved: false)
                == .contentUnobserved)
    }

    /// The one screen anybody may judge: the daemon is the live store and its
    /// emulator watched this child from the start.
    @Test("a live, fully observed daemon screen is judgeable")
    func aLiveObservedDaemonScreenIsJudgeable() {
        #expect(HolderScreenEvidence.refusal(forSource: .daemon, contentObserved: true) == nil)
    }
}
