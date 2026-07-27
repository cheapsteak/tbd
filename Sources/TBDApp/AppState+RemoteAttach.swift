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

    /// Pending-reconnect selections that are STILL blocked as of `now` —
    /// `RemoteReconnectPolicy.isBlocked` evaluated against each entry's
    /// provider's CURRENT health. A selection falls out of this set — and
    /// thus becomes attachable again — once its provider's health
    /// republishes as `.ok` at or after this entry's backoff window. In
    /// production this is always driven by the app's existing provider
    /// poll/publish cycle (`refreshRemote()`, ~60s or push `events`), never
    /// a dedicated timer: every time `remoteProviders` republishes, SwiftUI
    /// re-evaluates whatever reads `attachedRemoteSelections`, which
    /// recomputes this set against the current wall clock. A selection
    /// whose provider is no longer in `remoteProviders` at all is treated as
    /// unhealthy (`.error`) rather than silently un-blocking — an
    /// unregistered/vanished provider is never a "recovered" one.
    ///
    /// Takes `now` explicitly (rather than reading `Date()` internally) so
    /// tests can assert the exact instant backoff elapses without a real
    /// wall-clock sleep — see `attachedRemoteSelections(now:)`.
    func pendingReconnectBlockedSelections(now: Date) -> Set<RemoteSessionSelection> {
        Set(pendingReconnectRemoteSessions.compactMap { selection, pending -> RemoteSessionSelection? in
            let health = remoteProviders.first { $0.config.name == selection.provider }?.health ?? .error
            return RemoteReconnectPolicy.isBlocked(pending, providerHealth: health, now: now) ? selection : nil
        })
    }

    /// `pendingReconnectBlockedSelections(now:)` evaluated at the current
    /// wall clock — what production code (`attachedRemoteSelections`) uses.
    var pendingReconnectBlockedSelections: Set<RemoteSessionSelection> {
        pendingReconnectBlockedSelections(now: Date())
    }

    /// The remote-session selections that should have a live attach
    /// terminal at `now` — the testable core of `attachedRemoteSelections`.
    /// Reflects the current selection, mirror, detach-flag, and
    /// reconnect-backoff state for the given instant.
    func attachedRemoteSelections(now: Date) -> [RemoteSessionSelection] {
        RemoteAttachLifecycle.attachedSelections(
            selected: selectedRemoteSession,
            recentlyViewed: recentlyAttachedRemoteSessions,
            eligible: attachEligibleRemoteSelections,
            explicitlyDetached: Set(explicitlyDetachedRemoteSessions.keys),
            pendingReconnect: pendingReconnectBlockedSelections(now: now),
            cap: remoteAttachKeepAliveLimit
        )
    }

    /// The remote-session selections that should have a live attach
    /// terminal right now — what `RemoteAttachPager` mounts. Computed fresh
    /// on every read (like `keepAliveWorktreeIDs`), so it always reflects
    /// the current selection, mirror, detach-flag, and reconnect-backoff
    /// state without needing an explicit recompute call anywhere.
    var attachedRemoteSelections: [RemoteSessionSelection] {
        attachedRemoteSelections(now: Date())
    }

    /// Which selection the persistently-mounted remote-session detail host
    /// (`DetailSectionHostPager`'s `.remote` tab, via `RemoteSessionHostSlot`)
    /// should currently render its chrome for: the active selection when
    /// one exists, otherwise the most-recently-viewed remote session — so
    /// the host still has SOME concrete session to describe while the user
    /// is elsewhere (`RemoteSessionDetailView.selection` is non-optional,
    /// and the host stays mounted, just hidden, across that excursion
    /// specifically so `RemoteAttachPager`'s live connections survive it).
    /// `nil` only when no remote session has ever been selected this app
    /// session. Which stale session an invisible host's chrome technically
    /// describes never matters for correctness — visibility is separately
    /// gated on `selectedRemoteSession` itself, not this value.
    var remoteSessionHostSelection: RemoteSessionSelection? {
        selectedRemoteSession ?? recentlyAttachedRemoteSessions.first
    }
}
