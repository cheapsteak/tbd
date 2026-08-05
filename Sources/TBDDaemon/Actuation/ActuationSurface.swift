import Foundation
import TBDShared

// MARK: - The actuation boundary
//
// A row exists for acts that touch a session's **process, pty, or lifecycle**.
//
//  - IN: spawning or disposing of a session, parking or waking one, and
//    sending payload into one — local (tmux) or remote (provider).
//  - OUT: DB-only settings *about* a session (`setKeepWarm`, `setPin`,
//    renames, config writes, worktree/notes/repo mutations). Nothing there
//    reaches a process, so nothing there is an actuation.
//  - Sub-steps of one actuation are NOT separate rows. The polite `/exit`,
//    the Escape/C-c and the SIGTERM inside a hibernate, the interrupt inside
//    a profile swap, the paste-then-Enter inside a send — one row per
//    actuation-level intent, at the moment the intent is acted on.
//    The auto-`/login` pump a login spawn arms (`armLoginSession`) is a
//    sub-step too, even though its `/login` paste lands seconds later: the
//    operator asked for one thing — a session logged into this profile — and
//    the typing is how the spawn finishes, not a second intent. When the
//    observed rung lands it will confirm that spawn's row, not open a new one.
//
// Two layers write, and only two: the **RPC handler** for anything a caller
// asked for, and a **rail's own entry point** for anything the daemon started
// by itself. The shared lifecycle internals in between — `captureThenKillWindow`,
// `killWindowAndReap`, `performHibernate`, `closeScratchTerminals` — stay
// silent, because both `worktree.archive` and the boot-time reconcile sweep
// reach them and a row down there would double-count every archive. Reconcile
// is an entry point in its own right (boot is what invoked it), so its rows are
// rail-level logging rather than shared-path logging.
//
// The two layers name different things, deliberately. A worktree-level RPC
// (`worktree.archive`, `worktree.forget`, `scratch.delete`) writes ONE row
// naming the worktree, with no terminal: the caller asked for one thing and the
// per-terminal kills are how the lifecycle carries it out. Reconcile writes one
// row PER act, because each kill or park it performs is an independent decision
// it made about a terminal it has already resolved.
//
// The wired set lives here, in one file next to the writer, so a reviewer can
// see it at a glance: `method` names the door a request came through and
// `kind` names the act, and both are spelled once, per surface.

/// The public RPC surfaces that actuate a session, and what each one is.
///
/// Two exhaustive switches rather than a dictionary: the compiler then proves
/// every wired surface has both a method name and a kind, and a handler cannot
/// silently drift onto the wrong one.
enum ActuationSurface: CaseIterable, Sendable {
    case terminalSend
    case terminalCreate
    case terminalDelete
    /// Tears down the worktree's sessions (capture, kill, reap) before the
    /// checkout goes away. One row per call naming the worktree — the
    /// per-terminal kills happen inside `WorktreeLifecycle`'s phase.
    case worktreeArchive
    /// Same teardown as archive, minus the disk removal: one row, worktree-named.
    case worktreeForget
    /// Spawns a fresh hook terminal. The terminal is minted inside the
    /// lifecycle, so the row names the worktree — as `worktree.revive` does.
    case worktreeRerunPreSession
    /// Kills the scratch space's windows, then trashes its folder.
    case scratchDelete
    /// The same teardown as `scratch.delete`, keeping the folder on disk.
    case scratchArchive
    case terminalHibernate
    case terminalWake
    /// Legacy shim, retained for old CLI/app builds; parks like `terminal.hibernate`.
    case terminalSuspend
    /// Legacy shim, retained for old CLI/app builds; wakes like `terminal.wake`.
    case terminalResume
    /// Fan-out shim: one row per terminal it parks, at that terminal's own act moment.
    case worktreeSuspend
    /// Fan-out shim: one row per terminal it wakes, at that terminal's own act moment.
    case worktreeResume
    case terminalRecreateWindow
    case terminalSwapProfile
    case terminalContinueInCodex
    case terminalHistoryRevive
    /// Creates a worktree and spawns its primary terminals. The row names the
    /// worktree, not a terminal: those are minted inside the lifecycle phase.
    case worktreeCreate
    /// Creates a scratch space and spawns its primary terminal — same shape as
    /// `worktreeCreate`, through the same lifecycle spawn.
    case scratchCreate
    case worktreeRevive
    case worktreeReviveConversationFresh
    case remoteCreate
    case remoteStop
    case remoteSend

