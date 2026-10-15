import Foundation
import TBDShared

/// What the composer in a remote session's transcript pane offers.
///
/// The remote counterpart of `ComposerState`, and ordered the same way: scope
/// first (is there a composer at all), then whether the session is running,
/// then whether it is blocked. Every input is a machine fact — the provider's
/// declared capabilities and the `state` /
/// `agent_state` the provider reported through `list` and `events`. Nothing
/// here reads rendered terminal text.
///
/// It fails closed: only a session the provider reports as `running` can get
/// an enabled composer. A `starting` session has no agent to read a message
/// yet, and an `unknown` state — which is also what a raw value this build
/// does not know decodes to — is not evidence of a running process.
///
/// Exited outranks blocked for the reason the local composer gives: a session
/// whose process is gone cannot be sitting on a prompt, and telling somebody
/// to answer it in the terminal would send them nowhere. Unlike the local
/// composer, an exited remote session stays disabled: there is no wake path
/// for a remote target (spec non-goal).
enum RemoteComposerState: Equatable {
    /// No composer: the provider does not declare `send-submit`, or the
    /// session is not in the mirror.
    case hidden
    /// The session is running and not blocked; submitting sends the message.
    case running
    /// The provider reports the session, or its agent, as exited.
    case exited
    /// The provider reports the session as `starting`.
    case starting
    /// The provider reports the session's state as `unknown`.
    case stateUnknown
    /// `agent_state` is `waiting_input`: the agent is blocked on a prompt, and
    /// a pasted body plus Enter would choose its highlighted option. The
    /// daemon refuses the send in this state too.
    case blocked

    var isEnabled: Bool {
        self == .running
    }

    /// The disabled-state note shown in place of a working composer.
    var disabledMessage: String? {
        disabledMessage(promptAnswerable: false)
    }

    /// The text shown in place of the terminal-only note when the pane has an
    /// open prompt card the person can answer from the transcript.
    static let promptAboveMessage = "Claude is waiting on a prompt above"

    func disabledMessage(promptAnswerable: Bool) -> String? {
        switch self {
        case .exited: return "Session has exited"
        case .starting: return "Session is starting"
        case .stateUnknown: return "Session state is unknown"
        case .blocked:
            return promptAnswerable
                ? Self.promptAboveMessage
                : "Waiting on a prompt — answer it in the terminal"
        case .hidden, .running: return nil
        }
    }

    /// The shared composer's state for this remote state. `MessageComposerView`
    /// renders one vocabulary for both kinds of target: a blocked remote
    /// session shows the blocked banner (without Reveal Terminal — the attached
    /// terminal is already beside it), and an exited one a disabled note, since
    /// there is no wake path to offer.
    var composerState: ComposerState {
        composerState(promptAnswerable: false)
    }

    func composerState(promptAnswerable: Bool) -> ComposerState {
        let message = disabledMessage(promptAnswerable: promptAnswerable) ?? ""
        switch self {
        case .hidden: return .hidden
        case .running: return .running
        case .blocked: return .blocked(message: message)
        case .exited, .starting, .stateUnknown:
            return .unavailable(message: message)
        }
    }

    static func resolve(
        capabilities: [String],
        session: RemoteSessionPayload?
    ) -> RemoteComposerState {
        guard RemoteSessionDetailGates.offersComposer(capabilities: capabilities),
            let session
        else { return .hidden }

        if session.state == .exited || session.agentState == .exited {
            return .exited
        }
        switch session.state {
        case .running: break
        case .starting: return .starting
        case .unknown: return .stateUnknown
        case .exited: return .exited
        }
        if session.agentState == .waitingInput {
            return .blocked
        }
        return .running
    }
}
