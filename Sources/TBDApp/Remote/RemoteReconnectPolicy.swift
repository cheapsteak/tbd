import Foundation
import TBDShared

/// Backoff bookkeeping for one remote session whose attach terminal ended in
/// a NON-CLEAN class (`RemoteAttachExitClass.unexpected` or `.authNeeded`) —
/// distinct from `RemoteAttachDetachInfo`/`explicitlyDetachedRemoteSessions`,
/// which tracks a CLEAN exit the user chose (never auto-resumed). Neither
/// non-clean class is the user leaving — one is the transport's fault
/// (unreachable host, dropped connection), the other the provider's
/// credentials — so both are eligible to come back on their own once the
/// provider is healthy again; see `RemoteReconnectPolicy.isBlocked`.
struct RemotePendingReconnect: Equatable {
    /// The exit code that caused this entry (always non-zero — see
    /// `RemoteAttachExitClass` — since a `nil`/`0` exit routes to the
    /// clean-detach path instead).
    let exitCode: Int32?
    /// How many consecutive unexpected exits this selection has racked up
    /// without a clean run in between. Starts at 1 on the first unexpected
    /// exit, incremented each time `markRemoteSessionDetached` sees another
    /// one for a selection that already has a pending entry. An AUTH-class
    /// exit creates or preserves an entry without incrementing this — see
    /// `RemoteReconnectPolicy.authNeededPending`.
    let attempts: Int
    /// Earliest instant an automatic reattach may be attempted again.
    let nextEligibleAt: Date
}

/// Pure policy for automatic remote-attach reconnection after an unexpected
/// exit. No AppKit/SwiftUI/AppState dependency — directly unit-testable,
/// mirrors `RemoteAttachLifecycle`'s shape.
///
/// Reconnection is driven entirely by the app's EXISTING provider-health
/// poll/publish cycle (`AppState.refreshRemote()`, ~60s or push `events`) —
/// there is no timer here. Every time `remoteProviders` republishes,
/// `AppState.attachedRemoteSelections` recomputes and re-evaluates
/// `isBlocked` against the current wall clock, so a pending session becomes
/// eligible again on the poll tick at or after `nextEligibleAt`, without any
/// dedicated scheduling.
///
/// The cap on simultaneous live attaches (`AppState.remoteAttachKeepAliveLimit`)
/// is enforced entirely by `RemoteAttachLifecycle.attachedSelections` — this
/// type only decides whether a given selection is ELIGIBLE to be considered,
/// never how many can be live at once. A laptop waking from a long outage
/// with many pending sessions still only ever mounts up to the cap.
enum RemoteReconnectPolicy {
    /// Delay before the FIRST automatic reattach attempt after an unexpected
    /// exit, once the provider is healthy. Short enough that a single blip
    /// (one dropped packet, one missed poll) doesn't feel like a stuck UI.
    static let baseBackoff: TimeInterval = 5

    /// Ceiling on the exponential backoff below — caps how slowly a
    /// chronically-flapping provider gets retried, without ever fully
    /// giving up (a real multi-hour outage still recovers on the next poll
    /// after the provider reports healthy again).
    static let maxBackoff: TimeInterval = 300

    /// Exponential backoff for the Nth consecutive unexpected exit
    /// (`attempts` = 1 on the first failure): `baseBackoff * 2^(attempts-1)`,
    /// capped at `maxBackoff`. `attempts <= 0` is not a real state (an entry
    /// is only ever created with `attempts: 1`); returns 0 defensively.
    static func backoffInterval(attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        // Cap the exponent, not just the result, so `pow` never sees a huge
        // exponent that could overflow toward `.infinity`.
        let exponent = min(attempts - 1, 16)
        return min(maxBackoff, baseBackoff * pow(2, Double(exponent)))
    }

    /// Whether `pending`'s selection should still be excluded from automatic
    /// reattach right now: blocked unless the provider is healthy (`.ok`)
    /// AND this entry's own backoff window has elapsed. A provider that's
    /// merely `.stale`/`.error`/`.needsAuth` blocks regardless of timing —
    /// this is what makes "reattach is driven by provider health recovery,
    /// not a timer" true: no amount of elapsed backoff time admits a
    /// selection while its provider is still unhealthy.
    static func isBlocked(_ pending: RemotePendingReconnect, providerHealth: ProviderHealth, now: Date) -> Bool {
        guard providerHealth == .ok else { return true }
        return now < pending.nextEligibleAt
    }

    /// The next pending-reconnect entry for a selection that just had
    /// ANOTHER unexpected exit, given whatever entry (if any) already
    /// existed for it. Increments `attempts` on top of the prior value
    /// (starting at 1 for a fresh entry) so a session that keeps failing
    /// immediately after each automatic retry backs off further each time,
    /// rather than retrying at the same short interval forever.
    static func nextPending(exitCode: Int32?, previous: RemotePendingReconnect?, now: Date) -> RemotePendingReconnect {
        let attempts = (previous?.attempts ?? 0) + 1
        return RemotePendingReconnect(
            exitCode: exitCode,
            attempts: attempts,
            nextEligibleAt: now.addingTimeInterval(backoffInterval(attempts: attempts))
        )
    }

    /// The pending-reconnect entry for an attach that exited in the AUTH
    /// class (`RemoteAttachExitClass.authNeeded`). Same self-clearing
    /// mechanism as `nextPending` — the entry disappears on its own once the
    /// provider reports `.ok` again — but it deliberately does NOT escalate
    /// `attempts` (a fresh entry starts at 1 and stays there while auth
    /// exits repeat).
    ///
    /// Escalating would be measuring the wrong thing: exponential backoff
    /// exists to stop hammering a flapping transport, but an auth failure
    /// isn't hammering anything — `isBlocked` already refuses every reattach
    /// while health is `.needsAuth`, so the only effect of a grown backoff
    /// would be to delay the reattach that should follow the moment a human
    /// re-authenticates.
    static func authNeededPending(exitCode: Int32?, previous: RemotePendingReconnect?, now: Date) -> RemotePendingReconnect {
        let attempts = previous?.attempts ?? 1
        return RemotePendingReconnect(
            exitCode: exitCode,
            attempts: attempts,
            nextEligibleAt: now.addingTimeInterval(backoffInterval(attempts: attempts))
        )
    }
}
