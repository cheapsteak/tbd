import Testing
@testable import TBDApp

/// Fix pass 1 (task-10 review finding 5): the one pure decision behind the
/// "Detached" vs. "Attach ended unexpectedly" overlay framing — everything
/// else in `RemoteAttachTerminalView` is AppKit/PTY wiring outside this
/// codebase's unit-test harness (see task-10-report.md's "what I deliberately
/// did not unit-test" section), but this one classification is pure and
/// worth pinning directly.
@Suite("RemoteAttachTerminalView.isUnexpectedExit")
struct RemoteAttachTerminalViewTests {
    @Test func cleanExitIsNotUnexpected() {
        #expect(RemoteAttachTerminalView.isUnexpectedExit(exitCode: 0) == false)
    }

    @Test func nonZeroExitIsUnexpected() {
        #expect(RemoteAttachTerminalView.isUnexpectedExit(exitCode: 1) == true)
        #expect(RemoteAttachTerminalView.isUnexpectedExit(exitCode: 137) == true)
    }

    /// An auth-class exit is its OWN thing, not an unexpected session exit:
    /// framing "the provider's credentials expired" as a surprise crash
    /// sends the user to Reattach, which cannot work. It gets the auth CTA
    /// instead (`RemoteProviderAuthPresentation`).
    @Test func authClassExitIsNotFramedAsUnexpected() {
        #expect(RemoteAttachTerminalView.isUnexpectedExit(exitCode: 4) == false)
        #expect(RemoteAttachExitClass.classify(exitCode: 4) == .authNeeded)
    }

    @Test func unreadableExitCodeIsNotTreatedAsUnexpected() {
        // No exit code available isn't proof of failure — stays in the
        // non-alarming "Detached" framing rather than guessing.
        #expect(RemoteAttachTerminalView.isUnexpectedExit(exitCode: nil) == false)
    }
}
