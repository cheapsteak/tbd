import Foundation
import TBDShared

/// Whether a session may be moved from the tmux transport to the pty holder.
///
/// Deliberately does NOT require a resumable Claude session, unlike the
/// profile swap and manual hibernate: a shell has no conversation to resume
/// and must still be migratable, or tmux rows would live forever.
///
/// Three rows are turned away for having nothing to resume, because the only
/// move available to each of them would start a bare login shell where
/// something else belongs: a Codex tab, a Claude tab whose session has not
/// begun, and a pre-session hook tab. Each gets its own reason, because each
/// has a different thing for the person to do about it.
///
/// It also makes no judgement a later rail will make. The park's own rails
/// refuse typed input; repeating them here would give one question two answers.
/// And it judges only what the ROW says: a shell's busy-ness lives in the
/// process table, which this cannot read, so the coordinator's own rail asks
/// that question (`HibernationCoordinator.moveRunningShellToHolder`).
enum TransportMigrationEligibility: Equatable {
    case eligible
    case alreadyHolder
    case skip(reason: String)

    /// The skip a Codex tab gets. Named so the CLI, the app's report and the
    /// tests all quote one wording. The other two below are named for the same
    /// reason.
    static let codexSkip = "A Codex session cannot be moved; close the tab and open a new one"

    /// The skip a Claude tab with no conversation yet gets.
    static let claudeWithoutConversationSkip =
        "This Claude session has not started a conversation yet, so there is nothing to resume; "
        + "close the tab and open a new one, which starts on the pty holder."

    /// The skip a pre-session hook tab gets.
    static let preSessionSkip =
        "TBD created this tab to run the worktree's pre-session hook; it closes itself when the "
        + "hook finishes, so there is nothing to move."

    static func decide(_ terminal: Terminal) -> TransportMigrationEligibility {
        if terminal.transport == .holder { return .alreadyHolder }
        // A pre-session hook tab is a shell with no session id, so without this
        // it is eligible — and a fleet run during a worktree creation would kill
        // the hook mid-run, which `waitForPreSessionCompletion` reports as
        // `.paneKilled` and the person meets as a hook failure with the hook's
        // work lost.
        //
        // Unconditional, deliberately. The tab is transient, so skipping it
        // costs nothing even once the hook has finished, and a row-only view
        // cannot see whether the creation flow is still waiting on it.
        if terminal.label == TerminalLabel.preSession {
            return .skip(reason: preSessionSkip)
        }
        // A Codex tab carries no resumable session and must not be recreated as
        // a bare shell, which would discard the Codex session in place. Moving
        // it properly needs Codex's own launch preparation, which this path does
        // not have. The predicate matches the one the recreate path uses, so one
        // question has one answer across the daemon.
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            return .skip(reason: codexSkip)
        }
        // A Claude tab whose agent is still starting up, or whose session hook
        // never fired, names no conversation either — and that happens in the
        // field. Without this it would reach the running-shell move and have a
        // live agent killed and replaced by a bare login shell in a tab still
        // reading Claude. The shell move is for shells, and this is the line
        // that keeps it so.
        //
        // A nil `kind` reads as a shell, the same `(kind ?? .shell)` idiom the
        // rest of the daemon uses for a row written before kinds existed.
        if terminal.claudeSessionID == nil, (terminal.kind ?? .shell) == .claude {
            return .skip(reason: claudeWithoutConversationSkip)
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
