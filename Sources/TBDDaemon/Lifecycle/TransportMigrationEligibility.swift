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
/// something else belongs: a running Codex tab, a Claude tab whose session has
/// not begun, and a hook tab of either kind — `pre-session` or `setup`. Each
/// gets its own reason, because each has a different thing for the person to
/// do about it. A PARKED Codex tab is not among them: it is only rewritten,
/// and its next wake resumes the Codex thread on the holder.
///
/// It also makes no judgement a later rail will make. The park's own rails
/// decide — a turn in flight, a permission prompt, a transcript mid-write;
/// repeating them here would give one question two answers.
/// And it judges only what the ROW says: a shell's busy-ness lives in the
/// process table, which this cannot read, so the coordinator's own rail asks
/// that question (`HibernationCoordinator.moveRunningShellToHolder`).
enum TransportMigrationEligibility: Equatable {
    case eligible
    case alreadyHolder
    case skip(reason: String)

    /// The skip a RUNNING Codex tab gets. Named so the CLI, the app's report
    /// and the tests all quote one wording. The others below are named for the
    /// same reason.
    ///
    /// It tells the person to close the tab rather than to hibernate it first,
    /// because nothing parks a running Codex tab: a manual hibernate is
    /// Claude-only (`HibernationCoordinator.parkRefusal`), and the only parks
    /// that take a Codex row are the ones for a tab whose window has already
    /// gone — startup recovery's and a window recreate's.
    static let codexSkip =
        "A running Codex session cannot be moved; close the tab and open a new one, "
        + "which starts on the pty holder."

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
    /// resume — a hook tab, a running Codex tab, a Claude tab with no
    /// conversation — or nil for any other row.
    ///
    /// Each of those reasons tells the person what to do instead of migrating,
    /// because no run of the migration will ever move the row. So another
    /// refusal that would otherwise name `tbd terminal migrate` asks this
    /// first, and names no migration for these rows: a window recreate
    /// (`RPCRouter.tmuxRecreateRefusal(for:)`). That refusal words its own
    /// advice, because these reasons describe a row whose window is alive.
    /// The busy skips in `decide` are not among them: they clear when the
    /// turn ends.
    ///
    /// Judges the row whatever its transport; `decide` asks the transport
    /// first.
    static func nothingToResumeSkip(_ terminal: Terminal) -> String? {
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
            return preSessionSkip
        }
        // A `setup` hook tab is skipped for a reason the process-table busy
        // rail cannot see. A setup hook that FAILED has `exec $SHELL`'d, so the
        // tab somebody deliberately kept open to read the failure holds an idle
        // shell: the rail finds nothing running, the row is eligible, and the
        // move kills its window with no Closed Terminals capture — destroying
        // exactly the output the tab exists to show.
        //
        // Unconditional, like the pre-session skip, and for a cheaper reason:
        // the tab is TBD-created and closing it is what one does with it, so
        // skipping it costs nothing. `finishAutoCloseSetup` is a live observer
        // whenever `auto_close_setup_enabled` is on, which the row alone cannot
        // see either.
        if terminal.label == TerminalLabel.setup {
            return setupSkip
        }
        // A RUNNING Codex tab cannot be moved. The park is Claude-only, so the
        // only move left for it is the running-shell one, which would replace
        // the Codex session with a bare login shell in place.
        //
        // A PARKED Codex tab can, and must be able to: startup reconcile parks
        // a Codex row whose window died, and the wake refuses every row parked
        // on tmux, so without this the session could never come back. Nothing
        // is launched during the move — a parked row is only rewritten — and
        // the rewrite keeps the thread id and the recorded launch options, from
        // which the holder wake does Codex's own resume preparation. So it is
        // eligible exactly when the row names a Codex thread to resume, the
        // same plan the wake reads (`Terminal.recoveryResumePlan`).
        if terminal.kind == .codex || terminal.label == TerminalLabel.codex {
            let parkedWithAThread = terminal.isParked
                && terminal.recoveryResumePlan?.identity.agentKind == .codex
            guard parkedWithAThread else {
                return codexSkip
            }
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
            return claudeWithoutConversationSkip
        }
        return nil
    }
}
