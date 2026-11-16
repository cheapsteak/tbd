import Foundation
import TBDShared

/// Whether a session may be moved from the tmux transport to the pty holder.
///
/// Deliberately does NOT require a resumable Claude session, unlike the
/// profile swap and manual hibernate: a shell has no conversation to resume
/// and must still be migratable, or tmux rows would live forever.
///
/// Four rows are turned away for having nothing to resume, because the only
/// move available to each of them would start a bare login shell where
/// something else belongs: a Codex tab with no thread, a Claude tab whose
/// session has not begun, and a hook tab of either kind — `pre-session` or
/// `setup`. Each gets its own reason, because each has a different thing for
/// the person to do about it. A Codex tab that names a thread is not among
/// them: its thread is resumed on the holder.
///
/// It judges only what the ROW says. Whether a live row's tmux server is
/// still running is the migrator's question, asked before this one
/// (`TerminalTransportMigrator`).
enum TransportMigrationEligibility: Equatable {
    case eligible
    case alreadyHolder
    case skip(reason: String)

    /// The skip a Codex tab with no thread gets. Named so the CLI, the app's
    /// report and the tests all quote one wording. The others below are named
    /// for the same reason.
    static let codexSkip =
        "This Codex tab names no thread to resume, so nothing can be moved; close the tab and "
        + "open a new one, which starts on the pty holder."

    /// The skip a Claude tab with no conversation yet gets.
    static let claudeWithoutConversationSkip =
        "This Claude session has not started a conversation yet, so there is nothing to resume; "
        + "close the tab and open a new one, which starts on the pty holder."

    /// The skip a pre-session hook tab gets.
    static let preSessionSkip =
        "TBD created this tab to run the worktree's pre-session hook; it closes itself when the "
        + "hook finishes, so there is nothing to move."

    /// The skip a setup hook tab gets.
    static let setupSkip =
        "TBD created this tab to run the worktree's setup hook; close the tab when you are done "
        + "reading it, so there is nothing to move."

    static func decide(_ terminal: Terminal) -> TransportMigrationEligibility {
        if terminal.transport == .holder { return .alreadyHolder }
        if let reason = nothingToResumeSkip(terminal) {
            return .skip(reason: reason)
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

    /// The skip `decide` gives a row it turns away for having nothing to
    /// resume — a hook tab, a Codex tab with no thread, a Claude tab with no
    /// conversation — or nil for any other row.
    ///
    /// Each of those reasons tells the person what to do instead of migrating,
    /// because no run of the migration will ever move the row. The busy skips
    /// in `decide` are not among them: they clear when the turn ends.
    ///
    /// Judges the row whatever its transport; `decide` asks the transport
    /// first.
    static func nothingToResumeSkip(_ terminal: Terminal) -> String? {
        // A pre-session hook tab is a shell with no session id, so without this
        // it would be moved as a shell while the creation flow may still be
        // waiting on its hook.
        //
        // Unconditional, deliberately. The tab is transient, so skipping it
        // costs nothing even once the hook has finished, and a row-only view
        // cannot see whether the creation flow is still waiting on it.
        if terminal.label == TerminalLabel.preSession {
            return preSessionSkip
        }
        // A `setup` hook tab exists to show its hook's output, and a fresh
        // shell in its place would show nothing of it.
        //
        // Unconditional, like the pre-session skip, and for a cheaper reason:
        // the tab is TBD-created and closing it is what one does with it, so
        // skipping it costs nothing. `finishAutoCloseSetup` is a live observer
        // whenever `auto_close_setup_enabled` is on, which the row alone cannot
        // see either.
        if terminal.label == TerminalLabel.setup {
            return setupSkip
        }
        // A Codex tab moves exactly when it names a Codex thread to resume,
        // the same plan the wake reads (`Terminal.recoveryResumePlan`): the
        // rewrite keeps the thread id and the recorded launch options, from
        // which the holder wake does Codex's own resume preparation. One with
        // no thread has nothing to resume, and the shell move would replace it
        // with a bare login shell in place.
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            guard terminal.recoveryResumePlan?.identity.agentKind == .codex else {
                return codexSkip
            }
        }
        // A Claude tab whose session hook never fired names no conversation
        // either — and that happens in the field. Without this it would reach
        // the shell move and become a bare login shell in a tab still reading
        // Claude. The shell move is for shells, and this is the line that
        // keeps it so.
        //
        // A nil `kind` reads as a shell, the same `(kind ?? .shell)` idiom the
        // rest of the daemon uses for a row written before kinds existed.
        if terminal.claudeSessionID == nil, (terminal.kind ?? .shell) == .claude {
            return claudeWithoutConversationSkip
        }
        return nil
    }
}
