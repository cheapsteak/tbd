import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The remote-transcript gates in `RemoteSessionDetailGates` and the remote
/// composer's state. Each gate is tested on both branches, per repo policy for
/// behavior-gating conditionals: the capability present and absent.
@Suite("Remote transcript — pure gates and composer state")
struct RemoteTranscriptGatesTests {
    // MARK: - showsTranscriptToggle(capabilities:)

    @Test func toggleShownWithTranscriptRead() {
        #expect(RemoteSessionDetailGates.showsTranscriptToggle(
            capabilities: ["attach", "transcript.read"]))
    }

    @Test func toggleHiddenWithoutTranscriptRead() {
        #expect(!RemoteSessionDetailGates.showsTranscriptToggle(capabilities: []))
        // The pre-namespace spelling and the sibling transcript capabilities
        // are not `transcript.read`.
        #expect(!RemoteSessionDetailGates.showsTranscriptToggle(
            capabilities: ["transcript", "transcript.retain", "transcript.recall"]))
    }

    // MARK: - showsTranscriptPane(capabilities:open:)

    @Test func paneShownWhenToggleOfferedAndOpen() {
        #expect(RemoteSessionDetailGates.showsTranscriptPane(
            capabilities: ["transcript.read"], open: true))
    }

    @Test func paneHiddenWhenClosed() {
        #expect(!RemoteSessionDetailGates.showsTranscriptPane(
            capabilities: ["transcript.read"], open: false))
    }

    @Test func paneHiddenWithoutTranscriptReadEvenIfOpen() {
        #expect(!RemoteSessionDetailGates.showsTranscriptPane(
            capabilities: ["attach"], open: true))
    }

    // MARK: - offersComposer

    @Test func composerOfferedWithSendSubmit() {
        #expect(RemoteSessionDetailGates.offersComposer(capabilities: ["send-submit"]))
    }

    @Test func composerNotOfferedWithoutSendSubmit() {
        // Raw `send` is keystrokes, not a submitted message.
        #expect(!RemoteSessionDetailGates.offersComposer(
            capabilities: ["send", "transcript.read"]))
    }

    // MARK: - RemoteComposerState.resolve

    private func session(
        state: RemoteProcessState = .running, agentState: RemoteAgentState = .working
    ) -> RemoteSessionPayload {
        RemoteSessionPayload(id: "s1", state: state, agentState: agentState)
    }

    private func resolve(
        capabilities: [String] = ["send-submit"],
        session: RemoteSessionPayload?
    ) -> RemoteComposerState {
        RemoteComposerState.resolve(capabilities: capabilities, session: session)
    }

    @Test func composerRunningForAWorkingOrIdleSession() {
        #expect(resolve(session: session(agentState: .working)) == .running)
        #expect(resolve(session: session(agentState: .idle)) == .running)
        #expect(resolve(session: session(agentState: .unknown)) == .running)
        #expect(resolve(session: session(agentState: .working)).isEnabled)
    }

    /// Fail closed: only a session the provider reports as `running` gets an
    /// enabled composer. `starting` has no agent to read the message yet, and
    /// `unknown` (including a raw value this build does not know) is not
    /// evidence of a running process.
    @Test func composerDisabledUntilTheSessionReportsRunning() {
        #expect(resolve(session: session(state: .starting)) == .starting)
        #expect(resolve(session: session(state: .unknown)) == .stateUnknown)
        #expect(!RemoteComposerState.starting.isEnabled)
        #expect(!RemoteComposerState.stateUnknown.isEnabled)
        #expect(RemoteComposerState.starting.disabledMessage == "Session is starting")
        #expect(RemoteComposerState.stateUnknown.disabledMessage
                == "Session state is unknown")
        // Exited and blocked keep their precedence over the fail-closed cases
        // only where they apply: an exited agent in a starting session is exited.
        #expect(resolve(session: session(state: .starting, agentState: .exited)) == .exited)
        #expect(resolve(session: session(state: .unknown, agentState: .waitingInput))
                == .stateUnknown)
    }

    @Test func composerHiddenWithoutSendSubmit() {
        #expect(resolve(capabilities: ["send"], session: session()) == .hidden)
    }

    @Test func composerHiddenForASessionNotInTheMirror() {
        #expect(resolve(session: nil) == .hidden)
    }

    @Test func composerExitedWhenTheProcessOrAgentHasExited() {
        #expect(resolve(session: session(state: .exited, agentState: .unknown)) == .exited)
        #expect(resolve(session: session(state: .running, agentState: .exited)) == .exited)
        #expect(!RemoteComposerState.exited.isEnabled)
        #expect(RemoteComposerState.exited.disabledMessage == "Session has exited")
    }

    @Test func composerBlockedWhileWaitingOnInput() {
        #expect(resolve(session: session(agentState: .waitingInput)) == .blocked)
        #expect(!RemoteComposerState.blocked.isEnabled)
        #expect(RemoteComposerState.blocked.disabledMessage
            == "Waiting on a prompt — answer it in the terminal")
    }

    @Test func exitedOutranksBlocked() {
        #expect(resolve(session: session(state: .exited, agentState: .waitingInput)) == .exited)
    }

    @Test func hiddenAndRunningCarryNoDisabledMessage() {
        #expect(RemoteComposerState.hidden.disabledMessage == nil)
        #expect(RemoteComposerState.running.disabledMessage == nil)
        #expect(!RemoteComposerState.hidden.isEnabled)
    }
}
