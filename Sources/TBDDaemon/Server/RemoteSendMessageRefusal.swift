import Foundation
import TBDShared

/// TBD's own refusals of a message to a remote session, for the state the
/// laptop mirrors for it: the session has exited, or its agent is waiting on
/// a prompt.
///
/// Each is TBD's fixed words with its code (`CodedRefusal`), so a client may
/// show it: a paired phone hears it as it is.
enum RemoteSendMessageRefusal {
    /// The session has exited, or its provider stopped reporting it.
    static let exited = CodedRefusal(
        text: "session has exited; a message cannot be sent to it", code: .remoteSessionExited)

    /// The agent is waiting on a prompt that only the terminal can answer.
    static let waitingInput = CodedRefusal(
        text: "the agent is waiting on a prompt; answer it in the terminal", code: .remoteSessionWaitingInput)

    /// The agent is waiting on a prompt that its transcript card can answer.
    static let waitingInputAnswerOnCard = CodedRefusal(
        text: "the agent is waiting on a prompt; answer it on the card in the transcript",
        code: .remoteSessionWaitingInput)
}
