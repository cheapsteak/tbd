import Foundation
import TBDShared

/// Exit info recorded for a remote session whose attach terminal ended.
/// `exitCode` mirrors `RemoteAttachTerminalView.isUnexpectedExit`'s input —
/// nil or 0 reads as a clean/ambiguous detach, anything else as unexpected.
struct RemoteAttachDetachInfo: Equatable {
    let exitCode: Int32?
}

/// Pure attach-lifecycle policy for remote sessions — the remote analogue of
/// `AppState.keepAliveWorktreeIDs`'s protected-selection + capped-recency
/// shape, adapted for a resource that keep-alive doesn't have to think about
/// for local worktrees: attaching to a remote session spawns a REAL new
/// connection process (over SSM/ssh or similar), not a reattach to a tmux
/// session the daemon already keeps running — so both "how many stay live at
/// once" (the cap) and "don't respawn one that just ended" (the
/// explicit-detach exclusion) matter here in a way they don't for local
/// terminals.
///
/// No AppKit/SwiftUI/AppState dependency — directly unit-testable. The
/// AppKit/PTY spawning itself (`RemoteAttachPager`, `RemoteAttachTerminalView`)
/// consumes this decision's output but isn't itself covered by this type.
enum RemoteAttachLifecycle {
    /// The set of remote-session selections whose attach terminal should be
    /// live right now, most-recent-first (the current `selected` session, if
    /// eligible, always leads).
    ///
    /// Semantics, mirroring `AppState.keepAliveWorktreeIDs`:
    /// - `selected` (the currently viewed session) is PROTECTED — force
    ///   included when eligible, and does NOT consume `cap`'s budget —
    ///   unless it's ineligible or explicitly detached, in which case it is
    ///   excluded even though it's selected. This is the rule that makes
    ///   "select = auto-attach" safe: a session that just detached does not
    ///   silently respawn merely because its row is still the current
    ///   selection (see `explicitlyDetached`).
    /// - Up to `cap` additional entries from `recentlyViewed` (most-recent
    ///   first, excluding whatever `selected` already contributed) stay
    ///   warm so switching back between recently-viewed sessions is instant.
    ///   Beyond the cap, older entries are simply absent from the result —
    ///   the caller (the pager) is expected to tear down anything no longer
    ///   present, which is where the actual eviction/`terminate()` happens.
    /// - `eligible` is a POSITIVE allowlist (not a negative "ineligible"
    ///   exclusion list) so a selection this function has never heard of —
    ///   an unregistered provider, a session absent from the mirror
    ///   entirely — defaults to NOT attachable rather than accidentally
    ///   attachable. Callers compute it from capability ("attach" declared)
    ///   AND liveness (`!gone`).
    /// - `explicitlyDetached` overrides eligibility in both directions: even
    ///   `selected` is excluded while flagged, and eviction from the warm
    ///   cache never happens for the OPPOSITE reason (a session doesn't need
    ///   to be "explicitly detached" to be evicted — plain cap pressure
    ///   already handles that via `recentlyViewed`'s ordering).
    static func attachedSelections(
        selected: RemoteSessionSelection?,
        recentlyViewed: [RemoteSessionSelection],
        eligible: Set<RemoteSessionSelection>,
        explicitlyDetached: Set<RemoteSessionSelection>,
        cap: Int
    ) -> [RemoteSessionSelection] {
        func attachable(_ selection: RemoteSessionSelection) -> Bool {
            eligible.contains(selection) && !explicitlyDetached.contains(selection)
        }

        var result: [RemoteSessionSelection] = []
        var seen = Set<RemoteSessionSelection>()

        if let selected, attachable(selected) {
            result.append(selected)
            seen.insert(selected)
        }

        var kept = 0
        for selection in recentlyViewed {
            guard !seen.contains(selection) else { continue }
            guard attachable(selection) else { continue }
            guard kept < cap else { continue }
            result.append(selection)
            seen.insert(selection)
            kept += 1
        }

        return result
    }
}
