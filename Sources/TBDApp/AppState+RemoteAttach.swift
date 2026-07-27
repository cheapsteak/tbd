import Foundation
import os
import TBDShared

private let remoteAttachLogger = Logger(subsystem: "com.tbd.app", category: "remoteAttach")

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
    /// mirror, not `gone`, not `dismissed`, whose provider declares the
    /// `attach` capability, and whose provider is not `.needsAuth`.
    ///
    /// The health check covers `.needsAuth` and NOTHING else, and the
    /// asymmetry is deliberate:
    ///
    /// - `.needsAuth` means the provider itself cannot authenticate, so a
    ///   fresh `attach` dies on connect — the contract's auth-needed section
    ///   says a caller SHOULD NOT spawn new `attach` processes in that state.
    ///   `pendingReconnectBlockedSelections` can't cover this on its own
    ///   because it only ever inspects selections that ALREADY have a
    ///   pending entry, i.e. ones that have already burned a doomed attach;
    ///   a never-attached session under an already-unhealthy provider would
    ///   sail straight past it.
    /// - `.stale` and `.error` deliberately do NOT block. Both describe a
    ///   failing `list` — an unreachable or misbehaving CONTROL path — which
    ///   says nothing about whether `attach` can connect, and `.stale` in
    ///   particular is ordinary transport flake. Blocking on them would turn
    ///   one bad poll into "you can't open your sessions".
    ///
    /// Reuses `RemoteSessionDetailGates.available` — the
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
            let provider = remoteProviders.first { $0.config.name == session.provider }
            guard provider?.health != .needsAuth else { return nil }
            let capabilities = provider?.describe?.capabilities ?? []
            guard RemoteSessionDetailGates.available(capabilities: capabilities, gone: session.gone).contains(.attach) else {
                return nil
            }
            return RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
        })
    }

    /// Whether the app's OWN bookkeeping already says `selection`'s last
    /// attach ended because the provider couldn't authenticate — the local
    /// half of the auth CTA's gate (`RemoteProviderAuthPresentation.make`'s
    /// `localAuthExit`), independent of the daemon round trip that publishes
    /// provider health.
    ///
    /// Reads the pending-reconnect entry rather than
    /// `explicitlyDetachedRemoteSessions`: `markRemoteSessionDetached` routes
    /// every non-clean class to the former, and the latter holds only clean
    /// exits, which are never auth by construction.
    func remoteSessionHasLocalAuthExit(_ selection: RemoteSessionSelection) -> Bool {
        RemoteAttachExitClass.classify(
            exitCode: pendingReconnectRemoteSessions[selection]?.exitCode) == .authNeeded
    }

    /// Tells the daemon the exit code of an `attach` process the APP spawned,
    /// so an auth-class exit can move provider health without waiting for the
    /// next 60s `list` poll to independently rediscover it. Fire-and-forget:
    /// the daemon's own poll remains the authoritative path, so a failed
    /// report costs freshness, never correctness — it's logged, never
    /// surfaced.
    ///
    /// `nil` exit codes are never reported: there is nothing to classify.
    func reportRemoteAttachExit(_ selection: RemoteSessionSelection, exitCode: Int32?) {
        guard let exitCode else { return }
        let report = remoteAttachExitReporter
        Task {
            do {
                try await report(selection.provider, selection.sessionID, exitCode)
            } catch {
                remoteAttachLogger.debug(
                    """
                    reportRemoteAttachExit failed for \(selection.provider, privacy: .public)/\
                    \(selection.sessionID, privacy: .public): \(error, privacy: .public)
                    """)
            }
        }
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
