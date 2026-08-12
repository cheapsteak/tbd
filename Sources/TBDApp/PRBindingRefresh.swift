import Foundation
import TBDShared

/// Turning a `pr.bindingsAll` response into the app's published PR state —
/// pulled out of `AppState.refreshPRBindings` as a pure value transform so the
/// contract below can be asserted without a daemon.
///
/// The daemon reports the whole binding table in one call, so a successful poll
/// REPLACES the published maps rather than merging into them. That is what makes
/// the two outcomes that matter fall out of the shape rather than out of
/// per-worktree bookkeeping:
///
/// - a FAILED fetch keeps the previous maps untouched. An RPC hiccup is not
///   evidence that the fleet lost its PRs, and blanking every toolbar at once is
///   a very visible flap. `AppState` simply does not call this on a failure.
/// - a worktree ABSENT from the response loses its entry. Everything-detached,
///   or nothing ever bound, is a real answer and the surfaces must follow it.
enum PRBindingRefresh {

    /// The published state this transform produces. `detachedCounts` is tracked
    /// alongside `bindings` rather than inside it because it survives the very
    /// case that empties `bindings`: a worktree whose last PR was detached has
    /// no live bindings and a non-zero count, and that count is the only thing
    /// keeping the legacy-status fallback from resurrecting the detached PR.
    struct State: Equatable {
        var bindings: [UUID: [PRBinding]] = [:]
        var detachedCounts: [UUID: Int] = [:]
    }

    /// The state a whole-fleet response describes.
    ///
    /// Empty lists and zero counts are stored as ABSENCE, so each map stays the
    /// set of worktrees that actually have something rather than growing an
    /// entry per worktree ever polled — and so equality against the previously
    /// published map means what `AppState` reads it as.
    static func state(from result: PRBindingsAllResult) -> State {
        var state = State()
        for entry in result.worktrees {
            if !entry.bindings.isEmpty {
                state.bindings[entry.worktreeID] = entry.bindings
            }
            // A daemon that predates the field omits it; `nil` reads as zero,
            // the pre-existing behaviour.
            if let detached = entry.detachedCount, detached > 0 {
                state.detachedCounts[entry.worktreeID] = detached
            }
        }
        return state
    }
}
