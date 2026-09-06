import Foundation
import TBDShared

/// Whether an opted-in send may proceed against a session's standing
/// awaiting-input reason.
///
/// A pasted body plus Enter into a permission dialog commits whichever option is
/// highlighted, which is a destructive act nobody asked for. So the gate fails
/// toward refusing, and an unrecognized reason is treated as a dialog — because
/// that is exactly what a newer Claude Code's new dialog type looks like to this
/// build, and a gate that allowed unknowns would silently stop working the day a
/// dialog is added.
///
/// Informational reasons and the idle prompt are allowed: the first says nobody
/// is being waited on, and the second is the agent waiting for its next
/// instruction, which is the state the composer exists to answer.
///
/// **Pure.** The supersession question — has the session's own transcript shown
/// it moved on since the prompt was recorded — is answered by
/// `AwaitingInputSupersession`, the mechanism `terminal.list` already applies,
/// and handed in as a Bool. Reimplementing it here would give TBD two answers to
/// one question.
enum AwaitingInputSendGate {
    enum Decision: Equatable, Sendable {
        case allow
        case refuse(message: String)
    }

    static func decide(reason: AwaitingInputReason?, superseded: Bool) -> Decision {
        guard let reason else { return .allow }
        guard !superseded else { return .allow }
        switch reason.classification {
        case .promptOnScreen, .unrecognized:
            return .refuse(message: refusalMessage(reason))
        case .doneWaiting, .informational:
            return .allow
        }
    }

    /// The refusal a human reads. It carries the notification message verbatim,
    /// because that message is the question being asked, and answering it in the
    /// terminal is the correct resolution.
    ///
    /// TBD never *branches* on this text — that would be screen-scraping with an
    /// extra hop — it only carries it.
    static func refusalMessage(_ reason: AwaitingInputReason) -> String {
        let kind = reason.classification == .unrecognized
            ? "an awaiting-input state this build does not recognize"
            : "a prompt on screen"
        let quoted = reason.message.isEmpty ? "" : " — \"\(reason.message)\""
        return "terminal.send was refused: the session has \(kind)\(quoted). Nothing was typed; "
            + "a pasted message plus Enter would commit whichever option is highlighted. "
            + "Answer it in the terminal."
    }
}
