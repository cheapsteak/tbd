import Foundation
import TBDShared

/// What the composer offers for one terminal.
///
/// **Every input is a machine fact.** `kind`, `hibernatedAt`, `hibernateReason`
/// and `awaitingInputReason` are columns the daemon wrote from Claude Code's
/// hooks and the process table; the worktree's location is TBD's own record.
/// Nothing here reads rendered text, which this codebase forbids for state.
///
/// The order of the branches is the design: scope first (is there a composer at
/// all), then whether the process is running, then whether it is blocked. Not-
/// running outranks a standing prompt deliberately — a parked session cannot be
/// sitting on a dialog, and telling somebody to answer it in the terminal would
/// send them to a pane with a shell in it.
enum ComposerState: Equatable {
    /// No composer at all: the flag is off, the worktree is remote, or this is
    /// not a Claude session. Scope is Claude sessions on local worktrees; Codex,
    /// shell and remote are out, and the archived transcript view never gets one.
    case hidden
    /// Claude is working, idle, or in an informational state. A message sent
    /// mid-turn queues inside Claude Code, as it does when typed.
    case running
    /// The process is gone. Enabled, with a note that sending will resume the
    /// session and a send button that says so. `exited` distinguishes only the
    /// wording — a session that left on its own from one TBD parked.
    case notRunning(exited: Bool)
    /// A dialog is on screen, or an awaiting-input reason this build does not
    /// recognize. Disabled, showing the message the daemon carried and a Reveal
    /// Terminal action: answering in the terminal is the correct resolution,
    /// because a pasted body plus Enter would commit whichever option is
    /// highlighted.
    case blocked(message: String)

    var isEnabled: Bool {
        switch self {
        case .running, .notRunning: return true
        case .blocked, .hidden: return false
        }
    }

    static func resolve(
        terminal: Terminal?, isRemoteWorktree: Bool, composerEnabled: Bool
    ) -> ComposerState {
        guard composerEnabled, !isRemoteWorktree,
              let terminal, terminal.kind == .claude
        else { return .hidden }

        if terminal.hibernatedAt != nil {
            return .notRunning(exited: terminal.hibernateReason == .exited)
        }

        if let reason = terminal.awaitingInputReason {
            switch reason.classification {
            case .promptOnScreen, .unrecognized:
                return .blocked(message: reason.message)
            case .doneWaiting, .informational:
                return .running
            }
        }
        return .running
    }
}
