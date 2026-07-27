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

/// Tier 1. The child environment a provider `attach` is spawned with — the
/// other pure, injectable-seam half of `RemoteAttachTerminalView`. Same
/// shape as `TerminalViewerEnvironmentTests`, which covers the scrubbing
/// this composes on top of.
@Suite("RemoteAttachTerminalView.attachEnvironment")
struct RemoteAttachEnvironmentTests {
    /// The provider may itself exec tmux on the far side, and a nested-attach
    /// guard failure there is the same failure mode a nested LOCAL tmux
    /// attach hits — so the scrubbing `makeViewerEnvironment` does has to
    /// survive this wrapper.
    @Test func stripsTMUXAndTMUXPane() {
        let env = RemoteAttachTerminalView.attachEnvironment(base: [
            "TMUX": "/tmp/tmux-501/default",
            "TMUX_PANE": "%0",
            "PATH": "/usr/local/bin",
        ])
        #expect(env["TMUX"] == nil)
        #expect(env["TMUX_PANE"] == nil)
        #expect(env["PATH"] == "/usr/local/bin")
    }

    /// `docs/remote-provider-contract.md` normatively requires this on EVERY
    /// invocation. This is the only app-side spawn site, so without it a
    /// provider that branches on the contract version would see a different
    /// answer for `attach` than for every other verb.
    @Test func setsTheContractVersion() {
        #expect(RemoteAttachTerminalView.attachEnvironment(base: [:])["TBD_CONTRACT_VERSION"] == "1")
    }

    /// A provider that somehow inherited a different value must not win over
    /// the version this build actually speaks.
    @Test func overridesAnInheritedContractVersion() {
        let env = RemoteAttachTerminalView.attachEnvironment(base: ["TBD_CONTRACT_VERSION": "99"])
        #expect(env["TBD_CONTRACT_VERSION"] == "1")
    }
}
