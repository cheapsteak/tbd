import Foundation

/// Decides, from one tmux listing alone, what reconcile should do about a
/// `tbd-ext-*` external-attach session.
///
/// **The clientless clock lives on the session, not in the daemon.** An earlier
/// design kept an in-process map of "first seen client-less" stamps. That map
/// leaked entries for sessions that vanished any way other than by being
/// reaped, forgot everything across a daemon restart, and — because session
/// names are deterministic per terminal and carried no generation nonce — could
/// hand a brand-new session an already-expired deadline and reap it on its
/// first observation, inside the create-to-attach gap the grace period exists
/// to protect. Recording the stamp as a tmux *session* user option
/// (`@tbd_ext_clientless_since`) removes all three at once: the state dies with
/// the session it describes, survives a daemon restart, and a session recreated
/// under the same name starts with the option unset.
///
/// Two of tmux's own facts do the rest of the work, both measured against tmux
/// 3.6a:
///
/// - `#{session_created}` is epoch seconds and is always present.
/// - `#{session_last_attached}` is **empty for a session no client has ever
///   attached to**, and otherwise holds the epoch seconds of the last *attach*.
///   It is deliberately not used as the clientless clock: it does not move when
///   a client detaches, so a session attached for fifteen seconds and then
///   detached still reports the attach time — reaping off it would kill a
///   just-detached session with no grace at all. It answers exactly one
///   question reliably, and that is the one asked of it here: *has a client
///   attached since we stamped?*
///
/// A never-attached session therefore needs no stamp and no second sweep: tmux
/// already knows precisely how long it has been client-less, because it has
/// been client-less since it was created. That is the create-to-attach-gap
/// orphan — the session a failed or abandoned attach leaves behind — so the
/// case that actually leaks is reclaimed from a single observation.
enum ExternalAttachReclamation {

    /// How long a `tbd-ext-*` session must have been client-less before the
    /// reconciler kills it.
    ///
    /// The grace period is a measurement-integrity requirement, not a
    /// politeness. Reaping any client-less session immediately would take it
    /// during a momentary detach, or inside the gap between the `new-session
    /// -d` that mints it and the `attach` that follows — no work would be lost
    /// (the window is linked from `main` and survives), but the measurement
    /// run would be silently truncated and would still emit plausible-looking
    /// partial data. That is this investigation's signature failure mode. See
    /// `docs/specs/2026-08-27-external-tmux-attach-shortcut-design.md`,
    /// "Reclamation".
    static let gracePeriod: TimeInterval = 60

    /// What to do about one session, this sweep.
    enum Decision: Equatable {
        /// Client-less past the grace period: kill it (conditionally, so a
        /// client that arrives between the listing and the kill wins).
        case reap
        /// Client-less, but tmux cannot say since when. Record the stamp so the
        /// next sweep can, and leave the session alone.
        case stamp(Date)
        /// A client is attached and a stale stamp is still on the session.
        /// Clear it, so a later detach starts a fresh clock.
        case clearStamp
        /// Nothing to do.
        case leaveAlone
    }

    /// Decide from one observation. Pure, so every branch is unit-testable
    /// without a tmux server.
    ///
    /// - Parameters:
    ///   - session: one row of `TmuxManager.listSessions`.
    ///   - now: the injected date seam (`WorktreeLifecycle.now()`). These are
    ///     timestamps that get *compared*, so this takes a `Date`, not a
    ///     `Clock`.
    static func decide(session: TmuxSessionInfo, now: Date) -> Decision {
        guard session.attachedClients == 0 else {
            // Attached. Any stamp on it describes a clientless stretch that has
            // since ended, so drop it rather than let a later sweep measure
            // from it.
            return session.clientlessSince == nil ? .leaveAlone : .clearStamp
        }
        if let stamped = session.clientlessSince {
            // A stamp is only evidence while no client has attached since it
            // was written. `session_last_attached` is exactly that test: it
            // moves on attach, so a value at or after the stamp means somebody
            // used the session in between and the stamp is spent.
            let attachedSinceStamp = (session.lastAttached.map { $0 >= stamped }) ?? false
            if !attachedSinceStamp {
                return now.timeIntervalSince(stamped) >= gracePeriod ? .reap : .leaveAlone
            }
            return .stamp(now)
        }
        guard session.lastAttached != nil else {
            // Never attached, so it has been client-less since it was created —
            // a fact tmux already holds exactly. No stamp is written and no
            // second sweep is needed.
            return now.timeIntervalSince(session.created) >= gracePeriod ? .reap : .leaveAlone
        }
        // Attached at some point, detached at some unknown later moment. tmux
        // cannot date the detach, so this sweep starts the clock.
        return .stamp(now)
    }
}
