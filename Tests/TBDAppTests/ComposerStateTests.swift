import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The composer's four states, derived from `Terminal` columns and the
/// worktree's location — never from anything rendered.
///
/// The `hidden` cases are the scope statement: Claude sessions on local
/// worktrees, and nothing else.
@Suite("ComposerState")
struct ComposerStateTests {

    private func terminal(
        kind: TerminalKind? = .claude,
        hibernatedAt: Date? = nil,
        hibernateReason: HibernateReason? = nil,
        awaitingInput: AwaitingInputReason? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: kind, hibernatedAt: hibernatedAt, hibernateReason: hibernateReason,
            awaitingInputReason: awaitingInput,
            awaitingInputObservedAt: awaitingInput == nil ? nil : Date())
    }

    private func reason(_ type: String?, message: String = "Allow Bash(rm)?")
        -> AwaitingInputReason {
        AwaitingInputReason(
            message: message, hookEventName: "Notification", notificationType: type)
    }

    private func resolve(
        _ terminal: Terminal?, remote: Bool = false, enabled: Bool = true
    ) -> ComposerState {
        ComposerState.resolve(
            terminal: terminal, isRemoteWorktree: remote, composerEnabled: enabled)
    }

    // MARK: - Hidden

    /// The flag is the outermost gate: with it off the pane renders exactly as it
    /// did before.
    @Test func theFlagOffHidesIt() {
        #expect(resolve(terminal(), enabled: false) == .hidden)
    }

    @Test func codexAndShellTerminalsHaveNone() {
        #expect(resolve(terminal(kind: .codex)) == .hidden)
        #expect(resolve(terminal(kind: .shell)) == .hidden)
        #expect(resolve(terminal(kind: nil)) == .hidden)
    }

    @Test func aRemoteWorktreeHasNone() {
        #expect(resolve(terminal(), remote: true) == .hidden)
    }

    @Test func noTerminalAtAllHasNone() {
        #expect(resolve(nil) == .hidden)
    }

    // MARK: - Running

    @Test func aLiveClaudeSessionIsRunning() {
        #expect(resolve(terminal()) == .running)
    }

    /// Informational notifications and the idle prompt do not block: a subagent
    /// finishing is not a question, and the idle prompt is the agent waiting for
    /// exactly what the composer is about to send.
    @Test func informationalStatesStayRunning() {
        #expect(resolve(terminal(awaitingInput: reason("agent_completed"))) == .running)
        #expect(resolve(terminal(awaitingInput: reason("idle_prompt"))) == .running)
    }

    // MARK: - Not running

    @Test func aHibernatedSessionIsNotRunning() {
        #expect(resolve(terminal(
            hibernatedAt: Date(), hibernateReason: .manual)) == .notRunning(exited: false))
    }

    /// The exit stamp and a deliberate park are the same state with different
    /// wording on the button — one wake path, one UI.
    @Test func anExitedSessionIsNotRunningAndSaysSo() {
        #expect(resolve(terminal(
            hibernatedAt: Date(), hibernateReason: .exited)) == .notRunning(exited: true))
    }

    /// Not-running wins over a stale prompt: a parked session cannot be sitting
    /// on a dialog, and offering "answer it in the terminal" would send the
    /// person to a pane with a shell in it.
    @Test func notRunningOutranksAStandingPrompt() {
        #expect(resolve(terminal(
            hibernatedAt: Date(), hibernateReason: .exited,
            awaitingInput: reason("permission_prompt"))) == .notRunning(exited: true))
    }

    // MARK: - Blocked

    @Test func aPromptOnScreenBlocksAndCarriesItsMessage() {
        #expect(resolve(terminal(awaitingInput: reason("permission_prompt")))
            == .blocked(message: "Allow Bash(rm)?"))
    }

    /// An unrecognized reason blocks too, for the same reason the daemon's gate
    /// refuses on it: a newer Claude Code's new dialog type looks exactly like
    /// this to this build.
    @Test func anUnrecognizedReasonBlocks() {
        #expect(resolve(terminal(awaitingInput: reason("brand_new_dialog")))
            == .blocked(message: "Allow Bash(rm)?"))
        #expect(resolve(terminal(awaitingInput: reason(nil)))
            == .blocked(message: "Allow Bash(rm)?"))
    }

    // MARK: - Enablement

    @Test func onlyBlockedAndHiddenAreDisabled() {
        #expect(ComposerState.running.isEnabled)
        #expect(ComposerState.notRunning(exited: true).isEnabled)
        #expect(!ComposerState.blocked(message: "x").isEnabled)
        #expect(!ComposerState.hidden.isEnabled)
    }
}
