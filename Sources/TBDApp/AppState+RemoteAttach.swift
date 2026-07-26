import Foundation
import TBDShared

/// Wiring between `RemoteAttachLifecycle`'s pure decision and live
/// `AppState` state — see that type's doc comment for the policy itself.
/// The direct mutators (`touchAttachedRemoteSession`,
/// `markRemoteSessionDetached`, `reattachRemoteSession`,
/// `clearRemoteSessionDetachedFlag`, `pruneRemoteAttachState`) live in
/// `AppState.swift` itself, next to the `private(set)` stored properties
/// they mutate (Swift's `private` access control is file-scoped, not
/// type-scoped) — this file only computes read-only inputs/outputs.
extension AppState {
    /// Sessions eligible for auto-attach right now: present in the daemon's
    /// mirror, not `gone`, not `dismissed`, and whose provider declares the
    /// `attach` capability. Reuses `RemoteSessionDetailGates.available` — the
    /// exact same gate that decides whether the Attach TAB even renders — so
    /// a provider without the capability, or a gone session, can never end up
    /// attach-eligible here while simultaneously having no Attach tab to
    /// show it in (the two must never disagree). The `dismissed` exclusion is
    /// separate: it mirrors `usableEntryIndex`'s navigation-staleness
    /// predicate (`AppState+Navigation.swift`), which excludes `dismissed`
    /// but keeps `gone`. Currently unreachable in practice — Dismiss is only
    /// offered on `gone` rows, and `gone` alone already blocks eligibility
    /// above — but kept explicit so the two predicates can't silently drift
    /// if Dismiss is ever offered on a live row.
    var attachEligibleRemoteSelections: Set<RemoteSessionSelection> {
        Set(remoteSessions.compactMap { session -> RemoteSessionSelection? in
            guard !session.dismissed else { return nil }
            let capabilities = remoteProviders.first { $0.config.name == session.provider }?.describe?.capabilities ?? []
            guard RemoteSessionDetailGates.available(capabilities: capabilities, gone: session.gone).contains(.attach) else {
                return nil
            }
            return RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
        })
    }

    /// The remote-session selections that should have a live attach
    /// terminal right now — what `RemoteAttachPager` mounts. Computed fresh
    /// on every read (like `keepAliveWorktreeIDs`), so it always reflects
    /// the current selection, mirror, and detach-flag state without needing
    /// an explicit recompute call anywhere.
    var attachedRemoteSelections: [RemoteSessionSelection] {
        RemoteAttachLifecycle.attachedSelections(
            selected: selectedRemoteSession,
            recentlyViewed: recentlyAttachedRemoteSessions,
            eligible: attachEligibleRemoteSelections,
            explicitlyDetached: Set(explicitlyDetachedRemoteSessions.keys),
            cap: remoteAttachKeepAliveLimit
        )
    }
}
