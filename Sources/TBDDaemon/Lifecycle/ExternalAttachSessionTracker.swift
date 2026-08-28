import Foundation

/// Since when each `tbd-ext-*` tmux session has been observed with no attached
/// client — the state behind the reconciler's grace period.
///
/// The map holds timestamps that are **compared**, so this takes a date seam
/// from its caller rather than a `Clock`: `Duration` is behavior, `Date` is
/// data. The caller passes `WorktreeLifecycle.now()`, which tests back with
/// `TestDateSource`.
///
/// An actor, for the same reason `ConflictSweepCache` is one: `WorktreeLifecycle`
/// is a struct that gets value-copied into every daemon path, and all of those
/// copies must share one set of observations. A per-copy map would restart the
/// grace period on every sweep, and nothing would ever be reclaimed.
actor ExternalAttachSessionTracker {
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

    private struct Key: Hashable {
        let server: String
        let session: String
    }

    private var firstSeenClientless: [Key: Date] = [:]

    /// Record one observation of a session and answer whether it has now been
    /// client-less for at least `gracePeriod`.
    ///
    /// A session observed **with** a client drops its recorded stamp, so a
    /// detach/reattach cycle cannot accumulate a stale deadline: the sweep
    /// after a reattach starts the clock over rather than reaping a session
    /// somebody is watching through.
    func shouldReap(
        server: String, session: String, attachedClients: Int, at date: Date
    ) -> Bool {
        let key = Key(server: server, session: session)
        guard attachedClients == 0 else {
            firstSeenClientless.removeValue(forKey: key)
            return false
        }
        guard let clientlessSince = firstSeenClientless[key] else {
            firstSeenClientless[key] = date
            return false
        }
        return date.timeIntervalSince(clientlessSince) >= Self.gracePeriod
    }

    /// Drop a session's observation once it is gone, so a later session minted
    /// under the same terminal-keyed name starts its own clock instead of
    /// inheriting an already-expired one.
    func forget(server: String, session: String) {
        firstSeenClientless.removeValue(forKey: Key(server: server, session: session))
    }
}