    /// The exact public method name that carries this surface's requests.
    var method: String {
        switch self {
        case .terminalSend: return RPCMethod.terminalSend
        case .terminalCreate: return RPCMethod.terminalCreate
        case .terminalDelete: return RPCMethod.terminalDelete
        case .worktreeArchive: return RPCMethod.worktreeArchive
        case .worktreeForget: return RPCMethod.worktreeForget
        case .worktreeRerunPreSession: return RPCMethod.worktreeRerunPreSession
        case .scratchDelete: return RPCMethod.scratchDelete
        case .scratchArchive: return RPCMethod.scratchArchive
        case .terminalHibernate: return RPCMethod.terminalHibernate
        case .terminalWake: return RPCMethod.terminalWake
        case .terminalSuspend: return RPCMethod.terminalSuspend
        case .terminalResume: return RPCMethod.terminalResume
        case .worktreeSuspend: return RPCMethod.worktreeSuspend
        case .worktreeResume: return RPCMethod.worktreeResume
        case .terminalRecreateWindow: return RPCMethod.terminalRecreateWindow
        case .terminalSwapProfile: return RPCMethod.terminalSwapProfile
        case .terminalContinueInCodex: return RPCMethod.terminalContinueInCodex
        case .terminalHistoryRevive: return RPCMethod.terminalHistoryRevive
        case .worktreeCreate: return RPCMethod.worktreeCreate
        case .scratchCreate: return RPCMethod.scratchCreate
        case .worktreeRevive: return RPCMethod.worktreeRevive
        case .worktreeReviveConversationFresh: return RPCMethod.worktreeReviveConversationFresh
        case .remoteCreate: return RPCMethod.remoteCreate
        case .remoteStop: return RPCMethod.remoteStop
        case .remoteSend: return RPCMethod.remoteSend
        }
    }

    /// The act this surface performs. "Suspend" is not a kind — park and
    /// hibernate were unified, so the legacy suspend/resume surfaces map onto
    /// `hibernate`/`wake` while keeping their own `method`.
    var kind: ActuationKind {
        switch self {
        case .terminalSend, .remoteSend: return .send
        case .terminalCreate, .terminalRecreateWindow, .terminalSwapProfile,
             .terminalContinueInCodex, .terminalHistoryRevive, .worktreeCreate,
             .scratchCreate, .worktreeRevive, .worktreeReviveConversationFresh,
             .worktreeRerunPreSession, .remoteCreate: return .spawn
        case .terminalDelete, .worktreeArchive, .worktreeForget, .scratchDelete,
             .scratchArchive, .remoteStop: return .dispose
        case .terminalHibernate, .terminalSuspend, .worktreeSuspend: return .hibernate
        case .terminalWake, .terminalResume, .worktreeResume: return .wake
        }
    }
}

/// Daemon-internal actuation sites bypass the router entirely, so they carry
/// no `method`; they name the rail that acted instead.
enum ActuationRail {
    /// `LimitResumeActuator` typing its Escape/continue/Enter sequence.
    static let limitResume = "limit-resume"
    /// The idle sweep's trigger into `HibernationCoordinator`.
    static let autoHibernate = "auto-hibernate"
    /// `AutoHibernateOnMergeCoordinator` parking a worktree's sessions once its
    /// PR merged — a separate rail from the idle sweep, with its own switch.
    static let autoHibernateOnMerge = "auto-hibernate-on-merge"
    /// `AutoArchiveOnMergeCoordinator` archiving a whole worktree once its PR
    /// merged, tearing down its sessions with it.
    static let autoArchiveOnMerge = "auto-archive-on-merge"
    /// The Watch Desk's wrap-up and nudge pastes.
    static let nightwatchDesk = "nightwatch-desk"
    /// The boot-time (and post-`cleanup`) reconcile sweep: it kills the windows
    /// of worktrees that left disk, parks sessions whose window is gone, and
    /// reaps orphaned windows and dead servers. One row per act — each is an
    /// independent decision about a target the sweep has already resolved.
    static let reconcile = "reconcile"
}
