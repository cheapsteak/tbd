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
             .terminalContinueInCodex, .terminalHistoryRevive, .worktreeRevive,
             .worktreeReviveConversationFresh, .remoteCreate: return .spawn
        case .terminalDelete, .remoteStop: return .dispose
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
    /// The Watch Desk's wrap-up and nudge pastes.
    static let nightwatchDesk = "nightwatch-desk"
}
