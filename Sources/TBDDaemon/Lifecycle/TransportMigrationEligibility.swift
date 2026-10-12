import Foundation
import TBDShared

/// Whether a session may be moved from the tmux transport to the pty holder.
///
/// Deliberately does NOT require a resumable Claude session, unlike the
/// profile swap and manual hibernate: a shell has no conversation to resume
/// and must still be migratable, or tmux rows would live forever.
///
/// A Codex tab is the one row that is turned away for having nothing to
/// resume, because the only move available to it would silently replace Codex
/// with a bare shell.
///
/// It also makes no judgement a later rail will make. The park's own rails
/// refuse typed input; repeating them here would give one question two answers.
enum TransportMigrationEligibility: Equatable {
    case eligible
    case alreadyHolder
    case skip(reason: String)

    /// The skip a Codex tab gets. Named so the CLI, the app's report and the
    /// tests all quote one wording.
    static let codexSkip = "A Codex session cannot be moved; close the tab and open a new one"

    static func decide(_ terminal: Terminal) -> TransportMigrationEligibility {
        if terminal.transport == .holder { return .alreadyHolder }
        // A Codex tab carries no resumable session and must not be recreated as
        // a bare shell, which would discard the Codex session in place. Moving
        // it properly needs Codex's own launch preparation, which this path does
        // not have. The predicate matches the one the recreate path uses, so one
        // question has one answer across the daemon.
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            return .skip(reason: codexSkip)
        }
        // Same wording as `HibernationCoordinator.manualBlockReason`, so a
        // person meets one vocabulary.
        switch terminal.activityState {
        case .working:
            return .skip(reason: "Session is actively running")
        case .waitingForUser:
            return .skip(reason: "Session is waiting on a permission prompt")
        default:
            return .eligible
        }
    }
}
