import Foundation

/// TBD's own refusals of a message to a remote session, for the state the
/// laptop mirrors for it: the session has exited, or its agent is waiting on
/// a prompt.
///
/// They live in `Base` because the router (`Server`) writes them and the
/// phone app service (`PhoneBridge`) tells them from a provider's own words:
/// a phone hears these as they are, and never a provider's text, which can
/// quote a secret.
enum RemoteSendMessageRefusal {
    /// The session has exited, or its provider stopped reporting it.
    static let exited = "session has exited; a message cannot be sent to it"

    /// The agent is waiting on a prompt that only the terminal can answer.
    static let waitingInput = "the agent is waiting on a prompt; answer it in the terminal"

    /// The agent is waiting on a prompt that its transcript card can answer.
    static let waitingInputAnswerOnCard =
        "the agent is waiting on a prompt; answer it on the card in the transcript"
}
